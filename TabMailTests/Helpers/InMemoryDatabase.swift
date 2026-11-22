/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
@testable import TabMail

/// Creates a migrated in-memory GRDB DatabaseQueue for testing.
/// Uses the exact same migration chain as production (AppDatabase.migrate).
enum TestDatabase {

    /// Creates a fresh in-memory database with all migrations applied.
    static func make() throws -> DatabaseQueue {
        var config = Configuration()
        config.foreignKeysEnabled = true
        let db = try DatabaseQueue(configuration: config)
        try AppDatabase.runMigrations(on: db)
        return db
    }

    /// Insert a test account and return it.
    @discardableResult
    static func insertAccount(
        _ db: DatabaseQueue,
        id: String = "acc1",
        email: String = "test@example.com",
        provider: AccountProvider = .gmail
    ) throws -> Account {
        var account = Account(emailAddress: email, displayName: "Test", provider: provider)
        account.id = id
        try db.write { try account.insert($0) }
        return account
    }

    /// Insert a test folder and return it.
    ///
    /// Writes only the columns the live schema has, so a migration test can seed a
    /// folder on a database stopped at an older version (before a later migration
    /// added a `Folder` column). On a fully migrated database every column exists
    /// and this is exactly `folder.insert`.
    @discardableResult
    static func insertFolder(
        _ db: DatabaseQueue,
        name: String = "INBOX",
        path: String = "INBOX",
        role: FolderRole = .inbox,
        accountId: String = "acc1"
    ) throws -> Folder {
        let folder = Folder(name: name, path: path, role: role, accountId: accountId)
        try db.write { conn in
            let existing = Set(try conn.columns(in: Folder.databaseTableName).map(\.name))
            let pairs = try folder.databaseDictionary.filter { existing.contains($0.key) }.sorted { $0.key < $1.key }
            let columns = pairs.map { "\"\($0.key)\"" }.joined(separator: ", ")
            let placeholders = Array(repeating: "?", count: pairs.count).joined(separator: ", ")
            try conn.execute(
                sql: "INSERT INTO \"\(Folder.databaseTableName)\" (\(columns)) VALUES (\(placeholders))",
                arguments: StatementArguments(pairs.map(\.value)))
        }
        return folder
    }

    /// Insert `record` with only the columns the table has at this (older) schema, so a
    /// migration test can seed a database stopped before a later migration added columns.
    static func insertAtOldSchema<R: EncodableRecord & TableRecord>(_ record: R, _ db: Database) throws {
        let table = R.databaseTableName
        let columns = Set(try Row.fetchAll(db, sql: "PRAGMA table_info(\(table))").map { $0["name"] as String })
        let values = try record.databaseDictionary.filter { columns.contains($0.key) }
        let names = values.keys.sorted()
        try db.execute(
            sql: "INSERT INTO \(table) (\(names.map { "\"\($0)\"" }.joined(separator: ", "))) VALUES (\(names.map { _ in "?" }.joined(separator: ", ")))",
            arguments: StatementArguments(names.map { values[$0]! }))
    }

    /// Insert a test message header and return it.
    @discardableResult
    static func insertMessageHeader(
        _ db: DatabaseQueue,
        messageId: String = "100",
        subject: String = "Test Subject",
        from: String = "sender@example.com",
        fromAddress: String = "sender@example.com",
        to: String = "recipient@example.com",
        date: Date = Date(),
        snippet: String = "Test snippet",
        folderId: String = "acc1:INBOX",
        accountId: String = "acc1",
        folderPath: String = "INBOX",
        isInInbox: Bool = true,
        isRead: Bool = false,
        rfc822MessageId: String? = nil,
        actionTag: ActionTag? = nil
    ) throws -> MessageHeader {
        var header = MessageHeader(
            messageId: messageId,
            subject: subject,
            from: from,
            fromAddress: fromAddress,
            to: to,
            date: date,
            snippet: snippet,
            folderId: folderId,
            accountId: accountId,
            folderPath: folderPath,
            isInInbox: isInInbox
        )
        header.isRead = isRead
        header.rfc822MessageId = rfc822MessageId
        header.actionTag = actionTag
        if let tag = actionTag {
            header.tagSortOrder = tag.sortOrder
        }
        try db.write { try header.insert($0) }
        return header
    }

    /// Insert a test message body and return it.
    @discardableResult
    static func insertMessageBody(
        _ db: DatabaseQueue,
        headerId: String,
        htmlContent: String? = "<p>Test body</p>"
    ) throws -> MessageBody {
        let body = MessageBody( contentKey: ContentKey(rawValue: headerId), htmlContent: htmlContent)
        try db.write { try body.insert($0) }
        return body
    }
}

extension ComposeView {
    /// Tests: stores `value` through the one writer over whatever `reply`'s row holds now, the
    /// expectation of a card that just showed that suggestion.
    @discardableResult
    static func writeOverCurrent(_ value: ReplyResult, replyTo reply: MessageHeader, db: any DatabaseWriter) async -> AIWriteOutcome {
        let current = try? await db.read { try MessageHeader.fetchOne($0, key: reply.id)?.suggestion }
        return await writeCachedReplyToDB(value, replacing: current ?? nil, replyTo: reply, db: db)
    }
}
