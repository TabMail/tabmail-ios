/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

/// Round 13 — the two refusals the epoch guards were missing, and the three
/// legitimate states they must keep ADMITTING.
///
/// Both properties asserted here are the SAME hard invariant from two sides:
/// **no row whose bare UID belongs to one numbering may end up under a stamp
/// describing another** (constraint C3). `MessageHeader.stableId` falls back to
/// the bare numeric `messageId` — the IMAP UID — whenever a header carries no
/// `rfc822MessageId`, native IMAP actions address that UID directly, and
/// `AccountManager.newGestureRefusedForUnknownEpoch` tests only
/// `lastKnownUidValidity == nil`. So a stamp that is non-nil but WRONG admits
/// every gesture on every such row and resolves it against whatever message now
/// occupies that number.
///
/// The two defects:
///  1. `SyncEngine.crawlWalkWriteAllowed` compared a folder's stored stamp
///     against the caller's premise through ONE optional chain, so *the row is
///     GONE* and *the row exists and is UNSTAMPED* both produced `nil` — and a
///     caller holding the legitimate unstamped premise (`nil`) was therefore
///     ADMITTED against a folder that no longer exists.
///  2. `SyncEngine.selfHealFolder` inserted IMAP headers with no epoch premise
///     at all. Its entire method is *diff a live UID list against the local
///     `messageId` column and fetch the difference*, which after a UIDVALIDITY
///     turnover diffs two different numberings and mass-inserts the new one into
///     a folder still stamped with the old.
///
/// The three admission controls exist because a fix that closes a fail-open hole
/// very often opens a fail-closed one: an over-refusing epoch guard silently
/// stops crawling or stops repairing, which is mail the user never sees.
///
/// ⚑ R0: `v2final`'s `uidValidityWalkWriteAllowed` has the identical
/// missing-row collapse, and its self-heal DOES pass an epoch — but a mirror
/// read (`lastObservedUidValidity`) whose safety there rests on the ADR-IOS-061
/// Stage-2 provider refusal (`selectMailboxTracked` throws
/// `ProviderError.uidValidityChanged`), a term v3 does not have at all. Neither
/// transfers; see the two production sites for the full argument.
///
/// `.serialized, .processGlobalState` — replaces `AppDatabase.shared` and binds
/// a listening socket via `FakeIMAPServer`.
@Suite("Round 13 — the epoch guards refuse what they cannot describe", .serialized, .processGlobalState)
struct EpochGuardRefusalTests {

    // MARK: - Fixtures

    /// `FakeIMAPServer.defaultCapabilities` minus UIDPLUS, so no epoch can reach
    /// `Folder.lastKnownUidValidity` from STATUS and every epoch in play came
    /// from a SELECT.
    private static let nonUidplusCapabilities =
        ["IMAP4rev1", "AUTH=PLAIN", "LITERAL+", "ID", "NAMESPACE", "MOVE", "IDLE"]

    private static func rfc822(messageId: String, subject: String) -> String {
        """
        From: Test Sender <sender@example.com>\r
        To: Recipient <recipient@example.com>\r
        Subject: \(subject)\r
        Date: Thu, 01 Jan 2026 00:00:00 +0000\r
        Message-ID: <\(messageId)>\r
        Content-Type: text/plain; charset=utf-8\r
        \r
        epoch guard fixture body.\r

        """
    }

    private static func message(uid: Int, id: String, subject: String = "fixture") -> FakeIMAPServer.Message {
        FakeIMAPServer.makeMessage(uid: uid, rfc822Text: rfc822(messageId: id, subject: subject))
    }

    private static func provider(for server: FakeIMAPServer) -> IMAPProvider {
        IMAPProvider(
            host: "127.0.0.1",
            port: server.port,
            username: server.username,
            password: server.password,
            smtpHost: "127.0.0.1",
            smtpPort: 587,
            useTLS: false
        )
    }

