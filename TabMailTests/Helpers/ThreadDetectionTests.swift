/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

@Suite("ThreadDetection")
struct ThreadDetectionTests {

    // MARK: - Helpers

    /// Creates a file-based DatabasePool (ThreadDetection requires DatabasePool, not DatabaseQueue)
    private func makePool() throws -> DatabasePool {
        let tempDir = FileManager.default.temporaryDirectory
        let dbPath = tempDir.appendingPathComponent("test_thread_\(UUID().uuidString).sqlite").path
        var config = Configuration()
        config.foreignKeysEnabled = true
        let pool = try DatabasePool(path: dbPath, configuration: config)
        try AppDatabase.runMigrations(on: pool)
        return pool
    }

    private func insertAccount(_ pool: DatabasePool, id: String = "acc1") throws {
        try pool.write { db in
            var account = Account(emailAddress: "test@example.com", displayName: "Test", provider: .gmail)
            account.id = id
            try account.insert(db)
        }
    }

    private func insertFolder(_ pool: DatabasePool, accountId: String = "acc1") throws {
        try pool.write { db in
            let folder = Folder(name: "INBOX", path: "INBOX", role: .inbox, accountId: accountId)
            try folder.insert(db)
        }
    }

    private func insertFolder(_ pool: DatabasePool, name: String, path: String, role: FolderRole, accountId: String = "acc1") throws {
        try pool.write { db in
            let folder = Folder(name: name, path: path, role: role, accountId: accountId)
            try folder.insert(db)
        }
    }

    private func insertHeader(
        _ pool: DatabasePool,
        messageId: String,
        subject: String = "Test",
        rfc822MessageId: String? = nil,
        inReplyTo: String? = nil,
        references: [String] = [],
        threadId: String? = nil,
        date: Date = Date(),
        folderId: String = "acc1:INBOX",
        folderPath: String = "INBOX",
        accountId: String = "acc1"
    ) throws -> MessageHeader {
        var h = MessageHeader(
            messageId: messageId, subject: subject, from: "a@b.com",
            fromAddress: "a@b.com", to: "c@d.com", date: date,
            snippet: "", folderId: folderId,
            accountId: accountId, folderPath: folderPath, isInInbox: true
        )
        h.rfc822MessageId = rfc822MessageId.map { EmailFilter.normalizeMessageId($0) }
        h.inReplyTo = inReplyTo.map { EmailFilter.normalizeMessageId($0) }
        h.referencesJSON = MessageHeader.encodeReferences(references.map { EmailFilter.normalizeMessageId($0) })
        h.threadId = threadId
        try pool.write { db in
            try h.insert(db)
            try ThreadUtils.insertMessageReferences(for: h, db: db)
        }
        return h
    }

    @Test("No related messages for standalone email")
    func standaloneEmail() throws {
        let pool = try makePool()
        try insertAccount(pool)
        try insertFolder(pool)

        let h = try insertHeader(pool, messageId: "1", rfc822MessageId: "<standalone@test.com>")

        let related = try ThreadDetection.findRelatedMessages(for: h, in: pool)
        #expect(related.isEmpty)
    }

    @Test("Finds parent via inReplyTo → rfc822MessageId")
    func findsParent() throws {
        let pool = try makePool()
        try insertAccount(pool)
        try insertFolder(pool)

        let _ = try insertHeader(pool, messageId: "1", rfc822MessageId: "<parent@test.com>",
                                 date: Date().addingTimeInterval(-3600))
        let child = try insertHeader(pool, messageId: "2", rfc822MessageId: "<child@test.com>",
                                     inReplyTo: "<parent@test.com>")

        let related = try ThreadDetection.findRelatedMessages(for: child, in: pool)
        #expect(related.count == 1)
        #expect(related[0].rfc822MessageId == "parent@test.com")
    }

    @Test("Finds children via rfc822MessageId ← inReplyTo")
    func findsChildren() throws {
        let pool = try makePool()
        try insertAccount(pool)
        try insertFolder(pool)

        let parent = try insertHeader(pool, messageId: "1", rfc822MessageId: "<parent@test.com>",
                                      date: Date().addingTimeInterval(-3600))
        let _ = try insertHeader(pool, messageId: "2", rfc822MessageId: "<c1@test.com>",
                                 inReplyTo: "<parent@test.com>",
                                 date: Date().addingTimeInterval(-1800))
        let _ = try insertHeader(pool, messageId: "3", rfc822MessageId: "<c2@test.com>",
                                 inReplyTo: "<parent@test.com>")

        let related = try ThreadDetection.findRelatedMessages(for: parent, in: pool)
        #expect(related.count == 2)
    }

    @Test("Finds siblings (same inReplyTo)")
    func findsSiblings() throws {
        let pool = try makePool()
        try insertAccount(pool)
        try insertFolder(pool)

        let _ = try insertHeader(pool, messageId: "1", rfc822MessageId: "<parent@test.com>",
                                 date: Date().addingTimeInterval(-7200))
        let sibling1 = try insertHeader(pool, messageId: "2", rfc822MessageId: "<s1@test.com>",
                                        inReplyTo: "<parent@test.com>",
                                        date: Date().addingTimeInterval(-3600))
        let _ = try insertHeader(pool, messageId: "3", rfc822MessageId: "<s2@test.com>",
                                 inReplyTo: "<parent@test.com>")

        let related = try ThreadDetection.findRelatedMessages(for: sibling1, in: pool)
        #expect(related.count == 2)
    }

