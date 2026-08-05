/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Synchronization
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

// MARK: - (c) The register-vs-commit interleaving, at all three ChatStore sites

/// Fires ONE `DraftSessionRegistry.register` from INSIDE a `ChatStore` eviction's own
/// write transaction, by hooking SQLite's statement trace on the pool's connections.
///
/// This reproduces the interleaving the 2026-08-05 fix closes: a ComposeView opening
/// AFTER the sweep sampled `activeComposeSessionIds()` but BEFORE its write commits.
/// Nothing else in this file can express it — every other test here registers before
/// the sweep starts (or passes an explicit set), which the pre-fix and post-fix code
/// handle identically.
///
/// Armed explicitly, so the fixture's own inserts (which run on the same traced
/// connections) cannot trip it early, and it fires at most once. `marker` selects a
/// statement the target executes INSIDE its transaction but BEFORE it takes its live
/// registry read, so the registration always lands in the window under test.
private final class ChatStoreLateComposeHook: Sendable {
    private let armed = Mutex<Bool>(false)
    private let fired = Mutex<Bool>(false)
    private let draftId: String
    private let marker: @Sendable (String) -> Bool

    init(draftId: String, marker: @escaping @Sendable (String) -> Bool) {
        self.draftId = draftId
        self.marker = marker
    }

    /// Arm after fixture setup, immediately before the sweep.
    func arm() { armed.withLock { $0 = true } }

    /// True once the registration actually landed — every test asserts this, so a hook
    /// that silently never fired cannot make the invariant pass vacuously.
    var didFire: Bool { fired.withLock { $0 } }

    func observe(_ sql: String) {
        guard marker(sql) else { return }
        let shouldFire = armed.withLock { flag -> Bool in
            guard flag else { return false }
            flag = false
            return true
        }
        guard shouldFire else { return }
        DraftSessionRegistry.shared.register(draftId)
        fired.withLock { $0 = true }
    }
}

/// THE INVARIANT, one test per `ChatStore` deletion site: **chat turns belonging to a
/// compose session that registers before the eviction transaction commits are still
/// present after the eviction returns.** Asserted on the persisted rows, never on what
/// some set contained.
///
/// All three sites read `DraftSessionRegistry.shared.activeComposeSessionIds()` BEFORE
/// opening `dbPool.write` and consumed that frozen answer inside it, so a compose that
/// opened during the sweep was invisible and its authored turns were deleted:
/// `enforceTurnBudgets` (reached from the ORDINARY `appendTurn` path),
/// `evictHistoryBeyondCapImpl`, and `evictComposeSessionsImpl`. That is the shape
/// `DraftSessionRegistry`'s doc header forbids and that `DraftStore.evictImpl` carried
/// until `eda55f4ca`. Three sites, three tests — one test would be a census that
/// inherited its own search shape.
///
/// `.processGlobalState` + `.serialized`: these drive the production sweeps, which read
/// the process-wide `DraftSessionRegistry.shared`. Every registration is balanced.
@Suite("ChatStore eviction consults the live compose registry", .serialized, .processGlobalState)
struct ChatStoreLiveComposeRegistryGuardTests {

