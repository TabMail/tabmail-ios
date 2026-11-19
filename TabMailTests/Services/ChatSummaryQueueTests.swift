/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
import Synchronization
@testable import TabMail

/// ADR-IOS-114 decision 8: the chat view's summaries (opening a thread, and the background walk).
///
/// THE SYSTEM PROPERTIES pinned here:
///  1. A chat summary is done only with its text message, except the local no-content summary,
///     which never gets one; an ordinary summary is done with the summary alone. One predicate
///     (`summaryDone`) decides it for every site, so no chat job can retry forever.
///  2. A chat summary passes the folder scope in any folder but Drafts; every other job keeps the
///     Inbox scope. A chat summary is never asked for a draft, whichever caller asks, decided from
///     the email's own folder role; an email whose folder is unknown is refused too.
///  3. `forChat` is context, not identity: a chat offer and an ordinary offer for the same message
///     are one job, and the flags only widen. A chat offer is never lost to its ordinary twin,
///     pending, in flight or just completed: once the twin is gone, a chat summary is asked for.
///  4. A chat's request covers every email it names without a done chat summary, any folder; one
///     without its body is sent to the body queue and gets its job when the body is written. The
///     work goes to the front of both queues in the order asked, each request in front of the
///     earlier ones, and a body that lands puts its email's job at the front.
///  5. The walk covers the threads of the newest `SyncConfig.maxRecentEmails` Inbox rows and nothing
///     else, at most each thread's newest `ChatViewConfig.summaryWindow` emails, members with their
///     body and without a done chat summary, never Trash. It never asks for a draft, and a draft
///     takes no place in a thread's window. Each thread is looked up once however many of its
///     emails are in the Inbox, and no email of a thread is lost to that. A foreground pass runs it
///     only when the chat view was on as the pass began.
///  6. The chat view is on by default; it needs the user's toggle and AI on, and AI going off
///     never rewrites the toggle.
///
/// Which emails an open chat asks for is `ChatThreadViewLifecycleTests`.
///
/// Admission observation: see `WindowExemptAdmissionTests` (dispatch is suppressed so the queued
/// jobs stay observable).
@Suite("Chat summaries (open and walk)", .serialized, .processGlobalState)
struct ChatSummaryQueueTests {

    // MARK: - Harness

