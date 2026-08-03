/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Testing
@testable import TabMail

/// T4.V10 — two invariants of chat-session binding and chat-turn garbage collection.
///
/// (a) A chat session resolves its message WITHIN THE SESSION'S ACCOUNT. The key is
///     unchanged and still RFC-822-based (content identity: same content ⇒ same key);
///     what is added is a SCOPE. Before it, `rfc822MessageId` was searched globally,
///     so a session opened in account A could bind to account B's copy of the same
///     message — a wrong-message read.
///
/// (b) Background GC never deletes the `ChatTurn`s / `ChatHistoryTurn`s of a compose
///     the user currently has OPEN. Those are authored user bytes on screen.
///
/// Every exemption assertion is paired with its UNREGISTERED control, so nothing can
/// pass vacuously and the exemption is proven NOT universal (an exemption that
/// swallowed the whole sweep would be an eviction leak, not a guard).
///
/// PORT references — `v2final` (`e28dd4edb33cfb77a0d069de48e136f6ad92cd0c`):
/// `ChatStore.findByStableId(_:accountId:db:)`,
/// `ChatStore.extractAccountAndStableId(from:)`,
/// `ChatStore.enforceTurnBudgets(db:activeComposeSessions:)`,
/// `ChatStore.evictComposeSessionsImpl`, `ChatStore.evictHistoryBeyondCapImpl`,
/// and `TabMail/Services/AI/DraftSessionRegistry.swift` (commit `d2f0c96a3`).

// MARK: - (a) Account-scoped stable-id resolution

@Suite("ChatStore account-scoped message resolution")
struct ChatStoreAccountScopedResolutionTests {

    /// Two accounts that both hold a message carrying the SAME RFC 822 Message-ID —
    /// the collision the scope exists to disambiguate.
    private func makeDB() throws -> DatabaseQueue {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1", email: "acc1@example.com")
        try TestDatabase.insertAccount(db, id: "acc2", email: "acc2@example.com")
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")
        try TestDatabase.insertFolder(db, name: "Archive", path: "Archive", role: .archive, accountId: "acc1")
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc2")
        return db
    }

    // MARK: Session-key parsing (the scope's source)

    @Test("A msg-detail session id yields its account and a stable id that may contain colons")
    func sessionKeyParsesAccountAndStableId() throws {
        let plain = try #require(ChatStore.extractAccountAndStableId(from: "msg:acc1:x@example.com"))
        #expect(plain.accountId == "acc1")
        #expect(plain.stableId == "x@example.com")

        // The demo prefix is stripped once, and the split is on the FIRST colon after
        // "msg:" so a stable id that itself contains colons round-trips intact.
        let demo = try #require(ChatStore.extractAccountAndStableId(from: "demo:msg:acc1:x:y"))
        #expect(demo.accountId == "acc1")
        #expect(demo.stableId == "x:y")
    }

    @Test("A session id with no account or no stable component yields no scope at all")
    func sessionKeyRejectsIncompleteForms() {
        // An empty account would silently widen the scope back to "any account".
        #expect(ChatStore.extractAccountAndStableId(from: "msg::x@example.com") == nil)
        #expect(ChatStore.extractAccountAndStableId(from: "msg:acc1:") == nil)
        #expect(ChatStore.extractAccountAndStableId(from: "msg:acc1") == nil)
        #expect(ChatStore.extractAccountAndStableId(from: "compose:new:abc") == nil)
        #expect(ChatStore.extractAccountAndStableId(from: "inbox") == nil)
    }

    // MARK: findByStableId

    @Test("findByStableId never returns another account's message with the identical Message-ID")
    func findByStableIdRefusesTheOtherAccount() throws {
        let db = try makeDB()
        // ONLY account B holds the message. Account A has no copy at all.
        let inB = try TestDatabase.insertMessageHeader(
            db, messageId: "11", folderId: "acc2:INBOX", accountId: "acc2",
            folderPath: "INBOX", isInInbox: true, rfc822MessageId: "shared@example.com")

        let hit = try db.read { try ChatStore.findByStableId("shared@example.com", accountId: "acc1", db: $0) }
        #expect(hit == nil)
        #expect(hit?.id != inB.id)
    }

