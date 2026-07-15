/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Synchronization
import Testing
@testable import TabMail

/// Pins `AccountManager.recordRoleMove` — the ADR-IOS-058 intention-record
/// replacement for the deleted `performCoordinatedRoleMove` (PLAN_INTENTION_QUEUE.md
/// §9d/§9l step 4). `recordRoleMove` is the coordinated path agent tools
/// (`EmailArchiveTool`/`EmailDeleteTool`) and the notification action router use in
/// place of a direct `archive(resolved)`/`delete(resolved)` call on a confirmation-time
/// header snapshot. It appends one role-move intention record and awaits the
/// fold's durable completion via `recordAndWait`. Five properties are pinned:
/// 1. Basic archive: row moves, a `.move` PendingOperation is queued, the overlay
///    refcount/entry fully drain.
/// 2. Staleness (Trace-A regression): the write acts on FRESH row truth at execution
///    time, not a snapshot captured before an unbounded user-confirmation wait — a
///    message the user separately moved to Trash while confirmation was pending must
///    have its coordinated-archive PendingOperation record the CURRENT (Trash) source
///    path, not a stale one. Staleness protection is now STRUCTURAL: the fold
///    executor resolves row truth ONCE per component, and `move()`'s own re-resolve
///    (AccountManagerActions.swift) is a second layer.
/// 3. Single-component union: a coordinated move (`recordRoleMove`) whose id already
///    has an OPEN (unconsumed) gesture intention record joins that record's SAME
///    connected component instead of enqueueing a second fold closure — both
///    intentions execute together in ONE `executeFold` pass.
/// 4. Cross-account batches resolve destinations per account.
/// 5. Mixed batch: an account with no role folder is skipped BEFORE the record
///    append, so it never strands an overlay/journal entry.
///
/// `.serialized`: tests touch `AccountManager.shared`'s process-wide optimistic
/// overlay + intention journal + FIFO write queue — mirrors `InboxGestureActionTests`.
@Suite("recordRoleMove — agent-tool intention record + fresh-resolve (ADR-IOS-058)", .serialized, .processGlobalState)
struct CoordinatedToolActionTests {

    // MARK: - Harness (mirrors InboxGestureActionTests.swift)

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
    private func makeDurableHeader(
        folder: Folder,
        messageId: String,
        isRead: Bool = false,
        actionTag: ActionTag? = nil
    ) -> MessageHeader {
        var h = MessageHeader(
            messageId: messageId, subject: "Subj \(messageId)", from: "Sender", fromAddress: "s@example.com",
            to: "me@example.com", date: Date(), snippet: "snip",
            folderId: folder.id, accountId: folder.accountId, folderPath: folder.path,
            isInInbox: folder.role == .inbox
        )
        h.headerComplete = true
        h.isRead = isRead
        h.actionTag = actionTag
        h.rfc822MessageId = "<\(messageId)@example.com>"
        if let actionTag { h.tagSortOrder = actionTag.sortOrder }
        return h
    }

    @MainActor
    private final class AutoAcceptSink: AgentUISink {
        func deliverConfirmation(_ confirmation: AgentToolRouter.ActionConfirmation) {
            confirmation.onRespond(true)
        }
    }

    private func decodeToolResult(_ output: String) throws -> [String: Any] {
        let data = try #require(output.data(using: .utf8))
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// Teardown shared by every test. Mirrors `InboxGestureActionTests.restoreTestDB`:
    /// production paths driven here (drainPendingQueue, unread recounts) fire
    /// unstructured background Tasks the drain barrier cannot join, so they can run
    /// AFTER the defers — leave the test DB alive when there's no previous one to
    /// restore, rather than let `AppDatabase.rawPool`'s force-unwrap crash the process.
    private func restoreTestDB(previous: AppDatabase?, dir: URL) {
        if previous != nil {
            AppDatabase.shared.withLock { $0 = previous }
            try? FileManager.default.removeItem(at: dir)
        }
    }

    private func clearOverlay() {
        AccountManager.shared.intentionJournal.resetForTesting()
    }

    /// FIFO barrier — see `InboxGestureActionTests.drainWriteQueue`. `AccountManager`
    /// is an actor and this call is from a non-actor test context, so (unlike the
    /// production `awaitWriteQueueDrain()`, itself an actor method) this hops via
    /// `Task` before calling `enqueueWrite`.
    /// Round-2 audit: a single FIFO enqueue+await only guarantees closures
    /// already enqueued BEFORE this call have run — it does NOT guarantee the
    /// journal is empty. Two independently-created Tasks (a gesture site's
    /// `record()`, which spawns its own fold-executor Task, and this drain
    /// call) can reach the shared FIFO in EITHER order, so a fold closure the
    /// gesture just triggered may land AFTER this barrier's no-op closure and
    /// still be pending when the barrier returns — closing this window is the
    /// likely fix for the plan's known settle-flake. Loop the barrier until
    /// the journal reports fully drained (no pending records, no in-flight
    /// display holds/seqs); bounded so a genuine stuck-drain bug fails the
    /// test instead of hanging it forever.
    private func drainWriteQueue() async {
        var iterations = 0
        repeat {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                Task { await AccountManager.shared.enqueueWrite { cont.resume() } }
            }
            iterations += 1
        } while !AccountManager.shared.intentionJournal.isFullyDrainedForTesting() && iterations < 200
    }

