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

    @Test("An rfc-less message with no epoch anywhere is still captured and still written")
    func rfcLessMessageIsStillWritten() throws {
        // The exact shape `v2final`'s `AIWriteTarget.capture` REFUSES
        // (`normalizedRfc == nil && observedUidValidity == nil`). On v3 that shape is
        // the demo account, the ScreenshotMode folders and the whole first-sync
        // window, so refusing would disable AI for them permanently and silently.
        let db = try makeFixture(folderEpoch: nil)
        let original = makeHeader(subject: "No RFC", rfc822: nil, observedEpoch: nil)
        try db.write { try original.insert($0) }

        let target = try capture(db, original)
        #expect(target != nil, "capture must NOT refuse an rfc-less row with no epoch baseline")
        guard let target else { return }

        let outcome = try attemptSummaryWrite(db, target: target, blurb: "X's summary")
        #expect(outcome == .written)
        let after = try blurb(db, Self.headerId)
        #expect(after == "X's summary", "an rfc-less message must not be permanently un-writable by AI")
    }

    @Test("An unknown folder epoch is an absence of evidence, not a mismatch — the write lands")
    func unknownFolderEpochStillWrites() throws {
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
        #expect(after == "X's summary", "T1.3 first-sync / demo / screenshot state must not disable AI")
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

    /// The other half of C-1's split, and the reason 6a is evaluated BEFORE 6b: a
    /// row that is unstamped because the FOLDER was never observed either (first
    /// sync, `ScreenshotMode`'s raw-SQL folders) must still be written. Without
    /// this the fix above would read as "refuse whenever the stamp is nil", which
    /// silently disables AI for every account's first sync.
    @Test("An unstamped row in a never-observed folder still writes through")
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
}
