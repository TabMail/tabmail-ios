/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Testing
@testable import TabMail

/// Pins `NotificationActionRouter.execute` at the ADR-IOS-060 identity
/// boundary: notification actions may use provider transport IDs to locate a
/// durable or staged header, but every new message-action job carries only a
/// normalized RFC Message-ID. A supplied malformed RFC is refused; only a
/// legacy payload with no RFC field may attempt exact source-scoped local
/// recovery. A true cold miss uses the payload's valid RFC identity directly
/// and never persists the transport ID.
///
/// Eight end-state properties are pinned:
/// 1. A durable header + ARCHIVE routes through the production AccountManager
///    move path — the row moves to Archive and the durable operation carries
///    the header's RFC identity with the original folder as its source.
/// 2. No header anywhere (cold background launch, staged cache empty) +
///    ARCHIVE queues a `.move` using the valid RFC payload identity, inbox
///    source path, and archive destination path.
/// 3. No header anywhere + MARK_READ falls back to a `.markRead` op with
///    the valid RFC payload identity and inbox source path.
/// 4. A durable header + DELETE routes through the same production move path
///    and ends in Trash.
/// 5. Same UID in two folders (IMAP UIDs are folder-scoped): ARCHIVE acts on
///    the INBOX row only — the other folder's unrelated row is untouched
///    (the round-3 `isInInbox = 1` scoping regression pin).
/// 6-8. An exact staged hit for ARCHIVE/DELETE/MARK_READ takes the same
///    AccountManager path as a durable row: after the stateful staging-merge
///    double commits the row, final local state and the RFC-addressed durable
///    operation both match the requested action. Provider IDs remain lookup-only.
///
/// `.serialized`: tests swap `AppDatabase.shared` and drive `AccountManager
/// .shared`'s write paths — mirrors `CoordinatedToolActionTests`.
@Suite("NotificationActionRouter — notification-action dispatch fix", .serialized, .processGlobalState)
struct NotificationActionRouterTests {

    // MARK: - Harness (mirrors CoordinatedToolActionTests.swift)

    private func makeTestDB() throws -> (pool: DatabasePool, inbox: Folder, archive: Folder, trash: Folder, dir: URL, previous: AppDatabase?) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var config = Configuration()
        config.foreignKeysEnabled = true
        let pool = try DatabasePool(path: dir.appendingPathComponent("test.sqlite").path, configuration: config)
        let appDb = try AppDatabase(dbPool: pool)
        let previous = AppDatabase.shared.withLock { current -> AppDatabase? in
            let prev = current; current = appDb; return prev
        }
        // Pre-existing pins assert the single .move op; force mark-read-on-
        // archive/delete OFF so they keep exercising exactly that behavior
        // (mirrors CoordinatedToolActionTests). The dedicated ON test below
        // flips it back via the same key.
        UserDefaults.standard.set(false, forKey: AccountManager.markReadOnArchiveDeleteKey)
        try pool.writeWithoutTransaction { db in
            var acc = Account(emailAddress: "test@example.com", displayName: "Test", provider: .gmail)
            acc.id = "acc1"
            try acc.insert(db)
        }
        let inbox = Folder(name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")
        let archive = Folder(name: "Archive", path: "Archive", role: .archive, accountId: "acc1")
        let trash = Folder(name: "Trash", path: "Trash", role: .trash, accountId: "acc1")
        try pool.writeWithoutTransaction { db in
            let i = inbox; try i.insert(db)
            let a = archive; try a.insert(db)
            let t = trash; try t.insert(db)
        }
        return (pool, inbox, archive, trash, dir, previous)
    }

    /// A durable, query-visible header (`headerComplete = true`) for a folder.
    private func makeDurableHeader(folder: Folder, messageId: String) -> MessageHeader {
        var h = MessageHeader(
            messageId: messageId, subject: "Subj \(messageId)", from: "Sender", fromAddress: "s@example.com",
            to: "me@example.com", date: Date(), snippet: "snip",
            folderId: folder.id, accountId: folder.accountId, folderPath: folder.path,
            isInInbox: folder.role == .inbox
        )
        h.rfc822MessageId = "\(messageId)@example.com"
        h.headerComplete = true
        return h
    }

