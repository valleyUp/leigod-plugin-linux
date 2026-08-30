#!/bin/sh
set -eu

REPO_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
WORK_DIR=$(mktemp -d "$REPO_DIR/.leigod-test.XXXXXX")

cleanup() {
    rm -rf -- "$WORK_DIR"
}
trap cleanup EXIT HUP INT TERM

fail() {
    printf 'security-policy: %s\n' "$*" >&2
    exit 1
}

for script in \
    install.sh \
    uninstall.sh \
    docker/entrypoint.sh \
    docker/healthcheck.sh \
    docker/log-forwarder.sh \
    bin/leigod-game-run \
    libexec/leigod-game-enter \
    libexec/install-manifest.sh \
    packages/build-tar.sh \
    tests/discover-proxy.sh; do
    sh -n "$REPO_DIR/$script" || fail "shell syntax failed: $script"
done
LEIGOD_LOG_LEVEL=warn sh "$REPO_DIR/docker/log-forwarder.sh" --self-test ||
    fail 'accelerator log forwarder self-test failed'

. "$REPO_DIR/libexec/install-manifest.sh"
manifest_test_file=$WORK_DIR/managed-file
manifest_test_manifest=$WORK_DIR/install-manifest
printf 'installed content\n' > "$manifest_test_file"
printf '%s\n' '# leigod-plugin install manifest v1' > "$manifest_test_manifest"
leigod_manifest_record_file "$manifest_test_manifest" "$manifest_test_file" ||
    fail 'cannot record a manifest test file'
leigod_manifest_file_matches "$manifest_test_manifest" "$manifest_test_file" ||
    fail 'freshly recorded manifest entry does not match'
printf 'modified content\n' > "$manifest_test_file"
if leigod_manifest_file_matches "$manifest_test_manifest" "$manifest_test_file"; then
    fail 'manifest accepted a modified installed file'
fi
ln -s "$manifest_test_manifest" "$WORK_DIR/manifest-link"
if leigod_manifest_hash_for "$WORK_DIR/manifest-link" "$manifest_test_file" >/dev/null; then
    fail 'manifest helpers accepted a symlink manifest'
fi

cc -std=c11 -O2 -Wall -Wextra -Werror -D_FORTIFY_SOURCE=2 \
    -fstack-protector-strong -Wl,-z,relro,-z,now \
    -o "$WORK_DIR/leigod-netns-exec" "$REPO_DIR/src/leigod-netns-exec.c"
cc -std=c11 -O2 -Wall -Wextra -Werror -D_FORTIFY_SOURCE=2 \
    -fstack-protector-strong -Wl,-z,relro,-z,now \
    -o "$WORK_DIR/leigod-discover-proxy" "$REPO_DIR/src/leigod-discover-proxy.c"
"$WORK_DIR/leigod-discover-proxy" --self-test || fail 'discovery proxy self-test failed'
grep -q 'DynamicUser=yes' "$REPO_DIR/systemd/leigod-discover-proxy.service" ||
    fail 'discovery proxy unit must use DynamicUser'
if grep -E 'network_mode:[[:space:]]*host|privileged:[[:space:]]*true' \
    "$REPO_DIR/systemd/leigod-discover-proxy.service" >/dev/null; then
    fail 'discovery proxy unit must not use host network or privileged'
fi

grep -q 'privileged: false' "$REPO_DIR/docker/compose.yml" ||
    fail 'Compose must explicitly disable privileged mode'
if grep -R -E 'network_mode:[[:space:]]*host|privileged:[[:space:]]*true|pid:[[:space:]]*host|ipc:[[:space:]]*host' \
    "$REPO_DIR/docker" >/dev/null; then
    fail 'forbidden host namespace or privileged setting found'
fi
if grep -R -F '/var/run/docker.sock' "$REPO_DIR/docker" >/dev/null; then
    fail 'Docker socket must not be mounted into the container'
