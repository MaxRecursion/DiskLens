#!/bin/zsh
# Mac App Store edition: Xcode archive + export for upload to App Store Connect.
# Requires Xcode (App Store Connect rejects uploads not built by Xcode) and XcodeGen.
# Without Xcode it falls back to a local, ad-hoc signed sandboxed build for testing.
set -euo pipefail
cd "$(dirname "$0")/.."
source release.config
if ! xcode-select -p 2>/dev/null | grep -q "Xcode.app"; then
  echo "✗ Xcode is not the active developer directory ($(xcode-select -p 2>/dev/null || echo none))."
  echo "  Install Xcode from the Mac App Store, then: sudo xcode-select -s /Applications/Xcode.app"
  echo "  Building the local sandboxed test build instead (not uploadable):"
  exec scripts/package.sh appstore
fi
command -v xcodegen >/dev/null || { echo "✗ xcodegen missing: brew install xcodegen"; exit 1; }
[[ -n "$TEAM_ID" ]] || { echo "✗ Set TEAM_ID in release.config (and DEVELOPMENT_TEAM in project.yml)"; exit 1; }
xcodegen generate
ARCHIVE="dist/appstore/DiskLens.xcarchive"
rm -rf "$ARCHIVE"
xcodebuild -project DiskLens.xcodeproj -scheme DiskLens -configuration Release -destination 'generic/platform=macOS' \
  -archivePath "$ARCHIVE" DEVELOPMENT_TEAM="$TEAM_ID" archive
sed "s/TEAM_ID_PLACEHOLDER/$TEAM_ID/" scripts/ExportOptions-AppStore.plist > dist/appstore/ExportOptions.plist
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist dist/appstore/ExportOptions.plist -exportPath dist/appstore/export
echo "✓ dist/appstore/export — upload with Xcode Organizer, Transporter, or:"
echo "  xcrun altool --upload-package dist/appstore/export/DiskLens.pkg --type macos --apiKey KEY --apiIssuer ISSUER"
