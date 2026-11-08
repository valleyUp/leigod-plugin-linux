#!/usr/bin/python3
"""Keep the accelerator subnet in main, including when the uplink disappears."""
import argparse
import ipaddress
import json
import os
import subprocess

SUBNET = '172.21.0.0/16'
PROTOCOL = 242
RULES = [
    (100, 'from', 'lookup', 'main'),
    (101, 'from', 'unreachable', None),
    (102, 'to', 'lookup', 'main'),
    (103, 'to', 'unreachable', None),
]


def installed():
    return json.loads(subprocess.check_output(['ip', '-N', '-j', '-4', 'rule', 'show']))


def matches(rule, spec, subnet=SUBNET):
    priority, direction, action, table = spec
    address, bits = subnet.split('/')
    key = 'src' if direction == 'from' else 'dst'
    other = 'dst' if direction == 'from' else 'src'
    return (
        rule.get('priority') == priority
        and str(rule.get('protocol')) == str(PROTOCOL)
        and rule.get(key) == address
        and rule.get(key + 'len') == int(bits)
        and rule.get(other, 'all') == 'all'
        and (rule.get('table') in (table, '254', 254) if action == 'lookup'
             else str(rule.get('action')) in ('unreachable', '7'))
        and set(rule).issubset({'priority', 'protocol', 'src', 'srclen', 'dst',
                               'dstlen', 'action', 'table', 'flags'})
        and not rule.get('flags')
    )


def command(operation, spec, subnet=SUBNET):
    priority, direction, action, table = spec
    args = ['ip', '-4', 'rule', operation, 'pref', str(priority), direction,
            subnet, action]
    if table is not None:
        args.append(table)
    return args + ['protocol', str(PROTOCOL)]


def apply(remove=False, subnet=SUBNET, check_only=False):
    current = installed()
    # Refuse collisions before changing any rule.
    for spec in RULES:
        same_priority = [r for r in current if r.get('priority') == spec[0]]
        if any(not matches(r, spec, subnet) for r in same_priority) or len(same_priority) > 1:
            raise RuntimeError(f'ip rule priority {spec[0]} is already in use')
    if check_only:
        return
    if remove:
        for spec in RULES:
            if any(matches(r, spec, subnet) for r in current):
                subprocess.run(command('del', spec, subnet), check=True)
    else:
        added = []
        try:
            for spec in RULES:
                if not any(matches(r, spec, subnet) for r in current):
                    subprocess.run(command('add', spec, subnet), check=True)
                    added.append(spec)
        except Exception:
            for spec in reversed(added):
                subprocess.run(command('del', spec, subnet), check=False)
            raise


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--subnet', default=SUBNET, help='dedicated IPv4 bridge subnet')
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument('--remove', action='store_true')
    mode.add_argument('--check', action='store_true', help='check priority ownership without changing rules')
    args = parser.parse_args()
    if os.geteuid() != 0:
        parser.error('root is required')
    try:
        subnet = ipaddress.ip_network(args.subnet, strict=True)
    except ValueError as error:
        parser.error(str(error))
    if subnet.version != 4 or not subnet.is_private or subnet.prefixlen < 8:
        parser.error('a dedicated private IPv4 subnet with prefix length >= 8 is required')
    apply(args.remove, str(subnet), args.check)


if __name__ == '__main__':
    main()
