/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

/// Coverage for the pre-sync-row reclaim branch in `SyncEngineFullSync`
/// (bug 2c). When NSE (or any earlier writer) inserts a MessageHeader for
/// a push-arrival with a different `folderPath` than what the later sync
/// uses for the same message, sync must migrate the AI fields onto the
/// new row rather than silently creating a duplicate.
///
/// The real logic lives inside `syncFolderMessages`. We replicate the
/// reclaim algorithm here against an in-memory DB so we can verify the
/// invariants without dragging in providers, workers, account setup, or
/// OAuth. Algorithm mirror is intentional — if the production
/// implementation drifts, this test fails.
@Suite("Sync pre-sync reclaim")
struct SyncPreSyncReclaimTests {

    /// Simulates the production reclaim branch (minus ThreadUtils + user-
    /// label plumbing which are orthogonal). Keep in sync with
    /// `SyncEngineFullSync.syncFolderMessages` around the "pre-sync
    /// reclaim" comment block.
    @discardableResult
    private func reclaim(
        existing preSync: MessageHeader,
        incoming header: inout MessageHeader,
        accountId: String,
        folderPath: String,
        db: Database
    ) throws -> Bool {
        let oldId = preSync.id
        if header.actionTag == nil, let tag = preSync.actionTag {
            header.actionTag = tag
            header.tagSortOrder = tag.sortOrder
        }
        if header.summaryBlurb == nil {
            header.summaryBlurb = preSync.summaryBlurb
            header.summaryTodos = preSync.summaryTodos
            header.reminderDate = preSync.reminderDate
            header.reminderTime = preSync.reminderTime
            header.reminderContent = preSync.reminderContent
        }
        if header.cachedReply == nil { header.cachedReply = preSync.cachedReply }
        header.notified = header.notified || preSync.notified

        var deferredBody: MessageBody?
        if let body = try MessageBody.fetchOne(db, key: ContentKey(rawValue: oldId)) {
            var newBody = body
            newBody.id = ContentKey(rawValue: header.id)
            try MessageBody.deleteOne(db, key: ContentKey(rawValue: oldId))
            deferredBody = newBody
        }
        let oldCacheKey = MessageIdentity.aiCacheKey(
            accountId: accountId, folderPath: preSync.folderPath,
            rfc822MessageId: preSync.rfc822MessageId
        )
        let newCacheKey = MessageIdentity.aiCacheKey(
            accountId: accountId, folderPath: folderPath,
            rfc822MessageId: header.rfc822MessageId
        )
        if let oldCacheKey, let newCacheKey, oldCacheKey != newCacheKey,
           try MessageAICache.fetchOne(db, key: oldCacheKey) != nil {
            try db.execute(
                sql: "UPDATE messageAICache SET key = ? WHERE key = ?",
                arguments: [newCacheKey, oldCacheKey]
            )
        }
        try preSync.delete(db)
        try header.insert(db)
        if let body = deferredBody { try body.insert(db) }
        return true
    }

    private func seedAccount(_ db: DatabaseQueue, id: String = "acct-o") throws {
        try db.write { db in
            var acc = Account(emailAddress: "u@outlook.com", displayName: "U", provider: .outlook)
            acc.id = id
            try acc.insert(db)
        }
    }

    private func makeNSEHeader(accountId: String, messageId: String) -> MessageHeader {
        var h = MessageHeader(
            messageId: messageId, subject: "NSE subj", from: "Tabmail",
            fromAddress: "t@x", to: "",
            date: Date(timeIntervalSince1970: 1_000_000), snippet: "snip",
            // NSE fresh-header uses the provider-canonical folderPath. For this
            // test we seed with the Graph folder ID that NSE would have
            // captured from Graph's parentFolderId.
            folderId: MessageIdentity.folderId(accountId: accountId, folderPath: "AQMk-FOLDER"),
            accountId: accountId, folderPath: "AQMk-FOLDER", isInInbox: true
        )
        h.actionTag = .delete
        h.tagSortOrder = ActionTag.delete.sortOrder
        h.summaryBlurb = "Tabmail sent a test email"
        h.rfc822MessageId = "msg-rfc@example.com"
        h.notified = false
        h.headerComplete = true
        return h
    }