    private static func makeEngine(accountId: String, provider: IMAPProvider) async -> SyncEngine {
        let engine = SyncEngine()
        await engine.register(
            accountId: accountId, provider: provider,
            workQueue: ProviderWorkQueue(provider: provider, maxConcurrency: SyncConfig.imapMaxConnectionCeiling))
        return engine
    }

    /// A local row whose `messageId` IS a bare IMAP UID and which carries no
    /// `rfc822MessageId`, so `MessageHeader.stableId` falls back to that bare
    /// UID. That fallback is the entire reason the epoch matters.
    private static func insertHeader(
        accountId: String, path: String, uid: String, pool: DatabasePool
    ) throws {
        var header = MessageHeader(
            messageId: uid, subject: "pre-existing fixture \(uid)", from: "Sender",
            fromAddress: "sender@example.com", to: "recipient@example.com",
            date: Date(), snippet: "snippet",
            folderId: "\(accountId):\(path)", accountId: accountId, folderPath: path,
            isInInbox: false
        )
        header.headerComplete = true
        header.rfc822MessageId = nil
        let toInsert = header
        try pool.write { db in try toInsert.insert(db) }
    }

    private static func headers(_ pool: DatabasePool, folderId: String) throws -> [MessageHeader] {
        try pool.read { db in
            try MessageHeader.filter(Column("folderId") == folderId)
                .order(Column("messageId"))
                .fetchAll(db)
        }
    }

    private static func headerInfo(uid: Int, rfc822: String?) -> MessageHeaderInfo {
        MessageHeaderInfo(
            messageId: "\(uid)",
            rfc822MessageId: rfc822,
            inReplyTo: nil,
            references: [],
            threadId: nil,
            subject: "epoch guard fixture \(uid)",
            from: "Sender",
            fromAddress: "sender@example.com",
            to: "recipient@example.com",
            cc: "",
            bcc: "",
            replyTo: nil,
            date: Date(),
            snippet: "snippet",
            isRead: false,
            isFlagged: false,
            hasAttachments: false,
            isReplied: false,
            isForwarded: false,
            actionTag: nil
        )
    }

    private static func landed(_ outcome: SyncEngine.BackfillBatchOutcome) -> Bool {
        if case .landed = outcome { return true }
        return false
    }

    // MARK: - Blocker 1 — the CAS and the folder row that is not there

