/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

/// Tests for the going-forward chain-walk-first behavior of
/// `ThreadUtils.assignComputedThreadId`.
///
/// Background: pre-fix, Gmail/Exchange `nativeThreadId` was authoritative —
/// when Gmail split a perceived thread into two conversation IDs (subject
/// change, time gap, server heuristics), the inbox showed two rows even
/// though the messages shared an inReplyTo/References chain. Post-fix,
/// `assignComputedThreadId` runs `findAdoptableThreadId` first; native
/// threadId is only used to seed a fresh group.
@Suite("ThreadUtils.assignComputedThreadId — chain-walk first")
struct AssignComputedThreadIdChainFirstTests {

    private func makeDB() throws -> DatabaseQueue {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1")
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")
        return db
    }

    private func make(
        messageId: String,
        rfc822: String? = nil,
        inReplyTo: String? = nil,
        references: [String] = []
    ) -> MessageHeader {
        var h = MessageHeader(
            messageId: messageId, subject: "s", from: "a", fromAddress: "a@x",
            to: "b@x", date: Date(), snippet: "", folderId: "acc1:INBOX",
            accountId: "acc1", folderPath: "INBOX", isInInbox: true
        )
        h.rfc822MessageId = rfc822
        h.inReplyTo = inReplyTo
        h.referencesJSON = MessageHeader.encodeReferences(references)
        return h
    }

    @Test("Gmail: chain match wins over native threadId — fragmented conversation merges")
    func chainMatchOverridesNativeThreadId() throws {
        let db = try makeDB()
        // Message A: Gmail conversation T1, no chain dependency.
        var a = make(messageId: "uidA", rfc822: "a@x")
        try db.write { db in
            try ThreadUtils.assignComputedThreadId(to: &a, nativeThreadId: "T1", db: db)
            try a.insert(db)
            try ThreadUtils.insertMessageReferences(for: a, db: db)
        }
        #expect(a.computedThreadId == "T1")

        // Message B: Gmail says T2 (different conversation), but its inReplyTo
        // points at A. Chain-walk wins → adopt T1.
        var b = make(messageId: "uidB", rfc822: "b@x", inReplyTo: "a@x")
        try db.write { db in
            try ThreadUtils.assignComputedThreadId(to: &b, nativeThreadId: "T2", db: db)
        }
        #expect(b.computedThreadId == "T1", "Chain match must override Gmail's fragmented threadId")
    }

    @Test("Gmail: no chain match → native threadId seeds the new group")
    func noChainUsesNativeThreadId() throws {
        let db = try makeDB()
        // First message of a new conversation — nothing to chain to.
        var a = make(messageId: "uidA", rfc822: "first@x")
        try db.write { db in
            try ThreadUtils.assignComputedThreadId(to: &a, nativeThreadId: "T-new", db: db)
        }
        #expect(a.computedThreadId == "T-new")
    }

    @Test("IMAP: no chain, no native threadId → falls back to own rfc822MessageId")
    func imapFallback() throws {
        let db = try makeDB()
        var a = make(messageId: "uidA", rfc822: "a@x")
        try db.write { db in
            try ThreadUtils.assignComputedThreadId(to: &a, nativeThreadId: nil, db: db)
        }
        #expect(a.computedThreadId == "a@x")
    }

    @Test("IMAP: chain match still works when no native threadId is provided")
    func imapChainMatch() throws {
        let db = try makeDB()
        var a = make(messageId: "uidA", rfc822: "a@x")
        try db.write { db in
            try ThreadUtils.assignComputedThreadId(to: &a, nativeThreadId: nil, db: db)
            try a.insert(db)
            try ThreadUtils.insertMessageReferences(for: a, db: db)
        }
        let aCtid = a.computedThreadId

        var b = make(messageId: "uidB", rfc822: "b@x", inReplyTo: "a@x")
        try db.write { db in
            try ThreadUtils.assignComputedThreadId(to: &b, nativeThreadId: nil, db: db)
        }
        #expect(b.computedThreadId == aCtid, "IMAP reply must adopt parent's computedThreadId")
    }

    @Test("Subject-prefixed nativeThreadId is treated as no native threadId")
    func subjectPrefixIgnored() throws {
        let db = try makeDB()
        // 'subj:...' is the synthetic IMAP fallback marker. assignComputedThreadId
        // must not adopt it as the native id (per the existing !hasPrefix("subj:")
        // guard that we preserved post-refactor).
        var a = make(messageId: "uidA", rfc822: "a@x")
        try db.write { db in
            try ThreadUtils.assignComputedThreadId(to: &a, nativeThreadId: "subj:acc1:hello", db: db)
        }
        #expect(a.computedThreadId == "a@x", "subj: prefix must NOT be adopted as native threadId")
    }
}

