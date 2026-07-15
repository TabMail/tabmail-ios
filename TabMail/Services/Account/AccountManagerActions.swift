/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB

extension AccountManager {

    private struct DurableMessageActionMember: Sendable {
        let header: MessageHeader
        let rfc822MessageId: String
    }

    private struct MarkReadWriteResult: Sendable {
        var affectedFolderIds: Set<String> = []
        var notificationKeys: [(accountId: String, messageId: String)] = []
    }

    /// Pairs the exact row eligible for optimistic mutation with the canonical
    /// RFC identity written to the durable queue. Invalid identities disappear
    /// here, before either side of that contract can occur.
    private nonisolated static func durableMessageActionMembers(
        _ messages: [MessageHeader]
    ) -> [DurableMessageActionMember] {
        messages.compactMap { header in
            guard let address = MessageIdentity.durableActionAddress(
                accountId: header.accountId,
                folderPath: header.folderPath,
                rfc822MessageId: header.rfc822MessageId
            )
            else { return nil }
            return DurableMessageActionMember(
                header: header,
                rfc822MessageId: address.rfc822MessageId
            )
        }
    }

    /// Resolves current durable rows in caller order before admission. This
    /// prevents a stale UI snapshot from supplying either an obsolete source
    /// folder or an identity that is no longer attached to that row.
    private nonisolated static func resolveDurableMessageActionMembers(
        headerIds: [String],
        db: Database
    ) throws -> [DurableMessageActionMember] {
        guard !headerIds.isEmpty else { return [] }
        let rows = try MessageHeader
            .filter(headerIds.contains(Column("id")))
            .fetchAll(db)
        let rowsById = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        return durableMessageActionMembers(headerIds.compactMap { rowsById[$0] })
    }

    // MARK: - Actions (optimistic UI + persistent queue)
    //
    // All actions update GRDB state immediately (optimistic UI) then queue the
    // remote operation for async execution. The queue drains when:
    // - NetworkMonitor detects connection restored
    // - Foreground return (SyncScheduler.startForegroundPolling)
    // - After each successful sync poll
    // - On app launch (reconcilePendingOperations → drainPendingQueue)
    //
    // If the server state changed after queueing (message moved/deleted remotely),
    // the queued operation is dropped (conflict detection in drainPendingQueue).