fi
grep -q 'driver: macvlan' "$REPO_DIR/docker/compose.macvlan.yml" ||
    fail 'macvlan is not configured'
grep -q 'no-new-privileges:true' "$REPO_DIR/docker/compose.yml" ||
    fail 'no-new-privileges is not enabled'
grep -q 'read_only: true' "$REPO_DIR/docker/compose.yml" ||
    fail 'container root filesystem is not read-only'
grep -q 'source: leigod-state' "$REPO_DIR/docker/compose.yml" ||
    fail 'binding state does not use the dedicated named volume'
grep -q 'target: /var/lib/leigod/config' "$REPO_DIR/docker/compose.yml" ||
    fail 'binding state volume is not limited to the configuration directory'
grep -q 'name: leigod-plugin-state' "$REPO_DIR/docker/compose.yml" ||
    fail 'binding state volume does not have the fixed project name'
grep -q 'nocopy: true' "$REPO_DIR/docker/compose.yml" ||
    fail 'binding state volume must disable Docker copy-up'
grep -q 'test: \["CMD", "/usr/local/sbin/leigod-healthcheck"\]' \
    "$REPO_DIR/docker/compose.yml" || fail 'Compose does not use the healthcheck script'
grep -q "pgrep -f .*daemon" "$REPO_DIR/docker/healthcheck.sh" ||
    fail 'healthcheck does not require the accelerator daemon'
grep -q "pgrep -f .*web" "$REPO_DIR/docker/healthcheck.sh" ||
    fail 'healthcheck does not require the accelerator Web process'
grep -q "sport = :5588" "$REPO_DIR/docker/healthcheck.sh" ||
    fail 'healthcheck does not require the control port listener'
grep -q 'COPY docker/healthcheck.sh /usr/local/sbin/leigod-healthcheck' \
    "$REPO_DIR/docker/Dockerfile" || fail 'healthcheck script is not copied into the image'
grep -q 'COPY docker/log-forwarder.sh /usr/local/sbin/leigod-log-forwarder' \
    "$REPO_DIR/docker/Dockerfile" || fail 'log forwarder is not copied into the image'
grep -q 'LEIGOD_LOG_LEVEL: ${LEIGOD_LOG_LEVEL:-warn}' "$REPO_DIR/docker/compose.yml" ||
    fail 'Compose does not default to warning-level accelerator logs'
grep -q '^LEIGOD_LOG_LEVEL=warn$' "$REPO_DIR/config/docker.env.example" ||
    fail 'Docker environment example omits the default log level'
grep -q 'max-size: 10m' "$REPO_DIR/docker/compose.yml" ||
    fail 'Docker log size is not bounded'
grep -q 'max-file: "3"' "$REPO_DIR/docker/compose.yml" ||
    fail 'Docker log rotation count is not bounded'
grep -q 'speedSign.*redacted' "$REPO_DIR/docker/log-forwarder.sh" ||
    fail 'accelerator log forwarder does not redact session identifiers'
grep -q 'REPEAT_LIMIT=60' "$REPO_DIR/docker/log-forwarder.sh" ||
    fail 'accelerator log forwarder does not suppress repeated messages'
grep -q 'ln -s /opt/leigod /home/leigod' "$REPO_DIR/docker/Dockerfile" ||
    fail 'Steam Deck /home/leigod compatibility path is missing'
if grep -q 'type dummy' "$REPO_DIR/docker/entrypoint.sh"; then
    fail 'wlan0 must carry the Docker network instead of being an offline dummy'
fi
for override in compose.macvlan.yml compose.bridge.yml; do
    grep -q 'mac_address: ${LEIGOD_DEVICE_MAC' "$REPO_DIR/docker/$override" ||
        fail "device MAC is not assigned by Docker in $override"
