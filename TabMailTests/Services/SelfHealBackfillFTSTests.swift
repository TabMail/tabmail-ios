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

    @Test("Full-history heal re-indexes stuck rows regardless of date rank")
    func fullHistoryHealReindexesOldStuckRows() async throws {
        // The recurring heal samples only the most-recent 2000 by date; the
        // one-time full-history walk must reach stuck rows at ANY date rank.
        // Use a years-old date (dynamically derived — no hardcoded dates).
        let engine = SyncEngine()
        let oldDate = Calendar.current.date(byAdding: .year, value: -8, to: Date())!
        let headerId = try await insertHeaderMissingFromFTS(
            accountId: "fullheal-old", folderPath: "Archive", messageId: "m1",
            headerComplete: true, bodyComplete: true, bodyEmptyConfirmed: false
        )
        try await AppDatabase.dbPool.write { db in
            try db.execute(sql: "UPDATE messageHeader SET date = ? WHERE id = ?",
                           arguments: [oldDate, headerId])
        }
        #expect(await isMissingFromFTS(headerId: headerId) == true, "precondition")

        let healed = try await engine.healAllFTSBodyMembership(scopePrefix: "fullheal-old:")

        #expect(healed == 1)
        #expect(await isMissingFromFTS(headerId: headerId) == false, "full sweep must re-index regardless of age")
        // bodyComplete reset so the body pipeline re-fetches + re-indexes the body.
        let bodyComplete: Bool = try await AppDatabase.dbPool.read { db in
            try Bool.fetchOne(db, sql: "SELECT bodyComplete FROM messageHeader WHERE id = ?",
                              arguments: [headerId]) ?? true
        }
        #expect(bodyComplete == false)
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

// MARK: - One-time FTS orphan prune (FTS→GRDB direction)

/// `pruneFTSOrphans` removes FTS entries whose header id no longer exists in
/// GRDB — the inverse direction of the self-heals above. Uses the production
/// `AppDatabase.dbPool` + `SearchIndex.shared` (what the function operates on)
/// with unique prefixes + cleanup, mirroring the suites above.
@Suite("SyncEngine.pruneFTSOrphans — dead FTS entry removal", .serialized)
struct FTSOrphanPruneTests {

    private func makeRecord(_ headerId: String) -> FTSHeaderRecord {
        FTSHeaderRecord(
            headerId: headerId, messageId: "m-\(headerId.suffix(6))",
            subject: "orphanprune test", from: "a@x", to: "b@x",
            dateMs: Int64(Date().timeIntervalSince1970 * 1000),
            folderId: "orphanprune:INBOX"
        )
    }

    /// Insert a GRDB header whose PK is exactly `headerId` (account/folder
    /// created on demand), so the prune sees it as live.
    private func insertLiveHeader(headerId: String) async throws {
        let accountId = "orphanprune-acct"
        let folderPath = "INBOX"
        let messageId = String(headerId.split(separator: ":").last ?? "m1")
        try await AppDatabase.dbPool.write { db in
            if try Account.fetchOne(db, key: accountId) == nil {
                var account = Account(emailAddress: "op@example.com", displayName: "T", provider: .gmail)
                account.id = accountId
                try account.insert(db)
            }
            let folderId = MessageIdentity.folderId(accountId: accountId, folderPath: folderPath)
            if try Folder.fetchOne(db, key: folderId) == nil {
                let folder = Folder(name: folderPath, path: folderPath, role: .inbox, accountId: accountId)
                try folder.insert(db)
            }
            var header = MessageHeader(
                messageId: messageId,
                subject: "live", from: "a@x", fromAddress: "a@x", to: "b@x",
                date: Date(), snippet: "",
                folderId: folderId, accountId: accountId, folderPath: folderPath,
                isInInbox: true
            )
            try header.insert(db)
        }
    }

    private func cleanupGRDB(accountId: String) async {
        try? await AppDatabase.dbPool.write { db in
            _ = try Account.deleteOne(db, key: accountId) // cascades headers/folders
        }
    }

    @Test("Dead FTS entries are pruned; live entries survive")
    func prunesDeadKeepsLive() async throws {
        let liveId = "orphanprune-acct:INBOX:op-live-1"
        let deadId = "orphanprune-acct:INBOX:op-dead-1"
        try? await SearchIndex.shared.removeMessages(headerIds: [liveId, deadId])

        try await insertLiveHeader(headerId: liveId)
        _ = try await SearchIndex.shared.indexHeaders([makeRecord(liveId), makeRecord(deadId)])

        let engine = SyncEngine()
        // Scoped to this suite's prefix — parallel suites share SearchIndex.shared
        // and an unscoped sweep would remove their fixtures.
        _ = try await engine.pruneFTSOrphans(scopePrefix: "orphanprune-acct:")

        let missing = try await SearchIndex.shared.headerIdsMissingFromFTS([liveId, deadId])
        #expect(!missing.contains(liveId), "live entry must survive the prune")
        #expect(missing.contains(deadId), "dead entry must be pruned")

        try? await SearchIndex.shared.removeMessages(headerIds: [liveId, deadId])
        await cleanupGRDB(accountId: "orphanprune-acct")
    }

    @Test("Gate: oneTimeFTSReconciliation runs once, sets the flag, then no-ops")
    func gateRunsOnce() async throws {
        // UserDefaults isn't Sendable — sending one instance into the actor
        // twice trips the region checker. Fresh same-suite instances share the
        // backing store, so each call gets its own throwaway reference.
        let suiteName = "orphanprune-\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suiteName)!.removePersistentDomain(forName: suiteName) }
        let deadA = "orphanprune-acct:INBOX:op-gate-a"
        let deadB = "orphanprune-acct:INBOX:op-gate-b"
        try? await SearchIndex.shared.removeMessages(headerIds: [deadA, deadB])

        _ = try await SearchIndex.shared.indexHeaders([makeRecord(deadA)])

        let engine = SyncEngine()
        await engine.oneTimeFTSReconciliation(defaults: UserDefaults(suiteName: suiteName)!, scopePrefix: "orphanprune-acct:")
        #expect(UserDefaults(suiteName: suiteName)!.bool(forKey: SyncEngine.ftsReconcileDoneKey) == true)
        let missingA = try await SearchIndex.shared.headerIdsMissingFromFTS([deadA])
        #expect(missingA.contains(deadA), "first run prunes")

        // Second run is gated — a fresh dead entry must survive untouched.
        _ = try await SearchIndex.shared.indexHeaders([makeRecord(deadB)])
        await engine.oneTimeFTSReconciliation(defaults: UserDefaults(suiteName: suiteName)!, scopePrefix: "orphanprune-acct:")
        let missingB = try await SearchIndex.shared.headerIdsMissingFromFTS([deadB])
        #expect(!missingB.contains(deadB), "gated second run must not prune")

        try? await SearchIndex.shared.removeMessages(headerIds: [deadA, deadB])
    }

    @Test("Moved Gmail message: orphan is RE-KEYED to current id (body preserved), not deleted")
    func rekeysMovedGmailOrphan() async throws {
        let accountId = "driftheal-gmail"
        let msgId = "drift-msg-1"
        let oldId = MessageIdentity.headerId(accountId: accountId, folderPath: "INBOX", messageId: msgId)
        let newId = MessageIdentity.headerId(accountId: accountId, folderPath: "Archive", messageId: msgId)
        try? await SearchIndex.shared.removeMessages(headerIds: [oldId, newId])

        // GRDB has the message ONLY at its current (Archive) location — a Gmail archive.
        try await AppDatabase.dbPool.write { db in
            if try Account.fetchOne(db, key: accountId) == nil {
                var account = Account(emailAddress: "drift@example.com", displayName: "T", provider: .gmail)
                account.id = accountId
                try account.insert(db)
            }
            let folderId = MessageIdentity.folderId(accountId: accountId, folderPath: "Archive")
            if try Folder.fetchOne(db, key: folderId) == nil {
                try Folder(name: "Archive", path: "Archive", role: .archive, accountId: accountId).insert(db)
            }
            var header = MessageHeader(
                messageId: msgId, subject: "moved", from: "a@x", fromAddress: "a@x", to: "b@x",
                date: Date(), snippet: "", folderId: folderId, accountId: accountId,
                folderPath: "Archive", isInInbox: false)
            try header.insert(db)
        }

        // FTS still carries the STALE INBOX entry WITH its indexed body — the drift.
        _ = try await SearchIndex.shared.indexHeaders([
            FTSHeaderRecord(headerId: oldId, messageId: msgId, subject: "moved", from: "a@x", to: "b@x",
                dateMs: Int64(Date().timeIntervalSince1970 * 1000),
                folderId: MessageIdentity.folderId(accountId: accountId, folderPath: "INBOX"))
        ])
        _ = try await SearchIndex.shared.updateBodies([(headerId: oldId, body: "secret body phrase")])
        #expect(try await SearchIndex.shared.headerIdsMissingFromFTS([newId]).contains(newId),
                "precondition: current id not yet indexed")

        let engine = SyncEngine()
        _ = try await engine.pruneFTSOrphans(scopePrefix: "\(accountId):")

        // Re-keyed, not deleted: current id is indexed, the body survived, old id is gone.
        let missing = try await SearchIndex.shared.headerIdsMissingFromFTS([oldId, newId])
        #expect(missing.contains(oldId), "stale INBOX id must be re-keyed away")
        #expect(!missing.contains(newId), "moved message must now resolve under its current id")
        let body = try await SearchIndex.shared.bodyText(headerId: newId)
        #expect(body == "secret body phrase", "re-key must preserve the indexed body, not discard it")

        try? await SearchIndex.shared.removeMessages(headerIds: [oldId, newId])
        try? await AppDatabase.dbPool.write { db in _ = try Account.deleteOne(db, key: accountId) }
    }

    @Test("IMAP orphan is NOT re-keyed by UID (would be a different message) — pruned as dead")
    func imapOrphanNotRecoveredByUid() async throws {
        // IMAP messageId is a per-folder UID: the same number in another folder is
        // a DIFFERENT message. Recovery must skip non-Gmail/Graph and let the entry
        // prune (the sync-side UID re-key owns IMAP moves).
        let accountId = "driftheal-imap"
        let uid = "42"
        let oldId = MessageIdentity.headerId(accountId: accountId, folderPath: "INBOX", messageId: uid)
        let collidingId = MessageIdentity.headerId(accountId: accountId, folderPath: "Archive", messageId: uid)
        try? await SearchIndex.shared.removeMessages(headerIds: [oldId, collidingId])

        // GRDB: an IMAP account + a DIFFERENT message carrying the same UID in Archive.
        try await AppDatabase.dbPool.write { db in
            if try Account.fetchOne(db, key: accountId) == nil {
                var account = Account(emailAddress: "imap@example.com", displayName: "T", provider: .imap)
                account.id = accountId
                try account.insert(db)
            }
            let folderId = MessageIdentity.folderId(accountId: accountId, folderPath: "Archive")
            if try Folder.fetchOne(db, key: folderId) == nil {
                try Folder(name: "Archive", path: "Archive", role: .archive, accountId: accountId).insert(db)
            }
            var header = MessageHeader(
                messageId: uid, subject: "a totally different message", from: "a@x", fromAddress: "a@x", to: "b@x",
                date: Date(), snippet: "", folderId: folderId, accountId: accountId,
                folderPath: "Archive", isInInbox: false)
            try header.insert(db)
        }

        // FTS has the stale INBOX orphan (no GRDB INBOX header).
        _ = try await SearchIndex.shared.indexHeaders([
            FTSHeaderRecord(headerId: oldId, messageId: uid, subject: "original", from: "a@x", to: "b@x",
                dateMs: Int64(Date().timeIntervalSince1970 * 1000),
                folderId: MessageIdentity.folderId(accountId: accountId, folderPath: "INBOX"))
        ])

        let engine = SyncEngine()
        _ = try await engine.pruneFTSOrphans(scopePrefix: "\(accountId):")

        // IMAP must NOT be recovered by UID — the orphan is pruned, the unrelated
        // Archive message is never pulled into FTS.
        let missing = try await SearchIndex.shared.headerIdsMissingFromFTS([oldId, collidingId])
        #expect(missing.contains(oldId), "IMAP orphan must be pruned, not re-keyed onto a UID-colliding message")
        #expect(missing.contains(collidingId), "the unrelated Archive message must not be pulled into FTS")

        try? await SearchIndex.shared.removeMessages(headerIds: [oldId, collidingId])
        try? await AppDatabase.dbPool.write { db in _ = try Account.deleteOne(db, key: accountId) }
    }
}
