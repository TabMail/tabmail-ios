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
}
