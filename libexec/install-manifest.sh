#!/bin/sh

# Helpers shared by install.sh and uninstall.sh. Callers must keep the target
# paths on a fixed whitelist; this file deliberately does not remove anything.

leigod_manifest_hash_for() {
    _leigod_manifest_file=$1
    _leigod_manifest_target=$2

    [ -f "$_leigod_manifest_file" ] && [ ! -L "$_leigod_manifest_file" ] || return 1
    _leigod_manifest_hash=$(
        awk -v target="$_leigod_manifest_target" \
            '$2 == target { print $1; exit }' "$_leigod_manifest_file"
    )
    printf '%s\n' "$_leigod_manifest_hash" | grep -Eq '^[[:xdigit:]]{64}$' || return 1
    printf '%s' "$_leigod_manifest_hash" | tr '[:upper:]' '[:lower:]'
}

leigod_manifest_record_file() {
    _leigod_manifest_output=$1
    _leigod_manifest_target=$2

    [ -f "$_leigod_manifest_target" ] && [ ! -L "$_leigod_manifest_target" ] || return 1
    _leigod_manifest_hash=$(sha256sum -- "$_leigod_manifest_target" | awk '{print $1}') || return 1
    printf '%s  %s\n' "$_leigod_manifest_hash" "$_leigod_manifest_target" \
        >> "$_leigod_manifest_output"
}

leigod_manifest_file_matches() {
    _leigod_manifest_file=$1
    _leigod_manifest_target=$2

    _leigod_manifest_expected=$(
        leigod_manifest_hash_for "$_leigod_manifest_file" "$_leigod_manifest_target"
    ) || return 1
    [ -f "$_leigod_manifest_target" ] && [ ! -L "$_leigod_manifest_target" ] || return 1
    _leigod_manifest_actual=$(
        sha256sum -- "$_leigod_manifest_target" | awk '{print $1}'
    ) || return 1
    [ "$_leigod_manifest_actual" = "$_leigod_manifest_expected" ]
}
