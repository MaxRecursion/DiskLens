#!/bin/zsh
# Local build: the direct (non-sandboxed) edition plus the CLI, ad-hoc signed unless release.config
# has a Developer ID. Output: dist/DiskLens.app (copy of dist/direct/DiskLens.app) and dist/disklens-cli.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/env.sh
scripts/package.sh direct
swift build -c release --product disklens-cli
cp "$(swift build -c release --show-bin-path)/disklens-cli" dist/disklens-cli
rm -rf dist/DiskLens.app && cp -R dist/direct/DiskLens.app dist/DiskLens.app
echo "Built $(pwd)/dist/DiskLens.app and $(pwd)/dist/disklens-cli"
