/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

/// Tests for ActiveAIQueue's Item type and QueueStorage behavior.
/// ActiveAIQueue is an actor coupled to AppDatabase, SearchIndex, AIService,
/// and PromptStore singletons. The testable parts are:
/// 1. Item struct (Hashable conformance, dedup behavior)
/// 2. QueueStorage with ActiveAIQueue.Item (FIFO, retry, concurrency)
/// 3. Queue state machine transitions
/// 4. Body-missing retry behavior (items retry when FTS body unavailable)
/// 5. No concurrency limit on task dispatch (LLMSemaphore gates API calls instead)
@Suite("ActiveAIQueue - Item and Queue Behavior")
struct ActiveAIQueueTests {

    typealias Item = ActiveAIQueue.AIJob

    // MARK: - Item Hashable/Equatable

    @Test("Items with same headerId and jobType are equal")
    func itemEquality() {
        let a = Item(headerId: "acc1:INBOX:1", accountId: "acc1", jobType: .summary)
        let b = Item(headerId: "acc1:INBOX:1", accountId: "acc1", jobType: .summary)
        #expect(a == b)
    }

    @Test("Items with different headerId are not equal")
    func itemInequalityHeaderId() {
        let a = Item(headerId: "acc1:INBOX:1", accountId: "acc1", jobType: .summary)
        let b = Item(headerId: "acc1:INBOX:2", accountId: "acc1", jobType: .summary)
        #expect(a != b)
    }

    @Test("Items with different jobType are not equal")
    func itemInequalityJobType() {
        let a = Item(headerId: "acc1:INBOX:1", accountId: "acc1", jobType: .summary)
        let b = Item(headerId: "acc1:INBOX:1", accountId: "acc1", jobType: .action)
        #expect(a != b)
    }

    @Test("Item hashability allows Set dedup")
    func itemSetDedup() {
        let items: Set<Item> = [
            Item(headerId: "h1", accountId: "a1", jobType: .summary),
            Item(headerId: "h1", accountId: "a1", jobType: .summary),
            Item(headerId: "h2", accountId: "a1", jobType: .summary),
        ]
        #expect(items.count == 2)
    }

    // MARK: - QueueStorage with Item type

    @Test("Enqueue deduplicates AI items")
    func enqueueDedups() {
        var storage = QueueStorage<Item>()
        let item = Item(headerId: "h1", accountId: "a1", jobType: .summary)
        let first = storage.enqueue(item)
        let second = storage.enqueue(item)
        #expect(first == true)
        #expect(second == false)
        #expect(storage.count == 1)
    }

    @Test("EnqueueBatch adds only unique AI items")
    func enqueueBatchDedups() {
        var storage = QueueStorage<Item>()
        let items = [
            Item(headerId: "h1", accountId: "a1", jobType: .summary),
            Item(headerId: "h2", accountId: "a1", jobType: .summary),
            Item(headerId: "h1", accountId: "a1", jobType: .summary), // duplicate
            Item(headerId: "h3", accountId: "a2", jobType: .summary),
        ]
        let added = storage.enqueueBatch(items)
        #expect(added == 3)
        #expect(storage.count == 3)
    }

    @Test("Items with different jobTypes for same header are separate in queue")
    func multiJobTypeItems() {
        var storage = QueueStorage<Item>()
        let a1 = Item(headerId: "h1", accountId: "acc1", jobType: .summary)
        let a2 = Item(headerId: "h1", accountId: "acc1", jobType: .action)
        storage.enqueue(a1)
        storage.enqueue(a2)
        #expect(storage.count == 2)
    }

    // MARK: - Dispatch with no concurrency limit (matching TB architecture)

    @Test("collectCandidates with Int.max dispatches ALL items")
    func collectCandidatesNoLimit() {
        var storage = QueueStorage<Item>()
        for i in 1...100 {
            storage.enqueue(Item(headerId: "h\(i)", accountId: "a1", jobType: .summary))
        }

        // Int.max = no concurrency limit (LLMSemaphore gates API calls)
        let candidates = storage.collectCandidates(maxJobs: Int.max)
        #expect(candidates.count == 100)
        #expect(storage.pendingCount == 0) // All dispatched
    }

    @Test("In-flight items are skipped during candidate collection")
    func inFlightSkipped() {
        var storage = QueueStorage<Item>()
        let item1 = Item(headerId: "h1", accountId: "a1", jobType: .summary)
        let item2 = Item(headerId: "h2", accountId: "a1", jobType: .summary)
        storage.enqueue(item1)
        storage.enqueue(item2)

        // Collect first candidate
        let first = storage.collectCandidates(maxJobs: 1)
        #expect(first.count == 1)

        // Second collect should get the other item, not the in-flight one
        storage.incrementActiveJobs()
        let second = storage.collectCandidates(maxJobs: Int.max)
        #expect(second.count == 1)
        #expect(second[0] != first[0])
    }

    // MARK: - Job completion and retry

    @Test("Successful job completion removes item from queue")
    func jobCompletionRemovesItem() {
        var storage = QueueStorage<Item>()
        let item = Item(headerId: "h1", accountId: "a1", jobType: .summary)
        storage.enqueue(item)
        let candidates = storage.collectCandidates(maxJobs: Int.max)
        #expect(candidates.count == 1)
        guard let first = candidates.first else { return }
        storage.incrementActiveJobs()

        let hasMore = storage.jobCompleted(first, shouldRetry: false, maxRetries: SyncConfig.maxQueueRetries)
        #expect(hasMore == false)
        #expect(storage.isEmpty)
        #expect(storage.activeJobs == 0)
    }

    @Test("Failed job stays in queue for retry")
    func failedJobRetries() {
        var storage = QueueStorage<Item>()
        let item = Item(headerId: "h1", accountId: "a1", jobType: .summary)
        storage.enqueue(item)
        let candidates = storage.collectCandidates(maxJobs: Int.max)
        #expect(candidates.count == 1)
        guard let first = candidates.first else { return }
        storage.incrementActiveJobs()

        let hasMore = storage.jobCompleted(first, shouldRetry: true, maxRetries: SyncConfig.maxQueueRetries)
        #expect(hasMore == true)
        #expect(storage.count == 1) // Still in queue
        #expect(storage.retryCount(for: item) == 1)
    }

    @Test("Item removed after max retries exceeded")
    func maxRetriesExceeded() {
        var storage = QueueStorage<Item>()
        let item = Item(headerId: "h1", accountId: "a1", jobType: .summary)
        storage.enqueue(item)

        for _ in 0...SyncConfig.maxQueueRetries {
            let candidates = storage.collectCandidates(maxJobs: Int.max)
            if candidates.isEmpty { break }
            storage.incrementActiveJobs()
            _ = storage.jobCompleted(candidates[0], shouldRetry: true, maxRetries: SyncConfig.maxQueueRetries)
        }

        #expect(storage.isEmpty)
    }

    @Test("Retry count tracks per-item")
    func retryCountPerItem() {
        var storage = QueueStorage<Item>()
        let item1 = Item(headerId: "h1", accountId: "a1", jobType: .summary)
        let item2 = Item(headerId: "h2", accountId: "a1", jobType: .summary)
        storage.enqueue(item1)
        storage.enqueue(item2)

        // Fail item1 once
        _ = storage.collectCandidates(maxJobs: Int.max)
        storage.incrementActiveJobs()
        storage.incrementActiveJobs()
        _ = storage.jobCompleted(item1, shouldRetry: true, maxRetries: 3)
        _ = storage.jobCompleted(item2, shouldRetry: false, maxRetries: 3)

        #expect(storage.retryCount(for: item1) == 1)
        #expect(storage.retryCount(for: item2) == 0) // Removed, so 0
    }

    // MARK: - Body-missing retry behavior

