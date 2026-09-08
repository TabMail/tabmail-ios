/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import CryptoKit
import Foundation
import Testing
@testable import TabMail

struct IMAPAuthorityCredentialTests {
    private let key = SymmetricKey(data: Data(repeating: 42, count: 32))
    private let payload = IMAPCredPayload(host: "imap.example.test", port: 993,
        username: "synthetic", password: "synthetic-password", security: "tls")
    private func context(device: String = "device-a") -> IMAPSubscribeContext {
        IMAPSubscribeContext(userId: "user-a", deviceId: device,
            accountEmail: "mail@example.test", deviceToken: "token-a",
            apnsSandbox: false, nseCapable: true)
    }

    @Test func exactOrderedJSON() throws {
        let expected = #"["tabmail-imap-subscribe-v2","user-a","device-a","imap","mail@example.test","token-a",false,true]"#
        #expect(try context().credentialContext() == Data(expected.utf8))
    }

    @Test func unifiedBodyContainsExistingDeviceAndInboxFieldsOnly() throws {
        let envelope = try IMAPCredCrypto.sealAuthorityPayload(payload, context: context(), key: key)
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

    @Test(arguments: ["", "v1:synthetic", "v2:", "v2:" + String(repeating: "a", count: 65_536)])
    func invalidEnvelopeCannotBuildRequest(envelope: String) {
        #expect(throws: (any Error).self) { try context().requestBody(credentialEnvelope: envelope) }
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

    @Test func roundTripAndFreshNonce() throws {
        let a = try IMAPCredCrypto.sealAuthorityPayload(payload, context: context(), key: key)
        let b = try IMAPCredCrypto.sealAuthorityPayload(payload, context: context(), key: key)
        #expect(a.hasPrefix("v2:"))
        let packed = try #require(Data(base64Encoded: String(a.dropFirst(3))))
        let other = try #require(Data(base64Encoded: String(b.dropFirst(3))))
        #expect(packed.prefix(12) != other.prefix(12))
        let box = try AES.GCM.SealedBox(combined: packed)
        let decoded = try JSONDecoder().decode(IMAPCredPayload.self,
            from: AES.GCM.open(box, using: key, authenticating: context().credentialContext()))
        #expect(decoded.host == payload.host && decoded.port == payload.port)
        #expect(decoded.username == payload.username && decoded.password == payload.password)
        #expect(decoded.security == payload.security)
        #expect(throws: (any Error).self) { try AES.GCM.open(box, using: key) }
    }

    @Test(arguments: ["userId", "deviceId", "accountEmail", "deviceToken", "apnsSandbox", "nseCapable"])
    func everyRequestFieldAuthenticated(field: String) throws {
        let wire = try IMAPCredCrypto.sealAuthorityPayload(payload, context: context(), key: key)
        let box = try AES.GCM.SealedBox(combined: #require(Data(base64Encoded: String(wire.dropFirst(3)))))
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(context())) as? [String: Any])
        if field == "apnsSandbox" { object[field] = true }
        else if field == "nseCapable" { object[field] = false }
        else { object[field] = "different" }
        let changed = try JSONDecoder().decode(IMAPSubscribeContext.self,
            from: JSONSerialization.data(withJSONObject: object))
        let aad = try changed.credentialContext()
        #expect(throws: (any Error).self) { try AES.GCM.open(box, using: key, authenticating: aad) }
        #expect(try AES.GCM.open(box, using: key, authenticating: context().credentialContext()).isEmpty == false)
    }

    @Test(arguments: ["", "id\u{0}", "id\u{1f}", "id\u{7f}", String(repeating: "x", count: 513)])
    func invalidContextRefuses(device: String) {
        #expect(throws: (any Error).self) { try context(device: device).credentialContext() }
    }

    @Test func utf16Bound() throws {
        #expect(try context(device: String(repeating: "😀", count: 256)).credentialContext().isEmpty == false)
        #expect(throws: (any Error).self) { try context(device: String(repeating: "😀", count: 257)).credentialContext() }
    }

    @Test func nodeKnownAnswerDecrypts() throws {
        // Synthetic Node AES-GCM vector, key 32×42 and nonce 12×7. Test only.
        let encoded = "BwcHBwcHBwcHBwcHRN2XyibgBwvbIx3B+tLSQ1vrHR/7ExRQ2U6gu35MbWCKjs4iR+6i3YX8lCikZoukUbiLKpyG53LU+yYL9a6yEo2lGmYRKA95Hjd7U1p3kAaASQZO1ZVo7LZe18yoaVBwnKZeUoPNdIOnb/FuiEQS1lhBZjWE4e2vjcfmtYV5eQ=="
        let box = try AES.GCM.SealedBox(combined: #require(Data(base64Encoded: encoded)))
        let decoded = try JSONDecoder().decode(IMAPCredPayload.self,
            from: AES.GCM.open(box, using: key, authenticating: context().credentialContext()))
        #expect(decoded.host == payload.host && decoded.port == payload.port)
        #expect(decoded.username == payload.username && decoded.password == payload.password)
        #expect(decoded.security == payload.security)
    }

    @Test func escapingDoesNotNormalizeIdentity() throws {
        let device = "é/\"\\\u{2028}e\u{301}"
        let expected = "[\"tabmail-imap-subscribe-v2\",\"user-a\",\"é/\\\"\\\\\u{2028}e\u{301}\",\"imap\",\"mail@example.test\",\"token-a\",false,true]"
        #expect(try context(device: device).credentialContext() == Data(expected.utf8))
    }

    @Test func wrongKeySizeRefuses() {
        #expect(throws: (any Error).self) {
            try IMAPCredCrypto.sealAuthorityPayload(payload, context: context(),
                key: SymmetricKey(data: Data(repeating: 0, count: 16)))
        }
    }
}
