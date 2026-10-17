#!/usr/bin/env python3
"""Yeelight LAN CLI. Python 3.10+, standard library only."""

import argparse
import ipaddress
import json
import re
import socket
import sys
import time
from urllib.parse import urlsplit


SEARCH = (
    'M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1982\r\n'
    'MAN: "ssdp:discover"\r\nST: wifi_bulb\r\n\r\n'
).encode('ascii')
PROPERTIES = ['power', 'bright', 'ct', 'color_mode', 'rgb',
              'bg_power', 'bg_bright', 'bg_ct', 'bg_rgb', 'bg_color_mode', 'name']


class LightError(Exception):
    pass


def parse_discovery(data):
    lines = data.decode('utf-8', errors='replace').split('\r\n')
    if not lines or lines[0] != 'HTTP/1.1 200 OK':
        return None
    headers = {}
    for line in lines[1:]:
        key, sep, value = line.partition(':')
        if sep:
            headers[key.strip().lower()] = value.strip()
    try:
        url = urlsplit(headers.get('location', ''))
        if url.scheme != 'yeelight' or not url.hostname:
            return None
        ipaddress.IPv4Address(url.hostname)
        port = url.port or 55443
        if not 1 <= port <= 65535:
            return None
    except ValueError:
        return None
    return {'ip': url.hostname, 'port': port, **headers}


def discover(timeout=3.0, interface=None):
    devices = {}
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP) as sock:
        sock.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_TTL, 2)
        if interface:
            sock.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_IF,
                            socket.inet_aton(interface))
        sock.bind((interface or '', 0))
        deadline = time.monotonic() + timeout
        next_search = 0.0
        while time.monotonic() < deadline:
            now = time.monotonic()
            if now >= next_search:
                sock.sendto(SEARCH, ('239.255.255.250', 1982))
                next_search = now + 1.0
            sock.settimeout(min(.25, max(.001, deadline - time.monotonic())))
            try:
                data, _ = sock.recvfrom(8192)
            except socket.timeout:
                continue
            device = parse_discovery(data)
            if device:
                devices[(device['ip'], device['port'])] = device
    return sorted(devices.values(), key=lambda d: d['ip'])


def request(host, port, method, params, timeout=3.0):
    """One command per connection; skip asynchronous property notifications."""
    payload = json.dumps({'id': 1, 'method': method, 'params': params}) + '\r\n'
    deadline = time.monotonic() + timeout
    with socket.create_connection((host, port), timeout=timeout) as sock:
        sock.sendall(payload.encode('utf-8'))
        buffer = b''
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise LightError('设备回应超时')
            sock.settimeout(remaining)
            chunk = sock.recv(4096)
            if not chunk:
                raise LightError('设备在回应前关闭了连接')
            buffer += chunk
            if len(buffer) > 65536:
                raise LightError('设备回应过大')
            while b'\r\n' in buffer:
                line, buffer = buffer.split(b'\r\n', 1)
                if not line:
                    continue
                reply = json.loads(line)
                if not isinstance(reply, dict):
                    raise LightError('设备回应格式错误')
                if reply.get('id') != 1:
                    continue
                if 'error' in reply:
                    raise LightError('设备拒绝命令：' + json.dumps(reply['error'], ensure_ascii=False))
                if not isinstance(reply.get('result'), list):
                    raise LightError('设备回应缺少 result 列表')
                return reply['result']


def bounded(low, high):
    def parse(value):
        try:
            number = int(value)
        except ValueError as exc:
            raise argparse.ArgumentTypeError('请输入整数') from exc
        if not low <= number <= high:
            raise argparse.ArgumentTypeError(f'范围必须是 {low}–{high}')
        return number
    return parse


def rgb(value):
    if not re.fullmatch(r'#?[0-9a-fA-F]{6}', value):
        raise argparse.ArgumentTypeError('颜色格式应为 FF8800 或 "#FF8800"')
    return int(value.lstrip('#'), 16)


def make_parser():
    parser = argparse.ArgumentParser(description='Yeelight 挂灯局域网控制')
    parser.add_argument('--ip', help='挂灯 IP；省略时自动发现，且必须只有一台设备')
    parser.add_argument('--port', type=bounded(1, 65535), default=None, help='TCP 端口，默认 55443')
    parser.add_argument('--interface', help='发现使用的本机 IPv4 地址，多网卡时可指定')
    parser.add_argument('--bg', action='store_true', help='控制背部氛围灯')
    parser.add_argument('--duration', type=bounded(30, 60000), default=300, help='渐变毫秒数，默认 300')
    sub = parser.add_subparsers(dest='command', required=True)
    sub.add_parser('discover', help='发现设备及其支持的命令')
    sub.add_parser('status', help='读取状态，不改变灯光')
    for action in ('on', 'off', 'toggle'):
        sub.add_parser(action, help={'on': '开灯', 'off': '关灯', 'toggle': '切换开关'}[action])
    p = sub.add_parser('brightness', help='设置亮度 1–100')
    p.add_argument('value', type=bounded(1, 100))
    p = sub.add_parser('temperature', help='设置色温；具体范围取决于型号')
    p.add_argument('value', type=bounded(1700, 6500))
    p = sub.add_parser('color', help='设置 RGB 颜色；挂灯通常仅背部支持')
    p.add_argument('value', type=rgb)
    return parser


def run(args):
    device = None
    if args.command == 'discover' or not args.ip:
        devices = discover(interface=args.interface)
        if args.command == 'discover':
            if not devices:
                raise LightError('未发现设备。请确认灯已联网、App 中已开启局域网控制；也可用 --ip 指定地址。')
            return devices
        if not devices:
            raise LightError('未发现设备。请开启 App 中的局域网控制，或用 --ip 指定地址。')
        if len(devices) != 1:
            raise LightError('发现多台设备，请用 --ip 指定：' + ', '.join(d['ip'] for d in devices))
        device = devices[0]
        args.ip = device['ip']
    port = args.port if args.port is not None else (device['port'] if device else 55443)
    prefix = 'bg_' if args.bg else ''
    if args.command == 'status':
        values = request(args.ip, port, 'get_prop', PROPERTIES)
        if len(values) != len(PROPERTIES):
            raise LightError('状态回应数量与请求不符')
        return {'ip': args.ip, **dict(zip(PROPERTIES, values))}
    if args.command in ('on', 'off'):
        method, params = prefix + 'set_power', [args.command, 'smooth', args.duration]
    elif args.command == 'toggle':
        method, params = prefix + 'toggle', []
    else:
        method = prefix + {'brightness': 'set_bright', 'temperature': 'set_ct_abx', 'color': 'set_rgb'}[args.command]
        params = [args.value, 'smooth', args.duration]
    if device and device.get('support') and method not in device['support'].split():
        raise LightError(f'此设备未声明支持 {method}')
    return {'ip': args.ip, 'method': method, 'result': request(args.ip, port, method, params)}


def main():
    args = make_parser().parse_args()
    try:
        print(json.dumps(run(args), ensure_ascii=False, indent=2))
        return 0
    except (LightError, OSError, ValueError) as exc:
        print(f'错误：{exc}', file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
