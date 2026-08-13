/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

/// The drain used to resolve each queued member's identity columns with its own
/// `WHERE (messageId = ? OR rfc822MessageId = ?) AND accountId = ?` statement.
/// With no `sqlite_stat1` row for a full index on `messageHeader` — the regime a
/// device holds until the background `ANALYZE` runs, ADR-IOS-029 — SQLite serves
/// that predicate by WALKING the account, so a 200-member bulk archive spent
/// twelve seconds inside one read transaction. It is now two set-based
/// statements (`AccountManager.headerIdentitiesForQueuedMembers`).
///
/// **The invariant these tests pin is behavioural, not the mechanism**: every
/// member of the operation resolves to the SAME identity columns the per-member
/// statement resolved, associated with THAT member and no other. The batching is
/// where such a rewrite goes wrong — one `IN` list, one result set, and nothing
/// in the SQL says which row answered which member. A test that only asserted
/// "N rows came back" is green on an implementation that hands every member the
/// first row it found, which would poison `recordRecentlyCompleted` with another
/// message's ids.
///
/// `resolvesEveryMemberAsTheOldPerMemberStatementDid` is a differential test
/// against the previous predicate, run on fixtures where each member matches
/// exactly one row so the old statement's answer is itself well-defined. The
/// ambiguous case — several sibling rows for one member — has its own test,
/// because there the old `fetchOne` returned whichever row the plan reached
/// first and therefore had no stable answer to be equivalent to.
@Suite("A drain resolves every queued member's identity, and only its own", .serialized)
struct QueuedMemberIdentityLookupTests {

    // MARK: - Harness

    @discardableResult
    private func insertHeader(
        accountId: String, folderPath: String, uid: String, rfc822: String?,
        isInInbox: Bool = true, pool: DatabasePool
    ) throws -> String {
        var header = MessageHeader(
            messageId: uid, subject: "queued-member fixture \(uid)", from: "Sender",
            fromAddress: "sender@example.com", to: "recipient@example.com",
            date: Date(timeIntervalSince1970: 1_700_000_000), snippet: "fixture",
            folderId: MessageIdentity.folderId(accountId: accountId, folderPath: folderPath),
            accountId: accountId, folderPath: folderPath, isInInbox: isInInbox
        )
        header.rfc822MessageId = rfc822
        header.headerComplete = true
        let toInsert = header
        try pool.write { db in try toInsert.insert(db) }
        return header.id
    }

    /// The statement this fix replaced, kept verbatim as the differential oracle.
    private func legacyLookup(
        _ memberIds: [String], accountId: String, pool: DatabasePool
    ) throws -> [String: (rfc822: String?, messageId: String?)] {
        try pool.read { db in
            var out: [String: (rfc822: String?, messageId: String?)] = [:]
            for msgId in memberIds {
                let normalized = EmailFilter.normalizeMessageId(msgId)
                let header = try MessageHeader
                    .filter(
                        (Column("messageId") == msgId || Column("rfc822MessageId") == normalized) &&
                        Column("accountId") == accountId
                    )
                    .fetchOne(db)
                out[msgId] = (header?.rfc822MessageId, header?.messageId)
            }
            return out
        }
    }

