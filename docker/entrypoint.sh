#!/bin/sh
set -eu

readonly BASE=/opt/leigod
readonly BIN="$BASE/acc-gw.router.amd64"
readonly STATE_DIR=/var/lib/leigod/config
readonly TEMPLATE_DIR=/usr/share/leigod/config
readonly LOG_DIR=/tmp/acc/log
readonly LOG_FORWARDER=/usr/local/sbin/leigod-log-forwarder
readonly DNS_STUB=/usr/local/sbin/leigod-dns-stub

log_forwarder_pid=
dns_stub_pid=

log() {
    printf '[leigod] %s\n' "$*"
}

shutdown() {
    trap - INT TERM
    accelerator_pids=$(pgrep -f '^/opt/leigod/acc-gw.router.amd64 .*daemon' || true)
    if [ -n "$accelerator_pids" ]; then
        kill -TERM $accelerator_pids 2>/dev/null || true
    fi
    if [ -n "$log_forwarder_pid" ]; then
        kill -TERM "$log_forwarder_pid" 2>/dev/null || true
        wait "$log_forwarder_pid" 2>/dev/null || true
    fi
    if [ -n "$dns_stub_pid" ]; then
        kill -TERM "$dns_stub_pid" 2>/dev/null || true
        wait "$dns_stub_pid" 2>/dev/null || true
    fi
    exit 0
}

valid_mac() {
    printf '%s\n' "$1" | grep -Eq '^([[:xdigit:]]{2}:){5}[[:xdigit:]]{2}$'
}

prepare_state() {
    mkdir -p "$STATE_DIR"
    for source_file in "$TEMPLATE_DIR"/*; do
        target_file="$STATE_DIR/$(basename "$source_file")"
        if [ ! -e "$target_file" ]; then
            cp "$source_file" "$target_file"
        fi
    done
}

prepare_wlan0() {
    device_mac=${LEIGOD_DEVICE_MAC:-}
    if ! valid_mac "$device_mac"; then
        log 'LEIGOD_DEVICE_MAC is missing or invalid'
        exit 1
    fi
    device_mac=$(printf '%s\n' "$device_mac" | tr '[:upper:]' '[:lower:]')

    default_route=$(ip -4 route show default | sed -n '1p')
    network_iface=$(printf '%s\n' "$default_route" | sed -n 's/.* dev \([^ ]*\).*/\1/p')
    network_gateway=$(printf '%s\n' "$default_route" | sed -n 's/.* via \([^ ]*\).*/\1/p')
    if [ -z "$network_iface" ] || [ "$network_iface" = lo ]; then
        log 'cannot find the Docker interface carrying the IPv4 default route'
        exit 1
    fi
    if [ -z "$network_gateway" ]; then
        log 'cannot find the Docker IPv4 gateway'
        exit 1
    fi

    if [ "$network_iface" != wlan0 ]; then
        if ip link show wlan0 >/dev/null 2>&1; then
            log "wlan0 exists but the default route uses $network_iface"
            exit 1
        fi
        ip link set dev "$network_iface" down
        ip link set dev "$network_iface" name wlan0
        ip link set dev wlan0 up
        ip -4 route replace default via "$network_gateway" dev wlan0
    fi

    actual_mac=$(cat /sys/class/net/wlan0/address 2>/dev/null || true)
    if [ "$actual_mac" != "$device_mac" ]; then
        log "Docker wlan0 MAC mismatch: expected $device_mac, got ${actual_mac:-missing}"
        exit 1
    fi
    log "using Docker network interface as wlan0 ($device_mac)"
}

