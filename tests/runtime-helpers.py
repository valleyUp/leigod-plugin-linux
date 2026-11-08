#!/usr/bin/env python3

import importlib.util
import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest import mock

REPO = Path(__file__).resolve().parents[1]


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    loaded = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(loaded)
    return loaded


logs = module('logs', REPO / 'docker/log-forwarder.py')
status = module('status', REPO / 'docker/status.py')


class Installer(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='leigod-install-test-')
        self.root = Path(self.temp.name)
        (self.root / 'libexec').mkdir()
        (self.root / '.leigod').mkdir()
        shutil.copy(REPO / 'install.sh', self.root)
        for filename in ('install-config.sh', 'install-manifest.sh'):
            shutil.copy(REPO / 'libexec' / filename, self.root / 'libexec')
        self.config = self.root / '.leigod/docker.env'
        self.config.write_text('LEIGOD_NETWORK_MODE=bridge\nLEIGOD_BIND_ADDRESS=0.0.0.0\nLEIGOD_LOG_LEVEL=info\n'
                               'LEIGOD_DEVICE_MAC=02:11:22:33:44:55\nLEIGOD_DEBUG=1\nLEIGOD_USER=example-user\n'
                               'LEIGOD_BRIDGE_SUBNET=172.30.0.0/16\nLEIGOD_BRIDGE_IPV4=172.30.0.2\n'
                               'LEIGOD_BRIDGE_GATEWAY=172.30.0.1\nLEIGOD_BINARY_SHA256=' + 'a' * 64 + '\n')

    def tearDown(self):
        self.temp.cleanup()

    def config_output(self, arguments=(), environment=None):
        env = {key: value for key, value in os.environ.items() if not key.startswith('LEIGOD_')}
        env.update(environment or {})
        return subprocess.run(['sh', str(self.root / 'install.sh'), '--show-config', *arguments],
                              capture_output=True, text=True, env=env)

    def test_reinstall_retains_settings_and_precedence(self):
        before = self.config.read_bytes()
        result = self.config_output()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('LEIGOD_NETWORK_MODE=bridge\n', result.stdout)
        self.assertIn('LEIGOD_BIND_ADDRESS=0.0.0.0\n', result.stdout)
        self.assertIn('LEIGOD_DEBUG=1\n', result.stdout)
        self.assertIn('LEIGOD_DEVICE_MAC=02:11:22:33:44:55\n', result.stdout)
        self.assertIn('LEIGOD_BRIDGE_SUBNET=172.30.0.0/16\n', result.stdout)
        self.assertIn('LEIGOD_BINARY_SHA256=' + 'a' * 64 + '\n', result.stdout)
        result = self.config_output(['--log-level', 'warn', '--bind-address', '192.168.0.124'],
                                    {'LEIGOD_LOG_LEVEL': 'debug', 'LEIGOD_BIND_ADDRESS': '127.0.0.1'})
        self.assertEqual(result.returncode, 0)
        self.assertIn('LEIGOD_LOG_LEVEL=warn\n', result.stdout)
        self.assertIn('LEIGOD_BIND_ADDRESS=192.168.0.124\n', result.stdout)
        result = self.config_output(environment={'LEIGOD_LOG_LEVEL': 'debug'})
        self.assertIn('LEIGOD_LOG_LEVEL=debug\n', result.stdout)
        self.assertEqual(self.config.read_bytes(), before)

    def test_config_does_not_execute_shell_and_rejects_duplicate_or_symlink(self):
        marker = self.root / 'executed'
        self.config.write_text(f'LEIGOD_NETWORK_MODE=$(touch {marker})\n')
        self.assertNotEqual(self.config_output().returncode, 0)
        self.assertFalse(marker.exists())
        self.config.write_text('LEIGOD_NETWORK_MODE=bridge\nLEIGOD_NETWORK_MODE=macvlan\n')
        self.assertNotEqual(self.config_output().returncode, 0)
        self.config.unlink()
        target = self.root / 'target'
        target.write_text('LEIGOD_NETWORK_MODE=bridge\n')
        self.config.symlink_to(target)
        self.assertNotEqual(self.config_output().returncode, 0)

    def test_network_reuse_changes_and_foreign_ownership(self):
        docker = self.root / 'docker'
        docker.write_text('#!/bin/sh\n[ "$NETWORK_DATA" != absent ] || exit 1\nprintf "%s\\n" "$NETWORK_DATA"\n')
        docker.chmod(0o700)
        script = '. "$1"\nDOCKER=$2\nleigod_network_state leigod-plugin-bridge bridge 172.21.0.0/16 172.21.0.1 com.docker.network.bridge.name leigodbr0\n'
        cases = (
            ('bridge|leigod-plugin|172.21.0.0/16:172.21.0.1;|leigodbr0', 'reuse', 0),
            ('bridge|leigod-plugin|172.22.0.0/16:172.22.0.1;|leigodbr0', 'recreate', 0),
            ('bridge|leigod-plugin|172.21.0.0/16:172.21.0.1;|br-old', 'recreate', 0),
            ('bridge|other-project|172.21.0.0/16:172.21.0.1;|leigodbr0', '', 1),
            ('absent', 'absent', 0),
        )
        for data, expected, code in cases:
            with self.subTest(data=data):
                result = subprocess.run(['sh', '-c', script, 'test', str(REPO / 'libexec/install-config.sh'), str(docker)],
                                        capture_output=True, text=True, env={**os.environ, 'NETWORK_DATA': data})
                self.assertEqual(result.returncode, code, result.stderr)
                self.assertEqual(result.stdout.strip(), expected)