    private func makeHookedPool(
        hook: ChatStoreLateComposeHook
    ) throws -> (pool: DatabasePool, directory: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("chatstore-live-registry-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        configuration.prepareDatabase { db in
            db.trace(options: .statement) { event in
                hook.observe(event.description)
            }
        }
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

    private func turn(_ id: String, ts: Double, sessionId: String?, chars: Int = 12) -> ChatTurn {
        ChatTurn(
            id: id, timestamp: ts, role: "user",
            content: String(repeating: "x", count: max(1, chars)),
            userMessage: "authored \(id)", type: "normal", chars: chars,
            renderedContent: nil, sessionId: sessionId, remindersSnapshot: nil,
            emailContextJSON: nil, thinkingContent: nil)
    }

    private func historyTurn(_ id: String, ts: Double, sessionId: String) -> ChatHistoryTurn {
        ChatHistoryTurn(
            id: id, timestamp: ts, role: "user", content: "authored \(id)",
            userMessage: "authored \(id)", sessionId: sessionId, chars: 12, type: "normal")
    }

    // MARK: Site 1 — the turn-budget sweep on the ordinary append path

    /// `appendTurn` samples the registry, opens `dbPool.write`, inserts the new turn and
    /// its `chatHistory` twin, and only then runs the budget sweep. The hook therefore
    /// fires on that insert: inside the transaction, ahead of the deletion decision, and
    /// with the sampled set (the `activeComposeSessions` argument) still empty — exactly
    /// what `appendTurn` computed before the compose existed.
    @Test("A compose that opens inside the turn-budget transaction keeps its authored turns")
    func composeRegisteredInsideTurnBudgetTransactionKeepsItsTurns() throws {
        let victimDraftId = "new:budget-victim-\(UUID().uuidString)"
        let victimSession = "compose:\(victimDraftId)"
        let controlSession = "compose:new:budget-control-\(UUID().uuidString)"

        let hook = ChatStoreLateComposeHook(draftId: victimDraftId) { sql in
            sql.contains("INSERT INTO") && sql.contains("chatTurn")
        }
        let fixture = try makeHookedPool(hook: hook)
        defer { TestDatabaseTeardown.retire(pool: fixture.pool, directory: fixture.directory) }
        defer { DraftSessionRegistry.shared.unregister(victimDraftId) }

        // One turn OVER the count budget before the append, so the append pushes it two
        // over and the sweep must delete exactly two. The victim compose owns the
        // globally OLDEST turn — the FIFO victim the guard has to spare.
        let seeded = ChatStore.maxExchanges * 2 + 1
        try fixture.pool.write { db in
            try turn("budget-victim", ts: 0, sessionId: victimSession).insert(db)
            try turn("budget-control", ts: 1, sessionId: controlSession).insert(db)
            for index in 2..<seeded {
                try turn("budget-filler-\(index)", ts: Double(index),
                         sessionId: "msg:acc1:filler@example.com").insert(db)
            }
        }

        // Precondition: NOT open when the sweep begins. This is what the pre-transaction
        // sample would have missed, and it is the whole point of the test.
        #expect(!DraftSessionRegistry.shared.isActive(victimDraftId))
        hook.arm()

        // Mirrors `appendTurn`'s write block: insert, then sweep with the set that was
        // sampled BEFORE the transaction opened (empty — no compose was open then).
        let evicted = try fixture.pool.write { db -> [ChatTurn] in
            try turn("budget-appended", ts: Double(seeded), sessionId: "msg:acc1:filler@example.com")
                .insert(db)
            return try ChatStore.enforceTurnBudgets(db: db, activeComposeSessions: [])
        }

        // Harness non-vacuity: no interleaving ⇒ the assertions below prove nothing.
        #expect(hook.didFire)
        #expect(DraftSessionRegistry.shared.isActive(victimDraftId))

        let state = try fixture.pool.read { db in
            (victim: try ChatTurn.fetchOne(db, key: "budget-victim"),
             control: try ChatTurn.fetchOne(db, key: "budget-control"))
        }
        // THE INVARIANT — the open compose's authored turn survives the sweep.
        #expect(state.victim?.userMessage == "authored budget-victim")
        // …and the sweep still reclaimed its quota from the next-oldest EVICTABLE turns,
        // so the exemption skipped a row rather than disabling eviction.
        #expect(state.control == nil)
        #expect(evicted.count == 2)
    }

    // MARK: Site 2 — the chatHistory memory cap

    /// `evictHistoryBeyondCapImpl`'s first statement inside its write transaction is the
    /// `COUNT(*)` probe, which runs before it derives the exemption list — so the hook
    /// lands the registration in the window between the pre-transaction sample and the
    /// deletion decision.
    @Test("A compose that opens inside the memory-cap transaction keeps its history turns")
    func composeRegisteredInsideHistoryCapTransactionKeepsItsHistory() throws {
        let victimDraftId = "new:cap-victim-\(UUID().uuidString)"

        let hook = ChatStoreLateComposeHook(draftId: victimDraftId) { sql in
            sql.contains("chatHistory") && sql.contains("COUNT(")
        }
        let fixture = try makeHookedPool(hook: hook)
        defer { TestDatabaseTeardown.retire(pool: fixture.pool, directory: fixture.directory) }
        defer { DraftSessionRegistry.shared.unregister(victimDraftId) }

        // The OLDEST history row belongs to the compose that is about to open — the
        // cap's first victim.
        try fixture.pool.write { db in
            try historyTurn("cap-victim", ts: msAgo(days: 3),
                            sessionId: "compose:\(victimDraftId)").insert(db)
            try historyTurn("cap-control", ts: msAgo(days: 2),
                            sessionId: "msg:acc1:a@example.com").insert(db)
            try historyTurn("cap-newest", ts: msAgo(days: 1),
                            sessionId: "msg:acc1:b@example.com").insert(db)
        }

        #expect(!DraftSessionRegistry.shared.isActive(victimDraftId))
        hook.arm()

        // cap 2, total 3 → evict exactly one.
        let evicted = try ChatStore.shared.evictHistoryBeyondCapSync(
            dbPool: PrioritizedDatabase(pool: fixture.pool), maxTurns: 2)

        #expect(hook.didFire)
        #expect(DraftSessionRegistry.shared.isActive(victimDraftId))

        let state = try fixture.pool.read { db in
            (victim: try ChatHistoryTurn.fetchOne(db, key: "cap-victim"),
             control: try ChatHistoryTurn.fetchOne(db, key: "cap-control"),
             newest: try ChatHistoryTurn.fetchOne(db, key: "cap-newest"))
        }
        // THE INVARIANT — the newly-open compose's history survives.
        #expect(state.victim?.userMessage == "authored cap-victim")
        // …and so does the control, because a registration anywhere inside the
        // transaction now ROLLS THE WHOLE SWEEP BACK rather than deleting around the
        // new compose (the generation guard, matching `DraftStore.evictImpl`). The
        // sweep's selection was taken against a registry reading that is no longer
        // current, and re-running it costs nothing. Non-vacuity for THIS direction —
        // that the cap is still enforced at all — is carried by the second pass below.
        #expect(state.control != nil)
        #expect(state.newest != nil)
        #expect(evicted.isEmpty, "a rolled-back sweep must report that it evicted nothing")

        // THE MIRROR IMAGE — a rollback-on-registration must not starve the cap. The
        // victim compose is STILL OPEN and untouched; only `register` bumps the
        // generation, so this second pass observes an unchanged reading, completes,
        // and reclaims the oldest EVICTABLE row.
        let secondPass = try ChatStore.shared.evictHistoryBeyondCapSync(
            dbPool: PrioritizedDatabase(pool: fixture.pool), maxTurns: 2)
        #expect(secondPass == ["cap-control"],
                """
                the memory cap never completed while a compose was open — the generation \
                guard is tripping on steady state, so chatHistory grows without bound for \
                as long as the user has any compose on screen
                """)
        let after = try fixture.pool.read { db in
            (victim: try ChatHistoryTurn.fetchOne(db, key: "cap-victim"),
             control: try ChatHistoryTurn.fetchOne(db, key: "cap-control"))
        }
        #expect(after.victim != nil, "the open compose's history is still exempt on the second pass")
        #expect(after.control == nil)
    }

