/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import CryptoKit
import Foundation
import Testing
@testable import TabMail

private func hex(_ data: Data) -> String {
    data.map { String(format: "%02x", $0) }.joined()
}

private func openEnvelope(_ wire: String, with key: Curve25519.KeyAgreement.PrivateKey, aad: Data) throws -> Data {
    try SyntheticProxyKey.open(wire, with: key, aad: aad)
}

/// File types a target's build reads as text: sources, headers, plists and configs.
private let fencedExtensions: Set<String> = ["swift", "h", "m", "mm", "c", "plist", "entitlements", "xcconfig"]

private enum FenceError: Error { case missingRoot(String), walk([String]) }

/// The errors a directory walk reports, collected from the enumerator's handler.
private final class FenceWalkErrors: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func add(_ item: String) { lock.lock(); items.append(item); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return items }
}

/// Reads every fenced file under `root`; returns the paths read and those naming `marker`.
/// A missing root, a traversal error or an unreadable file fails the scan.
private func scanForMarker(_ marker: String, under root: URL) throws -> (scanned: [String], hits: [String]) {
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
        throw FenceError.missingRoot(root.lastPathComponent)
    }
    let errors = FenceWalkErrors()
    guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil,
        errorHandler: { url, error in errors.add("\(url.path): \(error)"); return false }) else {
        throw FenceError.missingRoot(root.lastPathComponent)
    }
    var scanned: [String] = [], hits: [String] = []
    for case let file as URL in walker where fencedExtensions.contains(file.pathExtension) {
        let text = try String(contentsOf: file, encoding: .utf8)
        scanned.append(file.path)
        if text.contains(marker) { hits.append(file.path) }
    }
    if !errors.all.isEmpty { throw FenceError.walk(errors.all) }
    return (scanned, hits)
}

struct IMAPAuthorityCredentialTests {
    private let keyA: Curve25519.KeyAgreement.PrivateKey
    private let keyB: Curve25519.KeyAgreement.PrivateKey
    private let payload = IMAPCredPayload(host: "imap.example.test", port: 993,
        username: "synthetic", password: "synthetic-password", security: "tls")

    init() throws {
        keyA = try SyntheticProxyKey.a()
        keyB = try SyntheticProxyKey.b()
    }

