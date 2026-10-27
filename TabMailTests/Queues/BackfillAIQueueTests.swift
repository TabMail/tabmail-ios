/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

// MARK: - Snapshot codec

@Suite("PendingAIRefinement — snapshot codec")
struct PendingAIRefinementCodecTests {

    @Test("ActionRefineSnapshot encodes and decodes round-trip")
    func actionRoundtrip() throws {
        let snap = ActionRefineSnapshot(
            messageStableId: "msg-1",
            accountId: "acc-1",
            subject: "Invoice Q3",
            from: "billing@example.com",
            summaryBlurb: "Invoice attached, due in 30 days",
            summaryTodos: "pay by end of month",
            originalAction: "reply",
            userManualTag: "archive"
        )
        let row = try PendingAIRefinement.make(snap, now: 1_000_000)
        #expect(row.jobType == "actionRefine")
        #expect(row.dedupKey == "actionRefine:msg-1:archive")
        #expect(row.createdAt == 1_000_000)

        let decoded = try row.decodeActionRefine()
        #expect(decoded.messageStableId == "msg-1")
        #expect(decoded.accountId == "acc-1")
        #expect(decoded.subject == "Invoice Q3")
        #expect(decoded.from == "billing@example.com")
        #expect(decoded.summaryBlurb == "Invoice attached, due in 30 days")
        #expect(decoded.summaryTodos == "pay by end of month")
        #expect(decoded.originalAction == "reply")
        #expect(decoded.userManualTag == "archive")
    }

    @Test("ActionRefineSnapshot dedupKey uses 'nil' literal when untagged")
    func actionUntaggedDedupKey() {
        let snap = ActionRefineSnapshot(
            messageStableId: "msg-2",
            accountId: "acc-1",
            subject: "", from: "",
            summaryBlurb: nil, summaryTodos: nil,
            originalAction: "reply",
            userManualTag: nil
        )
        #expect(snap.dedupKey == "actionRefine:msg-2:nil")
    }

    @Test("KBRefineSnapshot encodes and decodes round-trip")
    func kbRoundtrip() throws {
        let snap = KBRefineSnapshot(
            sessionId: "sess-1",
            enqueuedAt: 1_728_000_000_000,
            turns: [
                .init(role: "user", type: "normal", text: "hi"),
                .init(role: "assistant", type: "normal", text: "hello"),
            ]
        )
        let row = try PendingAIRefinement.make(snap, now: 1_728_000_000_000)
        #expect(row.jobType == "kbRefine")
        #expect(row.dedupKey == "kbRefine:sess-1")

        let decoded = try row.decodeKBRefine()
        #expect(decoded.sessionId == "sess-1")
        #expect(decoded.turns.count == 2)
        guard decoded.turns.count == 2 else { return }
        #expect(decoded.turns[0].role == "user")
        #expect(decoded.turns[0].text == "hi")
        #expect(decoded.turns[1].role == "assistant")
        #expect(decoded.turns[1].text == "hello")
    }

    @Test("Decoding wrong job type throws")
    func wrongJobTypeDecode() throws {
        let action = ActionRefineSnapshot(
            messageStableId: "x", accountId: "y",
            subject: "", from: "",
            summaryBlurb: nil, summaryTodos: nil,
            originalAction: "reply", userManualTag: "archive"
        )
        let row = try PendingAIRefinement.make(action, now: 0)
        #expect(throws: (any Error).self) {
            try row.decodeKBRefine()
        }
    }
}

// MARK: - Demo re-tags never teach (ADR-IOS-038)

