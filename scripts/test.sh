#!/bin/zsh
# Runs the DiskLens test suite (synthetic fixtures in temp dirs only — never real user files).
# With only the Command Line Tools, SwiftPM does not load the Swift Testing macro plugin, so its
# directory is passed explicitly.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/env.sh
exec swift test -Xswiftc -plugin-path -Xswiftc "$TESTING_PLUGIN_DIR" "$@"
