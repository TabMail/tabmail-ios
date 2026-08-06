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

    /// **THE INVARIANT: a provider throw is reported AS a throw, and the draft it
    /// left behind is immediately pushable again — with or without an intervening
    /// authored edit.**
    ///
    /// ⚠️ THIS TEST REPLACES A BLESSING TEST (MIS-014). Its predecessor,
    /// `providerThrowThenAuthoredEdit`, asserted `first == .terminalUnconfirmed`
    /// and `serverPushStatus == "unconfirmed"` — i.e. it asserted that swallowing
    /// the throw into a NORMAL RETURN was correct. That normal return is what let
    /// `AccountManagerQueue.executeSingleOp`'s success path retire the durable
    /// `.saveDraft` producer after one network failure. Its premise was the defect,
    /// so it is rewritten rather than repaired.
    ///
    /// What is asserted here is the SYSTEM PROPERTY, not the mechanism (MIS-015):
    /// the call throws; the authored content and the prior provider linkage are
    /// intact; and the very next push — with NO edit in between, which is the case
    /// the old test could not express because pre-fix the row was inadmissible —
    /// reaches the provider and completes. The "later authored edit still wins"
    /// half of the old test is kept as the second leg, because that is a genuine
    /// second property and not a restatement of the first.
    ///
    /// The queue-level half of this invariant (the durable `PendingOperation` row
    /// survives the throw) is pinned in
    /// `NeverDropExitClosureTests.aThrownDraftAppendKeepsItsSaveProducerAndTheNextDrainLandsIt`.
    @Test("A provider throw is rethrown and leaves the draft immediately pushable again")
    func providerThrowRethrowsAndLeavesTheDraftPushable() async throws {
        let fixture = try install()
        defer { finish(fixture) }
        let initial = draft(serverId: "old-resource")
        try await fixture.0.writeWithoutTransaction { try initial.insert($0) }
        let failingProvider = MockEmailProvider(
            saveDraftResult: .created(.outlook(graphId: "unreachable-resource")),
            saveDraftThrows: ProviderError.networkError(
                underlying: NSError(domain: "test", code: 1)))

        var rethrown = false
        do {
            _ = try await DraftStore.shared.pushDraftToServer(
                draftId: initial.id, expectedInstanceEpoch: "E1", provider: failingProvider,
                runtimeKind: .outlook, draftsFolderPath: "Drafts")
        } catch { rethrown = true }
        #expect(
            rethrown,
            "the provider threw and `pushDraftToServer` returned normally — the caller reads a normal return as a completed op and retires the user's Save intention")

        var live = try await fixture.0.read { try Draft.fetchOne($0, key: initial.id) }
        #expect(live?.serverDraftId == "old-resource", "the prior provider linkage was destroyed by a failed attempt")
        let failingCalls = await failingProvider.callLog
        #expect(failingCalls.filter { $0.hasPrefix("saveDraft") }.count == 1)

        // LEG 1 — a straight retry, with NO authored edit, reaches the provider.
        let retryProvider = MockEmailProvider(
            saveDraftResult: .created(.outlook(graphId: "retry-resource")))
        let retry = try await DraftStore.shared.pushDraftToServer(
            draftId: initial.id, expectedInstanceEpoch: "E1", provider: retryProvider,
            runtimeKind: .outlook, draftsFolderPath: "Drafts")
        #expect(retry == .completed)
        let retryCalls = await retryProvider.callLog
        #expect(
            retryCalls.filter { $0.hasPrefix("saveDraft") }.count == 1,
            "the retry never reached the provider — the failed attempt left the row inadmissible, which is a wedge, not a fix: \(retryCalls)")
        live = try await fixture.0.read { try Draft.fetchOne($0, key: initial.id) }
        #expect(live?.serverDraftId == "retry-resource")
        #expect(live?.body == "body", "the retry clobbered the authored body")

        // LEG 2 — a later authored edit still wins the CAS and still admits exactly
        // one fresh push carrying the newer content.
        try await fixture.0.write { db in
            guard var edited = try Draft.fetchOne(db, key: initial.id) else { return }
            edited.body = "fresh edit"
            edited.updatedAt += 1
            _ = try DraftStore.applySave(edited, db: db)
        }
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

