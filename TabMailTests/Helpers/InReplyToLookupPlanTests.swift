/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Testing
@testable import TabMail

/// #1563: the In-Reply-To lookups of the thread view (`ThreadDetection.findRelatedMessages`, run on
/// every email opened) and of the parent-side reply discovery
/// (`ReplyParentResolver.markInsertedParentsOfStoredReplies`, run on every batch of stored headers)
/// must seek `messageHeader_inReplyTo` whatever the planner statistics say. On a mailbox with no
/// In-Reply-To stored (Outlook's sync stores none) the app's ANALYZE records every row under one
/// value. Without the index name the thread view then walked the date index over the whole table,
/// and the reply discovery read every row of each Sent folder.
///
/// The fixture: one account, nine folders, 200 stored emails with no In-Reply-To, most in the
/// inbox, a fifth in Sent and the rest over six other folders.
@Suite("In-Reply-To lookups seek their index under any statistics")
struct InReplyToLookupPlanTests {

    /// Stored emails in the fixture, none with an In-Reply-To.
    static let storedRows = 200
    static let otherFolders = 6

    static func header(_ uid: String, folder: String, inReplyTo: String?, minutesAgo: Int) -> MessageHeader {
        var h = MessageHeader(
            messageId: uid, subject: "s", from: "a", fromAddress: "a@example.com",
            to: "b@example.com", date: Date().addingTimeInterval(-Double(minutesAgo) * 60), snippet: "",
            folderId: "acc1:\(folder)", accountId: "acc1", folderPath: folder, isInInbox: folder == "INBOX"
        )
        h.rfc822MessageId = "\(uid)@example.com"
        h.inReplyTo = inReplyTo
        return h
    }

    /// The opened email of the thread-view test and the parent of the reply-discovery test.
    static let parent = header("s2", folder: "INBOX", inReplyTo: nil, minutesAgo: 2)

    private static func seed(_ db: Database, statistics: InReplyToProbeStatistics) throws {
        var account = Account(emailAddress: "test@example.com", displayName: "Test", provider: .outlook)
        account.id = "acc1"
        try account.insert(db)
        var folders: [(String, FolderRole)] = [("INBOX", .inbox), ("Sent", .sent), ("Trash", .trash)]
        folders += (1...otherFolders).map { ("Folder\($0)", FolderRole.custom) }
        for (path, role) in folders {
            try Folder(name: path, path: path, role: role, accountId: "acc1").insert(db)
        }
        for i in 0..<storedRows {
            let folder = i % 5 == 0 ? "Sent" : i % 5 == 1 ? "Folder\(1 + i % otherFolders)" : "INBOX"
            try header("s\(i)", folder: folder, inReplyTo: nil, minutesAgo: i).insert(db)
        }
        if statistics == .noInReplyToStored { try DBProof.apply(.analyzed, to: db) }
    }

    /// Whether `db` carries `statistics`: no statistics for the In-Reply-To index, or every stored
    /// row counted under one value.
    private static func preconditionProblem(_ db: Database, _ statistics: InReplyToProbeStatistics) throws -> String? {
        let rows = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM messageHeader") ?? 0
        let stat = try db.tableExists("sqlite_stat1")
            ? try String.fetchOne(db, sql: "SELECT stat FROM sqlite_stat1 WHERE idx = 'messageHeader_inReplyTo'")
            : nil
        let holds = switch statistics {
        case .none: stat == nil
        case .noInReplyToStored: stat == "\(rows) \(rows)"
        }
        return holds ? nil : "precondition: \(statistics), index statistics \(stat ?? "none"), \(rows) rows"
    }

    /// The plan's loops and steps. A `BLOOM FILTER` line is a filter in front of a loop, not a loop,
    /// and whether the planner adds one depends on its version, so it is left out.
    private static func plan(_ sql: String, _ db: Database) throws -> [String] {
        try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN \(sql)")
            .map { $0["detail"] as String? ?? "" }
            .filter { !$0.hasPrefix("BLOOM FILTER") }
    }

    /// The index name both lookups carry, removed for the positive controls.
    private static let indexName = " INDEXED BY messageHeader_inReplyTo"