/// Tests for v54 `mergeFragmentedThreads` migration shape — runs the same
/// chain-walk re-evaluation for historic data. Validated by exercising
/// `ThreadUtils.findAdoptableThreadId` against a pre-populated fragmented
/// fixture (matches the migration's algorithm exactly).
@Suite("v54 — historic fragmented-thread merge")
struct V54MergeFragmentedThreadsTests {

    private func makeDB() throws -> DatabaseQueue {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1")
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")
        return db
    }

    /// Insert a message with explicit computedThreadId (pre-fix state).
    @discardableResult
    private func insertHistoric(
        _ db: DatabaseQueue,
        messageId: String,
        rfc822: String,
        inReplyTo: String? = nil,
        ctid: String
    ) throws -> MessageHeader {
        var h = MessageHeader(
            messageId: messageId, subject: "s", from: "a", fromAddress: "a@x",
            to: "b@x", date: Date(timeIntervalSinceNow: TimeInterval(messageId.count)),
            snippet: "", folderId: "acc1:INBOX",
            accountId: "acc1", folderPath: "INBOX", isInInbox: true
        )
        h.rfc822MessageId = rfc822
        h.inReplyTo = inReplyTo
        h.computedThreadId = ctid
        try db.write { db in
            try h.insert(db)
            try ThreadUtils.insertMessageReferences(for: h, db: db)
        }
        return h
    }

