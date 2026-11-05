/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

/// ADR-IOS-103 decision 8: the chat view's summaries (D2, opening a thread; D3, the background walk).
///
/// THE SYSTEM PROPERTIES pinned here:
///  1. A chat summary is done only with its text message, except the local no-content summary,
///     which never gets one; an ordinary summary is done with the summary alone. One predicate
///     (`summaryDone`) decides it for every site, so no chat job can retry forever.
///  2. A chat summary passes the folder scope in any folder; every other job keeps the Inbox scope.
///  3. `forChat` is context, not identity: a chat offer and an ordinary offer for the same message
///     are one job, and the flags only widen.
///  4. Opening a thread asks for every member without a done chat summary, any folder; a member
///     without its body is sent to the body queue and gets its job when the body is written.
///  5. The walk covers the threads of the newest `SyncConfig.maxRecentEmails` Inbox rows and nothing
///     else, members with their body and without a done chat summary, never Trash.
///  6. Release builds keep all of it off; the debug override counts only while debug is unlocked;
///     on also needs the user's toggle and AI on, and AI going off never rewrites the toggle.
///  7. Opening a thread with the chat view on asks once per open, with the opened message and its
///     thread; with it off, never.
///
/// Admission observation: see `WindowExemptAdmissionTests` (dispatch is suppressed so the queued
/// jobs stay observable).
@Suite("Chat summaries (D2 open, D3 walk)", .serialized, .processGlobalState)
struct ChatSummaryQueueTests {

    // MARK: - Harness

    @discardableResult
    private func insertHeader(
        accountId: String, uid: String, folderPath: String = "INBOX", isInInbox: Bool? = nil,
        date: Date = Date(), inReplyTo: String? = nil, bodyComplete: Bool = true,
        blurb: String? = nil, textMessage: String? = nil, pool: DatabasePool
    ) throws -> MessageHeader {
        var header = MessageHeader(
            messageId: uid, subject: "chat fixture \(uid)", from: "Sender",
            fromAddress: "sender@example.com", to: "recipient@example.com",
            date: date, snippet: "fixture",
            folderId: MessageIdentity.folderId(accountId: accountId, folderPath: folderPath),
            accountId: accountId, folderPath: folderPath, isInInbox: isInInbox ?? (folderPath == "INBOX")
        )
        header.rfc822MessageId = Self.rfc(uid)
        header.inReplyTo = inReplyTo
        header.headerComplete = true
        header.bodyComplete = bodyComplete
        header.summaryBlurb = blurb
        header.summaryTextMessage = textMessage
        let toInsert = header
        try pool.write { db in try toInsert.insert(db) }
        return header
    }

    private static func rfc(_ uid: String) -> String { "<chat-\(uid)@example.com>" }

    private func makeAccount(_ accountId: String, pool: DatabasePool) throws {
        _ = try FolderEpochTestFixture.makeAccount(id: accountId, provider: .gmail, pool: pool)
        try FolderEpochTestFixture.insertFolder(accountId: accountId, path: "INBOX", role: .inbox, pool: pool)
        try FolderEpochTestFixture.insertFolder(accountId: accountId, path: "Sent", role: .sent, pool: pool)
        try FolderEpochTestFixture.insertFolder(accountId: accountId, path: "Archive", role: .archive, pool: pool)
        try FolderEpochTestFixture.insertFolder(accountId: accountId, path: "Trash", role: .trash, pool: pool)
    }

    /// Collects what `enqueueChatSummaries` sends to the body queue.
    private actor BodyRequests {
        var ids: [String] = []
        func add(_ headers: [MessageHeader]) { ids.append(contentsOf: headers.map(\.id)) }
    }

    private func header(blurb: String?, textMessage: String?, isInInbox: Bool = true) -> MessageHeader {
        var h = MessageHeader(
            messageId: "1", subject: "s", from: "f", fromAddress: "f@example.com", to: "t@example.com",
            date: Date(), snippet: "", folderId: "acc|INBOX", accountId: "acc", folderPath: "INBOX",
            isInInbox: isInInbox)
        h.summaryBlurb = blurb
        h.summaryTextMessage = textMessage
        return h
    }

    // MARK: - 1. Done

