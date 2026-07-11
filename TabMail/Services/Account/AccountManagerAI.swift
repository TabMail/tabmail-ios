/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Synchronization
import UIKit
import UserNotifications

extension AccountManager {

    // MARK: - Direct Path (User-Opened Messages)

    /// Direct priority path for user-opened messages (matches TB's onMessagesDisplayed).
    /// Called when the user opens a message in MessageDetailView — bypasses the queue
    /// and processes AI immediately, mirroring how TB processes the displayed email
    /// inline rather than through the background drain loop.
    func processOpenedMessage(_ message: MessageHeader) async {
        guard message.isInInbox else { return }
        // Check body exists in GRDB
        let body = try? await dbPool.read { db in try MessageBody.fetchOne(db, key: message.id) }
        guard body != nil else { return } // body not yet fetched — fetchBody will trigger processMessage

        // No-content message: set action=delete, summary directly (no AI needed)
        let bodyEmpty = body?.htmlContent == nil || body?.htmlContent?.isEmpty == true
        let hasAttachments = !(body?.attachments.isEmpty ?? true)
        let needsSummary = message.summaryBlurb == nil || message.summaryBlurb?.isEmpty == true
        let needsAction = message.actionTag == nil
        if bodyEmpty && !hasAttachments && (needsSummary || needsAction) {
            let msgId = message.id
            try? await dbPool.write { db in
                guard var msg = try MessageHeader.fetchOne(db, key: msgId) else { return }
                msg.summaryBlurb = "This message has no content."
                msg.actionTag = .delete
                msg.tagSortOrder = ActionTag.delete.sortOrder
                try msg.save(db)
            }
            NotificationCenter.default.post(name: .messageDataDidChange, object: message.id)
            return
        }

        let needsReply = message.cachedReply == nil
        guard needsSummary || needsAction || needsReply else { return } // already fully processed

        let aiDisabled = AIService.optOutStore.bool(forKey: AIService.optOutAllAIKey)
        let deviceSyncEnabled = UserDefaults.standard.object(forKey: "device_sync_auto_enabled") as? Bool ?? true
        let hasSession = KeychainHelper.load(key: "tabmail_session") != nil
        guard hasSession && (!aiDisabled || deviceSyncEnabled) else { return }

        guard let account = try? await dbPool.read({ db in try Account.fetchOne(db, key: message.accountId) }) else {
            NotificationCenter.default.post(name: .aiDidFailForMessage, object: message.id)
            return
        }
        print("[AI] Priority direct path for opened message \(message.messageId)")
        await processMessage(message, account: account)
    }