    @Test("Native threadId finds related messages")
    func nativeThreadId() throws {
        let pool = try makePool()
        try insertAccount(pool)
        try insertFolder(pool)

        let msg1 = try insertHeader(pool, messageId: "1", rfc822MessageId: "<m1@test.com>",
                                    threadId: "thread-abc", date: Date().addingTimeInterval(-3600))
        let _ = try insertHeader(pool, messageId: "2", rfc822MessageId: "<m2@test.com>",
                                 threadId: "thread-abc")

        let related = try ThreadDetection.findRelatedMessages(for: msg1, in: pool)
        #expect(related.count == 1)
        #expect(related[0].rfc822MessageId == "m2@test.com")
    }

    @Test("Synthetic subj: threadId is ignored")
    func syntheticSubjThreadIdIgnored() throws {
        let pool = try makePool()
        try insertAccount(pool)
        try insertFolder(pool)

        let msg1 = try insertHeader(pool, messageId: "1", rfc822MessageId: "<m1@test.com>",
                                    threadId: "subj:acc1:meeting", date: Date().addingTimeInterval(-3600))
        let _ = try insertHeader(pool, messageId: "2", rfc822MessageId: "<m2@test.com>",
                                 threadId: "subj:acc1:meeting")

        let related = try ThreadDetection.findRelatedMessages(for: msg1, in: pool)
        #expect(related.isEmpty)
    }

    @Test("Results are sorted by date descending")
    func sortedByDateDescending() throws {
        let pool = try makePool()
        try insertAccount(pool)
        try insertFolder(pool)

        let now = Date()
        let parent = try insertHeader(pool, messageId: "1", rfc822MessageId: "<p@test.com>",
                                      date: now.addingTimeInterval(-7200))
        let _ = try insertHeader(pool, messageId: "2", rfc822MessageId: "<c1@test.com>",
                                 inReplyTo: "<p@test.com>",
                                 date: now.addingTimeInterval(-3600))
        let _ = try insertHeader(pool, messageId: "3", rfc822MessageId: "<c2@test.com>",
                                 inReplyTo: "<p@test.com>",
                                 date: now.addingTimeInterval(-1800))
        let _ = try insertHeader(pool, messageId: "4", rfc822MessageId: "<c3@test.com>",
                                 inReplyTo: "<p@test.com>",
                                 date: now)

        let related = try ThreadDetection.findRelatedMessages(for: parent, in: pool)
        #expect(related.count == 3)
        for i in 0..<(related.count - 1) {
            #expect(related[i].date >= related[i + 1].date)
        }
    }

    @Test("Chain walking finds grandparent")
    func chainWalkingGrandparent() throws {
        let pool = try makePool()
        try insertAccount(pool)
        try insertFolder(pool)

        let _ = try insertHeader(pool, messageId: "1", rfc822MessageId: "<gp@test.com>",
                                 date: Date().addingTimeInterval(-7200))
        let _ = try insertHeader(pool, messageId: "2", rfc822MessageId: "<p@test.com>",
                                 inReplyTo: "<gp@test.com>",
                                 date: Date().addingTimeInterval(-3600))
        let child = try insertHeader(pool, messageId: "3", rfc822MessageId: "<c@test.com>",
                                     inReplyTo: "<p@test.com>")

        let related = try ThreadDetection.findRelatedMessages(for: child, in: pool)
        #expect(related.count == 2)
        let ids = Set(related.map { $0.rfc822MessageId })
        #expect(ids.contains("gp@test.com"))
        #expect(ids.contains("p@test.com"))
    }

    @Test("Deep forward chain walking finds all descendants")
    func deepForwardChain() throws {
        let pool = try makePool()
        try insertAccount(pool)
        try insertFolder(pool)

        let now = Date()
        // Linear chain: A → B → C → D → E → F (user opens C, should find all)
        let _ = try insertHeader(pool, messageId: "1", rfc822MessageId: "<a@test.com>",
                                 date: now.addingTimeInterval(-5 * 3600))
        let _ = try insertHeader(pool, messageId: "2", rfc822MessageId: "<b@test.com>",
                                 inReplyTo: "<a@test.com>",
                                 date: now.addingTimeInterval(-4 * 3600))
        let msgC = try insertHeader(pool, messageId: "3", rfc822MessageId: "<c@test.com>",
                                    inReplyTo: "<b@test.com>",
                                    date: now.addingTimeInterval(-3 * 3600))
        let _ = try insertHeader(pool, messageId: "4", rfc822MessageId: "<d@test.com>",
                                 inReplyTo: "<c@test.com>",
                                 date: now.addingTimeInterval(-2 * 3600))
        let _ = try insertHeader(pool, messageId: "5", rfc822MessageId: "<e@test.com>",
                                 inReplyTo: "<d@test.com>",
                                 date: now.addingTimeInterval(-1 * 3600))
        let _ = try insertHeader(pool, messageId: "6", rfc822MessageId: "<f@test.com>",
                                 inReplyTo: "<e@test.com>",
                                 date: now)

        let related = try ThreadDetection.findRelatedMessages(for: msgC, in: pool)
        // Should find A, B, D, E, F (all 5 other messages)
        #expect(related.count == 5)
        let ids = Set(related.map { $0.rfc822MessageId })
        #expect(ids.contains("a@test.com"))
        #expect(ids.contains("b@test.com"))
        #expect(ids.contains("d@test.com"))
        #expect(ids.contains("e@test.com"))
        #expect(ids.contains("f@test.com"))
    }

