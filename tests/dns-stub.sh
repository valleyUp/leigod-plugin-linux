#!/bin/sh
set -eu

REPO_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
WORK_DIR=$(mktemp -d "$REPO_DIR/.leigod-test.XXXXXX")
stub_pid=
upstream_pid=

cleanup() {
    if [ -n "$stub_pid" ]; then
        kill "$stub_pid" 2>/dev/null || true
        wait "$stub_pid" 2>/dev/null || true
    fi
    if [ -n "$upstream_pid" ]; then
        kill "$upstream_pid" 2>/dev/null || true
        wait "$upstream_pid" 2>/dev/null || true
    fi
    rm -rf -- "$WORK_DIR"
}
trap cleanup EXIT HUP INT TERM

fail() {
    printf 'dns-stub: %s\n' "$*" >&2
    exit 1
}

cc -std=c11 -O2 -Wall -Wextra -Werror -pthread -D_FORTIFY_SOURCE=2 \
    -fstack-protector-strong -Wl,-z,relro,-z,now \
    -o "$WORK_DIR/leigod-dns-stub" "$REPO_DIR/src/leigod-dns-stub.c"

"$WORK_DIR/leigod-dns-stub" --self-test || fail 'C self-test failed'

python3 - <<'PY' &
import socket

reply = (
    b"\x12\x34\x81\x80\x00\x01\x00\x01\x00\x00\x00\x00"
    b"\x07example\x03com\x00\x00\x01\x00\x01"
    b"\xc0\x0c\x00\x01\x00\x01\x00\x00\x00\x3c\x00\x04"
    b"\x01\x02\x03\x04"
)
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", 5453))
s.settimeout(8)
try:
    data, addr = s.recvfrom(4096)
    if len(data) >= 12:
        s.sendto(reply, addr)
except socket.timeout:
    pass
s.close()
PY
upstream_pid=$!
sleep 0.2

"$WORK_DIR/leigod-dns-stub" --bind 127.0.0.1 --port 53553 --upstream 127.0.0.1:5453 \
    >/dev/null 2>"$WORK_DIR/stub.err" &
stub_pid=$!
sleep 0.2
kill -0 "$stub_pid" 2>/dev/null || fail "stub failed to start: $(cat "$WORK_DIR/stub.err")"

python3 - <<'PY' || fail 'forwarded DNS reply was not received'
import socket

query = (
    b"\x12\x34\x01\x00\x00\x01\x00\x00\x00\x00\x00\x00"
    b"\x07example\x03com\x00\x00\x01\x00\x01"
)
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.settimeout(2)
s.sendto(query, ("127.0.0.1", 53553))
data, _addr = s.recvfrom(4096)
if data[0:2] != b"\x12\x34":
    raise SystemExit("transaction id was not preserved")
if data[-4:] != b"\x01\x02\x03\x04":
    raise SystemExit("upstream A record was not forwarded")
s.close()
PY

printf 'dns-stub: live forward test passed\n'
