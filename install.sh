#!/bin/sh
set -eu

PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH

VERSION=1.2.2.15
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
RUNTIME_DIR=$SCRIPT_DIR/.leigod
CONFIG_FILE=$RUNTIME_DIR/docker.env
INSTALL_MANIFEST=$RUNTIME_DIR/install-manifest
GROUP_NAME=leigod-game
CONTAINER_NAME=leigod-plugin
DIRECT_POLICY_HELPER=/usr/local/libexec/leigod-direct-policy.py
DIRECT_POLICY_UNIT=/etc/systemd/system/leigod-direct-policy.service
direct_policy_present=0
BASE_URL=http://119.3.40.126

allow_unverified=0
show_config=0
previous_network_mode=

info() {
    printf '[INFO] %s\n' "$*"
}

warn() {
    printf '[WARN] %s\n' "$*" >&2
}

fail() {
    printf '[ERROR] %s\n' "$*" >&2
    exit 1
}

MANIFEST_HELPERS=$SCRIPT_DIR/libexec/install-manifest.sh
[ -r "$MANIFEST_HELPERS" ] || fail 'install manifest helpers are missing'
. "$MANIFEST_HELPERS"


usage() {
    cat <<'EOF'
Usage:
  sudo ./install.sh --ip ADDRESS [macvlan options]
  sudo ./install.sh --network bridge [--bind-address ADDRESS]

Options:
  --network macvlan|bridge   Network driver (default: macvlan)
  --parent INTERFACE         macvlan parent; auto-detected when possible
  --subnet CIDR              LAN subnet; auto-detected when possible
  --gateway ADDRESS          LAN gateway; auto-detected when possible
  --ip ADDRESS               Reserved LAN address for the container (macvlan)
  --bind-address ADDRESS     Bridge Web/API bind (default: 127.0.0.1; use 0.0.0.0 for phone discovery)
  --log-level LEVEL          Docker log detail: off|error|warn|info|debug (default: warn)
  --user USER                Desktop user allowed to run accelerated games
  --binary-sha256 HASH       Expected accelerator binary SHA-256
  --xdb-sha256 HASH          Expected IP database SHA-256
  --allow-unverified-download
                             Explicitly accept legacy HTTP downloads without hashes
  --show-config              Print resolved settings without deploying or auto-detecting LAN settings
  -h, --help                 Show this help

Reinstalls retain saved settings. Precedence: CLI > environment > saved > defaults.
Exit Steam, Ubisoft and games before an update that replaces their namespace.

Place both vendor assets under opt/leigod/ to avoid downloading them. A supplied
hash is always verified, whether an asset is local or downloaded.
EOF
}

case "${1:-}" in -h|--help) usage; exit 0 ;; esac
[ -r "$SCRIPT_DIR/libexec/install-config.sh" ] || fail 'install configuration helpers are missing'
. "$SCRIPT_DIR/libexec/install-config.sh"
if [ -e "$CONFIG_FILE" ] || [ -L "$CONFIG_FILE" ]; then
    leigod_config_validate "$CONFIG_FILE" || fail 'saved docker.env is not a regular, valid installer configuration'
    previous_network_mode=$(leigod_config_get LEIGOD_NETWORK_MODE '')
