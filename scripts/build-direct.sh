#!/bin/zsh
# Direct (Developer ID) edition: universal build → sign (hardened runtime) → notarize + staple the
# app → DMG → sign + notarize + staple the DMG. Identities come from release.config; without them
# the result is ad-hoc signed for local testing only.
#
# This SwiftPM build has no Sparkle (Sparkle is linked by the Xcode target "DiskLens Pro (Direct)").
# For a release with auto-update, archive that scheme in Xcode, then notarize its export with the
# same notarytool/stapler steps (scripts/release/appcast.sh signs the update for Sparkle).
set -euo pipefail
cd "$(dirname "$0")/.."
exec scripts/package.sh direct
