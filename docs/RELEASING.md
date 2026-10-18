# Releasing DiskLens

Two editions are built from the same code; the app detects the App Sandbox at runtime
(`Edition.current`). Monetization details: [LICENSING.md](LICENSING.md).

| | Mac App Store | Direct download (Developer ID) |
|---|---|---|
| Sandbox | Yes — scans only folders the user grants (security-scoped bookmarks) | No — scans home, apps, Homebrew, /Library |
| Pro | StoreKit 2 `pro.lifetime` | License key, 7-day trial |
| Running-apps check | GUI apps only (command-line tools shown as "unverified") | Full process list |
| Homebrew cleanup | Shown as a command to copy | Runs `brew cleanup --prune=all` after approval |
| CLI | — | `disklens-cli` inside the app (`Contents/Helpers`) |
| Updates | App Store | Sparkle 2 |
| Build | Xcode: `scripts/build-appstore.sh` | `scripts/build-direct.sh` (SwiftPM) or Xcode scheme "DiskLens Pro (Direct)" |

## Toolchain on this Mac

Only the Command Line Tools are installed (`xcode-select -p` → `/Library/Developer/CommandLineTools`,
Swift 6.4, SDKs 26, 26.5, 27). Everything except App Store archiving/upload, StoreKit testing and
linking Sparkle works with them:

```bash
./scripts/test.sh              # Swift Testing (plugin path passed explicitly — CLT does not load it)
./scripts/build_app.sh         # direct edition + CLI → dist/
scripts/package.sh appstore    # local sandboxed App Store build (ad-hoc signed)
scripts/make_screenshots.sh    # store screenshots, 4 sizes, synthetic demo data
```

The macOS 27 SDK implements SwiftUI's `@State` as a macro whose plugin ships only with Xcode, so
`scripts/env.sh` builds against the newest CLT SDK that still declares it as a property wrapper
(26.5). The binary runs natively on macOS 27. With Xcode active, the default SDK is used.

## What only you can do

1. **Apple Developer Program** — enroll (paid, yearly) at developer.apple.com/programs.
2. **Install Xcode** from the Mac App Store, then `sudo xcode-select -s /Applications/Xcode.app` and
   `brew install xcodegen`.
3. **Identifiers** — developer.apple.com ▸ Identifiers: `com.akshaykulkarni.DiskLens` (App Store,
   with In-App Purchase capability) and `com.akshaykulkarni.DiskLens.direct` (direct). Permanent once
   used; if you change them update `release.config` and `project.yml`.
4. **Certificates** — Xcode ▸ Settings ▸ Accounts ▸ Manage Certificates: "Apple Distribution",
   "Mac Installer Distribution" (App Store) and "Developer ID Application" (direct). Put your Team ID
   in `project.yml` (`DEVELOPMENT_TEAM`) and `release.config` (`TEAM_ID`, identities).
5. **Notarization credentials** — `xcrun notarytool store-credentials disklens-notary --apple-id YOU
   --team-id TEAMID` and set `NOTARY_PROFILE="disklens-notary"`.
6. **App Store Connect** — Agreements, Tax and Banking (Paid Apps agreement — required for IAP);
   New App (macOS, bundle ID above, SKU `disklens-mac`); create the non-consumable `pro.lifetime`
   (price tier, Family Sharing On — irreversible — display name/description from
   `docs/appstore/metadata.md`, review screenshot `06-paywall.jpg`); a Sandbox tester account.
7. **Merchant of record** for the direct edition (Paddle / Lemon Squeezy / FastSpring): products,
   payout, fulfilment webhook that mints keys (see LICENSING.md); put the checkout URL in
   `release.config` → `PURCHASE_URL` and `Resources/Info-Direct.plist`.
8. **Production license key pair** — generate on a trusted machine, embed the public key in
   `LicenseKey.embeddedPublicKey`, keep the private key offline, delete `.signing/`.
9. **Sparkle** — download Sparkle's tools, run `generate_keys`, put the public key in
   `Resources/Info-Direct.plist` (`SUPublicEDKey`), host the appcast at `SUFeedURL` (HTTPS).