    private func context(device: String = "device-a") -> IMAPSubscribeContext {
        IMAPSubscribeContext(userId: "user-a", deviceId: device,
            accountEmail: "mail@example.test", deviceToken: "token-a",
            apnsSandbox: false, nseCapable: true)
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    @Test func exactOrderedJSON() throws {
        let expected = #"["tabmail-imap-subscribe-v2","user-a","device-a","imap","mail@example.test","token-a",false,true]"#
        #expect(try context().credentialContext() == Data(expected.utf8))
    }

    @Test func unifiedBodyContainsExistingDeviceAndInboxFieldsOnly() throws {
        let envelope = try IMAPCredCrypto.sealAuthorityPayload(payload, context: context(), to: keyA.publicKey)
        let bytes = try context().requestBody(credentialEnvelope: envelope)
        let object = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        #expect(Set(object.keys) == Set(["protocolVersion", "userId", "deviceId", "provider",
            "accountEmail", "deviceToken", "apnsSandbox", "nseCapable", "credsCiphertext"]))
        #expect(object["protocolVersion"] as? Int == 2)
        #expect(object["userId"] as? String == "user-a")
        #expect(object["deviceId"] as? String == "device-a")
        #expect(object["provider"] as? String == "imap")
        #expect(object["accountEmail"] as? String == "mail@example.test")
        #expect(object["deviceToken"] as? String == "token-a")
        #expect(object["apnsSandbox"] as? Bool == false)
        #expect(object["nseCapable"] as? Bool == true)
        #expect(object["credsCiphertext"] as? String == envelope)
        #expect(String(decoding: bytes, as: UTF8.self).contains(payload.password) == false)
    }

    /// A sealed frame builds a request; the same frame under another version, an empty
    /// frame, and one byte over the 65,536-byte cap do not. The cap itself is allowed.
    @Test func requestTakesOnlyV3WithinTheCap() throws {
        let frame = try IMAPCredCrypto.sealAuthorityPayload(payload, context: context(), to: keyA.publicKey)
        let sealed = String(frame.dropFirst(3))
        let built = try context().requestBody(credentialEnvelope: frame)
        let object = try #require(JSONSerialization.jsonObject(with: built) as? [String: Any])
        #expect(object["credsCiphertext"] as? String == frame)
        for version in ["v1:", "v2:", "v4:", "V3:", "v3", ""] {
            #expect(throws: IMAPCredCryptoError.invalidContext, "\(version)") {
                try context().requestBody(credentialEnvelope: version + sealed)
            }
        }
        #expect(throws: IMAPCredCryptoError.invalidContext) { try context().requestBody(credentialEnvelope: "v3:") }
        #expect(throws: IMAPCredCryptoError.invalidContext) { try context().requestBody(credentialEnvelope: "") }
        let atCap = "v3:" + String(repeating: "A", count: 65_533)
        #expect(atCap.utf8.count == 65_536)
        let capBody = try context().requestBody(credentialEnvelope: atCap)
        let capObject = try #require(JSONSerialization.jsonObject(with: capBody) as? [String: Any])
        #expect(capObject["credsCiphertext"] as? String == atCap)
        #expect(throws: IMAPCredCryptoError.invalidContext) {
            try context().requestBody(credentialEnvelope: atCap + "A")
        }
    }

    /// A real seal's length moves in steps of four base64 characters, so the longest
    /// one within the cap is 65,535 bytes and the next is 65,539. Both are sealed for
    /// real: the first builds a request and the second does not.
    @Test func genuineSealsAtTheWireBoundary() throws {
        func credentials(password: String) -> IMAPCredPayload {
            IMAPCredPayload(host: payload.host, port: payload.port, username: payload.username,
                password: password, security: payload.security)
        }
        let unpadded = try JSONEncoder().encode(credentials(password: "")).count
        // 49,149 framed bytes (key id 8, encapsulated key 32, plaintext, tag 16)
        // encode to 65,532 base64 characters, 65,535 bytes with the prefix.
        let longestPassword = 49_149 - 8 - 32 - 16 - unpadded
        let within = try IMAPCredCrypto.sealAuthorityPayload(
            credentials(password: String(repeating: "a", count: longestPassword)), context: context(), to: keyA.publicKey)
        let withinBytes = within.utf8.count
        #expect(withinBytes == 65_535)
        let built = try context().requestBody(credentialEnvelope: within)
        let object = try #require(JSONSerialization.jsonObject(with: built) as? [String: Any])
        #expect(object["credsCiphertext"] as? String == within)
        let over = try IMAPCredCrypto.sealAuthorityPayload(
            credentials(password: String(repeating: "a", count: longestPassword + 1)), context: context(), to: keyA.publicKey)
        let overBytes = over.utf8.count
        #expect(overBytes == 65_539)
        #expect(throws: IMAPCredCryptoError.invalidContext) {
            try context().requestBody(credentialEnvelope: over)
        }
    }

    @Test func onlyExplicitActiveResponseReportsRestored() {
        let active = Data(#"{"outcome":"active"}"#.utf8)
        let pending = Data(#"{"outcome":"in_progress"}"#.utf8)
        #expect(IMAPSubscribeOutcome.decode(statusCode: 200, body: active) == .active)
        #expect(IMAPSubscribeOutcome.decode(statusCode: 202, body: pending) == .inProgress)
        #expect(IMAPSubscribeOutcome.decode(statusCode: 429, body: Data()) == .cooldown)
        for code in [200, 201, 202, 204, 400, 401, 403, 500, 503] {
            #expect(IMAPSubscribeOutcome.decode(statusCode: code, body: Data()) == .refused)
            if code != 200 { #expect(IMAPSubscribeOutcome.decode(statusCode: code, body: active) == .refused) }
            if code != 202 { #expect(IMAPSubscribeOutcome.decode(statusCode: code, body: pending) == .refused) }
        }
    }

    @Test func onlyTheRecipientKeyOpensAFreshlyEncapsulatedEnvelope() throws {
        let a = try IMAPCredCrypto.sealAuthorityPayload(payload, context: context(), to: keyA.publicKey)
        let b = try IMAPCredCrypto.sealAuthorityPayload(payload, context: context(), to: keyA.publicKey)
        #expect(a.hasPrefix("v3:"))
        let packed = try #require(Data(base64Encoded: String(a.dropFirst(3))))
        let other = try #require(Data(base64Encoded: String(b.dropFirst(3))))
        #expect(packed.prefix(8) == IMAPCredCrypto.keyId(of: keyA.publicKey))
        #expect(packed.dropFirst(8).prefix(32) != other.dropFirst(8).prefix(32))
        let aad = try context().credentialContext()
        let opened = try openEnvelope(a, with: keyA, aad: aad)
        let decoded = try JSONDecoder().decode(IMAPCredPayload.self, from: opened)
        #expect(decoded.host == payload.host && decoded.port == payload.port)
        #expect(decoded.username == payload.username && decoded.password == payload.password)
        #expect(decoded.security == payload.security)
        #expect(String(decoding: packed, as: UTF8.self).contains(payload.password) == false)
        #expect(throws: (any Error).self) { try openEnvelope(a, with: keyA, aad: Data()) }
        #expect(throws: (any Error).self) { try openEnvelope(a, with: keyB, aad: aad) }
    }

    /// Each recipient gets a header naming it and opens only its own envelope; the other
    /// key fails at the HPKE open itself (the opener does not pick a key by id).
    @Test func eachRecipientOpensOnlyItsOwnEnvelope() throws {
        let aad = try context().credentialContext()
        let toA = try IMAPCredCrypto.sealAuthorityPayload(payload, context: context(), to: keyA.publicKey)
        let toB = try IMAPCredCrypto.sealAuthorityPayload(payload, context: context(), to: keyB.publicKey)
        let packedA = try #require(Data(base64Encoded: String(toA.dropFirst(3))))
        let packedB = try #require(Data(base64Encoded: String(toB.dropFirst(3))))
        #expect(packedA.prefix(8) == IMAPCredCrypto.keyId(of: keyA.publicKey))
        #expect(packedB.prefix(8) == IMAPCredCrypto.keyId(of: keyB.publicKey))
        let openedA = try JSONDecoder().decode(IMAPCredPayload.self, from: openEnvelope(toA, with: keyA, aad: aad))
        let openedB = try JSONDecoder().decode(IMAPCredPayload.self, from: openEnvelope(toB, with: keyB, aad: aad))
        #expect(openedA.password == payload.password && openedB.password == payload.password)
        #expect(throws: (any Error).self) { try openEnvelope(toA, with: keyB, aad: aad) }
        #expect(throws: (any Error).self) { try openEnvelope(toB, with: keyA, aad: aad) }
    }

    @Test(arguments: ["", "not base64!", Data(repeating: 7, count: 31).base64EncodedString(),
        Data(repeating: 7, count: 33).base64EncodedString()])
    func malformedProxyKeyRefuses(encoded: String) throws {
        #expect(throws: IMAPCredCryptoError.invalidProxyKey) { try IMAPCredCrypto.proxyKey(encoded) }
        IMAPCredCrypto.$sealingKey.withValue(encoded) {
            #expect(throws: IMAPCredCryptoError.invalidProxyKey) { try IMAPCredCrypto.encrypt(payload, context: context()) }
        }
        let control = try IMAPCredCrypto.proxyKey(SyntheticProxyKey.encoded(keyA))
        #expect(control.rawRepresentation == keyA.publicKey.rawRepresentation)
    }

    /// `encrypt` seals to the bound key: what it returns opens with that key and no other.
    @Test func encryptSealsToTheSealingKey() throws {
        let wire = try IMAPCredCrypto.$sealingKey.withValue(SyntheticProxyKey.encoded(keyB)) {
            try IMAPCredCrypto.encrypt(payload, context: context())
        }
        let aad = try context().credentialContext()
        let opened = try JSONDecoder().decode(IMAPCredPayload.self, from: openEnvelope(wire, with: keyB, aad: aad))
        #expect(opened.password == payload.password && opened.host == payload.host)
        #expect(throws: (any Error).self) { try openEnvelope(wire, with: keyA, aad: aad) }
    }

    @Test(arguments: ["userId", "deviceId", "accountEmail", "deviceToken", "apnsSandbox", "nseCapable"])
    func everyRequestFieldAuthenticated(field: String) throws {
        let wire = try IMAPCredCrypto.sealAuthorityPayload(payload, context: context(), to: keyA.publicKey)
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(context())) as? [String: Any])
        if field == "apnsSandbox" { object[field] = true }
        else if field == "nseCapable" { object[field] = false }
        else { object[field] = "different" }
        let changed = try JSONDecoder().decode(IMAPSubscribeContext.self,
            from: JSONSerialization.data(withJSONObject: object))
        let aad = try changed.credentialContext()
        #expect(throws: (any Error).self) { try openEnvelope(wire, with: keyA, aad: aad) }
        let original = try context().credentialContext()
        let reopened = try openEnvelope(wire, with: keyA, aad: original)
        #expect(!reopened.isEmpty)
    }

    @Test(arguments: ["", "id\u{0}", "id\u{1f}", "id\u{7f}", String(repeating: "x", count: 513)])
    func invalidContextRefuses(device: String) {
        #expect(throws: (any Error).self) { try context(device: device).credentialContext() }
    }

    @Test func utf16Bound() throws {
        #expect(try context(device: String(repeating: "😀", count: 256)).credentialContext().isEmpty == false)
        #expect(throws: (any Error).self) { try context(device: String(repeating: "😀", count: 257)).credentialContext() }
    }

    /// The same CryptoKit-made envelope the proxy's tests open: the layout, key id and info
    /// built here match what the proxy reads.
    @Test func proxyFixtureEnvelopeOpens() throws {
        #expect(keyA.publicKey.rawRepresentation.base64EncodedString() == "Fmj00eYI8/sxlTCc5D0z46qjfgE4BpLazwkQ5s+JRWo=")
        #expect(hex(IMAPCredCrypto.keyId(of: keyA.publicKey)) == "bc90ba81f8f68cce")
        #expect(hex(IMAPCredCrypto.keyId(of: keyB.publicKey)) == "781b54822b025097")
        let wire = "v3:vJC6gfj2jM7gQM6KxMfIr/AKooyS+e/nYgyIVfeIeNgWvAQIVe4DAcfWAal/37OsB7+w64SVCMq9yh2Qac1okxFnrbJXjvHZWW215fufwgImjlcdxLEAOg+q/g//XMzdP79aLVFEoCNRSM4+G2QqeVfbF8R/T7NhD/orin007PJwKVLANpd0gkVUhJaaUDw7qpj/CNBHqhdwvpaJ+tb/Q3SKK0Q="
        let plaintext = try openEnvelope(wire, with: keyA, aad: context().credentialContext())
        #expect(String(decoding: plaintext, as: UTF8.self)
            == #"{"host":"imap.synthetic.invalid","username":"synthetic-user","password":"synthetic-secret","security":"tls"}"#)
    }

    @Test func escapingDoesNotNormalizeIdentity() throws {
        let device = "é/\"\\\u{2028}e\u{301}"
        let expected = "[\"tabmail-imap-subscribe-v2\",\"user-a\",\"é/\\\"\\\\\u{2028}e\u{301}\",\"imap\",\"mail@example.test\",\"token-a\",false,true]"
        #expect(try context(device: device).credentialContext() == Data(expected.utf8))
    }

    /// The app seals to the shipped proxy key: a real X25519 public key, not a test key.
    /// The one test that reads the shipped constant; every other test binds a synthetic key.
    @Test func shippedProxyKeySeals() throws {
        let key = try IMAPCredCrypto.proxyKey(IMAPCredCrypto.proxyPublicKey)
        // The production pair's key id, as the key run printed it (first 8 bytes of SHA-256).
        #expect(hex(IMAPCredCrypto.keyId(of: key)) == "a605db1b0439c3bd")
        #expect(key.rawRepresentation.base64EncodedString() == IMAPCredCrypto.proxyPublicKey)
        #expect(key.rawRepresentation != keyA.publicKey.rawRepresentation)
        #expect(key.rawRepresentation != keyB.publicKey.rawRepresentation)
        let wire = try IMAPCredCrypto.encrypt(payload, context: context())
        let packed = try #require(Data(base64Encoded: String(wire.dropFirst(3))))
        #expect(wire.hasPrefix("v3:"))
        #expect(packed.prefix(8) == IMAPCredCrypto.keyId(of: key))
    }

    /// No shared credential key is left for a build to carry: each target's sources,
    /// headers, plists and entitlements are read, and each target's own files are in the set.
    @Test func noSharedCredentialKeyRemains() throws {
        let crypto = try String(contentsOf: repositoryRoot.appendingPathComponent("Shared/Crypto/IMAPCredCrypto.swift"), encoding: .utf8)
        #expect(!crypto.contains("SymmetricKey") && !crypto.contains("AES."))
        let marker = "IMAP_CRED_ENCRYPTION_KEY"
        for path in ["TabMail/Resources/Info.plist", "TabMailNotificationService/Info.plist", "Secrets.xcconfig.example", "project.yml"] {
            let text = try String(contentsOf: repositoryRoot.appendingPathComponent(path), encoding: .utf8)
            #expect(!text.contains(marker), "\(path) still names the shared credential key")
        }
        let targets: [(folder: String, mustRead: [String])] = [
            ("Shared", ["/Shared/Crypto/IMAPCredCrypto.swift", "/Shared/Crypto/IMAPSubscribeContext.swift"]),
            // The two C files are the ones project.yml compiles explicitly (sqlite-vec).
            ("TabMail", ["/TabMail/Services/PushClient.swift", "/TabMail/TabMail-Bridging-Header.h",
                         "/TabMail/Resources/Info.plist", "/TabMail/TabMail.entitlements",
                         "/TabMail/Vendor/sqlite-vec/sqlite-vec.c", "/TabMail/Vendor/sqlite-vec/sqlite_vec_register.c"]),
            ("TabMailNotificationService", ["/TabMailNotificationService/NotificationService.swift",
                         "/TabMailNotificationService/Info.plist",
                         "/TabMailNotificationService/TabMailNotificationService.entitlements"]),
        ]
        for target in targets {
            let scan = try scanForMarker(marker, under: repositoryRoot.appendingPathComponent(target.folder))
            for file in target.mustRead {
                #expect(scan.scanned.contains { $0.hasSuffix(file) }, "\(target.folder) scan did not read \(file)")
            }
            #expect(scan.hits.isEmpty, "\(target.folder) still names the shared credential key: \(scan.hits)")
        }
    }

    /// The fence's detector: it reports a marker in any fenced file type at any depth,
    /// reads nothing else, finds nothing in a clean tree and fails on a missing folder.
    @Test func fenceScanFindsASyntheticMarker() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("fence-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let marker = "SYNTHETIC_FENCE_MARKER"
        let files: [(path: String, text: String)] = [
            ("clean/a.swift", "let value = 1\n"),
            ("clean/f.c", "static int value = 1;\n"),
            ("nested/deep/b.h", "#define \(marker) 1\n"),
            ("nested/vendor/g.c", "static const char *name = \"\(marker)\";\n"),
            ("c.swift", "let name = \"\(marker)\"\n"),
            ("d.plist", "<string>\(marker)</string>\n"),
            ("e.txt", "\(marker)\n"),
        ]
        for file in files {
            let url = root.appendingPathComponent(file.path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(file.text.utf8).write(to: url)
        }
        let found = try scanForMarker(marker, under: root)
        let hitNames = found.hits.map { URL(fileURLWithPath: $0).lastPathComponent }.sorted()
        #expect(hitNames == ["b.h", "c.swift", "d.plist", "g.c"])
        let scannedNames = found.scanned.map { URL(fileURLWithPath: $0).lastPathComponent }.sorted()
        #expect(scannedNames == ["a.swift", "b.h", "c.swift", "d.plist", "f.c", "g.c"])
        let clean = try scanForMarker("ABSENT_FENCE_MARKER", under: root)
        #expect(clean.hits.isEmpty && clean.scanned.count == 6)
        #expect(throws: (any Error).self) { try scanForMarker(marker, under: root.appendingPathComponent("missing")) }
    }
}