    // MARK: Site 3 — the compose-session TTL sweep

    /// `evictComposeSessionsImpl`'s first statement inside its write transaction is the
    /// expired-`compose:%` session SELECT, which runs before the loop takes any live
    /// registry read — so the hook lands the registration inside the window.
    @Test("A compose that opens inside the TTL-sweep transaction keeps its session turns")
    func composeRegisteredInsideTTLSweepTransactionKeepsItsSession() throws {
        let victimDraftId = "new:ttl-victim-\(UUID().uuidString)"
        let controlDraftId = "new:ttl-control-\(UUID().uuidString)"

        let hook = ChatStoreLateComposeHook(draftId: victimDraftId) { sql in
            sql.contains("compose:%")
        }
        let fixture = try makeHookedPool(hook: hook)
        defer { TestDatabaseTeardown.retire(pool: fixture.pool, directory: fixture.directory) }
        defer { DraftSessionRegistry.shared.unregister(victimDraftId) }

        // Both sessions are FAR past a 1-day TTL, so both are sweep candidates and the
        // only thing separating them is the registration.
        try fixture.pool.write { db in
            try turn("ttl-victim-turn", ts: msAgo(days: 30),
                     sessionId: "compose:\(victimDraftId)").insert(db)
            try turn("ttl-control-turn", ts: msAgo(days: 30),
                     sessionId: "compose:\(controlDraftId)").insert(db)
        }

        #expect(!DraftSessionRegistry.shared.isActive(victimDraftId))
        hook.arm()

        let evicted = try ChatStore.shared.evictComposeSessionsSync(
            dbPool: PrioritizedDatabase(pool: fixture.pool), ttlDays: 1)

        #expect(hook.didFire)
        #expect(DraftSessionRegistry.shared.isActive(victimDraftId))

        let state = try fixture.pool.read { db in
            (victim: try ChatTurn.fetchOne(db, key: "ttl-victim-turn"),
             control: try ChatTurn.fetchOne(db, key: "ttl-control-turn"))
        }
        // THE INVARIANT — the newly-open compose keeps its authored turns.
        #expect(state.victim?.userMessage == "authored ttl-victim-turn")
        // …and so does the identically-expired control session, because a registration
        // anywhere inside the transaction now rolls the WHOLE sweep back rather than
        // sweeping around the new compose. Non-vacuity for that direction is the
        // second pass below.
        #expect(state.control != nil)
        #expect(evicted == 0, "a rolled-back sweep must report that it evicted nothing")

        // THE MIRROR IMAGE — the TTL sweep must not starve while a compose is merely
        // open. The victim is still registered and untouched, so the generation is
        // unchanged and this pass completes.
        let secondPass = try ChatStore.shared.evictComposeSessionsSync(
            dbPool: PrioritizedDatabase(pool: fixture.pool), ttlDays: 1)
        #expect(secondPass == 1,
                """
                the TTL sweep never completed while a compose was open — the generation \
                guard is tripping on steady state, so expired compose sessions accumulate \
                for as long as the user has any compose on screen
                """)
        let after = try fixture.pool.read { db in
            (victim: try ChatTurn.fetchOne(db, key: "ttl-victim-turn"),
             control: try ChatTurn.fetchOne(db, key: "ttl-control-turn"))
        }
        #expect(after.victim != nil, "the open compose is still exempt on the second pass")
        #expect(after.control == nil)
    }
}

