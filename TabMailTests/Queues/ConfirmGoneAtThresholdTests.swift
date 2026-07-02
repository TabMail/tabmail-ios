/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

/// Unit tests for `BackfillBodyQueue.confirmGoneAtThreshold` — the pre-delete gate
/// that distinguishes "server confirmed gone" from "UID remapped by UIDVALIDITY"
/// before we permanently delete a local messageHeader.
///
/// `confirmGoneAtThreshold` branches on provider capability (`MessageExistenceProbe`)
/// and on the stored `rfc822MessageId`. Tests drive each branch with a small
/// mock provider that conforms to both `EmailProvider` and `MessageExistenceProbe`.
///
/// **Why the protocol refactor matters**: production uses `IMAPProvider` as the
/// only prober, but actors can't be subclassed, so we can't stub
/// `messageExistsInFolder` on a real IMAPProvider. The `MessageExistenceProbe`
/// protocol (added alongside these tests) narrows the dependency to exactly the
/// method needed for this classification.
///
/// Note: `confirmGoneAtThreshold` reads `rfc822MessageId` from
/// `AppDatabase.dbPool` (the production singleton). We insert directly into it
/// via `AppDatabase.dbPool.write` rather than an in-memory TestDatabase — the
/// production singleton is what BackfillBodyQueue queries, and the tests clean
/// up their inserts so shared state isn't polluted.
@Suite("BackfillBodyQueue.confirmGoneAtThreshold — classification branches")
struct ConfirmGoneAtThresholdTests {

    // MARK: - Mocks

