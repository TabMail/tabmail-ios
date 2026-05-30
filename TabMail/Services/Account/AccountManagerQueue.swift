/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB

extension AccountManager {

    // MARK: - Persistent Action Queue

    /// Queue an action tag write for async execution.
    /// Called from AI processing and manual tag application.
    /// Static + nonisolated: the GRDB write is thread-safe and doesn't need MainActor.
    /// Callers can call directly without `await MainActor.run { ... }`.
    nonisolated static func queueTagWrite(accountId: String, messageId: String, rfc822MessageId: String? = nil, tag: ActionTag?, folder: String) {
        // Prefer rfc822MessageId for IMAP messages (numeric UIDs) — survives UIDVALIDITY changes
        let stableId: String
        if UInt32(messageId) != nil, let rfc822 = rfc822MessageId, !rfc822.isEmpty {
            stableId = rfc822
        } else {
            stableId = messageId
        }
        let opType: OperationType = tag != nil ? .setTag : .removeTag
        let op = PendingOperation(type: opType, messageIds: [stableId], accountId: accountId, folderPath: folder, tagValue: tag?.rawValue)
        do {
            try AppDatabase.dbPool.write { db in try op.insert(db) }
        } catch {
            print("[Queue] ERROR: queueTagWrite failed: \(error)")
        }
        Task { @MainActor in await AccountManager.shared.drainPendingQueue() }
    }

    /// Shared mutable state for parallel drain tasks. All access on @MainActor.
    /// Reference type so concurrent @MainActor tasks see each other's updates at await points.
    private class DrainContext: @unchecked Sendable {
        var failedAccounts = Set<String>()
        var foldersToSync: Set<String> = []
        var executedAny = false
        // op.id values that have already produced a [QueueDiag] deep-dump this drain.
        // Prevents log-spam on the same stuck op that retries every drain cycle.
        var diagnosedOpIds: Set<String> = []
    }

