/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Synchronization

extension AccountManager {
    /// Record which queued operations this retirement re-addressed.
    ///
    /// Debug-gated (`BackgroundSyncLogger.logQueue`, `AppLogChannel.queue`) and
    /// present because `IOS-QUEUE-008` took a month to diagnose for exactly this
    /// reason: the lane decision and the address handoff are both invisible after
    /// the fact unless something writes them down. The line names the retiring op
    /// and every follower whose members it rewrote.
    func logReaddressedFollowers(
        _ result: MoveFinishResult, retiring op: PendingOperation
    ) {
        guard !result.readdressedOperationIds.isEmpty else { return }
        BackgroundSyncLogger.logQueue(
            "[Queue] handoff — move \(op.id.prefix(8)) retired and re-addressed "
                + "\(result.readdressedOperationIds.count) queued op(s): "
                + result.readdressedOperationIds.map { String($0.prefix(8)) }.joined(separator: ","))
    }







    /// TEST-ONLY one-shot fault for the post-claim re-read below.
    ///
    /// Holds an operation id; the next `liveOperation` call for that id throws a
    /// `DatabaseError` instead of reading, and clears the arming in the same
    /// critical section so it fires EXACTLY ONCE. `nil` (the default) is no
    /// fault, so production behaviour is the unarmed path.
    ///
    /// Modelled on `DebugModeManager.loggingEnabledOverrideForTesting`: `#if
    /// DEBUG` only, `Mutex`-wrapped, and it may only ADD a throw — it can never
    /// skip a guard, change a disposition, or make a read succeed that would
    /// otherwise fail. It exists because the state this seam produces (a read
    /// that throws AFTER the claim committed `inFlight` + `everAttempted`) is
    /// reachable in production from an interrupted/busy/I-O SQLite read but is
    /// not schedulable from a test against a healthy pool: every earlier read of
    /// the same drain — the ops snapshot, the classifier, the claim — runs on
    /// the same `PrioritizedDatabase`, so a connection-level fault would fail the
    /// drain before anything is ever claimed, which is a different scenario.
    #if DEBUG
    nonisolated static let liveOperationReadFaultForTesting = Mutex<String?>(nil)
    #endif

    /// The row as it is RIGHT NOW, by primary key — the address the drain is
    /// about to send, rather than the one it snapshotted.
    ///
    /// `nil` means exactly one thing: the row no longer exists. A read that
    /// FAILS throws instead, because "we could not determine the answer" is not
    /// evidence about the row and must stay retryable.
    ///
    /// Both executor admission by claimed ID and retained settlement recovery use
    /// this read. A positive absence honors a reset/removal; a thrown read keeps
    /// lifecycle or settlement ownership and stops this drain.
    func liveOperation(_ id: String) async throws -> PendingOperation? {
        #if DEBUG
        let faultArmed = Self.liveOperationReadFaultForTesting.withLock { armed -> Bool in
            guard armed == id else { return false }
            armed = nil
            return true
        }
        if faultArmed {
            throw DatabaseError(
                resultCode: .SQLITE_INTERRUPT,
                message: "injected post-claim re-read failure for \(id)")
        }
        #endif
        return try await dbPool.read { db in try PendingOperation.fetchOne(db, key: id) }
    }

    /// Record which members of a just-completed `.move` are now sitting in an
    /// INBOX, so the post-drain phase can enqueue AI for them.
    ///
    /// **THIS RESTORES ADR-IOS-008 PARITY; it does not invent a pattern.** The
    /// reference implementation is the TB addon's `onMoved.js`, whose
    /// `!wasInInbox && nowInInbox` arm states the rationale in its own comment:
    /// *"inbox scans may not process this message (e.g., sender filter or
    /// maxEmails cap). When a message ENTERS inbox, proactively run the unified
    /// pipeline on just this message so action tags are applied **without
    /// requiring a user click**."* iOS had the other two decision-3 events
    /// (new-mail-arrival via `BodyFetchProcessor`, startup scan via
    /// `ActiveAIQueue.repopulateFromDatabase`) and was missing this one, so a
    /// message moved into the inbox got AI only if the user opened it — i.e.
    /// only by performing the click the action tag exists to make unnecessary.
    ///
    /// **`nowInInbox` is read from the DURABLE ROW, never inferred.** The guard
    /// chain below (`accountId`, `folderPath == destinationPath`, `isInInbox`) is
    /// deliberately the SAME chain as
    /// `AccountManagerActions.restoreInboxAICacheAfterOptimisticMove`, the other
    /// place that asks "did this row actually land in the inbox" — the two are
    /// meant to stay recognisably paired.
    ///
    /// **`wasInInbox` is approximated by `dest != op.folderPath` at the call
    /// site, and that is a deliberate, benign deviation from TB.** The source row
    /// is gone by now, so a true `!wasInInbox` would cost another lookup. The
    /// only case it admits that TB would skip is inbox→inbox across two
    /// inbox-flagged folders, and the cost there is one DEDUPED job whose summary
    /// is already cached (`executeSummaryJob` returns on a cache hit and still
    /// chains the action job), never a wrong or duplicated write.
    func recordMembersThatEnteredInbox(
        _ op: PendingOperation, destinationPath: String, context: AccountOperationExecutor.DrainContext
    ) async {
        let accountId = op.accountId
        // Follow the provider-proven handoff first: when `COPYUID` landed,
        // `finishMove` has already re-keyed this row to its destination address,
        // so the source-shaped id no longer names it. When it did not, the alias
        // map is empty and this returns the id unchanged — which is still the
        // right key, because the row then keeps its source PK.
        let candidateIds = op.messageIds.map { messageId in
            MessageHeaderRekey.currentHeaderId(
                afterHandoffFrom: MessageIdentity.headerId(
                    accountId: accountId, folderPath: op.folderPath, messageId: messageId))
        }
        let entries: [AccountOperationExecutor.DrainContext.InboxEntry] = (try? await dbPool.read { db in
            var found: [AccountOperationExecutor.DrainContext.InboxEntry] = []
            for headerId in candidateIds {
                guard let header = try MessageHeader.fetchOne(db, key: headerId),
                      header.accountId == accountId,
                      header.folderPath == destinationPath,
                      header.isInInbox
                else { continue }
                found.append(AccountOperationExecutor.DrainContext.InboxEntry(
                    accountId: accountId,
                    messageId: header.messageId,
                    rfc822MessageId: header.rfc822MessageId))
            }
            return found
        }) ?? []
        guard !entries.isEmpty else { return }
        let key = "\(accountId)|\(destinationPath)"
        context.enteredInbox.withLock { $0[key, default: []].append(contentsOf: entries) }
        queueLog("[MoveTrace] entered inbox — \(entries.count) member(s) of op \(op.id) landed in \(destinationPath), AI enqueue deferred to post-drain")
    }

