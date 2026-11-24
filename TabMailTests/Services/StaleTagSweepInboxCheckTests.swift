/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Testing
@testable import TabMail

/// The per-candidate inbox check of the stale action-tag sweep (#1404): `SyncEngine.inboxCopySQL`, its plan, and
/// what the sweep does when the check cannot answer. The fixture is `StaleTagSweepFixture`.
@Suite("Stale action-tag sweep: the per-candidate inbox check", .serialized, .processGlobalState)
struct StaleTagSweepInboxCheckTests {
    private struct CheckFailed: Error {}

    /// The check runs only for a tag past the TTL with a Message-ID. When it fails, that tag stays (the next full
    /// sync's sweep checks it again), and the sweep goes on with the other rows.
    @Test("A failed inbox check keeps that tag, and the sweep goes on")
    func failedCheckKeepsTheTag() async throws {
        let fixture = try StaleTagSweepFixture()
        defer { fixture.restore() }
        let folders = try fixture.makeFolders()
        let expired = Date().addingTimeInterval(-(SyncConfig.actionTagTTLSeconds + 3600))
        let young = Date().addingTimeInterval(-3600)
        let checked = "<checked@example.com>"
        let (candidate, noMessageId, youngCopy) = try await fixture.pool.write { db in
            let candidate = try fixture.insert(db, folder: folders.swept[0], messageId: "candidate",
                                               rfc: checked, tag: .archive, setAt: expired)
            let noMessageId = try fixture.insert(db, folder: folders.swept[0], messageId: "no-message-id",
                                                 rfc: nil, tag: .delete, setAt: expired)
            let youngCopy = try fixture.insert(db, folder: folders.swept[1], messageId: "young",
                                               rfc: "<young@example.com>", tag: .reply, setAt: young)
            return (candidate, noMessageId, youngCopy)
        }
        let calls = StaleTagSweepFixture.SQLTape()

        await SyncEngine().sweepStaleActionTags(
            account: fixture.account, provider: MockEmailProvider(),
            inboxCopyExists: { rfc822MessageId, accountId in
                calls.record("\(rfc822MessageId) \(accountId)")
                throw CheckFailed()
            })

        let (storedCandidate, storedNoId, storedYoung) = try await fixture.pool.read { db in
            (try MessageHeader.fetchOne(db, key: candidate.id),
             try MessageHeader.fetchOne(db, key: noMessageId.id),
             try MessageHeader.fetchOne(db, key: youngCopy.id))
        }
        let made = calls.all
        #expect(made == ["\(checked) \(fixture.accountId)"], "the check ran for other rows than the one candidate: \(made)")
        #expect(storedCandidate?.actionTag == .archive, "a failed check cleared the tag")
        #expect(storedCandidate?.actionTagSetAt != nil)
        #expect(storedNoId?.actionTag == nil, "the sweep stopped at the failed check")
        #expect(storedYoung?.actionTag == .reply)
    }

