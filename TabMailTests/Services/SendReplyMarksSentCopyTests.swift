/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Testing
@testable import TabMail

/// The Sent copy of a forward never marks its original replied (#1483).
///
/// `ReplyParentResolver` reads a synced Sent message's In-Reply-To as "this is a
/// reply to that message": it marks the named message replied and clears its
/// Reply tag. A forward therefore carries no In-Reply-To
/// (`ThreadUtils.outgoingThreadHeaders`); it still names its original as the
/// last References id, so it stays in the conversation.
///
/// Each test queues the send as Send does (the production thread-header
/// builder), renders the message with the provider's own wire builder, puts that
/// copy in the server's Sent folder and runs the provider's sync. The completion
/// is not run, so what the original shows comes from Send's own mark (#1490) and
/// the Sent copy.
///
/// Outlook's sync reads no In-Reply-To (`GraphParse.parseMessage` sets it nil),
/// so an Outlook Sent copy marks nothing for a reply or a forward; its marks come
/// from the completion's last-verb write. Its test pins the wire only.
extension SendReplyMarksTests {

    /// The original's marks after its Sent copy synced, with the send not yet
    /// completed. Send marked it (#1490): a reply replied with its Reply tag
    /// cleared, a forward forwarded. A forward's copy must leave it unreplied
    /// with its Reply tag.
    static func expectedAfterSentCopy(isForward: Bool) -> Marks {
        isForward
            ? Marks(isReplied: false, isForwarded: true, actionTag: .reply)
            : Marks(isReplied: true, isForwarded: false, actionTag: ActionTag.none)
    }

    /// The queued send, as the drain hands it to a provider.
    static func queuedDraft(_ pool: DatabasePool, outboxId: String) async throws -> DraftMessage {
        let row = try await pool.read { db in try OutboxMessage.fetchOne(db, key: outboxId) }
        return try #require(row, "precondition: the send is queued").toDraftMessage()
    }

    /// The header block of an RFC 5322 message.
    static func headerBlock(_ message: String) -> Data {
        Data((message.components(separatedBy: "\r\n\r\n").first ?? message).utf8)
    }