    /// Process a single message after its body is fetched (priority path for user-opened messages).
    /// Handles AI summary + action classification, matching TB's processMessage().
    func processMessage(_ message: MessageHeader, account: Account) async {
        let body = try? await dbPool.read { db in try MessageBody.fetchOne(db, key: message.id) }
        guard let body, let bodyHtml = body.htmlContent, !bodyHtml.isEmpty else {
            NotificationCenter.default.post(name: .aiDidFailForMessage, object: message.id)
            return
        }

        let plainText = EmailFilter.htmlToPlainText(bodyHtml)

        let headerId = message.id
        let messageId = message.messageId
        let rfc822MessageId = message.rfc822MessageId
        let accountEmail = account.emailAddress
        let subject = message.subject
        let from = message.from
        let fromAddress = message.fromAddress
        let date = message.date
        let htmlContent = body.htmlContent
        let hasExistingAction = message.actionTag != nil
        let hasSummary = message.summaryBlurb != nil && message.summaryBlurb?.isEmpty == false
        let hasReply = message.cachedReply != nil
        let toRecipients = message.to
        let folderPath = message.folderPath
        let userName = account.displayName
        // "cc" needs positive evidence: the RECEIVING account's address in the
        // Cc header (claim set). All registered accounts feed the suppress set
        // only — a cross-account To/From hit prevents a claim, never makes one.
        let allAccountEmails = (try? await dbPool.read { db in
            try Account.fetchAll(db).map(\.emailAddress)
        }) ?? []
        let recipientStatus = PromptVariables.classifyRecipientStatus(
            toField: toRecipients, ccField: message.cc, fromField: message.fromAddress,
            claimEmails: [account.emailAddress], suppressEmails: allAccountEmails
        )
        let kbText = PromptStore.kbTextSnapshot()
        let actionPrompt = PromptStore.actionMarkdownSnapshot()
        let compositionPrompt = await MainActor.run { PromptStore.shared.compositionMarkdown() }
        let accountId = account.id

        Task { @Sendable in
            // Request extended background execution time for in-flight AI call
            let bgTaskId = Mutex<UIBackgroundTaskIdentifier>(.invalid)
            let taskId = await MainActor.run {
                UIApplication.shared.beginBackgroundTask(withName: "ai-priority-\(messageId)") {
                    let id = bgTaskId.withLock { $0 }
                    UIApplication.shared.endBackgroundTask(id)
                }
            }
            bgTaskId.withLock { $0 = taskId }
            defer {
                let id = bgTaskId.withLock { $0 }
                if id != .invalid {
                    Task { @MainActor in UIApplication.shared.endBackgroundTask(id) }
                }
            }

            let dbPool = self.dbPool

            // Double-check: fully processed by another path?
            if let msg = try? await dbPool.read({ db in try MessageHeader.fetchOne(db, key: headerId) }),
               msg.summaryBlurb != nil, msg.summaryBlurb?.isEmpty == false,
               msg.actionTag != nil, msg.cachedReply != nil {
                return
            }

            let aiService = AIService.shared
            let needsSA = !hasSummary || !hasExistingAction

            // Launch SA and R in parallel — R does not depend on summary/action output.
            // Queue dedup prevents the queue from re-processing what the direct path
            // already did (because GRDB fields will be non-nil after we write them).
            async let saTask: Void = {
                guard needsSA else { return }

                if !hasSummary {
                    // Full processing: summary + action
                    do {
                        guard let (summary, action, peerReply) = try await aiService.process(
                            messageId: messageId,
                            rfc822MessageId: rfc822MessageId,
                            accountEmail: accountEmail,
                            subject: subject,
                            from: from,
                            fromAddress: fromAddress,
                            date: date,
                            bodyText: plainText,
                            htmlContent: htmlContent,
                            hasExistingAction: hasExistingAction,
                            userName: userName,
                            kbText: kbText,
                            actionPrompt: actionPrompt,
                            recipientStatus: recipientStatus
                        ) else {
                            return // in-flight dedup (AIService level)
                        }

                        guard let blurb = summary.blurb, !blurb.isEmpty else {
                            print("[AI] No blurb for direct path \(messageId)")
                            NotificationCenter.default.post(name: .aiDidFailForMessage, object: headerId)
                            return
                        }

                        let tagToWrite: ActionTag? = try? await dbPool.write { db in
                            guard var msg = try MessageHeader.fetchOne(db, key: headerId) else { return nil }
                            msg.summaryBlurb = blurb
                            msg.summaryTodos = summary.todos
                            msg.reminderDate = summary.reminderDate
                            msg.reminderTime = summary.reminderTime
                            msg.reminderContent = summary.reminderContent

                            var tagForWrite: ActionTag?
                            var cacheActionTag: ActionTag?
                            if let action, !hasExistingAction {
                                let effectiveAction = (action == .reply && msg.isReplied) ? ActionTag.none : action
                                msg.actionTag = effectiveAction
                                msg.tagSortOrder = effectiveAction.sortOrder
                                tagForWrite = effectiveAction
                                cacheActionTag = action
                                if effectiveAction != action {
                                    print("[ReplyDetect] AI direct: reply→none for \(messageId)")
                                }
                            }

                            if let peerReply, !peerReply.isEmpty, msg.cachedReply == nil {
                                msg.cachedReply = peerReply
                                print("[AI] Device Sync reply applied for direct path \(messageId)")
                            }

                            try msg.save(db)

                            try MessageAICache.writeThrough(
                                accountId: accountId,
                                folderPath: folderPath,
                                rfc822MessageId: rfc822MessageId,
                                summaryBlurb: blurb,
                                summaryTodos: summary.todos,
                                reminderDate: summary.reminderDate,
                                reminderTime: summary.reminderTime,
                                reminderContent: summary.reminderContent,
                                actionTag: cacheActionTag,
                                cachedReply: msg.cachedReply,
                                db: db
                            )
                            return tagForWrite
                        }

                        NotificationCenter.default.post(name: .messageDataDidChange, object: headerId)

                        if let tagToWrite, !hasExistingAction {
                            AccountManager.queueTagWrite(accountId: accountId, messageId: messageId, rfc822MessageId: rfc822MessageId, tag: tagToWrite, folder: folderPath)
                        }

                        // Post active local notification when this message is reply-tagged
                        // (if not already notified by NSE). Gate lives inside via
                        // `EmailNotificationBuilder.isImportant` — matches the NSE rule.
                        Task { @MainActor in
                            guard UIApplication.shared.applicationState != .active else { return }
                            try? await self.postReplyNotificationIfNeeded(headerId: headerId)
                        }

                        print("[AI] Processed single message \(messageId)")
                    } catch {
                        print("[AI] Single message failed for \(messageId): \(error)")
                        NotificationCenter.default.post(name: .aiDidFailForMessage, object: headerId)
                    }
                } else if !hasExistingAction {
                    // Action-only: summary exists but action missing
                    do {
                        let msg = try? await dbPool.read({ db in try MessageHeader.fetchOne(db, key: headerId) })
                        let existingSummary = SummaryResult(
                            blurb: msg?.summaryBlurb,
                            todos: msg?.summaryTodos,
                            reminderDate: msg?.reminderDate,
                            reminderTime: msg?.reminderTime,
                            reminderContent: msg?.reminderContent
                        )
                        let action = try await aiService.classifyAction(
                            subject: subject,
                            from: from,
                            fromAddress: fromAddress,
                            bodyText: plainText,
                            htmlContent: htmlContent,
                            summary: existingSummary,
                            userName: userName,
                            actionPrompt: actionPrompt
                        )
                        if let action {
                            let effectiveAction: ActionTag = (try? await dbPool.write { db -> ActionTag in
                                guard var msg = try MessageHeader.fetchOne(db, key: headerId) else { return action }
                                let resolved = (action == .reply && msg.isReplied) ? ActionTag.none : action
                                msg.actionTag = resolved
                                msg.tagSortOrder = resolved.sortOrder
                                try msg.save(db)
                                try MessageAICache.writeThrough(
                                    accountId: accountId,
                                    folderPath: folderPath,
                                    rfc822MessageId: rfc822MessageId,
                                    actionTag: action,
                                    db: db
                                )
                                return resolved
                            }) ?? action
                            if effectiveAction != action {
                                print("[ReplyDetect] AI direct action-only: reply→none for \(messageId)")
                            }
                            AccountManager.queueTagWrite(accountId: accountId, messageId: messageId, rfc822MessageId: rfc822MessageId, tag: effectiveAction, folder: folderPath)
                            NotificationCenter.default.post(name: .messageDataDidChange, object: headerId)
                            print("[AI] Action-only for single message \(messageId): \(effectiveAction.displayName)")
                        }
                    } catch {
                        print("[AI] Action-only failed for single message \(messageId): \(error)")
                    }
                }
            }()

            async let rTask: Void = {
                guard !hasReply else { return }

                // Re-read model to check if another path populated the reply
                let msg = try? await dbPool.read({ db in try MessageHeader.fetchOne(db, key: headerId) })
                if let msg, msg.cachedReply == nil {
                    do {
                        let reply = try await aiService.processReply(
                            messageId: messageId,
                            rfc822MessageId: rfc822MessageId,
                            accountEmail: accountEmail,
                            subject: subject,
                            from: from,
                            fromAddress: fromAddress,
                            to: toRecipients,
                            date: date,
                            bodyText: plainText,
                            htmlContent: htmlContent,
                            userName: userName,
                            kbText: kbText,
                            compositionPrompt: compositionPrompt
                        )
                        if let reply {
                            try? await dbPool.write { db in
                                guard var msg = try MessageHeader.fetchOne(db, key: headerId) else { return }
                                msg.cachedReply = reply
                                try msg.save(db)
                                if !reply.isEmpty {
                                    try MessageAICache.writeThrough(
                                        accountId: accountId,
                                        folderPath: folderPath,
                                        rfc822MessageId: rfc822MessageId,
                                        cachedReply: reply,
                                        replyGeneratedAt: Date(),
                                        db: db
                                    )
                                    print("[AI] Reply precomputed for direct path \(messageId)")
                                } else {
                                    print("[AI] Reply filtered (sentinel) for direct path \(messageId)")
                                }
                            }
                            NotificationCenter.default.post(name: .messageDataDidChange, object: headerId)
                        }
                    } catch {
                        print("[AI] Reply precompute failed for direct path \(messageId): \(error)")
                    }
                }
            }()

            // Wait for both SA and R to complete
            _ = await (saTask, rTask)
        }
    }

