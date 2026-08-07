/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Synchronization
import Testing
@testable import TabMail

/// Pins the fix for the "dead toggle under write-queue lag" bug: `toggleRead`,
/// `markRead(_ messageIds:)`, and `toggleFlag` used to gate the USER GESTURE
/// behind `lookupMessage` — a synchronous main-actor `dbPool.read` — and
/// derive the target state (`newIsRead = !message.isRead`) from that DB row.
/// The DB lags the FIFO write queue by seconds under write bursts (logged
/// main-thread stalls up to 3.7s), so a second toggle within that window read
/// the SAME stale value as the first and computed the SAME target — a dead
/// no-op toggle from the user's perspective (log-confirmed: a drain of
/// `markRead×3 + markUnread×2` = the user hammering a dead toggle).
///
/// The fix: derive current state from the ON-SCREEN snapshot (`loadedMessages`)
/// — the visualized state the user is acting on — and resolve the
/// `MessageHeader` needed for the actual write OFF-MAIN, inside the already-
/// queued `enqueueWrite` closure, via the new `AccountManager.resolveHeaderForAction`
/// / `resolveHeadersForAction` helpers (one implementation shared with
/// `InboxViewModel.lookupMessage`'s two-step durable/staged-synthesis lookup).
///
/// `.serialized`: tests touch `AccountManager.shared`'s process-wide optimistic
/// overlay + FIFO write queue and `NSEDataBridge.latestStagedRows` — mirrors
/// `InboxListBehaviorPinningTests` / `MessageDetailStagedFallbackTests`.
///
/// BOTH traits are load-bearing, and they do different jobs. `.serialized`
/// orders tests INSIDE this suite. `.processGlobalState` is what excludes
/// OTHER suites: this one swaps `AppDatabase.shared` (`makeTestDB`) and wipes
/// `AccountManager.shared`'s process-wide overlay (`clearOverlay` →
/// `snapshotOverlay` + `removeOverlayEntries`), and `.serialized` does nothing
/// to stop a different suite doing the same thing concurrently
/// (`ProcessGlobalTestState.swift:8-14`). Without it the protection was
/// ONE-SIDED — `ProviderIdQueueFuzzTests` (T0.8) took the shared lock, this
/// suite never asked for it and barged in, and the fuzz suite's whole-overlay
/// wipe deleted this suite's in-flight entries. Reproduced 2026-07-30:
/// running only these two suites together went red 2 times in 9 runs on
/// `sequentialCyclesEachExecuteIndependently`. Do NOT "fix" a recurrence by
/// relaxing an assertion, adding a wait, or widening a bound — the trait is
/// the fix. Matches `v2final:…/InboxGestureActionTests.swift:31` verbatim.
@Suite("Inbox gesture actions — zero-DB, act-on-visualized-state (dead-toggle fix)", .serialized, .processGlobalState)
@MainActor
struct InboxGestureActionTests {