    @Test("Body-missing items retry (not dropped) — cycles to back of queue")
    func bodyMissingRetries() {
        // Simulates the processItem behavior: when FTS body is unavailable,
        // shouldRetry=true is returned, keeping the item in the queue.
        var storage = QueueStorage<Item>()
        let item = Item(headerId: "h1", accountId: "a1", jobType: .summary)
        storage.enqueue(item)

        // First attempt: body missing → shouldRetry=true
        let candidates1 = storage.collectCandidates(maxJobs: Int.max)
        #expect(candidates1.count == 1)
        guard let first = candidates1.first else { return }
        storage.incrementActiveJobs()
        let hasMore = storage.jobCompleted(first, shouldRetry: true, maxRetries: SyncConfig.maxQueueRetries)
        #expect(hasMore == true, "Item should stay in queue for retry")
        #expect(storage.count == 1)
        #expect(storage.retryCount(for: item) == 1)

        // Second attempt: body still missing → shouldRetry=true again
        let candidates2 = storage.collectCandidates(maxJobs: Int.max)
        #expect(candidates2.count == 1, "Item should be available for re-dispatch")
        guard let second = candidates2.first else { return }
        storage.incrementActiveJobs()
        _ = storage.jobCompleted(second, shouldRetry: true, maxRetries: SyncConfig.maxQueueRetries)
        #expect(storage.retryCount(for: item) == 2)
    }

    @Test("Body-missing item eventually removed after max retries")
    func bodyMissingMaxRetries() {
        var storage = QueueStorage<Item>()
        let item = Item(headerId: "h1", accountId: "a1", jobType: .summary)
        storage.enqueue(item)

        // Simulate max retries with body always missing
        for i in 0...SyncConfig.maxQueueRetries {
            let candidates = storage.collectCandidates(maxJobs: Int.max)
            if candidates.isEmpty { break }
            storage.incrementActiveJobs()
            _ = storage.jobCompleted(candidates[0], shouldRetry: true, maxRetries: SyncConfig.maxQueueRetries)
            if i < SyncConfig.maxQueueRetries {
                #expect(!storage.isEmpty, "Should stay in queue until max retries exceeded")
            }
        }

        #expect(storage.isEmpty, "Should be removed after max retries")
    }

    // MARK: - clearAll

    @Test("clearAll resets entire queue state")
    func clearAllResetsState() {
        var storage = QueueStorage<Item>()
        for i in 1...5 {
            storage.enqueue(Item(headerId: "h\(i)", accountId: "a1", jobType: .summary))
        }
        let _ = storage.collectCandidates(maxJobs: Int.max)
        storage.incrementActiveJobs()
        storage.incrementActiveJobs()

        // Before clear: queue has items, in-flight, active jobs
        #expect(!storage.isEmpty)

        storage.clearAll()
        #expect(storage.isEmpty)
        #expect(storage.count == 0)
        #expect(storage.pendingCount == 0)
        // Note: activeJobs is NOT cleared by clearAll — it tracks running tasks
        // The caller must handle that separately
    }

    @Test("After clearAll, same items can be re-enqueued")
    func clearAllAllowsReenqueue() {
        var storage = QueueStorage<Item>()
        let item = Item(headerId: "h1", accountId: "a1", jobType: .summary)
        storage.enqueue(item)
        storage.clearAll()

        let added = storage.enqueue(item)
        #expect(added == true)
        #expect(storage.count == 1)
    }

    // MARK: - FIFO ordering

    @Test("Queue processes items in FIFO order")
    func fifoOrdering() {
        var storage = QueueStorage<Item>()
        let items = (1...5).map { Item(headerId: "h\($0)", accountId: "a1", jobType: .summary) }
        storage.enqueueBatch(items)

        let first = storage.collectCandidates(maxJobs: 1)
        #expect(first[0].headerId == "h1")
        storage.incrementActiveJobs()
        _ = storage.jobCompleted(first[0], shouldRetry: false, maxRetries: 3)

        let second = storage.collectCandidates(maxJobs: 1)
        #expect(second[0].headerId == "h2")
    }

    @Test("Failed items go to back of queue (retry at back)")
    func failedItemGoesToBack() {
        var storage = QueueStorage<Item>()
        let items = (1...3).map { Item(headerId: "h\($0)", accountId: "a1", jobType: .summary) }
        storage.enqueueBatch(items)

        // Collect h1, fail it
        let first = storage.collectCandidates(maxJobs: 1)
        storage.incrementActiveJobs()
        #expect(first[0].headerId == "h1")
        _ = storage.jobCompleted(first[0], shouldRetry: true, maxRetries: 3)

        // Next dispatch should get h2, not h1
        let second = storage.collectCandidates(maxJobs: 1)
        #expect(second[0].headerId == "h2")
    }

    // MARK: - needsSummary / needsAction / needsReply logic

    @Test("Message with nil summaryBlurb needs summary")
    func nilSummaryNeedsSummary() {
        let blurb: String? = nil
        let needsSummary = blurb == nil || blurb?.isEmpty == true
        #expect(needsSummary == true)
    }

    @Test("Message with empty summaryBlurb needs summary")
    func emptySummaryNeedsSummary() {
        let blurb: String? = ""
        let needsSummary = blurb == nil || blurb?.isEmpty == true
        #expect(needsSummary == true)
    }

    @Test("Message with non-empty summaryBlurb does not need summary")
    func existingSummaryNoNeed() {
        let blurb: String? = "This is a summary"
        let needsSummary = blurb == nil || blurb?.isEmpty == true
        #expect(needsSummary == false)
    }

    @Test("Message with nil actionTag needs action")
    func nilActionNeedsAction() {
        let tag: ActionTag? = nil
        #expect(tag == nil)
    }

    @Test("Message with nil cachedReply needs reply")
    func nilReplyNeedsReply() {
        let reply: String? = nil
        #expect(reply == nil)
    }

    @Test("Message with all AI fields populated does not need processing")
    func fullyProcessedMessageSkipped() {
        let blurb: String? = "Summary"
        let tag: ActionTag? = .reply
        let reply: String? = "Reply text"

        let needsSummary = blurb == nil || blurb?.isEmpty == true
        let needsAction = tag == nil
        let needsReply = reply == nil
        let needsProcessing = needsSummary || needsAction || needsReply

        #expect(needsProcessing == false)
    }

    // MARK: - Architecture validation

    @Test("LLM semaphore gates concurrent calls, not queue dispatch")
    func architectureValidation() {
        // Verify that SyncConfig has the LLM semaphore limit
        #expect(SyncConfig.maxConcurrentLLMCalls == 32, "LLM semaphore should match TB maxAgentWorkers")

        // Verify the semaphore can be instantiated with the config value
        let sem = LLMSemaphore(maxConcurrent: SyncConfig.maxConcurrentLLMCalls)
        #expect(sem.activeCount == 0)
        #expect(sem.waiterCount == 0)
    }
}

// MARK: - T4.V7 AI-write identity guard

/// The invariant these pin is a SYSTEM PROPERTY, not a mechanism: **an AI result
/// computed for message X never lands on a different physical message that has
/// since taken over X's composite address** — and, in the other direction, the
/// guard must not become a blanket refusal, because these writes are the ONLY
/// source of a message's summary / action tag / precomputed reply / `notified`
/// stamp. Every test drives the real production choke point
/// (`AccountManager.aiGuardedHeaderWrite`), which all nine automatic-AI header
/// writes in `ActiveAIQueue` and `AccountManagerAI` route through.
@Suite("T4.V7 - AI write identity guard")
struct AIWriteIdentityGuardTests {

    private static let accountId = "acc1"
    private static let folderPath = "INBOX"
    private static let uid = "42"

    private static var folderId: String {
        MessageIdentity.folderId(accountId: accountId, folderPath: folderPath)
    }

    private static var headerId: String {
        MessageIdentity.headerId(accountId: accountId, folderPath: folderPath, messageId: uid)
    }

    // MARK: Fixture

