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

    // MARK: - The copy arrives through scroll to older mail, or the backfill walk

    /// The original stored in INBOX and tagged Reply, as `F.insertHeader` stores a row.
    static func storeOriginal(accountId: String, pool: DatabasePool) async throws -> (id: String, rfc: String) {
        try BackfillPageWalkFixture.insertHeader("orig", accountId: accountId, path: "INBOX", pool: pool)
        let stored = try await pool.read { db in
            try MessageHeader.filter(Column("folderId") == "\(accountId):INBOX" && Column("messageId") == "orig").fetchOne(db)
        }
        let original = try #require(stored, "precondition: the original is stored")
        let rfc = try #require(original.rfc822MessageId)
        try await tagReply(pool, headerId: original.id)
        return (original.id, rfc)
    }

    /// The stored Sent copy names the original (normalized), and the original's
    /// marks and queued tag changes are a forward's or a reply's.
    static func expectOtherAppCopyMarks(
        pool: DatabasePool, accountId: String, sentPath: String, copyMessageId: String,
        original: (id: String, rfc: String), isForward: Bool
    ) throws {
        let (copy, ops) = try pool.read { db in
            (try MessageHeader.filter(Column("folderId") == "\(accountId):\(sentPath)"
                && Column("messageId") == copyMessageId).fetchOne(db),
             try PendingOperation.filter(Column("accountId") == accountId && Column("type") == OperationType.setTag.rawValue).fetchAll(db))
        }
        let named = copy?.inReplyTo.map(EmailFilter.normalizeMessageId)
        #expect(named == original.rfc, "precondition: the Sent copy synced and names the original: \(named ?? "nil")")
        let want = expectedAfterOtherAppCopy(isForward: isForward)
        let after = try marks(pool, headerId: original.id)
        #expect(after == want, "after the Sent copy synced: \(after), want \(want)")
        #expect(ops.count == (isForward ? 0 : 1), "queued tag changes: \(ops.map { ($0.tagValue, $0.messageIds) })")
    }

    @Test("Scroll to older mail in Sent: another app's forward copy marks the original forwarded and keeps its Reply tag; a reply copy marks it replied",
          arguments: [true, false])
    func scrollOtherAppCopy(isForward: Bool) async throws {
        typealias F = BackfillPageWalkFixture
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        let accountId = "other-scroll-\(UUID().uuidString.prefix(8).lowercased())"
        _ = try FolderEpochTestFixture.makeAccount(id: accountId, provider: .gmail, pool: pool)
        try FolderEpochTestFixture.insertFolder(accountId: accountId, path: "INBOX", role: .inbox, pool: pool)
        try FolderEpochTestFixture.insertFolder(accountId: accountId, path: "SENT", role: .sent, pool: pool)
        let original = try await Self.storeOriginal(accountId: accountId, pool: pool)

        // Sent holds a newer message already; the other app's copy is older, so
        // scrolling Sent to older mail loads it.
        let server = StatefulGmailActionServer(messages: [
            F.gmailSeed("anchor", label: "SENT", daysAgo: 1),
            StatefulGmailActionServer.Seed(
                rfc822MessageId: "other-copy@example.com", providerMessageId: "othercopy", labels: ["SENT"],
                internalDate: F.daysAgo(5),
                headers: [
                    "In-Reply-To": "<\(original.rfc)>",
                    "References": "<\(original.rfc)>",
                    "Subject": Self.otherAppSubject("inserted orig", isForward: isForward),
                ]),
        ])
        defer { server.close() }
        try F.insertHeader("anchor", accountId: accountId, path: "SENT", pool: pool)
        try await pool.write { db in
            try db.execute(sql: "UPDATE messageHeader SET providerDate = date WHERE messageId = 'anchor'")
        }
        let sent = try #require(try FolderEpochTestFixture.readFolder(accountId: accountId, path: "SENT", pool: pool))
        let engine = await F.registeredEngine(accountId: accountId, provider: server.provider())

        _ = try await engine.fetchOlderMessages(folders: [sent])

        try Self.expectOtherAppCopyMarks(
            pool: pool, accountId: accountId, sentPath: "SENT", copyMessageId: "othercopy",
            original: original, isForward: isForward)
    }

    @Test("IMAP backfill walk of Sent: another app's forward copy marks the original forwarded and keeps its Reply tag; a reply copy marks it replied",
          arguments: [true, false])
    func backfillWalkOtherAppCopy(isForward: Bool) async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        let accountId = "other-walk-\(UUID().uuidString.prefix(8).lowercased())"
        let epoch = Self.imapEpoch + 2
        let account = try FolderEpochTestFixture.makeAccount(id: accountId, provider: .imap, pool: pool)
        try await pool.write { db in
            var inbox = Folder(name: "INBOX", path: "INBOX", role: .inbox, accountId: accountId)
            inbox.backfillComplete = true
            try inbox.insert(db)
        }
        let original = try await Self.storeOriginal(accountId: accountId, pool: pool)

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        let copy = FakeIMAPServer.makeMessage(uid: 7, rfc822Text: """
            From: Me <me@example.com>\r
            To: Someone <someone@example.com>\r
            Subject: \(Self.otherAppSubject("inserted orig", isForward: isForward))\r
            Date: \(formatter.string(from: Date().addingTimeInterval(-3_600)))\r
            Message-ID: <other-walk-copy@example.com>\r
            In-Reply-To: <\(original.rfc)>\r
            References: <\(original.rfc)>\r
            Content-Type: text/plain; charset=utf-8\r
            \r
            copy body.\r

            """)
        let server = FakeIMAPServer(mailboxes: ["INBOX": [], "Sent": [copy]])
        server.setUidValidity(epoch, for: "Sent")
        // A real server's ENVELOPE names the message a copy replies to.
        server.reportInReplyToInEnvelopes()
        try server.start()
        defer { server.stop() }
        try await pool.write { db in
            var sent = Folder(name: "Sent", path: "Sent", role: .sent, accountId: accountId)
            sent.backfillComplete = false
            sent.backfillUidCursor = 7
            sent.lastKnownUidValidity = epoch
            try sent.insert(db)
        }
        let imap = IMAPProvider(
            host: "127.0.0.1", port: server.port, username: server.username, password: server.password,
            smtpHost: "127.0.0.1", smtpPort: 587, useTLS: false)
        try await imap.connect()
        defer { Task { try? await imap.disconnect() } }
        let engine = SyncEngine()
        await engine.register(
            accountId: accountId, provider: imap,
            workQueue: ProviderWorkQueue(provider: imap, maxConcurrency: SyncConfig.imapMaxConnectionCeiling))

        _ = await engine.runBackfillWalk(account: account, deadline: BackfillPageWalkFixture.deadline())

        try Self.expectOtherAppCopyMarks(
            pool: pool, accountId: accountId, sentPath: "Sent", copyMessageId: "7",
            original: original, isForward: isForward)
        #expect(server.wrongMessageViolations().isEmpty)
        await engine.remove(accountId: accountId)
    }
}
