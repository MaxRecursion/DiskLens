#!/bin/zsh
# Sparkle 2 release step for the direct edition (run after the notarized DMG exists).
#   1. Once: download Sparkle's release tools (bin/generate_keys, bin/generate_appcast) from
#      https://github.com/sparkle-project/Sparkle/releases and run `generate_keys` — it stores the
#      EdDSA private key in your login Keychain and prints the public key for SUPublicEDKey
#      (Resources/Info-Direct.plist).
#   2. Each release: put the notarized DMG(s) and release notes (.html/.md with the same base name)
#      into one folder and run this script with the path to Sparkle's bin folder.
#   3. Upload the folder contents (appcast.xml + DMG) to the HTTPS location in SUFeedURL.
set -euo pipefail
SPARKLE_BIN="${1:?usage: appcast.sh /path/to/Sparkle/bin [updates-folder]}"
FOLDER="${2:-dist/direct}"
"$SPARKLE_BIN/generate_appcast" "$FOLDER"   # signs each archive with the Keychain EdDSA key
echo "✓ $FOLDER/appcast.xml — upload it next to the DMG"