    @Test("The thread view's In-Reply-To lookup seeks messageHeader_inReplyTo, with no statistics and with no In-Reply-To stored",
          arguments: InReplyToProbeStatistics.allCases)
    func threadViewLookupSeeksItsIndex(statistics: InReplyToProbeStatistics) throws {
        // `findRelatedMessages` reads through a pool; every connection records what it runs.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("inreplyto_plan_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("test.sqlite").path
        let tape = BackfillCountTape()
        var config = Configuration()
        config.foreignKeysEnabled = true
        config.prepareDatabase { db in db.trace(options: .statement) { tape.record($0.expandedDescription) } }
        let pool = try DatabasePool(path: path, configuration: config)
        defer {
            try? pool.close()
            try? FileManager.default.removeItem(at: directory)
        }
        try AppDatabase.runMigrations(on: pool)
        try pool.write { try Self.seed($0, statistics: statistics) }

        // The opened email names an ancestor nobody stored, as a reply does, so the lookup asks
        // for two Message-IDs; it has no stored reply, as for most mail: every lookup misses.
        var opened = Self.parent
        opened.referencesJSON = MessageHeader.encodeReferences(["root@example.com"])
        let before = tape.all.count
        let none = try ThreadDetection.findRelatedMessages(for: opened, in: pool)
        #expect(none.isEmpty, "nothing stored is connected to the opened email: \(none.map(\.id))")
        // Only the statements the lookup ran. A one-value list is written `=`, so either form counts.
        let probes = tape.all.dropFirst(before).map { $0.replacingOccurrences(of: "\"", with: "") }
            .filter { $0.contains("SELECT * FROM messageHeader") && ($0.contains("inReplyTo IN") || $0.contains("inReplyTo =")) }
        #expect(probes.count == 1, "the thread view runs one In-Reply-To lookup: \(probes)")
        guard probes.count == 1 else { return }

        // Planned on a fresh connection, which loads the statistics as they are.
        let queue = try DatabaseQueue(path: path)
        defer { try? queue.close() }
        try queue.read { db in
            let problem = try Self.preconditionProblem(db, statistics)
            #expect(problem == nil, "\(problem ?? "")")

            let seek = ["SEARCH messageHeader USING INDEX messageHeader_inReplyTo (inReplyTo=?)", "USE TEMP B-TREE FOR ORDER BY"]
            let planned = try Self.plan(probes[0], db)
            #expect(planned == seek, "\(statistics): the thread view's In-Reply-To lookup does not seek its index: \(planned)")

            if statistics == .noInReplyToStored {
                // Positive control: under these statistics the lookup without its index name walks
                // the date index over the whole table, so the state above is the one the name prevents.
                let control = try Self.plan(probes[0].replacingOccurrences(of: Self.indexName, with: ""), db)
                #expect(control == ["SCAN messageHeader USING INDEX messageHeader_date"],
                        "precondition: without its index name the lookup should scan here: \(control)")
            }
        }

        // The answer is unchanged: a stored reply is found, one in Trash is not.
        let (reply, trashed) = (
            Self.header("r1", folder: "INBOX", inReplyTo: Self.parent.rfc822MessageId, minutesAgo: 1),
            Self.header("r2", folder: "Trash", inReplyTo: Self.parent.rfc822MessageId, minutesAgo: 1)
        )
        try pool.write { db in
            try reply.insert(db)
            try trashed.insert(db)
        }
        let related = try ThreadDetection.findRelatedMessages(for: opened, in: pool).map(\.id)
        #expect(related == [reply.id], "the thread view did not find exactly the stored reply: \(related)")
    }

    @Test("The reply discovery's In-Reply-To lookup seeks messageHeader_inReplyTo, with no statistics and with no In-Reply-To stored",
          arguments: InReplyToProbeStatistics.allCases)
    func replyDiscoveryLookupSeeksItsIndex(statistics: InReplyToProbeStatistics) throws {
        let queue = try TestDatabase.make()
        try queue.write { try Self.seed($0, statistics: statistics) }

        try queue.write { db in
            let problem = try Self.preconditionProblem(db, statistics)
            #expect(problem == nil, "\(problem ?? "")")

            // A stored batch whose emails no stored Sent copy answers, as for most mail.
            let tape = BackfillCountTape()
            db.trace(options: .statement) { event in tape.record(event.expandedDescription) }
            let none = try ReplyParentResolver.markInsertedParentsOfStoredReplies(
                insertedRfc822Ids: ["new@example.com"], accountId: "acc1", db: db)
            db.trace()
            #expect(none.isEmpty, "no stored Sent copy answers the batch: \(none)")
            let probes = tape.all.filter { $0.contains("SELECT DISTINCT r.inReplyTo") }
            #expect(probes.count == 1, "the reply discovery runs one In-Reply-To lookup: \(tape.all)")
            guard probes.count == 1 else { return }

            // Every loop of the join seeks: the stored rows by In-Reply-To, each one's folder by its key.
            let seek = [
                "SEARCH r USING INDEX messageHeader_inReplyTo (inReplyTo=?)",
                "SEARCH f USING INDEX sqlite_autoindex_folder_1 (id=?)",
                "USE TEMP B-TREE FOR DISTINCT",
            ]
            let planned = try Self.plan(probes[0], db)
            #expect(planned == seek, "\(statistics): the reply discovery's In-Reply-To lookup does not seek its index: \(planned)")

            if statistics == .noInReplyToStored {
                // Positive control: under these statistics the lookup without its index name reads
                // every row of each Sent folder through a folder index (which one is the planner's
                // tie-break among the indexes that lead with `folderId`).
                let control = try Self.plan(probes[0].replacingOccurrences(of: Self.indexName, with: ""), db)
                let readsSentFolders = control.count == 3 && control[0] == "SCAN f"
                    && control[1].hasPrefix("SEARCH r USING INDEX messageHeader_folderId")
                    && control[1].hasSuffix("(folderId=?)")
                    && control[2] == "USE TEMP B-TREE FOR DISTINCT"
                #expect(readsSentFolders, "precondition: without its index name the lookup should read the Sent folders here: \(control)")
            }

            // The answer is unchanged: a reply stored in Sent marks its inserted parent replied.
            try Self.header("r1", folder: "Sent", inReplyTo: Self.parent.rfc822MessageId, minutesAgo: 1).insert(db)
            let marked = try ReplyParentResolver.markInsertedParentsOfStoredReplies(
                insertedRfc822Ids: [Self.parent.rfc822MessageId ?? ""], accountId: "acc1", db: db)
            #expect(marked == [Self.parent.id], "the reply discovery did not mark the answered parent: \(marked)")
        }
    }
}