    @Test("Merges two fragmented Gmail conversations sharing a chain")
    func mergesFragmentedGmailConversations() throws {
        let db = try makeDB()
        // Pre-fix state: Gmail split into two threadIds T1, T2. M1 in T1,
        // M2 in T2, but M2.inReplyTo = M1.rfc822 (chain-linked).
        let m1 = try insertHistoric(db, messageId: "uidM1", rfc822: "m1@x", ctid: "T1")
        let m2 = try insertHistoric(db, messageId: "uidM2", rfc822: "m2@x", inReplyTo: "m1@x", ctid: "T2")

        let merged = try db.write { try ThreadUtils.runFragmentMergeToFixpoint(db: $0) }
        #expect(merged >= 1)

        let after1 = try db.read { try MessageHeader.fetchOne($0, key: m1.id) }
        let after2 = try db.read { try MessageHeader.fetchOne($0, key: m2.id) }
        #expect(after1?.computedThreadId == after2?.computedThreadId,
                "Both messages must end up with the same computedThreadId")
    }

    @Test("Idempotent — second fixpoint run is a no-op")
    func idempotent() throws {
        let db = try makeDB()
        try insertHistoric(db, messageId: "uidM1", rfc822: "m1@x", ctid: "T1")
        try insertHistoric(db, messageId: "uidM2", rfc822: "m2@x", inReplyTo: "m1@x", ctid: "T2")

        let firstMerged = try db.write { try ThreadUtils.runFragmentMergeToFixpoint(db: $0) }
        let secondMerged = try db.write { try ThreadUtils.runFragmentMergeToFixpoint(db: $0) }
        #expect(firstMerged >= 1)
        #expect(secondMerged == 0)
    }

    @Test("Disconnected threads are left alone")
    func disconnectedThreadsUntouched() throws {
        let db = try makeDB()
        // Two completely unrelated Gmail conversations — no chain link.
        let m1 = try insertHistoric(db, messageId: "uidM1", rfc822: "m1@x", ctid: "T1")
        let m2 = try insertHistoric(db, messageId: "uidM2", rfc822: "m2@x", ctid: "T2")

        let merged = try db.write { try ThreadUtils.runFragmentMergeToFixpoint(db: $0) }
        #expect(merged == 0)

        let after1 = try db.read { try MessageHeader.fetchOne($0, key: m1.id) }
        let after2 = try db.read { try MessageHeader.fetchOne($0, key: m2.id) }
        #expect(after1?.computedThreadId == "T1")
        #expect(after2?.computedThreadId == "T2")
    }

    @Test("Three-message chain across three Gmail threadIds all converge to one")
    func threeMessageChainConverges() throws {
        let db = try makeDB()
        // M1 (T1) ← M2 (T2, inReplyTo=M1) ← M3 (T3, inReplyTo=M2)
        // The original single-pass version of this migration could leave
        // M1=T2, M2=T3, M3=T3 (head-of-chain stranded). The fixpoint loop
        // catches that and propagates one more hop.
        let m1 = try insertHistoric(db, messageId: "uidM1", rfc822: "m1@x", ctid: "T1")
        let m2 = try insertHistoric(db, messageId: "uidM2", rfc822: "m2@x", inReplyTo: "m1@x", ctid: "T2")
        let m3 = try insertHistoric(db, messageId: "uidM3", rfc822: "m3@x", inReplyTo: "m2@x", ctid: "T3")

        _ = try db.write { try ThreadUtils.runFragmentMergeToFixpoint(db: $0) }

        let after1 = try db.read { try MessageHeader.fetchOne($0, key: m1.id) }
        let after2 = try db.read { try MessageHeader.fetchOne($0, key: m2.id) }
        let after3 = try db.read { try MessageHeader.fetchOne($0, key: m3.id) }
        let ctid1 = after1?.computedThreadId
        let ctid2 = after2?.computedThreadId
        let ctid3 = after3?.computedThreadId
        #expect(ctid1 == ctid2)
        #expect(ctid2 == ctid3)
        #expect(ctid1 != "T1" || ctid2 != "T2" || ctid3 != "T3",
                "All three should have moved off their original ctid (full convergence, not partial)")
    }

    /// Wiring contract: every production code path that creates a permanent
    /// `MessageHeader` row MUST call `ThreadUtils.assignComputedThreadId` so
    /// that the chain-walk-first fix (Gmail-fragmented threads merge into
    /// the existing inbox group) actually applies to new inserts.
    ///
    /// This is a static-source check: it greps each known insert site for the
    /// call. Brittle to file moves but catches a refactor that drops the call
    /// at one site without breaking anything visibly until users see two rows.
    /// Update the path list when you intentionally add or remove an insert
    /// site (and only then).
    @Test("Wiring contract: every production insert path calls ThreadUtils.assignComputedThreadId")
    func wiringContractAllInsertPaths() throws {
        // Project root is two levels up from the test file: …/tabmail-ios/TabMailTests/Helpers/<this>
        // #filePath (vs #file) returns the absolute disk path even under iOS test harnesses;
        // #file is module-relative when compiled into a test bundle.
        let testFile = URL(fileURLWithPath: #filePath)
        let projectRoot = testFile.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

        let insertSites = [
            "TabMail/Services/Sync/SyncEngineFullSync.swift",
            "TabMail/Services/Sync/SyncEngine.swift",
            "TabMail/Services/Sync/SyncEngineDeltaSync.swift",
            "TabMail/Services/Sync/SyncEngineBackfillDeep.swift",
            "TabMail/Services/Account/AccountManagerOutbox.swift",
            "TabMail/Services/NSEDataBridge.swift",
        ]

        for relPath in insertSites {
            let path = projectRoot.appendingPathComponent(relPath)
            let source: String
            do {
                source = try String(contentsOf: path, encoding: .utf8)
            } catch {
                Issue.record("Cannot read \(relPath) — has the file moved? Update the contract test's path list. error=\(error)")
                continue
            }
            let containsCall = source.contains("ThreadUtils.assignComputedThreadId")
            #expect(containsCall, "\(relPath) inserts MessageHeader rows but does not call ThreadUtils.assignComputedThreadId — Gmail-fragmented threads will not merge for messages arriving via this path.")
        }
    }

    @Test("Five-message chain converges (multi-pass exercise)")
    func fiveMessageChainConverges() throws {
        let db = try makeDB()
        // M1 ← M2 ← M3 ← M4 ← M5, each with a distinct ctid.
        // Worst case for single-pass: only two hops merge; longer chains
        // need more passes.
        let m1 = try insertHistoric(db, messageId: "uidM1", rfc822: "m1@x", ctid: "T1")
        let m2 = try insertHistoric(db, messageId: "uidM2", rfc822: "m2@x", inReplyTo: "m1@x", ctid: "T2")
        let m3 = try insertHistoric(db, messageId: "uidM3", rfc822: "m3@x", inReplyTo: "m2@x", ctid: "T3")
        let m4 = try insertHistoric(db, messageId: "uidM4", rfc822: "m4@x", inReplyTo: "m3@x", ctid: "T4")
        let m5 = try insertHistoric(db, messageId: "uidM5", rfc822: "m5@x", inReplyTo: "m4@x", ctid: "T5")

        _ = try db.write { try ThreadUtils.runFragmentMergeToFixpoint(db: $0) }

        let ctids = try db.read { db -> Set<String> in
            var s = Set<String>()
            for h in [m1, m2, m3, m4, m5] {
                if let after = try MessageHeader.fetchOne(db, key: h.id) {
                    s.insert(after.computedThreadId)
                }
            }
            return s
        }
        #expect(ctids.count == 1, "All 5 messages must share the same computedThreadId after fixpoint, got: \(ctids)")
    }
}