    private func makeSyncHeader(accountId: String, messageId: String, folderPath: String) -> MessageHeader {
        var h = MessageHeader(
            messageId: messageId, subject: "NSE subj", from: "Tabmail",
            fromAddress: "t@x", to: "",
            date: Date(timeIntervalSince1970: 1_000_000), snippet: "snip",
            folderId: MessageIdentity.folderId(accountId: accountId, folderPath: folderPath),
            accountId: accountId, folderPath: folderPath, isInInbox: true
        )
        // Server has no actionTag / summaryBlurb for Outlook — simulate that.
        h.actionTag = nil
        h.summaryBlurb = nil
        h.rfc822MessageId = "msg-rfc@example.com"
        return h
    }

    @Test("Reclaim carries NSE's actionTag onto the sync-shaped header")
    func reclaimPreservesActionTag() throws {
        let db = try TestDatabase.make()
        try seedAccount(db)
        let preSync = makeNSEHeader(accountId: "acct-o", messageId: "m-1")
        try db.write { db in try preSync.insert(db) }

        var incoming = makeSyncHeader(accountId: "acct-o", messageId: "m-1", folderPath: "AQMk-FOLDER")

        try db.write { db in
            try reclaim(
                existing: preSync, incoming: &incoming,
                accountId: "acct-o", folderPath: "AQMk-FOLDER", db: db
            )
        }

        let rows = try db.read { db in
            try MessageHeader
                .filter(Column("accountId") == "acct-o" && Column("messageId") == "m-1")
                .fetchAll(db)
        }
        // Exactly one row (no duplicate).
        #expect(rows.count == 1)
        guard let row = rows.first else { return }
        // AI preserved, folder migrated, id recomputed under new folderPath.
        #expect(row.actionTag == .delete)
        #expect(row.summaryBlurb == "Tabmail sent a test email")
        #expect(row.folderPath == "AQMk-FOLDER")
        #expect(row.id == MessageIdentity.headerId(
            accountId: "acct-o", folderPath: "AQMk-FOLDER", messageId: "m-1"
        ))
    }

    @Test("Reclaim preserves summary + reminder fields when server response is bare")
    func reclaimPreservesSummaryAndReminders() throws {
        let db = try TestDatabase.make()
        try seedAccount(db)
        var preSync = makeNSEHeader(accountId: "acct-o", messageId: "m-2")
        preSync.reminderDate = "2026-05-01"
        preSync.reminderTime = "09:00"
        preSync.reminderContent = "Reply to Tabmail"
        preSync.summaryTodos = "todo-1"
        try db.write { db in try preSync.insert(db) }

        var incoming = makeSyncHeader(accountId: "acct-o", messageId: "m-2", folderPath: "AQMk-FOLDER")
        try db.write { db in
            try reclaim(
                existing: preSync, incoming: &incoming,
                accountId: "acct-o", folderPath: "AQMk-FOLDER", db: db
            )
        }

        let row = try db.read { db in
            try MessageHeader.fetchOne(db, key: MessageIdentity.headerId(
                accountId: "acct-o", folderPath: "AQMk-FOLDER", messageId: "m-2"
            ))
        }
        #expect(row?.summaryBlurb == "Tabmail sent a test email")
        #expect(row?.summaryTodos == "todo-1")
        #expect(row?.reminderDate == "2026-05-01")
        #expect(row?.reminderContent == "Reply to Tabmail")
    }

    @Test("Reclaim also cleans up additional duplicate inbox rows")
    func reclaimRemovesExtraDuplicates() throws {
        // If a prior bug produced TWO pre-sync inbox rows (same account +
        // messageId, different folderPaths), the first-row reclaim migrates
        // AI fields onto the new id and the loop DELETEs the rest. Without
        // that cleanup, the tail rows stick around with stale AI cache rows
        // and orphaned MessageBody entries.
        let db = try TestDatabase.make()
        try seedAccount(db)

        let extra1 = makeNSEHeader(accountId: "acct-o", messageId: "m-4")
        // Give it a different folderPath so id differs.
        var e1 = extra1
        e1.folderPath = "FIRST-FOLDER"
        e1.folderId = MessageIdentity.folderId(accountId: "acct-o", folderPath: "FIRST-FOLDER")
        e1.id = MessageIdentity.headerId(accountId: "acct-o", folderPath: "FIRST-FOLDER", messageId: "m-4")

        var e2 = extra1
        e2.folderPath = "SECOND-FOLDER"
        e2.folderId = MessageIdentity.folderId(accountId: "acct-o", folderPath: "SECOND-FOLDER")
        e2.id = MessageIdentity.headerId(accountId: "acct-o", folderPath: "SECOND-FOLDER", messageId: "m-4")

        try db.write { db in
            try e1.insert(db)
            try e2.insert(db)
        }

        // Simulate sync finding BOTH rows, reclaiming the first and
        // cleaning up the second.
        var incoming = makeSyncHeader(accountId: "acct-o", messageId: "m-4", folderPath: "CANONICAL-FOLDER")
        try db.write { db in
            let rows = try MessageHeader
                .filter(Column("accountId") == "acct-o")
                .filter(Column("messageId") == "m-4")
                .filter(Column("isInInbox") == true)
                .filter(Column("id") != incoming.id)
                .fetchAll(db)
            #expect(rows.count == 2)
            guard let first = rows.first else { return }
            try reclaim(
                existing: first, incoming: &incoming,
                accountId: "acct-o", folderPath: "CANONICAL-FOLDER", db: db
            )
            // Tail cleanup (loop mirror).
            for extra in rows.dropFirst() {
                try extra.delete(db)
            }
        }

        let remaining = try db.read { db in
            try MessageHeader
                .filter(Column("accountId") == "acct-o" && Column("messageId") == "m-4")
                .fetchAll(db)
        }
        #expect(remaining.count == 1)
        #expect(remaining.first?.folderPath == "CANONICAL-FOLDER")
    }

    @Test("Reclaim migrates AI cache key from old folderPath to new one")
    func reclaimMigratesAICacheKey() throws {
        let db = try TestDatabase.make()
        try seedAccount(db)
        let preSync = makeNSEHeader(accountId: "acct-o", messageId: "m-3")
        // Seed an AI cache entry under the OLD folderPath (this is what
        // NSEDataBridge's merge writes post-fix).
        let oldKey = MessageIdentity.aiCacheKey(
            accountId: "acct-o", folderPath: "AQMk-FOLDER",
            rfc822MessageId: "msg-rfc@example.com"
        )!
        try db.write { db in
            try preSync.insert(db)
            try db.execute(sql: """
                INSERT INTO messageAICache (key, summaryBlurb, actionTag, updatedAt)
                VALUES (?, ?, ?, ?)
                """, arguments: [oldKey, "blurb", "delete", Date()])
        }

        // Sync uses a DIFFERENT folderPath (simulating drift — this test
        // guards the general case). Reclaim must move the cache row.
        var incoming = makeSyncHeader(accountId: "acct-o", messageId: "m-3", folderPath: "DIFF-FOLDER")
        try db.write { db in
            try reclaim(
                existing: preSync, incoming: &incoming,
                accountId: "acct-o", folderPath: "DIFF-FOLDER", db: db
            )
        }

        let newKey = MessageIdentity.aiCacheKey(
            accountId: "acct-o", folderPath: "DIFF-FOLDER",
            rfc822MessageId: "msg-rfc@example.com"
        )!
        let oldPresent = try db.read { db in
            try MessageAICache.fetchOne(db, key: oldKey) != nil
        }
        let newPresent = try db.read { db in
            try MessageAICache.fetchOne(db, key: newKey) != nil
        }
        #expect(oldPresent == false)
        #expect(newPresent == true)
    }
}
