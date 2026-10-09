#!/usr/bin/env sh
# ACC-NG build entry point; the upstream build changed metadata/update channels.
exec python3 "$(dirname "$0")/tools/build_ng.py"
