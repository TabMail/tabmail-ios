/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

/// Integration tests for `BackfillBodyQueue.handleMissedItems` — the end-to-end
/// wiring between the miss-counter, the pre-delete confirmation, and the
/// per-branch action (delete / reset / keep).
///
/// `confirmGoneAtThreshold` is tested in isolation in `ConfirmGoneAtThresholdTests`.
/// These tests pin the GLUE: that the right action is taken for each
/// classification outcome, and that the counter state evolves as designed.
///
/// The sanity check is especially important given the failure mode we care
/// about: if the `.gone` vs `.stillExists` branches were ever swapped, every
/// UIDVALIDITY rotation would silently delete the whole folder. No amount of
/// visual review fully substitutes for a test that pins this.
///
/// Tests run against production `AppDatabase.dbPool` (what the queue reads),
/// using unique account IDs per test so runs don't pollute each other. Each
/// test cleans up its inserted row at the end.
@Suite("BackfillBodyQueue.handleMissedItems — dispatch wiring")
struct HandleMissedItemsTests {

    // MARK: - Mocks (same shape as ConfirmGoneAtThresholdTests)

    actor NonProbeProvider: EmailProvider {
        func connect() async throws {}
        func disconnect() async throws {}
        func fetchFolders() async throws -> [FolderInfo] { [] }
        func fetchMessages(folder: String, limit: Int, offset: Int) async throws -> [MessageHeaderInfo] { [] }
        func fetchMessage(id: String, folder: String) async throws -> FullMessageInfo { throw ProviderError.messageNotFound }
        func search(query: String, folder: String, after: Date?, before: Date?, from: String?, to: String?) async throws -> [MessageHeaderInfo] { [] }
        func markRead(ids: [String], folder: String) async throws {}
        func markUnread(ids: [String], folder: String) async throws {}
        func markFlagged(ids: [String], flagged: Bool, folder: String) async throws {}
        func move(ids: [String], from: String, to: String) async throws {}
        func send(draft: DraftMessage) async throws {}
        func appendToSentFolder(draft: DraftMessage, sentFolderPath: String, messageId: String) async throws -> Bool { true }
        func fetchHistory(since historyId: String) async throws -> HistoryResponse? { nil }
        func fetchMessageHeaders(ids: [String]) async throws -> [MessageHeaderInfo] { [] }
        func fetchTextBodies(ids: [String], folder: String) async throws -> [TextBodyFetchResult] { [] }
        func saveDraft(_ draft: DraftMessage, existingIdentity: DraftDeleteIdentity?, draftsFolderPath: String) async throws -> DraftSaveOutcome { .created(.outlook(graphId: "mock")) }
        func deleteDraft(identity: DraftDeleteIdentity) async throws {}
    }

    actor ProbingProvider: EmailProvider, MessageExistenceProbe {
        /// Uniform result for every rfc822, unless `uidsByRfc822` has an entry.
        private var result: Result<[String], Error>
        /// Per-rfc822 override — for multi-item tests where each message maps
        /// to a distinct new UID (empty array = gone).
        private var uidsByRfc822: [String: [String]]

        init(result: Result<[String], Error>, uidsByRfc822: [String: [String]] = [:]) {
            self.result = result
            self.uidsByRfc822 = uidsByRfc822
        }

        func currentUIDs(rfc822MessageId: String, folderPath: String) async throws -> [String] {
            if let mapped = uidsByRfc822[rfc822MessageId] { return mapped }
            return try result.get()
        }

        func messageExistsInFolder(rfc822MessageId: String, folderPath: String) async throws -> Bool {
            let uids = try await currentUIDs(rfc822MessageId: rfc822MessageId, folderPath: folderPath)
            return !uids.isEmpty
        }
        func connect() async throws {}
        func disconnect() async throws {}
        func fetchFolders() async throws -> [FolderInfo] { [] }
        func fetchMessages(folder: String, limit: Int, offset: Int) async throws -> [MessageHeaderInfo] { [] }
        func fetchMessage(id: String, folder: String) async throws -> FullMessageInfo { throw ProviderError.messageNotFound }
        func search(query: String, folder: String, after: Date?, before: Date?, from: String?, to: String?) async throws -> [MessageHeaderInfo] { [] }
        func markRead(ids: [String], folder: String) async throws {}
        func markUnread(ids: [String], folder: String) async throws {}
        func markFlagged(ids: [String], flagged: Bool, folder: String) async throws {}
        func move(ids: [String], from: String, to: String) async throws {}
        func send(draft: DraftMessage) async throws {}
        func appendToSentFolder(draft: DraftMessage, sentFolderPath: String, messageId: String) async throws -> Bool { true }
        func fetchHistory(since historyId: String) async throws -> HistoryResponse? { nil }
        func fetchMessageHeaders(ids: [String]) async throws -> [MessageHeaderInfo] { [] }
        func fetchTextBodies(ids: [String], folder: String) async throws -> [TextBodyFetchResult] { [] }
        func saveDraft(_ draft: DraftMessage, existingIdentity: DraftDeleteIdentity?, draftsFolderPath: String) async throws -> DraftSaveOutcome { .created(.outlook(graphId: "mock")) }
        func deleteDraft(identity: DraftDeleteIdentity) async throws {}
    }