    /// Enqueue AI for the members this drain moved into `folderPath`'s inbox.
    ///
    /// **WHY THIS RUNS HERE AND NOWHERE EARLIER — constraint: the id must be the
    /// POST-RE-KEY id.** `ActiveAIQueue.executeJob` resolves the body with
    /// `ContentKey(rawValue: job.headerId)`, so a job carrying a superseded
    /// address finds no FTS body and is dropped. A move can change that address
    /// twice over, by two different paths:
    ///  - the drain's own `COPYUID` re-key (`MessageHeaderRekey.finishMove`, with
    ///    the FTS/bodyAsset mirror in `publishMoveFinish`), and
    ///  - the sync's UID remap (`SyncEngine.runSyncMessages`, with its FTS mirror
    ///    in `SyncEngineFullSync.syncMessages`) when no `COPYUID` was available.
    ///
    /// Both mirrors have completed by the time the post-drain sync call above
    /// returns, so **at this point the durable id and the FTS key agree by
    /// construction** — which is a stronger guarantee than "the sync succeeded",
    /// and why this sits outside that do/catch. If `runSyncMessages` threw, its
    /// transaction rolled back and NEITHER was re-keyed; if it committed, the FTS
    /// mirror runs behind a `try?` that cannot propagate. There is no torn state
    /// to land in.
    ///
    /// Enqueueing from a gesture, from `optimisticMoveToFolder`, or at
    /// `finishMove` time would all race one of those re-keys — that race is
    /// `IOS-AI-005`'s shape and is exactly what this placement avoids.
    ///
    /// No AI-enabled gate: `dispatchPending` already refuses on `canProcessAI`
    /// and clears the queue, with `repopulateFromDatabase` re-discovering when
    /// conditions change. `repopulateFromDatabase` enqueues ungated for the same
    /// reason. ⚠️ That rediscovery is WINDOW-BOUNDED (ADR-IOS-078; comment
    /// corrected 2026-08-20, iOS #66) — `repopulationCandidates` selects only the
    /// newest `SyncConfig.maxRecentEmails` Inbox rows, while the enqueue below is
    /// deliberately window-EXEMPT, so for exactly the out-of-window rows this
    /// exemption exists to serve the stated recovery does NOT fire. Accepted per
    /// ADR-IOS-078's residual invariant: fail-closed, non-durable, one-gesture
    /// recoverable (reopen/Retry). Do NOT widen the sweep to "fix" it, and do NOT
    /// re-gate this producer to "restore" a global bound.
    /// `internal` (not `private`) for executable regression coverage — the same
    /// reason `resolveInboxEntryAITargets` below is: the window-exempt admission
    /// this handler performs is otherwise unreachable from a unit test.
    func enqueueAIForMembersThatEnteredInbox(
        key: String, folderPath: String, context: AccountOperationExecutor.DrainContext
    ) async {
        let entries = context.enteredInbox.withLock { $0.removeValue(forKey: key) } ?? []
        guard !entries.isEmpty else { return }
        // This path intentionally uses the dedicated destination-scoped,
        // RFC-first resolver below: the recorded UID may be stale after the move,
        // so `DurableIdentityLookup` cannot prove identity for this caller. A
        // successful rekey leaves the destination row available by RFC identity;
        // `ActiveAIQueue` later revalidates its live Inbox scope.
        let resolved: [(headerId: String, accountId: String)] = (try? await dbPool.read { db in
            try Self.resolveInboxEntryAITargets(
                entries: entries, folderPath: folderPath, db: db)
        }) ?? []
        guard !resolved.isEmpty else {
            queueLog("[MoveTrace] entered inbox — \(entries.count) member(s) in \(folderPath) resolved to no live inbox row, nothing enqueued")
            return
        }
        // Per-item `enqueue` (S + R, with A chained by the summary job) mirrors
        // the sibling event-driven site, `BodyFetchProcessor.flushBatch`'s
        // `enableAI && item.isInInbox` arm — EXCEPT the window: a move into the
        // Inbox is explicit user intent on a specific message, so it is
        // window-exempt (ADR-IOS-078 pathway regating, coordinator-ruled
        // 2026-08-19); gating it would recreate the user-must-click gap
        // ADR-IOS-008 decision 3 closed. `flushBatch`'s DEFAULT (background/sync)
        // path stays gated — it is the sync-origin producer the install-flood
        // bound exists for (that same function is dual-origin: the user-open body
        // fetch passes `aiWindowExempt: true`, but that is a different caller).
        // The executor still retires any job whose message has LEFT the Inbox
        // (membership is unconditional; only the newest-100 rank is waived).
        for item in resolved {
            await ActiveAIQueue.shared.enqueue(
                headerId: item.headerId, accountId: item.accountId, windowExempt: true)
        }
        queueLog("[MoveTrace] entered inbox — enqueued AI for \(resolved.count) member(s) in \(folderPath)")
    }

