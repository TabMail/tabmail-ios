/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Testing
@testable import TabMail

/// PLAN_INBOX_UNIFIED_READ.md — Phase 1 ("Pin current behavior", §5 Migration
/// phases item 1): a table-driven pinning suite over TODAY'S observable
/// inbox-list behavior, exercised entirely through `InboxViewModel`'s public
/// surface (`insertStagedRows` / `reloadMessages` / `resetMessages` /
/// `insertUndoneMessages` / `loadMoreMessages` / `lookupMessage` +
/// `loadedMessages`/`displayGroups`) — never internals. This is the safety
/// net for the `InboxListComposer` refactor (§2.1). Phase 3 switched the
/// three fetch sites to the reader (undo-survives-reload, test 8, is live).
/// Phase 4 closes the last transitional gap: `insertStagedRows` /
/// `insertUndoneMessages` now carry the same label-filter treatment as the
/// reader (§2.2), so test 10's transitional divergence is gone — event
/// inserts stay pure latency optimizations that never insert a row the
/// reader would reject. Phase 5 (§3 kill list) deleted the Pass-1 guard/
/// tombstone/AI-carry-over machinery `reloadMessages` used to own — tests
/// 2-5 now seed `NSEDataBridge.latestStagedRows` explicitly (the merge
/// publishes it BEFORE posting `.messagesStaged` in production, so any row
/// delivered to `insertStagedRows` is also in S) instead of relying on
/// VM-internal guard state, and pin the reader's structural survival/
/// suppression guarantees instead of the deleted bookkeeping.
///
/// `.serialized`: several tests touch the `AccountManager.shared` optimistic
/// overlay and `NSEDataBridge.latestStagedRows` — both process-wide globals —
/// so tests must not interleave (mirrors `InboxStagedRowGuardTests` /
/// `NSEStaleStagedRowInvalidationTests`).
@Suite("Inbox list behavior pinning (PLAN_INBOX_UNIFIED_READ Phase 1)", .serialized)
@MainActor
struct InboxListBehaviorPinningTests {

    // MARK: - Harness (mirrors InboxStagedInsertTests.swift / InboxStagedRowGuardTests.swift)

    private func makeTestDB() throws -> (pool: DatabasePool, inbox: Folder, archive: Folder, dir: URL, previous: AppDatabase?) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var config = Configuration()
        config.foreignKeysEnabled = true
        let pool = try DatabasePool(path: dir.appendingPathComponent("test.sqlite").path, configuration: config)
        let appDb = try AppDatabase(dbPool: pool)
        let previous = AppDatabase.shared.withLock { current -> AppDatabase? in
            let prev = current; current = appDb; return prev
        }
        try pool.writeWithoutTransaction { db in
            var acc = Account(emailAddress: "test@example.com", displayName: "Test", provider: .gmail)
            acc.id = "acc1"
            try acc.insert(db)
        }
        let inbox = Folder(name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")
        let archive = Folder(name: "Archive", path: "Archive", role: .archive, accountId: "acc1")
        try pool.writeWithoutTransaction { db in
            let i = inbox; try i.insert(db)
            let a = archive; try a.insert(db)
        }
        return (pool, inbox, archive, dir, previous)
    }

    private func makeStagedRow(
        accountId: String = "acc1",
        folderPath: String = "INBOX",
        messageId: String,
        date: Date = Date(),
        isRead: Bool = false,
        actionTag: String? = nil,
        summaryBlurb: String? = nil
    ) -> StagedInboxRow {
        StagedInboxRow(
            accountId: accountId, folderPath: folderPath, messageId: messageId,
            rfc822MessageId: nil, threadId: nil, inReplyTo: nil, references: [],
            subject: "Subj \(messageId)", senderName: "Sender", senderAddress: "s@example.com",
            to: "me@example.com", snippet: "snip", date: date,
            isRead: isRead, isFlagged: false, hasAttachments: false, isReplied: false,
            isForwarded: false, actionTag: actionTag, summaryBlurb: summaryBlurb
        )
    }

    /// A durable, query-visible header (`headerComplete = true`) for a folder.
    private func makeDurableHeader(
        folder: Folder,
        messageId: String,
        date: Date = Date(),
        isRead: Bool = false,
        headerComplete: Bool = true,
        actionTag: ActionTag? = nil,
        summaryBlurb: String? = nil,
        isInInbox: Bool = true
    ) -> MessageHeader {
        var h = MessageHeader(
            messageId: messageId, subject: "Subj \(messageId)", from: "Sender", fromAddress: "s@example.com",
            to: "me@example.com", date: date, snippet: "snip",
            folderId: folder.id, accountId: folder.accountId, folderPath: folder.path, isInInbox: isInInbox
        )
        h.headerComplete = headerComplete
        h.isRead = isRead
        h.actionTag = actionTag
        h.tagSortOrder = actionTag?.sortOrder ?? 99
        h.summaryBlurb = summaryBlurb
        return h
    }

    /// `AccountManager.shared` is a real singleton, not swapped per-test —
    /// clear any overlay entries a test leaves behind (mirrors
    /// InboxStagedRowGuardTests.swift's `clearOverlay`).
    private func clearOverlay() {
        let snapshot = AccountManager.shared.snapshotOverlay()
        AccountManager.shared.removeOverlayEntries(ids: Array(snapshot.keys))
    }

    /// `NSEDataBridge.latestStagedRows` is a process-wide Mutex snapshot —
    /// reset it so tests don't leak staged rows into each other (mirrors
    /// NSEStaleStagedRowInvalidationTests.swift's `resetGlobals`).
    private func resetStagedGlobal() {
        NSEDataBridge.latestStagedRows.withLock { $0 = [] }
    }

    // MARK: - 1. Staged insert is instant and zero-DB

    @Test("insertStagedRows inserts a snapshot immediately, sorted by date desc, with zero DB writes")
    func stagedInsertIsInstantAndSortedByDateDesc() throws {
        let (pool, inbox, _, dir, previous) = try makeTestDB()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            try? FileManager.default.removeItem(at: dir)
            clearOverlay(); resetStagedGlobal()
        }
        clearOverlay(); resetStagedGlobal()

        let vm = InboxViewModel(folders: [inbox])
        #expect(vm.loadedMessages.isEmpty)

        let older = Date().addingTimeInterval(-3600)
        let newer = Date()
        vm.insertStagedRows([
            makeStagedRow(messageId: "m-old", date: older),
            makeStagedRow(messageId: "m-new", date: newer)
        ])