// MARK: - (d) The window a live re-ask CANNOT see: registration after the row was examined

/// THE INVARIANT is the same one as suite (c) — **turns belonging to a compose that
/// registers before the eviction commits are still present afterwards** — asserted at
/// the window no per-row/per-sweep live re-ask can reach: the registration lands
/// AFTER the site has already taken its live registry read and staged the deletion
/// inside its open transaction.
///
/// Suite (c) hooks a statement that runs BEFORE each site's live read, so it exercises
/// the window round 1 closed and stays green on a system that still loses turns
/// registered later — the `MIS-015` shape. These three hook each site's own `DELETE`,
/// which is strictly after the exemption decision, and are therefore the tests that
/// actually distinguish the generation guard.
///
/// `MIS-006` — `DraftStore.evictImpl` got this guard in `20cd7b688` and `ChatStore`'s
/// three sites did not, for one round: the instance was fixed, the class was not. One
/// test per site, because a single test would be a census that inherited its own
/// search shape.
///
/// Every test carries its MIRROR IMAGE on the same fixture, because the naive fix is
/// worse than the bug in two distinct ways: (1) rolling back on a compose that is
/// merely OPEN would starve eviction forever, and (2) at `enforceTurnBudgets`
/// specifically, rolling back the CALLER's transaction would discard the user's
/// brand-new chat turn — which is why that one site rolls back a SAVEPOINT.
@Suite("ChatStore eviction rolls back a sweep a compose registered during",
       .serialized, .processGlobalState)
