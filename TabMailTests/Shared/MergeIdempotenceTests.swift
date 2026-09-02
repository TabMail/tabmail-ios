/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

/// End-to-end idempotence tests for the NSE staging → main-app merge path.
/// Verifies that the SQL-level contract (used by `NSEDataBridge.persistRendered-
/// BodyFromStaging`) is safe to re-run: running the same write twice produces
/// the same final state, with no duplicate bodies, no overwritten snippets,
/// and bodyComplete flipping only when appropriate.
///
/// These are pure SQL tests — they exercise the exact queries the helper
/// emits, run against an in-memory main-app DB. Any drift between the helper
/// and these queries will show up as test-file drift.
@Suite("NSE merge idempotence (SQL contract)")
struct MergeIdempotenceTests {

    @Test("Re-running body insert + bodyComplete update is a no-op")
    func reRunIsNoOp() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1", email: "u@ex.com")
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")
        try TestDatabase.insertMessageHeader(db, messageId: "m1", folderId: "acc1:INBOX", accountId: "acc1")

        let headerId: String = try db.read {
            try String.fetchOne($0, sql: "SELECT id FROM messageHeader WHERE messageId = 'm1'")!
        }

        // Run the merge sequence twice with identical inputs.
        for _ in 0..<2 {
            try db.write { db in
                // 1. MessageBody upsert-ignore.
                try db.execute(sql: """
                    INSERT OR IGNORE INTO messageBody (id, htmlContent, attachmentsJSON, icsText, fetchedAt)
                    VALUES (?, ?, ?, ?, ?)
                    """, arguments: [headerId, "<p>body</p>", nil, nil, Date()])

                // 2. UPDATE messageHeader — deterministic.
                try db.execute(sql: """
                    UPDATE messageHeader SET
                        bodyComplete = ?,
                        snippet = CASE WHEN ? = '' THEN snippet ELSE ? END
                    WHERE id = ?
                    """, arguments: [1, "body snippet", "body snippet", headerId])
            }
        }

        // Assertions: stable final state.
        let bodyCount: Int = try db.read {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM messageBody WHERE id = ?", arguments: [headerId])!
        }
        #expect(bodyCount == 1, "Duplicate insert must be ignored")

