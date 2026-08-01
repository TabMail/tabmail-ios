/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

/// A folder purge must leave NO sidecar state behind for ANY message the folder
/// held — including a reply/forward draft's optimistic placeholder header.
///
/// THE INVARIANT (the system end state, not any mint's spelling): after
/// `(accountId, folderPath)` is purged, no FTS entry and no `chatIdMapping` row
/// keyed by a header id belonging to that folder survives. The FTS sweep
/// (`SearchIndex.removeMessagesForFolder`) and the `chatIdMapping` sweep
/// (`AccountManager.uidValidityResetPurgeTxn`) are PREFIX matches over the full
/// `headerId` string, because neither sidecar carries a `folderId` column of its
/// own — so they are paired with `MessageIdentity`'s no-deeper-colon guard, which
/// EXCLUDES a colon-bearing tail rather than erroring.
///
/// 🚨 THE DEFECT THIS PINS. `AccountManager.queueDraftSave` mints the optimistic
/// header's `messageId` as `draft-<Draft.id>`, and for a reply/forward `Draft.id`
/// is `Draft.draftKey`'s colon-joined composite `reply:<accountId>:<stableId>`
/// (`ComposeView` builds `stableKey = "\(accountId):\(stableId)"`; on IMAP
/// `MessageHeader.stableId` is the rfc822 Message-ID). Interpolated raw, the
/// header id carried FOUR colons where the format allows exactly two, so BOTH
/// guards silently skipped the row: the `messageHeader` row was deleted (that
/// delete is by `folderId` column, colon-blind) while its FTS entry, chat-id
/// mapping and body assets were left behind, orphaned, with nothing logged.
///
/// ⚠ THE FIX IS AT THE MINT, AND THESE TESTS MUST FAIL IF IT EVER MOVES TO THE
/// GUARDS. `nestedSiblingFolderSurvivesTheParentPurge` is that tripwire: under an
/// IMAP server whose hierarchy delimiter is ':', `acct:Drafts:Sub:77` is a
/// DIFFERENT folder's header that shares the `acct:Drafts:` prefix, and relaxing
/// the no-deeper-colon guard to "fix" the draft orphan would sweep it into the
/// parent's purge — the mirror image of the bug, and strictly worse than an
/// orphan (an over-purge destroys another folder's state).
@Suite("Reply-draft placeholders are purged with their folder", .serialized, .processGlobalState)
struct DraftPlaceholderFolderPurgeTests {

    // MARK: - Harness

    private static let draftsPath = "Drafts"
    /// A ':'-delimited CHILD of `Drafts` — the shape only an IMAP server with a
    /// ':' hierarchy delimiter produces, and the reason the guards exist at all.
    private static let siblingPath = "Drafts:Sub"

    /// Installs a temp `AppDatabase` as `AppDatabase.shared` (which is what the
    /// real `AccountManager.shared` reads through its computed `dbPool`) holding
    /// one IMAP account plus a drafts-role folder and its ':'-delimited child.
    ///
    /// `accountId` is unique per test: `SearchIndex.shared` is a process-global
    /// FTS database shared with every other suite, and the folder purge under
    /// test is a prefix sweep — a fixed account id would let concurrent suites'
    /// rows fall inside this test's purge prefix (and vice versa).
    @MainActor
    private func makeTestDB(accountId: String) throws -> (pool: DatabasePool, dir: URL, previous: AppDatabase?) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var config = Configuration()
        config.foreignKeysEnabled = true
        let pool = try DatabasePool(path: dir.appendingPathComponent("test.sqlite").path, configuration: config)
        let appDb = try AppDatabase(dbPool: pool)
        let previous = AppDatabase.shared.withLock { current -> AppDatabase? in
            let prev = current
            current = appDb
            return prev
        }

