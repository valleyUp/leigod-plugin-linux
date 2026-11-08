#!/bin/sh
set -eu

PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH

VERSION=1.2.2.15
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
RUNTIME_DIR=$SCRIPT_DIR/.leigod
CONFIG_FILE=$RUNTIME_DIR/docker.env
INSTALL_MANIFEST=$RUNTIME_DIR/install-manifest
STATE_VOLUME=leigod-plugin-state
purge=0
purge_state=0

info() {
    printf '[INFO] %s\n' "$*"
}

fail() {
    printf '[ERROR] %s\n' "$*" >&2
    exit 1
}

warn() {
    printf '[WARN] %s\n' "$*" >&2
}

MANIFEST_HELPERS=$SCRIPT_DIR/libexec/install-manifest.sh
[ -r "$MANIFEST_HELPERS" ] || fail 'install manifest helpers are missing'
. "$MANIFEST_HELPERS"

while [ "$#" -gt 0 ]; do
    case "$1" in
        --purge) purge=1 ;;
        --purge-state) purge_state=1 ;;
        -h|--help)
            printf 'usage: sudo ./uninstall.sh [--purge] [--purge-state]\n'
            printf '%s\n' \
                '--purge removes the locally built Docker images.' \
                '--purge-state removes the phone binding state volume after label verification.'
            exit 0
            ;;
        *) fail "unknown option: $1" ;;
    esac
    shift
done

[ "$(id -u)" -eq 0 ] || fail 'run as root (sudo ./uninstall.sh)'

if [ -x /usr/bin/docker ]; then
    DOCKER=/usr/bin/docker
elif [ -x /usr/local/bin/docker ]; then
    DOCKER=/usr/local/bin/docker
else
    DOCKER=
fi

network_mode=
wrapper_sha256=
if [ -r "$CONFIG_FILE" ]; then
    network_mode=$(sed -n 's/^LEIGOD_NETWORK_MODE=//p' "$CONFIG_FILE" | head -n 1)
    wrapper_sha256=$(sed -n 's/^LEIGOD_WRAPPER_SHA256=//p' "$CONFIG_FILE" | head -n 1)
fi
case "$network_mode" in
    macvlan) compose_override=$SCRIPT_DIR/docker/compose.macvlan.yml ;;
    bridge) compose_override=$SCRIPT_DIR/docker/compose.bridge.yml ;;
    *) compose_override= ;;
esac

if [ -n "$DOCKER" ] && [ -r "$SCRIPT_DIR/docker/compose.yml" ] &&
   [ -n "$compose_override" ] && [ -r "$compose_override" ] && [ -r "$CONFIG_FILE" ]; then
    info 'stopping and removing the isolated accelerator container'
    "$DOCKER" compose --env-file "$CONFIG_FILE" --project-directory "$SCRIPT_DIR" \
        -f "$SCRIPT_DIR/docker/compose.yml" -f "$compose_override" \
        down --remove-orphans || true
elif [ -n "$DOCKER" ]; then
    project=$(
        "$DOCKER" inspect --format '{{index .Config.Labels "com.docker.compose.project"}}' \
            leigod-plugin 2>/dev/null || true
    )
    if [ "$project" = leigod-plugin ]; then
        info 'removing the orphaned accelerator container'
        "$DOCKER" rm -f leigod-plugin >/dev/null
    fi
    proxy_project=$(
        "$DOCKER" inspect --format '{{index .Config.Labels "com.docker.compose.project"}}' \
            leigod-discover-proxy 2>/dev/null || true
    )
    if [ "$proxy_project" = leigod-plugin ]; then
        info 'removing the orphaned discovery proxy container'
        "$DOCKER" rm -f leigod-discover-proxy >/dev/null
    fi
fi

if [ "$purge_state" -eq 1 ]; then
    [ -n "$DOCKER" ] || fail 'Docker is required to remove the binding state volume'
    if "$DOCKER" volume inspect "$STATE_VOLUME" >/dev/null 2>&1; then
        state_volume_project=$(
            "$DOCKER" volume inspect --format \
                '{{index .Labels "com.docker.compose.project"}}' "$STATE_VOLUME"
        )
        state_volume_key=$(
            "$DOCKER" volume inspect --format \
                '{{index .Labels "com.docker.compose.volume"}}' "$STATE_VOLUME"
        )
        if [ "$state_volume_project" != leigod-plugin ] ||
           [ "$state_volume_key" != leigod-state ]; then
            fail "refusing to remove $STATE_VOLUME because its Compose labels do not match this project"
        fi
        info "removing phone binding state volume: $STATE_VOLUME"
        "$DOCKER" volume rm "$STATE_VOLUME" >/dev/null ||
            fail "cannot remove binding state volume: $STATE_VOLUME"
    else
        info "phone binding state volume is already absent: $STATE_VOLUME"
    fi