    /// Drain all queued operations with per-message parallelism.
    ///
    /// Ops are grouped into per-message "lanes" keyed by first messageId. Each lane
    /// is a FIFO — ops for the same message execute sequentially (preserving ordering
    /// like removeTag→move). The drain runs the head of every lane concurrently,
    /// so ops for different messages make progress in parallel.
    ///
    /// Provider-level concurrency is managed by each provider (IMAP connection pool, HTTP pooling).
    ///
    /// Re-fetches after each pass to pick up ops inserted during the drain.
    /// Skips drain when offline to prevent retry storms.
    func drainPendingQueue() async {
        guard !isDraining else {
            needsRedrain = true
            return
        }
        guard NetworkMonitor.checkConnected() else { return }
        isDraining = true
        defer {
            isDraining = false
            if needsRedrain {
                needsRedrain = false
                Task { await drainPendingQueue() }
            }
        }

        pruneRecentlyCompleted()
        let ctx = DrainContext()

        // Max 3 passes to pick up ops inserted during drain.
        for pass in 0..<3 {
            let ops: [PendingOperation]
            do {
                ops = try await dbPool.read({ db in
                    try PendingOperation.order(Column("createdAt").asc).fetchAll(db)
                })
            } catch {
                print("[Queue] ERROR: Failed to fetch pending ops: \(error)")
                break
            }
            guard !ops.isEmpty else { break }

            if pass == 0 {
                let summary = ops.map { "\($0.type.rawValue)(\($0.messageIds.count)msgs)" }.joined(separator: ", ")
                print("[Queue] Draining \(ops.count) ops: \(summary)")
            } else {
                print("[Queue] Drain pass \(pass + 1): \(ops.count) ops remaining/new")
            }

            // Claim all valid ops, building per-message lanes (nested queues).
            // Key = "accountId:firstMessageId" — ops for the same message stay in FIFO order.
            var lanes: [String: [PendingOperation]] = [:]
            for op in ops {
                if ctx.failedAccounts.contains(op.accountId) { continue }
                guard providers[op.accountId] != nil else {
                    print("[Queue] No provider for \(op.accountId) — skipping \(op.type.rawValue)")
                    continue
                }

                let currentOp: PendingOperation?
                do {
                    currentOp = try await dbPool.write { db -> PendingOperation? in
                        guard var fetched = try PendingOperation.fetchOne(db, key: op.id) else {
                            return nil
                        }
                        if fetched.status == PendingStatus.cancelled.rawValue {
                            _ = try PendingOperation.deleteOne(db, key: fetched.id)
                            print("[Queue] Op \(op.id.prefix(8)) cancelled by undo, deleted")
                            return nil
                        }
                        if fetched.status == PendingStatus.inFlight.rawValue {
                            return nil
                        }
                        fetched.status = PendingStatus.inFlight.rawValue
                        try fetched.save(db)
                        return fetched
                    }
                } catch {
                    print("[Queue] ERROR: Failed to claim op \(op.id): \(error)")
                    continue
                }
                guard let currentOp else { continue }
                let key = "\(currentOp.accountId):\(currentOp.messageIds.first ?? currentOp.id)"
                lanes[key, default: []].append(currentOp)
            }

            guard !lanes.isEmpty else { break }

            // Launch one Task per lane. Each task drains its lane sequentially.
            // Different lanes (different messages) run concurrently.
            var tasks: [Task<Void, Never>] = []
            for (_, lane) in lanes {
                let capturedLane = lane
                let capturedCtx = ctx
                let task = Task { [self] in
                    for op in capturedLane {
                        if capturedCtx.failedAccounts.contains(op.accountId) {
                            try? await retryWrite(dbPool, label: "Queue") { db in
                                var updated = op
                                updated.status = PendingStatus.queued.rawValue
                                try updated.save(db)
                            }
                            continue
                        }
                        guard let queue = self.workQueues[op.accountId] else {
                            try? await retryWrite(dbPool, label: "Queue") { db in
                                var updated = op
                                updated.status = PendingStatus.queued.rawValue
                                try updated.save(db)
                            }
                            continue
                        }
                        let provider = queue.provider
                        await queue.execute(priority: .userAction) {
                            await self.executeSingleOp(op, provider: provider, context: capturedCtx)
                        }
                    }
                }
                tasks.append(task)
            }
            for task in tasks { await task.value }

            if !ctx.executedAny { break }
            ctx.executedAny = false
        }

        // Post-drain: sync destination folders so new UIDs are picked up immediately.
        if !ctx.foldersToSync.isEmpty {
            print("[MoveTrace] post-drain sync — syncing \(ctx.foldersToSync.count) destination folders: \(ctx.foldersToSync)")
            for key in ctx.foldersToSync {
                let parts = key.split(separator: "|", maxSplits: 1)
                guard parts.count == 2 else { continue }
                let accountId = String(parts[0])
                let folderPath = String(parts[1])
                guard let queue = workQueues[accountId] else { continue }
                guard let folder = try? await dbPool.read({ db in
                    try Folder.filter(Column("accountId") == accountId && Column("path") == folderPath).fetchOne(db)
                }) else {
                    print("[MoveTrace] post-drain sync — folder not found: \(accountId)|\(folderPath)")
                    continue
                }
                do {
                    try await queue.execute(priority: .userAction) {
                        try await self.syncEngine.syncFolderMessages(folder: folder, provider: queue.provider)
                    }
                    print("[MoveTrace] post-drain sync — completed for \(folder.name)")
                } catch {
                    print("[MoveTrace] post-drain sync — failed for \(folder.name): \(error)")
                }
            }
        }
    }

