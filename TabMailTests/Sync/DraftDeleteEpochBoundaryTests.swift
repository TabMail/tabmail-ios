/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

/// 🚨 THE SYSTEM PROPERTY: **a durable op recorded under a numbering the server
/// has since discarded NEVER EXECUTES.**
///
/// Asserted on what the PROVIDER was asked to do after a real
/// `queueDraftDelete` → real epoch advance → real `drainPendingQueue` sequence.
/// Deliberately NOT asserted on `PendingOperation.observedUidValidity`, on
/// `opIsAddressOnly`, or on any other part of the fix's mechanism: a
/// mechanism-pinning test inherits the spec that was wrong in the first place
/// and stays green on a broken system. The only thing that matters is that no
/// destructive command carrying a stale UID ever reaches `deleteDraft`.
///
/// **The defect this pins (confirmed 2026-07-31).** `queueDraftDelete` records
/// `messageIds = [numericUID, rfc822]` — the rfc822 id is carried for the sync
/// filter, not for resolution. Because a non-numeric id is present,
/// `AccountManager.opIsAddressOnly` returns FALSE, so the reset reaction's
/// step-5 sweep (`uidValidityResetStampFreshEpoch`) does not remove the row.
/// `executeOperation` then hands `messageIds.first` — the UID — to
/// `provider.deleteDraft`, which for a numeric id resolves to a LITERAL `UIDSet`
/// with no SEARCH. Post-reaction the op unparked and destroyed whichever message
/// the new epoch had placed at that UID: constraint C3, the one hard invariant.
///
/// **The mirror image, covered by the two controls below.** The fix's failure
/// mode is a PERMANENT refusal — a draft delete that silently stops working.
/// `unchangedEpochStillDeletesTheDraft` proves an untouched epoch still executes,
/// and `rfc822AddressedDeleteSurvivesAnEpochChange` proves the epoch-IMMUNE shape
/// (Message-ID SEARCH) is not swept up by the guard. Dropping either would be
/// dropping user intention for zero safety gain.
///
/// `.serialized, .processGlobalState` — replaces `AppDatabase.shared` and drives
/// the shared `AccountManager`'s provider registry and drain.
@Suite("A draft delete must not survive the UIDVALIDITY reset it was recorded under",
       .serialized, .processGlobalState)
struct DraftDeleteEpochBoundaryTests {

    private static let oldEpoch = 810_001
    private static let newEpoch = 810_002

    /// One IMAP account with a drafts-role folder stamped at `oldEpoch`.
    /// `FolderEpochTestFixture` (declared in `SyncFolderEpochPersistenceTests.swift`)
    /// is reused rather than re-rolled — it runs the real migrator, so the v69
    /// column under test exists exactly as it does in a shipped database.
    @MainActor
    private static func makeFixture(
        accountId: String
    ) throws -> (pool: DatabasePool, dir: URL, previous: AppDatabase?) {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        _ = try FolderEpochTestFixture.makeAccount(id: accountId, provider: .imap, pool: pool)
        try FolderEpochTestFixture.insertFolder(
            accountId: accountId, path: "INBOX", role: .inbox, pool: pool,
            lastKnownUidValidity: oldEpoch)
        try FolderEpochTestFixture.insertFolder(
            accountId: accountId, path: "Drafts", role: .drafts, pool: pool,
            lastKnownUidValidity: oldEpoch)
        return (pool, dir, previous)
    }

    /// Advance the folder's epoch through the PRODUCTION transactions the reset
    /// reaction itself uses — arm the quarantine, then stamp the fresh epoch (the
    /// write that also runs the address-only sweep and clears the flag). Driving
    /// the real boundary rather than a hand-written `UPDATE folder SET …` is what
    /// keeps this a test of the system and not of a fixture.
    @MainActor
    private static func advanceEpoch(accountId: String, folderPath: String, to fresh: Int) async {
        let folderId = "\(accountId):\(folderPath)"
        let armed = await AccountManager.shared.uidValidityResetArmFlag(folderId: folderId)
        #expect(armed, "fixture precondition: the quarantine flag could not be armed")
        let stamped = await AccountManager.shared.uidValidityResetStampFreshEpoch(
            accountId: accountId, folderPath: folderPath, folderId: folderId,
            fresh: UInt32(fresh))
        #expect(stamped, "fixture precondition: the fresh epoch could not be stamped")
    }

    @MainActor
    private static func withRegisteredProvider(
        accountId: String, provider: any EmailProvider, _ body: () async throws -> Void
    ) async rethrows {
        await AccountManager.shared.registerProviderForTesting(accountId: accountId, provider: provider)
        defer { Task { await AccountManager.shared.unregisterProviderForTesting(accountId: accountId) } }
        try await body()
    }

    private static func draftDeleteCalls(_ mock: MockEmailProvider) async -> [String] {
        await mock.callLogSnapshot().filter { $0.hasPrefix("deleteDraft(") }
    }