    /// ADR-IOS-049: before an optimistic action writes GRDB, ensure every target
    /// message is durably in GRDB. A row surfaced in-memory via `.messagesStaged`
    /// (`InboxViewModel.insertStagedRows`) isn't in GRDB yet, so the optimistic UPDATE
    /// would hit 0 rows and the NSE merge would later resurrect it as inbox. Draining
    /// the merge first makes the row real so optimistic-state wins. Cheap indexed
    /// existence read on the action path (NOT the render path); no-op + zero
    /// coordinator hop for the ~all case where every target is already durable.
    func ensureDurable(_ messages: [MessageHeader]) async {
        let anyMissing = (try? await dbPool.read { db -> Bool in
            for m in messages {
                let exists = try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM messageHeader WHERE id = ?)", arguments: [m.id]) ?? false
                if !exists { return true }
            }
            return false
        }) ?? false
        guard anyMissing else { return }
        await NSEMergeCoordinator.shared.merge()
    }

    /// Off-main `MessageHeader` resolution for use INSIDE queued write closures
    /// (`enqueueWrite`) — never on the MainActor gesture path. Mirrors
    /// `InboxViewModel.lookupMessage`'s exact two-step lookup (durable GRDB row,
    /// else the ADR-IOS-049 staged-row synthesis from `NSEDataBridge.latestStagedRows`)
    /// so a gesture on a just-pushed row not yet durable in GRDB still resolves
    /// once its closure runs — one implementation shared by both call sites
    /// instead of a second copy of the two-step logic.
    ///
    /// Ids that resolve to nothing (row genuinely vanished — e.g. deleted by an
    /// earlier queued op) are silently dropped. Callers gate on the returned
    /// array being smaller than `ids` and must not strand any optimistic
    /// overlay entry registered for a dropped id.
    func resolveHeadersForAction(ids: [String]) async -> [MessageHeader] {
        (try? await resolveHeadersForActionThrowing(ids: ids)) ?? []
    }

    /// Throwing variant of `resolveHeadersForAction` (ADR-IOS-058): lets the
    /// fold executor distinguish a genuine DB READ ERROR (throw — keep the
    /// intention records and retry) from a VANISHED row (clean read, id
    /// absent from both durable and staged sources — drop the intent with a
    /// log). The non-throwing wrapper preserves the pre-existing swallow-to-
    /// empty behavior for every legacy caller.
    func resolveHeadersForActionThrowing(ids: [String]) async throws -> [MessageHeader] {
        guard !ids.isEmpty else { return [] }
        let durable = try await dbPool.read { db -> [MessageHeader] in
            try MessageHeader.filter(ids.contains(Column("id"))).fetchAll(db)
        }
        var byId = Dictionary(uniqueKeysWithValues: durable.map { ($0.id, $0) })
        let missingIds = ids.filter { byId[$0] == nil }
        if !missingIds.isEmpty {
            let missingSet = Set(missingIds)
            let staged = NSEDataBridge.latestStagedRows.withLock { rows in
                rows.filter { missingSet.contains($0.headerId) }
            }
            for row in staged { byId[row.headerId] = row.toMessageHeader() }
        }
        // Preserve caller's id order; ids that resolved to nothing are dropped.
        return ids.compactMap { byId[$0] }
    }

    /// Singular convenience over `resolveHeadersForAction(ids:)` for single-message actions.
    func resolveHeaderForAction(id: String) async -> MessageHeader? {
        await resolveHeadersForAction(ids: [id]).first
    }

    func markRead(_ messages: [MessageHeader]) async {
        await ensureDurable(messages)

        let writeResult: MarkReadWriteResult
        do {
            writeResult = try await retryGatedQueueWrite(dbPool, label: "markRead", maxAttempts: 1) { db in
                let resolved = try Self.resolveDurableMessageActionMembers(
                    headerIds: messages.map(\.id),
                    db: db
                )
                let notificationKeys = resolved.map {
                    (accountId: $0.header.accountId, messageId: $0.header.messageId)
                }
                let resolvedHeaders = resolved.map(\.header)
                let expanded = try Self.expandWithSiblingsByRfc822(messages: resolvedHeaders, db: db)
                let actionable = Self.durableMessageActionMembers(expanded)
                let grouped = Dictionary(grouping: actionable) {
                    "\($0.header.accountId)|\($0.header.folderPath)"
                }
                var folderIds: Set<String> = []
                for (_, members) in grouped {
                    let accountId = members[0].header.accountId
                    let folderPath = members[0].header.folderPath
                    let durableIds = members.map(\.rfc822MessageId)
                    let msgIds = members.map(\.header.id)
                    guard let operation = PendingOperation.durableMessageAction(
                        type: .markRead,
                        messageIds: durableIds,
                        accountId: accountId,
                        folderPath: folderPath
                    ) else { continue }
                    let folderId = members[0].header.folderId
                    folderIds.insert(folderId)
                    let newlyRead = try Self.countCurrentlyUnread(msgIds: msgIds, db: db)
                    try MessageHeader.filter(msgIds.contains(Column("id"))).updateAll(db, Column("isRead").set(to: true))
                    if newlyRead > 0 {
                        try db.execute(sql: "UPDATE folder SET unreadCount = MAX(0, unreadCount - ?) WHERE id = ?", arguments: [newlyRead, folderId])
                    }
                    try operation.insert(db)
                }
                return MarkReadWriteResult(
                    affectedFolderIds: folderIds,
                    notificationKeys: notificationKeys
                )
            }
        } catch {
            print("[Queue] ERROR: markRead write failed: \(error)")
            writeResult = MarkReadWriteResult()
        }
        // Clear delivered notifications for messages the user just read
        for key in writeResult.notificationKeys {
            NSEDataBridge.clearNotification(accountId: key.accountId, messageId: key.messageId)
        }
        // Post immediately from actor for responsive sidebar badges, then async recount for accuracy
        Task { @MainActor in
            NotificationCenter.default.post(name: .unreadCountsDidChange, object: nil)
            NotificationCenter.default.post(name: .inboxDataDidChange, object: nil)
        }
        // notifyImmediately: the optimistic write above already decremented
        // folder.unreadCount, so the app-icon badge can update NOW (bg-task
        // protected) — without it, a read→immediate-background leaves the badge
        // stale until the next foreground recount.
        Task { await UnreadCountManager.shared.requestRecount(folderIds: writeResult.affectedFolderIds, notifyImmediately: true) }
        Task { await drainPendingQueue() }
    }

    func markUnread(_ messages: [MessageHeader]) async {
        await ensureDurable(messages)

        let affectedFolderIds: Set<String>
        do {
            affectedFolderIds = try await retryGatedQueueWrite(dbPool, label: "markUnread", maxAttempts: 1) { db in
                // Mirror of markRead: expand to sibling rows in other folders so an
                // unread mark on the inbox copy of a self-send also flips the Sent copy.
                let resolved = try Self.resolveDurableMessageActionMembers(
                    headerIds: messages.map(\.id),
                    db: db
                ).map(\.header)
                let expanded = try Self.expandWithSiblingsByRfc822(messages: resolved, db: db)
                let actionable = Self.durableMessageActionMembers(expanded)
                let grouped = Dictionary(grouping: actionable) {
                    "\($0.header.accountId)|\($0.header.folderPath)"
                }
                var folderIds: Set<String> = []
                for (_, members) in grouped {
                    let accountId = members[0].header.accountId
                    let folderPath = members[0].header.folderPath
                    let durableIds = members.map(\.rfc822MessageId)
                    let msgIds = members.map(\.header.id)
                    guard let operation = PendingOperation.durableMessageAction(
                        type: .markUnread,
                        messageIds: durableIds,
                        accountId: accountId,
                        folderPath: folderPath
                    ) else { continue }
                    // Count unread BEFORE marking unread — fresh DB read to compute delta
                    let folderId = members[0].header.folderId
                    folderIds.insert(folderId)
                    let alreadyUnread = try Self.countCurrentlyUnread(msgIds: msgIds, db: db)
                    let newlyUnread = msgIds.count - alreadyUnread
                    try MessageHeader.filter(msgIds.contains(Column("id"))).updateAll(db, Column("isRead").set(to: false))
                    if newlyUnread > 0 {
                        try db.execute(sql: "UPDATE folder SET unreadCount = unreadCount + ? WHERE id = ?", arguments: [newlyUnread, folderId])
                    }
                    try operation.insert(db)
                }
                return folderIds
            }
        } catch {
            print("[Queue] ERROR: markUnread write failed: \(error)")
            affectedFolderIds = []
        }
        // Post immediately from actor for responsive sidebar badges, then async recount for accuracy
        Task { @MainActor in
            NotificationCenter.default.post(name: .unreadCountsDidChange, object: nil)
            NotificationCenter.default.post(name: .inboxDataDidChange, object: nil)
        }
        // notifyImmediately: optimistic write already adjusted folder.unreadCount,
        // so the badge updates NOW (bg-task protected) and survives a quick background.
        Task { await UnreadCountManager.shared.requestRecount(folderIds: affectedFolderIds, notifyImmediately: true) }
        Task { await drainPendingQueue() }
    }

    // MARK: - Unread Count Helpers

    /// Count currently-unread messages from the DB inside an active transaction.
    /// Always re-reads from DB to avoid stale-snapshot races (e.g., markRead + move
    /// firing as concurrent Tasks — the second write must see the first's committed state).
    private nonisolated static func countCurrentlyUnread(msgIds: [String], db: Database) throws -> Int {
        guard !msgIds.isEmpty else { return 0 }
        let placeholders = msgIds.map { _ in "?" }.joined(separator: ",")
        return try Int.fetchOne(db, sql:
            "SELECT COUNT(*) FROM messageHeader WHERE id IN (\(placeholders)) AND isRead = 0",
            arguments: StatementArguments(msgIds)) ?? 0
    }

    /// Expand a list of messages to also include sibling rows that share the same
    /// `(accountId, rfc822MessageId)` but live in a different folder.
    ///
    /// Why: Gmail (and any IMAP server with shared message storage) represents a
    /// "send to self" as one underlying message that lives in both INBOX and Sent.
    /// On iOS we materialize that as two `MessageHeader` rows (keyed by folderId).
    /// When the user marks one row read, the other row should optimistically flip
    /// too — otherwise the Sent copy looks unread until the next delta sync.
    ///
    /// This is also correct for non-Gmail IMAP servers where self-send creates two
    /// independent UIDs: each sibling becomes its own per-folder group, so the
    /// caller's grouping logic emits a separate `PendingOperation` per folder, and
    /// the drain loop issues the appropriate STORE / API call against each.
    ///
    /// Sync acts as the safety net — if a sibling is missed (e.g., null or stale
    /// `rfc822MessageId`), the next delta sync reconciles it.
    nonisolated static func expandWithSiblingsByRfc822(
        messages: [MessageHeader],
        db: Database
    ) throws -> [MessageHeader] {
        // Group rfc822MessageIds by accountId (sibling lookups never cross accounts).
        var lookups: [String: Set<String>] = [:]
        for msg in messages {
            guard let rfc = msg.rfc822MessageId, !rfc.isEmpty else { continue }
            lookups[msg.accountId, default: []].insert(rfc)
        }
        if lookups.isEmpty { return messages }

        var seenIds = Set(messages.map(\.id))
        var result = messages
        for (accountId, rfcSet) in lookups {
            let rfcArray = Array(rfcSet)
            let placeholders = rfcArray.map { _ in "?" }.joined(separator: ",")
            var args: [DatabaseValueConvertible] = [accountId]
            args.append(contentsOf: rfcArray)
            let siblings = try MessageHeader.fetchAll(
                db,
                sql: "SELECT * FROM messageHeader WHERE accountId = ? AND rfc822MessageId IN (\(placeholders))",
                arguments: StatementArguments(args)
            )
            for sibling in siblings where !seenIds.contains(sibling.id) {
                result.append(sibling)
                seenIds.insert(sibling.id)
            }
        }
        return result
    }

    // MARK: - Optimistic Move (shared by archive, delete, move)

    private struct OptimisticMoveResult: Sendable {
        var affectedFolderIds: Set<String> = []
        var movedHeaderIds: Set<String> = []
        var movedAccountIds: Set<String> = []
    }

    /// Bounded Undo-admission reconciliation (ADR-IOS-060 §8.3/§9.3), called
    /// from inside the SAME gated transaction as the local optimistic
    /// mutation, only when the caller is Undo. Loads every active
    /// (queued/inFlight) row in durable order, NEVER touches the first
    /// (protected) row, and scans the rest newest→oldest for the first row
    /// related to `pendingOperation` (same account, member-set intersects).
    /// That candidate is cancellable only if it is still `queued` and
    /// flipping it EXACTLY equals `pendingOperation` (same op kind, complete
    /// member set, complete source/destination/label) — in which case this
    /// physically deletes the matched row (never `.cancelled`) and, for a
    /// non-reversible-by-deletion setter, would append the inverse (moves
    /// need no inverse row: the message never left). Any other outcome
    /// (no related row, in-flight, partial overlap, mismatched payload)
    /// falls through and the caller inserts `pendingOperation` unmodified —
    /// this function never rewrites, splits, or partially deletes a batch.
    /// Returns whether `pendingOperation`'s admission was fully handled.
    @discardableResult
    private nonisolated static func reconcileUndoAdmission(
        _ pendingOperation: PendingOperation,
        db: Database
    ) throws -> Bool {
        let activeRows = try PendingOperation.fetchAll(
            db,
            sql: "SELECT * FROM pendingOperation WHERE status != ? ORDER BY rowid ASC",
            arguments: [PendingStatus.cancelled.rawValue]
        )
        guard activeRows.first != nil else { return false }
        let ourMemberSet = Set(pendingOperation.messageIds)
        // Scan strictly AFTER the protected first row, newest → oldest. The
        // first row is excluded from consideration entirely, regardless of
        // its account or status — it may already be crossing into execution.
        for candidate in activeRows.dropFirst().reversed() {
            guard candidate.accountId == pendingOperation.accountId else { continue }
            let candidateMemberSet = Set(candidate.messageIds)
            guard !candidateMemberSet.isDisjoint(with: ourMemberSet) else { continue }
            // First related row scanning newest → oldest — stop here
            // regardless of outcome; never consider an older row instead.
            guard candidate.status == PendingStatus.queued.rawValue,
                  candidateMemberSet == ourMemberSet,
                  pendingOperation.matchesFlip(of: candidate)
            else { return false }
            _ = try PendingOperation.deleteOne(db, key: candidate.id)
            if pendingOperation.type == .move {
                // Location transition: deletion is sufficient — the message
                // never left the pre-move location the matched row recorded.
                return true
            }
            // Idempotent state/set operation: the inverse must still be the
            // last durable command that executes.
            try pendingOperation.insert(db)
            return true
        }
        return false
    }

    /// Core optimistic move: reassigns messages to the destination folder in GRDB
    /// and queues the PendingOperation. `actionTag`/`tagSortOrder` are NOT
    /// touched (Round D-0) — the tag is retained across folders and is a
    /// display-time concern only (gated on `isInInbox` at render time).
    /// Unread counts are adjusted inline (same transaction) for immediate UI feedback.
    /// UnreadCountManager async recount serves as safety net.
    /// Ordinary sync independently reconciles provider IDs through RFC identity.
    ///
    /// `isUndo` routes durable admission through `reconcileUndoAdmission`
    /// instead of an unconditional insert (ADR-IOS-060); every other caller
    /// leaves it false and always inserts.
    ///
    /// Returns the affected folder IDs and moved row/account identities from the same
    /// transaction. Provider-specific folder semantics stay behind `EmailProvider`.
    @discardableResult
    private nonisolated static func optimisticMoveToFolder(
        members: [DurableMessageActionMember],
        accountId: String,
        folderPath: String,
        destinationPath: String,
        opType: OperationType,
        isUndo: Bool = false,
        db: Database
    ) throws -> OptimisticMoveResult {
        // Self-move is a no-op — don't create PendingOperation or touch local state.
        // Happens when archiving from All Mail on Gmail (source=dest=__GMAIL_ALL_MAIL__).
        guard folderPath != destinationPath else {
            print("[Queue] Skipping no-op move (source==dest): \(folderPath)")
            return OptimisticMoveResult()
        }
        let msgs = members.map(\.header)
        let durableIds = members.map(\.rfc822MessageId)
        guard let pendingOperation = PendingOperation.durableMessageAction(
            type: opType,
            messageIds: durableIds,
            accountId: accountId,
            folderPath: folderPath,
            destinationPath: destinationPath
        ) else { return OptimisticMoveResult() }

        // Optimistic local update — move to destination folder immediately.
        // Message appears in destination right away; ordinary sync reconciles provider IDs.
        let destFolderId = "\(accountId):\(destinationPath)"
        let destFolder = try Folder.fetchOne(db, key: destFolderId)
        let destIsInbox = destFolder?.role == .inbox

        let msgIds = msgs.map(\.id)
        // Action tags are RETAINED across a folder move (owner decision,
        // 2026-07-14, Round D-0 — supersedes the 2026-07-10 F6 destructive
        // clear). A tag is inbox-scoped PRESENTATION, not an inbox-scoped
        // invariant: every tag renderer already gates display on
        // `isInInbox`, so a message leaving the inbox simply stops showing
        // its chip without losing the underlying value — no different from
        // any other header field. `actionTag`/`tagSortOrder` are therefore
        // left untouched here (they stay mutually consistent because this
        // move doesn't write either column). `sweepStaleActionTags`
        // (SyncEngineMaintenance.swift) remains the only place that reclaims
        // a stale out-of-inbox tag, as periodic disk hygiene — never this
        // move path.
        try MessageHeader.filter(msgIds.contains(Column("id"))).updateAll(db,
            Column("folderId").set(to: destFolderId),
            Column("folderPath").set(to: destinationPath),
            Column("isInInbox").set(to: destIsInbox)
        )

        // Inline unread count update — fresh DB read, not stale snapshot.
        // Re-read isRead from DB to avoid double-decrement when markRead + move race.
        let unreadMoving = try Self.countCurrentlyUnread(msgIds: msgIds, db: db)
        if unreadMoving > 0 {
            let sourceFolderId = msgs[0].folderId
            try db.execute(sql: "UPDATE folder SET unreadCount = MAX(0, unreadCount - ?) WHERE id = ?", arguments: [unreadMoving, sourceFolderId])
            try db.execute(sql: "UPDATE folder SET unreadCount = unreadCount + ? WHERE id = ?", arguments: [unreadMoving, destFolderId])
        }

        if isUndo {
            let reconciled = try Self.reconcileUndoAdmission(pendingOperation, db: db)
            if !reconciled {
                try pendingOperation.insert(db)
            }
        } else {
            try pendingOperation.insert(db)
        }
        print("[Queue] Queued \(opType.rawValue) for \(durableIds.count) msgs: \(folderPath) → \(destinationPath) (account: \(accountId))")
        return OptimisticMoveResult(
            affectedFolderIds: [msgs[0].folderId, destFolderId],
            movedHeaderIds: Set(msgs.map(\.id)),
            movedAccountIds: [accountId]
        )
    }

    /// `isUndo` (ADR-IOS-060) routes this move's durable admission through
    /// the bounded reconciliation formula instead of an unconditional insert.
    /// Only `AccountManager.undoMove`'s own inverse-move dispatch ever passes
    /// `true` — every gesture/tool/notification/settings caller leaves it
    /// false.
    func move(_ messages: [MessageHeader], to destinationPath: String, isUndo: Bool = false) async {
        guard !destinationPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        // Re-resolve fresh headers by id — the single choke point for every
        // surface (swipe, detail view, agent tools, settings bulk-archive).
        // Gesture paths capture `lookupMessage` snapshots at tap time and pass
        // them into queued closures; a second destination-changing gesture on
        // the same message before the first closure commits would otherwise
        // record a PendingOperation against the STALE source folderPath. The
        // provider would correctly find no member there and no-op, silently
        // losing the user's later move unless admission uses current row truth.
        // The write acts on row truth at execution time — same doctrine as
        // the fold executor's own resolve (ADR-IOS-058 `executeFold`) and
        // `recordRoleMove`'s pre-resolve upstream of it; the extra re-resolve
        // here is harmless. Ids that no longer resolve (vanished rows) are
        // dropped from the batch — correct, per `resolveHeadersForAction`'s
        // documented contract.
        let fresh = await resolveHeadersForAction(ids: messages.map(\.id))
        // Observability (audit round 5): resolveHeadersForAction swallows read
        // errors (`try?` → []), so an empty result for a NON-empty input is
        // either all-rows-vanished (legit) or a genuine read failure — in the
        // latter case this drop is the only trace the gesture ever existed.
        // Distinguishing the two needs a throwing resolve variant — recorded
        // as a phase-2 consideration in PLAN_OVERLAY_CALLSITE_AUDIT.md §6.
        if fresh.isEmpty, !messages.isEmpty {
            print("[Queue] WARNING: move(to: \(destinationPath)) resolved 0 of \(messages.count) ids — vanished rows or read failure; nothing queued")
        }
        // Same-folder move is a no-op. Drop those messages here — using FRESH
        // data so a stale caller snapshot whose row already sits at the
        // destination (e.g. an earlier queued move already landed it there)
        // is correctly filtered instead of queuing a pointless/incorrect
        // PendingOperation whose server-side MOVE has provider-dependent
        // effects (e.g. archive-from-Archive).
        let movable = fresh.filter { $0.folderPath != destinationPath }
        let candidates = Self.durableMessageActionMembers(movable)
        guard !candidates.isEmpty else { return }
        await ensureDurable(candidates.map(\.header))

        let moveResult: OptimisticMoveResult
        do {
            moveResult = try await retryGatedQueueWrite(dbPool, label: "move", maxAttempts: 1) { db in
                var result = OptimisticMoveResult()
                let actionable = try Self.resolveDurableMessageActionMembers(
                    headerIds: candidates.map(\.header.id),
                    db: db
                ).filter { $0.header.folderPath != destinationPath }
                let grouped = Dictionary(grouping: actionable) {
                    "\($0.header.accountId)|\($0.header.folderPath)"
                }
                for (_, members) in grouped {
                    let accountId = members[0].header.accountId
                    let folderPath = members[0].header.folderPath
                    let moved = try Self.optimisticMoveToFolder(members: members, accountId: accountId, folderPath: folderPath, destinationPath: destinationPath, opType: .move, isUndo: isUndo, db: db)
                    result.affectedFolderIds.formUnion(moved.affectedFolderIds)
                    result.movedHeaderIds.formUnion(moved.movedHeaderIds)
                    result.movedAccountIds.formUnion(moved.movedAccountIds)
                }
                return result
            }
        } catch {
            print("[Queue] ERROR: move write failed: \(error)")
            moveResult = OptimisticMoveResult()
        }
        Task { @MainActor in
            NotificationCenter.default.post(name: .unreadCountsDidChange, object: nil)
            NotificationCenter.default.post(name: .inboxDataDidChange, object: nil)
        }
        Task {
            await UnreadCountManager.shared.requestRecount(
                folderIds: moveResult.affectedFolderIds
            )
        }
        Task { await drainPendingQueue() }
    }

    func markFlagged(_ messages: [MessageHeader], flagged: Bool) async {
        await ensureDurable(messages)

        do {
            try await retryGatedQueueWrite(dbPool, label: "markFlagged", maxAttempts: 1) { db in
                let actionable = try Self.resolveDurableMessageActionMembers(
                    headerIds: messages.map(\.id),
                    db: db
                )
                let grouped = Dictionary(grouping: actionable) {
                    "\($0.header.accountId)|\($0.header.folderPath)"
                }
                for (_, members) in grouped {
                    let accountId = members[0].header.accountId
                    let folderPath = members[0].header.folderPath
                    let durableIds = members.map(\.rfc822MessageId)
                    guard let operation = PendingOperation.durableMessageAction(
                        type: flagged ? .markFlagged : .markUnflagged,
                        messageIds: durableIds,
                        accountId: accountId,
                        folderPath: folderPath
                    ) else { continue }
                    for msg in members.map(\.header) {
                        try db.execute(sql: "UPDATE messageHeader SET isFlagged = ? WHERE id = ?", arguments: [flagged, msg.id])
                    }
                    try operation.insert(db)
                }
            }
        } catch {
            print("[Queue] ERROR: markFlagged write failed: \(error)")
        }
        Task { @MainActor in NotificationCenter.default.post(name: .inboxDataDidChange, object: nil) }
        Task { await drainPendingQueue() }
    }

    /// Drop messages whose CURRENT folder already has `role` — same-role moves
    /// (archive-from-Archive, delete-from-Trash) are no-ops. Accounts can carry
    /// more than one folder per role (e.g. iCloud "Trash" + "Deleted Messages"),
    /// so the path-equality filter in `move()` alone can't catch these: the
    /// canonical `fetchOne` destination may be the OTHER same-role folder.
    private func messagesNotInRole(_ messages: [MessageHeader], role: FolderRole) async -> [MessageHeader] {
        let folderIds = Set(messages.map(\.folderId))
        let roleFolderIds: Set<String> = (try? await dbPool.read { db in
            let rows = try Folder
                .filter(folderIds.contains(Column("id")) && Column("role") == role.rawValue)
                .fetchAll(db)
            return Set(rows.map(\.id))
        }) ?? []
        guard !roleFolderIds.isEmpty else { return messages }
        return messages.filter { !roleFolderIds.contains($0.folderId) }
    }

    /// Undo never targets a role (its inverse is always an explicit folder —
    /// see `UndoAccountCommand`), so this never needs an `isUndo` parameter.
    func archive(_ messages: [MessageHeader]) async {
        let movable = await messagesNotInRole(messages, role: .archive)
        await moveToRoleFolderPerAccount(movable, role: .archive)
    }

    func delete(_ messages: [MessageHeader]) async {
        guard let first = messages.first else { return }
        AccountManager.logDeleteTrace(accountId: first.accountId, messages: messages, callSite: "AccountManager.delete")
        let movable = await messagesNotInRole(messages, role: .trash)
        await moveToRoleFolderPerAccount(movable, role: .trash)
    }

    /// Resolve the role folder PER ACCOUNT and move each account's messages to
    /// ITS OWN path. The previous implementation resolved the path from only
    /// `movable.first`'s account and applied it to every account in the batch —
    /// a cross-account batch (agent tools and the notification router accept
    /// ids spanning accounts) mis-filed every non-first account's messages
    /// into a folder path that doesn't exist for that account: the row got an
    /// optimistic folderId no real folder backs (message vanishes from that
    /// account's views until the next sync heals it) and a PendingOperation
    /// whose destinationPath is meaningless to that provider (self-heal drop —
    /// the archive/delete never happens server-side). Follow-up-session audit
    /// round 6; pre-existing, reachable via EmailArchiveTool/EmailDeleteTool.
    private func moveToRoleFolderPerAccount(_ movable: [MessageHeader], role: FolderRole) async {
        guard !movable.isEmpty else { return }
        let byAccount = Dictionary(grouping: movable, by: \.accountId)
        for (accountId, accountMessages) in byAccount {
            let path: String? = try? await dbPool.read { db in
                try Folder.filter(Column("accountId") == accountId && Column("role") == role.rawValue)
                    .fetchOne(db)?.path
            }
            guard let path else {
                print("[Queue] ERROR: no \(role.rawValue) folder found for account \(accountId) — \(accountMessages.count) message(s) skipped")
                continue
            }
            await move(accountMessages, to: path)
        }
    }

    // MARK: - Coordinated Tool Actions (agent tools / notifications, ADR-IOS-058)

    /// Archive/delete for agent tools (`EmailArchiveTool`/`EmailDeleteTool`) and the
    /// notification action router — replaces `performCoordinatedRoleMove` (ADR-IOS-058,
    /// plan §9d/§9l step 4). Appends ONE `.move(.role(role))` intention
    /// record for the actionable ids and awaits its fold's durable completion via
    /// `recordAndWait` — tools/notifications report success only after the local GRDB
    /// write + `PendingOperation` insert have landed (same semantics
    /// `performCoordinatedRoleMove`'s awaited continuation provided). No
    /// `UndoService.push` — tools/notifications are deliberately undo-less (plan §9a,
    /// `feedback_undo_stack_scope`). Since no `UndoableAction` ever references this
    /// row, Undo's bounded reconciliation (which only ever runs for an Undo-origin
    /// move) can never touch it either (ADR-IOS-060).
    ///
    /// Still pre-resolves headers for DISPLAY ONLY, mirroring `performCoordinatedRoleMove`'s
    /// former pre-resolve: this is an async non-gesture path (tool/notification
    /// dispatch, not a finger gesture), so a DB read here is fine — contrast the
    /// zero-DB gesture-path contract. Staleness is now handled STRUCTURALLY rather
    /// than by this function's own re-resolve: `executeFold`'s `.role` branch
    /// (`archive()`/`delete()`) re-resolves FRESH headers and re-filters via
    /// `messagesNotInRole` at fold time, so a message the user separately moved
    /// during an unbounded confirmation wait still gets acted on with row truth at
    /// execution, not this pre-resolve snapshot.
    @discardableResult
    func recordRoleMove(ids: [String], role: FolderRole, origin: IntentionOrigin) async -> Set<String> {
        guard !ids.isEmpty else { return [] }
        guard role == .archive || role == .trash else {
            BackgroundSyncLogger.logInbox("[AccountManager] recordRoleMove — unsupported role \(role.rawValue), no-op")
            return []
        }

        // Pre-resolve fresh headers to drop ids that no longer exist or are
        // already in the target role folder, and to look up each account's
        // destination folder for the overlay's display-only folderId. The
        // fold's `.role` branch re-resolves again at execution time — this
        // snapshot is display-only, never trusted for the write itself.
        let preResolved = await resolveHeadersForAction(ids: ids)
        let roleEligible = await messagesNotInRole(preResolved, role: role)
        let movable = Self.durableMessageActionMembers(roleEligible).map(\.header)
        guard !movable.isEmpty else {
            // Observability (audit round 5, carried): callers (agent tools,
            // notification router) report success unconditionally after this
            // await — a silent return here on a read failure
            // (resolveHeadersForAction swallows errors to []) would leave no
            // trace anywhere. Vanished/already-in-role ids are legit no-ops;
            // the log is the only failure correlate.
            print("[Queue] recordRoleMove(\(role.rawValue)): 0 of \(ids.count) ids actionable after resolve/role filter — nothing to do")
            return []
        }

        let accountIds = Set(movable.map(\.accountId))
        let destFolderIdByAccount: [String: String] = (try? await dbPool.read { db -> [String: String] in
            var result: [String: String] = [:]
            for accountId in accountIds {
                if let folder = try Folder
                    .filter(Column("accountId") == accountId && Column("role") == role.rawValue)
                    .fetchOne(db),
                   !folder.path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    result[accountId] = folder.id
                }
            }
            return result
        }) ?? [:]

        // Skip ids whose account has no folder for this role — mirrors
        // archive()/delete()'s own "no archive/trash folder for account" skip
        // (including its ERROR log convention — audit round 5). This filter
        // runs BEFORE the record append below, so a skipped id never enters
        // the journal — no overlay/journal entry to strand.
        let actionable = movable.filter { destFolderIdByAccount[$0.accountId] != nil }
        guard !actionable.isEmpty else {
            print("[Queue] ERROR: recordRoleMove(\(role.rawValue)) — no \(role.rawValue) folder resolved for account(s) \(accountIds.sorted().joined(separator: ",")); \(movable.count) message(s) skipped")
            return []
        }

        var displays: [String: PendingMutation] = [:]
        for msg in actionable {
            guard let destFolderId = destFolderIdByAccount[msg.accountId] else { continue }
            displays[msg.id] = PendingMutation(
                folderId: destFolderId,
                // Display-only hide, NOT a data clear (Round D-0 supersedes
                // the old F6 destructive clear): the tag is retained on the
                // header regardless of folder, but every renderer gates on
                // `isInInbox`, so the pending-drain overlay shows no tag the
                // moment the message LEAVES the inbox — archive/trash
                // destinations are never the inbox, so for this helper's two
                // supported roles "isInInbox on the pre-resolved snapshot" IS
                // "leaving the inbox".
                actionTag: msg.isInInbox ? .some(nil) : nil
            )
        }

        await recordAndWait(
            ids: actionable.map(\.id),
            kind: .move(.role(role)),
            displays: displays,
            origin: origin
        )
        return Set(actionable.map(\.id))
    }

    /// Diagnostic-only: log the trash-folder lookup result and the message(s) being deleted
    /// so we can correlate a delete action with the destinationPath that ends up on the
    /// PendingOperation. Includes every role=.trash candidate to surface duplicate or
    /// cross-account contamination.
    /// `callSite` identifies the entry point (multiple code paths queue a delete).
    static nonisolated func logDeleteTrace(accountId: String, messages: [MessageHeader], callSite: String) {
        let allTrash: [Folder] = (try? AppDatabase.dbPool.read { db in
            try Folder.filter(Column("accountId") == accountId && Column("role") == FolderRole.trash.rawValue)
                .fetchAll(db)
        }) ?? []
        let trashFolder = allTrash.first
        print("[DeleteTrace] \(callSite) — accountId=\(accountId) msgCount=\(messages.count) resolvedTrash=\(trashFolder.map { "id=\($0.id) name=\($0.name) path=\($0.path) role=\($0.role.rawValue)" } ?? "<nil>") trashCandidates=\(allTrash.count)")
        for f in allTrash {
            print("[DeleteTrace] trashCandidate: id=\(f.id) name=\(f.name) path=\(f.path)")
        }
        for m in messages {
            print("[DeleteTrace] msg: id=\(m.id) folderPath=\(m.folderPath) accountId=\(m.accountId) messageId=\(m.messageId) rfc822=\(m.rfc822MessageId ?? "<nil>") stableId=\(m.stableId)")
        }
    }

    // MARK: - Bulk Archive (Settings)

    /// Bulk-archive inbox messages older than `archiveCutoff`, one account
    /// batch at a time. Extracted from `SettingsView.archiveOldMessages`
    /// (test-review round-1, pure code move) — the View computes
    /// `inboxFolderIds`/`archiveCutoff` from its own `navigationStore` state
    /// and keeps its own guards/UI-state updates (`isLargeInbox`,
    /// `oldMessageCount`); this owns the fetch + per-account loop and
    /// returns the archived count.
    ///
    /// `await UndoService.shared.push(...)` below is the one adjustment the
    /// move required: the original call ran on the View's MainActor context
    /// (no hop needed); from inside the `AccountManager` actor, pushing to
    /// the MainActor-isolated `UndoService` crosses an isolation boundary —
    /// same call, same arguments, same order, just an explicit `await`.
    @discardableResult
    func archiveOldInboxMessages(inboxFolderIds: Set<String>, archiveCutoff: Date) async -> Int {
        guard let oldMessages = try? await AppDatabase.dbPool.read({ db in
            try MessageHeader
                .filter(inboxFolderIds.contains(Column("folderId")))
                .filter(Column("date") < archiveCutoff)
                .order(Column("date").asc)
                .fetchAll(db)
        }), !oldMessages.isEmpty else { return 0 }

        let admittedMessages = Self.durableMessageActionMembers(oldMessages).map(\.header)
        guard !admittedMessages.isEmpty else { return 0 }
        let byAccount = Dictionary(grouping: admittedMessages, by: \.accountId)
        var totalArchived = 0

        // Deterministic account order (test-review round 3): Dictionary
        // iteration order is per-process-randomized, which made the
        // per-account skip/abort distinction untestable deterministically —
        // and nondeterministic undo-stack push order is user-visible.
        for accountId in byAccount.keys.sorted() {
            let messages = byAccount[accountId] ?? []
            guard let archivePath = try? await AppDatabase.dbPool.read({ db in
                try Folder.filter(Column("accountId") == accountId && Column("role") == FolderRole.archive.rawValue).fetchOne(db)?.path
            }), !archivePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                print("[ArchiveOld] No archive folder for account \(accountId)")
                continue
            }
            let destFolderId = "\(accountId):\(archivePath)"
            // Undo commands are built from the pre-move headers directly
            // (ADR-IOS-060): no full-row snapshot, no overlay adjustment
            // needed — `UndoMember` carries only rfc822 identity and the
            // pre-move source path, neither of which the overlay affects.
            await UndoService.shared.push(UndoableAction(
                commands: UndoableAction.commands(
                    for: messages,
                    forwardDestinationByAccount: [accountId: archivePath]
                )
            ))
            // ADR-IOS-058: record() replaces the bare `manager.move(...)` call
            // this function used before. BEHAVIOR IMPROVEMENT (audit §9a): this
            // bulk archive previously had NO overlay coverage and bypassed the
            // FIFO write queue entirely (a bare actor call racing every other
            // queued gesture); it now gets both, same as every other archive
            // surface. ONE record covers this account's whole batch: members
            // may span source folders — source grouping is `move()`'s job at
            // execution time. recordAndWait (not fire-and-forget record())
            // preserves this function's pre-existing await-until-committed
            // contract: `totalArchived`/`oldMessageCount` below must reflect
            // completed local writes, not merely enqueued intent.
            var displays: [String: AccountManager.PendingMutation] = [:]
            for msg in messages {
                displays[msg.id] = .init(folderId: destFolderId, actionTag: msg.isInInbox ? .some(nil) : nil)
            }
            await AccountManager.shared.recordAndWait(
                ids: messages.map(\.id),
                kind: .move(.folder(folderId: destFolderId, folderPath: archivePath, isInbox: false)),
                displays: displays,
                origin: .settings
            )
            totalArchived += messages.count
        }

        print("[ArchiveOld] Archived \(totalArchived) messages older than \(SyncConfig.archiveAgeDays) days")
        return totalArchived
    }

    // MARK: - Search

    func search(query: String, account: Account, folder: String, after: Date? = nil, before: Date? = nil, from: String? = nil, to: String? = nil) async throws -> [MessageHeaderInfo] {
        guard let queue = workQueues[account.id] else { throw ProviderError.notConnected }
        return try await queue.execute(priority: .userAction) {
            try await queue.provider.search(query: query, folder: folder, after: after, before: before, from: from, to: to)
        }
    }

    // MARK: - Undo Support (ADR-IOS-060)

    /// Resolve one Undo member's CURRENT row. Two tiers, tried in order:
    ///
    /// 1. By `originalHeaderId` — an ordinary optimistic move (`optimisticMoveToFolder`)
    ///    UPDATEs folderId/folderPath on the EXISTING primary key; it never re-keys the
    ///    row. So the id captured at forward-gesture time is still valid unless an
    ///    INDEPENDENT sync re-key happened in between (Graph/IMAP provider-ID churn) —
    ///    the only case tier 2 exists for. This tier is what makes an Undo dispatched
    ///    while the forward move is STILL only in memory (never durably written) resolve
    ///    to the right row: the id is unaffected by the move not having happened yet.
    /// 2. By normalized RFC Message-ID scoped to `forwardDestinationPath` — the one place
    ///    the forward move is known to have put this message. Used only when tier 1's id
    ///    has vanished (an independent re-key). Zero or multiple matches there mean the
    ///    Undo is stale for this member.
    ///
    /// Never fabricates a row. A member neither tier resolves is dropped — the same
    /// stale-drop rule as any other locally vanished intention.
    private nonisolated static func resolveUndoMember(
        accountId: String,
        forwardDestinationPath: String,
        member: UndoMember,
        db: Database
    ) throws -> MessageHeader? {
        if let row = try MessageHeader.fetchOne(db, key: member.originalHeaderId),
           row.accountId == accountId,
           MessageIdentity.durableActionRFC822MessageId(row.rfc822MessageId) == member.rfc822MessageId,
           // Serial-intent location guard (ADR-IOS-060 §8.2, plan §19): the row
           // is undoable only where serial replay could have left it — at the
           // forward destination (fold already executed) or still at this
           // member's own source (fast tap: the forward fold is pending, the
           // in-memory annihilation case). Anywhere else means an independent
           // newer action (another client, a tool) moved it, and this Undo is
           // stale: never drag a message back from an unrelated folder because
           // undo "probably" owns it.
           row.folderPath == forwardDestinationPath || row.folderPath == member.sourceFolderPath {
            return row
        }
        let storedSpellings = [member.rfc822MessageId, "<\(member.rfc822MessageId)>"]
        let candidates = try MessageHeader
            .filter(
                Column("accountId") == accountId
                    && Column("folderPath") == forwardDestinationPath
                    && storedSpellings.contains(Column("rfc822MessageId"))
            )
            .fetchAll(db)
            .filter {
                MessageIdentity.durableActionRFC822MessageId($0.rfc822MessageId) == member.rfc822MessageId
            }
        guard candidates.count == 1 else { return nil }
        return candidates.first
    }

    /// Execute one account's Undo command: an ORDINARY inverse move through
    /// the same journal/fold/gated-admission path every other move uses
    /// (`origin: .undo`), source/destination swapped (ADR-IOS-060 §8.2). No
    /// snapshot, no token, no receipt, no full-row restore — only the
    /// location changes; any field change made between the forward move and
    /// this Undo (a read toggle, a retag) is left exactly as it is, per
    /// serial-replay semantics.
    ///
    /// A member whose row is not identifiable (`resolveUndoMember` above)
    /// is dropped: no local mutation, no durable work. Returns the dropped
    /// members' pre-move ids (for diagnostics/testing).
    @discardableResult
    func undoMove(
        accountId: String,
        forwardDestinationPath: String,
        members: [UndoMember]
    ) async -> Set<String> {
        guard !members.isEmpty else { return [] }

        let resolved: [(member: UndoMember, header: MessageHeader)]
        do {
            resolved = try await dbPool.read { db in
                try members.compactMap { member -> (UndoMember, MessageHeader)? in
                    guard let header = try Self.resolveUndoMember(
                        accountId: accountId,
                        forwardDestinationPath: forwardDestinationPath,
                        member: member,
                        db: db
                    ) else { return nil }
                    return (member, header)
                }
            }
        } catch {
            print("[UndoStack] ERROR: undoMove resolve failed for account \(accountId): \(error)")
            resolved = []
        }

        let resolvedOriginalIds = Set(resolved.map { $0.member.originalHeaderId })
        let staleOriginalIds = Set(members.map(\.originalHeaderId)).subtracting(resolvedOriginalIds)
        if !staleOriginalIds.isEmpty {
            if DebugModeManager.isLoggingEnabled() {
                print("[UndoStack] undoMove — \(staleOriginalIds.count) member(s) stale (not identifiable, or no longer where the forward move put them): \(staleOriginalIds)")
            }
            // `UndoService.undo()` already posted `.messagesUndone` (PRE-move ids) and
            // returned, so `InboxView.insertUndoneMessages` optimistically re-inserted
            // every member. A member this resolve DROPPED would otherwise linger as a
            // phantom row. Announce the refusals so the list re-reads the DB.
            await MainActor.run {
                NotificationCenter.default.post(name: .inboxDataDidChange, object: Array(staleOriginalIds))
            }
        }
        guard !resolved.isEmpty else { return staleOriginalIds }

        // A member whose row now lives under a DIFFERENT id than the View
        // dismissed (an independent sync re-key between the forward gesture
        // and this Undo — see `outlookArchiveUndoSurvivesGraphResourceIdRekey`)
        // needs its own `.messagesUndone` announcement: `insertUndoneMessages`
        // fetches by id, and the original id no longer exists.
        let rekeyed = resolved.filter { $0.header.id != $0.member.originalHeaderId }.map { $0.header.id }
        if !rekeyed.isEmpty {
            await MainActor.run {
                NotificationCenter.default.post(name: .messagesUndone, object: rekeyed)
            }
        }

        // Group by restore destination — a batch can span source folders.
        var touchedFolderIds: Set<String> = ["\(accountId):\(forwardDestinationPath)"]
        let groups = Dictionary(grouping: resolved) { $0.member.sourceFolderPath }
        for restorePath in groups.keys.sorted() {
            let groupMembers = groups[restorePath] ?? []
            let destFolderId = "\(accountId):\(restorePath)"
            touchedFolderIds.insert(destFolderId)
            let destIsInbox: Bool = (try? await dbPool.read { db in
                try Folder.fetchOne(db, key: destFolderId)?.role == .inbox
            }) ?? false
            var displays: [String: PendingMutation] = [:]
            for (_, header) in groupMembers {
                displays[header.id] = .init(folderId: destFolderId)
            }
            // Fire-and-forget `record()`, not `recordAndWait` — every other
            // gesture entry point (archive/delete/move) returns without
            // waiting for its fold to execute, and Undo is an ordinary
            // gesture (ADR-IOS-060). This also matters structurally: if the
            // forward move this undoes is STILL only in memory (its own fold
            // hasn't run yet), this record must be free to join the SAME
            // connected component without this call blocking on that fold's
            // completion — the in-memory annihilation case (§7.2).
            record(
                ids: groupMembers.map { $0.header.id },
                kind: .move(.folder(folderId: destFolderId, folderPath: restorePath, isInbox: destIsInbox)),
                displays: displays,
                origin: .undo
            )
        }

        Task { @MainActor in NotificationCenter.default.post(name: .unreadCountsDidChange, object: nil) }
        Task { await UnreadCountManager.shared.requestRecount(folderIds: touchedFolderIds) }
        Task { await drainPendingQueue() }
        return staleOriginalIds
    }

    // MARK: - Draft Queue (persistent save/delete)

    /// Look up the Drafts folder path for an account.
    func draftsFolderPath(accountId: String) async throws -> String {
        try await dbPool.read { db in
            try Folder.filter(Column("accountId") == accountId && Column("role") == FolderRole.drafts.rawValue)
                .fetchOne(db)?.path ?? "Drafts"
        }
    }

    /// Queue a draft save to the server's Drafts folder via PendingOperation.
    /// Creates/updates an optimistic MessageHeader in the Drafts folder so the draft
    /// appears immediately in the UI (before IMAP APPEND completes).
    func queueDraftSave(draftId: String, accountId: String) async {
        do {
            let folderPath = try await draftsFolderPath(accountId: accountId)

            // Write transaction returns FTS data for post-transaction indexing.
            let ftsInfo: (record: FTSHeaderRecord, bodyText: String)? = try await retryGatedQueueWrite(dbPool, label: "queueDraftSave", maxAttempts: 1) { db -> (FTSHeaderRecord, String)? in
                // Optimistic MessageHeader — draft appears in Drafts folder immediately.
                // Uses rfc822MessageId for dedup when sync brings in the real IMAP UID.
                guard let draft = try Draft.fetchOne(db, key: draftId) else {
                    print("[Queue] WARNING: Draft \(draftId) not found in DB, skipping queueDraftSave")
                    return nil
                }

                let folderId = "\(accountId):\(folderPath)"
                var rfc822 = draft.rfc822MessageId

                // Adopt the server-synced header if present. This catches the
                // ServerDraftCompose case: a draft was created by server sync
                // with its own rfc822MessageId (from the IMAP/Gmail header)
                // and a server-assigned messageId. Draft.rfc822MessageId on
                // the matched local Draft row is nil, so a naive
                // "generate new rfc822 + create optimistic header" path
                // produces an orphan next to the server-synced header. The
                // sync stale-check then deletes our optimistic orphan, the
                // list reverts to the pre-edit server-synced header, and the
                // user sees stale content.
                //
                // Resolution: if the draft has serverDraftId, find the
                // existing server-synced MessageHeader by its PK and adopt
                // its rfc822MessageId for the Draft row. The update branch
                // below then finds that same header and updates it in place.
                if rfc822 == nil, let sid = draft.serverDraftId {
                    let serverHeaderId = "\(accountId):\(folderPath):\(sid)"
                    if let serverHeader = try MessageHeader.fetchOne(db, key: serverHeaderId),
                       let serverRfc822 = serverHeader.rfc822MessageId,
                       !serverRfc822.isEmpty {
                        rfc822 = serverRfc822
                        try db.execute(
                            sql: "UPDATE draft SET rfc822MessageId = ? WHERE id = ?",
                            arguments: [rfc822, draftId]
                        )
                        print("[Queue] queueDraftSave: adopted rfc822 from server header \(serverHeaderId) → \(serverRfc822)")
                    } else {
                        print("[Queue] queueDraftSave: no server header found for serverDraftId=\(sid) — will generate fresh rfc822")
                    }
                }

                // Generate stable rfc822MessageId if still not assigned (fresh local draft).
                if rfc822 == nil {
                    let domain = accountId.contains("@") ? String(accountId.split(separator: "@").last ?? "tabmail.local") : "tabmail.local"
                    rfc822 = "draft-\(UUID().uuidString)@\(domain)"
                    // Persist to Draft table so pushDraftToServer reuses it
                    try db.execute(sql: "UPDATE draft SET rfc822MessageId = ? WHERE id = ?", arguments: [rfc822, draftId])
                }
                // Placeholder messageId — will be replaced by real IMAP UID via rfc822MessageId dedup in sync
                let placeholderMsgId = "draft-\(draftId)"
                let headerId = "\(accountId):\(folderPath):\(placeholderMsgId)"
                let senderAccount = try Account.fetchOne(db, key: accountId)
                let senderEmail = senderAccount?.emailAddress ?? accountId
                let senderDisplayName = senderAccount?.displayName ?? senderEmail
                let snippet = EmailFilter.snippetFromPlainText(draft.body)
                let dateMs = Int64(draft.updatedAt * 1000)

                var capturedHeaderId: String
                var capturedMessageId: String

                // Lookup strategy:
                //   1. By rfc822MessageId — the primary dedup key across sync/optimistic paths.
                //   2. By serverDraftId (constructed PK) — catches the ServerDraftCompose
                //      case where a local Draft row exists but its rfc822MessageId wasn't
                //      adopted above (e.g. server header was deleted but Draft persisted).
                var lookedUp = try MessageHeader
                    .filter(Column("folderId") == folderId && Column("rfc822MessageId") == rfc822)
                    .fetchOne(db)
                if lookedUp == nil, let sid = draft.serverDraftId {
                    lookedUp = try MessageHeader.fetchOne(
                        db, key: "\(accountId):\(folderPath):\(sid)"
                    )
                }
                if var existing = lookedUp {
                    // Update existing header (either optimistic or server-synced) in place —
                    // this is the snippet/subject/recipient refresh path. No orphan created.
                    print("[Queue] queueDraftSave: updating existing header id=\(existing.id) msgId=\(existing.messageId) rfc822=\(existing.rfc822MessageId ?? "nil") → newSnippet=\(String(snippet.prefix(60)))")
                    existing.subject = draft.subject
                    existing.to = draft.toArray.joined(separator: ", ")
                    existing.snippet = snippet
                    existing.date = Date(timeIntervalSince1970: draft.updatedAt)
                    // Ensure rfc822MessageId is populated so subsequent syncs can dedup.
                    if existing.rfc822MessageId == nil || existing.rfc822MessageId?.isEmpty == true {
                        existing.rfc822MessageId = rfc822
                    }
                    try existing.update(db)
                    // Update body so draft content is viewable immediately
                    let htmlBody = MessageBody.plainTextToHTML(draft.body)
                    let body = MessageBody(headerId: existing.id, htmlContent: htmlBody)
                    try body.save(db)
                    capturedHeaderId = existing.id
                    capturedMessageId = existing.messageId
                } else {
                    print("[Queue] queueDraftSave: no existing header found — creating optimistic with placeholder=\(placeholderMsgId) rfc822=\(rfc822 ?? "nil") serverDraftId=\(draft.serverDraftId ?? "nil")")
                    var header = MessageHeader(
                        messageId: placeholderMsgId,
                        subject: draft.subject,
                        from: senderDisplayName,
                        fromAddress: senderEmail,
                        to: draft.toArray.joined(separator: ", "),
                        date: Date(timeIntervalSince1970: draft.updatedAt),
                        snippet: snippet,
                        folderId: folderId,
                        accountId: accountId,
                        folderPath: folderPath,
                        isInInbox: false
                    )
                    header.rfc822MessageId = rfc822
                    header.cc = draft.ccArray.joined(separator: ", ")
                    header.bcc = draft.bccArray.joined(separator: ", ")
                    header.isRead = true // Drafts are always read
                    try header.insert(db)

                    // Also create MessageBody so draft content is viewable
                    let htmlBody = MessageBody.plainTextToHTML(draft.body)
                    let body = MessageBody(headerId: headerId, htmlContent: htmlBody)
                    try body.save(db)
                    capturedHeaderId = headerId
                    capturedMessageId = placeholderMsgId
                }

                // Include both draftId (for drain execution) and placeholder messageId
                // (for pendingAllIds protection). The stale check uses pendingAllIds to
                // protect optimistic headers from deletion while the push is pending.
                // This is critical for offline support — the drain can't run until
                // back online, but sync might try to clean up the placeholder.
                let opPlaceholder = "draft-\(draftId)"
                var opMsgIds = [draftId, opPlaceholder]
                // Also include rfc822MessageId for rfc822-based protection matching
                // (rfc822 is guaranteed non-nil here — either from draft or freshly generated)
                if let rfc822Id = rfc822 {
                    opMsgIds.append(rfc822Id)
                }
                try PendingOperation(
                    type: .saveDraft,
                    messageIds: opMsgIds,
                    accountId: accountId,
                    folderPath: folderPath
                ).insert(db)

                return (FTSHeaderRecord(
                    headerId: capturedHeaderId,
                    messageId: capturedMessageId,
                    subject: draft.subject,
                    from: "\(senderDisplayName) <\(senderEmail)>",
                    to: draft.toArray.joined(separator: ", "),
                    cc: draft.ccArray.joined(separator: ", "),
                    bcc: draft.bccArray.joined(separator: ", "),
                    dateMs: dateMs,
                    folderId: folderId
                ), draft.body)
            }

            // FTS indexing + headerComplete — runs after GRDB write succeeds.
            // Each step is independently caught so a failure in one doesn't block the others.
            // Priority: headerComplete=1 (visibility) > FTS body (searchability) > FTS header.
            if let ftsInfo {
                do {
                    _ = try await SearchIndex.shared.indexHeaders([ftsInfo.record])
                    if !ftsInfo.bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        _ = try await SearchIndex.shared.updateBodies([(headerId: ftsInfo.record.headerId, body: ftsInfo.bodyText)])
                    }
                } catch {
                    print("[Queue] WARNING: FTS indexing failed for draft \(ftsInfo.record.headerId): \(error)")
                }
                // Always set headerComplete=1 so the draft appears in folder queries,
                // regardless of whether FTS succeeded. Caught separately so notification
                // still fires even if this write fails (draft stays at headerComplete=0
                // but user gets the reload signal).
                do {
                    try await dbPool.write { db in
                        try db.execute(
                            sql: "UPDATE messageHeader SET headerComplete = 1 WHERE id = ?",
                            arguments: [ftsInfo.record.headerId]
                        )
                    }
                } catch {
                    print("[Queue] WARNING: headerComplete write failed for draft \(ftsInfo.record.headerId): \(error)")
                }
            }

            // Always post reload notification — even if FTS or headerComplete failed,
            // the GRDB header + body exist and may become visible on retry.
            NotificationCenter.default.post(name: .inboxDataDidChange, object: nil)
        } catch {
            print("[Queue] ERROR: queueDraftSave failed: \(error)")
        }
        Task { await drainPendingQueue() }
    }

    /// Queue a draft delete from the server's Drafts folder via PendingOperation.
    /// Optimistically removes the MessageHeader from the Drafts folder immediately.
    /// Requires the serverDraftId (IMAP UID / Gmail ID) from the Draft record.
    /// Pass rfc822MessageId to also remove optimistic headers (which use placeholder messageIds).
    func queueDraftDelete(serverDraftId: String, accountId: String, rfc822MessageId: String? = nil) async {
        do {
            let folderPath = try await draftsFolderPath(accountId: accountId)
            try await retryGatedQueueWrite(dbPool, label: "queueDraftDelete", maxAttempts: 1) { db in
                // Optimistic removal — draft disappears from UI immediately
                let folderId = "\(accountId):\(folderPath)"
                // Remove by server UID (synced header)
                let serverId = "\(accountId):\(folderPath):\(serverDraftId)"
                if try MessageHeader.deleteOne(db, key: serverId) {
                    _ = try? MessageBody.deleteOne(db, key: serverId)
                }
                // Also remove optimistic header by rfc822MessageId (placeholder UID)
                if let rfc822 = rfc822MessageId {
                    let optimistic = try MessageHeader
                        .filter(Column("folderId") == folderId && Column("rfc822MessageId") == rfc822)
                        .fetchAll(db)
                    for header in optimistic {
                        _ = try? MessageBody.deleteOne(db, key: header.id)
                        try header.delete(db)
                    }
                }

                // Include rfc822MessageId in the PendingOperation messageIds so
                // sync protection (pendingAllIds) prevents re-inserting a stale draft
                // from the server during the brief window before .deleteDraft drains.
                // Matches the protection pattern in queueDraftSave.
                var opMsgIds = [serverDraftId]
                if let rfc822 = rfc822MessageId {
                    opMsgIds.append(rfc822)
                }
                try PendingOperation(
                    type: .deleteDraft,
                    messageIds: opMsgIds,
                    accountId: accountId,
                    folderPath: folderPath
                ).insert(db)
            }
            // Refresh UI so the optimistic removal is visible immediately.
            NotificationCenter.default.post(name: .inboxDataDidChange, object: nil)
        } catch {
            print("[Queue] ERROR: queueDraftDelete failed: \(error)")
        }
        Task { await drainPendingQueue() }
    }

    /// Remove optimistic draft MessageHeader (no server op needed — draft was never pushed).
    func removeOptimisticDraftHeader(accountId: String, rfc822MessageId: String) async {
        do {
            let folderPath = try await draftsFolderPath(accountId: accountId)
            let folderId = "\(accountId):\(folderPath)"
            try await dbPool.write { db in
                let headers = try MessageHeader
                    .filter(Column("folderId") == folderId && Column("rfc822MessageId") == rfc822MessageId)
                    .fetchAll(db)
                for header in headers {
                    _ = try? MessageBody.deleteOne(db, key: header.id)
                    try header.delete(db)
                }
            }
        } catch {
            print("[Queue] ERROR: removeOptimisticDraftHeader failed: \(error)")
        }
    }

}