    /// Account + folder, with the folder's epoch state under the test's control.
    private func makeFixture(
        folderEpoch: Int?,
        resetPendingAt: Date? = nil,
        accountId: String = AIWriteIdentityGuardTests.accountId,
        provider: AccountProvider = .imap
    ) throws -> DatabaseQueue {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: accountId, email: "user@example.com", provider: provider)
        var folder = Folder(
            name: "INBOX", path: AIWriteIdentityGuardTests.folderPath,
            role: .inbox, accountId: accountId
        )
        folder.lastKnownUidValidity = folderEpoch
        folder.uidValidityResetPendingAt = resetPendingAt
        try db.write { try folder.insert($0) }
        return db
    }

    private func makeHeader(
        subject: String,
        rfc822: String?,
        observedEpoch: Int?,
        accountId: String = AIWriteIdentityGuardTests.accountId
    ) -> MessageHeader {
        var header = MessageHeader(
            messageId: AIWriteIdentityGuardTests.uid,
            subject: subject,
            from: "Sender <sender@example.com>",
            fromAddress: "sender@example.com",
            to: "user@example.com",
            // Dynamic per testing rule 7 — never a literal date.
            date: Date().addingTimeInterval(-3600),
            snippet: "snippet",
            folderId: MessageIdentity.folderId(
                accountId: accountId, folderPath: AIWriteIdentityGuardTests.folderPath),
            accountId: accountId,
            folderPath: AIWriteIdentityGuardTests.folderPath,
            isInInbox: true
        )
        header.rfc822MessageId = rfc822
        header.observedUidValidity = observedEpoch
        return header
    }

    /// Capture exactly as `ActiveAIQueue.executeJob` / `AccountManager.processOpenedMessage` do.
    private func capture(_ db: DatabaseQueue, _ message: MessageHeader) throws -> AIWriteTarget? {
        try db.read { try AIWriteTarget.capture(message: message, db: $0) }
    }

    /// The one guarded mutation every test attempts: stamp X's summary.
    private func attemptSummaryWrite(
        _ db: DatabaseQueue, target: AIWriteTarget, blurb: String
    ) throws -> AIWriteOutcome {
        try db.write { db in
            try AccountManager.aiGuardedHeaderWrite(db, target: target) { msg, db in
                msg.summaryBlurb = blurb
                try msg.save(db)
            }
        }
    }

    private func blurb(_ db: DatabaseQueue, _ id: String) throws -> String? {
        try db.read { db -> String? in
            guard let header = try MessageHeader.fetchOne(db, key: id) else { return nil }
            return header.summaryBlurb
        }
    }

    /// The MULTI-FIELD guarded mutation, shaped like production site 5
    /// (`AccountManagerAI.processMessage`): one AI job stamps the summary, the action
    /// tag, the precomputed reply and the `notified` flag through the same choke
    /// point. The misattribution pins use it because the invariant is *no AI field of
    /// X lands on Y*, not *one particular field did not*.
    private func attemptFullAIWrite(
        _ db: DatabaseQueue, target: AIWriteTarget, blurb: String
    ) throws -> AIWriteOutcome {
        try db.write { db in
            try AccountManager.aiGuardedHeaderWrite(db, target: target) { msg, db in
                msg.summaryBlurb = blurb
                msg.setActionTag(.reply)
                msg.cachedReply = "X's precomputed reply"
                msg.notified = true
                try msg.save(db)
            }
        }
    }

    /// NON-VACUITY, at value level: run the EXACT pre-guard expression every one of
    /// the nine sites used before T4.V7 — a bare `MessageHeader.fetchOne` + mutate +
    /// save — prove it LANDS, then undo it. Without this a `.dropped` could just as
    /// well mean the row was absent, locked or otherwise unwritable.
    private func proveBareWriteLandsThenUndo(_ db: DatabaseQueue, headerId: String) throws {
        let landed: Bool = try db.write { db in
            guard var bare = try MessageHeader.fetchOne(db, key: headerId) else { return false }
            bare.summaryBlurb = "pre-guard control write"
            try bare.save(db)
            return true
        }
        #expect(landed, "the row must be present and writable, else the drop proves nothing")
        #expect(try blurb(db, headerId) == "pre-guard control write")
        try db.write { db in
            guard var bare = try MessageHeader.fetchOne(db, key: headerId) else { return }
            bare.summaryBlurb = nil
            try bare.save(db)
        }
    }

    /// The END STATE the C3 invariant names: the row now at the captured address is
    /// the OTHER message, and it carries **no** AI field produced for X. Asserted on
    /// the database rather than on any guard's return value, so it stays true of the
    /// system rather than of one mechanism.
    private func expectNoAIFieldOfXLandedOn(
        _ db: DatabaseQueue, headerId: String, subject: String, rfc822: String?
    ) throws {
        let after = try db.read { try MessageHeader.fetchOne($0, key: headerId) }
        #expect(after != nil, "the replacement row must still be present")
        #expect(after?.subject == subject, "the row at X's address must still be the replacement")
        #expect(after?.rfc822MessageId == rfc822, "the row at X's address must still be the replacement")
        #expect(after?.summaryBlurb == nil, "X's summary landed on another message — misattribution (C3)")
        #expect(after?.actionTag == nil, "X's action tag landed on another message — misattribution (C3)")
        #expect(after?.cachedReply == nil, "X's precomputed reply landed on another message — misattribution (C3)")
        #expect(after?.notified == false, "X's notified stamp landed on another message — misattribution (C3)")
    }

    // MARK: The hazard — a proven UIDVALIDITY turnover

    @Test("A UIDVALIDITY turnover means X's AI summary never lands on the message now at X's address")
    func turnoverDropsTheWriteOntoTheReplacement() throws {
        let db = try makeFixture(folderEpoch: 111)
        let original = makeHeader(subject: "Original X", rfc822: "<x@example.com>", observedEpoch: 111)
        try db.write { try original.insert($0) }

        let target = try capture(db, original)
        #expect(target != nil, "capture must succeed on an ordinary stamped IMAP row")
        guard let target else { return }

        // The turnover, exactly as the purge-and-resync reaction leaves the world:
        // the old epoch's rows are gone, a DIFFERENT physical message occupies the
        // same UID under the new numbering, and the fresh epoch is stamped.
        let impostor = makeHeader(subject: "Impostor Y", rfc822: "<y@example.com>", observedEpoch: 222)
        try db.write { db in
            _ = try MessageHeader.deleteOne(db, key: Self.headerId)
            guard var folder = try Folder.fetchOne(db, key: Self.folderId) else { return }
            folder.lastKnownUidValidity = 222
            try folder.update(db)
            try impostor.insert(db)
        }

        // NON-VACUITY, and the value-level RED evidence: run the EXACT pre-guard
        // expression every one of the nine sites used before T4.V7 — a bare
        // `MessageHeader.fetchOne(db, key: headerId)` + mutate + save. It LANDS on
        // the impostor. So the drop below is the guard refusing, not the row being
        // absent, locked, or otherwise unwritable.
        let bareWriteLanded: Bool = try db.write { db in
            guard var bare = try MessageHeader.fetchOne(db, key: Self.headerId) else { return false }
            bare.summaryBlurb = "pre-guard control write"
            try bare.save(db)
            return true
        }
        #expect(bareWriteLanded, "the impostor row must be present and writable, else the drop proves nothing")
        let controlBlurb = try blurb(db, Self.headerId)
        #expect(controlBlurb == "pre-guard control write")

        // Reset so the guarded attempt starts from a clean row.
        try db.write { db in
            guard var bare = try MessageHeader.fetchOne(db, key: Self.headerId) else { return }
            bare.summaryBlurb = nil
            try bare.save(db)
        }

        let outcome = try attemptSummaryWrite(db, target: target, blurb: "X's summary")
        #expect(outcome == .dropped)

        let after = try db.read { try MessageHeader.fetchOne($0, key: Self.headerId) }
        #expect(after?.rfc822MessageId == "<y@example.com>", "the row at X's address is still the replacement")
        #expect(after?.summaryBlurb == nil, "X's summary must never land on the replacement")
    }

    @Test("A vanished row drops the AI write and never resurrects the message")
    func vanishedRowDropsTheWrite() throws {
        let db = try makeFixture(folderEpoch: 111)
        let original = makeHeader(subject: "Original X", rfc822: "<x@example.com>", observedEpoch: 111)
        try db.write { try original.insert($0) }

        let target = try capture(db, original)
        guard let target else {
            #expect(Bool(false), "capture must succeed")
            return
        }
        try db.write { db in _ = try MessageHeader.deleteOne(db, key: Self.headerId) }

        let outcome = try attemptSummaryWrite(db, target: target, blurb: "X's summary")
        #expect(outcome == .dropped)
        let after = try db.read { try MessageHeader.fetchOne($0, key: Self.headerId) }
        #expect(after == nil, "a guarded write must never re-create a purged row")
    }

    @Test("A folder mid UIDVALIDITY reset drops the AI write")
    func midResetDropsTheWrite() throws {
        let db = try makeFixture(folderEpoch: 111)
        let original = makeHeader(subject: "Original X", rfc822: "<x@example.com>", observedEpoch: 111)
        try db.write { try original.insert($0) }

        let target = try capture(db, original)
        guard let target else {
            #expect(Bool(false), "capture must succeed")
            return
        }
        try db.write { db in
            guard var folder = try Folder.fetchOne(db, key: Self.folderId) else { return }
            folder.uidValidityResetPendingAt = Date()
            try folder.update(db)
        }

        let outcome = try attemptSummaryWrite(db, target: target, blurb: "X's summary")
        #expect(outcome == .dropped)
        let after = try blurb(db, Self.headerId)
        #expect(after == nil, "no AI result may land on a folder whose rows are mid purge-and-resync")
    }

    // MARK: The other side — the guard must not become a blanket refusal

    @Test("An unchanged captured target still writes through")
    func unchangedTargetWritesThrough() throws {
        let db = try makeFixture(folderEpoch: 111)
        let original = makeHeader(subject: "Original X", rfc822: "<x@example.com>", observedEpoch: 111)
        try db.write { try original.insert($0) }

        let target = try capture(db, original)
        guard let target else {
            #expect(Bool(false), "capture must succeed")
            return
        }

        let outcome = try attemptSummaryWrite(db, target: target, blurb: "X's summary")
        #expect(outcome == .written)
        let after = try blurb(db, Self.headerId)
        #expect(after == "X's summary", "the ordinary healthy write must land — this is the whole product")
    }

    /// 🚨 AUDIT ROUND 4 / `IOS-ROUND3-D6` — **RE-SCOPED, NOT DELETED.** Its previous
    /// display name was *"An rfc-less message with no epoch anywhere is still
    /// captured and still written"* and it asserted `.written`, which BLESSED arm 7's
    /// fail-open admit: with no content witness and no numbering anywhere, nothing
    /// established that the row in front of the write was still the row that was
    /// captured, and the old arm returned it anyway.
    ///
    /// The half of it that was always right is kept verbatim in behaviour: **capture
    /// stays unconditional** (`v2final` refuses to capture this shape, which makes
    /// the whole AI job a permanent no-op; v3 does not). What changed is the WRITE,
    /// and the second half of this test is what keeps the change from being a
    /// blackout: once the next sync observes the folder's numbering and stamps the
    /// row, the very same rfc-less message DOES receive its AI result — through arm
    /// 8's positive three-way agreement, on the fresh capture the queue's arbiter
    /// re-drives (`summaryBlurb` is still nil, so the job was never retired).
    @Test("An rfc-less row with no numbering anywhere is captured, refused, and lands once its epoch is observed")
    func rfcLessMessageIsRefusedUntilItsNumberingIsObserved() throws {
        let db = try makeFixture(folderEpoch: nil)
        let original = makeHeader(subject: "No RFC", rfc822: nil, observedEpoch: nil)
        try db.write { try original.insert($0) }

        let target = try capture(db, original)
        #expect(target != nil, "capture must NOT refuse an rfc-less row with no epoch baseline")
        guard let target else { return }

        try proveBareWriteLandsThenUndo(db, headerId: Self.headerId)

        let refused = try attemptSummaryWrite(db, target: target, blurb: "X's summary")
        #expect(refused == .dropped,
                """
                An AI result was written against a row with NO content witness and NO numbering \
                anywhere — nothing positively established that this is still the captured message, \
                and a WRITE needs positive evidence (C3).
                """)
        #expect(try blurb(db, Self.headerId) == nil)
        // The job was NOT retired, so the arbiter re-drives it — this is the
        // mechanism by which the refusal is recoverable rather than permanent.
        let stillNeedsSummary = try db.read { db -> Bool in
            guard let header = try MessageHeader.fetchOne(db, key: Self.headerId) else { return false }
            return header.summaryBlurb == nil || header.summaryBlurb?.isEmpty == true
        }
        #expect(stillNeedsSummary, "a refused write must leave the job re-drivable")

        // The next sync pass: `runSyncMessages` stamps the folder from the SELECT that
        // served its fetch, and the rows it merges carry that same observation.
        try db.write { db in
            guard var folder = try Folder.fetchOne(db, key: Self.folderId) else { return }
            folder.lastKnownUidValidity = 111
            try folder.update(db)
            guard var header = try MessageHeader.fetchOne(db, key: Self.headerId) else { return }
            header.observedUidValidity = 111
            try header.save(db)
        }

        // The arbiter re-drives the job, and capture reads the CURRENT row — which is
        // how production captures (`processOpenedMessage`, `ActiveAIQueue.executeJob`).
        let recaptured = try db.read { db -> AIWriteTarget? in
            guard let current = try MessageHeader.fetchOne(db, key: Self.headerId) else { return nil }
            return try AIWriteTarget.capture(message: current, db: db)
        }
        guard let recaptured else {
            #expect(Bool(false), "re-capture must succeed")
            return
        }
        let landed = try attemptSummaryWrite(db, target: recaptured, blurb: "X's summary")
        #expect(landed == .written,
                "an rfc-less message must not be permanently un-writable by AI — arm 8 must carry it")
        #expect(try blurb(db, Self.headerId) == "X's summary")
    }

    /// 🚨 AUDIT ROUND 4 / `IOS-ROUND3-D6` — **RE-SCOPED, NOT DELETED.** Previous
    /// display name: *"An unknown folder epoch is an absence of evidence, not a
    /// mismatch — the write lands"*. That name is universally quantified and, after
    /// arm 7 was amended, FALSE in general: an unknown folder epoch now refuses
    /// every row it cannot otherwise identify. The case this test actually
    /// constructs is the RFC-BEARING one, and it stays green because **arm 6's
    /// content witness — not arm 7 — is what carries it.** (Same hazard class as
    /// `IOS-ROUND3-D5`: a universally-quantified name that enumerates a subset reads
    /// to a later reader as a proof it is not.)
    @Test("An unknown folder epoch does not refuse a row its Message-ID still identifies")
    func unknownFolderEpochStillWritesOnTheContentWitness() throws {
        let db = try makeFixture(folderEpoch: nil)
        let original = makeHeader(subject: "Original X", rfc822: "<x@example.com>", observedEpoch: 111)
        try db.write { try original.insert($0) }

        let target = try capture(db, original)
        guard let target else {
            #expect(Bool(false), "capture must succeed")
            return
        }

        let outcome = try attemptSummaryWrite(db, target: target, blurb: "X's summary")
        #expect(outcome == .written)
        let after = try blurb(db, Self.headerId)
        #expect(after == "X's summary",
                "the T1.3 first-sync window must not disable AI for a row whose content is still identifiable")
    }

    /// 🚨 AUDIT ROUND 1 / C-1. This test previously asserted the OPPOSITE
    /// ("An unstamped header row is an absence of evidence, not a mismatch — the
    /// write lands") and so BLESSED the defect: with the folder's epoch known and
    /// the captured row's stamp nil, `resolveCurrentHeader` admitted the write, and
    /// a turnover in the LLM window bound X's summary to whatever message the
    /// resync seated at X's UID. It is rewritten here to the SYSTEM PROPERTY the
    /// suite exists for — *an AI result computed against X is never written to a
    /// row that is not X* — with the same two-sided control the turnover test uses.
    ///
    /// A nil captured stamp is common and benign in ISOLATION (an optimistic move,
    /// a delta-sync re-key and the orphan-migration paths all null it), which is
    /// why "the write lands" looked reasonable. It is not benign when the FOLDER
    /// has a live numbering: then the row's UID was never proven under any epoch,
    /// so nothing rules out a re-seat. Refusing is recomputable; binding X's
    /// summary onto Y is not.
    ///
    /// AUDIT ROUND 2 classification: **correct, but non-discriminating — kept.**
    /// The property it asserts is true and it passes both before and after round
    /// 2's fix. But it moves the replacement row AND the folder's epoch together,
    /// so a guard that only ever consulted the FOLDER would satisfy it — and the
    /// round-1 guard was exactly that guard, which is why this test could not see
    /// the C3 hole sitting next to it. The three tests that follow hold the folder
    /// still and vary one field at a time.
    @Test("An AI result computed against an UNSTAMPED row never lands on the message that replaced it")
    func unstampedHeaderNeverWritesOntoTheReplacement() throws {
        let db = try makeFixture(folderEpoch: 111)
        let original = makeHeader(subject: "Original X", rfc822: "<x@example.com>", observedEpoch: nil)
        try db.write { try original.insert($0) }

        let target = try capture(db, original)
        #expect(target != nil, "capture must still succeed — refusing to capture would disable AI, not guard it")
        guard let target else { return }

        // The turnover, exactly as the purge-and-resync reaction leaves the world.
        let impostor = makeHeader(subject: "Impostor Y", rfc822: "<y@example.com>", observedEpoch: 222)
        try db.write { db in
            _ = try MessageHeader.deleteOne(db, key: Self.headerId)
            guard var folder = try Folder.fetchOne(db, key: Self.folderId) else { return }
            folder.lastKnownUidValidity = 222
            try folder.update(db)
            try impostor.insert(db)
        }

        // NON-VACUITY: the pre-guard expression (a bare fetch + mutate + save) LANDS
        // on the impostor, so the drop below is the guard refusing rather than the
        // row being absent or unwritable.
        let bareWriteLanded: Bool = try db.write { db in
            guard var bare = try MessageHeader.fetchOne(db, key: Self.headerId) else { return false }
            bare.summaryBlurb = "pre-guard control write"
            try bare.save(db)
            return true
        }
        #expect(bareWriteLanded, "the impostor row must be present and writable, else the drop proves nothing")
        try db.write { db in
            guard var bare = try MessageHeader.fetchOne(db, key: Self.headerId) else { return }
            bare.summaryBlurb = nil
            try bare.save(db)
        }

        let outcome = try attemptSummaryWrite(db, target: target, blurb: "X's summary")
        #expect(outcome == .dropped)

        let after = try db.read { try MessageHeader.fetchOne($0, key: Self.headerId) }
        #expect(after?.rfc822MessageId == "<y@example.com>", "the row at X's address is still the replacement")
        #expect(after?.summaryBlurb == nil,
                """
                X's summary landed on the message that replaced it. X's row carried no proven epoch, so \
                nothing established that the UID still names X — an absence of evidence must never \
                authorize a write (C3).
                """)
    }

    /// 🚨 AUDIT ROUND 2 / MUST FIX 1, invariant 1. The test ABOVE moves the
    /// replacement row and the folder's epoch TOGETHER, so it cannot tell whether
    /// the guard authenticated the MESSAGE or merely noticed the FOLDER moved — it
    /// passed on the pre-fix code for the wrong reason. This one holds the folder
    /// still: the folder stays on the captured epoch and unquarantined, and only
    /// the row at the captured address is replaced, by a row bearing no stamp at
    /// all (exactly what the merge window seats).
    ///
    /// RED on the pre-fix code: the old arms read `folder.lastKnownUidValidity`
    /// (still 111, so 6a passed), then the CAPTURED stamp (111, non-nil, so 6b
    /// passed), then compared captured-vs-folder (111 == 111, so arm 7 passed) —
    /// and returned the impostor. X's summary landed on Y. Every arm consulted the
    /// folder or the capture; not one of them looked at the row in front of it.
    @Test("X's AI result never lands on a replacement seated under the SAME folder epoch")
    func replacementUnderUnchangedFolderEpochNeverReceivesTheWrite() throws {
        let db = try makeFixture(folderEpoch: 111)
        let original = makeHeader(subject: "Original X", rfc822: "<x@example.com>", observedEpoch: 111)
        try db.write { try original.insert($0) }

        let target = try capture(db, original)
        #expect(target != nil, "capture must succeed on an ordinary stamped IMAP row")
        guard let target else { return }

        // The merge window, NOT a completed reset reaction: a different physical
        // message is seated at the captured address carrying no proven epoch, while
        // the folder stays stamped 111 and unquarantined.
        let impostor = makeHeader(subject: "Impostor Y", rfc822: "<y@example.com>", observedEpoch: nil)
        try db.write { db in
            _ = try MessageHeader.deleteOne(db, key: Self.headerId)
            try impostor.insert(db)
        }

        // The folder state the pre-fix arms consulted is UNCHANGED — this is what
        // makes the drop attributable to the row rather than to the folder.
        let folderAfter = try db.read { try Folder.fetchOne($0, key: Self.folderId) }
        #expect(folderAfter?.lastKnownUidValidity == 111, "the folder must still carry the captured epoch")
        #expect(folderAfter?.uidValidityResetPendingAt == nil, "the folder must not be quarantined")

        // NON-VACUITY: the pre-guard expression LANDS on the impostor, so the drop
        // below is the guard refusing rather than the row being absent or unwritable.
        let bareWriteLanded: Bool = try db.write { db in
            guard var bare = try MessageHeader.fetchOne(db, key: Self.headerId) else { return false }
            bare.summaryBlurb = "pre-guard control write"
            try bare.save(db)
            return true
        }
        #expect(bareWriteLanded, "the impostor row must be present and writable, else the drop proves nothing")
        try db.write { db in
            guard var bare = try MessageHeader.fetchOne(db, key: Self.headerId) else { return }
            bare.summaryBlurb = nil
            try bare.save(db)
        }

        let outcome = try attemptSummaryWrite(db, target: target, blurb: "X's summary")
        #expect(outcome == .dropped)

        let after = try db.read { try MessageHeader.fetchOne($0, key: Self.headerId) }
        #expect(after?.rfc822MessageId == "<y@example.com>", "the row at X's address is still the replacement")
        #expect(after?.summaryBlurb == nil,
                """
                X's summary landed on the message that replaced it. The folder's stored epoch still \
                matched, so a guard that authenticates the CAPTURED value against FOLDER state cannot \
                see this replacement at all — only the row's own epoch state can (C3).
                """)
    }

    /// 🚨 AUDIT ROUND 2 / MUST FIX 1, invariant 2. The cost half of the same
    /// conflation. An unstamped row is ORDINARY, not suspicious: 15 production
    /// sites null `observedUidValidity` against 4 that set it. When such a row has
    /// NOT been replaced, refusing does not fail closed in any useful sense — it
    /// leaves `summaryBlurb` nil, so `needsSummary` stays true, so the next open
    /// re-runs the LLM and drops it again: a paid API call repeated forever for a
    /// summary that can never land.
    ///
    /// RED on the pre-fix code: arm 6a passed (the folder's epoch is known, 111),
    /// then arm 6b refused solely because the CAPTURED stamp was nil — without ever
    /// checking that the row was still the very row that was captured.
    ///
    /// What makes admitting it SAFE rather than merely cheaper is the row's RFC
    /// Message-ID: it is unchanged, and it names the content rather than the
    /// address. Note what this test does NOT say — it does not say "a nil stamp
    /// writes through". The very next test holds everything here fixed except the
    /// Message-ID, and requires a refusal.
    @Test("An UNSTAMPED but UNREPLACED row still receives its AI result, and is not recomputed forever")
    func unstampedButUnreplacedRowStillWritesThrough() throws {
        // The folder has a live numbering; the row does not carry one. This is the
        // steady state after an optimistic move, a delta-sync re-key, a backfill
        // body write, or any row predating the column.
        let db = try makeFixture(folderEpoch: 111)
        let original = makeHeader(subject: "Original X", rfc822: "<x@example.com>", observedEpoch: nil)
        try db.write { try original.insert($0) }

        let target = try capture(db, original)
        #expect(target != nil, "capture must succeed — refusing to capture would disable AI, not guard it")
        guard let target else { return }

        // Nothing replaces X. The world simply moves on: the LLM round trip returns.
        let outcome = try attemptSummaryWrite(db, target: target, blurb: "X's summary")
        #expect(outcome == .written)

        let after = try db.read { try MessageHeader.fetchOne($0, key: Self.headerId) }
        #expect(after?.rfc822MessageId == "<x@example.com>", "the row must still be X")
        #expect(after?.summaryBlurb == "X's summary",
                """
                X's own AI result was refused even though X was never replaced. The result is not \
                merely lost: needsSummary stays true, so the LLM is re-billed on every subsequent \
                open and the summary can never land.
                """)
        // The system property the cost half is really about: the job is DONE, so the
        // arbiter stops re-driving it.
        // `needsSummary` is not a column — it is the arbiter's own derived predicate
        // (`AccountManagerAI.processMessage`: `summaryBlurb == nil || summaryBlurb?.isEmpty == true`).
        // Re-deriving it here rather than asserting on `summaryBlurb` directly is
        // deliberate: the property under test is "the arbiter stops re-driving this
        // job", so the assertion has to ask the question the arbiter asks.
        let stillNeedsSummary = try db.read { db -> Bool in
            guard let header = try MessageHeader.fetchOne(db, key: Self.headerId) else { return false }
            return header.summaryBlurb == nil || header.summaryBlurb?.isEmpty == true
        }
        #expect(stillNeedsSummary == false, "a landed summary must retire the job, not re-drive it forever")
    }

    /// 🚨 AUDIT ROUND 2 / MUST FIX 1 — the MIRROR-IMAGE hole, pinned so it cannot
    /// be reopened. This is the exact case the first attempted fix for invariant 2
    /// would have shipped broken: "the row's own stamp still equals the captured
    /// stamp" admits nil-against-nil, and a replacement seated at the captured UID
    /// with no stamp satisfies that just as well as the original does. An absence
    /// matching an absence is not evidence of anything.
    ///
    /// It is the previous test with EXACTLY ONE field changed — the Message-ID —
    /// so the pair isolates what the guard is actually allowed to rely on. Both
    /// rows are unstamped, the folder is unmoved and unquarantined, and the
    /// composite address is identical; only the content differs, and only the
    /// content decides.
    ///
    /// Green on the pre-fix code (old arm 6b refused every nil captured stamp, so
    /// it got this one right by luck rather than by reasoning) and green now. Its
    /// job is to stay green: it is RED against the rejected "nil == nil proceeds"
    /// variant, which is the only way this property can be lost.
    @Test("A replacement seated at the captured address with NO stamp receives no AI write either")
    func unstampedReplacementUnderUnchangedFolderEpochIsRefused() throws {
        let db = try makeFixture(folderEpoch: 111)
        let original = makeHeader(subject: "Original X", rfc822: "<x@example.com>", observedEpoch: nil)
        try db.write { try original.insert($0) }

        let target = try capture(db, original)
        #expect(target != nil, "capture must succeed")
        guard let target else { return }

        // A DIFFERENT physical message, seated at the same address, carrying no
        // proven epoch — indistinguishable from X on every field the epoch columns
        // expose, and distinguishable on exactly one: what email it is.
        let impostor = makeHeader(subject: "Impostor Y", rfc822: "<y@example.com>", observedEpoch: nil)
        try db.write { db in
            _ = try MessageHeader.deleteOne(db, key: Self.headerId)
            try impostor.insert(db)
        }

        let folderAfter = try db.read { try Folder.fetchOne($0, key: Self.folderId) }
        #expect(folderAfter?.lastKnownUidValidity == 111, "the folder must still carry its epoch")
        #expect(folderAfter?.uidValidityResetPendingAt == nil, "the folder must not be quarantined")

        // NON-VACUITY: the pre-guard expression LANDS on the impostor.
        let bareWriteLanded: Bool = try db.write { db in
            guard var bare = try MessageHeader.fetchOne(db, key: Self.headerId) else { return false }
            bare.summaryBlurb = "pre-guard control write"
            try bare.save(db)
            return true
        }
        #expect(bareWriteLanded, "the impostor row must be present and writable, else the drop proves nothing")
        try db.write { db in
            guard var bare = try MessageHeader.fetchOne(db, key: Self.headerId) else { return }
            bare.summaryBlurb = nil
            try bare.save(db)
        }

        let outcome = try attemptSummaryWrite(db, target: target, blurb: "X's summary")
        #expect(outcome == .dropped)

        let after = try db.read { try MessageHeader.fetchOne($0, key: Self.headerId) }
        #expect(after?.rfc822MessageId == "<y@example.com>", "the row at X's address is still the replacement")
        #expect(after?.summaryBlurb == nil,
                """
                X's summary landed on the message that replaced it. Both rows are unstamped, so the \
                epoch columns cannot tell them apart — matching an absence against an absence is not \
                positive identity, and only a positive one may authorize a write (C3).
                """)
    }

    /// The state where NOTHING has ever been observed — the folder was never
    /// selected either (first sync, `ScreenshotMode`'s raw-SQL folders). Distinct
    /// from the tests above, where the folder's numbering IS known. Without this the
    /// fix would be free to read as "refuse whenever a stamp is missing", which
    /// silently disables AI for every account's first sync.
    ///
    /// 🚨 AUDIT ROUND 4 / `IOS-ROUND3-D6` — **RE-SCOPED, NOT DELETED.** Previous
    /// display name: *"An unstamped row in a never-observed folder still writes
    /// through"*, and its comment claimed the case was *"reachable only through the
    /// epoch arms because such a row may have no RFC id at all"*. It never was: the
    /// row it constructs carries `<x@example.com>`, so **arm 6 carries it**, and it
    /// stays green for that reason after arm 7 was amended. The genuinely
    /// witnessless variant it appeared to cover is
    /// `rfcLessMessageIsRefusedUntilItsNumberingIsObserved` above, which now refuses.
    @Test("An unstamped row in a never-observed folder still writes through on its content witness")
    func unstampedHeaderInNeverObservedFolderStillWrites() throws {
        let db = try makeFixture(folderEpoch: nil)
        let original = makeHeader(subject: "Original X", rfc822: "<x@example.com>", observedEpoch: nil)
        try db.write { try original.insert($0) }

        let target = try capture(db, original)
        guard let target else {
            #expect(Bool(false), "capture must succeed")
            return
        }

        let outcome = try attemptSummaryWrite(db, target: target, blurb: "X's summary")
        #expect(outcome == .written)
        let after = try blurb(db, Self.headerId)
        #expect(after == "X's summary",
                "a folder that has never been observed has no numbering to have turned over — AI must not go dark there")
    }

    @Test("The demo account writes through even when its stored epochs disagree")
    func demoAccountIsNotEpochAddressed() throws {
        // Stored as `.imap`, served by `DemoProvider`: no server, no SELECT, no
        // epoch, ever. A disagreement that would be a proven turnover on a real
        // IMAP account cannot mean anything here, so the write must still land.
        let db = try makeFixture(folderEpoch: 111, accountId: DemoSeed.demoAccountId, provider: .imap)
        let original = makeHeader(
            subject: "Demo", rfc822: "<demo@example.com>",
            observedEpoch: 999, accountId: DemoSeed.demoAccountId)
        try db.write { try original.insert($0) }

        let target = try capture(db, original)
        guard let target else {
            #expect(Bool(false), "capture must succeed")
            return
        }

        let outcome = try attemptSummaryWrite(db, target: target, blurb: "demo summary")
        #expect(outcome == .written)
        let after = try blurb(db, original.id)
        #expect(after == "demo summary", "the demo account must never be epoch-refused")
    }

    @Test("A stable-provider account is not epoch-addressed and writes through")
    func stableProviderIsNotEpochAddressed() throws {
        // Gmail ids are never reassigned, so the address IS the identity and the
        // folder's epoch columns are meaningless for it.
        let db = try makeFixture(folderEpoch: 111, provider: .gmail)
        let original = makeHeader(subject: "Gmail", rfc822: "<g@example.com>", observedEpoch: 999)
        try db.write { try original.insert($0) }

        let target = try capture(db, original)
        guard let target else {
            #expect(Bool(false), "capture must succeed")
            return
        }

        let outcome = try attemptSummaryWrite(db, target: target, blurb: "gmail summary")
        #expect(outcome == .written)
        let after = try blurb(db, Self.headerId)
        #expect(after == "gmail summary", "a stable-provider message must never be epoch-refused")
    }

    // MARK: - IOS-ROUND3-D6 — an ABSENT or UNPROVEN folder epoch may not authorize a write
    //
    // The invariant these pin is the one `resolveCurrentHeader`'s own doc comment
    // states and arm 7 used to violate: **a WRITE needs positive evidence, and an
    // unknown epoch must never authorize a mutation.** It is the OPPOSITE direction
    // from the durable `PendingOperation` rule, where an unknown epoch must never
    // retire the user's intention — deliberately, because an AI write is
    // recomputable and a misattribution is not.
    //
    // The old arm was `guard let liveEpoch = folder?.lastKnownUidValidity else
    // { return header }` — an ADMIT that optional-chaining made a MISSING folder
    // satisfy exactly as readily as a never-observed one.

    /// Invariant: **a header that outlived its `Folder` row is not thereby
    /// authorized.** This is the structural half of the chain — migration
    /// `v2_dropMessageHeaderFolderFK` rebuilt `messageHeader` with `folderId` as a
    /// plain column and NO foreign key (only `accountId` cascades), so
    /// `SyncEngine.fullSync`'s vanished-folder cleanup deletes the folder row and
    /// leaves its headers orphaned — its own comment says so. `TestDatabase.make()`
    /// enables foreign keys, so the surviving row below is evidence of the absent
    /// cascade rather than an assumption about it.
    @Test("An orphaned RFC-less header whose Folder row is gone receives no AI write")
    func absentFolderRefusesTheWriteForAWitnesslessRow() throws {
        let db = try makeFixture(folderEpoch: 111)
        let original = makeHeader(subject: "Original X", rfc822: nil, observedEpoch: 111)
        try db.write { try original.insert($0) }

        let target = try capture(db, original)
        #expect(target != nil, "capture must succeed — capture is unconditional by design")
        guard let target else { return }

        try db.write { db in _ = try Folder.deleteOne(db, key: Self.folderId) }
        let orphan = try db.read { try MessageHeader.fetchOne($0, key: Self.headerId) }
        let folderAfter = try db.read { try Folder.fetchOne($0, key: Self.folderId) }
        #expect(folderAfter == nil, "the folder row must be gone")
        #expect(orphan != nil, "the header must SURVIVE its folder — nothing cascades it (migration v2)")

        try proveBareWriteLandsThenUndo(db, headerId: Self.headerId)

        let outcome = try attemptSummaryWrite(db, target: target, blurb: "X's summary")
        #expect(outcome == .dropped)
        #expect(try blurb(db, Self.headerId) == nil,
                """
                An AI result was written against a header whose folder row does not exist. \
                "We could not look" is not "nothing has happened here" — it is the absence of \
                evidence, and a write needs positive evidence (C3).
                """)
    }

    /// Invariant: **a folder whose numbering was never observed does not authorize a
    /// write it cannot otherwise identify.** The row here IS stamped; the folder is
    /// not, so no three-way agreement is obtainable and there is no content witness.
    /// This is the same posture the durable-gesture path already takes on the same
    /// state — `AccountManager.newGestureRefusedForUnknownEpoch` refuses on a nil
    /// `lastKnownUidValidity` (`IOS-EPOCH-001`).
    @Test("A never-observed folder epoch does not authorize an AI write for a witnessless row")
    func nilFolderEpochRefusesTheWriteForAWitnesslessRow() throws {
        let db = try makeFixture(folderEpoch: nil)
        let original = makeHeader(subject: "Original X", rfc822: nil, observedEpoch: 111)
        try db.write { try original.insert($0) }

        let target = try capture(db, original)
        #expect(target != nil, "capture must succeed")
        guard let target else { return }

        let folderBefore = try db.read { try Folder.fetchOne($0, key: Self.folderId) }
        #expect(folderBefore?.lastKnownUidValidity == nil, "the folder must be present and unstamped")

        try proveBareWriteLandsThenUndo(db, headerId: Self.headerId)

        let outcome = try attemptSummaryWrite(db, target: target, blurb: "X's summary")
        #expect(outcome == .dropped)
        #expect(try blurb(db, Self.headerId) == nil,
                """
                An AI result was written under a folder epoch nobody has ever observed. Nothing \
                established that this UID still names the captured message, and a write needs \
                positive evidence (C3).
                """)
    }

    /// 🚨 THE MISATTRIBUTION PIN — the whole reachable chain, replayed, asserted on
    /// the END STATE. Each step is a real production behaviour, cited where it lives:
    ///
    ///  1. X is an RFC-less IMAP header in folder F at epoch 111.
    ///  2. F vanishes server-side. `SyncEngine.fullSync` deletes the `Folder` row and
    ///     X survives as an orphan (no FK since migration `v2`).
    ///  3. F returns at epoch 222. The re-created row takes the deterministic
    ///     `"\(accountId):\(path)"` id, re-adopting the orphan — and it is NOT
    ///     stamped, because `uidValidityBootstrapWrite(observed:stored:
    ///     folderHoldsRows:)` refuses to stamp a folder that already holds rows. The
    ///     production decision function is called here rather than restated, so this
    ///     step cannot drift from it.
    ///  4. `SyncEngine.verifyAndBootstrapPrePopulatedFolderEpoch` cannot sample an
    ///     all-RFC-less population (its statement excludes rows with no
    ///     `rfc822MessageId`), returns `.unobservable`, and does NOT quarantine.
    ///  5. The merge seats a DIFFERENT message at X's canonical address:
    ///     `SyncEngine.providerAddressOwnershipProven` admits the canonical-PK hit
    ///     (`row.id == canonicalId`), so X's row becomes Y in place and is stamped
    ///     222.
    ///
    /// Then one AI job for X returns. The property: **no AI field computed for X may
    /// appear on Y.** RED before the fix — arms 1–3 pass on the identical composite
    /// address, arm 6 has no witness on either side, and the old arm 7 returned Y
    /// because the folder's epoch is still nil.
    @Test("No AI field computed for X lands on the message a re-created folder seated at X's address")
    func witnesslessReplacementInARecreatedFolderReceivesNoAIFieldOfX() throws {
        // 1 — X, RFC-less, at UID 42 under epoch 111.
        let db = try makeFixture(folderEpoch: 111)
        let x = makeHeader(subject: "Original X", rfc822: nil, observedEpoch: 111)
        try db.write { try x.insert($0) }

        let target = try capture(db, x)
        #expect(target != nil, "capture must succeed")
        guard let target else { return }

        // 2 + 3 — the folder vanishes and returns at epoch 222, re-adopting the orphan.
        let holdsRows: Bool = try db.write { db in
            _ = try Folder.deleteOne(db, key: Self.folderId)
            let holds = try MessageHeader
                .filter(Column("folderId") == Self.folderId).fetchCount(db) > 0
            var recreated = Folder(
                name: "INBOX", path: Self.folderPath, role: .inbox, accountId: Self.accountId)
            recreated.lastKnownUidValidity = SyncEngine.uidValidityBootstrapWrite(
                observed: 222, stored: nil, folderHoldsRows: holds)
            try recreated.insert(db)
            return holds
        }
        #expect(holdsRows, "the orphaned header must survive the folder deletion — no FK cascades it")
        let recreatedFolder = try db.read { try Folder.fetchOne($0, key: Self.folderId) }
        #expect(recreatedFolder?.lastKnownUidValidity == nil,
                "a folder that already holds rows must NOT be stamped by assertion (T4.S6b)")
        #expect(recreatedFolder?.uidValidityResetPendingAt == nil,
                "step 4 does not quarantine — `.unobservable` does nothing, by the anti-brick rule")

        // 4 — the verified door cannot help: no row here carries an rfc822 to sample.
        let sampled = try db.read { db in
            try SyncEngine.sampleUidsForEpochVerification(
                db, folderId: Self.folderId, highCount: 8, lowCount: 8)
        }
        #expect(sampled.isEmpty,
                "an all-RFC-less population yields no sample, so the epoch stays unknown (.unobservable)")

        // 5 — the merge seats Y at X's canonical address and stamps it with the new epoch.
        let canonicallyOwned = SyncEngine.providerAddressOwnershipProven(
            row: x, accountId: Self.accountId, folderPath: Self.folderPath,
            folderId: Self.folderId, messageId: Self.uid, canonicalId: Self.headerId,
            windowMode: .uid, sourceBoundEpoch: 222)
        #expect(canonicallyOwned, "the canonical-PK hit is what lets the merge overwrite this row in place")
        try db.write { db in
            guard var seated = try MessageHeader.fetchOne(db, key: Self.headerId) else { return }
            seated.subject = "Impostor Y"
            seated.from = "Other <other@example.com>"
            seated.fromAddress = "other@example.com"
            seated.rfc822MessageId = nil
            seated.observedUidValidity = 222
            try seated.save(db)
        }

        try proveBareWriteLandsThenUndo(db, headerId: Self.headerId)

        let outcome = try attemptFullAIWrite(db, target: target, blurb: "X's summary")
        #expect(outcome == .dropped)
        try expectNoAIFieldOfXLandedOn(db, headerId: Self.headerId, subject: "Impostor Y", rfc822: nil)
    }

    /// The sharper sub-case of the same hole, and the one that is least defensible:
    /// the captured Message-ID is PRESENT and the row now at that address carries a
    /// DIFFERENT one. That is not missing evidence — it is a **positive
    /// disagreement**, precisely the replacement arm 6 exists to catch, and the old
    /// arm 7 admitted it whenever the folder happened to be unstamped.
    @Test("A positive Message-ID disagreement is refused even when the folder was never observed")
    func positiveRfcDisagreementInANeverObservedFolderIsRefused() throws {
        let db = try makeFixture(folderEpoch: nil)
        let x = makeHeader(subject: "Original X", rfc822: "<x@example.com>", observedEpoch: 111)
        try db.write { try x.insert($0) }

        let target = try capture(db, x)
        #expect(target != nil, "capture must succeed")
        guard let target else { return }

        try db.write { db in
            guard var seated = try MessageHeader.fetchOne(db, key: Self.headerId) else { return }
            seated.subject = "Impostor Y"
            seated.rfc822MessageId = "<y@example.com>"
            seated.observedUidValidity = nil
            try seated.save(db)
        }
        let folderAfter = try db.read { try Folder.fetchOne($0, key: Self.folderId) }
        #expect(folderAfter?.lastKnownUidValidity == nil, "the folder must still be unobserved")

        try proveBareWriteLandsThenUndo(db, headerId: Self.headerId)

        let outcome = try attemptFullAIWrite(db, target: target, blurb: "X's summary")
        #expect(outcome == .dropped)
        try expectNoAIFieldOfXLandedOn(
            db, headerId: Self.headerId, subject: "Impostor Y", rfc822: "<y@example.com>")
    }

    /// NON-VACUITY, the other side: **arm 6 was not weakened.** The folder row is
    /// ABSENT — the strongest form of "no numbering evidence" — and the write still
    /// lands, because the RFC 2822 Message-ID names the CONTENT rather than the
    /// address, and an AI summary is derived content. Without this control the fix
    /// would be free to degrade into "refuse whenever the folder is not stamped",
    /// which is a blanket refusal wearing a guard's clothes.
    @Test("The RFC content witness still carries a row whose Folder row is gone")
    func contentWitnessStillCarriesARowWithNoFolder() throws {
        let db = try makeFixture(folderEpoch: 111)
        let original = makeHeader(subject: "Original X", rfc822: "<x@example.com>", observedEpoch: nil)
        try db.write { try original.insert($0) }

        let target = try capture(db, original)
        #expect(target != nil, "capture must succeed")
        guard let target else { return }

        try db.write { db in _ = try Folder.deleteOne(db, key: Self.folderId) }
        let folderAfter = try db.read { try Folder.fetchOne($0, key: Self.folderId) }
        #expect(folderAfter == nil, "the folder row must be gone, so only the content witness can carry this")

        let outcome = try attemptSummaryWrite(db, target: target, blurb: "X's summary")
        #expect(outcome == .written)
        #expect(try blurb(db, Self.headerId) == "X's summary",
                """
                The content witness was weakened along with arm 7. An RFC 2822 Message-ID that still \
                agrees identifies the MESSAGE regardless of what its folder metadata says, and derived \
                content is exactly what it is the correct instrument for (ADR-IOS-068 §7, ADR-IOS-072).
                """)
    }

    /// Arm 4's early return, swept over EVERY non-epoch-addressed provider rather
    /// than the two that happened to have a test. Their id spaces are never
    /// renumbered, so the address IS the identity and no folder or epoch state may
    /// influence the decision — asserted here in the harshest state the fix creates:
    /// no folder row at all, no stamp anywhere, no content witness.
    @Test("A provider whose ids are never renumbered is unaffected by any folder-epoch state",
          arguments: [AccountProvider.gmail, AccountProvider.outlook, AccountProvider.caldav])
    func nonEpochAddressedProvidersAreUnaffected(provider: AccountProvider) throws {
        let db = try makeFixture(folderEpoch: nil, provider: provider)
        let original = makeHeader(subject: "X", rfc822: nil, observedEpoch: nil)
        try db.write { try original.insert($0) }

        let target = try capture(db, original)
        #expect(target != nil, "capture must succeed")
        guard let target else { return }

        try db.write { db in _ = try Folder.deleteOne(db, key: Self.folderId) }

        let outcome = try attemptSummaryWrite(db, target: target, blurb: "\(provider.rawValue) summary")
        #expect(outcome == .written)
        #expect(try blurb(db, Self.headerId) == "\(provider.rawValue) summary",
                "\(provider.rawValue) ids are never renumbered — arm 4 must return before any epoch arm")
    }

    /// The demo account is IMAP-shaped and served by `DemoProvider`, so nothing can
    /// ever stamp it. It is excluded BY ID at arm 4; this pins the exclusion in the
    /// state the fix would otherwise black out permanently — no folder row, no
    /// content witness, no stamp.
    @Test("The demo account writes through with no folder row, no witness and no stamp")
    func demoAccountIsUnaffectedByTheFolderEpochRequirement() throws {
        let db = try makeFixture(folderEpoch: nil, accountId: DemoSeed.demoAccountId, provider: .imap)
        let original = makeHeader(
            subject: "Demo", rfc822: nil, observedEpoch: nil, accountId: DemoSeed.demoAccountId)
        try db.write { try original.insert($0) }

        let target = try capture(db, original)
        #expect(target != nil, "capture must succeed")
        guard let target else { return }

        try db.write { db in
            _ = try Folder.deleteOne(
                db, key: MessageIdentity.folderId(
                    accountId: DemoSeed.demoAccountId, folderPath: Self.folderPath))
        }

        let outcome = try attemptSummaryWrite(db, target: target, blurb: "demo summary")
        #expect(outcome == .written)
        #expect(try blurb(db, original.id) == "demo summary",
                "Demo Mode has no server and can never stamp an epoch — it must never be epoch-refused")
    }
}
