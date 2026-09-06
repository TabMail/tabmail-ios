/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Testing
@testable import TabMail

/// NO QUEUE-SIDE BATCH SPLITTING — per-member absence belongs to the provider.
///
/// The drain used to answer a multi-member not-found by writing one replacement
/// `PendingOperation` per member and deleting the parent, purely to discover
/// WHICH member was gone. That arm is deleted. Two properties replace it and
/// they fail in opposite directions, which is why every test below asserts one
/// of them explicitly:
///
/// **SAFETY.** A multi-member failure that carries no member-authoritative
/// result is UNRESOLVED. The row stays queued, with its original id, and
/// nothing is retired — including a failure that matches only
/// `isMessageNotFoundError`'s substring fallback (`NONEXISTENT`, `UID not
/// found`), which has dispositioned no member at all (`MIS-IOS-004`). "We could
/// not determine the answer" is never an exit.
///
/// **LIVENESS.** A member the server AUTHORITATIVELY reports gone must not
/// strand its siblings. The provider issues the per-member request, so the
/// provider is the only layer that can attribute the answer; it dispositions
/// that member and keeps going, and the surviving members still reach the wire
/// under the SAME operation.
///
/// Every test states a SYSTEM PROPERTY and reads it off the wire and the
/// durable queue — what the server ended up holding, how many times each member
/// was addressed, what the user is still owed. Nothing here names
/// `ProviderMembersDispositioned`, `confirmedGoneMembers` or any other type introduced
/// by the fix, deliberately: a test written against the mechanism inherits the
/// spec error it was supposed to catch (`MIS-015`), and these tests must be
/// compilable — and red — against the pre-fix tree.
///
/// **THE WIRE CALL COUNT IS HOW "no replacement child row is created" IS
/// OBSERVED.** A replacement child necessarily re-issues its member's request,
/// so "each member was addressed exactly once" is the observable consequence of
/// the split being gone, not a restatement of the mechanism. It is also the only
/// oracle available from outside: children were born and executed inside a
/// single `drainPendingQueue` call, so a post-drain row count cannot see them.
///
/// `.serialized, .processGlobalState` — swaps `AppDatabase.shared` and registers
/// providers on the `AccountManager` singleton.
@Suite("No queue-side batch splitting — per-member absence at the provider boundary",
       .serialized, .processGlobalState)
struct QueueMemberAbsenceTests {

    // MARK: - Harness (mirrors UserLabelWireValueTests.fixture / NeverDropExitClosureTests.fixture)

    private struct Fixture {
        let pool: DatabasePool
        let directory: URL
        let previous: AppDatabase?
        let accountId: String
    }

    private static let source = "INBOX"
    private static let destination = "Archive"

    /// A rendered provider failure whose ONLY claim to "not found" is its text.
    ///
    /// This is the real shape a failed IMAP command reaches the drain in: the
    /// tagged `NO` response, verbatim, inside an error whose type says nothing.
    /// `isMessageNotFoundError`'s substring fallback classifies it — and RFC
    /// 5530's `[NONEXISTENT]` names a missing MAILBOX, so it has dispositioned no
    /// message at all. Modelled locally rather than thrown from `ProviderError`
    /// because no `ProviderError` case carries free server text; the classifier
    /// reads `"\(error)"`, which is exactly what this provides.
    private struct RenderedIMAPFailure: Error, CustomStringConvertible {
        let description: String
    }

