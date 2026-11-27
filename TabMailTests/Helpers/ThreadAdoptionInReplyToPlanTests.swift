/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Testing
@testable import TabMail

/// #1563: every stored email runs the thread lookup (`ThreadUtils.findAdoptableThreadId`), and
/// its In-Reply-To probe must seek `messageHeader_inReplyTo` whatever the planner statistics
/// say. On a mailbox with no In-Reply-To stored (Outlook's sync stores none) the app's ANALYZE
/// records every row under one value, and the probe without its index name planned
/// `SCAN messageHeader`: the whole table read for every email stored.
@Suite("Thread lookup: the In-Reply-To probe seeks its index under any statistics")
struct ThreadAdoptionInReplyToPlanTests {

    /// Stored emails in the fixture, none with an In-Reply-To.
    static let storedRows = 200

    private static func header(_ uid: String, rfc822: String, inReplyTo: String?, thread: String) -> MessageHeader {
        var h = MessageHeader(
            messageId: uid, subject: "s", from: "a", fromAddress: "a@example.com",
            to: "b@example.com", date: Date(), snippet: "", folderId: "acc1:INBOX",
            accountId: "acc1", folderPath: "INBOX", isInInbox: true
        )
        h.rfc822MessageId = rfc822
        h.inReplyTo = inReplyTo
        h.computedThreadId = thread
        return h
    }

    private static func plan(_ sql: String, _ db: Database) throws -> [String] {
        try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN \(sql)").map { $0["detail"] as String? ?? "" }
    }

    @Test("The In-Reply-To probe seeks messageHeader_inReplyTo, with no statistics and with no In-Reply-To stored",
          arguments: InReplyToProbeStatistics.allCases)
    func probeSeeksItsIndex(statistics: InReplyToProbeStatistics) throws {
        let queue = try TestDatabase.make()
        try TestDatabase.insertAccount(queue, id: "acc1")
        try TestDatabase.insertFolder(queue, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")
        try queue.write { db in
            for i in 0..<Self.storedRows {
                try Self.header("s\(i)", rfc822: "s\(i)@example.com", inReplyTo: nil, thread: "t-\(i)").insert(db)
            }
            if statistics == .noInReplyToStored { try DBProof.apply(.analyzed, to: db) }
        }

        try queue.write { db in
            let rows = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM messageHeader") ?? 0
            let stat = try db.tableExists("sqlite_stat1")
                ? try String.fetchOne(db, sql: "SELECT stat FROM sqlite_stat1 WHERE idx = 'messageHeader_inReplyTo'")
                : nil
            let preconditionHolds = switch statistics {
            case .none: stat == nil
            case .noInReplyToStored: stat == "\(rows) \(rows)"
            }
            #expect(preconditionHolds, "precondition: \(statistics), index statistics \(stat ?? "none"), \(rows) rows")

            // A new email that names an ancestor nobody stored: the Message-ID probe misses,
            // so the In-Reply-To probe runs, as for most new mail.
            let tape = BackfillCountTape()
            db.trace(options: .statement) { event in tape.record(event.expandedDescription) }
            let adopted = try ThreadUtils.findAdoptableThreadId(
                myHeaderId: "acc1:INBOX:new", rfc822MessageId: "new@example.com",
                inReplyTo: nil, references: ["root@example.com"], db: db)
            db.trace()
            #expect(adopted == nil, "nothing stored is connected to the new email")
            let probes = tape.all.filter { $0.contains("WHERE inReplyTo IN") }
            #expect(probes.count == 1, "the lookup runs one In-Reply-To probe: \(tape.all)")
            guard probes.count == 1 else { return }

            let seek = ["SEARCH messageHeader USING INDEX messageHeader_inReplyTo (inReplyTo=?)"]
            let planned = try Self.plan(probes[0], db)
            #expect(planned == seek, "\(statistics): the In-Reply-To probe does not seek its index: \(planned)")

            if statistics == .noInReplyToStored {
                // Positive control: under these statistics the probe without its index name
                // reads the whole table, so the state above is the one the name prevents.
                let unnamed = probes[0].replacingOccurrences(of: " INDEXED BY messageHeader_inReplyTo", with: "")
                let control = try Self.plan(unnamed, db)
                #expect(control == ["SCAN messageHeader"],
                        "precondition: without its index name the probe should scan here: \(control)")
            }

            // The answer is unchanged: a reply stored before the new email is found.
            try Self.header("r1", rfc822: "r1@example.com", inReplyTo: "new@example.com", thread: "T-reply").insert(db)
            let joined = try ThreadUtils.findAdoptableThreadId(
                myHeaderId: "acc1:INBOX:new", rfc822MessageId: "new@example.com",
                inReplyTo: nil, references: ["root@example.com"], db: db)
            #expect(joined == "T-reply", "the probe found no stored reply to the new email")
        }
    }
}

/// The planner statistics `probeSeeksItsIndex` plans under: none (a fresh install), or the app's
/// ANALYZE over a mailbox with no In-Reply-To stored. At file scope because a `@Test` argument
/// cannot name a member of its own suite.
enum InReplyToProbeStatistics: String, CaseIterable, Sendable, CustomTestStringConvertible {
    case none
    case noInReplyToStored

    var testDescription: String { rawValue }
}