fi
network_mode=${LEIGOD_NETWORK_MODE-$(leigod_config_get LEIGOD_NETWORK_MODE macvlan)}
parent=${LEIGOD_PARENT-$(leigod_config_get LEIGOD_PARENT '')}
subnet=${LEIGOD_SUBNET-$(leigod_config_get LEIGOD_SUBNET '')}
gateway=${LEIGOD_GATEWAY-$(leigod_config_get LEIGOD_GATEWAY '')}
container_ip=${LEIGOD_IPV4-$(leigod_config_get LEIGOD_IPV4 '')}
bind_address=${LEIGOD_BIND_ADDRESS-$(leigod_config_get LEIGOD_BIND_ADDRESS 127.0.0.1)}
bridge_ipv4=${LEIGOD_BRIDGE_IPV4-$(leigod_config_get LEIGOD_BRIDGE_IPV4 172.21.0.2)}
bridge_subnet=${LEIGOD_BRIDGE_SUBNET-$(leigod_config_get LEIGOD_BRIDGE_SUBNET 172.21.0.0/16)}
bridge_gateway=${LEIGOD_BRIDGE_GATEWAY-$(leigod_config_get LEIGOD_BRIDGE_GATEWAY 172.21.0.1)}
device_mac=${LEIGOD_DEVICE_MAC-$(leigod_config_get LEIGOD_DEVICE_MAC '')}
debug=${LEIGOD_DEBUG-$(leigod_config_get LEIGOD_DEBUG 0)}
log_level=${LEIGOD_LOG_LEVEL-$(leigod_config_get LEIGOD_LOG_LEVEL warn)}
binary_sha256=${LEIGOD_BINARY_SHA256-$(leigod_config_get LEIGOD_BINARY_SHA256 '')}
xdb_sha256=${LEIGOD_XDB_SHA256-$(leigod_config_get LEIGOD_XDB_SHA256 '')}
target_user=${LEIGOD_USER-$(leigod_config_get LEIGOD_USER "${SUDO_USER:-}")}
# Compose gives exported variables precedence over --env-file. Resolved values
# below (including CLI overrides) must be the sole interpolation source.
unset LEIGOD_VERSION LEIGOD_NETWORK_MODE LEIGOD_PARENT LEIGOD_SUBNET LEIGOD_GATEWAY \
    LEIGOD_IPV4 LEIGOD_BIND_ADDRESS LEIGOD_BRIDGE_IPV4 LEIGOD_BRIDGE_SUBNET \
    LEIGOD_BRIDGE_GATEWAY LEIGOD_DEVICE_MAC LEIGOD_DEBUG LEIGOD_LOG_LEVEL LEIGOD_USER

while [ "$#" -gt 0 ]; do
    case "$1" in
        --network) [ "$#" -ge 2 ] || fail '--network needs a value'; network_mode=$2; shift 2 ;;
        --parent) [ "$#" -ge 2 ] || fail '--parent needs a value'; parent=$2; shift 2 ;;
        --subnet) [ "$#" -ge 2 ] || fail '--subnet needs a value'; subnet=$2; shift 2 ;;
        --gateway) [ "$#" -ge 2 ] || fail '--gateway needs a value'; gateway=$2; shift 2 ;;
        --ip) [ "$#" -ge 2 ] || fail '--ip needs a value'; container_ip=$2; shift 2 ;;
        --bind-address) [ "$#" -ge 2 ] || fail '--bind-address needs a value'; bind_address=$2; shift 2 ;;
        --log-level) [ "$#" -ge 2 ] || fail '--log-level needs a value'; log_level=$2; shift 2 ;;
        --user) [ "$#" -ge 2 ] || fail '--user needs a value'; target_user=$2; shift 2 ;;
        --binary-sha256) [ "$#" -ge 2 ] || fail '--binary-sha256 needs a value'; binary_sha256=$2; shift 2 ;;
        --xdb-sha256) [ "$#" -ge 2 ] || fail '--xdb-sha256 needs a value'; xdb_sha256=$2; shift 2 ;;
        --allow-unverified-download) allow_unverified=1; shift ;;
        --show-config) show_config=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) fail "unknown option: $1" ;;
    esac
done

if [ "$show_config" -eq 1 ]; then
    printf '%s\n' \
        "LEIGOD_NETWORK_MODE=$network_mode" "LEIGOD_PARENT=$parent" \
        "LEIGOD_SUBNET=$subnet" "LEIGOD_GATEWAY=$gateway" "LEIGOD_IPV4=$container_ip" \
        "LEIGOD_BIND_ADDRESS=$bind_address" "LEIGOD_BRIDGE_IPV4=$bridge_ipv4" \
        "LEIGOD_BRIDGE_SUBNET=$bridge_subnet" "LEIGOD_BRIDGE_GATEWAY=$bridge_gateway" \
        "LEIGOD_DEVICE_MAC=$device_mac" "LEIGOD_DEBUG=$debug" \
        "LEIGOD_LOG_LEVEL=$log_level" "LEIGOD_USER=$target_user" \
        "LEIGOD_BINARY_SHA256=$binary_sha256" "LEIGOD_XDB_SHA256=$xdb_sha256"
    exit 0
fi

