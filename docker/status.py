#!/usr/bin/python3
"""Report service health separately from PC acceleration capture and traffic."""

import argparse
import json
import re
import subprocess
import sys
import time
from pathlib import Path


def command(*args):
    result = subprocess.run(args, capture_output=True, text=True, timeout=3)
    return result.stdout if result.returncode == 0 else ''


def processes():
    modes = set()
    for path in Path('/proc').glob('[0-9]*/cmdline'):
        try:
            args = path.read_bytes().split(b'\0')
        except (FileNotFoundError, PermissionError, ProcessLookupError):
            continue
        if not args or args[0] != b'/opt/leigod/acc-gw.router.amd64':
            continue
        for index, arg in enumerate(args[:-1]):
            if arg == b'-r':
                modes.add(args[index + 1].decode('ascii', 'replace'))
    return modes


def counter_sample():
    try:
        return {key: int((Path('/sys/class/net/tun_PC/statistics') / key).read_text()) for key in
                ('rx_bytes', 'tx_bytes', 'rx_packets', 'tx_packets', 'rx_errors', 'tx_errors', 'rx_dropped', 'tx_dropped')}
    except (FileNotFoundError, ValueError):
        return None


def classify(service_healthy, acc_process, capture, residual):
    if not service_healthy:
        return 'service_unhealthy'
    if acc_process:
        return 'capture_ready' if capture else 'capture_incomplete'
    return 'residual_capture' if residual else 'idle'


def snapshot(sample_seconds):
    modes = processes()
    tcp = command('ss', '-H', '-ltn')
    udp = command('ss', '-H', '-lun')
    service = {
        'daemon': 'daemon' in modes,
        'web': 'web' in modes,
        'api_listener': bool(re.search(r':5588\s', tcp)),
        'dns_udp_listener': '127.0.0.53:53' in udp,
        'dns_tcp_listener': '127.0.0.53:53' in tcp,
        'tun_device': Path('/dev/net/tun').is_char_device(),
    }
    healthy = all(service.values())
    links = json.loads(command('ip', '-j', 'link', 'show', 'dev', 'tun_PC') or '[]')
    rules = json.loads(command('ip', '-j', '-4', 'rule', 'show') or '[]')
    routes = json.loads(command('ip', '-j', '-4', 'route', 'show', 'table', '102') or '[]')
    output = command('iptables', '-t', 'mangle', '-S', 'OUTPUT')
    policy = any(str(rule.get('table')) == '102' and str(rule.get('fwmark')) in ('258', '0x102') for rule in rules)
    tun_default = any(route.get('dst') == 'default' and route.get('dev') == 'tun_PC' for route in routes)
    mark = bool(re.search(r'-j MARK .*--set-(?:xmark|mark) 0x102(?:/|\s|$)', output))
    tun_up = any('UP' in link.get('flags', []) for link in links)
    capture = {'process': 'acc' in modes, 'tun_up': tun_up, 'policy_rule': policy,
               'default_route': tun_default, 'output_mark': mark, 'rules_readable': bool(output)}
    state = classify(healthy, capture['process'], tun_up and policy and tun_default and mark, policy or tun_default or mark)
    if healthy and not output:
        state = 'inspection_incomplete'
    traffic = None
    before = counter_sample()
    if sample_seconds and before is not None:
        time.sleep(sample_seconds)
        after = counter_sample()
        if after is not None and all(after[key] >= before[key] for key in before):
            traffic = {key: after[key] - before[key] for key in before}
    return {'service_healthy': healthy, 'service': service, 'acceleration_state': state,
            'capture': capture, 'sample_seconds': sample_seconds, 'tun_traffic_delta': traffic}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--json', action='store_true', help='machine-readable status without account data')
    parser.add_argument('--sample-seconds', type=float, default=2, help='TUN traffic sample duration, 0..30 (default: 2)')
    args = parser.parse_args()
    if not 0 <= args.sample_seconds <= 30:
        parser.error('--sample-seconds must be between 0 and 30')
    try:
        status = snapshot(args.sample_seconds)
    except (OSError, ValueError, subprocess.TimeoutExpired) as error:
        print(f'leigod-status: cannot collect status: {error}', file=sys.stderr)
        return 2
    if args.json:
        print(json.dumps(status, ensure_ascii=False))
    else:
        print('service: ' + ('healthy' if status['service_healthy'] else 'unhealthy'))
        print('acceleration: ' + status['acceleration_state'])
        print('capture: ' + ', '.join(f'{key}={str(value).lower()}' for key, value in status['capture'].items()))
        if status['tun_traffic_delta'] is not None:
            print('TUN traffic delta: ' + json.dumps(status['tun_traffic_delta']))
        print('capture_ready shows interception readiness; TUN traffic does not prove a particular game uses a node.')
    return 0 if status['acceleration_state'] in ('idle', 'capture_ready') else 1


if __name__ == '__main__':
    sys.exit(main())
