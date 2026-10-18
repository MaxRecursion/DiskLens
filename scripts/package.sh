#!/bin/zsh
# Builds a distributable DiskLens.app (universal: Apple silicon + Intel).
#
#   scripts/package.sh appstore   → dist/appstore/DiskLens.app (+ DiskLens.pkg when signing is configured)
#   scripts/package.sh direct     → dist/direct/DiskLens.app + DiskLens.dmg (notarized when configured)
#
# Signing identities come from release.config. Without them the app is ad-hoc signed, which is
# enough to run and test locally (including the App Sandbox) but not to distribute.
# NOTE: App Store Connect requires uploads built with Xcode; for the final App Store upload use the
# Xcode project (see docs/RELEASING.md). This script is for local sandbox testing and direct sales.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/env.sh
source release.config
EDITION="${1:-direct}"
[[ "$EDITION" == "appstore" || "$EDITION" == "direct" ]] || { echo "usage: $0 appstore|direct"; exit 2; }

OUT="dist/$EDITION"
APP="$OUT/$APP_NAME.app"
ENTITLEMENTS="Resources/DiskLens-$([[ $EDITION == appstore ]] && echo AppStore || echo Direct).entitlements"

echo "▸ Building universal release binary"
swift build -c release --arch arm64 --arch x86_64 --product DiskLensApp
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"

echo "▸ Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/DiskLensApp" "$APP/Contents/MacOS/$APP_NAME"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp Resources/PrivacyInfo.xcprivacy "$APP/Contents/Resources/PrivacyInfo.xcprivacy"
cp Resources/MenuBarIcon.png Resources/MenuBarIcon@2x.png "$APP/Contents/Resources/"
printf 'APPL????' > "$APP/Contents/PkgInfo"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleLocalizations</key><array><string>en</string></array>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIconName</key><string>AppIcon</string>
  <key>CFBundleSupportedPlatforms</key><array><string>MacOSX</string></array>
  <key>LSMinimumSystemVersion</key><string>$MIN_MACOS</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHumanReadableCopyright</key><string>$COPYRIGHT</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticTermination</key><false/>
  <key>NSSupportsSuddenTermination</key><false/>
  <key>ITSAppUsesNonExemptEncryption</key><false/>
  <key>NSDesktopFolderUsageDescription</key><string>DiskLens measures the names, sizes and dates of files on your Desktop and compares large files to find exact duplicates. Nothing leaves your Mac, and nothing is removed without your approval.</string>
  <key>NSDocumentsFolderUsageDescription</key><string>DiskLens measures the names, sizes and dates of files in Documents and compares large files to find exact duplicates. Nothing leaves your Mac, and nothing is removed without your approval.</string>
  <key>NSDownloadsFolderUsageDescription</key><string>DiskLens measures the names, sizes and dates of files in Downloads to find large installers and exact duplicates. Nothing leaves your Mac, and nothing is removed without your approval.</string>
  <key>NSRemovableVolumesUsageDescription</key><string>DiskLens measures file sizes on volumes you choose to scan.</string>
  <key>NSNetworkVolumesUsageDescription</key><string>DiskLens measures file sizes on network volumes you choose to scan.</string>
  <key>DiskLensSupportURL</key><string>$SUPPORT_URL</string>
  <key>DiskLensPrivacyPolicyURL</key><string>$PRIVACY_URL</string>
  <key>DiskLensTermsURL</key><string>$TERMS_URL</string>
  <key>DiskLensPurchaseURL</key><string>$PURCHASE_URL</string>
</dict></plist>
PLIST
if [[ "$EDITION" == "direct" ]]; then
  # The direct edition ships the command-line tool inside the bundle (Contents/Helpers).
  swift build -c release --arch arm64 --arch x86_64 --product disklens-cli
  mkdir -p "$APP/Contents/Helpers"
  cp "$BIN/disklens-cli" "$APP/Contents/Helpers/disklens-cli"
fi
plutil -lint "$APP/Contents/Info.plist" >/dev/null

sign() {  # sign <identity or -> [extra args...]
  local id="$1"; shift
  # Inner executables first (hardened runtime), then the bundle.
  if [[ -f "$APP/Contents/Helpers/disklens-cli" ]]; then
    codesign --force --sign "$id" --identifier "$BUNDLE_ID.cli" "$@" "$APP/Contents/Helpers/disklens-cli"
  fi
  codesign --force --sign "$id" --entitlements "$ENTITLEMENTS" "$@" "$APP"
  codesign --verify --strict --verbose=2 "$APP"
}

if [[ "$EDITION" == "appstore" ]]; then
  if [[ -n "$APPSTORE_SIGN_IDENTITY" && -n "$PROVISIONING_PROFILE" && -n "$INSTALLER_SIGN_IDENTITY" ]]; then
    echo "▸ Signing for the Mac App Store"
    cp "$PROVISIONING_PROFILE" "$APP/Contents/embedded.provisionprofile"
    sign "$APPSTORE_SIGN_IDENTITY" --options runtime --timestamp
    productbuild --component "$APP" /Applications --sign "$INSTALLER_SIGN_IDENTITY" "$OUT/$APP_NAME.pkg"
    echo "✓ $OUT/$APP_NAME.pkg (local install test only — upload the Xcode archive, see docs/RELEASING.md)"
  else
    echo "▸ No App Store identities configured — ad-hoc signing with sandbox entitlements (local testing only)"
    sign - --options runtime
  fi
else
  if [[ -n "$DEVELOPER_ID_IDENTITY" ]]; then
    echo "▸ Signing with Developer ID (hardened runtime)"
    sign "$DEVELOPER_ID_IDENTITY" --options runtime --timestamp
  else
    echo "▸ No Developer ID configured — ad-hoc signing (local use only)"
    sign - --options runtime
  fi
  if [[ -n "$DEVELOPER_ID_IDENTITY" && -n "$NOTARY_PROFILE" ]]; then
    echo "▸ Notarizing the app and stapling the ticket to it"
    ZIP="$OUT/$APP_NAME-notarize.zip"
    ditto -c -k --keepParent "$APP" "$ZIP"
    xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$APP"
    rm -f "$ZIP"
  fi
  DMG="$OUT/$APP_NAME-$VERSION.dmg"
  rm -f "$DMG"
  STAGE="$(mktemp -d)"
  cp -R "$APP" "$STAGE/"
  ln -s /Applications "$STAGE/Applications"
  hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
  rm -rf "$STAGE"
  if [[ -n "$DEVELOPER_ID_IDENTITY" ]]; then
    codesign --force --sign "$DEVELOPER_ID_IDENTITY" --timestamp "$DMG"
    if [[ -n "$NOTARY_PROFILE" ]]; then
      echo "▸ Notarizing the DMG"
      xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
      xcrun stapler staple "$DMG"
      spctl -a -t open --context context:primary-signature -vv "$DMG" || true
    fi
  fi
  echo "✓ $DMG"
fi
echo "✓ $APP ($(lipo -archs "$APP/Contents/MacOS/$APP_NAME"))"
