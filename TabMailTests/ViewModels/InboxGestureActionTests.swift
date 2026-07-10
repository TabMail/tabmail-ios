/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
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
@Suite("Inbox gesture actions — zero-DB, act-on-visualized-state (dead-toggle fix)", .serialized)
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
            AppDatabase.shared.withLock { $0 = previous }
            try? FileManager.default.removeItem(at: dir)
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
            AppDatabase.shared.withLock { $0 = previous }
            try? FileManager.default.removeItem(at: dir)
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
            AppDatabase.shared.withLock { $0 = previous }
            try? FileManager.default.removeItem(at: dir)
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
            AppDatabase.shared.withLock { $0 = previous }
            try? FileManager.default.removeItem(at: dir)
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

    @Test("toggleRead: after the queued write drains, DB truth matches the LAST toggle's target, not the first")
    func drainedDBStateMatchesLastToggleTarget() async throws {
        let (pool, inbox, _, dir, previous) = try makeTestDB()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            try? FileManager.default.removeItem(at: dir)
            clearOverlay(); resetStagedGlobal()
        }
        clearOverlay(); resetStagedGlobal()

        let header = makeDurableHeader(folder: inbox, messageId: "m-drain", isRead: false)
        try await pool.writeWithoutTransaction { db in try header.insert(db) }
        let id = header.id

        let vm = InboxViewModel(folders: [inbox])

        // Two toggles enqueue two writes: unread -> read -> unread.
        vm.toggleRead(id)
        vm.toggleRead(id)
        #expect(vm.loadedMessages.first?.isRead == false)

        await drainWriteQueue()

        let finalIsRead = try await pool.read { db in try MessageHeader.fetchOne(db, key: id)?.isRead }
        #expect(finalIsRead == false, "final DB state must match the LAST toggle's target (unread), not the first (read)")

        // The overlay entry must not strand once the write has drained.
        let overlay = AccountManager.shared.snapshotOverlay()
        #expect(overlay[id] == nil, "overlay entry stranded after drain — removeOverlayEntries did not run")
    }

    // MARK: - (f) Refcounted overlay release — the alternating-toggle regression
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
    // for in-flight-ness — a sibling op's drain ends the window early." Fixed
    // by refcounting (`AccountManager.retainOverlayEntry`/`releaseOverlayEntry`)
    // instead of removing on any single op's completion.

    @Test("toggleRead: a mid-drain reload after op1+op2 of three alternating toggles have completed still shows the FINAL intent, not the intermediate DB state op1/op2 left behind")
    func midDrainReloadShowsFinalIntentAcrossAlternatingToggles() async throws {
        let (pool, inbox, _, dir, previous) = try makeTestDB()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            try? FileManager.default.removeItem(at: dir)
            clearOverlay(); resetStagedGlobal()
        }
        clearOverlay(); resetStagedGlobal()

        let header = makeDurableHeader(folder: inbox, messageId: "m-alt-toggle", isRead: false)
        try await pool.writeWithoutTransaction { db in try header.insert(db) }
        let id = header.id

        let vm = InboxViewModel(folders: [inbox])
        #expect(vm.loadedMessages.first?.isRead == false)

        // gate0: blocks the FIFO write queue BEFORE any toggle — guaranteed
        // to be first in the queue (direct await, nothing else has enqueued
        // anything yet).
        let (gate0Stream, gate0) = AsyncStream<Void>.makeStream()
        await AccountManager.shared.enqueueWrite {
            var it = gate0Stream.makeAsyncIterator()
            _ = await it.next()
        }

        // op1, op2: unread -> read -> unread. `registerMutation`/
        // `retainOverlayEntry` both run SYNCHRONOUSLY inside `toggleRead`
        // (not deferred), so the overlay + refcount are already updated the
        // instant each call returns; only the actual DB write (inside the
        // queued closure) is deferred.
        vm.toggleRead(id) // op1 target: read
        vm.toggleRead(id) // op2 target: unread
        // Let op1/op2's closures (spawned via unstructured Tasks inside
        // toggleRead) actually append to the FIFO write queue — mirrors the
        // settle pattern MessageDetailStagedFallbackTests uses for cross-Task
        // ordering (unstructured Tasks racing a direct await).
        try await Task.sleep(for: .milliseconds(50))

        // gate1: appended via a DIRECT (non-Task-wrapped) await — STRICTLY
        // BEFORE op3 is spawned below, so its position in the FIFO queue
        // (after op1/op2, before op3) is deterministic rather than racing
        // op3's own unstructured-Task append.
        let (gate1Stream, gate1) = AsyncStream<Void>.makeStream()
        await AccountManager.shared.enqueueWrite {
            var it = gate1Stream.makeAsyncIterator()
            _ = await it.next()
        }

        // op3: unread -> read (the FINAL intent). Spawned AFTER gate1 is
        // already queued, so op3's closure can only land BEHIND gate1.
        vm.toggleRead(id)
        #expect(vm.loadedMessages.first?.isRead == true, "on-screen snapshot after 3 toggles must reflect the LAST toggle's target")
        #expect(AccountManager.shared.overlayOpRefCountForTesting()[id] == 3, "three queued ops on the same id must each hold their own retain")
        try await Task.sleep(for: .milliseconds(50)) // let op3's closure append behind gate1

        // Release gate0: op1 and op2 drain (their `releaseOverlayEntry` calls
        // bring the refcount 3 -> 1), then gate1 blocks the queue — op3 (the
        // LAST op, holding the final release) stays queued, NOT yet drained.
        gate0.finish()
        try await Task.sleep(for: .milliseconds(150))

        // op1 and op2 have both completed; op3 (the final op) is still in
        // flight — refcount must be exactly 1, overlay entry must still exist.
        #expect(AccountManager.shared.overlayOpRefCountForTesting()[id] == 1, "op1+op2 completed, op3 (the LAST op) has not — refcount must be exactly 1")
        #expect(AccountManager.shared.snapshotOverlay()[id] != nil, "overlay entry must survive while the LAST op is still queued")

        // THE regression check: reload mid-drain. Pre-fix, op1 completing
        // would have wiped the WHOLE coalesced entry (unconditional
        // `removeOverlayEntries`), so this reload would show raw DB truth —
        // "unread" (op1+op2's landed state) — instead of the FINAL
        // registered intent (read, op3's target). Post-fix, the overlay
        // entry (refcounted, still alive because op3 hasn't released) wins.
        await vm.reloadMessages()
        #expect(vm.loadedMessages.first?.isRead == true, "mid-drain reload must show the FINAL toggle intent (read), not the intermediate DB state (unread) op1/op2 left behind")

        // Release gate1 and drain the rest so the deferred teardown is safe.
        gate1.finish()
        await drainWriteQueue()

        let finalIsRead = try await pool.read { db in try MessageHeader.fetchOne(db, key: id)?.isRead }
        #expect(finalIsRead == true, "DB truth after full drain must match the LAST toggle's target")
        #expect(AccountManager.shared.snapshotOverlay()[id] == nil, "overlay entry stranded after full drain")
        #expect(AccountManager.shared.overlayOpRefCountForTesting()[id] == nil, "refcount entry stranded after full drain")
    }

    // MARK: - (g) Refcount hygiene

    @Test("refcount hygiene: after N queued toggles on the same id fully drain, both the overlay entry and the refcount entry are gone — no strand")
    func refcountDrainsToEmptyAfterAlternatingToggles() async throws {
        let (pool, inbox, _, dir, previous) = try makeTestDB()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            try? FileManager.default.removeItem(at: dir)
            clearOverlay(); resetStagedGlobal()
        }
        clearOverlay(); resetStagedGlobal()

        let header = makeDurableHeader(folder: inbox, messageId: "m-refcount-hygiene", isRead: false)
        try await pool.writeWithoutTransaction { db in try header.insert(db) }
        let id = header.id

        let vm = InboxViewModel(folders: [inbox])

        vm.toggleRead(id) // -> read
        vm.toggleRead(id) // -> unread
        vm.toggleRead(id) // -> read
        // Retain is synchronous (runs inside toggleRead, not the deferred
        // closure) — the refcount is already 3 the instant these return.
        #expect(AccountManager.shared.overlayOpRefCountForTesting()[id] == 3, "three queued toggles on the same id must each hold their own retain before any drains")

        await drainWriteQueue()

        #expect(AccountManager.shared.snapshotOverlay()[id] == nil, "overlay entry stranded after all ops drained")
        #expect(AccountManager.shared.overlayOpRefCountForTesting()[id] == nil, "refcount entry stranded after all ops drained")
    }

    // MARK: - (h) Mixed gestures on the same id

    @Test("mixed gestures on the same id: toggleRead + toggleFlag queued together — the overlay entry survives until BOTH complete, and the final state (snapshot + DB) reflects both intents")
    func mixedGesturesOnSameIdSurviveUntilBothComplete() async throws {
        let (pool, inbox, _, dir, previous) = try makeTestDB()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            try? FileManager.default.removeItem(at: dir)
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

        vm.toggleRead(id) // opA: isRead -> true
        try await Task.sleep(for: .milliseconds(50)) // let opA's closure append

        // gate1: appended (direct await) strictly BEFORE opB is even spawned.
        let (gate1Stream, gate1) = AsyncStream<Void>.makeStream()
        await AccountManager.shared.enqueueWrite {
            var it = gate1Stream.makeAsyncIterator()
            _ = await it.next()
        }

        vm.toggleFlag(id) // opB: isFlagged -> true
        try await Task.sleep(for: .milliseconds(100)) // let opB's closure append behind gate1

        #expect(vm.loadedMessages.first?.isRead == true)
        #expect(vm.loadedMessages.first?.isFlagged == true)
        #expect(AccountManager.shared.overlayOpRefCountForTesting()[id] == 2, "toggleRead + toggleFlag on the same id must each hold their own retain")

        // Release gate0: opA (read) drains; gate1 then blocks the queue —
        // opB (flag) stays queued, NOT yet drained.
        gate0.finish()
        try await Task.sleep(for: .milliseconds(150))

        // opA alone has completed. Pre-fix, opA's unconditional
        // `removeOverlayEntries` would have wiped the WHOLE coalesced entry
        // here — even though it already carries isFlagged=true from opB's
        // gesture-time `registerMutation` — so a reload would show
        // isFlagged=false (DB truth) despite the user's still-pending flag
        // tap. Post-fix, the refcount (still 1, opB not yet released) keeps
        // the entry alive.
        await vm.reloadMessages()
        #expect(vm.loadedMessages.first?.isRead == true)
        #expect(vm.loadedMessages.first?.isFlagged == true, "flag intent must survive opA (read) completing while opB (flag) is still queued")

        // Release gate1, drain opB, then verify final state + hygiene.
        gate1.finish()
        await drainWriteQueue()

        let final = try await pool.read { db -> (Bool?, Bool?) in
            let h = try MessageHeader.fetchOne(db, key: id)
            return (h?.isRead, h?.isFlagged)
        }
        #expect(final.0 == true)
        #expect(final.1 == true)
        #expect(AccountManager.shared.snapshotOverlay()[id] == nil)
        #expect(AccountManager.shared.overlayOpRefCountForTesting()[id] == nil)
    }

    // MARK: - (i) Vanished-row path releases

    @Test("toggleRead on a row that vanishes before the queued write drains (never durable, never staged) still releases its overlay retain — no strand")
    func vanishedRowPathReleasesOverlayRetain() async throws {
        let (pool, inbox, _, dir, previous) = try makeTestDB()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            try? FileManager.default.removeItem(at: dir)
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

        let dbCount = try await pool.read { db in try MessageHeader.filter(Column("accountId") == "acc1").fetchCount(db) }
        #expect(dbCount == 0, "no durable row ever existed for this id — the write is a graceful no-op")
    }
}