        try pool.writeWithoutTransaction { db in
            var acc = Account(emailAddress: "user@example.com", displayName: "Test", provider: .imap)
            acc.id = accountId
            try acc.insert(db)

            var drafts = Folder(name: "Drafts", path: Self.draftsPath, role: .drafts, accountId: accountId)
            drafts.lastKnownUidValidity = 12345
            try drafts.insert(db)

            var sibling = Folder(name: "Sub", path: Self.siblingPath, role: .custom, accountId: accountId)
            sibling.lastKnownUidValidity = 12345
            try sibling.insert(db)
        }
        return (pool, dir, previous)
    }

    private func restoreTestDB(pool: DatabasePool, previous: AppDatabase?, dir: URL) {
        InstalledTestDatabaseLifetime.finish(previous: previous, pool: pool, directory: dir)
    }

    /// A fresh local draft: no `serverDraftId`, so `queueDraftSave` classifies it
    /// APPEND-only and admits it (the epoch guard is never reached), and no
    /// `rfc822MessageId`, so production generates one exactly as it does live.
    @MainActor
    private func makeDraftRow(_ pool: DatabasePool, id: String, accountId: String) throws {
        let now = Date().timeIntervalSince1970
        let draft = Draft(
            id: id, accountId: accountId,
            toJSON: "[\"recipient@example.com\"]", ccJSON: "[]", bccJSON: "[]",
            subject: "Draft \(id.prefix(12))", body: "Zanzibarquixotic body text",
            replyToId: nil, isForward: false, editHistoryJSON: nil,
            createdAt: now, updatedAt: now,
            serverDraftId: nil, serverPushStatus: nil,
            rfc822MessageId: nil, attachmentsDirName: nil
        )
        try pool.writeWithoutTransaction { db in try draft.insert(db) }
    }

    /// Index one header straight into the shared FTS database, bypassing sync.
    private func indexFTS(headerId: String, messageId: String, folderId: String) async throws {
        _ = try await SearchIndex.shared.indexHeaders([
            FTSHeaderRecord( contentKey: ContentKey(rawValue: headerId),
                headerId: headerId, messageId: messageId,
                subject: "Zanzibarquixotic subject", from: "sender@example.com",
                to: "recipient@example.com",
                dateMs: Int64(Date().timeIntervalSince1970 * 1000),
                folderId: folderId
            )
        ])
    }

    private func isInFTS(_ headerId: String) async throws -> Bool {
        try await SearchIndex.shared.contentKeysMissingFromFTS([ContentKey(rawValue: headerId)]).isEmpty
    }

    private func chatMappingExists(_ pool: DatabasePool, realId: String) async throws -> Bool {
        try await pool.read { db in
            try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM chatIdMapping WHERE realId = ?", arguments: [realId]
            ) ?? 0
        } > 0
    }

    private func insertChatMapping(_ pool: DatabasePool, numericId: Int, realId: String) throws {
        try pool.writeWithoutTransaction { db in
            try db.execute(
                sql: "INSERT INTO chatIdMapping (numericId, realId) VALUES (?, ?)",
                arguments: [numericId, realId]
            )
        }
    }

    /// The header `queueDraftSave` actually minted for `draftId`, READ BACK from
    /// GRDB rather than recomputed. Recomputing the id in the test would pin the
    /// mint's spelling — the exact mechanism-pinning this suite must avoid.
    private func mintedDraftHeader(
        _ pool: DatabasePool, accountId: String, draftId: String
    ) async throws -> MessageHeader? {
        let rfc822 = try await pool.read { db in
            try Draft.fetchOne(db, key: draftId)?.rfc822MessageId
        }
        guard let rfc822 else { return nil }
        return try await pool.read { db in
            try MessageHeader
                .filter(Column("accountId") == accountId && Column("rfc822MessageId") == rfc822)
                .fetchOne(db)
        }
    }

    // MARK: - The defect + its over-refusal controls, in ONE end-state scenario

    @Test("A reply draft's FTS entry and chat mapping are GONE after its folder is purged")
    @MainActor
    func replyDraftSidecarsArePurgedWithTheFolder() async throws {
        let accountId = "purgetest-\(UUID().uuidString)"
        let (pool, dir, previous) = try makeTestDB(accountId: accountId)
        defer { restoreTestDB(pool: pool, previous: previous, dir: dir) }

        // 1. THE DEFECT'S SUBJECT — a reply draft. `Draft.draftKey` produces
        //    "reply:<accountId>:<stableId>"; on IMAP `stableId` is the parent's
        //    rfc822 Message-ID. Built through the real helper so the test cannot
        //    drift from what ComposeView does.
        let replyDraftId = Draft.draftKey(
            replyTo: "\(accountId):original-\(UUID().uuidString)@example.com",
            isForward: false, newId: nil
        )
        #expect(replyDraftId.contains(":"), "fixture precondition: a reply draft key is colon-joined")

        // 2. OVER-REFUSAL CONTROL A — a NORMAL (new) compose. ComposeView seeds
        //    `draftId` with a bare UUID, so its placeholder tail is colon-free and
        //    it was purged correctly even BEFORE the fix. If this goes red the
        //    purge itself broke.
        let plainDraftId = UUID().uuidString
        #expect(!plainDraftId.contains(":"), "fixture precondition: a new-compose draft key is colon-free")

        try makeDraftRow(pool, id: replyDraftId, accountId: accountId)
        try makeDraftRow(pool, id: plainDraftId, accountId: accountId)

        // Mint both optimistic headers through PRODUCTION code — header, body,
        // PendingOperation and FTS entry all come from `queueDraftSave` itself.
        await AccountManager.shared.queueDraftSave(draftId: replyDraftId, accountId: accountId)
        await AccountManager.shared.queueDraftSave(draftId: plainDraftId, accountId: accountId)

        let replyHeader = try await mintedDraftHeader(pool, accountId: accountId, draftId: replyDraftId)
        let plainHeader = try await mintedDraftHeader(pool, accountId: accountId, draftId: plainDraftId)
        let replyHeaderId = try #require(replyHeader?.id, "the reply draft's optimistic header must exist")
        let plainHeaderId = try #require(plainHeader?.id, "the new-compose draft's optimistic header must exist")

        // 3. OVER-REFUSAL CONTROL B — an ordinary synced message in the same
        //    folder (numeric IMAP UID, colon-free by construction).
        let syncedHeaderId = MessageIdentity.headerId(
            accountId: accountId, folderPath: Self.draftsPath, messageId: "42")
        try await indexFTS(
            headerId: syncedHeaderId, messageId: "42",
            folderId: MessageIdentity.folderId(accountId: accountId, folderPath: Self.draftsPath))

        // 4. ANTI-MIRROR-IMAGE CONTROL — a header in the ':'-delimited CHILD
        //    folder. It shares the parent's `acct:Drafts:` prefix and MUST NOT be
        //    swept by the parent's purge. Widening the guards to fix the draft
        //    orphan would take this row with it.
        let siblingHeaderId = MessageIdentity.headerId(
            accountId: accountId, folderPath: Self.siblingPath, messageId: "77")
        try await indexFTS(
            headerId: siblingHeaderId, messageId: "77",
            folderId: MessageIdentity.folderId(accountId: accountId, folderPath: Self.siblingPath))

        defer {
            let ids = [replyHeaderId, plainHeaderId, syncedHeaderId, siblingHeaderId]
            Task.detached { try? await SearchIndex.shared.removeMessages(contentKeys: ids.map(ContentKey.init(rawValue:))) }
        }

        // A chat pill mapping for each — the second sidecar the purge owns.
        try insertChatMapping(pool, numericId: 1, realId: replyHeaderId)
        try insertChatMapping(pool, numericId: 2, realId: plainHeaderId)
        try insertChatMapping(pool, numericId: 3, realId: siblingHeaderId)

        // ---- PRE-PURGE: non-vacuity, on BOTH sides. Everything is really there,
        // and the folder-scoped read model really sees the folder's own rows.
        #expect(try await isInFTS(replyHeaderId), "precondition: the reply draft is indexed")
        #expect(try await isInFTS(plainHeaderId), "precondition: the new-compose draft is indexed")
        #expect(try await isInFTS(syncedHeaderId), "precondition: the synced message is indexed")
        #expect(try await isInFTS(siblingHeaderId), "precondition: the child folder's message is indexed")
        #expect(try await chatMappingExists(pool, realId: replyHeaderId))
        #expect(try await chatMappingExists(pool, realId: plainHeaderId))
        #expect(try await chatMappingExists(pool, realId: siblingHeaderId))

        let scopedBefore = try await SearchIndex.shared.keywordSearch(
            query: "zanzibarquixotic",
            folderIds: [MessageIdentity.folderId(accountId: accountId, folderPath: Self.draftsPath)]
        ).map(\.contentKey.rawValue)
        #expect(scopedBefore.contains(plainHeaderId),
                "over-refusal control: a normal draft must be visible to a folder-scoped query")
        #expect(scopedBefore.contains(syncedHeaderId),
                "over-refusal control: a synced message must be visible to a folder-scoped query")

        // ---- THE PURGE. Both sweeps the UIDVALIDITY reaction runs for a folder.
        try await SearchIndex.shared.removeMessagesForFolder(
            accountId: accountId, folderPath: Self.draftsPath)
        _ = await AccountManager.shared.uidValidityResetPurgeTxn(
            accountId: accountId, folderPath: Self.draftsPath,
            folderId: MessageIdentity.folderId(accountId: accountId, folderPath: Self.draftsPath))

        // ---- POST-PURGE END STATE.

        // THE DEFECT. Pre-fix the reply draft's `messageHeader` row was deleted
        // (that delete is by `folderId` column) while these two survived — an
        // orphan with no owning row, and nothing logged.
        #expect(try await isInFTS(replyHeaderId) == false,
                "a reply draft's FTS entry must not survive its folder's purge")
        #expect(try await chatMappingExists(pool, realId: replyHeaderId) == false,
                "a reply draft's chat mapping must not survive its folder's purge")

        // OVER-REFUSAL CONTROLS — the purge still purges what it always did.
        #expect(try await isInFTS(plainHeaderId) == false,
                "over-refusal control: a normal draft must still be purged")
        #expect(try await chatMappingExists(pool, realId: plainHeaderId) == false,
                "over-refusal control: a normal draft's chat mapping must still be purged")
        #expect(try await isInFTS(syncedHeaderId) == false,
                "over-refusal control: an ordinary synced message must still be purged")

        // The owning rows are gone either way — which is what made the orphan
        // silent rather than self-correcting.
        let survivingDraftHeaders = try await pool.read { db in
            try MessageHeader
                .filter(Column("folderId") == MessageIdentity.folderId(
                    accountId: accountId, folderPath: Self.draftsPath))
                .fetchCount(db)
        }
        #expect(survivingDraftHeaders == 0)
    }

    @Test("A ':'-delimited CHILD folder survives its parent's purge")
    @MainActor
    func nestedSiblingFolderSurvivesTheParentPurge() async throws {
        // The tripwire for the mirror-image fix. If this goes red, the
        // no-deeper-colon guard was relaxed and one folder's purge now destroys
        // another folder's sidecar state.
        let accountId = "purgesibling-\(UUID().uuidString)"
        let (pool, dir, previous) = try makeTestDB(accountId: accountId)
        defer { restoreTestDB(pool: pool, previous: previous, dir: dir) }

        let parentHeaderId = MessageIdentity.headerId(
            accountId: accountId, folderPath: Self.draftsPath, messageId: "10")
        let childHeaderId = MessageIdentity.headerId(
            accountId: accountId, folderPath: Self.siblingPath, messageId: "20")
        try await indexFTS(
            headerId: parentHeaderId, messageId: "10",
            folderId: MessageIdentity.folderId(accountId: accountId, folderPath: Self.draftsPath))
        try await indexFTS(
            headerId: childHeaderId, messageId: "20",
            folderId: MessageIdentity.folderId(accountId: accountId, folderPath: Self.siblingPath))
        defer {
            let ids = [parentHeaderId, childHeaderId]
            Task.detached { try? await SearchIndex.shared.removeMessages(contentKeys: ids.map(ContentKey.init(rawValue:))) }
        }
        try insertChatMapping(pool, numericId: 1, realId: parentHeaderId)
        try insertChatMapping(pool, numericId: 2, realId: childHeaderId)

        #expect(try await isInFTS(parentHeaderId))
        #expect(try await isInFTS(childHeaderId))

        try await SearchIndex.shared.removeMessagesForFolder(
            accountId: accountId, folderPath: Self.draftsPath)
        _ = await AccountManager.shared.uidValidityResetPurgeTxn(
            accountId: accountId, folderPath: Self.draftsPath,
            folderId: MessageIdentity.folderId(accountId: accountId, folderPath: Self.draftsPath))

        #expect(try await isInFTS(parentHeaderId) == false,
                "the purged folder's own row must go")
        #expect(try await isInFTS(childHeaderId),
                "a ':'-delimited CHILD folder's FTS entry must NOT be swept by its parent's purge")
        #expect(try await chatMappingExists(pool, realId: parentHeaderId) == false)
        #expect(try await chatMappingExists(pool, realId: childHeaderId),
                "a ':'-delimited CHILD folder's chat mapping must NOT be swept by its parent's purge")
    }
}