    @MainActor
    private func fixture(
        accountId: String, provider: AccountProvider, folderEpoch: Int? = nil
    ) throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        let pool = try DatabasePool(
            path: directory.appendingPathComponent("test.sqlite").path,
            configuration: configuration)
        let appDatabase = try AppDatabase(dbPool: pool)
        let previous = AppDatabase.shared.withLock { current -> AppDatabase? in
            let old = current
            current = appDatabase
            return old
        }
        try pool.writeWithoutTransaction { db in
            var account = Account(
                emailAddress: "\(accountId)@example.com", displayName: "Absence",
                provider: provider)
            account.id = accountId
            try account.insert(db)
            // SOURCE ONLY. `drainPendingQueue` ends by syncing every destination
            // folder it touched, and that sync is a repair strictly downstream of
            // what these tests measure (`MIS-024`): against a fake server holding
            // the message it would restore state the drain was supposed to reach
            // on its own. Omitting the destination `Folder` row makes the
            // post-drain lookup miss and skips the sync, which is all it changes.
            var folder = Folder(
                name: Self.source, path: Self.source, role: .inbox, accountId: accountId)
            folder.lastKnownUidValidity = folderEpoch
            try folder.insert(db)
        }
        return Fixture(pool: pool, directory: directory, previous: previous, accountId: accountId)
    }

    @MainActor
    private func finish(_ fixture: Fixture) async {
        await AccountManager.shared.unregisterProviderForTesting(accountId: fixture.accountId)
        InstalledTestDatabaseLifetime.finish(
            previous: fixture.previous, pool: fixture.pool, directory: fixture.directory)
    }

    @discardableResult
    private func seedHeader(
        _ fixture: Fixture, messageId: String, rfc: String
    ) throws -> MessageHeader {
        var header = MessageHeader(
            messageId: messageId, subject: "absence \(messageId)", from: "Sender",
            fromAddress: "sender@example.com", to: "recipient@example.com",
            date: Date(), snippet: "absence body",
            folderId: MessageIdentity.folderId(
                accountId: fixture.accountId, folderPath: Self.source),
            accountId: fixture.accountId, folderPath: Self.source, isInInbox: true)
        header.rfc822MessageId = rfc
        header.headerComplete = true
        let stored = header
        try fixture.pool.writeWithoutTransaction { db in try stored.insert(db) }
        return stored
    }

    private func insert(_ op: PendingOperation, into fixture: Fixture) throws {
        try fixture.pool.writeWithoutTransaction { db in _ = try op.inserted(db) }
    }

    private func operations(_ fixture: Fixture) throws -> [PendingOperation] {
        try fixture.pool.read { db in
            try PendingOperation.order(Column("createdAt").asc).fetchAll(db)
        }
    }

    private func headerExists(_ fixture: Fixture, messageId: String) throws -> Bool {
        let id = MessageIdentity.headerId(
            accountId: fixture.accountId, folderPath: Self.source, messageId: messageId)
        return try fixture.pool.read { db in try MessageHeader.fetchOne(db, key: id) != nil }
    }

    /// Drain until the queue is empty AND no drain is in flight, or until the
    /// budget runs out. For the tests whose property is TERMINATION.
    @MainActor
    private func drainToQuiescence(_ fixture: Fixture) async throws {
        for _ in 0..<120 {
            let isEmpty = try await fixture.pool.read { db in try PendingOperation.fetchCount(db) == 0 }
            let isQuiescent = await AccountManager.shared.pendingQueueIsQuiescentForTesting()
            if isEmpty && isQuiescent { return }
            if isQuiescent {
                await AccountManager.shared.drainPendingQueue()
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    /// A fixed number of complete drain passes, for the tests whose property is
    /// RETENTION. Draining to quiescence would never terminate for a correctly
    /// retained operation, and a single pass would not prove the row survives the
    /// pass that FOLLOWS the one that refused it — which is where the pre-fix
    /// tree destroyed it, by re-shaping it into single-message children the next
    /// pass was then free to drop.
    @MainActor
    private func drainPasses(_ count: Int) async {
        for _ in 0..<count {
            await AccountManager.shared.drainPendingQueue()
        }
    }

    // MARK: - 1. A gone member does not strand the valid members (Gmail)

    /// **THE PROPERTY: a member the server reports gone is dispositioned by the
    /// provider that addressed it, the surviving members are still mutated under
    /// the SAME operation, and no member is addressed twice.**
    ///
    /// The gone member is FIRST, which is the shape that used to be fatal:
    /// `GmailProvider.markRead`'s loop threw on it before either survivor was
    /// attempted, so the batch reached the drain as a bare not-found with an
    /// empty prefix — nothing had succeeded and nothing could be attributed.
    ///
    /// RED PROOF (recorded): against the pre-fix tree the survivors are still
    /// eventually read, because the drain's split arm rebuilt each member as a
    /// child and executed the children inside the same `drainPendingQueue` call —
    /// so the OUTCOME assertions alone cannot tell the two trees apart. The
    /// discriminator is the wire: pre-fix `modifyLog` holds FOUR calls
    /// (`g-1` from the batch attempt, then `g-1`, `g-2`, `g-3` as children),
    /// post-fix exactly three, one per member. That count is the observable form
    /// of "no replacement child row is created".
    @Test("Gmail: a gone first member is dispositioned in place and the survivors still land, once each")
    @MainActor
    func gmailGoneFirstMemberDoesNotStrandTheSurvivors() async throws {
        // `g-1` is deliberately NOT seeded on the server — `messages.modify`
        // answers 404 for it, Gmail's authoritative "this message is gone".
        let server = StatefulGmailActionServer(messages: [
            .init(rfc822MessageId: "two@example.com", providerMessageId: "g-2", labels: ["INBOX", "UNREAD"]),
            .init(rfc822MessageId: "three@example.com", providerMessageId: "g-3", labels: ["INBOX", "UNREAD"]),
        ])
        defer { server.close() }

        let f = try fixture(accountId: "absence-gmail-setter", provider: .gmail)
        try seedHeader(f, messageId: "g-1", rfc: "one@example.com")
        try seedHeader(f, messageId: "g-2", rfc: "two@example.com")
        try seedHeader(f, messageId: "g-3", rfc: "three@example.com")

        let op = PendingOperation(
            type: .markRead, messageIds: ["g-1", "g-2", "g-3"],
            accountId: f.accountId, folderPath: Self.source)
        try insert(op, into: f)

        await AccountManager.shared.registerProviderForTesting(
            accountId: f.accountId, provider: server.provider())
        try await drainToQuiescence(f)

        // LIVENESS — the survivors were mutated, under the user's original op.
        #expect(server.snapshot(providerMessageId: "g-2")?.isRead == true,
                "a gone sibling stranded g-2: one absent member must not revert the gesture for the rest")
        #expect(server.snapshot(providerMessageId: "g-3")?.isRead == true,
                "a gone sibling stranded g-3: one absent member must not revert the gesture for the rest")

        // NO REPLACEMENT ROW — each member addressed exactly once. A child row
        // would have re-issued its member's `messages.modify`.
        let attempts = server.modifyLog().map(\.providerMessageId).sorted()
        #expect(attempts == ["g-1", "g-2", "g-3"], """
            each member must be addressed exactly once by the ONE operation that \
            named them; a second attempt on any member is a replacement child row \
            the scheduler is no longer allowed to create. Got: \(attempts)
            """)

        // The operation is complete — nothing is still owed and nothing starves.
        #expect(try operations(f).isEmpty,
                "the operation is fully dispositioned and must not be left queued")

        // The gone member's local header is retired, exactly as the surviving
        // single-message conflict arm has always done for a confirmed-gone
        // message; its siblings are untouched.
        #expect(try headerExists(f, messageId: "g-1") == false,
                "a member the server confirmed gone must not be left as a ghost row")
        #expect(try headerExists(f, messageId: "g-2") == true)
        #expect(try headerExists(f, messageId: "g-3") == true)

        await finish(f)
    }

    // MARK: - 2. A multi-member text-only not-found retires nothing

    /// **THE PROPERTY: a multi-member failure whose only claim to "not found" is
    /// TEXT retires no member, and the user's original row survives with its own
    /// id and its full membership.**
    ///
    /// RFC 5530's `[NONEXISTENT]` names a missing MAILBOX, not a missing message,
    /// and a rendered IMAP failure that merely quotes those words has
    /// dispositioned nothing. This is `MIS-IOS-004` in its purest form.
    ///
    /// RED PROOF (recorded): against the pre-fix tree the split arm rebuilt the
    /// three members as three single-message children in the same
    /// `drainPendingQueue` call; each child then matched the SAME text-only
    /// error, was single-message, and took the "message not found — dropping"
    /// terminal arm. The queue ends EMPTY and all three intentions are destroyed
    /// — `after.count == 1` fails with 0.
    @Test("A multi-member text-only NONEXISTENT retires no member and keeps the original row")
    @MainActor
    func multiMemberTextOnlyNotFoundRetiresNothing() async throws {
        let f = try fixture(accountId: "absence-text-only", provider: .imap, folderEpoch: 10)
        let provider = MockEmailProvider(staleWindowMode: .uid)
        await provider.setMoveThrows(RenderedIMAPFailure(
            description: "MOVE failed: a0007 NO [NONEXISTENT] Unknown Mailbox"))
        await AccountManager.shared.registerProviderForTesting(
            accountId: f.accountId, provider: provider)

        let op = PendingOperation(
            type: .move, messageIds: ["11", "12", "13"],
            accountId: f.accountId, folderPath: Self.source,
            destinationPath: Self.destination, observedUidValidity: 10)
        try insert(op, into: f)

        await drainPasses(2)

        let after = try operations(f)
        #expect(after.count == 1, """
            a batch failure that matches only the substring fallback is an ABSENCE \
            of per-member evidence and retires nothing. Getting 0 rows here means \
            every member was destroyed by the single-message terminal arm; getting \
            3 means the scheduler re-shaped the user's intention into replacement \
            rows. Got \(after.count).
            """)
        guard after.count == 1 else {
            await finish(f)
            return
        }
        #expect(after[0].id == op.id,
                "the retained operation must be the user's ORIGINAL row, not a replacement")
        #expect(after[0].messageIds == ["11", "12", "13"],
                "an unresolved operation keeps every member it was admitted with")
        #expect(after[0].status == PendingStatus.queued.rawValue,
                "an unresolved operation must be retryable, not left claimed")

        // `MockEmailProvider.movedIds` records the ATTEMPT, not the outcome — the
        // entry is appended before `moveThrows` fires — which makes it the right
        // oracle for the question here: WHAT was the provider asked to move?
        // Every request must still name the operation's full membership. A
        // single-member request is a replacement child executing on its own,
        // which is exactly what the deleted split arm produced.
        let attempts = await provider.movedIds
        // 🚨 TWO-SIDED. `allSatisfy` is TRUE of an empty array, so on its own it
        // is also satisfied by a tree in which the operation never reached the
        // provider at all — which is the OTHER way to lose the gesture (the
        // wedge corollary), and the one a retention test is least able to notice.
        #expect(!attempts.isEmpty, """
            the operation never reached the provider, so nothing was classified \
            and the retention asserted above is vacuous
            """)
        #expect(attempts.allSatisfy { $0.ids == ["11", "12", "13"] }, """
            an unresolved operation is retried WHOLE. A request naming one member \
            means the scheduler re-shaped the user's intention to find out which \
            member was gone. Got: \(attempts)
            """)

        await finish(f)
    }

    // MARK: - 3. A multi-member typed not-found retires nothing either

    /// **THE PROPERTY: the same holds for the TYPED not-found.** A provider that
    /// answers `ProviderError.messageNotFound` for a three-member batch has told
    /// us something about the batch and nothing about any member; the row and
    /// every local header survive.
    ///
    /// The header assertion is the C3 half: pre-fix, each child that took the
    /// single-message terminal arm also matched `isConfirmedGoneError` and had
    /// its LOCAL header deleted — three messages disappeared from the user's
    /// mailbox on the strength of one batch-level error.
    ///
    /// RED PROOF (recorded): pre-fix the queue ends EMPTY and all three headers
    /// are gone — `after.count == 1` fails with 0 and every `headerExists` fails.
    @Test("A multi-member typed messageNotFound retires no member and deletes no header")
    @MainActor
    func multiMemberTypedNotFoundRetiresNothing() async throws {
        let f = try fixture(accountId: "absence-typed", provider: .imap, folderEpoch: 10)
        try seedHeader(f, messageId: "21", rfc: "twentyone@example.com")
        try seedHeader(f, messageId: "22", rfc: "twentytwo@example.com")
        try seedHeader(f, messageId: "23", rfc: "twentythree@example.com")

        let provider = MockEmailProvider(staleWindowMode: .uid)
        await provider.setMoveThrows(ProviderError.messageNotFound)
        await AccountManager.shared.registerProviderForTesting(
            accountId: f.accountId, provider: provider)

        let op = PendingOperation(
            type: .move, messageIds: ["21", "22", "23"],
            accountId: f.accountId, folderPath: Self.source,
            destinationPath: Self.destination, observedUidValidity: 10)
        try insert(op, into: f)

        await drainPasses(2)

        let after = try operations(f)
        #expect(after.count == 1, """
            a batch-level `messageNotFound` says nothing about any MEMBER. Retiring \
            on it is exit 2 claimed without the evidence exit 2 requires. Got \
            \(after.count) rows.
            """)
        guard after.count == 1 else {
            await finish(f)
            return
        }
        #expect(after[0].id == op.id)
        #expect(after[0].messageIds == ["21", "22", "23"])

        for member in ["21", "22", "23"] {
            #expect(try headerExists(f, messageId: member) == true, """
                the local header for \(member) was deleted on the strength of a \
                BATCH error. No member was individually confirmed gone, so no \
                member's content may be destroyed.
                """)
        }

        await finish(f)
    }

    // MARK: - 4. Graph: a gone member settles the proven ones, once each

    /// **THE PROPERTY: on Graph, a gone first member does not prevent the
    /// remaining members from moving, each member's `/move` is issued exactly
    /// once, and the operation terminates.**
    ///
    /// Graph is the strictest case because a move REALLOCATES the resource id:
    /// the proven members' new addresses must be settled by the operation that
    /// proved them. Pre-fix, `moveProvingDestinations` hit the absent leading
    /// member, had an empty proven prefix, and rethrew — so the drain split, and
    /// the destination addresses the wire had already handed back for the
    /// survivors were discarded along with the parent row.
    ///
    /// RED PROOF (recorded): pre-fix the wire shows FOUR `/move` requests
    /// (`graph-1` from the batch attempt, then one per child), so the
    /// exactly-once assertion fails; the survivors do reach the archive, by way
    /// of the children.
    @Test("Graph: a gone first member does not strand the movable members, and each moves once")
    @MainActor
    func graphGoneFirstMemberDoesNotStrandTheMovableMembers() async throws {
        // `graph-1` is absent from the server model: `/move` answers 404.
        let server = StatefulExchangeActionServer(messages: [
            .init(rfc822MessageId: "g-two@example.com", providerMessageId: "graph-2",
                  folderId: Self.source),
            .init(rfc822MessageId: "g-three@example.com", providerMessageId: "graph-3",
                  folderId: Self.source),
        ])
        defer { server.close() }

        let f = try fixture(accountId: "absence-graph-move", provider: .outlook)
        try seedHeader(f, messageId: "graph-1", rfc: "g-one@example.com")
        try seedHeader(f, messageId: "graph-2", rfc: "g-two@example.com")
        try seedHeader(f, messageId: "graph-3", rfc: "g-three@example.com")

        let op = PendingOperation(
            type: .move, messageIds: ["graph-1", "graph-2", "graph-3"],
            accountId: f.accountId, folderPath: Self.source,
            destinationPath: Self.destination)
        try insert(op, into: f)

        await AccountManager.shared.registerProviderForTesting(
            accountId: f.accountId, provider: server.provider())
        try await drainToQuiescence(f)

        #expect(server.snapshots(rfc822MessageId: "g-two@example.com").map(\.folderId) == [Self.destination],
                "a gone sibling stranded graph-2")
        #expect(server.snapshots(rfc822MessageId: "g-three@example.com").map(\.folderId) == [Self.destination],
                "a gone sibling stranded graph-3")

        let moveCalls = server.http.servedCallSequence().filter { $0.contains("/move") }
        #expect(moveCalls.count == 3, """
            each member must be moved exactly once by the ONE operation that named \
            them. A fourth request is a replacement child re-issuing a member's \
            move — and on Graph that also means re-learning an address the first \
            attempt had already proved. Got: \(moveCalls)
            """)

        #expect(try operations(f).isEmpty,
                "the move is fully dispositioned and must not be left queued")
        #expect(try headerExists(f, messageId: "graph-1") == false,
                "a member Graph confirmed gone must not be left as a ghost row")

        await finish(f)
    }

    // MARK: - 5. The single-message terminal arm keeps its scope

    /// **THE PROPERTY: the surviving terminal arm still applies to a genuine
    /// SINGLE-message not-found.** Scoping it to `messageIds.count == 1` must
    /// narrow it, not disable it: one addressed message the provider says is gone
    /// is exit 2, the row goes, and the ghost header goes with it.
    ///
    /// This is the two-sided half of tests 2 and 3 — without it, "nothing is ever
    /// retired on a not-found" would satisfy them both and wedge every genuinely
    /// stale single-message operation forever (the wedge corollary).
    @Test("A single-message confirmed-gone not-found still retires the op and its ghost header")
    @MainActor
    func singleMessageNotFoundStillRetires() async throws {
        let f = try fixture(accountId: "absence-single", provider: .imap, folderEpoch: 10)
        try seedHeader(f, messageId: "31", rfc: "thirtyone@example.com")

        let provider = MockEmailProvider(staleWindowMode: .uid)
        await provider.setMoveThrows(ProviderError.messageNotFound)
        await AccountManager.shared.registerProviderForTesting(
            accountId: f.accountId, provider: provider)

        let op = PendingOperation(
            type: .move, messageIds: ["31"],
            accountId: f.accountId, folderPath: Self.source,
            destinationPath: Self.destination, observedUidValidity: 10)
        try insert(op, into: f)

        try await drainToQuiescence(f)

        #expect(try operations(f).isEmpty, """
            one addressed message the provider reports gone IS exit 2. Retaining it \
            would starve the lane forever on a message that will never come back.
            """)
        #expect(try headerExists(f, messageId: "31") == false,
                "a confirmed-gone single message must not be left as a ghost row")

        await finish(f)
    }

    // MARK: - 6. A 410 is not authoritative absence

    /// **THE PROPERTY: moving per-member absence to the provider must not widen
    /// WHICH answers retire an operation. A bare `410` retires nothing and
    /// deletes nothing, exactly as before.**
    ///
    /// `AccountManager.isMessageNotFoundError` — the gate a not-found has always
    /// had to pass before the drain may retire an op — accepts
    /// `ProviderError.messageNotFound` and HTTP **404**, and has never accepted
    /// `410`. A `410` therefore retried forever, which is the correct handling of
    /// a status a message endpoint can return for reasons other than "this
    /// message no longer exists". `isConfirmedGoneError` DOES accept `410`, but it
    /// is not a retirement gate: it runs only inside the arm the 404 gate already
    /// admitted, so its `410` is unreachable in the drain.
    ///
    /// 🚨 THE HAZARD THIS PINS IS HELPER REUSE, NOT A DESIGN CHOICE. The provider
    /// loops need a predicate for "the server confirmed THIS member gone", and the
    /// obvious candidate is the wider `isConfirmedGoneError`. Borrowing it makes
    /// its `410` reachable for the first time — and reachable on the most
    /// destructive path there is, because an absorbed member is retired AND loses
    /// its local header. That is strictly more destruction than the tree did
    /// before, arrived at by picking a helper rather than by deciding anything.
    ///
    /// The two-sided control is
    /// `gmailGoneFirstMemberDoesNotStrandTheSurvivors` above: the SAME shape with
    /// a `404` does retire the member and does delete its header, so this test
    /// cannot pass by the provider simply never dispositioning anything.
    ///
    /// RED PROOF (recorded): with `ProviderMemberAbsence.isAuthoritative`
    /// admitting `410`, the operation is retired and the header deleted — both
    /// assertions below fail (`operations(f).count → 0`, `headerExists → false`).
    @Test("Gmail: a bare 410 is not authoritative absence — nothing is retired and no header is deleted")
    @MainActor
    func gone410IsNotAuthoritativeAbsence() async throws {
        let server = StatefulGmailActionServer(messages: [
            .init(rfc822MessageId: "gone410@example.com", providerMessageId: "g-410", labels: ["INBOX", "UNREAD"]),
            .init(rfc822MessageId: "sibling410@example.com", providerMessageId: "g-411", labels: ["INBOX", "UNREAD"]),
        ])
        defer { server.close() }
        // The member EXISTS on the server; the endpoint simply answers 410 for it.
        // That is the whole point: nothing about the message is settled.
        server.injectGone410OnModify(providerMessageId: "g-410")

        let f = try fixture(accountId: "absence-gmail-410", provider: .gmail)
        try seedHeader(f, messageId: "g-410", rfc: "gone410@example.com")
        try seedHeader(f, messageId: "g-411", rfc: "sibling410@example.com")

        let op = PendingOperation(
            type: .markRead, messageIds: ["g-410", "g-411"],
            accountId: f.accountId, folderPath: Self.source)
        try insert(op, into: f)

        await AccountManager.shared.registerProviderForTesting(
            accountId: f.accountId, provider: server.provider())
        await drainPasses(2)

        // NON-VACUITY: the 410 really was served, so the drain really did have to
        // classify it.
        #expect(server.gone410OnModifyServedCount() >= 1,
                "the injected 410 never reached the wire, so nothing was classified")

        let after = try operations(f)
        #expect(after.count == 1, """
            a 410 is not authoritative absence. Retiring on it destroys the \
            user's gesture for a status the drain has never treated as \
            conclusive. Got \(after.count) rows.
            """)
        guard after.count == 1 else { await finish(f); return }
        #expect(after[0].id == op.id, "the retained row must be the user's original operation")
        #expect(after[0].messageIds == ["g-410", "g-411"],
                "no member was dispositioned, so every member is still owed")

        #expect(try headerExists(f, messageId: "g-410") == true, """
            the local header was deleted on the strength of a 410. Nothing \
            confirmed that message gone, and a header deleted for a live message \
            takes its body and FTS content with it.
            """)
        #expect(try headerExists(f, messageId: "g-411") == true)

        await finish(f)
    }


    // MARK: - 7. A batch too slow to finish in one attempt still reaches its tail

    /// The wall-clock profile of a batch whose members are each comfortably
    /// inside the operation deadline while their SUM is not — the shape both
    /// round-2 reviewers reproduced against production timings (four members,
    /// each ~8 s, under the 15 s `pendingOperationTimeoutSeconds`).
    ///
    /// 🚨 THE PREMISE IS ASSERTED, NOT ASSUMED, by
    /// `assertIsAnOverrunProfile(_:deadline:)` below: every member individually
    /// admissible, the batch jointly inadmissible. A fixture that quietly stopped
    /// satisfying either half would turn all three deadline tests into tests of
    /// nothing, and neither half is visible from an assertion on the outcome.
    private static let overrunHoldSeconds: [TimeInterval] = [0.05, 0.90, 1.40]
    /// The scaled stand-in for `SyncConfig.pendingOperationTimeoutSeconds`.
    /// Scaled because the production value is a `let` and the property under
    /// test is a RELATIONSHIP between the deadline and one member's request, not
    /// either number: 2.35 s of members against a 2.0 s deadline is the same
    /// relationship as 32 s against 15 s, and the suite does not have to spend
    /// half a minute per provider to state it.
    private static let overrunDeadlineSeconds: TimeInterval = 2.0

    private func assertIsAnOverrunProfile(
        _ holds: [TimeInterval], deadline: TimeInterval
    ) {
        #expect(holds.allSatisfy { $0 < deadline }, """
            a member of this fixture cannot finish inside the operation deadline \
            on its own, so the batch is not the overrun shape at all — it is a \
            batch of individually impossible members, which no stopping rule can \
            help. Holds: \(holds), deadline: \(deadline)
            """)
        #expect(holds.reduce(0, +) > deadline, """
            the whole batch fits inside one deadline, so nothing here can overrun \
            it and the test proves nothing. Holds: \(holds), deadline: \(deadline)
            """)
    }

    /// One attempt at the provider boundary, under a stand-in for the drain's
    /// own `withTimeout(SyncConfig.pendingOperationTimeoutSeconds)`.
    private enum AttemptOutcome {
        /// The attempt settled these members and said nothing about the rest.
        case settled([String])
        /// The attempt settled the whole request and reported nothing, which is
        /// what silence means on a `Void`-returning action.
        case settledEverything
        /// The attempt was discarded by the deadline. THE FAILURE THIS SUITE
        /// EXISTS FOR: everything the attempt had already done is lost with the
        /// abandoned task, so the row is requeued unchanged and the next attempt
        /// repeats it.
        case discardedByTheDeadline(any Error)
    }

    /// Drive `attempt` the way `executeSingleOp` drives a provider — one
    /// deadline-bounded call, then narrow the request to whatever is still owed —
    /// and return the order in which members were settled.
    ///
    /// 🚨 THIS IS THE DRAIN'S NARROWING LOOP, NOT A NEW POLICY. Its only job is to
    /// make the composition of "one bounded attempt" with "narrow and retry"
    /// observable at the provider boundary, where the deadline can be scaled. The
    /// DURABLE half of the same property — that the narrowing happens on the
    /// user's own row, under its own id — is asserted separately below, through
    /// the real drain.
    @MainActor
    private func settleUnderRepeatedDeadlines(
        _ ids: [String],
        attempt: (_ owed: [String]) async -> AttemptOutcome
    ) async -> [String] {
        var owed = ids
        var settled: [String] = []
        // Bounded so a loop that stops making progress fails an assertion instead
        // of hanging the suite: one attempt per member is the most a converging
        // implementation can need, and the slack catches an off-by-one.
        for _ in 0..<(ids.count + 2) {
            guard !owed.isEmpty else { break }
            switch await attempt(owed) {
            case .settledEverything:
                settled.append(contentsOf: owed)
                owed = []
            case .settled(let members):
                guard !members.isEmpty else {
                    Issue.record("""
                        an attempt settled NOTHING and still reported. An attempt \
                        that can settle nothing can never converge — this is the \
                        starvation the report exists to prevent, wearing the \
                        report's clothes. Still owed: \(owed)
                        """)
                    return settled
                }
                #expect(members == Array(owed.prefix(members.count)), """
                    the settled members are not a prefix of what was requested, in \
                    request order: settled \(members) out of \(owed)
                    """)
                settled.append(contentsOf: members)
                owed.removeFirst(min(members.count, owed.count))
            case .discardedByTheDeadline(let error):
                Issue.record("""
                    the attempt was discarded by the operation deadline instead of \
                    reporting what it had settled: \(error). Everything it had \
                    already mutated is lost with the abandoned task, so the row is \
                    requeued unchanged and the next attempt repeats the identical \
                    prefix into the identical deadline — the last member's \
                    intention never reaches the provider. That is persistent retry \
                    starvation, the wedge corollary. Settled so far: \(settled), \
                    still owed: \(owed)
                    """)
                return settled
            }
        }
        #expect(owed.isEmpty, """
            the batch never converged: \(owed) is still owed after one attempt per \
            member. A member that is never requested has had its intention dropped \
            just as surely as one that was deleted.
            """)
        return settled
    }

    /// **THE PROPERTY, for Gmail's label setter: a batch whose members are each
    /// admissible under the operation deadline but jointly are not still reaches
    /// its LAST member, and the progress each attempt makes is banked on the
    /// user's own durable row rather than repeated.**
    ///
    /// 🚨 WHAT THE ROUND-2 FINDING WAS. A between-member time budget cannot
    /// deliver this. It bounds what an attempt has ALREADY spent and says nothing
    /// about the duration of the request it is about to start, so for
    /// `[gone, live-a, live-b, tail]` at ~8 s a member the loop checks 8 s against
    /// its 9 s reserve, starts `live-b`, and is cancelled at 15 s — `withTimeout`
    /// having ALREADY resumed the drain with `TimeoutError`, so the settled prefix
    /// is discarded with the abandoned task, `requeueOrRetain` resets the row with
    /// its membership unchanged, and `tail` is never requested on any attempt.
    /// Choosing a smaller fraction cannot fix it and deleting the check alone
    /// restores unbounded replay; only bounding an attempt to ONE request makes
    /// the attempt's exposure equal to the quantity the deadline actually bounds.
    ///
    /// PHASE 1 — the deadline composition, at the provider boundary under a scaled
    /// stand-in for the drain's own `withTimeout`. Every attempt must come back
    /// with a report rather than a `TimeoutError`, and repeating on the remainder
    /// must reach the tail. PHASE 2 — the durable half, through the REAL drain: the
    /// row that survives is the user's original id with its `createdAt` intact,
    /// narrowed to the members still owed, and every member is addressed exactly
    /// once across the whole run.
    ///
    /// TWO-SIDED: phase 1 asserts the fixture really is an overrun profile
    /// (individually admissible, jointly not) and phase 2 asserts the mid-run row
    /// is a PROPER, NON-EMPTY suffix — so neither "the loop settled everything in
    /// one attempt" nor "the loop settled nothing" can satisfy them.
    ///
    /// RED PROOF (recorded): with the loop restored to its between-member time
    /// budget, phase 1's first attempt spends 2.35 s of member latency against the
    /// 2.0 s deadline and comes back `TimeoutError`, and phase 2's single drain
    /// retires the whole five-member row so the narrowed row is absent.
    @Test("Gmail: a batch too slow to finish in one attempt narrows the same row and still reaches its last member")
    @MainActor
    func gmailSetterOverrunNarrowsUnderTheOriginalIdAndReachesTheTail() async throws {
        // PHASE 1 — the deadline composition.
        let holds = Self.overrunHoldSeconds
        let deadline = Self.overrunDeadlineSeconds
        assertIsAnOverrunProfile(holds, deadline: deadline)

        let slowIds = (1...holds.count).map { "slow-g-\($0)" }
        let slowServer = StatefulGmailActionServer(messages: slowIds.map {
            .init(rfc822MessageId: "\($0)@example.com", providerMessageId: $0,
                  labels: ["INBOX", "UNREAD"])
        })
        defer { slowServer.close() }
        for (id, hold) in zip(slowIds, holds) {
            slowServer.holdModify(providerMessageId: id, forSeconds: hold)
        }

        let slowProvider = slowServer.provider()
        let folder = Self.source
        let settled = await settleUnderRepeatedDeadlines(slowIds) { owed in
            do {
                try await withTimeout(seconds: deadline) {
                    try await slowProvider.markRead(ids: owed, folder: folder)
                }
                return .settledEverything
            } catch let report as ProviderMembersDispositioned {
                return .settled(report.dispositionedMemberIds)
            } catch {
                return .discardedByTheDeadline(error)
            }
        }
        #expect(settled == slowIds,
                "every member must be settled exactly once, in request order. Got: \(settled)")
        let slowAddressed = slowServer.modifyLog().map(\.providerMessageId)
        #expect(slowAddressed == slowIds, """
            a member was addressed twice, or the tail was never addressed at all: \
            \(slowAddressed)
            """)
        for id in slowIds {
            #expect(slowServer.snapshot(providerMessageId: id)?.isRead == true,
                    "\(id) never received the gesture — the batch did not converge")
        }

        // PHASE 2 — the durable half, through the real drain.
        //
        // FIVE members, one per Gmail request. The executor has no pass cap and
        // re-claims the narrowed remainder inside the SAME run, so there is no
        // "between drains" instant to read any more — `observeNarrowingWhile
        // OneDrainConverges` manufactures the instant by holding the middle
        // member's request open, and then requires that same drain to converge
        // all five. The property is what the DURABLE row looks like while
        // converging.
        let members = (1...5).map { "bank-g-\($0)" }
        let server = StatefulGmailActionServer(messages: members.map {
            .init(rfc822MessageId: "\($0)@example.com", providerMessageId: $0,
                  labels: ["INBOX", "UNREAD"])
        })
        defer { server.close() }

        let f = try fixture(accountId: "overrun-gmail-setter", provider: .gmail)
        for id in members { try seedHeader(f, messageId: id, rfc: "\(id)@example.com") }
        let op = PendingOperation(
            type: .markRead, messageIds: members,
            accountId: f.accountId, folderPath: Self.source)
        try insert(op, into: f)
        // Compare against the row AS STORED, not the in-memory value: `createdAt`
        // round-trips through SQLite at a coarser resolution, so an equality
        // against the object we inserted would fail on serialization precision
        // rather than on the ordering property it is there to state.
        guard let seeded = try operations(f).first else {
            Issue.record("the operation was not stored, so there is nothing to narrow")
            await finish(f)
            return
        }

        // The MIDDLE member's request is held open, so the durable row can be read
        // at an instant when two members are settled and three are still owed.
        server.holdModify(
            providerMessageId: members[2], forSeconds: Self.midConvergenceHoldSeconds)
        await AccountManager.shared.registerProviderForTesting(
            accountId: f.accountId, provider: server.provider())

        try await observeNarrowingWhileOneDrainConverges(f, op: seeded) {
            server.modifyLog().contains { $0.providerMessageId == members[2] }
        }

        let addressed = server.modifyLog().map(\.providerMessageId)
        #expect(addressed == members, """
            every member must be addressed exactly once, in request order. A member \
            re-sent after it was settled is progress that was discarded rather than \
            banked. Got: \(addressed)
            """)
        for id in members {
            #expect(server.snapshot(providerMessageId: id)?.isRead == true,
                    "\(id) never received the gesture — including the LAST member, which a starved batch never reaches")
        }

        await finish(f)
    }

    /// The mid-run assertion shared by all three deadline tests: after a drain
    /// that could not finish the batch, what survives is the USER'S row — same id,
    /// same `createdAt`, already attempted — narrowed to a PROPER, NON-EMPTY
    /// SUFFIX of its original membership, in the original order.
    ///
    /// 🚨 IT IS TWO-SIDED BY CONSTRUCTION. "Non-empty" excludes an implementation
    /// that retired members it never settled; "proper" excludes one that banked
    /// nothing and left the row whole; "suffix, in order" excludes one that
    /// re-shaped the user's intention into a different membership. A replacement
    /// row fails the id check, which is how "no child row is created" is observed
    /// on the durable side (the wire count observes it on the other).
    private func assertNarrowedUnderTheOriginalRow(
        _ fixture: Fixture, op: PendingOperation
    ) throws {
        let rows = try operations(fixture)
        #expect(rows.count == 1, """
            the drain left \(rows.count) row(s) instead of the ONE the user \
            created: \(rows.map(\.messageIds)). Zero means the batch was retired \
            whole — more members left the row than any attempt settled; more than \
            one means the intention was re-shaped into replacement rows.
            """)
        guard rows.count == 1 else { return }
        let row = rows[0]
        #expect(row.id == op.id, "the surviving row must be the user's ORIGINAL operation")
        // `createdAt` is AGE, not order — `queuePosition` decides order and the
        // narrowing deliberately moves it to the tail. What this pins is that the
        // surviving row is the SAME DURABLE ROW the user created rather than a
        // freshly constructed replacement wearing the same id: a rebuilt row
        // would carry a new timestamp, and its age would restart.
        #expect(row.createdAt == op.createdAt,
                "the narrowed row is not the original — its `createdAt` changed, so a replacement row was constructed instead of the user's own being narrowed")
        #expect(row.everAttempted, "the row was narrowed without ever being attempted")
        #expect(!row.messageIds.isEmpty,
                "the row narrowed to nothing while still existing, so members left it without being settled")
        #expect(row.messageIds.count < op.messageIds.count, """
            the row still holds all \(op.messageIds.count) member(s), so the drain \
            banked nothing: every attempt repeats the identical prefix and the last \
            member is never requested.
            """)
        #expect(row.messageIds == Array(op.messageIds.suffix(row.messageIds.count)), """
            the members still owed are not the tail of the original request, in \
            order: \(row.messageIds) out of \(op.messageIds)
            """)
    }

    /// How long the mid-convergence member's request is held open. Wide enough
    /// that the observation below is not a race, and far inside
    /// `SyncConfig.pendingOperationTimeoutSeconds` (15 s) so the park can never
    /// turn into an operation timeout — which would silently change what is
    /// being measured into the deadline case phase 1 already covers.
    private static let midConvergenceHoldSeconds: TimeInterval = 3.0

    /// ONE drain, with the request for a MIDDLE member held open, observing the
    /// durable row at the instant that request is in flight — and then requiring
    /// that same drain to converge the WHOLE batch.
    ///
    /// 🚨 WHY THE OBSERVATION MOVED INSIDE THE DRAIN, AND WHY THAT IS THE POINT.
    /// It used to be taken BETWEEN drains: the drain capped itself at three
    /// passes and answered a narrowing by halting that lane, so a five-member
    /// batch could not finish in one drain and the narrowed row was trivially
    /// observable afterwards. Reading it that way also meant the user waited for
    /// a fresh drain trigger — another gesture, a reconnect, or the poll — for
    /// every three members of a gesture they had already made.
    ///
    /// The global single-operation executor has no pass cap and re-claims the
    /// narrowed remainder as the live front row, so the whole batch settles in
    /// ONE continuous run and there is no "between drains" left to look at. The
    /// held member manufactures the instant instead, and the convergence
    /// assertion at the end is the other half: both halves of the original
    /// property — narrowed under the ORIGINAL row, and every member reached — are
    /// still asserted, and the run count went from ⌈N/3⌉ to one.
    @MainActor
    private func observeNarrowingWhileOneDrainConverges(
        _ fixture: Fixture,
        op seeded: PendingOperation,
        parkedMemberHasArrived: @escaping @Sendable () -> Bool
    ) async throws {
        let drain = Task { @MainActor in await AccountManager.shared.drainPendingQueue() }
        var arrived = false
        for _ in 0..<1200 {
            if parkedMemberHasArrived() { arrived = true; break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(arrived, """
            the held member's request never reached the server, so the durable \
            observation below would be taken at an arbitrary instant rather than \
            mid-convergence
            """)
        if arrived { try assertNarrowedUnderTheOriginalRow(fixture, op: seeded) }
        await drain.value

        let owed = try operations(fixture)
        #expect(owed.isEmpty, """
            ONE drain did not settle every member — \(owed.map(\.messageIds)) is \
            still owed. An N-member operation must converge in a single continuous \
            run: the executor keeps claiming while a live front row exists, and a \
            narrowed remainder keeps its identity and its place in the queue \
            instead of waiting for the next drain trigger.
            """)
    }

    // MARK: - 8. The same, for the Graph setter

    /// **THE PROPERTY, for Graph's `PATCH /messages/{id}` setter loop.** Same two
    /// phases, same reasoning, different provider — the finding named all three
    /// loops and a fix verified on one of them says nothing about the others.
    ///
    /// RED PROOF (recorded): with the loop restored to its between-member time
    /// budget, phase 1's first attempt comes back `TimeoutError` and phase 2's
    /// single drain retires the whole five-member row.
    @Test("Graph: a setter batch too slow to finish in one attempt narrows the same row and still reaches its last member")
    @MainActor
    func graphSetterOverrunNarrowsUnderTheOriginalIdAndReachesTheTail() async throws {
        let holds = Self.overrunHoldSeconds
        let deadline = Self.overrunDeadlineSeconds
        assertIsAnOverrunProfile(holds, deadline: deadline)

        let slowIds = (1...holds.count).map { "slow-x-\($0)" }
        let slowServer = StatefulExchangeActionServer(messages: slowIds.map {
            .init(rfc822MessageId: "\($0)@example.com", providerMessageId: $0,
                  folderId: Self.source)
        })
        defer { slowServer.close() }
        for (id, hold) in zip(slowIds, holds) {
            slowServer.holdPatch(providerMessageId: id, forSeconds: hold)
        }

        let slowProvider = slowServer.provider()
        let folder = Self.source
        let settled = await settleUnderRepeatedDeadlines(slowIds) { owed in
            do {
                try await withTimeout(seconds: deadline) {
                    try await slowProvider.markRead(ids: owed, folder: folder)
                }
                return .settledEverything
            } catch let report as ProviderMembersDispositioned {
                return .settled(report.dispositionedMemberIds)
            } catch {
                return .discardedByTheDeadline(error)
            }
        }
        #expect(settled == slowIds,
                "every member must be settled exactly once, in request order. Got: \(settled)")
        let slowPatches = Self.patchedIds(slowServer)
        #expect(slowPatches == slowIds,
                "a member was PATCHed twice, or the tail was never PATCHed at all: \(slowPatches)")
        for id in slowIds {
            #expect(slowServer.snapshot(providerMessageId: id)?.isRead == true,
                    "\(id) never received the gesture — the batch did not converge")
        }

        // PHASE 2 — the durable half, through the real drain.
        let members = (1...5).map { "bank-x-\($0)" }
        let server = StatefulExchangeActionServer(messages: members.map {
            .init(rfc822MessageId: "\($0)@example.com", providerMessageId: $0,
                  folderId: Self.source)
        })
        defer { server.close() }

        let f = try fixture(accountId: "overrun-graph-setter", provider: .outlook)
        for id in members { try seedHeader(f, messageId: id, rfc: "\(id)@example.com") }
        let op = PendingOperation(
            type: .markRead, messageIds: members,
            accountId: f.accountId, folderPath: Self.source)
        try insert(op, into: f)
        // Compare against the row AS STORED, not the in-memory value: `createdAt`
        // round-trips through SQLite at a coarser resolution, so an equality
        // against the object we inserted would fail on serialization precision
        // rather than on the ordering property it is there to state.
        guard let seeded = try operations(f).first else {
            Issue.record("the operation was not stored, so there is nothing to narrow")
            await finish(f)
            return
        }

        // See the Gmail sibling: the middle member is held so the narrowed row is
        // observable at an instant, this executor having removed the between-drain
        // window the observation used to be taken in.
        server.holdPatch(
            providerMessageId: members[2], forSeconds: Self.midConvergenceHoldSeconds)
        await AccountManager.shared.registerProviderForTesting(
            accountId: f.accountId, provider: server.provider())

        try await observeNarrowingWhileOneDrainConverges(f, op: seeded) {
            Self.patchedIds(server).contains(members[2])
        }

        let patched = Self.patchedIds(server)
        #expect(patched == members, """
            every member must be PATCHed exactly once, in request order. A member \
            re-sent after it was settled is progress that was discarded rather than \
            banked. Got: \(patched)
            """)
        for id in members {
            #expect(server.snapshot(providerMessageId: id)?.isRead == true,
                    "\(id) never received the gesture — including the LAST member, which a starved batch never reaches")
        }

        await finish(f)
    }

    // MARK: - 9. The same, for the Graph move

    /// **THE PROPERTY, for Graph's `/move` loop — the strictest of the three,
    /// because a move REALLOCATES the resource id.** An attempt that went on to a
    /// second member and was then cancelled would discard the destination address
    /// the wire had already handed back for the first, which is the exact state
    /// `moveProvingDestinations` exists to prevent (`IOS-GRAPH-002`).
    ///
    /// The move loop reports through its RETURN VALUE rather than by throwing, so
    /// phase 1 reads the settled members off `MoveOutcome.provenIds`; everything
    /// else is identical.
    ///
    /// RED PROOF (recorded): with the loop restored to its between-member time
    /// budget, phase 1's first attempt comes back `TimeoutError` and phase 2's
    /// single drain retires the whole five-member row.
    @Test("Graph: a move batch too slow to finish in one attempt narrows the same row and still reaches its last member")
    @MainActor
    func graphMoveOverrunNarrowsUnderTheOriginalIdAndReachesTheTail() async throws {
        let holds = Self.overrunHoldSeconds
        let deadline = Self.overrunDeadlineSeconds
        assertIsAnOverrunProfile(holds, deadline: deadline)

        let slowIds = (1...holds.count).map { "slow-mv-\($0)" }
        let slowServer = StatefulExchangeActionServer(messages: slowIds.map {
            .init(rfc822MessageId: "\($0)@example.com", providerMessageId: $0,
                  folderId: Self.source)
        })
        defer { slowServer.close() }
        for (id, hold) in zip(slowIds, holds) {
            slowServer.holdMove(providerMessageId: id, forSeconds: hold)
        }

        let slowProvider = slowServer.provider()
        let source = Self.source
        let destination = Self.destination
        let settled = await settleUnderRepeatedDeadlines(slowIds) { owed in
            do {
                let outcome = try await withTimeout(seconds: deadline) {
                    try await slowProvider.moveProvingDestinations(
                        ids: owed, from: source, to: destination)
                }
                return outcome.provenIds.count == owed.count
                    ? .settledEverything
                    : .settled(outcome.provenIds)
            } catch {
                return .discardedByTheDeadline(error)
            }
        }
        #expect(settled == slowIds,
                "every member must be settled exactly once, in request order. Got: \(settled)")
        let slowMoves = Self.movedIds(slowServer)
        #expect(slowMoves == slowIds,
                "a member was moved twice, or the tail was never moved at all: \(slowMoves)")
        for id in slowIds {
            #expect(slowServer.snapshots(rfc822MessageId: "\(id)@example.com").map(\.folderId)
                        == [Self.destination],
                    "\(id) never reached the destination — the batch did not converge")
        }

        // PHASE 2 — the durable half, through the real drain.
        let members = (1...5).map { "bank-mv-\($0)" }
        let server = StatefulExchangeActionServer(messages: members.map {
            .init(rfc822MessageId: "\($0)@example.com", providerMessageId: $0,
                  folderId: Self.source)
        })
        defer { server.close() }

        let f = try fixture(accountId: "overrun-graph-move", provider: .outlook)
        for id in members { try seedHeader(f, messageId: id, rfc: "\(id)@example.com") }
        let op = PendingOperation(
            type: .move, messageIds: members,
            accountId: f.accountId, folderPath: Self.source,
            destinationPath: Self.destination)
        try insert(op, into: f)
        // Compare against the row AS STORED, not the in-memory value: `createdAt`
        // round-trips through SQLite at a coarser resolution, so an equality
        // against the object we inserted would fail on serialization precision
        // rather than on the ordering property it is there to state.
        guard let seeded = try operations(f).first else {
            Issue.record("the operation was not stored, so there is nothing to narrow")
            await finish(f)
            return
        }

        // See the Gmail sibling. The held id is the one the move is ADDRESSED to,
        // which is still the source-side id at the moment the request is served —
        // Graph reallocates it in the response, not before it.
        server.holdMove(
            providerMessageId: members[2], forSeconds: Self.midConvergenceHoldSeconds)
        await AccountManager.shared.registerProviderForTesting(
            accountId: f.accountId, provider: server.provider())

        try await observeNarrowingWhileOneDrainConverges(f, op: seeded) {
            Self.movedIds(server).contains(members[2])
        }

        let moved = Self.movedIds(server)
        #expect(moved == members, """
            every member must be moved exactly once, in request order. A second \
            /move for a member is a re-learned address the first attempt had \
            already proved and thrown away. Got: \(moved)
            """)
        for id in members {
            #expect(server.snapshots(rfc822MessageId: "\(id)@example.com").map(\.folderId)
                        == [Self.destination],
                    "\(id) never reached the destination — including the LAST member, which a starved batch never reaches")
        }

        await finish(f)
    }

    /// The provider ids a Graph `PATCH /messages/{id}` was addressed to, in wire
    /// order. Read off `recordedCalls()` because this fixture keeps no patch log
    /// of its own; the METHOD is part of the filter so a `GET` on the same path
    /// cannot be counted as a mutation.
    private static func patchedIds(_ server: StatefulExchangeActionServer) -> [String] {
        server.http.recordedCalls().compactMap { call in
            guard call.method == "PATCH",
                  let url = URL(string: call.url),
                  url.path.contains("/messages/") else { return nil }
            return url.lastPathComponent
        }
    }

    /// The provider ids a Graph `POST /messages/{id}/move` was addressed to, in
    /// wire order.
    private static func movedIds(_ server: StatefulExchangeActionServer) -> [String] {
        server.http.recordedCalls().compactMap { call in
            guard call.method == "POST",
                  let url = URL(string: call.url),
                  url.path.hasSuffix("/move") else { return nil }
            return url.deletingLastPathComponent().lastPathComponent
        }
    }


    // MARK: - 10. The per-member continuation matrix

    /// What the SERVER does to a given member of the batch.
    enum MemberRole: Sendable {
        /// Not seeded at all: `messages.modify` answers 404, Gmail's
        /// authoritative "this message is gone". Absence is modelled by the
        /// message not existing, never by an injected status, so the fixture
        /// cannot drift from what the real endpoint does.
        case absent
        /// Seeded and mutable — the member whose intention must survive.
        case live
        /// Seeded, but its modify answers 503 until the fault is cleared.
        case transient
        /// Seeded, and its modify answers a bare 410 — the NEGATIVE control.
        case gone410
    }

    /// The setters that route through a per-member loop, and what each of them
    /// asks the server for. `markUnread` and `markUnflagged` are here because the
    /// two flag directions are separate `modifyEachMessage` call sites with
    /// separate label arguments, and a matrix that only ever sets a flag cannot
    /// see a clear that never reaches the wire.
    enum AbsenceSetter: String, Sendable, CaseIterable, CustomTestStringConvertible {
        case markRead, markUnread, flag, unflag, labelMove

        var testDescription: String { rawValue }

        var opType: OperationType {
            switch self {
            case .markRead: .markRead
            case .markUnread: .markUnread
            case .flag: .markFlagged
            case .unflag: .markUnflagged
            case .labelMove: .move
            }
        }

        /// The labels a member carries BEFORE the gesture, chosen so the gesture
        /// is always a real change: a test that asks for a state the fixture
        /// already holds proves nothing about whether the request went out.
        var seededLabels: Set<String> {
            switch self {
            case .markRead: ["INBOX", "UNREAD"]
            case .markUnread: ["INBOX"]
            case .flag: ["INBOX"]
            case .unflag: ["INBOX", "STARRED"]
            case .labelMove: ["INBOX"]
            }
        }

        var destinationPath: String? {
            self == .labelMove ? QueueMemberAbsenceTests.destination : nil
        }

        /// Has the gesture actually landed on this member, ON THE SERVER? This is
        /// the effect oracle the whole matrix turns on — a request that was
        /// addressed but applied nothing is not a member that was dispositioned.
        func isApplied(_ snapshot: StatefulGmailActionServer.Snapshot) -> Bool {
            switch self {
            case .markRead: snapshot.isRead
            case .markUnread: !snapshot.isRead
            case .flag: snapshot.isFlagged
            case .unflag: !snapshot.isFlagged
            case .labelMove:
                snapshot.labels.contains(QueueMemberAbsenceTests.destination)
                    && !snapshot.labels.contains(QueueMemberAbsenceTests.source)
            }
        }
    }

    /// Where the absent members sit relative to the live ones. Position is the
    /// whole point: a loop that stops at the first absence, or that stops
    /// accumulating after one, is only visible when something the user still
    /// wants comes AFTER an absent member.
    enum AbsenceLayout: String, Sendable, CaseIterable, CustomTestStringConvertible {
        case absentFirstThenLiveSuffix
        case twoAbsentSeparatedByALiveOne
        case everyMemberAbsent
        case absentPrefixThenTransientThenLive
        case gone410FirstThenLiveSuffix

        var testDescription: String { rawValue }

        var roles: [MemberRole] {
            switch self {
            case .absentFirstThenLiveSuffix: [.absent, .live, .live]
            case .twoAbsentSeparatedByALiveOne: [.absent, .live, .absent, .live]
            case .everyMemberAbsent: [.absent, .absent, .absent, .absent, .absent]
            case .absentPrefixThenTransientThenLive: [.absent, .live, .transient, .live]
            case .gone410FirstThenLiveSuffix: [.gone410, .live, .live]
            }
        }
    }

    /// How many local header rows name this message, in ANY folder.
    ///
    /// Counted by `messageId` rather than by header id because a completed move
    /// RE-KEYS the row to the destination folder path, so a source-scoped lookup
    /// would report a moved member's header as "deleted" and turn the scoped
    /// cleanup assertion into a false pass.
    private func headerCount(_ fixture: Fixture, messageId: String) throws -> Int {
        try fixture.pool.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM messageHeader WHERE accountId = ? AND messageId = ?",
                arguments: [fixture.accountId, messageId]) ?? -1
        }
    }

    /// **THE PROPERTY, across every setter that has a per-member loop and every
    /// arrangement of absent members: an authoritative absence dispositions ONLY
    /// that member, every other member still gets the gesture the user asked for,
    /// and every member the server said is gone — not one of them, not the first
    /// of them — loses its local header.**
    ///
    /// 🚨 THE ORACLE IS SERVER STATE, NOT ADDRESSED REQUESTS. A request that goes
    /// out and applies nothing is not a dispositioned member, and a matrix that
    /// counted requests would accept a loop that asked for the wrong label. Each
    /// setter therefore declares the labels it seeds and the effect it must leave,
    /// and both flag DIRECTIONS are present because setting and clearing are
    /// separate call sites with separate arguments.
    ///
    /// The mutations this exists to kill, each of which survives a single
    /// one-gone mark-read test:
    ///
    /// - **Accumulating only one absent id.** `twoAbsentSeparatedByALiveOne`
    ///   fails at the second absent member's header, which is left as a ghost no
    ///   operation names any more.
    /// - **Absorbing a later transient failure once an earlier member was
    ///   absent.** `absentPrefixThenTransientThenLive` fails twice: the
    ///   transiently-refused member never receives the gesture, and its header is
    ///   destroyed as though the server had confirmed it gone.
    /// - **Widening what counts as absence to a 410.**
    ///   `gone410FirstThenLiveSuffix` fails at the retained row and at every
    ///   header — it is the negative control, and it runs for every setter
    ///   because the predicate is shared by all of them.
    ///
    /// TWO-SIDED THROUGHOUT: the layouts with a refusal assert that the members
    /// AFTER it are still in their seeded state, so "the gesture landed
    /// everywhere" can never be satisfied by a loop that mutates indiscriminately.
    ///
    /// RED PROOF (recorded): see the per-mutation runs in the round-2 evidence —
    /// truncating `absent` to its first id fails
    /// `twoAbsentSeparatedByALiveOne` at `headerCount(m3) == 0`; absorbing a
    /// non-authoritative error once `absent` is non-empty fails
    /// `absentPrefixThenTransientThenLive` at the transient member's effect and
    /// header; returning after the first absence fails the single-pass
    /// convergence assertion.
    @Test("Gmail: per-member absence dispositions only the absent members, for every setter and every layout",
          arguments: AbsenceSetter.allCases, AbsenceLayout.allCases)
    @MainActor
    func perMemberAbsenceMatrix(setter: AbsenceSetter, layout: AbsenceLayout) async throws {
        let roles = layout.roles
        let ids = roles.indices.map { "m\($0 + 1)" }
        let server = StatefulGmailActionServer(
            messages: zip(ids, roles).filter { $0.1 != .absent }.map { id, _ in
                .init(rfc822MessageId: "\(id)@example.com", providerMessageId: id,
                      labels: setter.seededLabels)
            })
        defer { server.close() }
        for (id, role) in zip(ids, roles) {
            switch role {
            case .transient: server.injectTransient503OnModify(providerMessageId: id)
            case .gone410: server.injectGone410OnModify(providerMessageId: id)
            case .absent, .live: break
            }
        }

        let f = try fixture(
            accountId: "absence-matrix-\(setter.rawValue)-\(layout.rawValue)", provider: .gmail)
        for id in ids { try seedHeader(f, messageId: id, rfc: "\(id)@example.com") }

        let op = PendingOperation(
            type: setter.opType, messageIds: ids,
            accountId: f.accountId, folderPath: Self.source,
            destinationPath: setter.destinationPath)
        try insert(op, into: f)

        await AccountManager.shared.registerProviderForTesting(
            accountId: f.accountId, provider: server.provider())

        // The members that must end up carrying the gesture, and the ones that
        // must not have been touched while a refusal is standing.
        let liveIds = zip(ids, roles).filter { $0.1 == .live || $0.1 == .transient }.map(\.0)
        let absentIds = zip(ids, roles).filter { $0.1 == .absent }.map(\.0)

        switch layout {
        case .gone410FirstThenLiveSuffix:
            await drainPasses(2)

            // NON-VACUITY: the control status really reached the wire.
            #expect(server.gone410OnModifyServedCount() >= 1,
                    "the injected 410 never reached the wire, so nothing was classified")

            let after = try operations(f)
            #expect(after.count == 1, """
                a 410 is not authoritative absence for \(setter.rawValue) either. \
                Retiring on it destroys the user's gesture for a status the drain \
                has never treated as conclusive. Got \(after.count) rows.
                """)
            guard after.count == 1 else { await finish(f); return }
            #expect(after[0].id == op.id,
                    "the retained row must be the user's ORIGINAL operation, not a replacement")
            #expect(after[0].messageIds == ids,
                    "no member was dispositioned, so every member is still owed")
            #expect(after[0].status == PendingStatus.queued.rawValue,
                    "an unresolved operation must be retryable, not left claimed")
            #expect(after[0].retryCount >= 1,
                    "the attempt was never charged, so the row was not actually retried")

            // THE SUFFIX IS UNTOUCHED — the loop rethrew the unclassifiable
            // failure with the remaining members unattempted.
            for id in liveIds {
                let snapshot = server.snapshot(providerMessageId: id)
                #expect(snapshot.map(setter.isApplied) == false, """
                    \(id) was mutated even though the batch was refused before it: \
                    \(String(describing: snapshot))
                    """)
            }
            for id in ids {
                #expect(try headerCount(f, messageId: id) == 1, """
                    \(id)'s local header was deleted on the strength of a 410. \
                    Nothing confirmed that message gone, and a header deleted for a \
                    live message takes its body and FTS content with it.
                    """)
            }
            await finish(f)
            return

        case .absentPrefixThenTransientThenLive:
            await drainPasses(2)

            // NON-VACUITY: the transient really was served.
            #expect(server.transient503OnModifyServedCount() >= 1,
                    "the injected 503 never reached the wire, so no refusal was classified")

            // MID-STATE — a transient refusal is NOT a disposition. The whole row
            // is still owed under its own id, and the member AFTER the refusal was
            // never attempted.
            let held = try operations(f)
            #expect(held.count == 1, "a transient refusal retired something. Got \(held.count) rows.")
            guard held.count == 1 else { await finish(f); return }
            #expect(held[0].id == op.id, "the retained row must be the user's ORIGINAL operation")
            // THE NEVER-DROP HALF. Members the loop settled before the refusal
            // may legitimately have left the row; the refused member and
            // everything after it may NOT — nothing settled them.
            #expect(held[0].messageIds.contains(ids[2]) && held[0].messageIds.contains(ids[3]), """
                the transiently-refused member or the member behind it left the \
                row: \(held[0].messageIds). A 503 settles nothing, and a member \
                that was never attempted is still owed.
                """)
            #expect(held[0].retryCount >= 1, "the provider refusal was never charged")
            let suffixId = ids[3]
            let suffix = server.snapshot(providerMessageId: suffixId)
            #expect(suffix.map(setter.isApplied) == false, """
                \(suffixId) was mutated even though the member before it was \
                refused: \(String(describing: suffix))
                """)
            #expect(try headerCount(f, messageId: ids[2]) == 1, """
                the transiently-refused member's header was deleted as though the \
                server had confirmed it gone. A 503 settles nothing.
                """)

            // The fault heals; the operation must converge on its own.
            server.clearTransient503sOnModify()
            try await drainToQuiescence(f)

        case .absentFirstThenLiveSuffix, .twoAbsentSeparatedByALiveOne, .everyMemberAbsent:
            // DRAIN UNTIL IT STOPS. A settled member leaves the row one at a
            // time, so an N-member batch costs N attempts; the global executor
            // now takes them all inside one run, and an absent member that
            // routes through the retryable disposition still costs a fresh one.
            // A FIXED DRAIN COUNT WOULD PIN THE CONVERGENCE RATE, WHICH IS A
            // MECHANISM, NOT THE PROPERTY (`MIS-015`) — and it is the mechanism
            // most likely to change again: it has already changed twice, once by
            // the round-2 correction to the pass cap and once by deleting the cap.
            try await drainToQuiescence(f)

            // 🚨 THE WIRE COUNT IS WHAT THE OLD DRAIN-COUNT ASSERTION WAS
            // REALLY PROTECTING, and it survives the rate change intact: EVERY
            // MEMBER ADDRESSED EXACTLY ONCE, IN REQUEST ORDER, ACROSS THE WHOLE
            // RUN. Two different failures land on it from opposite sides.
            //
            // A member requested TWICE is progress that was made and then
            // discarded rather than banked on the durable row — the round-2
            // defect's own signature, in which every attempt replays the same
            // settled prefix. It is also how a replacement child row is observed
            // from outside: a child necessarily re-issues its member's request,
            // and children are born and retired inside a single
            // `drainPendingQueue` call, so no post-drain row count can see them.
            //
            // A member requested ZERO times is the starved tail — an intention
            // that never reached the provider at all.
            let addressed = server.modifyLog().map(\.providerMessageId)
            #expect(addressed == ids, """
                every member must be addressed exactly once, in request order. \
                A repeat is progress the drain discarded instead of banking on the \
                user's own row (or a replacement child re-issuing its member's \
                request); a member missing entirely is an intention that never \
                reached the provider. Expected \(ids), got \(addressed).
                """)
        }

        // CONVERGENCE — every member the server still holds carries the gesture.
        for id in liveIds {
            let snapshot = server.snapshot(providerMessageId: id)
            #expect(snapshot.map(setter.isApplied) == true, """
                \(id) never received the \(setter.rawValue) gesture: \
                \(String(describing: snapshot)). An absent sibling must not strand it.
                """)
        }
        let leftovers = try operations(f).map(\.messageIds)
        #expect(leftovers.isEmpty, """
            the operation is fully dispositioned and must not be left queued. \
            Rows left: \(leftovers)
            """)

        // SCOPED CLEANUP — every gone member loses its header, and only they do.
        for id in absentIds {
            #expect(try headerCount(f, messageId: id) == 0, """
                \(id) was confirmed gone by the server and its ghost header \
                survived. Nothing names that message any more, so nothing will \
                ever retire it.
                """)
        }
        for id in liveIds {
            #expect(try headerCount(f, messageId: id) == 1, """
                \(id) is live and its header was destroyed with its absent \
                sibling's — the cleanup must be scoped to the members the server \
                actually reported gone.
                """)
        }

        await finish(f)
    }


    // MARK: - 11. The unresolved arm is attempted ONCE per drain, and isolates nobody

    /// **THE PROPERTY: an unresolved multi-member failure is attempted AT MOST
    /// ONCE per drain and charged exactly one retry per drain, however many
    /// further passes other work forces — and it neither mutates the follower
    /// waiting on one of its members nor stops the rest of its account.**
    ///
    /// 🚨 THE FIXTURE HAS TO GIVE THE EXECUTOR SOMEWHERE ELSE TO GO OR IT PROVES
    /// NOTHING. The executor keeps claiming while a live front row exists, so a
    /// fixture whose ONLY operation fails runs out of candidates immediately and
    /// every assertion about "attempted once" is satisfied by a drain that had
    /// one candidate to begin with. The independent `markRead` below is queued
    /// FIRST for exactly that reason: it succeeds, the executor keeps walking, and
    /// the refused bundle — now moved to the tail — is back in front of the walk,
    /// where only `DrainContext.deferredOperationIds` stops it being re-claimed.
    ///
    /// The three failure directions, all asserted:
    ///
    /// - **Re-sending the bundle inside one drain.** Each repeat is another round
    ///   trip and — for a provider whose refusal comes AFTER a wire mutation —
    ///   another duplicate. `movedIds` counts requests, so it sees this directly.
    /// - **Charging a retry per pass instead of per drain.** Retry counts feed
    ///   the stuck-op diagnostics and every future ageing policy; three charges
    ///   for one refusal walks an operation toward a ceiling three times too fast.
    /// - **Mutating the follower.** The follower names a member of the unresolved
    ///   bundle, so running it would apply the user's LATER gesture to a message
    ///   whose earlier gesture has not happened yet.
    ///
    /// The account is not isolated either: the independent work completes. Note
    /// what that assertion can and cannot see — it runs BEFORE the refusal in the
    /// same lane, so it cannot by itself rule out the arm having marked the
    /// account failed. That property is decided in `DrainContext` and is asserted
    /// where it is decided, on the owned context in
    /// `AccountManagerQueueDrainTests.messageNotFoundBatchRetainsTheOriginalRow`.
    ///
    /// LIVENESS, asserted second because retention alone is satisfied forever by
    /// a wedge: once the provider stops refusing, the bundle and then the follower
    /// both execute, in that order.
    ///
    /// RED PROOF (recorded): with the unresolved arm's tail movement no longer
    /// recording the chain in `DrainContext.deferredOperationIds`, the bundle is
    /// re-claimed and re-sent every time the walk comes back round to it inside
    /// the same drain — `movedIds.count` climbs without bound instead of settling
    /// at 1 after the first drain and 2 after the second, and `retryCount` climbs
    /// with it.
    @Test("An unresolved multi-member failure is attempted once per drain, isolates nobody, and converges")
    @MainActor
    func anUnresolvedBatchIsAttemptedOncePerDrainAndConverges() async throws {
        // `.gmail` so the lane key is ACCOUNT-qualified: the independent work, the
        // bundle and the follower are then one ordered lane, and every claim pass
        // re-forms it. Under a folder-qualified key the independent work would be
        // a concurrent lane and the ordering below would be a race.
        let f = try fixture(accountId: "absence-unresolved-passes", provider: .gmail)
        try seedHeader(f, messageId: "u-1", rfc: "u-one@example.com")
        try seedHeader(f, messageId: "u-2", rfc: "u-two@example.com")
        try seedHeader(f, messageId: "u-3", rfc: "u-three@example.com")

        let provider = MockEmailProvider()
        await provider.setMoveThrows(ProviderError.messageNotFound)
        await AccountManager.shared.registerProviderForTesting(
            accountId: f.accountId, provider: provider)

        // Ordered by `createdAt`, whole-second so the GRDB round trip compares
        // exactly, and relative to now (no hardcoded dates).
        let base = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded() - 3600)
        var independent = PendingOperation(
            type: .markRead, messageIds: ["u-3"],
            accountId: f.accountId, folderPath: Self.source)
        independent.createdAt = base
        var bundle = PendingOperation(
            type: .move, messageIds: ["u-1", "u-2"],
            accountId: f.accountId, folderPath: Self.source,
            destinationPath: Self.destination)
        bundle.createdAt = base.addingTimeInterval(1)
        var follower = PendingOperation(
            type: .markRead, messageIds: ["u-1"],
            accountId: f.accountId, folderPath: Self.source)
        follower.createdAt = base.addingTimeInterval(2)
        for op in [independent, bundle, follower] { try insert(op, into: f) }

        await drainPasses(1)

        // NON-VACUITY: the independent op really did execute, so the drain really
        // did have further passes to make — and the account was not isolated.
        let firstDrainReads = await provider.markedReadIds.map(\.ids)
        #expect(firstDrainReads == [["u-3"]], """
            the independent work did not execute exactly once, so this drain never \
            had a second claim pass and "attempted once per drain" is untested: \
            \(firstDrainReads)
            """)

        let firstDrainMoves = await provider.movedIds.map(\.ids)
        #expect(firstDrainMoves == [["u-1", "u-2"]], """
            the unresolved bundle was sent \(firstDrainMoves.count) time(s) in ONE \
            drain. It is attempted at most once per drain: a refusal raised after a \
            wire mutation would otherwise be repeated on every remaining pass. \
            Got: \(firstDrainMoves)
            """)

        var rows = try operations(f)
        #expect(rows.count == 2, "the bundle and its follower must both still be owed: \(rows.map(\.messageIds))")
        guard rows.count == 2 else { await finish(f); return }
        var heldBundle = try #require(rows.first { $0.id == bundle.id })
        let heldFollower = try #require(rows.first { $0.id == follower.id })
        #expect(heldBundle.messageIds == ["u-1", "u-2"],
                "no member was individually dispositioned, so every member is still owed")
        #expect(heldBundle.retryCount == 1, """
            the unresolved bundle was charged \(heldBundle.retryCount) retries for \
            ONE drain. A refusal is charged once per drain, not once per pass.
            """)
        #expect(heldBundle.status == PendingStatus.queued.rawValue,
                "an unresolved operation must be retryable, not left claimed")
        #expect(heldFollower.retryCount == 0,
                "the follower was charged for its predecessor's refusal")

        // THE FOLLOWER IS UNTOUCHED. It names a member of the unresolved bundle,
        // so running it applies the user's LATER gesture to a message whose
        // earlier one has not happened.
        let readsAfterFirstDrain = await provider.markedReadIds.map(\.ids)
        #expect(readsAfterFirstDrain.allSatisfy { $0 == ["u-3"] }, """
            the follower ran ahead of the unresolved predecessor that shares its \
            member: \(readsAfterFirstDrain)
            """)

        // ONE MORE DRAIN — "once per drain" is a rate, and a single drain cannot
        // tell it apart from "once, ever".
        await drainPasses(1)
        let secondDrainMoves = await provider.movedIds.map(\.ids)
        #expect(secondDrainMoves.count == 2, """
            the second drain sent the bundle \(secondDrainMoves.count - 1) time(s) \
            instead of once: \(secondDrainMoves)
            """)
        rows = try operations(f)
        heldBundle = try #require(rows.first { $0.id == bundle.id })
        #expect(heldBundle.retryCount == 2,
                "the second drain charged \(heldBundle.retryCount - 1) retries instead of one")

        // LIVENESS — the refusal ends and both gestures land, in the order the
        // user made them.
        await provider.setMoveThrows(nil)
        try await drainToQuiescence(f)

        #expect(try operations(f).isEmpty, """
            the bundle or its follower starved after the refusal cleared. A gesture \
            that never executes has been dropped just as surely as one that was \
            deleted (the wedge corollary).
            """)
        let finalMoves = await provider.movedIds.map(\.ids)
        #expect(finalMoves.last == ["u-1", "u-2"],
                "the bundle never completed as ONE operation: \(finalMoves)")
        let finalReads = await provider.markedReadIds.map(\.ids)
        #expect(finalReads == [["u-3"], ["u-1"]], """
            the follower did not execute exactly once, after its predecessor: \
            \(finalReads)
            """)

        await finish(f)
    }

}
