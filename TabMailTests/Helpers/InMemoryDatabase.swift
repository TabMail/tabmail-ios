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
    @discardableResult
    static func insertFolder(
        _ db: DatabaseQueue,
        name: String = "INBOX",
        path: String = "INBOX",
        role: FolderRole = .inbox,
        accountId: String = "acc1"
    ) throws -> Folder {
        let folder = Folder(name: name, path: path, role: role, accountId: accountId)
        try db.write { try folder.insert($0) }
        return folder
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
        actionTag: ActionTag? = nil,
        actionTagSetAt: Date? = nil
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
            // Defaults to nil (not `Date()`) when the caller doesn't specify one —
            // preserves every pre-existing call site's behavior under the sweep's
            // fail-safe NULL-is-eligible rule (SyncConfig.actionTagTTLSeconds).
            // Tests exercising TTL semantics pass this explicitly.
            header.actionTagSetAt = actionTagSetAt
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
        let body = MessageBody(headerId: headerId, htmlContent: htmlContent)
        try db.write { try body.insert($0) }
        return body
    }
}