        #expect(vm.loadedMessages.count == 2)
        guard vm.loadedMessages.count == 2 else { return }
        #expect(vm.loadedMessages[0].messageId == "m-new")
        #expect(vm.loadedMessages[1].messageId == "m-old")

        // Zero-DB: no synchronous or async write happened as a side effect of
        // the in-memory insert — the durable table stays empty for this account.
        let dbCount = try pool.read { db in
            try MessageHeader.filter(Column("accountId") == "acc1").fetchCount(db)
        }
        #expect(dbCount == 0)
    }

    // MARK: - 2. Staged row survives a reload pre-durability

    @Test("a staged row with no durable GRDB write yet survives a reload (the reader includes S)")
    func stagedRowSurvivesReloadPreDurability() async throws {
        let (_, inbox, _, dir, previous) = try makeTestDB()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            try? FileManager.default.removeItem(at: dir)
            clearOverlay(); resetStagedGlobal()
        }
        clearOverlay(); resetStagedGlobal()

        let vm = InboxViewModel(folders: [inbox])
        let row = makeStagedRow(messageId: "m-phantom")
        // Seed the merge's published global BEFORE the zero-I/O insert —
        // mirrors the real timeline (NSEDataBridge.performMerge publishes
        // `latestStagedRows` BEFORE posting `.messagesStaged`), so a reload's
        // `InboxListReader` read (which consults this global as S) sees the
        // same row `insertStagedRows` rendered instantly. Post-Phase-5 this is
        // what makes the row survive — not VM-internal guard state.
        NSEDataBridge.latestStagedRows.withLock { $0 = [row] }
        vm.insertStagedRows([row])
        #expect(vm.loadedMessages.count == 1)

        await vm.reloadMessages()
        #expect(vm.loadedMessages.count == 1)
        #expect(vm.loadedMessages.first?.messageId == "m-phantom")
    }

    // MARK: - 3. Staged row survives reload after a non-removing overlay mutation

    @Test("an isRead-only overlay mutation does not evict a staged row — it survives a reload (f843c02 class, now via the reader)")
    func stagedRowSurvivesReloadAfterNonRemovingOverlayMutation() async throws {
        let (_, inbox, _, dir, previous) = try makeTestDB()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            try? FileManager.default.removeItem(at: dir)
            clearOverlay(); resetStagedGlobal()
        }
        clearOverlay(); resetStagedGlobal()

        let vm = InboxViewModel(folders: [inbox])
        let row = makeStagedRow(messageId: "m-read")
        // Seed the global before insert — see stagedRowSurvivesReloadPreDurability's comment.
        NSEDataBridge.latestStagedRows.withLock { $0 = [row] }
        vm.insertStagedRows([row])
        #expect(vm.loadedMessages.count == 1)
        let id = MessageIdentity.headerId(accountId: "acc1", folderPath: "INBOX", messageId: "m-read")

        // Mirrors MessageDetailViewModel.markReadOnOpenIfNeeded: an isRead-only
        // overlay mutation, no folder change.
        AccountManager.shared.registerMutation(id: id, mutation: .init(isRead: true))

        await vm.reloadMessages()
        #expect(vm.loadedMessages.count == 1)
        #expect(vm.loadedMessages.contains { $0.id == id })
    }

    // MARK: - 4. Folder-move overlay releases the row; once the durable write
    // lands, a stale zero-I/O re-insert is a bounded, reload-correcting
    // transient (§2.2 accepted transient — the tombstone that used to block
    // this outright is gone, PLAN_INBOX_UNIFIED_READ.md §3)

    @Test("a folderId overlay mutation moving a staged row out of the displayed set releases it on reload; once the durable write lands in the new folder, a stale zero-I/O re-insert flashes back but the next reload evicts it for good (stale-by-move suppression, §2.2 accepted transient)")
    func folderMoveOverlayReleasesRowAndReloadConverges() async throws {
        let (pool, inbox, archive, dir, previous) = try makeTestDB()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            try? FileManager.default.removeItem(at: dir)
            clearOverlay(); resetStagedGlobal()
        }
        clearOverlay(); resetStagedGlobal()

        let vm = InboxViewModel(folders: [inbox])
        let row = makeStagedRow(messageId: "m-moved")
        NSEDataBridge.latestStagedRows.withLock { $0 = [row] }
        vm.insertStagedRows([row])
        #expect(vm.loadedMessages.count == 1)
        let id = MessageIdentity.headerId(accountId: "acc1", folderPath: "INBOX", messageId: "m-moved")

        // User archives the just-pushed (not yet durable) row: overlay
        // registered optimistically (mirrors InboxViewModel.archive()).
        AccountManager.shared.registerMutation(id: id, mutation: .init(folderId: archive.id))
        await vm.reloadMessages()
        #expect(vm.loadedMessages.isEmpty)

        // Pre-write re-insert attempt: while the folder-move overlay entry is
        // still registered, `insertStagedRows`' own overlay check blocks the row.
        vm.insertStagedRows([row])
        #expect(vm.loadedMessages.isEmpty)

        // The archive's durable write lands (mirrors `manager.move` completing
        // — the real timeline's `optimisticWrite` step), THEN the overlay
        // drains (`AccountManager.removeOverlayEntries`, called after the
        // queued PendingOperation completes) — the real bug's timeline: the
        // archive's overlay entry drains long before a LATER push re-stages
        // the message. NOTE: the durable copy's id embeds the Archive
        // folderPath (`acc1:Archive:m-moved`), NOT the staged row's INBOX id —
        // the reader links the two via the merge's (accountId, messageId)
        // identity lookup (`DurableIdentityLookup`), never id equality; this
        // id skew is exactly the stale-by-move shape.
        let archived = makeDurableHeader(folder: archive, messageId: "m-moved", isInInbox: false)
        #expect(archived.id != id)
        try await pool.writeWithoutTransaction { db in try archived.insert(db) }
        AccountManager.shared.removeOverlayEntries(ids: [id])

        // Post-drain re-insert attempt: `insertStagedRows` is a ZERO-I/O path
        // by contract (§2.2) — it never consults durable state, so nothing
        // stops it from rendering the phantom again here. This is the honest,
        // accepted transient (no tombstone anymore): insert → present.
        vm.insertStagedRows([row])
        #expect(
            vm.loadedMessages.count == 1,
            "insertStagedRows' zero-I/O contract means a stale re-insert renders immediately — accepted §2.2 transient, not a regression"
        )

        // A reload converges: the reader sees the durable header now living in
        // Archive (folderId disagrees with the staged row's INBOX folder) and
        // suppresses the S row as stale-by-move (§2.1a) — reload → gone, for good.
        await vm.reloadMessages()
        #expect(vm.loadedMessages.isEmpty)
        #expect(!vm.loadedMessages.contains { $0.id == id })
    }

    // MARK: - 5. Merge-side scrub (PLAN_INBOX_UNIFIED_READ.md §3 — replaces
    // invalidateStagedRows/.stagedRowsInvalidated): once the merge scrubs a
    // stale-by-move row from NSEDataBridge.latestStagedRows, the reader's own
    // stale-by-move suppression evicts it on the next reload — no VM-side
    // eviction handler is needed anymore (see NSEStaleStagedRowInvalidationTests
    // for the merge-side a/b/c coverage this test's setup mirrors).

    @Test("a staged row scrubbed from NSEDataBridge.latestStagedRows (merge-side stale-by-move cleanup) is evicted by the next reload")
    func staleByMoveScrubIsEvictedByReload() async throws {
        let (pool, inbox, archive, dir, previous) = try makeTestDB()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            try? FileManager.default.removeItem(at: dir)
            clearOverlay(); resetStagedGlobal()
        }
        clearOverlay(); resetStagedGlobal()

        let vm = InboxViewModel(folders: [inbox])
        let row = makeStagedRow(messageId: "m-stale")
        NSEDataBridge.latestStagedRows.withLock { $0 = [row] }
        vm.insertStagedRows([row])
        #expect(vm.loadedMessages.count == 1)
        let id = MessageIdentity.headerId(accountId: "acc1", folderPath: "INBOX", messageId: "m-stale")

        // Mirrors NSEDataBridge.performMerge's STALE-BY-MOVE DETECTION: a
        // later merge discovers the durable header for this identity now
        // lives in a different folder (archived via another client/instance)
        // and (a) deletes the staging row, (b) scrubs `latestStagedRows`, (c)
        // drops the stage-memo entry. This test pins the VM-observable half:
        // once the durable header disagrees and the global is scrubbed, the
        // NEXT reload evicts the phantom — no `.stagedRowsInvalidated`
        // notification or VM eviction handler needed anymore.
        // NOTE: the durable copy's id embeds the Archive folderPath — a
        // DIFFERENT id than the staged INBOX row's; the reader's stale-by-move
        // check links them via the (accountId, messageId) identity lookup.
        let archived = makeDurableHeader(folder: archive, messageId: "m-stale", isInInbox: false)
        #expect(archived.id != id)
        try await pool.writeWithoutTransaction { db in try archived.insert(db) }
        NSEDataBridge.latestStagedRows.withLock { $0.removeAll { $0.headerId == id } }

        // Still on screen — nothing evicts it synchronously anymore.
        #expect(vm.loadedMessages.count == 1)

        await vm.reloadMessages()
        #expect(vm.loadedMessages.isEmpty)
        #expect(!vm.loadedMessages.contains { $0.id == id })
    }

    // MARK: - 6. AI fields never flash

    @Test("staged actionTag/summaryBlurb are carried over — never flash to nil when a phase-1 durable header lands without them; real AI fields win once they land")
    func aiFieldsCarryOverNeverFlashToNil() async throws {
        let (pool, inbox, _, dir, previous) = try makeTestDB()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            try? FileManager.default.removeItem(at: dir)
            clearOverlay(); resetStagedGlobal()
        }
        clearOverlay(); resetStagedGlobal()

        let vm = InboxViewModel(folders: [inbox])
        let row = makeStagedRow(messageId: "m-ai", actionTag: ActionTag.reply.rawValue, summaryBlurb: "staged blurb")
        // Seed the global — the composer's AI carry-over (InboxListComposer.
        // applyAICarryOver) only fires when a staged (S) row resolves to the
        // same durable identity, so the reader must see this row as S too
        // (mirrors the merge's publish-before-post order).
        NSEDataBridge.latestStagedRows.withLock { $0 = [row] }
        vm.insertStagedRows([row])
        #expect(vm.loadedMessages.count == 1)
        guard vm.loadedMessages.count == 1 else { return }
        #expect(vm.loadedMessages[0].actionTag == .reply)
        #expect(vm.loadedMessages[0].summaryBlurb == "staged blurb")

        let id = MessageIdentity.headerId(accountId: "acc1", folderPath: "INBOX", messageId: "m-ai")
        // Phase-1 shape: headerComplete=true (query-visible) but AI-less
        // (actionTag/summaryBlurb nil) — exactly what NSEDataBridge's
        // phase-1 upsert / a plain sync insert writes.
        let durable = makeDurableHeader(folder: inbox, messageId: "m-ai")
        #expect(durable.id == id)
        try await pool.writeWithoutTransaction { db in try durable.insert(db) }

        await vm.reloadMessages()

        #expect(vm.loadedMessages.count == 1)
        guard vm.loadedMessages.count == 1 else { return }
        #expect(vm.loadedMessages[0].id == id)
        #expect(vm.loadedMessages[0].actionTag == .reply)
        #expect(vm.loadedMessages[0].summaryBlurb == "staged blurb")

        // Real (and here, deliberately DIFFERENT) AI fields land durably —
        // the composer only carries S's fields onto a D row when the D row's
        // own fields are nil (§2.1a); once real values are present, D wins
        // outright and the stale staged copy is never consulted again.
        try await pool.writeWithoutTransaction { db in
            try db.execute(
                sql: "UPDATE messageHeader SET actionTag = ?, tagSortOrder = ?, summaryBlurb = ? WHERE id = ?",
                arguments: [ActionTag.archive.rawValue, ActionTag.archive.sortOrder, "real blurb", id]
            )
        }
        await vm.reloadMessages()
        #expect(vm.loadedMessages.count == 1)
        guard vm.loadedMessages.count == 1 else { return }
        #expect(vm.loadedMessages[0].actionTag == .archive)
        #expect(vm.loadedMessages[0].tagSortOrder == ActionTag.archive.sortOrder)
        #expect(vm.loadedMessages[0].summaryBlurb == "real blurb")
    }

    // MARK: - 7. Undo reappears

    @Test("undo: overlay + insertUndoneMessages makes an archived durable row reappear in the inbox list")
    func undoReappearsViaOverlayAndInsertUndoneMessages() async throws {
        let (pool, inbox, archive, dir, previous) = try makeTestDB()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            try? FileManager.default.removeItem(at: dir)
            clearOverlay(); resetStagedGlobal()
        }
        clearOverlay(); resetStagedGlobal()

        // Durable header currently in Archive (the "already moved" state).
        let archived = makeDurableHeader(folder: archive, messageId: "m-undo", isInInbox: false)
        try await pool.writeWithoutTransaction { db in try archived.insert(db) }
        let id = archived.id

        // VM only displays the inbox folder.
        let vm = InboxViewModel(folders: [inbox])
        #expect(vm.loadedMessages.isEmpty)

        // Mirror UndoService.undo()'s .move case EXACTLY (UndoService.swift
        // ~129-133): register the overlay BEFORE the deferred DB write, with
        // the pre-move isInInbox value (true — the message was in inbox
        // before being archived).
        AccountManager.shared.registerMutation(id: id, mutation: .init(
            folderId: inbox.id, folderPath: inbox.path, isInInbox: true
        ))

        vm.insertUndoneMessages([id])
        #expect(vm.loadedMessages.count == 1)
        #expect(vm.loadedMessages.first?.id == id)
    }

    // MARK: - 8. Undo survives an immediate reload — CLOSED by the Phase 3 P-step

    // Verified-failing pre-Phase-3 (2026-07-09): both expectations failed,
    // loadedMessages.count → 0 after reloadMessages() (the latent undo hole —
    // insertUndoneMessages had no reload-survival guarantee). PLAN_INBOX_UNIFIED_READ.md
    // §2.1 step 2's P-step (InboxListReader's overlay-pinned-row fetch) closes
    // it: every reload now re-fetches an undone-but-not-yet-durable row by id
    // as long as its overlay folderId mutation points into the displayed set.
    @Test("undo survives an immediate reloadMessages()")
    func undoSurvivesImmediateReload() async throws {
        let (pool, inbox, archive, dir, previous) = try makeTestDB()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            try? FileManager.default.removeItem(at: dir)
            clearOverlay(); resetStagedGlobal()
        }
        clearOverlay(); resetStagedGlobal()

        let archived = makeDurableHeader(folder: archive, messageId: "m-undo-reload", isInInbox: false)
        try await pool.writeWithoutTransaction { db in try archived.insert(db) }
        let id = archived.id

        let vm = InboxViewModel(folders: [inbox])
        AccountManager.shared.registerMutation(id: id, mutation: .init(
            folderId: inbox.id, folderPath: inbox.path, isInInbox: true
        ))
        vm.insertUndoneMessages([id])
        #expect(vm.loadedMessages.count == 1)

        // The deferred DB restore write has NOT landed (mirrors the real
        // timeline: UndoService registers the overlay synchronously, then
        // enqueues the write asynchronously) — the durable header is still
        // physically in Archive. A plain folder-scoped D query would miss
        // this row entirely; the reader's P-step (§2.1 step 2) is what closes
        // the hole — it fetches overlay-pinned rows (an overlay `folderId`
        // pointing INTO the displayed set, durable row elsewhere) by id on
        // EVERY read, independent of any staged-row bookkeeping.
        await vm.reloadMessages()
        #expect(vm.loadedMessages.count == 1)
        #expect(vm.loadedMessages.contains { $0.id == id })
    }

    // MARK: - 9. Unread filter

    @Test("filterUnread excludes read rows from both the fetch path and staged inserts")
    func unreadFilterExcludesReadRowsFromFetchAndStagedInsert() throws {
        let (pool, inbox, _, dir, previous) = try makeTestDB()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            try? FileManager.default.removeItem(at: dir)
            clearOverlay(); resetStagedGlobal()
        }
        clearOverlay(); resetStagedGlobal()

        // A read and an unread durable message, inserted BEFORE the VM exists.
        let readHeader = makeDurableHeader(folder: inbox, messageId: "m-read-durable", isRead: true)
        let unreadHeader = makeDurableHeader(folder: inbox, messageId: "m-unread-durable", isRead: false)
        try pool.writeWithoutTransaction { db in
            let r = readHeader; try r.insert(db)
            let u = unreadHeader; try u.insert(db)
        }

        let vm = InboxViewModel(folders: [inbox])
        vm.filterUnread = true
        vm.resetMessages()

        #expect(vm.loadedMessages.count == 1)
        guard vm.loadedMessages.count == 1 else { return }
        #expect(vm.loadedMessages[0].messageId == "m-unread-durable")

        // Staged-insert path: a read staged row must also be excluded.
        vm.insertStagedRows([
            makeStagedRow(messageId: "m-read-staged", isRead: true),
            makeStagedRow(messageId: "m-unread-staged", isRead: false)
        ])
        #expect(vm.loadedMessages.count == 2)
        #expect(!vm.loadedMessages.contains { $0.messageId == "m-read-staged" })
        #expect(vm.loadedMessages.contains { $0.messageId == "m-unread-staged" })
    }

    // MARK: - 10. Label filter — unified across every path (Phase 4 closes the divergence)

    // PLAN_INBOX_UNIFIED_READ.md Phase 3 unified the label filter INSIDE the
    // reader (InboxListComposer step 6 — applies to D/P/S alike; S rows
    // synthesize with `userLabels == []`, so an active label filter always
    // drops them). Phase 4 gives `insertStagedRows` the same query-level
    // guard (§2.2/§5 Phase 4): an active label filter makes EVERY staged row
    // ineligible (zero userLabels can never satisfy a non-empty
    // `filterLabelIds`), so the function now bails before inserting anything.
    // Phase 5 deleted `resetMessages`' explicit re-seed call entirely — its
    // page-1 fetch already routes through the reader, which applies the SAME
    // label filter directly to S (`NSEDataBridge.latestStagedRows`), so a
    // staged row seeded into the global is excluded by the fetch itself, not
    // a second insert-then-guard pass.
    @Test("label filter: an unlabeled staged row is excluded by insertStagedRows directly, by resetMessages' fetch (via the reader), and stays excluded across a reload")
    func labelFilterExcludesUnlabeledStagedRowEverywhere() async throws {
        let (pool, inbox, _, dir, previous) = try makeTestDB()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            try? FileManager.default.removeItem(at: dir)
            clearOverlay(); resetStagedGlobal()
        }
        clearOverlay(); resetStagedGlobal()

        // Durable row with NO labels attached — excluded by the reader either way.
        let unlabeled = makeDurableHeader(folder: inbox, messageId: "m-unlabeled")
        try await pool.writeWithoutTransaction { db in let h = unlabeled; try h.insert(db) }

        let vm = InboxViewModel(folders: [inbox])
        vm.filterLabelIds = ["label-x"]
        // Apply the filter — assigning the property alone doesn't refetch
        // (init's page-1 load ran pre-filter and included the durable row);
        // mirrors the real set-filter-then-reset flow. The reader's D query
        // label-filters the durable unlabeled row out.
        vm.resetMessages()
        #expect(vm.loadedMessages.isEmpty)

        // (i) Direct `insertStagedRows` call — the query-level guard bails
        // before inserting anything while a label filter is active.
        let stagedRow = makeStagedRow(messageId: "m-staged-unlabeled")
        vm.insertStagedRows([stagedRow])
        #expect(vm.loadedMessages.isEmpty)

        // (ii) `resetMessages()`'s page-1 fetch consults
        // `NSEDataBridge.latestStagedRows` (the merge's actual publish point)
        // directly via the reader, which label-filters S the same way it
        // filters D — so a staged row seeded into the global is excluded by
        // the fetch itself.
        NSEDataBridge.latestStagedRows.withLock { $0 = [stagedRow] }
        vm.resetMessages()
        #expect(vm.loadedMessages.isEmpty)
        #expect(!vm.loadedMessages.contains { $0.messageId == "m-staged-unlabeled" })
        #expect(!vm.loadedMessages.contains { $0.messageId == "m-unlabeled" })

        // (iii) `reloadMessages()` — nothing was ever inserted, and the
        // reader excludes the labeled-filtered staged row on every fetch, so
        // there is nothing to protect across a reload either.
        await vm.reloadMessages()
        #expect(vm.loadedMessages.isEmpty)
    }

    // MARK: - 11. Pagination overlap

    @Test("loadMoreMessages dedups against loadedIds — a durable duplicate of an already-loaded staged row is not appended twice")
    func loadMoreMessagesDedupsAgainstLoadedIds() throws {
        let (pool, inbox, _, dir, previous) = try makeTestDB()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            try? FileManager.default.removeItem(at: dir)
            clearOverlay(); resetStagedGlobal()
        }
        clearOverlay(); resetStagedGlobal()

        let pageSize = SyncConfig.inboxPageSize
        let now = Date()

        // Exactly `pageSize` filler rows so the initial page fills the window
        // (hasMoreMessages == true afterward), all newer than the two rows below.
        try pool.writeWithoutTransaction { db in
            for i in 0..<pageSize {
                let filler = makeDurableHeader(
                    folder: inbox, messageId: "filler-\(i)",
                    date: now.addingTimeInterval(-60 * Double(i + 1))
                )
                try filler.insert(db)
            }
            // Older than every filler — excluded from page 1 by the pageSize trim.
            let dup = makeDurableHeader(folder: inbox, messageId: "m-dup", date: now.addingTimeInterval(-60 * Double(pageSize + 1)))
            try dup.insert(db)
            let older = makeDurableHeader(folder: inbox, messageId: "m-older", date: now.addingTimeInterval(-60 * Double(pageSize + 2)))
            try older.insert(db)
        }

        let vm = InboxViewModel(folders: [inbox])
        #expect(vm.loadedMessages.count == pageSize)
        #expect(vm.hasMoreMessages == true)

        // Stage the SAME identity as the not-yet-loaded durable "m-dup" row
        // (simulates a push re-staging a message whose durable copy already
        // exists further back than the current window), dated newest so it
        // sorts to the front — the pagination cursor (`loadedMessages.last`)
        // stays anchored to the oldest filler.
        let dupId = MessageIdentity.headerId(accountId: "acc1", folderPath: "INBOX", messageId: "m-dup")
        vm.insertStagedRows([makeStagedRow(messageId: "m-dup", date: now)])
        #expect(vm.loadedMessages.count == pageSize + 1)
        #expect(vm.loadedMessages.first?.id == dupId)

        vm.loadMoreMessages()

        // The durable "m-dup" row IS within the query window opened by the
        // pagination cursor, but must be deduped against the already-loaded
        // staged copy — only "m-older" is newly appended.
        #expect(vm.loadedMessages.count == pageSize + 2)
        let ids = vm.loadedMessages.map(\.id)
        #expect(Set(ids).count == ids.count)
        #expect(vm.loadedMessages.filter { $0.messageId == "m-dup" }.count == 1)
        #expect(vm.loadedMessages.contains { $0.messageId == "m-older" })
    }

    // MARK: - 12. Triage order

    @Test("mode=.triage sorts by tagSortOrder asc then date desc, for both fetched and staged-inserted rows")
    func triageOrderSortsFetchedAndStagedRows() throws {
        let (pool, inbox, _, dir, previous) = try makeTestDB()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            try? FileManager.default.removeItem(at: dir)
            clearOverlay(); resetStagedGlobal()
        }
        clearOverlay(); resetStagedGlobal()

        let now = Date()
        // Durable rows: the reply-tagged row is OLDER than the archive-tagged
        // one, but triage order must still rank it first (tagSortOrder wins).
        let replyHeader = makeDurableHeader(folder: inbox, messageId: "m-reply-durable", date: now.addingTimeInterval(-60), actionTag: .reply)
        let archiveHeader = makeDurableHeader(folder: inbox, messageId: "m-archive-durable", date: now, actionTag: .archive)
        try pool.writeWithoutTransaction { db in
            let r = replyHeader; try r.insert(db)
            let a = archiveHeader; try a.insert(db)
        }

        let vm = InboxViewModel(folders: [inbox])
        vm.mode = .triage
        vm.resetMessages()

        #expect(vm.loadedMessages.count == 2)
        guard vm.loadedMessages.count == 2 else { return }
        #expect(vm.loadedMessages[0].messageId == "m-reply-durable")
        #expect(vm.loadedMessages[1].messageId == "m-archive-durable")

        // Staged insert, same mode: a staged "reply" row sorts ahead of the
        // existing "archive" row too, even though it is OLDER by date than both.
        vm.insertStagedRows([
            makeStagedRow(messageId: "m-reply-staged", date: now.addingTimeInterval(-120), actionTag: ActionTag.reply.rawValue)
        ])
        #expect(vm.loadedMessages.count == 3)
        guard vm.loadedMessages.count == 3 else { return }
        #expect(vm.loadedMessages[0].messageId == "m-reply-durable")
        #expect(vm.loadedMessages[1].messageId == "m-reply-staged")
        #expect(vm.loadedMessages[2].messageId == "m-archive-durable")
    }

    // MARK: - 13. resetMessages surfaces staged-but-not-yet-durable rows via the reader

    // PLAN_INBOX_UNIFIED_READ.md §3 deleted `resetMessages`' explicit
    // `insertStagedRows(NSEDataBridge.latestStagedRows...)` re-seed call — the
    // observable behavior this test pins is UNCHANGED, because
    // `resetMessages`' `fetchPage(before: nil)` already routes through
    // `InboxListReader`/`InboxListComposer`, which reads
    // `NSEDataBridge.latestStagedRows` directly as S on every fetch (Phase 3).
    // So a staged-but-not-yet-durable row still appears on every
    // `resetMessages()` call — just via the reader, not a second insert pass.
    @Test("resetMessages surfaces staged-but-not-yet-durable rows from NSEDataBridge.latestStagedRows via the reader")
    func resetMessagesReseedsFromLatestStagedRows() throws {
        let (_, inbox, _, dir, previous) = try makeTestDB()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            try? FileManager.default.removeItem(at: dir)
            clearOverlay(); resetStagedGlobal()
        }
        clearOverlay(); resetStagedGlobal()

        let row = makeStagedRow(messageId: "m-reseed")
        NSEDataBridge.latestStagedRows.withLock { $0 = [row] }

        // init() -> loadInitialPage() -> resetMessages() -> fetchPage already
        // surfaces it once, via the reader.
        let vm = InboxViewModel(folders: [inbox])
        #expect(vm.loadedMessages.count == 1)
        guard vm.loadedMessages.count == 1 else { return }
        #expect(vm.loadedMessages[0].messageId == "m-reseed")

        // Call resetMessages() again explicitly to pin the behavior independent
        // of the one-time init path (mirrors a filter/folder-change reset,
        // e.g. clearFilters()).
        vm.resetMessages()
        #expect(vm.loadedMessages.count == 1)
        #expect(vm.loadedMessages.first?.messageId == "m-reseed")
    }

    // MARK: - 14. Undo + label filter — insertUndoneMessages honors the active label filter

    // `insertUndoneMessages` is NOT the zero-I/O staged path — it already
    // reads the durable header by id, by design (PLAN_INBOX_UNIFIED_READ.md
    // §5 Phase 4). Loading real labels alongside that fetch (via
    // `UserLabelStore.loadLabels`, the same helper `InboxListReader`'s P-step
    // uses for its "undo shape") lets it honor an active label filter with
    // full fidelity instead of unconditionally dropping every undone row —
    // matching what the reader would show on the very next reload.
    @Test("undo + label filter: insertUndoneMessages includes a genuinely-labeled undone row and excludes an unlabeled one")
    func insertUndoneMessagesHonorsLabelFilter() async throws {
        let (pool, inbox, archive, dir, previous) = try makeTestDB()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            try? FileManager.default.removeItem(at: dir)
            clearOverlay(); resetStagedGlobal()
        }
        clearOverlay(); resetStagedGlobal()

        // Two durable headers in Archive (the "already moved" state) — one
        // carries the filtered label, the other carries none.
        let labeled = makeDurableHeader(folder: archive, messageId: "m-undo-labeled", isInInbox: false)
        let unlabeled = makeDurableHeader(folder: archive, messageId: "m-undo-unlabeled", isInInbox: false)
        try await pool.writeWithoutTransaction { db in
            let l = labeled; try l.insert(db)
            let u = unlabeled; try u.insert(db)
            try UserLabel(id: "label-x", accountId: "acc1", name: "Filtered", isSystem: false).insert(db)
            try MessageUserLabel(messageId: labeled.id, userLabelId: "label-x").insert(db)
        }

        let vm = InboxViewModel(folders: [inbox])
        vm.filterLabelIds = ["label-x"]

        // Mirror UndoService.undo()'s .move case for BOTH messages: overlay
        // registered before the deferred DB restore write.
        AccountManager.shared.registerMutation(id: labeled.id, mutation: .init(
            folderId: inbox.id, folderPath: inbox.path, isInInbox: true
        ))
        AccountManager.shared.registerMutation(id: unlabeled.id, mutation: .init(
            folderId: inbox.id, folderPath: inbox.path, isInInbox: true
        ))

        vm.insertUndoneMessages([labeled.id, unlabeled.id])

        #expect(vm.loadedMessages.count == 1)
        guard vm.loadedMessages.count == 1 else { return }
        #expect(vm.loadedMessages[0].id == labeled.id)
        #expect(vm.loadedMessages[0].userLabels.map(\.id) == ["label-x"])
        #expect(!vm.loadedMessages.contains { $0.id == unlabeled.id })
    }

    // MARK: - 15. F2 audit: loadMoreMessages excludeIds ordering, 2 folders,
    // real pageSize (PLAN_INBOX_UNIFIED_READ.md audit). Reproduces the exact
    // `fetchPage`/`compose` trace: an already-loaded, tag-first (triage mode)
    // row from one folder legitimately re-enters a later page's D query —
    // its date is older than the pagination cursor, which in triage mode is
    // NOT the globally oldest loaded date (tag priority sorts it ahead of
    // newer, untagged rows on page 1). Before the fix, `compose` trimmed to
    // `targetCount` BEFORE the VM's `loadedIds` dedup filtered that row back
    // out — eating a trim slot and silently dropping a legitimately older,
    // not-yet-loaded row, with `hasMoreMessages` flipping false even though
    // reachable mail remained.

    @Test("loadMoreMessages (triage, 2 folders, real pageSize): an already-loaded old high-priority row re-entering page 2's query does not shrink the page or drop older rows")
    func loadMoreMessagesExcludeIdsOrderingMultiFolder() throws {
        let (pool, inbox, _, dir, previous) = try makeTestDB()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            try? FileManager.default.removeItem(at: dir)
            clearOverlay(); resetStagedGlobal()
        }
        clearOverlay(); resetStagedGlobal()

        let priority = Folder(name: "Priority", path: "Priority", role: .inbox, accountId: "acc1")
        try pool.writeWithoutTransaction { db in let p = priority; try p.insert(db) }

        let pageSize = SyncConfig.inboxPageSize
        let now = Date()

        // folder1 ("Priority"): ONE reply-tagged row, dated far older than
        // everything else below — triage mode sorts it FIRST on tagSortOrder
        // alone, regardless of its (old) date.
        let replyOld = makeDurableHeader(
            folder: priority, messageId: "reply-old",
            date: now.addingTimeInterval(-60 * 200), actionTag: .reply
        )

        // folder2 (inbox): pageSize "newer" rows (page-1 candidates) +
        // (pageSize - 1) "older" rows (page-2 candidates). NOTE pageSize-1,
        // not pageSize, for the older tier: the per-folder D query caps each
        // folder at `query.targetCount` rows independently — a pre-existing,
        // unrelated-to-F2 bound ("Bounded: fetches at most folders.count ×
        // pageSize", see fetchPage's doc comment). Page 1's trim bumps
        // exactly ONE "newer" row out of the window (§4.3 — `replyOld`'s tag
        // priority always wins the trim, so a "newer" row pays for it); that
        // bumped row rejoins the "older" tier as a page-2 candidate for
        // folder2, so sizing the older tier at pageSize-1 keeps folder2's
        // combined page-2 candidate count exactly at its per-folder cap —
        // isolating the F2 exclude-ordering bug from that separate, expected
        // per-folder bound instead of conflating the two.
        var newerHeaders: [MessageHeader] = []
        for i in 0..<pageSize {
            newerHeaders.append(makeDurableHeader(
                folder: inbox, messageId: "newer-\(i)",
                date: now.addingTimeInterval(-60 * Double(i + 1))
            ))
        }
        var olderHeaders: [MessageHeader] = []
        for i in 0..<(pageSize - 1) {
            olderHeaders.append(makeDurableHeader(
                folder: inbox, messageId: "older-\(i)",
                date: now.addingTimeInterval(-60 * Double(pageSize + 1 + i))
            ))
        }
        try pool.writeWithoutTransaction { db in
            let r = replyOld; try r.insert(db)
            for h in newerHeaders { let x = h; try x.insert(db) }
            for h in olderHeaders { let x = h; try x.insert(db) }
        }

        let vm = InboxViewModel(folders: [priority, inbox])
        // Set mode AFTER construction (mirrors triageOrderSortsFetchedAndStagedRows)
        // and force a fresh page-1 fetch under it.
        vm.mode = .triage
        vm.resetMessages()

        // Page 1: replyOld (tag-first) + the newest (pageSize - 1) of the
        // "newer" tier — the trim bumps exactly one "newer" row (the oldest
        // of that tier, `newer-(pageSize-1)`) out of the window. Expected,
        // correct triage window-trim behavior (§4.3) — NOT the bug under test.
        #expect(vm.loadedMessages.count == pageSize)
        #expect(vm.hasMoreMessages == true)
        let bumpedNewerId = MessageIdentity.headerId(
            accountId: "acc1", folderPath: "INBOX", messageId: "newer-\(pageSize - 1)"
        )
        #expect(
            !vm.loadedMessages.contains { $0.id == bumpedNewerId },
            "test setup assumption violated: expected exactly one newer row bumped from page 1"
        )

        vm.loadMoreMessages()

        // The fix: `excludeIds` removes `replyOld` (already loaded) AFTER
        // eligibility decisions but BEFORE compose's targetCount trim, so the
        // bumped newer row + the full older tier both make it into a FULL
        // pageSize-sized next page — no drops, hasMoreMessages stays true.
        #expect(vm.loadedMessages.count == pageSize * 2, "page 2 delivered fewer than pageSize rows — F2 regression")
        #expect(vm.hasMoreMessages == true, "hasMoreMessages flipped false with reachable mail remaining — F2 regression")

        let loadedIdsAfter = Set(vm.loadedMessages.map(\.id))
        #expect(
            loadedIdsAfter.contains(bumpedNewerId),
            "the newer row bumped from page 1 was permanently dropped, not deferred to page 2"
        )
        for i in 0..<(pageSize - 1) {
            let id = MessageIdentity.headerId(accountId: "acc1", folderPath: "INBOX", messageId: "older-\(i)")
            #expect(loadedIdsAfter.contains(id), "older-\(i) missing from page 2 — F2 regression")
        }
        // No duplicate `replyOld` — it re-entered the D query but must not
        // double-render (it's already on screen from page 1).
        #expect(vm.loadedMessages.filter { $0.id == replyOld.id }.count == 1)
    }

    // MARK: - 16. G1 audit: Pass-1 field-level preservation — non-empty beats empty

    @Test("Pass-1 retains an existing non-empty computedThreadId when the reader's adoption misses on reload (parent evicted from the window)")
    func pass1RetainsComputedThreadIdOnAdoptionMiss() async throws {
        let (pool, inbox, _, dir, previous) = try makeTestDB()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            try? FileManager.default.removeItem(at: dir)
            clearOverlay(); resetStagedGlobal()
        }
        clearOverlay(); resetStagedGlobal()

        // Durable, on-screen parent with a real thread id + rfc822 id.
        var parent = MessageHeader(
            messageId: "1000", subject: "Parent", from: "Sender", fromAddress: "s@example.com",
            to: "me@example.com", date: Date().addingTimeInterval(-60), snippet: "p",
            folderId: inbox.id, accountId: "acc1", folderPath: "INBOX", isInInbox: true
        )
        parent.headerComplete = true
        parent.rfc822MessageId = "<parent@x>"
        parent.computedThreadId = "thread-A"
        let parentId = parent.id
        let parentToInsert = parent
        try await pool.writeWithoutTransaction { db in try parentToInsert.insert(db) }

        let vm = InboxViewModel(folders: [inbox])
        #expect(vm.loadedMessages.count == 1)

        // Staged reply adopts the on-screen parent's thread id instantly via
        // the zero-I/O insertStagedRows path (InboxStagedInsertTests.
        // adoptsThreadId pins this in isolation).
        let reply = StagedInboxRow(
            accountId: "acc1", folderPath: "INBOX", messageId: "m-reply",
            rfc822MessageId: "<reply@x>", threadId: nil, inReplyTo: "<parent@x>", references: [],
            subject: "Re: Parent", senderName: "Sender", senderAddress: "s@example.com",
            to: "me@example.com", snippet: "reply snip", date: Date(),
            isRead: false, isFlagged: false, hasAttachments: false, isReplied: false,
            isForwarded: false, actionTag: nil, summaryBlurb: nil
        )
        // Seed the global BEFORE insert — mirrors the merge's publish-before-
        // post order (see stagedRowSurvivesReloadPreDurability's comment).
        NSEDataBridge.latestStagedRows.withLock { $0 = [reply] }
        vm.insertStagedRows([reply])
        #expect(vm.loadedMessages.count == 2)
        let replyId = MessageIdentity.headerId(accountId: "acc1", folderPath: "INBOX", messageId: "m-reply")
        #expect(vm.loadedMessages.first { $0.id == replyId }?.computedThreadId == "thread-A")
        #expect(vm.displayGroups.count == 1)
        guard vm.displayGroups.count == 1 else { return }
        #expect(vm.displayGroups[0].id == "thread-A")

        // Simulate the parent being evicted from the window / re-keyed (e.g.
        // a UID remap) — the composer's D∪P adoption pool no longer has it,
        // so a fresh reload synthesizes the reply with an EMPTY
        // computedThreadId (no adoption match this cycle). The staged row
        // itself is unchanged — still in S, not yet durable.
        try await pool.writeWithoutTransaction { db in
            try db.execute(sql: "DELETE FROM messageHeader WHERE id = ?", arguments: [parentId])
        }

        await vm.reloadMessages()

        // G1: the fresh (empty) computedThreadId must not clobber the
        // existing (adopted, non-empty) one — and the ThreadGroup key stays
        // stable (the user-visible contract; a reverted key would silently
        // re-collapse the group).
        let reloaded = vm.loadedMessages.first { $0.id == replyId }
        #expect(reloaded?.computedThreadId == "thread-A")
        #expect(vm.displayGroups.contains { $0.id == "thread-A" })
    }

    @Test("Pass-1 retains an existing non-empty snippet when a re-synthesized staged row's fresh snippet is empty (real SnippetLoader tier-1 FTS in-place fill, ahead of the staging snapshot)")
    func pass1RetainsSnippetOnEmptyFreshRow() async throws {
        let (_, inbox, _, dir, previous) = try makeTestDB()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            try? FileManager.default.removeItem(at: dir)
            clearOverlay(); resetStagedGlobal()
        }
        clearOverlay(); resetStagedGlobal()

        let vm = InboxViewModel(folders: [inbox])
        // A staged-only row (no durable GRDB copy) with an EMPTY staged
        // snippet — this field NEVER changes for the rest of the test, so
        // every `compose` re-synthesizes the row with an empty snippet via
        // `StagedInboxRow.toMessageHeader()`, exactly like a durable-less
        // push whose provider snippet was blank.
        let row = StagedInboxRow(
            accountId: "acc1", folderPath: "INBOX", messageId: "m-g1-snippet-fill",
            rfc822MessageId: nil, threadId: nil, inReplyTo: nil, references: [],
            subject: "Subj", senderName: "Sender", senderAddress: "s@example.com",
            to: "me@example.com", snippet: "", date: Date(),
            isRead: false, isFlagged: false, hasAttachments: false, isReplied: false,
            isForwarded: false, actionTag: nil, summaryBlurb: nil
        )
        NSEDataBridge.latestStagedRows.withLock { $0 = [row] }
        vm.insertStagedRows([row])
        #expect(vm.loadedMessages.count == 1)
        let id = MessageIdentity.headerId(accountId: "acc1", folderPath: "INBOX", messageId: "m-g1-snippet-fill")
        #expect(vm.loadedMessages.first { $0.id == id }?.snippet.isEmpty == true)

        // Seed the REAL FTS index (`SearchIndex.shared` — a process-wide
        // singleton, decoupled from the `AppDatabase.shared` swap; same
        // pattern as `SelfHealBackfillFTSTests`) with body text for this
        // headerId, so `loadSnippetBatch`'s tier-1 lookup can find it and
        // perform the REAL in-place fill (`loadedMessages[idx].snippet =
        // snippet`, InboxViewModel.swift ~1336) — the exact mechanism
        // `flushAIBatch`'s snippet-fallback comment documents.
        _ = try await SearchIndex.shared.indexHeaders([
            FTSHeaderRecord(
                headerId: id, messageId: "m-g1-snippet-fill", subject: "Subj",
                from: "Sender", to: "me@example.com",
                dateMs: Int64(Date().timeIntervalSince1970 * 1000)
            )
        ])
        try await SearchIndex.shared.updateBody(
            headerId: id, body: "This is the real message body used to drive the in-place snippet fill."
        )

        // Drive the real public entry point — debounces 100ms then runs
        // loadSnippetBatch's tier-0 (DB/staged-header miss) → tier-1 (FTS hit).
        guard let snapshot = vm.loadedMessages.first(where: { $0.id == id }) else {
            Issue.record("staged row not inserted"); return
        }
        vm.requestSnippetIfNeeded(for: snapshot)

        var filledSnippet: String?
        for _ in 0..<40 {
            if let s = vm.loadedMessages.first(where: { $0.id == id })?.snippet, !s.isEmpty {
                filledSnippet = s
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        guard let filledSnippet else {
            Issue.record("SnippetLoader tier-1 in-place fill did not land — test setup issue, not the fix under test")
            try? await SearchIndex.shared.removeMessages(headerIds: [id])
            return
        }

        // The staged snapshot in S is UNCHANGED (still empty) — every
        // compose re-synthesizes the row from it via `toMessageHeader()`.
        await vm.reloadMessages()

        let reloaded = vm.loadedMessages.first { $0.id == id }
        #expect(
            reloaded?.snippet == filledSnippet,
            "Pass-1 let an empty fresh snippet clobber the SnippetLoader's in-place fill"
        )
        try? await SearchIndex.shared.removeMessages(headerIds: [id])
    }

    @Test("Pass-1 does NOT over-preserve: a durable fresh row with a real, DIFFERENT snippet/computedThreadId always wins")
    func pass1FreshNonEmptyValuesWinOverExisting() async throws {
        let (pool, inbox, _, dir, previous) = try makeTestDB()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            try? FileManager.default.removeItem(at: dir)
            clearOverlay(); resetStagedGlobal()
        }
        clearOverlay(); resetStagedGlobal()

        var header = MessageHeader(
            messageId: "m1", subject: "Subj", from: "Sender", fromAddress: "s@example.com",
            to: "me@example.com", date: Date(), snippet: "old snippet",
            folderId: inbox.id, accountId: "acc1", folderPath: "INBOX", isInInbox: true
        )
        header.headerComplete = true
        header.computedThreadId = "thread-old"
        let headerId = header.id
        let headerToInsert = header
        try await pool.writeWithoutTransaction { db in try headerToInsert.insert(db) }

        let vm = InboxViewModel(folders: [inbox])
        #expect(vm.loadedMessages.count == 1)
        guard vm.loadedMessages.count == 1 else { return }
        #expect(vm.loadedMessages[0].snippet == "old snippet")
        #expect(vm.loadedMessages[0].computedThreadId == "thread-old")

        try await pool.writeWithoutTransaction { db in
            try db.execute(
                sql: "UPDATE messageHeader SET snippet = ?, computedThreadId = ? WHERE id = ?",
                arguments: ["new snippet", "thread-new", headerId]
            )
        }

        await vm.reloadMessages()
        #expect(vm.loadedMessages.count == 1)
        guard vm.loadedMessages.count == 1 else { return }
        #expect(vm.loadedMessages[0].snippet == "new snippet")
        #expect(vm.loadedMessages[0].computedThreadId == "thread-new")
    }
}
