/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Testing
@testable import TabMail

/// A forward sent from another mail app marks its original forwarded, never
/// replied, even when it names the original in In-Reply-To (#1492).
///
/// Thunderbird sets In-Reply-To on every forward: with References present and no
/// In-Reply-To, it takes the last References id whatever the compose kind
/// (comm-central `MimeMessage.sys.mjs`, `_gatherMimeHeaders`). So when that
/// forward's Sent copy syncs, In-Reply-To alone says "a reply". Its subject's
/// forward prefix says otherwise: the original is marked forwarded, keeps its
/// Reply tag (the user has not answered it), and stays so through a later pass.
///
/// Each test puts a Thunderbird-shaped copy in the server's Sent folder
/// (In-Reply-To = the original's Message-ID, References ending with it, subject
/// "Fwd: ...") and runs the provider's sync. A reply-shaped copy ("Re: ...")
/// is the control: it still marks the original replied and clears its tag.
extension SendReplyMarksTests {

    /// The original's marks after another app's Sent copy synced.
    static func expectedAfterOtherAppCopy(isForward: Bool) -> Marks {
        isForward
            ? Marks(isReplied: false, isForwarded: true, actionTag: .reply)
            : Marks(isReplied: true, isForwarded: false, actionTag: ActionTag.none)
    }

    /// The subject another app gives the copy.
    static func otherAppSubject(_ original: String, isForward: Bool) -> String {
        (isForward ? "Fwd: " : "Re: ") + original
    }

    // MARK: - Gmail

    @Test("Gmail: another app's forward copy with In-Reply-To marks the original forwarded and keeps its Reply tag; a reply copy marks it replied",
          arguments: [true, false])
    func gmailOtherAppCopy(isForward: Bool) async throws {
        let seed = GmailDeltaApplyInvariantTests.seed("other-1", labels: ["INBOX"])
        try await GmailDeltaApplyInvariantTests.withWorld(seeds: [seed]) { w in
            try await w.foregroundPassWithFullSyncDue()
            let stored = try w.row("other-1", in: w.inbox)
            let original = try #require(stored, "precondition: the full pass stored the original")
            let originalRfc = try #require(original.rfc822MessageId)
            try await Self.tagReply(w.pool, headerId: original.id)

            w.server.addMessage(GmailDeltaApplyInvariantTests.seed("other-sent", labels: ["SENT"], headers: [
                "In-Reply-To": "<\(originalRfc)>",
                "References": "<\(originalRfc)>",
                "Subject": Self.otherAppSubject(original.subject, isForward: isForward),
            ]))
            try await w.completedDelta()
            let copy = try w.row("other-sent", in: w.sent)
            let named = copy?.inReplyTo.map(EmailFilter.normalizeMessageId)
            #expect(named == originalRfc, "precondition: the Sent copy synced and names the original: \(named ?? "nil")")

            let want = Self.expectedAfterOtherAppCopy(isForward: isForward)
            let after = try Self.marks(w.pool, headerId: original.id)
            #expect(after == want, "after the Sent copy synced: \(after), want \(want)")

            // A later full pass re-reads the original (the server holds no forwarded flag).
            try await w.foregroundPassWithFullSyncDue()
            let later = try Self.marks(w.pool, headerId: original.id)
            #expect(later == want, "after a later full pass: \(later), want \(want)")
        }
    }

    // MARK: - IMAP

    @Test("IMAP: another app's forward copy with In-Reply-To marks the original forwarded and keeps its Reply tag; a reply copy marks it replied",
          arguments: [true, false])
    func imapOtherAppCopy(isForward: Bool) async throws {
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
        let accountId = "other-imap-\(UUID().uuidString.prefix(8).lowercased())"
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
        let header = try #require(stored, "precondition: the full pass stored the original")
        let originalRfc = try #require(header.rfc822MessageId)
        try await Self.tagReply(pool, headerId: header.id)

        // The other app's copy, as it lands in Sent: In-Reply-To and References name
        // the original, and the subject says what it is. Appended through the
        // provider's own APPEND, which writes exactly these headers.
        var draft = DraftMessage(
            to: ["someone@example.com"], subject: Self.otherAppSubject(header.subject, isForward: isForward),
            body: "body", inReplyTo: originalRfc, references: [originalRfc])
        let copyId = "other-sent-\(UUID().uuidString.prefix(8).lowercased())@example.com"
        draft.messageId = copyId
        let appended = try await provider.appendToSentFolder(draft: draft, sentFolderPath: sentPath, messageId: copyId)
        #expect(appended, "precondition: the Sent copy was appended")
        let kept = server.snapshotMessagesWithFlags(in: sentPath)
        #expect(kept.count == 1, "precondition: one Sent copy on the server")
        guard kept.count == 1 else { return }
        let inReplyTo = FakeIMAPServer.unfoldedHeaderValue("In-Reply-To", in: kept[0].message.headerData)
        #expect(inReplyTo == "<\(originalRfc)>", "precondition: the copy names the original: \(inReplyTo ?? "nil")")

        try await fullPass()
        let sentId = "\(accountId):\(sentPath)"
        let synced = try await pool.read { db in
            try MessageHeader.filter(Column("folderId") == sentId).fetchAll(db)
        }
        let named = synced.map { $0.inReplyTo.map(EmailFilter.normalizeMessageId) ?? "nil" }
        #expect(named == [originalRfc], "precondition: the Sent copy synced and names the original: \(named)")

        let want = Self.expectedAfterOtherAppCopy(isForward: isForward)
        let after = try Self.marks(pool, headerId: header.id)
        #expect(after == want, "after the Sent copy synced: \(after), want \(want)")

        try await fullPass()
        let later = try Self.marks(pool, headerId: header.id)
        #expect(later == want, "after a later full pass: \(later), want \(want)")
        #expect(server.wrongMessageViolations().isEmpty)
        await engine.remove(accountId: accountId)
    }
}