# The phone already binds this process as Steam Deck, then polls getDeviceList.
# Isolated bridge netns has no LAN DHCP/mDNS neighbors, so the App shows nothing
# to accelerate. Seed OpenWrt-style leases the binary already knows how to read.
prepare_dhcp_leases() {
    wlan_mac=$(cat /sys/class/net/wlan0/address 2>/dev/null || true)
    wlan_ip=$(ip -4 addr show dev wlan0 | awk '/inet / {print $2; exit}' | cut -d/ -f1)
    if ! valid_mac "$wlan_mac" || [ -z "$wlan_ip" ]; then
        log 'cannot seed DHCP leases; wlan0 address is missing'
        return 0
    fi
    expiry=$(( $(date +%s) + 2592000 ))
    duid=01:$(printf '%s' "$wlan_mac" | tr '[:upper:]' '[:lower:]')
    printf '%s %s %s steamdeck %s\n' "$expiry" "$wlan_mac" "$wlan_ip" "$duid" > /tmp/dhcp.leases
    printf '%s %s %s windows-pc %s\n' "$expiry" "$wlan_mac" "$wlan_ip" "$duid" >> /tmp/dhcp.leases
    mkdir -p /var/lib/leigod/misc /var/lib/misc 2>/dev/null || true
    if [ -d /var/lib/misc ] && [ -w /var/lib/misc ]; then
        cp /tmp/dhcp.leases /var/lib/misc/dnsmasq.leases
    fi
    log "seeded local discovery leases for $wlan_ip ($wlan_mac)"
}

start_accelerator() {
    set -- -r daemon -m tun -p 5588
    if [ "${LEIGOD_DEBUG:-0}" = 1 ]; then
        set -- -d debug "$@"
    fi

    : > "$LOG_DIR/console.log"
    "$BIN" "$@" >> "$LOG_DIR/console.log" 2>&1 &
    acc_pid=$!
    log "accelerator started (pid $acc_pid)"
}

start_log_forwarder() {
    log_level=${LEIGOD_LOG_LEVEL:-warn}
    case "$log_level" in
        off|error|warn|info|debug) ;;
        *)
            log "invalid LEIGOD_LOG_LEVEL: $log_level"
            exit 1
            ;;
    esac

    mkdir -p "$LOG_DIR"
    if [ "$log_level" = off ]; then
        log 'accelerator file-log forwarding is disabled'
        return
    fi

    "$LOG_FORWARDER" &
    log_forwarder_pid=$!
    log "forwarding accelerator file logs at level $log_level"
}

log_forwarder_running() {
    [ "$log_level" = off ] ||
        { [ -n "$log_forwarder_pid" ] && kill -0 "$log_forwarder_pid" 2>/dev/null; }
}

prepare_dns_stub() {
    if ! ip -4 addr show dev lo | grep -q ' inet 127.0.0.53/'; then
        ip -4 addr add 127.0.0.53/32 dev lo
    fi
}

start_dns_stub() {
    if [ ! -x "$DNS_STUB" ]; then
        log 'DNS stub helper is missing'
        exit 1
    fi
    "$DNS_STUB" --bind 127.0.0.53 --upstream 223.6.6.6 --upstream 114.114.114.114 &
    dns_stub_pid=$!
    log "DNS stub listening on 127.0.0.53:53 (pid $dns_stub_pid)"
}

dns_stub_running() {
    [ -n "$dns_stub_pid" ] && kill -0 "$dns_stub_pid" 2>/dev/null
}

accelerator_running() {
    pgrep -f '^/opt/leigod/acc-gw.router.amd64 .*daemon' >/dev/null 2>&1
}

trap shutdown INT TERM

if [ ! -c /dev/net/tun ]; then
    log '/dev/net/tun is not available'
    exit 1
fi
if [ "$(cat /sys/class/dmi/id/product_name 2>/dev/null || true)" != Jupiter ]; then
    log 'Steam Deck DMI view is not mounted'
    exit 1
fi
if [ ! -x "$BIN" ]; then
    log 'accelerator binary is missing or not executable'
    exit 1
fi

prepare_state
prepare_wlan0
prepare_dhcp_leases
prepare_dns_stub
start_dns_stub
start_log_forwarder

while :; do
    if ! dns_stub_running; then
        log 'DNS stub stopped; restarting it'
        wait "$dns_stub_pid" 2>/dev/null || true
        start_dns_stub
    fi
    if ! log_forwarder_running; then
        log 'accelerator log forwarder stopped; restarting it'
        wait "$log_forwarder_pid" 2>/dev/null || true
        start_log_forwarder
    fi
    if ! accelerator_running; then
        log 'accelerator is not running; starting it'
        start_accelerator
    fi
    sleep 5 &
    wait $!
done
