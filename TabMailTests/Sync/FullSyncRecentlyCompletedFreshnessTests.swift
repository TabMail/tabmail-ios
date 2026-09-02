/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

/// Issue #106 — the PRODUCER side of the `recentlyCompleted` sync protection.
///
/// `StaleProtectionTests` already pins the CONSUMER: given a protection set that
/// contains a message, `runSyncMessages` does not touch it. That test cannot fail
/// for this defect, because the defect was never in the consumer — it was in where
/// the caller got the set from. `SyncEngineFullSync` used to snapshot
/// `AccountManager.recentlyCompleted` ONCE, before its folder loop, and hand that
/// same value to every folder. `recordRecentlyCompleted` runs when a queued op
/// COMPLETES, so an op that completed after the snapshot was taken was invisible:
/// no longer pending (so `isPendingDestructive` missed it) and not in the snapshot
/// (so `isRecentlyCompleted` missed it too). Both guards failed for one reason.
///
/// Observed consequence: a message archived while a full sync was already running
/// was re-inserted into its SOURCE folder as a fresh header — no snippet, and
/// unfetchable, because the source address no longer resolved.
///
/// The invariant pinned here is deliberately about the SYSTEM PROPERTY, not the
/// fix's mechanism: **an operation that completes after a full sync begins is
/// still honoured by the folders that sync after it.** A test that asserted "the
/// set is read per folder" would pass just as happily against a different sound
/// design (a live actor read, an ordering change), and would inherit this fix's
/// assumptions rather than checking the behaviour.
///
/// `.serialized, .processGlobalState`: `AccountManager.recentlyCompleted` is a
/// process-global map and `AppDatabase.shared` is swapped, so these must not
/// interleave with siblings (`IOS-TEST-006` is the cross-suite collision in this
/// exact state).
@Suite("Full sync honours an operation that completes mid-run", .serialized, .processGlobalState)
struct FullSyncRecentlyCompletedFreshnessTests {

    private static let accountId = "fullsync-freshness"
    /// The message that exists in INBOX locally and is listed by the server in
    /// BOTH folders. Archive has no local row for it, so Archive's pass sees it as
    /// remote-only — the exact shape that produced the ghost.
    private static let movedUid = "900"

    private static func info(uid: String) -> MessageHeaderInfo {
        MessageHeaderInfo(
            messageId: uid, rfc822MessageId: "freshness-\(uid)@example.com", inReplyTo: nil,
            references: [], threadId: nil, subject: "freshness \(uid)", from: "Sender",
            fromAddress: "sender@example.com", to: "recipient@example.com",
            cc: "", bcc: "", replyTo: nil,
            date: Date(timeIntervalSince1970: 1_700_000_000), snippet: "freshness",
            isRead: false, isFlagged: false, hasAttachments: false,
            isReplied: false, isForwarded: false, actionTag: nil)
    }

    /// Two folders, because ONE folder cannot express this defect: the completion
    /// has to land between two folders' passes. INBOX is `primaryRoles` (priority
    /// 0) and Archive is `secondaryRoles` (priority 2), so `fullSync`'s own sort
    /// guarantees INBOX runs first and Archive second.
    private static func fixture() throws -> (pool: DatabasePool, dir: URL, previous: AppDatabase?, account: Account) {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        let account = try FolderEpochTestFixture.makeAccount(id: accountId, provider: .imap, pool: pool)
        try FolderEpochTestFixture.insertFolder(
            accountId: accountId, path: "INBOX", role: .inbox, pool: pool)
        try FolderEpochTestFixture.insertFolder(
            accountId: accountId, path: "Archive", role: .archive, pool: pool)
        // Local row in INBOX only. This keeps INBOX's own pass a no-op (server and
        // local agree) so the only folder that can insert anything is Archive.
        try FolderEpochTestFixture.insertHeaders(
            accountId: accountId, path: "INBOX", uids: [Int(movedUid)!], pool: pool)
        return (pool, dir, previous, account)
    }

    private static func makeMock() async -> MockEmailProvider {
        let mock = MockEmailProvider(staleWindowMode: .uid)
        await mock.setFetchFoldersResult([
            FolderInfo(name: "INBOX", path: "INBOX", role: .inbox, unreadCount: 0,
                       totalCount: 1, uidNext: 901, uidValidity: 4242),
            FolderInfo(name: "Archive", path: "Archive", role: .archive, unreadCount: 0,
                       totalCount: 1, uidNext: 901, uidValidity: 4242)
        ])
        // Returned for BOTH folders: INBOX has the row locally (no-op), Archive
        // does not (remote-only → the upsert loop's insert path).
        await mock.setFetchMessagesResult([info(uid: movedUid)])
        return mock
    }

    @Test("An operation completing mid-sync protects a folder that syncs after it")
    func completionMidRunIsHonouredByLaterFolders() async throws {
        let (pool, dir, previous, account) = try Self.fixture()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
        }
        await AccountManager.shared.clearRecentlyCompletedForTesting()
        defer { Task { await AccountManager.shared.clearRecentlyCompletedForTesting() } }

        let mock = await Self.makeMock()
        // Fire while INBOX is being listed — i.e. after the run has begun and
        // before Archive's pass. This is the drain completing mid-sync.
        await mock.setFetchMessagesHook { folder in
            guard folder == "INBOX" else { return }
            await AccountManager.shared.recordRecentlyCompleted(messageIds: [Self.movedUid])
        }

        try await SyncEngine().fullSync(account: account, provider: mock)

        let archived = try FolderEpochTestFixture.headerCount(
            accountId: Self.accountId, path: "Archive", pool: pool)
        #expect(
            archived == 0,
            "a folder syncing after the completion must honour it — re-inserting here is the snippet-less, unfetchable ghost of issue #106")
    }

    /// THE CONTROL, and it is what makes the assertion above mean something. With
    /// no completion recorded, the identical fixture MUST insert — otherwise the
    /// test above would pass against a sync that inserts nothing at all, or a
    /// fixture that never reaches the upsert path.
    @Test("Without the completion the same fixture DOES insert (the protection is load-bearing)")
    func withoutTheCompletionTheGhostIsInserted() async throws {
        let (pool, dir, previous, account) = try Self.fixture()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
        }
        await AccountManager.shared.clearRecentlyCompletedForTesting()
        defer { Task { await AccountManager.shared.clearRecentlyCompletedForTesting() } }

        let mock = await Self.makeMock()   // no hook: nothing completes mid-run

        try await SyncEngine().fullSync(account: account, provider: mock)

        let archived = try FolderEpochTestFixture.headerCount(
            accountId: Self.accountId, path: "Archive", pool: pool)
        #expect(
            archived == 1,
            "control: an unprotected remote-only message must still be inserted, or the assertion above is vacuous")
    }
}