    /// 🚨 THE INVARIANT: **a batch is never reported as LANDED when the folder it
    /// names does not exist.** Asserted on what the caller is TOLD, because that
    /// is what the caller acts on: the backfill walk reads a non-refusal as "this
    /// range is accounted for" and calls `UIDWalkCursor.confirmRange`, which
    /// advances the crawl past mail that was never stored — the
    /// "never mark unfetched content as fetched" rule, one level up. It is NOT
    /// asserted as "the guard returned false", which is the mechanism and which
    /// would stay green on a system where the caller ignored it.
    ///
    /// The premise is `.init(nil)` — the LEGITIMATE unstamped-folder premise a
    /// crawl holds for any folder `bootstrapCrawledFolderUidValidity` refuses to
    /// stamp. That is the whole point: it is the one premise value that a missing
    /// row could impersonate.
    ///
    /// ⚠ **The second `#expect` is NOT a formality, and the database does not
    /// hold that line.** `v1_createTables` declares `messageHeader.folderId` with
    /// `.references("folder", onDelete: .cascade)`, but migration
    /// `v2_dropMessageHeaderFolderFK` rebuilds the table with `folderId` as a
    /// plain column and NO foreign key — so nothing below this guard refuses an
    /// orphan. With the guard inverted both expectations failed: the outcome was
    /// `.landed(inserted: 1, …)` AND a real `messageHeader` row was written
    /// naming a folder id with no row behind it.
    @Test("A batch is never reported as landed when the folder row it names is gone")
    @MainActor
    func aBatchIsNeverReportedAsLandedWhenItsFolderRowIsGone() async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }

        let accountId = "r13-missing-folder-row"
        _ = try FolderEpochTestFixture.makeAccount(id: accountId, provider: .imap, pool: pool)
        // No folder row is ever inserted: the state a walk reaches when the
        // account is removed, the folder is deleted, or a folder-list rebuild is
        // mid-flight while a chunk it already fetched sits outside SQLite.
        let folderId = "\(accountId):Receipts"

        let engine = SyncEngine()
        let outcome = await engine.insertBackfillBatch(
            [Self.headerInfo(uid: 42, rfc822: "gone-folder@example.com")],
            folderId: folderId,
            accountId: accountId,
            folderPath: "Receipts",
            folderRole: .custom,
            isInInbox: false,
            epochPremise: .init(nil),
            observedEpoch: nil
        )

        #expect(!Self.landed(outcome),
                """
                the insert was reported as LANDED for a folder whose row does not exist — the \
                caller (`SyncEngine.runBackfill`) reads that as "this range is accounted for" and \
                confirms it, advancing the crawl past mail that was never stored. The premise \
                was the legitimate UNSTAMPED one (`.init(nil)`), which a missing row \
                impersonated because both collapsed to a nil stored epoch.
                """)
        #expect(try Self.headers(pool, folderId: folderId).isEmpty,
                "a header row was written naming a folder that does not exist")
    }

    /// THE MIRROR IMAGE, and the reason blocker 1's fix is a `guard let` on the
    /// ROW rather than on the epoch: an unstamped folder that EXISTS is a real
    /// and common crawl state — any folder holding rows of unproven epoch, which
    /// `bootstrapCrawledFolderUidValidity` refuses to stamp — and it is exactly
    /// the state `CrawlEpochPremise` was introduced to keep GUARDED rather than
    /// un-guarded. Refusing it would stop the crawl inserting anything into every
    /// such folder: mail the user never sees, permanently.
    ///
    /// This control passes on both trees. It is not a red proof and is not
    /// dressed as one; it exists so that a future "tighten the guard" round
    /// cannot close the hole in blocker 1 by refusing everything.
    @Test("An unstamped folder that still EXISTS still accepts the unstamped premise")
    @MainActor
    func anUnstampedFolderThatStillExistsStillAcceptsTheUnstampedPremise() async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }

        let accountId = "r13-unstamped-present"
        _ = try FolderEpochTestFixture.makeAccount(id: accountId, provider: .imap, pool: pool)
        try FolderEpochTestFixture.insertFolder(
            accountId: accountId, path: "Receipts", role: .custom, pool: pool,
            lastKnownUidValidity: nil)
        let folderId = "\(accountId):Receipts"

        let engine = SyncEngine()
        let outcome = await engine.insertBackfillBatch(
            [Self.headerInfo(uid: 42, rfc822: "unstamped-present@example.com")],
            folderId: folderId,
            accountId: accountId,
            folderPath: "Receipts",
            folderRole: .custom,
            isInInbox: false,
            epochPremise: .init(nil),
            observedEpoch: nil
        )

        #expect(Self.landed(outcome),
                "the crawl was refused on a folder that exists and is genuinely unstamped")
        #expect(try Self.headers(pool, folderId: folderId)
                    .contains { $0.rfc822MessageId == "unstamped-present@example.com" },
                "the crawl's row never reached a folder it was entitled to write to")
    }

    // MARK: - Blocker 2 — self-heal across a UIDVALIDITY turnover

    /// 🚨 THE INVARIANT: **self-heal never adds a row whose UID belongs to a
    /// numbering the folder's stamp does not describe.** Asserted on the folder's
    /// durable contents, not on which of the three guard terms declined.
    ///
    /// The fixture is the turnover itself: the folder's rows are stamped
    /// `staleEpoch` and carry bare UIDs, the server is on `liveEpoch`, and the
    /// server's mail is not present locally — so self-heal's SEARCH-vs-local diff
    /// reports it "missing" and, unguarded, fetches and inserts it. The folder
    /// then holds UIDs from two numberings under ONE non-nil stamp, and every
    /// bare-UID gesture on all of them is admitted.
    ///
    /// This is the state the backfill walk already refuses at
    /// `crawlEpochGate` and that `insertBackfillBatch`'s CAS already refuses for
    /// the walk's chunks. Self-heal reached the same table with neither.
    @Test("Self-heal never inserts headers from a numbering the folder is not stamped with")
    @MainActor
    func selfHealNeverInsertsHeadersFromAnUnstampedNumbering() async throws {
        let staleEpoch = 915_101   // what the folder's rows are stamped with
        let liveEpoch = 915_102    // what the server is on now
        let decoyRfc = "selfheal-turnover-decoy@example.com"

        let server = FakeIMAPServer(
            capabilities: Self.nonUidplusCapabilities,
            mailboxes: ["INBOX": [Self.message(uid: 42, id: decoyRfc, subject: "post-turnover mail")]])
        server.setUidValidity(liveEpoch, for: "INBOX")
        try server.start()
        defer { server.stop() }

        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }

        let accountId = "r13-selfheal-turnover"
        let account = try FolderEpochTestFixture.makeAccount(id: accountId, provider: .imap, pool: pool)
        try FolderEpochTestFixture.insertFolder(
            accountId: accountId, path: "INBOX", role: .inbox, pool: pool,
            lastKnownUidValidity: staleEpoch)
        let folderId = "\(accountId):INBOX"
        // A pre-turnover row, bare UID and no RFC Message-ID: it is what makes
        // the stale stamp describe REAL data, so nothing may advance it.
        try Self.insertHeader(accountId: accountId, path: "INBOX", uid: "7", pool: pool)

        let imap = Self.provider(for: server)
        try await imap.connect()
        defer { Task { try? await imap.disconnect() } }
        let engine = await Self.makeEngine(accountId: accountId, provider: imap)
        let folder = try #require(
            try FolderEpochTestFixture.readFolder(accountId: accountId, path: "INBOX", pool: pool))

        await engine.selfHealRecentMessages(account: account, forceSingleFolder: folder)

        let rows = try Self.headers(pool, folderId: folderId)
        #expect(!rows.contains { $0.rfc822MessageId == decoyRfc },
                """
                self-heal fetched a message under UIDVALIDITY \(liveEpoch) and inserted it into a \
                folder stamped \(staleEpoch). The folder now holds UIDs from two numberings under \
                one stamp, and because that stamp is non-nil \
                `AccountManager.newGestureRefusedForUnknownEpoch` ADMITS every bare-UID gesture on \
                all of them — a gesture on the pre-turnover row resolves its number in the live \
                mailbox and mutates a message it never targeted (C3). \
                Rows: \(rows.map { "\($0.messageId)=\($0.rfc822MessageId ?? "-")" })
                """)
        let after = try FolderEpochTestFixture.readFolder(accountId: accountId, path: "INBOX", pool: pool)
        #expect(after?.lastKnownUidValidity == staleEpoch,
                "self-heal must not advance a stamp either — it has no purge-and-resync reaction to run")
    }

    /// THE MIRROR IMAGE #1 — self-heal must still repair when the folder's stamp
    /// and the live mailbox AGREE, which is the overwhelmingly common case. A
    /// guard that refused here would silently disable UID-gap repair for every
    /// IMAP account, and the symptom (mail that exists on the server and never
    /// appears locally) is precisely the one self-heal exists to fix.
    ///
    /// Passes on both trees, by construction. It is an over-refusal control, not
    /// a red proof.
    @Test("Self-heal still repairs a real UID gap when the folder and the server agree")
    @MainActor
    func selfHealStillRepairsWhenTheEpochsAgree() async throws {
        let liveEpoch = 915_201
        let repairedRfc = "selfheal-repaired@example.com"

        let server = FakeIMAPServer(
            capabilities: Self.nonUidplusCapabilities,
            mailboxes: ["INBOX": [Self.message(uid: 42, id: repairedRfc, subject: "gap mail")]])
        server.setUidValidity(liveEpoch, for: "INBOX")
        try server.start()
        defer { server.stop() }

        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }

        let accountId = "r13-selfheal-agrees"
        let account = try FolderEpochTestFixture.makeAccount(id: accountId, provider: .imap, pool: pool)
        try FolderEpochTestFixture.insertFolder(
            accountId: accountId, path: "INBOX", role: .inbox, pool: pool,
            lastKnownUidValidity: liveEpoch)
        let folderId = "\(accountId):INBOX"
        try Self.insertHeader(accountId: accountId, path: "INBOX", uid: "7", pool: pool)

        let imap = Self.provider(for: server)
        try await imap.connect()
        defer { Task { try? await imap.disconnect() } }
        let engine = await Self.makeEngine(accountId: accountId, provider: imap)
        let folder = try #require(
            try FolderEpochTestFixture.readFolder(accountId: accountId, path: "INBOX", pool: pool))

        await engine.selfHealRecentMessages(account: account, forceSingleFolder: folder)

        let rows = try Self.headers(pool, folderId: folderId)
        #expect(rows.contains { $0.rfc822MessageId == repairedRfc },
                """
                self-heal refused a folder whose stamp (\(liveEpoch)) matches the live mailbox — \
                UID-gap repair is now off for every IMAP account, and the mail this pass exists to \
                recover stays missing. Rows: \(rows.map { "\($0.messageId)=\($0.rfc822MessageId ?? "-")" })
                """)
    }

    /// THE MIRROR IMAGE #2 — a server that reports NO UIDVALIDITY on SELECT.
    /// Nothing is ever stamped for such an account, so every gesture on its rows
    /// stays refused by `newGestureRefusedForUnknownEpoch` and no bare UID is
    /// ever resolved against the wrong numbering — the accepted `IOS-EPOCH-001`
    /// window. Self-heal must keep working there rather than treating "no epoch
    /// on either side" as a disagreement, which is precisely how a nil-collapsing
    /// comparison would fail.
    ///
    /// It also covers the nil that `fetchMessageHeadersWithObservedEpoch` returns
    /// when no batch reported an epoch: both sides nil must ADMIT.
    ///
    /// Passes on both trees; over-refusal control, not a red proof.
    @Test("Self-heal still repairs on a server that reports no UIDVALIDITY at all")
    @MainActor
    func selfHealStillRepairsOnAnEpochlessServer() async throws {
        let repairedRfc = "selfheal-epochless@example.com"

        let server = FakeIMAPServer(
            capabilities: Self.nonUidplusCapabilities,
            mailboxes: ["INBOX": [Self.message(uid: 42, id: repairedRfc, subject: "gap mail")]])
        server.suppressSelectUidValidity(for: "INBOX")
        try server.start()
        defer { server.stop() }

        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }

        let accountId = "r13-selfheal-epochless"
        let account = try FolderEpochTestFixture.makeAccount(id: accountId, provider: .imap, pool: pool)
        try FolderEpochTestFixture.insertFolder(
            accountId: accountId, path: "INBOX", role: .inbox, pool: pool,
            lastKnownUidValidity: nil)
        let folderId = "\(accountId):INBOX"
        try Self.insertHeader(accountId: accountId, path: "INBOX", uid: "7", pool: pool)

        let imap = Self.provider(for: server)
        try await imap.connect()
        defer { Task { try? await imap.disconnect() } }
        let engine = await Self.makeEngine(accountId: accountId, provider: imap)
        let folder = try #require(
            try FolderEpochTestFixture.readFolder(accountId: accountId, path: "INBOX", pool: pool))

        await engine.selfHealRecentMessages(account: account, forceSingleFolder: folder)

        let rows = try Self.headers(pool, folderId: folderId)
        #expect(rows.contains { $0.rfc822MessageId == repairedRfc },
                """
                self-heal refused an account whose server reports no UIDVALIDITY on SELECT. That \
                account's folders are never stamped, so its gestures are already refused and there \
                is no wrong-numbering hazard to guard against — refusing here only costs the user \
                the repair. Rows: \(rows.map { "\($0.messageId)=\($0.rfc822MessageId ?? "-")" })
                """)
    }
}