    @Test("findByStableId returns the session account's own message with that Message-ID")
    func findByStableIdResolvesWithinTheSessionAccount() throws {
        let db = try makeDB()
        // BOTH accounts hold the same Message-ID; each lookup must pick its own.
        let inA = try TestDatabase.insertMessageHeader(
            db, messageId: "11", folderId: "acc1:INBOX", accountId: "acc1",
            folderPath: "INBOX", isInInbox: true, rfc822MessageId: "shared@example.com")
        let inB = try TestDatabase.insertMessageHeader(
            db, messageId: "22", folderId: "acc2:INBOX", accountId: "acc2",
            folderPath: "INBOX", isInInbox: true, rfc822MessageId: "shared@example.com")

        let hitA = try db.read { try ChatStore.findByStableId("shared@example.com", accountId: "acc1", db: $0) }
        let hitB = try db.read { try ChatStore.findByStableId("shared@example.com", accountId: "acc2", db: $0) }
        #expect(hitA?.id == inA.id)
        #expect(hitA?.accountId == "acc1")
        // Two-sided: the scope selects, it does not merely suppress.
        #expect(hitB?.id == inB.id)
        #expect(hitB?.accountId == "acc2")
    }

    @Test("findByStableId picks the Inbox sibling deterministically among same-account copies")
    func findByStableIdPrefersTheInboxSibling() throws {
        let db = try makeDB()
        // Archive copy inserted FIRST so an undefined pick would return it.
        _ = try TestDatabase.insertMessageHeader(
            db, messageId: "10", folderId: "acc1:Archive", accountId: "acc1",
            folderPath: "Archive", isInInbox: false, rfc822MessageId: "copies@example.com")
        let inbox = try TestDatabase.insertMessageHeader(
            db, messageId: "20", folderId: "acc1:INBOX", accountId: "acc1",
            folderPath: "INBOX", isInInbox: true, rfc822MessageId: "copies@example.com")

        let hit = try db.read { try ChatStore.findByStableId("copies@example.com", accountId: "acc1", db: $0) }
        #expect(hit?.id == inbox.id)
        #expect(hit?.isInInbox == true)
    }

    // MARK: resolveMessageHeaderId (consumer 1)

    @Test("A stale primary key never resolves onto another account's copy of the same message")
    func resolveRefusesTheOtherAccount() throws {
        let db = try makeDB()
        // Account B holds the message; account A's captured PK is long gone.
        let inB = try TestDatabase.insertMessageHeader(
            db, messageId: "11", folderId: "acc2:INBOX", accountId: "acc2",
            folderPath: "INBOX", isInInbox: true, rfc822MessageId: "shared@example.com")

        let resolved = try db.read {
            try ChatStore.resolveMessageHeaderId(
                originalId: "acc1:INBOX:99",
                sessionId: "msg:acc1:shared@example.com",
                db: $0)
        }
        #expect(resolved == nil)
        #expect(resolved != inB.id)
    }

    @Test("A stale primary key still resolves onto the same account's moved message")
    func resolveStillFollowsTheMoveWithinTheAccount() throws {
        let db = try makeDB()
        // The message moved INBOX → Archive inside account A (its PK changed), and
        // account B happens to hold the same Message-ID.
        let moved = try TestDatabase.insertMessageHeader(
            db, messageId: "20", folderId: "acc1:Archive", accountId: "acc1",
            folderPath: "Archive", isInInbox: false, rfc822MessageId: "shared@example.com")
        _ = try TestDatabase.insertMessageHeader(
            db, messageId: "11", folderId: "acc2:INBOX", accountId: "acc2",
            folderPath: "INBOX", isInInbox: true, rfc822MessageId: "shared@example.com")

        let resolved = try db.read {
            try ChatStore.resolveMessageHeaderId(
                originalId: "acc1:INBOX:20",
                sessionId: "msg:acc1:shared@example.com",
                db: $0)
        }
        // Non-vacuity: the scoped lookup still finds the RIGHT row after a move.
        #expect(resolved == moved.id)
    }

    // MARK: isMessageInInbox (consumer 2 — msg-detail session eviction)

    @Test("Session eviction never reads inbox membership from another account's copy")
    func inboxMembershipRefusesTheOtherAccount() throws {
        let db = try makeDB()
        // The message is in account B's INBOX. Account A has no copy.
        _ = try TestDatabase.insertMessageHeader(
            db, messageId: "11", folderId: "acc2:INBOX", accountId: "acc2",
            folderPath: "INBOX", isInInbox: true, rfc822MessageId: "shared@example.com")
        try db.write { try Self.anchorTurn(sessionId: "msg:acc1:shared@example.com").insert($0) }

        let inInbox = try db.read { try ChatStore.isMessageInInbox(sessionId: "msg:acc1:shared@example.com", db: $0) }
        #expect(inInbox == false)
    }

