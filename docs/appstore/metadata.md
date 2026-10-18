# DiskLens — App Store Connect listing

Copy each field into App Store Connect → your app → macOS App → 1.0.0. Character limits are Apple's;
`python3 scripts/check_metadata.py` verifies them (and flags remaining `example.com` placeholders).

## Name (30)
DiskLens

## Subtitle (30)
Disk space map & safe cleanup

## Promotional text (170)
See what fills your Mac with a treemap, then reclaim space with suggestions you preview and approve. Scanning and recommendations are free. No data collection.

## Keywords (100, comma-separated, no spaces)
disk,space,storage,treemap,analyzer,cleaner,cache,duplicates,developer,node_modules,xcode,purge

## Description (4000)
DiskLens shows you where your disk space went — and helps you get it back without putting your files at risk.

FREE: SEE EVERYTHING
• An interactive treemap sized by the space each folder really occupies on disk. Double-click to zoom into any folder; breadcrumbs take you back.
• Every byte belongs to exactly one category — Applications, Documents & Media, Developer Artifacts, Package Caches, SDKs & VMs, AI Models & Tool Data, Downloads, System — and DiskLens shows which rule put it there.
• Largest files, search, size filters, a scan manifest with every folder macOS kept private (shown as “unknown”, never as zero), and changes since your last scan.
• The complete list of cleanup suggestions with honest estimates, the evidence behind each one and the exact action — plus previews and dry runs of any cleanup. Move any single item to the Trash yourself.
• Your first one-click cleanup (up to 2 GB) is included, so you can see the result before you decide.

CLEANUP YOU CAN TRUST
• Three tiers: disposable caches, conditional items that need a quick check, and things DiskLens never touches for you — personal files, backups, virtual-machine disks and app data are listed for your review only.
• Honest estimates. DiskLens understands APFS clones and hard links, so it never promises space that deleting a shared file cannot free.
• A full preview of the exact folders before anything happens, an optional dry run, and an approval tied to that exact plan. Prefer an undo? Move items to the Trash instead.
• Before every removal DiskLens re-checks that the item is still the one it scanned and that the app that owns it is not running. (macOS does not let App Store apps see command-line tools; items they may use are marked “unverified” and never pre-selected.)
• After cleaning, DiskLens measures the real change in free space and keeps a report.

DISKLENS PRO (ONE-TIME PURCHASE)
• One-click cleanup of approved plans, with a verification report.
• Duplicate finder: byte-identical copies found with SHA-256 on your Mac; clones and hard links are recognised.
• Developer rule pack: node_modules with lockfile checks, JavaScript, .NET and Python build output, Xcode DerivedData, Playwright browsers, npm, pnpm, pip and Homebrew caches, stale app-update downloads, Electron and AI-tool caches, superseded CLI versions.
• Scheduled background scans, a free-space monitor in the menu bar and low-space alerts.
• Markdown and JSON report export and scan history.
Safety checks, previews and dry runs are never behind the paywall.

PRIVATE BY DESIGN
• Scanning is read-only. To find exact duplicates, DiskLens compares the contents of large files — locally, on your Mac.
• Cloud-only files (iCloud Drive, Google Drive) are never downloaded.
• No ads, no analytics, no account. DiskLens collects no data; your scan stays on your Mac.
• You choose which folders DiskLens may see.

Requires macOS 14 Sonoma or later. Optimised for Apple silicon and Intel Macs.

## What's New (4000) — version 1.0.0
First release.

## In-app purchase (App Store Connect → Monetization → In-App Purchases)
- Type: Non-Consumable
- Reference name: DiskLens Pro (lifetime)
- Product ID: `pro.lifetime` (must match `StoreProducts.proLifetime`; permanent once created)
- Price: choose a price tier in App Store Connect — the app shows `Product.displayPrice` only.
- Family Sharing: **On** (decision and trade-offs in docs/LICENSING.md; cannot be turned off later)
- Display name (35): DiskLens Pro
- Description (55): One-click cleanup, duplicates, scheduling and reports
- Review screenshot: `docs/appstore/screenshots/06-paywall.jpg`
- Review notes: see docs/appstore/review-notes.md ▸ In-app purchase

## URLs
- Support URL: https://example.com/disklens/support   ← replace (host docs/site/support.html)
- Marketing URL (optional): leave empty unless you have a real page
- Privacy Policy URL: https://example.com/disklens/privacy   ← replace (host docs/site/privacy.html)
- Terms of Use (EULA): Apple's standard EULA, or host docs/site/terms.html and add it under App Information ▸ License Agreement

## Categories
- Primary: Utilities
- Secondary: Developer Tools

## Age rating
All questions: None → 4+.

## App Privacy (nutrition label)
"Data Not Collected" — no analytics, no accounts, no tracking; scan results stay on the user's Mac.
Purchases are processed by Apple (StoreKit); DiskLens receives only the signed transaction, which
never leaves the Mac. (Matches Resources/PrivacyInfo.xcprivacy: no collected data types, no tracking.)

## Export compliance
Uses only Apple's standard OS cryptography (SHA-256 to compare files, Ed25519 verification of
StoreKit/license signatures) → exempt. `ITSAppUsesNonExemptEncryption = NO` is set in Info.plist.

## Copyright
© 2026 Akshay Kulkarni

## Screenshots (2880 × 1800 and 2560 × 1600, 16:10; 1440 × 900 and 1280 × 800 also accepted)
Generated from a synthetic demo Mac (no real user data) with the sandboxed App Store edition by
`scripts/make_screenshots.sh` → `docs/appstore/screenshots/<size>/`. Suggested order and captions:
1. 01-explorer — "See what fills your Mac at a glance"
2. 02-cleanup — "Evidence for every suggestion — free"
3. 03-preview — "Nothing happens until you approve the exact plan"
4. 04-categories — "Every byte, in exactly one category"
5. 05-zoom — "Zoom into any folder"
6. 06-paywall — "Pro: one-click cleanup, duplicates, scheduling"
