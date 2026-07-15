/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import SwiftMail

extension AccountManager {

    // MARK: - Outbox (Offline Send Queue)

    /// Queue a send operation to the outbox. Persists the draft + attachments to disk,
    /// then fires off a drain attempt. Throws if persistence fails — caller MUST
    /// surface the error to the user so the message is not silently lost.
    /// Returns the created outboxId so the caller can pass it to PendingSendService.
    ///
    /// `async`: the persistence runs through the ASYNC `dbPool.write` overload (in
    /// `persistQueuedSend`), so the `@MainActor` caller (`ComposeView.send`) is
    /// SUSPENDED — not blocked — while the single serialized writer is busy with a
    /// background write. A *synchronous* write here was the compose-dismiss freeze:
    /// the writer-serialization wait was transmitted 1:1 to the main thread (2–3 s
    /// on a contended writer). See PROJECT_MEMORY "Foreground-return UI freeze".
    ///
    /// Double-send firewall: if an in-flight (`.queued`/`.sending`) outbox row for
    /// this `draftId` already exists — a rapid double-tap, or async reentrancy
    /// during the now-suspended dismiss window — NO second row is created; the
    /// existing id is returned. (This is the persistence-layer guarantee; the UI
    /// `isSending` guard in ComposeView is the first line of defense.)
    @discardableResult
    nonisolated func queueSend(draft: DraftMessage, from account: Account, replyToHeaderId: String? = nil, isForward: Bool = false, serverDraftId: String? = nil, draftId: String) async throws -> String {
        let result = try await Self.persistQueuedSend(
            draft: draft,
            accountId: account.id,
            replyToHeaderId: replyToHeaderId,
            isForward: isForward,
            serverDraftId: serverDraftId,
            draftId: draftId
        )
        if DebugModeManager.isLoggingEnabled() {
            if result.deduped {
                print("[Outbox] Deduped duplicate send for draftId=\(draftId) → existing outbox id=\(result.outboxId)")
            } else {
                print("[Outbox] Queued send to \(draft.to.joined(separator: ", ")) (id: \(result.outboxId))")
            }
        }

        NotificationCenter.default.post(name: .backgroundDataDidChange, object: nil)
        if let resolvedOriginalId = result.resolvedOriginalId {
            NotificationCenter.default.post(name: .inboxDataDidChange, object: nil)
            // Notify MessageDetailViewModel so reply/forward indicator updates immediately
            NotificationCenter.default.post(name: .messageDataDidChange, object: resolvedOriginalId)
        }
        // synchronous=NORMAL durability: the OutboxMessage row is committed, but NORMAL
        // does not fsync per commit. Harden the send NOW (async, off the compose-dismiss
        // path) so it survives an unclean power-off before the drain runs — a dropped send
        // is the outbox's cardinal sin. Skip on dedup (no new row was written).
        if !result.deduped {
            Task { await AppDatabase.checkpointForDurability() }
        }
        Task { await self.drainOutbox() }
        return result.outboxId
    }

    /// In-flight outbox row id for `draftId`, or nil. The double-send firewall
    /// predicate: dedup ONLY against non-terminal (`.queued`/`.sending`) rows. A
    /// `.failed` row does NOT block — re-sending an explicitly-failed draft is
    /// legitimate user intention, not a duplicate. MUST be called inside the same
    /// write transaction as the insert so two concurrent sends can't both pass it
    /// (GRDB serializes writers → the 2nd transaction sees the 1st's row).
    nonisolated static func inFlightOutboxId(forDraftId draftId: String, db: Database) throws -> String? {
        try OutboxMessage
            .filter(Column("draftId") == draftId)
            .filter([OutboxStatus.queued.rawValue, OutboxStatus.sending.rawValue].contains(Column("status")))
            .fetchOne(db)?
            .id
    }

    /// Pure persistence step of a queued send — the SINGLE SOURCE OF TRUTH for
    /// "turn this draft into (at most) one outbox row", with NO drain side effects
    /// (so tests can drive it deterministically). Saves attachments to disk
    /// (outside the txn), then in ONE async write transaction either dedups against
    /// an existing in-flight row (the firewall) or inserts the new row and applies
    /// optimistic isReplied/isForwarded to the original message.
    ///
    /// Returns the id of the outbox row that now represents this send (the freshly
    /// inserted one, or the pre-existing in-flight one when deduped), whether it
    /// deduped, and the resolved original-header id for the reply/forward badge.
    nonisolated static func persistQueuedSend(
        draft: DraftMessage,
        accountId: String,
        replyToHeaderId: String?,
        isForward: Bool,
        serverDraftId: String?,
        draftId: String
    ) async throws -> (outboxId: String, deduped: Bool, resolvedOriginalId: String?) {
        var outbox = OutboxMessage(
            accountId: accountId,
            draft: draft,
            originalMessageHeaderId: replyToHeaderId,
            isForward: isForward
        )
        outbox.serverDraftId = serverDraftId
        outbox.draftId = draftId
        // Hold the send until `now + undoHold + claimBuffer`. UI Undo button is
        // shown for `undoHold` (5 s); drain claim fires after +1 s claim buffer.
        // The 1 s gap eliminates TOCTOU races between user-taps-Undo and the
        // atomic claim transaction.
        outbox.holdUntil = Date().addingTimeInterval(
            SyncConfig.outboxUndoHoldSeconds + SyncConfig.outboxClaimBufferSeconds
        )

        // Save attachments to disk first (outside DB transaction — a file I/O
        // failure must not leave an outbox row pointing at a half-written dir).
        if !draft.attachments.isEmpty {
            try OutboxMessage.saveAttachments(draft.attachments, dirName: outbox.id)
        }

        // Capture immutable, Sendable values for the @Sendable async write closure.
        let outboxToInsert = outbox
        let inReplyTo = draft.inReplyTo
        let hadAttachments = !draft.attachments.isEmpty
        do {
            let result = try await AppDatabase.dbPool.write { db -> (outboxId: String, deduped: Bool, resolvedOriginalId: String?) in
                // FIREWALL: an in-flight row for this draft already exists (double
                // tap / async reentrancy). Do NOT insert a second row.
                if let existingId = try inFlightOutboxId(forDraftId: draftId, db: db) {
                    return (existingId, true, nil)
                }
                try outboxToInsert.insert(db)
                // Optimistic isReplied/isForwarded — matches markRead/archive pattern.
                // Server state overwrites on next sync (~90s). No rollback needed.
                guard let originalId = replyToHeaderId else { return (outboxToInsert.id, false, nil) }
                guard let original = try resolveOriginalMessage(
                    originalId: originalId, inReplyTo: inReplyTo, db: db
                ) else { return (outboxToInsert.id, false, nil) }
                if isForward {
                    try db.execute(sql: "UPDATE messageHeader SET isForwarded = 1 WHERE id = ?", arguments: [original.id])
                } else {
                    try db.execute(sql: "UPDATE messageHeader SET isReplied = 1 WHERE id = ?", arguments: [original.id])
                    // Clear "Reply" action tag — user already committed to replying.
                    // Action tags are local-only (ADR-IOS-036).
                    if original.actionTag == .reply {
                        try db.execute(
                            sql: "UPDATE messageHeader SET actionTag = ?, tagSortOrder = ?, actionTagSetAt = ? WHERE id = ?",
                            arguments: [ActionTag.none.rawValue, ActionTag.none.sortOrder, Date(), original.id]
                        )
                    }
                }
                return (outboxToInsert.id, false, original.id)
            }
            // Deduped → the attachments dir we just wrote (named by the discarded
            // new outbox.id) is orphaned; clean it up. The kept (existing) row owns
            // its own dir from its original queueSend.
            if result.deduped, hadAttachments {
                outbox.deleteAttachments()
            }
            return result
        } catch {
            // Clean up attachments if DB insert failed.
            outbox.deleteAttachments()
            throw error
        }
    }