    @Test("A chat summary is done only with its text message, or as the no-content summary; an ordinary one with the summary alone")
    func summaryDoneMatrix() {
        let cases: [(blurb: String?, text: String?, ordinary: Bool, chat: Bool)] = [
            (nil, nil, false, false),
            ("", nil, false, false),
            (nil, "T", false, false),
            ("S.", nil, true, false),
            ("S.", "T", true, true),
            (MessageHeader.noContentSummary, nil, true, true),
        ]
        for c in cases {
            let h = header(blurb: c.blurb, textMessage: c.text)
            #expect(ActiveAIQueue.summaryDone(h, forChat: false) == c.ordinary, "ordinary \(c)")
            #expect(ActiveAIQueue.summaryDone(h, forChat: true) == c.chat,
                    "chat \(c): a chat job whose done-condition never holds retries forever")
        }
    }

    // MARK: - 2. Scope

    @Test("A chat summary is in scope in any folder; every other job only in the Inbox")
    func scopeMatrix() {
        let archived = header(blurb: nil, textMessage: nil, isInInbox: false)
        let inbox = header(blurb: nil, textMessage: nil, isInInbox: true)
        let chat = ActiveAIQueue.AIJob(headerId: "h", accountId: "a", jobType: .summary, windowExempt: true, forChat: true)
        let ordinary = ActiveAIQueue.AIJob(headerId: "h", accountId: "a", jobType: .summary)
        let exempt = ActiveAIQueue.AIJob(headerId: "h", accountId: "a", jobType: .summary, windowExempt: true)
        #expect(ActiveAIQueue.inScope(archived, for: chat), "a thread holds Sent and archived mail")
        #expect(!ActiveAIQueue.inScope(archived, for: ordinary))
        #expect(!ActiveAIQueue.inScope(archived, for: exempt), "window exemption never removes the Inbox scope")
        #expect(ActiveAIQueue.inScope(inbox, for: chat))
        #expect(ActiveAIQueue.inScope(inbox, for: ordinary))
    }

    @Test("The action chained after a chat summary keeps the Inbox scope")
    func chainedActionIsNotForChat() {
        let chat = ActiveAIQueue.AIJob(headerId: "h", accountId: "a", jobType: .summary, windowExempt: true, forChat: true)
        let action = ActiveAIQueue.chainedActionJob(after: chat)
        #expect(action.jobType == .action)
        #expect(!action.forChat)
        #expect(action.windowExempt)
    }

    // MARK: - 3. Identity and merge

    @Test("forChat is context, not identity, and a chat offer upgrades a pending ordinary summary")
    func chatOfferUpgradesOrdinaryTwin() async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        try makeAccount("acc-cs-1", pool: pool)
        let msg = try insertHeader(accountId: "acc-cs-1", uid: "u1", pool: pool)

        #expect(ActiveAIQueue.AIJob(headerId: "h", accountId: "a", jobType: .summary)
                == ActiveAIQueue.AIJob(headerId: "h", accountId: "a", jobType: .summary, forChat: true))

        let queue = ActiveAIQueue()
        await queue.setDispatchSuppressedForTesting(true)
        await queue.enqueue(headerId: msg.id, accountId: msg.accountId)
        let before = await queue.queuedJobsForTesting.filter { $0.headerId == msg.id && $0.jobType == .summary }
        #expect(before.count == 1)
        #expect(before.allSatisfy { !$0.forChat && !$0.windowExempt })

        await queue.enqueueChatSummaries([msg], requestBodies: { _ in })
        let after = await queue.queuedJobsForTesting.filter { $0.headerId == msg.id && $0.jobType == .summary }
        #expect(after.count == 1, "the chat offer upgrades the pending summary, never duplicates it")
        #expect(after.allSatisfy { $0.forChat && $0.windowExempt },
                "a swallowed chat offer leaves a summary that finishes without its text message")
    }

    @Test("An ordinary offer never downgrades a pending chat summary")
    func ordinaryOfferNeverDowngradesChat() async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        try makeAccount("acc-cs-2", pool: pool)
        let msg = try insertHeader(accountId: "acc-cs-2", uid: "u1", pool: pool)

        let queue = ActiveAIQueue()
        await queue.setDispatchSuppressedForTesting(true)
        await queue.enqueueChatSummaries([msg], requestBodies: { _ in })
        await queue.enqueue(headerId: msg.id, accountId: msg.accountId)

        let summaries = await queue.queuedJobsForTesting.filter { $0.headerId == msg.id && $0.jobType == .summary }
        #expect(summaries.count == 1)
        #expect(summaries.allSatisfy { $0.forChat && $0.windowExempt })
        let reply = await queue.queuedJobsForTesting.filter { $0.headerId == msg.id && $0.jobType == .reply }
        #expect(reply.count == 1, "the ordinary offer still adds its reply job")
        #expect(reply.allSatisfy { !$0.forChat }, "only summary jobs are chat jobs")
    }

    // MARK: - 4. Opening a thread

    @Test("Opening a thread asks for every member without a done chat summary, any folder, and sends bodiless members to the body queue")
    func openRequestsMembers() async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        let acc = "acc-cs-3"
        try makeAccount(acc, pool: pool)
        let sent = try insertHeader(accountId: acc, uid: "sent", folderPath: "Sent", pool: pool)
        let archivedHalf = try insertHeader(accountId: acc, uid: "half", folderPath: "Archive", blurb: "S.", pool: pool)
        let done = try insertHeader(accountId: acc, uid: "done", blurb: "S.", textMessage: "T", pool: pool)
        let noContent = try insertHeader(accountId: acc, uid: "empty", blurb: MessageHeader.noContentSummary, pool: pool)
        let bodiless = try insertHeader(accountId: acc, uid: "nobody", folderPath: "Archive", bodyComplete: false, pool: pool)

        let queue = ActiveAIQueue()
        await queue.setDispatchSuppressedForTesting(true)
        let requests = BodyRequests()
        await queue.enqueueChatSummaries([sent, archivedHalf, done, noContent, bodiless],
                                         requestBodies: { await requests.add($0) })

        let jobs = await queue.queuedJobsForTesting
        #expect(Set(jobs.map(\.headerId)) == [sent.id, archivedHalf.id],
                "members with a body and no done chat summary get a job, Sent and Archive included; done and no-content members get none; the bodiless one waits")
        #expect(jobs.allSatisfy { $0.jobType == .summary && $0.forChat && $0.windowExempt })
        #expect(await requests.ids == [bodiless.id])

        // The body lands: the waiting member gets its job, once.
        await queue.chatBodyArrived(headerId: bodiless.id)
        await queue.chatBodyArrived(headerId: bodiless.id)
        let afterBody = await queue.queuedJobsForTesting.filter { $0.headerId == bodiless.id }
        #expect(afterBody.count == 1)
        #expect(afterBody.allSatisfy { $0.jobType == .summary && $0.forChat })

        // A body for a message nobody asked for adds nothing.
        await queue.chatBodyArrived(headerId: "\(acc)|never-asked")
        #expect(await queue.queuedJobsForTesting.count == 3)
    }

    @Test("Opening reads the members' current state, not the caller's copies")
    func openRereadsMembers() async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        let acc = "acc-cs-4"
        try makeAccount(acc, pool: pool)
        let stale = try insertHeader(accountId: acc, uid: "u1", pool: pool)
        try await pool.write { db in
            try db.execute(sql: "UPDATE messageHeader SET summaryBlurb = 'S.', summaryTextMessage = 'T' WHERE id = ?",
                           arguments: [stale.id])
        }
        let queue = ActiveAIQueue()
        await queue.setDispatchSuppressedForTesting(true)
        await queue.enqueueChatSummaries([stale], requestBodies: { _ in })
        #expect(await queue.queuedJobsForTesting.isEmpty,
                "the summary landed after the caller's snapshot; asking again would spend a model call for nothing")
    }

    // MARK: - 5. The walk

    @Test("The walk covers the threads of recent Inbox mail, any folder but Trash, members with a body and no done chat summary")
    func walkCandidates() async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        let acc = "acc-cs-5"
        try makeAccount(acc, pool: pool)
        let root = try insertHeader(accountId: acc, uid: "root", folderPath: "Archive", pool: pool)
        let inbox = try insertHeader(accountId: acc, uid: "inbox", inReplyTo: Self.rfc("root"), pool: pool)
        let sentReply = try insertHeader(accountId: acc, uid: "sent", folderPath: "Sent", inReplyTo: Self.rfc("inbox"), pool: pool)
        try insertHeader(accountId: acc, uid: "done", folderPath: "Sent", inReplyTo: Self.rfc("inbox"),
                         blurb: "S.", textMessage: "T", pool: pool)
        try insertHeader(accountId: acc, uid: "nobody", folderPath: "Archive", inReplyTo: Self.rfc("inbox"),
                         bodyComplete: false, pool: pool)
        try insertHeader(accountId: acc, uid: "trashed", folderPath: "Trash", inReplyTo: Self.rfc("inbox"), pool: pool)
        try insertHeader(accountId: acc, uid: "unrelated", folderPath: "Archive", pool: pool)

        let candidates = try ActiveAIQueue.chatWalkCandidates(pool: pool)
        #expect(candidates.map(\.headerId).sorted() == [inbox.id, root.id, sentReply.id].sorted())
        #expect(candidates.count == Set(candidates.map(\.headerId)).count, "each member once")
        #expect(candidates.allSatisfy { $0.accountId == acc })
    }

    @Test("The walk stops at the newest Inbox rows: the thread of an older Inbox row is not walked")
    func walkIsBoundedByRecentInbox() async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        let acc = "acc-cs-6"
        try makeAccount(acc, pool: pool)
        let now = Date()
        // Newest maxRecentEmails Inbox rows, all already done.
        for i in 0..<SyncConfig.maxRecentEmails {
            try insertHeader(accountId: acc, uid: "r\(i)", date: now.addingTimeInterval(TimeInterval(-i)),
                             blurb: "S.", textMessage: "T", pool: pool)
        }
        // One older Inbox row with a reply in Sent: both outside the walk.
        try insertHeader(accountId: acc, uid: "old", date: now.addingTimeInterval(-86_400), pool: pool)
        try insertHeader(accountId: acc, uid: "old-reply", folderPath: "Sent", inReplyTo: Self.rfc("old"), pool: pool)
        // Control: the same shape inside the window is walked.
        try insertHeader(accountId: acc, uid: "new-reply", folderPath: "Sent", inReplyTo: Self.rfc("r0"), pool: pool)

        let ids = try ActiveAIQueue.chatWalkCandidates(pool: pool).map(\.headerId)
        #expect(ids == [MessageIdentity.headerId(accountId: acc, folderPath: "Sent", messageId: "new-reply")])
    }

    // MARK: - 6. Release gate

    /// Everything `ChatViewConfig.isActive` reads, saved and put back so no suite sees residue:
    /// the debug unlock, the override, the user toggle, the AI opt-out and the subscription gate.
    @MainActor
    private struct SavedChatViewState {
        let defaults = UserDefaults.standard
        let unlocked = UserDefaults.standard.object(forKey: "debug_mode_unlocked")
        let override = UserDefaults.standard.object(forKey: "debug_chat_view_enabled")
        let toggle = UserDefaults.standard.object(forKey: ChatViewConfig.enabledKey)
        let optOut = AIService.optOutStore.object(forKey: AIService.optOutAllAIKey)
        let gateOpen = AISubscriptionGate.shared.isActive
        let lastKnownActive = UserDefaults.standard.object(forKey: "ai_subscription_last_known_active")

        /// Debug unlocked, the override as given, the toggle unset (on), AI on.
        func setChatView(on: Bool) {
            defaults.set(true, forKey: "debug_mode_unlocked")
            ChatViewConfig.debugOverride = on
            defaults.removeObject(forKey: ChatViewConfig.enabledKey)
            AIService.optOutStore.set(false, forKey: AIService.optOutAllAIKey)
            AISubscriptionGate.shared.openGate()
        }

        func restore() {
            if gateOpen { AISubscriptionGate.shared.openGate() } else { AISubscriptionGate.shared.closeGate() }
            defaults.set(lastKnownActive, forKey: "ai_subscription_last_known_active")
            defaults.set(unlocked, forKey: "debug_mode_unlocked")
            defaults.set(override, forKey: "debug_chat_view_enabled")
            defaults.set(toggle, forKey: ChatViewConfig.enabledKey)
            AIService.optOutStore.set(optOut, forKey: AIService.optOutAllAIKey)
        }
    }

    @MainActor
    @Test("Release builds keep the chat view off; the override counts only while debug is unlocked; on needs the toggle and AI")
    func releaseGate() {
        let saved = SavedChatViewState()
        defer { saved.restore() }
        #expect(!ChatViewConfig.isAvailableInBuild, "the chat view must not reach users before it ships")

        saved.setChatView(on: true)
        #expect(ChatViewConfig.isActive)

        UserDefaults.standard.set(false, forKey: "debug_mode_unlocked")
        #expect(!ChatViewConfig.isReachable)
        #expect(!ChatViewConfig.isActive, "a leftover override must not count once debug is locked")

        UserDefaults.standard.set(true, forKey: "debug_mode_unlocked")
        UserDefaults.standard.set(false, forKey: ChatViewConfig.enabledKey)
        #expect(ChatViewConfig.isReachable, "the Settings row stays while the user has it off")
        #expect(!ChatViewConfig.isActive, "the user turned it off")

        UserDefaults.standard.removeObject(forKey: ChatViewConfig.enabledKey)
        AIService.optOutStore.set(true, forKey: AIService.optOutAllAIKey)
        #expect(!ChatViewConfig.isActive, "opted out of AI")

        AIService.optOutStore.set(false, forKey: AIService.optOutAllAIKey)
        AISubscriptionGate.shared.closeGate()
        #expect(!ChatViewConfig.isActive, "no plan or trial")
        #expect(UserDefaults.standard.object(forKey: ChatViewConfig.enabledKey) == nil,
                "AI going off never rewrites the user's choice")

        AISubscriptionGate.shared.openGate()
        #expect(ChatViewConfig.isActive, "AI back on: the user's choice applies again")
        ChatViewConfig.debugOverride = false
        #expect(!ChatViewConfig.isActive)
    }

    @Test("The chat view is on only when reachable, chosen and with AI on")
    func activeMatrix() {
        for reachable in [false, true] {
            for chosen in [false, true] {
                for aiOn in [false, true] {
                    #expect(ChatViewConfig.isActive(reachable: reachable, enabledByUser: chosen, aiOn: aiOn)
                            == (reachable && chosen && aiOn))
                }
            }
        }
        for optedOut in [false, true] {
            for subscribed in [false, true] {
                #expect(ChatViewConfig.isAIOn(optedOut: optedOut, subscribed: subscribed) == (!optedOut && subscribed))
            }
        }
    }

    // MARK: - 7. Opening a thread in the detail view

    private func stagedRow(messageId: String, references: [String] = []) -> StagedInboxRow {
        StagedInboxRow(
            accountId: "acc1", folderPath: "INBOX", messageId: messageId,
            rfc822MessageId: "<\(messageId)@example.com>", threadId: nil, inReplyTo: nil, references: references,
            subject: "Staged \(messageId)", senderName: "Sender", senderAddress: "s@example.com",
            to: "me@example.com", snippet: "snip", date: Date(),
            isRead: false, isFlagged: false, hasAttachments: false, isReplied: false,
            isForwarded: false, actionTag: nil, summaryBlurb: nil
        )
    }

    private actor Requests {
        var calls: [[String]] = []
        func add(_ headers: [MessageHeader]) { calls.append(headers.map(\.id)) }
    }

    /// Opens a staged reply whose parent is durable, drives two thread loads through the merge-commit
    /// signal, and returns the chat requests the view model made.
    @MainActor
    private func openThread(chatViewOn: Bool) async throws -> (requests: [[String]], focused: String, parent: String) {
        let saved = SavedChatViewState()
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer {
            saved.restore()
            AppDatabase.shared.withLock { $0 = previous }
            NSEDataBridge.latestStagedRows.withLock { $0 = [] }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
        }
        saved.setChatView(on: chatViewOn)
        _ = try FolderEpochTestFixture.makeAccount(id: "acc1", provider: .gmail, pool: pool)

        let parent = stagedRow(messageId: "chat-parent")
        let focused = stagedRow(messageId: "chat-reply", references: [parent.rfc822MessageId!])
        try await pool.write { db in try parent.toMessageHeader().insert(db) }
        NSEDataBridge.latestStagedRows.withLock { $0 = [focused] }

        let vm = MessageDetailViewModel(
            messageId: focused.headerId, dbPool: pool, fetchBodyOverride: { _ in },
            observeNotifications: true
        )
        let requests = Requests()
        vm._requestChatSummariesOverride = { await requests.add($0) }

        #expect(!vm.hasLoadedThread, "the chat waits for the thread before its first scroll")
        // First load: wait until it applied. Second load (a later merge): it must not ask again.
        NotificationCenter.default.post(name: .nseMergeDidCommit, object: MessageDetailStagedFallbackTests.testPostSentinel)
        for _ in 0..<150 where vm.threadMessages.isEmpty {
            try await Task.sleep(for: .milliseconds(20))
        }
        NotificationCenter.default.post(name: .nseMergeDidCommit, object: MessageDetailStagedFallbackTests.testPostSentinel)
        try await Task.sleep(for: .milliseconds(300))
        #expect(vm.threadMessages.map(\.id) == [parent.headerId], "fixture: the thread load must find the parent")
        #expect(vm.hasLoadedThread)
        return (await requests.calls, focused.headerId, parent.headerId)
    }

    @MainActor
    @Test("With the chat view on, opening a thread asks once, with the opened message and its thread")
    func openAsksOnce() async throws {
        let result = try await openThread(chatViewOn: true)
        #expect(result.requests.count == 1, "one request per open; later thread reloads do not ask again")
        guard result.requests.count == 1 else { return }
        #expect(Set(result.requests[0]) == [result.focused, result.parent])
    }

    @MainActor
    @Test("With the chat view off, opening a thread asks nothing")
    func openAsksNothingWhenOff() async throws {
        let result = try await openThread(chatViewOn: false)
        #expect(result.requests.isEmpty)
    }
}
