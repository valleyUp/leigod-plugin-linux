#!/bin/sh
set -eu

# Build the optimization-check images first. Use a separate bridge network,
# fresh tmpfs state and no published ports; never attach to the running plugin.
# The vendor Web module needs Internet access to fetch its global config.
REPO_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
test_network=leigod-test-$$
test_container=$test_network
created_network=0
created_container=0
cleanup() {
    [ "$created_container" -eq 0 ] || docker rm -f "$test_container" >/dev/null 2>&1 || true
    [ "$created_network" -eq 0 ] || docker network rm "$test_network" >/dev/null 2>&1 || true
}
trap cleanup EXIT HUP INT TERM

docker network create "$test_network" >/dev/null
created_network=1
docker run -d --name "$test_container" --init --network "$test_network" \
    --mac-address 02:11:22:33:44:90 --read-only \
    --cap-drop ALL --cap-add NET_ADMIN --cap-add NET_RAW \
    --security-opt no-new-privileges:true --device /dev/net/tun:/dev/net/tun:rwm \
    --memory 512m --pids-limit 128 --cpus 2 \
    --sysctl net.ipv6.conf.all.disable_ipv6=1 --sysctl net.ipv6.conf.default.disable_ipv6=1 \
    --tmpfs /tmp:rw,nosuid,nodev,noexec,size=128m \
    --tmpfs /run:rw,nosuid,nodev,noexec,size=8m \
    --tmpfs /var/lib/leigod:rw,nosuid,nodev,noexec,size=128m \
    --mount "type=bind,src=$REPO_DIR/opt/leigod/fake_product_name,dst=/sys/class/dmi/id/product_name,readonly" \
    -e LEIGOD_DEVICE_MAC=02:11:22:33:44:90 -e LEIGOD_LOG_LEVEL=warn \
    leigod-plugin:optimization-check >/dev/null
created_container=1

healthy=0
attempt=0
while [ "$attempt" -lt 40 ]; do
    if docker exec "$test_container" /usr/local/sbin/leigod-healthcheck >/dev/null 2>&1; then
        healthy=1
        break
    fi
    attempt=$((attempt + 1))
    sleep 1
done
if [ "$healthy" -ne 1 ]; then
    docker logs --tail 30 "$test_container" >&2
    printf 'container-smoke: service did not become healthy\n' >&2
    exit 1
fi
docker exec "$test_container" /usr/local/sbin/leigod-log-forwarder --self-test
status=$(docker exec "$test_container" /usr/local/sbin/leigod-status --json --sample-seconds 0)
printf '%s\n' "$status" | python3 -c 'import json,sys; s=json.load(sys.stdin); assert s["service_healthy"]; assert s["acceleration_state"] == "idle"; print("container-smoke: healthy/idle, DNS UDP+TCP listeners verified")'
log_processes=$(docker exec "$test_container" pgrep -fc '^/usr/bin/python3 /usr/local/libexec/leigod-log-forwarder.py$')
[ "$log_processes" -eq 1 ] || { printf 'container-smoke: expected one log process\n' >&2; exit 1; }
docker run --rm --network none --cap-drop ALL --read-only \
    --security-opt no-new-privileges:true leigod-discover-proxy:optimization-check --self-test
printf 'container-smoke: log process and non-root discovery image passed\n'