    /// Execute a single claimed op against its provider. Updates shared DrainContext
    /// with results (executedAny, failedAccounts, foldersToSync, recentActions).
    private func executeSingleOp(_ currentOp: PendingOperation, provider: any EmailProvider, context: DrainContext) async {
        let opType = currentOp.type.rawValue
        let opMsgCount = currentOp.messageIds.count

        do {
            try await withTimeout(seconds: SyncConfig.pendingOperationTimeoutSeconds) {
                try await self.executeOperation(currentOp, provider: provider)
            }
            // TOCTOU fix: record recentActions BEFORE deleting PendingOp.
            // Sync engine has two guards against re-inserting moved messages:
            //   1. pendingDestructiveIds — read inside the sync write transaction
            //   2. recentMoveIdsByFolder — snapshot from actor before the sync write
            // If we delete the PendingOp first and record recentAction after, there's
            // a window where neither guard is active (PendingOp gone from DB, recentAction
            // not yet on actor). By recording recentAction first, at every instant at least
            // one guard is active:
            //   - Before step 3 (delete): PendingOp in DB → pendingDestructiveIds catches it
            //   - After step 2 (record): recentAction on actor → recentMoveIdsByFolder catches it
            // If app crashes between steps 2 and 3, the PendingOp re-executes (idempotent).

            // Step 1: Collect rfc822MessageIds (read-only, separate from delete).
            var actionInfos: [(String, String?, String?)] = [] // (opMsgId, rfc822MessageId, numericMessageId)
            let trackedTypes: Set<OperationType> = [
                .archive, .delete, .move,
                .markRead, .markUnread, .markFlagged, .markUnflagged, .setTag, .removeTag
            ]
            if trackedTypes.contains(currentOp.type) {
                do {
                    actionInfos = try await dbPool.read { db -> [(String, String?, String?)] in
                        var infos: [(String, String?, String?)] = []
                        for msgId in currentOp.messageIds {
                            let normalizedMsgId = EmailFilter.normalizeMessageId(msgId)
                            let header = try MessageHeader
                                .filter(
                                    (Column("messageId") == msgId || Column("rfc822MessageId") == normalizedMsgId) &&
                                    Column("accountId") == currentOp.accountId
                                )
                                .fetchOne(db)
                            infos.append((msgId, header?.rfc822MessageId, header?.messageId))
                        }
                        return infos
                    }
                } catch {
                    print("[Queue] WARNING: Failed to collect rfc822 info for \(currentOp.id): \(error)")
                }
            }

            // Step 2: Record in recentlyCompleted (30s TTL) BEFORE deleting PendingOp.
            // Bridges the gap between PendingOp deletion and server-side state propagation.
            // This ensures sync engine always sees the protection entry.
            var completedIds: [String] = []
            for (msgId, rfc822, numericId) in actionInfos {
                completedIds.append(msgId)
                if let rfc822 { completedIds.append(rfc822) }
                if let numericId, numericId != msgId { completedIds.append(numericId) }
            }
            recordRecentlyCompleted(messageIds: completedIds)

            // Step 3: Delete PendingOp. MUST succeed — remote op already completed.
            // If we don't delete, it re-executes on next drain (idempotent but wasteful).
            do {
                try await retryWrite(dbPool, label: "Queue") { db in
                    _ = try PendingOperation.deleteOne(db, key: currentOp.id)
                }
            } catch {
                print("[Queue] CRITICAL: Failed to delete completed PendingOperation \(currentOp.id) after retries — will re-execute on next drain")
            }
            if [.archive, .delete, .move].contains(currentOp.type), let dest = currentOp.destinationPath {
                context.foldersToSync.insert("\(currentOp.accountId)|\(dest)")
            }
            // Sync Drafts folder after draft save/delete so MessageHeaders reflect server state.
            // After saveDraft: the sync's UID remap detection matches our optimistic header
            // (placeholder messageId) to the real server header by rfc822MessageId, migrating
            // the header in-place and preserving the body + local state.
            if [.saveDraft, .deleteDraft].contains(currentOp.type) {
                context.foldersToSync.insert("\(currentOp.accountId)|\(currentOp.folderPath)")
            }
            context.executedAny = true
        } catch {
            // UID resolution failed on tag ops — skip (best-effort).
            // Tag removal is queued before move to prevent flag copying on IMAP MOVE.
            // If we can't resolve the UID, skipping the tag op is far better than
            // blocking the entire account's drain (including the actual archive/move).
            if case ProviderError.uidResolutionFailed = error,
               [.setTag, .removeTag].contains(currentOp.type) {
                print("[Queue] Tag op UID resolution failed for \(currentOp.messageIds.first ?? "?") — skipping (best-effort)")
                try? await retryWrite(dbPool, label: "Queue") { db in
                    _ = try PendingOperation.deleteOne(db, key: currentOp.id)
                }
                context.executedAny = true
                return
            }
            if isMessageNotFoundError(error) {
                if currentOp.messageIds.count > 1 {
                    // Batch op hit messageNotFound — one message is gone but others
                    // may still need processing. Split into individual single-message
                    // ops so each can succeed/fail independently.
                    print("[Queue] Conflict in batch \(opType) (\(opMsgCount) msgs) — splitting into individual ops")
                    do {
                        try await dbPool.write { db in
                            for msgId in currentOp.messageIds {
                                try PendingOperation(type: currentOp.type, messageIds: [msgId], accountId: currentOp.accountId, folderPath: currentOp.folderPath, destinationPath: currentOp.destinationPath, tagValue: currentOp.tagValue).insert(db)
                            }
                            _ = try PendingOperation.deleteOne(db, key: currentOp.id)
                        }
                    } catch {
                        print("[Queue] Failed to split batch op \(currentOp.id): \(error) — batch will retry as-is")
                    }
                    context.executedAny = true
                    return
                }
                // Single-message conflict — drop (server wins)
                print("[Queue] Conflict: \(opType) — message not found, dropping")
                try? await retryWrite(dbPool, label: "Queue") { db in
                    _ = try PendingOperation.deleteOne(db, key: currentOp.id)
                }
                // If the error was a structurally-confirmed permanent gone (HTTP 404/410
                // or ProviderError.messageNotFound), also delete the local header. The
                // message is verified gone on the server; retaining a ghost row causes
                // other queues (body fetch, AI) to retry forever.
                // We deliberately DO NOT delete on the string-matching branch of
                // isMessageNotFoundError — too risky for false positives.
                if isConfirmedGoneError(error), let msgId = currentOp.messageIds.first {
                    // Scope delete to the exact (account, folder, messageId) row — broader
                    // matches risk deleting unrelated messages that happen to share a UID
                    // in a different IMAP folder.
                    let hid = MessageIdentity.headerId(accountId: currentOp.accountId, folderPath: currentOp.folderPath, messageId: msgId)
                    await deleteConfirmedGoneHeader(headerId: hid, reason: "\(opType) 404")
                }
                context.executedAny = true
                return
            }
            // Permanently invalid operation — drop immediately (will never succeed on retry).
            // E.g., Gmail "Invalid label: DRAFT" when a .move op tried to remove the DRAFT label.
            if isPermanentlyInvalidError(error) {
                print("[Queue] Permanently invalid \(opType): \(error) — dropping")
                try? await retryWrite(dbPool, label: "Queue") { db in
                    _ = try PendingOperation.deleteOne(db, key: currentOp.id)
                }
                context.executedAny = true
                return
            }
            // UID resolution failed — message not found in source folder via IMAP SEARCH.
            // Confirm staleness by checking destination (for move ops) or drop (for flag ops).
            if case ProviderError.uidResolutionFailed(let failedId) = error {
                // Batch ops: split into singles so each can be confirmed independently.
                if currentOp.messageIds.count > 1 {
                    print("[Queue] UID resolution failed in batch \(opType) (\(opMsgCount) msgs) — splitting into individual ops")
                    do {
                        try await dbPool.write { db in
                            for msgId in currentOp.messageIds {
                                try PendingOperation(type: currentOp.type, messageIds: [msgId], accountId: currentOp.accountId, folderPath: currentOp.folderPath, destinationPath: currentOp.destinationPath, tagValue: currentOp.tagValue).insert(db)
                            }
                            _ = try PendingOperation.deleteOne(db, key: currentOp.id)
                        }
                    } catch {
                        print("[Queue] Failed to split batch op \(currentOp.id): \(error) — batch will retry as-is")
                    }
                    context.executedAny = true
                    return
                }

                // Single-message op: confirm staleness.
                if let dest = currentOp.destinationPath, currentOp.type == .move,
                   let imapProvider = provider as? IMAPProvider {
                    // Move op on IMAP: check if message is in destination folder.
                    // Found → confirmed done. Not found → confirmed stale (can't recover). Either way, drop.
                    // Connection error → can't confirm, fall through to retry.
                    do {
                        let existsInDest = try await imapProvider.messageExistsInFolder(rfc822MessageId: failedId, folderPath: dest)
                        if existsInDest {
                            print("[Queue] Confirmed done: \(opType) \(failedId) — already in destination \(dest), dropping")
                        } else {
                            print("[Queue] Confirmed stale: \(opType) \(failedId) — not in source \(currentOp.folderPath) or destination \(dest), dropping")
                        }
                        try? await retryWrite(dbPool, label: "Queue") { db in
                            _ = try PendingOperation.deleteOne(db, key: currentOp.id)
                        }
                        context.executedAny = true
                        return
                    } catch {
                        // If destination folder itself doesn't exist (NONEXISTENT, etc.),
                        // the message can't be in it — confirmed stale.
                        let destCheckDesc = "\(error)"
                        if destCheckDesc.contains("NONEXISTENT") || destCheckDesc.contains("does not exist") || destCheckDesc.contains("Mailbox doesn't exist") {
                            print("[Queue] Confirmed stale: \(opType) \(failedId) — not in source \(currentOp.folderPath), destination \(dest) no longer exists, dropping")
                            try? await retryWrite(dbPool, label: "Queue") { db in
                                _ = try PendingOperation.deleteOne(db, key: currentOp.id)
                            }
                            context.executedAny = true
                            return
                        }
                        print("[Queue] UID resolution failed for \(opType) \(failedId), destination check failed: \(error) — will retry")
                    }
                } else if currentOp.type != .move {
                    // Flag/mark op: message not in folder, flag change is moot — drop.
                    print("[Queue] Confirmed stale: \(opType) \(failedId) — message not in folder \(currentOp.folderPath), dropping")
                    try? await retryWrite(dbPool, label: "Queue") { db in
                        _ = try PendingOperation.deleteOne(db, key: currentOp.id)
                    }
                    context.executedAny = true
                    return
                }

                // Fall through: retry (destination check failed or non-IMAP move provider)
                print("[Queue] UID resolution failed for \(opType) \(currentOp.messageIds.first ?? "?") — will retry (not blocking account)")
                try? await retryWrite(dbPool, label: "Queue") { db in
                    var updated = currentOp
                    updated.status = PendingStatus.queued.rawValue
                    try updated.save(db)
                }
                return
            }
            // Connection/transient error — reset op to queued and mark account failed.
            // NEVER drop on age alone — transient errors don't confirm the op is stale.
            // Staleness is confirmed by: messageNotFound (server says gone), or
            // uidResolutionFailed + destination check (not in source or destination).
            // failedAccounts prevents hammering within a single drain.
            let ageHours = Date().timeIntervalSince(currentOp.createdAt) / 3600
            print("[Queue] Failed \(opType): \(error) (age \(String(format: "%.1f", ageHours))h) — will retry")
            // Deep diagnostic on the failing op — fires once per (drain, opId) so a
            // stuck op that retries every drain doesn't fill the log. Dumps full op
            // fields, error structural unwrap, classifier results, and the DB rows
            // scoped to the exact message + the involved folders.
            if !context.diagnosedOpIds.contains(currentOp.id) {
                context.diagnosedOpIds.insert(currentOp.id)
                await logStuckOpDiagnostic(currentOp, error: error)
            }
            // Self-heal: a .move op whose destination Folder doesn't exist locally
            // is unsalvageable on retry. This happens when the account's folder list
            // was re-ingested (e.g., IMAP→OAuth migration changing "Deleted Messages"
            // → "TRASH") after the op was queued, leaving the op pointing at an
            // obsolete path. Drop the op rather than retry forever — the original
            // user intent ("remove from source folder") is honored by remote-state-
            // wins-on-conflict (ADR-IOS-001): if server already moved/deleted the
            // message, sync brings the truth in; if not, the user can re-issue.
            if currentOp.type == .move, let destPath = currentOp.destinationPath {
                let destMissing: Bool = (try? await dbPool.read { db in
                    try Folder.fetchOne(db, key: "\(currentOp.accountId):\(destPath)") == nil
                }) ?? false
                if destMissing {
                    print("[Queue] Self-heal: dropping \(opType) — destination Folder missing locally: \(currentOp.accountId):\(destPath)")
                    try? await retryWrite(dbPool, label: "Queue") { db in
                        _ = try PendingOperation.deleteOne(db, key: currentOp.id)
                    }
                    context.executedAny = true
                    return
                }
            }
            try? await retryWrite(dbPool, label: "Queue") { db in
                var updated = currentOp
                updated.status = PendingStatus.queued.rawValue
                // Bump retryCount on each failure so the value matches reality (and
                // is visible in [QueueDiag] dumps). Previously this stayed at 0
                // forever, masking the runaway-retry case where we observed
                // `retryCount=0 ageHours=217` on the same op.
                updated.retryCount += 1
                try updated.save(db)
            }
            context.failedAccounts.insert(currentOp.accountId)
        }
    }