        let row = try db.read {
            try Row.fetchOne($0, sql: "SELECT bodyComplete, snippet FROM messageHeader WHERE id = ?", arguments: [headerId])
        }
        #expect(row?["bodyComplete"] == 1)
        #expect(row?["snippet"] == "body snippet")
    }

    @Test("First writer wins: sync's body is NOT overwritten by later NSE merge")
    func firstWriterWins() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1", email: "u@ex.com")
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")
        try TestDatabase.insertMessageHeader(db, messageId: "m1", folderId: "acc1:INBOX", accountId: "acc1")

        let headerId: String = try db.read {
            try String.fetchOne($0, sql: "SELECT id FROM messageHeader WHERE messageId = 'm1'")!
        }

        // Sync writes body first.
        try db.write { db in
            try db.execute(sql: """
                INSERT OR IGNORE INTO messageBody (id, htmlContent, fetchedAt)
                VALUES (?, ?, ?)
                """, arguments: [headerId, "<p>SYNC-BODY</p>", Date()])
        }

        // NSE merge arrives later, tries to INSERT OR IGNORE — should not overwrite.
        try db.write { db in
            try db.execute(sql: """
                INSERT OR IGNORE INTO messageBody (id, htmlContent, fetchedAt)
                VALUES (?, ?, ?)
                """, arguments: [headerId, "<p>NSE-BODY</p>", Date()])
        }

        let html: String? = try db.read {
            try String.fetchOne($0, sql: "SELECT htmlContent FROM messageBody WHERE id = ?", arguments: [headerId])
        }
        #expect(html == "<p>SYNC-BODY</p>", "INSERT OR IGNORE must preserve the first writer")
    }

    @Test("bodyComplete stays 0 when hasUnresolvedCIDs; no MessageBody persisted")
    func unresolvedCIDsPreventComplete() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1", email: "u@ex.com")
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")
        try TestDatabase.insertMessageHeader(db, messageId: "m1", folderId: "acc1:INBOX", accountId: "acc1")

        let headerId: String = try db.read {
            try String.fetchOne($0, sql: "SELECT id FROM messageHeader WHERE messageId = 'm1'")!
        }

        // Simulate merge with hasUnresolvedCIDs=true:
        //  - NO MessageBody insert (otherwise sync's re-render with onConflict:
        //    .ignore would fail to overwrite and leave broken cid: refs forever).
        //  - bodyComplete stays 0 so ActiveBodyQueue re-fetches.
        //  - headerComplete=1 mirrors what NSE merge's create-fresh-header branch sets.
        try db.write { db in
            try db.execute(sql: "UPDATE messageHeader SET bodyComplete = 0, headerComplete = 1 WHERE id = ?", arguments: [headerId])
            // NO `INSERT INTO messageBody` here — that's the key behavior.
        }

        // Verify no MessageBody row exists.
        let bodyCount: Int = try db.read {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM messageBody WHERE id = ?", arguments: [headerId])!
        }
        #expect(bodyCount == 0, "Unresolved-CID body must NOT be persisted — sync re-render must win")

        // Verify ActiveBodyQueue filter includes this message for re-fetch.
        let enqueued: Int = try db.read {
            // The production query itself, via `ActiveBodyQueue.admissionItems`. A hand-copied
            // predicate stops BEING the admission predicate the moment production gains a
            // clause — it just gained `AND bodyMetadataOversized = 0`, and a never-drop claim
            // measured against a stale copy proves nothing about the queue that actually runs.
            try ActiveBodyQueue.admissionItems($0).filter { $0.headerId == headerId }.count
        }
        #expect(enqueued == 1, "CID-unresolved message must remain in ActiveBodyQueue's filter")
    }

    @Test("Empty snippet from merge preserves existing snippet (CASE WHEN guard)")
    func emptySnippetGuardPreservesExisting() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1", email: "u@ex.com")
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")
        try TestDatabase.insertMessageHeader(db, messageId: "m1", folderId: "acc1:INBOX", accountId: "acc1")

        let headerId: String = try db.read {
            try String.fetchOne($0, sql: "SELECT id FROM messageHeader WHERE messageId = 'm1'")!
        }

        // Pre-populate snippet from sync.
        try db.write { db in
            try db.execute(sql: "UPDATE messageHeader SET snippet = ? WHERE id = ?",
                          arguments: ["existing snippet from sync", headerId])
        }

        // Merge with empty snippet (NSE didn't render a text body) — must NOT clobber.
        try db.write { db in
            try db.execute(sql: """
                UPDATE messageHeader SET
                    bodyComplete = ?,
                    snippet = CASE WHEN ? = '' THEN snippet ELSE ? END
                WHERE id = ?
                """, arguments: [1, "", "", headerId])
        }

        let snippet: String? = try db.read {
            try String.fetchOne($0, sql: "SELECT snippet FROM messageHeader WHERE id = ?", arguments: [headerId])
        }
        #expect(snippet == "existing snippet from sync",
                "Empty merge snippet must not overwrite existing sync-derived snippet")
    }

    @Test("Merge creates both header + body atomically when NSE arrives before sync")
    func freshHeaderFromStaging() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1", email: "u@ex.com")
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")

        // Simulate the merge's "create fresh header from NSE staging" branch —
        // INSERT the header + body in the same transaction.
        try db.write { db in
            var header = MessageHeader(
                messageId: "nse-m1", subject: "NSE subject",
                from: "Alice", fromAddress: "alice@ex.com",
                to: "me@ex.com", date: Date(),
                snippet: "NSE snippet", folderId: "acc1:INBOX",
                accountId: "acc1", folderPath: "INBOX", isInInbox: true
            )
            header.headerComplete = true
            try header.insert(db, onConflict: .ignore)

            let headerId = try String.fetchOne(db, sql: """
                SELECT id FROM messageHeader WHERE accountId = ? AND messageId = ?
                """, arguments: ["acc1", "nse-m1"])!

            // MessageBody stores only htmlContent — plain-text is converted via
            // MessageBody.create in production (see PROJECT_MEMORY.md).
            try db.execute(sql: """
                INSERT OR IGNORE INTO messageBody (id, htmlContent, fetchedAt)
                VALUES (?, ?, ?)
                """, arguments: [headerId, "<p>rendered NSE body</p>", Date()])
            try db.execute(sql: """
                UPDATE messageHeader SET bodyComplete = 1 WHERE id = ?
                """, arguments: [headerId])
        }

        // Verify end state.
        let row = try db.read {
            try Row.fetchOne($0, sql: """
                SELECT h.id, h.subject, h.bodyComplete, b.htmlContent
                FROM messageHeader h
                LEFT JOIN messageBody b ON b.id = h.id
                WHERE h.accountId = 'acc1' AND h.messageId = 'nse-m1'
                """)
        }
        #expect(row?["subject"] == "NSE subject")
        #expect(row?["bodyComplete"] == 1)
        #expect(row?["htmlContent"] == "<p>rendered NSE body</p>")
    }

    @Test("setTag pendingOperation is deduped by deterministic id — no dupes on merge retry")
    func pendingOpDedup() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1", email: "u@ex.com")
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")

        // Simulate merge inserting setTag pendingOp twice (e.g. crash between
        // merge-write and staging-row-delete → merge re-runs).
        let detId = "setTag:acc1:msg100:reply"
        let messageIdsJSON = (try? JSONSerialization.data(withJSONObject: ["msg100"]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        for _ in 0..<2 {
            try db.write { db in
                // try? because second insert is expected to violate PK UNIQUE.
                try? db.execute(sql: """
                    INSERT INTO pendingOperation (id, type, messageIdsJSON, accountId, folderPath, tagValue, createdAt, status, retryCount)
                    VALUES (?, 'setTag', ?, ?, 'INBOX', ?, ?, 'queued', 0)
                    """, arguments: [detId, messageIdsJSON, "acc1", "reply", Date()])
            }
        }

        let count: Int = try db.read {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM pendingOperation WHERE id = ?",
                             arguments: [detId])!
        }
        #expect(count == 1, "Deterministic id must dedup — one op, not two")
    }

    @Test("Sync-arrives-after-NSE: header already exists, body not re-fetched")
    func syncAfterNSEIsNoOp() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1", email: "u@ex.com")
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")

        // Step 1: NSE merge creates header + body with bodyComplete=1.
        try db.write { db in
            var header = MessageHeader(
                messageId: "m1", subject: "NSE subject",
                from: "Alice", fromAddress: "alice@ex.com", to: "",
                date: Date(), snippet: "NSE", folderId: "acc1:INBOX",
                accountId: "acc1", folderPath: "INBOX", isInInbox: true
            )
            header.headerComplete = true
            header.bodyComplete = true
            try header.insert(db)
            let headerId = try String.fetchOne(db, sql: """
                SELECT id FROM messageHeader WHERE messageId = 'm1'
                """)!
            try db.execute(sql: """
                INSERT INTO messageBody (id, htmlContent, fetchedAt) VALUES (?, ?, ?)
                """, arguments: [headerId, "<p>NSE body</p>", Date()])
        }

        // Step 2: Sync runs, would enqueue for body fetch ONLY if bodyComplete=0.
        // Verify the header is filtered OUT by ActiveBodyQueue's SQL predicate.
        let shouldEnqueue: Int = try db.read {
            // The production query itself, via `ActiveBodyQueue.admissionItems`. A hand-copied
            // predicate stops BEING the admission predicate the moment production gains a
            // clause — it just gained `AND bodyMetadataOversized = 0`, and a never-drop claim
            // measured against a stale copy proves nothing about the queue that actually runs.
            try ActiveBodyQueue.admissionItems($0).count
        }
        #expect(shouldEnqueue == 0, "NSE-complete body must be skipped by sync's body queue")
    }
}
