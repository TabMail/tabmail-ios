/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
import Synchronization
@testable import TabMail

/// ADR-IOS-056 coverage: the active body/AI flush writes (`ActiveBodyQueue`'s wrap of
/// the shared `BodyFetchProcessor`, and `ActiveAIQueue`'s own pool) execute at
/// `.normal` — above deep backfill (`.background`), below the merge/user-action/badge
/// tier (`.priority`) — and a privileged merge context still wins regardless.
///
/// `.serialized`: swaps the process-wide `AppDatabase.shared` singleton and installs a
/// DEBUG-only test observer on `DatabaseWriteQueue.shared`, mirroring the established
/// convention in `InboxListReaderIntegrationTests` / `OnDemandBodyFetchIntegrationTests`.
/// All throwing calls in each test happen either BEFORE the observer is installed or
/// AFTER it is cleared, so the explicit (non-`defer`) `clearObserver()` call always
/// runs — no unstructured `Task` is needed (and none is used) around it, which would
/// otherwise risk racing the NEXT test's `installObserver()`.
@Suite("BodyFetchProcessor / ActiveAIQueue write tier (ADR-IOS-056)", .serialized, .processGlobalState)
struct WriteTierRoutingTests {

    // MARK: - Helpers

    /// Temp file-backed DatabasePool with all migrations applied (DatabasePool
    /// requires WAL, not available with `:memory:`) — same recipe as
    /// `InboxListReaderIntegrationTests`/`OnDemandBodyFetchIntegrationTests`.
    private func makeTestPool(suspendable: Bool = false) throws -> (pool: DatabasePool, dir: URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("test.sqlite").path
        var config = Configuration()
        config.foreignKeysEnabled = true
        config.observesSuspensionNotifications = suspendable
        let pool = try DatabasePool(path: path, configuration: config)
        try AppDatabase.runMigrations(on: pool)
        return (pool, dir)
    }