    /// Returns true if the error indicates the message no longer exists (conflict — drop op).
    ///
    /// Matches three classes of signal:
    /// 1. `ProviderError.messageNotFound` — providers that classify explicitly.
    /// 2. `ProviderError.networkError` wrapping an HTTP 404. Must unwrap both the
    ///    `HTTPError.networkError(statusCode:)` shape (Exchange/Gmail providers throw
    ///    this — a plain Swift enum that does NOT bridge to `NSError` with code=404)
    ///    AND the `NSError(code: 404)` shape (other paths that throw `NSError` directly).
    /// 3. IMAP server-side rejection strings ("NONEXISTENT", "UID not found", etc.).
    ///
    /// Strict structural matches (1 and 2) are additionally surfaced via
    /// `isConfirmedGoneError`, which gates destructive header deletion.
    nonisolated func isMessageNotFoundError(_ error: Error) -> Bool {
        if case ProviderError.messageNotFound = error { return true }
        if case ProviderError.networkError(let underlying) = error {
            if case HTTPError.networkError(let statusCode) = underlying, statusCode == 404 {
                return true
            }
            if (underlying as NSError).code == 404 { return true }
        }
        let desc = "\(error)"
        if desc.contains("no such message") || desc.contains("UID not found") ||
           desc.contains("Message not found") || desc.contains("NONEXISTENT") { return true }
        return false
    }