else
    info "phone binding state volume was retained: $STATE_VOLUME (use --purge-state to remove it)"
fi

retained_managed_files=0
manifest_available=0
if [ -f "$INSTALL_MANIFEST" ] && [ ! -L "$INSTALL_MANIFEST" ]; then
    manifest_available=1
elif [ -e "$INSTALL_MANIFEST" ] || [ -L "$INSTALL_MANIFEST" ]; then
    warn "install manifest is not a trusted regular file and was retained: $INSTALL_MANIFEST"
    retained_managed_files=1
fi

remove_managed_file() {
    managed_target=$1
    if [ ! -e "$managed_target" ] && [ ! -L "$managed_target" ]; then
        return 0
    fi
    if [ "$manifest_available" -eq 1 ] &&
       leigod_manifest_file_matches "$INSTALL_MANIFEST" "$managed_target"; then
        rm -f -- "$managed_target"
        return 0
    fi
    warn "managed file is modified or cannot be verified and was retained: $managed_target"
    retained_managed_files=1
    return 1
}

policy_helper=/usr/local/libexec/leigod-direct-policy.py
policy_unit=/etc/systemd/system/leigod-direct-policy.service
if [ -e "$policy_helper" ] || [ -L "$policy_helper" ] ||
   [ -e "$policy_unit" ] || [ -L "$policy_unit" ]; then
    if [ "$manifest_available" -eq 1 ] &&
       leigod_manifest_file_matches "$INSTALL_MANIFEST" "$policy_helper" &&
       leigod_manifest_file_matches "$INSTALL_MANIFEST" "$policy_unit"; then
        policy_subnet=$(awk '$1 == "ExecStop=/usr/local/libexec/leigod-direct-policy.py" && $2 == "--subnet" {print $3; exit}' "$policy_unit")
        [ -n "$policy_subnet" ] || fail 'cannot read the verified direct policy subnet'
        info 'removing the verified direct routing policy and its exact rules'
        systemctl disable --now leigod-direct-policy.service ||
            fail 'cannot stop the direct routing policy; its files were retained'
        "$policy_helper" --subnet "$policy_subnet" --remove ||
            fail 'cannot remove the direct policy rules; its files were retained'
        remove_managed_file "$policy_unit" || true
        remove_managed_file "$policy_helper" || true
        systemctl daemon-reload
    else
        warn 'direct routing policy files cannot both be verified and were retained'
        retained_managed_files=1
    fi
fi

if [ "$manifest_available" -eq 1 ]; then
    remove_managed_file /usr/bin/leigod-game-run || true
else
    if [ -f /usr/bin/leigod-game-run ] && [ ! -L /usr/bin/leigod-game-run ] &&
       printf '%s\n' "$wrapper_sha256" | grep -Eq '^[[:xdigit:]]{64}$'; then
        installed_wrapper_sha256=$(sha256sum /usr/bin/leigod-game-run | awk '{print $1}')
        if [ "$installed_wrapper_sha256" = "$wrapper_sha256" ]; then
            rm -f -- /usr/bin/leigod-game-run
        else
            warn '/usr/bin/leigod-game-run was modified after installation and was retained'
            retained_managed_files=1
        fi
    elif [ -e /usr/bin/leigod-game-run ] || [ -L /usr/bin/leigod-game-run ]; then
        warn '/usr/bin/leigod-game-run ownership cannot be verified and was retained'
        retained_managed_files=1
    fi
fi

remove_managed_file /usr/local/libexec/leigod-game-enter || true
remove_managed_file /usr/local/libexec/leigod-netns-exec || true
remove_managed_file /etc/sudoers.d/leigod-game || true

rm -f "$CONFIG_FILE"
if [ "$retained_managed_files" -eq 0 ]; then
    rm -f -- "$INSTALL_MANIFEST"
    rmdir "$RUNTIME_DIR" 2>/dev/null || true
else
    warn "install manifest retained for manual review: $INSTALL_MANIFEST"
fi

if [ "$purge" -eq 1 ] && [ -n "$DOCKER" ]; then
    info 'purging the locally built images'
    "$DOCKER" image rm "leigod-plugin:$VERSION" >/dev/null 2>&1 || true
    "$DOCKER" image rm "leigod-discover-proxy:$VERSION" >/dev/null 2>&1 || true
else
    info 'the locally built Docker images were retained; use --purge to remove them'
fi

info 'uninstalled; downloaded vendor assets and the leigod-game group were retained'