struct ChatStoreEvictionGenerationGuardTests {

    private func makeHookedPool(
        hook: ChatStoreLateComposeHook
    ) throws -> (pool: DatabasePool, directory: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("chatstore-generation-guard-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        configuration.prepareDatabase { db in
            db.trace(options: .statement) { event in
                hook.observe(event.description)
            }
        }
        let pool = try DatabasePool(
            path: directory.appendingPathComponent("test.sqlite").path,
            configuration: configuration)
        try AppDatabase.runMigrations(on: pool)
        return (pool, directory)
    }

    private func msAgo(days: Double) -> Double {
        (Date().timeIntervalSince1970 - days * 86400) * 1000
    }

    private func turn(_ id: String, ts: Double, sessionId: String?, chars: Int = 12) -> ChatTurn {
        ChatTurn(
            id: id, timestamp: ts, role: "user",
            content: String(repeating: "x", count: max(1, chars)),
            userMessage: "authored \(id)", type: "normal", chars: chars,
            renderedContent: nil, sessionId: sessionId, remindersSnapshot: nil,
            emailContextJSON: nil, thinkingContent: nil)
    }

    private func historyTurn(_ id: String, ts: Double, sessionId: String) -> ChatHistoryTurn {
        ChatHistoryTurn(
            id: id, timestamp: ts, role: "user", content: "authored \(id)",
            userMessage: "authored \(id)", sessionId: sessionId, chars: 12, type: "normal")
    }

    // MARK: Site 1 — the turn-budget sweep, whose rollback must NOT take the new turn

    /// 🚨 **THE ASSERTION THAT MATTERS MOST HERE IS `budget-appended`.** This sweep runs
    /// inside `appendTurn`'s transaction, which also carries the user's brand-new turn.
    /// Copying `DraftStore.evictImpl`'s whole-transaction rollback would have discarded
    /// it — dropping the very intention the call exists to persist, the exact mirror
    /// image of the bug being fixed. The guard therefore scopes its undo to a SAVEPOINT.
    @Test("A compose that opens after its own turn was deleted gets the sweep rolled back — and keeps the new turn")
    func composeRegisteredAfterItsTurnWasDeletedRollsBackOnlyTheSweep() throws {
        let victimDraftId = "new:budget-late-victim-\(UUID().uuidString)"
        let victimSession = "compose:\(victimDraftId)"
        let controlSession = "compose:new:budget-late-control-\(UUID().uuidString)"

        // The sweep's OWN delete — strictly after `exemptSessions` was derived and after
        // this row's exemption check passed. `INSERT INTO "chatTurn"` cannot match.
        let hook = ChatStoreLateComposeHook(draftId: victimDraftId) { sql in
            sql.contains("DELETE") && sql.contains("chatTurn")
        }
        let fixture = try makeHookedPool(hook: hook)
        defer { TestDatabaseTeardown.retire(pool: fixture.pool, directory: fixture.directory) }
        defer { DraftSessionRegistry.shared.unregister(victimDraftId) }

        let seeded = ChatStore.maxExchanges * 2 + 1
        try fixture.pool.write { db in
            try turn("budget-late-victim", ts: 0, sessionId: victimSession).insert(db)
            try turn("budget-late-control", ts: 1, sessionId: controlSession).insert(db)
            for index in 2..<seeded {
                try turn("budget-late-filler-\(index)", ts: Double(index),
                         sessionId: "msg:acc1:filler@example.com").insert(db)
            }
        }

        #expect(!DraftSessionRegistry.shared.isActive(victimDraftId),
                "precondition: not open when the sweep begins, and not open when its turn is examined")
        hook.arm()

        // `appendTurn`'s shape: the user's new turn is inserted OUTSIDE the sweep's
        // savepoint, then the sweep runs with the set sampled before the transaction.
        let evicted = try fixture.pool.write { db -> [ChatTurn] in
            try turn("budget-appended", ts: Double(seeded), sessionId: "msg:acc1:filler@example.com")
                .insert(db)
            return try ChatStore.enforceTurnBudgets(db: db, activeComposeSessions: [])
        }

