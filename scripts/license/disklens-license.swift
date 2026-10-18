// DiskLens license-key tool — NEVER bundled with the app. Run it on the machine that holds the
// private signing key (ideally offline), or port the 20 lines of `issue` to your payment
// provider's webhook (Paddle / Lemon Squeezy / FastSpring fulfilment).
//
//   swiftc -O scripts/license/disklens-license.swift -o /tmp/disklens-license
//   /tmp/disklens-license keygen --out .signing
//   /tmp/disklens-license issue --key .signing/license-signing.key --email buyer@example.com --edition pro
//   /tmp/disklens-license issue --key .signing/license-signing.key --email ci@example.com --edition team --seats 10 --years 1
//   /tmp/disklens-license verify --public <base64> --license-file key.txt
//
// Key format (must match Sources/DiskLensCore/Licensing/LicenseKey.swift):
//   DLK1.<base64url(payload JSON)>.<base64url(Ed25519 signature over "DLK1.<base64url(payload JSON)>")>
import Foundation
import CryptoKit

func fail(_ s: String) -> Never { FileHandle.standardError.write(Data((s + "\n").utf8)); exit(2) }
let args = Array(CommandLine.arguments.dropFirst())
func value(_ f: String) -> String? { args.firstIndex(of: f).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
func values(_ f: String) -> [String] { args.enumerated().compactMap { $0.element == f && $0.offset + 1 < args.count ? args[$0.offset + 1] : nil } }
func b64url(_ d: Data) -> String {
    d.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
}
func unb64url(_ s: String) -> Data? {
    var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    while b.count % 4 != 0 { b += "=" }
    return Data(base64Encoded: b)
}

struct Payload: Codable {
    var v = 1
    var product = "disklens"
    var licenseID: String
    var edition: String
    var emailHash: String
    var seats: Int
    var issuedAt: Date
    var expiresAt: Date?
    var machineHashes: [String]?
}

switch args.first {
case "keygen":
    let dir = value("--out") ?? ".signing"
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let path = dir + "/license-signing.key"
    if FileManager.default.fileExists(atPath: path) { fail("Refusing to overwrite existing \(path). Move it away first.") }
    let key = Curve25519.Signing.PrivateKey()
    guard FileManager.default.createFile(atPath: path, contents: Data(key.rawRepresentation.base64EncodedString().utf8),
                                         attributes: [.posixPermissions: 0o600]) else { fail("Could not write \(path)") }
    print("Private signing key written to \(path) (mode 0600). Keep it secret and back it up offline.")
    print("Public key (paste into LicenseKey.embeddedPublicKey):")
    print(key.publicKey.rawRepresentation.base64EncodedString())

case "issue":
    guard let keyPath = value("--key"), let email = value("--email"), let edition = value("--edition"),
          ["pro", "team"].contains(edition) else {
        fail("usage: issue --key FILE --email EMAIL --edition pro|team [--seats N] [--years N | --expires YYYY-MM-DD] [--machine HASH]...")
    }
    guard let raw = try? String(contentsOfFile: keyPath, encoding: .utf8),
          let rawData = Data(base64Encoded: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
          let priv = try? Curve25519.Signing.PrivateKey(rawRepresentation: rawData) else { fail("Cannot read private key \(keyPath)") }
    let now = Date()
    var expires: Date? = nil
    if let e = value("--expires") {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withFullDate]
        guard let d = f.date(from: e) else { fail("--expires must be YYYY-MM-DD") }
        expires = d
    } else if let y = value("--years"), let n = Int(y) {
        expires = Calendar(identifier: .gregorian).date(byAdding: .year, value: n, to: now)
    }
    if edition == "team" && expires == nil { expires = Calendar(identifier: .gregorian).date(byAdding: .year, value: 1, to: now) }
    let norm = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let hash = SHA256.hash(data: Data(norm.utf8)).map { String(format: "%02x", $0) }.joined()
    let machines = values("--machine")
    let p = Payload(licenseID: value("--id") ?? UUID().uuidString, edition: edition, emailHash: hash,
                    seats: Int(value("--seats") ?? "1") ?? 1, issuedAt: now, expiresAt: expires,
                    machineHashes: machines.isEmpty ? nil : machines)
    let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.sortedKeys]
    let body = "DLK1." + b64url(try enc.encode(p))
    let sig = try priv.signature(for: Data(body.utf8))
    print(body + "." + b64url(sig))

case "verify":
    guard let pub = value("--public"), let file = value("--license-file"),
          let pubData = Data(base64Encoded: pub), let pk = try? Curve25519.Signing.PublicKey(rawRepresentation: pubData),
          let text = try? String(contentsOfFile: file, encoding: .utf8) else { fail("usage: verify --public BASE64 --license-file FILE") }
    let parts = text.filter { !$0.isWhitespace }.split(separator: ".")
    guard parts.count == 3, let sig = unb64url(String(parts[2])), let payload = unb64url(String(parts[1])) else { fail("malformed key") }
    let ok = pk.isValidSignature(sig, for: Data("\(parts[0]).\(parts[1])".utf8))
    print(ok ? "signature: valid" : "signature: INVALID")
    print(String(decoding: payload, as: UTF8.self))
    exit(ok ? 0 : 1)

default:
    fail("usage: disklens-license keygen|issue|verify (see header comment)")
}