    @Test("Forward chain from first message finds all replies")
    func forwardChainFromFirst() throws {
        let pool = try makePool()
        try insertAccount(pool)
        try insertFolder(pool)

        let now = Date()
        // A → B → C → D → E (user opens A, should find B through E)
        let msgA = try insertHeader(pool, messageId: "1", rfc822MessageId: "<a@test.com>",
                                    date: now.addingTimeInterval(-4 * 3600))
        let _ = try insertHeader(pool, messageId: "2", rfc822MessageId: "<b@test.com>",
                                 inReplyTo: "<a@test.com>",
                                 date: now.addingTimeInterval(-3 * 3600))
        let _ = try insertHeader(pool, messageId: "3", rfc822MessageId: "<c@test.com>",
                                 inReplyTo: "<b@test.com>",
                                 date: now.addingTimeInterval(-2 * 3600))
        let _ = try insertHeader(pool, messageId: "4", rfc822MessageId: "<d@test.com>",
                                 inReplyTo: "<c@test.com>",
                                 date: now.addingTimeInterval(-1 * 3600))
        let _ = try insertHeader(pool, messageId: "5", rfc822MessageId: "<e@test.com>",
                                 inReplyTo: "<d@test.com>",
                                 date: now)

        let related = try ThreadDetection.findRelatedMessages(for: msgA, in: pool)
        #expect(related.count == 4)
        let ids = Set(related.map { $0.rfc822MessageId })
        #expect(ids.contains("b@test.com"))
        #expect(ids.contains("c@test.com"))
        #expect(ids.contains("d@test.com"))
        #expect(ids.contains("e@test.com"))
    }

    @Test("Empty inReplyTo and rfc822MessageId returns empty")
    func emptyFieldsReturnsEmpty() throws {
        let pool = try makePool()
        try insertAccount(pool)
        try insertFolder(pool)

        let msg = try insertHeader(pool, messageId: "1")

        let related = try ThreadDetection.findRelatedMessages(for: msg, in: pool)
        #expect(related.isEmpty)
    }

    // MARK: - References Header Tests

    @Test("Forward references: finds ancestor via References header when inReplyTo is missing from DB")
    func forwardReferencesFindsAncestor() throws {
        let pool = try makePool()
        try insertAccount(pool)
        try insertFolder(pool)

        let now = Date()
        // Message A: the original
        let _ = try insertHeader(pool, messageId: "1", rfc822MessageId: "<a@test.com>",
                                 date: now.addingTimeInterval(-3600))
        // Message B: inReplyTo points to a MISSING intermediate, but references includes A
        let msgB = try insertHeader(pool, messageId: "2", rfc822MessageId: "<b@test.com>",
                                    inReplyTo: "<missing@test.com>",
                                    references: ["<a@test.com>", "<missing@test.com>"],
                                    date: now)

        let related = try ThreadDetection.findRelatedMessages(for: msgB, in: pool)
        #expect(related.count == 1)
        guard related.count == 1 else { return }
        #expect(related[0].rfc822MessageId == "a@test.com")
    }

    @Test("Reverse references: finds descendant that references me")
    func reverseReferencesFindsDescendant() throws {
        let pool = try makePool()
        try insertAccount(pool)
        try insertFolder(pool)

        let now = Date()
        // Message A: the original (no inReplyTo, no references)
        let msgA = try insertHeader(pool, messageId: "1", rfc822MessageId: "<a@test.com>",
                                    date: now.addingTimeInterval(-3600))
        // Message B: inReplyTo points to MISSING, but references includes A
        let _ = try insertHeader(pool, messageId: "2", rfc822MessageId: "<b@test.com>",
                                 inReplyTo: "<missing@test.com>",
                                 references: ["<a@test.com>", "<missing@test.com>"],
                                 date: now)

        let related = try ThreadDetection.findRelatedMessages(for: msgA, in: pool)
        #expect(related.count == 1)
        guard related.count == 1 else { return }
        #expect(related[0].rfc822MessageId == "b@test.com")
    }

    @Test("Transitive references: BFS expansion connects siblings through shared ancestor")
    func transitiveReferencesViaBFS() throws {
        let pool = try makePool()
        try insertAccount(pool)
        try insertFolder(pool)

        let now = Date()
        // Real scenario: forwarded email chain with missing intermediates.
        // Message 1 (original): no inReplyTo, no references
        let _ = try insertHeader(pool, messageId: "1",
                                 subject: "Original",
                                 rfc822MessageId: "<original@test.com>",
                                 date: now.addingTimeInterval(-7200))
        // Message 2 (FW): inReplyTo=MISSING, references=[original, missing]
        let msg2 = try insertHeader(pool, messageId: "2",
                                    subject: "FW: Original",
                                    rfc822MessageId: "<fw@test.com>",
                                    inReplyTo: "<missing1@test.com>",
                                    references: ["<original@test.com>", "<missing1@test.com>"],
                                    date: now.addingTimeInterval(-3600))
        // Message 3 (Re: FW): inReplyTo=MISSING2, references=[original, missing1, missing2]
        let _ = try insertHeader(pool, messageId: "3",
                                 subject: "Re: FW: Original",
                                 rfc822MessageId: "<reply@test.com>",
                                 inReplyTo: "<missing2@test.com>",
                                 references: ["<original@test.com>", "<missing1@test.com>", "<missing2@test.com>"],
                                 date: now)

        // Opening message 2 should find BOTH message 1 AND message 3
        // Message 1: found via forward references (original@test.com in msg2's refs)
        // Message 3: found via BFS expansion — after finding msg1, reverse lookup on msg1
        //            finds msg3 (msg3's refs contain original@test.com)
        let related = try ThreadDetection.findRelatedMessages(for: msg2, in: pool)
        #expect(related.count == 2)
        guard related.count == 2 else { return }
        let ids = Set(related.map { $0.rfc822MessageId })
        #expect(ids.contains("original@test.com"))
        #expect(ids.contains("reply@test.com"))
    }

