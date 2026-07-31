/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
import Synchronization
@testable import TabMail

/// The red-first proof that `MockEmailProvider`'s UIDVALIDITY epoch seam and
/// its await-boundary hooks are **live** — i.e. that a mock-driven epoch
/// observation reaches the production code that consumes it, and that a test
/// can act while a provider call is genuinely in flight.
///
/// ## Why this suite exists — a missing override makes future tests LIE
///
/// `EmailProvider.lastObservedUidValidity(folderPath:)`
/// (`TabMail/Providers/EmailProvider.swift:188`) carries a `nil` protocol
/// default (`:258`), because UIDVALIDITY is an IMAP concept and every other
/// provider honestly reports "unknown". `IMAPProvider` overrides it from its
/// `Mutex`-backed SELECT mirror (`IMAPProvider.swift:80-88`). `MockEmailProvider`
/// did **not** — so it silently inherited `nil`.
///
/// A mock that always answers `nil` does not merely fail to model the epoch; it
/// makes every test written against the epoch pass **vacuously**. "Stamp the
/// source epoch at admission" stamps `nil`; "compare the stamped epoch at claim
/// time" compares `nil` to `nil` and never takes the mismatch branch. Each test
/// goes green without ever executing the branch it was written for — an
/// assertion that cannot fail. That is the same shape as the rejected
/// drop-on-epoch-change attempt, and it is why the seam is a **prerequisite**
/// for the epoch stamp/compare work rather than a follow-up to it.
///
/// So this suite does not assert "the mock has a method". It asserts the SYSTEM
/// property that the missing override destroyed: **an epoch the provider
/// observes during a sync pass reaches `Folder.lastKnownUidValidity`.** The real
/// production capture site is `SyncEngineFullSync.runSyncMessages`
/// (`SyncEngineFullSync.swift:693`), which reads the observation into a local
/// immediately after its own `fetchMessages` and persists it through
/// `SyncEngine.bootstrapFolderUidValidity` (`SyncEngineDeltaSync.swift:844`)
/// inside the same write transaction. Nothing here is mocked except the
/// provider, and nothing about the assertion changes if the mock's internals do.
///
/// ## REFERENCE (`v2final`, tag `e28dd4edb`)
///
/// The seam under test is a verbatim port of
/// `v2final:TabMailTests/Mocks/MockEmailProvider.swift:29-71` — the `Mutex`-backed
/// per-folder box, the `nonisolated` override, `setMockedUidValidity` and the
/// per-call consuming `setMockedUidValiditySequence`. That region is
/// keying-agnostic (it concerns the FOLDER epoch, never message identity), so it
/// needed no adaptation to v3's provider-id keying. The reference drives it from
/// `v2final:TabMailTests/Services/SyncEngineUidValidityMergeGuardTests.swift:547`,
/// where sequence `[old]` + static `new` proves a merge guard compares the
/// epoch its own fetch captured rather than re-reading the live mirror. v3 has
/// no such guard yet, so the tests below pin the seam's contract at the one
/// production consumer v3 does have.
///
/// ## Red-first evidence — MEASURED 2026-07-30, quoted verbatim
///
/// The inversion is the MINIMAL one that reproduces the defect exactly: the
/// mock's `lastObservedUidValidity(folderPath:)` was renamed, so it stopped
/// being the protocol witness and the actor fell back to
/// `EmailProvider`'s `{ nil }` default — i.e. precisely the 220-line shape at
/// `b3fb8563f`. Everything else (both `Mutex` boxes, both setters, this file)
/// was left untouched, so the boxes stay populated and the failures can only be
/// the missing override. Verbatim console output:
///
/// ```
/// ✘ Test "A mock-observed epoch reaches the folder's stored epoch" recorded an issue at MockProviderEpochSeamTests.swift:157:9: Expectation failed: (mock.lastObservedUidValidity(folderPath: "INBOX") → nil) == (observedEpoch → 838601)
/// ✘ Test "A mock-observed epoch reaches the folder's stored epoch" recorded an issue at MockProviderEpochSeamTests.swift:171:9: Expectation failed: (after → nil) == (Int(observedEpoch) → 838601)
/// ✘ Test "A mock-observed epoch reaches the folder's stored epoch" failed after 0.294 seconds with 2 issues.
/// ✘ Test "A consuming epoch sequence hands successive sync passes successive values" recorded an issue at MockProviderEpochSeamTests.swift:220:9: Expectation failed: (afterFirst → nil) == (Int(firstEpoch) → 838701)
/// ✘ Test "A consuming epoch sequence hands successive sync passes successive values" recorded an issue at MockProviderEpochSeamTests.swift:232:9: Expectation failed: (afterSecond → nil) == (Int(secondEpoch) → 838702)
/// ✘ Test "A consuming epoch sequence hands successive sync passes successive values" recorded an issue at MockProviderEpochSeamTests.swift:244:9: Expectation failed: (afterThird → nil) == (Int(staticEpoch) → 838703)
/// ✘ Test "A consuming epoch sequence hands successive sync passes successive values" failed after 0.050 seconds with 3 issues.
/// ✔ Test "A provider call in flight has not yet released its durable operation" passed after 0.043 seconds.
/// ✘ Test run with 3 tests in 1 suite failed after 0.401 seconds with 5 issues.
/// ```
///
/// `→ nil` on every epoch assertion is the inherited protocol default in action:
/// the production capture site ran, read `nil`, and persisted nothing — while
/// the test had configured `838601`. That is the vacuous pass, made visible.
/// The probe was restored in the SAME step and the restoration proved by md5
/// (`bedd29e3…`), `git diff --numstat` back to `103 0`, and a grep showing no
/// probe text survives anywhere in the tree.
///
/// The `.swift:NNN` line numbers above are as-recorded; this doc comment has
/// changed length since (it now carries the output it describes), so they no
/// longer index the same assertions — the quoted test name plus expectation is
/// the identifying part. Same convention as
/// `SelectSourcedFolderEpochTests`'s recorded inversions.
///
/// The third test is green on both shapes **by construction** — the hooks it
/// drives are new seams, so its acceptance is that the shape is usable from a
/// real production drive, not a red-to-green transition. Without the hook the
/// observation it makes is not merely wrong, it is unwritable.
///
/// `.serialized, .processGlobalState` — every test here swaps
/// `AppDatabase.shared`, and the third also drives `AccountManager.shared`.
@Suite("The mock provider's epoch + in-flight seams are live", .serialized, .processGlobalState)
struct MockProviderEpochSeamTests {

