/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Testing
@testable import TabMail

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
}
