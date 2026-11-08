#!/usr/bin/env python3
"""Exercise helpers against local UDP/TCP servers, without vendor/network access."""

import concurrent.futures
import contextlib
import socket
import struct
import subprocess
import tempfile
import threading
import time
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
QUERY = b'\x12\x34\x01\x00\x00\x01\x00\x00\x00\x00\x00\x00\x07example\x03com\x00\x00\x01\x00\x01'


def dns_reply(query, tail=b'\x01\x02\x03\x04', truncated=False):
    header = query[:2] + (b'\x83\x80' if truncated else b'\x81\x80') + b'\x00\x01\x00\x01\x00\x00\x00\x00'
    return header + query[12:29] + b'\xc0\x0c\x00\x01\x00\x01\x00\x00\x00\x3c\x00\x04' + tail


def receive_full(sock, length):
    data = b''
    while len(data) < length:
        part = sock.recv(length - len(data))
        if not part:
            raise EOFError('DNS TCP stream closed')
        data += part
    return data


class Server:
    def __init__(self, host='127.0.0.1', udp=None, tcp=None):
        self.udp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.udp.bind((host, 0))
        self.udp.settimeout(0.1)
        self.address = self.udp.getsockname()
        self.tcp = socket.socket()
        self.tcp.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.tcp.bind(self.address)
        self.tcp.listen()
        self.tcp.settimeout(0.1)
        self.running = True
        self.errors = []
        self.jobs = []

        def udp_loop():
            while self.running:
                try:
                    data, address = self.udp.recvfrom(65535)
                except socket.timeout:
                    continue
                if udp:
                    self.spawn(lambda d=data, a=address: udp(self.udp, d, a))

        def tcp_loop():
            while self.running:
                try:
                    client, _ = self.tcp.accept()
                except socket.timeout:
                    continue
                def respond(c=client):
                    with c:
                        c.settimeout(3)
                        length = struct.unpack('!H', receive_full(c, 2))[0]
                        query = receive_full(c, length)
                        if tcp:
                            reply = tcp(query)
                            c.sendall(struct.pack('!H', len(reply)) + reply)
                self.spawn(respond)

        self.threads = [threading.Thread(target=udp_loop), threading.Thread(target=tcp_loop)]
        for thread in self.threads:
            thread.start()

    def spawn(self, fn):
        def run():
            try:
                fn()
            except Exception as error:
                self.errors.append(error)
        thread = threading.Thread(target=run)
        self.jobs.append(thread)
        thread.start()

    def close(self):
        self.running = False
        for thread in self.threads:
            thread.join(2)
        for thread in self.jobs:
            thread.join(3)
        self.udp.close()
        self.tcp.close()


def free_port(host):
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        sock.bind((host, 0))
        return sock.getsockname()[1]