done
unexpected_capability=$(
    sed -n '/^    cap_add:/,/^    devices:/p' "$REPO_DIR/docker/compose.yml" |
        sed -n 's/^      - //p' | grep -Ev '^(NET_ADMIN|NET_RAW)$' || true
)
[ -z "$unexpected_capability" ] || fail "unexpected container capability: $unexpected_capability"

if grep -R -E 'iptables([^[:alnum:]_]|$).*-[FAX]|ip[[:space:]]+link[[:space:]]+add|ip[[:space:]]+route[[:space:]]+(add|replace)' \
    "$REPO_DIR/install.sh" "$REPO_DIR/uninstall.sh" "$REPO_DIR/libexec" "$REPO_DIR/bin" >/dev/null; then
    fail 'host installer path contains a host network mutation'
fi

[ ! -e "$REPO_DIR/systemd/leigod_plugin.service" ] ||
    fail 'legacy host-network systemd service still exists'
[ ! -e "$REPO_DIR/debian/postinst" ] ||
    fail 'legacy Debian host-network installer still exists'
if grep -E '/opt/leigod-plugin|/etc/leigod-plugin|/usr/local/bin/leigod-game-run|\.local/bin/leigod-game-run' \
    "$REPO_DIR/install.sh" "$REPO_DIR/uninstall.sh" >/dev/null; then
    fail 'installer writes project state outside the repository or uses the wrong wrapper path'
fi
grep -q 'install -m 0755 .* /usr/bin/leigod-game-run' "$REPO_DIR/install.sh" ||
    fail 'system wrapper is not installed to /usr/bin/leigod-game-run'
grep -q 'RUNTIME_DIR=\$SCRIPT_DIR/.leigod' "$REPO_DIR/install.sh" ||
    fail 'runtime configuration is not repository-local'
grep -q '"\$SCRIPT_DIR"$' "$REPO_DIR/install.sh" ||
    fail 'Docker build context is not the current repository'
grep -q 'INSTALL_MANIFEST=\$RUNTIME_DIR/install-manifest' "$REPO_DIR/install.sh" ||
    fail 'install manifest is not repository-local'
grep -q 'leigod_manifest_record_file' "$REPO_DIR/install.sh" ||
    fail 'installer does not record managed system files'
grep -q 'leigod_manifest_file_matches' "$REPO_DIR/uninstall.sh" ||
    fail 'uninstaller does not verify managed file hashes'
grep -q 'STATE_VOLUME=leigod-plugin-state' "$REPO_DIR/uninstall.sh" ||
    fail 'uninstaller does not use the fixed binding state volume name'
grep -q -- '--purge-state' "$REPO_DIR/uninstall.sh" ||
    fail 'uninstaller does not expose an explicit state purge option'
grep -q 'com.docker.compose.project' "$REPO_DIR/uninstall.sh" ||
    fail 'state volume removal does not verify the Compose project label'
grep -q 'com.docker.compose.volume' "$REPO_DIR/uninstall.sh" ||
    fail 'state volume removal does not verify the Compose volume label'
uninstall_help=$(sh "$REPO_DIR/uninstall.sh" --help)
printf '%s\n' "$uninstall_help" | grep -q -- '--purge-state' ||
    fail 'uninstaller help omits state purge semantics'

source_archive=$WORK_DIR/leigod-source.tar.gz
LEIGOD_SOURCE_OUTPUT=$source_archive sh "$REPO_DIR/packages/build-tar.sh" >/dev/null
archive_root=leigod-plugin-1.2.2.15
tar -tzf "$source_archive" > "$WORK_DIR/source-archive.list"
for required_archive_path in \
    "$archive_root/systemd/leigod-discover-proxy.service" \
    "$archive_root/docker/healthcheck.sh" \
    "$archive_root/docker/log-forwarder.sh" \
    "$archive_root/libexec/install-manifest.sh"; do
    grep -Fxq "$required_archive_path" "$WORK_DIR/source-archive.list" ||
        fail "source package is missing: $required_archive_path"