    /// The id each recorded member is CURRENTLY addressable by, for the AI
    /// enqueue above. `internal static` for executable regression coverage — the
    /// same reason `AccountManagerActions
    /// .restoreInboxAICacheAfterOptimisticMove` is internal; it is not a second
    /// enqueue path.
    ///
    /// ⚠️ **DO NOT "simplify" this to `MessageIdentity.headerId(accountId:
    /// folderPath: messageId:)` on the recorded `messageId`.** That reconstructs
    /// the address the member had when it was recorded, which the sync's UID
    /// remap can already have superseded — the job would then miss its FTS body
    /// and be dropped. Worse, resolving a bare source UID against a different
    /// folder can land on an UNRELATED message that shares that number, because
    /// IMAP UIDs are mailbox-local.
    ///
    /// 🚨 **AND DO NOT ROUTE THIS BACK THROUGH `DurableIdentityLookup.find` —
    /// IT WAS WRITTEN THAT WAY, AND IT RESOLVED THE WRONG MESSAGE.** That
    /// helper's header lists six consumers that must stay "in lockstep", so a
    /// reader who finds a seventh identity resolution sitting outside it will
    /// try to restore consistency by routing this through `find` again. That
    /// reintroduces a wrong-message defect, for a reason that is a PREMISE of
    /// the helper rather than a bug in it:
    ///
    ///  - `find`'s **step 1** matches `(accountId, folderPath, messageId)` and
    ///    returns immediately with **no rfc822 check** — the only unguarded step
    ///    of its three. Its stated justification is *"Unambiguous: IMAP UIDs are
    ///    scoped per folder, so a hit here is provably the same message."* The G3
    ///    audit that added rejection logic added it to step **2**, the
    ///    folder-BLIND case; step 1 was deliberately left bare.
    ///  - That is sound **only if the `(folderPath, messageId)` pair you pass is
    ///    the message's CURRENT address.** All six lockstep consumers pass a
    ///    STAGED row's address, which the NSE has just observed on the server —
    ///    current by construction.
    ///  - **This caller cannot honour that.** It deliberately passes the
    ///    PRE-REMAP UID against the folder the message has only just moved INTO.
    ///    An unrelated message can legitimately occupy that exact address, and
    ///    step 1 returns it. Verified: `MoveIntoInboxAIEnqueueTests
    ///    .aiTargetIsNeverAUidCollisionVictim` failed on this code, resolving the
    ///    decoy's body instead of the moved message's.
    ///
    /// The distinction that keeps the two apart: the lockstep list is about
    /// **dedup identity** for the merge and the reader. This is **AI-target
    /// selection after a known move**, whose input address is stale on purpose.
    /// Consistency must not be bought by reintroducing the wrong-message defect.
    ///
    /// So the priority is INVERTED relative to `find`: the rfc822 identity is
    /// the only thing that survives both re-key paths, so it is required rather
    /// than used as a fallback.
    ///
    /// The RFC index hint is load-bearing with migration-left statistics. Without
    /// it SQLite walks `messageHeader_accountId_messageId (accountId=?)`; on the
    /// current migrated schema with 200k rows / 100k per account, a hit/miss took
    /// 17.0–26.2 ms (p95) versus 0.004–0.005 ms through the v1 single-column RFC
    /// index. After `ANALYZE`, both forms took 0.003–0.006 ms. This loop is already
    /// off-main and the hint adds no write, space, or concurrency cost.
    ///
    /// A composite index would add per-message write/space cost, while foreground
    /// whole-database `ANALYZE` is disproportionate and does not improve every
    /// query class. If the named index disappears, the statement throws and this
    /// caller's existing `try?` resolves no AI target rather than guessing.
    ///
    /// The destination-folder predicate already selects the intended move target;
    /// `ORDER BY id ASC LIMIT 1` deliberately makes same-folder duplicate-RFC rows
    /// deterministic. It does NOT prefer or require `isInInbox`, because
    /// `ActiveAIQueue.readJobOutcome` remains the authoritative live scope check.
    /// The bounded N+1 is retained: entries are only the members of one completed
    /// operation, and per-entry refusal/logging remains clearer than broadening this
    /// fix into a set-based identity rewrite.
    nonisolated static func resolveInboxEntryAITargets(
        entries: [AccountOperationExecutor.DrainContext.InboxEntry], folderPath: String, db: Database
    ) throws -> [(headerId: String, accountId: String)] {
        var out: [(headerId: String, accountId: String)] = []
        for entry in entries {
            // FAIL CLOSED, and OBSERVABLY. A member with no usable rfc822
            // identity cannot be re-identified across a UID remap by anything
            // this function has, and guessing from the stale address is the
            // wrong-message bug above. Refusing costs only that this message
            // waits for the ordinary foreground repopulate or an open — but a
            // SILENT refusal would be indistinguishable from "AI has not run
            // yet", which is exactly `IOS-AI-005`'s unobservable-drop shape.
            // Debug-gated per development rule 12.
            guard let rfc822 = entry.rfc822MessageId, !rfc822.isEmpty else {
                queueLog("[MoveTrace] entered inbox — REFUSED AI enqueue for \(entry.accountId) uid=\(entry.messageId) in \(folderPath): no rfc822 Message-ID, cannot re-identify across a UID remap")
                continue
            }
            // Scoped to the destination FOLDER, so the row this lands on is the
            // one that entered THIS inbox. `isInInbox = 1` is deliberately NOT a
            // conjunct here: `folderPath` already pins the folder, the capture in
            // `recordMembersThatEnteredInbox` only records rows that were
            // `isInInbox`, and `ActiveAIQueue.readJobOutcome` independently
            // refuses a job whose row is no longer in an inbox (`.scopeExited`).
            // A redundant conjunct in a correctness guard can mask the failure of
            // the one that matters.
            guard let id = try String.fetchOne(
                db, sql: Self.inboxEntryAITargetSQL,
                arguments: [entry.accountId, folderPath, rfc822]
            )
            else {
                queueLog("[MoveTrace] entered inbox — no live row in \(folderPath) for rfc822 identity of uid=\(entry.messageId), nothing enqueued")
                continue
            }
            out.append((headerId: id, accountId: entry.accountId))
        }
        return out
    }

    /// The exact moved-inbox AI-target statement, exposed so plan coverage
    /// exercises production SQL instead of a test-only copy.
    nonisolated static let inboxEntryAITargetSQL = """
        SELECT id FROM messageHeader INDEXED BY messageHeader_rfc822MessageId
        WHERE accountId = ? AND folderPath = ? AND rfc822MessageId = ?
        ORDER BY id ASC
        LIMIT 1
        """

    // MARK: - Queued-member identity lookup

    /// The `messageHeader` identity columns a drain needs for one queued member.
    struct QueuedMemberIdentity {
        let rfc822MessageId: String?
        let messageId: String
    }