    /// Teardown shared by every test. Mirrors `CoordinatedToolActionTests.restoreTestDB`:
    /// production paths driven here (drainPendingQueue, unread recounts) fire
    /// unstructured background Tasks the drain barrier cannot join, so they can run
    /// AFTER the defers — leave the test DB alive when there's no previous one to
    /// restore, rather than let `AppDatabase.rawPool`'s force-unwrap crash the process.
    private func restoreTestDB(previous: AppDatabase?, dir: URL) {
        UserDefaults.standard.removeObject(forKey: AccountManager.markReadOnArchiveDeleteKey)
        if previous != nil {
            AppDatabase.shared.withLock { $0 = previous }
            try? FileManager.default.removeItem(at: dir)
        }
    }

    /// Cold-path tests must not accidentally resolve via a staged row left
    /// over from another test — the message ids used below are unique to this
    /// suite, but clearing the global keeps the "no header anywhere" premise
    /// explicit and mirrors `InboxGestureActionTests.resetStagedGlobal`.
    private func resetStagedGlobal() {
        NSEDataBridge.latestStagedRows.withLock { $0 = [] }
        #if DEBUG
        NotificationActionRouter.prepareStagedHeaderForActionForTesting.withLock { $0 = nil }
        #endif
    }

    /// The real app's `ensureDurable` drains the App Group staging database
    /// before the manager action writes. XCTest has no App Group container, so
    /// model that one external boundary statefully: commit the exact staged
    /// header when the router is about to dispatch it, then let the unmodified
    /// production AccountManager path determine both local and queue end state.
    private func installStagedMergeDouble(pool: DatabasePool) {
        #if DEBUG
        NotificationActionRouter.prepareStagedHeaderForActionForTesting.withLock { hook in
            hook = { header in
                try await pool.writeWithoutTransaction { db in
                    try header.insert(db)
                }
            }
        }
        #endif
    }

    /// An NSE-staged (not-yet-durable) row for the STAGED-hit branch —
    /// mirrors `InboxGestureActionTests.makeStagedRow`, with
    /// `rfc822MessageId` is exposed because staged lookup uses the provider ID
    /// while durable admission must use the normalized RFC identity.
    private func makeStagedRow(accountId: String, messageId: String, rfc822MessageId: String?) -> StagedInboxRow {
        StagedInboxRow(
            accountId: accountId, folderPath: "INBOX", messageId: messageId,
            rfc822MessageId: rfc822MessageId, threadId: nil, inReplyTo: nil, references: [],
            subject: "Subj \(messageId)", senderName: "Sender", senderAddress: "s@example.com",
            to: "me@example.com", snippet: "snip", date: Date(),
            isRead: false, isFlagged: false, hasAttachments: false, isReplied: false,
            isForwarded: false, actionTag: nil, summaryBlurb: nil
        )
    }

    // MARK: - (1) Durable header + ARCHIVE

    @Test("durable header + ARCHIVE routes through AccountManager.archive: row moves to Archive, ONE .move PendingOperation is queued with the original folder as source")
    func durableHeaderArchiveRoutesThroughManager() async throws {
        let (pool, inbox, archive, _, dir, previous) = try makeTestDB()
        defer { restoreTestDB(previous: previous, dir: dir) }

        let header = makeDurableHeader(folder: inbox, messageId: "m-archive-durable")
        try await pool.writeWithoutTransaction { db in try header.insert(db) }
        let id = header.id

        await NotificationActionRouter.execute(
            actionId: "ARCHIVE", transportMessageId: "m-archive-durable",
            rfc822MessageId: "m-archive-durable@example.com", accountId: "acc1"
        )

        let final = try await pool.read { db in try MessageHeader.fetchOne(db, key: id) }
        #expect(final?.folderId == archive.id)
        #expect(final?.folderPath == archive.path)

        let ops = try await pool.read { db in try PendingOperation.fetchAll(db) }
        #expect(ops.count == 1)
        guard ops.count == 1 else { return }
        #expect(ops[0].type == .move)
        #expect(ops[0].folderPath == inbox.path, "source folderPath must be the ORIGINAL (inbox) path")
        #expect(ops[0].destinationPath == archive.path)
        #expect(ops[0].messageIds == ["m-archive-durable@example.com"])

        // The public router call waits for its AccountManager work to finish,
        // so it must not leave a staged intention behind.
        #expect(AccountManager.shared.intentionJournal.isFullyDrainedForTesting(), "notification action must leave no stranded intention")
    }