    @Test("Session eviction still sees the session account's own inbox copy")
    func inboxMembershipFindsTheSameAccountCopy() throws {
        let db = try makeDB()
        _ = try TestDatabase.insertMessageHeader(
            db, messageId: "11", folderId: "acc1:INBOX", accountId: "acc1",
            folderPath: "INBOX", isInInbox: true, rfc822MessageId: "shared@example.com")
        try db.write { try Self.anchorTurn(sessionId: "msg:acc1:shared@example.com").insert($0) }

        // Non-vacuity: a session whose message IS in its own inbox stays exempt.
        let inInbox = try db.read { try ChatStore.isMessageInInbox(sessionId: "msg:acc1:shared@example.com", db: $0) }
        #expect(inInbox == true)
    }

    /// A msg-detail session's first turn carrying NO `emailContextJSON`, so resolution
    /// must go through the session key's stable-identity anchor (the scoped path).
    private static func anchorTurn(sessionId: String) -> ChatTurn {
        ChatTurn(
            id: "anchor-\(UUID().uuidString)", timestamp: Date().timeIntervalSince1970 * 1000,
            role: "user", content: "chat_converse", userMessage: "what is this about",
            type: "normal", chars: 20, renderedContent: nil, sessionId: sessionId,
            remindersSnapshot: nil, emailContextJSON: nil, thinkingContent: nil)
    }
}

// MARK: - (b) Budget sweeps exempt an open compose

/// Drives the REAL `ChatStore.enforceTurnBudgets` seam that `appendTurn` calls, so the
/// exemption is pinned at the sweep itself rather than at a re-implementation.
@Suite("ChatStore turn-budget sweep active-compose guard")
struct ChatStoreTurnBudgetActiveGuardTests {

    private let openSession = "compose:new:open-\(UUID().uuidString)"
    private let closedSession = "compose:new:closed-\(UUID().uuidString)"

    private func turn(_ id: String, ts: Double, sessionId: String?, chars: Int) -> ChatTurn {
        ChatTurn(
            id: id, timestamp: ts, role: "user",
            content: String(repeating: "x", count: max(1, chars)),
            userMessage: "authored \(id)", type: "normal", chars: chars,
            renderedContent: nil, sessionId: sessionId, remindersSnapshot: nil,
            emailContextJSON: nil, thinkingContent: nil)
    }

    /// One turn OVER the count budget, with the open compose's turn as the globally
    /// OLDEST — i.e. exactly the FIFO victim the guard has to spare.
    private func seedOverCountBudget(_ db: DatabaseQueue) throws {
        let total = ChatStore.maxExchanges * 2 + 2 // two over the count budget
        try db.write { connection in
            try turn("open-oldest", ts: 0, sessionId: openSession, chars: 1).insert(connection)
            try turn("closed-next", ts: 1, sessionId: closedSession, chars: 1).insert(connection)
            for index in 2..<total {
                try turn("filler-\(index)", ts: Double(index), sessionId: "msg:acc1:filler@example.com", chars: 1)
                    .insert(connection)
            }
        }
    }

    @Test("The turn-count budget sweep spares the oldest turns of an open compose")
    func countBudgetSparesTheOpenCompose() throws {
        let db = try TestDatabase.make()
        try seedOverCountBudget(db)

        let evicted = try db.write {
            try ChatStore.enforceTurnBudgets(db: $0, activeComposeSessions: [openSession])
        }
        let evictedIds = Set(evicted.map(\.id))

        #expect(!evictedIds.contains("open-oldest"))
        #expect(try db.read { try ChatTurn.fetchOne($0, key: "open-oldest") } != nil)
        // The sweep still did its job on the next-oldest EVICTABLE turn, so the
        // exemption skipped a row rather than aborting the sweep.
        #expect(evictedIds.contains("closed-next"))
        #expect(evicted.count == 2)
    }

    @Test("The turn-count budget sweep still evicts that same compose once it is closed")
    func countBudgetEvictsTheClosedCompose() throws {
        let db = try TestDatabase.make()
        try seedOverCountBudget(db)

        // Identical fixture, EMPTY active set — the control that proves the exemption
        // is not universal and that the fixture really is over budget.
        let evicted = try db.write {
            try ChatStore.enforceTurnBudgets(db: $0, activeComposeSessions: [])
        }
        let evictedIds = Set(evicted.map(\.id))

        #expect(evictedIds.contains("open-oldest"))
        #expect(evictedIds.contains("closed-next"))
        #expect(try db.read { try ChatTurn.fetchOne($0, key: "open-oldest") } == nil)
    }