    /// Resolves the identity columns for EVERY member of a queued operation in two
    /// set-based statements, replacing one `fetchOne` per member.
    ///
    /// ## Why this is not an N+1 tidy-up
    ///
    /// The per-member statement was
    /// `WHERE (messageId = ? OR rfc822MessageId = ?) AND accountId = ?`, and with no
    /// `sqlite_stat1` row for a full index on `messageHeader` — the regime a device
    /// holds until `SyncEngineMaintenance.runRefreshPlannerStatisticsIfStale` runs,
    /// see ADR-IOS-029 — SQLite cannot use a two-index `MULTI-INDEX OR` for it and
    /// falls back to `SEARCH messageHeader USING INDEX messageHeader_accountId_messageId
    /// (accountId=?)`: a walk of the whole account that stops at the first matching row.
    /// Measured on a 260k-row fixture, 189,800 rows in the account, SQLite 3.51.0 (Mac;
    /// a device is 2–4× slower), 200 members:
    ///
    /// ```
    ///                                        stale stats      ANALYZEd
    ///   per-member fetchOne (before)          12,229 ms          11 ms
    ///   IN-list arm A + hinted arm B (after)      <1 ms          <1 ms
    /// ```
    ///
    /// ⚠️ The cost depends on WHERE the member sits in the walk, not merely on whether
    /// it exists — the ADR's "probe with a value that EXISTS" warning has this sibling.
    /// The same 200 lookups against members at the HEAD of `(accountId, messageId)`
    /// order measured 0.105 ms each and made the defect look absent. The figures above
    /// draw from the tail, which is where a bulk archive of recent mail lands.
    ///
    /// ## Ordering of the two arms, and what changed
    ///
    /// Arm A matches `messageId` exactly, arm B matches the normalized
    /// `rfc822MessageId`; a member resolved by both takes arm A. That is the same
    /// precedence the `MULTI-INDEX OR` plan already applied whenever statistics
    /// existed. Within one arm several rows can match — `messageId` is a per-folder
    /// UID and repeats across the folders of one account (the fixture has 8 rows for
    /// `messageId = '1'` in one account) — so the pick is made deterministic with
    /// `ORDER BY isInInbox DESC, id ASC`, the same inbox-preferred tie-break
    /// `ChatStore.findByStableIdSQL` uses. **This is a deliberate narrowing:** the
    /// previous `fetchOne` over an `OR` returned whichever row its plan reached first,
    /// so which sibling won already differed between statistics regimes. The consumers
    /// feed `recordRecentlyCompleted`, so the change is which sibling's ids enter a 30s
    /// sync-protection set, never which message is mutated.
    ///
    /// ## `INDEXED BY` on arm B is load-bearing
    ///
    /// Without it, arm B plans as `messageHeader_accountId_messageId (accountId=?)` in
    /// the stale regime — one account walk for the whole op (69 ms measured) instead of
    /// one per member. With it, both regimes seek: `messageHeader_rfc822MessageId
    /// (rfc822MessageId=?)`, 0 ms. Same reasoning and same fail-safe as
    /// `ChatStore.findByStableIdSQL`: a migration that drops or renames the index makes
    /// this statement THROW rather than silently walk, and both callers already treat a
    /// throw as "no identity columns collected".
    nonisolated static func headerIdentitiesForQueuedMembers(
        _ memberIds: [String], accountId: String, db: Database
    ) throws -> [String: QueuedMemberIdentity] {
        guard !memberIds.isEmpty else { return [:] }

        var normalizedByRaw: [String: String] = [:]
        for id in memberIds { normalizedByRaw[id] = EmailFilter.normalizeMessageId(id) }

        // Keyed by the value each arm matches on. `pick` keeps the inbox-preferred,
        // lowest-`id` row so a member resolves to the same sibling every time.
        var byMessageId: [String: (sortKey: (Int, String), identity: QueuedMemberIdentity)] = [:]
        var byRfc822: [String: (sortKey: (Int, String), identity: QueuedMemberIdentity)] = [:]

        func absorb(_ rows: [Row], into table: inout [String: (sortKey: (Int, String), identity: QueuedMemberIdentity)],
                    keyedBy key: (Row) -> String?) {
            for row in rows {
                guard let bucket = key(row) else { continue }
                let rowId: String = row["id"]
                let isInInbox: Bool = row["isInInbox"]
                // isInInbox DESC → inbox rows sort first, hence `0` for inbox.
                let sortKey = (isInInbox ? 0 : 1, rowId)
                let identity = QueuedMemberIdentity(
                    rfc822MessageId: row["rfc822MessageId"], messageId: row["messageId"])
                if let existing = table[bucket], existing.sortKey <= sortKey { continue }
                table[bucket] = (sortKey, identity)
            }
        }

        for chunk in Array(normalizedByRaw.keys).chunked(into: SyncConfig.sqlChunkSize) {
            let rows = try Row.fetchAll(
                db, sql: Self.queuedMemberIdentitySQL(matching: "messageId", count: chunk.count),
                arguments: StatementArguments([accountId] + chunk))
            absorb(rows, into: &byMessageId, keyedBy: { (row: Row) -> String? in row["messageId"] })
        }
        for chunk in Array(Set(normalizedByRaw.values)).chunked(into: SyncConfig.sqlChunkSize) {
            let rows = try Row.fetchAll(
                db, sql: Self.queuedMemberIdentitySQL(matching: "rfc822MessageId", count: chunk.count),
                arguments: StatementArguments([accountId] + chunk))
            absorb(rows, into: &byRfc822, keyedBy: { (row: Row) -> String? in row["rfc822MessageId"] })
        }

        var out: [String: QueuedMemberIdentity] = [:]
        for (raw, normalized) in normalizedByRaw {
            if let hit = byMessageId[raw] {
                out[raw] = hit.identity
            } else if let hit = byRfc822[normalized] {
                out[raw] = hit.identity
            }
        }
        return out
    }

    /// The statements `headerIdentitiesForQueuedMembers` runs, exposed so a plan test
    /// asserts against production's own SQL rather than a copy that could drift
    /// (`ChatStore.findByStableIdSQL` / `MessageContentStore.ownersSQL` precedent).
    nonisolated static func queuedMemberIdentitySQL(matching column: String, count: Int) -> String {
        let placeholders = Array(repeating: "?", count: count).joined(separator: ", ")
        // Arm B needs the hint; arm A's plan is already a two-column seek in both
        // regimes, and an unnecessary hint would only add a way for a future migration
        // to break the statement.
        let hint = column == "rfc822MessageId" ? " INDEXED BY messageHeader_rfc822MessageId" : ""
        return """
            SELECT id, messageId, rfc822MessageId, isInInbox
            FROM messageHeader\(hint)
            WHERE accountId = ? AND \(column) IN (\(placeholders))
            """
    }

