/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Testing
@testable import TabMail

/// Audit round 1, classes A and B — the closure, not the nine instances.
///
/// > Only two positive, non-zero epochs that disagree in the operation's OWN
/// > source address space may retire a queued op through exit 4. Every missing,
/// > malformed, unreadable, zero, or unknown component leaves the op durably
/// > queued. Retirement is per MEMBER, never per batch.
///
/// A queued op may leave the queue for exactly four reasons: provider success; a
/// PROVIDER-AUTHORITATIVE stale/no-op result; annihilation by a newer inverse
/// action; a PROVEN id reset in its own address space. **"We could not determine
/// the answer" is not an exit.**
///
/// Every test here asserts a SYSTEM PROPERTY — what happened to the user's
/// intention and what reached the wire — never the mechanism that produced it.
/// None of them assert that a stamp is non-nil or that a thrown error has a
/// particular type; a test written that way inherits the spec error it was meant
/// to catch.
@Suite("Never-drop exit closure — audit classes A and B", .serialized, .processGlobalState)
struct NeverDropExitClosureTests {
    private struct Fixture {
        let pool: DatabasePool
        let directory: URL
        let previous: AppDatabase?
        let accountId: String
    }

    /// Folders are `(path, role, lastKnownUidValidity)`. A `nil` epoch models a
    /// folder we have never successfully SELECTed.
    @MainActor
    private func fixture(
        accountId: String,
        provider: AccountProvider = .imap,
        folders: [(String, FolderRole, Int?)] = [("INBOX", .inbox, 10), ("Archive", .archive, 10)]
    ) throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
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
                emailAddress: "closure@example.com", displayName: "Closure", provider: provider)
            account.id = accountId
            try account.insert(db)
            for (path, role, epoch) in folders {
                var folder = Folder(name: path, path: path, role: role, accountId: accountId)
                folder.lastKnownUidValidity = epoch
                try folder.insert(db)
            }
        }
        return Fixture(pool: pool, directory: directory, previous: previous, accountId: accountId)
    }

    @MainActor
    private func finish(_ fixture: Fixture) async {
        await AccountManager.shared.unregisterProviderForTesting(accountId: fixture.accountId)
        InstalledTestDatabaseLifetime.finish(
            previous: fixture.previous, pool: fixture.pool, directory: fixture.directory)
    }

    private func insert(_ operations: [PendingOperation], into pool: DatabasePool) throws {
        try pool.writeWithoutTransaction { db in
            for operation in operations { try operation.insert(db) }
        }
    }

    private func operations(_ pool: DatabasePool) throws -> [PendingOperation] {
        try pool.read { db in try PendingOperation.order(Column("createdAt").asc).fetchAll(db) }
    }

    private static func rfc822(messageId: String) -> String {
        """
        From: Sender <sender@example.com>\r
        To: Receiver <receiver@example.com>\r
        Subject: closure\r
        Date: Thu, 01 Jan 2026 00:00:00 +0000\r
        Message-ID: <\(messageId)>\r
        Content-Type: text/plain; charset=utf-8\r
        \r
        closure body\r

        """
    }

    private static func message(uid: Int, id: String) -> FakeIMAPServer.Message {
        FakeIMAPServer.makeMessage(uid: uid, rfc822Text: rfc822(messageId: id))
    }

    @MainActor
    private func registeredIMAPProvider(
        server: FakeIMAPServer, fixture: Fixture
    ) async throws -> IMAPProvider {
        let provider = IMAPProvider(
            host: "127.0.0.1", port: server.port,
            username: server.username, password: server.password,
            smtpHost: "127.0.0.1", smtpPort: 587, useTLS: false)
        try await provider.connect()
        await AccountManager.shared.registerProviderForTesting(
            accountId: fixture.accountId, provider: provider)
        return provider
    }

    // MARK: - A-2 — a batch split must not destroy the admission the parent held

    /// A-2. The split rebuilds each member as a fresh child and deletes the
    /// parent IN THE SAME TRANSACTION, so any field not copied across is
    /// destroyed. The children were being built without `observedUidValidity`,
    /// which on IMAP made every one of them un-admittable — and, before A-3, a
    /// deterministic DELETE on the very next drain. A conflict on ONE member of
    /// a batch silently reverted the gesture for ALL of them.
    ///
    /// THE PROPERTY: the members that were NOT the conflict still get moved.
    /// The test never inspects a stamp and never inspects the intermediate split
    /// rows — `drainPendingQueue` keeps claiming until nothing is claimable, so
    /// the children are born and executed inside the same call. What it observes
    /// is the provider's own record of what it was asked to do.
    ///
    /// The conflict is armed on the FIRST member so the batch attempt records no
    /// partial prefix; every entry in `movedIds` afterwards is therefore a split
    /// child, which is what makes the assertion unambiguous. Member "1" itself
    /// is correctly retired — `messageNotFound` is exit 2, the provider telling
    /// us the work is moot.
    ///
    /// RED PROOF (recorded): dropping `observedUidValidity: currentOp.observedUidValidity`
    /// from the `splitOp` initializer fails this at the `movedIds` assertion —
    /// the set is empty, because checkpoint A cannot admit an unstamped child
    /// (and, before A-3, deleted it outright). The conflict on ONE member
    /// silently reverted the gesture for ALL of them.
    @Test("A batch split leaves children the drain can still execute")
    @MainActor
    func batchSplitChildrenRemainExecutable() async throws {
        let f = try fixture(accountId: "closure-split")
        let provider = MockEmailProvider(staleWindowMode: .uid)
        await AccountManager.shared.registerProviderForTesting(accountId: f.accountId, provider: provider)
        // A conflict on the FIRST member is what triggers the split, and leaves
        // the batch attempt with an empty "already succeeded" prefix.
        await provider.setMoveThrowsOnId("1", error: ProviderError.messageNotFound)

        let parent = PendingOperation(
            type: .move, messageIds: ["1", "2", "3"], accountId: f.accountId,
            folderPath: "INBOX", destinationPath: "Archive", observedUidValidity: 10)
        try insert([parent], into: f.pool)

        await AccountManager.shared.drainPendingQueue()

        let movedIds = await provider.movedIds
        let movedMembers = Set(movedIds.flatMap(\.ids))
        #expect(
            movedMembers == Set(["2", "3"]),
            "the members that were not the conflict must still be moved — a child that lost its admission is a silently reverted gesture: \(movedIds)"
        )
        // Each survivor moved as its own single-member op, which is what "split"
        // means; a whole-batch retry would show ["1","2","3"] in one entry.
        #expect(movedIds.allSatisfy { $0.ids.count == 1 })
        #expect(try operations(f.pool).isEmpty)
        await finish(f)
    }

    // MARK: - A-4 — an unknown live epoch is not a proven turnover

    /// A-4. `requireUidValidity` threw the SAME
    /// `ProviderError.uidValidityChanged` for a proven turnover and for a
    /// server that simply did not report a UIDVALIDITY on SELECT (SwiftMail
    /// yields the `UIDValidity(0)` default). The drain retires that error, so a
    /// nonconforming server destroyed the op.
    ///
    /// This is the brief's own stated example: *a folder SELECT reporting no
    /// UIDVALIDITY leaves the op queued*.
    ///
    /// RED PROOF (recorded): reverting `requireUidValidity` to the two-outcome
    /// `guard live == expected` form fails this at `after.count == 1` — the row
    /// is gone, retired as a turnover that was never observed.
    @Test("A source SELECT that reports no UIDVALIDITY leaves the op queued and mutates nothing")
    @MainActor
    func unknownSourceEpochLeavesTheOpQueued() async throws {
        let target = "unknown-source-epoch@example.com"
        let server = FakeIMAPServer(mailboxes: ["INBOX": [Self.message(uid: 5, id: target)]])
        server.setUidValidity(10, for: "INBOX")
        // The mailbox's real epoch is untouched and MATCHES the op's stamp — the
        // only thing missing is the server telling us so. If absence were treated
        // as evidence, this op would be retired despite nothing having changed.
        server.suppressSelectUidValidity(for: "INBOX")
        server.expectMutation(rfc822MessageId: target)
        try server.start()
        defer { server.stop() }

        let f = try fixture(accountId: "closure-unknown-epoch")
        let provider = try await registeredIMAPProvider(server: server, fixture: f)
        let op = PendingOperation(
            type: .markRead, messageIds: ["5"], accountId: f.accountId,
            folderPath: "INBOX", observedUidValidity: 10)
        try insert([op], into: f.pool)

        await AccountManager.shared.drainPendingQueue()

        let after = try operations(f.pool)
        #expect(
            after.count == 1,
            "an unknown live epoch is an absence of evidence — the op must stay queued, not be retired as a proven turnover"
        )
        guard after.count == 1 else {
            try? await provider.disconnect()
            await finish(f)
            return
        }
        #expect(after[0].id == op.id)
        #expect(after[0].status == PendingStatus.queued.rawValue)
        // C3: refusing must also mean mutating nothing.
        #expect(!server.flags(in: "INBOX", uid: 5).contains("\\Seen"))
        #expect(server.wrongMessageViolations().isEmpty)
        try? await provider.disconnect()
        await finish(f)
    }

    /// NON-VACUITY partner for `unknownSourceEpochLeavesTheOpQueued`: the same
    /// fixture with the suppression removed completes normally. Without this,
    /// the test above would pass against a provider that could never mutate
    /// anything.
    @Test("The same fixture with UIDVALIDITY reported completes the action and retires the op")
    @MainActor
    func reportedSourceEpochCompletesTheAction() async throws {
        let target = "known-source-epoch@example.com"
        let server = FakeIMAPServer(mailboxes: ["INBOX": [Self.message(uid: 5, id: target)]])
        server.setUidValidity(10, for: "INBOX")
        server.expectMutation(rfc822MessageId: target)
        try server.start()
        defer { server.stop() }

        let f = try fixture(accountId: "closure-known-epoch")
        let provider = try await registeredIMAPProvider(server: server, fixture: f)
        try insert([PendingOperation(
            type: .markRead, messageIds: ["5"], accountId: f.accountId,
            folderPath: "INBOX", observedUidValidity: 10)], into: f.pool)

        await AccountManager.shared.drainPendingQueue()

        #expect(server.flags(in: "INBOX", uid: 5).contains("\\Seen"))
        #expect(try operations(f.pool).isEmpty)
        #expect(server.wrongMessageViolations().isEmpty)
        try? await provider.disconnect()
        await finish(f)
    }

    // MARK: - A-5 — local absence is not provider authority

    /// A-5. The move arm deleted the op when the destination folder was merely
    /// absent from local GRDB, calling it a self-heal. A folder row we have not
    /// synced yet, or lost, says nothing about whether the mailbox exists on the
    /// server — and the user asked for this move. Only the provider may declare
    /// the destination gone (`IMAPActionMailboxAbsent`, which the move path
    /// still honours as exit 2).
    ///
    /// RED PROOF (recorded): restoring the `destMissing` delete fails this at
    /// `after.count == 1` — the archive is silently discarded and, because the
    /// local row is what the drain consults, it never retries once the folder
    /// syncs.
    @Test("A move whose destination folder is missing LOCALLY keeps the op queued")
    @MainActor
    func locallyMissingDestinationKeepsTheOpQueued() async throws {
        // Only INBOX exists locally: the user moved to a folder this device has
        // no `Folder` row for yet.
        let f = try fixture(
            accountId: "closure-dest-missing",
            folders: [("INBOX", .inbox, 10)])
        let provider = MockEmailProvider(staleWindowMode: .uid)
        await AccountManager.shared.registerProviderForTesting(accountId: f.accountId, provider: provider)
        await provider.setMoveThrows(ProviderError.notConnected)

        let op = PendingOperation(
            type: .move, messageIds: ["1"], accountId: f.accountId,
            folderPath: "INBOX", destinationPath: "Archive", observedUidValidity: 10)
        try insert([op], into: f.pool)

        await AccountManager.shared.drainPendingQueue()

        let after = try operations(f.pool)
        #expect(
            after.count == 1,
            "a destination absent from LOCAL GRDB is not the provider saying the mailbox is gone — the move must stay queued"
        )
        guard after.count == 1 else { await finish(f); return }
        #expect(after[0].id == op.id)
        #expect(after[0].status == PendingStatus.queued.rawValue)

        // And it is genuinely retryable: once the transient condition clears the
        // same intention executes, without the folder row ever appearing.
        await provider.setMoveThrows(nil)
        await AccountManager.shared.drainPendingQueue()
        let moved = await provider.movedIds.flatMap(\.ids)
        #expect(moved.contains("1"))
        #expect(try operations(f.pool).isEmpty)
        await finish(f)
    }

    // MARK: - A-6 — a label gesture must be addressable on the wire

    /// A-6. `UserLabelMenuModel.applyLabel` enqueued `MessageHeader.stableId` —
    /// an rfc822 Message-ID on IMAP — with no admission epoch. Checkpoint A can
    /// only refuse that shape, so on IMAP EVERY label gesture was accepted by
    /// the UI, checkmarked, and then deterministically destroyed: a shipped
    /// capability (`v1.6.38`'s `setUserLabel`) reduced to a phantom.
    ///
    /// THE PROPERTY: the keyword actually lands on the server. Asserted at the
    /// wire, not at the queue, because a stamped op that no provider arm can
    /// execute would still be a dropped intention.
    ///
    /// RED PROOF (recorded): reverting `applyLabel` to
    /// `messageIds: [header.stableId]` with no `observedUidValidity` fails this
    /// at the keyword assertion — the server records no STORE at all — and the
    /// op row is gone by the end of the drain.
    @Test("An IMAP user-label gesture reaches the server as a keyword STORE")
    @MainActor
    func imapUserLabelGestureReachesTheWire() async throws {
        let target = "label-target@example.com"
        let server = FakeIMAPServer(mailboxes: ["INBOX": [Self.message(uid: 44, id: target)]])
        server.setUidValidity(10, for: "INBOX")
        server.expectMutation(rfc822MessageId: target)
        try server.start()
        defer { server.stop() }

        let f = try fixture(accountId: "closure-label", folders: [("INBOX", .inbox, 10)])
        let provider = try await registeredIMAPProvider(server: server, fixture: f)

        var header = MessageHeader(
            messageId: "44", subject: "Label target", from: "Sender",
            fromAddress: "sender@example.com", to: "me@example.com", date: Date(),
            snippet: "label",
            folderId: MessageIdentity.folderId(accountId: f.accountId, folderPath: "INBOX"),
            accountId: f.accountId, folderPath: "INBOX", isInInbox: true)
        header.rfc822MessageId = target
        header.headerComplete = true
        // Every synced IMAP row carries the epoch it was observed under; that is
        // what `admittedOrdinaryActionTargets` proves the on-screen address
        // against before admitting a gesture on it.
        header.observedUidValidity = 10
        let storedHeader = header
        try await f.pool.writeWithoutTransaction { db in
            try storedHeader.insert(db)
            try UserLabel(accountId: f.accountId, providerLabelId: "urgent", name: "Urgent", isSystem: false)
                .insert(db)
        }

        let model = UserLabelMenuModel(messageSnapshot: MessageSnapshot(from: storedHeader))
        model.supportsRemoteUserLabels = true
        let applied = await model.applyLabel(
            UserLabel(accountId: f.accountId, providerLabelId: "urgent", name: "Urgent", isSystem: false))
        #expect(applied, "the gesture must be admitted on a provider that supports remote labels")

        // `applyLabel` drains inline; drain again so a requeue would still land.
        await AccountManager.shared.drainPendingQueue()

        #expect(
            server.flags(in: "INBOX", uid: 44).contains("urgent"),
            "the label must reach the server: \(server.flags(in: "INBOX", uid: 44))"
        )
        #expect(try operations(f.pool).isEmpty)
        #expect(server.wrongMessageViolations().isEmpty)
        try? await provider.disconnect()
        await finish(f)
    }

    // MARK: - B-1 — an unprovable move is retryable, not terminal

    /// B-1. `IMAPProvider.move`'s evidence refusal threw
    /// `ProviderError.actionIdentityResolutionFailed`, which lands in a drain
    /// arm that DELETES the op. Every premise in that arm's comment was
    /// `.deleteDraft`-specific, so the effect was that upgrading silently
    /// discarded archives on exactly the servers least able to prove anything.
    ///
    /// ⚠ **RE-SCOPED TWICE — record both prior fixtures, because each was a
    /// BLESSING TEST for the wedge of its round, and a display name that no
    /// longer exists silently reads as ABSENT on an expected-name list.**
    ///  1. Rounds 1–2: a NON-UIDPLUS server. That pinned "a move on a
    ///     non-UIDPLUS server leaves the source untouched and the op queued" as
    ///     correct, when the capability can never appear, so the op could never
    ///     complete on any future drain and its `.haltLane` disposition starved
    ///     every later gesture on that message forever. Round 3 deleted the
    ///     capability refusal; the two-sided partner is now
    ///     `aNonUidPlusMoveCompletesAndReleasesItsLane`.
    ///  2. Round 3: a UIDPLUS server that WITHHOLDS `COPYUID`, on the theory
    ///     that such a server "may prove it next time" (RFC 4315 §3 makes the
    ///     response code a MAY). **Audit round 4 found that theory false** — §3
    ///     makes it a SHOULD "with limited exceptions", then names two, both
    ///     properties of the MAILBOX rather than of the attempt: a mailbox the
    ///     client may COPY or APPEND to but not SELECT or EXAMINE ("SHOULD NOT
    ///     send"), and a `UIDNOTSTICKY` mail store ("MAY omit"). For such a
    ///     server the evidence never arrives and this was
    ///     blessing a second permanent wedge, one that re-COPIES on every drain
    ///     and seats a destination duplicate each time. The two-sided partner is
    ///     now `aWithheldCopyUidMoveCompletesAndReleasesItsLane`.
    ///
    /// The display name is unchanged only because the property is unchanged: an
    /// op whose outcome this attempt could not DETERMINE stays queued. What
    /// changed both times is the fixture — which server behaviour actually
    /// leaves the outcome undetermined.
    ///
    /// **The fixture now is a destination that omits the REQUIRED
    /// `* OK [UIDVALIDITY n]` from its SELECT response (RFC 3501 §6.3.1).**
    /// This is the genuine "we could not determine the answer": the move is
    /// refused BEFORE the `UID COPY`, so no wire mutation happens, no duplicate
    /// is seated, and the next attempt against a conforming SELECT completes
    /// normally. Nothing about it is a capability the server can never have.
    ///
    /// RED PROOF (recorded): restoring
    /// `throw ProviderError.actionIdentityResolutionFailed` on the evidence
    /// gate fails this at `after.count == 1` — the row is deleted by the generic
    /// identity-resolution arm.
    @Test("A move on a server that cannot prove COPYUID keeps the op queued")
    @MainActor
    func unprovableMoveKeepsTheOpQueued() async throws {
        let target = "unprovable-move@example.com"
        let server = FakeIMAPServer(mailboxes: [
            "INBOX": [Self.message(uid: 77, id: target)],
            "Archive": [],
        ])
        // The destination's SELECT omits `* OK [UIDVALIDITY n]`, so this attempt
        // never learns which address space a `COPYUID` would even refer to. That
        // is an absence of evidence, not a statement about the mailbox, and the
        // very next conformant SELECT ends it.
        server.suppressSelectUidValidity(for: "Archive")
        server.setUidValidity(10, for: "INBOX")
        server.setUidValidity(10, for: "Archive")
        server.expectMutation(rfc822MessageId: target)
        try server.start()
        defer { server.stop() }

        let f = try fixture(accountId: "closure-no-uidplus")
        let provider = try await registeredIMAPProvider(server: server, fixture: f)
        let op = PendingOperation(
            type: .move, messageIds: ["77"], accountId: f.accountId,
            folderPath: "INBOX", destinationPath: "Archive", observedUidValidity: 10)
        try insert([op], into: f.pool)

        await AccountManager.shared.drainPendingQueue()

        let after = try operations(f.pool)
        #expect(
            after.count == 1,
            "a server that did not report the destination epoch has told us nothing about whether the move happened — the intention must survive"
        )
        guard after.count == 1 else {
            try? await provider.disconnect()
            await finish(f)
            return
        }
        #expect(after[0].id == op.id)
        #expect(after[0].status == PendingStatus.queued.rawValue)
        // The source is untouched and NOTHING was copied, so nothing was lost by
        // refusing and no retry can accumulate duplicates.
        #expect(server.messageIDs(in: "INBOX") == ["<\(target)>"])
        #expect(server.messageIDs(in: "Archive").isEmpty)
        #expect(server.flags(in: "INBOX", uid: 77).isEmpty)
        #expect(server.wrongMessageViolations().isEmpty)
        try? await provider.disconnect()
        await finish(f)
    }

    // MARK: - AUDIT ROUND 2 / MUST FIX 2 — an unprovable op is not an account outage

    /// 🚨 AUDIT ROUND 2. `unprovableMoveKeepsTheOpQueued` above proved the
    /// unprovable op SURVIVES. It did not ask what that survival cost everything
    /// else, and the answer was: everything else.
    ///
    /// The evidence-unavailable refusals fell through to the drain's generic
    /// connection/transient arm, which does
    /// `context.failedAccounts.insert(currentOp.accountId)`. That set means "this
    /// account's PROVIDER is down, stop hammering it" and it is ACCOUNT-WIDE — so
    /// an op the server merely declined to prove took every other gesture on the
    /// account down with it, and `ctx` is per-drain so the next drain reproduced it
    /// exactly. On a standards-valid non-UIDPLUS server (RFC 4315 §3 makes COPYUID
    /// a MAY) that is not a hiccup, it is the queue's permanent end state, and no
    /// UI lists or clears `PendingOperation` rows so the user can neither see it
    /// nor clear it. Before round 1 the op was simply deleted: one dropped move,
    /// queue kept working. **Preserving one intention by denying every intention
    /// behind it is not never-drop — it is a worse violation wearing a safe shape.**
    ///
    /// TWO PROPERTIES, both asserted at the server across TWO drains, because the
    /// fix has to hold a line on each side and the obvious repair breaks the other:
    ///
    ///  1. **An UNRELATED op on the same account still reaches the wire.** Different
    ///     lane, so nothing about it depends on the unprovable op's outcome. Three
    ///     of them, not one, each landing a distinct flag: the account-wide skip was
    ///     re-evaluated before EVERY op in a lane, so the second and third were
    ///     refused even once the first had slipped through.
    ///  2. **A LANE-MATE of the unprovable op does NOT reach the wire while that op
    ///     is still queued.** `buildLanes` unions on shared message ids, so a
    ///     lane-mate names the same message; running it ahead of an unresolved
    ///     predecessor is the race `.haltLane` exists to prevent, and the fix must
    ///     not buy property 1 by giving that up. This is a REGRESSION GUARD: it is
    ///     green pre-fix (the poison stopped everything, including this) and green
    ///     post-fix, and it goes red on the natural-looking repair that skips the
    ///     refused op at CLAIM time — which lets its lane form without it.
    ///
    /// It deliberately does NOT assert that the unprovable op is still queued (that
    /// is `unprovableMoveKeepsTheOpQueued`'s job) and never inspects
    /// `failedAccounts`, `evidenceRefused` or any other drain internal — all
    /// mechanism, and a test written against them would keep passing if the poison
    /// simply moved somewhere else.
    ///
    /// ⚠ **RE-SCOPED TWICE, each time for the same reason and in lockstep with
    /// `unprovableMoveKeepsTheOpQueued` above — read that test's fixture history
    /// first; it is the full argument.** Property 2 requires the lane-mate NOT
    /// to reach the wire, so it is a lane-ORDERING property only while the
    /// predecessor is genuinely unresolved-FOR-NOW. On a predecessor that can
    /// never resolve, the very same assertion pins PERMANENT STARVATION of a
    /// gesture the user made as correct — which is what it was doing with a
    /// NON-UIDPLUS fixture (rounds 1–2) and again with a `COPYUID`-withholding
    /// UIDPLUS fixture (round 3; audit round 4 showed RFC 4315 §3 names servers
    /// for which that response code never arrives). Both of those now COMPLETE,
    /// and their lane-mates MUST execute — see
    /// `aNonUidPlusMoveCompletesAndReleasesItsLane` and
    /// `aWithheldCopyUidMoveCompletesAndReleasesItsLane`.
    ///
    /// The fixture is therefore a destination whose SELECT omits the REQUIRED
    /// `* OK [UIDVALIDITY n]` (RFC 3501 §6.3.1): refused before any wire
    /// mutation, resolvable by the next conformant SELECT, and — the reason it
    /// suits THIS test specifically — scoped to the move's destination, so the
    /// account's other gestures on INBOX are entirely unaffected by it, which is
    /// exactly the separation property 1 measures.
    @Test("An op the server will never prove wedges only its own lane, not the account")
    @MainActor
    func unprovableOpDoesNotWedgeTheAccountsOtherGestures() async throws {
        let unprovable = "wedge-unprovable@example.com"
        let bystander = "wedge-bystander@example.com"
        let server = FakeIMAPServer(mailboxes: [
            "INBOX": [Self.message(uid: 77, id: unprovable), Self.message(uid: 88, id: bystander)],
            "Archive": [],
        ])
        // The move's destination reports no UIDVALIDITY, so the move cannot be
        // resolved THIS attempt and is refused before any wire mutation; a
        // conformant SELECT on any later attempt ends the refusal.
        server.suppressSelectUidValidity(for: "Archive")
        server.setUidValidity(10, for: "INBOX")
        server.setUidValidity(10, for: "Archive")
        server.expectMutation(rfc822MessageId: unprovable)
        server.expectMutation(rfc822MessageId: bystander)
        try server.start()
        defer { server.stop() }

        let f = try fixture(accountId: "closure-wedge")
        let provider = try await registeredIMAPProvider(server: server, fixture: f)

        // The op this attempt cannot obtain evidence for.
        var unprovableMove = PendingOperation(
            type: .move, messageIds: ["77"], accountId: f.accountId,
            folderPath: "INBOX", destinationPath: "Archive", observedUidValidity: 10)
        unprovableMove.createdAt = Date().addingTimeInterval(-60)

        func later(
            _ type: OperationType, on uid: String, _ secondsAgo: TimeInterval
        ) -> PendingOperation {
            var op = PendingOperation(
                type: type, messageIds: [uid], accountId: f.accountId,
                folderPath: "INBOX", observedUidValidity: 10)
            op.createdAt = Date().addingTimeInterval(-secondsAgo)
            return op
        }
        try insert(
            [
                unprovableMove,
                // Property 2's subject: names the SAME message as the unprovable
                // move, so `buildLanes` puts it in that op's lane, behind it.
                later(.markFlagged, on: "77", 40),
                // Property 1's subjects: a different message, therefore a different
                // lane, therefore nothing to do with the refusal.
                later(.markRead, on: "88", 30),
                later(.markFlagged, on: "88", 20),
                later(.markReplied, on: "88", 10),
            ],
            into: f.pool)

        await AccountManager.shared.drainPendingQueue()
        await AccountManager.shared.drainPendingQueue()

        // PROPERTY 1 — the rest of the account still reaches the wire.
        let unrelated = server.flags(in: "INBOX", uid: 88)
        #expect(
            unrelated.contains("\\Seen"),
            "the first unrelated gesture never reached the server — flags: \(unrelated)")
        #expect(
            unrelated.contains("\\Flagged"),
            """
            a gesture on an UNRELATED message was refused because a different op could not be \
            proven. An unprovable refusal is not a provider outage, and one intention may never be \
            preserved by denying every intention behind it — flags: \(unrelated)
            """)
        #expect(
            unrelated.contains("\\Answered"),
            """
            the account is still wedged after the earlier gestures got through — the account-wide \
            skip is re-evaluated before every op in a lane, so a later one is refused even once an \
            earlier one slipped past — flags: \(unrelated)
            """)

        // PROPERTY 2 — the lane-mate is still held behind its unresolved
        // predecessor. NON-VACUOUS by construction: the identical `.markFlagged`
        // gesture on uid 88 above provably lands, so this absence is the lane
        // ordering holding, not `.markFlagged` being unable to work.
        let laneMate = server.flags(in: "INBOX", uid: 77)
        #expect(
            !laneMate.contains("\\Flagged"),
            """
            a lane-mate of the unprovable op executed while that op was still queued. They name the \
            SAME message by construction, so this gesture ran ahead of a predecessor the user \
            issued FIRST and whose eventual retry will now act against state it never observed — \
            flags: \(laneMate)
            """)
        // C3 holds throughout: nothing was mutated on a message no gesture named.
        #expect(server.wrongMessageViolations().isEmpty)
        try? await provider.disconnect()
        await finish(f)
    }

    // MARK: - AUDIT ROUND 3 — a capability the server lacks is not "unproven yet"

    /// 🚨 AUDIT ROUND 3. `IMAPProvider.move` opened with
    /// `guard await server.supportsUIDPlus else { throw … }`, so on a
    /// standards-valid non-UIDPLUS server the move threw before any wire
    /// mutation — on EVERY attempt, forever, because the missing capability is
    /// not evidence that can arrive later. The refusal's drain arm returns
    /// `.haltLane`, and `buildLanes` unions ops that share a message id, so the
    /// user's every LATER gesture on that same message was held behind an op
    /// that could never resolve. Neither row had any user-visible resolution
    /// path: nothing lists or clears `PendingOperation`.
    ///
    /// **That is the never-drop WEDGE corollary — an op that stays queued but
    /// prevents every intention behind it from executing has not been
    /// preserved** — and three tests were BLESSING it as correct
    /// (`unprovableMoveKeepsTheOpQueued`, `unprovableOpDoesNotWedgeThe…`, and
    /// `IMAPMoveWireContractTests.nonUidPlusMove…`); all three are re-scoped to
    /// the UIDPLUS-withholding case, which is the genuinely-unprovable one.
    ///
    /// THE PROPERTY, asserted as end state at the server and in the queue —
    /// never as "the provider did not throw a particular error":
    ///  1. the user's move COMPLETED: the message is at the destination and its
    ///     source copy is soft-deleted;
    ///  2. the queue is EMPTY, so the op retired and nothing is starved;
    ///  3. a LANE-MATE gesture the user issued afterwards on the same message
    ///     EXECUTED — the half that makes this a wedge test rather than a move
    ///     test.
    ///
    /// The source copy is `\Deleted` but still present, which is deliberate and
    /// is the accepted cost recorded in `KNOWN_ISSUES.md` `IOS-IMAP-001`: a
    /// server without UIDPLUS has no narrower purge than a mailbox-wide
    /// `EXPUNGE`, which would irreversibly destroy unrelated mail that already
    /// carries `\Deleted`. Incomplete VISIBLE cleanup is preferred over both
    /// that and the permanent wedge. Asserting the `\Deleted` mark (rather than
    /// the source being gone) pins exactly that decision.
    ///
    /// RED PROOF (recorded): with the `supportsUIDPlus` refusal restored, this
    /// fails at property 1 — `Archive` is empty — and at properties 2 and 3.
    @Test("A move on a server without UIDPLUS completes and releases its lane")
    @MainActor
    func aNonUidPlusMoveCompletesAndReleasesItsLane() async throws {
        let target = "nouidplus-target@example.com"
        let bystander = "nouidplus-bystander@example.com"
        let server = FakeIMAPServer(
            capabilities: FakeIMAPServer.defaultCapabilities.filter { $0 != "UIDPLUS" },
            mailboxes: [
                "INBOX": [Self.message(uid: 77, id: target), Self.message(uid: 88, id: bystander)],
                "Archive": [],
            ])
        server.setUidValidity(10, for: "INBOX")
        server.setUidValidity(10, for: "Archive")
        server.expectMutation(rfc822MessageId: target)
        server.expectMutation(rfc822MessageId: bystander)
        try server.start()
        defer { server.stop() }

        let f = try fixture(accountId: "closure-nouidplus-completes")
        let provider = try await registeredIMAPProvider(server: server, fixture: f)

        var move = PendingOperation(
            type: .move, messageIds: ["77"], accountId: f.accountId,
            folderPath: "INBOX", destinationPath: "Archive", observedUidValidity: 10)
        move.createdAt = Date().addingTimeInterval(-60)
        // Issued AFTER the move and naming the SAME message, so `buildLanes` puts
        // it in the move's lane, behind it. This is the gesture the wedge starved.
        var laneMate = PendingOperation(
            type: .markFlagged, messageIds: ["77"], accountId: f.accountId,
            folderPath: "INBOX", observedUidValidity: 10)
        laneMate.createdAt = Date().addingTimeInterval(-40)
        try insert([move, laneMate], into: f.pool)

        await AccountManager.shared.drainPendingQueue()

        // PROPERTY 1 — the move completed on the wire.
        #expect(
            server.messageIDs(in: "Archive") == ["<\(target)>"],
            """
            the user's archive never reached the destination on a server whose only defect is that \
            it does not advertise a MAY-level extension — Archive: \(server.messageIDs(in: "Archive"))
            """)
        let sourceFlags = server.flags(in: "INBOX", uid: 77)
        #expect(
            sourceFlags.contains("\\Deleted"),
            "the source copy was not soft-deleted, so the move only half happened — flags: \(sourceFlags)")
        // IOS-IMAP-001: no mailbox-wide EXPUNGE, so the bystander is untouched.
        #expect(server.messageIDs(in: "INBOX").contains("<\(bystander)>"))

        // PROPERTY 2 — nothing is starved: both ops retired.
        #expect(
            try operations(f.pool).isEmpty,
            "an op remained queued after a move that completed, so the lane is still held")

        // PROPERTY 3 — the lane-mate the user issued afterwards EXECUTED. This is
        // the half the deleted refusal made impossible forever.
        #expect(
            sourceFlags.contains("\\Flagged"),
            """
            the lane-mate gesture never reached the server. Its predecessor completed, so nothing \
            legitimately holds it — this is the permanent starvation the capability refusal caused \
            — flags: \(sourceFlags)
            """)
        #expect(server.wrongMessageViolations().isEmpty)
        try? await provider.disconnect()
        await finish(f)
    }

    // MARK: - B-2 — every member is dispositioned on ITS OWN evidence, never on a sibling's

    /// B-2. When COPYUID named only SOME of the requested UIDs, `move` returned
    /// normally and the drain retired the WHOLE op as provider success. The
    /// members COPYUID never named were never moved, are still in the source
    /// folder, and their move was thrown away — a silent partial loss that no
    /// later sync recovers, because the durable row is gone.
    ///
    /// ⚠ **RE-SCOPED (audit round 4). Prior display name: *"A partial COPYUID
    /// retires only the proven member and re-queues the rest"*.** It required
    /// the unnamed member to stay QUEUED, which was correct only while "unnamed"
    /// meant "undetermined". It does not: the COPY's tagged OK covers every
    /// message the command actually addressed (RFC 3501 §6.4.7), and a member
    /// the source still holds after the COPY is one the COPY addressed, because
    /// a UID can only ever LEAVE a mailbox within one UIDVALIDITY (§2.3.1.1).
    /// So the unnamed-but-live member's outcome IS determined, and leaving it
    /// queued made this a BLESSING TEST for the round-2 wedge: the row narrowed
    /// to that member, re-COPIED it on the next drain (seating a destination
    /// duplicate) and then halted its lane on the same missing evidence, for a
    /// server RFC 4315 §3 says may never furnish it.
    ///
    /// THE PROPERTY, unchanged in substance and now stated for all three
    /// possible per-member outcomes: **each member is dispositioned on ITS OWN
    /// evidence, never on a sibling's.** What differs per member is WHICH
    /// mutation the evidence authorizes:
    ///  - `COPYUID` names 81 ⇒ its source copy may be irreversibly PURGED;
    ///  - 82 is unnamed but still in the source ⇒ tagged OK + liveness moves it,
    ///    authorizing only the REVERSIBLE `\Deleted` mark;
    ///  - and both moved, so both retire and NOTHING is left to re-copy.
    /// Asserted across TWO drains against the server's own mailbox contents, so
    /// it holds regardless of how retirement is implemented.
    ///
    /// RED PROOF (recorded): against the pre-round-4 provider this fails at the
    /// queue-empty expectation and at the `\Deleted` flag on the withheld
    /// member — that member was left unflagged, unmoved-from-the-user's-view and
    /// queued behind evidence that was never coming.
    @Test("A partial COPYUID moves every member and purges only the one it names")
    @MainActor
    func partialCopyUidRetiresPerMember() async throws {
        let proven = "partial-proven@example.com"
        let withheld = "partial-withheld@example.com"
        let server = FakeIMAPServer(mailboxes: [
            "INBOX": [Self.message(uid: 81, id: proven), Self.message(uid: 82, id: withheld)],
            "Archive": [],
        ])
        server.setUidValidity(10, for: "INBOX")
        server.setUidValidity(10, for: "Archive")
        // The server copies both but names only 81 in COPYUID.
        server.withholdCopyUID(forSourceUIDs: [82])
        try server.start()
        defer { server.stop() }

        let f = try fixture(accountId: "closure-partial-copyuid")
        let provider = try await registeredIMAPProvider(server: server, fixture: f)
        let op = PendingOperation(
            type: .move, messageIds: ["81", "82"], accountId: f.accountId,
            folderPath: "INBOX", destinationPath: "Archive", observedUidValidity: 10)
        try insert([op], into: f.pool)

        await AccountManager.shared.drainPendingQueue()
        // A second drain is the duplicate detector: anything still queued here
        // re-issues its COPY against a destination that already holds the copy.
        await AccountManager.shared.drainPendingQueue()

        let remaining = try operations(f.pool).map(\.messageIds)
        #expect(
            remaining.isEmpty,
            """
            an op stayed queued after every one of its members had moved. Its next drain re-COPIES \
            what is already at the destination, and on a server that never sends COPYUID it does \
            that forever: \(remaining)
            """
        )
        // BOTH members moved, exactly once each.
        #expect(Set(server.messageIDs(in: "Archive")) == ["<\(proven)>", "<\(withheld)>"])
        #expect(
            server.messageIDs(in: "Archive").count == 2,
            "a member was copied twice — an unretired op re-COPIED on the second drain: \(server.messageIDs(in: "Archive"))")
        // The member COPYUID named was purged; the member it did not name is
        // soft-deleted and still there, which is the accepted `IOS-IMAP-001`
        // cost of moving on evidence that authorizes nothing irreversible.
        #expect(!server.messageIDs(in: "INBOX").contains("<\(proven)>"))
        #expect(server.messageIDs(in: "INBOX").contains("<\(withheld)>"))
        #expect(
            server.flags(in: "INBOX", uid: 82).contains("\\Deleted"),
            """
            the member COPYUID did not name was never marked, so the user's move did not happen for \
            it at all — flags: \(server.flags(in: "INBOX", uid: 82))
            """)
        #expect(server.wrongMessageViolations().isEmpty)
        try? await provider.disconnect()
        await finish(f)
    }

    // MARK: - AUDIT ROUND 4 — a member the source no longer holds is exit 2, not a sibling's success

    /// 🚨 **AUDIT ROUND 4 — HOLE 1, at the queue.** Round 3 authorized the whole
    /// requested set's source cleanup on the COPY's tagged OK. The command is a
    /// `UID COPY`, and RFC 3501 §6.4.8 says a non-existent UID *"is ignored
    /// without any error message generated"*, so a UID COPY can *"return an OK
    /// without performing any operations"*. A member that had already left the
    /// source therefore rode out of the queue on a PRESENT sibling's tagged OK.
    ///
    /// **The mirror image is what makes this test necessary rather than
    /// obvious:** the fix must NOT keep such a member queued. The server has
    /// stated it is not in that folder — a positive, provider-authoritative
    /// fact (exit 2), and precisely what shipped `v1.6.38`'s `idempotentMove`
    /// acted on with `if srcUIDs.isEmpty { … return }`. Keeping it queued would
    /// re-create the wedge `15d97a628` removed, since no later drain can make an
    /// absent message present again.
    ///
    /// THE PROPERTIES, all end state:
    ///  1. the present sibling MOVED — destination holds it, source does not;
    ///  2. the queue is EMPTY, so neither the absent member nor the op it rode
    ///     in is starving anything;
    ///  3. a LANE-MATE gesture the user issued afterwards on the same message
    ///     REACHED the wire — the half that makes this a wedge test rather than
    ///     a move test. Its flag lands on nothing because its own predecessor
    ///     purged the message, which is correct and is why the assertion is that
    ///     the gesture was ATTEMPTED, not that a flag survived.
    ///
    /// RED PROOF (recorded): against the pre-round-4 provider this fails at
    /// properties 2 and 3 — `move` retires only the COPYUID-named member, the
    /// row narrows to the absent one, and the next claim in the same drain
    /// throws `noCopyUidEvidence`, halting the lane with two rows queued.
    @Test("A member the source no longer holds retires without wedging its lane")
    @MainActor
    func aSourceAbsentMemberRetiresWithoutWedgingItsLane() async throws {
        let present = "absent-member-present@example.com"
        let bystander = "absent-member-bystander@example.com"
        let server = FakeIMAPServer(mailboxes: [
            "INBOX": [Self.message(uid: 77, id: present), Self.message(uid: 88, id: bystander)],
            "Archive": [],
        ])
        server.setUidValidity(10, for: "INBOX")
        server.setUidValidity(10, for: "Archive")
        server.expectMutation(rfc822MessageId: present)
        try server.start()
        defer { server.stop() }

        let f = try fixture(accountId: "closure-source-absent-member")
        let provider = try await registeredIMAPProvider(server: server, fixture: f)

        // UID 99 was in INBOX when the user swiped both messages to Archive and
        // is not there now — another client moved it. UIDVALIDITY never changed,
        // so every epoch assertion passes and the `UID COPY` silently copies one
        // of the two and returns tagged OK.
        var move = PendingOperation(
            type: .move, messageIds: ["77", "99"], accountId: f.accountId,
            folderPath: "INBOX", destinationPath: "Archive", observedUidValidity: 10)
        move.createdAt = Date().addingTimeInterval(-60)
        var laneMate = PendingOperation(
            type: .markFlagged, messageIds: ["77"], accountId: f.accountId,
            folderPath: "INBOX", observedUidValidity: 10)
        laneMate.createdAt = Date().addingTimeInterval(-40)
        try insert([move, laneMate], into: f.pool)

        await AccountManager.shared.drainPendingQueue()

        // PROPERTY 1 — the sibling that WAS present moved.
        #expect(server.messageIDs(in: "Archive") == ["<\(present)>"])
        #expect(!server.messageIDs(in: "INBOX").contains("<\(present)>"))
        // Nothing at all happened to the co-resident message.
        #expect(server.messageIDs(in: "INBOX") == ["<\(bystander)>"])
        #expect(server.flags(in: "INBOX", uid: 88).isEmpty)

        // PROPERTY 2 — nothing is starved.
        let remaining = try operations(f.pool).map(\.messageIds)
        #expect(
            remaining.isEmpty,
            """
            an op stayed queued for a member the SERVER says is not in that folder. No later drain \
            can make an absent message present, so this is the permanent wedge in its other form: \
            \(remaining)
            """
        )

        // PROPERTY 3 — the lane-mate the user issued afterwards was attempted.
        // NON-VACUOUS the other way round: pre-fix the lane halts and this
        // command never appears on the wire at all.
        let flagStores = server.recordedCommands().filter {
            let upper = $0.uppercased()
            return upper.contains("UID STORE") && upper.contains("\\FLAGGED")
        }
        #expect(
            flagStores.contains { $0.contains("77") },
            """
            the lane-mate gesture never reached the server. Its predecessor reached an exit for \
            every member, so nothing legitimately holds it — commands: \(flagStores)
            """)
        #expect(server.wrongMessageViolations().isEmpty)
        try? await provider.disconnect()
        await finish(f)
    }

    // MARK: - AUDIT ROUND 4 — a server that never sends COPYUID must still reach an exit

    /// 🚨 **AUDIT ROUND 4 — HOLE 2, and the direct two-sided partner of
    /// `unprovableMoveKeepsTheOpQueued`.** Round 3 kept a whole-op refusal
    /// (`noCopyUidEvidence`) for a UIDPLUS server that returns no `COPYUID`, on
    /// the theory that such a server may furnish it next time. RFC 4315 §3
    /// exempts two mailbox kinds from its SHOULD — one the client may COPY or
    /// APPEND to but not SELECT or EXAMINE ("SHOULD NOT send", to avoid
    /// disclosing the mailbox) and a `UIDNOTSTICKY` mail store ("MAY omit", as
    /// not meaningful) — and both are properties of the MAILBOX, so a server
    /// that omits the code omits it every time. For those the op reached NONE of
    /// the four never-drop exits, and the refusal is raised AFTER the `UID
    /// COPY`, so it was strictly worse than the capability wedge `15d97a628`
    /// deleted: every drain seated another duplicate at the destination and then
    /// halted the same lane again.
    ///
    /// THE PROPERTIES, asserted at the server across TWO drains:
    ///  1. the move COMPLETED — the destination holds the message and the source
    ///     copy is soft-deleted;
    ///  2. the destination holds EXACTLY ONE copy after two drains. This is the
    ///     duplicate half, and it is the reason a "just keep retrying" answer is
    ///     not acceptable for this server;
    ///  3. the queue is EMPTY and a LANE-MATE gesture issued afterwards on the
    ///     same message EXECUTED and is visible in the flags — possible here,
    ///     unlike the source-absent case, precisely because no `COPYUID` means
    ///     no purge, so the soft-deleted source copy is still addressable.
    ///
    /// The source copy staying `\Deleted`-but-present is the accepted
    /// `IOS-IMAP-001` cost: `COPYUID` remains the ONLY evidence that authorizes
    /// an irreversible `UID EXPUNGE`, so a server that withholds it gets the
    /// reversible half of the move and nothing more.
    ///
    /// RED PROOF (recorded): against the pre-round-4 provider this fails at
    /// property 2 (`Archive` holds TWO copies, one per drain), at property 1's
    /// `\Deleted` mark, and at property 3 — the op never leaves the queue.
    @Test("A UIDPLUS server that never sends COPYUID still completes the move and releases its lane")
    @MainActor
    func aWithheldCopyUidMoveCompletesAndReleasesItsLane() async throws {
        let target = "withheld-completes@example.com"
        let bystander = "withheld-completes-bystander@example.com"
        let server = FakeIMAPServer(mailboxes: [
            "INBOX": [Self.message(uid: 77, id: target), Self.message(uid: 88, id: bystander)],
            "Archive": [],
        ])
        // UIDPLUS advertised, `COPYUID` never sent for this UID — the RFC 4315
        // §3 server that has no response code to give.
        server.withholdCopyUID(forSourceUIDs: [77])
        server.setUidValidity(10, for: "INBOX")
        server.setUidValidity(10, for: "Archive")
        server.expectMutation(rfc822MessageId: target)
        try server.start()
        defer { server.stop() }

        let f = try fixture(accountId: "closure-withheld-completes")
        let provider = try await registeredIMAPProvider(server: server, fixture: f)

        var move = PendingOperation(
            type: .move, messageIds: ["77"], accountId: f.accountId,
            folderPath: "INBOX", destinationPath: "Archive", observedUidValidity: 10)
        move.createdAt = Date().addingTimeInterval(-60)
        // Issued AFTER the move and naming the SAME message, so `buildLanes`
        // puts it in the move's lane, behind it.
        var laneMate = PendingOperation(
            type: .markFlagged, messageIds: ["77"], accountId: f.accountId,
            folderPath: "INBOX", observedUidValidity: 10)
        laneMate.createdAt = Date().addingTimeInterval(-40)
        try insert([move, laneMate], into: f.pool)

        await AccountManager.shared.drainPendingQueue()
        await AccountManager.shared.drainPendingQueue()

        // PROPERTY 1 — the move completed.
        #expect(
            server.messageIDs(in: "Archive") == ["<\(target)>"],
            """
            the user's archive never reached the destination on a server whose only defect is that \
            it does not send a response code RFC 4315 §3 says it may have no way to send — Archive: \
            \(server.messageIDs(in: "Archive"))
            """)
        let sourceFlags = server.flags(in: "INBOX", uid: 77)
        #expect(
            sourceFlags.contains("\\Deleted"),
            "the source copy was not soft-deleted, so the move only half happened — flags: \(sourceFlags)")

        // PROPERTY 2 — no duplicate. Two drains, one copy.
        #expect(
            server.messageIDs(in: "Archive").count == 1,
            """
            the destination accumulated a duplicate across drains — an op that cannot retire keeps \
            re-issuing its COPY: \(server.messageIDs(in: "Archive"))
            """)
        #expect(server.messageIDs(in: "INBOX").contains("<\(bystander)>"))

        // PROPERTY 3 — nothing is starved, and the lane-mate executed.
        #expect(
            try operations(f.pool).isEmpty,
            "an op remained queued after a move that completed, so the lane is still held")
        #expect(
            sourceFlags.contains("\\Flagged"),
            """
            the lane-mate gesture never reached the server. Its predecessor completed, so nothing \
            legitimately holds it — this is the permanent starvation the evidence refusal caused — \
            flags: \(sourceFlags)
            """)
        #expect(server.wrongMessageViolations().isEmpty)
        try? await provider.disconnect()
        await finish(f)
    }

    // MARK: - A-6 — the completed-send flag producer, at the wire

    /// A-6, the OUTBOX half. `imapUserLabelGestureReachesTheWire` above pins the
    /// user-label producer; this pins the other one.
    /// `AccountManagerOutbox.deleteCompletedSendAtomic` queued its `.markReplied` /
    /// `.markForwarded` op naming `original.stableId` — an rfc822 Message-ID on
    /// IMAP — with no `observedUidValidity`. Checkpoint A can only SKIP that shape
    /// and the `.markReplied` executor arm can only no-op on it, so the parent's
    /// `\Answered` keyword never reached the server: the local flag said the user
    /// had replied and the account, seen from any other client, did not.
    ///
    /// THE PROPERTY: after a completed reply is finalized, the SERVER records the
    /// answered flag on the parent, and nothing is left queued. Asserted at the
    /// wire rather than at the queue on purpose — a queued op no provider arm can
    /// execute is indistinguishable from an op that was never queued, which is
    /// exactly how this defect stayed invisible to a count-the-rows assertion.
    ///
    /// This is the addressable case. The UNaddressable one — a parent whose folder
    /// or row carries no epoch — is the `IOS-EPOCH-001` accepted fail-closed
    /// window, where refusing to queue is the specified behaviour. Audit round 2
    /// wrote that negative case: see
    /// `sendCompletionWithholdsBothHalvesForAnUnaddressableParent` below.
    ///
    /// RED PROOF (recorded): reverting the producer to
    /// `messageIds: [original.stableId]` with no `observedUidValidity` fails this
    /// at the flag assertion — the server records no STORE at all — while the
    /// row-count assertions it replaced stay green.
    @Test("A completed reply flags its parent on the server, not just locally")
    @MainActor
    func completedReplyFlagsItsParentOnTheServer() async throws {
        let parentRfc = "answered-parent@example.com"
        let server = FakeIMAPServer(mailboxes: ["INBOX": [Self.message(uid: 57, id: parentRfc)]])
        server.setUidValidity(10, for: "INBOX")
        server.expectMutation(rfc822MessageId: parentRfc)
        try server.start()
        defer { server.stop() }

        let f = try fixture(accountId: "closure-replied", folders: [("INBOX", .inbox, 10)])
        let provider = try await registeredIMAPProvider(server: server, fixture: f)

        let parent: MessageHeader = {
            var value = MessageHeader(
                messageId: "57", subject: "Original", from: "Sender",
                fromAddress: "sender@example.com", to: "me@example.com", date: Date(),
                snippet: "original",
                folderId: MessageIdentity.folderId(accountId: f.accountId, folderPath: "INBOX"),
                accountId: f.accountId, folderPath: "INBOX", isInInbox: true)
            value.rfc822MessageId = parentRfc
            value.headerComplete = true
            // Every synced IMAP row carries the epoch it was observed under.
            value.observedUidValidity = 10
            return value
        }()

        let sent: OutboxMessage = {
            var value = OutboxMessage(
                accountId: f.accountId,
                draft: DraftMessage(
                    to: ["sender@example.com"], subject: "Re: Original", body: "reply",
                    inReplyTo: "<\(parentRfc)>"),
                originalMessageHeaderId: parent.id,
                isForward: false)
            value.status = OutboxStatus.sending.rawValue
            value.sentAt = Date()
            value.appendedToSent = true
            return value
        }()
        try await f.pool.writeWithoutTransaction { db in
            try parent.insert(db)
            try sent.insert(db)
        }

        _ = try await f.pool.write { db in
            try AccountManager.deleteCompletedSendAtomic(outboxId: sent.id, db: db)
        }
        await AccountManager.shared.drainPendingQueue()

        #expect(
            server.flags(in: "INBOX", uid: 57).contains("\\Answered"),
            "the reply flag must reach the server: \(server.flags(in: "INBOX", uid: 57))"
        )
        let parentId = parent.id
        let flaggedParent = try await f.pool.read { db in
            try MessageHeader.fetchOne(db, key: parentId)
        }
        #expect(flaggedParent?.isReplied == true)
        #expect(try operations(f.pool).isEmpty)
        #expect(server.wrongMessageViolations().isEmpty)
        try? await provider.disconnect()
        await finish(f)
    }

    // MARK: - AUDIT ROUND 2 / MUST FIX 3 — the refusal must refuse BOTH halves

    /// 🚨 AUDIT ROUND 2. The negative case the test above scopes out.
    ///
    /// `deleteCompletedSendAtomic` set `original.isReplied` / `.isForwarded`
    /// OUTSIDE its `if let flagAdmission` guards. So for a parent the app cannot
    /// address — the `IOS-EPOCH-001` fail-closed window — the LOCAL half was
    /// written and the DURABLE half was not: no op, no retry, no record, no
    /// disposition to the caller. The UI then said "replied" while the account,
    /// seen from any other client, had no `\Answered` on that message and never
    /// would. Both siblings deciding the same question —
    /// `UserLabelMenuModel.applyLabel`/`removeLabel` and
    /// `InboxViewModel.removeUserLabel` — guard BEFORE the local mutation so
    /// neither half lands; this was a third shape inside one remediation.
    ///
    /// THE PROPERTY: local state and the server AGREE. `isReplied` is not a private
    /// note that the user composed something — it is the local mirror of the
    /// server's `\Answered`, and it may not assert a flag that was never queued.
    ///
    /// ⚠ THE FIX IS NOT TO ADMIT THE GESTURE. Withholding an unaddressable durable
    /// op is the specified disposition and this test would be WRONG to demand a
    /// `\Answered` here. It demands only that the local half be as withheld as the
    /// durable half.
    ///
    /// ⚠ SCOPE — READ THE NAME LITERALLY. This covers the COMPLETION producer,
    /// `deleteCompletedSendAtomic`, and nothing else. It is deliberately NOT named
    /// as an end-to-end guarantee, because there is not one: the OTHER producer,
    /// `AccountManagerOutbox.persistQueuedSend`, writes
    /// `UPDATE messageHeader SET isReplied = 1` optimistically at QUEUE time with no
    /// admission gate, so on the full queue→send→complete path the local claim still
    /// outlives an unaddressable parent. That write is verbatim in the shipped
    /// release `07a4bb703`, is correct optimistic-UI behaviour per ADR-IOS-001, and
    /// is deliberately unchanged; the residual end-to-end gap is registered in
    /// `KNOWN_ISSUES.md`. A universally-quantified name here would repeat the exact
    /// hazard that let the label-producer bug survive a release line —
    /// `ProviderNativeActionAdmissionTests`' *"Every ordinary IMAP producer …"*
    /// enumerates four.
    ///
    /// NON-VACUITY, and the reason the parent carries a `reply` action tag: the tag
    /// IS cleared. That proves `deleteCompletedSendAtomic` resolved this parent and
    /// ran its reply branch — so `isReplied == false` is the guard refusing, not the
    /// function bailing out earlier at `resolveOriginalMessage` and never reaching
    /// the flag at all. (The tag is local-only by ADR-IOS-036, so clearing it claims
    /// nothing about the server and is deliberately outside the admission guard.)
    /// The addressable half of the pair is `completedReplyFlagsItsParentOnTheServer`
    /// immediately above, which runs the identical shape WITH epochs and gets both.
    @Test("Send COMPLETION does not mark an unaddressable parent replied when it queues no flag op")
    @MainActor
    func sendCompletionWithholdsBothHalvesForAnUnaddressableParent() async throws {
        let parentRfc = "unaddressable-parent@example.com"
        let server = FakeIMAPServer(mailboxes: ["INBOX": [Self.message(uid: 57, id: parentRfc)]])
        server.setUidValidity(10, for: "INBOX")
        try server.start()
        defer { server.stop() }

        // The accepted fail-closed window: the folder has never been SELECTed, so
        // nothing can positively address a message inside it.
        let f = try fixture(accountId: "closure-unaddressable", folders: [("INBOX", .inbox, nil)])
        let provider = try await registeredIMAPProvider(server: server, fixture: f)

        let parent: MessageHeader = {
            var value = MessageHeader(
                messageId: "57", subject: "Original", from: "Sender",
                fromAddress: "sender@example.com", to: "me@example.com", date: Date(),
                snippet: "original",
                folderId: MessageIdentity.folderId(accountId: f.accountId, folderPath: "INBOX"),
                accountId: f.accountId, folderPath: "INBOX", isInInbox: true)
            value.rfc822MessageId = parentRfc
            value.headerComplete = true
            // No epoch on the row either — an unproven address, both sides.
            value.observedUidValidity = nil
            value.setActionTag(.reply)
            return value
        }()

        let sent: OutboxMessage = {
            var value = OutboxMessage(
                accountId: f.accountId,
                draft: DraftMessage(
                    to: ["sender@example.com"], subject: "Re: Original", body: "reply",
                    inReplyTo: "<\(parentRfc)>"),
                originalMessageHeaderId: parent.id,
                isForward: false)
            value.status = OutboxStatus.sending.rawValue
            value.sentAt = Date()
            value.appendedToSent = true
            return value
        }()
        try await f.pool.writeWithoutTransaction { db in
            try parent.insert(db)
            try sent.insert(db)
        }

        _ = try await f.pool.write { db in
            try AccountManager.deleteCompletedSendAtomic(outboxId: sent.id, db: db)
        }
        await AccountManager.shared.drainPendingQueue()

        let parentId = parent.id
        let after = try await f.pool.read { db in try MessageHeader.fetchOne(db, key: parentId) }

        // NON-VACUITY: the function really did resolve this parent and run the
        // reply branch — the local-only action tag was cleared.
        #expect(
            after?.actionTag == ActionTag.none,
            "precondition: the reply branch must have run, or the assertion below proves nothing")

        #expect(
            after?.isReplied == false,
            """
            the parent is marked replied locally while no durable gesture was queued for it and the \
            server carries no \\Answered. `isReplied` is the local mirror of the server flag, so \
            writing it here asserts a server-side fact on the strength of evidence we just refused \
            to act on. Refusing must refuse BOTH halves.
            """)
        #expect(
            !server.flags(in: "INBOX", uid: 57).contains("\\Answered"),
            "nothing may reach the wire for a parent the app cannot positively address")
        #expect(server.wrongMessageViolations().isEmpty)
        try? await provider.disconnect()
        await finish(f)
    }

    // MARK: - A-4 (draft leg) — the same closure, on the IRREVERSIBLE draft delete

    /// The A-4 defect survived on a third site. `IMAPProvider.deleteDraftStrong`
    /// carried its own copy of the two-outcome comparison —
    /// `guard selection.uidValidity.value == recordedUidValidity else { throw
    /// ProviderError.actionIdentityResolutionFailed(…) }` — inherited verbatim from
    /// `v2final`, which has the identical shape. A SELECT that omits the untagged
    /// UIDVALIDITY response yields SwiftMail's `UIDValidity(0)` default, zero is
    /// never equal to a recorded `nz-number`, and the drain DELETES the durable op
    /// on `actionIdentityResolutionFailed`. "The server did not tell us" took a
    /// terminal exit.
    ///
    /// THE PROPERTY: the user's delete intention survives an answer the server
    /// declined to give, and the server-side draft is untouched. The test never
    /// inspects the thrown error's type — it observes the durable row and the wire.
    ///
    /// The product cost of the defect: on such a server every send left a PERMANENT
    /// duplicate in Drafts, because the post-send server-draft cleanup was
    /// annihilated instead of retried.
    ///
    /// RED PROOF (recorded in the marker): restoring the two-outcome guard fails
    /// this at `after.count == 1` — the row is gone.
    @Test("A Drafts SELECT that reports no UIDVALIDITY leaves the draft delete queued and destroys nothing")
    @MainActor
    func unknownDraftsEpochLeavesTheDraftDeleteQueued() async throws {
        let target = "unknown-drafts-epoch@example.com"
        let server = FakeIMAPServer(mailboxes: ["Drafts": [Self.message(uid: 5, id: target)]])
        // The mailbox's real epoch MATCHES the address the op recorded — the only
        // thing missing is the server saying so.
        server.setUidValidity(10, for: "Drafts")
        server.suppressSelectUidValidity(for: "Drafts")
        server.expectMutation(rfc822MessageId: target)
        try server.start()
        defer { server.stop() }

        let f = try fixture(
            accountId: "closure-draft-unknown-epoch",
            folders: [("INBOX", .inbox, 10), ("Drafts", .drafts, 10)])
        let provider = try await registeredIMAPProvider(server: server, fixture: f)
        let op = PendingOperation(
            type: .deleteDraft, messageIds: ["5"], accountId: f.accountId,
            folderPath: "Drafts",
            observedUidValidity: 10, draftServerUidValidity: 10,
            draftDeleteAddressKind: .providerResource)
        try insert([op], into: f.pool)

        await AccountManager.shared.drainPendingQueue()

        let after = try operations(f.pool)
        #expect(
            after.count == 1,
            "an unknown live epoch is an absence of evidence — the delete intention must stay queued, not be retired as an unresolvable identity"
        )
        guard after.count == 1 else {
            try? await provider.disconnect()
            await finish(f)
            return
        }
        #expect(after[0].id == op.id)
        #expect(after[0].status == PendingStatus.queued.rawValue)
        // `deleteDraftStrong` is IRREVERSIBLE — refusing must also mean the draft is
        // still there to delete on the retry.
        #expect(server.messageIDs(in: "Drafts") == ["<\(target)>"])
        #expect(
            !server.flags(in: "Drafts", uid: 5).contains("\\Deleted"),
            "not even the soft half of the destructive sequence may run on an unproven epoch")
        #expect(server.wrongMessageViolations().isEmpty)
        try? await provider.disconnect()
        await finish(f)
    }

    /// NON-VACUITY partner: the same fixture with the suppression removed deletes
    /// the draft and retires the op. Without this, the test above would pass
    /// against a draft path that could never delete anything at all.
    @Test("The same draft fixture with UIDVALIDITY reported deletes the draft and retires the op")
    @MainActor
    func reportedDraftsEpochCompletesTheDraftDelete() async throws {
        let target = "known-drafts-epoch@example.com"
        let server = FakeIMAPServer(mailboxes: ["Drafts": [Self.message(uid: 5, id: target)]])
        server.setUidValidity(10, for: "Drafts")
        server.expectMutation(rfc822MessageId: target)
        try server.start()
        defer { server.stop() }

        let f = try fixture(
            accountId: "closure-draft-known-epoch",
            folders: [("INBOX", .inbox, 10), ("Drafts", .drafts, 10)])
        let provider = try await registeredIMAPProvider(server: server, fixture: f)
        try insert([PendingOperation(
            type: .deleteDraft, messageIds: ["5"], accountId: f.accountId,
            folderPath: "Drafts",
            observedUidValidity: 10, draftServerUidValidity: 10,
            draftDeleteAddressKind: .providerResource)], into: f.pool)

        await AccountManager.shared.drainPendingQueue()

        #expect(server.messageIDs(in: "Drafts").isEmpty)
        #expect(try operations(f.pool).isEmpty)
        #expect(server.wrongMessageViolations().isEmpty)
        try? await provider.disconnect()
        await finish(f)
    }

    /// THE OTHER DIRECTION, and it must not regress: two epochs that are BOTH real
    /// and disagree is a PROVEN turnover in this op's own address space — exit 4.
    /// The op is retired and the draft is not touched, because the UID it names now
    /// addresses whatever the new numbering put there (C3).
    ///
    /// A one-sided fix that made every epoch disagreement retryable would pass the
    /// test above while converting exit 4 into an unbounded retry against a
    /// reassigned address. This is the half that keeps the fix honest.
    @Test("A proven Drafts UIDVALIDITY turnover still retires the draft delete and mutates nothing")
    @MainActor
    func provenDraftsEpochTurnoverRetiresTheDraftDelete() async throws {
        let occupant = "post-turnover-occupant@example.com"
        let server = FakeIMAPServer(mailboxes: ["Drafts": [Self.message(uid: 5, id: occupant)]])
        // The mailbox has rolled: uid 5 now names a DIFFERENT message.
        server.setUidValidity(11, for: "Drafts")
        // Arm the oracle on the draft the op INTENDED (which the turnover took with
        // it), so any mutation landing on the occupant is recorded as a violation
        // rather than silently licensed.
        server.expectMutation(rfc822MessageId: "pre-turnover-intended-draft@example.com")
        try server.start()
        defer { server.stop() }

        let f = try fixture(
            accountId: "closure-draft-turnover",
            folders: [("INBOX", .inbox, 10), ("Drafts", .drafts, 10)])
        let provider = try await registeredIMAPProvider(server: server, fixture: f)
        try insert([PendingOperation(
            type: .deleteDraft, messageIds: ["5"], accountId: f.accountId,
            folderPath: "Drafts",
            observedUidValidity: 10, draftServerUidValidity: 10,
            draftDeleteAddressKind: .providerResource)], into: f.pool)

        await AccountManager.shared.drainPendingQueue()

        #expect(
            try operations(f.pool).isEmpty,
            "a PROVEN turnover is exit 4 — every retry would fail identically and forever, so the op is retired"
        )
        #expect(
            server.messageIDs(in: "Drafts") == ["<\(occupant)>"],
            "the message the new numbering put at uid 5 must not be destroyed by an op that never observed that numbering (C3)"
        )
        #expect(server.wrongMessageViolations().isEmpty)
        try? await provider.disconnect()
        await finish(f)
    }

    /// THE WEDGE COROLLARY. Trading a dropped intention for a starved lane scores
    /// zero: "an op that stays queued forever while starving other intentions has
    /// not been preserved."
    ///
    /// The drain has NO retry budget for `ProviderEvidenceUnavailable` — it
    /// requeues, bumps `retryCount` (diagnostics only for `PendingOperation`),
    /// records the op in `evidenceRefused` and returns `.haltLane`. So a refusal
    /// that can never clear halts ITS OWN lane indefinitely, and this test bounds
    /// exactly what that costs.
    ///
    /// A lane is a connected component over `"accountId:folderPath:messageId"`
    /// (`buildLanes`), so a `.deleteDraft` op's lane is `<account>:<Drafts>:<uid>`.
    /// Three ops here, drained TWICE against a Drafts mailbox that never reports an
    /// epoch:
    ///  - the draft delete — must still be durably queued after both passes;
    ///  - a same-lane `markRead` on the same Drafts UID — starved behind it, and
    ///    that starvation must not destroy it either. (It could not have succeeded
    ///    anyway: it reaches the same zero-epoch SELECT and raises the same
    ///    refusal, so nothing SATISFIABLE is being starved.)
    ///  - a different-lane `markRead` in INBOX, where the server does report an
    ///    epoch — this one must reach the provider and retire. Asserted BOTH ways:
    ///    a durable db assertion that its row is gone, and the wire flag it set.
    ///    A test that only checked the first op survived would pass while the whole
    ///    account was wedged.
    ///
    /// ⚠ REACHABILITY, established separately and worth recording: the "server
    /// PERMANENTLY omits UIDVALIDITY" case cannot produce a `.deleteDraft` op at
    /// all. `AccountManager.queueDraftDelete` is its only producer and its IMAP arm
    /// admits only when `folder.lastKnownUidValidity == uidValidity` with
    /// `uidValidity > 0`; every writer of that column normalises through
    /// `SyncEngine.knownUidValidity`, which returns nil for `<= 0`, so on such a
    /// server the column stays nil forever and the gesture is refused at admission
    /// (`IOS-EPOCH-001`). The reachable population is a Drafts folder whose epoch
    /// WAS observed and then stops being reported — indefinite, not permanent,
    /// self-healing on the first conformant SELECT. This test still pins the
    /// permanent shape, because a bound nobody checks is a hope.
    @Test("A Drafts mailbox that never reports UIDVALIDITY keeps the draft delete durable and does not starve the account")
    @MainActor
    func epochlessDraftsMailboxKeepsTheDeleteDurableWithoutStarvingTheAccount() async throws {
        let draft = "epochless-drafts-target@example.com"
        let inboxTarget = "other-lane-target@example.com"
        let server = FakeIMAPServer(mailboxes: [
            "Drafts": [Self.message(uid: 5, id: draft)],
            "INBOX": [Self.message(uid: 7, id: inboxTarget)],
        ])
        server.setUidValidity(10, for: "Drafts")
        server.setUidValidity(10, for: "INBOX")
        // Permanent: never restored, on either drain.
        server.suppressSelectUidValidity(for: "Drafts")
        server.expectMutations([draft, inboxTarget])
        try server.start()
        defer { server.stop() }

        let f = try fixture(
            accountId: "closure-draft-epochless-lane",
            folders: [("INBOX", .inbox, 10), ("Drafts", .drafts, 10)])
        let provider = try await registeredIMAPProvider(server: server, fixture: f)

        let base = Date(timeIntervalSince1970: 1_800_000_000)
        var deleteOp = PendingOperation(
            type: .deleteDraft, messageIds: ["5"], accountId: f.accountId,
            folderPath: "Drafts",
            observedUidValidity: 10, draftServerUidValidity: 10,
            draftDeleteAddressKind: .providerResource)
        deleteOp.createdAt = base
        // Same lane as `deleteOp`: same account, same folder, same member id. The
        // explicit `createdAt` ordering is what puts it BEHIND the refusal.
        var sameLane = PendingOperation(
            type: .markRead, messageIds: ["5"], accountId: f.accountId,
            folderPath: "Drafts", observedUidValidity: 10)
        sameLane.createdAt = base.addingTimeInterval(1)
        // A disjoint component — this is the intention that must not be starved.
        var otherLane = PendingOperation(
            type: .markRead, messageIds: ["7"], accountId: f.accountId,
            folderPath: "INBOX", observedUidValidity: 10)
        otherLane.createdAt = base.addingTimeInterval(2)
        try insert([deleteOp, sameLane, otherLane], into: f.pool)

        await AccountManager.shared.drainPendingQueue()
        await AccountManager.shared.drainPendingQueue()

        let remaining = try operations(f.pool)
        let remainingIds = Set(remaining.map(\.id))
        #expect(
            remainingIds.contains(deleteOp.id),
            "the delete intention must survive a server that never answers — repeated refusals are not an exit"
        )
        #expect(
            remainingIds.contains(sameLane.id),
            "a starved same-lane op must be preserved too; halting a lane is not a licence to destroy what is behind it"
        )
        // DURABLE db assertion that the disjoint lane made real progress — a wire
        // count alone would still pass against a queue that re-runs the same op
        // forever without ever retiring it.
        #expect(
            !remainingIds.contains(otherLane.id),
            "an unrelated intention in a disjoint lane must reach the provider and retire — a refusal on one lane may never wedge the account"
        )
        #expect(
            server.flags(in: "INBOX", uid: 7).contains("\\Seen"),
            "and it must have actually reached the wire, not merely left the queue"
        )
        #expect(
            server.messageIDs(in: "Drafts") == ["<\(draft)>"],
            "nothing irreversible may happen to the draft while its epoch is unproven"
        )
        #expect(
            !server.flags(in: "Drafts", uid: 5).contains("\\Deleted"),
            "not even the soft half of the destructive sequence"
        )
        #expect(server.wrongMessageViolations().isEmpty)
        try? await provider.disconnect()
        await finish(f)
    }
}
