#!/bin/sh

# Read installer-owned dotenv data as data, never as shell code. Environment
# overrides are applied by the caller, followed by command-line options.
leigod_config_validate() {
    [ -f "$1" ] && [ ! -L "$1" ] || return 1
    awk '
        /^[[:space:]]*(#|$)/ { next }
        {
            key = $0; sub(/=.*/, "", key)
            if (key !~ /^LEIGOD_[A-Z0-9_]+$/ || index($0, "=") == 0 || seen[key]++) exit 1
            value = substr($0, length(key) + 2)
            # Our generated values need no quoting or dotenv interpolation.
            if (value !~ /^[a-zA-Z0-9_.:\/-]*$/ &&
                !(key == "LEIGOD_USER" && value ~ /^[a-z_][a-z0-9_-]*\$$/)) exit 1
        }
    ' "$1"
}

leigod_config_get() {
    if [ -r "$CONFIG_FILE" ]; then
        awk -v key="$1" -v fallback="$2" '
            index($0, key "=") == 1 { print substr($0, length(key) + 2); found = 1; exit }
            END { if (!found) print fallback }
        ' "$CONFIG_FILE"
    else
        printf '%s\n' "$2"
    fi
}

# A Docker network can be retained when its driver, IPAM and required driver
# option agree. Image/service changes do not require deleting the network.
leigod_network_state() {
    _leigod_network=$1
    _leigod_driver=$2
    _leigod_subnet=$3
    _leigod_gateway=$4
    _leigod_option=$5
    _leigod_expected_option=$6
    if ! _leigod_actual=$("$DOCKER" network inspect --format \
        "{{.Driver}}|{{index .Labels \"com.docker.compose.project\"}}|{{range .IPAM.Config}}{{.Subnet}}:{{.Gateway}};{{end}}|{{index .Options \"$_leigod_option\"}}" \
        "$_leigod_network" 2>/dev/null); then
        printf '%s\n' absent
        return
    fi
    case "$_leigod_actual" in
        *'|leigod-plugin|'*) ;;
        *) printf 'network %s is not owned by this Compose project\n' "$_leigod_network" >&2; return 1 ;;
    esac
    if [ "$_leigod_actual" = "$_leigod_driver|leigod-plugin|$_leigod_subnet:$_leigod_gateway;|$_leigod_expected_option" ]; then
        printf '%s\n' reuse
    else
        printf '%s\n' recreate
    fi
}

# Container processes have their own PID namespace; host applications entered
# by our wrapper share the installer PID namespace and must exit before rebuild.
leigod_namespace_clients() {
    _leigod_net=$(readlink "/proc/$1/ns/net" 2>/dev/null) || return 0
    _leigod_host_pid=$(readlink /proc/self/ns/pid) || return 1
    for _leigod_proc in /proc/[0-9]*; do
        [ "$(readlink "$_leigod_proc/ns/net" 2>/dev/null || true)" = "$_leigod_net" ] || continue
        [ "$(readlink "$_leigod_proc/ns/pid" 2>/dev/null || true)" = "$_leigod_host_pid" ] || continue
        printf '%s %s\n' "${_leigod_proc##*/}" "$(cat "$_leigod_proc/comm" 2>/dev/null || true)"
    done
}
