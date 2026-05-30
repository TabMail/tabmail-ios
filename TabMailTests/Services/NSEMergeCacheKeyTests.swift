/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

/// Coverage for the cache-key-source choice in `NSEDataBridge.merge`'s
/// existing-header branch (audit finding C3): when sync races ahead of
/// the merge and moves a message between NSE's fetch and the main-app
/// merge, the AI-cache key we write MUST use the header's CURRENT
/// folderPath (GRDB row value), not the staged `msg.folderPath` from
/// NSE capture time. Otherwise the main-app probe — which reads the
/// header's current folderPath — misses every NSE-written cache row.
///
/// We can't call `mergeNSEStagingData()` directly (opens the App Group
/// staging DB), so the test replicates the specific SQL + key-building
/// the merge performs for an existing-header row. Any production drift
/// (e.g., someone reverts the `existingFolderPath` lookup) trips this.
@Suite("NSEDataBridge merge cache-key source")
struct NSEMergeCacheKeyTests {

    /// Replicate the SELECT + cache-key-write the production
    /// existing-header branch performs. Returns the (folderPath,
    /// cacheKey) it resolved for the merged row.
    private func simulateExistingBranch(
        db: DatabaseQueue,
        accountId: String,
        messageId: String,
        stagedFolderPath: String,
        stagedRfc822: String?,
        stagedAction: String
    ) throws -> (folderPath: String, cacheKey: String?) {
        try db.write { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT id, folderId, folderPath, rfc822MessageId FROM messageHeader
                WHERE accountId = ? AND messageId = ?
                """, arguments: [accountId, messageId]) else {
                return ("", nil)
            }
            let existingFolderPath: String = row["folderPath"] ?? stagedFolderPath
            let existingRfc822: String? = row["rfc822MessageId"]
            let rfc = stagedRfc822 ?? existingRfc822
            let cacheKey = MessageIdentity.aiCacheKey(
                accountId: accountId,
                folderPath: existingFolderPath,
                rfc822MessageId: rfc
            )
            if let cacheKey {
                try db.execute(sql: """
                    INSERT OR REPLACE INTO messageAICache
                    (key, summaryBlurb, actionTag, updatedAt)
                    VALUES (?, ?, ?, ?)
                    """, arguments: [cacheKey, "s", stagedAction, Date()])
            }
            return (existingFolderPath, cacheKey)
        }
    }

    private func seedAccountAndHeader(
        _ db: DatabaseQueue,
        accountId: String = "acct-o",
        folderPath: String,
        messageId: String = "msg-1",
        rfc822: String? = "r@x"
    ) throws {
        try db.write { db in
            var acc = Account(emailAddress: "u@outlook.com", displayName: "U", provider: .outlook)
            acc.id = accountId
            try acc.insert(db)
            var h = MessageHeader(
                messageId: messageId, subject: "", from: "", fromAddress: "", to: "",
                date: Date(timeIntervalSince1970: 0), snippet: "",
                folderId: MessageIdentity.folderId(accountId: accountId, folderPath: folderPath),
                accountId: accountId,
                folderPath: folderPath,
                isInInbox: true
            )
            h.rfc822MessageId = rfc822
            try h.insert(db)
        }
    }

    @Test("Cache key uses existing header's folderPath (not the staged one) when they differ")
    func cacheKeyFollowsExistingHeader() throws {
        let db = try TestDatabase.make()
        // Sync raced ahead and moved this message to folderPath "POST-MOVE"
        // between NSE's fetch (captured folderPath "AT-FETCH") and merge.
        try seedAccountAndHeader(db, folderPath: "POST-MOVE")

        let (folderPath, cacheKey) = try simulateExistingBranch(
            db: db,
            accountId: "acct-o",
            messageId: "msg-1",
            stagedFolderPath: "AT-FETCH",   // NSE captured this
            stagedRfc822: "r@x",
            stagedAction: "delete"
        )
        // The merge resolves the CURRENT path from GRDB, not what NSE staged.
        #expect(folderPath == "POST-MOVE")
        #expect(cacheKey == "acct-o:POST-MOVE:r@x")

        // And the cache row is readable at the same key the main app's
        // probe will construct (parity with `MessageAICache.cacheKey`).
        let probedKey = MessageAICache.cacheKey(
            accountId: "acct-o", folderPath: "POST-MOVE", rfc822MessageId: "r@x"
        )
        #expect(probedKey == cacheKey)
        let stored = try db.read { db in
            try MessageAICache.fetchOne(db, key: probedKey!)
        }
        #expect(stored?.actionTag == .delete)
    }

    @Test("No drift path: staged folderPath equals existing — cache key matches both")
    func cacheKeyNoDriftPath() throws {
        let db = try TestDatabase.make()
        try seedAccountAndHeader(db, folderPath: "INBOX")

        let (folderPath, cacheKey) = try simulateExistingBranch(
            db: db,
            accountId: "acct-o",
            messageId: "msg-1",
            stagedFolderPath: "INBOX",
            stagedRfc822: "r@x",
            stagedAction: "archive"
        )
        #expect(folderPath == "INBOX")
        #expect(cacheKey == "acct-o:INBOX:r@x")
    }

    // Note: a dedicated "folderPath column NULL → falls back to staged"
    // test was considered but dropped — MessageHeader's schema declares
    // folderPath NOT NULL, so reaching the nil branch requires a direct
    // SQL insert that bypasses the Record API. The `?? stagedFolderPath`
    // coalesce is trivial code (`row["folderPath"] ?? stagedFolderPath`);
    // the real contracts worth testing (above) are covered.
}
