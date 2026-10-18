import Foundation
import Observation

public enum PurchaseOutcome: Equatable, Sendable {
    case purchased
    case cancelled
    /// Ask to Buy / payment confirmation pending; Pro unlocks when the transaction arrives.
    case pending
    /// StoreKit could not verify the transaction's signature: nothing is unlocked.
    case unverified(String)
    case productUnavailable
    case failed(String)
}

/// Single source of truth for the license state. Combines (in order of precedence) a verified
/// App Store entitlement, an activated license key, and the direct edition's trial. All external
/// systems are injected: `PurchaseStore` (StoreKit), `SecureStore` (Keychain), the license file,
/// the verification key and the clock — so tests need neither StoreKit nor the Keychain.
@MainActor
@Observable
public final class LicenseService {
    public private(set) var state: LicenseState = .free
    public private(set) var products: [StoreProductInfo] = []
    public private(set) var trial: TrialStatus = .notStarted
    public private(set) var activeLicense: LicensePayload?
    /// Why a stored license key is not active (expired, bound to another Mac …), if any.
    public private(set) var licenseProblem: String?
    public private(set) var freeAllowance = FreeCleanupAllowance()
    public private(set) var isPurchasing = false
    public private(set) var purchasePending = false
    public private(set) var storeEntitled = false
    public private(set) var productsError: String?
    public let edition: Edition

    @ObservationIgnored private let purchaseStore: any PurchaseStore
    @ObservationIgnored private let secure: any SecureStore
    @ObservationIgnored private let licenseFile: LicenseFileStore?
    @ObservationIgnored private let verifier: LicenseKey
    @ObservationIgnored private let machineHash: String?
    @ObservationIgnored private let clock: @Sendable () -> Date
    @ObservationIgnored private var updatesTask: Task<Void, Never>?
    @ObservationIgnored private var storeProductID = StoreProducts.proLifetime

    static let cacheKey = "storekit.entitlement.v1"

    public init(edition: Edition = .current, purchaseStore: any PurchaseStore = NoPurchaseStore(),
                secure: any SecureStore = KeychainStore(), licenseFile: LicenseFileStore? = LicenseFileStore(),
                verifier: LicenseKey = .embedded(), machineHash: String? = MachineIdentity.hash(),
                clock: @escaping @Sendable () -> Date = { Date() }) {
        self.edition = edition
        self.purchaseStore = purchaseStore
        self.secure = secure
        self.licenseFile = licenseFile
        self.verifier = verifier
        self.machineHash = machineHash
        self.clock = clock
    }

    /// A service fixed to one state (offscreen snapshots, previews).
    public static func fixed(_ state: LicenseState, edition: Edition, freeRunsUsed: Int = 0) -> LicenseService {
        let mem = InMemorySecureStore()
        try? mem.setValue(FreeCleanupAllowance(runsUsed: freeRunsUsed), for: FreeRunCounter.key)
        let s = LicenseService(edition: edition, secure: mem, licenseFile: nil)
        s.state = state
        s.freeAllowance = FreeCleanupAllowance(runsUsed: freeRunsUsed)
        if case .pro(.appStore) = state { s.storeEntitled = true }
        s.products = [StoreProductInfo(id: StoreProducts.proLifetime, displayName: "DiskLens Pro",
                                       description: "Lifetime unlock", displayPrice: "")]
        return s
    }

    public var gate: FeatureGate { FeatureGate(state: state, edition: edition, now: clock(), freeAllowance: freeAllowance) }
    public func isEnabled(_ f: Feature) -> Bool { gate.isEnabled(f) }
    public var proProduct: StoreProductInfo? { products.first { $0.id == StoreProducts.proLifetime } }

    // MARK: Launch

    /// Call once at launch: `prepare()` then `connect()`.
    public func start() async {
        prepare()
        await connect()
    }

    /// Synchronous part of launch: applies the cached App Store entitlement, the license file and
    /// the trial, so the first frame already shows the right state.
    public func prepare() {
        if edition == .appStore, let cached = try? secure.value(CachedStoreEntitlement.self, for: Self.cacheKey) {
            storeEntitled = true
            storeProductID = cached.productID
        }
        loadLicenseFromFile()
        TrialManager(store: secure).touch(now: clock())
        reload()
    }

    /// Starts listening to transaction updates (StoreKit requires this from launch), then
    /// reconciles with `Transaction.currentEntitlements` and loads the localized price.
    public func connect() async {
        guard edition == .appStore else { return }
        startListening()
        await refreshStoreEntitlements()
        await loadProducts()
    }

    /// Re-reads the trial, free-run counter and license file and recomputes the state.
    public func reload() {
        trial = TrialManager(store: secure).status(now: clock())
        freeAllowance = FreeRunCounter(store: secure).allowance()
        recompute()
    }

    /// Called on the main actor whenever `state` changes (e.g. to re-run Pro-only analysis).
    @ObservationIgnored public var onStateChange: ((LicenseState) -> Void)?