    struct ProbeError: Error { let reason: String }

    // MARK: - Fixture helpers

    /// Insert a messageHeader with a specified `missFetchCount`. Returns the
    /// headerId. Callers must invoke `cleanup(headerId:)` at the end of their
    /// test.
    private func insertHeader(
        accountId: String,
        folderPath: String,
        messageId: String,
        rfc822: String?,
        missFetchCount: Int
    ) async throws -> String {
        let folderId = MessageIdentity.folderId(accountId: accountId, folderPath: folderPath)
        let headerId = MessageIdentity.headerId(accountId: accountId, folderPath: folderPath, messageId: messageId)
        try await AppDatabase.dbPool.write { db in
            if try Account.fetchOne(db, key: accountId) == nil {
                var account = Account(emailAddress: "\(accountId)@example.com", displayName: "Test", provider: .gmail)
                account.id = accountId
                try account.insert(db)
            }
            if try Folder.fetchOne(db, key: folderId) == nil {
                let folder = Folder(name: folderPath, path: folderPath, role: .inbox, accountId: accountId)
                try folder.insert(db)
            }
            var header = MessageHeader(
                messageId: messageId,
                subject: "t", from: "a@x", fromAddress: "a@x", to: "b@x",
                date: Date(), snippet: "",
                folderId: folderId, accountId: accountId, folderPath: folderPath,
                isInInbox: false
            )
            header.rfc822MessageId = rfc822
            header.headerComplete = true
            header.missFetchCount = missFetchCount
            try header.insert(db)
        }
        return headerId
    }

    private func cleanup(headerId: String) async {
        try? await AppDatabase.dbPool.write { db in
            try db.execute(sql: "DELETE FROM messageHeader WHERE id = ?", arguments: [headerId])
        }
    }

    private func readMissCount(headerId: String) async -> Int? {
        try? await AppDatabase.dbPool.read { db in
            try Int.fetchOne(db, sql: "SELECT missFetchCount FROM messageHeader WHERE id = ?", arguments: [headerId])
        }
    }