    @Test("Opening original message finds all descendants via reverse references")
    func originalFindsAllDescendantsViaReverseRefs() throws {
        let pool = try makePool()
        try insertAccount(pool)
        try insertFolder(pool)

        let now = Date()
        // Original: no references
        let msgA = try insertHeader(pool, messageId: "1",
                                    rfc822MessageId: "<original@test.com>",
                                    date: now.addingTimeInterval(-7200))
        // FW: references original
        let _ = try insertHeader(pool, messageId: "2",
                                 rfc822MessageId: "<fw@test.com>",
                                 inReplyTo: "<missing@test.com>",
                                 references: ["<original@test.com>", "<missing@test.com>"],
                                 date: now.addingTimeInterval(-3600))
        // Re: FW: references original
        let _ = try insertHeader(pool, messageId: "3",
                                 rfc822MessageId: "<reply@test.com>",
                                 inReplyTo: "<missing2@test.com>",
                                 references: ["<original@test.com>", "<missing@test.com>", "<missing2@test.com>"],
                                 date: now)

        let related = try ThreadDetection.findRelatedMessages(for: msgA, in: pool)
        #expect(related.count == 2)
        guard related.count == 2 else { return }
        let ids = Set(related.map { $0.rfc822MessageId })
        #expect(ids.contains("fw@test.com"))
        #expect(ids.contains("reply@test.com"))
    }

    @Test("Union approach: all signals combined — inReplyTo chain + references + threadId")
    func allSignalsCombined() throws {
        let pool = try makePool()
        try insertAccount(pool)
        try insertFolder(pool)

        let now = Date()
        // msg1: connected via threadId
        let _ = try insertHeader(pool, messageId: "1", rfc822MessageId: "<m1@test.com>",
                                 threadId: "thread-1",
                                 date: now.addingTimeInterval(-4 * 3600))
        // msg2: connected via inReplyTo to msg1
        let _ = try insertHeader(pool, messageId: "2", rfc822MessageId: "<m2@test.com>",
                                 inReplyTo: "<m1@test.com>",
                                 date: now.addingTimeInterval(-3 * 3600))
        // msg3: connected via References to msg1 (inReplyTo missing)
        let _ = try insertHeader(pool, messageId: "3", rfc822MessageId: "<m3@test.com>",
                                 inReplyTo: "<missing@test.com>",
                                 references: ["<m1@test.com>", "<missing@test.com>"],
                                 date: now.addingTimeInterval(-2 * 3600))
        // msg4: connected only via threadId
        let _ = try insertHeader(pool, messageId: "4", rfc822MessageId: "<m4@test.com>",
                                 threadId: "thread-1",
                                 date: now.addingTimeInterval(-1 * 3600))
        // The opened message: has threadId + references
        let opened = try insertHeader(pool, messageId: "5", rfc822MessageId: "<m5@test.com>",
                                      inReplyTo: "<m2@test.com>",
                                      references: ["<m1@test.com>", "<m2@test.com>"],
                                      threadId: "thread-1",
                                      date: now)

        let related = try ThreadDetection.findRelatedMessages(for: opened, in: pool)
        // Should find all 4 other messages
        #expect(related.count == 4)
        guard related.count == 4 else { return }
        let ids = Set(related.map { $0.rfc822MessageId })
        #expect(ids.contains("m1@test.com"))
        #expect(ids.contains("m2@test.com"))
        #expect(ids.contains("m3@test.com"))
        #expect(ids.contains("m4@test.com"))
    }

    // MARK: - Junction Table (messageReference) Reverse Lookup Tests

    @Test("Reverse lookup uses messageReference table — single descendant")
    func junctionTableReverseBasic() throws {
        let pool = try makePool()
        try insertAccount(pool)
        try insertFolder(pool)

        let now = Date()
        // A: original message, no references
        let msgA = try insertHeader(pool, messageId: "1", rfc822MessageId: "<a@test.com>",
                                    date: now.addingTimeInterval(-3600))
        // B: references A (no inReplyTo — so only discoverable via reverse reference lookup)
        let _ = try insertHeader(pool, messageId: "2", rfc822MessageId: "<b@test.com>",
                                 references: ["<a@test.com>"],
                                 date: now)

        let related = try ThreadDetection.findRelatedMessages(for: msgA, in: pool)
        #expect(related.count == 1)
        guard related.count == 1 else { return }
        #expect(related[0].rfc822MessageId == "b@test.com")
    }

    @Test("Reverse lookup uses messageReference table — multiple descendants")
    func junctionTableReverseMultiple() throws {
        let pool = try makePool()
        try insertAccount(pool)
        try insertFolder(pool)

        let now = Date()
        let msgA = try insertHeader(pool, messageId: "1", rfc822MessageId: "<a@test.com>",
                                    date: now.addingTimeInterval(-7200))
        // B and C both reference A but have no inReplyTo link
        let _ = try insertHeader(pool, messageId: "2", rfc822MessageId: "<b@test.com>",
                                 references: ["<a@test.com>"],
                                 date: now.addingTimeInterval(-3600))
        let _ = try insertHeader(pool, messageId: "3", rfc822MessageId: "<c@test.com>",
                                 references: ["<a@test.com>"],
                                 date: now)

        let related = try ThreadDetection.findRelatedMessages(for: msgA, in: pool)
        #expect(related.count == 2)
        guard related.count == 2 else { return }
        let ids = Set(related.map { $0.rfc822MessageId })
        #expect(ids.contains("b@test.com"))
        #expect(ids.contains("c@test.com"))
    }

