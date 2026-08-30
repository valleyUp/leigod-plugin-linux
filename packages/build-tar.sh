#!/bin/sh
set -eu

VERSION=1.2.2.15
REPO_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUTPUT=${LEIGOD_SOURCE_OUTPUT:-$REPO_DIR/packages/leigod-plugin-$VERSION-source.tar.gz}
STAGE=$(mktemp -d "$REPO_DIR/packages/.leigod-source.XXXXXX")
PACKAGE_DIR=$STAGE/leigod-plugin-$VERSION

cleanup() {
    rm -rf -- "$STAGE"
}
trap cleanup EXIT HUP INT TERM

mkdir -p "$PACKAGE_DIR"
tar -C "$REPO_DIR" \
    --exclude=.git \
    --exclude=.agents \
    --exclude=.codex \
    --exclude=.leigod \
    --exclude='.leigod-build.*' \
    --exclude='.leigod-test.*' \
    --exclude='packages/.leigod-source.*' \
    --exclude=debian \
    --exclude='packages/*.deb' \
    --exclude='packages/*.tar.gz' \
    --exclude='bin/leigod-discover-proxy' \
    --exclude='opt/leigod/acc-gw.router.*' \
    --exclude='opt/leigod/config/ipdatacloud_country.xdb' \
    -cf - . | tar -C "$PACKAGE_DIR" -xf -

tar -C "$STAGE" -czf "$OUTPUT" "leigod-plugin-$VERSION"
printf 'Built source package without vendor binaries: %s\n' "$OUTPUT"
