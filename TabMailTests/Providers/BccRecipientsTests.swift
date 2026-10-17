/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Testing
@testable import TabMail

/// BCC recipients survive every path a draft or a sent message takes to the
/// server: a saved draft still names them when it is reopened, a sent message
/// reaches them, and the sender's Sent copy names them. Only the delivered
/// message leaves them out, and that is pinned in `IMAPProviderBuildEmailTests`.
@Suite("BCC recipients on every provider path", .serialized)
struct BccRecipientsTests {
    private static let bcc = ["hidden@example.com", "Hidden Two <hidden2@example.com>"]

    private static func draft(bcc: [String] = Self.bcc, cc: [String] = [], attachment: Bool = false) -> DraftMessage {
        var draft = DraftMessage(
            to: ["to@example.com"], cc: cc, bcc: bcc, subject: "With BCC", body: "Body",
            attachments: attachment
                ? [DraftAttachment(filename: "a.txt", mimeType: "text/plain", data: Data("a".utf8))]
                : [])
        draft.messageId = "bcc-\(UUID().uuidString)@example.com"
        return draft
    }

    /// The header block's unfolded `Bcc` field body, nil when there is none.
    private static func bccField(in message: String) -> String? {
        let header = message.components(separatedBy: "\r\n\r\n").first ?? message
        let unfolded = header.replacingOccurrences(of: "\r\n ", with: " ")
            .replacingOccurrences(of: "\r\n\t", with: " ")
        return unfolded.components(separatedBy: "\r\n")
            .first { $0.lowercased().hasPrefix("bcc:") }
            .map { String($0.dropFirst(4)).trimmingCharacters(in: .whitespaces) }
    }

    // MARK: - IMAP

    private static func imapProvider(_ server: FakeIMAPServer) -> IMAPProvider {
        IMAPProvider(
            host: "127.0.0.1", port: server.port,
            username: server.username, password: server.password,
            smtpHost: "127.0.0.1", smtpPort: 587, useTLS: false)
    }

    private static func storedMessage(_ server: FakeIMAPServer, in mailbox: String) throws -> String {
        let stored = server.snapshotMessagesWithFlags(in: mailbox)
        #expect(stored.count == 1)
        let raw = try #require(stored.first?.message.raw)
        return String(decoding: raw, as: UTF8.self)
    }

    @Test("An IMAP draft names its BCC recipients, display names included")
    func imapDraftNamesBcc() async throws {
        let server = FakeIMAPServer(mailboxes: ["Drafts": []])
        server.setUidValidity(81_001, for: "Drafts")
        try server.start()
        defer { server.stop() }
        let provider = Self.imapProvider(server)
        try await provider.connect()
        defer { Task { try? await provider.disconnect() } }

        _ = try await provider.saveDraft(Self.draft(), existingIdentity: nil, draftsFolderPath: "Drafts")

        let field = try #require(Self.bccField(in: try Self.storedMessage(server, in: "Drafts")))
        #expect(field == "hidden@example.com, Hidden Two <hidden2@example.com>")
    }

