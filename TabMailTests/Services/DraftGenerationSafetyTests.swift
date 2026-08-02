/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Testing
@testable import TabMail

/// PORT — compact coverage of v2final's sticky read, generation CAS, and
/// Stage A/B fences. Recovery/redrive/compatibility matrices are SUBTRACTED.
@Suite("Draft generation safety", .serialized, .processGlobalState)
@MainActor
struct DraftGenerationSafetyTests {
    private enum MidPushMutation: Sendable, Equatable { case edit, replacement }

    private func draft(
        id: String = "draft-1",
        epoch: String = "E1",
        body: String = "body",
        status: String? = nil,
        serverId: String? = nil,
        updatedAt: Double = 1
    ) -> Draft {
        var value = Draft(
            id: id, accountId: "acc1", toJSON: "[]", ccJSON: "[]", bccJSON: "[]",
            subject: "subject", body: body, replyToId: nil, isForward: false,
            editHistoryJSON: nil, createdAt: 1, updatedAt: updatedAt,
            serverDraftId: serverId, serverPushStatus: status,
            rfc822MessageId: "old@example.com", attachmentsDirName: nil)
        value.instanceEpoch = epoch
        return value
    }

    private func install() throws -> (DatabasePool, URL, AppDatabase?) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("draft-generation-\(UUID().uuidString)")
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
        try pool.writeWithoutTransaction { db in
            var account = Account(
                emailAddress: "acc1@example.com", displayName: "Test", provider: .outlook)
            account.id = "acc1"
            try account.insert(db)
        }
        return (pool, directory, previous)
    }

    private func finish(_ fixture: (DatabasePool, URL, AppDatabase?)) {
        InstalledTestDatabaseLifetime.finish(
            previous: fixture.2, pool: fixture.0, directory: fixture.1)
    }

    @Test("An initial draft read error remains a sticky mutation firewall")
    func stickyReadError() {
        #expect(ComposeDraftGuards.effectiveMutationState(
            initialLoad: .error, perOp: .loaded) == .error)
        #expect(ComposeDraftGuards.effectiveMutationState(
            initialLoad: .loaded, perOp: .error) == .error)
        #expect(ComposeDraftGuards.effectiveMutationState(
            initialLoad: .notFound, perOp: .loaded) == .loaded)
    }

    @Test("Checked close from E1 cannot delete live E2 or its authored chat turns")
    func generationOwnedDelete() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        let successor = draft(epoch: "E2")
        let persistedSession = "compose:\(successor.id)"
        try db.write { connection in
            try successor.insert(connection)
            try ChatTurn(
                id: "live-turn", timestamp: 1, role: "user", content: "compose_edit",
                userMessage: "new", type: "normal", chars: 3, renderedContent: nil,
                sessionId: persistedSession, remindersSnapshot: nil, emailContextJSON: nil,
                thinkingContent: nil).insert(connection)
        }

        #expect(throws: DraftStore.DraftEpochAdmissionError.self) {
            try db.write {
                try DraftStore.applyDelete(
                    id: successor.id, expectedInstanceEpoch: "E1", db: $0)
            }
        }
        #expect(try db.read { try Draft.fetchOne($0, key: successor.id) } != nil)
        #expect(try db.read { try ChatTurn.fetchOne($0, key: "live-turn") } != nil)

        try db.write {
            try DraftStore.applyDelete(
                id: successor.id, expectedInstanceEpoch: "E2", db: $0)
        }
        #expect(try db.read { try Draft.fetchOne($0, key: successor.id) } == nil)
        #expect(try db.read { try ChatTurn.fetchOne($0, key: "live-turn") } == nil)
    }

    @Test("A live draft's authored compose turns survive routine maintenance")
    func liveDraftTurnsSurviveMaintenance() throws {
        let fixture = try install()
        defer { finish(fixture) }
        let liveDraft = draft(id: "reply:acc1:INBOX:message-1", epoch: "E1")
        let authoredTurn = ChatTurn(
            id: "live-authored-turn", timestamp: 1, role: "user",
            content: "compose_edit", userMessage: "Keep every authored byte",
            type: "normal", chars: 24, renderedContent: nil,
            sessionId: "compose:\(liveDraft.id)",
            remindersSnapshot: nil, emailContextJSON: nil, thinkingContent: nil)
        try fixture.0.write { db in
            try liveDraft.insert(db)
            try authoredTurn.insert(db)
        }

        _ = try DraftStore.shared.evictSync(
            dbPool: PrioritizedDatabase(pool: fixture.0), limit: 10)

        let state = try fixture.0.read { db in
            (try Draft.fetchOne(db, key: liveDraft.id),
             try ChatTurn.fetchOne(db, key: authoredTurn.id))
        }
        #expect(state.0?.instanceEpoch == "E1")
        #expect(state.1?.userMessage == "Keep every authored byte")
    }

    @Test("A stale generation cursor cannot overwrite or resurrect its successor")
    func staleCursor() async throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        let initial = draft(epoch: "E1")
        try await db.write { try initial.insert($0) }
        let successor = draft(epoch: "E1", body: "successor", updatedAt: 2)
        try await db.write {
            _ = try DraftStore.admitSave(
                successor, newEpoch: "E2", expectedPredecessor: "E1", db: $0)
        }
        let stale = ComposeGenerationCursor(
            newEpoch: "E1", initialExpectedPredecessor: "E1")

        var overwriteRefused = false
        do {
            _ = try await stale.admit { epoch, predecessor in
                try db.write {
                    try DraftStore.admitSave(
                        initial, newEpoch: epoch, expectedPredecessor: predecessor, db: $0)
                }
            }
        } catch { overwriteRefused = true }
        #expect(overwriteRefused)
        let afterOverwriteAttempt = try await db.read {
            try Draft.fetchOne($0, key: initial.id)
        }
        #expect(afterOverwriteAttempt?.body == "successor")

        try await db.write { _ = try Draft.deleteOne($0, key: initial.id) }
        var resurrectionRefused = false
        do {
            _ = try await stale.admit { epoch, predecessor in
                try db.write {
                    try DraftStore.admitSave(
                        initial, newEpoch: epoch, expectedPredecessor: predecessor, db: $0)
                }
            }
        } catch { resurrectionRefused = true }
        #expect(resurrectionRefused)
        let afterResurrectionAttempt = try await db.read {
            try Draft.fetchOne($0, key: initial.id)
        }
        #expect(afterResurrectionAttempt == nil)
    }

    @Test("An edit before Stage A prevents provider I/O")
    func preStageAReplacement() async throws {
        let fixture = try install()
        defer { finish(fixture) }
        let initial = draft()
        try await fixture.0.writeWithoutTransaction { try initial.insert($0) }
        let captured = try #require(try await fixture.0.read {
            try Draft.fetchOne($0, key: initial.id)
        })
        try await fixture.0.write { db in
            guard var edited = try Draft.fetchOne(db, key: initial.id) else { return }
            edited.body = "newer"
            edited.updatedAt += 1
            _ = try DraftStore.applySave(edited, db: db)
        }

        let context = try await fixture.0.write { db in
            try DraftStore.performStageA(
                initialDraft: captured,
                expectedInstanceEpoch: "E1",
                previousIdentity: nil,
                freshRfc: "fresh@example.com",
                db: db)
        }

        #expect(context == nil)
        #expect(try await fixture.0.read { try Draft.fetchOne($0, key: initial.id) }?.body == "newer")
    }

    @Test(
        "An edit or generation replacement between Stage A and Stage B is not stamped pushed",
        arguments: [MidPushMutation.edit, .replacement])
    private func midPushMutation(_ mutation: MidPushMutation) async throws {
        let fixture = try install()
        defer { finish(fixture) }
        let initial = draft()
        try await fixture.0.writeWithoutTransaction { try initial.insert($0) }
        let provider = MockEmailProvider(
            saveDraftResult: .created(.outlook(graphId: "mock-draft-id")))
        await provider.setSaveDraftHook {
            try? await AppDatabase.dbPool.write { db in
                guard var live = try Draft.fetchOne(db, key: initial.id) else { return }
                live.body = "authored during push"
                live.updatedAt += 1
                switch mutation {
                case .edit:
                    _ = try DraftStore.applySave(live, db: db)
                case .replacement:
                    _ = try DraftStore.admitSave(
                        live, newEpoch: "E2", expectedPredecessor: "E1", db: db)
                }
            }
        }

        let result = try await DraftStore.shared.pushDraftToServer(
            draftId: initial.id, expectedInstanceEpoch: "E1", provider: provider,
            runtimeKind: .outlook, draftsFolderPath: "Drafts")

        let live = try await fixture.0.read { try Draft.fetchOne($0, key: initial.id) }
        #expect(result == .notApplied)
        #expect(live?.body == "authored during push")
        #expect(live?.serverPushStatus == "dirty")
        #expect(live?.serverDraftId == nil)
        #expect(live?.instanceEpoch == (mutation == .edit ? "E1" : "E2"))
    }

    @Test("A provider throw terminalizes unconfirmed and a later authored edit admits one fresh push")
    func providerThrowThenAuthoredEdit() async throws {
        let fixture = try install()
        defer { finish(fixture) }
        let initial = draft(serverId: "old-resource")
        try await fixture.0.writeWithoutTransaction { try initial.insert($0) }
        let failingProvider = MockEmailProvider(
            saveDraftResult: .created(.outlook(graphId: "unreachable-resource")),
            saveDraftThrows: ProviderError.networkError(
                underlying: NSError(domain: "test", code: 1)))

        let first = try await DraftStore.shared.pushDraftToServer(
            draftId: initial.id, expectedInstanceEpoch: "E1", provider: failingProvider,
            runtimeKind: .outlook, draftsFolderPath: "Drafts")

        var live = try await fixture.0.read { try Draft.fetchOne($0, key: initial.id) }
        #expect(first == .terminalUnconfirmed)
        #expect(live?.serverPushStatus == "unconfirmed")
        #expect(live?.serverDraftId == "old-resource")
        let failingCalls = await failingProvider.callLog
        #expect(failingCalls.filter { $0.hasPrefix("saveDraft") }.count == 1)

        try await fixture.0.write { db in
            guard var edited = try Draft.fetchOne(db, key: initial.id) else { return }
            edited.body = "fresh edit"
            edited.updatedAt += 1
            _ = try DraftStore.applySave(edited, db: db)
        }
        live = try await fixture.0.read { try Draft.fetchOne($0, key: initial.id) }
        #expect(live?.serverPushStatus == "dirty")

        let succeedingProvider = MockEmailProvider(
            saveDraftResult: .created(.outlook(graphId: "new-resource")))
        let result = try await DraftStore.shared.pushDraftToServer(
            draftId: initial.id, expectedInstanceEpoch: "E1", provider: succeedingProvider,
            runtimeKind: .outlook, draftsFolderPath: "Drafts")

        live = try await fixture.0.read { try Draft.fetchOne($0, key: initial.id) }
        #expect(result == .completed)
        #expect(live?.body == "fresh edit")
        #expect(live?.serverPushStatus == "pushed")
        #expect(live?.serverDraftId == "new-resource")
        let succeedingCalls = await succeedingProvider.callLog
        #expect(succeedingCalls.filter { $0.hasPrefix("saveDraft") }.count == 1)
    }

    /// ⚑ NO REFERENCE — INVENTED: the approved minimum local arbitration proof for
    /// the observed suspended Agent-versus-Send race; it adds no lifecycle machinery.
    @Test("Agent and Send claims are mutually exclusive and release restores admission")
    func agentSendFence() {
        let fence = ComposeAgentSendFence()
        #expect(fence.beginAgent())
        #expect(!fence.claimSend())
        fence.finishAgent()
        #expect(fence.claimSend())
        #expect(!fence.beginAgent())
        fence.releaseFailedSend()
        #expect(fence.beginAgent())
        fence.finishAgent()
    }
}