    // MARK: - Manual Tag Teaching (port of TB contextMenus.js applyManualTags)

    /// Apply a manual tag override from the user (long-press context menu).
    /// Matches TB addon's "Tag as Reply/None/Archive/Delete" flow:
    /// 1. Update GRDB state (optimistic UI)
    /// 2. Write tag to IMAP/Gmail
    /// 3. Update persistent AI cache
    /// 4. Fire-and-forget: auto-update user_action.md via LLM patch
    func applyManualTag(_ message: MessageHeader, tag: ActionTag?) async {
        // Block self-sent tagging (matches TB's isInternalSender check)
        guard let account = try? await dbPool.read({ db in try Account.fetchOne(db, key: message.accountId) }) else {
            print("[ManualTag] No account for message \(message.messageId)")
            return
        }

        if message.fromAddress.lowercased() == account.emailAddress.lowercased() {
            print("[ManualTag] Blocking manual tag on self-sent message \(message.messageId)")
            return
        }

        let previousTag = message.actionTag
        let accountId = message.accountId
        let messageId = message.messageId
        let folderPath = message.folderPath
        let rfc822MessageId = message.rfc822MessageId

        // Capture data for auto-update prompt BEFORE changing the tag
        let subject = message.subject
        let from = message.from
        let summaryBlurb = message.summaryBlurb
        let summaryTodos = message.summaryTodos
        let originalAction = previousTag?.rawValue ?? ""
        let userManualTag = tag?.rawValue ?? ""

        if DebugModeManager.isLoggingEnabled() { print("[ManualTag] START messageId=\(messageId) previousTag=\(previousTag?.rawValue ?? "nil") newTag=\(tag?.rawValue ?? "nil") subject=\(subject.prefix(60)) from=\(from.prefix(40))") }
        if DebugModeManager.isLoggingEnabled() { print("[ManualTag] summaryBlurb=\(summaryBlurb?.prefix(80) ?? "nil") summaryTodos=\(summaryTodos?.prefix(80) ?? "nil")") }

        // A staged-only row (ADR-IOS-049) isn't in GRDB yet — Step 1's
        // fetchOne-guarded write would silently no-op and the user's tag
        // would vanish with no error and no retry (round-2 audit). Force the
        // row durable first, mirroring markRead/markUnread/markFlagged/move.
        await ensureDurable([message])

        // Step 1: Update GRDB state immediately (optimistic UI)
        try? await dbPool.write { db in
            guard var msg = try MessageHeader.fetchOne(db, key: message.id) else { return }
            msg.actionTag = tag
            msg.tagSortOrder = tag?.sortOrder ?? 99
            try msg.save(db)
        }

        // Step 2: Queue tag write for async execution
        AccountManager.queueTagWrite(accountId: accountId, messageId: messageId, rfc822MessageId: rfc822MessageId, tag: tag, folder: folderPath)
        Task { @MainActor in NotificationCenter.default.post(name: .inboxDataDidChange, object: nil) }

        // Steps 3-4 run asynchronously
        Task {
            // Step 3: Update persistent AI cache
            try? await dbPool.write { db in
                try MessageAICache.writeThrough(
                    accountId: accountId,
                    folderPath: folderPath,
                    rfc822MessageId: rfc822MessageId,
                    actionTag: tag,
                    db: db
                )
            }
            print("[ManualTag] Applied \(tag?.displayName ?? "remove") to \(messageId)")

            // Step 4: Enqueue auto-update user_action.md for durable retry via BackfillAIQueue.
            // Previously a fire-and-forget LLM call — now persisted to GRDB first so it
            // survives app kill / suspend / network drop. The queue drains on BGProcessing
            // and foreground. `currentUserActionMd` is read live at drain time.
            if tag != nil, originalAction != userManualTag {
                // Re-tag enqueue counts against the
                // demo budget, but the consume happens at *drain* time (in
                // BackfillAIQueue) so it reflects an actual outgoing call.
                // Here we only short-circuit when the budget is already at
                // zero — no point queueing what can't drain.
                let isDemo = await MainActor.run { DemoModeStore.shared.isActive }
                let exhausted = await MainActor.run { DemoModeStore.shared.isCallBudgetExhausted }
                if isDemo && exhausted {
                    print("[ManualTag] Step 4: skip enqueue — demo budget exhausted")
                } else {
                    print("[ManualTag] Step 4: enqueuing actionRefine original=\(originalAction) userTag=\(userManualTag)")
                    let snapshot = ActionRefineSnapshot(
                        messageStableId: message.stableId,
                        accountId: accountId,
                        subject: subject,
                        from: from,
                        summaryBlurb: summaryBlurb,
                        summaryTodos: summaryTodos,
                        originalAction: originalAction,
                        userManualTag: userManualTag
                    )
                    await BackfillAIQueue.shared.enqueueActionRefine(snapshot)
                    print("[ManualTag] Step 4: actionRefine enqueued")
                }
            } else {
                print("[ManualTag] Step 4: skipped actionRefine — tag=\(tag?.rawValue ?? "nil") original=\(originalAction) userTag=\(userManualTag)")
            }
        }
    }