    @Test("notification ARCHIVE with mark-read-on-archive ON composes read + move: header read and archived locally, both durable ops queued")
    func notificationArchiveComposesReadWhenSettingOn() async throws {
        let (pool, inbox, archive, _, dir, previous) = try makeTestDB()
        defer { restoreTestDB(previous: previous, dir: dir) }
        // makeTestDB forces the setting OFF for the legacy pins — this test
        // covers the owner-requested uniform behavior, so flip it ON.
        UserDefaults.standard.set(true, forKey: AccountManager.markReadOnArchiveDeleteKey)

        var unread = makeDurableHeader(folder: inbox, messageId: "m-archive-markread")
        unread.isRead = false
        let header = unread
        try await pool.writeWithoutTransaction { db in try header.insert(db) }
        let id = header.id

        await NotificationActionRouter.execute(
            actionId: "ARCHIVE", transportMessageId: "m-archive-markread",
            rfc822MessageId: "m-archive-markread@example.com", accountId: "acc1"
        )

        let final = try await pool.read { db in try MessageHeader.fetchOne(db, key: id) }
        #expect(final?.folderId == archive.id)
        #expect(final?.isRead == true, "a notification archive marks the message read when the setting is ON")

        let ops = try await pool.read { db in
            try PendingOperation.fetchAll(db).sorted { $0.type.rawValue < $1.type.rawValue }
        }
        let opTypes = Set(ops.map(\.type))
        #expect(opTypes == [.move, .markRead], "read intent composes with the move through the same fold")
        #expect(AccountManager.shared.intentionJournal.isFullyDrainedForTesting())
    }

    @Test("canonical RFC action lookup matches a whitespace-wrapped bracketed durable header")
    func bracketedDurableRFCResolves() async throws {
        let (pool, inbox, archive, _, dir, previous) = try makeTestDB()
        defer { restoreTestDB(previous: previous, dir: dir); resetStagedGlobal() }
        resetStagedGlobal()

        var header = makeDurableHeader(folder: inbox, messageId: "bracketed-provider-id")
        header.rfc822MessageId = "  \t<bracketed-action@example.com>  "
        let headerToInsert = header
        try await pool.writeWithoutTransaction { db in try headerToInsert.insert(db) }

        await NotificationActionRouter.execute(
            actionId: "ARCHIVE",
            transportMessageId: "bracketed-provider-id",
            rfc822MessageId: "bracketed-action@example.com",
            accountId: "acc1"
        )

        let moved = try await pool.read { db in
            try MessageHeader.fetchOne(db, key: headerToInsert.id)
        }
        #expect(moved?.folderId == archive.id)
        let ops = try await pool.read { db in try PendingOperation.fetchAll(db) }
        #expect(ops.count == 1)
        guard ops.count == 1 else { return }
        #expect(ops[0].messageIds == ["bracketed-action@example.com"])
    }

    // MARK: - (2) No header anywhere + ARCHIVE

    @Test("no header anywhere (cold background launch) + ARCHIVE queues a .move using the payload RFC identity")
    func noHeaderArchiveQueuesColdMoveOp() async throws {
        let (pool, inbox, archive, _, dir, previous) = try makeTestDB()
        defer { restoreTestDB(previous: previous, dir: dir); resetStagedGlobal() }
        resetStagedGlobal()

        // HONESTY NOTE: `NotificationActionRouter.execute` runs one
        // `NSEMergeCoordinator.shared.merge()` pass before falling back to
        // `queueColdPendingOperation` (see the enum doc comment in
        // AppDelegate.swift) — in a real cold-background-launch, that merge
        // pass can pull an already-staged (App Group) row durable and the
        // retried lookup succeeds, dispatching through the coordinated
        // move path instead of the cold fallback. In the TEST HOST, `merge()`
        // no-ops (no app-group container), so this test can only ever reach
        // the cold-fallback branch — it pins the full-cold-miss contract
        // below; the merge-succeeds recovery branch is structurally
        // unreachable in this harness (same convention as
        // InboxGestureActionTests.swift's staged-row HONESTY NOTE, ~line 1467).
        await NotificationActionRouter.execute(
            actionId: "ARCHIVE", transportMessageId: "m-cold-archive",
            rfc822MessageId: "<m-cold-archive@example.com>", accountId: "acc1"
        )

        let ops = try await pool.read { db in try PendingOperation.fetchAll(db) }
        #expect(ops.count == 1)
        guard ops.count == 1 else { return }
        #expect(ops[0].type == .move)
        #expect(ops[0].folderPath == inbox.path)
        #expect(ops[0].destinationPath == archive.path)
        #expect(ops[0].messageIds == ["m-cold-archive@example.com"])
        #expect(ops[0].accountId == "acc1")

        let headerCount = try await pool.read { db in try MessageHeader.fetchCount(db) }
        #expect(headerCount == 0, "no header was ever created — the cold path never synthesizes one")
    }