    /// Three turns, each on its own equal to the WHOLE character budget, so the char
    /// sweep must evict two of them; the open compose owns the oldest.
    private func seedOverCharBudget(_ db: DatabaseQueue) throws {
        let wholeBudget = ChatStore.maxExchanges * ChatStore.charsPerExchange
        try db.write { connection in
            try turn("open-old", ts: 0, sessionId: openSession, chars: wholeBudget).insert(connection)
            try turn("closed-mid", ts: 1, sessionId: closedSession, chars: wholeBudget).insert(connection)
            try turn("closed-new", ts: 2, sessionId: closedSession, chars: wholeBudget).insert(connection)
        }
    }

    @Test("The character budget sweep spares an open compose's turn even as the oldest")
    func charBudgetSparesTheOpenCompose() throws {
        let db = try TestDatabase.make()
        try seedOverCharBudget(db)

        let evicted = try db.write {
            try ChatStore.enforceTurnBudgets(db: $0, activeComposeSessions: [openSession])
        }
        let evictedIds = Set(evicted.map(\.id))

        #expect(!evictedIds.contains("open-old"))
        #expect(try db.read { try ChatTurn.fetchOne($0, key: "open-old") } != nil)
        // The sweep consumed the evictable rows instead of stalling on the exempt one.
        #expect(evictedIds.contains("closed-mid"))
        #expect(evictedIds.contains("closed-new"))
    }

    @Test("The character budget sweep still evicts that turn once the compose is closed")
    func charBudgetEvictsTheClosedCompose() throws {
        let db = try TestDatabase.make()
        try seedOverCharBudget(db)

        let evicted = try db.write {
            try ChatStore.enforceTurnBudgets(db: $0, activeComposeSessions: [])
        }
        let evictedIds = Set(evicted.map(\.id))

        #expect(evictedIds.contains("open-old"))
        #expect(try db.read { try ChatTurn.fetchOne($0, key: "open-old") } == nil)
    }
}

// MARK: - (b) Background maintenance sweeps exempt an open compose

/// `.processGlobalState` + `.serialized`: these drive the production sweeps, which read
/// the process-wide `DraftSessionRegistry.shared`. Every registration is balanced by a
/// `defer` unregister.
@Suite("ChatStore maintenance sweeps active-compose guard", .serialized, .processGlobalState)
struct ChatStoreMaintenanceActiveGuardTests {

    private func makePool() throws -> (pool: DatabasePool, directory: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("chatstore-active-guard-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        let pool = try DatabasePool(
            path: directory.appendingPathComponent("test.sqlite").path,
            configuration: configuration)
        try AppDatabase.runMigrations(on: pool)
        try pool.write { db in
            var account = Account(
                emailAddress: "acc1@example.com", displayName: "Test", provider: .outlook)
            account.id = "acc1"
            try account.insert(db)
        }
        return (pool, directory)
    }

    /// Milliseconds since epoch, `daysAgo` days back from now. Derived from `Date()` so
    /// the fixture can never go stale against a TTL.
    private func msAgo(days: Double) -> Double {
        (Date().timeIntervalSince1970 - days * 86400) * 1000
    }

    private func turn(_ id: String, ts: Double, sessionId: String) -> ChatTurn {
        ChatTurn(
            id: id, timestamp: ts, role: "user", content: "compose_edit",
            userMessage: "authored \(id)", type: "normal", chars: 12,
            renderedContent: nil, sessionId: sessionId, remindersSnapshot: nil,
            emailContextJSON: nil, thinkingContent: nil)
    }

    private func historyTurn(_ id: String, ts: Double, sessionId: String) -> ChatHistoryTurn {
        ChatHistoryTurn(
            id: id, timestamp: ts, role: "user", content: "authored \(id)",
            userMessage: "authored \(id)", sessionId: sessionId, chars: 12, type: "normal")
    }

    // MARK: Compose TTL sweep