done
if grep -Fxq "$archive_root/bin/leigod-discover-proxy" "$WORK_DIR/source-archive.list"; then
    fail 'source package contains the local precompiled discovery proxy'
fi

if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    LEIGOD_VERSION=1.2.2.15 \
    LEIGOD_DEVICE_MAC=02:11:22:33:44:55 \
    LEIGOD_PARENT=eth0 \
    LEIGOD_SUBNET=192.0.2.0/24 \
    LEIGOD_GATEWAY=192.0.2.1 \
    LEIGOD_IPV4=192.0.2.2 \
        docker compose --project-directory "$REPO_DIR" \
        -f "$REPO_DIR/docker/compose.yml" \
        -f "$REPO_DIR/docker/compose.macvlan.yml" config > "$WORK_DIR/macvlan.yml"

    LEIGOD_VERSION=1.2.2.15 \
    LEIGOD_DEVICE_MAC=02:11:22:33:44:55 \
    LEIGOD_BIND_ADDRESS=127.0.0.1 \
    LEIGOD_BRIDGE_IPV4=172.21.0.2 \
    LEIGOD_BRIDGE_SUBNET=172.21.0.0/16 \
    LEIGOD_BRIDGE_GATEWAY=172.21.0.1 \
        docker compose --project-directory "$REPO_DIR" \
        -f "$REPO_DIR/docker/compose.yml" \
        -f "$REPO_DIR/docker/compose.bridge.yml" config > "$WORK_DIR/bridge.yml"

    for rendered in "$WORK_DIR/macvlan.yml" "$WORK_DIR/bridge.yml"; do
        grep -q 'NET_ADMIN' "$rendered" || fail "NET_ADMIN missing from $rendered"
        grep -q 'NET_RAW' "$rendered" || fail "NET_RAW missing from $rendered"
        grep -q 'source: /dev/net/tun' "$rendered" || fail "TUN missing from $rendered"
        if grep -E 'network_mode:[[:space:]]*host|privileged:[[:space:]]*true' "$rendered" >/dev/null; then
            fail "unsafe rendered Compose config: $rendered"
        fi
        grep -q 'source: leigod-state' "$rendered" ||
            fail "binding state volume missing from $rendered"
        grep -q 'target: /var/lib/leigod/config' "$rendered" ||
            fail "binding state mount target changed in $rendered"
        grep -q 'name: leigod-plugin-state' "$rendered" ||
            fail "binding state volume name changed in $rendered"
        if grep -E "source: $REPO_DIR/\.leigod" "$rendered" >/dev/null; then
            fail "binding state leaked into a host repository bind mount: $rendered"
        fi
    done
    grep -q 'driver: macvlan' "$WORK_DIR/macvlan.yml" || fail 'rendered macvlan driver changed'
    grep -q "source: $REPO_DIR/opt/leigod/fake_product_name" "$WORK_DIR/macvlan.yml" ||
        fail 'DMI bind source is not repository-local'
    grep -q 'host_ip: 127.0.0.1' "$WORK_DIR/bridge.yml" || fail 'bridge fallback is not loopback-bound'
    grep -A5 'target: 5588' "$WORK_DIR/bridge.yml" | grep -q 'protocol: tcp' ||
        fail 'bridge Web/API TCP port is not published'
    grep -q 'ipv4_address: 172.21.0.2' "$WORK_DIR/bridge.yml" ||
        fail 'bridge container IP is not pinned'
    if grep -E 'target: 6066' "$WORK_DIR/bridge.yml" >/dev/null; then
        fail 'bridge discovery UDP must be owned by the host proxy, not Docker publish'
    fi
    if grep -A5 'target: 10001' "$WORK_DIR/bridge.yml" >/dev/null; then
        fail 'debug port must not be published'
    fi
fi

sh "$REPO_DIR/tests/discover-proxy.sh"

printf 'security-policy: all checks passed\n'