    /// Generate an RFC822 Message-ID for a given sender email address.
    /// Format: <UUID@domain>
    nonisolated static func generateMessageId(senderEmail: String) -> String {
        let domain = senderEmail.split(separator: "@").last.map(String.init) ?? "tabmail.local"
        return "<\(UUID().uuidString)@\(domain)>"
    }

    /// Drain all queued outbox messages. Also retries pending Sent folder appends
    /// for messages that were sent but whose IMAP APPEND didn't complete.
    ///
    /// Serial design: picks the oldest ready (past-hold) queued message, sends it,
    /// sleeps `outboxMinSendGapSeconds` (global rate limit), then re-fetches. Per-
    /// iteration re-fetch catches messages whose hold expires during our sleep.
    /// An `attempted` set prevents transient-failure rows from being retried
    /// within this drain pass (they'd spin the loop forever). After the loop,
    /// if any queued rows remain with future `holdUntil`, schedule a fire-and-
    /// forget wake-up Task for the earliest one.
    ///
    /// Only processes `.queued` messages — `.failed` messages require explicit
    /// user retry (swipe-to-retry sets status back to `.queued`).
    ///
    /// All DB writes use `do/catch` (never `try?`) because silent failures on
    /// status transitions can cause double-sends via crash recovery.
    func drainOutbox() async {
        guard !isDrainingOutbox else {
            print("[Outbox] Skipped drain — already draining")
            return
        }
        guard NetworkMonitor.checkConnected() else {
            print("[Outbox] Skipped drain — offline")
            return
        }
        isDrainingOutbox = true
        defer { isDrainingOutbox = false }

        // Log non-queued messages for debugging (stuck/failed). Only fires when
        // there's something unusual to report.
        do {
            let stuckMessages = try await dbPool.read { db in
                try OutboxMessage
                    .filter(Column("status") != OutboxStatus.queued.rawValue)
                    .fetchAll(db)
            }
            for m in stuckMessages {
                print("[Outbox] Stuck message: id=\(m.id) status=\(m.status) retryCount=\(m.retryCount) sentAt=\(String(describing: m.sentAt)) appendedToSent=\(m.appendedToSent) error=\(m.errorMessage ?? "nil") to=\(m.to)")
            }
        } catch {
            print("[Outbox] ERROR: Failed to check outbox state: \(error)")
        }

        // Phase 1: Retry pending Sent folder appends (sent but not yet appended)
        await drainPendingSentAppends()

        // Phase 2: Serial drain of ready (past-hold) queued messages.
        var attempted: Set<String> = []
        var drainedCount = 0

        while !Task.isCancelled {
            // Fetch all queued, filter in Swift — `try?` on a closure returning
            // Optional would produce a double-Optional that doesn't auto-flatten.
            let queuedAll: [OutboxMessage] = (try? await dbPool.read { db in
                try OutboxMessage
                    .filter(Column("status") == OutboxStatus.queued.rawValue)
                    .order(Column("createdAt").asc)
                    .fetchAll(db)
            }) ?? []
            guard let msg = queuedAll.first(where: {
                !attempted.contains($0.id) &&
                ($0.holdUntil ?? .distantPast) <= Date() &&
                workQueues[$0.accountId] != nil
            }) else { break }
            attempted.insert(msg.id)

            guard let (current, messageId) = await atomicClaim(msg) else { continue }

            // NOTE: local Draft deletion happens on send COMPLETION
            // (finalizeOutboxMessage), not at claim time. If SMTP fails
            // transiently, the draft stays in DraftStore so the user can
            // retry or edit.

            NotificationCenter.default.post(name: .backgroundDataDidChange, object: nil)
            await sendSingleOutboxMessage(current, messageId: messageId)
            drainedCount += 1

            // Rate limit: sleep between sends. Global serial — all accounts
            // share this spacing. Acceptable trade-off for a rarely-deep outbox.
            try? await Task.sleep(
                nanoseconds: UInt64(SyncConfig.outboxMinSendGapSeconds * 1_000_000_000)
            )
        }

        if drainedCount > 0 {
            print("[Outbox] Drained \(drainedCount) message(s)")
        }

        // Schedule a wake-up Task for the earliest still-pending future-hold
        // message. Handles the just-queued case AND app-relaunch: if queueSend
        // ran this session, its `Task { drainOutbox() }` triggered us and we
        // fell through the loop (hold still future); we schedule the wake-up
        // here. On relaunch, reconcileOutbox calls drainOutbox (line 854);
        // same flow. Multiple concurrent wake-ups are harmless — the
        // isDrainingOutbox guard serializes re-entry.
        // `attempted` isn't in the filter: if a row was attempted and left
        // .queued (transient failure), we don't auto-retry this session — the
        // next natural drain trigger (foreground, sync, queueSend) handles it.
        let earliest: OutboxMessage?
        do {
            earliest = try await dbPool.read { db in
                try OutboxMessage
                    .filter(Column("status") == OutboxStatus.queued.rawValue)
                    .order(Column("holdUntil").asc)
                    .fetchOne(db)
            }
        } catch {
            earliest = nil
        }
        if let earliest, let hold = earliest.holdUntil, hold > Date() {
            let interval = hold.timeIntervalSinceNow
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard !Task.isCancelled else { return }
                await self?.drainOutbox()
            }
        }
    }

    /// Atomic claim: re-read + status check + mark .sending + persist sentMessageId
    /// in a single write transaction. Returns nil if the row vanished (discarded)
    /// or is no longer .queued. Same pattern as drainPendingQueue's atomic claim.
    private func atomicClaim(_ msg: OutboxMessage) async -> (message: OutboxMessage, messageId: String)? {
        // Look up sender email for Message-ID generation (outside the write txn).
        let senderEmail: String? = try? await dbPool.read { db in
            try Account.fetchOne(db, key: msg.accountId)?.emailAddress
        }
        do {
            return try await dbPool.write { db -> (OutboxMessage, String)? in
                guard let fetched = try OutboxMessage.fetchOne(db, key: msg.id) else {
                    return nil // vanished (discarded)
                }
                guard fetched.outboxStatus == .queued else {
                    return nil // already claimed
                }
                let messageId = fetched.sentMessageId ?? AccountManager.generateMessageId(senderEmail: senderEmail ?? "user@tabmail.local")
                try db.execute(
                    sql: "UPDATE outboxMessage SET status = ?, sentMessageId = ? WHERE id = ?",
                    arguments: [OutboxStatus.sending.rawValue, messageId, fetched.id]
                )
                return (fetched, messageId)
            }
        } catch {
            print("[Outbox] WARNING: Could not claim \(msg.id): \(error)")
            return nil
        }
    }

    /// Send a single outbox message. Called serially from drainOutbox.
    /// Errors are self-contained: transient failures leave the row as .queued
    /// (retry on next drain), permanent failures increment retryCount and
    /// eventually flip to .failed (user-visible, manual retry).
    private func sendSingleOutboxMessage(_ current: OutboxMessage, messageId: String) async {
        guard let queue = workQueues[current.accountId] else { return }
        let provider = queue.provider

        print("[Outbox] Sending message \(current.id) to \(current.to.joined(separator: ", "))")

        do {
            let draft: DraftMessage
            do {
                draft = try current.toDraftMessage()
            } catch {
                // Attachment files corrupted/missing — mark as failed, do NOT send
                // an incomplete email (missing attachments = silent data corruption).
                print("[Outbox] ERROR: Could not reconstruct draft for \(current.id): \(error)")
                try? await retryWrite(dbPool, label: "Outbox") { db in
                    try db.execute(
                        sql: "UPDATE outboxMessage SET status = ?, errorMessage = ? WHERE id = ?",
                        arguments: [OutboxStatus.failed.rawValue, "Attachment files could not be loaded. The message was NOT sent.", current.id]
                    )
                }
                return
            }

            // Inject the pre-generated Message-ID into the draft so the provider
            // uses it for SMTP send (ensuring IMAP append uses the same ID).
            var draftWithId = draft
            draftWithId.messageId = messageId
            let draftToSend = draftWithId

            print("[Outbox] Sending \(current.id) via \(type(of: provider))")
            try await queue.execute(priority: .userAction) {
                try await provider.send(draft: draftToSend)
            }
            print("[Outbox] Send succeeded for \(current.id)")

            // Send succeeded — stamp sentAt FIRST (narrow write, fast). This
            // is the double-send prevention marker: if the app crashes before
            // the append/delete below, reconcileOutbox sees sentAt != nil and
            // retries the append (not re-sends).
            do {
                // Outbox rule 2: state transitions retry, never single-shot.
                // This stamp is the double-send firewall — a transient failure
                // (busy timeout, suspension abort) that goes unretried leaves
                // status=sending + sentAt=nil, which reconcileOutbox re-queues
                // as a full re-send.
                let sentDate = Date()
                let outboxId = current.id
                try await retryWrite(dbPool, retryDelay: .milliseconds(200), label: "Outbox.sentAt") { db in
                    try db.execute(sql: "UPDATE outboxMessage SET sentAt = ? WHERE id = ?",
                                   arguments: [sentDate, outboxId])
                }
            } catch {
                // sentAt write failed — proceed anyway. sentAt is a safety net.
                print("[Outbox] WARNING: Could not stamp sentAt for \(current.id): \(error)")
            }

            // Optimistic Sent folder header: insert a placeholder MessageHeader so the
            // message appears in the Sent folder immediately (before IMAP APPEND + sync).
            // Uses rfc822MessageId for dedup — sync will replace this with the real UID.
            await insertOptimisticSentHeader(outboxMessage: current, messageId: messageId, draft: draftWithId)

            // Attempt Sent folder append. If it fails, the message stays in the
            // outbox with sentAt set — drainPendingSentAppends will retry later.
            let appended = await attemptSentAppend(
                provider: provider,
                draft: draftWithId,
                accountId: current.accountId,
                messageId: messageId,
                outboxId: current.id
            )

            if appended {
                // Both send and append succeeded — finalize.
                await finalizeOutboxMessage(current)
            } else {
                print("[Outbox] Sent but append to Sent folder pending — will retry (id: \(current.id))")
            }

            print("[Outbox] Sent successfully (id: \(current.id))")
        } catch {
            // Send failed — three-tier error classification:
            // 1. Fatal (invalid recipient, message too large): immediately mark 'failed',
            //    no retries. These will never succeed without user intervention.
            // 2. Transient (connection, TLS, timeout): keep 'queued' indefinitely
            //    without incrementing retryCount. Resolves on its own.
            // 3. Permanent (auth, command rejected): increment retryCount, mark
            //    'failed' after 3 attempts so user can retry or discard.
            if !(error is CancellationError) && !SyncEngine.isConnectionError(error) {
                BackgroundSyncLogger.logError("Send failed for \(current.id): \(error)", source: "outbox:\(current.accountId)")
            }
            let errorDesc = String(describing: error)
            let isFatal = Self.isFatalSendError(error)
            let isTransient = !isFatal && Self.isTransientSendError(error)
            let newRetryCount = isTransient ? current.retryCount : current.retryCount + 1
            let shouldAutoRetry = !isFatal && (isTransient || newRetryCount < 3)
            let newStatus = shouldAutoRetry ? OutboxStatus.queued.rawValue : OutboxStatus.failed.rawValue

            do {
                try await retryWrite(dbPool, label: "Outbox") { db in
                    try db.execute(
                        sql: "UPDATE outboxMessage SET status = ?, errorMessage = ?, retryCount = ? WHERE id = ?",
                        arguments: [newStatus, errorDesc, newRetryCount, current.id]
                    )
                }
                NotificationCenter.default.post(name: .backgroundDataDidChange, object: nil)
            } catch {
                print("[Outbox] CRITICAL: Could not update \(current.id) status — stays as 'sending', will be re-queued on restart")
            }
            if isFatal {
                print("[Outbox] Send failed for \(current.id) (fatal, no retry — requires user action): \(error)")
            } else if isTransient {
                print("[Outbox] Send failed for \(current.id) (transient, will auto-retry on next drain): \(error)")
            } else if shouldAutoRetry {
                print("[Outbox] Send failed for \(current.id) (permanent retry \(newRetryCount)/3, will auto-retry): \(error)")
            } else {
                print("[Outbox] Send failed for \(current.id) after \(newRetryCount) permanent failures — marked as failed: \(error)")
            }
        }
    }

    // MARK: - Error Classification

    /// Classify whether a send error is definitively unrecoverable on first attempt.
    /// Fatal errors (invalid recipient, message too large) will never succeed no matter how
    /// many times we retry — mark as 'failed' immediately so the user can fix and retry.
    nonisolated static func isFatalSendError(_ error: Error) -> Bool {
        if let smtpError = error as? SMTPError {
            switch smtpError {
            case .invalidEmailAddress, .messageTooLarge:
                return true
            default:
                return false
            }
        }
        return false
    }

    /// Classify whether a send error is transient (will resolve on its own) vs permanent.
    /// Transient errors keep the message as 'queued' indefinitely without incrementing retryCount.
    /// Permanent errors increment retryCount and mark as 'failed' after 3 attempts.
    nonisolated static func isTransientSendError(_ error: Error) -> Bool {
        // SMTPError cases
        if let smtpError = error as? SMTPError {
            switch smtpError {
            case .connectionFailed, .tlsFailed, .sendFailed:
                // Connection issues, TLS negotiation, send failures are transient
                return true
            case .authenticationFailed, .invalidEmailAddress, .commandFailed, .messageTooLarge, .invalidResponse, .unexpectedResponse:
                // Auth failures, bad addresses, server rejections are permanent
                return false
            }
        }
        // URL/network errors are transient
        if (error as NSError).domain == NSURLErrorDomain { return true }
        // NIO connection errors are transient
        let desc = String(describing: error)
        if desc.contains("connection") || desc.contains("timeout") || desc.contains("Connection") { return true }
        // Default: treat as permanent to avoid infinite retries on truly broken sends
        return false
    }

    // MARK: - Optimistic Sent Header

    /// Insert a placeholder MessageHeader into the Sent folder so the message appears
    /// immediately in the UI after send succeeds. Uses rfc822MessageId (the pre-generated
    /// Message-ID) for dedup — when sync brings in the real IMAP UID, the placeholder is
    /// replaced in-place (same pattern as optimistic drafts).
    private func insertOptimisticSentHeader(outboxMessage msg: OutboxMessage, messageId: String, draft: DraftMessage) async {
        do {
            // Write transaction returns FTS data for post-transaction indexing.
            // Same pattern as queueDraftSave — headerComplete=1 must be set via the real
            // FTS pipeline, not manually, otherwise the body queue / recovery logic misbehaves.
            let ftsInfo: (record: FTSHeaderRecord, bodyText: String)? = try await dbPool.write { db -> (FTSHeaderRecord, String)? in
                guard let sentFolder = try Folder
                    .filter(Column("accountId") == msg.accountId && Column("role") == FolderRole.sent.rawValue)
                    .fetchOne(db) else {
                    return nil // No Sent folder — nothing to insert into
                }

                let folderId = sentFolder.id
                let rfc822 = EmailFilter.normalizeMessageId(messageId)

                // Don't insert if a header with this rfc822MessageId already exists (idempotent)
                if try MessageHeader
                    .filter(Column("folderId") == folderId && Column("rfc822MessageId") == rfc822)
                    .fetchOne(db) != nil {
                    return nil
                }

                let senderAccount = try Account.fetchOne(db, key: msg.accountId)
                let senderEmail = senderAccount?.emailAddress ?? msg.accountId
                let senderDisplayName = senderAccount?.displayName ?? senderEmail
                let plainText = draft.isHTML ? EmailFilter.htmlToPlainText(draft.body) : draft.body
                let snippet = EmailFilter.snippetFromPlainText(plainText)
                let placeholderMsgId = "sent-\(msg.id)"
                let headerId = "\(msg.accountId):\(sentFolder.path):\(placeholderMsgId)"
                let now = Date()

                var header = MessageHeader(
                    messageId: placeholderMsgId,
                    subject: msg.subject,
                    from: senderDisplayName,
                    fromAddress: senderEmail,
                    to: msg.to.joined(separator: ", "),
                    date: now,
                    snippet: snippet,
                    folderId: folderId,
                    accountId: msg.accountId,
                    folderPath: sentFolder.path,
                    isInInbox: false
                )
                header.rfc822MessageId = rfc822
                header.cc = msg.cc.joined(separator: ", ")
                header.bcc = msg.bcc.joined(separator: ", ")
                header.isRead = true
                header.inReplyTo = msg.inReplyTo.map { EmailFilter.normalizeMessageId($0) }
                header.referencesJSON = MessageHeader.encodeReferences(msg.references)
                // Thread grouping so the sent message appears in the conversation
                try ThreadUtils.assignComputedThreadId(to: &header, nativeThreadId: nil, db: db)
                try header.insert(db)
                try ThreadUtils.insertMessageReferences(for: header, db: db)

                // Also create MessageBody so the message is viewable immediately
                if draft.isHTML {
                    let body = MessageBody(headerId: headerId, htmlContent: draft.body)
                    try body.save(db)
                } else {
                    let htmlBody = MessageBody.plainTextToHTML(draft.body)
                    let body = MessageBody(headerId: headerId, htmlContent: htmlBody)
                    try body.save(db)
                }

                return (FTSHeaderRecord(
                    headerId: headerId,
                    messageId: placeholderMsgId,
                    subject: msg.subject,
                    from: "\(senderDisplayName) <\(senderEmail)>",
                    to: msg.to.joined(separator: ", "),
                    cc: msg.cc.joined(separator: ", "),
                    bcc: msg.bcc.joined(separator: ", "),
                    dateMs: Int64(now.timeIntervalSince1970 * 1000),
                    folderId: folderId
                ), plainText)
            }

            // FTS indexing + headerComplete — runs after GRDB write succeeds.
            // Each step independently caught so failure in one doesn't block the others.
            // Without headerComplete=1, the optimistic header is invisible in the Sent folder
            // view (InboxViewModel filters by headerComplete==true).
            if let ftsInfo {
                do {
                    _ = try await SearchIndex.shared.indexHeaders([ftsInfo.record])
                    if !ftsInfo.bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        _ = try await SearchIndex.shared.updateBodies([(headerId: ftsInfo.record.headerId, body: ftsInfo.bodyText)])
                    }
                } catch {
                    print("[Outbox] WARNING: FTS indexing failed for sent \(ftsInfo.record.headerId): \(error)")
                }
                do {
                    // bodyComplete=1: the body is already persisted locally (MessageBody row
                    // inserted above), so nothing to fetch. Without this, BackfillBodyQueue's
                    // repopulate (headerComplete=1 AND bodyComplete=0 AND isInInbox=0) picks
                    // up the placeholder and feeds its synthetic "sent-<UUID>" messageId to
                    // GmailProvider/GraphAPI → HTTP 400 invalid id, every cold start, until
                    // the delta-sync dedup (SyncEngineDeltaSync) replaces the row.
                    try await dbPool.write { db in
                        try db.execute(
                            sql: "UPDATE messageHeader SET headerComplete = 1, bodyComplete = 1 WHERE id = ?",
                            arguments: [ftsInfo.record.headerId]
                        )
                    }
                } catch {
                    print("[Outbox] WARNING: headerComplete write failed for sent \(ftsInfo.record.headerId): \(error)")
                }
            }

            // Always post reload notification — UI refreshes regardless of FTS/headerComplete success.
            NotificationCenter.default.post(name: .inboxDataDidChange, object: nil)
            print("[Outbox] Inserted optimistic Sent header for \(msg.id)")
        } catch {
            // Non-fatal — the message will appear after sync
            print("[Outbox] WARNING: Could not insert optimistic Sent header: \(error)")
        }
    }

    // MARK: - Sent Folder Append

    /// Attempt to append a sent message to the Sent folder. Returns true if successful.
    private func attemptSentAppend(
        provider: any EmailProvider,
        draft: DraftMessage,
        accountId: String,
        messageId: String,
        outboxId: String
    ) async -> Bool {
        // Look up Sent folder path for this account
        let sentPath: String?
        do {
            sentPath = try await dbPool.read { db in
                try Folder
                    .filter(Column("accountId") == accountId)
                    .filter(Column("role") == FolderRole.sent.rawValue)
                    .fetchOne(db)?
                    .path
            }
        } catch {
            print("[Outbox] WARNING: Could not look up Sent folder for \(accountId): \(error)")
            return false
        }

        guard let sentPath else {
            print("[Outbox] WARNING: No Sent folder found for account \(accountId)")
            // No Sent folder configured — can't append. Mark as appended to avoid
            // blocking the outbox forever. The message was sent via SMTP.
            await markAppendedToSent(outboxId: outboxId)
            return true
        }

        do {
            guard let queue = workQueues[accountId] else { return false }
            let result = try await queue.execute(priority: .userAction) {
                try await provider.appendToSentFolder(draft: draft, sentFolderPath: sentPath, messageId: messageId)
            }
            if result {
                await markAppendedToSent(outboxId: outboxId)
            }
            return result
        } catch {
            print("[Outbox] WARNING: Failed to append to Sent folder for \(outboxId): \(error)")
            return false
        }
    }

    /// Mark an outbox message as having been appended to the Sent folder.
    private func markAppendedToSent(outboxId: String) async {
        do {
            try await dbPool.write { db in
                try db.execute(
                    sql: "UPDATE outboxMessage SET appendedToSent = 1 WHERE id = ?",
                    arguments: [outboxId]
                )
            }
        } catch {
            print("[Outbox] WARNING: Could not mark \(outboxId) as appended to Sent: \(error)")
        }
    }

    /// Drain pending Sent folder appends — messages that were sent via SMTP but whose
    /// IMAP APPEND to the Sent folder didn't complete (crash, connection drop, etc.).
    private func drainPendingSentAppends() async {
        let pendingMessages: [OutboxMessage]
        do {
            pendingMessages = try await dbPool.read { db in
                try OutboxMessage
                    .filter(Column("sentAt") != nil)
                    .filter(Column("appendedToSent") == false)
                    .fetchAll(db)
            }
        } catch {
            print("[Outbox] ERROR: Failed to fetch pending sent appends: \(error)")
            return
        }

        guard !pendingMessages.isEmpty else { return }
        print("[Outbox] Retrying \(pendingMessages.count) pending Sent folder appends")

        for msg in pendingMessages {
            guard let queue = workQueues[msg.accountId] else {
                print("[Outbox] No provider for \(msg.accountId) — skipping sent append")
                continue
            }
            let provider = queue.provider

            guard let messageId = msg.sentMessageId else {
                // No Message-ID stored — can't dedup. Mark as appended to unblock.
                print("[Outbox] WARNING: No sentMessageId for \(msg.id) — marking as appended")
                await markAppendedToSent(outboxId: msg.id)
                await finalizeOutboxMessage(msg)
                continue
            }

            let draft: DraftMessage
            do {
                draft = try msg.toDraftMessage()
            } catch {
                // Attachments already cleaned up from a previous partial finalize.
                // Build a draft without attachments — the email was already sent,
                // we just need the content for the Sent folder copy.
                var draftWithoutAttachments = DraftMessage(
                    to: msg.to,
                    cc: msg.cc,
                    bcc: msg.bcc,
                    subject: msg.subject,
                    body: msg.body,
                    isHTML: msg.isHTML,
                    inReplyTo: msg.inReplyTo,
                    references: msg.references,
                    attachments: []
                )
                draftWithoutAttachments.messageId = messageId
                draft = draftWithoutAttachments
            }

            var draftWithId = draft
            draftWithId.messageId = messageId

            let appended = await attemptSentAppend(
                provider: provider,
                draft: draftWithId,
                accountId: msg.accountId,
                messageId: messageId,
                outboxId: msg.id
            )

            if appended {
                await finalizeOutboxMessage(msg)
            }
        }
    }

    /// Finalize an outbox message: update reply/forward flags, delete from DB, clean up attachments.
    /// Called only after BOTH send and Sent folder append have succeeded.
    private func finalizeOutboxMessage(_ msg: OutboxMessage) async {
        var replyDetectHeaderId: String?
        var deleted = false
        do {
            replyDetectHeaderId = try await retryGatedQueueWrite(dbPool, label: "Outbox", maxAttempts: 3) { db -> String? in
                try OutboxMessage.deleteOne(db, key: msg.id)

                // Update isReplied/isForwarded on the original message and, when
                // it has a valid RFC identity, queue the matching server flag.
                // Resolves the original message using the existing lookup pattern:
                // 1. PK lookup (originalMessageHeaderId) — works if message hasn't moved
                // 2. rfc822MessageId lookup (inReplyTo) — survives IMAP folder moves
                // This is the same resolution pattern used throughout the codebase
                // (eviction, ChatIdTranslator, PendingOperation).
                if let originalId = msg.originalMessageHeaderId {
                    let original: MessageHeader? = try Self.resolveOriginalMessage(
                        originalId: originalId, inReplyTo: msg.inReplyTo, db: db
                    )
                    if msg.isForward {
                        if let original {
                            try db.execute(sql: "UPDATE messageHeader SET isForwarded = 1 WHERE id = ?", arguments: [original.id])
                            if let address = MessageIdentity.durableActionAddress(
                                accountId: original.accountId,
                                folderPath: original.folderPath,
                                rfc822MessageId: original.rfc822MessageId,
                                providerMessageId: original.messageId
                            ), let operation = PendingOperation.durableMessageAction(
                                    type: .markForwarded,
                                    messageIds: [address.memberIdentity],
                                    accountId: address.accountId,
                                    folderPath: address.folderPath
                            ) {
                                try operation.insert(db)
                            }
                        }
                    } else {
                        if var original {
                            original.isReplied = true
                            // Queue server-side \Answered only through the
                            // provider-neutral durable identity boundary.
                            if let address = MessageIdentity.durableActionAddress(
                                accountId: original.accountId,
                                folderPath: original.folderPath,
                                rfc822MessageId: original.rfc822MessageId,
                                providerMessageId: original.messageId
                            ), let operation = PendingOperation.durableMessageAction(
                                    type: .markReplied,
                                    messageIds: [address.memberIdentity],
                                    accountId: address.accountId,
                                    folderPath: address.folderPath
                            ) {
                                try operation.insert(db)
                            }
                            if original.actionTag == .reply {
                                original.setActionTag(ActionTag.none)
                                print("[ReplyDetect] Outbox: reply→none for \(original.messageId) (just replied)")
                                try original.update(db)
                                return originalId
                            }
                            try original.update(db)
                        }
                    }
                }
                return nil
            }
            deleted = true
        } catch {
            // retryWrite already logged individual attempts
        }
        // ReplyDetect: notify UI immediately so tag badge updates
        if let replyDetectHeaderId {
            NotificationCenter.default.post(name: .messageDataDidChange, object: replyDetectHeaderId)
        }
        if deleted {
            NotificationCenter.default.post(name: .backgroundDataDidChange, object: nil)
            // Notify inbox list so isReplied/isForwarded/tag changes propagate
            NotificationCenter.default.post(name: .inboxDataDidChange, object: nil)
        } else {
            print("[Outbox] CRITICAL: Could not delete sent message \(msg.id) after 3 attempts — sentAt is set, reconcile will clean up")
        }
        msg.deleteAttachments()

        // Delete the LOCAL draft row now that the send is complete. During the
        // undo-hold window the Draft stayed alive so Undo could reopen compose
        // with its exact contents; once SMTP + Sent-append both succeed, it's
        // safe to remove. Fire-and-forget — non-critical cleanup.
        if let did = msg.draftId {
            Task { try? DraftStore.shared.delete(id: did) }
        }

        // Queue server draft deletion via PendingOperation (crash-safe, retried on failure).
        // The email has been sent — the draft on the server is now stale.
        if let serverDraftId = msg.serverDraftId {
            await queueDraftDelete(serverDraftId: serverDraftId, accountId: msg.accountId)
        }

        // Sync the Sent folder so the sent message appears there immediately.
        if let queue = workQueues[msg.accountId] {
            let accountId = msg.accountId
            Task {
                do {
                    let sentFolder = try await dbPool.read { db in
                        try Folder.filter(Column("accountId") == accountId && Column("role") == FolderRole.sent.rawValue).fetchOne(db)
                    }
                    if let folder = sentFolder {
                        try await queue.execute(priority: .userAction) {
                            try await self.syncEngine.syncFolderMessages(folder: folder, provider: queue.provider)
                        }
                    }
                } catch {
                    print("[Outbox] Post-send Sent folder sync failed: \(error)")
                }
            }
        }
    }

    #if DEBUG
    func finalizeOutboxMessageForTesting(_ message: OutboxMessage) async {
        await finalizeOutboxMessage(message)
    }
    #endif

    /// Resolve the original message for isReplied/isForwarded updates.
    /// Uses the stableId resolution pattern: PK lookup first, rfc822MessageId search if stale.
    /// This is the standard pattern used across the codebase for IMAP MOVE resilience.
    private nonisolated static func resolveOriginalMessage(originalId: String, inReplyTo: String?, db: Database) throws -> MessageHeader? {
        // Strategy 1: direct PK lookup (fast, works if message hasn't moved)
        if let header = try MessageHeader.fetchOne(db, key: originalId) {
            return header
        }
        // Strategy 2: rfc822MessageId search (survives IMAP folder moves)
        if let rfc822 = inReplyTo.map({ EmailFilter.normalizeMessageId($0) }), !rfc822.isEmpty {
            return try MessageHeader
                .filter(Column("rfc822MessageId") == rfc822)
                .fetchOne(db)
        }
        return nil
    }

    // draftsFolderPath is defined in AccountManagerActions

    /// Get the provider for an account by ID.
    private func providerForAccount(_ accountId: String) async throws -> any EmailProvider {
        guard let account = try await dbPool.read({ db in try Account.fetchOne(db, key: accountId) }),
              let provider = providers[account.id] else {
            throw NSError(domain: "AccountManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "No provider for account \(accountId)"])
        }
        return provider
    }

    // MARK: - Crash Recovery

    /// On app launch, recover outbox state from any crash during the previous session.
    ///
    /// - Messages with `sentAt != nil` AND `appendedToSent == true` were fully completed
    ///   but the DB delete didn't finish — delete them now.
    /// - Messages with `sentAt != nil` AND `appendedToSent == false` were sent but the
    ///   Sent folder append didn't complete — keep them for drainPendingSentAppends.
    /// - Messages with `sentAt == nil` and status `sending` were mid-send when the app
    ///   crashed — reset to `queued` for retry (accepts the small double-send risk for
    ///   the case where send succeeded but sentAt write didn't).
    /// - Cleans up orphaned attachment directories that have no matching DB row.
    func reconcileOutbox() async {
        // Collect cleanup work to do OUTSIDE the DB transaction
        // (file I/O and network calls inside a write block would roll back on failure).
        var dirsToClean: [String] = []
        var serverDraftsToDelete: [(accountId: String, serverDraftId: String)] = []

        var localDraftsToDelete: [String] = []
        do {
            let result: (dirs: [String], drafts: [(String, String)], localDrafts: [String]) = try await retryGatedQueueWrite(dbPool, label: "Outbox", maxAttempts: 3, retryDelay: .milliseconds(200)) { db in
                let stale = try OutboxMessage
                    .filter(Column("status") == OutboxStatus.sending.rawValue)
                    .fetchAll(db)
                var dirs: [String] = []
                var drafts: [(String, String)] = []
                var localDrafts: [String] = []
                for msg in stale {
                    if msg.sentAt != nil {
                        if msg.appendedToSent {
                            // Fully completed — delete DB row now, clean files after transaction.
                            // Also set isReplied/isForwarded + queue server flag (crash may have
                            // occurred before the normal post-send update ran).
                            print("[Outbox] Crash recovery: deleting fully-completed message \(msg.id)")
                            // Collect server draft for cleanup (may have been missed on crash)
                            if let sdi = msg.serverDraftId {
                                drafts.append((msg.accountId, sdi))
                            }
                            // Collect local Draft row for cleanup (same — finalizeOutboxMessage
                            // would have deleted it; this catches the crash-before-finalize case).
                            if let did = msg.draftId {
                                localDrafts.append(did)
                            }
                            if let originalId = msg.originalMessageHeaderId {
                                let original: MessageHeader? = try Self.resolveOriginalMessage(
                                    originalId: originalId, inReplyTo: msg.inReplyTo, db: db
                                )
                                if msg.isForward {
                                    if let original {
                                        try db.execute(sql: "UPDATE messageHeader SET isForwarded = 1 WHERE id = ?", arguments: [original.id])
                                        if let address = MessageIdentity.durableActionAddress(
                                            accountId: original.accountId,
                                            folderPath: original.folderPath,
                                            rfc822MessageId: original.rfc822MessageId,
                                            providerMessageId: original.messageId
                                        ), let operation = PendingOperation.durableMessageAction(
                                            type: .markForwarded,
                                            messageIds: [address.memberIdentity],
                                            accountId: address.accountId,
                                            folderPath: address.folderPath
                                        ) {
                                            try operation.insert(db)
                                        }
                                    }
                                } else if var original {
                                    original.isReplied = true
                                    if let address = MessageIdentity.durableActionAddress(
                                        accountId: original.accountId,
                                        folderPath: original.folderPath,
                                        rfc822MessageId: original.rfc822MessageId,
                                        providerMessageId: original.messageId
                                    ), let operation = PendingOperation.durableMessageAction(
                                        type: .markReplied,
                                        messageIds: [address.memberIdentity],
                                        accountId: address.accountId,
                                        folderPath: address.folderPath
                                    ) {
                                        try operation.insert(db)
                                    }
                                    if original.actionTag == .reply {
                                        original.setActionTag(ActionTag.none)
                                    }
                                    try original.update(db)
                                }
                            }
                            try OutboxMessage.deleteOne(db, key: msg.id)
                            if let dirName = msg.attachmentsDirName {
                                dirs.append(dirName)
                            }
                        } else {
                            // Sent but append incomplete — reset to 'sending' so
                            // drainPendingSentAppends picks it up. Keep sentAt set
                            // to prevent double-send.
                            print("[Outbox] Crash recovery: sent but Sent append pending for \(msg.id)")
                            // Status stays as 'sending' — drainPendingSentAppends
                            // queries by sentAt != nil AND appendedToSent == false.
                        }
                    } else {
                        // Was mid-send — reset for retry
                        print("[Outbox] Crash recovery: resetting sending message \(msg.id) to queued")
                        try db.execute(sql: "UPDATE outboxMessage SET status = ? WHERE id = ?",
                                       arguments: [OutboxStatus.queued.rawValue, msg.id])
                    }
                }
                return (dirs, drafts, localDrafts)
            }
            dirsToClean = result.dirs
            serverDraftsToDelete = result.drafts
            localDraftsToDelete = result.localDrafts
        } catch {
            // retryWrite already logged individual attempts
        }

        // File I/O outside the transaction — safe, idempotent
        for dirName in dirsToClean {
            let dir = OutboxMessage.attachmentsBaseDir.appendingPathComponent(dirName, isDirectory: true)
            try? FileManager.default.removeItem(at: dir)
        }

        // Queue server draft deletion via PendingOperation for crash-recovered messages
        for (accountId, serverDraftId) in serverDraftsToDelete {
            await queueDraftDelete(serverDraftId: serverDraftId, accountId: accountId)
        }

        // Delete local Draft rows for fully-completed crash-recovered messages.
        for did in localDraftsToDelete {
            try? DraftStore.shared.delete(id: did)
        }

        // Clean up orphaned attachment directories (crash during queueSend between
        // saveAttachments and DB insert, or other edge cases)
        await cleanOrphanedAttachmentDirs()

        await drainOutbox()
    }

    /// Remove attachment directories that have no matching outboxMessage row.
    private func cleanOrphanedAttachmentDirs() async {
        let baseDir = OutboxMessage.attachmentsBaseDir
        guard let dirs = try? FileManager.default.contentsOfDirectory(at: baseDir, includingPropertiesForKeys: nil) else { return }
        guard !dirs.isEmpty else { return }

        let existingIds: Set<String>
        do {
            existingIds = try await dbPool.read { db in
                let ids = try String.fetchAll(db, sql: "SELECT id FROM outboxMessage WHERE attachmentsDirName IS NOT NULL")
                return Set(ids)
            }
        } catch {
            print("[Outbox] WARNING: Could not fetch outbox IDs for orphan cleanup: \(error)")
            return
        }

        for dir in dirs {
            let dirName = dir.lastPathComponent
            if !existingIds.contains(dirName) {
                print("[Outbox] Cleaning orphaned attachment dir: \(dirName)")
                try? FileManager.default.removeItem(at: dir)
            }
        }
    }

    /// Retry a failed outbox message. Resets status to queued and clears retryCount
    /// so the message gets a fresh set of automatic retries. Returns true if reset succeeded.
    @discardableResult
    nonisolated func retryOutboxMessage(_ messageId: String) -> Bool {
        do {
            try AppDatabase.dbPool.write { db in
                try db.execute(
                    sql: "UPDATE outboxMessage SET status = ?, errorMessage = NULL, retryCount = 0 WHERE id = ?",
                    arguments: [OutboxStatus.queued.rawValue, messageId]
                )
            }
            NotificationCenter.default.post(name: .backgroundDataDidChange, object: nil)
            Task { await self.drainOutbox() }
            return true
        } catch {
            print("[Outbox] ERROR: Failed to retry \(messageId): \(error)")
            return false
        }
    }

    /// Discard an outbox message (delete from DB + disk).
    /// Uses a single write transaction to atomically fetch + delete, preventing a
    /// TOCTOU race where drainOutbox could pick up the message between read and delete.
    /// Refuses to discard a message that is currently being sent (status == sending).
    nonisolated func discardOutboxMessage(_ messageId: String) {
        do {
            let attachmentsDirName: String? = try AppDatabase.dbPool.write { db in
                guard let msg = try OutboxMessage.fetchOne(db, key: messageId) else { return nil }
                // Don't discard mid-send — the email may have already left the server
                guard msg.outboxStatus != .sending else {
                    print("[Outbox] Cannot discard \(messageId) — currently sending")
                    return nil
                }
                try OutboxMessage.deleteOne(db, key: messageId)
                return msg.attachmentsDirName
            }
            // Clean up attachments on disk (outside transaction — safe, idempotent)
            if let dirName = attachmentsDirName {
                let dir = OutboxMessage.attachmentsBaseDir.appendingPathComponent(dirName, isDirectory: true)
                try? FileManager.default.removeItem(at: dir)
            }
            print("[Outbox] Discarded message \(messageId)")
            NotificationCenter.default.post(name: .backgroundDataDidChange, object: nil)
            // Trigger drain so remaining queued messages get processed immediately
            Task { await self.drainOutbox() }
        } catch {
            print("[Outbox] ERROR: Failed to discard \(messageId): \(error)")
        }
    }
}