    // MARK: - (1) Basic archive

    @Test("EmailArchiveTool mixed batch admits RFC and token members, refusing only blank scope — refusals map back to numeric IDs")
    @MainActor
    func archiveToolAdmitsHybridMembers() async throws {
        let (pool, inbox, archive, _, dir, previous) = try makeTestDB()
        defer { restoreTestDB(previous: previous, dir: dir); clearOverlay() }
        clearOverlay()

        let admitted = makeDurableHeader(folder: inbox, messageId: "tool-archive-admitted")
        var missingRFC = makeDurableHeader(folder: inbox, messageId: "tool-archive-missing-rfc")
        missingRFC.rfc822MessageId = nil
        var blankSource = makeDurableHeader(folder: inbox, messageId: "tool-archive-blank-source")
        blankSource.folderPath = ""
        let missingRFCHeader = missingRFC
        let blankSourceHeader = blankSource
        try await pool.writeWithoutTransaction { db in
            try admitted.insert(db)
            try missingRFCHeader.insert(db)
            try blankSourceHeader.insert(db)
        }

        let translator = MockChatIdTranslator()
        await translator.seed(101, realId: admitted.id)
        await translator.seed(102, realId: missingRFCHeader.id)
        await translator.seed(103, realId: blankSourceHeader.id)
        let tool = EmailArchiveTool(context: ToolContext(db: pool, translator: translator))

        let output = try await tool.execute(
            arguments: ["unique_ids": .array([.int(101), .int(102), .int(103)])],
            invocation: ToolInvocation(uiSink: AutoAcceptSink(), sessionKey: "test:archive-rfc-admission")
        )
        let result = try decodeToolResult(output)

        // Hybrid identity (PLAN_IDENTITY_HYBRID §2): the missing-RFC member
        // admits as a provider-ID token; only the blank-scope member refuses.
        #expect(result["success"] as? Bool == true)
        #expect(result["archived_count"] as? Int == 2)
        #expect(Set(result["archived_subjects"] as? [String] ?? []) == [admitted.subject, missingRFCHeader.subject])
        let failedIds = (result["failed_ids"] as? [NSNumber])?.map(\.intValue)
        #expect(failedIds == [103])

        let headerIds = [admitted.id, missingRFCHeader.id, blankSourceHeader.id]
        let final = try await pool.read { db in
            try MessageHeader.filter(keys: headerIds).fetchAll(db)
        }
        let finalById = Dictionary(uniqueKeysWithValues: final.map { ($0.id, $0) })
        #expect(finalById[admitted.id]?.folderId == archive.id)
        #expect(finalById[missingRFCHeader.id]?.folderId == archive.id, "the token member's optimistic move lands too")
        #expect(finalById[blankSourceHeader.id]?.folderId == inbox.id)

        let ops = try await pool.read { db in try PendingOperation.fetchAll(db) }
        #expect(ops.count == 1)
        guard ops.count == 1 else { return }
        #expect(Set(ops[0].messageIds) == ["tool-archive-admitted@example.com", "tool-archive-missing-rfc"],
                "normalized RFC member + byte-exact provider token")
    }

    @Test("EmailDeleteTool: tail members delete via provider-ID tokens; only the blank-scope member refuses")
    @MainActor
    func deleteToolAdmitsTailMembersRefusesBlankScope() async throws {
        let (pool, inbox, _, trash, dir, previous) = try makeTestDB()
        defer { restoreTestDB(previous: previous, dir: dir); clearOverlay() }
        clearOverlay()

        try await pool.writeWithoutTransaction { db in
            var blankAccount = Account(
                emailAddress: "blank-account@example.com",
                displayName: "Blank Account",
                provider: .gmail
            )
            blankAccount.id = ""
            try blankAccount.insert(db)
        }

        var missingRFC = makeDurableHeader(folder: inbox, messageId: "tool-delete-missing-rfc")
        missingRFC.rfc822MessageId = nil
        var malformedRFC = makeDurableHeader(folder: inbox, messageId: "tool-delete-malformed-rfc")
        malformedRFC.rfc822MessageId = "<bad@example.com>\r\nBcc: injected@example.com"
        var blankAccount = makeDurableHeader(folder: inbox, messageId: "tool-delete-blank-account")
        blankAccount.accountId = ""
        let missingRFCHeader = missingRFC
        let malformedRFCHeader = malformedRFC
        let blankAccountHeader = blankAccount
        try await pool.writeWithoutTransaction { db in
            try missingRFCHeader.insert(db)
            try malformedRFCHeader.insert(db)
            try blankAccountHeader.insert(db)
        }

        let translator = MockChatIdTranslator()
        await translator.seed(201, realId: missingRFCHeader.id)
        await translator.seed(202, realId: malformedRFCHeader.id)
        await translator.seed(203, realId: blankAccountHeader.id)
        let tool = EmailDeleteTool(context: ToolContext(db: pool, translator: translator))

        let output = try await tool.execute(
            arguments: ["unique_ids": .array([.int(201), .int(202), .int(203)])],
            invocation: ToolInvocation(uiSink: AutoAcceptSink(), sessionKey: "test:delete-rfc-admission")
        )
        let result = try decodeToolResult(output)

        // Hybrid identity (PLAN_IDENTITY_HYBRID §2): missing/malformed RFC
        // members admit as provider-ID tokens; only the blank-account member
        // refuses.
        #expect(result["success"] as? Bool == true)
        #expect(result["deleted_count"] as? Int == 2)
        let failedIds = (result["failed_ids"] as? [NSNumber])?.map(\.intValue)
        #expect(failedIds == [203])

        let final = try await pool.read { db in
            try MessageHeader.filter(keys: [missingRFCHeader.id, malformedRFCHeader.id, blankAccountHeader.id]).fetchAll(db)
        }
        let finalById = Dictionary(uniqueKeysWithValues: final.map { ($0.id, $0) })
        #expect(finalById[missingRFCHeader.id]?.folderId == trash.id)
        #expect(finalById[malformedRFCHeader.id]?.folderId == trash.id)
        #expect(finalById[blankAccountHeader.id]?.folderId == inbox.id)
        let ops = try await pool.read { db in try PendingOperation.fetchAll(db) }
        #expect(ops.count == 1)
        guard ops.count == 1 else { return }
        #expect(Set(ops[0].messageIds) == ["tool-delete-missing-rfc", "tool-delete-malformed-rfc"],
                "byte-exact provider-ID tokens — never the malformed RFC string")
    }

    @Test("recordRoleMove archives a message: row moves to Archive, the tag is RETAINED (Round D-0), ONE .move PendingOperation is queued, and the overlay refcount/entry fully drain")
    func basicArchiveMovesRowAndDrainsOverlay() async throws {
        let (pool, inbox, archive, _, dir, previous) = try makeTestDB()
        defer { restoreTestDB(previous: previous, dir: dir); clearOverlay() }
        clearOverlay()

        let header = makeDurableHeader(folder: inbox, messageId: "m-basic-archive", actionTag: .reply)
        try await pool.writeWithoutTransaction { db in try header.insert(db) }
        let id = header.id

        await AccountManager.shared.recordRoleMove(ids: [id], role: .archive, origin: .tool)

        let final = try await pool.read { db in try MessageHeader.fetchOne(db, key: id) }
        #expect(final?.folderId == archive.id)
        #expect(final?.folderPath == archive.path)
        #expect(final?.isInInbox == false)
        #expect(final?.actionTag == .reply, "Round D-0: the tag is retained across the inbox-leaving move — no longer destructively cleared")
        #expect(final?.tagSortOrder == ActionTag.reply.sortOrder, "tagSortOrder stays paired with the retained tag")

        // Tags are local-only (ADR-IOS-036) and a move never writes the
        // actionTag column at all (Round D-0), so only the `.move` op is
        // queued — no `.removeTag`/`.setTag` PendingOperation either way.
        let ops = try await pool.read { db in try PendingOperation.fetchAll(db) }
        #expect(ops.count == 1)
        guard ops.count == 1 else { return }
        #expect(ops[0].type == .move)
        #expect(ops[0].destinationPath == archive.path)

        #expect(AccountManager.shared.snapshotOverlay()[id] == nil, "overlay entry stranded after recordRoleMove completed")
        #expect(AccountManager.shared.intentionJournal.isFullyDrainedForTesting(), "journal stranded after recordRoleMove completed")
    }

    // MARK: - (2) Staleness pin (Trace-A regression)

    @Test("staleness regression: a message moved to Trash AFTER the tool captured its id (during the confirmation wait) — the coordinated archive re-resolves FRESH row truth, so its PendingOperation records the CURRENT (Trash) source path, not a stale Inbox path")
    func staleSnapshotDoesNotCorruptSourcePath() async throws {
        let (pool, inbox, archive, trash, dir, previous) = try makeTestDB()
        defer { restoreTestDB(previous: previous, dir: dir); clearOverlay() }
        clearOverlay()

        let header = makeDurableHeader(folder: inbox, messageId: "m-stale-pin")
        try await pool.writeWithoutTransaction { db in try header.insert(db) }
        let id = header.id

        // Simulate the user's later action DURING what would have been the tool's
        // unbounded confirmation wait: move the row to Trash directly (bypassing
        // the coordinated helper — this is the "later user action" the stale
        // snapshot must not reverse). `move()` awaits its own dbPool.write, so the
        // row and its PendingOperation are durably committed before this returns —
        // optimisticMoveToFolder's updateAll only touches folderId/folderPath/
        // isInInbox, never the PK, so `id` stays valid for the lookup below.
        await AccountManager.shared.move([header], to: trash.path)

        let afterFirstMove = try await pool.read { db in try MessageHeader.fetchOne(db, key: id) }
        #expect(afterFirstMove?.folderId == trash.id, "setup: row must be in Trash before the coordinated archive runs")

        // recordRoleMove takes ONLY the id (never a pre-resolved header), and its
        // pre-resolve is display-only: the fold executor's own throwing resolve
        // (`resolveHeadersForActionThrowing`, ADR-IOS-058 "resolve row truth ONCE")
        // re-reads fresh row truth (Trash) at execution time, so there is no stale
        // snapshot to corrupt the resulting PendingOperation's source folderPath —
        // `move()`'s own re-resolve is a second, redundant layer.
        await AccountManager.shared.recordRoleMove(ids: [id], role: .archive, origin: .tool)

        let ops = try await pool.read { db in
            try PendingOperation.order(Column("createdAt").asc).fetchAll(db)
        }
        #expect(ops.count == 2, "one PendingOperation for the Trash move, one for the coordinated archive")
        guard ops.count == 2 else { return }
        // Match by destination rather than positional index — both ops can share
        // a `createdAt` millisecond in a fast test run, so ordering ties aren't
        // load-bearing here; content is.
        guard let archiveOp = ops.first(where: { $0.destinationPath == archive.path }) else {
            Issue.record("no PendingOperation targeting Archive was queued")
            return
        }
        #expect(ops.contains { $0.destinationPath == trash.path }, "the original move-to-Trash op must still be present")
        #expect(archiveOp.type == .move)
        #expect(archiveOp.folderPath == trash.path, "source folderPath must be the CURRENT (Trash) path, not the stale pre-confirmation Inbox path")

        let final = try await pool.read { db in try MessageHeader.fetchOne(db, key: id) }
        #expect(final?.folderId == archive.id, "final row must land in Archive (archive-from-Trash is legitimate)")

        #expect(AccountManager.shared.intentionJournal.isFullyDrainedForTesting(), "journal stranded")
        #expect(AccountManager.shared.snapshotOverlay()[id] == nil)
    }

    // MARK: - (3) Single-component union with an open gesture intention (ADR-IOS-058 journal record)

    @Test("single-component union: a coordinated archive (recordRoleMove) appended while an in-flight gesture intention record for the SAME id is still open joins that SAME connected component — ONE fold execution runs both, the row ends up read AND archived, and the overlay/refcount/journal all drain to empty")
    func coordinatedMoveOrdersAfterOpenIntentCycle() async throws {
        let (pool, inbox, archive, _, dir, previous) = try makeTestDB()
        defer { restoreTestDB(previous: previous, dir: dir); clearOverlay() }
        clearOverlay()

        let header = makeDurableHeader(folder: inbox, messageId: "m-fifo-union", isRead: false)
        try await pool.writeWithoutTransaction { db in try header.insert(db) }
        let id = header.id

        // Gate the FIFO write queue BEFORE the gesture: with an empty queue the
        // fold's executor can drain (and release its retain) before an
        // ungated intermediate assertion runs — the mid-state is only
        // deterministically observable while the gate blocks the drain
        // (pattern: InboxGestureActionTests).
        let (gateStream, gate) = AsyncStream<Void>.makeStream()
        await AccountManager.shared.enqueueWrite {
            var it = gateStream.makeAsyncIterator()
            _ = await it.next()
        }

        // Appends a journal record for id (retain #1, via record()) and
        // enqueues ITS fold executor closure onto the FIFO write queue
        // (behind the gate) via an unstructured Task.
        AccountManager.shared.registerGestureIntent(id: id, .isRead(target: true, baseline: false))
        // Settle: let the fold's Task actually append its closure to the queue
        // BEFORE the coordinated call below appends its own record — establishes
        // deterministic component-joining (mirrors InboxGestureActionTests' 50ms settle).
        try await Task.sleep(for: .milliseconds(50))

        // Deterministic while gated: the executor cannot run, so its retain is
        // still outstanding.
        #expect(AccountManager.shared.intentionJournal.recordsForTesting().filter { $0.ids.contains(id) }.count == 1, "the single isRead record is pending before the coordinated call joins in")

        // Start the coordinated archive CONCURRENTLY, while the gate still blocks
        // the FIFO queue — `recordRoleMove`'s pre-resolve is plain `dbPool.read`
        // work, not FIFO-gated, so it (and the `record()` append inside
        // `recordAndWait`) can complete before the gesture's already-queued fold
        // closure ever runs. Because `id` is still in the journal's OPEN
        // component (its fold hasn't consumed it yet), this append does NOT
        // enqueue a second fold closure — `needsFold` is false, and the record
        // just joins the SAME pending component (ADR-IOS-058: "records sharing
        // any member id join one component"). `recordAndWait` then blocks on
        // that shared component's eventual completion, not a second FIFO slot.
        let coordinatedTask = Task {
            await AccountManager.shared.recordRoleMove(ids: [id], role: .archive, origin: .tool)
        }

        // Bounded deterministic poll (round-1 audit item 4) — replaces a fixed
        // 50ms sleep heuristic: loop until the concurrent recordRoleMove's
        // pre-resolve + append lands and joins the SAME open component, while
        // the gate still blocks the one fold closure that will run them.
        for _ in 0..<200 {
            if AccountManager.shared.intentionJournal.recordsForTesting().filter({ $0.ids.contains(id) }).count == 2 {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }

        // Deterministic proof of single-component joining: BOTH records
        // (isRead + move) are pending for `id` — two independent retains, one
        // still-unconsumed component — while the gate still blocks the ONE fold
        // closure that will execute them together.
        // (mid-flight retain-balance assertion dropped — the record-count check
        // below carries the "2 intents pending" invariant under the derived journal)
        #expect(AccountManager.shared.intentionJournal.recordsForTesting().filter { $0.ids.contains(id) }.count == 2, "the move record joined the SAME open component as the gesture's isRead record — no second fold closure was enqueued")

        // Release the gate: the ONE queued fold closure runs, consumes the
        // shared component (both records), and executes markRead + archive
        // together in a single `executeFold` pass — `recordRoleMove`'s await
        // resolves once that single execution completes.
        gate.finish()
        let actedIds = await coordinatedTask.value
        #expect(actedIds == [id])

        await drainWriteQueue()

        let final = try await pool.read { db in try MessageHeader.fetchOne(db, key: id) }
        #expect(final?.isRead == true, "the fold's markRead must have executed")
        #expect(final?.folderId == archive.id, "the coordinated archive must have executed")

        let ops = try await pool.read { db in try PendingOperation.fetchAll(db) }
        let opTypes = Set(ops.map(\.type))
        #expect(opTypes.contains(.markRead), "the fold's write must have produced a PendingOperation")
        #expect(opTypes.contains(.move), "the coordinated archive's write must have produced a PendingOperation")

        #expect(AccountManager.shared.intentionJournal.isFullyDrainedForTesting(), "journal stranded")
        #expect(AccountManager.shared.snapshotOverlay()[id] == nil, "overlay entry stranded")
    }

    // MARK: - (4) Cross-account batch (audit round 6)

    @Test("cross-account archive batch: each account's message lands in ITS OWN archive folder — the destination is resolved per account, never from the batch's first member")
    func crossAccountArchiveResolvesDestinationPerAccount() async throws {
        let (pool, inbox, archive, _, dir, previous) = try makeTestDB()
        defer { restoreTestDB(previous: previous, dir: dir); clearOverlay() }
        clearOverlay()

        // Second account with a DIFFERENT archive path — the pre-fix code
        // resolved the path from movable.first's account only and applied it
        // to every account in the batch, mis-filing acc2's row into a folder
        // path that doesn't exist for acc2.
        try await pool.writeWithoutTransaction { db in
            var acc2 = Account(emailAddress: "second@example.com", displayName: "Second", provider: .gmail)
            acc2.id = "acc2"
            try acc2.insert(db)
            try Folder(name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc2").insert(db)
            try Folder(name: "Archived Mail", path: "Archived Mail", role: .archive, accountId: "acc2").insert(db)
        }
        let inbox2 = try await pool.read { db in
            try Folder.filter(Column("accountId") == "acc2" && Column("role") == FolderRole.inbox.rawValue).fetchOne(db)
        }
        let archive2 = try await pool.read { db in
            try Folder.filter(Column("accountId") == "acc2" && Column("role") == FolderRole.archive.rawValue).fetchOne(db)
        }
        #expect(inbox2 != nil); #expect(archive2 != nil)
        guard let inbox2, let archive2 else { return }

        let h1 = makeDurableHeader(folder: inbox, messageId: "m-xacct-1")
        let h2 = makeDurableHeader(folder: inbox2, messageId: "m-xacct-2")
        try await pool.writeWithoutTransaction { db in try h1.insert(db); try h2.insert(db) }

        await AccountManager.shared.recordRoleMove(ids: [h1.id, h2.id], role: .archive, origin: .tool)

        let f1 = try await pool.read { db in try MessageHeader.fetchOne(db, key: h1.id) }
        let f2 = try await pool.read { db in try MessageHeader.fetchOne(db, key: h2.id) }
        #expect(f1?.folderPath == archive.path, "acc1's row must land in acc1's archive")
        #expect(f2?.folderPath == archive2.path, "acc2's row must land in acc2's OWN archive path, not acc1's")

        let ops = try await pool.read { db in try PendingOperation.fetchAll(db) }
        let destByAccount = Dictionary(uniqueKeysWithValues: ops.map { ($0.accountId, $0.destinationPath) })
        #expect(destByAccount["acc1"] == archive.path)
        #expect(destByAccount["acc2"] == archive2.path, "acc2's op must carry acc2's destination, not acc1's")

        #expect(AccountManager.shared.intentionJournal.isFullyDrainedForTesting(), "journal stranded")
        for id in [h1.id, h2.id] {
            #expect(AccountManager.shared.snapshotOverlay()[id] == nil, "overlay entry stranded for \(id)")
        }
    }

    // MARK: - (5) Mixed batch: one account missing its role folder entirely (round-8 note (a))

    @Test("mixed multi-account batch: acc2 has NO archive folder at all — acc1's message archives normally (ONE .move op), acc2's message is skipped entirely (zero ops, untouched), and neither the acted-on nor the skipped id strands an overlay/refcount/journal entry")
    func mixedBatchAccountMissingRoleFolderSkipsCleanly() async throws {
        let (pool, inbox, archive, _, dir, previous) = try makeTestDB()
        defer { restoreTestDB(previous: previous, dir: dir); clearOverlay() }
        clearOverlay()

        // acc2 has ONLY an inbox — no archive folder anywhere for this account.
        // recordRoleMove's own "no role folder for account" skip (mirrors
        // archive()/delete()'s moveToRoleFolderPerAccount skip) must drop h2
        // from `actionable` BEFORE the intention record append for it —
        // otherwise h2's id would enter the journal with no way to ever be
        // consumed for this role.
        try await pool.writeWithoutTransaction { db in
            var acc2 = Account(emailAddress: "second@example.com", displayName: "Second", provider: .gmail)
            acc2.id = "acc2"
            try acc2.insert(db)
            try Folder(name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc2").insert(db)
        }
        let inbox2 = try await pool.read { db in
            try Folder.filter(Column("accountId") == "acc2" && Column("role") == FolderRole.inbox.rawValue).fetchOne(db)
        }
        #expect(inbox2 != nil)
        guard let inbox2 else { return }

        let h1 = makeDurableHeader(folder: inbox, messageId: "m-missing-role-1")
        let h2 = makeDurableHeader(folder: inbox2, messageId: "m-missing-role-2")
        try await pool.writeWithoutTransaction { db in try h1.insert(db); try h2.insert(db) }

        await AccountManager.shared.recordRoleMove(ids: [h1.id, h2.id], role: .archive, origin: .tool)

        let f1 = try await pool.read { db in try MessageHeader.fetchOne(db, key: h1.id) }
        #expect(f1?.folderId == archive.id, "acc1's row must still archive normally")
        #expect(f1?.folderPath == archive.path)

        let f2 = try await pool.read { db in try MessageHeader.fetchOne(db, key: h2.id) }
        #expect(f2?.folderId == inbox2.id, "acc2's row is untouched — still in acc2's inbox")
        #expect(f2?.folderPath == inbox2.path)

        let ops = try await pool.read { db in try PendingOperation.fetchAll(db) }
        #expect(ops.count == 1, "exactly one .move op — only acc1's actionable message")
        guard ops.count == 1 else { return }
        #expect(ops[0].accountId == "acc1")
        #expect(ops[0].type == .move)
        #expect(ops[0].destinationPath == archive.path)

        for id in [h1.id, h2.id] {
            #expect(AccountManager.shared.snapshotOverlay()[id] == nil, "overlay entry stranded for \(id)")
        }
        #expect(AccountManager.shared.intentionJournal.isFullyDrainedForTesting(), "journal stranded — h2 must never have entered the journal")
    }

    // MARK: - (6) Fold-layer role-miss pin (test-review round-1)

    /// `recordRoleMove` pre-filters accounts missing the destination role
    /// folder BEFORE appending the intention record (see (5) above), so the
    /// executor's OWN "no role folder found" skip in
    /// `AccountManagerActions.moveToRoleFolderPerAccount` (the ERROR-log
    /// branch reached when `archive()`/`delete()` re-resolves the role
    /// folder at FOLD time and finds it gone) is dead code coverage-wise
    /// through the normal path. Bypassing `recordRoleMove` and appending a
    /// `.move(.role(...))` record DIRECTLY via `AccountManager.shared.record`
    /// reaches it: the archive folder exists at record time (so a real
    /// caller's own pre-filter would have let it through) but is deleted
    /// while the fold is gated, so by the time `archive()` re-resolves the
    /// role folder at fold time, it's gone.
    @Test("role folder deleted BETWEEN record and fold: the executor's 'no role folder found' skip leaves the row untouched, queues NO PendingOperation, and strands nothing in the journal/overlay")
    func roleFolderDeletedBetweenRecordAndFoldSkipsWithoutStranding() async throws {
        let (pool, inbox, archive, _, dir, previous) = try makeTestDB()
        defer { restoreTestDB(previous: previous, dir: dir); clearOverlay() }
        clearOverlay()

        let header = makeDurableHeader(folder: inbox, messageId: "m-role-folder-miss")
        try await pool.writeWithoutTransaction { db in try header.insert(db) }
        let id = header.id

        // Gate the FIFO write queue so the fold executor cannot run until the
        // archive folder has been deleted — mirrors
        // coordinatedMoveOrdersAfterOpenIntentCycle's gate pattern.
        let (gateStream, gate) = AsyncStream<Void>.makeStream()
        await AccountManager.shared.enqueueWrite {
            var it = gateStream.makeAsyncIterator()
            _ = await it.next()
        }

        // Bypass recordRoleMove's own pre-filter entirely — append the
        // intention record DIRECTLY so the fold executor's re-resolve is the
        // only thing standing between "archive folder existed at record
        // time" and "archive folder is gone at fold time".
        AccountManager.shared.record(
            ids: [id], kind: .move(.role(.archive)), displays: [:], origin: .tool
        )

        // Delete the archive folder while the fold is still gated.
        try await pool.writeWithoutTransaction { db in
            _ = try archive.delete(db)
        }

        gate.finish()
        await drainWriteQueue()

        let final = try await pool.read { db in try MessageHeader.fetchOne(db, key: id) }
        #expect(final?.folderId == inbox.id, "row must be untouched — moveToRoleFolderPerAccount's 'no folder' skip never wrote it")
        #expect(final?.folderPath == inbox.path)

        let ops = try await pool.read { db in try PendingOperation.fetchAll(db) }
        #expect(ops.isEmpty, "no PendingOperation — the skip happens before move()'s insert")

        #expect(AccountManager.shared.intentionJournal.isFullyDrainedForTesting(), "journal stranded")
        #expect(AccountManager.shared.snapshotOverlay()[id] == nil, "overlay entry stranded")
    }

    // MARK: - (7) recordAndWait resumes on a vanished row (test-review round-1)

    /// `recordAndWait` must RETURN even when its id never resolves to any
    /// row (durable or staged) — the fold executor's "vanished row" branch
    /// drops the intent with a log but still calls `completeExecution`,
    /// which resumes the awaited receipt. A regression here would hang the
    /// caller (a tool/notification awaiting the receipt) forever. Bounded
    /// against a 5s timeout via two racing tasks rather than trusting a bare
    /// `await` not to hang the whole test run.
    @Test("recordAndWait resumes (does not hang) when its only id never resolves to any row — a vanished row still completes the receipt")
    func recordAndWaitResumesOnVanishedRow() async throws {
        let (_, _, _, _, dir, previous) = try makeTestDB()
        defer {
            restoreTestDB(previous: previous, dir: dir)
            clearOverlay()
            // Failure-mode ergonomics (test-review round 2): if the pin ever
            // FIRES (recordAndWait hangs), the unstructured racer would strand
            // a parked receipt + an inFlightDisplays entry in the process-wide
            // journal, cascading into unrelated-looking failures across later
            // suites. resetForTesting() resumes parked receipts before
            // clearing, so a regression stays ONE isolated red test.
            AccountManager.shared.intentionJournal.resetForTesting()
        }
        clearOverlay()

        // A plain local actor (not `withTaskGroup`) so a genuine hang in
        // `recordAndWait` can't force this test itself to hang: `Task { }` is
        // unstructured, so the test function can move on and fail cleanly at
        // the bounded poll below instead of being forced to join the slow
        // task at a `withTaskGroup` scope exit.
        actor RaceOutcome {
            private(set) var winner: String?
            func declare(_ w: String) { if winner == nil { winner = w } }
        }
        let outcome = RaceOutcome()

        Task {
            await AccountManager.shared.recordAndWait(
                ids: ["nonexistent-id-xyz"], kind: .isRead(true),
                displays: ["nonexistent-id-xyz": .init(isRead: true)], origin: .tool
            )
            await outcome.declare("recorded")
        }
        Task {
            try? await Task.sleep(for: .seconds(5))
            await outcome.declare("timedOut")
        }

        var winner: String?
        for _ in 0..<600 where winner == nil {
            winner = await outcome.winner
            if winner == nil { try? await Task.sleep(for: .milliseconds(10)) }
        }
        #expect(winner == "recorded", "recordAndWait must resume on a vanished row, not hang for 5s")

        await drainWriteQueue()
        #expect(AccountManager.shared.intentionJournal.isFullyDrainedForTesting(), "journal stranded after vanished-row drop")
    }

    // MARK: - (8) Receipt discipline across the primary-resolve read-error retry

    /// Pins `recordAndWait`'s receipt across `executeFold`'s PRIMARY-resolve
    /// read-error path: the receipt must NOT resume during the reinsert
    /// window (the intent has not executed — resuming there would report a
    /// tool success for a write that never happened) and MUST resume after
    /// the paced retry (`SyncConfig.intentionResolveRetryDelaySeconds`)
    /// executes the intent. Mechanically sound because the reinserted
    /// record's seq stays in the journal's pending set, so `awaitCompletion`
    /// stays parked until the retry fold's `completeExecution`. Bounded
    /// polls throughout — no bare unbounded awaits (see the vanished-row
    /// pin above for the discipline's rationale).
    @Test("recordAndWait receipt across a primary-resolve read error: not resumed during the reinsert window, resumed after the paced retry — row moved, exactly one .move op")
    func receiptWaitsAcrossPrimaryResolveRetry() async throws {
        let (pool, inbox, archive, _, dir, previous) = try makeTestDB()
        defer {
            restoreTestDB(previous: previous, dir: dir)
            // clearOverlay() resumes any parked receipt before clearing, so a
            // regression (receipt stranded past the deadline) stays ONE red
            // test instead of cascading into later suites.
            clearOverlay()
            AccountManager.simulatePrimaryResolveFailureForTesting.withLock { $0 = nil }
        }
        clearOverlay()

        let header = makeDurableHeader(folder: inbox, messageId: "m-receipt-retry")
        try await pool.writeWithoutTransaction { db in try header.insert(db) }
        let id = header.id

        // Arm the one-shot, ID-SCOPED primary-resolve failure BEFORE the
        // call: the fold's FIRST resolve throws, records reinsert, the retry
        // fires after the paced delay. (The seam lives in executeFold only —
        // recordRoleMove's display-only pre-resolve is unaffected.)
        AccountManager.simulatePrimaryResolveFailureForTesting.withLock { $0 = id }

        // Child task: the receipt-returning call, with an atomic flag set on
        // return.
        let returned = Mutex(false)
        Task {
            await AccountManager.shared.recordRoleMove(ids: [id], role: .archive, origin: .tool)
            returned.withLock { $0 = true }
        }

        // Poll until the failed fold has provably run and REINSERTED: seam
        // consumed (the fold attempt happened) AND the record is back in the
        // journal (between consume and reinsert the journal is transiently
        // empty, so the conjunction can't fire early) — the pattern from
        // InboxGestureActionTests.annihilationDuringPrimaryResolveRetryWindow.
        var reinserted = false
        for _ in 0..<300 where !reinserted {
            let seamConsumed = AccountManager.simulatePrimaryResolveFailureForTesting.withLock { $0 == nil }
            if seamConsumed && AccountManager.shared.intentionJournal.recordsForTesting().contains(where: { $0.ids.contains(id) }) {
                reinserted = true
            } else {
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
        }
        #expect(reinserted, "setup: the failed fold must have reinserted the move record")

        // Receipt-window sampling: reinsert is detected ~10-20ms in, the
        // retry fires at 1000ms (SyncConfig.intentionResolveRetryDelaySeconds),
        // so 200ms sits deep inside the window — an early-resumed receipt now
        // has ample time to flip the flag; cannot flake red on the correct impl.
        try? await Task.sleep(for: .milliseconds(200))

        // Inside the reinsert window (the paced retry is ~1s out) the receipt
        // must still be parked — the intent has NOT executed.
        #expect(returned.withLock { $0 } == false, "the receipt must NOT resume during the reinsert window — the write has not happened yet")

        // The paced retry executes the intent and completes the receipt —
        // generous 10s deadline, well past the 1s cadence.
        var resumed = false
        for _ in 0..<1000 where !resumed {
            if returned.withLock({ $0 }) {
                resumed = true
            } else {
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
        }
        #expect(resumed, "the receipt must resume once the paced retry executed the intent")

        await drainWriteQueue()

        let final = try await pool.read { db in try MessageHeader.fetchOne(db, key: id) }
        #expect(final?.folderId == archive.id, "the retry must have executed the archive — a read error never drops the intent")

        let ops = try await pool.read { db in try PendingOperation.fetchAll(db) }
        let moveOps = ops.filter { $0.type == .move }
        #expect(moveOps.count == 1, "exactly one .move op — the failed first attempt wrote nothing")
        guard moveOps.count == 1 else { return }
        #expect(moveOps[0].destinationPath == archive.path)

        #expect(AccountManager.shared.intentionJournal.isFullyDrainedForTesting(), "journal stranded")
        #expect(AccountManager.simulatePrimaryResolveFailureForTesting.withLock { $0 } == nil, "the one-shot seam was consumed")
    }
}