    @Test("BFS expansion finds transitive connections via junction table")
    func junctionTableBFSTransitive() throws {
        let pool = try makePool()
        try insertAccount(pool)
        try insertFolder(pool)

        let now = Date()
        // A: original
        let _ = try insertHeader(pool, messageId: "1", rfc822MessageId: "<a@test.com>",
                                 date: now.addingTimeInterval(-7200))
        // B: references A (no inReplyTo)
        let msgB = try insertHeader(pool, messageId: "2", rfc822MessageId: "<b@test.com>",
                                    references: ["<a@test.com>"],
                                    date: now.addingTimeInterval(-3600))
        // C: references A (no inReplyTo) — sibling of B, connected transitively
        let _ = try insertHeader(pool, messageId: "3", rfc822MessageId: "<c@test.com>",
                                 references: ["<a@test.com>"],
                                 date: now)

        // Opening B should find A (forward ref) and C (BFS: A found → reverse lookup on A finds C)
        let related = try ThreadDetection.findRelatedMessages(for: msgB, in: pool)
        #expect(related.count == 2)
        guard related.count == 2 else { return }
        let ids = Set(related.map { $0.rfc822MessageId })
        #expect(ids.contains("a@test.com"))
        #expect(ids.contains("c@test.com"))
    }

    @Test("Junction table reverse lookup with no messageReference rows returns empty")
    func junctionTableNoRows() throws {
        let pool = try makePool()
        try insertAccount(pool)
        try insertFolder(pool)

        // A: standalone message — no one references it
        let msgA = try insertHeader(pool, messageId: "1", rfc822MessageId: "<a@test.com>")
        // B: also standalone, no references at all
        let _ = try insertHeader(pool, messageId: "2", rfc822MessageId: "<b@test.com>")

        let related = try ThreadDetection.findRelatedMessages(for: msgA, in: pool)
        #expect(related.isEmpty)
    }

    @Test("Junction table reverse lookup does not return self")
    func junctionTableExcludesSelf() throws {
        let pool = try makePool()
        try insertAccount(pool)
        try insertFolder(pool)

        // A references itself (degenerate case) — should not appear in results
        let msgA = try insertHeader(pool, messageId: "1", rfc822MessageId: "<a@test.com>",
                                    references: ["<a@test.com>"])

        let related = try ThreadDetection.findRelatedMessages(for: msgA, in: pool)
        #expect(related.isEmpty)
    }

    // MARK: - Trash / Spam Exclusion

    @Test("Trashed replies are excluded from related messages")
    func trashedReplyExcluded() throws {
        let pool = try makePool()
        try insertAccount(pool)
        try insertFolder(pool) // INBOX
        try insertFolder(pool, name: "Trash", path: "Trash", role: .trash)

        let parent = try insertHeader(pool, messageId: "1",
                                      rfc822MessageId: "<p@test.com>",
                                      date: Date().addingTimeInterval(-3600))
        // A live reply in INBOX — should appear
        let _ = try insertHeader(pool, messageId: "2",
                                 rfc822MessageId: "<live@test.com>",
                                 inReplyTo: "<p@test.com>")
        // A deleted reply in Trash — should be filtered out
        let _ = try insertHeader(pool, messageId: "3",
                                 rfc822MessageId: "<deleted@test.com>",
                                 inReplyTo: "<p@test.com>",
                                 folderId: "acc1:Trash",
                                 folderPath: "Trash")

        let related = try ThreadDetection.findRelatedMessages(for: parent, in: pool)
        #expect(related.count == 1)
        guard related.count == 1 else { return }
        #expect(related[0].rfc822MessageId == "live@test.com")
    }

    @Test("Spam replies are excluded from related messages")
    func spamReplyExcluded() throws {
        let pool = try makePool()
        try insertAccount(pool)
        try insertFolder(pool) // INBOX
        try insertFolder(pool, name: "Spam", path: "Spam", role: .spam)

        let parent = try insertHeader(pool, messageId: "1",
                                      rfc822MessageId: "<p@test.com>",
                                      date: Date().addingTimeInterval(-3600))
        let _ = try insertHeader(pool, messageId: "2",
                                 rfc822MessageId: "<ham@test.com>",
                                 inReplyTo: "<p@test.com>")
        let _ = try insertHeader(pool, messageId: "3",
                                 rfc822MessageId: "<junk@test.com>",
                                 inReplyTo: "<p@test.com>",
                                 folderId: "acc1:Spam",
                                 folderPath: "Spam")

        let related = try ThreadDetection.findRelatedMessages(for: parent, in: pool)
        #expect(related.count == 1)
        guard related.count == 1 else { return }
        #expect(related[0].rfc822MessageId == "ham@test.com")
    }

    @Test("Trash exclusion applies to native threadId lookups")
    func trashExcludedFromThreadId() throws {
        let pool = try makePool()
        try insertAccount(pool)
        try insertFolder(pool) // INBOX
        try insertFolder(pool, name: "Trash", path: "Trash", role: .trash)

        let msg1 = try insertHeader(pool, messageId: "1",
                                    rfc822MessageId: "<m1@test.com>",
                                    threadId: "thread-abc",
                                    date: Date().addingTimeInterval(-3600))
        // Sibling in Trash via native threadId — must not appear
        let _ = try insertHeader(pool, messageId: "2",
                                 rfc822MessageId: "<m2@test.com>",
                                 threadId: "thread-abc",
                                 folderId: "acc1:Trash",
                                 folderPath: "Trash")

        let related = try ThreadDetection.findRelatedMessages(for: msg1, in: pool)
        #expect(related.isEmpty)
    }