    // MARK: - (2b) No header anywhere + DELETE

    /// The DELETE cell of the cold fallback (`queueColdPendingOperation`,
    /// AppDelegate.swift): the `role: .trash` arm of the ARCHIVE/DELETE
    /// ternary — sits next to the cold ARCHIVE pin above so BOTH cold
    /// `.move` router cells are covered, not just the archive side.
    @Test("no header anywhere (cold background launch) + DELETE queues a .move using the payload RFC identity")
    func noHeaderDeleteQueuesColdMoveOp() async throws {
        let (pool, inbox, _, trash, dir, previous) = try makeTestDB()
        defer { restoreTestDB(previous: previous, dir: dir); resetStagedGlobal() }
        resetStagedGlobal()

        // HONESTY NOTE (see the identical note on noHeaderArchiveQueuesColdMoveOp
        // above): the test host's `NSEMergeCoordinator.merge()` no-ops (no
        // app-group container), so this test pins only the full-cold-miss
        // contract — the merge-succeeds recovery branch (a staged row becomes
        // durable and the retried lookup finds it) is structurally
        // unreachable in this harness.
        await NotificationActionRouter.execute(
            actionId: "DELETE", transportMessageId: "m-cold-delete",
            rfc822MessageId: "m-cold-delete@example.com", accountId: "acc1"
        )

        let ops = try await pool.read { db in try PendingOperation.fetchAll(db) }
        #expect(ops.count == 1)
        guard ops.count == 1 else { return }
        #expect(ops[0].type == .move)
        #expect(ops[0].folderPath == inbox.path)
        #expect(ops[0].destinationPath == trash.path)
        #expect(ops[0].messageIds == ["m-cold-delete@example.com"])
        #expect(ops[0].accountId == "acc1")

        let headerCount = try await pool.read { db in try MessageHeader.fetchCount(db) }
        #expect(headerCount == 0, "no header was ever created — the cold path never synthesizes one")
    }

    // MARK: - (3) No header anywhere + MARK_READ

    @Test("no header anywhere + MARK_READ queues a .markRead PendingOperation directly against the inbox path")
    func noHeaderMarkReadQueuesColdMarkReadOp() async throws {
        let (pool, inbox, _, _, dir, previous) = try makeTestDB()
        defer { restoreTestDB(previous: previous, dir: dir); resetStagedGlobal() }
        resetStagedGlobal()

        // HONESTY NOTE (see the identical note on noHeaderArchiveQueuesColdMoveOp
        // above): the test host's `NSEMergeCoordinator.merge()` no-ops (no
        // app-group container), so this test pins only the full-cold-miss
        // contract — the merge-succeeds recovery branch (a staged row becomes
        // durable and the retried lookup finds it) is structurally
        // unreachable in this harness.
        await NotificationActionRouter.execute(
            actionId: "MARK_READ", transportMessageId: "m-cold-markread",
            rfc822MessageId: "m-cold-markread@example.com", accountId: "acc1"
        )

        let ops = try await pool.read { db in try PendingOperation.fetchAll(db) }
        #expect(ops.count == 1)
        guard ops.count == 1 else { return }
        #expect(ops[0].type == .markRead)
        #expect(ops[0].folderPath == inbox.path)
        #expect(ops[0].destinationPath == nil)
        #expect(ops[0].messageIds == ["m-cold-markread@example.com"])
    }

    @Test("legacy notification without RFC recovers exactly one inbox header and queues only its RFC identity")
    func legacyPayloadRecoversExactSourceScopedRFC() async throws {
        let (pool, inbox, archive, _, dir, previous) = try makeTestDB()
        defer { restoreTestDB(previous: previous, dir: dir); resetStagedGlobal() }
        resetStagedGlobal()

        let header = makeDurableHeader(folder: inbox, messageId: "legacy-provider-id")
        try await pool.writeWithoutTransaction { db in try header.insert(db) }

        await NotificationActionRouter.execute(
            actionId: "ARCHIVE", transportMessageId: "legacy-provider-id",
            rfc822MessageId: nil, accountId: "acc1"
        )

        let moved = try await pool.read { db in try MessageHeader.fetchOne(db, key: header.id) }
        #expect(moved?.folderId == archive.id)
        let ops = try await pool.read { db in try PendingOperation.fetchAll(db) }
        #expect(ops.count == 1)
        guard ops.count == 1 else { return }
        #expect(ops[0].messageIds == ["legacy-provider-id@example.com"])
    }