    // MARK: - Drain-barrier Test Seam (T0.8)
    //
    // `ProviderIdQueueFuzzTests` needs a drain barrier, and per the plan's T0.5
    // callout a barrier is only correct if it samples its predicate BEFORE
    // requesting a drain — otherwise every poll lands on `drainPendingQueue()`'s
    // is-draining guard above, sets `needsRedrain` itself, and the barrier keeps
    // its own re-arm alive forever. That corrected shape needs to be able to
    // observe "no drain in flight", which `isDraining`/`needsRedrain`
    // (`AccountManager.swift:274`, `:276`) do not expose to a test on their own.
    //
    // This is a verbatim port of the reference accessor
    // (`v2final:TabMail/Services/Account/AccountManagerQueue.swift:3172-3174`) —
    // same name, same predicate — with the one deviation this file's sibling
    // seams already established (`IMAPProvider.mutLogForTesting` and the
    // T0.6(a) pool-invariant seams; symbol-cited, no line numbers): the
    // reference leaves its `…ForTesting` surface UNGATED, here it is `#if DEBUG`
    // so Release builds carry neither the member nor any call site. Purely
    // additive: nothing above changed, and no production code reads it.
    #if DEBUG

    /// Narrow test seam for proving that awaiting a drain also joins any
    /// requested re-drain instead of leaving unstructured queue work behind.
    ///
    /// The barrier that consumes it MUST read this FIRST and only then ask for a
    /// drain (see `ProviderIdQueueFuzzTests.drainProviderQueue`) — the inverse
    /// ordering is the self-re-arm bug the reference fixed in `f214c704a`.
    func pendingQueueIsQuiescentForTesting() -> Bool {
        !isDraining && !needsRedrain
    }

    #endif