    @Test("Trash exclusion applies to reverse reference (junction table) lookups")
    func trashExcludedFromReverseReferences() throws {
        let pool = try makePool()
        try insertAccount(pool)
        try insertFolder(pool) // INBOX
        try insertFolder(pool, name: "Trash", path: "Trash", role: .trash)

        // Root in INBOX
        let msgA = try insertHeader(pool, messageId: "1", rfc822MessageId: "<a@test.com>",
                                    date: Date().addingTimeInterval(-3600))
        // Descendant discoverable only via the reverse messageReference lookup — in Trash
        let _ = try insertHeader(pool, messageId: "2", rfc822MessageId: "<b@test.com>",
                                 references: ["<a@test.com>"],
                                 folderId: "acc1:Trash",
                                 folderPath: "Trash")

        let related = try ThreadDetection.findRelatedMessages(for: msgA, in: pool)
        #expect(related.isEmpty)
    }

    @Test("Mixed thread: live siblings still appear when some are trashed")
    func mixedThreadLiveSiblingsKept() throws {
        let pool = try makePool()
        try insertAccount(pool)
        try insertFolder(pool) // INBOX
        try insertFolder(pool, name: "Trash", path: "Trash", role: .trash)

        let _ = try insertHeader(pool, messageId: "1",
                                 rfc822MessageId: "<p@test.com>",
                                 date: Date().addingTimeInterval(-7200))
        // Opening this live sibling. Expect to see parent + the other live sibling,
        // NOT the trashed sibling.
        let live = try insertHeader(pool, messageId: "2",
                                    rfc822MessageId: "<s1@test.com>",
                                    inReplyTo: "<p@test.com>",
                                    date: Date().addingTimeInterval(-3600))
        let _ = try insertHeader(pool, messageId: "3",
                                 rfc822MessageId: "<s2@test.com>",
                                 inReplyTo: "<p@test.com>",
                                 date: Date().addingTimeInterval(-1800))
        let _ = try insertHeader(pool, messageId: "4",
                                 rfc822MessageId: "<junked@test.com>",
                                 inReplyTo: "<p@test.com>",
                                 date: Date(),
                                 folderId: "acc1:Trash",
                                 folderPath: "Trash")

        let related = try ThreadDetection.findRelatedMessages(for: live, in: pool)
        #expect(related.count == 2)
        let ids = Set(related.compactMap(\.rfc822MessageId))
        #expect(ids.contains("p@test.com"))
        #expect(ids.contains("s2@test.com"))
        #expect(!ids.contains("junked@test.com"))
    }

    @Test("Trashed parent is excluded when walking inReplyTo upward")
    func trashedParentExcluded() throws {
        let pool = try makePool()
        try insertAccount(pool)
        try insertFolder(pool) // INBOX
        try insertFolder(pool, name: "Trash", path: "Trash", role: .trash)

        // Parent lives in Trash; child in INBOX. Opening the child should not
        // surface the trashed parent via the parent lookup in findByHeaderChain.
        let _ = try insertHeader(pool, messageId: "1",
                                 rfc822MessageId: "<p@test.com>",
                                 date: Date().addingTimeInterval(-3600),
                                 folderId: "acc1:Trash",
                                 folderPath: "Trash")
        let child = try insertHeader(pool, messageId: "2",
                                     rfc822MessageId: "<c@test.com>",
                                     inReplyTo: "<p@test.com>")

        let related = try ThreadDetection.findRelatedMessages(for: child, in: pool)
        #expect(related.isEmpty)
    }

    @Test("Forward references lookup excludes trashed ancestors")
    func forwardReferencesExcludesTrash() throws {
        let pool = try makePool()
        try insertAccount(pool)
        try insertFolder(pool) // INBOX
        try insertFolder(pool, name: "Trash", path: "Trash", role: .trash)

        // Ancestor A lives in Trash. Message B (in INBOX) lists A in its References
        // header. The forward branch of expandReferences must not pull A back in.
        let _ = try insertHeader(pool, messageId: "1",
                                 rfc822MessageId: "<a@test.com>",
                                 date: Date().addingTimeInterval(-3600),
                                 folderId: "acc1:Trash",
                                 folderPath: "Trash")
        let msgB = try insertHeader(pool, messageId: "2",
                                    rfc822MessageId: "<b@test.com>",
                                    inReplyTo: "<missing@test.com>",
                                    references: ["<a@test.com>", "<missing@test.com>"],
                                    date: Date())

        let related = try ThreadDetection.findRelatedMessages(for: msgB, in: pool)
        #expect(related.isEmpty)
    }