    /// Checks what the rendered message names, so a pass below is not vacuous:
    /// both name the original as the last References id; only a reply names it
    /// in In-Reply-To.
    static func expectThreading(_ headers: Data, originalRfc: String, isForward: Bool) {
        let inReplyTo = FakeIMAPServer.unfoldedHeaderValue("In-Reply-To", in: headers)
        let references = FakeIMAPServer.unfoldedHeaderValue("References", in: headers)
        #expect(references?.hasSuffix("<\(originalRfc)>") == true,
                "the copy names the original as its last References id: \(references ?? "nil")")
        if isForward {
            #expect(inReplyTo == nil, "a forward's copy carries no In-Reply-To: \(inReplyTo ?? "nil")")
        } else {
            #expect(inReplyTo == "<\(originalRfc)>", "a reply's copy names the original: \(inReplyTo ?? "nil")")
        }
    }

    // MARK: - Gmail

    @Test("Gmail: a forward's Sent copy leaves the original's marks and Reply tag alone; a reply's marks it replied",
          arguments: [false, true])
    func gmailSentCopy(isForward: Bool) async throws {
        let seed = GmailDeltaApplyInvariantTests.seed("copy-1", labels: ["INBOX"])
        try await GmailDeltaApplyInvariantTests.withWorld(seeds: [seed]) { w in
            try await w.foregroundPassWithFullSyncDue()
            let stored = try w.row("copy-1", in: w.inbox)
            let original = try #require(stored, "precondition: the full pass stored the original")
            let originalRfc = try #require(original.rfc822MessageId)
            try await Self.tagReply(w.pool, headerId: original.id)

            let queued = try await Self.queue(
                pool: w.pool, accountId: w.accountId, original: original, isForward: isForward)
            // The message as GmailProvider sends it (`users.messages.send` raw).
            let draft = try await Self.queuedDraft(w.pool, outboxId: queued.outboxId)
            let body = w.provider.buildSendBody(draft: draft)
            let raw = try #require(body["raw"] as? String)
            var base64 = raw.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            while base64.count % 4 != 0 { base64 += "=" }
            let mime = String(decoding: try #require(Data(base64Encoded: base64)), as: UTF8.self)
            let headers = Self.headerBlock(mime)
            Self.expectThreading(headers, originalRfc: originalRfc, isForward: isForward)

            // Gmail files that message in Sent, and the change pass reads it.
            var sentHeaders: [String: String] = [:]
            for name in ["In-Reply-To", "References"] {
                if let value = FakeIMAPServer.unfoldedHeaderValue(name, in: headers) { sentHeaders[name] = value }
            }
            w.server.addMessage(GmailDeltaApplyInvariantTests.seed("copy-sent", labels: ["SENT"], headers: sentHeaders))
            try await w.completedDelta()
            #expect(try w.row("copy-sent", in: w.sent) != nil, "precondition: the Sent copy synced")

            let after = try Self.marks(w.pool, headerId: original.id)
            let want = Self.expectedAfterSentCopy(isForward: isForward)
            #expect(after == want, "after the Sent copy synced: \(after), want \(want)")
        }
    }

    // MARK: - IMAP

    @Test("IMAP: a forward's Sent copy leaves the original's marks and Reply tag alone; a reply's marks it replied",
          arguments: [false, true])
    func imapSentCopy(isForward: Bool) async throws {
        let sentPath = "Sent"
        let sentEpoch = Self.imapEpoch + 1
        let server = FakeIMAPServer(
            capabilities: Self.imapCapabilities,
            mailboxes: [Self.imapPath: [IMAPChangeReaderTests.message(1)], sentPath: []])
        server.setUidValidity(Self.imapEpoch, for: Self.imapPath)
        server.setUidValidity(sentEpoch, for: sentPath)
        // A real server's ENVELOPE names the message a copy replies to.
        server.reportInReplyToInEnvelopes()
        try server.start()
        defer { server.stop() }

        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        let accountId = "copy-imap-\(UUID().uuidString.prefix(8).lowercased())"
        _ = try FolderEpochTestFixture.makeAccount(id: accountId, provider: .imap, pool: pool)
        try FolderEpochTestFixture.insertFolder(
            accountId: accountId, path: Self.imapPath, role: .inbox, pool: pool,
            lastKnownUidValidity: Self.imapEpoch)
        try FolderEpochTestFixture.insertFolder(
            accountId: accountId, path: sentPath, role: .sent, pool: pool,
            lastKnownUidValidity: sentEpoch)

        let provider = IMAPProvider(
            host: "127.0.0.1", port: server.port, username: server.username, password: server.password,
            smtpHost: "127.0.0.1", smtpPort: 587, useTLS: false)
        try await provider.connect()
        defer { Task { try? await provider.disconnect() } }
        let engine = SyncEngine()
        await engine.register(
            accountId: accountId, provider: provider,
            workQueue: ProviderWorkQueue(provider: provider, maxConcurrency: SyncConfig.imapMaxConnectionCeiling))

        func account() throws -> Account {
            let stored = try pool.read { db in try Account.fetchOne(db, key: accountId) }
            return try #require(stored)
        }
        func fullPass() async throws {
            try await pool.write { db in
                _ = try Account.filter(Column("id") == accountId).updateAll(db,
                    Column("lastFullSyncAt").set(to: nil as Date?))
            }
            _ = try await engine.sync(account: try account())
        }

        try await fullPass()
        let inboxId = "\(accountId):\(Self.imapPath)"
        let stored = try await pool.read { db in
            try MessageHeader.filter(Column("folderId") == inboxId && Column("messageId") == "1").fetchOne(db)
        }
        let original = try #require(stored, "precondition: the full pass stored the original")
        let originalRfc = try #require(original.rfc822MessageId)
        try await Self.tagReply(pool, headerId: original.id)

        let queued = try await Self.queue(pool: pool, accountId: accountId, original: original, isForward: isForward)
        // The copy kept in Sent, through the provider's own APPEND.
        var draft = try await Self.queuedDraft(pool, outboxId: queued.outboxId)
        let sentMessageId = "copy-sent-\(UUID().uuidString.prefix(8).lowercased())@example.com"
        draft.messageId = sentMessageId
        let appended = try await provider.appendToSentFolder(
            draft: draft, sentFolderPath: sentPath, messageId: sentMessageId)
        #expect(appended, "precondition: the Sent copy was appended")
        let kept = server.snapshotMessagesWithFlags(in: sentPath)
        #expect(kept.count == 1, "precondition: one Sent copy on the server")
        guard kept.count == 1 else { return }
        Self.expectThreading(kept[0].message.headerData, originalRfc: originalRfc, isForward: isForward)

        try await fullPass()
        let sentId = "\(accountId):\(sentPath)"
        let sentRows = try await pool.read { db in
            try MessageHeader.filter(Column("folderId") == sentId).fetchCount(db)
        }
        #expect(sentRows == 1, "precondition: the Sent copy synced")

        let after = try Self.marks(pool, headerId: original.id)
        let want = Self.expectedAfterSentCopy(isForward: isForward)
        #expect(after == want, "after the Sent copy synced: \(after), want \(want)")
        #expect(server.wrongMessageViolations().isEmpty)
        await engine.remove(accountId: accountId)
    }

    // MARK: - Outlook

    /// The extended property Exchange writes a threading header from.
    static func graphProperty(_ id: String, in payload: [String: Any]) -> String? {
        let properties = payload["singleValueExtendedProperties"] as? [[String: String]] ?? []
        return properties.first { $0["id"] == id }?["value"]
    }

    @Test("Outlook: a forward goes out with no In-Reply-To and names its original as its last References id; a reply names it in both",
          arguments: [false, true])
    func outlookForwardWire(isForward: Bool) async throws {
        try await OutlookChangeReadingTests.withWorld { w in
            try w.insertRow("copy-1", in: w.inbox)
            let stored = try w.row("copy-1", in: w.inbox)
            let original = try #require(stored, "precondition: the original is held")
            let originalRfc = try #require(original.rfc822MessageId)

            let queued = try await Self.queue(
                pool: w.pool, accountId: w.accountId, original: original, isForward: isForward)
            let draft = try await Self.queuedDraft(w.pool, outboxId: queued.outboxId)
            let payload = w.provider.buildGraphSendPayload(draft: draft, sending: true)
            let inReplyTo = Self.graphProperty(ExchangeProvider.graphInReplyToProperty, in: payload)
            let references = Self.graphProperty(ExchangeProvider.graphReferencesProperty, in: payload)
            #expect(references?.hasSuffix("<\(originalRfc)>") == true,
                    "the send names the original as its last References id: \(references ?? "nil")")
            if isForward {
                #expect(inReplyTo == nil, "a forward carries no In-Reply-To: \(inReplyTo ?? "nil")")
            } else {
                #expect(inReplyTo == "<\(originalRfc)>", "a reply names the original: \(inReplyTo ?? "nil")")
            }
        }
    }
}
