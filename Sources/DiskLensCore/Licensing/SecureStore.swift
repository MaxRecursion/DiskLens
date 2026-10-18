import Foundation
import Security

/// Small key–value store for entitlement bookkeeping (trial start, free-run counter, cached
/// StoreKit entitlement). The app uses the Keychain so the values survive deleting preferences;
/// tests and offscreen snapshots use the in-memory store and never touch the user's Keychain.
public protocol SecureStore: Sendable {
    /// nil when the key has never been written. Throws when the store cannot be read (callers
    /// treat that as "unknown" and fail closed for anything that grants access).
    func data(for key: String) throws -> Data?
    func set(_ data: Data?, for key: String) throws
}

public extension SecureStore {
    func value<T: Decodable>(_ type: T.Type, for key: String) throws -> T? {
        guard let d = try data(for: key) else { return nil }
        return try SecureStoreCoding.decoder.decode(T.self, from: d)
    }
    func setValue<T: Encodable>(_ value: T?, for key: String) throws {
        try set(value.map { try SecureStoreCoding.encoder.encode($0) }, for: key)
    }
}

enum SecureStoreCoding {
    static let encoder: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.sortedKeys]; return e }()
    static let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()
}

public enum SecureStoreError: Error, Equatable, CustomStringConvertible {
    case keychain(OSStatus)
    public var description: String {
        switch self {
        case .keychain(let s): return "Keychain error \(s): \((SecCopyErrorMessageString(s, nil) as String?) ?? "unknown")"
        }
    }
}

/// Generic-password items in the login Keychain, this device only, never synced to iCloud.
public struct KeychainStore: SecureStore {
    public var service: String
    public init(service: String = "com.akshaykulkarni.DiskLens.entitlements") { self.service = service }

    func base(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: key,
         kSecAttrSynchronizable as String: kCFBooleanFalse as Any]
    }

    public func data(for key: String) throws -> Data? {
        var q = base(key)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let s = SecItemCopyMatching(q as CFDictionary, &out)
        if s == errSecItemNotFound { return nil }
        guard s == errSecSuccess else { throw SecureStoreError.keychain(s) }
        return out as? Data
    }

    public func set(_ data: Data?, for key: String) throws {
        guard let data else {
            let s = SecItemDelete(base(key) as CFDictionary)
            guard s == errSecSuccess || s == errSecItemNotFound else { throw SecureStoreError.keychain(s) }
            return
        }
        let update = [kSecValueData as String: data]
        var s = SecItemUpdate(base(key) as CFDictionary, update as CFDictionary)
        if s == errSecItemNotFound {
            var add = base(key)
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            add[kSecAttrLabel as String] = "DiskLens entitlement data"
            s = SecItemAdd(add as CFDictionary, nil)
        }
        guard s == errSecSuccess else { throw SecureStoreError.keychain(s) }
    }
}

/// Process-local store for tests, previews and offscreen snapshots.
public final class InMemorySecureStore: SecureStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data] = [:]
    /// When set, every read and write throws (simulates a locked/unavailable Keychain).
    public var failing = false
    public init() {}
    public func data(for key: String) throws -> Data? {
        lock.lock(); defer { lock.unlock() }
        if failing { throw SecureStoreError.keychain(errSecInteractionNotAllowed) }
        return items[key]
    }
    public func set(_ data: Data?, for key: String) throws {
        lock.lock(); defer { lock.unlock() }
        if failing { throw SecureStoreError.keychain(errSecInteractionNotAllowed) }
        items[key] = data
    }
}

// MARK: - Trial

public enum TrialStatus: Equatable, Sendable {
    case notStarted
    case active(expires: Date)
    case expired(expired: Date)
    /// The Keychain could not be read: no trial is granted (fail closed), nothing else is affected.
    case unavailable
}

/// The direct edition's 7-day full trial. Started explicitly by the user, at most once per Mac
/// user account; stored in the Keychain. The clock is never allowed to run backwards: the latest
/// time ever seen is remembered, so setting the date back does not extend the trial.
public struct TrialManager: Sendable {
    public static let length: TimeInterval = 7 * 86_400
    static let key = "trial.v1"

    struct Record: Codable, Equatable {
        var startedAt: Date
        var lastSeen: Date
    }

    public var store: any SecureStore
    public init(store: any SecureStore) { self.store = store }

    public func status(now: Date = Date()) -> TrialStatus {
        let record: Record?
        do { record = try store.value(Record.self, for: Self.key) } catch { return .unavailable }
        guard let record else { return .notStarted }
        let expires = record.startedAt.addingTimeInterval(Self.length)
        let effectiveNow = max(now, record.lastSeen)
        return effectiveNow < expires ? .active(expires: expires) : .expired(expired: expires)
    }

    /// Starts the trial if it has never been started. Never restarts an existing or expired trial.
    @discardableResult
    public func start(now: Date = Date()) throws -> TrialStatus {
        if case .notStarted = status(now: now) {
            try store.setValue(Record(startedAt: now, lastSeen: now), for: Self.key)
        }
        return status(now: now)
    }

    /// Records that `now` has been observed (call at launch and when the trial is checked).
    public func touch(now: Date = Date()) {
        guard var r = try? store.value(Record.self, for: Self.key), now > r.lastSeen else { return }
        r.lastSeen = now
        try? store.setValue(r, for: Self.key)
    }
}

// MARK: - Free cleanup run counter

/// Persists how many free one-click cleanup runs were used. Reading failures count as "used"
/// (fail closed); this only ever limits the free run, never a safety feature or a dry run.
public struct FreeRunCounter: Sendable {
    static let key = "free-cleanup-runs.v1"
    public var store: any SecureStore
    public init(store: any SecureStore) { self.store = store }

    public func allowance() -> FreeCleanupAllowance {
        do { return try store.value(FreeCleanupAllowance.self, for: Self.key) ?? FreeCleanupAllowance() }
        catch { return FreeCleanupAllowance(runsUsed: FreeCleanupAllowance.runsIncluded) }
    }

    /// Reserves the free run before executing (if this throws, do not execute).
    public func consume() throws {
        var a = allowance()
        a.runsUsed += 1
        try store.setValue(a, for: Self.key)
    }

    /// Gives the run back when it removed nothing (every item skipped or failed), so the user
    /// still gets to experience a real result.
    public func refund() {
        var a = allowance()
        guard a.runsUsed > 0 else { return }
        a.runsUsed -= 1
        try? store.setValue(a, for: Self.key)
    }
}
