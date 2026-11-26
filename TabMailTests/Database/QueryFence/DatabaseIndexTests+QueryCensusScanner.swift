/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Testing
@testable import TabMail

/// Pins `QueryCensusScanner` on a fixed source: every site it finds with its key text, the
/// line endings it accepts, and which edits move a key. The registry is keyed by these
/// texts, so a scanner that stopped seeing a site, or keyed it by something an unrelated
/// edit moves, would show here and not only as registry churn.
extension DatabaseIndexTests {

    static let scannerFixtureFile = "Fixture.swift"

    static let scannerFixture = ###"""
    import GRDB

    struct UnreadStore {
        let queue: DatabaseQueue
        init(queue: DatabaseQueue) throws {
            self.queue = queue
            try queue.write { db in try db.execute(sql: "DELETE FROM pendingRender") }
        }

        /// Unread headers of one folder.
        func unread(_ db: Database, folderId: String) throws -> [String] {
            try String.fetchAll(db, sql: "SELECT id FROM messageHeader WHERE folderId = ? AND isRead = 0", arguments: [folderId])
        }

        func prune(ids: [String]) throws {
            let marks = ids.map { _ in "?" }.joined(separator: ",")
            try queue.write { db in
                // Remove the bodies first.
                try db.execute(sql: "DELETE FROM messageBody WHERE id IN (\(marks))", arguments: StatementArguments(ids)); try db.execute(sql: ##"DELETE FROM messageUserLabel WHERE labelName = "#\##(label)" AND note <> '\n'"##)
                try Pruner.run(on: queue)
            }
            try Pruner.run(on: self.queue)
        }

        func flagged(_ db: Database) throws -> [MessageHeader] {
            let request = MessageHeader.filter(Column("isFlagged") == true)
            return try request.fetchAll(db)
        }

        func touch(_ db: Database, folderId: String) throws {
            try db.execute(sql: "UPDATE messageHeader SET isRead = 1 " + "WHERE folderId = ?", arguments: [folderId])
            try db.execute(sql: "UPDATE messageHeader SET isRead = 1 " + "WHERE folderId = ?", arguments: [folderId])
            print("Found \(rows.select(where: folderId)) from cache")
        }

        func evict(_ db: Database, afterEachPage: @Sendable () async -> Void = { await Pruner.pause() }) throws {
            try db.execute(sql: "DELETE FROM messageBody WHERE fetchedAt < 0")
        }

        func inboxPage(_ db: Database, folderId: String, unreadOnly: Bool) throws -> [MessageHeader] {
            let inbox = MessageHeader.filter(Column("isInInbox") == true)
            let inFolder = inbox.filter(Column("folderId") == folderId)
            let size = Pager.pageSize(for: folderId)
            var page = inFolder.order(Column("date").desc)
            if unreadOnly { page = page.filter(Column("isRead") == false) }
            return try Pager.rows(db, page.limit(size), cap: size)
        }

        static func pendingRequest(accountId: String) -> QueryInterfaceRequest<MessageHeader> {
            if accountId.isEmpty {
                return MessageHeader.none()
            }
            return MessageHeader.filter(Column("accountId") == accountId && Column("bodyComplete") == false)
        }

        func pendingCount(_ db: Database, request: QueryInterfaceRequest<MessageHeader>) throws -> Int {
            try request.fetchCount(db)
        }
    }
    """###

    /// A site without its file and last line, for comparison.
    struct ScannedSite: Equatable, CustomStringConvertible {
        let line: Int
        let context: String
        let kind: String
        let ordinal: Int
        let text: String
        let sql: String

        init(_ line: Int, _ context: String, _ kind: String, _ ordinal: Int, _ text: String, sql: String = "") {
            self.line = line
            self.context = context
            self.kind = kind
            self.ordinal = ordinal
            self.text = text
            self.sql = sql
        }

        init(_ site: QueryCensusScanner.Site) {
            self.init(site.line, site.context, site.kind, site.ordinal, site.text, sql: site.sql)
        }

        var description: String { "\(line) \(context) \(kind)#\(ordinal) \(text) | \(sql)" }
    }

    static func scanned(_ source: String) -> [QueryCensusScanner.Site] {
        QueryCensusScanner.scan(file: scannerFixtureFile, source: source)
    }

    @Test("The scanner finds every SQL literal and query call of a source, two on one line included, keyed by their own text")
    func scannerFindsEverySite() {
        let found = Self.scanned(Self.scannerFixture).map { ScannedSite($0) }
        let selectHeaders = #"SELECT id FROM messageHeader WHERE folderId = ? AND isRead = 0"#
        let touchCall = #"db.execute(sql: "UPDATE messageHeader SET isRead = 1 " + "WHERE folderId = ?", arguments: [folderId])"#
        let expected = [
            // A type right after an import line, an `init` right after a property line, and a
            // one-line closure of `write`: each names its declaration.
            ScannedSite(7, "UnreadStore.init", "call", 0, #"db.execute(sql: "DELETE FROM pendingRender")"#),
            ScannedSite(7, "UnreadStore.init", "sql", 0, "DELETE FROM pendingRender", sql: "DELETE FROM pendingRender"),
            // A literal and the call that runs it, with the handle typed as a parameter.
            ScannedSite(12, "UnreadStore.unread", "call", 0, #"String.fetchAll(db, sql: ""# + selectHeaders + #"", arguments: [folderId])"#),
            ScannedSite(12, "UnreadStore.unread", "sql", 0, selectHeaders, sql: selectHeaders),
            // Two calls on one line, in a closure of `write`; an interpolation keeps its source in
            // the key and is `\(…)` in the statement; a raw `##` string keeps its text as written.
            ScannedSite(19, "UnreadStore.prune", "call", 0,
                        #"db.execute(sql: "DELETE FROM messageBody WHERE id IN (\(marks))", arguments: StatementArguments(ids))"#),
            ScannedSite(19, "UnreadStore.prune", "call", 0,
                        ##"db.execute(sql: "DELETE FROM messageUserLabel WHERE labelName = "#\(label)" AND note <> '\n'")"##),
            ScannedSite(19, "UnreadStore.prune", "sql", 0, #"DELETE FROM messageBody WHERE id IN (\(marks))"#,
                        sql: #"DELETE FROM messageBody WHERE id IN (\(…))"#),
            ScannedSite(19, "UnreadStore.prune", "sql", 0, ##"DELETE FROM messageUserLabel WHERE labelName = "#\(label)" AND note <> '\n'"##,
                        sql: ##"DELETE FROM messageUserLabel WHERE labelName = "#\(…)" AND note <> '\n'"##),
            // A `DatabaseQueue` property passed to a helper, bare and as a member.
            ScannedSite(20, "UnreadStore.prune", "call", 0, "Pruner.run(on: queue)"),
            ScannedSite(22, "UnreadStore.prune", "call", 0, "Pruner.run(on: self.queue)"),
            // A request built on another line carries its initializer.
            ScannedSite(27, "UnreadStore.flagged", "call", 0,
                        #"request.fetchAll(db) ⟨request = MessageHeader.filter(Column("isFlagged") == true)⟩"#),
            // Concatenated SQL: the call holds the whole statement; the first fragment is the
            // literal that reads as SQL, its statement unnormalized. Identical sites count up.
            ScannedSite(31, "UnreadStore.touch", "call", 0, touchCall),
            ScannedSite(31, "UnreadStore.touch", "sql", 0, "UPDATE messageHeader SET isRead = 1", sql: "UPDATE messageHeader SET isRead = 1 "),
            ScannedSite(32, "UnreadStore.touch", "call", 1, touchCall),
            ScannedSite(32, "UnreadStore.touch", "sql", 1, "UPDATE messageHeader SET isRead = 1", sql: "UPDATE messageHeader SET isRead = 1 "),
            // A parameter's default closure opens no declaration: the body after the parameter
            // list still names its function.
            ScannedSite(37, "UnreadStore.evict", "call", 0, #"db.execute(sql: "DELETE FROM messageBody WHERE fetchedAt < 0")"#),
            ScannedSite(37, "UnreadStore.evict", "sql", 0, "DELETE FROM messageBody WHERE fetchedAt < 0",
                        sql: "DELETE FROM messageBody WHERE fetchedAt < 0"),
            // A request passed as an argument carries its binding, the reassignment made under a
            // condition, and the request bindings it was built from (two hops); the page size is a
            // value, not a request, so it is not carried.
            ScannedSite(46, "UnreadStore.inboxPage", "call", 0,
                        #"Pager.rows(db, page.limit(size), cap: size) ⟨page = inFolder.order(Column("date").desc)⟩"#
                            + #" ⟨page = page.filter(Column("isRead") == false)⟩ ⟨inFolder = inbox.filter(Column("folderId") == folderId)⟩"#
                            + #" ⟨inbox = MessageHeader.filter(Column("isInInbox") == true)⟩"#),
            // A function returning a request is a site of its own, its whole text the key.
            ScannedSite(49, "UnreadStore.pendingRequest", "request", 0,
                        #"func pendingRequest(accountId: String) -> QueryInterfaceRequest<MessageHeader> { if accountId.isEmpty { return MessageHeader.none() }"#
                            + #" return MessageHeader.filter(Column("accountId") == accountId && Column("bodyComplete") == false) }"#),
            // A receiver that is a parameter does not borrow another function's binding.
            ScannedSite(57, "UnreadStore.pendingCount", "call", 0, "request.fetchCount(db)"),
        ]
        #expect(found == expected)
    }

    @Test("A CRLF or CR source scans exactly as the LF one")
    func scannerReadsEveryLineEnding() {
        let lf = Self.scanned(Self.scannerFixture).map { ScannedSite($0) }
        #expect(lf.count == 20)
        for ending in ["\r\n", "\r"] {
            let other = Self.scanned(Self.scannerFixture.replacingOccurrences(of: "\n", with: ending)).map { ScannedSite($0) }
            #expect(other == lf, "line ending \(ending.debugDescription)")
        }
    }

    @Test("An edit above a site or of its declaration keeps its key; an edit of what it queries changes exactly its key")
    func scannerKeysFollowTheQuery() {
        let base = Self.scanned(Self.scannerFixture)
        let baseKeys = Set(base.map(\.key))

        let moved = Self.scannerFixture
            .replacingOccurrences(of: "import GRDB\n", with: "import Foundation\nimport GRDB\n\n")
            .replacingOccurrences(of: "folderId: String) throws -> [String] {", with: "folderId: String, limit: Int) throws -> [String] {")
        let movedSites = Self.scanned(moved)
        #expect(moved != Self.scannerFixture)
        #expect(movedSites.map(\.key) == base.map(\.key))
        #expect(movedSites.map(\.line) == base.map { $0.line + 2 })

        let edits: [(name: String, from: String, to: String, changed: Int)] = [
            ("the predicate of a literal", "isRead = 0\"", "isRead = 1\"", 2),
            ("the source of an interpolation", #"IN (\(marks))"#, #"IN (\(placeholders))"#, 2),
            // Only `flagged`'s call: `pendingCount`'s parameter `request` is not that binding.
            ("the request a call runs", #"Column("isFlagged") == true"#, #"Column("isFlagged") == false"#, 1),
            ("the second fragment of a concatenation",
             "\"WHERE folderId = ?\", arguments: [folderId])\n        print(", "\"WHERE accountId = ?\", arguments: [folderId])\n        print(", 1),
            ("a request passed as an argument", #"inFolder.order(Column("date").desc)"#, #"inFolder.order(Column("date").asc)"#, 1),
            ("a request two bindings back", #"Column("isInInbox") == true"#, #"Column("isInInbox") == false"#, 1),
            ("a reassignment under a condition", #"page.filter(Column("isRead") == false)"#, #"page.filter(Column("isRead") == true)"#, 1),
            ("the body of a request helper", #"Column("bodyComplete") == false"#, #"Column("bodyComplete") == true"#, 1),
            ("a branch of a request helper", "return MessageHeader.none()", "return MessageHeader.all()", 1),
            ("a value a call reads", "Pager.pageSize(for: folderId)", "Pager.defaultPageSize", 0),
        ]
        for edit in edits {
            let edited = Self.scannerFixture.replacingOccurrences(of: edit.from, with: edit.to)
            let keys = Set(Self.scanned(edited).map(\.key))
            let gone = baseKeys.subtracting(keys)
            let added = keys.subtracting(baseKeys)
            #expect(edited != Self.scannerFixture, "\(edit.name): the edit did not apply")
            #expect(gone.count == edit.changed && added.count == edit.changed, "\(edit.name): gone \(gone), added \(added)")
        }
    }

    @Test("A literal whose interpolated code reads as SQL is not SQL")
    func scannerReadsOnlyTheLiteralText() {
        let sites = Self.scanned(Self.scannerFixture)
        #expect(!sites.contains { $0.text.contains("from cache") })
    }
}