/// Installs a temporary `AppDatabase.shared` (the queue writes through it), so
/// the suite mutates global state and must be `.serialized`.
@Suite("BackfillAIQueue — demo re-tags never teach the real action prompt", .serialized, .processGlobalState)
struct BackfillAIQueueDemoRetagTests {
    private func install() throws -> (DatabasePool, URL, AppDatabase?) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("backfill-demo-retag-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        let pool = try DatabasePool(
            path: directory.appendingPathComponent("test.sqlite").path,
            configuration: configuration)
        let appDatabase = try AppDatabase(dbPool: pool)
        let previous = AppDatabase.shared.withLock { current -> AppDatabase? in
            let saved = current
            current = appDatabase
            return saved
        }
        return (pool, directory, previous)
    }

    /// Refinement drains wait while the demo runs, so a queued demo re-tag
    /// would drain after exit and teach the user's REAL action prompt with
    /// demo content. No row may be queued.
    @Test("A demo re-tag never queues a refinement of the real action prompt")
    func demoRetagQueuesNoRefinement() async throws {
        let fixture = try install()
        defer { InstalledTestDatabaseLifetime.finish(previous: fixture.2, pool: fixture.0, directory: fixture.1) }

        await BackfillAIQueue.shared.enqueueActionRefine(ActionRefineSnapshot(
            messageStableId: "\(DemoSeed.demoAccountId):INBOX:demo-msg-5",
            accountId: DemoSeed.demoAccountId,
            subject: "Weekly digest", from: "news@example.com",
            summaryBlurb: nil, summaryTodos: nil,
            originalAction: ActionTag.archive.rawValue, userManualTag: ActionTag.delete.rawValue))
        await BackfillAIQueue.shared.cancelAllInFlight()

        let queued = try await fixture.0.read { try PendingAIRefinement.fetchCount($0) }
        #expect(queued == 0)
    }

    /// The pair to the demo case: a real account's re-tag is queued to teach
    /// its action prompt. Demo mode is held on meanwhile only so the queue
    /// defers its drain (no AI call in a test); the admission is by account.
    @Test("A real account's re-tag queues one refinement of its action prompt")
    @MainActor
    func realRetagQueuesARefinement() async throws {
        let fixture = try install()
        let store = DemoModeStore.shared
        defer {
            store._resetForTests()
            InstalledTestDatabaseLifetime.finish(previous: fixture.2, pool: fixture.0, directory: fixture.1)
        }
        store._resetForTests()
        store.isActive = true
        try #require(DemoModeStore.isDemoActive)

        let snapshot = ActionRefineSnapshot(
            messageStableId: "acc-real:INBOX:42",
            accountId: "acc-real",
            subject: "Weekly digest", from: "news@example.com",
            summaryBlurb: nil, summaryTodos: nil,
            originalAction: ActionTag.archive.rawValue, userManualTag: ActionTag.delete.rawValue)
        await BackfillAIQueue.shared.enqueueActionRefine(snapshot)
        await BackfillAIQueue.shared.cancelAllInFlight()

        let rows = try await fixture.0.read { try PendingAIRefinement.fetchAll($0) }
        try #require(rows.count == 1)
        guard rows.count == 1 else { return }
        #expect(rows[0].dedupKey == snapshot.dedupKey)
        #expect(rows[0].jobType == BackfillAIJobType.actionRefine.rawValue)
        let payload = try JSONDecoder().decode(ActionRefineSnapshot.self, from: Data(rows[0].payloadJSON.utf8))
        #expect(payload.accountId == "acc-real")
        #expect(payload.userManualTag == ActionTag.delete.rawValue)
    }
}

// MARK: - Role-aware Turn.from(ChatTurn)

@Suite("KBRefineSnapshot.Turn.from — role-aware text extraction (critical)")
struct KBRefineTurnFromTests {

    /// Build a ChatTurn with the fields that matter for this logic. Other
    /// required fields get neutral defaults.
    private func makeTurn(
        role: String,
        content: String,
        userMessage: String?,
        renderedContent: String?
    ) -> ChatTurn {
        ChatTurn(
            id: "t",
            timestamp: 0,
            role: role,
            content: content,
            userMessage: userMessage,
            type: "normal",
            chars: content.count,
            renderedContent: renderedContent,
            sessionId: nil,
            remindersSnapshot: nil,
            emailContextJSON: nil,
            thinkingContent: nil
        )
    }

    @Test("User turn with renderedContent → uses renderedContent (pills dereferenced)")
    func userWithRenderedContent() {
        let t = makeTurn(
            role: "user",
            content: "chat_converse",
            userMessage: "check [Email](7)",
            renderedContent: "check 'Invoice'"
        )
        let snap = KBRefineSnapshot.Turn.from(t)
        #expect(snap.role == "user")
        #expect(snap.text == "check 'Invoice'")
    }

