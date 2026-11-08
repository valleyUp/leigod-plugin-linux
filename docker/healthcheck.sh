#!/bin/sh
set -eu

test -c /dev/net/tun
pgrep -f '^/opt/leigod/acc-gw.router.amd64 .*daemon' >/dev/null
pgrep -f '^/opt/leigod/acc-gw.router.amd64 .*web' >/dev/null
ss -H -ltn 'sport = :5588' | grep -q '^LISTEN[[:space:]]'
ss -H -lun 'sport = :53' | grep -q '127.0.0.53:53'
ss -H -ltn 'sport = :53' | grep -q '127.0.0.53:53'