10. **Web pages** — host `docs/site/` (support, privacy, terms); replace every `example.com` URL and the
    support e-mail (`python3 scripts/check_metadata.py` lists them). Have the terms reviewed.
11. **Confirm** copyright holder ("© 2026 Akshay Kulkarni"), prices, availability and age rating.

## Mac App Store build (Xcode)

```bash
xcodegen generate                 # DiskLens.xcodeproj from project.yml
scripts/build-appstore.sh         # archive (scheme DiskLens) + export with scripts/ExportOptions-AppStore.plist
```

Or in Xcode: scheme **DiskLens** ▸ Product ▸ Archive ▸ Organizer ▸ Validate ▸ Distribute ▸ App
Store Connect. Test the purchase first with the scheme's StoreKit configuration, then TestFlight
with a Sandbox account. In App Store Connect fill in the listing from `docs/appstore/metadata.md`,
upload `docs/appstore/screenshots/2880x1800/*.jpg`, attach the IAP to the version, paste
`docs/appstore/review-notes.md`, App Privacy = **Data Not Collected**, then submit.

## Direct download (Developer ID, notarized)

```bash
scripts/build-direct.sh   # universal app + CLI → sign (hardened runtime) → notarize + staple app → DMG → sign + notarize + staple DMG
```

For auto-update builds use the Xcode scheme **DiskLens Pro (Direct)** (links Sparkle), export with
Developer ID, then run the same notarytool/stapler steps and `scripts/release/appcast.sh`.

## Local sandbox test (no developer account needed)

```bash
scripts/package.sh appstore && open dist/appstore/DiskLens.app
```

Runs exactly like the App Store edition (folder grants, container at
`~/Library/Containers/com.akshaykulkarni.DiskLens`), except StoreKit has no products without Xcode's
StoreKit configuration or App Store Connect — the paywall then says the price could not be loaded
(no price is invented). Delete that container before testing an Xcode/TestFlight build.

## Regenerating assets

```bash
swiftc -O scripts/tools/make_icon.swift -o /tmp/make_icon && /tmp/make_icon Resources \
  && iconutil -c icns Resources/AppIcon.iconset -o Resources/AppIcon.icns \
  && cp Resources/AppIcon.iconset/*.png Resources/Assets.xcassets/AppIcon.appiconset/ \
  && cp Resources/MenuBarIcon*.png Resources/Assets.xcassets/MenuBarIcon.imageset/
python3 scripts/tools/extract_strings.py   # refresh Resources/Localizable.xcstrings
scripts/make_screenshots.sh                # App Store screenshots from the synthetic demo Mac
python3 scripts/check_metadata.py          # listing limits + remaining placeholders
```

## Launch checklist

- [ ] `./scripts/test.sh` passes; Xcode build of both schemes has no warnings that matter
- [ ] Version and build number bumped (`project.yml`, `release.config`)
- [ ] Production license public key embedded; `.signing/` removed from the machine you build on
- [ ] `SUPublicEDKey`, `SUFeedURL`, `PURCHASE_URL`, support/privacy/terms URLs set — `check_metadata.py` clean
- [ ] StoreKit config test: purchase, cancel, pending (Ask to Buy), refund, restore, offline launch
- [ ] TestFlight Sandbox purchase + restore on a second Mac; Family Sharing member sees Pro
- [ ] Free tier walk-through: scan, recommendations, preview, dry run, single-item Trash, free run (≤ 2 GB), paywall "Not Now"
- [ ] Direct: trial start/expiry, key activate/deactivate, CLI `license status`, `policy` dry run, exit codes
- [ ] Screenshots regenerated (`scripts/make_screenshots.sh`) and inspected
- [ ] App Privacy = Data Not Collected; export compliance = exempt; IAP attached to the version
- [ ] Notarized DMG passes `spctl -a -t open --context context:primary-signature -vv`
- [ ] Appcast published and "Check for Updates…" finds the release from the previous build