    @discardableResult
    private func insertHeader(
        accountId: String, uid: String, folderPath: String = "INBOX", isInInbox: Bool? = nil,
        date: Date = Date(), inReplyTo: String? = nil, threadId: String? = nil, bodyComplete: Bool = true,
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
        header.threadId = threadId
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

    @Test("A chat summary is in scope in any folder but Drafts; every other job only in the Inbox")
    func scopeMatrix() {
        let archived = header(blurb: nil, textMessage: nil, isInInbox: false)
        let inbox = header(blurb: nil, textMessage: nil, isInInbox: true)
        let chat = ActiveAIQueue.AIJob(headerId: "h", accountId: "a", jobType: .summary, windowExempt: true, forChat: true)
        let ordinary = ActiveAIQueue.AIJob(headerId: "h", accountId: "a", jobType: .summary)
        let exempt = ActiveAIQueue.AIJob(headerId: "h", accountId: "a", jobType: .summary, windowExempt: true)
        #expect(ActiveAIQueue.inScope(archived, chatAllowed: true, for: chat), "a thread holds Sent and archived mail")
        #expect(!ActiveAIQueue.inScope(archived, chatAllowed: false, for: chat), "never a draft")
        #expect(!ActiveAIQueue.inScope(archived, chatAllowed: true, for: ordinary))
        #expect(!ActiveAIQueue.inScope(archived, chatAllowed: true, for: exempt), "window exemption never removes the Inbox scope")
        #expect(ActiveAIQueue.inScope(inbox, chatAllowed: true, for: chat))
        #expect(ActiveAIQueue.inScope(inbox, chatAllowed: true, for: ordinary))
    }

    @Test("A chat summary is refused for a Drafts-role email whichever caller asks, from its own folder role, any account")
    func draftGateRefusesEveryCaller() async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        let acc = "acc-cs-gate"
        try makeAccount(acc, pool: pool)
        try FolderEpochTestFixture.insertFolder(accountId: acc, path: "Drafts", role: .drafts, pool: pool)
        // Another account that holds nothing but the draft.
        let other = "acc-cs-gate-other"
        _ = try FolderEpochTestFixture.makeAccount(id: other, provider: .gmail, pool: pool)
        try FolderEpochTestFixture.insertFolder(accountId: other, path: "Drafts", role: .drafts, pool: pool)
        let draft = try insertHeader(accountId: acc, uid: "draft", folderPath: "Drafts", pool: pool)
        let otherDraft = try insertHeader(accountId: other, uid: "other-draft", folderPath: "Drafts", bodyComplete: false, pool: pool)
        // A folder no row describes: its role is unknown, so it is refused (fail closed).
        let unknown = try insertHeader(accountId: acc, uid: "unknown", folderPath: "Gone", pool: pool)
        // Controls: Sent, Archive and a folder of the user's own, with no role, are summarized for
        // the chat.
        try FolderEpochTestFixture.insertFolder(accountId: acc, path: "Projects", role: .custom, pool: pool)
        let sent = try insertHeader(accountId: acc, uid: "sent", folderPath: "Sent", pool: pool)
        let archived = try insertHeader(accountId: acc, uid: "archived", folderPath: "Archive", bodyComplete: false, pool: pool)
        let filed = try insertHeader(accountId: acc, uid: "filed", folderPath: "Projects", pool: pool)

        let allowed = try await pool.read { db in
            try [draft, otherDraft, unknown, sent, archived, filed].map { try ActiveAIQueue.chatSummaryAllowed($0, db: db) }
        }
        #expect(allowed == [false, false, false, true, true, true], "allowed: \(allowed)")
        let chatJob = { (h: MessageHeader) in
            ActiveAIQueue.AIJob(headerId: h.id, accountId: h.accountId, jobType: .summary, windowExempt: true, forChat: true)
        }
        #expect(!ActiveAIQueue.inScope(draft, chatAllowed: allowed[0], for: chatJob(draft)), "the executor's scope refuses it")

        // The shown chat (its open, its database observation and re-checks, a joining email) and a
        // row on screen all ask through `enqueueChatSummaries`.
        let queue = ActiveAIQueue()
        await queue.setDispatchSuppressedForTesting(true)
        let requests = BodyRequests()
        await queue.enqueueChatSummaries([draft, otherDraft, unknown, sent, archived, filed],
                                         requestBodies: { await requests.add($0) })
        #expect(Set(await queue.queuedJobsForTesting.map(\.headerId)) == [sent.id, filed.id],
                "no job for a draft of either account, nor for an unknown folder; controls: Sent and a folder with no role")
        #expect(await requests.ids == [archived.id], "no body is fetched to summarize a draft; control: Archive")
        // The walk never offers it either (`walkLeavesDraftsOut`); a job that reaches the executor
        // by any other way is refused there (`ChatSummaryExecutionTests.chatSummaryRefusesADraft`).
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

    /// What a Device Sync peer's summary leaves on the row: a summary with no text message.
    private func writePeerSummary(_ id: String, pool: DatabasePool) async throws {
        try await pool.write { db in
            try db.execute(sql: "UPDATE messageHeader SET summaryBlurb = 'S.', summaryTextMessage = NULL WHERE id = ?",
                           arguments: [id])
        }
    }

    private func chatSummaryQueued(_ queue: ActiveAIQueue, _ id: String) async -> Bool {
        await queue.queuedJobsForTesting.contains { $0.headerId == id && $0.jobType == .summary && $0.forChat }
    }

    /// Enqueues the ordinary summary and reply for `msg` and takes both into flight, as dispatch does.
    private func ordinaryTwinInFlight(_ msg: MessageHeader, queue: ActiveAIQueue) async throws -> ActiveAIQueue.AIJob {
        await queue.enqueue(headerId: msg.id, accountId: msg.accountId)
        let inFlight = await queue.takePendingIntoFlightForTesting()
        let twin = try #require(inFlight.first { $0.headerId == msg.id && $0.jobType == .summary })
        #expect(!twin.forChat)
        return twin
    }

