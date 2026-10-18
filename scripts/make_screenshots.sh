#!/bin/zsh
# Renders Mac App Store screenshots (JPEG, no transparency) from the synthetic demo Mac — never real
# user data — using the sandboxed App Store edition, so they show exactly what that edition does.
# Sizes: 1280×800, 1440×900, 2560×1600, 2880×1800 (all 16:10 sizes App Store Connect accepts).
# The sandboxed renderer can only write inside its own container; files are copied out.
set -euo pipefail
cd "$(dirname "$0")/.."
source release.config
scripts/package.sh appstore >/dev/null
CONTAINER="$HOME/Library/Containers/$BUNDLE_ID/Data"
RAW="$CONTAINER/tmp/store-screenshots"
rm -rf "$RAW"
# Force US English formatting so numbers and dates look the same for every developer.
"dist/appstore/$APP_NAME.app/Contents/MacOS/$APP_NAME" -AppleLocale en_US -AppleLanguages '(en)' --snapshot "$RAW" --demo --all-sizes
OUT=docs/appstore/screenshots
rm -rf "$OUT"; mkdir -p "$OUT"
jpg() { sips -s format jpeg -s formatOptions 92 "$1" --out "$2" >/dev/null; }
for size in 1280x800 1440x900 2560x1600 2880x1800; do
  W=${size%x*}; H=${size#*x}
  mkdir -p "$OUT/$size"
  jpg "$RAW/Explorer-$size.png"        "$OUT/$size/01-explorer.jpg"
  jpg "$RAW/Cleanup-$size.png"         "$OUT/$size/02-cleanup.jpg"
  jpg "$RAW/Categories-$size.png"      "$OUT/$size/04-categories.jpg"
  jpg "$RAW/Explorer-zoomed-$size.png" "$OUT/$size/05-zoom.jpg"
  # Sheets are rendered alone (at 2×); scale them to the canvas and centre them.
  for pair in "Cleanup-Preview:03-preview" "Paywall:06-paywall"; do
    src="${pair%%:*}"; dst="${pair##*:}"
    sips -Z $(( H * 82 / 100 )) "$RAW/$src.png" --out "$RAW/$src-$size.png" >/dev/null
    sips -p "$H" "$W" --padColor 111216 "$RAW/$src-$size.png" --out "$RAW/$src-$size-padded.png" >/dev/null
    jpg "$RAW/$src-$size-padded.png" "$OUT/$size/$dst.jpg"
  done
done
rm -rf "$RAW"
for f in "$OUT"/*/*.jpg; do echo "$(sips -g pixelWidth -g pixelHeight -g hasAlpha "$f" | awk '/pixel|hasAlpha/{printf "%s ", $2}') $f"; done