        #expect(hook.didFire, "harness non-vacuity: the interleaving must actually have happened")
        #expect(DraftSessionRegistry.shared.isActive(victimDraftId))

        let state = try fixture.pool.read { db in
            (victim: try ChatTurn.fetchOne(db, key: "budget-late-victim"),
             control: try ChatTurn.fetchOne(db, key: "budget-late-control"),
             appended: try ChatTurn.fetchOne(db, key: "budget-appended"))
        }
        #expect(state.victim?.userMessage == "authored budget-late-victim",
                """
                the authored turns of a compose that was still OPENING were deleted — it had \
                registered but not yet loaded, so it holds nothing in memory to re-save
                """)
        #expect(state.control != nil, "the savepoint rolls back, so the control's eviction is undone too")
        #expect(evicted.isEmpty, "a rolled-back sweep must report that it evicted nothing")
        #expect(state.appended?.userMessage == "authored budget-appended",
                """
                the user's BRAND-NEW turn was rolled back with the sweep — that is the mirror \
                image of the bug: the rollback must be a SAVEPOINT scoped to the eviction, not \
                the caller's whole transaction, or every rolled-back sweep drops the intention \
                `appendTurn` exists to persist
                """)

        // THE MIRROR IMAGE (starvation) — the compose stays open and untouched, so the
        // next append's sweep observes an unchanged generation and completes.
        let secondPass = try fixture.pool.write { db -> [ChatTurn] in
            try ChatStore.enforceTurnBudgets(db: db, activeComposeSessions: [])
        }
        #expect(!secondPass.isEmpty,
                """
                the turn-budget sweep never completed while a compose was open — the generation \
                guard is tripping on steady state, so chatTurn grows without bound for as long \
                as the user has any compose on screen
                """)
        let after = try fixture.pool.read { db in
            (victim: try ChatTurn.fetchOne(db, key: "budget-late-victim"),
             control: try ChatTurn.fetchOne(db, key: "budget-late-control"))
        }
        #expect(after.victim != nil, "the open compose's turn is still exempt on the second pass")
        #expect(after.control == nil, "the closed compose's turn is reclaimed once the sweep can run")
    }

    // MARK: Site 2 — the chatHistory memory cap

    @Test("A compose that opens after its history row was deleted gets the cap sweep rolled back")
    func composeRegisteredAfterItsHistoryWasDeletedRollsBackTheSweep() throws {
        let victimDraftId = "new:cap-late-victim-\(UUID().uuidString)"

        // `DELETE FROM chatHistory WHERE id IN (…)` — strictly after the exemption list
        // was derived and after the victim's id was selected into the delete.
        let hook = ChatStoreLateComposeHook(draftId: victimDraftId) { sql in
            sql.contains("DELETE") && sql.contains("chatHistory")
        }
        let fixture = try makeHookedPool(hook: hook)
        defer { TestDatabaseTeardown.retire(pool: fixture.pool, directory: fixture.directory) }
        defer { DraftSessionRegistry.shared.unregister(victimDraftId) }

        try fixture.pool.write { db in
            try historyTurn("cap-late-victim", ts: msAgo(days: 3),
                            sessionId: "compose:\(victimDraftId)").insert(db)
            try historyTurn("cap-late-control", ts: msAgo(days: 2),
                            sessionId: "msg:acc1:a@example.com").insert(db)
            try historyTurn("cap-late-newest", ts: msAgo(days: 1),
                            sessionId: "msg:acc1:b@example.com").insert(db)
        }

        #expect(!DraftSessionRegistry.shared.isActive(victimDraftId))
        hook.arm()

        let evicted = try ChatStore.shared.evictHistoryBeyondCapSync(
            dbPool: PrioritizedDatabase(pool: fixture.pool), maxTurns: 2)

        #expect(hook.didFire, "harness non-vacuity: the interleaving must actually have happened")
        #expect(DraftSessionRegistry.shared.isActive(victimDraftId))

        let state = try fixture.pool.read { db in
            (victim: try ChatHistoryTurn.fetchOne(db, key: "cap-late-victim"),
             control: try ChatHistoryTurn.fetchOne(db, key: "cap-late-control"))
        }
        #expect(state.victim?.userMessage == "authored cap-late-victim")
        #expect(state.control != nil, "the whole transaction rolls back")
        #expect(evicted.isEmpty,
                """
                a rolled-back sweep must report nothing, or the caller cascades phantom \
                deletions into memory.db
                """)

        // THE MIRROR IMAGE (starvation).
        let secondPass = try ChatStore.shared.evictHistoryBeyondCapSync(
            dbPool: PrioritizedDatabase(pool: fixture.pool), maxTurns: 2)
        #expect(secondPass == ["cap-late-control"],
                "the cap never completes while a compose is open — chatHistory grows unbounded")
        #expect(try fixture.pool.read { try ChatHistoryTurn.fetchOne($0, key: "cap-late-victim") } != nil)
    }

    // MARK: Site 3 — the compose-session TTL sweep

    @Test("A compose that opens after its session was swept gets the TTL sweep rolled back")
    func composeRegisteredAfterItsSessionWasSweptRollsBackTheSweep() throws {
        let victimDraftId = "new:ttl-late-victim-\(UUID().uuidString)"
        let controlDraftId = "new:ttl-late-control-\(UUID().uuidString)"

        // The loop's own `DELETE FROM chatTurn WHERE sessionId = …`, which runs after
        // that session's live `activeComposeSessionIds()` check has already passed.
        let hook = ChatStoreLateComposeHook(draftId: victimDraftId) { sql in
            sql.contains("DELETE") && sql.contains("chatTurn")
        }
        let fixture = try makeHookedPool(hook: hook)
        defer { TestDatabaseTeardown.retire(pool: fixture.pool, directory: fixture.directory) }
        defer { DraftSessionRegistry.shared.unregister(victimDraftId) }

        try fixture.pool.write { db in
            try turn("ttl-late-victim-turn", ts: msAgo(days: 30),
                     sessionId: "compose:\(victimDraftId)").insert(db)
            try turn("ttl-late-control-turn", ts: msAgo(days: 30),
                     sessionId: "compose:\(controlDraftId)").insert(db)
        }

        #expect(!DraftSessionRegistry.shared.isActive(victimDraftId))
        hook.arm()

        let evicted = try ChatStore.shared.evictComposeSessionsSync(
            dbPool: PrioritizedDatabase(pool: fixture.pool), ttlDays: 1)

        #expect(hook.didFire, "harness non-vacuity: the interleaving must actually have happened")
        #expect(DraftSessionRegistry.shared.isActive(victimDraftId))

        // Whichever expired session the loop reached first, the registration landed
        // inside the transaction, so BOTH sessions' turns are restored.
        let state = try fixture.pool.read { db in
            (victim: try ChatTurn.fetchOne(db, key: "ttl-late-victim-turn"),
             control: try ChatTurn.fetchOne(db, key: "ttl-late-control-turn"))
        }
        #expect(state.victim?.userMessage == "authored ttl-late-victim-turn")
        #expect(state.control != nil, "the whole transaction rolls back")
        #expect(evicted == 0, "a rolled-back sweep must report that it evicted nothing")

        // THE MIRROR IMAGE (starvation).
        let secondPass = try ChatStore.shared.evictComposeSessionsSync(
            dbPool: PrioritizedDatabase(pool: fixture.pool), ttlDays: 1)
        #expect(secondPass == 1,
                "the TTL sweep never completes while a compose is open — expired sessions accumulate")
        let after = try fixture.pool.read { db in
            (victim: try ChatTurn.fetchOne(db, key: "ttl-late-victim-turn"),
             control: try ChatTurn.fetchOne(db, key: "ttl-late-control-turn"))
        }
        #expect(after.victim != nil, "the open compose is still exempt on the second pass")
        #expect(after.control == nil)
    }
}
