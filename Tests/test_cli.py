import socket
import threading
import unittest
from unittest.mock import patch
import yeelight


class CliTests(unittest.TestCase):
    def test_discovery(self):
        data = (b'HTTP/1.1 200 OK\r\nLocation: yeelight://192.0.2.42:55443\r\n'
                b'model: lamp15\r\nsupport: get_prop bg_set_rgb\r\n\r\n')
        self.assertEqual(yeelight.parse_discovery(data)['model'], 'lamp15')
        self.assertIsNone(yeelight.parse_discovery(b'HTTP/1.1 200 OK\r\nLocation: http://example.com\r\n'))

    def test_background_command(self):
        args = yeelight.make_parser().parse_args(['--ip', '127.0.0.1', '--bg', 'color', 'FF8800'])
        with patch.object(yeelight, 'request', return_value=['ok']) as request:
            yeelight.run(args)
            request.assert_called_once_with('127.0.0.1', 55443, 'bg_set_rgb', [0xff8800, 'smooth', 300])

    def test_multiple_devices(self):
        with patch.object(yeelight, 'discover', return_value=[{'ip': '192.0.2.42'}, {'ip': '192.0.2.43'}]):
            with self.assertRaisesRegex(yeelight.LightError, '多台'):
                yeelight.run(yeelight.make_parser().parse_args(['on']))

    def test_reply_notifications_and_fragmentation(self):
        with socket.socket() as listener:
            listener.bind(('127.0.0.1', 0))
            listener.listen()
            listener.settimeout(2)
            port = listener.getsockname()[1]
            errors = []

            def serve():
                try:
                    connection, _ = listener.accept()
                    with connection:
                        connection.settimeout(2)
                        request = b''
                        while not request.endswith(b'\r\n'):
                            part = connection.recv(4096)
                            if not part:
                                raise AssertionError('Client disconnected')
                            request += part
                        self.assertIn(b'"method": "get_prop"', request)
                        connection.sendall(b'{"method":"props","params":{}}\r\n{"id":1,"res')
                        connection.sendall(b'ult":["on"]}\r\n')
                except Exception as exc:
                    errors.append(exc)

            thread = threading.Thread(target=serve, daemon=True)
            thread.start()
            try:
                self.assertEqual(yeelight.request('127.0.0.1', port, 'get_prop', ['power']), ['on'])
            finally:
                thread.join(timeout=3)
            self.assertFalse(thread.is_alive())
            self.assertEqual(errors, [])


if __name__ == '__main__':
    unittest.main()