    @Test("The compose TTL sweep keeps a reopened compose's expired turns while it is open")
    func ttlSweepSparesTheOpenCompose() throws {
        let fixture = try makePool()
        defer { TestDatabaseTeardown.retire(pool: fixture.pool, directory: fixture.directory) }
        let openId = "new:open-\(UUID().uuidString)"
        let closedId = "new:closed-\(UUID().uuidString)"
        // Both sessions' turns are FAR past a 1-day TTL — no race needed, the reopened
        // compose is simply older than the sweep's cutoff.
        try fixture.pool.write { db in
            try turn("open-turn", ts: msAgo(days: 30), sessionId: "compose:\(openId)").insert(db)
            try turn("closed-turn", ts: msAgo(days: 30), sessionId: "compose:\(closedId)").insert(db)
        }

        DraftSessionRegistry.shared.register(openId)
        defer { DraftSessionRegistry.shared.unregister(openId) }

        _ = try ChatStore.shared.evictComposeSessionsSync(
            dbPool: PrioritizedDatabase(pool: fixture.pool), ttlDays: 1)

        let state = try fixture.pool.read { db in
            (open: try ChatTurn.fetchOne(db, key: "open-turn"),
             closed: try ChatTurn.fetchOne(db, key: "closed-turn"))
        }
        #expect(state.open?.userMessage == "authored open-turn")
        // Control: the identically-expired CLOSED compose is still reclaimed.
        #expect(state.closed == nil)
    }

    @Test("The compose TTL sweep reclaims the same session once the compose closes")
    func ttlSweepEvictsAfterTheComposeCloses() throws {
        let fixture = try makePool()
        defer { TestDatabaseTeardown.retire(pool: fixture.pool, directory: fixture.directory) }
        let draftId = "new:reopened-\(UUID().uuidString)"
        try fixture.pool.write { db in
            try turn("reopened-turn", ts: msAgo(days: 30), sessionId: "compose:\(draftId)").insert(db)
        }

        // Register and unregister — the exemption must be released, never sticky.
        DraftSessionRegistry.shared.register(draftId)
        DraftSessionRegistry.shared.unregister(draftId)
        #expect(!DraftSessionRegistry.shared.isActive(draftId))

        _ = try ChatStore.shared.evictComposeSessionsSync(
            dbPool: PrioritizedDatabase(pool: fixture.pool), ttlDays: 1)

        #expect(try fixture.pool.read { try ChatTurn.fetchOne($0, key: "reopened-turn") } == nil)
    }

    // MARK: Memory cap sweep

    @Test("The memory cap skips an open compose's oldest history and evicts the next one instead")
    func historyCapSparesTheOpenCompose() throws {
        let fixture = try makePool()
        defer { TestDatabaseTeardown.retire(pool: fixture.pool, directory: fixture.directory) }
        let openId = "new:open-\(UUID().uuidString)"
        // The OLDEST history row belongs to the open compose — the cap's first victim.
        try fixture.pool.write { db in
            try historyTurn("h-open", ts: msAgo(days: 3), sessionId: "compose:\(openId)").insert(db)
            try historyTurn("h-closed", ts: msAgo(days: 2), sessionId: "msg:acc1:a@example.com").insert(db)
            try historyTurn("h-newest", ts: msAgo(days: 1), sessionId: "msg:acc1:b@example.com").insert(db)
        }

        DraftSessionRegistry.shared.register(openId)
        defer { DraftSessionRegistry.shared.unregister(openId) }

        // cap 2, total 3 → evict exactly one.
        let evicted = try ChatStore.shared.evictHistoryBeyondCapSync(
            dbPool: PrioritizedDatabase(pool: fixture.pool), maxTurns: 2)

        #expect(evicted.count == 1)
        guard evicted.count == 1 else { return }
        // The oldest EVICTABLE row went instead of the exempt one.
        #expect(evicted[0] == "h-closed")
        #expect(try fixture.pool.read { try ChatHistoryTurn.fetchOne($0, key: "h-open") } != nil)
    }

    @Test("The memory cap evicts the oldest history once no compose is open")
    func historyCapEvictsTheOldestWhenNothingIsOpen() throws {
        let fixture = try makePool()
        defer { TestDatabaseTeardown.retire(pool: fixture.pool, directory: fixture.directory) }
        let closedId = "new:closed-\(UUID().uuidString)"
        try fixture.pool.write { db in
            try historyTurn("h-open", ts: msAgo(days: 3), sessionId: "compose:\(closedId)").insert(db)
            try historyTurn("h-closed", ts: msAgo(days: 2), sessionId: "msg:acc1:a@example.com").insert(db)
            try historyTurn("h-newest", ts: msAgo(days: 1), sessionId: "msg:acc1:b@example.com").insert(db)
        }

        // Nothing registered — the control that proves the exemption is not universal.
        let evicted = try ChatStore.shared.evictHistoryBeyondCapSync(
            dbPool: PrioritizedDatabase(pool: fixture.pool), maxTurns: 2)

        #expect(evicted.count == 1)
        guard evicted.count == 1 else { return }
        #expect(evicted[0] == "h-open")
        #expect(try fixture.pool.read { try ChatHistoryTurn.fetchOne($0, key: "h-open") } == nil)
    }
}