    @Test("User turn without renderedContent → falls back to userMessage (NEVER content)")
    func userFallsBackToUserMessage() {
        let t = makeTurn(
            role: "user",
            content: "chat_converse",       // this MUST NOT leak to snapshot
            userMessage: "what is this?",
            renderedContent: nil
        )
        let snap = KBRefineSnapshot.Turn.from(t)
        #expect(snap.text == "what is this?")
        #expect(snap.text != "chat_converse")
    }

    @Test("User turn with nil userMessage AND nil renderedContent → empty string (not 'chat_converse')")
    func userAllNilFallsBackEmpty() {
        let t = makeTurn(
            role: "user",
            content: "chat_converse",
            userMessage: nil,
            renderedContent: nil
        )
        let snap = KBRefineSnapshot.Turn.from(t)
        #expect(snap.text == "")
        #expect(snap.text != "chat_converse")
    }

    @Test("Assistant turn with renderedContent → uses renderedContent")
    func assistantWithRenderedContent() {
        let t = makeTurn(
            role: "assistant",
            content: "done with [Email](7)",
            userMessage: nil,
            renderedContent: "done with 'Invoice'"
        )
        let snap = KBRefineSnapshot.Turn.from(t)
        #expect(snap.role == "assistant")
        #expect(snap.text == "done with 'Invoice'")
    }

    @Test("Assistant turn without renderedContent → falls back to content")
    func assistantFallsBackToContent() {
        let t = makeTurn(
            role: "assistant",
            content: "the answer is 42",
            userMessage: nil,
            renderedContent: nil
        )
        let snap = KBRefineSnapshot.Turn.from(t)
        #expect(snap.text == "the answer is 42")
    }

    @Test("Type field is preserved")
    func typePreserved() {
        let t = makeTurn(role: "assistant", content: "greet", userMessage: nil, renderedContent: nil)
        let snap = KBRefineSnapshot.Turn.from(t)
        #expect(snap.type == "normal")
    }
}

// MARK: - Drain-side reconstruction (KBRefineSnapshot.toChatTurns)

@Suite("KBRefineSnapshot.toChatTurns — role-aware reconstruction (drain-side)")
struct KBRefineToChatTurnsTests {

    @Test("User turn reconstructed with userMessage=text, content=empty")
    func userTurn() {
        let snap = KBRefineSnapshot(
            sessionId: "s1",
            enqueuedAt: 1_000,
            turns: [.init(role: "user", type: "normal", text: "hello")]
        )
        let turns = snap.toChatTurns()
        #expect(turns.count == 1)
        guard turns.count == 1 else { return }
        #expect(turns[0].role == "user")
        #expect(turns[0].userMessage == "hello")
        // Critical: NOT the template name "chat_converse" — that would be the
        // raw live-turn value; we must NOT leak it via reconstruction.
        #expect(turns[0].content == "")
    }

    @Test("Assistant turn reconstructed with content=text, userMessage=nil")
    func assistantTurn() {
        let snap = KBRefineSnapshot(
            sessionId: "s1",
            enqueuedAt: 1_000,
            turns: [.init(role: "assistant", type: "normal", text: "hi there")]
        )
        let turns = snap.toChatTurns()
        #expect(turns.count == 1)
        guard turns.count == 1 else { return }
        #expect(turns[0].role == "assistant")
        #expect(turns[0].content == "hi there")
        #expect(turns[0].userMessage == nil)
    }

    @Test("buildChatHistory-compatible: reading per role yields the original text")
    func buildChatHistoryCompat() {
        // Simulates KBRefinementService.buildChatHistory's read pattern
        // (KBRefinementService.swift:130–149). If reconstruction swapped the
        // branches, backend would see empty transcript for one role.
        let snap = KBRefineSnapshot(
            sessionId: "s1",
            enqueuedAt: 0,
            turns: [
                .init(role: "user", type: "normal", text: "question"),
                .init(role: "assistant", type: "normal", text: "answer"),
            ]
        )
        let turns = snap.toChatTurns()
        #expect(turns.count == 2)
        guard turns.count == 2 else { return }
        // buildChatHistory reads userMessage for user, content for assistant.
        let userPart = turns[0].userMessage ?? "MISSING"
        let assistantPart = turns[1].content
        #expect(userPart == "question")
        #expect(assistantPart == "answer")
    }

