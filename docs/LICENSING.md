# Monetization and licensing

DiskLens is freemium. One codebase, two storefronts:

| | Mac App Store edition | Direct edition (Developer ID) |
|---|---|---|
| Pro | StoreKit 2 non-consumable `pro.lifetime` | Ed25519-signed license key (`DLK1.…`) |
| Trial | — (Apple has no trials for non-consumables) | 7 days, once per user, started by the user |
| Free one-click cleanup | 1 run, plans up to 2 GB (estimate) | same |
| CLI | not included | `disklens-cli` (Pro or Team key) |
| Updates | App Store | Sparkle 2 (EdDSA-signed appcast) |
| Team / CI | — | yearly per-machine Team key (`seats`, `expiresAt`) |

## What is free and what is Pro

Defined in one place: `Sources/DiskLensCore/Licensing/FeatureGate.swift`.

* **Free, never gated** — scanning, treemap, categories, largest files, search, inspector, scan
  manifest with coverage gaps, change detection, the full recommendation list (estimates, tiers,
  evidence, exact actions — including the developer pack's findings), cleanup preview, dry run,
  every safety check, and moving one item at a time to the Trash. `FeatureGate.allowsDryRun()`,
  `allowsPreview()` and `allowsSingleItemTrash()` return `true` unconditionally (tested).
* **Pro** — `Feature.cleanupExecution`, `.duplicates`, `.developerRules` (one-click cleanup of the
  developer rule pack: see `RulePack.developerRuleIDs`), `.scheduling` (background scans, menu bar,
  low-space alerts), `.reportExport` (Markdown/JSON, scan history), `.cli` (direct edition).
* **Conversion hooks** — one free one-click run up to 2 GB estimated (`FreeCleanupAllowance`), the
  direct edition's 7-day trial (`TrialManager`), and a contextual paywall (`PaywallContext`) whose
  headline quotes only the measured estimate of the user's latest scan ("DiskLens found 8.53 GB you
  can safely reclaim"); without a scan it shows no number. "Not Now" always closes it.
* **Never** — ads, telemetry, uploading scan data, scare tactics, paywalled previews/dry runs/safety.

The trial start, the free-run counter and the cached App Store entitlement are stored in the login
Keychain (`KeychainStore`, this-device-only, not synced), not in UserDefaults. A Keychain read error
grants no trial and counts the free run as used (fail closed) — it never blocks a safety feature.

## Mac App Store: StoreKit 2

Code: `LicenseService` (logic, unit-tested with a fake `PurchaseStore`) + `StoreKitPurchaseStore`
(thin StoreKit adapter in the app).

* Launch: `LicenseService.prepare()` applies the cached entitlement synchronously, `connect()` starts
  the `Transaction.updates` listener, reconciles with `Transaction.currentEntitlements` (works
  offline from the on-device receipt; it is the source of truth — a cache without an entitlement is
  dropped) and loads `Product.products(for:)`.
* Purchase: `Product.purchase(confirmIn:)` on macOS 15.2+, else `purchase()`. Only
  `VerificationResult.verified` transactions unlock; every transaction is `finish()`ed. `.pending`
  (Ask to Buy) unlocks later through `Transaction.updates`.
* Refunds/revocations arrive through `Transaction.updates` (`revocationDate`) → entitlements are
  re-read and Pro is removed.
* Restore Purchases → `AppStore.sync()` then `currentEntitlements` (paywall and Settings ▸ License).
* Price: `Product.displayPrice` only. Nothing in the app hard-codes a price.

### Family Sharing decision

**Enabled** (`EntitlementPolicy.familySharingEnabled = true`, `familyShareable: true` in the
StoreKit config). Reasons: it is a one-time, lifetime utility unlock; families commonly share a Mac
setup; Apple features family-shareable apps; and refunds/revocations are handled anyway. Trade-off:
fewer separate purchases per household. **Turning Family Sharing on in App Store Connect cannot be
undone for that product** — decide before the first submission. To disable, set the flag to `false`
and leave it off in App Store Connect.

### Local testing (needs Xcode)

`Resources/StoreKit/DiskLens.storekit` defines `pro.lifetime` (its 9.99 price is a local test value
only; the real price is set in App Store Connect). The XcodeGen scheme "DiskLens" uses it
(`Run ▸ Options ▸ StoreKit Configuration`). Test: purchase, cancel, Ask to Buy, refund (Debug ▸
StoreKit ▸ Manage Transactions), restore, offline. Then a Sandbox account on a TestFlight build.

## Direct edition: license keys

* Format: `DLK1.<base64url(payload JSON)>.<base64url(Ed25519 signature)>`, signature over
  `DLK1.<payload>`. Payload: `v`, `product`, `licenseID`, `edition` (`pro`|`team`), `emailHash`
  (SHA-256 of the lower-cased e-mail — no e-mail in clear text), `seats`, `issuedAt`, `expiresAt`
  (required for Team), optional `machineHashes` (per-machine binding; `MachineIdentity.hash()` is a
  salted SHA-256 of the hardware UUID).
* Verification: offline with CryptoKit `Curve25519.Signing` and the public key embedded in
  `LicenseKey.embeddedPublicKey`. Tampered, expired, future-dated, wrong-product and other-machine
  keys are rejected (tested).
* Storage: `~/Library/Application Support/DiskLens/license.dlk` (mode 0600), shared by the app and
  `disklens-cli`; CI can point `DISKLENS_LICENSE_FILE` elsewhere. A file (not the Keychain) so
  headless CI machines work; editing it cannot forge a license.
* Activation UI: paywall ▸ "Enter License Key…", Settings ▸ License (activate/deactivate);
  CLI: `disklens-cli license activate --key-file FILE|-`, `license status [--json]`, `license deactivate`.

### Minting keys — the private key never ships

```bash
swiftc -O scripts/license/disklens-license.swift -o /tmp/disklens-license
/tmp/disklens-license keygen --out .signing          # once; prints the public key
/tmp/disklens-license issue --key .signing/license-signing.key --email buyer@example.com --edition pro
/tmp/disklens-license issue --key .signing/license-signing.key --email it@corp.example --edition team --seats 25 --years 1
```

A development key pair was generated in `.signing/` (git-ignored, 0600) and its public key is
embedded. **Before launch, generate a fresh production pair on a trusted machine, embed the new
public key, store the private key in a password manager / HSM, and delete `.signing/`.** Rotating
the key invalidates every key minted with the old one.

### Merchant of record

Use a merchant of record so VAT/sales tax, invoices and refunds are handled for you:
**Paddle**, **Lemon Squeezy** or **FastSpring** all support one-time products and yearly
subscriptions (Team), webhooks, and custom license delivery. Setup outline:

1. Create products: "DiskLens Pro" (one-time) and "DiskLens Team" (yearly, quantity = seats).
2. Point the fulfilment webhook at a tiny serverless function that verifies the provider's webhook
   signature, then runs the same 20 lines as `disklens-license issue` (Swift, or port to
   TypeScript/Python with any Ed25519 library) with the private key from the function's secret
   store, and e-mails the key (or returns it to the provider's checkout to display).
3. Put the checkout URL in `release.config` (`PURCHASE_URL`) → `DiskLensPurchaseURL` in Info.plist.
4. Refunds/chargebacks: keep a revocation list keyed by `licenseID` and ship it with updates if
   needed (offline verification cannot revoke instantly — documented limitation). Team keys expire
   on their own after a year.
5. Seats are honour-based offline. For strict enforcement issue per-machine keys (`--machine HASH`,
   the customer reads the hash with `disklens-cli license machine-id`) or use the
   provider's activation API.

## Sparkle (direct edition)

* The Xcode target `DiskLensDirect` (scheme "DiskLens Pro (Direct)") links Sparkle 2 via SwiftPM;
  `Sources/DiskLensApp/Update/SparkleUpdater.swift` compiles only when Sparkle is present
  (`#if canImport(Sparkle)`), adding "Check for Updates…" to the app menu. The plain SwiftPM build
  and the App Store target do not include Sparkle.
* Info keys in `Resources/Info-Direct.plist`: `SUFeedURL` (HTTPS), `SUPublicEDKey` (from Sparkle's
  `generate_keys`, which keeps the EdDSA private key in your Keychain), daily automatic checks,
  system profiling off.
* Each release: notarized DMG → `scripts/release/appcast.sh /path/to/Sparkle/bin dist/direct` →
  upload `appcast.xml` + DMG to the feed location.