    /// Publish a COMMITTED local move finish into the **three** stores that key
    /// by `messageHeader.id` but do not live in the GRDB database — the
    /// in-memory undo stack, the FTS index, and the body-asset manifest. Applied
    /// re-keys move all three. Retained-unaddressed members lose only their
    /// unsafe stale-address undo entries. Removed old ids lose undo entries and
    /// external mirrors. Shared by the whole-op success path and the narrowing
    /// pass so the dispositions cannot drift.
    ///
    /// ⚠️ THIS LEDE SAID "**two** … the in-memory undo stack and the FTS index"
    /// until R16-7 (corrected 2026-08-06), while the block 30 lines below it
    /// shouted that the manifest is *"THE **THIRD** STORE KEYED BY
    /// `messageHeader.id` OUTSIDE GRDB"* and the body has mirrored into it since
    /// R12-T7. A stale count in the lede is worse than no count: a reader
    /// enumerating out-of-GRDB stores stops at the first sentence that answers
    /// the question. Re-derive rather than trust — the predicate skips comments,
    /// so nothing here can satisfy it:
    ///   `rg -n --pcre2 '^(?!\s*(///|//)).*(UndoService\.shared\.applyRekeys|SearchIndex\.shared\.rekeyHeaders|BodyAssetStore\.rekeyContentKey)'
    ///    TabMail/Services/Account/AccountManagerQueue.swift` → **3**.
    ///
    /// 🚨 THE UNDO STACK IS PUBLISHED FIRST, AND THE ORDER IS THE FIX
    /// (`IOS-UNDO-002`). `SearchIndex` is a SEPARATE SQLite pool, so its re-key
    /// is a real cross-database round trip. Running it first left the undo stack
    /// naming the STALE `originalHeaderId` for the whole of that suspension: an
    /// `Undo` landing inside it popped an entry `AccountManager.undoMove`
    /// authenticates with `MessageHeader.fetchOne(db, key: originalHeaderId)`,
    /// which is now nil, so the WHOLE command was refused — and the later
    /// publication could not repair an entry already popped off the stack.
    /// Publishing to the undo stack first removes the cross-database trip from
    /// that window entirely, leaving only the `@MainActor` hop every publication
    /// in this app already has. Nothing else about the ordering moves: both
    /// stores are still updated AFTER the GRDB commit, which is the two-phase
    /// shape the sync path uses.
    ///
    /// ⚠ ACCEPTED RESIDUAL: an undo landing inside that single `@MainActor` hop
    /// is still refused whole. It is fail-closed — the message is correctly at
    /// the destination, nothing mutates the wrong message, no queued op is
    /// dropped — and the user recovers by moving it back with one ordinary
    /// gesture.
    ///
    /// 🚨 A COLLIDED RE-KEY LEAVES NO HEADER BEHIND (`IOS-SEARCH-002`), so its
    /// FTS entry is removed rather than moved. `MessageHeaderRekey.apply`
    /// deletes the old row before its collision return, so the old id names
    /// nothing; leaving its index entry in place produces the *indexed but
    /// unfindable* class — a search hit whose header is gone, at a composite id
    /// a later message can re-occupy. The sync caller already compensates by
    /// routing the id down its `staleIds` path; this is the drain's equivalent.
    ///
    /// 🚨 THE BODY-ASSET MANIFEST IS THE **THIRD** STORE KEYED BY
    /// `messageHeader.id` OUTSIDE GRDB, AND IT USED TO BE MISSING FROM HERE
    /// (R12-T7). `MessageHeaderRekey.apply`'s doc calls `bodyAsset`
    /// *"deliberately out of scope … swept by its own headerId-prefix
    /// maintenance path"*, and that was true while the drain never re-keyed —
    /// at `v1.6.38` the id stayed live, so `BodyAssetMaintenance.pruneOrphans`
    /// never saw the key as dead. It stopped being true the moment this
    /// function started finishing moves locally, because that sweep's ONLY
    /// recovery leg, `MessageContentStore.recoverMovedContentKey`, is gated on
    /// `provider == .gmail || .outlook` **and** matches on an **unchanged**
    /// `providerMessageId` — and `finishMove` re-keys precisely because the
    /// tail CHANGED. IMAP is excluded by the gate; Outlook passes the gate and
    /// misses the lookup. The sweep therefore reclassified a live message's
    /// cached inline images and attachments as orphans and deleted them, while
    /// the carried-over `messageBody` row at the NEW key still referenced them
    /// through `tabmail-asset://`, and `attachmentAssetId(contentKey:…)` — which
    /// looks up by `headerId` — could no longer find the bytes it had.
    ///
    /// ⚠ THIS IS A REGRESSION, NOT MERELY AN EDGE, which is why it is fixed
    /// rather than registered under THE MANTRA. It self-heals at
    /// `SyncConfig.bodyCacheTTLHours`, so it clears the recoverability test —
    /// but the path that reaches it is *archive or move a message you just
    /// read*, an ordinary primary path that `v1.6.38` handled correctly.
    ///
    /// ⚠ THE COLLISION SPLIT IS LOAD-BEARING HERE FOR A DIFFERENT REASON THAN
    /// IT IS FOR FTS. A collided re-key means a row ALREADY occupies the
    /// destination address; mirroring the re-key blindly would file two
    /// messages' attachments under one content key, and every later
    /// `attachmentAssetId` lookup at that key could return the OTHER message's
    /// bytes — a content misattribution, C3-adjacent. So the collided ids take
    /// `deleteAllAssets` exactly as they take `removeMessages` above: the
    /// destination row is the survivor and owns its own assets, and the loser's
    /// cache is re-downloadable. `rekeyContentKey` independently makes the same
    /// choice if it races (`newExists` ⇒ delete the old key), so the two agree.
    ///
    /// ⚠ COST (A6). This adds ONE bounded `UPDATE` per applied record on the
    /// manifest queue — the same cardinality IN ROWS as the FTS mirror
    /// immediately above, but NOT in transactions: `SearchIndex.rekeyHeaders`
    /// takes the whole array in ONE call, while this loop issues N separate
    /// cross-process `queue.write`s on the manifest pool. Batching it would need
    /// a manifest-side multi-key overload plus a per-key collision split, which
    /// is more mechanism than the cost justifies — N is bounded by one drained
    /// op's members and none of this is on the render path. The store's primary
    /// key is `id` and `headerId` is the column the sweep already scans, so each
    /// write is itself cheap. Both stores are separate SQLite pools;
    /// this one is synchronous because `BodyAssetStore` is a nonisolated `enum`
    /// serving the NSE and the main app identically. A missing App Group
    /// container makes `manifestQueue()` nil and every call a no-op returning 0,
    /// which is the correct fail-safe: no assets means nothing to orphan.
    func publishMoveFinish(_ result: MoveFinishResult) async {
        let applied = result.applied
        let removedOldHeaderIds = result.removedOldHeaderIds
        if !applied.isEmpty {
            queueLog("[MoveTrace] executeSingleOp — re-keyed \(applied.count) moved row(s) to their provider-proven destination address")
            // The undo stack names its members by the SAME primary key and UID
            // this re-key just changed, so it has to follow — otherwise
            // finishing the move would break undo rather than enable it.
            // An Undo already admitted to the local FIFO may still need to
            // cancel a deferred successor keyed by the predecessor's OLD
            // address. COPYUID publication happens outside that FIFO. Keep
            // only those in-progress members on the old key until their
            // already-queued cancellation runs; stacked actions and ordinary
            // in-progress Undo members still follow the provider rekey.
            let deferredCancellationIds = Set(deferredMoveSuccessors.keys)
            await UndoService.shared.applyRekeys(
                applied,
                preservingInProgressMemberIds: deferredCancellationIds)
            await MainActor.run {
                NotificationCenter.default.post(
                    name: .messageHeadersRekeyed,
                    object: applied)
            }
            // Persisted chat pills name messages by that same mutable primary key.
            // Keep their numeric identity stable across the move; otherwise a
            // cached discussion still renders its baked subject but tapping it
            // resolves the now-deleted source address and appears inert.
            for record in applied {
                _ = await ChatIdTranslator.shared.remapRealId(
                    from: record.oldHeaderId,
                    to: record.newHeaderId)
            }
            // The FTS index is a SEPARATE database, so its re-key is two-phase —
            // outside the GRDB write — exactly as the sync path does it. The
            // entry MOVES; it is never removed.
            try? await SearchIndex.shared.rekeyHeaders(applied.map {
                (oldKey: ContentKey(rawValue: $0.oldHeaderId),
                 newKey: ContentKey(rawValue: $0.newHeaderId),
                 newMessageId: $0.newProviderMessageId)
            })
            // The body-asset manifest keys by the same header id. See the
            // R12-T7 block above: `pruneOrphans`' recovery leg structurally
            // cannot see the id-CHANGING shape this function produces, so
            // without this the next sweep deletes a live message's cached
            // bodies and attachments.
            var rekeyedAssetKeys = 0
            for record in applied {
                if BodyAssetStore.rekeyContentKey(
                    from: ContentKey(rawValue: record.oldHeaderId),
                    to: ContentKey(rawValue: record.newHeaderId)) > 0 {
                    rekeyedAssetKeys += 1
                }
            }
            if rekeyedAssetKeys > 0 {
                queueLog("[MoveTrace] executeSingleOp — re-keyed \(rekeyedAssetKeys) moved row(s)' cached body assets")
            }
        }
        let unsafeUndoIds = result.unsafeUndoOldHeaderIds + removedOldHeaderIds
        if !unsafeUndoIds.isEmpty {
            await UndoService.shared.discardMembers(namedByOldHeaderIds: unsafeUndoIds)
        }
        if !removedOldHeaderIds.isEmpty {
            queueLog("[MoveTrace] executeSingleOp — dropped \(removedOldHeaderIds.count) external mirror(s) whose old header no longer exists")
            try? await SearchIndex.shared.removeMessages(
                contentKeys: removedOldHeaderIds.map { ContentKey(rawValue: $0) })
            // Same disposition for the assets, and for a stronger reason —
            // merging them onto the survivor's key would misattribute one
            // message's attachment bytes to another.
            for oldId in removedOldHeaderIds {
                _ = BodyAssetStore.deleteAllAssets(forContentKey: ContentKey(rawValue: oldId))
            }
        }
    }