[ "$(id -u)" -eq 0 ] || fail 'run as root (sudo ./install.sh ...)'
[ "$(uname -m)" = x86_64 ] || fail 'only x86_64 is supported'
[ -c /dev/net/tun ] || fail '/dev/net/tun is unavailable; load the tun kernel module first'

for command_name in awk cat cc curl cut getent grep groupadd head hostname id install ip mktemp readlink sed sha256sum sudo tr usermod visudo; do
    command -v "$command_name" >/dev/null 2>&1 || fail "required command is missing: $command_name"
done

if [ -x /usr/bin/docker ]; then
    DOCKER=/usr/bin/docker
elif [ -x /usr/local/bin/docker ]; then
    DOCKER=/usr/local/bin/docker
else
    fail 'Docker Engine is required; install it from your distribution or Docker first'
fi
"$DOCKER" info >/dev/null 2>&1 || fail 'Docker daemon is unavailable'
"$DOCKER" compose version >/dev/null 2>&1 || fail 'Docker Compose v2 plugin is required'

existing_project=$(
    "$DOCKER" inspect --format '{{index .Config.Labels "com.docker.compose.project"}}' \
        "$CONTAINER_NAME" 2>/dev/null || true
)
if [ -n "$existing_project" ] && [ "$existing_project" != leigod-plugin ]; then
    fail "container name $CONTAINER_NAME is already used outside this project"
fi

existing_proxy_project=$(
    "$DOCKER" inspect --format '{{index .Config.Labels "com.docker.compose.project"}}' \
        leigod-discover-proxy 2>/dev/null || true
)
if [ -n "$existing_proxy_project" ] && [ "$existing_proxy_project" != leigod-plugin ]; then
    fail 'container name leigod-discover-proxy is already used outside this project'
fi

case "$network_mode" in
    macvlan|bridge) ;;
    *) fail '--network must be macvlan or bridge' ;;
esac

# Verify ownership before replacing or stopping an installed routing guard.
for managed_policy_target in "$DIRECT_POLICY_HELPER" "$DIRECT_POLICY_UNIT"; do
    if [ -e "$managed_policy_target" ] || [ -L "$managed_policy_target" ]; then
        leigod_manifest_file_matches "$INSTALL_MANIFEST" "$managed_policy_target" ||
            fail "routing policy file is modified or not owned by this installation: $managed_policy_target"
        direct_policy_present=1
    fi
done
if [ "$direct_policy_present" -eq 1 ]; then
    [ -f "$DIRECT_POLICY_HELPER" ] && [ -f "$DIRECT_POLICY_UNIT" ] ||
        fail 'installed routing policy is incomplete; review it before reinstalling'
fi
if [ "$network_mode" = bridge ] || [ "$direct_policy_present" -eq 1 ]; then
    command -v python3 >/dev/null 2>&1 || fail 'Python 3 is required for bridge routing protection'
    command -v systemctl >/dev/null 2>&1 || fail 'systemd is required for bridge routing protection'
fi
if [ "$network_mode" = bridge ]; then
    [ -r "$SCRIPT_DIR/libexec/leigod-direct-policy.py" ] &&
        [ -r "$SCRIPT_DIR/systemd/leigod-direct-policy.service" ] ||
        fail 'direct routing policy sources are missing'
fi

case "$log_level" in
    off|error|warn|info|debug) ;;
    *) fail '--log-level must be off, error, warn, info or debug' ;;
esac
case "$debug" in 0|1) ;; *) fail 'LEIGOD_DEBUG must be 0 or 1' ;; esac

valid_ipv4() {
    printf '%s\n' "$1" | awk -F. '
        NF != 4 { exit 1 }
        {
            for (i = 1; i <= 4; i++) {
                if ($i !~ /^[0-9]+$/ || $i > 255) exit 1
            }
            exit 0
        }
    '
}

valid_hash() {
    printf '%s\n' "$1" | grep -Eq '^[[:xdigit:]]{64}$'
}