    private func headerExists(headerId: String) async -> Bool {
        let count = (try? await AppDatabase.dbPool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM messageHeader WHERE id = ?", arguments: [headerId]) ?? 0
        }) ?? 0
        return count > 0
    }

    private func makeItem(accountId: String, folderPath: String, messageId: String, headerId: String) -> BackfillBodyQueue.Item {
        .init(headerId: headerId, accountId: accountId, folderPath: folderPath, messageId: messageId, isInInbox: false)
    }

    // MARK: - Below-threshold: counter-only path

    @Test("Below threshold: missFetchCount increments, header kept, confirmation NOT invoked")
    func belowThresholdOnlyIncrements() async throws {
        // Start at 2. Threshold is 5 (SyncConfig.backfillBodyMissThreshold).
        // One miss → 3, still below threshold → no confirmation, no delete.
        let queue = BackfillBodyQueue()
        let headerId = try await insertHeader(
            accountId: "hmi-below", folderPath: "INBOX", messageId: "u1",
            rfc822: "<r@x>", missFetchCount: 2
        )
        let item = makeItem(accountId: "hmi-below", folderPath: "INBOX", messageId: "u1", headerId: headerId)
        // Use ProbingProvider that would return .gone if called; test verifies it
        // was NOT called (header kept, counter bumped to 3).
        let provider = ProbingProvider(result: .success([]))

        await queue.handleMissedItems([item], provider: provider)

        #expect(await headerExists(headerId: headerId) == true, "header should be kept below threshold")
        #expect(await readMissCount(headerId: headerId) == 3, "counter should bump from 2 to 3")
        await cleanup(headerId: headerId)
    }

    @Test("One below, one at threshold: partitioning routes each to the correct branch")
    func mixedBatchPartitioning() async throws {
        // Covers the split in `partitioned.toDelete` vs `toRetry`. A realistic
        // batch has items at different miss counts — the lower one must stay
        // pending while the higher one goes through confirmation.
        let queue = BackfillBodyQueue()
        let low = try await insertHeader(
            accountId: "hmi-mixed", folderPath: "INBOX", messageId: "low",
            rfc822: "<r-low@x>", missFetchCount: 0
        )
        let high = try await insertHeader(
            accountId: "hmi-mixed", folderPath: "INBOX", messageId: "high",
            rfc822: "<r-high@x>", missFetchCount: 4  // one miss → threshold
        )
        let lowItem = makeItem(accountId: "hmi-mixed", folderPath: "INBOX", messageId: "low", headerId: low)
        let highItem = makeItem(accountId: "hmi-mixed", folderPath: "INBOX", messageId: "high", headerId: high)
        // Probe returns "not found" → high item confirmed gone, deleted.
        // Low item bumps counter only.
        let provider = ProbingProvider(result: .success([]))

        await queue.handleMissedItems([lowItem, highItem], provider: provider)

        #expect(await headerExists(headerId: low) == true)
        #expect(await readMissCount(headerId: low) == 1)
        #expect(await headerExists(headerId: high) == false, "threshold + confirmed gone should delete")
        await cleanup(headerId: low)
    }

    // MARK: - Threshold branches

    @Test("Threshold + non-probe provider → header deleted (REST 404 short-circuit)")
    func thresholdNonProbeDeletes() async throws {
        // Non-probe providers (Gmail/Exchange) have already had their clean 404
        // signal filtered at fetchMessagesBatch time. At threshold we go
        // straight to .gone → delete.
        let queue = BackfillBodyQueue()
        let headerId = try await insertHeader(
            accountId: "hmi-thr-nonprobe", folderPath: "INBOX", messageId: "u1",
            rfc822: "<r@x>", missFetchCount: 4
        )
        let item = makeItem(accountId: "hmi-thr-nonprobe", folderPath: "INBOX", messageId: "u1", headerId: headerId)

        await queue.handleMissedItems([item], provider: NonProbeProvider())

        #expect(await headerExists(headerId: headerId) == false)
    }

    @Test("Threshold + probe .gone → header deleted")
    func thresholdProbeGoneDeletes() async throws {
        // IMAP-like provider, rfc822 SEARCH returns empty → confirmed gone.
        let queue = BackfillBodyQueue()
        let headerId = try await insertHeader(
            accountId: "hmi-thr-pgone", folderPath: "INBOX", messageId: "u1",
            rfc822: "<r@x>", missFetchCount: 4
        )
        let item = makeItem(accountId: "hmi-thr-pgone", folderPath: "INBOX", messageId: "u1", headerId: headerId)
        let provider = ProbingProvider(result: .success([]))

        await queue.handleMissedItems([item], provider: provider)

        #expect(await headerExists(headerId: headerId) == false)
    }

    @Test("Threshold + probe finds SAME UID → counter RESET to 0, header kept (transient miss)")
    func thresholdStillExistsResetsCounter() async throws {
        // rfc822 SEARCH finds the message at the SAME UID we've been fetching —
        // the miss was transient (partial FETCH / flap). We MUST NOT delete;
        // counter resets to 0 so the next miss chain starts fresh.
        let queue = BackfillBodyQueue()
        let headerId = try await insertHeader(
            accountId: "hmi-thr-still", folderPath: "INBOX", messageId: "u1",
            rfc822: "<r@x>", missFetchCount: 4
        )
        let item = makeItem(accountId: "hmi-thr-still", folderPath: "INBOX", messageId: "u1", headerId: headerId)
        let provider = ProbingProvider(result: .success(["u1"]))

        await queue.handleMissedItems([item], provider: provider)

        #expect(await headerExists(headerId: headerId) == true, "same-UID transient miss MUST NOT delete the header")
        #expect(await readMissCount(headerId: headerId) == 0, "counter MUST be reset after .stillExists(nil)")
        await cleanup(headerId: headerId)
    }

    @Test("A backfill miss on a remapped UID re-keys and never deletes")
    func thresholdRemapRekeysHeader() async throws {
        // The UIDVALIDITY-rotation / cross-client-move case. rfc822 SEARCH finds
        // the message under a NEW UID. The header is re-keyed in place so the
        // body fetch proceeds under the live UID — previously this branch just
        // reset the counter and retried the dead UID forever (the permanent
        // "99% indexed" stall).
        let queue = BackfillBodyQueue()
        let headerId = try await insertHeader(
            accountId: "hmi-thr-remap", folderPath: "INBOX", messageId: "u1",
            rfc822: "<r-remap@x>", missFetchCount: 4
        )
        let item = makeItem(accountId: "hmi-thr-remap", folderPath: "INBOX", messageId: "u1", headerId: headerId)
        let provider = ProbingProvider(result: .success(["777"]))

        await queue.handleMissedItems([item], provider: provider)

        let newHeaderId = MessageIdentity.headerId(accountId: "hmi-thr-remap", folderPath: "INBOX", messageId: "777")
        #expect(await headerExists(headerId: headerId) == false, "old dead-UID row must be re-keyed away")
        #expect(await headerExists(headerId: newHeaderId) == true, "re-keyed row must exist under the new UID")
        #expect(await readMissCount(headerId: newHeaderId) == 0, "re-keyed row starts a fresh miss chain")
        let newMessageId = try? await AppDatabase.dbPool.read { db in
            try String.fetchOne(db, sql: "SELECT messageId FROM messageHeader WHERE id = ?", arguments: [newHeaderId])
        }
        #expect(newMessageId == "777")
        await cleanup(headerId: newHeaderId)
    }

    @Test("Threshold + probe throws → header kept, counter NOT reset")
    func thresholdCannotConfirmKeepsCounter() async throws {
        // Transient failure during confirmation — can't verify either way, so
        // we must not delete AND must not reset. The counter stays at the
        // post-increment value so next cycle still hits threshold; if the
        // transient clears, the next attempt decides.
        let queue = BackfillBodyQueue()
        let headerId = try await insertHeader(
            accountId: "hmi-thr-cant", folderPath: "INBOX", messageId: "u1",
            rfc822: "<r@x>", missFetchCount: 4
        )
        let item = makeItem(accountId: "hmi-thr-cant", folderPath: "INBOX", messageId: "u1", headerId: headerId)
        let provider = ProbingProvider(result: .failure(ProbeError(reason: "connection")))

        await queue.handleMissedItems([item], provider: provider)

        #expect(await headerExists(headerId: headerId) == true, "cannotConfirm MUST NOT delete the header")
        #expect(await readMissCount(headerId: headerId) == 5, "counter stays at post-increment value (not reset)")
        await cleanup(headerId: headerId)
    }

    @Test("Threshold + nil rfc822 + probe provider → cannotConfirm, header kept, counter unchanged from increment")
    func thresholdNilRfc822CannotConfirm() async throws {
        // Even with an IMAP-like provider, a header without rfc822MessageId
        // cannot be remap-checked. Falls into .cannotConfirm.
        let queue = BackfillBodyQueue()
        let headerId = try await insertHeader(
            accountId: "hmi-thr-nilrfc", folderPath: "INBOX", messageId: "u1",
            rfc822: nil, missFetchCount: 4
        )
        let item = makeItem(accountId: "hmi-thr-nilrfc", folderPath: "INBOX", messageId: "u1", headerId: headerId)
        // Probe would say .stillExists if called, but should not be called.
        let provider = ProbingProvider(result: .success(["777"]))

        await queue.handleMissedItems([item], provider: provider)

        #expect(await headerExists(headerId: headerId) == true)
        #expect(await readMissCount(headerId: headerId) == 5, "counter increments but not reset (no .stillExists)")
        await cleanup(headerId: headerId)
    }

    // MARK: - Regression: branch-swap catastrophe

    @Test("REGRESSION: UIDVALIDITY-like mass miss does NOT lose any message when probe finds them under new UIDs")
    func regressionUidValidityMassMissSafety() async throws {
        // If `.gone` and `.stillExists` branches are ever swapped, a
        // UIDVALIDITY rotation that makes ALL UIDs missing would delete every
        // header in the folder. This test pins that scenario: 10 headers, all
        // missing, all probe-finds-them under new UIDs → 0 messages lost —
        // every row is re-keyed in place (new UID present, counter 0).
        let queue = BackfillBodyQueue()
        var headerIds: [String] = []
        var uidMap: [String: [String]] = [:]
        for i in 0..<10 {
            let id = try await insertHeader(
                accountId: "hmi-mass-safety", folderPath: "INBOX", messageId: "u\(i)",
                rfc822: "<r\(i)@x>", missFetchCount: 4
            )
            headerIds.append(id)
            uidMap["<r\(i)@x>"] = ["\(1000 + i)"]  // each message remapped to a distinct new UID
        }
        let items = headerIds.enumerated().map { (i, hid) in
            makeItem(accountId: "hmi-mass-safety", folderPath: "INBOX", messageId: "u\(i)", headerId: hid)
        }
        let provider = ProbingProvider(result: .success([]), uidsByRfc822: uidMap)

        await queue.handleMissedItems(items, provider: provider)

        for i in 0..<10 {
            let newId = MessageIdentity.headerId(
                accountId: "hmi-mass-safety", folderPath: "INBOX", messageId: "\(1000 + i)"
            )
            #expect(await headerExists(headerId: newId) == true, "UID-remap message \(i) must survive under its new UID")
            #expect(await readMissCount(headerId: newId) == 0, "counter reset for re-keyed row \(i)")
            #expect(await headerExists(headerId: headerIds[i]) == false, "old dead-UID row \(i) re-keyed away")
            await cleanup(headerId: newId)
        }
    }
}