    @Test("no-RFC notification with a full local miss queues the provider transport ID as a token member")
    func legacyPayloadFullMissQueuesTokenMember() async throws {
        let (pool, inbox, archive, _, dir, previous) = try makeTestDB()
        defer { restoreTestDB(previous: previous, dir: dir); resetStagedGlobal() }
        resetStagedGlobal()

        await NotificationActionRouter.execute(
            actionId: "ARCHIVE", transportMessageId: "provider-only-id",
            rfc822MessageId: nil, accountId: "acc1"
        )

        // PLAN_IDENTITY_HYBRID §2: instead of refusing, the cold path admits
        // the transport ID as an opaque token member against the inbox scope;
        // the adapter resolves it by exact provider ID at drain.
        let ops = try await pool.read { db in try PendingOperation.fetchAll(db) }
        #expect(ops.count == 1)
        guard ops.count == 1 else { return }
        #expect(ops[0].type == .move)
        #expect(ops[0].messageIds == ["provider-only-id"])
        #expect(ops[0].folderPath == inbox.path)
        #expect(ops[0].destinationPath == archive.path)
    }

    @Test("present malformed RFC never falls back to transport-ID recovery")
    func malformedSuppliedRFCDoesNotRecoverProviderId() async throws {
        let (pool, inbox, _, _, dir, previous) = try makeTestDB()
        defer { restoreTestDB(previous: previous, dir: dir); resetStagedGlobal() }
        resetStagedGlobal()

        let header = makeDurableHeader(folder: inbox, messageId: "malformed-fallback-id")
        try await pool.writeWithoutTransaction { db in try header.insert(db) }

        await NotificationActionRouter.execute(
            actionId: "ARCHIVE",
            transportMessageId: "malformed-fallback-id",
            rfc822MessageId: "<broken",
            accountId: "acc1"
        )

        let persisted = try await pool.read { db in
            try MessageHeader.fetchOne(db, key: header.id)
        }
        #expect(persisted?.folderId == inbox.id)
        let ops = try await pool.read { db in try PendingOperation.fetchAll(db) }
        #expect(ops.isEmpty)
    }

    @Test("duplicate inbox matches make legacy provider-ID recovery a no-op")
    func legacyPayloadDuplicateSourceMatchesNoOp() async throws {
        let (pool, inbox, _, _, dir, previous) = try makeTestDB()
        defer { restoreTestDB(previous: previous, dir: dir); resetStagedGlobal() }
        resetStagedGlobal()

        let secondInbox = Folder(name: "Inbox Alias", path: "Inbox Alias", role: .inbox, accountId: "acc1")
        var first = makeDurableHeader(folder: inbox, messageId: "duplicate-provider-id")
        var second = makeDurableHeader(folder: secondInbox, messageId: "duplicate-provider-id")
        first.rfc822MessageId = "first@example.com"
        second.rfc822MessageId = "second@example.com"
        let firstToInsert = first
        let secondToInsert = second
        try await pool.writeWithoutTransaction { db in
            try secondInbox.insert(db)
            try firstToInsert.insert(db)
            try secondToInsert.insert(db)
        }

        await NotificationActionRouter.execute(
            actionId: "DELETE", transportMessageId: "duplicate-provider-id",
            rfc822MessageId: nil, accountId: "acc1"
        )

        let ops = try await pool.read { db in try PendingOperation.fetchAll(db) }
        #expect(ops.isEmpty)
        let headers = try await pool.read { db in try MessageHeader.fetchAll(db) }
        #expect(headers.allSatisfy { $0.isInInbox })
    }