if [ "$network_mode" = macvlan ]; then
    if [ -z "$parent" ]; then
        parent=$(ip -4 route show default | awk '/default/ {for (i=1; i<=NF; i++) if ($i == "dev") {print $(i+1); exit}}')
    fi
    [ -n "$parent" ] || fail 'cannot detect the macvlan parent; pass --parent'
    printf '%s\n' "$parent" | grep -Eq '^[[:alnum:]_.:-]+$' || fail 'invalid parent interface'
    ip link show dev "$parent" >/dev/null 2>&1 || fail "parent interface does not exist: $parent"

    if [ -z "$gateway" ]; then
        gateway=$(ip -4 route show default dev "$parent" | awk '/default/ {print $3; exit}')
    fi
    if [ -z "$subnet" ]; then
        subnet=$(ip -4 route show dev "$parent" proto kernel scope link | awk '$1 ~ /\// {print $1; exit}')
    fi

    valid_ipv4 "$gateway" || fail 'cannot detect a valid gateway; pass --gateway'
    subnet_address=${subnet%/*}
    subnet_prefix=${subnet#*/}
    valid_ipv4 "$subnet_address" || fail 'cannot detect a valid subnet; pass --subnet CIDR'
    case "$subnet_prefix" in
        ''|*[!0-9]*) fail 'cannot detect a valid subnet prefix; pass --subnet CIDR' ;;
    esac
    [ "$subnet_prefix" -le 32 ] || fail 'subnet prefix must be between 0 and 32'
    valid_ipv4 "$container_ip" ||
        fail 'macvlan requires --ip with an unused address reserved outside the DHCP pool'

    case "$parent" in
        wl*|wlan*) warn 'many Wi-Fi drivers reject macvlan; use --network bridge if startup fails' ;;
    esac
else
    valid_ipv4 "$bind_address" || fail 'bridge bind address must be IPv4'
    valid_ipv4 "$bridge_ipv4" || fail 'bridge container address is invalid'
    valid_ipv4 "$bridge_gateway" || fail 'bridge gateway is invalid'
    bridge_subnet=$(python3 - "$bridge_subnet" "$bridge_ipv4" "$bridge_gateway" <<'PY_SUBNET'
import ipaddress
import sys
network = ipaddress.ip_network(sys.argv[1], strict=True)
if network.version != 4 or not network.is_private or network.prefixlen < 8:
    raise SystemExit('a dedicated private IPv4 bridge subnet with prefix length >= 8 is required')
for address in sys.argv[2:]:
    ip = ipaddress.ip_address(address)
    if ip not in network or ip in (network.network_address, network.broadcast_address):
        raise SystemExit('bridge IP and gateway must be usable addresses in the bridge subnet')
if sys.argv[2] == sys.argv[3]:
    raise SystemExit('bridge IP and gateway must differ')
print(network)
PY_SUBNET
    ) || fail 'invalid bridge subnet/IP/gateway configuration'
fi


# Check policy ownership/priorities before building or replacing containers.
previous_policy_subnet=
if [ "$direct_policy_present" -eq 1 ]; then
    previous_policy_subnet=$(awk '$1 == "ExecStop=/usr/local/libexec/leigod-direct-policy.py" && $2 == "--subnet" {print $3; exit}' "$DIRECT_POLICY_UNIT")
    [ -n "$previous_policy_subnet" ] || fail 'cannot read the verified direct policy subnet'
    "$DIRECT_POLICY_HELPER" --subnet "$previous_policy_subnet" --check ||
        fail 'installed direct routing policy has conflicting rules'
elif [ "$network_mode" = bridge ]; then
    python3 "$SCRIPT_DIR/libexec/leigod-direct-policy.py" --subnet "$bridge_subnet" --check ||
        fail 'routing policy priorities 100-103 are already occupied'
fi

if [ -n "$target_user" ]; then
    printf '%s\n' "$target_user" | grep -Eq '^[a-z_][a-z0-9_-]*[$]?$' ||
        fail 'desktop user name is invalid'
fi
[ -n "$target_user" ] && [ "$target_user" != root ] ||
    fail 'a non-root desktop user is required; pass --user USER'
id -- "$target_user" >/dev/null 2>&1 || fail "desktop user does not exist: $target_user"

if [ -n "$device_mac" ]; then
    printf '%s\n' "$device_mac" | grep -Eq '^([[:xdigit:]]{2}:){5}[[:xdigit:]]{2}$' ||
        fail 'LEIGOD_DEVICE_MAC is invalid'
