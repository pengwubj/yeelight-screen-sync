"""Integration tests for the compiled Swift client; only loopback is used."""
import json
import socket
import subprocess
import threading
import time
import unittest


class LampSimulator:
    def __init__(self, mode):
        self.mode = mode
        self.tcp = socket.socket()
        self.tcp.bind(('127.0.0.1', 0))
        self.tcp.listen()
        self.tcp.settimeout(.2)
        self.udp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.udp.bind(('127.0.0.1', 0))
        self.udp.settimeout(.2)
        self.stopped = threading.Event()
        self.errors = []
        self.colours = self.heartbeats = 0
        self.token = '0123456789abcdef' * 2  # Synthetic fixture, never a real credential.
        self.threads = [threading.Thread(target=self.guard, args=(self.serve_tcp,), daemon=True),
                        threading.Thread(target=self.guard, args=(self.serve_udp,), daemon=True)]

    def guard(self, operation):
        try:
            operation()
        except Exception as exc:
            if not self.stopped.is_set():
                self.errors.append(exc)

    def serve_tcp(self):
        while not self.stopped.is_set():
            try:
                connection, _ = self.tcp.accept()
                break
            except socket.timeout:
                continue
        else:
            return
        with connection:
            connection.settimeout(2)
            data = b''
            while not data.endswith(b'\r\n'):
                part = connection.recv(4096)
                if not part:
                    return
                data += part
            request = json.loads(data)
            assert request['method'] == 'get_prop'
            if self.mode == 'timeout':
                for _ in range(20):
                    try:
                        connection.sendall(b'{"method":"props","params":{}}\r\n')
                    except (BrokenPipeError, ConnectionResetError):
                        break
                    time.sleep(.05)
                return
            if self.mode == 'error':
                reply = {'id': request['id'], 'error': {'code': -1, 'message': 'rejected'}}
            else:
                reply = {'id': request['id'], 'result': ['off', 'on', '16711680']}
            response = json.dumps(reply).encode() + b'\r\n'
            connection.sendall(b'{"method":"props","params":{"power":"on"}}\r\n' + response[:10])
            time.sleep(.02)
            connection.sendall(response[10:])

    def serve_udp(self):
        while not self.stopped.is_set():
            try:
                packet, address = self.udp.recvfrom(8192)
            except socket.timeout:
                continue
            assert packet.endswith(b'\r\n')
            request = json.loads(packet)
            method = request['method']
            if method == 'udp_sess_new':
                token = 'x' * 32 if self.mode == 'bad-token' else self.token
                reply = {'id': request['id'], 'method': 'udp_sess_token', 'params': {'token': token}}
            else:
                assert request['token'] == self.token
                if method == 'bg_set_rgb':
                    assert request['params'] == [16711680, 'sudden', 0]
                    self.colours += 1
                    continue
                assert method == 'udp_sess_keep_alive'
                assert request['params'] == ['keeplive_interval', '10']
                self.heartbeats += 1
                if self.mode == 'stale-ack':
                    reply = {'id': 999999, 'result': ['ok']}
                else:
                    reply = {'id': request['id'], 'method': method, 'params': {'token': self.token}}
            self.udp.sendto(json.dumps(reply).encode() + b'\r\n', address)

    def run(self):
        for thread in self.threads:
            thread.start()
        try:
            result = subprocess.run(['.build/TransportCheck', '127.0.0.1',
                                     str(self.tcp.getsockname()[1]), str(self.udp.getsockname()[1]), self.mode],
                                    timeout=55, capture_output=True, text=True)
            if result.returncode:
                raise AssertionError(result.stderr)
            return result.stdout
        finally:
            self.stopped.set()
            for thread in self.threads:
                thread.join(timeout=3)
            self.tcp.close()
            self.udp.close()
            assert not self.errors, self.errors
            assert all(not thread.is_alive() for thread in self.threads)


class TransportTests(unittest.TestCase):
    def test_stream(self):
        lamp = LampSimulator('stream')
        self.assertIn('PASS:', lamp.run())
        self.assertEqual(lamp.colours, 400)
        self.assertGreaterEqual(lamp.heartbeats, 5)

    def test_deadline(self):
        self.assertIn('absolute TCP deadline', LampSimulator('timeout').run())

    def test_device_error(self):
        self.assertIn('TCP device error', LampSimulator('error').run())

    def test_bad_token(self):
        self.assertIn('invalid UDP token', LampSimulator('bad-token').run())

    def test_unrelated_ack(self):
        self.assertIn('cannot keep session alive', LampSimulator('stale-ack').run())


if __name__ == '__main__':
    unittest.main(verbosity=2)