    @Test("Cross-account: trash in one account does not filter inbox in another")
    func crossAccountTrashIsolation() throws {
        let pool = try makePool()
        try insertAccount(pool, id: "acc1")
        try insertAccount(pool, id: "acc2")
        try insertFolder(pool, accountId: "acc1") // INBOX
        try insertFolder(pool, accountId: "acc2") // INBOX
        try insertFolder(pool, name: "Trash", path: "Trash", role: .trash, accountId: "acc1")

        // Reply lives in acc2 INBOX. Only acc1 has a Trash folder. The reply must
        // not be filtered just because a trash folder exists on some other account.
        // (Thread detection is cross-account by design — it keys off rfc822 headers,
        // which can legitimately match across accounts; the scope of this test is
        // strictly that trash-folder-id membership does not over-reach.)
        let parent = try insertHeader(pool, messageId: "1",
                                      rfc822MessageId: "<p@test.com>",
                                      date: Date().addingTimeInterval(-3600))
        let _ = try insertHeader(pool, messageId: "2",
                                 rfc822MessageId: "<reply@test.com>",
                                 inReplyTo: "<p@test.com>",
                                 folderId: "acc2:INBOX",
                                 folderPath: "INBOX",
                                 accountId: "acc2")

        let related = try ThreadDetection.findRelatedMessages(for: parent, in: pool)
        #expect(related.count == 1)
        guard related.count == 1 else { return }
        #expect(related[0].rfc822MessageId == "reply@test.com")
        #expect(related[0].accountId == "acc2")
    }

    // MARK: - computedThreadId Lateral Adoption

    /// Insert a header via `ThreadUtils.assignComputedThreadId` + `insertMessageReferences`
    /// so that its `computedThreadId` is set using the production code path.
    @discardableResult
    private func insertHeaderWithComputedThreadId(
        _ pool: DatabasePool,
        messageId: String,
        subject: String = "Test",
        rfc822MessageId: String? = nil,
        inReplyTo: String? = nil,
        references: [String] = [],
        nativeThreadId: String? = nil,
        date: Date = Date(),
        folderId: String = "acc1:INBOX",
        folderPath: String = "INBOX",
        accountId: String = "acc1"
    ) throws -> MessageHeader {
        var h = MessageHeader(
            messageId: messageId, subject: subject, from: "a@b.com",
            fromAddress: "a@b.com", to: "c@d.com", date: date,
            snippet: "", folderId: folderId,
            accountId: accountId, folderPath: folderPath, isInInbox: true
        )
        h.rfc822MessageId = rfc822MessageId.map { EmailFilter.normalizeMessageId($0) }
        h.inReplyTo = inReplyTo.map { EmailFilter.normalizeMessageId($0) }
        h.referencesJSON = MessageHeader.encodeReferences(references.map { EmailFilter.normalizeMessageId($0) })
        try pool.write { db in
            try ThreadUtils.assignComputedThreadId(to: &h, nativeThreadId: nativeThreadId, db: db)
            try h.insert(db)
            try ThreadUtils.insertMessageReferences(for: h, db: db)
        }
        return h
    }

    @Test("assignComputedThreadId: lateral adoption via shared References entry")
    func assignComputedThreadIdLateralAdoption() throws {
        // Same production scenario as `lateralSiblingsViaSharedExternalAncestor`,
        // but asserting the insert-time thread ADOPTION (inbox grouping path)
        // rather than the detail-view FIND path.
        let pool = try makePool()
        try insertAccount(pool)
        try insertFolder(pool)

        let now = Date()
        // First insert (older): no priors to adopt from, so falls back to own rfc822.
        let msgB = try insertHeaderWithComputedThreadId(
            pool, messageId: "B",
            rfc822MessageId: "<exchange-b-001@example.com>",
            inReplyTo: "<gmail-ancestor-w@mail.example.com>",
            references: ["<gmail-ancestor-w@mail.example.com>"],
            date: now.addingTimeInterval(-1800))
        #expect(msgB.computedThreadId == "exchange-b-001@example.com")

        // Second insert (newer): shares a References entry (gmail-ancestor-w) with msgB
        // but neither its inReplyTo nor its rfc822 directly cites msgB. Under the
        // old code this would have fallen back to its own rfc822 (→ separate
        // group). Under the unified lookup, Query B matches
        // "msgB.inReplyTo IN my.L" and adopts msgB's threadId.
        let msgA = try insertHeaderWithComputedThreadId(
            pool, messageId: "A",
            rfc822MessageId: "<exchange-a-001@example.com>",
            inReplyTo: "<gmail-ancestor-z@mail.example.com>",
            references: ["<gmail-ancestor-w@mail.example.com>", "<gmail-ancestor-z@mail.example.com>"],
            date: now)

        #expect(msgA.computedThreadId == msgB.computedThreadId)
    }

    @Test("assignComputedThreadId: Gmail/Exchange native threadId is authoritative")
    func assignComputedThreadIdNativeTakesPrecedence() throws {
        let pool = try makePool()
        try insertAccount(pool)
        try insertFolder(pool)

        let msg = try insertHeaderWithComputedThreadId(
            pool, messageId: "1",
            rfc822MessageId: "<m@test.com>",
            nativeThreadId: "native-thread-xyz")

        #expect(msg.computedThreadId == "native-thread-xyz")
    }

    @Test("assignComputedThreadId: subj: native threadId is ignored (IMAP fallback path runs)")
    func assignComputedThreadIdSubjSkipped() throws {
        let pool = try makePool()
        try insertAccount(pool)
        try insertFolder(pool)

        // No priors to adopt — falls back to own rfc822 rather than adopting the
        // synthetic subj: id.
        let msg = try insertHeaderWithComputedThreadId(
            pool, messageId: "1",
            rfc822MessageId: "<m@test.com>",
            nativeThreadId: "subj:acc1:meeting")

        #expect(msg.computedThreadId == "m@test.com")
    }

    // MARK: - Lateral (Shared-Ancestor) Siblings

