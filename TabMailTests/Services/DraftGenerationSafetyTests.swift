/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Synchronization
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
    /// `AccountManager.executeSingleOp`'s success path retire the durable
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

    /// **THE INVARIANT (R11-E): an unresolvable provider identity keeps the user's
    /// Save intention QUEUED, and only a lost generation CAS retires it.**
    ///
    /// The `.saveDraft` arm in `AccountManager.executeSingleOp` states outright
    /// that "EVERY DISPOSITION THAT REACHES THIS LINE IS A RETIREMENT", so a returned
    /// `.notApplied` drops the intention. `runtimeKind == .unknown` is an ABSENCE OF
    /// EVIDENCE — never-drop clause 2 names "an unresolvable identity" as retryable,
    /// not provider-authoritative — so it must leave through the THROW that the queue
    /// classifies as a retry, exactly as the sibling `.deleteDraft` arm in the same
    /// switch already does.
    ///
    /// ⚠️ TWO-SIDED (`feedback_non_vacuity_must_be_two_sided`). A guard that simply
    /// threw for everything would satisfy the first leg alone, so the second leg pins
    /// the opposite verdict on the same call: a genuinely lost CAS still returns
    /// `.notApplied` and is still retired. Both legs also assert the PROVIDER CALL
    /// COUNT, so "did not retire" cannot be confused with "sent the draft anyway".
    @Test("An unresolvable provider kind throws instead of retiring the Save, while a lost CAS still retires")
    func unknownRuntimeKindThrowsAndLostCasStillRetires() async throws {
        let fixture = try install()
        defer { finish(fixture) }
        let initial = draft()
        try await fixture.0.writeWithoutTransaction { try initial.insert($0) }

        // LEG 1 — the draft is perfectly pushable; only the runtime kind is
        // unresolvable. It must THROW, touch no provider, and stay pushable.
        let unusedProvider = MockEmailProvider(
            saveDraftResult: .created(.outlook(graphId: "must-not-be-used")))
        var thrown: Error?
        do {
            _ = try await DraftStore.shared.pushDraftToServer(
                draftId: initial.id, expectedInstanceEpoch: "E1", provider: unusedProvider,
                runtimeKind: .unknown, draftsFolderPath: "Drafts")
        } catch { thrown = error }
        guard let providerError = thrown as? ProviderError,
              case .actionIdentityResolutionFailed = providerError else {
            Issue.record(
                "an unknown runtime kind returned normally — the `.saveDraft` arm reads any normal return as a retirement and drops the user's Save intention (got \(String(describing: thrown)))")
            return
        }
        let unusedCalls = await unusedProvider.callLog
        #expect(unusedCalls.filter { $0.hasPrefix("saveDraft") }.isEmpty)

        // ⚠️ CORRECTED 2026-08-06 (R12-T4). This used to read "The intention survives
        // intact: a later drain that CAN resolve the kind lands the very same row."
        // **That is false of the ASSEMBLED SYSTEM and it is the sentence that let
        // round 11's `eff3ded9d` ship believing it had stopped a drop.** This test
        // calls `pushDraftToServer` DIRECTLY and never runs the drain's classifier;
        // in the real drain `ProviderError.actionIdentityResolutionFailed` is the
        // TERMINAL-DROP signal, so the durable `PendingOperation` row IS deleted and
        // no later drain re-attempts anything. What genuinely survives — and all this
        // leg may claim — is the LOCAL `Draft` row: the authored text is intact and
        // remains pushable by any caller that can resolve the kind, which is what the
        // next four lines actually demonstrate.
        //
        // The assembled-system property is pinned where it belongs, at the drain:
        // `NeverDropExitClosureTests.anUnresolvableDraftKindRetiresTheProducerButNotTheAuthoredText`.
        // Read that test's adjudication (`IOS-QUEUE-003` item 4, `IOS-DRAFT-018`)
        // before changing either.
        //
        // The local row is still pushable once the kind resolves:
        let retryProvider = MockEmailProvider(
            saveDraftResult: .created(.outlook(graphId: "resolved-resource")))
        let retry = try await DraftStore.shared.pushDraftToServer(
            draftId: initial.id, expectedInstanceEpoch: "E1", provider: retryProvider,
            runtimeKind: .outlook, draftsFolderPath: "Drafts")
        #expect(retry == .completed)
        let live = try await fixture.0.read { try Draft.fetchOne($0, key: initial.id) }
        #expect(live?.serverDraftId == "resolved-resource")

        // LEG 2 — a genuinely lost generation CAS is exit 3 and STILL retires. A
        // FRESH row (never pushed, status nil) so the ONLY failing condition is the
        // epoch: on `initial` the completed push above would also have failed the
        // status test, and the verdict would not be attributable to the CAS.
        let superseded = draft(id: "draft-2", epoch: "E1")
        try await fixture.0.writeWithoutTransaction { try superseded.insert($0) }
        let staleProvider = MockEmailProvider(
            saveDraftResult: .created(.outlook(graphId: "must-not-be-used-either")))
        let stale = try await DraftStore.shared.pushDraftToServer(
            draftId: superseded.id, expectedInstanceEpoch: "E0-superseded", provider: staleProvider,
            runtimeKind: .outlook, draftsFolderPath: "Drafts")
        #expect(stale == .notApplied,
                "a superseded generation is a provider-authoritative exit 3 and must still retire")
        let staleCalls = await staleProvider.callLog
        #expect(staleCalls.filter { $0.hasPrefix("saveDraft") }.isEmpty)
    }

    // MARK: R16-2 — promoting the placeholder must carry the header's children

    /// 🚨 THE INVARIANT, stated as the system property rather than the mechanism
    /// (`MIS-015`): **after a draft placeholder is promoted to the server's real
    /// identity, the message's user labels and its threading edges still exist
    /// against the address the message now has.** No assertion here names
    /// `MessageHeaderRekey.apply`; any carrier that keeps them reachable passes.
    ///
    /// `DraftStore.migrateExactPlaceholder` is a header PRIMARY-KEY change, so it is a
    /// member of the class *"every code path that changes a header's primary key"* —
    /// and it had exactly the gap `BackfillBodyQueue.rekeyRemappedHeader` did: it
    /// carried the BODY by hand and let `placeholder.delete(db)` cascade
    /// `messageUserLabel` and `messageReference` away. `messageReference` is the one
    /// that bites here — a REPLY draft carries `In-Reply-To`, so its edge to the
    /// message being replied to was destroyed at the exact moment the placeholder
    /// became the real draft, dropping the user's own reply out of the conversation
    /// it belongs to. That is `MIS-006`: the instance fixed, the class left open.
    ///
    /// Asserted at the STORE, as end state. The promoted id is the server address
    /// (`accountId:draftsFolder:<graphId>`), so the assertion also proves the carry
    /// landed on the NEW key and not merely that some row survived somewhere.
    @Test("Promoting a draft placeholder carries its labels and threading edges to the real id")
    func placeholderPromotionCarriesLabelsAndThreadEdges() async throws {
        let fixture = try install()
        defer { finish(fixture) }
        let initial = draft(id: "reply-draft-1", epoch: "E1")
        let parentRfc = "r16-2-parent@example.com"
        let placeholderId = PendingOperation.draftPlaceholderHeaderPK(
            accountId: "acc1", draftsFolderPath: "Drafts",
            draftId: initial.id, instanceEpoch: "E1")
        let promotedId = "acc1:Drafts:mock-graph-id"

        try await fixture.0.writeWithoutTransaction { db in
            try initial.insert(db)
            try Folder(name: "Drafts", path: "Drafts", role: .drafts, accountId: "acc1").insert(db)
            var placeholder = MessageHeader(
                messageId: PendingOperation.draftPlaceholderMessageId(
                    draftId: initial.id, instanceEpoch: "E1"),
                subject: "Re: fixture", from: "Owner", fromAddress: "owner@example.com",
                to: "peer@example.com", date: Date(), snippet: "",
                folderId: "acc1:Drafts", accountId: "acc1", folderPath: "Drafts",
                isInInbox: false)
            placeholder.inReplyTo = parentRfc
            try placeholder.insert(db)
            try ThreadUtils.insertMessageReferences(for: placeholder, db: db)
            let label = UserLabel(
                accountId: "acc1", providerLabelId: "follow-up", name: "Follow up", isSystem: false)
            try label.insert(db, onConflict: .ignore)
            try MessageUserLabel(messageId: placeholder.id, userLabelId: label.id).insert(db)
        }

        // MIS-030 — anchor the fixture: the placeholder id this test computed really
        // is the row the promotion will migrate, and it really does carry both children.
        #expect(try await fixture.0.read { try MessageHeader.fetchOne($0, key: placeholderId) } != nil,
                "precondition: the placeholder header exists at the id the promotion looks up")
        #expect(try await fixture.0.read {
            try MessageUserLabel.filter(Column("messageId") == placeholderId).fetchCount($0)
        } == 1, "precondition: the user applied a label to the draft")
        #expect(try await fixture.0.read {
            try Int.fetchOne(
                $0, sql: "SELECT COUNT(*) FROM messageReference WHERE messageHeaderId = ?",
                arguments: [placeholderId])
        } == 1, "precondition: the reply draft has a threading edge to its parent")

        let provider = MockEmailProvider(
            saveDraftResult: .created(.outlook(graphId: "mock-graph-id")))
        let result = try await DraftStore.shared.pushDraftToServer(
            draftId: initial.id, expectedInstanceEpoch: "E1", provider: provider,
            runtimeKind: .outlook, draftsFolderPath: "Drafts")
        #expect(result == .completed, "setup: the push must have completed for a promotion to occur")

        #expect(try await fixture.0.read { try MessageHeader.fetchOne($0, key: promotedId) } != nil,
                "setup: the placeholder must have been promoted to the server address")
        let carriedLabels = try await fixture.0.read {
            try MessageUserLabel.filter(Column("messageId") == promotedId).fetchAll($0)
        }
        #expect(carriedLabels.count == 1,
                """
                the user's label must follow the draft to the identity the server assigned — \
                the placeholder delete cascades `messageUserLabel` and NOTHING in the \
                database can rebuild it, so a promotion that does not carry it destroys the \
                label silently and permanently. Got \(carriedLabels.count)
                """)
        guard carriedLabels.count == 1 else { return }
        #expect(carriedLabels[0].userLabelId == "acc1:follow-up")

        let edges = try await fixture.0.read {
            try String.fetchAll(
                $0, sql: "SELECT referencedRfc822Id FROM messageReference WHERE messageHeaderId = ?",
                arguments: [promotedId])
        }
        #expect(edges == [parentRfc],
                """
                and the reply's threading edge must exist at the promoted id, or the user's \
                own reply falls out of the conversation it answers. Got \(edges)
                """)
        #expect(try await fixture.0.read {
            try MessageUserLabel.filter(Column("messageId") == placeholderId).fetchCount($0)
        } == 0, "and nothing may be left filed under the retired placeholder id")
    }

    /// **THE MIRROR IMAGE OF THE `"pushing"`-RESIDUE FIX, AND IT IS WORSE THAN THE
    /// BUG (`MIS-005`): a draft whose provider save is GENUINELY LIVE in this
    /// process must never be pushed a second time.**
    ///
    /// `pushDraftToServer` now re-admits a `serverPushStatus == "pushing"` row
    /// instead of returning `.notApplied` on it, because that residue can be
    /// orphaned inside a live process (an in-process clear-arm whose own DB write
    /// threw) and retiring the durable Save producer on it drops a user intention —
    /// pinned at
    /// `NeverDropExitClosureTests.inProcessPushingResidueNeverRetiresItsSaveProducer`.
    /// Read naively, that re-admission would also fire while the first attempt's
    /// APPEND is still on the wire, duplicating the draft under a live race. That is
    /// the `IOS-OUTBOX-006` shape, and it is the direction this test holds shut.
    ///
    /// **IT IS REACHABLE, NOT DEFENSIVE.** `executeSingleOp` wraps `executeOperation`
    /// in `withTimeout`, whose own doc comment says the operation task is
    /// "abandoned", and cancellation is cooperative — so a slow APPEND is still live
    /// when a later drain re-claims the same durable op. `DraftStore` is an `actor`
    /// and `pushDraftToServer` `await`s across the provider call, so actor isolation
    /// alone does not exclude the second entry; that reentrancy is exactly the
    /// question `KNOWN_ISSUES.md` `IOS-DRAFT-016` left open, and the in-process
    /// claim answers it without needing a reentrancy proof.
    ///
    /// **TWO-SIDED** (`feedback_non_vacuity_must_be_two_sided`): a claim that simply
    /// refused forever would satisfy leg 1 alone, so leg 2 pins RELEASE — after the
    /// first push returns, the claim is gone and an ordinary later push reaches a
    /// provider and completes. The refusal is also asserted to be a THROW rather
    /// than a returned disposition, because every disposition the `.saveDraft` arm
    /// receives retires the durable producer.
    @Test("A live push blocks a second push for the same draft, and releasing restores admission")
    func aLivePushBlocksASecondPushForTheSameDraft() async throws {
        let fixture = try install()
        defer { finish(fixture) }
        let initial = draft()
        try await fixture.0.writeWithoutTransaction { try initial.insert($0) }

        // The SECOND push gets its own provider, so a wrongly-admitted re-entry
        // records a `saveDraft` call HERE rather than recursing into the hook.
        let concurrentProvider = MockEmailProvider(
            saveDraftResult: .created(.outlook(graphId: "must-not-be-created")))
        let secondAttempt = Mutex<String>("never ran")
        let claimedDuringCall = Mutex<Bool>(false)

        let firstProvider = MockEmailProvider(
            saveDraftResult: .created(.outlook(graphId: "first-resource")))
        await firstProvider.setSaveDraftHook { [id = initial.id] in
            // Runs INSIDE the provider call: the row is durably `"pushing"` and the
            // save is genuinely on the wire — the window no before/after snapshot
            // can observe.
            claimedDuringCall.withLock { $0 = DraftStore.isPushInFlightForTesting(id) }
            do {
                let disposition = try await DraftStore.shared.pushDraftToServer(
                    draftId: id, expectedInstanceEpoch: "E1", provider: concurrentProvider,
                    runtimeKind: .outlook, draftsFolderPath: "Drafts")
                secondAttempt.withLock { $0 = "returned \(disposition)" }
            } catch {
                secondAttempt.withLock { $0 = "threw" }
            }
        }

        let first = try await DraftStore.shared.pushDraftToServer(
            draftId: initial.id, expectedInstanceEpoch: "E1", provider: firstProvider,
            runtimeKind: .outlook, draftsFolderPath: "Drafts")

        // LEG 1 — nothing was pushed twice, and the refusal was not a disposition.
        let concurrentCalls = await concurrentProvider.callLog
        #expect(
            concurrentCalls.filter { $0.hasPrefix("saveDraft") }.isEmpty,
            """
            a second push reached the provider while the first was still on the wire — that \
            duplicates the user's draft on the server under a live race, which is strictly worse \
            than the dropped producer the re-admission exists to prevent: \(concurrentCalls)
            """)
        #expect(
            secondAttempt.withLock({ $0 }) == "threw",
            """
            the concurrent push returned a disposition instead of throwing; every disposition the \
            `.saveDraft` arm receives RETIRES the durable Save producer, so a returned value here \
            drops the intention that the live attempt may yet fail to satisfy — got \
            \(secondAttempt.withLock { $0 })
            """)
        #expect(claimedDuringCall.withLock { $0 },
                "the claim must be HELD across the provider call, not merely around the DB writes")

        // The first attempt itself is unaffected.
        #expect(first == .completed)
        let firstCalls = await firstProvider.callLog
        #expect(firstCalls.filter { $0.hasPrefix("saveDraft") }.count == 1)
        let pushed = try await fixture.0.read { try Draft.fetchOne($0, key: initial.id) }
        #expect(pushed?.serverDraftId == "first-resource")

        // LEG 2 — RELEASE. A claim that never released would be a permanent wedge,
        // which the wedge corollary puts in the same non-recoverable set as a drop.
        #expect(!DraftStore.isPushInFlightForTesting(initial.id),
                "the claim outlived the push — every later attempt on this draft would be refused forever")
        try await fixture.0.write { db in
            guard var edited = try Draft.fetchOne(db, key: initial.id) else { return }
            edited.body = "second edit"
            edited.updatedAt += 1
            _ = try DraftStore.applySave(edited, db: db)
        }
        let laterProvider = MockEmailProvider(
            saveDraftResult: .created(.outlook(graphId: "second-resource")))
        let later = try await DraftStore.shared.pushDraftToServer(
            draftId: initial.id, expectedInstanceEpoch: "E1", provider: laterProvider,
            runtimeKind: .outlook, draftsFolderPath: "Drafts")
        #expect(later == .completed)
        let laterCalls = await laterProvider.callLog
        #expect(
            laterCalls.filter { $0.hasPrefix("saveDraft") }.count == 1,
            "an ordinary later push never reached the provider — the claim is a wedge, not a fence: \(laterCalls)")
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
        //
        // ⚠ This assertion read `== .dismiss` until 2026-08-05 and was a BLESSING
        // TEST: it pinned the DECISION rather than the property, so it held the
        // `.error` + unsaved-edits case at "dismiss silently" — dropping the
        // user's authored text with none of the confirmation every other
        // content-bearing close shows. The invariant was always "`.error` never
        // authorizes a WRITE", which `closeActionWrites` states directly; a close
        // that merely ASKS before discarding satisfies it.
        for hasContent in [true, false] {
            for hasChanges in [true, false] {
                let action = ComposeDraftGuards.closeAction(
                    readState: state, hasContent: hasContent, hasChanges: hasChanges)
                #expect(!ComposeDraftGuards.closeActionWrites(action),
                        "a thrown read must never authorize a save, overwrite or delete")
                #expect(action != .promptSave,
                        "and must never offer Save, which would overwrite a row we could not read")
            }
        }
        // The other half, which the old assertion hid: a close that WOULD drop
        // authored edits asks first, even under a read error.
        #expect(ComposeDraftGuards.closeAction(
            readState: state, hasContent: true, hasChanges: true) == .promptDiscardEdits)
        // …and one with nothing to lose still just dismisses, so the prompt has
        // not simply been made unconditional.
        #expect(ComposeDraftGuards.closeAction(
            readState: state, hasContent: true, hasChanges: false) == .dismiss)
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
        case .promptSave, .dismiss, .promptDiscardEdits:
            // `.promptDiscardEdits` confirms then DISMISSES — it writes nothing,
            // so the unread row on disk is left exactly as it was.
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

    // MARK: R14-F3 — the same verdict on the path with nothing to dismiss

    /// 🚨 THE INVARIANT THIS PINS — the system property, not the mechanism
    /// (`MIS-015`): **when the durable draft-queue producer REFUSES, the user is
    /// told, so the authored content is still reachable by one ordinary gesture.**
    ///
    /// The agent-chat compose surface (`DynamicIslandChat.autoSaveDraft`) auto-saves
    /// after every compose-edit turn and has no dismissal to gate — the sheet is
    /// open before and after. So the sibling's "does not dismiss" half is vacuous
    /// here and the whole property rests on the OTHER half: a refusal that is not
    /// surfaced is indistinguishable from a save that worked. Until R14-F3 the
    /// verdict was discarded outright (`queueDraftSave` is `@discardableResult`),
    /// which left the user's text committed to `Draft` with no Drafts-folder
    /// `MessageHeader` to open it by, and `SyncEngineMaintenance` trimming the row
    /// later — a dropped intention with no sync recovery, exactly as on the
    /// `ComposeView` path.
    ///
    /// ⚠️ It is deliberately NOT "the local `Draft` row is rolled back". That is the
    /// mirror image: it would destroy the authored text this guard exists to keep.
    @Test("A refused durable auto-save surfaces the failure instead of passing silently")
    func refusedDurableAutoSaveSurfacesTheFailure() async {
        var toldTheUser = false
        await ComposeDraftGuards.runCheckedDurableAutoSave(
            save: { false },
            onAdmissionFailure: { toldTheUser = true })
        #expect(toldTheUser,
                "a refused durable auto-save must surface the failure — on this path nothing else can, because there is no dismissal to withhold and the compose sheet looks identical either way")
    }

    /// TWO-SIDED NON-VACUITY ANCHOR (`MIS-030`). Without this,
    /// `refusedDurableAutoSaveSurfacesTheFailure` would still pass against a guard
    /// that warns on EVERY save — which would be its own defect: a warning the user
    /// sees after every successful agent compose-edit turn is noise they learn to
    /// ignore, and it would be showing on the exact path that is working. This is
    /// the side that must stay GREEN when the fix is inverted.
    @Test("An admitted durable auto-save surfaces nothing")
    func admittedDurableAutoSaveSurfacesNothing() async {
        var toldTheUser = false
        await ComposeDraftGuards.runCheckedDurableAutoSave(
            save: { true },
            onAdmissionFailure: { toldTheUser = true })
        #expect(!toldTheUser, "an admitted durable auto-save must not warn the user")
    }

    // MARK: R15-FIX-1 — the R14-F3 class, not just its instance

    /// 🚨 THE INVARIANT THIS PINS — the system property, not the mechanism
    /// (`MIS-015`): **a durable auto-save that fails for a reason other than losing a
    /// generation CAS produces a user-visible warning.**
    ///
    /// R14-F3 closed exactly ONE exit of `DynamicIslandChat.autoSaveDraft` — the
    /// refused durable admission, pinned by the two tests directly above. Every
    /// EARLIER exit of the same function still returned silently, and those are the
    /// *more likely* failure modes: a thrown predecessor read, a thrown save on
    /// either branch, and an unresolvable owning account. On each of them the user's
    /// typed text is stranded with no signal whatsoever — the compose sheet looks
    /// identical to a successful turn, and on this surface there is no dismissal to
    /// withhold. That is `MIS-006`: the instance fixed, the class left open.
    ///
    /// Asserted as a SET, not case-by-case, so a future exit added to the roster and
    /// classified silent breaks this test instead of joining the silent majority.
    @Test("Every determinable auto-save failure warns the user")
    func everyDeterminableAutoSaveFailureWarnsTheUser() {
        let warning = Set(ComposeDraftGuards.AutoSaveExit.allCases
            .filter { ComposeDraftGuards.autoSaveExitWarnsUser($0) })
        #expect(warning == [
            .predecessorReadFailed,
            .updateSaveFailed,
            .noAccountForFirstSave,
            .firstSaveFailed,
            .attachmentCarryIncomplete,
            .durableAdmissionRefused,
        ], "a thrown read, a thrown write on either branch, an unresolvable account and a refused durable admission are all 'we could not do it' — never provider-authoritative success — so each must reach the user")
        // Non-vacuity: the hazard is real only if these exits exist at all.
        #expect(warning.count == 6)
    }

    /// TWO-SIDED ANCHOR — the DELIBERATELY HELD direction (`MIS-026`). Without this,
    /// `everyDeterminableAutoSaveFailureWarnsTheUser` would still pass against a
    /// guard that warns on EVERY exit, which is the mirror image and its own defect:
    ///
    /// > Do not warn merely because `cursor.admit` returns a non-applied CAS result —
    /// > a newer generation may already have durably won, and warning there would
    /// > report a false failure. The correct opposite direction is to surface actual
    /// > read/write/account-resolution failures while retaining the silent
    /// > newer-generation no-op.
    ///
    /// A lost CAS is not a failure at all: a NEWER save of the same draft already
    /// landed durably, so the user's text is safe and a warning there is a lie that
    /// trains them to ignore the channel. `.composeUnavailable` is held silent for a
    /// different reason — `autoSaveDraft`'s single caller, `sendComposeEdit`, already
    /// returns early with its own dedicated warning on the same conditions, so
    /// warning here would double-report one cause.
    ///
    /// This is the side that must stay GREEN when the fix is inverted toward
    /// blanket-warning.
    @Test("A lost-generation auto-save no-op warns nothing")
    func aLostGenerationAutoSaveNoOpWarnsNothing() {
        let silent = Set(ComposeDraftGuards.AutoSaveExit.allCases
            .filter { !ComposeDraftGuards.autoSaveExitWarnsUser($0) })
        #expect(silent == [
            .updateLostGeneration,
            .firstSaveLostGeneration,
            .composeUnavailable,
        ], "only a CAS no-op (a newer generation durably won) or an entry condition already warned upstream may pass silently")
        #expect(silent.count == 3)
        // The roster is exhaustive: every exit is classified exactly once, so a new
        // one cannot be added without landing in one of the two asserted sets.
        #expect(silent.count + ComposeDraftGuards.AutoSaveExit.allCases
            .filter({ ComposeDraftGuards.autoSaveExitWarnsUser($0) }).count
            == ComposeDraftGuards.AutoSaveExit.allCases.count)
    }

    // MARK: R16-3 — the pill's claim must match the SAVE OUTCOME

    /// 🚨 THE INVARIANT (the system property, `MIS-015`): **no exit that leaves no
    /// durable draft may be reported as one that does** — i.e. the global
    /// "Draft updated — tap to review" signal is reachable only from an exit after
    /// which a durable draft actually exists.
    ///
    /// The defect: `DynamicIslandChatButton` published that pending response 41 lines
    /// BEFORE the `await autoSaveDraft(…)` it announces, so a failed first save still
    /// offered the Inbox a success pill. Tapping it reached
    /// `DraftComposePresenter`'s `case .notFound: Color.clear.onAppear { dismiss() }`
    /// — a success signal that opens NOTHING, for generated content that was never
    /// committed and that no sync can recreate. `finishAutoSave`'s warning could not
    /// cover it: that is a chat `.warning`, invisible once the compose sheet is gone,
    /// which is precisely the situation the pill exists for.
    ///
    /// ⚠️ A DIFFERENT QUESTION FROM `autoSaveExitWarnsUser`, and the two disagree on
    /// exactly the CAS exits — which is why this is a second roster and not a reuse.
    /// That one asks *"must a warning appear in this transcript?"*; this asks
    /// *"may a global, cross-view signal claim a reviewable draft exists?"*.
    ///
    /// Asserted as a SET over `allCases`, so an exit added to the roster and left
    /// unclassified breaks this test instead of silently joining the claiming side.
    @Test("Only a lost generation CAS leaves a durable draft the pill may claim")
    func onlyALostGenerationLeavesADurableDraft() {
        let claimable = Set(ComposeDraftGuards.AutoSaveExit.allCases
            .filter { ComposeDraftGuards.autoSaveExitLeftDurableDraft($0) })
        #expect(claimable == [
            .updateLostGeneration,
            .firstSaveLostGeneration,
        ], "a NEWER generation durably won the write, so a reviewable draft does exist and that generation publishes its own signal — these are the only two exits after which 'Draft updated — tap to review' is true")
        #expect(claimable.count == 2)
    }

    /// TWO-SIDED ANCHOR — the side that must go RED when the fix is inverted, and the
    /// reason the roster above cannot be satisfied by returning `true` everywhere.
    ///
    /// The `false` set is every exit that ends with NO row written by anyone: a thrown
    /// predecessor read, a thrown save on either branch, an unresolvable owning
    /// account, and a refused durable admission. `.composeUnavailable` is `false` for
    /// a different reason — the turn's own state went away mid-flight, so this turn
    /// has no evidence either way and must not assert one (never-drop clause 2: an
    /// absence of evidence is not a positive result).
    ///
    /// The exhaustiveness assertion at the end is what makes the pair a partition:
    /// every one of the nine cases is classified exactly once, so a tenth cannot be
    /// added without landing in one of the two asserted sets.
    @Test("Every auto-save exit that wrote nothing must not be claimed as a saved draft")
    func exitsThatWroteNothingAreNotClaimedAsSaved() {
        let notClaimable = Set(ComposeDraftGuards.AutoSaveExit.allCases
            .filter { !ComposeDraftGuards.autoSaveExitLeftDurableDraft($0) })
        #expect(notClaimable == [
            .composeUnavailable,
            .predecessorReadFailed,
            .updateSaveFailed,
            .noAccountForFirstSave,
            .firstSaveFailed,
            .attachmentCarryIncomplete,
            .durableAdmissionRefused,
        ], "after each of these the user's generated text is NOT in the Drafts route, so a global 'tap to review' pill would open nothing — the exact dead signal R16-3 removed")
        #expect(notClaimable.count == 7)
        // The roster is a PARTITION of the enum: nine cases, classified once each.
        #expect(notClaimable.count + ComposeDraftGuards.AutoSaveExit.allCases
            .filter({ ComposeDraftGuards.autoSaveExitLeftDurableDraft($0) }).count
            == ComposeDraftGuards.AutoSaveExit.allCases.count)
        #expect(ComposeDraftGuards.AutoSaveExit.allCases.count == 9,
                "non-vacuity: the original eight-exit class plus the attachment carry refusal are all classified")
    }

    // MARK: R17-5 — "no save was attempted" is not "the save landed"

    /// 🚨 THE INVARIANT (the system property, `MIS-015`): **the global
    /// "Draft updated — tap to review" signal is published only when this turn has
    /// POSITIVE evidence that a durable draft exists.** No assertion names the
    /// call site or the branch shape; any decision procedure that withholds the
    /// claim without evidence passes.
    ///
    /// R16-3 moved that publication below the save it announces, and R16 then
    /// re-created the symptom through a different door: the call site read
    /// `let landed = !autoSaveAttempted || (exit.map(…) ?? true)`, so the branch
    /// where NO SAVE WAS ATTEMPTED — `draftId == nil`, or `skipDraftAutoSave` —
    /// published the success text anyway. Tapping it reached
    /// `DraftComposePresenter`'s `case .notFound:` arm and dismissed instantly.
    ///
    /// The comment licensing it said *"the caller that set `skipDraftAutoSave`
    /// owns the save"*. It does not: `ComposeView.applyInlineEdit` calls
    /// `persistCachedReply` only `if replyTo != nil && !isForward`, so new-message
    /// and forward have no durable writer at all — and `persistCachedReply` writes
    /// `messageHeader.cachedReply`, not the `Draft` row the tap resolves.
    @Test("A compose-edit turn that attempted no save claims no durable draft")
    func noAttemptedSaveClaimsNoDurableDraft() {
        #expect(ComposeDraftGuards.composeEditGlobalSignal(
            autoSaveAttempted: false, autoSaveExit: nil) == ComposeDraftGuards.ComposeEditSignal.none,
                """
                `skipDraftAutoSave` / no `draftId` wrote nothing, so the turn has no \
                evidence a reviewable draft exists. Publishing the success text here \
                is a global claim that opens nothing
                """)
        // And it is not the WARNING either — nothing failed, nothing was tried.
        // Claiming "this draft couldn't be saved" would be the opposite falsehood.
        #expect(ComposeDraftGuards.composeEditGlobalSignal(
            autoSaveAttempted: false, autoSaveExit: nil) != .autoSaveDidNotLand)
        // An exit value cannot smuggle a claim past the attempted gate either.
        for exit in ComposeDraftGuards.AutoSaveExit.allCases {
            #expect(ComposeDraftGuards.composeEditGlobalSignal(
                autoSaveAttempted: false, autoSaveExit: exit) == ComposeDraftGuards.ComposeEditSignal.none,
                    "no save was attempted, so \(exit.rawValue) cannot license any claim")
        }
    }

    /// TWO-SIDED ANCHOR (`feedback_non_vacuity_must_be_two_sided`) — the side that
    /// goes RED if the fix is over-applied into "never claim anything". A turn that
    /// DID attempt the save and landed it must still publish the success text, and
    /// one that attempted and provably failed must still publish the warning;
    /// otherwise the R16-3 signal is silently deleted rather than made truthful.
    @Test("An attempted compose-edit save still reports its real outcome")
    func attemptedSaveStillReportsItsOutcome() {
        #expect(ComposeDraftGuards.composeEditGlobalSignal(
            autoSaveAttempted: true, autoSaveExit: nil) == .durableDraftAvailable,
                "a nil exit is `autoSaveDraft`'s success path — the durable row landed")
        for exit in ComposeDraftGuards.AutoSaveExit.allCases {
            let expected: ComposeDraftGuards.ComposeEditSignal =
                ComposeDraftGuards.autoSaveExitLeftDurableDraft(exit)
                ? .durableDraftAvailable : .autoSaveDidNotLand
            #expect(ComposeDraftGuards.composeEditGlobalSignal(
                autoSaveAttempted: true, autoSaveExit: exit) == expected,
                    "an ATTEMPTED save defers to the existing roster, unchanged, for \(exit.rawValue)")
        }
        // Non-vacuity: the loop above exercised BOTH signals, so it cannot pass by
        // the roster having collapsed to one side.
        let signals = Set(ComposeDraftGuards.AutoSaveExit.allCases.map {
            ComposeDraftGuards.composeEditGlobalSignal(autoSaveAttempted: true, autoSaveExit: $0)
        })
        #expect(signals == [.durableDraftAvailable, .autoSaveDidNotLand])
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

