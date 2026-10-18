import Testing
import Foundation
import CryptoKit
@testable import DiskLensCore

// MARK: - Helpers

func signLicense(_ p: LicensePayload, _ key: Curve25519.Signing.PrivateKey) -> String {
    let enc = JSONEncoder()
    enc.dateEncodingStrategy = .iso8601
    enc.outputFormatting = [.sortedKeys]
    let body = "DLK1." + Base64URL.encode(try! enc.encode(p))
    return body + "." + Base64URL.encode(try! key.signature(for: Data(body.utf8)))
}

func plan(_ recs: [Recommendation]) -> CleanupPlan { CleanupPlan(scanID: nil, items: recs) }

func rec(rule: String, tier: CleanupTier = .low, bytes: Int64, kind: CleanupActionKind = .deletePermanently) -> Recommendation {
    var r = makeRec("/tmp/disklens-test/\(rule)-\(bytes)", tier: tier, kind: kind, bytes: bytes)
    r.ruleID = rule
    r.id = "\(rule):\(bytes)"
    return r
}

/// Scripted stand-in for StoreKit 2.
actor FakePurchaseStore: PurchaseStore {
    var entitlements: [StoreVerification] = []
    var purchaseResult: StorePurchaseResult = .userCancelled
    var productList = [StoreProductInfo(id: StoreProducts.proLifetime, displayName: "DiskLens Pro", description: "Lifetime", displayPrice: "€9,99")]
    var finished: [UInt64] = []
    var syncCalls = 0
    var syncError: Error?
    nonisolated let stream: AsyncStream<StoreVerification>
    nonisolated let continuation: AsyncStream<StoreVerification>.Continuation

    init() {
        var c: AsyncStream<StoreVerification>.Continuation!
        stream = AsyncStream { c = $0 }
        continuation = c
    }

    func set(entitlements: [StoreVerification]) { self.entitlements = entitlements }
    func set(purchase: StorePurchaseResult) { purchaseResult = purchase }
    func set(products: [StoreProductInfo]) { productList = products }
    func set(syncError: Error?) { self.syncError = syncError }

    func products(_ ids: [String]) async throws -> [StoreProductInfo] { productList.filter { ids.contains($0.id) } }
    func purchase(_ productID: String) async throws -> StorePurchaseResult { purchaseResult }
    func currentEntitlements() async -> [StoreVerification] { entitlements }
    nonisolated func transactionUpdates() -> AsyncStream<StoreVerification> { stream }
    func finish(transactionID: UInt64) async { finished.append(transactionID) }
    func syncWithAppStore() async throws { syncCalls += 1; if let syncError { throw syncError } }
}

let proTx = StoreTransactionInfo(id: 42, productID: StoreProducts.proLifetime, purchaseDate: Date(timeIntervalSince1970: 1_700_000_000))

// MARK: - Feature gate

@Suite("Feature gate: free, trial, pro")
struct FeatureGateTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func freeTierHasNoProFeaturesButKeepsSafetyAndPreviews() {
        let g = FeatureGate(state: .free, edition: .direct, now: now)
        for f in Feature.allCases { #expect(!g.isEnabled(f), "\(f) must be Pro") }
        #expect(g.allowsDryRun() && g.allowsPreview() && g.allowsSingleItemTrash())
    }

