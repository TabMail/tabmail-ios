/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

@Suite("ComposeView.writeCachedReplyToDB")
struct ComposeSuggestionPersistTests {

    @Test("Updates cachedReply on messageHeader for the given id")
    func updatesCachedReplyColumn() async throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let header = try TestDatabase.insertMessageHeader(db, messageId: "1")

        await ComposeView.writeCachedReplyToDB("edited reply", headerId: header.id, db: db)

        let fetched = try await db.read { try MessageHeader.fetchOne($0, key: header.id) }
        #expect(fetched?.cachedReply == "edited reply")
    }

    @Test("No-op when headerId does not match any row")
    func noOpOnMissingHeader() async throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let header = try TestDatabase.insertMessageHeader(db, messageId: "1")

        await ComposeView.writeCachedReplyToDB("ghost", headerId: "nonexistent", db: db)

        let fetched = try await db.read { try MessageHeader.fetchOne($0, key: header.id) }
        #expect(fetched?.cachedReply == nil)
    }

    @Test("Overwrites a prior cachedReply value")
    func overwritesPriorValue() async throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let header = try TestDatabase.insertMessageHeader(db, messageId: "1")

        await ComposeView.writeCachedReplyToDB("first", headerId: header.id, db: db)
        await ComposeView.writeCachedReplyToDB("second", headerId: header.id, db: db)

        let fetched = try await db.read { try MessageHeader.fetchOne($0, key: header.id) }
        #expect(fetched?.cachedReply == "second")
    }

    @Test("Touches only cachedReply — other fields unchanged")
    func leavesOtherFieldsAlone() async throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let header = try TestDatabase.insertMessageHeader(
            db,
            messageId: "1",
            subject: "Untouched subject",
            from: "alice@example.com",
            snippet: "Untouched snippet"
        )

        await ComposeView.writeCachedReplyToDB("new reply", headerId: header.id, db: db)

        let fetched = try await db.read { try MessageHeader.fetchOne($0, key: header.id) }
        #expect(fetched?.subject == "Untouched subject")
        #expect(fetched?.from == "alice@example.com")
        #expect(fetched?.snippet == "Untouched snippet")
        #expect(fetched?.cachedReply == "new reply")
    }
}
