#!/bin/sh
set -eu
# The image uses one Python process for all four logs. Resolve the adjacent
# source when running tests directly from the repository.
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
if [ -r "$script_dir/log-forwarder.py" ]; then
    exec python3 "$script_dir/log-forwarder.py" "$@"
fi
exec /usr/bin/python3 /usr/local/libexec/leigod-log-forwarder.py "$@"