    @Test("Type and sessionId propagated from snapshot")
    func typeAndSessionIdPropagated() {
        let snap = KBRefineSnapshot(
            sessionId: "sess-abc",
            enqueuedAt: 0,
            turns: [.init(role: "user", type: "normal", text: "x")]
        )
        let turns = snap.toChatTurns()
        guard turns.count == 1 else { return }
        #expect(turns[0].type == "normal")
        #expect(turns[0].sessionId == "sess-abc")
    }

    @Test("Synthetic id is unique per index within the session")
    func syntheticIdUnique() {
        let snap = KBRefineSnapshot(
            sessionId: "s1",
            enqueuedAt: 0,
            turns: [
                .init(role: "user", type: "normal", text: "a"),
                .init(role: "assistant", type: "normal", text: "b"),
                .init(role: "user", type: "normal", text: "c"),
            ]
        )
        let turns = snap.toChatTurns()
        let ids = turns.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test("Timestamp propagated from enqueuedAt (Int64 millis → Double)")
    func timestampPropagation() {
        let enqueuedAt: Int64 = 1_728_000_000_000
        let snap = KBRefineSnapshot(
            sessionId: "s1",
            enqueuedAt: enqueuedAt,
            turns: [.init(role: "user", type: "normal", text: "x")]
        )
        let turns = snap.toChatTurns()
        guard turns.count == 1 else { return }
        #expect(turns[0].timestamp == Double(enqueuedAt))
    }

    @Test("chars reflects text.count, not role-specific field")
    func charsReflectsText() {
        let snap = KBRefineSnapshot(
            sessionId: "s1",
            enqueuedAt: 0,
            turns: [
                .init(role: "user", type: "normal", text: "12345"),
                .init(role: "assistant", type: "normal", text: "hello world"),
            ]
        )
        let turns = snap.toChatTurns()
        guard turns.count == 2 else { return }
        #expect(turns[0].chars == 5)
        #expect(turns[1].chars == 11)
    }
}

// MARK: - GRDB schema / migration / SQL

@Suite("pendingAIRefinement — migration + SQL")
struct PendingAIRefinementMigrationTests {

    @Test("v45 creates pendingAIRefinement table with PK on dedupKey")
    func schemaExists() throws {
        let db = try TestDatabase.make()
        let tableExists: Bool = try db.read { dbConn in
            try Bool.fetchOne(dbConn, sql: """
                SELECT EXISTS(
                    SELECT 1 FROM sqlite_master
                    WHERE type = 'table' AND name = 'pendingAIRefinement'
                )
            """) ?? false
        }
        #expect(tableExists)

        // PK on dedupKey
        let pkCols: [String] = try db.read { dbConn in
            try String.fetchAll(dbConn, sql: """
                SELECT name FROM pragma_table_info('pendingAIRefinement') WHERE pk > 0
            """)
        }
        #expect(pkCols == ["dedupKey"])
    }

    @Test("idx_pendingAIRefinement_createdAt index exists")
    func indexExists() throws {
        let db = try TestDatabase.make()
        let indexCount: Int = try db.read { dbConn in
            try Int.fetchOne(dbConn, sql: """
                SELECT COUNT(*) FROM sqlite_master
                WHERE type = 'index' AND name = 'idx_pendingAIRefinement_createdAt'
            """) ?? 0
        }
        #expect(indexCount == 1)
    }