    /// The production check reads once per candidate: a tag past the TTL with a Message-ID. An inbox copy keeps the
    /// tag; no inbox copy (or one only in another account's inbox) clears it.
    @Test("The production check reads once per candidate and keeps only a tag whose message is in this account's inbox")
    func oneReadPerCandidate() async throws {
        let fixture = try StaleTagSweepFixture()
        defer { fixture.restore() }
        let folders = try fixture.makeFolders()
        let expired = Date().addingTimeInterval(-(SyncConfig.actionTagTTLSeconds + 3600))
        let young = Date().addingTimeInterval(-3600)
        let rows = try await fixture.pool.write { db -> [String: MessageHeader] in
            try fixture.insert(db, folder: folders.inbox, messageId: "inbox-0",
                               rfc: StaleTagSweepFixture.inboxMessageId(0), tag: nil, setAt: nil)
            try fixture.insert(db, folder: folders.otherInbox, messageId: "other-0",
                               rfc: StaleTagSweepFixture.otherInboxMessageId(0), tag: nil, setAt: nil,
                               accountId: StaleTagSweepFixture.otherAccountId)
            return [
                "inInbox": try fixture.insert(db, folder: folders.swept[0], messageId: "in-inbox",
                                              rfc: StaleTagSweepFixture.inboxMessageId(0), tag: .reply, setAt: expired),
                "archivedOnly": try fixture.insert(db, folder: folders.swept[0], messageId: "archived-only",
                                                   rfc: "<archived-only@example.com>", tag: .archive, setAt: expired),
                "otherAccountsInbox": try fixture.insert(db, folder: folders.swept[1], messageId: "other-accounts-inbox",
                                                         rfc: StaleTagSweepFixture.otherInboxMessageId(0), tag: .delete,
                                                         setAt: nil),
                "young": try fixture.insert(db, folder: folders.swept[1], messageId: "young",
                                            rfc: StaleTagSweepFixture.inboxMessageId(0), tag: .reply, setAt: young),
            ]
        }
        fixture.tape.clear()

        await SyncEngine().sweepStaleActionTags(account: fixture.account, provider: MockEmailProvider())

        let inboxReads = fixture.inboxReads()
        #expect(inboxReads.count == 3, "expected one check per candidate (3), got \(inboxReads.count): \(inboxReads)")
        #expect(inboxReads.allSatisfy { $0.hasPrefix("SELECT 1 FROM messageHeader") },
                "an inbox read other than the check: \(inboxReads)")
        let stored = try await fixture.pool.read { db in
            try rows.mapValues { try MessageHeader.fetchOne(db, key: $0.id)?.actionTag }
        }
        #expect(stored["inInbox"] == .some(.reply), "the copy of a message in this account's inbox lost its tag")
        #expect(stored["archivedOnly"] == .some(nil), "a copy with no inbox copy kept its tag")
        #expect(stored["otherAccountsInbox"] == .some(nil), "another account's inbox kept this account's tag")
        #expect(stored["young"] == .some(.reply))
    }

    /// The check seeks a Message-ID index on the Message-ID, never an index on `isInInbox` or `accountId` (every
    /// inbox row of every account, or every row of the account), with no planner statistics and after the app's
    /// ANALYZE. Planned on a fresh connection, which loads the statistics as they are.
    @Test("The check seeks a Message-ID index, with and without planner statistics",
          arguments: DBProof.Statistics.allCases)
    func checkSeeksTheMessageIdIndex(statistics: DBProof.Statistics) async throws {
        let fixture = try StaleTagSweepFixture()
        defer { fixture.restore() }
        let folders = try fixture.makeFolders()
        let expired = Date().addingTimeInterval(-(SyncConfig.actionTagTTLSeconds + 3600))
        try await fixture.pool.write { db in
            for j in 0..<300 {
                try fixture.insert(db, folder: folders.inbox, messageId: "inbox-\(j)",
                                   rfc: StaleTagSweepFixture.inboxMessageId(j), tag: nil, setAt: nil)
                try fixture.insert(db, folder: folders.swept[j % folders.swept.count], messageId: "copy-\(j)",
                                   rfc: StaleTagSweepFixture.inboxMessageId(j), tag: .archive, setAt: expired)
            }
            for k in 0..<StaleTagSweepFixture.otherInboxRows {
                try fixture.insert(db, folder: folders.otherInbox, messageId: "other-\(k)",
                                   rfc: StaleTagSweepFixture.otherInboxMessageId(k), tag: nil, setAt: nil,
                                   accountId: StaleTagSweepFixture.otherAccountId)
            }
            try DBProof.apply(statistics, to: db)
        }
        let path = fixture.directory.appendingPathComponent("test.sqlite").path
        let queue = try DatabaseQueue(path: path)
        defer { try? queue.close() }
        let (statRows, plan, found, missing) = try await queue.read { db in
            let statRows = try db.tableExists("sqlite_stat1")
                ? try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sqlite_stat1") ?? 0 : 0
            let plan = try Row.fetchAll(
                db, sql: "EXPLAIN QUERY PLAN \(SyncEngine.inboxCopySQL)",
                arguments: [StaleTagSweepFixture.inboxMessageId(7), fixture.accountId]
            ).map { $0["detail"] as String? ?? "" }
            let found = try SyncEngine.inboxCopyExists(
                db, rfc822MessageId: StaleTagSweepFixture.inboxMessageId(7), accountId: fixture.accountId)
            let missing = try SyncEngine.inboxCopyExists(
                db, rfc822MessageId: StaleTagSweepFixture.otherInboxMessageId(0), accountId: fixture.accountId)
            return (statRows, plan, found, missing)
        }
        #expect((statRows > 0) == (statistics == .analyzed), "precondition: \(statistics.label), \(statRows) sqlite_stat1 rows")
        #expect(found, "the check missed an inbox copy")
        #expect(!missing, "the check found another account's inbox copy")
        #expect(plan.count == 1, "\(statistics.label): \(plan)")
        let seek = plan.first ?? ""
        #expect(seek.hasPrefix("SEARCH messageHeader USING INDEX messageHeader_rfc822MessageId")
                    && seek.hasSuffix("(rfc822MessageId=?)"),
                "\(statistics.label): the check does not seek a Message-ID index on the Message-ID: \(plan)")
    }
}