    @Test func activeTrialUnlocksEverythingInTheDirectEdition() {
        let g = FeatureGate(state: .trial(expires: now.addingTimeInterval(3600)), edition: .direct, now: now)
        for f in Feature.allCases { #expect(g.isEnabled(f)) }
    }

    @Test func expiredTrialFallsBackToFree() {
        let g = FeatureGate(state: .trial(expires: now.addingTimeInterval(-1)), edition: .direct, now: now)
        for f in Feature.allCases { #expect(!g.isEnabled(f)) }
        #expect(g.allowsDryRun())
    }

    @Test func appStorePurchaseUnlocksEverythingExceptTheDirectOnlyCLI() {
        let g = FeatureGate(state: .pro(source: .appStore(productID: StoreProducts.proLifetime)), edition: .appStore, now: now)
        for f in Feature.allCases where f != .cli { #expect(g.isEnabled(f)) }
        #expect(!g.isEnabled(.cli))
    }

    @Test func licenseKeysUnlockCLIOnlyInTheDirectEditionAndRespectExpiry() {
        let pro = FeatureGate(state: .pro(source: .licenseKey(edition: .pro, expires: nil)), edition: .direct, now: now)
        #expect(pro.isEnabled(.cli) && pro.isEnabled(.cleanupExecution))
        let team = FeatureGate(state: .pro(source: .licenseKey(edition: .team, expires: now.addingTimeInterval(86_400))), edition: .direct, now: now)
        #expect(team.isEnabled(.cli))
        let lapsed = FeatureGate(state: .pro(source: .licenseKey(edition: .team, expires: now.addingTimeInterval(-1))), edition: .direct, now: now)
        #expect(!lapsed.isEnabled(.cli) && !lapsed.isEnabled(.cleanupExecution))
    }

    @Test func freeRunAllowsOneCappedPlanThenRequiresPro() {
        var g = FeatureGate(state: .free, edition: .appStore, now: now)
        let small = plan([rec(rule: "npm-cache", bytes: 1_500_000_000)])
        #expect(g.executionDecision(for: small) == .allowedAsFreeRun(capBytes: FreeCleanupAllowance.capBytes))
        let big = plan([rec(rule: "npm-cache", bytes: 1_500_000_000), rec(rule: "pip-cache", bytes: 600_000_000)])
        #expect(g.executionDecision(for: big) == .exceedsFreeRunCap(planBytes: 2_100_000_000, capBytes: FreeCleanupAllowance.capBytes))
        g.freeAllowance = FreeCleanupAllowance(runsUsed: 1)
        #expect(g.executionDecision(for: small) == .requiresPro(.developerRules))
        #expect(g.executionDecision(for: plan([rec(rule: "google-updater-cache", bytes: 10)])) == .requiresPro(.cleanupExecution))
    }

    @Test func tierThreeIsNeverExecutableAndDoesNotCountTowardsTheCap() {
        let g = FeatureGate(state: .pro(source: .appStore(productID: "pro.lifetime")), edition: .appStore, now: now)
        #expect(g.executionDecision(for: plan([rec(rule: "large-file", tier: .manualReview, bytes: 9_000_000_000, kind: .manualReview)])) == .nothingExecutable)
        let free = FeatureGate(state: .free, edition: .appStore, now: now)
        let mixed = plan([rec(rule: "npm-cache", bytes: 1_000_000_000), rec(rule: "vm-disk", tier: .manualReview, bytes: 50_000_000_000, kind: .manualReview)])
        #expect(free.executionDecision(for: mixed) == .allowedAsFreeRun(capBytes: FreeCleanupAllowance.capBytes))
    }

    @Test func proAndTrialMayExecuteAnyTierOneOrTwoPlan() {
        let p = plan([rec(rule: "node-modules", tier: .conditional, bytes: 30_000_000_000)])
        #expect(FeatureGate(state: .pro(source: .licenseKey(edition: .pro, expires: nil)), edition: .direct, now: now).executionDecision(for: p) == .allowed)
        #expect(FeatureGate(state: .trial(expires: now.addingTimeInterval(10)), edition: .direct, now: now).executionDecision(for: p) == .allowed)
    }

    @Test func developerPackMembership() {
        #expect(RulePack.of(ruleID: "node-modules") == .developer)
        #expect(RulePack.of(ruleID: "xcode-deriveddata") == .developer)
        #expect(RulePack.of(ruleID: "app-cache:Code Cache") == .developer)
        #expect(RulePack.of(ruleID: "sparkle-update") == .developer)
        #expect(RulePack.of(ruleID: "large-file") == .core)
        #expect(RulePack.of(ruleID: "duplicates") == .core)
        // Every developer rule id must exist in the catalog (no typos that silently ungate a rule).
        let ids = Set(RuleCatalog.standard(home: "/Users/nobody").map(\.id))
        for id in RulePack.developerRuleIDs { #expect(ids.contains(id), "unknown developer rule id \(id)") }
    }
}

// MARK: - License keys

@Suite("License keys: Ed25519 offline verification")
struct LicenseKeyTests {
    let priv = Curve25519.Signing.PrivateKey()
    var verifier: LicenseKey { LicenseKey(publicKey: priv.publicKey) }
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func payload(_ edition: LicenseEdition = .pro, expires: Date? = nil, machines: [String]? = nil) -> LicensePayload {
        LicensePayload(licenseID: "L-1", edition: edition, emailHash: LicensePayload.emailHash(" Buyer@Example.com "),
                       seats: edition == .team ? 5 : 1, issuedAt: now.addingTimeInterval(-86_400), expiresAt: expires, machineHashes: machines)
    }

    @Test func validKeyVerifiesIncludingLineBreaksFromEmail() throws {
        let key = signLicense(payload(), priv)
        let wrapped = key.enumerated().map { $0.offset % 40 == 39 ? "\($0.element)\n" : String($0.element) }.joined()
        let p = try verifier.verify("  " + wrapped + "\n", now: now, machineHash: nil)
        #expect(p.edition == .pro && p.licenseID == "L-1")
        #expect(p.emailHash == LicensePayload.emailHash("buyer@example.com"))
        #expect(!key.contains("example.com"), "the key must not contain the e-mail address")
    }

    @Test func tamperedPayloadOrSignatureIsRejected() throws {
        let key = signLicense(payload(), priv)
        let parts = key.split(separator: ".").map(String.init)
        // Swap in a payload claiming Team with 1000 seats, keep the original signature.
        var forged = payload(.team, expires: now.addingTimeInterval(1e9)); forged.seats = 1000
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        let forgedKey = "DLK1." + Base64URL.encode(try enc.encode(forged)) + "." + parts[2]
        #expect(throws: LicenseKeyError.badSignature) { try verifier.verify(forgedKey, now: now, machineHash: nil) }
        // Flip one signature character.
        var sig = Array(parts[2]); sig[5] = sig[5] == "A" ? "B" : "A"
        #expect(throws: LicenseKeyError.badSignature) { try verifier.verify("DLK1.\(parts[1]).\(String(sig))", now: now, machineHash: nil) }
        // A key signed by someone else's private key.
        let other = signLicense(payload(), Curve25519.Signing.PrivateKey())
        #expect(throws: LicenseKeyError.badSignature) { try verifier.verify(other, now: now, machineHash: nil) }
        // Production verifier rejects a key signed with a random test key.
        #expect(throws: LicenseKeyError.badSignature) { try LicenseKey.embedded().verify(key, now: now, machineHash: nil) }
    }

    @Test func malformedKeysAreRejected() {
        for bad in ["", "hello", "DLK1.abc", "DLK2.a.b", "DLK1.!!!.???", "DLK1." + Base64URL.encode(Data("{}".utf8)) + ".AAAA"] {
            #expect(throws: LicenseKeyError.malformed) { try verifier.verify(bad, now: now, machineHash: nil) }
        }
    }

    @Test func expiredAndFutureKeysAreRejected() {
        let expired = signLicense(payload(.team, expires: now.addingTimeInterval(-60)), priv)
        #expect(throws: LicenseKeyError.expired(now.addingTimeInterval(-60))) { try verifier.verify(expired, now: now, machineHash: nil) }
        var future = payload(); future.issuedAt = now.addingTimeInterval(30 * 86_400)
        #expect(throws: LicenseKeyError.self) { try verifier.verify(signLicense(future, priv), now: now, machineHash: nil) }
        var noExpiry = payload(.team); noExpiry.expiresAt = nil
        #expect(throws: LicenseKeyError.teamLicenseWithoutExpiry) { try verifier.verify(signLicense(noExpiry, priv), now: now, machineHash: nil) }
    }

    @Test func wrongProductAndUnknownVersionAreRejected() {
        var p = payload(); p.product = "otherapp"
        #expect(throws: LicenseKeyError.wrongProduct("otherapp")) { try verifier.verify(signLicense(p, priv), now: now, machineHash: nil) }
        var v = payload(); v.v = 2
        #expect(throws: LicenseKeyError.unsupportedVersion(2)) { try verifier.verify(signLicense(v, priv), now: now, machineHash: nil) }
    }

    @Test func machineBindingIsEnforcedWhenPresent() throws {
        let bound = signLicense(payload(machines: ["aaa", "bbb"]), priv)
        #expect(try verifier.verify(bound, now: now, machineHash: "bbb").machineHashes == ["aaa", "bbb"])
        #expect(throws: LicenseKeyError.notValidOnThisMac) { try verifier.verify(bound, now: now, machineHash: "ccc") }
        #expect(throws: LicenseKeyError.notValidOnThisMac) { try verifier.verify(bound, now: now, machineHash: nil) }
    }

    @Test func embeddedPublicKeyIsAValidEd25519Key() {
        _ = LicenseKey.embedded()
        #expect(MachineIdentity.hash()?.count ?? 64 == 64)
    }
}

// MARK: - Trial & free-run counter

@Suite("Trial and free cleanup run (Keychain-backed counters)")
struct TrialTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func trialLifecycle() throws {
        let store = InMemorySecureStore()
        let tm = TrialManager(store: store)
        #expect(tm.status(now: t0) == .notStarted)
        #expect(try tm.start(now: t0) == .active(expires: t0.addingTimeInterval(TrialManager.length)))
        #expect(tm.status(now: t0.addingTimeInterval(6 * 86_400)) == .active(expires: t0.addingTimeInterval(TrialManager.length)))
        #expect(tm.status(now: t0.addingTimeInterval(7 * 86_400)) == .expired(expired: t0.addingTimeInterval(TrialManager.length)))
        // Starting again never restarts it.
        #expect(try tm.start(now: t0.addingTimeInterval(30 * 86_400)) == .expired(expired: t0.addingTimeInterval(TrialManager.length)))
    }

    @Test func settingTheClockBackDoesNotExtendTheTrial() throws {
        let tm = TrialManager(store: InMemorySecureStore())
        try tm.start(now: t0)
        tm.touch(now: t0.addingTimeInterval(8 * 86_400))           // seen after expiry
        #expect(tm.status(now: t0.addingTimeInterval(86_400)) == .expired(expired: t0.addingTimeInterval(TrialManager.length)))
    }

    @Test func unreadableKeychainGrantsNoTrialAndCountsTheFreeRunAsUsed() {
        let store = InMemorySecureStore()
        store.failing = true
        #expect(TrialManager(store: store).status(now: t0) == .unavailable)
        #expect(FreeRunCounter(store: store).allowance().remaining == 0)
        #expect(throws: (any Error).self) { try FreeRunCounter(store: store).consume() }
    }

    @Test func freeRunIsConsumedOnceAndRefundedWhenNothingWasRemoved() throws {
        let c = FreeRunCounter(store: InMemorySecureStore())
        #expect(c.allowance().remaining == 1)
        try c.consume()
        #expect(c.allowance().remaining == 0)
        c.refund()
        #expect(c.allowance().remaining == 1)
    }
}

// MARK: - LicenseService with an injected StoreKit stand-in

@Suite("LicenseService: StoreKit logic via injected PurchaseStore")
@MainActor
struct LicenseServiceTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func service(_ store: FakePurchaseStore, edition: Edition = .appStore, secure: InMemorySecureStore = InMemorySecureStore(),
                 licenseDir: URL? = nil, verifier: LicenseKey = .embedded()) -> LicenseService {
        let t = now
        return LicenseService(edition: edition, purchaseStore: store, secure: secure,
                              licenseFile: licenseDir.map { LicenseFileStore(directory: $0) }, verifier: verifier,
                              machineHash: "m1", clock: { t })
    }

    @Test func launchWithoutPurchaseIsFreeAndLoadsLocalizedPrice() async {
        let store = FakePurchaseStore()
        let s = service(store)
        await s.start()
        #expect(s.state == .free)
        #expect(s.proProduct?.displayPrice == "€9,99")
    }

    @Test func verifiedPurchaseUnlocksProAndFinishesTheTransaction() async {
        let store = FakePurchaseStore()
        await store.set(purchase: .success(.verified(proTx)))
        let s = service(store)
        await s.start()
        #expect(await s.purchasePro() == .purchased)
        #expect(s.state == .pro(source: .appStore(productID: StoreProducts.proLifetime)))
        #expect(await store.finished == [42])
    }

    @Test func unverifiedPurchaseUnlocksNothing() async {
        let store = FakePurchaseStore()
        await store.set(purchase: .success(.unverified(proTx, reason: "bad signature")))
        let s = service(store)
        await s.start()
        #expect(await s.purchasePro() == .unverified("bad signature"))
        #expect(s.state == .free)
    }

    @Test func cancelledAndPendingPurchases() async {
        let store = FakePurchaseStore()
        let s = service(store)
        await s.start()
        await store.set(purchase: .userCancelled)
        #expect(await s.purchasePro() == .cancelled)
        await store.set(purchase: .pending)
        #expect(await s.purchasePro() == .pending)
        #expect(s.purchasePending && s.state == .free)
        // Ask to Buy approved later: arrives via Transaction.updates.
        store.continuation.yield(.verified(proTx))
        for _ in 0..<50 where !s.state.isPaid { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(s.state.isPaid)
        #expect(!s.purchasePending)
    }

    @Test func missingProductIsReportedNotFaked() async {
        let store = FakePurchaseStore()
        await store.set(products: [])
        let s = service(store)
        await s.start()
        #expect(s.proProduct == nil && s.productsError != nil)
        #expect(await s.purchasePro() == .productUnavailable)
    }

    @Test func restoreUsesAppStoreSyncAndCurrentEntitlements() async {
        let store = FakePurchaseStore()
        let s = service(store)
        await s.start()
        await store.set(entitlements: [.verified(proTx)])
        let r = await s.restorePurchases()
        #expect((try? r.get()) == true)
        #expect(await store.syncCalls == 1)
        #expect(s.state.isPaid)
    }

    @Test func refundRevokesProAndClearsTheOfflineCache() async {
        let store = FakePurchaseStore()
        let secure = InMemorySecureStore()
        await store.set(entitlements: [.verified(proTx)])
        let s = service(store, secure: secure)
        await s.start()
        #expect(s.state.isPaid)
        var revoked = proTx; revoked.revocationDate = now
        await store.set(entitlements: [])
        store.continuation.yield(.verified(revoked))
        for _ in 0..<50 where s.state.isPaid { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(s.state == .free)
        #expect((try? secure.data(for: LicenseService.cacheKey)) == .some(nil))
    }

    @Test func offlineCacheGivesInstantStateAndStoreKitStaysTheSourceOfTruth() async throws {
        let secure = InMemorySecureStore()
        try secure.setValue(CachedStoreEntitlement(productID: StoreProducts.proLifetime, transactionID: 42, verifiedAt: now), for: LicenseService.cacheKey)
        // StoreKit (on-device receipt) still has the purchase: stays Pro.
        let store = FakePurchaseStore()
        await store.set(entitlements: [.verified(proTx)])
        let s = service(store, secure: secure)
        await s.start()
        #expect(s.state.isPaid)
        // A cache on its own (e.g. copied from another account) is overruled by StoreKit.
        let s2 = service(FakePurchaseStore(), secure: secure)
        await s2.start()
        #expect(s2.state == .free)
    }

    @Test func familySharedEntitlementCountsAndUnverifiedEntitlementDoesNot() async {
        var shared = proTx; shared.ownership = .familyShared
        let a = FakePurchaseStore(); await a.set(entitlements: [.verified(shared)])
        let s = service(a); await s.start()
        #expect(s.state.isPaid == EntitlementPolicy.familySharingEnabled)
        let b = FakePurchaseStore(); await b.set(entitlements: [.unverified(proTx, reason: "jailbreak")])
        let s2 = service(b); await s2.start()
        #expect(s2.state == .free)
    }

    @Test func directEditionTrialAndLicenseKeyActivation() async throws {
        let fx = Fixture("license")
        let dir = fx.root
        defer { withExtendedLifetime(fx) {} }
        let priv = Curve25519.Signing.PrivateKey()
        let s = service(FakePurchaseStore(), edition: .direct, licenseDir: URL(fileURLWithPath: dir),
                        verifier: LicenseKey(publicKey: priv.publicKey))
        await s.start()
        #expect(s.state == .free)
        try s.startTrial()
        #expect(s.state == .trial(expires: now.addingTimeInterval(TrialManager.length)))
        // Invalid key: nothing stored, still on trial.
        #expect(throws: LicenseKeyError.malformed) { try s.activate(licenseKey: "DLK1.nope") }
        #expect(!FileManager.default.fileExists(atPath: dir + "/license.dlk"))
        let key = signLicense(LicensePayload(licenseID: "T-9", edition: .team, emailHash: "x", seats: 3,
                                             issuedAt: now, expiresAt: now.addingTimeInterval(365 * 86_400)), priv)
        try s.activate(licenseKey: key)
        #expect(s.state == .pro(source: .licenseKey(edition: .team, expires: now.addingTimeInterval(365 * 86_400))))
        #expect(s.isEnabled(.cli))
        let perms = try FileManager.default.attributesOfItem(atPath: dir + "/license.dlk")[.posixPermissions] as? Int
        #expect(perms == 0o600)
        // A new service instance (next launch) picks the key up from disk.
        let s2 = service(FakePurchaseStore(), edition: .direct, licenseDir: URL(fileURLWithPath: dir), verifier: LicenseKey(publicKey: priv.publicKey))
        await s2.start()
        #expect(s2.state.isPaid)
        try s2.deactivateLicense()
        #expect(s2.state == .free)   // its own (empty) Keychain has no trial
    }

    @Test func appStoreEditionOffersNoTrial() async throws {
        let s = service(FakePurchaseStore(), edition: .appStore)
        await s.start()
        try s.startTrial()
        #expect(s.state == .free)
    }
}

// MARK: - Paywall copy

@Suite("Paywall copy uses measured numbers only")
struct PaywallTests {
    @Test func quotesOnlyTheMeasuredTierOneEstimateAsSafe() {
        let recs = [rec(rule: "npm-cache", bytes: 4_140_000_000), rec(rule: "pip-cache", bytes: 4_390_000_000),
                    rec(rule: "node-modules", tier: .conditional, bytes: 2_750_000_000),
                    rec(rule: "large-file", tier: .manualReview, bytes: 15_000_000_000, kind: .manualReview)]
        let c = PaywallContext.from(recommendations: recs, scanDate: Date(), trigger: .cleanup)
        #expect(c.headline == "DiskLens found 8.53 GB you can safely reclaim")
        #expect(c.itemCount == 2 && c.conditionalCount == 1)   // tier 3 never counted
        #expect(c.subheadline.contains("2.75 GB"))
        // In-use items are never quoted.
        var inUse = rec(rule: "npm-cache", bytes: 1_000_000_000); inUse.id = "busy"; inUse.inUseBy = ["node"]
        #expect(PaywallContext.from(recommendations: recs + [inUse], scanDate: Date(), trigger: .cleanup).headline
                == "DiskLens found 8.53 GB you can safely reclaim")
        // Only conditional items: no "safely".
        let t2 = PaywallContext.from(recommendations: [recs[2]], scanDate: Date(), trigger: .cleanup)
        #expect(t2.headline == "DiskLens found 2.75 GB you can reclaim after a quick check")
    }

    @Test func withoutAScanNoNumberIsInvented() {
        let c = PaywallContext.from(recommendations: [], scanDate: nil, trigger: .cleanup)
        #expect(c.reclaimableEstimate == nil)
        #expect(!c.headline.contains("GB") && !c.subheadline.contains("GB"))
        let empty = PaywallContext.from(recommendations: [], scanDate: Date(), trigger: .duplicates)
        #expect(empty.reclaimableEstimate == 0 && !empty.headline.contains("GB"))
    }
}
