/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Synchronization
import Testing
@testable import TabMail

/// Fires ONE `DraftSessionRegistry.register` from inside the eviction write
/// transaction, by hooking SQLite's statement trace on the pool's own connections.
///
/// This reproduces the real interleaving the fix closes: a ComposeView opening
/// AFTER `evictImpl` took its pre-transaction `snapshot()` but BEFORE the write
/// commits. Nothing else in the suite can express it — every other test registers
/// before the sweep starts, which both the pre-fix and post-fix code handle.
///
/// It is armed explicitly, so the fixture's own `chatTurn` inserts (which run on
/// the same traced connections) cannot trip it early, and it fires at most once.
private final class LateComposeRegistrationHook: Sendable {
    private let armed = Mutex<Bool>(false)
    private let fired = Mutex<Bool>(false)
    private let draftId: String

    init(draftId: String) { self.draftId = draftId }

    /// Arm after fixture setup, immediately before the sweep.
    func arm() { armed.withLock { $0 = true } }

    /// True once the registration actually landed — the test asserts this so a
    /// hook that silently never fired cannot make the invariant pass vacuously.
    var didFire: Bool { fired.withLock { $0 } }

    /// `evictImpl`'s FIRST statement inside its write transaction is the
    /// orphaned-compose-session SELECT over `chatTurn`, so matching that puts the
    /// registration inside the transaction and ahead of the draft row loop.
    func observe(_ sql: String) {
        guard sql.contains("chatTurn") else { return }
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

/// T4.D4 — background GC must never delete an OPEN compose's `Draft` or its
/// authored `ChatTurn`s. Both legs of `DraftStore.evictImpl` are covered, each
/// with its unregistered control so neither assertion can pass vacuously.
///
/// PORT reference: `v2final:TabMail/Services/AI/DraftSessionRegistry.swift`
/// (commit `d2f0c96a3`) and `v2final:…/DraftStore.swift` → `evictImpl`.
///
/// `.processGlobalState` because `DraftSessionRegistry.shared` is a process-wide
/// singleton; every registration below is balanced by a `defer` unregister.
@Suite("Draft session registry", .serialized, .processGlobalState)
struct DraftSessionRegistryTests {

    // MARK: - Fixture

    private func makePool() throws -> (pool: DatabasePool, directory: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("draft-session-registry-\(UUID().uuidString)", isDirectory: true)
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

    /// Same fixture as `makePool()`, plus a statement trace that lets `hook` fire a
    /// registration from inside the eviction transaction.
    private func makeHookedPool(
        hook: LateComposeRegistrationHook
    ) throws -> (pool: DatabasePool, directory: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("draft-session-registry-\(UUID().uuidString)", isDirectory: true)
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

    private func draft(id: String, updatedAt: Double) -> Draft {
        Draft(
            id: id, accountId: "acc1", toJSON: "[]", ccJSON: "[]", bccJSON: "[]",
            subject: "subject", body: "authored body for \(id)", replyToId: nil,
            isForward: false, editHistoryJSON: nil, createdAt: updatedAt,
            updatedAt: updatedAt, serverDraftId: nil, serverPushStatus: nil,
            rfc822MessageId: nil, attachmentsDirName: nil)
    }

    private func turn(id: String, sessionId: String, text: String) -> ChatTurn {
        ChatTurn(
            id: id, timestamp: 1, role: "user", content: "compose_edit",
            userMessage: text, type: "normal", chars: text.count,
            renderedContent: nil, sessionId: sessionId, remindersSnapshot: nil,
            emailContextJSON: nil, thinkingContent: nil)
    }

    // MARK: - Refcount

    @Test("Two ComposeViews on one draftId stay protected until the last one closes")
    func refcountedRegistration() {
        let registry = DraftSessionRegistry.shared
        let draftId = "reply:acc1:shared@example.com"
        registry.register(draftId)
        registry.register(draftId)
        defer { registry.unregister(draftId) }

        #expect(registry.isActive(draftId))
        registry.unregister(draftId)
        // One view closed; the sibling still has it open.
        #expect(registry.isActive(draftId))
        #expect(registry.snapshot().contains(draftId))
        #expect(registry.activeComposeSessionIds().contains("compose:\(draftId)"))
        #expect(registry.activeComposeSessionIds().contains("demo:compose:\(draftId)"))

        registry.unregister(draftId)
        #expect(!registry.isActive(draftId))
        #expect(!registry.snapshot().contains(draftId))
        #expect(!registry.activeComposeSessionIds().contains("compose:\(draftId)"))
    }

    @Test("A spurious unregister never drives the refcount negative")
    func spuriousUnregisterIsANoOp() {
        let registry = DraftSessionRegistry.shared
        let draftId = "new:never-registered-\(UUID().uuidString)"
        registry.unregister(draftId)
        #expect(!registry.isActive(draftId))

        // A single register must still fully protect the id — proof the stray
        // unregister above did not push the count to -1.
        registry.register(draftId)
        #expect(registry.isActive(draftId))
        registry.unregister(draftId)
        #expect(!registry.isActive(draftId))
    }

    // MARK: - Eviction

    @Test("Background eviction keeps an open compose's draft and its authored chat turns")
    func evictionSkipsOpenCompose() throws {
        let fixture = try makePool()
        defer { TestDatabaseTeardown.retire(pool: fixture.pool, directory: fixture.directory) }
        let now = Date().timeIntervalSince1970
        let openId = "new:open-compose"
        let closedId = "new:closed-compose"
        let newestId = "new:newest-compose"

        // Saved oldest-first, so the OPEN draft is the least recently touched and
        // would be the eviction victim without the registry guard.
        try fixture.pool.write { db in
            _ = try DraftStore.applySave(draft(id: openId, updatedAt: now - 300), db: db)
            _ = try DraftStore.applySave(draft(id: closedId, updatedAt: now - 200), db: db)
            _ = try DraftStore.applySave(draft(id: newestId, updatedAt: now - 100), db: db)
            try turn(
                id: "open-turn", sessionId: "compose:\(openId)",
                text: "Keep every authored byte").insert(db)
            try turn(
                id: "closed-turn", sessionId: "compose:\(closedId)",
                text: "This compose was closed").insert(db)
        }

        let registry = DraftSessionRegistry.shared
        registry.register(openId)
        defer { registry.unregister(openId) }

        _ = try DraftStore.shared.evictSync(
            dbPool: PrioritizedDatabase(pool: fixture.pool), limit: 1)

        let state = try fixture.pool.read { db in
            (open: try Draft.fetchOne(db, key: openId),
             closed: try Draft.fetchOne(db, key: closedId),
             newest: try Draft.fetchOne(db, key: newestId),
             openTurn: try ChatTurn.fetchOne(db, key: "open-turn"),
             closedTurn: try ChatTurn.fetchOne(db, key: "closed-turn"))
        }
        // The open compose survives with its authored turn…
        #expect(state.open != nil)
        #expect(state.openTurn?.userMessage == "Keep every authored byte")
        // …the most recently touched draft survives on recency…
        #expect(state.newest != nil)
        // …and the unregistered control is evicted, so the guard above is not vacuous.
        #expect(state.closed == nil)
        #expect(state.closedTurn == nil)
    }

    @Test("An open compose's chat turns survive before its first draft save")
    func orphanSweepSkipsOpenCompose() throws {
        let fixture = try makePool()
        defer { TestDatabaseTeardown.retire(pool: fixture.pool, directory: fixture.directory) }
        // A brand-new compose has chat turns BEFORE its first Draft row exists, so
        // the orphan-session sweep sees it as unowned.
        let openId = "new:unsaved-open-compose"
        let abandonedId = "new:abandoned-compose"
        try fixture.pool.write { db in
            try turn(
                id: "unsaved-open-turn", sessionId: "compose:\(openId)",
                text: "Typed before the first save").insert(db)
            try turn(
                id: "abandoned-turn", sessionId: "compose:\(abandonedId)",
                text: "Nobody has this open").insert(db)
        }

        let registry = DraftSessionRegistry.shared
        registry.register(openId)
        defer { registry.unregister(openId) }

        _ = try DraftStore.shared.evictSync(
            dbPool: PrioritizedDatabase(pool: fixture.pool), limit: 10)

        let state = try fixture.pool.read { db in
            (openTurn: try ChatTurn.fetchOne(db, key: "unsaved-open-turn"),
             abandonedTurn: try ChatTurn.fetchOne(db, key: "abandoned-turn"))
        }
        #expect(state.openTurn?.userMessage == "Typed before the first save")
        // Control: an orphan session nobody has open is still reclaimed.
        #expect(state.abandonedTurn == nil)
    }

    // MARK: - The register-vs-commit interleaving

    /// THE INVARIANT: a draft whose compose session is registered at ANY point
    /// before the eviction transaction commits is still present after `evictImpl`
    /// returns — asserted on the persisted rows, not on what the snapshot held.
    ///
    /// Pre-2026-08-05 `evictImpl` sampled `DraftSessionRegistry` ONCE, before
    /// opening `dbPool.write`, and never re-consulted it. A ComposeView that opened
    /// during the sweep was therefore invisible, and the sweep deleted its draft
    /// row, its authored compose chat turns and (after commit) its attachment
    /// directory while the user was typing into it. Both the function's own comment
    /// and `DraftSessionRegistry`'s doc header asserted the opposite — that the
    /// window "only ever costs a retention" and that a draft is "kept, never
    /// wrongly deleted".
    ///
    /// The distinguishing timing is supplied by `LateComposeRegistrationHook`: the
    /// draft is NOT open when the sweep starts (asserted below), and becomes open
    /// inside the transaction.
    @Test("A compose that opens inside the eviction transaction keeps its draft")
    func composeRegisteredInsideEvictionTransactionKeepsItsDraft() throws {
        let victimId = "new:opens-mid-transaction"
        let controlId = "new:never-opened-control"
        let newestId = "new:newest-holds-the-slot"

        let hook = LateComposeRegistrationHook(draftId: victimId)
        let fixture = try makeHookedPool(hook: hook)
        defer { TestDatabaseTeardown.retire(pool: fixture.pool, directory: fixture.directory) }
        // The hook registers; this balances it however the assertions land.
        defer { DraftSessionRegistry.shared.unregister(victimId) }

        let now = Date().timeIntervalSince1970
        // Saved oldest-first, so `victimId` is the least recently touched and is the
        // eviction victim on recency — the same setup as `evictionSkipsOpenCompose`,
        // differing ONLY in when the registration lands.
        try fixture.pool.write { db in
            _ = try DraftStore.applySave(draft(id: victimId, updatedAt: now - 300), db: db)
            _ = try DraftStore.applySave(draft(id: controlId, updatedAt: now - 200), db: db)
            _ = try DraftStore.applySave(draft(id: newestId, updatedAt: now - 100), db: db)
            try turn(
                id: "victim-turn", sessionId: "compose:\(victimId)",
                text: "Typed while the sweep was running").insert(db)
            try turn(
                id: "control-turn", sessionId: "compose:\(controlId)",
                text: "Nobody has this open").insert(db)
        }

        // Precondition: NOT open when the sweep begins. This is what makes the
        // pre-transaction snapshot miss it, and it is the whole point of the test.
        #expect(!DraftSessionRegistry.shared.isActive(victimId))
        hook.arm()

        _ = try DraftStore.shared.evictSync(
            dbPool: PrioritizedDatabase(pool: fixture.pool), limit: 1)

        // Harness non-vacuity: if the hook never fired there was no interleaving and
        // the assertions below would prove nothing.
        #expect(hook.didFire)
        #expect(DraftSessionRegistry.shared.isActive(victimId))

        let state = try fixture.pool.read { db in
            (victim: try Draft.fetchOne(db, key: victimId),
             control: try Draft.fetchOne(db, key: controlId),
             newest: try Draft.fetchOne(db, key: newestId),
             victimTurn: try ChatTurn.fetchOne(db, key: "victim-turn"),
             controlTurn: try ChatTurn.fetchOne(db, key: "control-turn"))
        }
        // THE INVARIANT — the draft the user is composing into survives, with its
        // authored chat turn.
        #expect(state.victim != nil)
        #expect(state.victimTurn?.userMessage == "Typed while the sweep was running")
        // Recency still holds for the untouched newest draft…
        #expect(state.newest != nil)
        // …and the never-opened control is still evicted, so the guard above is not
        // vacuous and the fix did not simply disable eviction.
        #expect(state.control == nil)
        #expect(state.controlTurn == nil)
    }
}
