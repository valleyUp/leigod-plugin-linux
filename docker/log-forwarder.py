#!/usr/bin/python3
"""Follow all vendor logs with bounded buffers and per-message rate limiting."""

import collections
import os
import re
import signal
import sys
import time
from pathlib import Path

REPEAT_SECONDS = 60
MAX_LINE_LENGTH = 4096
MAX_RAW_LENGTH = 65536
MAX_FINGERPRINTS = 1024
PROTECTED = r"token|nonce|user_id|password|authorization|cookie|speedSign"
JSON_SECRET = re.compile(r'("(?:' + PROTECTED + r')"\s*:\s*)("(?:\\.|[^"\\])*"|[^,}\s]+)', re.I)
AUTH_SECRET = re.compile(r'(Authorization\s*:\s*)(?:Bearer|Basic)\s+[^\s",;]+', re.I)
PLAIN_SECRET = re.compile(r'((?:' + PROTECTED + r')\b\s*[:=]\s*)[^,;\s]+', re.I)
URL_SECRET = re.compile(r'([?&][\w.-]*(?:token|secret|password|auth|sign|key)[\w.-]*=)[^&\s",;]+', re.I)
TIMESTAMP = re.compile(r'^\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\.\d+\s+')


def sanitize(line):
    line = JSON_SECRET.sub(r'\1"<redacted>"', line)
    line = AUTH_SECRET.sub(r'\1<redacted>', line)
    line = PLAIN_SECRET.sub(r'\1<redacted>', line)
    return URL_SECRET.sub(r'\1<redacted>', line)[:MAX_LINE_LENGTH]


def priority(line, fallback):
    if re.search(r'fatal|error|failed', line, re.I):
        return 0
    if re.search(r'warn|cannot|bad rule|rtnetlink|ioctl', line, re.I):
        return 1
    if re.search(r'debug', line, re.I):
        return 3
    if re.search(r'info', line, re.I):
        return 2
    return fallback


class Forwarder:
    def __init__(self, threshold, emit=print):
        self.threshold = threshold
        self.emit = emit
        self.levels = {}
        self.seen = collections.OrderedDict()

    def summary(self, key, record):
        if record[1]:
            self.emit(f'[leigod:{key[0]}] suppressed {record[1]} repetitions: {key[1]}'[:MAX_LINE_LENGTH])

    def flush(self, now, force=False):
        for key, record in list(self.seen.items()):
            if force or now - record[0] >= REPEAT_SECONDS:
                self.summary(key, record)
                del self.seen[key]

    def line(self, source, raw, now):
        safe = sanitize(raw)
        level = priority(safe, self.levels.get(source, 2))
        self.levels[source] = level
        if level > self.threshold:
            return
        key = (source, TIMESTAMP.sub('', safe))
        if key in self.seen:
            self.seen[key][1] += 1
            return
        if len(self.seen) >= MAX_FINGERPRINTS:
            old_key, old_record = self.seen.popitem(last=False)
            self.summary(old_key, old_record)
        self.seen[key] = [now, 0]
        self.emit(f'[leigod:{source}] {safe}'[:MAX_LINE_LENGTH])


class Tail:
    def __init__(self, path):
        self.path = path
        self.file = None
        self.identity = None
        self.buffer = b''
        self.oversize = False
        self.initial = True

    def close(self):
        if self.file:
            self.file.close()
        self.file = None

    def read(self):
        try:
            stat = self.path.stat()
        except FileNotFoundError:
            stat = None
        if self.file is None:
            if stat is None:
                return []
            self.file = self.path.open('rb')
            current = os.fstat(self.file.fileno())
            self.identity = (current.st_dev, current.st_ino)
            if self.initial:
                self.file.seek(0, 2)
                end = self.file.tell()
                if end:
                    self.file.seek(end - 1)
                    self.oversize = self.file.read(1) != b'\n'
                    self.file.seek(0, 2)
                self.initial = False
        elif stat and (stat.st_dev, stat.st_ino) == self.identity and stat.st_size < self.file.tell():
            self.file.seek(0)
            self.buffer = b''
            self.oversize = False
        data = self.file.read(65536)
        if not data:
            if stat and (stat.st_dev, stat.st_ino) != self.identity:
                self.close()
                self.buffer = b''
                self.oversize = False
            return []
        chunks = (self.buffer + data).split(b'\n')
        self.buffer = chunks.pop()
        lines = []
        for chunk in chunks:
            if self.oversize or len(chunk) > MAX_RAW_LENGTH:
                self.oversize = False
                continue
            lines.append(chunk.decode('utf-8', 'replace').rstrip('\r'))
        if len(self.buffer) > MAX_RAW_LENGTH:
            self.buffer = b''
            self.oversize = True
        return lines


def self_test():
    sample = 'WARN token=plain-secret {"user_id":42,"speedSign":"session-secret"} Authorization: Bearer bearer-secret https://example.invalid/?access_token=query-secret&mode=1'
    safe = sanitize(sample)
    assert all(secret not in safe for secret in ('plain-secret', 'session-secret', 'bearer-secret', 'query-secret', ':42'))
    assert safe.count('<redacted>') == 5
    assert priority('DEBUG test', 2) == 3
    assert priority('Cannot open device', 2) == 1
    lines = []
    forwarder = Forwarder(1, lines.append)
    for index in range(4):
        forwarder.line('web', '2026-01-01 00:00:00.000 WARN offline', index)
        forwarder.line('web', '2026-01-01 00:00:00.001 WARN empty', index)
    assert len(lines) == 2
    forwarder.flush(61)
    assert len(lines) == 4 and all('suppressed 3' in line for line in lines[2:])


def main():
    if sys.argv[1:] == ['--self-test']:
        self_test()
        return 0
    if sys.argv[1:]:
        print('usage: leigod-log-forwarder [--self-test]', file=sys.stderr)
        return 2
    level = os.environ.get('LEIGOD_LOG_LEVEL', 'warn')
    if level == 'off':
        return 0
    levels = {'error': 0, 'warn': 1, 'info': 2, 'debug': 3}
    if level not in levels:
        print(f'[leigod:log] invalid LEIGOD_LOG_LEVEL: {level}', file=sys.stderr)
        return 1
    directory = Path(os.environ.get('LEIGOD_LOG_DIR', '/tmp/acc/log'))
    directory.mkdir(parents=True, exist_ok=True)
    tails = {name: Tail(directory / filename) for name, filename in (
        ('daemon', 'acc_daemon.log'), ('game', 'acc_PC.log'),
        ('web', 'web_api.log'), ('console', 'console.log'))}
    forwarder = Forwarder(levels[level], lambda line: print(line, flush=True))
    running = True

    def stop(_signum, _frame):
        nonlocal running
        running = False

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    try:
        while running:
            now = time.monotonic()
            forwarder.flush(now)
            for source, tail in tails.items():
                for line in tail.read():
                    forwarder.line(source, line, now)
            time.sleep(0.2)
    finally:
        forwarder.flush(time.monotonic(), force=True)
        for tail in tails.values():
            tail.close()
    return 0


if __name__ == '__main__':
    sys.exit(main())