    @Test("A chat offer made while its ordinary twin is in flight is asked for once the twin ends without a text message")
    func chatOfferOutlivesInFlightTwin() async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        try makeAccount("acc-cs-t1", pool: pool)
        let msg = try insertHeader(accountId: "acc-cs-t1", uid: "u1", pool: pool)
        let queue = ActiveAIQueue()
        await queue.setDispatchSuppressedForTesting(true)
        let twin = try await ordinaryTwinInFlight(msg, queue: queue)

        await queue.enqueueChatSummaries([msg], requestBodies: { _ in })
        try await writePeerSummary(msg.id, pool: pool)
        await queue.finishInFlightForTesting(twin)

        #expect(await chatSummaryQueued(queue, msg.id),
                "nothing asks for the text message, so the open chat shows Summarizing for good")
    }

    @Test("A chat offer made just after its ordinary twin ended without a text message is asked for")
    func chatOfferAfterTwinCompleted() async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        try makeAccount("acc-cs-t2", pool: pool)
        let msg = try insertHeader(accountId: "acc-cs-t2", uid: "u1", pool: pool)
        let queue = ActiveAIQueue()
        await queue.setDispatchSuppressedForTesting(true)
        let twin = try await ordinaryTwinInFlight(msg, queue: queue)
        try await writePeerSummary(msg.id, pool: pool)
        await queue.finishInFlightForTesting(twin)
        #expect(!(await chatSummaryQueued(queue, msg.id)), "control: no chat offer was made yet")

        await queue.enqueueChatSummaries([msg], requestBodies: { _ in })
        #expect(await chatSummaryQueued(queue, msg.id),
                "the twin's recent completion must not stand for the chat summary it did not write")
    }

    @Test("A chat offer made while its ordinary twin is in flight upgrades the twin when it must run again")
    func chatOfferUpgradesTwinThatRetries() async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        try makeAccount("acc-cs-t3", pool: pool)
        let msg = try insertHeader(accountId: "acc-cs-t3", uid: "u1", pool: pool)
        let queue = ActiveAIQueue()
        await queue.setDispatchSuppressedForTesting(true)
        let twin = try await ordinaryTwinInFlight(msg, queue: queue)

        await queue.enqueueChatSummaries([msg], requestBodies: { _ in })
        await queue.finishInFlightForTesting(twin)   // no summary written: it runs again

        let summaries = await queue.queuedJobsForTesting.filter { $0.headerId == msg.id && $0.jobType == .summary }
        #expect(summaries.count == 1)
        #expect(summaries.allSatisfy { $0.forChat && $0.windowExempt },
                "the retry would finish without the text message the chat asked for")
    }

    @Test("Recovery forgets a chat offer that waited on an in-flight twin")
    func recoveryForgetsWaitingChatOffer() async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        try makeAccount("acc-cs-t4", pool: pool)
        let msg = try insertHeader(accountId: "acc-cs-t4", uid: "u1", pool: pool)
        let queue = ActiveAIQueue()
        await queue.setDispatchSuppressedForTesting(true)
        _ = try await ordinaryTwinInFlight(msg, queue: queue)
        await queue.enqueueChatSummaries([msg], requestBodies: { _ in })
        await queue.cancelAllInFlight()

        // After recovery an ordinary pass runs the same summary; the chat asked before recovery.
        let next = try await ordinaryTwinInFlight(msg, queue: queue)
        try await writePeerSummary(msg.id, pool: pool)
        await queue.finishInFlightForTesting(next)
        #expect(!(await chatSummaryQueued(queue, msg.id)),
                "recovery resets the queue: a request made before it is not acted on after it (the shown chat asks again once the queue is rebuilt)")
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

        // A later request (an older email came on screen) goes in front of the earlier one.
        await queue.enqueueChatSummaries([a], requestBodies: { _ in })
        jobs = await queue.queuedJobsForTesting
        #expect(jobs.prefix(3).map(\.headerId) == [a.id, c.id, b.id])

        // A body that lands: the shown chat's observation asks for that email alone, and its job
        // goes to the front.
        try await pool.write { db in
            try db.execute(sql: "UPDATE messageHeader SET bodyComplete = 1 WHERE id = ?", arguments: [bodilessOne.id])
        }
        await queue.enqueueChatSummaries([bodilessOne], requestBodies: { _ in })
        jobs = await queue.queuedJobsForTesting
        #expect(jobs.first.map { $0.headerId == bodilessOne.id && $0.forChat } == true,
                "the landed body's job comes first: \(jobs.map(\.headerId))")
        #expect(jobs.dropFirst().prefix(3).map(\.headerId) == [a.id, c.id, b.id], "the requests keep their order behind it")
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

    @Test("A foreground pass walks the threads only when the chat view was on as it began", arguments: [true, false])
    func repopulateWalksOnlyWithChatViewOn(chatViewActive: Bool) async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        let acc = "acc-cs-w-\(chatViewActive)"
        try makeAccount(acc, pool: pool)
        // The Inbox row has everything the ordinary pass asks for, but no text message.
        let inbox = try insertHeader(accountId: acc, uid: "inbox", blurb: "S.", pool: pool)
        try await pool.write { db in
            try db.execute(sql: "UPDATE messageHeader SET actionTag = 'none', cachedReply = 'R' WHERE id = ?",
                           arguments: [inbox.id])
        }
        let sentReply = try insertHeader(accountId: acc, uid: "sent", folderPath: "Sent", inReplyTo: Self.rfc("inbox"), pool: pool)

        let queue = ActiveAIQueue()
        await queue.setDispatchSuppressedForTesting(true)
        await queue.repopulateFromDatabase(chatViewActive: chatViewActive)

        let jobs = await queue.queuedJobsForTesting
        if chatViewActive {
            #expect(Set(jobs.map(\.headerId)) == [inbox.id, sentReply.id],
                    "the walk asks for the thread's members without a text message, Sent included")
            #expect(jobs.allSatisfy { $0.jobType == .summary && $0.forChat && $0.windowExempt })
        } else {
            #expect(jobs.isEmpty, "with the chat view off, the pass asks for no chat summaries")
        }
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

    @Test("The walk never asks for a draft, and the window holds the thread's newest real emails")
    func walkLeavesDraftsOut() async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        let acc = "acc-cs-drafts"
        try makeAccount(acc, pool: pool)
        try FolderEpochTestFixture.insertFolder(accountId: acc, path: "Drafts", role: .drafts, pool: pool)
        let now = Date()
        let length = ChatViewConfig.summaryWindow + 1
        // A chain, oldest first; only the newest email is in the Inbox.
        var ids: [String] = []
        for i in 0..<length {
            let newest = i == length - 1
            let h = try insertHeader(accountId: acc, uid: "d\(i)", folderPath: newest ? "INBOX" : "Archive",
                                     date: now.addingTimeInterval(TimeInterval(i - length) * 60),
                                     inReplyTo: i == 0 ? nil : Self.rfc("d\(i - 1)"), pool: pool)
            ids.append(h.id)
        }
        // The user's reply draft to the newest email, the thread's newest member, with its body.
        let draft = try insertHeader(accountId: acc, uid: "reply-draft", folderPath: "Drafts", date: now,
                                     inReplyTo: Self.rfc("d\(length - 1)"), pool: pool)
        let thread = try ThreadDetection.findRelatedMessages(for: draft, in: pool)
        #expect(thread.count == length, "control: the draft is a member of the thread")

        let candidates = try ActiveAIQueue.chatWalkCandidates(pool: pool).map(\.headerId)
        #expect(!candidates.contains(draft.id), "no chat summary is asked for a draft: its text would leave the device for nothing shown")
        #expect(Set(candidates) == Set(ids.suffix(ChatViewConfig.summaryWindow)),
                "the window holds the newest \(ChatViewConfig.summaryWindow) real emails: \(candidates)")
    }

    @Test("Many Inbox emails of one thread cost the walk one thread lookup")
    func walkLooksEachThreadUpOnce() async throws {
        // A pool that records every statement it runs.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let statements = Mutex<[String]>([])
        var config = Configuration()
        config.prepareDatabase { db in
            db.trace { event in statements.withLock { $0.append("\(event)") } }
        }
        let pool = try DatabasePool(path: dir.appendingPathComponent("t.sqlite").path, configuration: config)
        _ = try AppDatabase(dbPool: pool)
        defer { TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        let acc = "acc-cs-once"
        try makeAccount(acc, pool: pool)
        let now = Date()
        let length = 6
        // A chain whose every email is in the Inbox, oldest first.
        var ids: [String] = []
        for i in 0..<length {
            let h = try insertHeader(accountId: acc, uid: "o\(i)", date: now.addingTimeInterval(TimeInterval(i - length) * 60),
                                     inReplyTo: i == 0 ? nil : Self.rfc("o\(i - 1)"), pool: pool)
            ids.append(h.id)
        }
        // The walk's own queries: a connection's first read also introspects the schema (PRAGMA,
        // sqlite_master) once, which is not the walk's cost.
        func walk() throws -> (ids: Set<String>, statements: Int) {
            statements.withLock { $0.removeAll() }
            let found = try ActiveAIQueue.chatWalkCandidates(pool: pool).map(\.headerId)
            let queries = statements.withLock { log in
                log.filter { $0.hasPrefix("SELECT") && !$0.contains("sqlite_master") && !$0.contains("sqlite_schema") }.count
            }
            return (Set(found), queries)
        }
        _ = try walk()  // warm the connection, so both measured walks run on the same footing
        let allInInbox = try walk()
        // The same thread with only its newest email in the Inbox: one row, one lookup.
        let newest = ids[length - 1]
        try await pool.write { db in
            try db.execute(sql: "UPDATE messageHeader SET isInInbox = 0 WHERE id != ?", arguments: [newest])
        }
        let oneInInbox = try walk()
        #expect(allInInbox.ids == Set(ids), "control: the walk covers the whole thread")
        #expect(oneInInbox.ids == allInInbox.ids)
        #expect(oneInInbox.statements > 0, "control: the queries are recorded")
        #expect(allInInbox.statements == oneInInbox.statements,
                "\(length) Inbox emails of one thread cost what one does: \(allInInbox.statements) queries against \(oneInInbox.statements)")
    }

    @Test("A thread looked up once loses no email: rows reached only by a native thread id, or under another one, are looked up themselves")
    func walkLosesNoEmailOfAThread() async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        let acc = "acc-cs-noloss"
        try makeAccount(acc, pool: pool)
        let now = Date()
        // The provider threads `sibling` with `walked` (thread t1), with no reference link between
        // them; `sibling`'s reply sits in another provider thread (t2). The walk reaches `sibling`
        // through t1 only, so `sibling`'s own thread, with `reply`, must still be walked.
        try insertHeader(accountId: acc, uid: "walked", date: now, threadId: "t1", pool: pool)
        try insertHeader(accountId: acc, uid: "sibling", date: now.addingTimeInterval(-60), threadId: "t1", pool: pool)
        let reply = try insertHeader(accountId: acc, uid: "reply", folderPath: "Archive", date: now.addingTimeInterval(-30),
                                     inReplyTo: Self.rfc("sibling"), threadId: "t2", pool: pool)
        // A row linked by reference to an earlier row but under another provider thread (t4): its
        // thread holds `split`, which only t4 reaches.
        try insertHeader(accountId: acc, uid: "first", date: now.addingTimeInterval(-120), threadId: "t3", pool: pool)
        try insertHeader(accountId: acc, uid: "linked", date: now.addingTimeInterval(-180),
                         inReplyTo: Self.rfc("first"), threadId: "t4", pool: pool)
        let split = try insertHeader(accountId: acc, uid: "split", folderPath: "Archive",
                                     date: now.addingTimeInterval(-150), threadId: "t4", pool: pool)

        let candidates = Set(try ActiveAIQueue.chatWalkCandidates(pool: pool).map(\.headerId))
        #expect(candidates.contains(reply.id), "the email of a row reached only by its native thread id: \(candidates)")
        #expect(candidates.contains(split.id), "the email of a row under another native thread id: \(candidates)")
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