    @Test("The IMAP Sent copy names the BCC recipients")
    func imapSentCopyNamesBcc() async throws {
        let server = FakeIMAPServer(mailboxes: ["Sent": []])
        try server.start()
        defer { server.stop() }
        let provider = Self.imapProvider(server)
        try await provider.connect()
        defer { Task { try? await provider.disconnect() } }

        let draft = Self.draft()
        _ = try await provider.appendToSentFolder(
            draft: draft, sentFolderPath: "Sent", messageId: try #require(draft.messageId))

        let field = try #require(Self.bccField(in: try Self.storedMessage(server, in: "Sent")))
        #expect(field == "hidden@example.com, Hidden Two <hidden2@example.com>")
    }

    // MARK: - Gmail

    private static func decodeRaw(_ raw: String) -> String {
        var base64 = raw.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        return String(decoding: Data(base64Encoded: base64) ?? Data(), as: UTF8.self)
    }

    /// The `raw` message of every Gmail request recorded, decoded.
    private static func gmailRawMessages(_ http: FakeHTTP.Scenario) throws -> [String] {
        try http.recordedCalls().compactMap { call in
            guard let body = call.body,
                  let json = try JSONSerialization.jsonObject(with: body) as? [String: Any] else { return nil }
            let raw = (json["raw"] as? String) ?? ((json["message"] as? [String: Any])?["raw"] as? String)
            return raw.map(Self.decodeRaw)
        }
    }

    @Test("Gmail sends and saves drafts with a Bcc header, with and without attachments",
          arguments: [false, true])
    func gmailNamesBcc(attachment: Bool) async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        http.register(path: "/messages/send", method: "POST", response: .json(raw: #"{"id":"sent-1"}"#))
        http.register(path: "/drafts", method: "POST",
                      response: .json(raw: #"{"id":"r-1","message":{"id":"m-1"}}"#))
        http.register(path: "/drafts/r-1", method: "PUT",
                      response: .json(raw: #"{"id":"r-1","message":{"id":"m-2"}}"#))
        let provider = GmailProvider(userEmail: "me@example.com", accessToken: { _ in "tok" }, session: http.session)

        try await provider.send(draft: Self.draft(attachment: attachment))
        _ = try await provider.saveDraft(
            Self.draft(attachment: attachment), existingIdentity: nil, draftsFolderPath: "DRAFT")
        _ = try await provider.saveDraft(
            Self.draft(attachment: attachment), existingIdentity: .gmail(resourceId: "r-1"),
            draftsFolderPath: "DRAFT")

        let messages = try Self.gmailRawMessages(http)
        #expect(messages.count == 3)
        for message in messages {
            #expect(Self.bccField(in: message) == "hidden@example.com, Hidden Two <hidden2@example.com>")
        }
    }

    @Test("Gmail writes no Bcc header when there are no BCC recipients")
    func gmailNoBccNoHeader() {
        let provider = GmailProvider(userEmail: "me@example.com", accessToken: { _ in "tok" })
        #expect(Self.bccField(in: provider.buildRFC822(draft: Self.draft(bcc: []))) == nil)
        let mime = String(decoding: provider.buildMIMEMessage(draft: Self.draft(bcc: [], attachment: true)), as: UTF8.self)
        #expect(Self.bccField(in: mime) == nil)
    }

    // MARK: - Outlook

    private static func graphBodies(_ http: FakeHTTP.Scenario, method: String) throws -> [[String: Any]] {
        try http.recordedCalls().filter { $0.method == method }.compactMap { call in
            guard let body = call.body else { return nil }
            let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
            return (json?["message"] as? [String: Any]) ?? json
        }
    }

    private static func addresses(_ list: Any?) -> [String]? {
        (list as? [[String: Any]])?.compactMap { ($0["emailAddress"] as? [String: Any])?["address"] as? String }
    }

    @Test("Outlook sends and creates drafts with the BCC recipients")
    func outlookNamesBcc() async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        http.register(path: "/sendMail", method: "POST", response: .status(202))
        http.register(path: "/mailFolders/drafts/messages", method: "POST", response: .json(raw: #"{"id":"g-1"}"#))
        let provider = ExchangeProvider(userEmail: "me@example.com", accessToken: { _ in "tok" }, session: http.session)

        let bcc = ["hidden@example.com", "hidden2@example.com"]
        try await provider.send(draft: Self.draft(bcc: bcc))
        _ = try await provider.saveDraft(Self.draft(bcc: bcc), existingIdentity: nil, draftsFolderPath: "Drafts")

        let bodies = try Self.graphBodies(http, method: "POST")
        #expect(bodies.count == 2)
        for body in bodies {
            #expect(Self.addresses(body["bccRecipients"]) == bcc)
        }
    }

    /// A draft update is a PATCH, which keeps every property it does not name.
    @Test("Clearing every CC and BCC recipient of an Outlook draft clears them on the server")
    func outlookClearedRecipientsAreCleared() async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        http.register(path: "/messages/g-1", method: "PATCH", response: .json(raw: #"{"id":"g-1"}"#))
        let provider = ExchangeProvider(userEmail: "me@example.com", accessToken: { _ in "tok" }, session: http.session)

        _ = try await provider.saveDraft(
            Self.draft(bcc: [], cc: []), existingIdentity: .outlook(graphId: "g-1"), draftsFolderPath: "Drafts")

        let patch = try #require(try Self.graphBodies(http, method: "PATCH").first)
        #expect(Self.addresses(patch["ccRecipients"]) == [])
        #expect(Self.addresses(patch["bccRecipients"]) == [])
    }
}