    @Test("INSERT OR REPLACE (via PersistableRecord .replace policy) UPSERTs on dedupKey")
    func upsertInPlace() throws {
        let db = try TestDatabase.make()
        let first = ActionRefineSnapshot(
            messageStableId: "msg-1", accountId: "acc-1",
            subject: "First subject", from: "a@b.com",
            summaryBlurb: nil, summaryTodos: nil,
            originalAction: "reply", userManualTag: "archive"
        )
        let second = ActionRefineSnapshot(
            messageStableId: "msg-1", accountId: "acc-1",
            subject: "Second subject — user re-teaches", from: "a@b.com",
            summaryBlurb: nil, summaryTodos: nil,
            originalAction: "reply", userManualTag: "archive"
        )
        try db.write { dbConn in
            try PendingAIRefinement.make(first, now: 100).insert(dbConn)
            try PendingAIRefinement.make(second, now: 200).insert(dbConn)
        }

        let rows: [PendingAIRefinement] = try db.read { dbConn in
            try PendingAIRefinement.fetchAll(dbConn)
        }
        #expect(rows.count == 1)
        guard rows.count == 1 else { return }
        #expect(rows[0].dedupKey == "actionRefine:msg-1:archive")
        #expect(rows[0].createdAt == 200)

        let decoded = try rows[0].decodeActionRefine()
        #expect(decoded.subject == "Second subject — user re-teaches")
    }

    @Test("TTL sweep: DELETE WHERE createdAt < cutoff removes expired rows only")
    func ttlSweep() throws {
        let db = try TestDatabase.make()
        let fresh = ActionRefineSnapshot(
            messageStableId: "m-fresh", accountId: "a",
            subject: "", from: "", summaryBlurb: nil, summaryTodos: nil,
            originalAction: "reply", userManualTag: "archive"
        )
        let stale = ActionRefineSnapshot(
            messageStableId: "m-stale", accountId: "a",
            subject: "", from: "", summaryBlurb: nil, summaryTodos: nil,
            originalAction: "reply", userManualTag: "archive"
        )
        try db.write { dbConn in
            try PendingAIRefinement.make(fresh, now: 1_000_000).insert(dbConn)
            try PendingAIRefinement.make(stale, now: 100).insert(dbConn)
        }

        // Sweep anything older than cutoff 500.
        try db.write { dbConn in
            try dbConn.execute(
                sql: "DELETE FROM pendingAIRefinement WHERE createdAt < ?",
                arguments: [500]
            )
        }

        let keys: [String] = try db.read { dbConn in
            try String.fetchAll(dbConn, sql:
                "SELECT dedupKey FROM pendingAIRefinement")
        }
        #expect(keys == ["actionRefine:m-fresh:archive"])
    }

    @Test("FIFO load: ORDER BY createdAt ASC returns oldest first")
    func fifoOrdering() throws {
        let db = try TestDatabase.make()
        let a = ActionRefineSnapshot(
            messageStableId: "a", accountId: "x",
            subject: "", from: "", summaryBlurb: nil, summaryTodos: nil,
            originalAction: "reply", userManualTag: "archive"
        )
        let b = ActionRefineSnapshot(
            messageStableId: "b", accountId: "x",
            subject: "", from: "", summaryBlurb: nil, summaryTodos: nil,
            originalAction: "reply", userManualTag: "archive"
        )
        let c = ActionRefineSnapshot(
            messageStableId: "c", accountId: "x",
            subject: "", from: "", summaryBlurb: nil, summaryTodos: nil,
            originalAction: "reply", userManualTag: "archive"
        )
        try db.write { dbConn in
            try PendingAIRefinement.make(a, now: 300).insert(dbConn)
            try PendingAIRefinement.make(b, now: 100).insert(dbConn)
            try PendingAIRefinement.make(c, now: 200).insert(dbConn)
        }
        let keys: [String] = try db.read { dbConn in
            try String.fetchAll(dbConn, sql: """
                SELECT dedupKey FROM pendingAIRefinement ORDER BY createdAt ASC
            """)
        }
        #expect(keys == [
            "actionRefine:b:archive",
            "actionRefine:c:archive",
            "actionRefine:a:archive",
        ])
    }

    @Test("Index is used for ORDER BY createdAt (EXPLAIN QUERY PLAN)")
    func indexCoverage() throws {
        let db = try TestDatabase.make()
        let plan: [String] = try db.read { dbConn in
            try Row.fetchAll(dbConn, sql: """
                EXPLAIN QUERY PLAN
                SELECT dedupKey FROM pendingAIRefinement ORDER BY createdAt ASC
            """).map { row in
                row["detail"] as String
            }
        }
        let combined = plan.joined(separator: " | ")
        // SQLite should indicate index usage by name.
        #expect(combined.contains("idx_pendingAIRefinement_createdAt"))
    }
}
