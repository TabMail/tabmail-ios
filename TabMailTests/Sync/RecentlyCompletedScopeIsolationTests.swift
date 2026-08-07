/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Testing
@testable import TabMail

/// `IOS-TEST-006` — the stale sweep must not skip a row because a DIFFERENT test
/// scope completed an operation that happened to carry the same bare id.
///
/// **The invariant asserted here is about WHICH ROWS THE SWEEP MAY SKIP, not
/// about the shape of the protection map's key.** `AccountManager.recentlyCompleted`
/// is process-global `[String: Date]` keyed by a BARE `messageId`, which on IMAP
/// IS the per-folder UID; `FakeIMAPServer` hands out UIDs `1/2/3` for a COPY into
/// an empty destination, and `FolderEpochTestFixture.insertHeaders` seeds rows
/// whose `messageId` is `"1"/"2"/"3"`. A drain in one suite therefore protected an
/// unrelated suite's rows for the whole 30 s TTL, and
/// `SyncFullSyncFolderEpochTests`' `sameEpochStillLetsTheStaleSweepDelete` (the
/// control that proves the sweep is a live deleter) plus
/// `turnoverFetchIsAnUnguardedDeleter` (whose `withKnownIssue` then recorded no
/// issue, i.e. passed on a broken premise — the MIS-014 blessing class) both went
/// wrong in a large selector set while passing in isolation.
///
/// **The production key is deliberately NOT scoped, and this test must not be read
/// as asking for that.** `recentlyCompleted`'s second leg is the RFC 822
/// Message-ID, which is folder- and account-agnostic by construction and is what
/// keeps an optimistically-moved row alive at its DESTINATION while its source
/// address is what the drain recorded. Every consumer
/// (`SyncEngine.runSyncMessages`' `isRecentlyCompleted` /
/// `isProtectedByRecent` / `isProtected`,
/// `SyncEngine.deleteConfirmedGhostHeaders`) uses the map only to
/// SKIP a delete or an overwrite, so an over-broad match costs at most one sync
/// pass and can never remove protection — while narrowing the key deletes local
/// rows the server still has. Shipped `v1.6.38` keys it identically
/// (`git show 07a4bb703:TabMail/Services/Account/AccountManager.swift`). The leak
/// is closed at the only boundary that composes across suites: the
/// `ProcessGlobalTestState` scope. `.serialized` orders tests inside one suite
/// only, so ordering was never available as a fix.
@Suite("Cross-scope isolation of the stale-sweep protection map", .serialized, .processGlobalState)
struct RecentlyCompletedScopeIsolationTests {

    @Test("A stale sweep never skips a row because an EARLIER scope completed an op on the same bare UID")
    func protectionRecordedInAnEarlierScopeNeverSurvivesIntoTheNext() async throws {
        // SCOPE 1 — stands in for the contaminating suite. A drain that has just
        // completed ops on UIDs 1/2/3 is exactly what `FinishTheMoveLocallyTests`
        // and `NeverDropExitClosureTests` leave behind: `FakeIMAPServer`'s COPY
        // assigns `(destinationMessages.map(\.uid).max() ?? 0) + 1`, so a COPY into
        // an empty mailbox yields 1, 2, 3.
        try await ProcessGlobalTestState.withLock {
            await AccountManager.shared.recordRecentlyCompleted(messageIds: ["1", "2", "3"])
            // NON-VACUITY, half 1: the contaminating write really landed. Without
            // this the test would pass on a build where `recordRecentlyCompleted`
            // silently did nothing, proving nothing at all.
            let recorded = await AccountManager.shared.isRecentlyCompleted("2")
            #expect(recorded, "fixture is vacuous — the contaminating protection entry was never recorded")
        }

        // SCOPE 2 — the victim. A different account whose Archive folder happens to
        // own UIDs 1/2/3, syncing WITHIN ONE EPOCH against a folder the server
        // reports as empty. That is complete knowledge, so the sweep must remove
        // all three; the only thing that can save them is protection leaked from
        // scope 1.
        try await ProcessGlobalTestState.withLock {
            let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
            defer {
                AppDatabase.shared.withLock { $0 = previous }
                TestDatabaseTeardown.retire(pool: pool, directory: dir)
            }

            let accountId = "recent-scope-isolation"
            let account = try FolderEpochTestFixture.makeAccount(
                id: accountId, provider: .imap, pool: pool)
            try FolderEpochTestFixture.insertFolder(
                accountId: accountId, path: "Archive", role: .archive, pool: pool,
                totalCount: 0, lastKnownUidValidity: 111, lastKnownHighestModSeq: 9000)
            try FolderEpochTestFixture.insertHeaders(
                accountId: accountId, path: "Archive", uids: [1, 2, 3], pool: pool)

            let mock = MockEmailProvider()
            // Same epoch (111 → 111) so no UIDVALIDITY term is in play at all; the
            // modseq moves so the folder is genuinely fetched.
            await mock.setFetchFoldersResult([
                FolderInfo(name: "Archive", path: "Archive", role: .archive, unreadCount: 0,
                           totalCount: 0, uidNext: 4, highestModSeq: 9500, uidValidity: 111)
            ])
            await mock.setFetchMessagesResult([])

            try await SyncEngine().fullSync(account: account, provider: mock)

            // NON-VACUITY, half 2: the sweep genuinely ran. A folder that was never
            // fetched deletes nothing for reasons that have nothing to do with the
            // protection map.
            let calls = await mock.callLogSnapshot()
            #expect(calls.contains { $0.hasPrefix("fetchMessages(folder:Archive") },
                    "fixture is vacuous — the folder was never fetched, so no sweep ran: \(calls)")

            #expect(try FolderEpochTestFixture.headerCount(
                accountId: accountId, path: "Archive", pool: pool) == 0,
                    """
                    the sweep skipped rows an unrelated earlier scope had completed ops on: \
                    process-global protection keyed by a bare IMAP UID leaked across the test \
                    scope boundary, so a folder this test's account never touched kept mail the \
                    server no longer has
                    """)
        }
    }
}
