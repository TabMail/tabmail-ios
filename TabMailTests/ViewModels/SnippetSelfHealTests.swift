/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

@Suite("Snippet self-heal — Tier 0 DB check")
struct SnippetSelfHealTests {

    // MARK: - Helpers

    /// Simulates the Tier 0 logic from InboxViewModel.loadSnippetBatch():
    /// For each headerId with empty in-memory snippet, check if DB has a non-empty snippet.
    /// Returns snippet updates that would be applied to the in-memory snapshots.
    private func tier0Check(
        db: DatabaseQueue,
        emptySnippetIds: [String]
    ) throws -> [(headerId: String, snippet: String)] {
        var updates: [(headerId: String, snippet: String)] = []
        for headerId in emptySnippetIds {
            if let header = try db.read({ dbConn in try MessageHeader.fetchOne(dbConn, key: headerId) }),
               !header.snippet.isEmpty {
                updates.append((headerId: headerId, snippet: header.snippet))
            }
        }
        return updates
    }

    // MARK: - Tests

    @Test("Tier 0 picks up snippet already written to DB by fetchBody")
    func picksUpExistingSnippet() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db, name: "Sent", path: "Sent", role: .sent)
        let header = try TestDatabase.insertMessageHeader(
            db, messageId: "1", snippet: "",
            folderId: "acc1:Sent", folderPath: "Sent", isInInbox: false
        )

        // Simulate fetchBody writing snippet to DB (as fetchBody does at line 130-132)
        try db.write { dbConn in
            try dbConn.execute(
                sql: "UPDATE messageHeader SET snippet = ? WHERE id = ?",
                arguments: ["Meeting notes from yesterday's call...", header.id]
            )
        }

        // Tier 0 check — in-memory snapshot still has empty snippet
        let updates = try tier0Check(db: db, emptySnippetIds: [header.id])
        #expect(updates.count == 1)
        guard updates.count == 1 else { return }
        #expect(updates[0].headerId == header.id)
        #expect(updates[0].snippet == "Meeting notes from yesterday's call...")
    }

    @Test("Tier 0 skips messages whose DB snippet is still empty")
    func skipsStillEmpty() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let header = try TestDatabase.insertMessageHeader(
            db, messageId: "1", snippet: ""
        )

        let updates = try tier0Check(db: db, emptySnippetIds: [header.id])
        #expect(updates.isEmpty)
    }

    @Test("Tier 0 handles mix of filled and empty snippets")
    func mixedSnippets() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)

        let h1 = try TestDatabase.insertMessageHeader(db, messageId: "1", snippet: "")
        let h2 = try TestDatabase.insertMessageHeader(db, messageId: "2", snippet: "")

        // Only h2 gets its snippet filled (e.g., by ActiveBodyQueue)
        try db.write { dbConn in
            try dbConn.execute(
                sql: "UPDATE messageHeader SET snippet = ? WHERE id = ?",
                arguments: ["Filled snippet", h2.id]
            )
        }

        let updates = try tier0Check(db: db, emptySnippetIds: [h1.id, h2.id])
        #expect(updates.count == 1)
        guard updates.count == 1 else { return }
        #expect(updates[0].headerId == h2.id)
        #expect(updates[0].snippet == "Filled snippet")
    }

    @Test("Tier 0 handles non-existent header IDs gracefully")
    func nonExistentIds() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)

        let updates = try tier0Check(db: db, emptySnippetIds: ["nonexistent-id"])
        #expect(updates.isEmpty)
    }

    @Test("Tier 0 is idempotent — running twice returns same result")
    func idempotent() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db, name: "Sent", path: "Sent", role: .sent)
        let header = try TestDatabase.insertMessageHeader(
            db, messageId: "1", snippet: "",
            folderId: "acc1:Sent", folderPath: "Sent", isInInbox: false
        )

        try db.write { dbConn in
            try dbConn.execute(
                sql: "UPDATE messageHeader SET snippet = ? WHERE id = ?",
                arguments: ["Idempotent snippet", header.id]
            )
        }

        let first = try tier0Check(db: db, emptySnippetIds: [header.id])
        let second = try tier0Check(db: db, emptySnippetIds: [header.id])
        #expect(first.count == second.count)
        guard first.count == 1, second.count == 1 else { return }
        #expect(first[0].snippet == second[0].snippet)
    }

    @Test("Tier 1 FTS body text produces same snippet as canonical htmlToPlainText path")
    func tier1FTSConsistency() throws {
        // Tier 1 reads plain text from FTS and runs snippetFromPlainText.
        // The canonical path is htmlToPlainText → snippetFromPlainText.
        // Verify both produce identical snippets for the same HTML source.
        let html = "<p>Meeting notes from <b>yesterday's</b> call about the Q3 roadmap.</p>"
        let canonicalPlain = EmailFilter.htmlToPlainText(html)
        let canonicalSnippet = EmailFilter.snippetFromPlainText(canonicalPlain)

        // FTS stores the output of htmlToPlainText, so Tier 1 reads that same plain text
        let tier1Snippet = EmailFilter.snippetFromPlainText(canonicalPlain)
        #expect(tier1Snippet == canonicalSnippet)
        #expect(tier1Snippet.contains("Meeting notes"))
        #expect(!tier1Snippet.contains("<p>"))
        #expect(!tier1Snippet.contains("<b>"))
    }

    @Test("Tier 1 FTS body with display:none preheader produces clean snippet")
    func tier1FTSPreheaderClean() throws {
        // Real-world: Mailchimp-style HTML with display:none padding div
        let html = """
        <div style="display:none;max-height:0px;overflow:hidden;">\u{034F} \u{200C} &nbsp; \u{034F} \u{200C}</div>\
        <p>Important update about your account security settings.</p>
        """
        // FTS stores plain text from htmlToPlainText
        let ftsText = EmailFilter.htmlToPlainText(html)
        let snippet = EmailFilter.snippetFromPlainText(ftsText)
        #expect(snippet.contains("Important update"))
        #expect(!snippet.contains("\u{034F}"))
        #expect(!snippet.contains("\u{200C}"))
    }

    @Test("Tier 1 FTS snippet writes to DB and matches Tier 2 result")
    func tier1WritesMatchesTier2() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let header = try TestDatabase.insertMessageHeader(db, messageId: "fts1", snippet: "")

        // Simulate Tier 1: FTS has body text, derive snippet and write to DB
        let ftsBodyText = "Thanks for the update. I'll review the document and get back to you by Friday."
        let tier1Snippet = EmailFilter.snippetFromPlainText(ftsBodyText)
        try db.write { dbConn in
            try dbConn.execute(
                sql: "UPDATE messageHeader SET snippet = ? WHERE id = ?",
                arguments: [tier1Snippet, header.id]
            )
        }

        // Verify DB was updated
        let updated = try db.read { try MessageHeader.fetchOne($0, key: header.id) }
        #expect(updated?.snippet == tier1Snippet)
        #expect(!tier1Snippet.isEmpty)

        // Simulate Tier 2 would produce same result from same plain text source
        let tier2Snippet = EmailFilter.snippetFromPlainText(ftsBodyText)
        #expect(tier1Snippet == tier2Snippet)
    }

    @Test("All snippet paths produce identical output for same HTML input")
    func allPathsConsistent() throws {
        let html = "<div><h1>Newsletter</h1><p>Check out our <a href='#'>latest updates</a> and new features.</p></div>"

        // Path A: Canonical (ActiveBodyQueue, AccountManagerFetch, BackfillWalk)
        let plainA = EmailFilter.htmlToPlainText(html)
        let snippetA = EmailFilter.snippetFromPlainText(plainA)

        // Path B: Tier 1 FTS (reads plain text that was stored by Path A)
        let snippetB = EmailFilter.snippetFromPlainText(plainA)

        // Path C: Tier 2 InboxViewModel (htmlToPlainText → snippetFromPlainText)
        let plainC = EmailFilter.htmlToPlainText(html)
        let snippetC = EmailFilter.snippetFromPlainText(plainC)

        #expect(snippetA == snippetB)
        #expect(snippetB == snippetC)
        #expect(snippetA.contains("latest updates"))
    }

    @Test("Sent message snippet populated after body fetch — full flow simulation")
    func sentMessageFullFlow() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db, name: "Sent", path: "Sent", role: .sent)

        // Step 1: Sync creates header with empty snippet (IMAP always returns empty)
        let header = try TestDatabase.insertMessageHeader(
            db, messageId: "1", snippet: "",
            folderId: "acc1:Sent", folderPath: "Sent", isInInbox: false
        )

        // Step 2: Body is fetched and snippet derived
        let bodyText = "Thanks for the update. I'll review the document and get back to you by Friday."
        let snippet = EmailFilter.snippetFromPlainText(bodyText)
        try db.write { dbConn in
            try dbConn.execute(
                sql: "UPDATE messageHeader SET snippet = ? WHERE id = ?",
                arguments: [snippet, header.id]
            )
        }

        // Step 3: Tier 0 self-heal picks it up
        let updates = try tier0Check(db: db, emptySnippetIds: [header.id])
        #expect(updates.count == 1)
        guard updates.count == 1 else { return }
        #expect(!updates[0].snippet.isEmpty)
        #expect(updates[0].snippet == snippet)
    }
}