    @Test("distinct durable and staged RFC matches are ambiguous across tiers")
    func durableAndStagedRFCConflictNoOp() async throws {
        let (pool, inbox, _, _, dir, previous) = try makeTestDB()
        defer { restoreTestDB(previous: previous, dir: dir); resetStagedGlobal() }
        resetStagedGlobal()

        var durable = makeDurableHeader(folder: inbox, messageId: "old-provider-id")
        durable.rfc822MessageId = "shared-action@example.com"
        let durableToInsert = durable
        try await pool.writeWithoutTransaction { db in try durableToInsert.insert(db) }
        NSEDataBridge.latestStagedRows.withLock { rows in
            rows = [makeStagedRow(
                accountId: "acc1",
                messageId: "new-provider-id",
                rfc822MessageId: "<shared-action@example.com>"
            )]
        }

        await NotificationActionRouter.execute(
            actionId: "ARCHIVE",
            transportMessageId: "new-provider-id",
            rfc822MessageId: "shared-action@example.com",
            accountId: "acc1"
        )

        let persisted = try await pool.read { db in
            try MessageHeader.fetchOne(db, key: durableToInsert.id)
        }
        #expect(persisted?.folderId == inbox.id)
        let ops = try await pool.read { db in try PendingOperation.fetchAll(db) }
        #expect(ops.isEmpty)
    }

    // MARK: - (4) Durable header + DELETE

    @Test("durable header + DELETE routes through AccountManager.delete: row moves to Trash, ONE .move PendingOperation targets Trash")
    func durableHeaderDeleteRoutesThroughManager() async throws {
        let (pool, inbox, _, trash, dir, previous) = try makeTestDB()
        defer { restoreTestDB(previous: previous, dir: dir) }

        let header = makeDurableHeader(folder: inbox, messageId: "m-delete-durable")
        try await pool.writeWithoutTransaction { db in try header.insert(db) }
        let id = header.id

        await NotificationActionRouter.execute(
            actionId: "DELETE", transportMessageId: "m-delete-durable",
            rfc822MessageId: "m-delete-durable@example.com", accountId: "acc1"
        )

        let final = try await pool.read { db in try MessageHeader.fetchOne(db, key: id) }
        #expect(final?.folderId == trash.id)
        #expect(final?.folderPath == trash.path)

        let ops = try await pool.read { db in try PendingOperation.fetchAll(db) }
        #expect(ops.count == 1)
        guard ops.count == 1 else { return }
        #expect(ops[0].type == .move)
        #expect(ops[0].folderPath == inbox.path)
        #expect(ops[0].destinationPath == trash.path)
        #expect(ops[0].messageIds == ["m-delete-durable@example.com"])

        #expect(AccountManager.shared.intentionJournal.isFullyDrainedForTesting(), "notification action must leave no stranded intention")
    }

    // MARK: - (5) Same UID across two folders (FIX 1 regression)

    @Test("same messageId (UID) exists in both the inbox and archive folders — IMAP UIDs are folder-scoped, so ARCHIVE must act on the INBOX row ONLY; the pre-existing archive-folder row with the same UID is untouched")
    func sameUidTwoFoldersArchiveActsOnInboxRowOnly() async throws {
        let (pool, inbox, archive, _, dir, previous) = try makeTestDB()
        defer { restoreTestDB(previous: previous, dir: dir) }

        // Insert the ARCHIVE-folder row FIRST (lower rowid) — an unfiltered
        // `fetchOne` (no ORDER BY, no folder predicate) tends to return rows
        // in insertion order, so this ordering is the one most likely to
        // surface the wrong-folder bug if the `isInInbox = 1` filter were
        // ever dropped.
        let archiveRow = makeDurableHeader(folder: archive, messageId: "same-uid-42")
        let inboxRow = makeDurableHeader(folder: inbox, messageId: "same-uid-42")
        #expect(archiveRow.id != inboxRow.id, "same UID in two folders must produce distinct composite ids (MessageIdentity.headerId embeds folderPath)")
        try await pool.writeWithoutTransaction { db in
            try archiveRow.insert(db)
            try inboxRow.insert(db)
        }

        await NotificationActionRouter.execute(
            actionId: "ARCHIVE", transportMessageId: "same-uid-42",
            rfc822MessageId: "same-uid-42@example.com", accountId: "acc1"
        )

        let finalInboxRow = try await pool.read { db in try MessageHeader.fetchOne(db, key: inboxRow.id) }
        #expect(finalInboxRow?.folderId == archive.id, "the INBOX row (and only the inbox row) must have moved to Archive")
        #expect(finalInboxRow?.folderPath == archive.path)

        let finalArchiveRow = try await pool.read { db in try MessageHeader.fetchOne(db, key: archiveRow.id) }
        #expect(finalArchiveRow?.folderId == archive.id, "the pre-existing archive-folder row must be untouched — still in its original folder")
        #expect(finalArchiveRow?.folderPath == archive.path)

        let ops = try await pool.read { db in try PendingOperation.fetchAll(db) }
        #expect(ops.count == 1, "exactly one .move op — only the inbox row was ever acted on")
        guard ops.count == 1 else { return }
        #expect(ops[0].folderPath == inbox.path, "source folderPath must be the inbox path, not the archive row's")
        #expect(ops[0].destinationPath == archive.path)
    }