// MARK: - T4.D6 / T4.D7 / T4.D8 — compose fail-closed invariants
//
// These pin SYSTEM PROPERTIES of the compose close / save / discard / open paths,
// not the mechanisms that implement them:
//
//   D6  a THROWN `Draft.fetchOne` is NOT absence — it authorizes NO delete, NO
//       overwrite and NO insert, and the draft on disk SURVIVES. Two-sided: a
//       genuine absence, and a successful read, still authorize the ordinary paths
//       (a guard that refused everything would satisfy the first half alone).
//   D7  emptiness counts Cc/Bcc and the uncommitted recipient text; a LOADED row
//       cleared to nothing PROMPTS instead of vanishing; dismiss happens only
//       AFTER the delete has landed.
//   D8  a persisted draft binds ONLY to the account that owns the row; an
//       unresolvable owner binds NOTHING.
//
// `ComposeView` is a SwiftUI value with `@State`/`@Environment` storage and cannot
// be instantiated headlessly, so each test drives the PRODUCTION decision seam
// (`ComposeDraftGuards`) and then performs the real database / filesystem effect
// that the production call site performs for that decision. The dispatch is the
// only test-local part; every predicate under test is the shipping one.
@Suite("Compose draft fail-closed guards", .serialized, .processGlobalState)
@MainActor
struct ComposeDraftGuardTests {

    private struct SuspendedReadFailure: Error {}
    private struct BusyWriterFailure: Error {}

    private func emptyDraft(id: String = "draft-fc", accountId: String = "acc1", epoch: String = "E1") -> Draft {
        var value = Draft(
            id: id, accountId: accountId, toJSON: "[]", ccJSON: "[]", bccJSON: "[]",
            subject: "", body: "", replyToId: nil, isForward: false,
            editHistoryJSON: nil, createdAt: 1, updatedAt: 1,
            serverDraftId: nil, serverPushStatus: nil,
            rfc822MessageId: nil, attachmentsDirName: nil)
        value.instanceEpoch = epoch
        return value
    }

    // MARK: D6 — a thrown read is not absence

