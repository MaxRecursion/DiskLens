import Foundation

/// StoreKit-free description of the App Store, so purchase logic is unit-tested without StoreKit.
/// The app's `StoreKitPurchaseStore` maps StoreKit 2's `Product`, `Transaction` and
/// `VerificationResult` onto these types; tests use a scripted fake.
public struct StoreProductInfo: Sendable, Equatable, Identifiable {
    public var id: String
    public var displayName: String
    public var description: String
    /// Localized price exactly as StoreKit formats it (`Product.displayPrice`). Never computed here.
    public var displayPrice: String
    public init(id: String, displayName: String, description: String, displayPrice: String) {
        self.id = id; self.displayName = displayName; self.description = description; self.displayPrice = displayPrice
    }
}

public enum StoreOwnership: String, Sendable, Codable {
    case purchased
    case familyShared
}

public struct StoreTransactionInfo: Sendable, Equatable {
    public var id: UInt64
    public var productID: String
    public var purchaseDate: Date
    /// Set when Apple refunded or revoked the purchase.
    public var revocationDate: Date?
    public var ownership: StoreOwnership
    public init(id: UInt64, productID: String, purchaseDate: Date, revocationDate: Date? = nil, ownership: StoreOwnership = .purchased) {
        self.id = id; self.productID = productID; self.purchaseDate = purchaseDate
        self.revocationDate = revocationDate; self.ownership = ownership
    }
}

/// Mirrors StoreKit's `VerificationResult`: only `.verified` transactions ever grant anything.
public enum StoreVerification: Sendable, Equatable {
    case verified(StoreTransactionInfo)
    case unverified(StoreTransactionInfo, reason: String)

    public var transaction: StoreTransactionInfo {
        switch self { case .verified(let t), .unverified(let t, _): return t }
    }
}

public enum StorePurchaseResult: Sendable, Equatable {
    case success(StoreVerification)
    case userCancelled
    /// Awaiting approval (Ask to Buy, SCA). The result arrives later through `transactionUpdates`.
    case pending
}

public protocol PurchaseStore: Sendable {
    func products(_ ids: [String]) async throws -> [StoreProductInfo]
    func purchase(_ productID: String) async throws -> StorePurchaseResult
    /// StoreKit 2 `Transaction.currentEntitlements` (works offline from the on-device receipt).
    func currentEntitlements() async -> [StoreVerification]
    /// StoreKit 2 `Transaction.updates`. Must be listened to from launch.
    func transactionUpdates() -> AsyncStream<StoreVerification>
    func finish(transactionID: UInt64) async
    /// `AppStore.sync()` — the "Restore Purchases" button.
    func syncWithAppStore() async throws
}

/// Used where no App Store exists (direct edition, CLI, tests of other features).
public struct NoPurchaseStore: PurchaseStore {
    public init() {}
    public func products(_ ids: [String]) async throws -> [StoreProductInfo] { [] }
    public func purchase(_ productID: String) async throws -> StorePurchaseResult { .userCancelled }
    public func currentEntitlements() async -> [StoreVerification] { [] }
    public func transactionUpdates() -> AsyncStream<StoreVerification> { AsyncStream { $0.finish() } }
    public func finish(transactionID: UInt64) async {}
    public func syncWithAppStore() async throws {}
}

/// Product identifiers. Prices are set in App Store Connect and shown via `displayPrice` only.
public enum StoreProducts {
    public static let proLifetime = "pro.lifetime"
    public static let all = [proLifetime]
}

/// Decides whether a transaction grants Pro. Family Sharing is enabled for the lifetime unlock
/// (see docs/LICENSING.md), so family-shared transactions count the same as purchases.
public enum EntitlementPolicy {
    public static let familySharingEnabled = true

    public static func grantsPro(_ v: StoreVerification) -> Bool {
        guard case .verified(let t) = v else { return false }
        guard t.productID == StoreProducts.proLifetime, t.revocationDate == nil else { return false }
        return t.ownership == .purchased || familySharingEnabled
    }
}

/// Last verified App Store entitlement, cached (Keychain) so the app shows the right state
/// instantly at launch and while offline, until StoreKit's own answer arrives.
struct CachedStoreEntitlement: Codable, Equatable {
    var productID: String
    var transactionID: UInt64
    var verifiedAt: Date
}