    // MARK: - Harness (mirrors InboxListBehaviorPinningTests.swift)

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
        isFlagged: Bool = false
    ) -> StagedInboxRow {
        StagedInboxRow(
            accountId: accountId, folderPath: folderPath, messageId: messageId,
            rfc822MessageId: nil, threadId: nil, inReplyTo: nil, references: [],
            subject: "Subj \(messageId)", senderName: "Sender", senderAddress: "s@example.com",
            to: "me@example.com", snippet: "snip", date: date,
            isRead: isRead, isFlagged: isFlagged, hasAttachments: false, isReplied: false,
            isForwarded: false, actionTag: nil, summaryBlurb: nil
        )
    }

    /// A durable, query-visible header (`headerComplete = true`) for a folder.
    private func makeDurableHeader(
        folder: Folder,
        messageId: String,
        date: Date = Date(),
        isRead: Bool = false,
        isFlagged: Bool = false
    ) -> MessageHeader {
        var h = MessageHeader(
            messageId: messageId, subject: "Subj \(messageId)", from: "Sender", fromAddress: "s@example.com",
            to: "me@example.com", date: date, snippet: "snip",
            folderId: folder.id, accountId: folder.accountId, folderPath: folder.path, isInInbox: true
        )
        h.headerComplete = true
        h.isRead = isRead
        h.isFlagged = isFlagged
        return h
    }

    /// Teardown shared by every test. The production paths these tests drive
    /// fire UNSTRUCTURED background Tasks the drain barrier cannot join
    /// (drainPendingQueue, unread recounts, queueTagWrite's drain hop,
    /// applyManualTag steps 3-4) — they can run AFTER the defers. Restoring a
    /// nil `previous` would make `AppDatabase.rawPool`'s force-unwrap
    /// fatalError the whole test process. `InstalledTestDatabaseLifetime`
    /// restores a real predecessor when present, leaves a nil-predecessor
    /// fixture installed, and retains the complete fixture group until process
    /// exit in both cases.
    private func restoreTestDB(previous: AppDatabase?, pool: DatabasePool, dir: URL) {
        InstalledTestDatabaseLifetime.finish(
            previous: previous,
            pool: pool,
            directory: dir
        )
    }

    private func clearOverlay() {
        let snapshot = AccountManager.shared.snapshotOverlay()
        AccountManager.shared.removeOverlayEntries(ids: Array(snapshot.keys))
    }

    private func resetStagedGlobal() {
        NSEDataBridge.latestStagedRows.withLock { $0 = [] }
    }

    /// Enqueue a barrier onto `AccountManager.shared`'s FIFO write queue and
    /// await it — since the queue is strictly FIFO, every write enqueued
    /// BEFORE this call is guaranteed to have drained by the time this
    /// returns. Mirrors `MessageDetailStagedFallbackTests.pinSurvivesWhileMoveQueued`'s
    /// closing barrier.
    private func drainWriteQueue() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            Task { await AccountManager.shared.enqueueWrite { cont.resume() } }
        }
    }

    // MARK: - (a) Rapid double-toggle correctness

    @Test("toggleRead: a second toggle immediately after the first flips BACK, derived from the visualized snapshot — not a stale DB read")
    func rapidDoubleToggleReadDerivesFromVisualizedState() async throws {
        let (pool, inbox, _, dir, previous) = try makeTestDB()
        defer {
            restoreTestDB(previous: previous, pool: pool, dir: dir)
            clearOverlay(); resetStagedGlobal()
        }
        clearOverlay(); resetStagedGlobal()

        let header = makeDurableHeader(folder: inbox, messageId: "m-toggle", isRead: false)
        try await pool.writeWithoutTransaction { db in try header.insert(db) }
        let id = header.id

        let vm = InboxViewModel(folders: [inbox])
        #expect(vm.loadedMessages.count == 1)
        #expect(vm.loadedMessages.first?.isRead == false)

        // Block the FIFO write queue BEFORE either toggle so neither queued
        // write can drain while we assert the visualized (snapshot) state —
        // mirrors MessageDetailStagedFallbackTests.pinSurvivesWhileMoveQueued.
        let (gateStream, gate) = AsyncStream<Void>.makeStream()
        await AccountManager.shared.enqueueWrite {
            var iterator = gateStream.makeAsyncIterator()
            _ = await iterator.next()
        }
        defer { gate.finish() }

        // Toggle #1: unread -> read.
        vm.toggleRead(id)
        #expect(vm.loadedMessages.first?.isRead == true)

        // Toggle #2, IMMEDIATELY (no drain in between): derived from the
        // JUST-FLIPPED visualized snapshot ("read"), so this MUST flip back
        // to unread. Pre-fix, `toggleRead` gated on a synchronous
        // `lookupMessage` DB read — the DB row is still "unread" here too
        // (the write queue is gated, and even ungated the first write hasn't
        // executed yet), so BOTH toggles would compute the same
        // unread -> read target: a dead second toggle.
        vm.toggleRead(id)
        #expect(vm.loadedMessages.first?.isRead == false, "second toggle did not flip back — computed from a stale source instead of the visualized snapshot")

        // The DB row itself is untouched while gated — confirms the gesture
        // path performed zero durable writes ahead of the queue.
        let dbIsReadWhileGated = try await pool.read { db in try MessageHeader.fetchOne(db, key: id)?.isRead }
        #expect(dbIsReadWhileGated == false)
    }

    // MARK: - (b) Zero-DB gesture on a staged-only row

    @Test("toggleRead on a staged-only row (no durable header) flips the snapshot instantly; the queued write resolves via the ADR-IOS-049 staged synthesis and no-ops gracefully with zero durable rows")
    func toggleReadOnStagedOnlyRowFlipsInstantlyAndResolvesGracefully() async throws {
        let (pool, inbox, _, dir, previous) = try makeTestDB()
        defer {
            restoreTestDB(previous: previous, pool: pool, dir: dir)
            clearOverlay(); resetStagedGlobal()
        }
        clearOverlay(); resetStagedGlobal()

        let vm = InboxViewModel(folders: [inbox])
        let row = makeStagedRow(messageId: "m-staged-toggle", isRead: false)
        NSEDataBridge.latestStagedRows.withLock { $0 = [row] }
        vm.insertStagedRows([row])
        #expect(vm.loadedMessages.count == 1)
        let id = MessageIdentity.headerId(accountId: "acc1", folderPath: "INBOX", messageId: "m-staged-toggle")
        #expect(vm.loadedMessages.first?.isRead == false)

        // Gesture: the snapshot flips INSTANTLY — the row is not durable
        // anywhere at gesture time, so a gesture-path DB read would have
        // found nothing durable either; the fix never attempts one.
        vm.toggleRead(id)
        #expect(vm.loadedMessages.first?.isRead == true)

        // Mechanism check: the SAME resolution the queued closure uses finds
        // this id via the staged synthesis (mirrors `lookupMessage`'s
        // two-step lookup) — this is what lets the queued write complete
        // even though the row was never durable when the gesture fired.
        let resolved = await AccountManager.shared.resolveHeaderForAction(id: id)
        #expect(resolved != nil)
        #expect(resolved?.id == id)

        // End-to-end: drain the real queued closure. `AccountManager.markRead`
        // -> `ensureDurable` sees the id missing from GRDB and calls
        // `NSEMergeCoordinator.shared.merge()`, which safely no-ops in the
        // test host (no app-group container — see NSEDataBridge.performMerge's
        // early-return branch), then the UPDATE touches zero durable rows.
        // Achievable contract: the gesture never strands, crashes, or hangs
        // on a not-yet-durable id — it just can't durably persist a row that
        // was never written to GRDB (a real device's `ensureDurable` merges
        // the row durable first via the production app-group path).
        await drainWriteQueue()
        let dbCount = try await pool.read { db in try MessageHeader.filter(Column("accountId") == "acc1").fetchCount(db) }
        #expect(dbCount == 0, "no durable row ever existed for this id — the write is a graceful no-op, not a crash/hang")
    }

    // MARK: - (c) Batch markRead with mixed on-/off-screen members

    @Test("markRead(_:) computes per-member state correctly when some members are off-screen — mixed read/unread, only some in loadedMessages")
    func markReadHandlesMixedOnAndOffScreenMembers() async throws {
        let (pool, inbox, _, dir, previous) = try makeTestDB()
        defer {
            restoreTestDB(previous: previous, pool: pool, dir: dir)
            clearOverlay(); resetStagedGlobal()
        }
        clearOverlay(); resetStagedGlobal()

        // On-screen: one unread, one already-read. Loaded into the VM below.
        let onScreenUnread = makeDurableHeader(folder: inbox, messageId: "m-onscreen-unread", isRead: false)
        let onScreenRead = makeDurableHeader(folder: inbox, messageId: "m-onscreen-read", isRead: true)
        try await pool.writeWithoutTransaction { db in
            let a = onScreenUnread; try a.insert(db)
            let b = onScreenRead; try b.insert(db)
        }

        let vm = InboxViewModel(folders: [inbox])
        #expect(vm.loadedMessages.count == 2)

        // Off-screen: durable in GRDB but inserted AFTER the VM's initial
        // load, so it is never in `loadedMessages` — simulates a thread
        // member captured in a stale `ThreadGroup` value that the current
        // `loadedMessages` no longer carries (see markRead's doc comment).
        let offScreenUnread = makeDurableHeader(folder: inbox, messageId: "m-offscreen-unread", isRead: false)
        try await pool.writeWithoutTransaction { db in try offScreenUnread.insert(db) }
        #expect(!vm.loadedMessages.contains { $0.id == offScreenUnread.id })

        vm.markRead([onScreenUnread.id, onScreenRead.id, offScreenUnread.id])

        // Optimistic UI: only the on-screen UNREAD member flips immediately;
        // the already-read member is untouched; the off-screen member has no
        // snapshot to mutate.
        #expect(vm.loadedMessages.first { $0.id == onScreenUnread.id }?.isRead == true)
        #expect(vm.loadedMessages.first { $0.id == onScreenRead.id }?.isRead == true)
        #expect(vm.loadedMessages.count == 2, "off-screen member must not be inserted into loadedMessages by markRead")

        await drainWriteQueue()

        // Final DB truth: the on-screen unread member and the off-screen
        // unread member both end up read; the already-read member is
        // unaffected (idempotent write).
        let finalStates = try await pool.read { db -> [String: Bool] in
            var result: [String: Bool] = [:]
            for id in [onScreenUnread.id, onScreenRead.id, offScreenUnread.id] {
                result[id] = try MessageHeader.fetchOne(db, key: id)?.isRead
            }
            return result
        }
        #expect(finalStates[onScreenUnread.id] == true)
        #expect(finalStates[onScreenRead.id] == true)
        #expect(finalStates[offScreenUnread.id] == true, "off-screen unread member was not resolved+written by the queued closure")
    }

    // MARK: - (d) toggleFlag equivalent of (a)

    @Test("toggleFlag: a second toggle immediately after the first flips BACK, derived from the visualized snapshot — not a stale DB read")
    func rapidDoubleToggleFlagDerivesFromVisualizedState() async throws {
        let (pool, inbox, _, dir, previous) = try makeTestDB()
        defer {
            restoreTestDB(previous: previous, pool: pool, dir: dir)
            clearOverlay(); resetStagedGlobal()
        }
        clearOverlay(); resetStagedGlobal()

        let header = makeDurableHeader(folder: inbox, messageId: "m-flag-toggle", isFlagged: false)
        try await pool.writeWithoutTransaction { db in try header.insert(db) }
        let id = header.id

        let vm = InboxViewModel(folders: [inbox])
        #expect(vm.loadedMessages.first?.isFlagged == false)

        let (gateStream, gate) = AsyncStream<Void>.makeStream()
        await AccountManager.shared.enqueueWrite {
            var iterator = gateStream.makeAsyncIterator()
            _ = await iterator.next()
        }
        defer { gate.finish() }

        vm.toggleFlag(id)
        #expect(vm.loadedMessages.first?.isFlagged == true)

        vm.toggleFlag(id)
        #expect(vm.loadedMessages.first?.isFlagged == false, "second toggle did not flip back — computed from a stale source instead of the visualized snapshot")

        let dbIsFlaggedWhileGated = try await pool.read { db in try MessageHeader.fetchOne(db, key: id)?.isFlagged }
        #expect(dbIsFlaggedWhileGated == false)
    }

    // MARK: - (e) Overlay-drain correctness

    @Test("toggleRead: after the queued write drains, DB truth matches the LAST toggle's target, not the first — and since the two toggles round-trip back to the original state, the coalesced cycle (ADR-IOS-057) executes as a perfect cancel-out: zero PendingOperations")
    func drainedDBStateMatchesLastToggleTarget() async throws {
        let (pool, inbox, _, dir, previous) = try makeTestDB()
        defer {
            restoreTestDB(previous: previous, pool: pool, dir: dir)
            clearOverlay(); resetStagedGlobal()
        }
        clearOverlay(); resetStagedGlobal()

        let header = makeDurableHeader(folder: inbox, messageId: "m-drain", isRead: false)
        try await pool.writeWithoutTransaction { db in try header.insert(db) }
        let id = header.id

        let vm = InboxViewModel(folders: [inbox])

        // Gate the queue so both toggles are guaranteed to land in the SAME
        // cycle (without a gate, the first toggle's spawned executor Task
        // could race ahead and consume the cycle before the second toggle
        // call runs, splitting them into two independent, non-cancelling
        // writes instead of one coalesced cancel-out).
        let (gateStream, gate) = AsyncStream<Void>.makeStream()
        await AccountManager.shared.enqueueWrite {
            var it = gateStream.makeAsyncIterator()
            _ = await it.next()
        }

        // Two toggles register into ONE coalesced cycle: unread -> read -> unread.
        vm.toggleRead(id)
        vm.toggleRead(id)
        #expect(vm.loadedMessages.first?.isRead == false)

        gate.finish()
        await drainWriteQueue()

        let finalIsRead = try await pool.read { db in try MessageHeader.fetchOne(db, key: id)?.isRead }
        #expect(finalIsRead == false, "final DB state must match the LAST toggle's target (unread), not the first (read)")

        // The overlay entry must not strand once the write has drained.
        let overlay = AccountManager.shared.snapshotOverlay()
        #expect(overlay[id] == nil, "overlay entry stranded after drain — releaseOverlayEntry did not run")

        // ADR-IOS-057 cancel-out contract: the cycle's final target (unread)
        // equals its baseline (unread) — the executor must not have called
        // markRead/markUnread at all, so zero PendingOperations exist.
        let pendingOpsCount = try await pool.read { db in try PendingOperation.fetchCount(db) }
        #expect(pendingOpsCount == 0, "a perfect cancel-out must produce zero PendingOperations")
    }

    // MARK: - (f) Latest-intent coalescing (ADR-IOS-057) — the alternating-toggle regression
    //
    // Pins the fix for the "dead toggle under write-queue lag" fix's OWN
    // regression (2026-07-10, logmain.log line 1743): `AccountManager.optimisticOverlay`
    // is COALESCED — one `PendingMutation` per id, always holding the LATEST
    // registered intent — but every queued gesture closure called
    // `manager.removeOverlayEntries(ids:)` unconditionally on ITS OWN
    // completion. With N alternating toggles queued FIFO behind a slow write
    // lane, op #1 completing wiped the coalesced entry (which by then already
    // carried op #N's registered intent, since `registerMutation` runs
    // SYNCHRONOUSLY at gesture time) while ops #2..N were still in flight —
    // every `reloadMessages()` call in that window fell through to raw DB
    // truth (an intermediate toggle target) instead of the user's final
    // intent. Same bug class as `MessageDetailViewModel.localMovePins`
    // (ADR-IOS-049 amendment round 8): "overlay-presence is the wrong proxy
    // for in-flight-ness — a sibling op's drain ends the window early."
    //
    // The refcount fix (retain/release) was the FIRST cure. ADR-IOS-057 goes
    // further: repeated gesture intents for the SAME id now coalesce into ONE
    // `AccountManager.IntentCycle` — N alternating toggles hold exactly ONE
    // retain and queue exactly ONE executor closure (`executeIntentCycle`),
    // not N. The "op1+op2 done, op3 still queued" mid-drain window this test
    // used to probe no longer exists FOR REPEATED TOGGLES OF THE SAME FIELD
    // (there is only ever one closure per open cycle) — what remains to pin
    // is that (a) N rapid toggles really do collapse to ONE retain/closure,
    // and (b) a reload while that ONE cycle is still queued shows the FINAL
    // registered intent, not raw (pre-gesture) DB truth.

    @Test("toggleRead: three rapid alternating toggles collapse into ONE coalesced cycle (ADR-IOS-057) — refcount 1, ONE queued closure; a reload while that cycle is still gated shows the FINAL intent, and after release+drain DB truth matches the final intent with no strand")
    func midDrainReloadShowsFinalIntentAcrossAlternatingToggles() async throws {
        let (pool, inbox, _, dir, previous) = try makeTestDB()
        defer {
            restoreTestDB(previous: previous, pool: pool, dir: dir)
            clearOverlay(); resetStagedGlobal()
        }
        clearOverlay(); resetStagedGlobal()

        let header = makeDurableHeader(folder: inbox, messageId: "m-alt-toggle", isRead: false)
        try await pool.writeWithoutTransaction { db in try header.insert(db) }
        let id = header.id

        let vm = InboxViewModel(folders: [inbox])
        #expect(vm.loadedMessages.first?.isRead == false)

        // gate0: blocks the FIFO write queue BEFORE any toggle.
        let (gate0Stream, gate0) = AsyncStream<Void>.makeStream()
        await AccountManager.shared.enqueueWrite {
            var it = gate0Stream.makeAsyncIterator()
            _ = await it.next()
        }

        // Three rapid toggles: unread -> read -> unread -> read (final: read).
        // `registerGestureIntent` runs SYNCHRONOUSLY inside `toggleRead`, so
        // the overlay + cycle are already updated the instant each call
        // returns; only the cycle's ONE executor closure (spawned once, on
        // the FIRST toggle) is deferred behind gate0.
        vm.toggleRead(id)
        vm.toggleRead(id)
        vm.toggleRead(id)
        #expect(vm.loadedMessages.first?.isRead == true, "on-screen snapshot after 3 toggles must reflect the LAST toggle's target")
        #expect(AccountManager.shared.overlayOpRefCountForTesting()[id] == 1, "three toggles on the same id coalesce into ONE cycle — ONE retain, not three")
        #expect(AccountManager.shared.pendingIntentCyclesForTesting()[id]?.isReadTarget == true, "cycle's net isRead target must be the LAST toggle's value")

        // Let the cycle's executor Task actually append behind gate0.
        try await Task.sleep(for: .milliseconds(50))

        // Regression check: reload while the cycle's ONE closure is still
        // queued. Pre-fix (unconditional `removeOverlayEntries`, no
        // coalescing), an EARLIER op completing could wipe the overlay while
        // a later toggle was still in flight; post-fix there is only ever
        // ONE closure per open cycle, and it hasn't run yet — the overlay
        // must still carry the FINAL registered intent (read), not raw
        // (pre-gesture) DB truth (unread).
        await vm.reloadMessages()
        #expect(vm.loadedMessages.first?.isRead == true, "reload while the coalesced cycle is still queued must show the FINAL intent")

        gate0.finish()
        await drainWriteQueue()

        let finalIsRead = try await pool.read { db in try MessageHeader.fetchOne(db, key: id)?.isRead }
        #expect(finalIsRead == true, "DB truth after full drain must match the LAST toggle's target")
        #expect(AccountManager.shared.snapshotOverlay()[id] == nil, "overlay entry stranded after full drain")
        #expect(AccountManager.shared.overlayOpRefCountForTesting()[id] == nil, "refcount entry stranded after full drain")
        #expect(AccountManager.shared.pendingIntentCyclesForTesting()[id] == nil, "intent cycle stranded after full drain")
    }

    // MARK: - (g) Refcount hygiene

    @Test("refcount hygiene: three toggles on the same id coalesce into ONE cycle (ADR-IOS-057, refcount 1); after it drains, the overlay entry, the refcount entry, AND the intent-cycle entry are all gone — no strand")
    func refcountDrainsToEmptyAfterAlternatingToggles() async throws {
        let (pool, inbox, _, dir, previous) = try makeTestDB()
        defer {
            restoreTestDB(previous: previous, pool: pool, dir: dir)
            clearOverlay(); resetStagedGlobal()
        }
        clearOverlay(); resetStagedGlobal()

        let header = makeDurableHeader(folder: inbox, messageId: "m-refcount-hygiene", isRead: false)
        try await pool.writeWithoutTransaction { db in try header.insert(db) }
        let id = header.id

        let vm = InboxViewModel(folders: [inbox])

        // Gate the queue so the cycle's executor Task cannot race ahead and
        // consume the cycle between the three toggle calls below (without a
        // gate, the FIRST toggle's spawned Task could run to completion on
        // another thread before the third toggle call executes, splitting
        // one coalesced cycle into two and leaving refcount 2, not 1).
        let (gateStream, gate) = AsyncStream<Void>.makeStream()
        await AccountManager.shared.enqueueWrite {
            var it = gateStream.makeAsyncIterator()
            _ = await it.next()
        }

        vm.toggleRead(id) // -> read
        vm.toggleRead(id) // -> unread
        vm.toggleRead(id) // -> read
        // Retain is synchronous (runs inside toggleRead's registerGestureIntent
        // call, not the deferred closure) — the refcount is already 1 the
        // instant these return, since all three coalesce into ONE cycle.
        #expect(AccountManager.shared.overlayOpRefCountForTesting()[id] == 1, "three toggles on the same id coalesce into ONE cycle, holding exactly one retain")

        gate.finish()
        await drainWriteQueue()

        #expect(AccountManager.shared.snapshotOverlay()[id] == nil, "overlay entry stranded after the cycle drained")
        #expect(AccountManager.shared.overlayOpRefCountForTesting()[id] == nil, "refcount entry stranded after the cycle drained")
        #expect(AccountManager.shared.pendingIntentCyclesForTesting()[id] == nil, "intent cycle stranded after it drained")
    }

    // MARK: - (h) Mixed gestures on the same id

    @Test("mixed gestures on the same id: toggleRead + toggleFlag coalesce into ONE cycle (ADR-IOS-057, refcount 1) carrying both fields — a reload while that cycle is still gated shows BOTH intents, and after release+drain the final state (snapshot + DB) reflects both")
    func mixedGesturesOnSameIdSurviveUntilBothComplete() async throws {
        let (pool, inbox, _, dir, previous) = try makeTestDB()
        defer {
            restoreTestDB(previous: previous, pool: pool, dir: dir)
            clearOverlay(); resetStagedGlobal()
        }
        clearOverlay(); resetStagedGlobal()

        let header = makeDurableHeader(folder: inbox, messageId: "m-mixed", isRead: false, isFlagged: false)
        try await pool.writeWithoutTransaction { db in try header.insert(db) }
        let id = header.id

        let vm = InboxViewModel(folders: [inbox])

        // gate0: blocks the FIFO write queue before either gesture.
        let (gate0Stream, gate0) = AsyncStream<Void>.makeStream()
        await AccountManager.shared.enqueueWrite {
            var it = gate0Stream.makeAsyncIterator()
            _ = await it.next()
        }

        vm.toggleRead(id) // opens the cycle: isRead -> true
        vm.toggleFlag(id) // joins the SAME cycle: isFlagged -> true

        #expect(vm.loadedMessages.first?.isRead == true)
        #expect(vm.loadedMessages.first?.isFlagged == true)
        #expect(AccountManager.shared.overlayOpRefCountForTesting()[id] == 1, "toggleRead + toggleFlag on the same id coalesce into ONE cycle, not two separate retains")

        // Let the cycle's executor Task actually append behind gate0.
        try await Task.sleep(for: .milliseconds(50))

        // Mid-gate reload: NEITHER field has executed yet (one closure, still
        // queued) — the overlay must carry BOTH intents.
        await vm.reloadMessages()
        #expect(vm.loadedMessages.first?.isRead == true)
        #expect(vm.loadedMessages.first?.isFlagged == true, "both intents must survive while the coalesced cycle is still queued")

        gate0.finish()
        await drainWriteQueue()

        let final = try await pool.read { db -> (Bool?, Bool?) in
            let h = try MessageHeader.fetchOne(db, key: id)
            return (h?.isRead, h?.isFlagged)
        }
        #expect(final.0 == true)
        #expect(final.1 == true)
        #expect(AccountManager.shared.snapshotOverlay()[id] == nil)
        #expect(AccountManager.shared.overlayOpRefCountForTesting()[id] == nil)
        #expect(AccountManager.shared.pendingIntentCyclesForTesting()[id] == nil)
    }

    // MARK: - (i) Vanished-row path releases

    @Test("toggleRead on a row that vanishes before the queued write drains (never durable, never staged) still releases its overlay retain — no strand")
    func vanishedRowPathReleasesOverlayRetain() async throws {
        let (pool, inbox, _, dir, previous) = try makeTestDB()
        defer {
            restoreTestDB(previous: previous, pool: pool, dir: dir)
            clearOverlay(); resetStagedGlobal()
        }
        clearOverlay(); resetStagedGlobal()

        let vm = InboxViewModel(folders: [inbox])
        // Row is on-screen (VM-local, via insertStagedRows) but NEVER durable
        // in GRDB and NEVER registered in NSEDataBridge.latestStagedRows —
        // `resolveHeaderForAction` (durable-then-staged two-step lookup) will
        // find nothing for this id when the queued closure runs.
        let row = makeStagedRow(messageId: "m-vanished", isRead: false)
        vm.insertStagedRows([row])
        #expect(vm.loadedMessages.count == 1)
        let id = MessageIdentity.headerId(accountId: "acc1", folderPath: "INBOX", messageId: "m-vanished")

        vm.toggleRead(id)
        #expect(vm.loadedMessages.first?.isRead == true, "optimistic flip happens regardless of durability")
        #expect(AccountManager.shared.overlayOpRefCountForTesting()[id] == 1, "gesture-time retain happens even for a row that will fail to resolve")

        await drainWriteQueue()

        // The queued closure hit the vanished-row branch (`resolveHeaderForAction`
        // returned nil) and called `releaseOverlayEntry` on its own — the
        // refcount and overlay must both be fully drained, not stranded.
        #expect(AccountManager.shared.snapshotOverlay()[id] == nil, "overlay entry stranded on the vanished-row no-op path")
        #expect(AccountManager.shared.overlayOpRefCountForTesting()[id] == nil, "refcount entry stranded on the vanished-row no-op path")
        #expect(AccountManager.shared.pendingIntentCyclesForTesting()[id] == nil, "intent cycle stranded on the vanished-row no-op path")

        let dbCount = try await pool.read { db in try MessageHeader.filter(Column("accountId") == "acc1").fetchCount(db) }
        #expect(dbCount == 0, "no durable row ever existed for this id — the write is a graceful no-op")
    }

    // MARK: - (j) Perfect cancel-out — zero writes

    @Test("4 alternating toggleRead taps (even count) cancel out to a perfect no-op: DB truth unchanged, zero PendingOperations, folder.unreadCount untouched, and the overlay/refcount/cycle registers all drain to empty")
    func alternatingTogglesCancelOutToZeroWrites() async throws {
        let (pool, inbox, _, dir, previous) = try makeTestDB()
        defer {
            restoreTestDB(previous: previous, pool: pool, dir: dir)
            clearOverlay(); resetStagedGlobal()
        }
        clearOverlay(); resetStagedGlobal()

        let header = makeDurableHeader(folder: inbox, messageId: "m-cancel-4x", isRead: false)
        try await pool.writeWithoutTransaction { db in try header.insert(db) }
        let id = header.id
        let unreadCountBefore = try await pool.read { db in try Folder.fetchOne(db, key: inbox.id)?.unreadCount }

        let vm = InboxViewModel(folders: [inbox])

        // Gate the queue so all four taps land in the SAME cycle deterministically
        // (without a gate, the cycle's executor Task could race ahead and consume
        // the cycle between taps, splitting them into two cycles).
        let (gateStream, gate) = AsyncStream<Void>.makeStream()
        await AccountManager.shared.enqueueWrite {
            var it = gateStream.makeAsyncIterator()
            _ = await it.next()
        }

        vm.toggleRead(id) // read
        vm.toggleRead(id) // unread
        vm.toggleRead(id) // read
        vm.toggleRead(id) // unread — back to baseline
        #expect(vm.loadedMessages.first?.isRead == false)
        #expect(AccountManager.shared.overlayOpRefCountForTesting()[id] == 1, "four taps on the same id still coalesce into ONE cycle")

        // Let the cycle's executor Task actually append behind the gate.
        try await Task.sleep(for: .milliseconds(50))

        gate.finish()
        await drainWriteQueue()

        let finalIsRead = try await pool.read { db in try MessageHeader.fetchOne(db, key: id)?.isRead }
        #expect(finalIsRead == false, "cancel-out must leave DB truth unchanged from baseline")

        let pendingOpsCount = try await pool.read { db in try PendingOperation.fetchCount(db) }
        #expect(pendingOpsCount == 0, "a perfect cancel-out must produce zero PendingOperations")

        let unreadCountAfter = try await pool.read { db in try Folder.fetchOne(db, key: inbox.id)?.unreadCount }
        #expect(unreadCountAfter == unreadCountBefore, "cancel-out must not touch folder.unreadCount")

        #expect(AccountManager.shared.snapshotOverlay()[id] == nil)
        #expect(AccountManager.shared.overlayOpRefCountForTesting()[id] == nil)
        #expect(AccountManager.shared.pendingIntentCyclesForTesting()[id] == nil)
    }

    @Test("3 alternating toggleRead taps (odd count, net flip) execute as exactly ONE write of the final target — one PendingOperation, folder.unreadCount adjusted by exactly one")
    func oddToggleCountProducesExactlyOneWrite() async throws {
        let (pool, inbox, _, dir, previous) = try makeTestDB()
        defer {
            restoreTestDB(previous: previous, pool: pool, dir: dir)
            clearOverlay(); resetStagedGlobal()
        }
        clearOverlay(); resetStagedGlobal()

        let header = makeDurableHeader(folder: inbox, messageId: "m-odd-3x", isRead: false)
        try await pool.writeWithoutTransaction { db in try header.insert(db) }
        let id = header.id
        // Seed unreadCount=1 (one unread message) so the post-markRead
        // decrement is observable — the harness's Folder init defaults to 0,
        // and markRead's `MAX(0, unreadCount - newlyRead)` would otherwise
        // clamp at 0 either way (see AccountManagerActionsTests for the same
        // seeding pattern).
        try await pool.writeWithoutTransaction { db in
            try db.execute(sql: "UPDATE folder SET unreadCount = 1 WHERE id = ?", arguments: [inbox.id])
        }

        let vm = InboxViewModel(folders: [inbox])

        let (gateStream, gate) = AsyncStream<Void>.makeStream()
        await AccountManager.shared.enqueueWrite {
            var it = gateStream.makeAsyncIterator()
            _ = await it.next()
        }

        vm.toggleRead(id) // read
        vm.toggleRead(id) // unread
        vm.toggleRead(id) // read — net flip
        #expect(vm.loadedMessages.first?.isRead == true)

        // Let the cycle's executor Task actually append behind the gate.
        try await Task.sleep(for: .milliseconds(50))

        gate.finish()
        await drainWriteQueue()

        let finalIsRead = try await pool.read { db in try MessageHeader.fetchOne(db, key: id)?.isRead }
        #expect(finalIsRead == true, "net flip must land as read")

        let pendingOps = try await pool.read { db in try PendingOperation.fetchAll(db) }
        #expect(pendingOps.count == 1, "3 toggles coalescing to a net flip must produce exactly ONE PendingOperation")
        guard pendingOps.count == 1 else { return }
        #expect(pendingOps[0].type == .markRead)

        let unreadCountAfter = try await pool.read { db in try Folder.fetchOne(db, key: inbox.id)?.unreadCount }
        #expect(unreadCountAfter == 0, "exactly one message transitioned unread -> read")

        #expect(AccountManager.shared.snapshotOverlay()[id] == nil)
        #expect(AccountManager.shared.overlayOpRefCountForTesting()[id] == nil)
        #expect(AccountManager.shared.pendingIntentCyclesForTesting()[id] == nil)
    }

    @Test("a gesture registered after the previous cycle for the same id has fully drained starts a NEW, independent cycle — two round-trips land as two separate writes, no strand")
    func intentAfterCycleConsumedStartsNewCycle() async throws {
        let (pool, inbox, _, dir, previous) = try makeTestDB()
        defer {
            restoreTestDB(previous: previous, pool: pool, dir: dir)
            clearOverlay(); resetStagedGlobal()
        }
        clearOverlay(); resetStagedGlobal()

        let header = makeDurableHeader(folder: inbox, messageId: "m-new-cycle", isRead: false)
        try await pool.writeWithoutTransaction { db in try header.insert(db) }
        let id = header.id

        let vm = InboxViewModel(folders: [inbox])

        vm.toggleRead(id) // -> read
        // Let the cycle's executor Task actually append to the FIFO queue
        // before the drain barrier's own Task races it (mirrors the settle
        // pattern used across this suite).
        try await Task.sleep(for: .milliseconds(50))
        await drainWriteQueue()

        let afterFirst = try await pool.read { db in try MessageHeader.fetchOne(db, key: id)?.isRead }
        #expect(afterFirst == true)
        #expect(AccountManager.shared.pendingIntentCyclesForTesting()[id] == nil, "first cycle must be fully consumed before the next gesture")
        #expect(AccountManager.shared.overlayOpRefCountForTesting()[id] == nil)

        vm.toggleRead(id) // starts a FRESH cycle -> unread
        // Same settle: the second cycle's executor append must land before
        // the drain barrier.
        try await Task.sleep(for: .milliseconds(50))
        await drainWriteQueue()

        let afterSecond = try await pool.read { db in try MessageHeader.fetchOne(db, key: id)?.isRead }
        #expect(afterSecond == false, "the second gesture must start a NEW cycle and execute independently, not be swallowed by the already-consumed first cycle")
        #expect(AccountManager.shared.snapshotOverlay()[id] == nil)
        #expect(AccountManager.shared.overlayOpRefCountForTesting()[id] == nil)
        #expect(AccountManager.shared.pendingIntentCyclesForTesting()[id] == nil)

        let pendingOpsCount = try await pool.read { db in try PendingOperation.fetchCount(db) }
        #expect(pendingOpsCount == 2, "two independent (non-coalesced) cycles must each produce their own PendingOperation")
    }

    // MARK: - (k) applyManualTag coalescing

    @Test("applyManualTag: tagging Reply then Archive on the same id (gated) coalesces into ONE cycle (refcount 1) whose executed write lands the LATEST tag, not the first")
    func tagRetagCoalescesToLatestTag() async throws {
        let (pool, inbox, _, dir, previous) = try makeTestDB()
        defer {
            restoreTestDB(previous: previous, pool: pool, dir: dir)
            clearOverlay(); resetStagedGlobal()
        }
        clearOverlay(); resetStagedGlobal()

        let header = makeDurableHeader(folder: inbox, messageId: "m-tag-retag", isRead: false)
        try await pool.writeWithoutTransaction { db in try header.insert(db) }
        let id = header.id

        let vm = InboxViewModel(folders: [inbox])
        #expect(vm.loadedMessages.first?.actionTag == nil)

        let (gateStream, gate) = AsyncStream<Void>.makeStream()
        await AccountManager.shared.enqueueWrite {
            var it = gateStream.makeAsyncIterator()
            _ = await it.next()
        }

        vm.applyManualTag(id, tag: .reply)
        vm.applyManualTag(id, tag: .archive)
        #expect(vm.loadedMessages.first?.actionTag == .archive)
        #expect(AccountManager.shared.overlayOpRefCountForTesting()[id] == 1, "two re-tags on the same id coalesce into ONE cycle")

        // Let the cycle's executor Task actually append behind the gate.
        try await Task.sleep(for: .milliseconds(50))

        gate.finish()
        await drainWriteQueue()

        let finalTag = try await pool.read { db in try MessageHeader.fetchOne(db, key: id)?.actionTag }
        #expect(finalTag == .archive, "drain must land the LATEST tag, not the first")
        #expect(AccountManager.shared.snapshotOverlay()[id] == nil)
        #expect(AccountManager.shared.overlayOpRefCountForTesting()[id] == nil)
        #expect(AccountManager.shared.pendingIntentCyclesForTesting()[id] == nil)
    }

    @Test("applyManualTag: tagging Reply then back to nil (the original baseline) is a perfect cancel-out — DB tag unchanged, zero PendingOperations")
    func tagBackToBaselineIsNoOp() async throws {
        let (pool, inbox, _, dir, previous) = try makeTestDB()
        defer {
            restoreTestDB(previous: previous, pool: pool, dir: dir)
            clearOverlay(); resetStagedGlobal()
        }
        clearOverlay(); resetStagedGlobal()

        let header = makeDurableHeader(folder: inbox, messageId: "m-tag-cancel", isRead: false)
        try await pool.writeWithoutTransaction { db in try header.insert(db) }
        let id = header.id

        let vm = InboxViewModel(folders: [inbox])
        #expect(vm.loadedMessages.first?.actionTag == nil)

        let (gateStream, gate) = AsyncStream<Void>.makeStream()
        await AccountManager.shared.enqueueWrite {
            var it = gateStream.makeAsyncIterator()
            _ = await it.next()
        }

        vm.applyManualTag(id, tag: .reply)
        vm.applyManualTag(id, tag: nil) // back to the original baseline (no tag)
        #expect(vm.loadedMessages.first?.actionTag == nil)

        // Let the cycle's executor Task actually append behind the gate.
        try await Task.sleep(for: .milliseconds(50))

        gate.finish()
        await drainWriteQueue()

        let finalTag = try await pool.read { db in try MessageHeader.fetchOne(db, key: id)?.actionTag }
        #expect(finalTag == nil, "cancel-out must leave DB tag at baseline")

        let pendingOpsCount = try await pool.read { db in try PendingOperation.fetchCount(db) }
        #expect(pendingOpsCount == 0, "a perfect tag cancel-out must never call applyManualTag/queueTagWrite — zero PendingOperations")

        #expect(AccountManager.shared.snapshotOverlay()[id] == nil)
        #expect(AccountManager.shared.overlayOpRefCountForTesting()[id] == nil)
        #expect(AccountManager.shared.pendingIntentCyclesForTesting()[id] == nil)
    }

    // MARK: - (l) The §1 mixed-path bypass regression — toggle + move on the same id
    //
    // Before this round, `InboxViewModel.archive`/`move`/etc. called
    // `manager.removeOverlayEntries(ids:)` UNCONDITIONALLY on their own
    // completion — bypassing the gesture-toggle refcount entirely. If a
    // toggle (or, now, an intent cycle) was still in flight for the SAME id
    // when an archive/move's closure completed, the move's unconditional
    // removal stripped the WHOLE coalesced overlay entry, including the
    // sibling op's still-pending intent (PLAN_OVERLAY_CALLSITE_AUDIT.md §1
    // "mixed-path refcount bypass"). Both directions are pinned below: the
    // move finishing first must not strip a still-pending toggle intent, and
    // the toggle finishing first must not strip a still-pending move intent.

    @Test("mixed-path regression: a toggleRead intent-cycle queued BEFORE an archive (move) for the SAME id — the cycle's release does not strip the archive's still-pending folderId intent, and vice versa; final state reflects BOTH")
    func mixedToggleAndArchiveOnSameId() async throws {
        let (pool, inbox, archive, dir, previous) = try makeTestDB()
        defer {
            restoreTestDB(previous: previous, pool: pool, dir: dir)
            clearOverlay(); resetStagedGlobal()
        }
        clearOverlay(); resetStagedGlobal()

        let header = makeDurableHeader(folder: inbox, messageId: "m-mixed-toggle-archive", isRead: false)
        try await pool.writeWithoutTransaction { db in try header.insert(db) }
        let id = header.id

        let vm = InboxViewModel(folders: [inbox])
        #expect(vm.loadedMessages.first?.isRead == false)

        // gate0: blocks the FIFO write queue before either op.
        let (gate0Stream, gate0) = AsyncStream<Void>.makeStream()
        await AccountManager.shared.enqueueWrite {
            var it = gate0Stream.makeAsyncIterator()
            _ = await it.next()
        }

        // op1: toggleRead — opens an intent cycle (retain=1), queues the
        // cycle's executor closure behind gate0.
        vm.toggleRead(id)
        try await Task.sleep(for: .milliseconds(50)) // let the cycle's executor Task append

        // gate1: appended (direct await) strictly BEFORE archive is called,
        // so its FIFO position (after the cycle executor, before the move)
        // is deterministic.
        let (gate1Stream, gate1) = AsyncStream<Void>.makeStream()
        await AccountManager.shared.enqueueWrite {
            var it = gate1Stream.makeAsyncIterator()
            _ = await it.next()
        }

        // op2: archive — takes its OWN retain (refcount 2 total) and queues
        // the move closure behind gate1.
        vm.archive(id)
        try await Task.sleep(for: .milliseconds(100)) // let the move's closure append behind gate1

        #expect(AccountManager.shared.overlayOpRefCountForTesting()[id] == 2, "the intent cycle and the archive each hold their own retain")

        // Release gate0: the cycle executor runs (marks read), releasing ITS
        // retain (2 -> 1). gate1 still blocks the move.
        gate0.finish()
        try await Task.sleep(for: .milliseconds(150))

        #expect(AccountManager.shared.overlayOpRefCountForTesting()[id] == 1, "the cycle released its retain; the archive's retain is still outstanding")
        #expect(AccountManager.shared.snapshotOverlay()[id] != nil, "overlay entry must survive — the archive's retain is still outstanding")

        // THE regression check: reload mid-drain. Pre-fix, the archive's
        // direct `removeOverlayEntries` would have run on ITS OWN completion
        // regardless of the cycle — but here the CYCLE finished first and
        // released correctly (this fix doesn't change that side). The
        // reverse order (below) is where the historical bug shape bites.
        // Here we confirm the overlay still carries the archive's pending
        // folderId intent while the move is in flight, on top of the
        // already-landed read intent.
        await vm.reloadMessages()
        #expect(vm.loadedMessages.isEmpty, "the row must appear moved out of the inbox — the archive's folderId overlay intent is still registered")

        gate1.finish()
        await drainWriteQueue()

        let final = try await pool.read { db in try MessageHeader.fetchOne(db, key: id) }
        #expect(final?.folderId == archive.id, "final DB state must reflect the archive move")
        #expect(final?.isRead == true, "final DB state must reflect the read intent")
        #expect(AccountManager.shared.snapshotOverlay()[id] == nil)
        #expect(AccountManager.shared.overlayOpRefCountForTesting()[id] == nil)
        #expect(AccountManager.shared.pendingIntentCyclesForTesting()[id] == nil)
    }

    @Test("mixed-path regression, REVERSE order: an archive (move) queued BEFORE a toggleRead intent-cycle for the SAME id — once the move's closure completes and releases its retain, the STILL-QUEUED cycle's outstanding retain keeps the folderId overlay intent alive, so a reload keeps showing the row moved out (the §1 mixed-path bypass this round fixes)")
    func mixedArchiveAndToggleOnSameIdReverseOrder() async throws {
        let (pool, inbox, archive, dir, previous) = try makeTestDB()
        defer {
            restoreTestDB(previous: previous, pool: pool, dir: dir)
            clearOverlay(); resetStagedGlobal()
        }
        clearOverlay(); resetStagedGlobal()

        let header = makeDurableHeader(folder: inbox, messageId: "m-mixed-archive-toggle", isRead: false)
        try await pool.writeWithoutTransaction { db in try header.insert(db) }
        let id = header.id

        let vm = InboxViewModel(folders: [inbox])

        let (gate0Stream, gate0) = AsyncStream<Void>.makeStream()
        await AccountManager.shared.enqueueWrite {
            var it = gate0Stream.makeAsyncIterator()
            _ = await it.next()
        }

        // op1: archive — retain=1, queues the move closure behind gate0.
        vm.archive(id)
        try await Task.sleep(for: .milliseconds(50))

        let (gate1Stream, gate1) = AsyncStream<Void>.makeStream()
        await AccountManager.shared.enqueueWrite {
            var it = gate1Stream.makeAsyncIterator()
            _ = await it.next()
        }

        // op2: toggleRead — opens a NEW intent cycle for this id (retain=2
        // total; the archive's retain is a separate refcount slot), queues
        // the cycle executor behind gate1.
        vm.toggleRead(id)
        try await Task.sleep(for: .milliseconds(100))

        #expect(AccountManager.shared.overlayOpRefCountForTesting()[id] == 2, "the archive move and the toggle's intent cycle each hold their own retain")

        // Release gate0: the move runs (folderId -> archive), releasing ITS
        // retain (2 -> 1). gate1 still blocks the cycle executor.
        gate0.finish()
        try await Task.sleep(for: .milliseconds(150))

        #expect(AccountManager.shared.overlayOpRefCountForTesting()[id] == 1, "the move released its retain; the toggle cycle's retain is still outstanding")
        #expect(AccountManager.shared.snapshotOverlay()[id] != nil, "overlay entry must survive — the toggle cycle's retain is still outstanding")

        // THE regression check: reload mid-drain. Pre-fix (direct
        // `removeOverlayEntries` on the move's own completion — the §1
        // mixed-path bypass), the move completing would have wiped the WHOLE
        // coalesced entry even though the toggle's isRead intent was still
        // pending. Post-fix, the refcount (still 1, the cycle not yet
        // released) keeps the WHOLE entry — including the already-landed
        // folderId — alive.
        await vm.reloadMessages()
        #expect(vm.loadedMessages.isEmpty, "the row must still appear moved out of the inbox — the folderId intent must survive the move's own release because a sibling retain (the toggle cycle) is still outstanding")

        gate1.finish()
        await drainWriteQueue()

        let final = try await pool.read { db in try MessageHeader.fetchOne(db, key: id) }
        #expect(final?.folderId == archive.id)
        #expect(final?.isRead == true)
        #expect(AccountManager.shared.snapshotOverlay()[id] == nil)
        #expect(AccountManager.shared.overlayOpRefCountForTesting()[id] == nil)
        #expect(AccountManager.shared.pendingIntentCyclesForTesting()[id] == nil)
    }

    // MARK: - (m) UndoService holds its own overlay share

    @Test("UndoService.undo(): the restore intent's overlay retain survives independently — releasing only when the undo's own queued closure completes, not when the sibling op it's undoing (the archive) completes")
    func undoHoldsRetainUntilRestoreExecutes() async throws {
        let (pool, inbox, _, dir, previous) = try makeTestDB()
        defer {
            restoreTestDB(previous: previous, pool: pool, dir: dir)
            clearOverlay(); resetStagedGlobal()
            UndoService.shared.dismissAll()
        }
        clearOverlay(); resetStagedGlobal()
        UndoService.shared.dismissAll()

        let header = makeDurableHeader(folder: inbox, messageId: "m-undo-retain", isRead: false)
        try await pool.writeWithoutTransaction { db in try header.insert(db) }
        let id = header.id

        let vm = InboxViewModel(folders: [inbox])

        // Gate the write queue BEFORE the archive so its move closure stays
        // queued for the whole test.
        let (gateStream, gate) = AsyncStream<Void>.makeStream()
        await AccountManager.shared.enqueueWrite {
            var it = gateStream.makeAsyncIterator()
            _ = await it.next()
        }

        vm.archive(id)
        try await Task.sleep(for: .milliseconds(50))
        #expect(AccountManager.shared.overlayOpRefCountForTesting()[id] == 1, "archive holds its own retain")
        #expect(UndoService.shared.currentAction != nil)

        // Undo the still-queued archive: registers the RESTORE intent (back
        // to the original inbox folder) and takes its OWN retain — the
        // archive's move closure is still gated, unexecuted, still holding
        // ITS retain.
        await UndoService.shared.undo()
        #expect(AccountManager.shared.overlayOpRefCountForTesting()[id] == 2, "the undo's restore takes its own retain alongside the archive's still-outstanding one")
        #expect(AccountManager.shared.snapshotOverlay()[id]?.folderId == inbox.id, "the undo's registerMutation overwrites the coalesced entry's folderId back to the restore target")

        gate.finish()
        await drainWriteQueue()

        let final = try await pool.read { db in try MessageHeader.fetchOne(db, key: id) }
        #expect(final?.folderId == inbox.id, "undo must restore the message to its original folder")
        #expect(AccountManager.shared.snapshotOverlay()[id] == nil, "overlay entry stranded after full drain")
        #expect(AccountManager.shared.overlayOpRefCountForTesting()[id] == nil, "refcount entry stranded after full drain")
    }

    @Test("UndoService.undo(): the restore intent overwrites the archive gesture's overlay tag-clear — the restored chip is visible DURING the drain window, not only after every retain releases (follow-up audit round-1 finding)")
    func undoRestoresActionTagIntoOverlayWhileArchiveClearStillHeld() async throws {
        let (pool, inbox, _, dir, previous) = try makeTestDB()
        defer {
            restoreTestDB(previous: previous, pool: pool, dir: dir)
            clearOverlay(); resetStagedGlobal()
            UndoService.shared.dismissAll()
        }
        clearOverlay(); resetStagedGlobal()
        UndoService.shared.dismissAll()

        var header = makeDurableHeader(folder: inbox, messageId: "m-undo-tag", isRead: true)
        header.actionTag = ActionTag.reply
        try await pool.writeWithoutTransaction { [header] db in try header.insert(db) }
        let id = header.id

        let vm = InboxViewModel(folders: [inbox])

        // Gate the write queue BEFORE the archive so both the archive's move
        // closure and the undo's restore closure stay queued while we inspect
        // the overlay mid-window.
        let (gateStream, gate) = AsyncStream<Void>.makeStream()
        await AccountManager.shared.enqueueWrite {
            var it = gateStream.makeAsyncIterator()
            _ = await it.next()
        }

        vm.archive(id)
        try await Task.sleep(for: .milliseconds(50))
        #expect(AccountManager.shared.snapshotOverlay()[id]?.actionTag == ActionTag??.some(nil),
                "the inbox-leaving archive registers the overlay tag-clear")

        await UndoService.shared.undo()
        // The restore mutation must overwrite the coalesced entry's tag-clear
        // with the pre-move snapshot's tag — registerMutation only overwrites
        // fields the new mutation SETS, so undo has to set actionTag explicitly.
        #expect(AccountManager.shared.snapshotOverlay()[id]?.actionTag == ActionTag??.some(.reply),
                "undo restores the tag INTO the overlay for the drain window")

        gate.finish()
        await drainWriteQueue()

        let final = try await pool.read { db in try MessageHeader.fetchOne(db, key: id) }
        #expect(final?.folderId == inbox.id)
        #expect(final?.actionTag == ActionTag.reply, "DB truth: full-row restore brings the tag back")
        #expect(AccountManager.shared.snapshotOverlay()[id] == nil)
        #expect(AccountManager.shared.overlayOpRefCountForTesting()[id] == nil)
    }

    @Test("FIX 4: archive() queued right behind a STILL-QUEUED tag gesture (never drained) — undo must restore the gesture's tag, not the pre-gesture DB value. Before the fix, archive()'s undo snapshot came from a fresh lookupMessage DB read (predates the queued gesture), so undo silently reverted the user's most recent tap")
    func undoAfterArchiveRestoresStillQueuedTagGesture() async throws {
        let (pool, inbox, _, dir, previous) = try makeTestDB()
        defer {
            restoreTestDB(previous: previous, pool: pool, dir: dir)
            clearOverlay(); resetStagedGlobal()
            UndoService.shared.dismissAll()
        }
        clearOverlay(); resetStagedGlobal()
        UndoService.shared.dismissAll()

        // Durable row starts with NO tag. The tag is applied via the REAL
        // gesture path below and is STILL QUEUED (never drained to DB) when
        // the archive fires — distinct from a pre-existing durable tag.
        let header = makeDurableHeader(folder: inbox, messageId: "m-undo-queued-tag", isRead: true)
        try await pool.writeWithoutTransaction { db in try header.insert(db) }
        let id = header.id

        let vm = InboxViewModel(folders: [inbox])
        #expect(vm.loadedMessages.first?.actionTag == nil)

        // Gate the write queue BEFORE the tag gesture so both the tag
        // intent-cycle's executor and the archive's move closure stay queued
        // for the whole test.
        let (gateStream, gate) = AsyncStream<Void>.makeStream()
        await AccountManager.shared.enqueueWrite {
            var it = gateStream.makeAsyncIterator()
            _ = await it.next()
        }

        // Gesture #1: tag Reply — registers a NEW intent cycle (retain #1),
        // still queued behind the gate.
        vm.applyManualTag(id, tag: .reply)
        #expect(vm.loadedMessages.first?.actionTag == .reply)
        #expect(AccountManager.shared.snapshotOverlay()[id]?.actionTag == ActionTag??.some(.reply))

        // Let the tag cycle's executor Task actually enqueue behind the gate
        // before the archive fires, so ordering is deterministic.
        try await Task.sleep(for: .milliseconds(50))

        // Gesture #2: archive — while the tag gesture is STILL queued
        // (retain #2). Pre-fix, `archive(_:)`'s UndoableAction snapshot came
        // from `lookupMessage(messageId)` — a fresh DB read whose actionTag
        // is still nil (the tag gesture hasn't drained) — so undo would
        // restore nil, silently dropping the just-applied tag.
        vm.archive(id)
        try await Task.sleep(for: .milliseconds(50))
        #expect(AccountManager.shared.overlayOpRefCountForTesting()[id] == 2, "tag intent-cycle + archive each hold their own retain")

        await UndoService.shared.undo()
        #expect(AccountManager.shared.snapshotOverlay()[id]?.actionTag == ActionTag??.some(.reply),
                "undo's restore mutation must carry the STILL-QUEUED gesture's tag, not the pre-gesture DB value")

        gate.finish()
        await drainWriteQueue()

        let final = try await pool.read { db in try MessageHeader.fetchOne(db, key: id) }
        #expect(final?.folderId == inbox.id, "undo must restore the message to its original (inbox) folder")
        #expect(final?.actionTag == .reply, "DB truth: the still-queued tag gesture must survive the archive+undo cycle, not revert to the pre-gesture nil")
        #expect(AccountManager.shared.snapshotOverlay()[id] == nil, "overlay stranded after full drain")
        #expect(AccountManager.shared.overlayOpRefCountForTesting()[id] == nil, "refcount stranded after full drain")
        #expect(AccountManager.shared.pendingIntentCyclesForTesting()[id] == nil, "intent-cycle register stranded after full drain")
    }

    // MARK: - (n) Round-1 audit coverage gaps

    @Test("MessageDetailViewModel.toggleRead(): two gated calls round-trip back to baseline — a perfect cancel-out with zero PendingOperations, DB unchanged, and all registers empty")
    func detailToggleReadCancelOutIsZeroWrites() async throws {
        let (pool, inbox, _, dir, previous) = try makeTestDB()
        defer {
            restoreTestDB(previous: previous, pool: pool, dir: dir)
            clearOverlay(); resetStagedGlobal()
        }
        clearOverlay(); resetStagedGlobal()

        let header = makeDurableHeader(folder: inbox, messageId: "m-detail-cancel", isRead: false)
        try await pool.writeWithoutTransaction { db in try header.insert(db) }
        let id = header.id

        // Lightest detail-VM harness (MessageDetailViewModelMoveTests): the
        // test-only init is zero-I/O, so seed `message` directly instead of
        // driving the async loadBody resolve.
        let vm = MessageDetailViewModel(messageId: id, dbPool: pool, fetchBodyOverride: { _ in })
        vm._testSeedMessage(header)

        let (gateStream, gate) = AsyncStream<Void>.makeStream()
        await AccountManager.shared.enqueueWrite {
            var it = gateStream.makeAsyncIterator()
            _ = await it.next()
        }

        vm.toggleRead() // unread -> read
        vm.toggleRead() // read -> unread (back to baseline)
        #expect(vm.message?.isRead == false)
        #expect(AccountManager.shared.overlayOpRefCountForTesting()[id] == 1, "two toggles on the same id coalesce into ONE cycle")

        // Let the cycle's executor Task actually append behind the gate.
        try await Task.sleep(for: .milliseconds(50))

        gate.finish()
        await drainWriteQueue()

        let finalIsRead = try await pool.read { db in try MessageHeader.fetchOne(db, key: id)?.isRead }
        #expect(finalIsRead == false, "cancel-out must leave DB truth unchanged from baseline")

        let pendingOpsCount = try await pool.read { db in try PendingOperation.fetchCount(db) }
        #expect(pendingOpsCount == 0, "a perfect cancel-out must produce zero PendingOperations")

        #expect(AccountManager.shared.snapshotOverlay()[id] == nil)
        #expect(AccountManager.shared.overlayOpRefCountForTesting()[id] == nil)
        #expect(AccountManager.shared.pendingIntentCyclesForTesting()[id] == nil)
    }

    @Test("toggleRead (net flip) + toggleFlag×2 (cancel-out) + applyManualTag (local net change) on the same id, via InboxViewModel, all fold into ONE IntentCycle (refcount 1) — drain lands one provider write (isRead); flag stays untouched and tag stays local")
    func threeFieldsCoalesceInOneCycle() async throws {
        let (pool, inbox, _, dir, previous) = try makeTestDB()
        defer {
            restoreTestDB(previous: previous, pool: pool, dir: dir)
            clearOverlay(); resetStagedGlobal()
        }
        clearOverlay(); resetStagedGlobal()

        let header = makeDurableHeader(folder: inbox, messageId: "m-three-fields", isRead: false, isFlagged: false)
        try await pool.writeWithoutTransaction { db in try header.insert(db) }
        let id = header.id

        let vm = InboxViewModel(folders: [inbox])
        #expect(vm.loadedMessages.first?.actionTag == nil)

        let (gateStream, gate) = AsyncStream<Void>.makeStream()
        await AccountManager.shared.enqueueWrite {
            var it = gateStream.makeAsyncIterator()
            _ = await it.next()
        }

        vm.toggleRead(id)                  // isRead: false -> true (net flip)
        vm.toggleFlag(id)                  // isFlagged: false -> true
        vm.toggleFlag(id)                  // isFlagged: true -> false (cancel-out, back to baseline)
        vm.applyManualTag(id, tag: .reply) // actionTag: nil -> .reply (net change)

        #expect(vm.loadedMessages.first?.isRead == true)
        #expect(vm.loadedMessages.first?.isFlagged == false)
        #expect(vm.loadedMessages.first?.actionTag == .reply)
        #expect(AccountManager.shared.overlayOpRefCountForTesting()[id] == 1, "all four gestures on the same id fold into ONE cycle")

        // Let the cycle's executor Task actually append behind the gate.
        try await Task.sleep(for: .milliseconds(50))

        gate.finish()
        await drainWriteQueue()

        let finalHeader = try await pool.read { db in try MessageHeader.fetchOne(db, key: id) }
        #expect(finalHeader?.isRead == true, "net isRead flip must land")
        #expect(finalHeader?.isFlagged == false, "flag round-tripped back to baseline — must be unchanged")
        #expect(finalHeader?.actionTag == .reply, "net tag change must land")

        let pendingOps = try await pool.read { db in try PendingOperation.fetchAll(db) }
        let opTypes = Set(pendingOps.map(\.type))
        #expect(!opTypes.contains(.markFlagged), "a perfect flag cancel-out must never write markFlagged")
        #expect(!opTypes.contains(.markUnflagged), "a perfect flag cancel-out must never write markUnflagged")
        #expect(opTypes.contains(.markRead), "the net isRead flip must produce a markRead op")
        #expect(!opTypes.contains(.setTag), "manual tags are local-only and must not create a provider op")
        #expect(pendingOps.count == 1, "only the provider-backed isRead change must enqueue; tag stays local and flag cancelled out")

        #expect(AccountManager.shared.snapshotOverlay()[id] == nil)
        #expect(AccountManager.shared.overlayOpRefCountForTesting()[id] == nil)
        #expect(AccountManager.shared.pendingIntentCyclesForTesting()[id] == nil)
    }

    // Deviation from the spec's literal gate-INSIDE-the-write-path ask: there
    // is no production seam that pauses `executeIntentCycle` between
    // consuming the cycle and its markRead/markUnread/markFlagged/
    // applyManualTag calls, and the write itself is a fast in-actor async DB
    // write with no natural pause point — gating it would mean adding a
    // test-only seam to production code purely for this test, out of scope
    // for this fix batch. Driven instead via the spec's own documented
    // fallback: a fully-drained first cycle, then a second cycle registered
    // strictly afterward. Every `drainWriteQueue()` call is a FIFO barrier,
    // so this is fully deterministic — no sleep-based race.
    @Test("a gesture cycle registered strictly after a prior cycle for the same id has fully drained starts a SECOND, independent cycle whose own write is semantically necessary — final DB state matches the LAST registered intent and every register drains to empty (ADR-IOS-057 accepted residual)")
    func sequentialCyclesEachExecuteIndependently() async throws {
        let (pool, inbox, _, dir, previous) = try makeTestDB()
        defer {
            restoreTestDB(previous: previous, pool: pool, dir: dir)
            clearOverlay(); resetStagedGlobal()
        }
        clearOverlay(); resetStagedGlobal()

        let header = makeDurableHeader(folder: inbox, messageId: "m-tap-during-write", isRead: false)
        try await pool.writeWithoutTransaction { db in try header.insert(db) }
        let id = header.id

        let vm = InboxViewModel(folders: [inbox])

        // Cycle 1: a single toggle, fully drained before cycle 2 starts.
        vm.toggleRead(id) // -> read
        await drainWriteQueue()
        let afterFirst = try await pool.read { db in try MessageHeader.fetchOne(db, key: id)?.isRead }
        #expect(afterFirst == true)
        #expect(AccountManager.shared.pendingIntentCyclesForTesting()[id] == nil, "cycle 1 must be fully consumed before cycle 2 starts")
        #expect(AccountManager.shared.overlayOpRefCountForTesting()[id] == nil)

        // Cycle 2: registered strictly after cycle 1's write has landed and
        // released. Three rapid toggles (odd count) net to a genuine flip —
        // this cycle's write is semantically necessary, not a cancel-out.
        vm.toggleRead(id) // -> unread
        vm.toggleRead(id) // -> read
        vm.toggleRead(id) // -> unread (net flip from cycle 1's landed "read")
        await drainWriteQueue()

        let afterSecond = try await pool.read { db in try MessageHeader.fetchOne(db, key: id)?.isRead }
        #expect(afterSecond == false, "final DB state must match cycle 2's LAST registered intent, not cycle 1's landed state")
        #expect(AccountManager.shared.snapshotOverlay()[id] == nil)
        #expect(AccountManager.shared.overlayOpRefCountForTesting()[id] == nil)
        #expect(AccountManager.shared.pendingIntentCyclesForTesting()[id] == nil)

        let pendingOpsCount = try await pool.read { db in try PendingOperation.fetchCount(db) }
        #expect(pendingOpsCount == 2, "two independent cycles must each produce their own PendingOperation")
    }

    @Test("archiveThread with 2 members: each member id holds its OWN single retain while the move is gated; after drain both retains release independently and both rows land in the archive folder")
    func threadBatchRetainsPerMemberAndReleasesPerMember() async throws {
        let (pool, inbox, archive, dir, previous) = try makeTestDB()
        defer {
            restoreTestDB(previous: previous, pool: pool, dir: dir)
            clearOverlay(); resetStagedGlobal()
        }
        clearOverlay(); resetStagedGlobal()

        let header1 = makeDurableHeader(folder: inbox, messageId: "m-thread-batch-1", isRead: false)
        let header2 = makeDurableHeader(folder: inbox, messageId: "m-thread-batch-2", isRead: false)
        try await pool.writeWithoutTransaction { db in
            try header1.insert(db)
            try header2.insert(db)
        }
        let id1 = header1.id
        let id2 = header2.id

        let vm = InboxViewModel(folders: [inbox])

        let (gateStream, gate) = AsyncStream<Void>.makeStream()
        await AccountManager.shared.enqueueWrite {
            var it = gateStream.makeAsyncIterator()
            _ = await it.next()
        }

        vm.archiveThread([id1, id2])
        try await Task.sleep(for: .milliseconds(50)) // let the move closure append behind the gate

        #expect(AccountManager.shared.overlayOpRefCountForTesting()[id1] == 1, "each thread member holds its own single retain")
        #expect(AccountManager.shared.overlayOpRefCountForTesting()[id2] == 1, "each thread member holds its own single retain")

        gate.finish()
        await drainWriteQueue()

        let final1 = try await pool.read { db in try MessageHeader.fetchOne(db, key: id1) }
        let final2 = try await pool.read { db in try MessageHeader.fetchOne(db, key: id2) }
        #expect(final1?.folderId == archive.id, "member 1 must have moved to the archive folder")
        #expect(final2?.folderId == archive.id, "member 2 must have moved to the archive folder")

        #expect(AccountManager.shared.snapshotOverlay()[id1] == nil)
        #expect(AccountManager.shared.snapshotOverlay()[id2] == nil)
        #expect(AccountManager.shared.overlayOpRefCountForTesting()[id1] == nil, "member 1's retain must release independently")
        #expect(AccountManager.shared.overlayOpRefCountForTesting()[id2] == nil, "member 2's retain must release independently")
    }

    @Test("UndoService.undo() on a 2-message UndoableAction: the restore intent retains its OWN share per member id alongside the still-outstanding archiveThread retain; both fully release after drain and both rows restore to the original folder")
    func undoMultiMessageReleasesAllRetains() async throws {
        let (pool, inbox, _, dir, previous) = try makeTestDB()
        defer {
            restoreTestDB(previous: previous, pool: pool, dir: dir)
            clearOverlay(); resetStagedGlobal()
            UndoService.shared.dismissAll()
        }
        clearOverlay(); resetStagedGlobal()
        UndoService.shared.dismissAll()

        let header1 = makeDurableHeader(folder: inbox, messageId: "m-undo-multi-1", isRead: false)
        let header2 = makeDurableHeader(folder: inbox, messageId: "m-undo-multi-2", isRead: false)
        try await pool.writeWithoutTransaction { db in
            try header1.insert(db)
            try header2.insert(db)
        }
        let id1 = header1.id
        let id2 = header2.id

        let vm = InboxViewModel(folders: [inbox])

        // Gate the write queue BEFORE the archiveThread so its move closure
        // stays queued for the whole test.
        let (gateStream, gate) = AsyncStream<Void>.makeStream()
        await AccountManager.shared.enqueueWrite {
            var it = gateStream.makeAsyncIterator()
            _ = await it.next()
        }

        vm.archiveThread([id1, id2])
        try await Task.sleep(for: .milliseconds(50))
        #expect(AccountManager.shared.overlayOpRefCountForTesting()[id1] == 1, "archiveThread holds its own retain per member")
        #expect(AccountManager.shared.overlayOpRefCountForTesting()[id2] == 1, "archiveThread holds its own retain per member")
        #expect(UndoService.shared.currentAction != nil)

        // Undo the still-queued archiveThread: registers the RESTORE intent
        // for BOTH members and takes its OWN retain per member — the
        // archiveThread's move closure is still gated, unexecuted, still
        // holding ITS retain.
        await UndoService.shared.undo()
        #expect(AccountManager.shared.overlayOpRefCountForTesting()[id1] == 2, "the undo's restore takes its own retain per member alongside archiveThread's still-outstanding one")
        #expect(AccountManager.shared.overlayOpRefCountForTesting()[id2] == 2, "the undo's restore takes its own retain per member alongside archiveThread's still-outstanding one")

        gate.finish()
        await drainWriteQueue()

        let final1 = try await pool.read { db in try MessageHeader.fetchOne(db, key: id1) }
        let final2 = try await pool.read { db in try MessageHeader.fetchOne(db, key: id2) }
        #expect(final1?.folderId == inbox.id, "undo must restore member 1 to its original folder")
        #expect(final2?.folderId == inbox.id, "undo must restore member 2 to its original folder")
        #expect(AccountManager.shared.snapshotOverlay()[id1] == nil, "overlay entry stranded after full drain")
        #expect(AccountManager.shared.snapshotOverlay()[id2] == nil, "overlay entry stranded after full drain")
        #expect(AccountManager.shared.overlayOpRefCountForTesting()[id1] == nil, "refcount entry stranded after full drain")
        #expect(AccountManager.shared.overlayOpRefCountForTesting()[id2] == nil, "refcount entry stranded after full drain")
    }

    // MARK: - (o) Out-of-band local writer vs a cancelled-out cycle (round-3 audit)

    @Test("markAllAsRead queued BEFORE a same-id toggle burst must not swallow the burst's net intent: the cycle executor compares its target against the row's CURRENT truth (which markAllAsRead flipped mid-cycle) and re-asserts the user's latest visualized state")
    func markAllAsReadBeforeToggleBurstDoesNotSwallowLatestIntent() async throws {
        let (pool, inbox, _, dir, previous) = try makeTestDB()
        defer {
            restoreTestDB(previous: previous, pool: pool, dir: dir)
            clearOverlay(); resetStagedGlobal()
        }
        clearOverlay(); resetStagedGlobal()

        let header = makeDurableHeader(folder: inbox, messageId: "m-markall-vs-cycle", isRead: false)
        try await pool.writeWithoutTransaction { db in try header.insert(db) }
        let id = header.id

        let vm = InboxViewModel(folders: [inbox])
        #expect(vm.loadedMessages.first?.isRead == false)

        // gate0: blocks the FIFO write queue before anything.
        let (gate0Stream, gate0) = AsyncStream<Void>.makeStream()
        await AccountManager.shared.enqueueWrite {
            var it = gate0Stream.makeAsyncIterator()
            _ = await it.next()
        }

        // markAllAsRead first: its batch closure (which writes isRead=true to
        // every unread row, BYPASSING the intent register and the overlay)
        // queues behind gate0.
        vm.markAllAsRead()
        try await Task.sleep(for: .milliseconds(50)) // let its closure append

        // Then a same-id toggle burst: read, then back to unread. The net
        // intent (unread — the user's LATEST visualized state) equals the
        // cycle's gesture-time baseline, so a baseline-compared skip would
        // treat it as a pure cancel-out and write NOTHING — letting
        // markAllAsRead's earlier batch write win over gestures that
        // postdate it (the round-3 regression). The header-truth comparison
        // sees target(false) != row(true, post-batch) and re-asserts unread.
        vm.toggleRead(id) // -> read
        vm.toggleRead(id) // -> unread (net intent; joins the same cycle)
        try await Task.sleep(for: .milliseconds(50)) // let the executor append behind the batch
        #expect(vm.loadedMessages.first?.isRead == false, "visualized state after the burst is unread")

        gate0.finish()
        await drainWriteQueue()

        let finalIsRead = try await pool.read { db in try MessageHeader.fetchOne(db, key: id)?.isRead }
        #expect(finalIsRead == false, "the toggle burst postdates markAllAsRead — its net intent (unread) must win; a baseline-compared cancel-out would leave the row read")

        // Both writes really happened: markAllAsRead's markRead op AND the
        // executor's corrective markUnread op.
        let opTypes = try await pool.read { db in try PendingOperation.fetchAll(db).map(\.type) }
        #expect(opTypes.contains(.markRead), "markAllAsRead's batch write must have landed first")
        #expect(opTypes.contains(.markUnread), "the cycle executor must re-assert the net intent against the batch write")

        #expect(AccountManager.shared.snapshotOverlay()[id] == nil)
        #expect(AccountManager.shared.overlayOpRefCountForTesting()[id] == nil)
        #expect(AccountManager.shared.pendingIntentCyclesForTesting()[id] == nil)
    }

    // MARK: - (p) Tag-only cycle on a staged-only row (round-2 audit)

    @Test("applyManualTag on a staged-only row completes gracefully — optimistic tag survives on screen, zero strand (strand-hygiene pin: the test host's merge no-op means this CANNOT distinguish ensureDurable-present from absent; the silent-tag-loss fix is guarded by code review + ADR-IOS-057, not by this test)")
    func tagOnStagedOnlyRowRunsEnsureDurableAndReleasesGracefully() async throws {
        let (pool, inbox, _, dir, previous) = try makeTestDB()
        defer {
            restoreTestDB(previous: previous, pool: pool, dir: dir)
            clearOverlay(); resetStagedGlobal()
        }
        clearOverlay(); resetStagedGlobal()

        let vm = InboxViewModel(folders: [inbox])
        let row = makeStagedRow(messageId: "m-staged-tag")
        NSEDataBridge.latestStagedRows.withLock { $0 = [row] }
        vm.insertStagedRows([row])
        #expect(vm.loadedMessages.count == 1)
        let id = MessageIdentity.headerId(accountId: "acc1", folderPath: "INBOX", messageId: "m-staged-tag")
        #expect(vm.loadedMessages.first?.actionTag == nil)

        // Gesture: tag a row that is not durable anywhere yet. Pre-round-2,
        // AccountManager.applyManualTag never called ensureDurable, so its
        // fetchOne-guarded Step-1 write silently no-op'd for staged rows and
        // the tag vanished with no error/retry. Post-fix the executor path
        // forces ensureDurable first. HONESTY NOTE (round-3 audit): in the
        // test host the NSE merge no-ops (no app-group container), so this
        // test passes with OR without the ensureDurable call — it pins only
        // the graceful no-crash/no-strand contract for the tag-on-staged-row
        // path (same achievable contract as
        // toggleReadOnStagedOnlyRowFlipsInstantlyAndResolvesGracefully); the
        // durability fix itself is not observable from a unit test host.
        vm.applyManualTag(id, tag: .reply)
        #expect(vm.loadedMessages.first?.actionTag == .reply, "optimistic tag flip happens regardless of durability")
        try await Task.sleep(for: .milliseconds(50)) // let the cycle's executor Task append
        await drainWriteQueue()

        // Achievable contract in the test host (merge cannot durabilize):
        // the cycle never strands, crashes, or hangs — refcount, register,
        // and overlay all fully drain.
        #expect(AccountManager.shared.snapshotOverlay()[id] == nil, "overlay entry stranded after staged-row tag cycle")
        #expect(AccountManager.shared.overlayOpRefCountForTesting()[id] == nil, "refcount entry stranded after staged-row tag cycle")
        #expect(AccountManager.shared.pendingIntentCyclesForTesting()[id] == nil, "intent cycle stranded after staged-row tag cycle")
    }

    // MARK: - (q) Tag-vs-move closure-reorder race (FIX B)
    //
    // Audit round 2: a tag gesture opens an intent cycle; an archive
    // gesture's move closure can end up AHEAD of the cycle executor in the
    // FIFO (both enqueue via unstructured Tasks — no ordering guarantee
    // between them). The move clears actionTag and moves the row out of the
    // inbox; the tag executor then resolves the header, sees
    // `target != header.actionTag`, and (pre-fix) re-applied the tag to the
    // now-archived row — a stale chip in Archive/Trash lists. Fix:
    // `executeIntentCycle`'s actionTag branch now guards on the RESOLVED
    // header's `isInInbox` and skips the write when the row has already left
    // the inbox by execution time.

    @Test("executeIntentCycle: a tag intent whose RESOLVED header has already left the inbox (simulating a move closure that ran ahead of the tag executor in the FIFO) does NOT reinstate the tag — no .setTag PendingOperation, actionTag stays nil, and the overlay/refcount/intent registers all drain to empty")
    func tagIntentSkipsReinstateWhenRowLeftInboxBeforeExecution() async throws {
        let (pool, inbox, archive, dir, previous) = try makeTestDB()
        defer {
            restoreTestDB(previous: previous, pool: pool, dir: dir)
            clearOverlay(); resetStagedGlobal()
        }
        clearOverlay(); resetStagedGlobal()

        let header = makeDurableHeader(folder: inbox, messageId: "m-tag-move-race", isRead: false)
        try await pool.writeWithoutTransaction { db in try header.insert(db) }
        let id = header.id

        // Gate the FIFO write queue BEFORE registering the tag intent so its
        // executor closure cannot run until we've simulated the reordered
        // move below.
        let (gateStream, gate) = AsyncStream<Void>.makeStream()
        await AccountManager.shared.enqueueWrite {
            var it = gateStream.makeAsyncIterator()
            _ = await it.next()
        }

        // Tag gesture: opens an intent cycle for id (retain #1), queues its
        // executor closure onto the FIFO write queue behind the gate.
        AccountManager.shared.registerGestureIntent(id: id, .actionTag(target: .reply, baseline: nil))
        // Settle: let the cycle's Task actually append its closure to the
        // queue before the simulated-move write below (mirrors the settle
        // pattern used across this suite).
        try await Task.sleep(for: .milliseconds(50))
        #expect(AccountManager.shared.overlayOpRefCountForTesting()[id] == 1, "the tag intent cycle holds its own retain")

        // Simulate the archive gesture's move closure having ALREADY RUN
        // ahead of the tag executor in the FIFO: directly update the row in
        // DB to the post-move state (folderId/folderPath -> Archive,
        // isInInbox -> false, actionTag cleared by F6, tagSortOrder reset to
        // the sweepStaleActionTags sentinel) — bypassing the overlay/queue
        // machinery entirely, since only the RESOLVED DB row is what
        // `executeIntentCycle` consults for the isInInbox guard.
        try await pool.writeWithoutTransaction { db in
            try db.execute(sql: """
                UPDATE messageHeader
                SET folderId = ?, folderPath = ?, isInInbox = ?, actionTag = NULL, tagSortOrder = 99
                WHERE id = ?
                """, arguments: [archive.id, archive.path, false, id])
        }

        // Release the gate: the tag executor now resolves the header (which
        // shows isInInbox == false, actionTag == nil) and must skip the
        // reinstate rather than writing target (.reply) over the cleared tag.
        gate.finish()
        await drainWriteQueue()
        // Settle: the executor's release/log side effects are synchronous
        // within its closure, but give any trailing unstructured Task a beat
        // before asserting (mirrors this suite's drain+settle convention).
        try await Task.sleep(for: .milliseconds(50))

        let final = try await pool.read { db in try MessageHeader.fetchOne(db, key: id) }
        #expect(final?.actionTag == nil, "the tag must NOT be reinstated on a row that left the inbox")
        #expect(final?.folderId == archive.id, "the simulated move's folder must be untouched by the tag executor")

        let pendingOps = try await pool.read { db in try PendingOperation.fetchAll(db) }
        #expect(!pendingOps.contains { $0.type == .setTag }, "no .setTag PendingOperation may be queued for a row that already left the inbox")

        #expect(AccountManager.shared.snapshotOverlay()[id] == nil, "overlay entry stranded after the skipped-tag cycle")
        #expect(AccountManager.shared.overlayOpRefCountForTesting()[id] == nil, "refcount entry stranded after the skipped-tag cycle")
        #expect(AccountManager.shared.pendingIntentCyclesForTesting()[id] == nil, "intent cycle stranded after the skipped-tag cycle")
    }

    // MARK: - (q) T4.V20-A — markAllAsRead must TERMINATE

    /// An IMAP account whose folder epoch is UNKNOWN
    /// (`lastKnownUidValidity == nil`, i.e. its first sync has not completed).
    ///
    /// That is the cheapest *production-reachable* way to make
    /// `AccountManager.admittedOrdinaryActionTargets` refuse a whole
    /// group: it bails at the folder guard, so `markRead` writes no row and
    /// queues no op and the page comes back still `isRead = 0`. The refusal is
    /// RETRYABLE, not authoritative (an unread epoch is an ABSENCE of evidence
    /// — see `roleMoveRejectDispositions`), and it persists for exactly as long
    /// as the condition holds, which is what turns "a page that did not land"
    /// into "the same page forever" for an uncursored loop.
    private func makeEpochlessIMAPFolder(pool: DatabasePool) throws -> Folder {
        var account = Account(emailAddress: "unsynced@example.com", displayName: "Unsynced", provider: .imap)
        account.id = "acc-epochless"
        let folder = Folder(name: "INBOX", path: "INBOX", role: .inbox, accountId: account.id)
        let accountToInsert = account
        let folderToInsert = folder
        try pool.writeWithoutTransaction { db in
            try accountToInsert.insert(db)
            try folderToInsert.insert(db)
        }
        return folder
    }

    @Test("T4.V20-A — markAllAsRead terminates when a page's durable write never lands: the keyset cursor retires each page whether or not markRead admitted it, so a folder whose admission is refused for as long as its epoch is unknown ends the sweep instead of re-reading the identical page forever and holding the FIFO write queue")
    func markAllAsReadTerminatesWhenABatchWriteNeverLands() async throws {
        let (pool, _, _, dir, previous) = try makeTestDB()
        defer {
            InboxViewModel.markAllAsReadWillAdmitBatchForTesting.withLock { $0 = nil }
            restoreTestDB(previous: previous, pool: pool, dir: dir)
            clearOverlay(); resetStagedGlobal()
        }
        clearOverlay(); resetStagedGlobal()
        InboxViewModel.markAllAsReadWillAdmitBatchForTesting.withLock { $0 = nil }

        let folder = try makeEpochlessIMAPFolder(pool: pool)
        let folderId = folder.id
        let header = makeDurableHeader(folder: folder, messageId: "1001", isRead: false)
        try await pool.writeWithoutTransaction { db in try header.insert(db) }
        let headerId = header.id

        // BOUNDED SAFETY VALVE — why this test cannot simply await the sweep.
        //
        // The livelock this pins is not slow, it is non-terminating, and it
        // holds `AccountManager`'s FIFO write queue while it spins. A test that
        // just awaited `drainWriteQueue()` would therefore hang the whole test
        // PROCESS (Swift Testing has no per-test timeout that can reclaim a
        // blocked serial queue), taking thousands of unrelated results with it.
        //
        // So the admission seam counts pages and, if the count ever exceeds a
        // small bound, reaches in from OUTSIDE the loop and clears the folder's
        // unread rows — which starves even the broken implementation and lets
        // the process finish. Whether the valve had to fire IS the assertion:
        // production has no such valve.
        let admissionBound = 8
        let admissions = Mutex(0)
        let valveFired = Mutex(false)
        let admissionHook: @Sendable ([MessageHeader]) async -> Void = { _ in
            let seen = admissions.withLock { (count: inout Int) -> Int in
                count += 1
                return count
            }
            guard seen > admissionBound else { return }
            valveFired.withLock { $0 = true }
            try? await AppDatabase.dbPool.write { db in
                try db.execute(
                    sql: "UPDATE messageHeader SET isRead = 1 WHERE folderId = ?",
                    arguments: [folderId])
            }
        }
        InboxViewModel.markAllAsReadWillAdmitBatchForTesting.withLock { $0 = admissionHook }

        let vm = InboxViewModel(folders: [folder])
        #expect(vm.loadedMessages.count == 1)

        vm.markAllAsRead()
        try await Task.sleep(for: .milliseconds(50)) // let its closure append to the FIFO
        await drainWriteQueue()

        // (1) TERMINATION. The sweep must run out of work on its own. The valve
        // firing means it did not — it kept handing the same page to a
        // `markRead` that admits nothing, which in production is an
        // unkillable loop holding every other durable write behind it.
        #expect(valveFired.withLock { $0 } == false, "markAllAsRead did not terminate on its own — the bounded safety valve had to starve it. That is the uncursored re-read-the-identical-page livelock, and in production nothing releases the valve: the FIFO write queue stays held forever")

        // (2) A REFUSED WRITE IS NOT AUTHORITATIVE. Retiring a page from the
        // sweep must never be equivalent to marking it read: the row stays
        // unread on disk (and therefore on screen, via the trailing recount +
        // reloadMessages), so the user can see it and act again.
        let finalIsRead = try await pool.read { db in try MessageHeader.fetchOne(db, key: headerId)?.isRead }
        #expect(finalIsRead == false, "the cursor advancing past a page that markRead refused must not be equivalent to marking it read — the refused row must stay unread and re-actionable")

        // (3) …and it must not fabricate a durable op for work that never landed.
        let ops = try await pool.read { db in try PendingOperation.fetchAll(db) }
        #expect(ops.isEmpty, "a refused admission queues nothing; the sweep must not invent a .markRead op for a page the admission rejected")
    }

    @Test("T4.V20-A — the all-succeeds sweep still marks EVERY unread message read, across multiple folders and multiple pages: the keyset cursor must retire the PAGE, never the folder and never the sweep")
    func markAllAsReadSweepsEveryUnreadAcrossFoldersAndPages() async throws {
        let (pool, firstInbox, _, dir, previous) = try makeTestDB()
        defer {
            InboxViewModel.markAllAsReadWillAdmitBatchForTesting.withLock { $0 = nil }
            restoreTestDB(previous: previous, pool: pool, dir: dir)
            clearOverlay(); resetStagedGlobal()
        }
        clearOverlay(); resetStagedGlobal()
        InboxViewModel.markAllAsReadWillAdmitBatchForTesting.withLock { $0 = nil }

        // TWO folders, and they must both be `.inbox`-role: the VM self-heals
        // `folders` from the DB for a `.unified(.inbox)` selection
        // (`resolveFoldersFromDB`), so a second folder of any other role would
        // simply be dropped before `markAllAsRead` ever saw it.
        //
        // The second account id sorts BELOW the first ON PURPOSE. Header ids are
        // `<accountId>:<folderPath>:<messageId>`, so every id in the second
        // folder is BINARY-less-than every id in the first. A cursor (or an
        // upper bound) hoisted out of the per-folder loop therefore excludes the
        // whole second folder — which is exactly the regression this asserts on.
        var secondAccount = Account(emailAddress: "second@example.com", displayName: "Second", provider: .gmail)
        secondAccount.id = "acc0"
        let secondInbox = Folder(name: "INBOX", path: "INBOX", role: .inbox, accountId: secondAccount.id)
        let accountToInsert = secondAccount
        let folderToInsert = secondInbox
        try await pool.writeWithoutTransaction { db in
            try accountToInsert.insert(db)
            try folderToInsert.insert(db)
        }

        // Sized off the production page size so both folders MUST paginate,
        // with a ragged final page in each (a whole-page-multiple count would
        // not distinguish "stopped on the empty page" from "stopped early").
        let pageSize = SyncConfig.inboxPageSize
        let firstCount = pageSize * 2 + 3
        let secondCount = pageSize + 7
        let expectedPages = 3 + 2

        let now = Date()
        var headers: [MessageHeader] = []
        for i in 0..<firstCount {
            headers.append(makeDurableHeader(
                folder: firstInbox, messageId: String(format: "i-%05d", i),
                date: now.addingTimeInterval(-Double(i) * 60), isRead: false))
        }
        for i in 0..<secondCount {
            headers.append(makeDurableHeader(
                folder: secondInbox, messageId: String(format: "j-%05d", i),
                date: now.addingTimeInterval(-Double(i) * 60), isRead: false))
        }
        let seeded = headers
        try await pool.writeWithoutTransaction { db in
            for header in seeded { try header.insert(db) }
        }

        // Same bounded valve as the termination test — a cursor that never
        // ADVANCES (rather than one that is absent) would spin here too, and no
        // completeness assertion is worth hanging the suite for.
        let pageBound = expectedPages * 3
        let pageSizes = Mutex<[Int]>([])
        let valveFired = Mutex(false)
        let firstId = firstInbox.id
        let secondId = secondInbox.id
        let admissionHook: @Sendable ([MessageHeader]) async -> Void = { batch in
            let seen = pageSizes.withLock { (sizes: inout [Int]) -> Int in
                sizes.append(batch.count)
                return sizes.count
            }
            guard seen > pageBound else { return }
            valveFired.withLock { $0 = true }
            try? await AppDatabase.dbPool.write { db in
                try db.execute(sql: "UPDATE messageHeader SET isRead = 1")
            }
        }
        InboxViewModel.markAllAsReadWillAdmitBatchForTesting.withLock { $0 = admissionHook }

        let vm = InboxViewModel(folders: [firstInbox, secondInbox])
        #expect(Set(vm.folders.map(\.id)) == [firstId, secondId], "fixture guard: the VM must actually be sweeping BOTH folders (self-heal resolves `.unified(.inbox)` from the DB)")

        vm.markAllAsRead()
        try await Task.sleep(for: .milliseconds(50)) // let its closure append to the FIFO
        await drainWriteQueue()

        #expect(valveFired.withLock { $0 } == false, "the sweep did not terminate on its own — a cursor that never advances livelocks exactly like no cursor at all")

        // COMPLETENESS is the invariant. The user asked for all of it.
        let unreadInFirst = try await pool.read { db in
            try MessageHeader.filter(Column("folderId") == firstId && Column("isRead") == false).fetchCount(db)
        }
        let unreadInSecond = try await pool.read { db in
            try MessageHeader.filter(Column("folderId") == secondId && Column("isRead") == false).fetchCount(db)
        }
        #expect(unreadInFirst == 0, "\(unreadInFirst) of \(firstCount) messages left unread in the first folder — a sweep that retires the FOLDER after its first page drops the tail of the user's mark-all")
        #expect(unreadInSecond == 0, "\(unreadInSecond) of \(secondCount) messages left unread in the second folder — each folder must start its own cursor and its own upper bound; hoisting either out of the folder loop excludes every id that sorts outside the first folder's range")

        // Coverage guard: the two-sidedness above is only meaningful if the
        // sweep really paginated. It also pins that no page is admitted twice.
        let pages = pageSizes.withLock { $0 }
        #expect(pages.count == expectedPages, "expected \(expectedPages) pages at page size \(pageSize) for \(firstCount)+\(secondCount) unread, saw \(pages) — if this is 1 the test is vacuous, if it is larger a page was re-read")
        #expect(pages.reduce(0, +) == firstCount + secondCount, "every unread row must be admitted exactly once across the sweep, saw \(pages.reduce(0, +)) admissions for \(firstCount + secondCount) rows")
    }

    // MARK: - (h) T4.D10 — a Drafts swipe-delete addresses the tapped draft, or nothing
    //
    // THE INVARIANT (the system end state, not the guard's spelling): a Drafts
    // swipe-delete either removes the draft the user tapped — at the provider,
    // by that row's OWN provider-issued address — or it removes nothing anywhere
    // and reports the gesture unacted so the row un-hides and stays retryable.
    // There is no third outcome, and in particular no outcome in which a LOCAL
    // identifier is handed to the provider as if it were a provider address.
    //
    // 🚨 THE DEFECT THESE PIN. `deleteDraftMessage`'s header-only arm built its
    // provider identity straight from `message.messageId`. That field holds a
    // synthetic `draft-<id>:<epoch>:<len>` placeholder for any Drafts row minted
    // by `AccountManager.queueDraftSave` before the server assigned an id, and a
    // stale one survives indefinitely: `queueDraftSave` keys the placeholder on
    // the draft's CURRENT `instanceEpoch` and never removes the previous
    // generation's row, so the placeholder-ownership census above resolves
    // nothing and the gesture falls through to the header-only arm. Gmail then
    // received `POST /messages/draft-…/trash`, answered 404, and
    // `trashContainedDraftMessage` reads 404 as idempotent success — so the op
    // RETIRED, the local header was already deleted at queue time, and the real
    // server draft (addressed by `Draft.serverDraftId`, which that arm never
    // consulted) survived and re-synced. A destructive gesture reported as done
    // that never touched its target.
    //
    // Reference: `v2final:TabMail/Views/Compose/ComposeView.swift`
    // `ServerDraftOpen.inboxDraftDeletePlan(...)`, whose FIRST branch is exactly
    // this refusal (and whose Outlook branch admits only
    // `exactProviderIdentifier`, which rejects the same ids).

    /// A Drafts-folder header for `acc1`, shaped like the rows the Drafts list
    /// actually renders (read, not in the inbox, query-visible).
    private func makeDraftsHeader(messageId: String) -> MessageHeader {
        var h = MessageHeader(
            messageId: messageId, subject: "Quarterly notes", from: "Test",
            fromAddress: "test@example.com", to: "recipient@example.com",
            date: Date(), snippet: "snip",
            folderId: "acc1:Drafts", accountId: "acc1", folderPath: "Drafts",
            isInInbox: false
        )
        h.headerComplete = true
        h.isRead = true
        return h
    }

    /// A local draft row already pushed to Gmail, so its only provider address
    /// is the RESOURCE id it carries.
    private func makePushedGmailDraft(id: String, epoch: String, resourceId: String) -> Draft {
        let now = Date().timeIntervalSince1970
        var draft = Draft(
            id: id, accountId: "acc1",
            toJSON: "[\"recipient@example.com\"]", ccJSON: "[]", bccJSON: "[]",
            subject: "Quarterly notes", body: "Body the user authored.",
            replyToId: nil, isForward: false, editHistoryJSON: nil,
            createdAt: now, updatedAt: now,
            serverDraftId: resourceId, serverPushStatus: "pushed",
            rfc822MessageId: nil, attachmentsDirName: nil
        )
        draft.instanceEpoch = epoch
        return draft
    }

    @Test("A stale-generation Drafts placeholder is never handed to Gmail as a delete address — nothing is deleted anywhere and the gesture stays retryable")
    @MainActor
    func staleGenerationDraftsPlaceholderDeletesNothingAndStaysRetryable() async throws {
        let (pool, inbox, _, dir, previous) = try makeTestDB()
        defer {
            restoreTestDB(previous: previous, pool: pool, dir: dir)
            clearOverlay(); resetStagedGlobal()
        }
        clearOverlay(); resetStagedGlobal()

        // A FakeHTTP-backed Gmail provider: `draftRuntimeIdentityKind` is a
        // CONCRETE-TYPE check, so the real class is required — and the scoped
        // session is what guarantees no request can escape to the live endpoint.
        let http = FakeHTTP.Scenario()
        // 🚨 NO `defer { http.close() }`, and this is not an oversight —
        // `IOS-TEST-009`. `InboxViewModel.delete` reaches
        // `AccountManager.queueDraftDelete`, which ends with an
        // UNSTRUCTURED `Task { await drainPendingQueue() }` that outlives this
        // test body BY DESIGN (a user gesture must not block on its wire
        // drain). Invalidating this session while that drain is in flight makes
        // its next request raise the Objective-C `NSGenericException` 'Task
        // created in a session that has been invalidated' — uncatchable in
        // Swift, so `libc++abi` terminates the WHOLE test process, every test
        // not yet run in that launch is silently dropped, and xcodebuild blames
        // whichever test was next rather than this one. The scope below closes
        // the scenario only after that drain has settled, and does so while the
        // provider is still registered, which is the order the drain needs to
        // claim its operation at all. See `EscapedDrainTransport`.
        let gmail = GmailProvider(
            userEmail: "test@example.com", accessToken: { _ in "tok" }, session: http.session)
        try await EscapedDrainTransport.withProviderAndTransport(
            accountId: "acc1", provider: gmail, transport: http, pool: pool
        ) {

            let drafts = Folder(name: "Drafts", path: "Drafts", role: .drafts, accountId: "acc1")
            try await pool.writeWithoutTransaction { db in let d = drafts; try d.insert(db) }

            let draftId = Draft.draftKey(
                replyTo: nil, isForward: false, newId: "t4d10-stale-\(UUID().uuidString)")
            let liveEpoch = "E-live-\(UUID().uuidString)"
            let staleEpoch = "E-stale-\(UUID().uuidString)"
            let resourceId = "r-gmail-resource-1"
            let draft = makePushedGmailDraft(id: draftId, epoch: liveEpoch, resourceId: resourceId)
            try await pool.writeWithoutTransaction { db in let d = draft; try d.insert(db) }

            // The row still on screen is the placeholder minted under the PREVIOUS
            // compose generation — the one `queueDraftSave` leaves behind. Built
            // through the production helper so the fixture cannot drift from the id
            // shape production actually mints.
            let stalePlaceholderId = PendingOperation.draftPlaceholderMessageId(
                draftId: draftId, instanceEpoch: staleEpoch)
            let header = makeDraftsHeader(messageId: stalePlaceholderId)
            try await pool.writeWithoutTransaction { db in let h = header; try h.insert(db) }
            let headerId = header.id

            // Fixture guard: this scenario is only meaningful if the placeholder
            // census really misses, i.e. the row's id is NOT the live generation's.
            #expect(
                stalePlaceholderId != PendingOperation.draftPlaceholderMessageId(
                    draftId: draftId, instanceEpoch: liveEpoch),
                "fixture is vacuous — the on-screen placeholder matches the draft's live generation, so the owned-draft arm would handle it and the header-only arm is never reached")

            let vm = InboxViewModel(folders: [inbox])
            let acted = await vm.delete(headerId)

            // 1. The gesture is reported UNACTED, which is what makes the swipe
            //    un-hide the row (`InboxView`'s dismissed-id contract) and keeps the
            //    user's intention alive and repeatable.
            #expect(acted == false, "the swipe reported success for a draft it could not address — the row stays hidden while the server copy survives, and the user has no way to retry")

            // 2. Nothing was destroyed locally.
            let survivingHeader = try await pool.read { db in
                try MessageHeader.fetchOne(db, key: headerId)
            }
            #expect(survivingHeader != nil, "the tapped Drafts row was deleted locally even though no provider delete could be addressed — it vanishes from the list while the server copy re-syncs")
            let survivingDraft = try await pool.read { db in try Draft.fetchOne(db, key: draftId) }
            #expect(survivingDraft?.serverDraftId == resourceId, "the authored draft row and its Gmail resource address must be untouched by a refused delete")

            // 3. No durable destructive op was admitted at all — in particular none
            //    carrying the local placeholder as if it were a Gmail address.
            let allOps = try await pool.read { db in try PendingOperation.fetchAll(db) }
            let deleteOps = allOps.filter { $0.type == .deleteDraft }
            #expect(deleteOps.isEmpty, "a .deleteDraft op was admitted for an unaddressable row: \(deleteOps.map(\.messageIds))")

            // 4. Wire oracle: nothing naming the local placeholder reached Gmail.
            let placeholderTraffic = http.servedCallSequence().filter { $0.contains(stalePlaceholderId) }
            #expect(placeholderTraffic.isEmpty, "a local placeholder id was sent to Gmail as a provider address: \(placeholderTraffic)")
        }
    }

    @Test("A real Gmail Drafts row is queued for deletion under the tapped row's own byte-exact message id, not a same-account local draft's")
    @MainActor
    func realGmailDraftsRowIsDeletedByItsOwnProviderAddress() async throws {
        let (pool, inbox, _, dir, previous) = try makeTestDB()
        defer {
            restoreTestDB(previous: previous, pool: pool, dir: dir)
            clearOverlay(); resetStagedGlobal()
        }
        clearOverlay(); resetStagedGlobal()

        let http = FakeHTTP.Scenario()
        // 🚨 NO `defer { http.close() }` — see the sibling test above and
        // `EscapedDrainTransport`. THIS is the leg that actually starts the
        // escaped drain: it admits a `.deleteDraft` operation, so
        // `queueDraftDelete` fires its unstructured
        // `Task { await drainPendingQueue() }`, the drain reaches
        // `GmailProvider.deleteDraft` → `trashContainedDraftMessage` →
        // `performHTTPRequest` on THIS session, and closing the session first
        // kills the whole test process (`IOS-TEST-009`).
        let gmail = GmailProvider(
            userEmail: "test@example.com", accessToken: { _ in "tok" }, session: http.session)
        try await EscapedDrainTransport.withProviderAndTransport(
            accountId: "acc1", provider: gmail, transport: http, pool: pool
        ) {

            let drafts = Folder(name: "Drafts", path: "Drafts", role: .drafts, accountId: "acc1")
            try await pool.writeWithoutTransaction { db in let d = drafts; try d.insert(db) }

            // A DECOY: an unrelated local draft on the SAME account, carrying its own
            // Gmail resource id. Nothing about the tapped row may resolve to it.
            let decoyId = Draft.draftKey(
                replyTo: nil, isForward: false, newId: "t4d10-decoy-\(UUID().uuidString)")
            let decoy = makePushedGmailDraft(
                id: decoyId, epoch: "E-decoy-\(UUID().uuidString)", resourceId: "r-gmail-decoy")
            try await pool.writeWithoutTransaction { db in let d = decoy; try d.insert(db) }

            // The tapped row: a genuine Gmail Drafts header with a real, byte-exact
            // provider message id and no local Draft of its own.
            let tappedProviderId = "18f0c9d2e4b6a1c3"
            let header = makeDraftsHeader(messageId: tappedProviderId)
            try await pool.writeWithoutTransaction { db in let h = header; try h.insert(db) }
            let headerId = header.id

            let vm = InboxViewModel(folders: [inbox])
            let acted = await vm.delete(headerId)

            // NON-VACUITY: the addressable case must still delete. A "fix" that
            // refuses every header-only Drafts delete fails right here.
            #expect(acted == true, "an addressable Gmail Drafts row was refused — the fail-closed guard is over-refusing and the user can no longer delete drafts at all")

            let deletedHeader = try await pool.read { db in
                try MessageHeader.fetchOne(db, key: headerId)
            }
            #expect(deletedHeader == nil, "the tapped row is still on screen after an admitted delete")

            let allOps = try await pool.read { db in try PendingOperation.fetchAll(db) }
            let deleteOps = allOps.filter { $0.type == .deleteDraft }
            #expect(deleteOps.count == 1, "expected exactly one queued draft delete, got \(deleteOps.count)")
            guard deleteOps.count == 1 else { return }
            let op = deleteOps[0]
            // The address handed to Gmail is the TAPPED row's own id, byte for byte —
            // never the decoy's resource id, and never a normalized/trimmed variant.
            #expect(op.messageIds == [tappedProviderId], "the queued delete names \(op.messageIds) instead of the tapped row's own provider id")
            #expect(op.draftDeleteAddressKind == DraftDeleteAddressKind.gmailContainedMessage.rawValue, "a Drafts-folder header carries Gmail's contained MESSAGE id, never a draft RESOURCE id — mistyping the namespace sends it to the wrong Gmail route")
            #expect(op.accountId == "acc1")
            #expect(op.folderPath == "Drafts")

            // The decoy is untouched: sharing an account never donates authority.
            let survivingDecoy = try await pool.read { db in try Draft.fetchOne(db, key: decoyId) }
            #expect(survivingDecoy?.serverDraftId == "r-gmail-decoy", "an unrelated same-account draft was consumed by another row's delete")
        }
    }
}