    func recompute() {
        let before = state
        defer { if state != before { onStateChange?(state) } }
        let now = clock()
        if storeEntitled {
            state = .pro(source: .appStore(productID: storeProductID))
        } else if let lic = activeLicense, lic.expiresAt.map({ now < $0 }) ?? true {
            state = .pro(source: lic.proSource)
        } else if edition == .direct, case .active(let expires) = trial {
            state = .trial(expires: expires)
        } else {
            state = .free
        }
    }

    // MARK: App Store (StoreKit 2 via PurchaseStore)

    public func loadProducts() async {
        do {
            products = try await purchaseStore.products(StoreProducts.all)
            productsError = products.isEmpty ? "The App Store did not return the Pro product. Check your connection and try again." : nil
        } catch {
            productsError = "Could not load the price from the App Store: \(error.localizedDescription)"
        }
    }

    func startListening() {
        guard updatesTask == nil else { return }
        let stream = purchaseStore.transactionUpdates()
        updatesTask = Task { [weak self] in
            for await update in stream {
                await self?.handle(update)
            }
        }
    }

    /// Processes one transaction from `Transaction.updates` or a purchase. Unverified transactions
    /// never unlock anything; refunds/revocations re-check the current entitlements.
    func handle(_ v: StoreVerification) async {
        let t = v.transaction
        if EntitlementPolicy.grantsPro(v) {
            setStoreEntitled(t)
        } else if t.productID == StoreProducts.proLifetime && t.revocationDate != nil {
            await refreshStoreEntitlements()
        }
        await purchaseStore.finish(transactionID: t.id)
        purchasePending = false
    }

    private func setStoreEntitled(_ t: StoreTransactionInfo) {
        storeEntitled = true
        storeProductID = t.productID
        try? secure.setValue(CachedStoreEntitlement(productID: t.productID, transactionID: t.id, verifiedAt: clock()), for: Self.cacheKey)
        recompute()
    }

    /// Reconciles with `Transaction.currentEntitlements` (the source of truth; works offline).
    public func refreshStoreEntitlements() async {
        guard edition == .appStore else { return }
        let entitlements = await purchaseStore.currentEntitlements()
        if let granting = entitlements.first(where: EntitlementPolicy.grantsPro) {
            setStoreEntitled(granting.transaction)
        } else {
            storeEntitled = false
            try? secure.set(nil, for: Self.cacheKey)
            recompute()
        }
    }

    public func purchasePro() async -> PurchaseOutcome {
        guard edition == .appStore else { return .productUnavailable }
        if proProduct == nil {
            await loadProducts()
            guard proProduct != nil else { return .productUnavailable }
        }
        isPurchasing = true
        defer { isPurchasing = false }
        do {
            switch try await purchaseStore.purchase(StoreProducts.proLifetime) {
            case .success(let v):
                guard case .verified = v else {
                    await purchaseStore.finish(transactionID: v.transaction.id)
                    if case .unverified(_, let reason) = v { return .unverified(reason) }
                    return .unverified("unknown")
                }
                await handle(v)
                return state.isPaid ? .purchased : .failed("The purchase did not include DiskLens Pro.")
            case .userCancelled:
                return .cancelled
            case .pending:
                purchasePending = true
                return .pending
            }
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// "Restore Purchases": forces a sync with the App Store, then re-reads the entitlements.
    @discardableResult
    public func restorePurchases() async -> Result<Bool, Error> {
        guard edition == .appStore else { return .success(state.isPaid) }
        do {
            try await purchaseStore.syncWithAppStore()
            await refreshStoreEntitlements()
            return .success(storeEntitled)
        } catch {
            await refreshStoreEntitlements()
            return .failure(error)
        }
    }

    // MARK: License keys (direct edition)

    func loadLicenseFromFile() {
        guard edition == .direct, let text = licenseFile?.load() else { activeLicense = nil; licenseProblem = nil; return }
        do {
            activeLicense = try verifier.verify(text, now: clock(), machineHash: machineHash)
            licenseProblem = nil
        } catch {
            activeLicense = nil
            licenseProblem = (error as? LicenseKeyError)?.description ?? error.localizedDescription
        }
    }

    /// Verifies the key offline and stores it. Throws `LicenseKeyError` without storing anything
    /// when the key is invalid.
    @discardableResult
    public func activate(licenseKey text: String) throws -> LicensePayload {
        let payload = try verifier.verify(text, now: clock(), machineHash: machineHash)
        try licenseFile?.save(text.filter { !$0.isWhitespace })
        activeLicense = payload
        licenseProblem = nil
        recompute()
        return payload
    }

    public func deactivateLicense() throws {
        try licenseFile?.remove()
        activeLicense = nil
        licenseProblem = nil
        recompute()
    }

    // MARK: Trial and free run

    /// Starts the direct edition's one-time 7-day trial.
    public func startTrial() throws {
        guard edition == .direct else { return }
        try TrialManager(store: secure).start(now: clock())
        reload()
    }

    /// Reserves the free cleanup run before executing it. Throws (and the run must not happen)
    /// if the counter cannot be persisted.
    public func reserveFreeRun() throws {
        try FreeRunCounter(store: secure).consume()
        freeAllowance = FreeRunCounter(store: secure).allowance()
    }

    public func refundFreeRun() {
        FreeRunCounter(store: secure).refund()
        freeAllowance = FreeRunCounter(store: secure).allowance()
    }
}
