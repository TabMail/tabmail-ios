/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import GRDB
import Testing
@testable import TabMail

@Suite("v88 body-indexing terminal state")
struct BodyIndexingFailureMigrationTests {
    @Test("v88 adds a nullable reason and the exact partial queue index")
    func migrationAddsTerminalReasonAndQueueIndex() throws {
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        let database = try DatabaseQueue(configuration: configuration)
        var migrator = DatabaseMigrator()
        AppDatabase.registerAllMigrations(on: &migrator)

        try migrator.migrate(database, upTo: "v87_retireDirectAIPending")
        let before = try database.read { db in
            try db.columns(in: "messageHeader").map(\.name)
        }
        #expect(!before.contains("bodyIndexingFailureReason"))

        try migrator.migrate(database)
        let after = try database.read { db in
            (
                columns: try db.columns(in: "messageHeader"),
                indexSQL: try String.fetchOne(
                    db,
                    sql: "SELECT sql FROM sqlite_master WHERE type = 'index' AND name = ?",
                    arguments: ["messageHeader_bodyIndexingQueue"]
                )
            )
        }
        let reason = try #require(after.columns.first(where: {
            $0.name == "bodyIndexingFailureReason"
        }))
        #expect(reason.isNotNull == false)
        let indexSQL = try #require(after.indexSQL)
        #expect(indexSQL.contains("bodyIndexingFailureReason IS NULL"))
        #expect(indexSQL.contains("headerComplete = 1"))
    }

    @Test("New message rows default to no terminal failure")
    func newRowsStartRetryable() throws {
        let database = try TestDatabase.make()
        try TestDatabase.insertAccount(database)
        try TestDatabase.insertFolder(database)
        let header = try TestDatabase.insertMessageHeader(database)
        let stored = try database.read { db in
            try MessageHeader.fetchOne(db, key: header.id)
        }
        #expect(stored?.bodyIndexingFailureReason == nil)
    }
}
