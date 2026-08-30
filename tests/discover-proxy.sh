#!/bin/sh
set -eu

REPO_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
WORK_DIR=$(mktemp -d "$REPO_DIR/.leigod-test.XXXXXX")
plugin_pid=
proxy_pid=

cleanup() {
    if [ -n "$proxy_pid" ]; then
        kill "$proxy_pid" 2>/dev/null || true
        wait "$proxy_pid" 2>/dev/null || true
    fi
    if [ -n "$plugin_pid" ]; then
        kill "$plugin_pid" 2>/dev/null || true
        wait "$plugin_pid" 2>/dev/null || true
    fi
    rm -rf -- "$WORK_DIR"
}
trap cleanup EXIT HUP INT TERM

fail() {
    printf 'discover-proxy: %s\n' "$*" >&2
    exit 1
}

cc -std=c11 -O2 -Wall -Wextra -Werror -D_FORTIFY_SOURCE=2 \
    -fstack-protector-strong -Wl,-z,relro,-z,now \
    -o "$WORK_DIR/leigod-discover-proxy" "$REPO_DIR/src/leigod-discover-proxy.c"

"$WORK_DIR/leigod-discover-proxy" --self-test || fail 'C self-test failed'

python3 - <<'PY' || fail 'loopback 127.0.0.2 is unavailable for the rewrite test'
import socket
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.bind(("127.0.0.2", 0))
s.close()
PY

python3 - <<'PY' &
import socket
reply = (
    b"<NBOX> WHO abc acc-gw (model=SteamDeck, sn=02:11:22:33:44:55, "
    b"fw=, sw=1.2.2.15, ip=172.21.0.2, bound=true)"
)
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.2", 46066))
s.settimeout(8)
try:
    data, addr = s.recvfrom(2048)
    if b"<NBOX>" in data:
        s.sendto(reply, addr)
except socket.timeout:
    pass
s.close()
PY
plugin_pid=$!
sleep 0.2

"$WORK_DIR/leigod-discover-proxy" --bind 127.0.0.1 --container 127.0.0.2 --port 46066 \
    >/dev/null 2>"$WORK_DIR/proxy.err" &
proxy_pid=$!
sleep 0.2
kill -0 "$proxy_pid" 2>/dev/null || fail "proxy failed to start: $(cat "$WORK_DIR/proxy.err")"

python3 - <<'PY' || fail 'rewritten discovery reply was not received'
import socket
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.settimeout(2)
s.bind(("127.0.0.1", 0))
s.sendto(b"<NBOX> HELLO", ("127.0.0.1", 46066))
data, _addr = s.recvfrom(2048)
text = data.decode("ascii", "replace")
print(text)
if "model=SteamDeck" not in text:
    raise SystemExit("missing SteamDeck model")
if "ip=127.0.0.1" not in text:
    raise SystemExit("advertised ip was not rewritten to the LAN bind address")
if "ip=172.21.0.2" in text:
    raise SystemExit("container ip leaked into discovery reply")
s.close()
PY

printf 'discover-proxy: live rewrite test passed\n'