else
    if [ -r /etc/machine-id ]; then
        machine_seed=$(sed -n '1p' /etc/machine-id)
    else
        machine_seed=$(hostname)
    fi
    device_suffix=$(printf '%s' "$machine_seed:leigod-plugin" | sha256sum | cut -c1-10 |
        sed 's/../&:/g;s/:$//')
    device_mac="02:$device_suffix"
fi

prepare_asset() {
    asset_name=$1
    asset_url=$2
    expected_hash=$3
    asset_mode=$4
    source_path=$SCRIPT_DIR/opt/leigod/$asset_name

    if [ -n "$expected_hash" ] && ! valid_hash "$expected_hash"; then
        fail "invalid SHA-256 for $asset_name"
    fi
    expected_hash=$(printf '%s' "$expected_hash" | tr '[:upper:]' '[:lower:]')

    if [ -f "$source_path" ]; then
        candidate=$source_path
        downloaded=0
    else
        if [ -z "$expected_hash" ] && [ "$allow_unverified" -ne 1 ]; then
            fail "$asset_name is missing; provide its SHA-256 or explicitly use --allow-unverified-download"
        fi
        candidate=$work_dir/$(basename "$asset_name")
        downloaded=1
        info "downloading $asset_name"
        curl --fail --location --show-error --proto '=http,https' \
            --proto-redir '=http,https' --connect-timeout 15 --retry 3 \
            --output "$candidate" "$asset_url" ||
            fail "download failed: $asset_name"
    fi

    [ -s "$candidate" ] || fail "asset is empty: $asset_name"

    actual_hash=$(sha256sum "$candidate" | awk '{print $1}')
    if [ -n "$expected_hash" ] && [ "$actual_hash" != "$expected_hash" ]; then
        fail "SHA-256 mismatch for $asset_name"
    fi
    if [ -z "$expected_hash" ]; then
        warn "$asset_name was not independently verified (SHA-256: $actual_hash)"
    else
        info "verified $asset_name ($actual_hash)"
    fi
    if [ "$downloaded" -eq 1 ]; then
        install -m "$asset_mode" "$candidate" "$source_path"
    fi
}

work_dir=$(mktemp -d "$SCRIPT_DIR/.leigod-build.XXXXXX")
config_pending=
cleanup() {
    [ -z "$config_pending" ] || rm -f -- "$config_pending"
    rm -rf -- "$work_dir"
}
trap cleanup EXIT HUP INT TERM

info 'using the current repository as the isolated Docker build context'
install -d -m 0755 "$RUNTIME_DIR"

prepare_asset acc-gw.router.amd64 "$BASE_URL/acc-gw.router.amd64" "$binary_sha256" 0755
prepare_asset config/ipdatacloud_country.xdb "$BASE_URL/ipdatacloud_country.xdb" "$xdb_sha256" 0644

wrapper_sha256=$(sha256sum "$SCRIPT_DIR/bin/leigod-game-run" | awk '{print $1}')
if [ -e /usr/bin/leigod-game-run ]; then
    existing_wrapper_sha256=$(sha256sum /usr/bin/leigod-game-run 2>/dev/null | awk '{print $1}' || true)
    if [ "$existing_wrapper_sha256" != "$wrapper_sha256" ] &&
       [ ! -e /etc/sudoers.d/leigod-game ]; then
        fail '/usr/bin/leigod-game-run already exists and is not owned by this installation'
    fi
fi
staged_config=$work_dir/docker.env
cat > "$staged_config" <<EOF
LEIGOD_VERSION=$VERSION
LEIGOD_NETWORK_MODE=$network_mode
LEIGOD_PARENT=$parent
LEIGOD_SUBNET=$subnet
LEIGOD_GATEWAY=$gateway
LEIGOD_IPV4=$container_ip
LEIGOD_BIND_ADDRESS=$bind_address
LEIGOD_BRIDGE_IPV4=$bridge_ipv4
LEIGOD_BRIDGE_SUBNET=$bridge_subnet
LEIGOD_BRIDGE_GATEWAY=$bridge_gateway
LEIGOD_DEVICE_MAC=$device_mac
LEIGOD_DEBUG=$debug
LEIGOD_LOG_LEVEL=$log_level
LEIGOD_USER=$target_user
LEIGOD_WRAPPER_SHA256=$wrapper_sha256
LEIGOD_BINARY_SHA256=$binary_sha256
LEIGOD_XDB_SHA256=$xdb_sha256
EOF
chmod 0600 "$staged_config"
leigod_config_validate "$staged_config" || fail 'resolved configuration contains unsupported characters'