    // MARK: - (6) Staged-only headers use production AccountManager actions

    @Test("exact staged-row hit + ARCHIVE: merged row ends in Archive and one RFC-addressed move is queued, never the provider UID")
    func stagedRowArchiveRoutesThroughManager() async throws {
        let (pool, _, archive, _, dir, previous) = try makeTestDB()
        defer { restoreTestDB(previous: previous, dir: dir); resetStagedGlobal() }
        resetStagedGlobal()

        // The numeric IMAP-style UID is lookup-only; durable work must use RFC.
        let staged = makeStagedRow(accountId: "acc1", messageId: "9101", rfc822MessageId: "staged-9101@example.com")
        NSEDataBridge.latestStagedRows.withLock { $0 = [staged] }
        installStagedMergeDouble(pool: pool)

        await NotificationActionRouter.execute(
            actionId: "ARCHIVE", transportMessageId: "9101",
            rfc822MessageId: "staged-9101@example.com", accountId: "acc1"
        )

        let final = try await pool.read { db in try MessageHeader.fetchOne(db, key: staged.headerId) }
        #expect(final?.folderId == archive.id)
        #expect(final?.folderPath == archive.path)
        #expect(final?.isInInbox == false)

        let ops = try await pool.read { db in try PendingOperation.fetchAll(db) }
        #expect(ops.count == 1)
        guard ops.count == 1 else { return }
        #expect(ops[0].type == .move)
        #expect(ops[0].accountId == "acc1")
        #expect(ops[0].folderPath == "INBOX", "source folderPath is the staged row's folder")
        #expect(ops[0].destinationPath == "Archive")
        #expect(ops[0].messageIds == ["staged-9101@example.com"], "the op must carry normalized RFC identity — never the provider UID \"9101\"")

        #expect(AccountManager.shared.intentionJournal.isFullyDrainedForTesting(), "notification action must leave no stranded intention")
    }

    @Test("exact staged-row hit + DELETE: merged row ends in Trash and one RFC-addressed move is queued, never the provider UID")
    func stagedRowDeleteRoutesThroughManager() async throws {
        let (pool, _, _, trash, dir, previous) = try makeTestDB()
        defer { restoreTestDB(previous: previous, dir: dir); resetStagedGlobal() }
        resetStagedGlobal()

        let staged = makeStagedRow(accountId: "acc1", messageId: "9102", rfc822MessageId: "staged-9102@example.com")
        NSEDataBridge.latestStagedRows.withLock { $0 = [staged] }
        installStagedMergeDouble(pool: pool)

        await NotificationActionRouter.execute(
            actionId: "DELETE", transportMessageId: "9102",
            rfc822MessageId: "staged-9102@example.com", accountId: "acc1"
        )

        let final = try await pool.read { db in try MessageHeader.fetchOne(db, key: staged.headerId) }
        #expect(final?.folderId == trash.id)
        #expect(final?.folderPath == trash.path)
        #expect(final?.isInInbox == false)

        let ops = try await pool.read { db in try PendingOperation.fetchAll(db) }
        #expect(ops.count == 1)
        guard ops.count == 1 else { return }
        #expect(ops[0].type == .move)
        #expect(ops[0].accountId == "acc1")
        #expect(ops[0].folderPath == "INBOX")
        #expect(ops[0].destinationPath == "Trash")
        #expect(ops[0].messageIds == ["staged-9102@example.com"], "provider UID \"9102\" must never enter durable work")
        #expect(AccountManager.shared.intentionJournal.isFullyDrainedForTesting())
    }