    @Test("A thrown draft read authorizes no delete, no overwrite and no insert")
    func thrownReadAuthorizesNoMutation() {
        let thrown: Result<Draft?, Error> = .failure(SuspendedReadFailure())
        let state = ComposeDraftGuards.readState(thrown)
        #expect(state == .error)
        // Save-merge and discard-delete authority are both REFUSED. Without this,
        // the save path rebuilt its merge base from a read that never saw the row
        // (clobbering stored edit history and server linkage) and the discard path
        // deleted locally without the remote cleanup the row's identity funds.
        #expect(!ComposeDraftGuards.saveMayMutate(readState: state))
        #expect(!ComposeDraftGuards.discardMayDelete(readState: state))
        // …and NO combination of content/changes turns the close into a mutation.
        for hasContent in [true, false] {
            for hasChanges in [true, false] {
                #expect(ComposeDraftGuards.closeAction(
                    readState: state, hasContent: hasContent, hasChanges: hasChanges) == .dismiss)
            }
        }
        // The sticky firewall: a later SUCCESSFUL per-op read does not reopen it.
        #expect(ComposeDraftGuards.effectiveMutationState(
            initialLoad: state, perOp: .loaded) == .error)
    }

    @Test("A draft whose read threw survives the close that would otherwise have deleted it")
    func thrownReadLeavesDraftOnDisk() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        let row = emptyDraft()
        try db.write { try row.insert($0) }

        // The compose emptied to nothing (the exact shape that authorizes a delete)
        // but the initial read THREW, so the compose never saw the row.
        let state = ComposeDraftGuards.readState(
            Result<Draft?, Error>.failure(SuspendedReadFailure()))
        let action = ComposeDraftGuards.closeAction(
            readState: state, hasContent: false, hasChanges: true)
        // Perform exactly what the production close does for each decision.
        switch action {
        case .deleteThenDismiss, .promptDelete:
            try db.write {
                try DraftStore.applyDelete(id: row.id, expectedInstanceEpoch: "E1", db: $0)
            }
        case .promptSave, .dismiss:
            break
        }
        #expect(try db.read { try Draft.fetchOne($0, key: row.id) } != nil)
    }

    @Test("A genuine absence and a successful read still authorize the ordinary compose paths")
    func nonVacuousPositiveLeg() throws {
        // NON-VACUITY for the test above: the guards do not simply refuse everything.
        let absent = ComposeDraftGuards.readState(Result<Draft?, Error>.success(nil))
        #expect(absent == .notFound)
        #expect(ComposeDraftGuards.saveMayMutate(readState: absent))
        #expect(ComposeDraftGuards.discardMayDelete(readState: absent))
        #expect(ComposeDraftGuards.closeAction(
            readState: absent, hasContent: false, hasChanges: true) == .deleteThenDismiss)

        let present = ComposeDraftGuards.readState(Result<Draft?, Error>.success(emptyDraft()))
        #expect(present == .loaded)
        #expect(ComposeDraftGuards.saveMayMutate(readState: present))
        #expect(ComposeDraftGuards.discardMayDelete(readState: present))
        #expect(ComposeDraftGuards.closeAction(
            readState: present, hasContent: true, hasChanges: true) == .promptSave)

        // …and the CONFIRMED delete of a cleared loaded row really removes it.
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        let row = emptyDraft()
        try db.write { try row.insert($0) }
        #expect(ComposeDraftGuards.closeAction(
            readState: present, hasContent: false, hasChanges: true) == .promptDelete)
        try db.write {
            try DraftStore.applyDelete(id: row.id, expectedInstanceEpoch: "E1", db: $0)
        }
        #expect(try db.read { try Draft.fetchOne($0, key: row.id) } == nil)
    }

    // MARK: D7 — emptiness, the cleared-row prompt, and delete-before-dismiss

    @Test("A draft holding only Cc, Bcc or half-typed recipients is not empty")
    func recipientsOnlyDraftIsNotEmpty() {
        func empty(
            to: [String] = [], cc: [String] = [], bcc: [String] = [],
            toInput: String = "", ccInput: String = "", bccInput: String = ""
        ) -> Bool {
            !ComposeDraftGuards.hasContent(
                subject: "", body: "", to: to, cc: cc, bcc: bcc,
                toInput: toInput, ccInput: ccInput, bccInput: bccInput,
                hasAttachments: false)
        }
        // Each of these was read as EMPTY by the superseded inline test (which
        // looked at subject/body/To/attachments only) and therefore routed to a
        // silent delete on close.
        #expect(!empty(cc: ["cc@example.com"]))
        #expect(!empty(bcc: ["bcc@example.com"]))
        #expect(!empty(toInput: "half-typed@example.com"))
        #expect(!empty(ccInput: "half-typed@example.com"))
        #expect(!empty(bccInput: "half-typed@example.com"))
        // NEGATIVE leg: a genuinely empty compose is still empty, so the guard has
        // not simply been made to answer "not empty" for everything.
        #expect(empty())
        #expect(empty(toInput: "   ", ccInput: "\t", bccInput: " "))

        // The close CONSEQUENCE: a loaded Cc-only draft never routes to a delete.
        let ccOnly = ComposeDraftGuards.hasContent(
            subject: "", body: "", to: [], cc: ["cc@example.com"], bcc: [],
            toInput: "", ccInput: "", bccInput: "", hasAttachments: false)
        let action = ComposeDraftGuards.closeAction(
            readState: .loaded, hasContent: ccOnly, hasChanges: true)
        #expect(action == .promptSave)
        #expect(action != .promptDelete)
        #expect(action != .deleteThenDismiss)
    }

    @Test("An uncommitted recipient is flushed into the tokens close and save persist")
    func pendingRecipientIsCommitted() {
        #expect(ComposeDraftGuards.committedRecipients(
            tokens: [], input: "  late@example.com  ") == ["late@example.com"])
        #expect(ComposeDraftGuards.committedRecipients(
            tokens: ["first@example.com"], input: "second@example.com")
            == ["first@example.com", "second@example.com"])
        // Whitespace-only input must not add a bogus recipient.
        #expect(ComposeDraftGuards.committedRecipients(
            tokens: ["first@example.com"], input: "   ") == ["first@example.com"])
    }

    @Test("A loaded draft cleared to nothing prompts instead of silently vanishing")
    func clearedLoadedRowPrompts() {
        // The load-bearing distinction: an EXISTING row the user emptied must ask
        // first; a brand-new/absent one is delete-eligible without a prompt.
        #expect(ComposeDraftGuards.closeAction(
            readState: .loaded, hasContent: false, hasChanges: true) == .promptDelete)
        #expect(ComposeDraftGuards.closeAction(
            readState: .loaded, hasContent: false, hasChanges: false) == .promptDelete)
        #expect(ComposeDraftGuards.closeAction(
            readState: .notFound, hasContent: false, hasChanges: true) == .deleteThenDismiss)
        #expect(ComposeDraftGuards.closeAction(
            readState: .notFound, hasContent: false, hasChanges: false) == .deleteThenDismiss)
    }

    @Test("A cleared loaded draft still exists while its confirmation prompt is on screen")
    func clearedRowSurvivesUntilConfirmed() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        let row = emptyDraft()
        try db.write { try row.insert($0) }
        // Reaching the decision must have NO durable effect of its own.
        let action = ComposeDraftGuards.closeAction(
            readState: .loaded, hasContent: false, hasChanges: true)
        #expect(action == .promptDelete)
        #expect(try db.read { try Draft.fetchOne($0, key: row.id) } != nil)
    }

    @Test("A failed local delete keeps the compose open instead of dismissing")
    func failedDeleteDoesNotDismiss() async {
        var dismissed = false
        var surfaced: Error?
        await ComposeDraftGuards.runCheckedLocalDeleteThenDismiss(
            delete: { throw BusyWriterFailure() },
            dismiss: { dismissed = true },
            onDeleteFailure: { surfaced = $0 })
        #expect(!dismissed)
        guard let surfaced else {
            Issue.record("expected the failed delete to surface an error")
            return
        }
        #expect(surfaced is BusyWriterFailure)
    }

    @Test("Dismiss runs only after the delete has landed durably")
    func dismissRunsAfterTheDeleteLands() async throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        let row = emptyDraft()
        try await db.write { try row.insert($0) }

        var rowStillPresentAtDismiss: Bool?
        var dismissed = false
        await ComposeDraftGuards.runCheckedLocalDeleteThenDismiss(
            delete: {
                try db.write {
                    try DraftStore.applyDelete(
                        id: row.id, expectedInstanceEpoch: "E1", db: $0)
                }
            },
            dismiss: {
                // ORDER, not just outcome: at the instant the UI acknowledges, the
                // durable delete must already have committed.
                rowStillPresentAtDismiss =
                    ((try? db.read { try Draft.fetchOne($0, key: row.id) }) ?? nil) != nil
                dismissed = true
            },
            onDeleteFailure: { _ in })
        #expect(dismissed)
        #expect(rowStillPresentAtDismiss == false)
        #expect(try await db.read { try Draft.fetchOne($0, key: row.id) } == nil)
    }

    // MARK: R7 — a refused DURABLE draft-queue admission must not dismiss

    /// 🚨 THE INVARIANT THIS PINS — stated as the system property, not as the
    /// mechanism (`MIS-015`): **when the durable draft-queue admission fails, the
    /// compose is NOT dismissed and the user is told.**
    ///
    /// It is deliberately NOT "the `Bool` is read". `AccountManager.queueDraftSave`
    /// mints the visible Drafts-folder `MessageHeader`, the `MessageBody` and the
    /// durable `.saveDraft` `PendingOperation` in one write transaction, so on
    /// `false` the user's authored text is committed to `Draft` but has no route
    /// back to it — drafts open header-led and `DraftStore.loadAll()` has zero
    /// production callers — and `SyncEngineMaintenance` later evicts it outright.
    /// Dismissing there acknowledges a save whose content is unreachable and is then
    /// destroyed: a dropped user intention with no sync recovery. The compose is the
    /// user's last chance, exactly as Outbox Reliability Rule 1 has it for `send()`.
    @Test("A refused durable draft-save keeps the compose open instead of dismissing")
    func refusedDurableSaveKeepsTheComposeOpen() async {
        var dismissed = false
        var toldTheUser = false
        await ComposeDraftGuards.runCheckedDurableSaveThenDismiss(
            save: { false },
            dismiss: { dismissed = true },
            onAdmissionFailure: { toldTheUser = true })
        // The whole property: the authored text stays on screen, AND the failure is
        // surfaced rather than swallowed. Both halves, or the user silently loses it.
        #expect(!dismissed, "a refused durable save must never dismiss the compose")
        #expect(toldTheUser, "a refused durable save must surface an error")
    }

    /// TWO-SIDED NON-VACUITY ANCHOR. Without this, `refusedDurableSaveKeepsTheComposeOpen`
    /// would still pass against a guard that never dismisses at all — which would be a
    /// different defect (the compose could never be closed by Save). This is the side
    /// that must stay GREEN when the fix is inverted, and it is written from the
    /// inversion's printed output rather than from reading the guard (`MIS-024` #4).
    @Test("An admitted durable draft-save dismisses and surfaces nothing")
    func admittedDurableSaveDismisses() async {
        var dismissed = false
        var toldTheUser = false
        await ComposeDraftGuards.runCheckedDurableSaveThenDismiss(
            save: { true },
            dismiss: { dismissed = true },
            onAdmissionFailure: { toldTheUser = true })
        #expect(dismissed, "an admitted durable save must dismiss")
        #expect(!toldTheUser, "an admitted durable save must not surface an error")
    }

    /// ORDER, not just outcome — the sibling `dismissRunsAfterTheDeleteLands` applied
    /// to this path: at the instant the UI acknowledges the save, the durable
    /// producer must already have returned its verdict.
    @Test("Dismiss runs only after the durable save has reported success")
    func dismissRunsOnlyAfterTheDurableSaveReports() async {
        var saveCompleted = false
        var saveHadCompletedAtDismiss: Bool?
        await ComposeDraftGuards.runCheckedDurableSaveThenDismiss(
            save: {
                saveCompleted = true
                return true
            },
            dismiss: { saveHadCompletedAtDismiss = saveCompleted },
            onAdmissionFailure: { })
        #expect(saveHadCompletedAtDismiss == true)
    }

    // MARK: D8 — fail-closed account binding

    @Test("A persisted draft whose owning account is unresolvable binds nothing")
    func unresolvableOwnerBindsNothing() throws {
        let db = try TestDatabase.make()
        // A DIFFERENT account exists — the exact fallback the removed
        // `navigationStore.accounts.first` / `resolvedAccount` chain would have
        // bound the draft to.
        try TestDatabase.insertAccount(db, id: "other-acct", email: "other@example.com")
        let orphan = emptyDraft(id: "draft-orphan", accountId: "missing-acct")

        // Resolution is exactly what the presenter performs.
        let resolved = try db.read { try Account.fetchOne($0, key: orphan.accountId) }
        #expect(resolved == nil)
        #expect(!ComposeDraftGuards.mayBindPersistedDraft(
            draftAccountId: orphan.accountId, resolvedAccountId: resolved?.id))

        // Non-vacuity of the hazard: a wrong account WAS available to bind to, and
        // it is not the row's owner — so the refusal is doing real work.
        let fallbackCandidates = try db.read { try Account.fetchAll($0) }
        #expect(fallbackCandidates.count == 1)
        guard fallbackCandidates.count == 1 else { return }
        #expect(fallbackCandidates[0].id != orphan.accountId)
        #expect(!ComposeDraftGuards.mayBindPersistedDraft(
            draftAccountId: orphan.accountId, resolvedAccountId: fallbackCandidates[0].id))
    }

    @Test("A persisted draft whose owning account resolves opens bound to that exact account")
    func resolvableOwnerBindsNormally() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "owner-acct", email: "owner@example.com")
        try TestDatabase.insertAccount(db, id: "other-acct", email: "other@example.com")
        let owned = emptyDraft(id: "draft-owned", accountId: "owner-acct")

        let resolved = try db.read { try Account.fetchOne($0, key: owned.accountId) }
        #expect(resolved?.id == "owner-acct")
        #expect(ComposeDraftGuards.mayBindPersistedDraft(
            draftAccountId: owned.accountId, resolvedAccountId: resolved?.id))
        // …and the sibling account is still refused, so the predicate is an
        // equality on the OWNER, not a non-nil check.
        #expect(!ComposeDraftGuards.mayBindPersistedDraft(
            draftAccountId: owned.accountId, resolvedAccountId: "other-acct"))
    }
}