info 'building the game namespace helper'
cc -std=c11 -O2 -Wall -Wextra -Werror -D_FORTIFY_SOURCE=2 \
    -fstack-protector-strong -Wl,-z,relro,-z,now \
    -o "$work_dir/leigod-netns-exec" "$SCRIPT_DIR/src/leigod-netns-exec.c"

info "building leigod-plugin:$VERSION"
"$DOCKER" build --pull --build-arg "LEIGOD_VERSION=$VERSION" \
    -f "$SCRIPT_DIR/docker/Dockerfile" -t "leigod-plugin:$VERSION" "$SCRIPT_DIR"

if [ "$network_mode" = bridge ]; then
    info "building leigod-discover-proxy:$VERSION"
    "$DOCKER" build --pull \
        -f "$SCRIPT_DIR/docker/Dockerfile.discover-proxy" \
        -t "leigod-discover-proxy:$VERSION" "$SCRIPT_DIR"
fi

if [ "$network_mode" = macvlan ]; then
    compose_override=$SCRIPT_DIR/docker/compose.macvlan.yml
else
    compose_override=$SCRIPT_DIR/docker/compose.bridge.yml
fi

if [ "$network_mode" = bridge ]; then
    network_name=leigod-plugin-bridge
    network_state=$(leigod_network_state "$network_name" bridge "$bridge_subnet" "$bridge_gateway" \
        com.docker.network.bridge.name leigodbr0) || fail 'cannot reuse the requested bridge network'
else
    network_name=leigod-plugin-macvlan
    network_state=$(leigod_network_state "$network_name" macvlan "$subnet" "$gateway" \
        parent "$parent") || fail 'cannot reuse the requested macvlan network'
fi
"$DOCKER" compose --env-file "$staged_config" --project-directory "$SCRIPT_DIR" \
    -f "$SCRIPT_DIR/docker/compose.yml" -f "$compose_override" config -q
new_config_hash=$("$DOCKER" compose --env-file "$staged_config" --project-directory "$SCRIPT_DIR" \
    -f "$SCRIPT_DIR/docker/compose.yml" -f "$compose_override" config --hash accelerator | awk '{print $NF}')
[ -n "$new_config_hash" ] || fail 'Compose cannot calculate the accelerator configuration hash'
old_config_hash=$("$DOCKER" inspect --format '{{index .Config.Labels "com.docker.compose.config-hash"}}' "$CONTAINER_NAME" 2>/dev/null || true)
old_image=$("$DOCKER" inspect --format '{{.Image}}' "$CONTAINER_NAME" 2>/dev/null || true)
new_image=$("$DOCKER" image inspect --format '{{.Id}}' "leigod-plugin:$VERSION")
namespace_replace=0
if [ "$network_state" = recreate ] || [ "$old_config_hash" != "$new_config_hash" ] || \
   [ "$old_image" != "$new_image" ] || [ "$previous_network_mode" != "$network_mode" ]; then
    namespace_replace=1
fi
if [ "$namespace_replace" -eq 1 ]; then
    old_pid=$("$DOCKER" inspect --format '{{.State.Pid}}' "$CONTAINER_NAME" 2>/dev/null || true)
    case "$old_pid" in ''|0) ;; *)
        live_clients=$(leigod_namespace_clients "$old_pid")
        if [ -n "$live_clients" ]; then
            printf '%s\n' "$live_clients" >&2
            fail 'exit these Steam/Ubisoft/game processes, then rerun; their network namespace would be replaced'
        fi
    esac
fi
if [ "$network_state" = recreate ] || \
   { [ -n "$previous_network_mode" ] && [ "$previous_network_mode" != "$network_mode" ]; }; then
    case "$previous_network_mode" in
        macvlan|bridge) previous_override=$SCRIPT_DIR/docker/compose.$previous_network_mode.yml ;;
        '') previous_override=$compose_override ;;
        *) fail 'saved network mode is invalid' ;;
    esac
    old_compose_config=$staged_config
    [ ! -r "$CONFIG_FILE" ] || old_compose_config=$CONFIG_FILE
    info 'network driver/IPAM changed; rebuilding the project network'
    "$DOCKER" compose --env-file "$old_compose_config" --project-directory "$SCRIPT_DIR" \
        -f "$SCRIPT_DIR/docker/compose.yml" -f "$previous_override" down --remove-orphans
    if [ "$network_state" = recreate ] && "$DOCKER" network inspect "$network_name" >/dev/null 2>&1; then
        "$DOCKER" network rm "$network_name"
    fi