    /// Drain until the queue is EMPTY *and* no drain is in flight, or the bound is
    /// exhausted.
    ///
    /// ⚠ A single `await drainPendingQueue()` is NOT sufficient here and silently
    /// under-tests. `queueDraftDelete` ends with an unstructured `Task { await
    /// drainPendingQueue() }` of its own; if that stray drain is still inside its
    /// three-pass loop when the test's explicit call arrives, the `isDraining`
    /// guard turns the test's call into a `needsRedrain` flag and returns
    /// IMMEDIATELY, so the assertions run before anything has executed. That is
    /// what made `unchangedEpochStillDeletesTheDraft` fail against the CORRECT
    /// implementation on its first run. The predicate is sampled AFTER the drain
    /// returns and includes `pendingQueueIsQuiescentForTesting` precisely so a
    /// deferred re-drive is joined rather than raced.
    @MainActor
    private static func drainUntilSettled(_ pool: DatabasePool) async {
        for _ in 0..<60 {
            await AccountManager.shared.drainPendingQueue()
            let remaining = (try? await pool.read { db in try PendingOperation.fetchCount(db) }) ?? 1
            let quiescent = await AccountManager.shared.pendingQueueIsQuiescentForTesting()
            if remaining == 0 && quiescent { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    // MARK: - 1. The invariant

    @Test("A draft delete recorded under the old numbering never reaches the provider")
    @MainActor
    func draftDeleteRecordedUnderTheOldEpochNeverExecutes() async throws {
        let accountId = "draft-epoch-drop"
        let (pool, dir, previous) = try Self.makeFixture(accountId: accountId)
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }

        // The user deletes a SYNCED draft — `serverDraftId` is the IMAP UID that
        // `IMAPProvider.saveDraft` minted, which is the ordinary shape.
        await AccountManager.shared.queueDraftDelete(
            serverDraftId: "5150", accountId: accountId,
            rfc822MessageId: "draft-under-old-epoch@example.com")
        let queued = try await pool.read { db in try PendingOperation.fetchAll(db) }
        #expect(queued.count == 1, "fixture precondition: the delete was not admitted at all")
        guard queued.count == 1 else { return }
        #expect(!AccountManager.opIsAddressOnly(queued[0]),
                """
                fixture precondition LOST: this op is now classified address-only, so the reaction's \
                own sweep would remove it and this test would prove nothing. The whole point is that \
                a `[uid, rfc822]` op escapes that classifier.
                """)

        // The server renumbers the mailbox. UID 5150 now names a DIFFERENT message.
        await Self.advanceEpoch(accountId: accountId, folderPath: "Drafts", to: Self.newEpoch)

        let mock = MockEmailProvider()
        await Self.withRegisteredProvider(accountId: accountId, provider: mock) {
            await Self.drainUntilSettled(pool)
        }

        let calls = await Self.draftDeleteCalls(mock)
        #expect(calls.isEmpty,
                """
                a draft delete recorded under UIDVALIDITY \(Self.oldEpoch) was executed against \
                UIDVALIDITY \(Self.newEpoch): \(calls). UID 5150 addresses a numbering the server \
                discarded, so `IMAPProvider.deleteDraft` resolves it to a literal UIDSet and \
                expunges whichever message the NEW numbering put there — C3. C5 makes dropping the \
                intention at an identity-reset boundary the correct resolution.
                """)
        let remaining = try await pool.read { db in try PendingOperation.fetchAll(db) }
        #expect(remaining.isEmpty,
                """
                the op survived the drain without executing — that is a PARK, not a no-op, and the \
                old epoch never comes back, so it wedges this lane forever.
                """)
    }

    // MARK: - 2. Over-refusal controls (the mirror image)

    @Test("Control: an UNCHANGED epoch still deletes the draft")
    @MainActor
    func unchangedEpochStillDeletesTheDraft() async throws {
        let accountId = "draft-epoch-unchanged"
        let (pool, dir, previous) = try Self.makeFixture(accountId: accountId)
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }

        await AccountManager.shared.queueDraftDelete(
            serverDraftId: "5151", accountId: accountId,
            rfc822MessageId: "draft-same-epoch@example.com")
        #expect(try await pool.read { db in try PendingOperation.fetchCount(db) } == 1,
                "fixture precondition: the delete was not admitted")

        let mock = MockEmailProvider()
        await Self.withRegisteredProvider(accountId: accountId, provider: mock) {
            await Self.drainUntilSettled(pool)
        }

        let calls = await Self.draftDeleteCalls(mock)
        #expect(calls.contains { $0.contains("draftId:5151") },
                """
                a draft delete on a folder whose epoch NEVER CHANGED was refused. This is the \
                mirror image of the bug: a guard that never lifts silently stops draft deletion \
                working at all, and the server draft reappears on the next sync.
                """)
    }

    @Test("Control: an rfc822-addressed draft delete survives an epoch change and still executes")
    @MainActor
    func rfc822AddressedDeleteSurvivesAnEpochChange() async throws {
        // A non-numeric `serverDraftId` routes through `IMAPProvider.searchByMessageId`,
        // which resolves by RFC 822 Message-ID and is unaffected by any renumbering.
        // Refusing it would drop user intention for zero safety gain — the exact
        // over-drop `opIsAddressOnly` already refuses to make for a mixed op.
        let accountId = "draft-epoch-rfc"
        let (pool, dir, previous) = try Self.makeFixture(accountId: accountId)
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }

        await AccountManager.shared.queueDraftDelete(
            serverDraftId: "draft-epoch-immune@example.com", accountId: accountId)
        #expect(try await pool.read { db in try PendingOperation.fetchCount(db) } == 1,
                "fixture precondition: the rfc822-addressed delete was not admitted")

        await Self.advanceEpoch(accountId: accountId, folderPath: "Drafts", to: Self.newEpoch)

        let mock = MockEmailProvider()
        await Self.withRegisteredProvider(accountId: accountId, provider: mock) {
            await Self.drainUntilSettled(pool)
        }

        let calls = await Self.draftDeleteCalls(mock)
        #expect(calls.contains { $0.contains("draftId:draft-epoch-immune@example.com") },
                """
                an epoch-IMMUNE draft delete (resolved by Message-ID SEARCH, not by UID) was dropped \
                at the reset boundary. A UIDVALIDITY change cannot invalidate a Message-ID, so this \
                is a pure intention drop — NEVER DROP USER INTENTION.
                """)
    }
}