    /// Stricter sibling of `isMessageNotFoundError` used to decide whether we may also
    /// DELETE the local messageHeader row. Only fires on structural signals that
    /// unambiguously confirm the message is gone from the server:
    ///   - `ProviderError.messageNotFound` (providers that classify explicitly)
    ///   - HTTP 404 / 410 (server responded with a permanent not-found status)
    ///
    /// Deliberately does NOT match the string-matching fallback in
    /// `isMessageNotFoundError` — IMAP error descriptions can be noisy and we never
    /// want a false positive to permanently delete user data.
    nonisolated func isConfirmedGoneError(_ error: Error) -> Bool {
        if case ProviderError.messageNotFound = error { return true }
        if case ProviderError.networkError(let underlying) = error {
            if case HTTPError.networkError(let statusCode) = underlying,
               statusCode == 404 || statusCode == 410 {
                return true
            }
            let nsCode = (underlying as NSError).code
            if nsCode == 404 || nsCode == 410 { return true }
        }
        return false
    }

    /// Delete a single messageHeader (identified by its full primary key) that has
    /// been structurally confirmed gone from the server. FK CASCADE removes the
    /// MessageBody + MessageReference children. The FTS row is removed out-of-band.
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
    func deleteConfirmedGoneHeader(headerId: String, reason: String) async {
        let existed: Bool
        do {
            existed = try await dbPool.write { db in
                try MessageHeader.deleteOne(db, key: headerId)
            }
        } catch {
            print("[Gone] GRDB delete failed for \(headerId): \(error)")
            return
        }
        guard existed else { return }
        print("[Gone] Deleted header \(headerId) — reason=\(reason)")
        do {
            try await SearchIndex.shared.removeMessages(headerIds: [headerId])
        } catch {
            print("[Gone] FTS remove failed for \(headerId): \(error)")
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
        let ageHours = Date().timeIntervalSince(op.createdAt) / 3600
        print("[QueueDiag] === op=\(op.id) type=\(op.type.rawValue) ===")
        print("[QueueDiag] op: accountId=\(op.accountId) folderPath=\(op.folderPath) destinationPath=\(op.destinationPath ?? "<nil>") tagValue=\(op.tagValue ?? "<nil>") userLabelId=\(op.userLabelId ?? "<nil>")")
        print("[QueueDiag] op: messageIds=\(op.messageIds) retryCount=\(op.retryCount) status=\(op.status) ageHours=\(String(format: "%.2f", ageHours))")

        // Error structural unwrap — confirms whether classifiers should/shouldn't match
        print("[QueueDiag] error.type=\(type(of: error)) error=\(error)")
        if case ProviderError.networkError(let underlying) = error {
            print("[QueueDiag] underlying.type=\(type(of: underlying)) underlying=\(underlying)")
            if case HTTPError.networkError(let statusCode) = underlying {
                print("[QueueDiag] HTTPError statusCode=\(statusCode)")
            }
            let ns = underlying as NSError
            print("[QueueDiag] NSError domain=\(ns.domain) code=\(ns.code)")
        }
        print("[QueueDiag] classifier: isMessageNotFoundError=\(isMessageNotFoundError(error)) isConfirmedGoneError=\(isConfirmedGoneError(error)) isPermanentlyInvalidError=\(isPermanentlyInvalidError(error))")

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
                        print("[QueueDiag] MessageHeader: NONE for msgId=\(msgId) normalized=\(normalized) account=\(op.accountId)")
                    } else {
                        for h in headers {
                            print("[QueueDiag] MessageHeader: id=\(h.id) folderId=\(h.folderId) folderPath=\(h.folderPath) messageId=\(h.messageId) rfc822=\(h.rfc822MessageId ?? "<nil>") isInInbox=\(h.isInInbox) isRead=\(h.isRead) actionTag=\(h.actionTag?.rawValue ?? "<nil>")")
                        }
                    }
                }