else
    info "network $network_name: $network_state; retaining existing network when present"
fi
info "starting accelerator with $network_mode networking"
"$DOCKER" compose --env-file "$staged_config" --project-directory "$SCRIPT_DIR" \
    -f "$SCRIPT_DIR/docker/compose.yml" -f "$compose_override" up -d --remove-orphans

health=starting
attempt=0
while [ "$attempt" -lt 20 ]; do
    health=$("$DOCKER" inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' \
        "$CONTAINER_NAME" 2>/dev/null || true)
    [ "$health" = healthy ] && break
    [ "$health" = unhealthy ] && break
    attempt=$((attempt + 1))
    sleep 2
done
[ "$health" = healthy ] || fail "container health is $health; inspect: docker logs $CONTAINER_NAME"

if [ "$network_mode" = bridge ]; then
    assigned_ip=$("$DOCKER" inspect --format \
        '{{(index .NetworkSettings.Networks "leigod-plugin-bridge").IPAddress}}' \
        "$CONTAINER_NAME")
    [ "$assigned_ip" = "$bridge_ipv4" ] ||
        fail "bridge container IP is $assigned_ip, expected $bridge_ipv4"

    proxy_running=false
    attempt=0
    while [ "$attempt" -lt 10 ]; do
        proxy_running=$("$DOCKER" inspect --format '{{.State.Running}}' \
            leigod-discover-proxy 2>/dev/null || true)
        [ "$proxy_running" = true ] && break
        attempt=$((attempt + 1))
        sleep 1
    done
    [ "$proxy_running" = true ] ||
        fail 'discovery proxy container is not running; inspect: docker logs leigod-discover-proxy'

    proxy_net=$("$DOCKER" inspect --format '{{.HostConfig.NetworkMode}}' leigod-discover-proxy)
    proxy_priv=$("$DOCKER" inspect --format '{{.HostConfig.Privileged}}' leigod-discover-proxy)
    proxy_caps=$("$DOCKER" inspect --format '{{json .HostConfig.CapAdd}}' leigod-discover-proxy)
    proxy_drop=$("$DOCKER" inspect --format '{{json .HostConfig.CapDrop}}' leigod-discover-proxy)
    proxy_user=$("$DOCKER" inspect --format '{{.Config.User}}' leigod-discover-proxy)
    [ "$proxy_net" = host ] ||
        fail "discovery proxy network is $proxy_net, expected host"
    [ "$proxy_priv" = false ] || fail 'discovery proxy container must not be privileged'
    case "$proxy_caps" in
        null|'[]') ;;
        *) fail "discovery proxy has unexpected capabilities: $proxy_caps" ;;
    esac
    [ "$proxy_drop" = '["ALL"]' ] ||
        fail "discovery proxy did not drop all capabilities: $proxy_drop"
    case "$proxy_user" in
        65534|65534:65534) ;;
        *) fail "discovery proxy user is $proxy_user, expected 65534:65534" ;;
    esac
    info "LAN discovery proxy listens on $bind_address:6066 and advertises that LAN address"
fi

# A changed subnet must remove the old unit's exact rules before replacement.
if [ "$direct_policy_present" -eq 1 ] &&
   { [ "$network_mode" != bridge ] || [ "$previous_policy_subnet" != "$bridge_subnet" ]; }; then
    info 'stopping the previously verified direct routing policy'
    systemctl disable --now leigod-direct-policy.service ||
        fail 'cannot stop the previous direct routing policy'
    "$DIRECT_POLICY_HELPER" --subnet "$previous_policy_subnet" --remove ||
        fail 'cannot remove the previous direct policy rules'
