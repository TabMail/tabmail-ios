/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

@Suite("MessageSnapshot")
struct MessageSnapshotTests {

    @Test("MessageSnapshot preserves the header's E1 epoch after the Folder advances to E2")
    func preservesCapturedObservationEpoch() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, provider: .imap)
        var folder = try TestDatabase.insertFolder(db)
        var header = try TestDatabase.insertMessageHeader(db, messageId: "21")
        header.observedUidValidity = 101
        try db.write { try header.update($0) }
        let snapshot = MessageSnapshot(from: header)
        folder.lastKnownUidValidity = 202
        try db.write { try folder.update($0) }

        #expect(snapshot.observedUidValidity == 101)
    }

    @Test("Init from MessageHeader copies all fields")
    func initFromHeader() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let header = try TestDatabase.insertMessageHeader(
            db,
            messageId: "1",
            subject: "Important",
            from: "Alice <alice@example.com>",
            fromAddress: "alice@example.com",
            to: "bob@example.com",
            snippet: "Hello there",
            isRead: false,
            rfc822MessageId: "<msg@example.com>",
            actionTag: .archive
        )

        let snapshot = MessageSnapshot(from: header)
        #expect(snapshot.id == header.id)
        #expect(snapshot.accountId == header.accountId)
        #expect(snapshot.subject == "Important")
        #expect(snapshot.from == "Alice <alice@example.com>")
        #expect(snapshot.fromAddress == "alice@example.com")
        #expect(snapshot.snippet == "Hello there")
        #expect(snapshot.isRead == false)
        #expect(snapshot.actionTag == .archive)
        #expect(snapshot.rfc822MessageId == "<msg@example.com>")
    }

    @Test("Snapshot supports mutable optimistic UI fields")
    func mutableFields() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let header = try TestDatabase.insertMessageHeader(db, messageId: "1", isRead: false)
        var snapshot = MessageSnapshot(from: header)

        #expect(snapshot.isRead == false)
        snapshot.isRead = true
        #expect(snapshot.isRead == true)

        snapshot.isFlagged = true
        #expect(snapshot.isFlagged == true)

        snapshot.actionTag = .delete
        #expect(snapshot.actionTag == .delete)
    }

    @Test("Snapshot Identifiable with id")
    func identifiable() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let header = try TestDatabase.insertMessageHeader(db, messageId: "1")
        let snapshot = MessageSnapshot(from: header)
        #expect(!snapshot.id.isEmpty)
    }

    @Test("Snapshot Hashable")
    func hashable() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let header = try TestDatabase.insertMessageHeader(db, messageId: "1")
        let snapshot = MessageSnapshot(from: header)

        var set = Set<MessageSnapshot>()
        set.insert(snapshot)
        set.insert(snapshot) // duplicate
        #expect(set.count == 1)
    }

    @Test("hasReplyReady is true when cachedReply is non-empty")
    func hasReplyReady() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        var header = try TestDatabase.insertMessageHeader(db, messageId: "1")
        header.cachedReply = "Draft reply"
        try db.write { try header.update($0) }
        let fetched = try db.read { try MessageHeader.fetchOne($0, key: header.id)! }
        let snapshot = MessageSnapshot(from: fetched)
        #expect(snapshot.hasReplyReady == true)
        #expect(snapshot.isReplyProcessed == true)
    }

    @Test("hasReplyReady is false when cachedReply is nil")
    func noReplyReady() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let header = try TestDatabase.insertMessageHeader(db, messageId: "1")
        let snapshot = MessageSnapshot(from: header)
        #expect(snapshot.hasReplyReady == false)
        #expect(snapshot.isReplyProcessed == false)
    }

    @Test("isReplyProcessed is true but hasReplyReady false for empty sentinel")
    func emptyReplySentinel() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        var header = try TestDatabase.insertMessageHeader(db, messageId: "1")
        header.cachedReply = "" // empty sentinel = processed but filtered
        try db.write { try header.update($0) }
        let fetched = try db.read { try MessageHeader.fetchOne($0, key: header.id)! }
        let snapshot = MessageSnapshot(from: fetched)
        #expect(snapshot.hasReplyReady == false) // empty string = not ready
        #expect(snapshot.isReplyProcessed == true) // but was processed
    }
}
