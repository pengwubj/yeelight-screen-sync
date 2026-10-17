#!/usr/bin/env python3
"""Check the files selected for publication, without printing matched secrets."""
import argparse
from pathlib import Path
import re
import struct
import subprocess
import sys


PATTERNS = {
    'personal filesystem path': re.compile(rb'(?:/Users/|/home/)[A-Za-z0-9._-]+/'),
    'hardcoded private IPv4 address': re.compile(rb'\b(?:10\.(?:\d{1,3}\.){2}\d{1,3}|192\.168\.\d{1,3}\.\d{1,3}|172\.(?:1[6-9]|2\d|3[01])\.\d{1,3}\.\d{1,3})\b'),
    'GitHub credential': re.compile(rb'\b(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{30,})\b'),
    'private key material': re.compile(rb'-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----'),
    'cloud access key': re.compile(rb'\bAKIA[0-9A-Z]{16}\b'),
}
FORBIDDEN_PARTS = {'.build', 'dist', '__pycache__', '.DS_Store', 'xcuserdata'}
FORBIDDEN_SUFFIXES = {'.log', '.pem', '.key', '.p12', '.mobileprovision', '.zip', '.app'}
PNG_CHUNKS = {b'IHDR', b'PLTE', b'IDAT', b'IEND', b'sRGB', b'gAMA', b'cHRM', b'pHYs', b'iCCP', b'tRNS', b'sBIT'}


def check_png(data):
    if not data.startswith(b'\x89PNG\r\n\x1a\n'):
        return False
    offset = 8
    while offset + 12 <= len(data):
        size = struct.unpack('>I', data[offset:offset + 4])[0]
        kind = data[offset + 4:offset + 8]
        if kind not in PNG_CHUNKS or offset + 12 + size > len(data):
            return False
        offset += 12 + size
        if kind == b'IEND':
            return offset == len(data)
    return False


def check_jpeg(data):
    if not data.startswith(b'\xff\xd8') or not data.endswith(b'\xff\xd9'):
        return False
    offset = 2
    while offset + 4 <= len(data):
        if data[offset] != 255:
            return False
        marker = data[offset + 1]
        if marker in {0xe1, 0xed, 0xfe}:  # EXIF/XMP, Photoshop or comments.
            return False
        if marker == 0xda:
            return True
        size = struct.unpack('>H', data[offset + 2:offset + 4])[0]
        if size < 2 or offset + 2 + size > len(data):
            return False
        offset += 2 + size
    return False


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--staged', action='store_true', help='Read Git index contents instead of working files')
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    paths = subprocess.check_output(['git', 'ls-files', '-z'], cwd=root).split(b'\0')
    failures = []
    checked = 0
    for encoded in filter(None, paths):
        name = encoded.decode()
        path = Path(name)
        if any(part in FORBIDDEN_PARTS or part.endswith('.app') for part in path.parts) or path.suffix in FORBIDDEN_SUFFIXES or path.name.startswith('.env'):
            failures.append((name, 'local artifact or credential file'))
            continue
        data = subprocess.check_output(['git', 'show', ':' + name], cwd=root) if args.staged else (root / path).read_bytes()
        checked += 1
        if path.suffix == '.png':
            if not check_png(data):
                failures.append((name, 'unexpected image metadata or invalid PNG'))
            continue
        if path.suffix in {'.jpg', '.jpeg'}:
            if not check_jpeg(data):
                failures.append((name, 'unexpected image metadata or invalid JPEG'))
            continue
        if b'\0' in data:
            failures.append((name, 'unexpected binary file'))
            continue
        for label, expression in PATTERNS.items():
            if expression.search(data):
                failures.append((name, label))
    if not checked:
        print('FAIL: no tracked publication files to inspect', file=sys.stderr)
        return 1
    for name, label in failures:
        print(f'FAIL: {name}: {label}', file=sys.stderr)
    if failures:
        return 1
    print(f'PASS: {checked} publication files; no matched credentials, personal paths, private IPv4 literals or forbidden artifacts')
    print('Image pixels still require visual review; pattern checks are not a complete secret audit.')
    return 0


if __name__ == '__main__':
    sys.exit(main())
