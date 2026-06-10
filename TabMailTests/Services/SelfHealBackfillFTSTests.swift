/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

/// Integration tests for `SyncEngine.selfHealBackfillFTSMembership`.
///
/// The self-heal is the safety net that catches the FTS orphan case described
/// in the original log (`logmain.log`): rows with `headerComplete=1` that the
/// FTS index doesn't actually have. Without the heal, `updateBodies()` silently
/// defers, `bodyComplete` stays 0, and the backfill queue re-dispatches the
/// same rows every cycle.
///
/// Tests use the production `AppDatabase.dbPool` and `SearchIndex.shared`
/// singletons (what the function operates on) and clean up both GRDB and FTS
/// state at the end of each test so runs don't pollute each other.
@Suite("SyncEngine.selfHealBackfillFTSMembership — orphan detection + re-index")
struct SelfHealBackfillFTSTests {

    // MARK: - Fixture

    /// Insert a messageHeader directly into production GRDB (skipping FTS
    /// indexing) so it matches the "orphan" shape the self-heal targets.
    /// Returns the headerId. Caller cleans up via `cleanup`.
    private func insertHeaderMissingFromFTS(
        accountId: String,
        folderPath: String,
        messageId: String,
        headerComplete: Bool,
        bodyComplete: Bool,
        bodyEmptyConfirmed: Bool
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
                subject: "selfheal test", from: "a@x", fromAddress: "a@x", to: "b@x",
                date: Date(), snippet: "",
                folderId: folderId, accountId: accountId, folderPath: folderPath,
                isInInbox: false
            )
            header.headerComplete = headerComplete
            header.bodyComplete = bodyComplete
            header.bodyEmptyConfirmed = bodyEmptyConfirmed
            try header.insert(db)
        }
        return headerId
    }

    private func cleanup(headerId: String) async {
        try? await AppDatabase.dbPool.write { db in
            try db.execute(sql: "DELETE FROM messageHeader WHERE id = ?", arguments: [headerId])
        }
        try? await SearchIndex.shared.removeMessages(headerIds: [headerId])
    }

    private func isMissingFromFTS(headerId: String) async -> Bool {
        let missing = (try? await SearchIndex.shared.headerIdsMissingFromFTS([headerId])) ?? []
        return missing.contains(headerId)
    }

    // MARK: - Tests

    @Test("Orphan (headerComplete=1, bodyComplete=0, missing from FTS) is re-indexed")
    func reindexesOrphan() async throws {
        let engine = SyncEngine()
        let headerId = try await insertHeaderMissingFromFTS(
            accountId: "selfheal-orphan", folderPath: "Archive", messageId: "m1",
            headerComplete: true, bodyComplete: false, bodyEmptyConfirmed: false
        )
        // Precondition — FTS really is missing this header.
        #expect(await isMissingFromFTS(headerId: headerId) == true, "precondition: FTS must be missing the orphan")

        await engine.selfHealBackfillFTSMembership()

        #expect(await isMissingFromFTS(headerId: headerId) == false, "self-heal should re-index the orphan")
        await cleanup(headerId: headerId)
    }

    @Test("No-op when no orphans exist (all candidate rows already in FTS)")
    func noOpWhenAllIndexed() async throws {
        // Precondition guard — we assume the production FTS and GRDB are in
        // sync for whatever non-test accounts are present. We insert one
        // orphan, re-index it ourselves, run self-heal, verify it doesn't
        // choke on a well-formed DB. Most of this test's value is that the
        // function returns cleanly when nothing needs healing.
        let engine = SyncEngine()
        let headerId = try await insertHeaderMissingFromFTS(
            accountId: "selfheal-noop", folderPath: "Archive", messageId: "m1",
            headerComplete: true, bodyComplete: false, bodyEmptyConfirmed: false
        )
        // First run heals it; second run is the "no-op" case we're testing.
        await engine.selfHealBackfillFTSMembership()
        #expect(await isMissingFromFTS(headerId: headerId) == false)

        // Run again — should find no orphans for THIS row (re-indexing an
        // already-indexed row is a no-op at the SQL level).
        await engine.selfHealBackfillFTSMembership()
        #expect(await isMissingFromFTS(headerId: headerId) == false)
        await cleanup(headerId: headerId)
    }

    @Test("Out of scope: bodyComplete=1 header is NOT re-indexed by backfill self-heal")
    func skipsRowsOutOfScope_bodyComplete() async throws {
        // The backfill self-heal scope is deliberately narrow: `headerComplete=1
        // AND bodyComplete=0 AND !bodyEmptyConfirmed`. Rows with bodyComplete=1
        // are handled by `selfHealFTSBodyMembership` instead (all folders,
        // most-recent-first — see FTSSelfHealCandidateScopeTests).
        // This test pins the scope — if someone broadens the SQL it'll catch it.
        let engine = SyncEngine()
        let headerId = try await insertHeaderMissingFromFTS(
            accountId: "selfheal-bodydone", folderPath: "Archive", messageId: "m1",
            headerComplete: true, bodyComplete: true, bodyEmptyConfirmed: false
        )
        #expect(await isMissingFromFTS(headerId: headerId) == true, "precondition")

        await engine.selfHealBackfillFTSMembership()

        // bodyComplete=1 is out of scope for THIS heal → still missing.
        #expect(await isMissingFromFTS(headerId: headerId) == true, "bodyComplete=1 rows are not backfill's scope")
        await cleanup(headerId: headerId)
    }

    @Test("Out of scope: bodyEmptyConfirmed=1 header is NOT re-indexed")
    func skipsRowsOutOfScope_bodyEmptyConfirmed() async throws {
        // bodyEmptyConfirmed rows represent messages we've actively decided not
        // to retry body fetch for. They must not be dragged back into the
        // backfill queue via FTS re-indexing.
        let engine = SyncEngine()
        let headerId = try await insertHeaderMissingFromFTS(
            accountId: "selfheal-emptyconfirmed", folderPath: "Archive", messageId: "m1",
            headerComplete: true, bodyComplete: false, bodyEmptyConfirmed: true
        )
        #expect(await isMissingFromFTS(headerId: headerId) == true, "precondition")

        await engine.selfHealBackfillFTSMembership()

        #expect(await isMissingFromFTS(headerId: headerId) == true, "bodyEmptyConfirmed rows must stay out")
        await cleanup(headerId: headerId)
    }

    @Test("Out of scope: headerComplete=0 header is NOT re-indexed (handled by recoverIncompleteHeaders)")
    func skipsRowsOutOfScope_headerIncomplete() async throws {
        // headerComplete=0 means the header was never successfully FTS-indexed
        // to begin with — that's the `recoverIncompleteHeaders` pathway, not
        // ours. This self-heal assumes GRDB has claimed FTS membership.
        let engine = SyncEngine()
        let headerId = try await insertHeaderMissingFromFTS(
            accountId: "selfheal-headerincomplete", folderPath: "Archive", messageId: "m1",
            headerComplete: false, bodyComplete: false, bodyEmptyConfirmed: false
        )
        #expect(await isMissingFromFTS(headerId: headerId) == true, "precondition")

        await engine.selfHealBackfillFTSMembership()

        #expect(await isMissingFromFTS(headerId: headerId) == true, "headerComplete=0 is recoverIncompleteHeaders' job")
        await cleanup(headerId: headerId)
    }

    @Test("Multiple orphans across different (account, folder) — all re-indexed")
    func reindexesMultipleOrphans() async throws {
        // The self-heal should be batch-oriented, not per-row. Mixing accounts
        // + folders verifies no hidden single-account assumption slipped in.
        let engine = SyncEngine()
        let h1 = try await insertHeaderMissingFromFTS(
            accountId: "selfheal-multi-a", folderPath: "Archive", messageId: "m1",
            headerComplete: true, bodyComplete: false, bodyEmptyConfirmed: false
        )
        let h2 = try await insertHeaderMissingFromFTS(
            accountId: "selfheal-multi-b", folderPath: "Sent", messageId: "m1",
            headerComplete: true, bodyComplete: false, bodyEmptyConfirmed: false
        )
        let h3 = try await insertHeaderMissingFromFTS(
            accountId: "selfheal-multi-a", folderPath: "Drafts", messageId: "m2",
            headerComplete: true, bodyComplete: false, bodyEmptyConfirmed: false
        )

        await engine.selfHealBackfillFTSMembership()

        #expect(await isMissingFromFTS(headerId: h1) == false)
        #expect(await isMissingFromFTS(headerId: h2) == false)
        #expect(await isMissingFromFTS(headerId: h3) == false)

        await cleanup(headerId: h1)
        await cleanup(headerId: h2)
        await cleanup(headerId: h3)
    }
}