    /// Non-IMAP-like provider — does NOT conform to MessageExistenceProbe.
    /// Used to verify the non-IMAP short-circuit path (returns .gone).
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
        func saveDraft(_ draft: DraftMessage, existingDraftId: String?, draftsFolderPath: String) async throws -> DraftSaveResult { DraftSaveResult(serverId: "mock") }
        func deleteDraft(draftId: String, draftsFolderPath: String) async throws {}
    }

    /// Probe-conforming provider — controls `currentUIDs` return value
    /// (empty = gone, non-empty = still exists) and `recordedCalls` for assertion.
    actor ProbingProvider: EmailProvider, MessageExistenceProbe {
        private var result: Result<[String], Error>
        private(set) var recordedCalls: [(rfc822: String, folder: String)] = []

        init(result: Result<[String], Error>) { self.result = result }

        func setResult(_ r: Result<[String], Error>) { result = r }

        func currentUIDs(rfc822MessageId: String, folderPath: String) async throws -> [String] {
            recordedCalls.append((rfc822: rfc822MessageId, folder: folderPath))
            return try result.get()
        }

        func messageExistsInFolder(rfc822MessageId: String, folderPath: String) async throws -> Bool {
            let uids = try await currentUIDs(rfc822MessageId: rfc822MessageId, folderPath: folderPath)
            return !uids.isEmpty
        }

        // EmailProvider stubs (not exercised here)
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
        func saveDraft(_ draft: DraftMessage, existingDraftId: String?, draftsFolderPath: String) async throws -> DraftSaveResult { DraftSaveResult(serverId: "mock") }
        func deleteDraft(draftId: String, draftsFolderPath: String) async throws {}
    }

    struct ProbeError: Error, Equatable { let reason: String }

    // MARK: - Test fixture

    /// Insert a messageHeader directly into the production `AppDatabase.dbPool`
    /// (which is what BackfillBodyQueue reads). Returns the headerId; callers
    /// must call `cleanupHeader` at the end to remove the row.
    private func insertHeader(
        accountId: String,
        folderPath: String,
        messageId: String,
        rfc822: String?
    ) async throws -> String {
        let headerId = MessageIdentity.headerId(accountId: accountId, folderPath: folderPath, messageId: messageId)
        let folderId = MessageIdentity.folderId(accountId: accountId, folderPath: folderPath)
        try await AppDatabase.dbPool.write { db in
            // Use the production models so we don't have to enumerate every
            // NOT-NULL column by hand (brittle as migrations add columns).
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
                subject: "test",
                from: "a@x",
                fromAddress: "a@x",
                to: "b@x",
                date: Date(),
                snippet: "",
                folderId: folderId,
                accountId: accountId,
                folderPath: folderPath,
                isInInbox: false
            )
            header.rfc822MessageId = rfc822
            header.headerComplete = true
            try header.insert(db)
        }
        return headerId
    }

    private func cleanupHeader(_ headerId: String) async {
        try? await AppDatabase.dbPool.write { db in
            try db.execute(sql: "DELETE FROM messageHeader WHERE id = ?", arguments: [headerId])
        }
    }

    private func makeItem(headerId: String, accountId: String, folderPath: String, messageId: String) -> BackfillBodyQueue.Item {
        .init(headerId: headerId, accountId: accountId, folderPath: folderPath, messageId: messageId, isInInbox: false)
    }

    // MARK: - Classification branches

    @Test("Non-MessageExistenceProbe provider → .gone (short-circuit for REST)")
    func nonProbeShortCircuits() async throws {
        // For REST providers the fetchMessagesBatch fix already guarantees that
        // "missing from result" is a clean 404 signal, so at threshold we go
        // straight to .gone without consulting any probe.
        let queue = BackfillBodyQueue()
        let headerId = try await insertHeader(
            accountId: "acc-nonprobe", folderPath: "INBOX", messageId: "u-1", rfc822: "<r1@x>"
        )

        let item = makeItem(headerId: headerId, accountId: "acc-nonprobe", folderPath: "INBOX", messageId: "u-1")
        let provider = NonProbeProvider()

        let result = await queue.confirmGoneAtThreshold(item: item, provider: provider)
        #expect(result == .gone)
        await cleanupHeader(headerId)
    }

    @Test("Probe provider + rfc822 found under NEW UID → .stillExists(newUID:) (UID remap, no delete)")
    func proberFoundReturnsStillExists() async throws {
        // UIDVALIDITY rotated: UID not in current BODYSTRUCTURE, but rfc822
        // search finds the message under a new UID. We must NOT delete the
        // local header — the caller re-keys it to the new UID in place.
        let queue = BackfillBodyQueue()
        let headerId = try await insertHeader(
            accountId: "acc-found", folderPath: "INBOX", messageId: "u-1", rfc822: "<r-found@x>"
        )

        let item = makeItem(headerId: headerId, accountId: "acc-found", folderPath: "INBOX", messageId: "u-1")
        let provider = ProbingProvider(result: .success(["77"]))

        let result = await queue.confirmGoneAtThreshold(item: item, provider: provider)
        #expect(result == .stillExists(newUID: "77"))

        let calls = await provider.recordedCalls
        #expect(calls.count == 1)
        guard calls.count == 1 else { return }
        #expect(calls[0].rfc822 == "<r-found@x>")
        #expect(calls[0].folder == "INBOX")
        await cleanupHeader(headerId)
    }

    @Test("Probe provider + rfc822 found at SAME UID → .stillExists(nil) (transient miss)")
    func proberFoundSameUIDReturnsNilNewUID() async throws {
        // The stored UID is still on the server — the batch miss was transient
        // (partial FETCH response, flap). No re-key; caller resets the counter.
        let queue = BackfillBodyQueue()
        let headerId = try await insertHeader(
            accountId: "acc-same", folderPath: "INBOX", messageId: "u-1", rfc822: "<r-same@x>"
        )

        let item = makeItem(headerId: headerId, accountId: "acc-same", folderPath: "INBOX", messageId: "u-1")
        let provider = ProbingProvider(result: .success(["u-1"]))

        let result = await queue.confirmGoneAtThreshold(item: item, provider: provider)
        #expect(result == .stillExists(newUID: nil))
        await cleanupHeader(headerId)
    }

    @Test("Probe provider + multiple UIDs → highest numeric UID wins (newest copy)")
    func proberMultipleUIDsPicksHighest() async throws {
        // Duplicate copies in the folder (e.g. re-APPEND after a flaky move):
        // UIDs are monotonic per folder, so the highest is the newest copy.
        let queue = BackfillBodyQueue()
        let headerId = try await insertHeader(
            accountId: "acc-multi", folderPath: "INBOX", messageId: "u-1", rfc822: "<r-multi@x>"
        )

        let item = makeItem(headerId: headerId, accountId: "acc-multi", folderPath: "INBOX", messageId: "u-1")
        let provider = ProbingProvider(result: .success(["9", "123", "45"]))

        let result = await queue.confirmGoneAtThreshold(item: item, provider: provider)
        #expect(result == .stillExists(newUID: "123"))
        await cleanupHeader(headerId)
    }

    @Test("Probe provider + rfc822 NOT found → .gone (truly deleted, safe to remove)")
    func proberNotFoundReturnsGone() async throws {
        // Message EXPUNGE'd from the server; rfc822 search comes back empty in
        // the folder. Now safe to delete the local header.
        let queue = BackfillBodyQueue()
        let headerId = try await insertHeader(
            accountId: "acc-gone", folderPath: "INBOX", messageId: "u-1", rfc822: "<r-gone@x>"
        )

        let item = makeItem(headerId: headerId, accountId: "acc-gone", folderPath: "INBOX", messageId: "u-1")
        let provider = ProbingProvider(result: .success([]))

        let result = await queue.confirmGoneAtThreshold(item: item, provider: provider)
        #expect(result == .gone)
        await cleanupHeader(headerId)
    }

    @Test("Probe provider + rfc822 SEARCH throws → .cannotConfirm (don't delete, don't reset)")
    func proberThrowsReturnsCannotConfirm() async throws {
        // Connection error or server issue during the confirmation SEARCH.
        // We don't know whether the message exists, so we MUST NOT delete.
        // Caller keeps the row and retries next cycle / lets full-sync handle.
        let queue = BackfillBodyQueue()
        let headerId = try await insertHeader(
            accountId: "acc-throws", folderPath: "INBOX", messageId: "u-1", rfc822: "<r-throws@x>"
        )

        let item = makeItem(headerId: headerId, accountId: "acc-throws", folderPath: "INBOX", messageId: "u-1")
        let provider = ProbingProvider(result: .failure(ProbeError(reason: "connection reset")))

        let result = await queue.confirmGoneAtThreshold(item: item, provider: provider)
        #expect(result == .cannotConfirm)
        await cleanupHeader(headerId)
    }

    @Test("Probe provider + NIL rfc822 → .cannotConfirm (no remap check possible)")
    func proberNilRfc822ReturnsCannotConfirm() async throws {
        // Some legacy / malformed IMAP messages have no Message-ID header at
        // all. We can't do rfc822 remap detection for them — don't delete.
        let queue = BackfillBodyQueue()
        let headerId = try await insertHeader(
            accountId: "acc-nilrfc", folderPath: "INBOX", messageId: "u-1", rfc822: nil
        )

        let item = makeItem(headerId: headerId, accountId: "acc-nilrfc", folderPath: "INBOX", messageId: "u-1")
        let provider = ProbingProvider(result: .success(["77"]))  // would otherwise succeed

        let result = await queue.confirmGoneAtThreshold(item: item, provider: provider)
        #expect(result == .cannotConfirm)

        // Probe should NOT have been called since rfc822 is nil.
        let calls = await provider.recordedCalls
        #expect(calls.isEmpty)
        await cleanupHeader(headerId)
    }

    @Test("Probe provider + EMPTY rfc822 → .cannotConfirm (normalized empty string is same as nil)")
    func proberEmptyRfc822ReturnsCannotConfirm() async throws {
        // Guard against the edge case where rfc822MessageId was stored as "".
        // Should be treated the same as nil — don't attempt a probe on an
        // empty string.
        let queue = BackfillBodyQueue()
        let headerId = try await insertHeader(
            accountId: "acc-empty", folderPath: "INBOX", messageId: "u-1", rfc822: ""
        )

        let item = makeItem(headerId: headerId, accountId: "acc-empty", folderPath: "INBOX", messageId: "u-1")
        let provider = ProbingProvider(result: .success(["77"]))

        let result = await queue.confirmGoneAtThreshold(item: item, provider: provider)
        #expect(result == .cannotConfirm)
        let calls = await provider.recordedCalls
        #expect(calls.isEmpty)
        await cleanupHeader(headerId)
    }

    // MARK: - Regression / wiring

    @Test("IMAPProvider conforms to MessageExistenceProbe (wiring guard)")
    func imapProviderConforms() {
        // If someone accidentally removes the MessageExistenceProbe conformance
        // from IMAPProvider, the production path silently becomes "non-probe →
        // .gone" — effectively disabling UIDVALIDITY remap protection for IMAP.
        // This test pins the conformance.
        let isProbe: Any.Type = IMAPProvider.self
        let conforms = (isProbe as? any MessageExistenceProbe.Type) != nil
        #expect(conforms, "IMAPProvider must conform to MessageExistenceProbe so backfill runs the rfc822 remap check")
    }
}