@contextlib.contextmanager
def helper(binary, arguments):
    process = subprocess.Popen([str(binary), *arguments], stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    time.sleep(0.1)
    if process.poll() is not None:
        raise RuntimeError(process.stderr.read().decode())
    try:
        yield process
    finally:
        process.terminate()
        try:
            process.wait(8)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()
        process.stderr.close()


class Helpers(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix='leigod-network-test-')
        cls.binaries = {}
        for name in ('dns-stub', 'discover-proxy'):
            path = Path(cls.temp.name) / name
            subprocess.run(['cc', '-std=c11', '-O2', '-Wall', '-Wextra', '-Werror', '-pthread',
                            '-D_FORTIFY_SOURCE=2', '-fstack-protector-strong', '-Wl,-z,relro,-z,now',
                            '-o', str(path), str(REPO / 'src' / f'leigod-{name}.c')], check=True)
            cls.binaries[name] = path

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    @contextlib.contextmanager
    def dns(self, server, extra=()):
        port = free_port('127.0.0.1')
        with helper(self.binaries['dns-stub'], ['--bind', '127.0.0.1', '--port', str(port),
                                              '--upstream', '%s:%s' % server.address, *extra]):
            yield ('127.0.0.1', port)

    def query(self, address, query=QUERY, tcp=False):
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM if tcp else socket.SOCK_DGRAM) as sock:
            sock.settimeout(5)
            if tcp:
                sock.connect(address)
                sock.sendall(struct.pack('!H', len(query)) + query)
                length = struct.unpack('!H', receive_full(sock, 2))[0]
                return receive_full(sock, length)
            sock.sendto(query, address)
            return sock.recvfrom(65535)[0]

    def test_dns_udp_tcp_and_truncation_fallback(self):
        calls = []
        def udp(sock, query, address):
            sock.sendto(dns_reply(query, truncated=True), address)
        def tcp(query):
            calls.append(query)
            return dns_reply(query)
        server = Server(udp=udp, tcp=tcp)
        try:
            with self.dns(server) as address:
                self.assertEqual(self.query(address)[-4:], b'\x01\x02\x03\x04')
                self.assertEqual(self.query(address, tcp=True)[-4:], b'\x01\x02\x03\x04')
                self.assertEqual(len(calls), 2)
        finally:
            server.close()
        self.assertFalse(server.errors)

    def test_dns_ignores_wrong_peer_id_question_and_query_packets(self):
        def udp(sock, query, address):
            good = dns_reply(query)
            with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as spoof:
                spoof.sendto(dns_reply(query, tail=b'BAD!'), address)
            sock.sendto(b'\x99\x99' + good[2:], address)
            sock.sendto(good[:12] + good[12:].replace(b'example', b'INVALID', 1), address)
            sock.sendto(query, address)
            time.sleep(0.03)
            sock.sendto(good, address)
        server = Server(udp=udp)
        try:
            with self.dns(server) as address:
                self.assertEqual(self.query(address), dns_reply(QUERY))
        finally:
            server.close()
        self.assertFalse(server.errors)

    def test_dns_slow_request_does_not_block_other_queries(self):
        def udp(sock, query, address):
            if query[:2] == b'\x12\x34':
                time.sleep(0.6)
            sock.sendto(dns_reply(query), address)
        server = Server(udp=udp)
        try:
            with self.dns(server) as address, concurrent.futures.ThreadPoolExecutor() as executor:
                slow = executor.submit(self.query, address)
                time.sleep(0.08)
                start = time.monotonic()
                self.assertEqual(self.query(address, b'\x56\x78' + QUERY[2:])[:2], b'\x56\x78')
                self.assertLess(time.monotonic() - start, 0.4)
                self.assertEqual(slow.result(), dns_reply(QUERY))
        finally:
            server.close()

    def test_dns_failover_and_servfail(self):
        silent = Server()
        working = Server(udp=lambda sock, query, address: sock.sendto(dns_reply(query), address))
        try:
            with self.dns(silent, ['--upstream', '%s:%s' % working.address]) as address:
                self.assertEqual(self.query(address), dns_reply(QUERY))
            with self.dns(silent) as address:
                answer = self.query(address)
                self.assertEqual(answer[:2], QUERY[:2])
                self.assertEqual(answer[3] & 15, 2)
        finally:
            silent.close()
            working.close()

    def test_dns_large_reply_preserves_udp_limit_and_tcp_full_reply(self):
        record = dns_reply(QUERY)[29:]
        large = QUERY[:2] + b'\x81\x80\x00\x01\x00\x28\x00\x00\x00\x00' + QUERY[12:] + record * 40
        server = Server(udp=lambda sock, query, address: sock.sendto(dns_reply(query, truncated=True), address),
                        tcp=lambda query: query[:2] + large[2:])
        try:
            with self.dns(server) as address:
                response = self.query(address)
                self.assertLessEqual(len(response), 512)
                self.assertTrue(response[2] & 2)
                self.assertEqual(self.query(address, tcp=True), large)
                edns = QUERY[:10] + b'\x00\x01' + QUERY[12:] + b'\x00\x00\x29\x04\xd0\x00\x00\x00\x00\x00\x00'
                self.assertEqual(self.query(address, edns), large)
        finally:
            server.close()

    def test_discovery_filters_and_rewrites_from_verified_peer(self):
        requests = []
        def respond(sock, query, address):
            requests.append(query)
            reply = b'<NBOX> WHO any acc-gw (model=SteamDeck, ip=172.21.0.2, bound=true)'
            with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as spoof:
                spoof.sendto(reply.replace(b'SteamDeck', b'BAD'), address)
            sock.sendto(b'unexpected packet', address)
            time.sleep(0.02)
            sock.sendto(reply, address)
        server = Server('127.0.0.2', udp=respond)
        try:
            with helper(self.binaries['discover-proxy'], ['--bind', '127.0.0.1', '--container', '127.0.0.2',
                                                         '--port', str(server.address[1])]):
                with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as client:
                    client.settimeout(1)
                    target = ('127.0.0.1', server.address[1])
                    client.sendto(b'garbage', target)
                    client.sendto(b'<NBOX> HELLOevil', target)
                    time.sleep(0.03)
                    client.sendto(b'<NBOX> HELLO any', target)
                    reply, source = client.recvfrom(4096)
                    self.assertEqual(source, target)
                    self.assertIn(b'ip=127.0.0.1', reply)
                    self.assertIn(b'model=SteamDeck', reply)
                    self.assertEqual(requests, [b'<NBOX> HELLO any'])
        finally:
            server.close()

    def test_discovery_late_reply_cannot_answer_next_client(self):
        def respond(sock, query, address):
            token = query.split()[-1]
            time.sleep(0.6 if token == b'A' else 0.25)
            sock.sendto(b'<NBOX> WHO ' + token + b' acc-gw (model=SteamDeck, ip=172.21.0.2)', address)
        server = Server('127.0.0.2', udp=respond)
        try:
            with helper(self.binaries['discover-proxy'], ['--bind', '127.0.0.1', '--container', '127.0.0.2',
                                                         '--port', str(server.address[1])]):
                target = ('127.0.0.1', server.address[1])
                with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as first, socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as second:
                    first.sendto(b'<NBOX> HELLO A', target)
                    time.sleep(0.45)
                    second.settimeout(1)
                    second.sendto(b'<NBOX> HELLO B', target)
                    reply, _ = second.recvfrom(2048)
                    self.assertIn(b'WHO B ', reply)
                    first.settimeout(0.05)
                    with self.assertRaises(socket.timeout):
                        first.recvfrom(2048)
        finally:
            server.close()

    def test_discovery_concurrent_clients(self):
        def respond(sock, query, address):
            token = query.split()[-1]
            if token == b'slow':
                time.sleep(0.3)
            sock.sendto(b'<NBOX> WHO ' + token + b' acc-gw (ip=172.21.0.2)', address)
        server = Server('127.0.0.2', udp=respond)
        try:
            with helper(self.binaries['discover-proxy'], ['--bind', '127.0.0.1', '--container', '127.0.0.2',
                                                         '--port', str(server.address[1])]):
                with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as slow, socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as fast:
                    target = ('127.0.0.1', server.address[1])
                    slow.sendto(b'<NBOX> HELLO slow', target)
                    time.sleep(0.05)
                    start = time.monotonic()
                    fast.settimeout(1)
                    fast.sendto(b'<NBOX> HELLO fast', target)
                    self.assertIn(b'WHO fast ', fast.recvfrom(2048)[0])
                    self.assertLess(time.monotonic() - start, 0.2)
        finally:
            server.close()


if __name__ == '__main__':
    unittest.main(verbosity=2)
