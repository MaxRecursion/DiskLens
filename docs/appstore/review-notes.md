# Notes for App Review (paste into "App Review Information → Notes")

DiskLens is a disk-space analyzer with a free tier and one non-consumable in-app purchase
("DiskLens Pro", product ID pro.lifetime). No account or sign-in is needed. The app has no network
access of its own; purchases go through StoreKit.

How to review:
1. Launch DiskLens. The welcome sheet explains what it reads and that nothing is removed without
   approval.
2. Click "Grant Home Folder…" and choose the Home folder in the Open panel (standard App Sandbox
   user-selected access; DiskLens keeps a security-scoped bookmark so access persists). Optionally
   add /Applications. Then click "Start Scan" (a typical home folder takes under a minute).
3. Explorer shows the treemap; double-click tiles to zoom. Categories, Largest Files and Scan
   Manifest show measurements and coverage. Select any file and use "Move to Trash…" (free).
4. Cleanup lists suggestions in three tiers with evidence (free). On a freshly set-up Mac there may
   be few caches; to see a suggestion, run this in Terminal and then click Rescan:
       mkdir -p ~/Library/Caches/pip && mkfile 100m ~/Library/Caches/pip/review-test.bin
   A tier-1 "pip cache" item appears. Select it, click "Preview Cleanup…", then "Dry Run" to see the
   exact action without changing anything. Tick "I reviewed the exact paths…" to enable approval;
   "Move to Trash instead of deleting" keeps everything recoverable. The first one-click cleanup
   (up to 2 GB) is free; afterwards the Approve button offers DiskLens Pro. Tier-3 items (personal
   files, backups, VM disks, app data) are never removed by the app.
5. Reports shows the measured free-space change after an approved cleanup.

In-app purchase:
- The paywall appears only when the user chooses a Pro action (or "Upgrade" in the sidebar); it is
  dismissible with "Not Now" and never blocks scanning, recommendations, previews, dry runs or any
  safety check. Its headline quotes the space measured by the user's own latest scan, e.g.
  "DiskLens found 2.31 GB you can safely reclaim"; without a scan it shows no number.
- The price is the localized Product.displayPrice from StoreKit. "Restore Purchases" is on the
  paywall and in Settings ▸ License (AppStore.sync + Transaction.currentEntitlements).
- Terms of Use and Privacy Policy links are on the paywall.
- With the sandbox account: Cleanup ▸ Preview ▸ Approve (after the free run) or sidebar "Upgrade" →
  "Unlock Pro". Pro unlocks immediately; refunds are honoured via Transaction.updates.

Safety and privacy:
- The app removes only items the user explicitly selected and approved in the preview (or a single
  item they chose to move to the Trash), and only inside folders the user granted. Before each
  removal it re-validates the path and the item's identity and checks that the owning app is not
  running. (The sandbox does not expose command-line tools, so items that such tools may use are
  marked "unverified" and are not pre-selected.)
- It never downloads cloud-only files and does not launch other programs. For tools that must clean
  up after themselves (e.g. Homebrew) it shows a command the user may run.
- To find exact duplicates (Pro) it hashes large files locally. No data is collected or transmitted.
- The app makes no "speed up your Mac" or similar performance claims; it reports measured sizes and
  labels every estimate as an estimate.