    /// Swaps in a fresh `AppDatabase.shared` backed by a temp pool, with one message
    /// header fixture inserted. Returns the header and a restore closure (swaps
    /// `AppDatabase.shared` back AND removes the temp dir) the caller MUST run in
    /// `defer` — `defer { restore() }`, nothing else needed.
    private func makeTestDB(suspendable: Bool = false) throws -> (header: MessageHeader, restore: () -> Void) {
        let (pool, dir) = try makeTestPool(suspendable: suspendable)
        let appDb = try AppDatabase(dbPool: pool)
        let previous = AppDatabase.shared.withLock { current -> AppDatabase? in
            let prev = current; current = appDb; return prev
        }
        var account = Account(emailAddress: "tier-test@example.com", displayName: "Tier Test", provider: .gmail)
        account.id = "acc1"
        let folder = Folder(name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")
        var header = MessageHeader(
            messageId: "tier_\(UUID().uuidString)",
            subject: "Tier test subject",
            from: "sender@example.com",
            fromAddress: "sender@example.com",
            to: "recipient@example.com",
            date: Date(),
            snippet: "",
            folderId: "acc1:INBOX",
            accountId: "acc1",
            folderPath: "INBOX",
            isInInbox: true
        )
        header.headerComplete = true
        try pool.write { db in
            try account.insert(db)
            try folder.insert(db)
            try header.insert(db)
        }
        let restore: () -> Void = {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
        }
        return (header, restore)
    }

    /// Install `record` as the test observer on `DatabaseWriteQueue.shared` and
    /// return an async clear function. Callers MUST `await clear()` before the test
    /// returns (see the suite-level note on why no `defer` is used).
    ///
    /// Takes the recording closure rather than returning a `Mutex` — `Mutex` is a
    /// noncopyable (`~Copyable`) struct and can't be packed into a tuple return
    /// (Swift Testing / Synchronization limitation, see `PriorityGateTests`'
    /// "bind results to locals first" note); each caller owns its own `Mutex` local.
    private func installObserver(
        record: @escaping @Sendable (WritePriority, String?) -> Void
    ) async -> @Sendable () async -> Void {
        await DatabaseWriteQueue.shared.setTestObserverForTesting(record)
        return { await DatabaseWriteQueue.shared.setTestObserverForTesting(nil) }
    }

    private func makeFetchResult(headerId: String, accountId: String, folderPath: String, messageId: String) -> BodyFetchProcessor.FetchResult {
        let item = BodyFetchProcessor.Item(
            headerId: headerId, accountId: accountId, folderPath: folderPath,
            messageId: messageId, isInInbox: true
        )
        let body = MessageBody.create( contentKey: ContentKey(rawValue: headerId), htmlBody: "<p>Tier test body</p>")
        return BodyFetchProcessor.FetchResult(
            item: item, renderedBody: body, plainText: "Tier test body plain text",
            hasAttachments: false, hasUnresolvedICS: false,
            // This fixture is about write-tier routing, not identity: the account is
            // `.gmail` (no reused UID space) and the header carries no rfc822 id, so
            // `BodyAddressGate` has nothing to contradict and `process` proceeds.
            fetchedRfc822MessageId: nil
        )
    }

    private func postSuspend() {
        NotificationCenter.default.post(name: Database.suspendNotification, object: nil)
    }

    private func postResume() {
        NotificationCenter.default.post(name: Database.resumeNotification, object: nil)
    }

    // MARK: - BodyFetchProcessor.process — the ActiveBodyQueue wrap

    @Test("process() wrapped in PriorityGate.normal (ActiveBodyQueue's wrap) executes at .normal, NOT .priority")
    func processNormalWrapExecutesNormal() async throws {
        let (header, restore) = try makeTestDB()
        defer { restore() }
        let recorded = Mutex<[(WritePriority, String?)]>([])
        let clearObserver = await installObserver { priority, label in recorded.withLock { $0.append((priority, label)) } }

        let fetchResult = makeFetchResult(
            headerId: header.id, accountId: header.accountId,
            folderPath: header.folderPath, messageId: header.messageId
        )
        _ = await PriorityGate.normal {
            await BodyFetchProcessor.process(fetchResult: fetchResult, enableAI: false)
        }
        await clearObserver()

        let snapshot = recorded.withLock { $0 }
        #expect(!snapshot.isEmpty, "process() with non-empty plainText must write MessageBody")
        #expect(snapshot.allSatisfy { $0.0 == .normal }, "every recorded write must be .normal, got \(snapshot.map(\.0))")
        #expect(!snapshot.contains { $0.0 == .priority }, "must NOT execute at .priority")
    }

    @Test("process() UNWRAPPED (on-demand fetchBody / SnippetLoader path) still defaults to .priority — unchanged")
    func processUnwrappedStaysPriority() async throws {
        let (header, restore) = try makeTestDB()
        defer { restore() }
        let recorded = Mutex<[(WritePriority, String?)]>([])
        let clearObserver = await installObserver { priority, label in recorded.withLock { $0.append((priority, label)) } }

        let fetchResult = makeFetchResult(
            headerId: header.id, accountId: header.accountId,
            folderPath: header.folderPath, messageId: header.messageId
        )
        // No PriorityGate wrap — mirrors AccountManager.fetchBody / the
        // InboxViewModel SnippetLoader tier-2 on-demand fetch, both of which call
        // BodyFetchProcessor directly and must stay .priority (a live user action).
        _ = await BodyFetchProcessor.process(fetchResult: fetchResult, enableAI: false)
        await clearObserver()

        let snapshot = recorded.withLock { $0 }
        #expect(!snapshot.isEmpty)
        #expect(snapshot.allSatisfy { $0.0 == .priority }, "on-demand path must stay .priority, got \(snapshot.map(\.0))")
    }

    @Test("replaceExistingBody swaps only after a complete body is ready")
    func replaceExistingBodyUsesCurrentRowAsFallback() async throws {
        let (header, restore) = try makeTestDB()
        defer { restore() }
        try await AppDatabase.rawPool.write { db in
            try MessageBody(
                contentKey: ContentKey(rawValue: header.id),
                htmlContent: "<p>old readable body</p>").insert(db)
            try db.execute(
                sql: """
                    UPDATE messageHeader
                    SET bodyComplete = 1,
                        bodyEmptyConfirmed = 1,
                        emptyFetchCount = 3,
                        embeddingComplete = 1,
                        summaryBlurb = 'This message has no content.',
                        actionTag = ?,
                        tagSortOrder = ?
                    WHERE id = ?
                """,
                arguments: [
                    ActionTag.delete.rawValue,
                    ActionTag.delete.sortOrder,
                    header.id,
                ])
        }

        let result = makeFetchResult(
            headerId: header.id,
            accountId: header.accountId,
            folderPath: header.folderPath,
            messageId: header.messageId)
        let (outcome, processed) = await BodyFetchProcessor.process(
            fetchResult: result,
            enableAI: false,
            replaceExistingBody: true)

        #expect(outcome == .success)
        #expect(processed != nil)
        let state = try await AppDatabase.rawPool.read { db -> (MessageBody?, Row?) in
            let body = try MessageBody.fetchOne(db, key: header.id)
            let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT bodyComplete, bodyEmptyConfirmed, emptyFetchCount,
                           embeddingComplete, summaryBlurb, actionTag, tagSortOrder
                    FROM messageHeader WHERE id = ?
                """,
                arguments: [header.id])
            return (body, row)
        }
        #expect(state.0?.htmlContent == "<p>Tier test body</p>")
        #expect((state.1?["bodyComplete"] as Int?) == 0)
        #expect((state.1?["bodyEmptyConfirmed"] as Int?) == 0)
        #expect((state.1?["emptyFetchCount"] as Int?) == 0)
        #expect((state.1?["embeddingComplete"] as Int?) == 0)
        #expect((state.1?["summaryBlurb"] as String?) == nil)
        #expect((state.1?["actionTag"] as String?) == nil)
        #expect((state.1?["tagSortOrder"] as Int?) == 99)
    }

    @Test("A failed body-cache write stays retryable and produces no FTS candidate")
    func bodyWriteAbortDoesNotReportSuccess() async throws {
        let (header, restore) = try makeTestDB(suspendable: true)
        defer {
            postResume()
            restore()
        }
        let fetchResult = makeFetchResult(
            headerId: header.id, accountId: header.accountId,
            folderPath: header.folderPath, messageId: header.messageId)

        postSuspend()
        let (outcome, processed) = await BodyFetchProcessor.process(
            fetchResult: fetchResult, enableAI: false)
        postResume()

        #expect(outcome == .retry,
                "bytes not committed to the body cache remain retryable")
        #expect(processed == nil,
                "FTS/bodyComplete must not outrun the failed body-cache write")
        let body = try await AppDatabase.rawPool.read {
            try MessageBody.fetchOne($0, key: ContentKey(rawValue: header.id))
        }
        #expect(body == nil)
    }

    @Test("A failed attachment-only body-cache write stays retryable")
    func attachmentOnlyWriteAbortDoesNotReportSuccess() async throws {
        let (header, restore) = try makeTestDB(suspendable: true)
        defer {
            postResume()
            restore()
        }
        let item = BodyFetchProcessor.Item(
            headerId: header.id, accountId: header.accountId,
            folderPath: header.folderPath, messageId: header.messageId,
            isInInbox: true)
        let fetchResult = BodyFetchProcessor.FetchResult(
            item: item,
            renderedBody: MessageBody.create(
                contentKey: ContentKey(rawValue: header.id), htmlBody: ""),
            plainText: nil, hasAttachments: true,
            hasUnresolvedICS: false, fetchedRfc822MessageId: nil)

        postSuspend()
        let (outcome, processed) = await BodyFetchProcessor.process(
            fetchResult: fetchResult, enableAI: false)
        postResume()

        #expect(outcome == .retry)
        #expect(processed == nil,
                "an FTS placeholder must not outrun the failed attachment cache write")
        let body = try await AppDatabase.rawPool.read {
            try MessageBody.fetchOne($0, key: ContentKey(rawValue: header.id))
        }
        #expect(body == nil)
    }

    @Test("A failed confirmed-empty transaction is retryable, never acknowledged")
    func confirmedEmptyWriteAbortDoesNotReportConfirmation() async throws {
        let (header, restore) = try makeTestDB(suspendable: true)
        defer {
            postResume()
            restore()
        }
        try await AppDatabase.rawPool.write { db in
            try db.execute(
                sql: "UPDATE messageHeader SET emptyFetchCount = 2 WHERE id = ?",
                arguments: [header.id])
        }
        let item = BodyFetchProcessor.Item(
            headerId: header.id, accountId: header.accountId,
            folderPath: header.folderPath, messageId: header.messageId,
            isInInbox: true)
        let fetchResult = BodyFetchProcessor.FetchResult(
            item: item,
            renderedBody: MessageBody.create(
                contentKey: ContentKey(rawValue: header.id), htmlBody: ""),
            plainText: nil, hasAttachments: false,
            hasUnresolvedICS: false, fetchedRfc822MessageId: nil)

        postSuspend()
        let (outcome, processed) = await BodyFetchProcessor.process(
            fetchResult: fetchResult, enableAI: false)
        postResume()

        #expect(outcome == .retry,
                "an empty body is confirmed only when its body+flag transaction commits")
        #expect(processed == nil)
        let updated = try await AppDatabase.rawPool.read {
            try MessageHeader.fetchOne($0, key: header.id)
        }
        #expect(updated?.bodyComplete == false)
        #expect(updated?.bodyEmptyConfirmed == false)
    }

    @Test("A privileged merge context wins over the .normal wrap — PrioritizedDatabase.effectivePriority checks inPrivilegedContext first")
    func privilegedMergeOverridesNormalWrap() async throws {
        let (header, restore) = try makeTestDB()
        defer { restore() }
        let recorded = Mutex<[(WritePriority, String?)]>([])
        let clearObserver = await installObserver { priority, label in recorded.withLock { $0.append((priority, label)) } }

        let fetchResult = makeFetchResult(
            headerId: header.id, accountId: header.accountId,
            folderPath: header.folderPath, messageId: header.messageId
        )
        // Exactly ActiveBodyQueue's wrap (.normal), but additionally nested inside
        // a privileged merge section — the merge still wins.
        await PriorityGate.privileged {
            _ = await PriorityGate.normal {
                await BodyFetchProcessor.process(fetchResult: fetchResult, enableAI: false)
            }
        }
        await clearObserver()

        let snapshot = recorded.withLock { $0 }
        #expect(!snapshot.isEmpty)
        #expect(snapshot.allSatisfy { $0.0 == .priority }, "privileged merge must force .priority even under a .normal wrap, got \(snapshot.map(\.0))")
    }

    @Test("Sanity: the PriorityGate.background wrap BackfillBodyQueue uses is unaffected by this ADR")
    func backgroundWrapUnchanged() async throws {
        let (header, restore) = try makeTestDB()
        defer { restore() }
        let recorded = Mutex<[(WritePriority, String?)]>([])
        let clearObserver = await installObserver { priority, label in recorded.withLock { $0.append((priority, label)) } }

        let fetchResult = makeFetchResult(
            headerId: header.id, accountId: header.accountId,
            folderPath: header.folderPath, messageId: header.messageId
        )
        _ = await PriorityGate.background {
            await BodyFetchProcessor.process(fetchResult: fetchResult, enableAI: false)
        }
        await clearObserver()

        let snapshot = recorded.withLock { $0 }
        #expect(!snapshot.isEmpty)
        #expect(snapshot.allSatisfy { $0.0 == .background }, "BackfillBodyQueue's wrap must stay .background, got \(snapshot.map(\.0))")
    }

    // MARK: - BodyFetchProcessor.flushBatch — the ActiveBodyQueue wrap (real FTS + downstream)

    @Test("flushBatch() wrapped in PriorityGate.normal writes the bodyComplete/snippet flag at .normal")
    func flushBatchNormalWrapExecutesNormal() async throws {
        let (header, restore) = try makeTestDB()
        defer { restore() }

        // Index the header in FTS first so flushBatch's updateBodies confirms it
        // (writtenToFts) and proceeds to the GRDB bodyComplete/snippet write —
        // otherwise the write is deferred and there's nothing to observe.
        let record = FTSHeaderRecord( contentKey: ContentKey(rawValue: header.id),
            headerId: header.id, messageId: header.messageId, subject: header.subject,
            from: "\(header.from) <\(header.fromAddress)>", to: header.to,
            dateMs: Int64(header.date.timeIntervalSince1970 * 1000)
        )
        try await SearchIndex.shared.removeMessages( contentKeys: [header.id].map(ContentKey.init(rawValue:)))
        _ = try await SearchIndex.shared.indexHeaders([record])

        let recorded = Mutex<[(WritePriority, String?)]>([])
        let clearObserver = await installObserver { priority, label in recorded.withLock { $0.append((priority, label)) } }

        let processed = BodyFetchProcessor.ProcessedItem(
            contentKey: ContentKey(rawValue: header.id),
            headerId: header.id, accountId: header.accountId, isInInbox: true,
            body: "Tier test flush body", snippet: "Tier test flush snippet"
        )
        // enableAI: false — routes the downstream enqueue to BackfillEmbeddingQueue
        // only (EmbeddingService.shared is nil in unit tests, so it no-ops before
        // touching any pool); avoids entangling ActiveAIQueue/ActiveEmbeddingQueue
        // LLM/CoreML side effects in this DB-write-tier assertion.
        await PriorityGate.normal {
            await BodyFetchProcessor.flushBatch([processed], enableAI: false)
        }
        await clearObserver()

        let snapshot = recorded.withLock { $0 }
        #expect(!snapshot.isEmpty, "flushBatch must write bodyComplete/snippet once the header is confirmed in FTS")
        #expect(snapshot.allSatisfy { $0.0 == .normal }, "flush path must execute at .normal, got \(snapshot.map(\.0))")
        #expect(!snapshot.contains { $0.0 == .priority })

        let updated = try await AppDatabase.rawPool.read { db in try MessageHeader.fetchOne(db, key: header.id) }
        #expect(updated?.bodyComplete == true, "sanity: the write actually landed")

        try? await SearchIndex.shared.removeMessages( contentKeys: [header.id].map(ContentKey.init(rawValue:)))
    }

    // MARK: - ActiveAIQueue / ActiveBodyQueue own pool tier

    @Test("ActiveAIQueue.dbPool is .normal (ADR-IOS-056) — was .background before this ADR")
    func activeAIQueuePoolIsNormal() async throws {
        let (_, restore) = try makeTestDB()
        defer { restore() }
        let tier = await ActiveAIQueue.shared.dbPoolPriorityForTesting
        #expect(tier == .normal)
    }

    @Test("ActiveBodyQueue.dbPool is .normal (ADR-IOS-056) — was .priority before this ADR")
    func activeBodyQueuePoolIsNormal() async throws {
        let (_, restore) = try makeTestDB()
        defer { restore() }
        let tier = await ActiveBodyQueue.shared.dbPoolPriorityForTesting
        #expect(tier == .normal)
    }

    @Test("Untouched pools keep their pre-ADR tiers: dbPool=.priority, backgroundPool=.background")
    func untouchedPoolsUnchanged() throws {
        #expect(AppDatabase.dbPool.priority == .priority)
        #expect(AppDatabase.backgroundPool.priority == .background)
        #expect(AppDatabase.syncPool.priority == .normal)
    }
}