    @Test("Lateral siblings via shared References entry (external ancestor)")
    func lateralSiblingsViaSharedExternalAncestor() throws {
        // Production scenario: two messages delivered through Outlook/Exchange
        // that rewrote their Message-IDs. The original Gmail message IDs they
        // still cite in their References headers are NOT in the local DB.
        // Neither message's inReplyTo points at the other. They can only be
        // linked via their shared References entry (the missing external ancestor).
        let pool = try makePool()
        try insertAccount(pool)
        try insertFolder(pool)

        let now = Date()
        // First reply: inReplyTo = original Gmail msg, references = [original].
        let msgB = try insertHeader(pool, messageId: "B",
                                    rfc822MessageId: "<exchange-b-001@example.com>",
                                    inReplyTo: "<gmail-ancestor-w@mail.example.com>",
                                    references: ["<gmail-ancestor-w@mail.example.com>"],
                                    date: now.addingTimeInterval(-1800))
        // Second follow-up: inReplyTo points at a DIFFERENT Gmail msg, but
        // references include the same gmail-ancestor-w ancestor as msgB.
        let msgA = try insertHeader(pool, messageId: "A",
                                    rfc822MessageId: "<exchange-a-001@example.com>",
                                    inReplyTo: "<gmail-ancestor-z@mail.example.com>",
                                    references: ["<gmail-ancestor-w@mail.example.com>",
                                                 "<gmail-ancestor-z@mail.example.com>"],
                                    date: now)

        let relatedFromA = try ThreadDetection.findRelatedMessages(for: msgA, in: pool)
        #expect(relatedFromA.count == 1)
        guard relatedFromA.count == 1 else { return }
        #expect(relatedFromA[0].rfc822MessageId == "exchange-b-001@example.com")

        let relatedFromB = try ThreadDetection.findRelatedMessages(for: msgB, in: pool)
        #expect(relatedFromB.count == 1)
        guard relatedFromB.count == 1 else { return }
        #expect(relatedFromB[0].rfc822MessageId == "exchange-a-001@example.com")
    }

    @Test("Lateral siblings via shared inReplyTo parent not present in DB")
    func lateralSiblingsViaSharedInReplyTo() throws {
        // Both messages reply to the same parent, but the parent row is absent.
        // Classic "sibling via inReplyTo" already worked under the old code, but
        // re-covering this path under the unified query protects against regression.
        let pool = try makePool()
        try insertAccount(pool)
        try insertFolder(pool)

        let now = Date()
        let s1 = try insertHeader(pool, messageId: "s1",
                                  rfc822MessageId: "<s1@test.com>",
                                  inReplyTo: "<missing@test.com>",
                                  references: ["<missing@test.com>"],
                                  date: now.addingTimeInterval(-1800))
        let s2 = try insertHeader(pool, messageId: "s2",
                                  rfc822MessageId: "<s2@test.com>",
                                  inReplyTo: "<missing@test.com>",
                                  references: ["<missing@test.com>"],
                                  date: now)
        _ = s2

        let related = try ThreadDetection.findRelatedMessages(for: s1, in: pool)
        #expect(related.count == 1)
        guard related.count == 1 else { return }
        #expect(related[0].rfc822MessageId == "s2@test.com")
    }

    @Test("Lateral linkage respects Trash/Spam exclusion")
    func lateralRespectsExcludedFolders() throws {
        let pool = try makePool()
        try insertAccount(pool)
        try insertFolder(pool) // INBOX
        try insertFolder(pool, name: "Trash", path: "Trash", role: .trash)

        let now = Date()
        // Two lateral siblings via shared external ancestor — one in Trash.
        let live = try insertHeader(pool, messageId: "live",
                                    rfc822MessageId: "<live@test.com>",
                                    inReplyTo: "<missingA@test.com>",
                                    references: ["<root@test.com>", "<missingA@test.com>"],
                                    date: now.addingTimeInterval(-1800))
        let _ = try insertHeader(pool, messageId: "junked",
                                 rfc822MessageId: "<junked@test.com>",
                                 inReplyTo: "<missingB@test.com>",
                                 references: ["<root@test.com>", "<missingB@test.com>"],
                                 date: now,
                                 folderId: "acc1:Trash",
                                 folderPath: "Trash")

        let related = try ThreadDetection.findRelatedMessages(for: live, in: pool)
        #expect(related.isEmpty)
    }

    // MARK: - Trash BFS

    @Test("Trash BFS: deleted intermediate must not leak its descendants into results")
    func trashBFSBlocksDescendants() throws {
        let pool = try makePool()
        try insertAccount(pool)
        try insertFolder(pool) // INBOX
        try insertFolder(pool, name: "Trash", path: "Trash", role: .trash)

        // A (INBOX) → B (Trash) → C (INBOX). Opening A must not return B (trashed),
        // and because BFS does not expand through B, C stays hidden too.
        let msgA = try insertHeader(pool, messageId: "1", rfc822MessageId: "<a@test.com>",
                                    date: Date().addingTimeInterval(-7200))
        let _ = try insertHeader(pool, messageId: "2", rfc822MessageId: "<b@test.com>",
                                 inReplyTo: "<a@test.com>",
                                 date: Date().addingTimeInterval(-3600),
                                 folderId: "acc1:Trash",
                                 folderPath: "Trash")
        // C references only B's rfc822 — reachable only by walking through B.
        let _ = try insertHeader(pool, messageId: "3", rfc822MessageId: "<c@test.com>",
                                 inReplyTo: "<b@test.com>")

        let related = try ThreadDetection.findRelatedMessages(for: msgA, in: pool)
        // B is trashed (excluded). C is discoverable only via B, so it stays hidden.
        #expect(related.isEmpty)
    }
}
