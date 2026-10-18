import Foundation
import CryptoKit
import IOKit

/// Contents of a direct-edition license key. It identifies the buyer only by a SHA-256 hash of
/// their e-mail address (so a key never contains personal data in clear text).
public struct LicensePayload: Codable, Sendable, Equatable {
    /// Payload format version.
    public var v: Int
    public var product: String
    public var licenseID: String
    public var edition: LicenseEdition
    /// Hex SHA-256 of the lower-cased, trimmed purchaser e-mail.
    public var emailHash: String
    /// Number of Macs the license covers (Team); 1 for personal Pro.
    public var seats: Int
    public var issuedAt: Date
    /// Required for Team (yearly); nil for lifetime Pro.
    public var expiresAt: Date?
    /// Optional per-machine binding: hashes from `MachineIdentity.hash()` the key is valid on.
    public var machineHashes: [String]?

    public init(v: Int = 1, product: String = LicenseKey.product, licenseID: String, edition: LicenseEdition,
                emailHash: String, seats: Int = 1, issuedAt: Date, expiresAt: Date? = nil, machineHashes: [String]? = nil) {
        self.v = v; self.product = product; self.licenseID = licenseID; self.edition = edition
        self.emailHash = emailHash; self.seats = seats; self.issuedAt = issuedAt; self.expiresAt = expiresAt
        self.machineHashes = machineHashes
    }

    public static func emailHash(_ email: String) -> String {
        let norm = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return SHA256.hash(data: Data(norm.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public var proSource: ProSource { .licenseKey(edition: edition, expires: expiresAt) }
}

public enum LicenseKeyError: Error, Equatable, CustomStringConvertible, Sendable {
    case malformed
    case unsupportedVersion(Int)
    case badSignature
    case wrongProduct(String)
    case expired(Date)
    case notYetValid(Date)
    case teamLicenseWithoutExpiry
    case notValidOnThisMac

    public var description: String {
        switch self {
        case .malformed: return "This is not a DiskLens license key. Paste the whole key, starting with “DLK1.”."
        case .unsupportedVersion(let v): return "This license key uses format version \(v), which this version of DiskLens does not understand. Update DiskLens."
        case .badSignature: return "The license key's signature is not valid. It may have been mistyped or altered."
        case .wrongProduct(let p): return "This license key is for a different product (\(p))."
        case .expired(let d): return "This license expired on \(d.formatted(date: .abbreviated, time: .omitted)). Renew it to keep Team features."
        case .notYetValid(let d): return "This license key is dated \(d.formatted(date: .abbreviated, time: .omitted)), which is in the future. Check the Mac's date and time."
        case .teamLicenseWithoutExpiry: return "This Team license key has no expiry date, which is not allowed."
        case .notValidOnThisMac: return "This license key is bound to other Macs."
        }
    }
}

/// Offline verification of Ed25519-signed license keys.
///
/// Key format: `DLK1.<base64url(payload JSON)>.<base64url(Ed25519 signature)>`, where the signature
/// covers the ASCII bytes `DLK1.<base64url(payload JSON)>`. Only the public key is embedded in the
/// app; keys are minted by `scripts/license/disklens-license.swift`, which is never bundled.
public struct LicenseKey: Sendable {
    public static let prefix = "DLK1"
    public static let product = "disklens"
    /// Production verification key (raw 32-byte Ed25519 public key, base64). Rotate it with
    /// `scripts/license/disklens-license.swift keygen` before launch; see docs/LICENSING.md.
    public static let embeddedPublicKey = "T7b5jt19IEYU8ELVmdUmo4hhmEqt6pXtJhr/mMnRqPo="
    /// Small allowance for clocks that are slightly behind the issuer's.
    public static let clockSkew: TimeInterval = 48 * 3600

    public var publicKey: Curve25519.Signing.PublicKey

    public init(publicKey: Curve25519.Signing.PublicKey) { self.publicKey = publicKey }

    public static func embedded() -> LicenseKey {
        let raw = Data(base64Encoded: embeddedPublicKey)!
        return LicenseKey(publicKey: try! Curve25519.Signing.PublicKey(rawRepresentation: raw))
    }

    /// Parses and verifies a key. Whitespace and line breaks (from e-mail clients) are ignored.
    public func verify(_ text: String, now: Date = Date(), machineHash: String? = MachineIdentity.hash()) throws -> LicensePayload {
        let key = text.filter { !$0.isWhitespace }
        let parts = key.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == Self.prefix,
              let payloadData = Base64URL.decode(String(parts[1])),
              let sig = Base64URL.decode(String(parts[2])), sig.count == 64 else { throw LicenseKeyError.malformed }
        let signed = Data("\(parts[0]).\(parts[1])".utf8)
        guard publicKey.isValidSignature(sig, for: signed) else { throw LicenseKeyError.badSignature }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        guard let payload = try? dec.decode(LicensePayload.self, from: payloadData) else { throw LicenseKeyError.malformed }
        guard payload.v == 1 else { throw LicenseKeyError.unsupportedVersion(payload.v) }
        guard payload.product == Self.product else { throw LicenseKeyError.wrongProduct(payload.product) }
        if payload.edition == .team && payload.expiresAt == nil { throw LicenseKeyError.teamLicenseWithoutExpiry }
        if payload.issuedAt > now.addingTimeInterval(Self.clockSkew) { throw LicenseKeyError.notYetValid(payload.issuedAt) }
        if let exp = payload.expiresAt, now >= exp { throw LicenseKeyError.expired(exp) }
        if let machines = payload.machineHashes, !machines.isEmpty {
            guard let machineHash, machines.contains(machineHash) else { throw LicenseKeyError.notValidOnThisMac }
        }
        return payload
    }
}

public enum Base64URL {
    public static func encode(_ d: Data) -> String {
        d.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
    public static func decode(_ s: String) -> Data? {
        guard !s.isEmpty, s.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else { return nil }
        var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b.count % 4 != 0 { b += "=" }
        return Data(base64Encoded: b)
    }
}

/// A stable, non-reversible identifier of this Mac for optional per-machine license binding:
/// SHA-256 of a fixed prefix and the hardware platform UUID. The UUID itself is never stored or shown.
public enum MachineIdentity {
    public static func hash() -> String? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard let uuid = IORegistryEntryCreateCFProperty(service, kIOPlatformUUIDKey as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String else { return nil }
        return SHA256.hash(data: Data("disklens-machine-v1:\(uuid)".utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// Stores the activated license key for the direct edition and the CLI (shared location, 0600).
/// A file is used instead of the Keychain so headless CI machines without an unlocked login
/// Keychain can use Team licenses. The key is signed, so editing the file cannot forge a license.
public struct LicenseFileStore: Sendable {
    public var url: URL
    public init(directory: URL = ScanStore().directory) { url = directory.appendingPathComponent("license.dlk") }

    public static func fromEnvironment() -> LicenseFileStore {
        if let p = ProcessInfo.processInfo.environment["DISKLENS_LICENSE_FILE"], !p.isEmpty {
            var s = LicenseFileStore(); s.url = URL(fileURLWithPath: (p as NSString).expandingTildeInPath); return s
        }
        return LicenseFileStore()
    }

    public func load() -> String? { try? String(contentsOf: url, encoding: .utf8) }

    public func save(_ key: String) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let tmp = url.appendingPathExtension("tmp")
        try? FileManager.default.removeItem(at: tmp)
        guard FileManager.default.createFile(atPath: tmp.path, contents: Data(key.utf8), attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        } else {
            try FileManager.default.moveItem(at: tmp, to: url)
        }
    }

    public func remove() throws {
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
}