    /// Retire the local headers of members a PROVIDER named as gone, for an
    /// operation whose retirement has just committed.
    ///
    /// 🚨 CALLED FROM EVERY PATH THAT RETIRES SUCH A MEMBER, AND ONLY AFTER ITS
    /// RETIREMENT HAS COMMITTED. The header row lives in a different table and its
    /// deletion releases FTS and body content, so it must never be able to precede
    /// the operation's own retirement; and the four sites that can commit one —
    /// whole-op success, the narrowing path, and the retained replay of either —
    /// must all do it, or a member is retired from the queue while its ghost row
    /// survives in the mailbox.
    ///
    /// `memberIds` are ids the provider reported through
    /// `ProviderMembersDispositioned` / `MoveOutcome.confirmedGoneIds`, i.e. members a
    /// request addressed to THAT member answered `ProviderMemberAbsence`-
    /// authoritatively for. Nothing else may be passed here.
    ///
    /// 🚨 WHY `op.folderPath` RECONSTRUCTS THE HEADER'S REAL PRIMARY KEY, even
    /// though the gesture has already moved the row locally. A header's id is
    /// `(accountId, folderPath, messageId)`, and a `.move` gesture applies
    /// `optimisticMoveToFolder` immediately — but that helper UPDATEs
    /// `folderId` / `folderPath` / `isInInbox` / `observedUidValidity` BY PRIMARY
    /// KEY `id` and does NOT re-key the row, so the id still spells the SOURCE
    /// folder while the columns spell the destination. The operation's
    /// `folderPath` is that same source folder, so it is the correct component
    /// here; taking `destinationPath`, or re-deriving from the header's current
    /// `folderPath` column, would compute an id no row has and the delete would
    /// silently match nothing.
    ///
    /// The same reasoning covers a FOLLOWER of an already-landed move: the drain
    /// re-keys a row only through `MessageHeaderRekey.finishMove`, and a
    /// follower's own `folderPath` is by construction its predecessor's landing
    /// folder — the address space the follower was admitted into — so the pair
    /// (op.folderPath, memberId) is exactly what that row's id was built from.
    func retireConfirmedGoneMemberHeaders(
        _ op: PendingOperation, memberIds: [String]
    ) async {
        for goneId in memberIds {
            let hid = MessageIdentity.headerId(
                accountId: op.accountId,
                folderPath: op.folderPath,
                messageId: goneId)
            await deleteConfirmedGoneHeader(
                headerId: hid, reason: "\(op.type.rawValue) member gone")
        }
    }

    /// Delete a single messageHeader (identified by its full primary key) that has
    /// been structurally confirmed gone from the server. The FK cascade removes the
    /// MessageReference children; the `messageBody` row is reclaimed by the routed
    /// release below (Stage D dropped that cascade — a content key is not a header
    /// id). The FTS row is removed on the same release.
    /// Safe to call with a headerId that isn't in the local DB — DELETE returns 0
    /// rows and FTS remove is idempotent.
    ///
    /// Scoped to the exact (accountId, folderPath, messageId) combination, NOT
    /// (accountId, messageId) alone: for IMAP, UIDs are per-folder so the same
    /// messageId can identify completely different messages across folders, and
    /// a broader delete would orphan unrelated rows.
    ///
    /// ONLY call this when `isConfirmedGoneError` returned true (Exchange/Gmail
    /// 404/410 or ProviderError.messageNotFound) or the IMAP-backfill miss-count
    /// threshold has been reached after an rfc822 confirmation. Never call on a
    /// transient connection error.
    /// 🚨 ORDERING CONTRACT (`MessageContentStore`): the content key and its scope
    /// are captured INSIDE the delete transaction, from the row about to go away,
    /// and the release happens AFTER that transaction commits. Reversed, the header
    /// still exists when owners are counted, the count is always ≥ 1, and the FTS
    /// row is never removed — a silent no-op every outcome-only test still passes.
    func deleteConfirmedGoneHeader(headerId: String, reason: String) async {
        let captured: MessageContentStore.CapturedContent?
        let existed: Bool
        do {
            (existed, captured) = try await dbPool.write {
                db -> (Bool, MessageContentStore.CapturedContent?) in
                guard let header = try MessageHeader.fetchOne(db, key: headerId) else {
                    return (false, nil)
                }
                let captured = try MessageContentStore.capture(header, db: db)
                try header.delete(db)
                return (true, captured)
            }
        } catch {
            queueLog("[Gone] GRDB delete failed for \(headerId): \(error)")
            return
        }
        guard existed else { return }
        queueLog("[Gone] Deleted header \(headerId) — reason=\(reason)")
        if let captured {
            await MessageContentStore.releaseUnowned(
                captured.contentKey, scope: captured.scope,
                stores: [.searchIndex, .body], pool: dbPool)
        } else {
            // No account row to read a key space from — keep the pre-existing
            // unconditional removal rather than invent an owner. `.body` is part of
            // that pre-existing behaviour: the cascade deleted it here too.
            await MessageContentStore.release(
                ContentKey(rawValue: headerId), stores: [.searchIndex, .body], pool: dbPool)
        }
    }