    @Test("exact staged-row hit + MARK_READ: merged row ends read and one RFC-addressed markRead is queued, never the provider UID")
    func stagedRowMarkReadRoutesThroughManager() async throws {
        let (pool, inbox, _, _, dir, previous) = try makeTestDB()
        defer { restoreTestDB(previous: previous, dir: dir); resetStagedGlobal() }
        resetStagedGlobal()

        let staged = makeStagedRow(accountId: "acc1", messageId: "9103", rfc822MessageId: "staged-9103@example.com")
        NSEDataBridge.latestStagedRows.withLock { $0 = [staged] }
        installStagedMergeDouble(pool: pool)
        try await pool.writeWithoutTransaction { db in
            try db.execute(sql: "UPDATE folder SET unreadCount = 1 WHERE id = ?", arguments: [inbox.id])
        }

        await NotificationActionRouter.execute(
            actionId: "MARK_READ", transportMessageId: "9103",
            rfc822MessageId: "staged-9103@example.com", accountId: "acc1"
        )

        let final = try await pool.read { db in try MessageHeader.fetchOne(db, key: staged.headerId) }
        #expect(final?.folderId == inbox.id)
        #expect(final?.folderPath == inbox.path)
        #expect(final?.isRead == true)

        let ops = try await pool.read { db in try PendingOperation.fetchAll(db) }
        #expect(ops.count == 1)
        guard ops.count == 1 else { return }
        #expect(ops[0].type == .markRead)
        #expect(ops[0].accountId == "acc1")
        #expect(ops[0].folderPath == "INBOX")
        #expect(ops[0].destinationPath == nil)
        #expect(ops[0].messageIds == ["staged-9103@example.com"], "provider UID \"9103\" must never enter durable work")

        let unreadCount = try await pool.read { db in try Folder.fetchOne(db, key: inbox.id)?.unreadCount }
        #expect(unreadCount == 0)
    }

    // MARK: - (7) Durable header + MARK_READ

    /// Pins the durable MARK_READ router cell (AppDelegate.swift's
    /// `case "MARK_READ": await AccountManager.shared.markRead([header])`) —
    /// the batch API deliberately lives outside the user-intention journal.
    /// Sits next to the durable ARCHIVE/DELETE pins
    /// above so all three durable-dispatch cells are covered.
    @Test("durable header + MARK_READ dispatches via AccountManager.markRead: isRead flips, exactly one .markRead PendingOperation, folder unreadCount decremented by exactly the newly-read count")
    func durableHeaderMarkReadRoutesThroughManager() async throws {
        let (pool, inbox, _, _, dir, previous) = try makeTestDB()
        defer { restoreTestDB(previous: previous, dir: dir) }

        // Target + one unrelated unread filler, with unreadCount matching row
        // truth (2): the final assertion (1) distinguishes "decremented by
        // exactly the newly-read count" from "recounted/zeroed" — stable
        // whichever of the optimistic decrement or the async recount lands
        // last (both agree on 1; mirrors ReadUnreadPersistenceTests).
        let header = makeDurableHeader(folder: inbox, messageId: "m-markread-durable")
        let filler = makeDurableHeader(folder: inbox, messageId: "m-markread-filler")
        try await pool.writeWithoutTransaction { db in
            try header.insert(db)
            try filler.insert(db)
            try db.execute(sql: "UPDATE folder SET unreadCount = 2 WHERE id = ?", arguments: [inbox.id])
        }
        let id = header.id

        await NotificationActionRouter.execute(
            actionId: "MARK_READ", transportMessageId: "m-markread-durable",
            rfc822MessageId: "m-markread-durable@example.com", accountId: "acc1"
        )

        let final = try await pool.read { db in try MessageHeader.fetchOne(db, key: id) }
        #expect(final?.isRead == true, "the durable row must be marked read")
        let fillerRow = try await pool.read { db in try MessageHeader.fetchOne(db, key: filler.id) }
        #expect(fillerRow?.isRead == false, "the unrelated filler is untouched")

        let ops = try await pool.read { db in try PendingOperation.fetchAll(db) }
        #expect(ops.count == 1)
        guard ops.count == 1 else { return }
        #expect(ops[0].type == .markRead)
        #expect(ops[0].folderPath == inbox.path)
        #expect(ops[0].destinationPath == nil)
        #expect(ops[0].messageIds == ["m-markread-durable@example.com"])

        let unread = try await pool.read { db in try Folder.fetchOne(db, key: inbox.id)?.unreadCount }
        #expect(unread == 1, "unreadCount decremented by exactly the newly-read count (2 → 1)")
    }
}