    // MARK: - Harness

    /// Reads the column straight from SQLite rather than through a cached
    /// `Folder` value, so the assertion cannot be satisfied by a stale in-memory
    /// copy of the row the write transaction updated.
    private func storedEpoch(accountId: String, path: String, pool: DatabasePool) throws -> Int? {
        try FolderEpochTestFixture.readFolder(accountId: accountId, path: path, pool: pool)?
            .lastKnownUidValidity
    }

    /// Returns the column to "never observed" so a following sync pass faces the
    /// same bootstrap opportunity as the first. `bootstrapFolderUidValidity` is
    /// deliberately BOOTSTRAP-ONLY (`SyncEngineDeltaSync.swift:802`) — it writes
    /// nothing once the column holds a value — so without this the second and
    /// third passes below could not distinguish "the sequence advanced" from
    /// "the write was refused", and the test would pass for the wrong reason.
    private func clearStoredEpoch(folderId: String, pool: DatabasePool) throws {
        try pool.write { db in
            try db.execute(
                sql: "UPDATE folder SET lastKnownUidValidity = NULL WHERE id = ?",
                arguments: [folderId])
        }
    }

    /// Non-async, so GRDB's synchronous `write`/`read` overloads are selected —
    /// inside an `async` test body the async overloads win and the call needs an
    /// `await` it must not have. Same idiom as
    /// `AccountManagerQueueDrainTests.insertOp`/`fetchOp`.
    private func insertOp(_ op: PendingOperation, pool: DatabasePool) throws {
        try pool.writeWithoutTransaction { db in try op.insert(db) }
    }

    private func fetchOp(_ id: String, pool: DatabasePool) throws -> PendingOperation? {
        try pool.read { db in try PendingOperation.fetchOne(db, key: id) }
    }

    // MARK: - 1. The round trip