fi
if [ "$network_mode" = bridge ]; then
    python3 "$SCRIPT_DIR/libexec/leigod-direct-policy.py" --subnet "$bridge_subnet" --check ||
        fail 'routing policy priorities 100-103 are already occupied'
    info 'installing the dedicated bridge direct routing policy'
    install -d -m 0755 /usr/local/libexec /etc/systemd/system
    install -m 0755 "$SCRIPT_DIR/libexec/leigod-direct-policy.py" "$DIRECT_POLICY_HELPER"
    sed "s|@LEIGOD_BRIDGE_SUBNET@|$bridge_subnet|g" \
        "$SCRIPT_DIR/systemd/leigod-direct-policy.service" > "$work_dir/leigod-direct-policy.service"
    install -m 0644 "$work_dir/leigod-direct-policy.service" "$DIRECT_POLICY_UNIT"
elif [ "$direct_policy_present" -eq 1 ]; then
    rm -f -- "$DIRECT_POLICY_HELPER" "$DIRECT_POLICY_UNIT"
    systemctl daemon-reload
fi

info 'installing the restricted per-game launcher'
install -d -m 0755 /usr/local/libexec
install -m 0700 "$work_dir/leigod-netns-exec" /usr/local/libexec/leigod-netns-exec
install -m 0755 "$SCRIPT_DIR/libexec/leigod-game-enter" /usr/local/libexec/leigod-game-enter
install -m 0755 "$SCRIPT_DIR/bin/leigod-game-run" /usr/bin/leigod-game-run

if ! getent group "$GROUP_NAME" >/dev/null 2>&1; then
    groupadd --system "$GROUP_NAME"
fi
usermod -a -G "$GROUP_NAME" -- "$target_user"
info "authorized desktop user: $target_user"
visudo -cf "$SCRIPT_DIR/sudoers/leigod-game" >/dev/null || fail 'sudoers rule is invalid'
install -m 0440 "$SCRIPT_DIR/sudoers/leigod-game" /etc/sudoers.d/leigod-game

manifest_tmp=$work_dir/install-manifest
printf '%s\n' '# leigod-plugin install manifest v1' > "$manifest_tmp"
for managed_target in \
    /usr/bin/leigod-game-run \
    /usr/local/libexec/leigod-game-enter \
    /usr/local/libexec/leigod-netns-exec \
    /etc/sudoers.d/leigod-game; do
    leigod_manifest_record_file "$manifest_tmp" "$managed_target" ||
        fail "cannot record installed file in manifest: $managed_target"
done
if [ "$network_mode" = bridge ]; then
    for managed_target in "$DIRECT_POLICY_HELPER" "$DIRECT_POLICY_UNIT"; do
        leigod_manifest_record_file "$manifest_tmp" "$managed_target" ||
            fail "cannot record routing policy file in manifest: $managed_target"
    done
fi
install -m 0600 "$manifest_tmp" "$INSTALL_MANIFEST"
if [ "$network_mode" = bridge ]; then
    systemctl daemon-reload
    systemctl enable --now leigod-direct-policy.service ||
        fail 'cannot activate the direct routing policy; inspect its systemd journal'
    info "bridge leigodbr0 uses main routing for $bridge_subnet; missing routes fail without TUN fallback"
    info 'sing-box TUN must exclude leigodbr0 and the bridge return subnet; see docs/SING_BOX_BYPASS.md'
fi

# Commit only after build, deployment, health checks and host installation all
# succeeded. A failed build/deploy leaves the previous saved settings intact.
config_pending=$(mktemp "$RUNTIME_DIR/.docker.env.XXXXXX")
install -m 0600 "$staged_config" "$config_pending"
mv -f -- "$config_pending" "$CONFIG_FILE"
config_pending=
info 'installation complete'
printf '%s\n' \
    'Log out and back in once so the leigod-game group applies.' \
    'For each Lutris game, set Command prefix to: /usr/bin/leigod-game-run --' \
    'Direct Wine example: leigod-game-run -- wine /path/to/game.exe'
if [ "$network_mode" = bridge ] && [ "$bind_address" != 127.0.0.1 ]; then
    printf '%s\n' \
        'Phone discovery: same Wi-Fi, scan for Steam Deck.' \
        'UDP 6066 replies advertise the host LAN address that received the probe.' \
        'Allow LAN access to TCP 5588 and UDP 6066 on the host firewall.'
fi