    // MARK: - Reply-based Local Notification

    /// Post an active local notification when a newly-processed message is
    /// reply-tagged (`EmailNotificationBuilder.isImportant`). Gate matches
    /// the NSE — reply is the single source of "important enough to ping".
    /// Reminder fields flesh out the body when present but do not drive the
    /// active/passive decision.
    ///
    /// Skips when the NSE has already notified for this message
    /// (`header.notified == true`).
    @MainActor
    private func postReplyNotificationIfNeeded(headerId: String) async throws {
        guard let header = try await dbPool.read({ db in try MessageHeader.fetchOne(db, key: headerId) }),
              !header.notified else { return }
        let signal = EmailNotificationBuilder.Signal(
            senderName: header.from,
            senderEmail: header.fromAddress,
            subject: header.subject,
            summaryBlurb: header.summaryBlurb,
            actionTag: header.actionTag?.rawValue,
            reminderContent: header.reminderContent,
            dueDate: header.reminderDate,
            dueTime: header.reminderTime
        )
        guard EmailNotificationBuilder.isImportant(signal) else { return }

        let notificationId = EmailNotificationBuilder.identifier(
            accountId: header.accountId, messageId: header.messageId
        )

        // Remove any existing passive notification (from NSE metadata-only)
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [notificationId])

        let content = UNMutableNotificationContent()
        EmailNotificationBuilder.fill(
            content, signal: signal,
            accountId: header.accountId, messageId: header.messageId
        )

        try await UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: notificationId, content: content, trigger: nil))

        try await dbPool.write { db in
            try db.execute(sql: "UPDATE messageHeader SET notified = 1 WHERE id = ?", arguments: [headerId])
        }
        print("[AI] Posted reminder notification for \(headerId)")
    }
}