    /// THE headline case, and the one the missing override silently broke: an
    /// epoch the provider observed during a sync pass must end up readable from
    /// the DB. With the mock inheriting the protocol's `nil` default this
    /// assertion reads `nil` no matter what the test configures — which is
    /// exactly why a stamp-the-epoch test written against this mock would have
    /// stamped nothing and still gone green.
    ///
    /// The folder starts with an empty mailbox and no local headers, so the
    /// pass's stale-detection sweep has nothing to classify and the only thing
    /// this test can measure is the epoch persist.
    @Test("A mock-observed epoch reaches the folder's stored epoch")
    func mockObservedEpochReachesTheStoredEpoch() async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }

        let accountId = "mock-epoch-roundtrip"
        _ = try FolderEpochTestFixture.makeAccount(id: accountId, provider: .imap, pool: pool)
        try FolderEpochTestFixture.insertFolder(
            accountId: accountId, path: "INBOX", role: .inbox, pool: pool, totalCount: 0)
        let folder = try #require(
            try FolderEpochTestFixture.readFolder(accountId: accountId, path: "INBOX", pool: pool))
        #expect(folder.lastKnownUidValidity == nil, "precondition: no epoch stored yet")

        let observedEpoch: UInt32 = 838_601
        let mock = MockEmailProvider(staleWindowMode: .uid)
        await mock.setMockedUidValidity(observedEpoch, folderPath: "INBOX")
        await mock.setFetchMessagesResult([])

        // Precondition that makes this a test of the ROUND TRIP rather than of
        // the setter: the provider really does answer with the configured epoch
        // when asked the way production asks.
        #expect(mock.lastObservedUidValidity(folderPath: "INBOX") == observedEpoch,
                "precondition: the seam must answer, otherwise the assertion below is vacuous")
        #expect(mock.lastObservedUidValidity(folderPath: "Archive") == nil,
                "a folder the test never configured must still answer honestly unknown")

        _ = try await SyncEngine.runSyncMessages(
            for: folder, provider: mock, limit: SyncConfig.syncMessageLimit,
            dbPool: AppDatabase.dbPool)

        // Bound to a local first: Swift Testing does not expand a `try`
        // expression, so asserting on the call directly would print the
        // expression source instead of the observed value — and the observed
        // value (`→ nil`) is the whole evidence.
        let after = try storedEpoch(accountId: accountId, path: "INBOX", pool: pool)
        #expect(after == Int(observedEpoch),
                """
                a sync pass must persist the epoch its own fetch observed — a provider double \
                that always answers nil makes every stamp-the-epoch and compare-the-epoch test \
                pass without ever executing the branch it was written for
                """)
    }

    // MARK: - 2. The consuming sequence

    /// The seam's second half, and the one that models the hazard the epoch
    /// checkpoints exist to close: the shared cross-connection mirror ADVANCING
    /// between the moment a pass captures the epoch and the moment a later guard
    /// evaluates it. A static value cannot express that — every read returns the
    /// same answer, so a guard that wrongly re-reads the live mirror is
    /// indistinguishable from one that correctly uses its captured value.
    ///
    /// Three successive passes over the same folder, each given a fresh
    /// bootstrap opportunity, must persist `[first, second, static]` in that
    /// order: the sequence takes precedence while it has entries, each call
    /// consumes exactly one, and once exhausted the static value answers. All
    /// three land through the real production capture site, so this pins the
    /// contract end-to-end rather than the mock's internals.
    @Test("A consuming epoch sequence hands successive sync passes successive values")
    func consumingEpochSequenceYieldsSuccessiveValues() async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }

        let accountId = "mock-epoch-sequence"
        _ = try FolderEpochTestFixture.makeAccount(id: accountId, provider: .imap, pool: pool)
        try FolderEpochTestFixture.insertFolder(
            accountId: accountId, path: "INBOX", role: .inbox, pool: pool, totalCount: 0)
        let folder = try #require(
            try FolderEpochTestFixture.readFolder(accountId: accountId, path: "INBOX", pool: pool))
        let folderId = folder.id

        let firstEpoch: UInt32 = 838_701
        let secondEpoch: UInt32 = 838_702
        let staticEpoch: UInt32 = 838_703

        let mock = MockEmailProvider(staleWindowMode: .uid)
        await mock.setMockedUidValiditySequence([firstEpoch, secondEpoch], folderPath: "INBOX")
        await mock.setMockedUidValidity(staticEpoch, folderPath: "INBOX")
        await mock.setFetchMessagesResult([])

        _ = try await SyncEngine.runSyncMessages(
            for: folder, provider: mock, limit: SyncConfig.syncMessageLimit,
            dbPool: AppDatabase.dbPool)
        let afterFirst = try storedEpoch(accountId: accountId, path: "INBOX", pool: pool)
        #expect(afterFirst == Int(firstEpoch),
                """
                while the sequence has entries it must take precedence over the static value — \
                otherwise a test cannot express a mirror that has already moved on from the \
                epoch the pass under test actually ran under
                """)

        try clearStoredEpoch(folderId: folderId, pool: pool)
        _ = try await SyncEngine.runSyncMessages(
            for: folder, provider: mock, limit: SyncConfig.syncMessageLimit,
            dbPool: AppDatabase.dbPool)
        let afterSecond = try storedEpoch(accountId: accountId, path: "INBOX", pool: pool)
        #expect(afterSecond == Int(secondEpoch),
                """
                each observation must CONSUME one sequence entry: a sequence that replayed its \
                first value would make "the mirror advanced between capture and evaluation" \
                unrepresentable, which is the whole hazard the epoch checkpoints exist to close
                """)

        try clearStoredEpoch(folderId: folderId, pool: pool)
        _ = try await SyncEngine.runSyncMessages(
            for: folder, provider: mock, limit: SyncConfig.syncMessageLimit,
            dbPool: AppDatabase.dbPool)
        let afterThird = try storedEpoch(accountId: accountId, path: "INBOX", pool: pool)
        #expect(afterThird == Int(staticEpoch),
                "once the sequence is exhausted the static value must answer, not nil")
    }

    // MARK: - 3. The await-boundary hook

    /// The in-flight seam. `executeSingleOp` deletes the durable
    /// `PendingOperation` row only AFTER the provider call returns
    /// (`AccountManagerQueue.swift:413-419`, step 3, deliberately ordered after
    /// step 2's `recordRecentlyCompleted`): the user's intention stays on disk
    /// until the server has actually been told. That ordering is the
    /// persist-before-acknowledge half of NEVER DROP USER INTENTION, and the
    /// window it guards is invisible from outside — a test that only looks
    /// before and after sees a row, then no row, and must INFER what happened
    /// in between.
    ///
    /// `setMarkReadHook` is what makes the window observable: it is awaited from
    /// inside `MockEmailProvider.markRead`, i.e. inside `executeOperation`,
    /// inside `executeSingleOp`'s timeout box. Reading the row from there
    /// observes the real intermediate state.
    @Test("A provider call in flight has not yet released its durable operation")
    func aProviderCallInFlightHasNotYetReleasedItsDurableOperation() async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }

        let op = PendingOperation(
            type: .markRead, messageIds: ["mock-hook-msg-1"],
            accountId: "mock-hook-acc", folderPath: "INBOX")
        try insertOp(op, pool: pool)

        // `@Sendable` closure state crossing isolation domains — `Mutex`, never
        // `nonisolated(unsafe)` (iOS resilience rule 5).
        let observed = Mutex<(fired: Bool, rowPresentInFlight: Bool)>((false, false))
        let opId = op.id
        let provider = MockEmailProvider()
        await provider.setMarkReadHook {
            let present = ((try? pool.read { db in try PendingOperation.fetchOne(db, key: opId) }) ?? nil) != nil
            observed.withLock { $0 = (fired: true, rowPresentInFlight: present) }
        }

        let outcome = await AccountManager.shared.executeSingleOp(
            op, provider: provider, context: AccountManager.DrainContext())

        let (fired, rowPresentInFlight) = observed.withLock { $0 }
        #expect(fired, "the hook must actually be awaited from inside the provider call, not skipped")
        #expect(rowPresentInFlight,
                """
                the durable intention must still be on disk while the provider call that \
                discharges it is in flight — releasing it first opens a window in which a crash \
                loses the user's action with the server never having been told
                """)
        #expect(outcome == .proceed, "a successful markRead completes the op")

        let after = try fetchOp(opId, pool: pool)
        #expect(after == nil, "and only once the call returned is the row released")
    }
}