    /// Deep-dive log for a failing PendingOperation. Gated by `context.diagnosedOpIds`
    /// so it fires at most once per drain per opId. Logs:
    ///   - Full op fields (accountId, folderPath, destinationPath, retryCount, …)
    ///   - Error structural unwrap (ProviderError → HTTPError statusCode, NSError domain/code)
    ///   - Classifier verdicts (isMessageNotFound, isConfirmedGone, isPermanentlyInvalid)
    ///   - DB rows scoped to the exact message + the involved folders:
    ///       * MessageHeader rows for each msgId in the op (any folder, same account)
    ///       * Source Folder row (accountId:folderPath)
    ///       * Destination Folder row (accountId:destinationPath)
    ///       * All Folders with role=.trash for the account (sanity check role lookup)
    func logStuckOpDiagnostic(_ op: PendingOperation, error: Error) async {
        // Log-only helper: gate the WHOLE body, not just the emission. Every
        // `queueLog` below is individually gated too, but this guard is what
        // skips the scoped DB read the dump exists to render — a read whose only
        // consumer is a line that is never rendered while the gate is closed.
        //
        // ⚠️ "while the gate is CLOSED", not "in a shipping build" — an earlier
        // wording of this comment said the latter and it is FALSE.
        // `DebugModeManager.isLoggingEnabled()` is a RUNTIME unlock, not a build
        // configuration, so on a device or TestFlight build belonging to an
        // allowed user who has unlocked debug logging this guard passes, the DB
        // read runs, and the dump IS visible. That is the intended behaviour —
        // this diagnostic exists to be readable in the field. Do not "optimise"
        // it away on the belief that release builds never reach it.
        //
        // The caller's `context.diagnosedOpIds` bookkeeping happens before this
        // call, so returning early changes no control flow there.
        guard DebugModeManager.isLoggingEnabled() else { return }
        let ageHours = Date().timeIntervalSince(op.createdAt) / 3600
        queueLog("[QueueDiag] === op=\(op.id) type=\(op.type.rawValue) ===")
        queueLog("[QueueDiag] op: accountId=\(op.accountId) folderPath=\(op.folderPath) destinationPath=\(op.destinationPath ?? "<nil>") tagValue=\(op.tagValue ?? "<nil>") userLabelId=\(op.userLabelId ?? "<nil>")")
        queueLog("[QueueDiag] op: messageIds=\(op.messageIds) retryCount=\(op.retryCount) uidResolutionRetryCount=\(op.uidResolutionRetryCount) status=\(op.status) ageHours=\(String(format: "%.2f", ageHours))")

        // Error structural unwrap — confirms whether classifiers should/shouldn't match
        queueLog("[QueueDiag] error.type=\(type(of: error)) error=\(error)")
        if case ProviderError.networkError(let underlying) = error {
            queueLog("[QueueDiag] underlying.type=\(type(of: underlying)) underlying=\(underlying)")
            if case HTTPError.networkError(let statusCode) = underlying {
                queueLog("[QueueDiag] HTTPError statusCode=\(statusCode)")
            }
            let ns = underlying as NSError
            queueLog("[QueueDiag] NSError domain=\(ns.domain) code=\(ns.code)")
        }
        queueLog("[QueueDiag] classifier: isMessageNotFoundError=\(AccountOperationExecutor.isMessageNotFoundError(error)) isConfirmedGoneError=\(AccountOperationExecutor.isConfirmedGoneError(error)) isPermanentlyInvalidError=\(AccountOperationExecutor.isPermanentlyInvalidError(error))")

        // Message-scoped DB dump — only rows relevant to this op + its folders.
        do {
            try await dbPool.read { db in
                for msgId in op.messageIds {
                    let normalized = EmailFilter.normalizeMessageId(msgId)
                    let headers = try MessageHeader
                        .filter(
                            (Column("messageId") == msgId || Column("rfc822MessageId") == normalized) &&
                            Column("accountId") == op.accountId
                        )
                        .fetchAll(db)
                    if headers.isEmpty {
                        queueLog("[QueueDiag] MessageHeader: NONE for msgId=\(msgId) normalized=\(normalized) account=\(op.accountId)")
                    } else {
                        for h in headers {
                            queueLog("[QueueDiag] MessageHeader: id=\(h.id) folderId=\(h.folderId) folderPath=\(h.folderPath) messageId=\(h.messageId) rfc822=\(h.rfc822MessageId ?? "<nil>") isInInbox=\(h.isInInbox) isRead=\(h.isRead) actionTag=\(h.actionTag?.rawValue ?? "<nil>")")
                        }
                    }
                }

                let srcId = "\(op.accountId):\(op.folderPath)"
                if let src = try Folder.fetchOne(db, key: srcId) {
                    queueLog("[QueueDiag] Folder(source): id=\(src.id) name=\(src.name) path=\(src.path) role=\(src.role.rawValue)")
                } else {
                    queueLog("[QueueDiag] Folder(source): NONE for id=\(srcId)")
                }

                if let dest = op.destinationPath {
                    let destId = "\(op.accountId):\(dest)"
                    if let f = try Folder.fetchOne(db, key: destId) {
                        queueLog("[QueueDiag] Folder(destination): id=\(f.id) name=\(f.name) path=\(f.path) role=\(f.role.rawValue)")
                    } else {
                        queueLog("[QueueDiag] Folder(destination): NONE for id=\(destId)")
                    }
                }

                let trashFolders = try Folder
                    .filter(Column("accountId") == op.accountId && Column("role") == FolderRole.trash.rawValue)
                    .fetchAll(db)
                if trashFolders.isEmpty {
                    queueLog("[QueueDiag] Folder(role=trash): NONE for account=\(op.accountId)")
                } else {
                    for f in trashFolders {
                        queueLog("[QueueDiag] Folder(role=trash): id=\(f.id) name=\(f.name) path=\(f.path)")
                    }
                }
            }
        } catch {
            queueLog("[QueueDiag] ERROR: scoped DB read failed: \(error)")
        }
        queueLog("[QueueDiag] === end op=\(op.id) ===")
    }




    /// The post-connect queue kick: drain whatever the durable action queue
    /// still owes, then reconcile the outbox and drain the calendar queue.
    ///
    /// 🚨 THIS IS NOT CRASH RECOVERY ANY MORE, and it must never become it
    /// again. The blind whole-table sweep of previous-session residue that used
    /// to open this function now lives in
    /// `AppDatabase.recoverPreviousSessionResidue`, called from
    /// `AppDatabase.init` before the pool is ever published — the only boundary
    /// at which "residue" is provable. It could not stay here: `RootView` calls
    /// this function only AFTER every account has finished connecting, while a
    /// connected account's gestures and the background entry points have already
    /// been draining, so a whole-table sweep here reaches rows this LIVE process
    /// owns. It deleted a `.move` whose proven provider result this process was
    /// still holding for replay, after which the replay dropped that proof as if
    /// the user had wiped the row and the follower went to the wire at an
    /// address Graph had already reallocated (`IOS-GRAPH-005`, #114).
    ///
    /// The name and both callers are unchanged; what changed is that this
    /// function no longer writes anything before it drains.
    func reconcilePendingOperations() async {
        await drainPendingQueue()
        await reconcileOutbox()
        await drainCalendarQueue()
    }
}
