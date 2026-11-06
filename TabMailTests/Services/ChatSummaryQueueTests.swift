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
///  4. A chat's request covers every email it names without a done chat summary, any folder; one
///     without its body is sent to the body queue and gets its job when the body is written. The
///     work goes to the front of both queues in the order asked, so what is on screen comes first
///     and the latest request beats earlier ones; an earlier request that resumes later (from the
///     database read or the body hop) adds its work behind, never ahead of the latest.
///  5. The walk covers the threads of the newest `SyncConfig.maxRecentEmails` Inbox rows and nothing
///     else, at most each thread's newest `ChatViewConfig.summaryWindow` emails, members with their
///     body and without a done chat summary, never Trash.
///  6. Release builds keep all of it off; the debug override counts only while debug is unlocked;
///     on also needs the user's toggle and AI on, and AI going off never rewrites the toggle.
///
/// Which emails an open chat asks for is `ChatSummaryWindowTests` and `ChatThreadViewLifecycleTests`.
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

    /// Holds a request in its body hop until opened.
    private actor BodyHop {
        private var held: CheckedContinuation<Void, Never>?
        var isHolding: Bool { held != nil }
        func hold() async { await withCheckedContinuation { held = $0 } }
        func open() { held?.resume(); held = nil }
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

    @Test("A request goes to the front of the queues in the order asked, and the latest request comes first")
    func requestOrderComesFirst() async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        let acc = "acc-cs-7"
        try makeAccount(acc, pool: pool)
        let a = try insertHeader(accountId: acc, uid: "a", folderPath: "Archive", pool: pool)
        let b = try insertHeader(accountId: acc, uid: "b", pool: pool)
        let c = try insertHeader(accountId: acc, uid: "c", folderPath: "Sent", pool: pool)
        let other = try insertHeader(accountId: acc, uid: "other", pool: pool)
        let bodilessOne = try insertHeader(accountId: acc, uid: "nb1", bodyComplete: false, pool: pool)
        let bodilessTwo = try insertHeader(accountId: acc, uid: "nb2", bodyComplete: false, pool: pool)

        let queue = ActiveAIQueue()
        await queue.setDispatchSuppressedForTesting(true)
        // Work already waiting: another email, and an ordinary summary of b.
        await queue.enqueue(headerId: other.id, accountId: acc)
        await queue.enqueue(headerId: b.id, accountId: acc)
        let requests = BodyRequests()

        await queue.enqueueChatSummaries([c, bodilessTwo, b, bodilessOne, a], requestBodies: { await requests.add($0) })
        var jobs = await queue.queuedJobsForTesting
        #expect(jobs.prefix(3).map(\.headerId) == [c.id, b.id, a.id], "asked first, in the order asked, ahead of waiting work")
        #expect(jobs.prefix(3).allSatisfy { $0.jobType == .summary && $0.forChat })
        #expect(jobs.dropFirst(3).allSatisfy { $0.headerId == other.id || $0.headerId == b.id },
                "the waiting work stays, behind")
        #expect(await requests.ids == [bodilessTwo.id, bodilessOne.id], "bodies are asked for in the same order")

        // A later request (the user scrolled) beats the earlier one.
        await queue.enqueueChatSummaries([a], requestBodies: { _ in })
        jobs = await queue.queuedJobsForTesting
        #expect(jobs.prefix(3).map(\.headerId) == [a.id, c.id, b.id])

        // A body that lands for an email only the earlier request asked for joins behind.
        await queue.chatBodyArrived(headerId: bodilessOne.id)
        jobs = await queue.queuedJobsForTesting
        #expect(jobs.first?.headerId == a.id, "the latest request stays first: \(jobs.map(\.headerId))")
        #expect(jobs.contains { $0.headerId == bodilessOne.id && $0.forChat })

        // One the latest request asked for comes first.
        await queue.enqueueChatSummaries([bodilessTwo], requestBodies: { _ in })
        await queue.chatBodyArrived(headerId: bodilessTwo.id)
        #expect(await queue.queuedJobsForTesting.first?.headerId == bodilessTwo.id)
    }

    @Test("An earlier request that resumes after a later one never puts its emails ahead of the later screen")
    func earlierRequestNeverOvertakes() async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        let acc = "acc-cs-9"
        try makeAccount(acc, pool: pool)
        let a = try insertHeader(accountId: acc, uid: "a", pool: pool)
        let b = try insertHeader(accountId: acc, uid: "b", pool: pool)
        let bodiless = try insertHeader(accountId: acc, uid: "nb", bodyComplete: false, pool: pool)

        let queue = ActiveAIQueue()
        await queue.setDispatchSuppressedForTesting(true)
        let hop = BodyHop()
        let earlier = Task { await queue.enqueueChatSummaries([a, bodiless], requestBodies: { _ in await hop.hold() }) }
        for _ in 0..<200 {
            if await hop.isHolding { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(await hop.isHolding, "the earlier request waits in its body hop")

        await queue.enqueueChatSummaries([b], requestBodies: { _ in })
        await hop.open()
        await earlier.value
        var jobs = await queue.queuedJobsForTesting.map(\.headerId)
        #expect(jobs.first == b.id, "the later screen stays first: \(jobs)")
        #expect(jobs.contains(a.id), "the earlier request's email still waits")

        await queue.chatBodyArrived(headerId: bodiless.id)
        jobs = await queue.queuedJobsForTesting.map(\.headerId)
        #expect(jobs.first == b.id, "its body landing does not overtake either: \(jobs)")
        #expect(jobs.contains(bodiless.id))
    }

    @Test("The body queue puts a chat's emails first, in the order asked")
    func bodyQueueOrderComesFirst() async throws {
        func header(_ uid: String) -> MessageHeader {
            MessageHeader(
                messageId: uid, subject: "s", from: "f", fromAddress: "f@example.com", to: "t@example.com",
                date: Date(), snippet: "", folderId: "acc-cs-8|INBOX", accountId: "acc-cs-8", folderPath: "INBOX",
                isInInbox: true)
        }
        let queue = ActiveBodyQueue()
        let waiting = [header("w1"), header("w2")]
        let asked = [header("c2"), header("w2"), header("c1")]
        await queue.enqueueBatch(waiting)
        await queue.enqueueBatch(asked, first: true)
        #expect(await queue.queuedItemsForTesting.map(\.headerId) == [asked[0].id, asked[1].id, asked[2].id, waiting[0].id])
        await queue.enqueueBatch([waiting[0]])
        #expect(await queue.queuedItemsForTesting.last?.headerId == waiting[0].id, "an ordinary enqueue keeps its place")
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

    @Test("The walk takes at most each thread's newest summaryWindow emails")
    func walkTakesEachThreadsNewest() async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        let acc = "acc-cs-9"
        try makeAccount(acc, pool: pool)
        let now = Date()
        let length = ChatViewConfig.summaryWindow + 5
        // A chain, oldest first; only the newest is in the Inbox.
        var ids: [String] = []
        for i in 0..<length {
            let newest = i == length - 1
            let h = try insertHeader(accountId: acc, uid: "w\(i)", folderPath: newest ? "INBOX" : "Archive",
                                     date: now.addingTimeInterval(TimeInterval(i - length) * 60),
                                     inReplyTo: i == 0 ? nil : Self.rfc("w\(i - 1)"), pool: pool)
            ids.append(h.id)
        }
        let candidates = try ActiveAIQueue.chatWalkCandidates(pool: pool).map(\.headerId)
        #expect(Set(candidates) == Set(ids.suffix(ChatViewConfig.summaryWindow)),
                "the newest emails, which an open chat shows first; the rest wait for the chat to ask")
    }

    // MARK: - 6. The switch

    /// Everything `ChatViewConfig.isActive` reads, saved and put back so no suite sees residue:
    /// the user toggle, the AI opt-out and the subscription gate.
    @MainActor
    struct SavedChatViewState {
        let defaults = UserDefaults.standard
        let toggle = UserDefaults.standard.object(forKey: ChatViewConfig.enabledKey)
        let optOut = AIService.optOutStore.object(forKey: AIService.optOutAllAIKey)
        let gateOpen = AISubscriptionGate.shared.isActive
        let lastKnownActive = UserDefaults.standard.object(forKey: "ai_subscription_last_known_active")

        /// The toggle as given, AI on.
        func setChatView(on: Bool) {
            defaults.set(on, forKey: ChatViewConfig.enabledKey)
            AIService.optOutStore.set(false, forKey: AIService.optOutAllAIKey)
            AISubscriptionGate.shared.openGate()
        }

        func restore() {
            if gateOpen { AISubscriptionGate.shared.openGate() } else { AISubscriptionGate.shared.closeGate() }
            defaults.set(lastKnownActive, forKey: "ai_subscription_last_known_active")
            defaults.set(toggle, forKey: ChatViewConfig.enabledKey)
            AIService.optOutStore.set(optOut, forKey: AIService.optOutAllAIKey)
        }
    }

    @MainActor
    @Test("The chat view is on by default; off needs the toggle off, an opt-out or no plan; AI going off keeps the choice")
    func chatViewSwitch() {
        let saved = SavedChatViewState()
        defer { saved.restore() }

        saved.setChatView(on: true)
        UserDefaults.standard.removeObject(forKey: ChatViewConfig.enabledKey)
        #expect(ChatViewConfig.isActive, "a fresh install has it on")

        UserDefaults.standard.set(false, forKey: ChatViewConfig.enabledKey)
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
    }

    @Test("The chat view is on only when chosen and with AI on")
    func activeMatrix() {
        for chosen in [false, true] {
            for aiOn in [false, true] {
                #expect(ChatViewConfig.isActive(enabledByUser: chosen, aiOn: aiOn) == (chosen && aiOn))
            }
        }
        for optedOut in [false, true] {
            for subscribed in [false, true] {
                #expect(ChatViewConfig.isAIOn(optedOut: optedOut, subscribed: subscribed) == (!optedOut && subscribed))
            }
        }
    }
}