// MARK: - Round-9: the two compose gestures that dropped authored content

/// Both invariants here are about the same thing from opposite ends: a compose
/// window is frequently the ONLY copy of what the user just wrote, so no gesture
/// may end its life while that text has not reached a store — and where the text
/// genuinely cannot be saved, the user is asked rather than told afterwards.
@Suite("Compose authored-content guards")
struct ComposeAuthoredContentGuardTests {

    // MARK: S4 — an explicit Save that cannot resolve an account

    @Test("""
    An explicit Save with no resolvable account is BLOCKED, never a silent \
    dismiss: the compose stays open holding the user's text instead of being \
    torn down before a single byte of it has been written anywhere
    """)
    func explicitSaveWithoutAnAccountIsBlockedNotDismissed() {
        // The production consequence, mirrored: `.blocked` surfaces and RETURNS,
        // `.save` goes on to write and eventually dismiss. `saveDraftAndDismiss`
        // switches on exactly this verdict, and its `.blocked` arm is a bare
        // `return` — it dismissed instead until 2026-08-05, discarding the
        // composer BEFORE committing the pending recipient input and before
        // writing the Draft, its header, its body or the durable `.saveDraft`
        // operation.
        var dismissed = false
        var wroteAnything = false
        var surfacedReason = false

        func applyExplicitSaveDecision(resolved: Account?) {
            switch ComposeDraftGuards.saveAccount(resolved: resolved) {
            case .blocked:
                surfacedReason = true
            case .save:
                wroteAnything = true
                dismissed = true
            }
        }

        applyExplicitSaveDecision(resolved: nil)
        #expect(!dismissed,
                "the Save gesture must not tear down the compose that holds the only copy of the text")
        #expect(!wroteAnything, "and it must not half-write either")
        #expect(surfacedReason, "the user must be told why the save did not happen")
    }

    @Test("""
    Non-vacuity — a resolvable account still saves, against EXACTLY that \
    account, so the refusal above is not a blanket refusal
    """)
    func resolvableAccountStillSaves() {
        let account = Account(
            emailAddress: "user@example.com", displayName: "User", provider: .gmail)
        switch ComposeDraftGuards.saveAccount(resolved: account) {
        case .blocked:
            Issue.record("a resolvable account must not be refused")
        case .save(let bound):
            #expect(bound.id == account.id)
            #expect(bound.emailAddress == "user@example.com")
        }
    }

    // MARK: S5 — a read-error close that would drop unsaved edits

    @Test("""
    A close that would drop authored edits ALWAYS asks first — including under a \
    draft read error, where the compose used to be dismissed with none of the \
    confirmation every other content-bearing close shows
    """)
    func readErrorCloseWithUnsavedEditsAsksBeforeDiscarding() {
        let decision = ComposeDraftGuards.closeAction(
            readState: .error, hasContent: true, hasChanges: true)
        #expect(decision == .promptDiscardEdits)
        // …and the same is true for every other read state that holds unsaved
        // edits, so "ask before dropping authored edits" is the property, not a
        // special case bolted onto one branch.
        #expect(ComposeDraftGuards.closeAction(
            readState: .loaded, hasContent: true, hasChanges: true) == .promptSave)
        #expect(ComposeDraftGuards.closeAction(
            readState: .notFound, hasContent: true, hasChanges: true) == .promptSave)
    }

    @Test("""
    HELD DIRECTION — a read error still authorizes NO write, in every \
    combination: the prompt added above offers no Save, because saving would \
    overwrite a draft row we failed to read
    """)
    func readErrorStillAuthorizesNoWrite() {
        for hasContent in [true, false] {
            for hasChanges in [true, false] {
                let decision = ComposeDraftGuards.closeAction(
                    readState: .error, hasContent: hasContent, hasChanges: hasChanges)
                #expect(!ComposeDraftGuards.closeActionWrites(decision))
                #expect(decision != .promptSave)
                #expect(decision != .promptDelete)
                #expect(decision != .deleteThenDismiss)
            }
        }
        // Non-vacuity for the loop: `closeActionWrites` does not simply answer
        // `false` for everything — the writing decisions are still writing ones.
        #expect(ComposeDraftGuards.closeActionWrites(.promptSave))
        #expect(ComposeDraftGuards.closeActionWrites(.promptDelete))
        #expect(ComposeDraftGuards.closeActionWrites(.deleteThenDismiss))
        #expect(!ComposeDraftGuards.closeActionWrites(.dismiss))
        #expect(!ComposeDraftGuards.closeActionWrites(.promptDiscardEdits))
    }

    @Test("""
    A read-error close with nothing unsaved still dismisses outright — the new \
    confirmation is scoped to edits that would otherwise be lost, not made \
    unconditional
    """)
    func readErrorCloseWithoutUnsavedEditsStillDismisses() {
        #expect(ComposeDraftGuards.closeAction(
            readState: .error, hasContent: true, hasChanges: false) == .dismiss)
        #expect(ComposeDraftGuards.closeAction(
            readState: .error, hasContent: false, hasChanges: false) == .dismiss)
        #expect(ComposeDraftGuards.closeAction(
            readState: .error, hasContent: false, hasChanges: true) == .dismiss)
    }
}
