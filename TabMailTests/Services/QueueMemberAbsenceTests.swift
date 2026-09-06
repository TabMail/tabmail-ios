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
/// `ProviderMembersAbsent`, `confirmedGoneMembers` or any other type introduced
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
        try fixture.pool.writeWithoutTransaction { db in try op.insert(db) }
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

}