                let srcId = "\(op.accountId):\(op.folderPath)"
                if let src = try Folder.fetchOne(db, key: srcId) {
                    print("[QueueDiag] Folder(source): id=\(src.id) name=\(src.name) path=\(src.path) role=\(src.role.rawValue)")
                } else {
                    print("[QueueDiag] Folder(source): NONE for id=\(srcId)")
                }

                if let dest = op.destinationPath {
                    let destId = "\(op.accountId):\(dest)"
                    if let f = try Folder.fetchOne(db, key: destId) {
                        print("[QueueDiag] Folder(destination): id=\(f.id) name=\(f.name) path=\(f.path) role=\(f.role.rawValue)")
                    } else {
                        print("[QueueDiag] Folder(destination): NONE for id=\(destId)")
                    }
                }

                let trashFolders = try Folder
                    .filter(Column("accountId") == op.accountId && Column("role") == FolderRole.trash.rawValue)
                    .fetchAll(db)
                if trashFolders.isEmpty {
                    print("[QueueDiag] Folder(role=trash): NONE for account=\(op.accountId)")
                } else {
                    for f in trashFolders {
                        print("[QueueDiag] Folder(role=trash): id=\(f.id) name=\(f.name) path=\(f.path)")
                    }
                }
            }
        } catch {
            print("[QueueDiag] ERROR: scoped DB read failed: \(error)")
        }
        print("[QueueDiag] === end op=\(op.id) ===")
    }

    /// Returns true if the error indicates the operation is permanently invalid and should be dropped.
    /// E.g., Gmail rejects label modifications on system labels like DRAFT — these will never succeed.
    /// Only matches 400-level errors from REST providers (Gmail/Exchange) to avoid false positives.
    ///
    /// Must accept TWO underlying-error shapes — they come from different throw sites:
    ///   - `HTTPError.networkError(statusCode: 400)` — thrown by `request()` helpers via
    ///     `catch let e as HTTPError { throw ProviderError.networkError(underlying: e) }`.
    ///     This is a plain Swift enum; its NSError bridge gives `domain="TabMail.HTTPError"
    ///     code=1` (the enum case ordinal), NOT `code=400`. So the NSError-domain check
    ///     below would never match this shape — pattern-match the enum directly.
    ///   - `NSError(domain: "Gmail"|"Exchange", code: 400)` — thrown by retry-aware paths.
    nonisolated func isPermanentlyInvalidError(_ error: Error) -> Bool {
        if case ProviderError.networkError(let underlying) = error {
            if case HTTPError.networkError(let statusCode) = underlying, statusCode == 400 {
                return true
            }
            let ns = underlying as NSError
            if ns.code == 400 && (ns.domain == "Gmail" || ns.domain == "Exchange") {
                return true
            }
        }
        return false
    }

    func executeOperation(_ op: PendingOperation, provider: any EmailProvider) async throws {
        switch op.type {
        case .archive, .delete:
            // Legacy enum cases — all new ops use .move. No-op for any stale rows.
            return
        case .move:
            guard let dest = op.destinationPath else {
                print("[MoveTrace] ERROR: move op missing destinationPath")
                throw ProviderError.messageNotFound
            }
            // Self-move (source == dest) is a no-op — skip the provider call entirely.
            // This happens when archiving from All Mail on Gmail (source and dest both resolve
            // to __GMAIL_ALL_MAIL__). Treating as success lets the op be cleaned up normally.
            guard op.folderPath != dest else {
                print("[MoveTrace] executeOperation.move — no-op (source==dest): \(op.folderPath)")
                return
            }
            let opAgeMin = Date().timeIntervalSince(op.createdAt) / 60
            print("[MoveTrace] executeOperation.move — msgIds=\(op.messageIds) from=\(op.folderPath) to=\(dest) provider=\(type(of: provider)) accountId=\(op.accountId) opId=\(op.id) retryCount=\(op.retryCount) ageMin=\(String(format: "%.1f", opAgeMin))")
            try await provider.move(ids: op.messageIds, from: op.folderPath, to: dest)
            print("[MoveTrace] executeOperation.move — completed successfully")
        case .markRead:
            try await provider.markRead(ids: op.messageIds, folder: op.folderPath)
        case .markUnread:
            try await provider.markUnread(ids: op.messageIds, folder: op.folderPath)
        case .markFlagged:
            try await provider.markFlagged(ids: op.messageIds, flagged: true, folder: op.folderPath)
        case .markUnflagged:
            try await provider.markFlagged(ids: op.messageIds, flagged: false, folder: op.folderPath)
        case .setTag, .removeTag:
            // Action tags are local-only (ADR-IOS-036). Local state is already
            // applied at the call site; the op drains to a no-op so legacy
            // queued rows flush cleanly. No provider write.
            break
        case .markReplied:
            if let imap = provider as? IMAPProvider {
                try await imap.markReplied(ids: op.messageIds, folder: op.folderPath)
            }
            // Gmail/Exchange REST APIs don't support \Answered flag — local state preserved by sync
        case .markForwarded:
            if let imap = provider as? IMAPProvider {
                try await imap.markForwarded(ids: op.messageIds, folder: op.folderPath)
            }
            // Gmail/Exchange REST APIs don't support $Forwarded keyword — local state preserved by sync
        case .saveDraft:
            // messageIds[0] = local Draft table key (draftId)
            // folderPath = server-side Drafts folder path
            guard let draftId = op.messageIds.first else { return }
            try await DraftStore.shared.pushDraftToServer(
                draftId: draftId,
                provider: provider,
                draftsFolderPath: op.folderPath
            )
        case .deleteDraft:
            // messageIds[0] = serverDraftId (IMAP UID / Gmail ID)
            // folderPath = server-side Drafts folder path
            guard let serverDraftId = op.messageIds.first else { return }
            // Silently swallow 404/410: some providers (notably Gmail) auto-
            // delete a draft when the corresponding message is sent, so by the
            // time our queueDraftDelete runs the server row is already gone.
            // Treat "not found" as a successful delete.
            do {
                try await provider.deleteDraft(draftId: serverDraftId, draftsFolderPath: op.folderPath)
            } catch {
                let desc = String(describing: error).lowercased()
                let isNotFound = desc.contains("404") || desc.contains("410")
                    || desc.contains("not found") || desc.contains("notfound")
                    || desc.contains("does not exist")
                if isNotFound {
                    print("[Queue] deleteDraft: server draft \(serverDraftId) already gone — treating as success")
                } else {
                    throw error
                }
            }
        case .addUserLabel:
            guard let labelId = op.userLabelId, let msgId = op.messageIds.first else { return }
            if let gmail = provider as? GmailProvider {
                try await gmail.modifyMessage(id: msgId, addLabelIds: [labelId])
            } else if provider is ExchangeProvider {
                print("[Queue] addUserLabel not yet supported for Exchange")
            } else if let imap = provider as? IMAPProvider {
                try await imap.setUserLabel(messageId: msgId, keyword: labelId, add: true, folder: op.folderPath)
            }
        case .removeUserLabel:
            guard let labelId = op.userLabelId, let msgId = op.messageIds.first else { return }
            if let gmail = provider as? GmailProvider {
                try await gmail.modifyMessage(id: msgId, removeLabelIds: [labelId])
            } else if provider is ExchangeProvider {
                print("[Queue] removeUserLabel not yet supported for Exchange")
            } else if let imap = provider as? IMAPProvider {
                try await imap.setUserLabel(messageId: msgId, keyword: labelId, add: false, folder: op.folderPath)
            }
        }
    }

    /// On app launch, recover from any crash during the previous session.
    /// Resets inFlight ops back to queued (they were mid-execution when app died),
    /// then drains the entire queue. All operations are idempotent, so re-execution is safe.
    func reconcilePendingOperations() async {
        // Crash recovery MUST succeed — inFlight ops from the previous session are stuck
        // and will never drain unless reset to queued.
        try? await retryWrite(dbPool, label: "Queue") { db in
            let staleOps = try PendingOperation
                .filter(Column("status") == PendingStatus.inFlight.rawValue)
                .fetchAll(db)
            if !staleOps.isEmpty {
                print("[Queue] Crash recovery: resetting \(staleOps.count) inFlight ops to queued")
                for op in staleOps {
                    var updated = op
                    updated.status = PendingStatus.queued.rawValue
                    try updated.save(db)
                }
            }
            // Clean up cancelled ops from previous session
            let cancelledCount = try PendingOperation
                .filter(Column("status") == PendingStatus.cancelled.rawValue)
                .deleteAll(db)
            if cancelledCount > 0 {
                print("[Queue] Crash recovery: cleaned up \(cancelledCount) cancelled ops")
            }
        }
        await drainPendingQueue()
        await reconcileOutbox()
        await reconcileCalendarQueue()
    }
}
