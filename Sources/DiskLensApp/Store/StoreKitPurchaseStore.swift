import Foundation
import AppKit
import StoreKit
import DiskLensCore

/// StoreKit 2 implementation of `PurchaseStore` (Mac App Store edition). All decisions about
/// what a transaction grants live in DiskLensCore (`LicenseService`, `EntitlementPolicy`) and are
/// unit-tested with a fake; this adapter only translates StoreKit types.
@MainActor
final class StoreKitPurchaseStore: PurchaseStore {
    private var products: [String: Product] = [:]
    /// Transactions handed out but not yet finished (finish() needs the StoreKit object).
    private var unfinished: [UInt64: Transaction] = [:]

    enum StoreError: LocalizedError {
        case productNotFound(String)
        var errorDescription: String? {
            switch self { case .productNotFound(let id): return "The App Store did not return the product \(id)." }
        }
    }

    func products(_ ids: [String]) async throws -> [StoreProductInfo] {
        let found = try await Product.products(for: ids)
        for p in found { products[p.id] = p }
        return found.map { StoreProductInfo(id: $0.id, displayName: $0.displayName, description: $0.description, displayPrice: $0.displayPrice) }
    }

    func purchase(_ productID: String) async throws -> StorePurchaseResult {
        var product = products[productID]
        if product == nil { product = try await Product.products(for: [productID]).first }
        guard let product else { throw StoreError.productNotFound(productID) }
        let result: Product.PurchaseResult
        if #available(macOS 15.2, *), let window = NSApp.keyWindow ?? NSApp.mainWindow {
            result = try await product.purchase(confirmIn: window)
        } else {
            result = try await product.purchase()
        }
        switch result {
        case .success(let v): return .success(map(v))
        case .userCancelled: return .userCancelled
        case .pending: return .pending
        @unknown default: return .userCancelled
        }
    }

    func currentEntitlements() async -> [StoreVerification] {
        var out: [StoreVerification] = []
        for await v in Transaction.currentEntitlements { out.append(map(v, keepForFinish: false)) }
        return out
    }

    nonisolated func transactionUpdates() -> AsyncStream<StoreVerification> {
        AsyncStream { continuation in
            let task = Task { @MainActor [weak self] in
                for await v in Transaction.updates {
                    guard let self else { break }
                    continuation.yield(self.map(v))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func finish(transactionID: UInt64) async {
        if let t = unfinished.removeValue(forKey: transactionID) { await t.finish() }
    }

    func syncWithAppStore() async throws { try await AppStore.sync() }

    private func map(_ v: VerificationResult<Transaction>, keepForFinish: Bool = true) -> StoreVerification {
        switch v {
        case .verified(let t):
            if keepForFinish { unfinished[t.id] = t }
            return .verified(info(t))
        case .unverified(let t, let error):
            if keepForFinish { unfinished[t.id] = t }
            return .unverified(info(t), reason: error.localizedDescription)
        }
    }

    private func info(_ t: Transaction) -> StoreTransactionInfo {
        StoreTransactionInfo(id: t.id, productID: t.productID, purchaseDate: t.purchaseDate, revocationDate: t.revocationDate,
                             ownership: t.ownershipType == .familyShared ? .familyShared : .purchased)
    }
}