class Logs(unittest.TestCase):
    def test_alternating_repeats_and_redaction(self):
        logs.self_test()
        safe = logs.sanitize('WARN {"password":"escaped\\\"secret","user_id":1234} Authorization: Basic credential')
        self.assertNotIn('secret', safe)
        self.assertNotIn('1234', safe)
        self.assertNotIn('credential', safe)
        self.assertEqual(len(logs.sanitize('WARN ' + 'x' * 10000)), logs.MAX_LINE_LENGTH)

    def test_follow_partial_lines_rotation_truncation_and_oversize(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'web.log'
            path.write_bytes(b'old ignored line\n')
            tail = logs.Tail(path)
            try:
                self.assertEqual(tail.read(), [])
                with path.open('ab') as file:
                    file.write(b'WARN token=sec')
                self.assertEqual(tail.read(), [])
                with path.open('ab') as file:
                    file.write(b'ret\n')
                self.assertEqual(logs.sanitize(tail.read()[0]), 'WARN token=<redacted>')
                path.rename(path.with_suffix('.old'))
                path.write_bytes(b'WARN rotated\n')
                self.assertEqual(tail.read(), [])
                self.assertEqual(tail.read(), ['WARN rotated'])
                path.write_bytes(b'WARN x\n')
                self.assertEqual(tail.read(), ['WARN x'])
                with path.open('ab') as file:
                    file.write(b'x' * (logs.MAX_RAW_LENGTH * 2) + b'\nWARN after giant line\n')
                lines = []
                for _ in range(4):
                    lines.extend(tail.read())
                self.assertEqual(lines, ['WARN after giant line'])
            finally:
                tail.close()


class Status(unittest.TestCase):
    def collect(self, modes, rule=True, route=True, mark=True, listeners=True, readable=True):
        def command(*args):
            if args[:3] == ('ss', '-H', '-ltn'):
                return 'LISTEN 0 128 0.0.0.0:5588 *:*\nLISTEN 0 16 127.0.0.53:53 *:*' if listeners else ''
            if args[:3] == ('ss', '-H', '-lun'):
                return 'UNCONN 0 0 127.0.0.53:53 *:*' if listeners else ''
            if args[:3] == ('ip', '-j', 'link'):
                return json.dumps([{'flags': ['UP']}])
            if 'rule' in args:
                return json.dumps([{'table': 102, 'fwmark': '0x102'}] if rule else [])
            if 'route' in args:
                return json.dumps([{'dst': 'default', 'dev': 'tun_PC'}] if route else [])
            if args[0] == 'iptables':
                if not readable:
                    return ''
                return '-P OUTPUT ACCEPT\n' + ('-A OUTPUT -p tcp -j MARK --set-xmark 0x102/0xffffffff\n' if mark else '')
            raise AssertionError(args)
        with mock.patch.object(status, 'processes', return_value=set(modes)), \
             mock.patch.object(status, 'command', side_effect=command), \
             mock.patch.object(status, 'counter_sample', return_value=None), \
             mock.patch.object(Path, 'is_char_device', return_value=True):
            return status.snapshot(0)

    def test_idle_is_healthy_even_with_unused_tun(self):
        result = self.collect(('daemon', 'web'), rule=False, route=False, mark=False)
        self.assertTrue(result['service_healthy'])
        self.assertEqual(result['acceleration_state'], 'idle')

    def test_capture_missing_route_residual_and_missing_web(self):
        self.assertEqual(self.collect(('daemon', 'web', 'acc'))['acceleration_state'], 'capture_ready')
        self.assertEqual(self.collect(('daemon', 'web', 'acc'), route=False)['acceleration_state'], 'capture_incomplete')
        self.assertEqual(self.collect(('daemon', 'web'))['acceleration_state'], 'residual_capture')
        self.assertEqual(self.collect(('daemon',))['acceleration_state'], 'service_unhealthy')
        self.assertEqual(self.collect(('daemon', 'web'), readable=False)['acceleration_state'], 'inspection_incomplete')


if __name__ == '__main__':
    unittest.main(verbosity=2)
