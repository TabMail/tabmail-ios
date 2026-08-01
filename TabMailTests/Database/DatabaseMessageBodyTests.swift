/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

@Suite("Database MessageBody")
struct DatabaseMessageBodyTests {

    @Test("MessageBody INSERT OR IGNORE: first wins")
    func insertOrIgnoreFirstWins() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        try TestDatabase.insertMessageHeader(db, messageId: "1")

        let headerId = "acc1:INBOX:1"
        try TestDatabase.insertMessageBody(db, headerId: headerId, htmlContent: "<p>First</p>")
        try db.write { db in
            let body = MessageBody( contentKey: ContentKey(rawValue: headerId), htmlContent: "<p>Second</p>")
            try body.insert(db, onConflict: .ignore)
        }
        let fetched = try db.read { try MessageBody.fetchOne($0, key: headerId) }
        #expect(fetched?.htmlContent == "<p>First</p>")
    }

    @Test("MessageBody cascades on header deletion")
    func cascadesOnHeaderDeletion() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        try TestDatabase.insertMessageHeader(db, messageId: "1")
        try TestDatabase.insertMessageBody(db, headerId: "acc1:INBOX:1")

        try db.write { _ = try MessageHeader.deleteOne($0, key: "acc1:INBOX:1") }

        let body = try db.read { try MessageBody.fetchOne($0, key: "acc1:INBOX:1") }
        #expect(body == nil)
    }

    @Test("MessageBody fetchedAt is set")
    func fetchedAtSet() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        try TestDatabase.insertMessageHeader(db, messageId: "1")

        let before = Date()
        let body = try TestDatabase.insertMessageBody(db, headerId: "acc1:INBOX:1")
        let after = Date()

        #expect(body.fetchedAt >= before)
        #expect(body.fetchedAt <= after)
    }

    @Test("MessageBody with nil htmlContent")
    func nilHtmlContent() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        try TestDatabase.insertMessageHeader(db, messageId: "1")
        _ = try TestDatabase.insertMessageBody(db, headerId: "acc1:INBOX:1", htmlContent: nil)

        let fetched = try db.read { try MessageBody.fetchOne($0, key: "acc1:INBOX:1") }
        #expect(fetched?.htmlContent == nil)
    }

    @Test("MessageBody with attachments JSON")
    func withAttachmentsJSON() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        try TestDatabase.insertMessageHeader(db, messageId: "1")

        try db.write { db in
            var body = MessageBody( contentKey: ContentKey(rawValue: "acc1:INBOX:1"), htmlContent: "<p>test</p>")
            body.attachmentsJSON = "[{\"filename\":\"doc.pdf\",\"contentType\":\"application/pdf\",\"section\":\"1\",\"size\":100}]"
            try body.insert(db)
        }

        let fetched = try db.read { try MessageBody.fetchOne($0, key: "acc1:INBOX:1") }
        #expect(fetched?.attachmentsJSON?.contains("doc.pdf") == true)
        #expect(fetched?.attachments.count == 1)
    }
}
