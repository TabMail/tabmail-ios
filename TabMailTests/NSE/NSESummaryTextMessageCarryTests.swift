/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

/// The summary's text message, end to end through the extension: the open-time column upgrade
/// (`NSEStagingDB.ensureSummaryTextMessageColumn`), the gradual `stageSummary` and the terminal
/// `persistProcessedMessage`, `StagedMessage(row:)`, and the new-header merge. A push must not lose
/// the text message the extension already paid for, or the chat view asks the model again.
@Suite("NSE staging carries the summary text message")
struct NSESummaryTextMessageCarryTests {

    private static func metadata(_ messageId: String) -> NSEMessageMetadata {
        NSEMessageMetadata(
            messageId: messageId, threadId: "t-\(messageId)", rfc822MessageId: "\(messageId)@example.com",
            senderName: "Sender", senderEmail: "sender@example.com",
            to: "recipient@example.com", cc: "", bcc: "", replyTo: nil,
            inReplyTo: nil, references: [], subject: "staged \(messageId)", snippet: "s",
            dateString: "", date: Date(), isRead: false, isFlagged: false, hasAttachments: false,
            isReplied: false, isForwarded: false, providerLabels: ["INBOX"], folderPath: "INBOX"
        )
    }

    private static func decode(_ queue: DatabaseQueue, id: String) throws -> NSEDataBridge.StagedMessage {
        let row = try #require(try queue.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM nse_processed_message WHERE id = ?", arguments: [id])
        })
        return NSEDataBridge.StagedMessage(row: row)
    }

    private static func columns(_ queue: DatabaseQueue) throws -> Set<String> {
        try queue.read { db in
            Set(try Row.fetchAll(db, sql: "PRAGMA table_info(nse_processed_message)").map { $0["name"] as String })
        }
    }

    private static func makeStaging() throws -> (dir: URL, queue: DatabaseQueue) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("nse_staging.sqlite").path
        #expect(AppDatabase.createNSEStagingDB(atPath: path))
        let queue = try DatabaseQueue(path: path)
        // The columns `NSEStagingDB.open` adds before any write; the text message column is
        // left to each test, which checks its upgrade.
        NSEStagingDB.ensureObservedUidValidityColumn(db: queue)
        NSEStagingDB.ensureProviderDateColumn(db: queue)
        return (dir, queue)
    }

    @Test("A fresh staging schema has the column")
    func freshSchemaHasColumn() throws {
        let (dir, queue) = try Self.makeStaging()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(try Self.columns(queue).contains("summaryTextMessage"))
    }

    @Test("Staging writers, decoder and merge carry the text message; a legacy row decodes nil")
    func roundTrip() throws {
        let (dir, queue) = try Self.makeStaging()
        defer { try? FileManager.default.removeItem(at: dir) }
        // The schema an older app shipped, with a row staged under it.
        try queue.write { db in
            try db.execute(sql: "ALTER TABLE nse_processed_message DROP COLUMN summaryTextMessage")
            try db.execute(sql: """
                INSERT INTO nse_processed_message
                    (id, accountId, accountEmail, provider, messageId, rfc822MessageId, folderPath,
                     subject, senderName, senderEmail, snippet, date, summaryBlurb, processedAt,
                     aiCompleted, notified, populated)
                VALUES ('acc1:legacy', 'acc1', 'user@example.com', 'gmail', 'legacy', 'legacy@example.com', 'INBOX',
                        'legacy', 'Sender', 'sender@example.com', '', ?, 'old summary', ?, 1, 0, 1)
                """, arguments: [Date().timeIntervalSince1970, Date().timeIntervalSince1970])
        }
        #expect(!(try Self.columns(queue)).contains("summaryTextMessage"), "precondition: old schema")
        // A legacy row read before the extension upgrades the table decodes nil, never traps.
        #expect(try Self.decode(queue, id: "acc1:legacy").summaryTextMessage == nil)

        NSEStagingDB.ensureSummaryTextMessageColumn(db: queue)
        #expect(try Self.columns(queue).contains("summaryTextMessage"))
        NSEStagingDB.ensureSummaryTextMessageColumn(db: queue) // idempotent
        #expect(try Self.columns(queue).contains("summaryTextMessage"))

        let meta = Self.metadata("push-1")
        NSEStagingDB.stageHeader(db: queue, accountId: "acc1", accountEmail: "user@example.com",
                                 provider: "gmail", message: meta, historyId: "1")
        NSEStagingDB.stageSummary(db: queue, accountId: "acc1", message: meta,
                                  summaryBlurb: "Budget review.", summaryTodos: nil,
                                  reminderDate: nil, reminderTime: nil, reminderContent: nil,
                                  summaryTextMessage: "Can you review the budget?")
        #expect(try Self.decode(queue, id: "acc1:push-1").summaryTextMessage == "Can you review the budget?")

        let persisted = NSEStagingDB.persistProcessedMessage(
            db: queue, accountId: "acc1", accountEmail: "user@example.com", provider: "gmail",
            message: meta, renderedBody: nil, summaryBlurb: "Budget review.", summaryTodos: nil,
            actionTag: "reply", reminderDate: nil, reminderTime: nil, reminderContent: nil,
            summaryTextMessage: "Can you review the budget by Friday?", historyId: "2",
            aiCompleted: true, notified: true)
        #expect(persisted)
        let staged = try Self.decode(queue, id: "acc1:push-1")
        #expect(staged.summaryTextMessage == "Can you review the budget by Friday?")

        let main = try TestDatabase.make()
        try TestDatabase.insertAccount(main, id: "acc1", email: "user@example.com")
        try TestDatabase.insertFolder(main, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")
        var fts: [NSEDataBridge.NSEFTSBodyItem] = []
        let legacy = try Self.decode(queue, id: "acc1:legacy")
        try main.write { db in
            _ = try NSEDataBridge.insertNewHeaderFromStaging(staged, db: db, ftsBatch: &fts)
            _ = try NSEDataBridge.insertNewHeaderFromStaging(legacy, db: db, ftsBatch: &fts)
        }
        let header = try #require(try main.read {
            try MessageHeader.fetchOne($0, key: MessageIdentity.headerId(accountId: "acc1", folderPath: "INBOX", messageId: "push-1"))
        })
        #expect(header.summaryBlurb == "Budget review.")
        #expect(header.summaryTextMessage == "Can you review the budget by Friday?")
        let legacyHeader = try #require(try main.read {
            try MessageHeader.fetchOne($0, key: MessageIdentity.headerId(accountId: "acc1", folderPath: "INBOX", messageId: "legacy"))
        })
        #expect(legacyHeader.summaryBlurb == "old summary")
        #expect(legacyHeader.summaryTextMessage == nil)
    }

    @Test("A terminal write without a text message stages nil (a peer hit or AI off)")
    func terminalWithoutTextMessage() throws {
        let (dir, queue) = try Self.makeStaging()
        defer { try? FileManager.default.removeItem(at: dir) }
        let meta = Self.metadata("peer-1")
        NSEStagingDB.stageHeader(db: queue, accountId: "acc1", accountEmail: "user@example.com",
                                 provider: "gmail", message: meta, historyId: "1")
        NSEStagingDB.stageSummary(db: queue, accountId: "acc1", message: meta,
                                  summaryBlurb: "S.", summaryTodos: nil, reminderDate: nil,
                                  reminderTime: nil, reminderContent: nil, summaryTextMessage: "T.")
        let persisted = NSEStagingDB.persistProcessedMessage(
            db: queue, accountId: "acc1", accountEmail: "user@example.com", provider: "gmail",
            message: meta, renderedBody: nil, summaryBlurb: "Peer summary", summaryTodos: nil,
            actionTag: "none", reminderDate: nil, reminderTime: nil, reminderContent: nil,
            historyId: "2", aiCompleted: true, notified: false)
        #expect(persisted)
        #expect(try Self.decode(queue, id: "acc1:peer-1").summaryTextMessage == nil)
    }
}