    /// `static` so the plan probes can run inside GRDB's `@Sendable` async
    /// read/write closures without capturing a local function.
    private static func explainPlan(_ sql: String, db: Database) throws -> String {
        try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN " + sql,
                         arguments: StatementArguments(
                             ["acc"] + (0..<200).map { "rfc\($0)@example.com" }))
            .map { $0["detail"] as String }
            .joined(separator: " | ")
    }

    private func newLookup(
        _ memberIds: [String], accountId: String, pool: DatabasePool
    ) throws -> [String: AccountManager.QueuedMemberIdentity] {
        try pool.read { db in
            try AccountManager.headerIdentitiesForQueuedMembers(
                memberIds, accountId: accountId, db: db)
        }
    }

    // MARK: - 1. Equivalence with the statement it replaced

    @Test("Every member resolves to what the old per-member statement resolved")
    func resolvesEveryMemberAsTheOldPerMemberStatementDid() async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        let accountId = "acc-queued-identity-1"
        // `messageHeader.accountId` is a foreign key and the fixture enables
        // foreign keys, so the account row has to exist before any header does.
        _ = try FolderEpochTestFixture.makeAccount(id: accountId, provider: .imap, pool: pool)

        // Three members addressable by UID, three only by their RFC 822 id, and
        // one that matches nothing. Each matches at most one row, so the old
        // statement has a well-defined answer to be compared against.
        for uid in ["101", "102", "103"] {
            try insertHeader(accountId: accountId, folderPath: "INBOX", uid: uid,
                             rfc822: "uid-\(uid)@example.com", pool: pool)
        }
        for (i, rfc) in ["alpha@example.com", "beta@example.com", "gamma@example.com"].enumerated() {
            try insertHeader(accountId: accountId, folderPath: "Archive",
                             uid: "90\(i)", rfc822: rfc, isInInbox: false, pool: pool)
        }

        let members = [
            "101", "102", "103",
            "alpha@example.com",
            "<beta@example.com>",       // angle-bracketed: must normalize before matching
            "gamma@example.com",
            "no-such-member@example.com",
        ]

        let legacy = try legacyLookup(members, accountId: accountId, pool: pool)
        let fresh = try newLookup(members, accountId: accountId, pool: pool)

        for member in members {
            guard let expected = legacy[member] else {
                Issue.record("the oracle produced no entry for \(member) — fixture is broken")
                continue
            }
            let actual = fresh[member]
            #expect(actual?.rfc822MessageId == expected.rfc822,
                    "member \(member): rfc822 diverged from the replaced statement")
            #expect(actual?.messageId == expected.messageId,
                    "member \(member): messageId diverged from the replaced statement")
        }

        // Spelled out, so the test still says what "correct" is if the oracle is
        // ever deleted: each member got ITS OWN row, not a neighbour's.
        #expect(fresh["101"]?.rfc822MessageId == "uid-101@example.com")
        #expect(fresh["102"]?.rfc822MessageId == "uid-102@example.com")
        #expect(fresh["103"]?.rfc822MessageId == "uid-103@example.com")
        #expect(fresh["alpha@example.com"]?.messageId == "900")
        #expect(fresh["<beta@example.com>"]?.messageId == "901")
        #expect(fresh["gamma@example.com"]?.messageId == "902")
        #expect(fresh["no-such-member@example.com"] == nil,
                "an unresolvable member must be ABSENT, so the call sites emit (nil, nil)")
    }

    // MARK: - 2. Account scoping

    @Test("A row in another account is never borrowed, however it is addressed")
    func neverCrossesTheAccountBoundary() async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }

        _ = try FolderEpochTestFixture.makeAccount(id: "acc-scope-other", provider: .imap, pool: pool)
        _ = try FolderEpochTestFixture.makeAccount(id: "acc-scope-mine", provider: .imap, pool: pool)

        // Same UID and same RFC id in a DIFFERENT account — the shape a shared
        // mailbox or a re-added account produces.
        try insertHeader(accountId: "acc-scope-other", folderPath: "INBOX", uid: "500",
                         rfc822: "collide@example.com", pool: pool)

        let fresh = try newLookup(["500", "collide@example.com"],
                                  accountId: "acc-scope-mine", pool: pool)
        #expect(fresh.isEmpty, "the other account's row must not resolve: \(fresh)")

        // And the decoy resolves normally for its own account, so the emptiness
        // above is scoping rather than a broken fixture.
        let owned = try newLookup(["500"], accountId: "acc-scope-other", pool: pool)
        #expect(owned["500"]?.rfc822MessageId == "collide@example.com")
    }

    // MARK: - 3. Sibling rows

    @Test("Sibling copies resolve to one deterministic, inbox-preferred row")
    func siblingPickIsDeterministicAndInboxPreferred() async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        let accountId = "acc-queued-identity-siblings"
        _ = try FolderEpochTestFixture.makeAccount(id: accountId, provider: .imap, pool: pool)

        // `messageId` is a per-folder UID, so one value legitimately names rows
        // in several folders of the same account.
        try insertHeader(accountId: accountId, folderPath: "Archive", uid: "700",
                         rfc822: "archive-copy@example.com", isInInbox: false, pool: pool)
        try insertHeader(accountId: accountId, folderPath: "INBOX", uid: "700",
                         rfc822: "inbox-copy@example.com", isInInbox: true, pool: pool)

        let first = try newLookup(["700"], accountId: accountId, pool: pool)
        #expect(first["700"]?.rfc822MessageId == "inbox-copy@example.com",
                "the inbox sibling must win the tie-break")

        // Stable: the old `fetchOne` over an OR could answer differently as soon
        // as statistics changed the plan. This must not.
        for _ in 0..<5 {
            let again = try newLookup(["700"], accountId: accountId, pool: pool)
            #expect(again["700"]?.rfc822MessageId == first["700"]?.rfc822MessageId)
        }
    }

    // MARK: - 4. Beyond one chunk

    @Test("An operation larger than one SQL chunk still resolves every member")
    func resolvesEveryMemberBeyondOneChunk() async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        let accountId = "acc-queued-identity-chunk"
        _ = try FolderEpochTestFixture.makeAccount(id: accountId, provider: .imap, pool: pool)

        // One more than a whole chunk, so a loop that dropped its tail — or
        // resolved only the first chunk — leaves a detectable hole.
        let count = SyncConfig.sqlChunkSize + 7
        let uids = (0..<count).map { "u\($0)" }
        try await pool.write { db in
            for uid in uids {
                var header = MessageHeader(
                    messageId: uid, subject: "chunk fixture \(uid)", from: "Sender",
                    fromAddress: "sender@example.com", to: "recipient@example.com",
                    date: Date(timeIntervalSince1970: 1_700_000_000), snippet: "fixture",
                    folderId: MessageIdentity.folderId(accountId: accountId, folderPath: "INBOX"),
                    accountId: accountId, folderPath: "INBOX", isInInbox: true)
                header.rfc822MessageId = "rfc-\(uid)@example.com"
                try header.insert(db)
            }
        }

        let fresh = try newLookup(uids, accountId: accountId, pool: pool)
        #expect(fresh.count == count)
        for uid in uids {
            #expect(fresh[uid]?.rfc822MessageId == "rfc-\(uid)@example.com",
                    "member \(uid) was lost or mis-associated across the chunk boundary")
        }
    }

    // MARK: - 5. The plan the fix exists to obtain

    @Test("The RFC 822 arm seeks its own index in every statistics regime")
    func rfc822ArmSeeksItsIndexInEveryStatisticsRegime() async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }

        // Production's own SQL, not a copy — the whole reason the builder is
        // exposed (`ChatStore.findByStableIdSQL` precedent).
        let hinted = AccountManager.queuedMemberIdentitySQL(matching: "rfc822MessageId", count: 200)
        let unhinted = hinted.replacingOccurrences(
            of: " INDEXED BY messageHeader_rfc822MessageId", with: "")
        #expect(unhinted != hinted, "the hint must be present in production's SQL")

        // Regime A: the database as the migration chain leaves it.
        try await pool.read { db in
            let hintedPlan = try Self.explainPlan(hinted, db: db)
            let unhintedPlan = try Self.explainPlan(unhinted, db: db)
            #expect(hintedPlan.contains("messageHeader_rfc822MessageId"),
                    "hinted arm stopped seeking its index: \(hintedPlan)")
            // Two-sided: without the hint the planner does NOT choose that index,
            // which is the defect this fix exists to prevent. If this side ever
            // passes, the assertion above has stopped proving anything.
            #expect(!unhintedPlan.contains("messageHeader_rfc822MessageId"),
                    "the unhinted form now seeks rfc822 by itself — re-derive whether the hint is still load-bearing: \(unhintedPlan)")
        }

        // Regime B: no statistics at all — what a device runs until
        // `SyncEngineMaintenance.runRefreshPlannerStatisticsIfStale` fires, and
        // the only regime `fts.db` and a fresh install ever see.
        try await pool.write { db in
            let hasStats = try Bool.fetchOne(
                db, sql: "SELECT COUNT(*) > 0 FROM sqlite_master WHERE name = 'sqlite_stat1'") ?? false
            if hasStats {
                try db.execute(sql: "DELETE FROM sqlite_stat1")
                // Reloads the (now empty) statistics into the schema cache;
                // without it SQLite keeps planning from what it already read.
                try db.execute(sql: "ANALYZE sqlite_master")
            }
            let hintedPlan = try Self.explainPlan(hinted, db: db)
            let unhintedPlan = try Self.explainPlan(unhinted, db: db)
            #expect(hintedPlan.contains("messageHeader_rfc822MessageId"),
                    "hinted arm stopped seeking its index with no statistics: \(hintedPlan)")
            #expect(!unhintedPlan.contains("messageHeader_rfc822MessageId"),
                    "the unhinted form now seeks rfc822 with no statistics — the hint's premise changed: \(unhintedPlan)")
        }
    }
}
