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

    /// Force the app-owned COPY/STORE/UID-EXPUNGE route for tests whose
    /// contract is specifically about COPYUID or reversible soft deletion.
    private static let ownedMoveCapabilities = FakeIMAPServer.defaultCapabilities.filter {
        $0 != "MOVE"
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

    // MARK: - A-2 — a conflict on one member must not revert the gesture for all of them

    /// A-2, RESTATED. The original hazard was the batch SPLIT: it rebuilt each
    /// member as a fresh child and deleted the parent in the same transaction, so
    /// any field not copied across was destroyed — the children were being built
    /// without `observedUidValidity`, which on IMAP made every one of them
    /// un-admittable and (before A-3) a deterministic DELETE on the next drain.
    /// A conflict on ONE member silently reverted the gesture for ALL of them.
    ///
    /// The split is now DELETED, and with it the class of defect this test was
    /// written to catch: the scheduler no longer re-shapes an operation at all,
    /// so there is no child that can lose an admission. What remains is the
    /// property the split was a (wrong) means to — **a batch-level conflict must
    /// not cost the user the members it never said anything about** — and it is
    /// now satisfied by RETENTION rather than by children. This test therefore
    /// asserts that property directly, in both directions:
    ///
    /// - SAFETY: the batch error attributes nothing, so nothing is moved, nothing
    ///   is retired, and the row keeps its own id and all three members.
    /// - LIVENESS: once the conflict clears, the SAME operation moves all three
    ///   members and terminates. Safety alone is satisfied forever by an op that
    ///   starves, which is a dropped intention by the wedge corollary.
    ///
    /// The conflict is armed on the FIRST member so the attempt records no
    /// partial prefix — the batch reaches the drain as a bare not-found with
    /// nothing succeeded and nothing attributable, which is the exact shape that
    /// used to trigger the split.
    ///
    /// RED PROOF (recorded): against the pre-fix tree the split fires inside the
    /// first `drainPendingQueue` call, the three children are executed in the same
    /// call, and member "1" is dropped by the single-message terminal arm — the
    /// first `stillOwed.count == 1` assertion fails with 0 rows and the "nothing
    /// moved" assertion fails with `["2"], ["3"]`.
    @Test("A batch-level conflict retains every member, and the same operation completes once it clears")
    @MainActor
    func batchConflictRetainsEveryMemberAndConverges() async throws {
        let f = try fixture(accountId: "closure-split")
        let provider = MockEmailProvider(staleWindowMode: .uid)
        await AccountManager.shared.registerProviderForTesting(accountId: f.accountId, provider: provider)
        // A conflict on the FIRST member leaves the attempt with an empty
        // "already succeeded" prefix: the drain learns only that the batch failed.
        await provider.setMoveThrowsOnId("1", error: ProviderError.messageNotFound)

        let parent = PendingOperation(
            type: .move, messageIds: ["1", "2", "3"], accountId: f.accountId,
            folderPath: "INBOX", destinationPath: "Archive", observedUidValidity: 10)
        try insert([parent], into: f.pool)

        await AccountManager.shared.drainPendingQueue()

        let duringConflict = await provider.movedIds
        #expect(
            duringConflict.flatMap(\.ids).isEmpty,
            "no member was individually dispositioned, so no member may be moved on its own: \(duringConflict)"
        )
        let stillOwed = try operations(f.pool)
        #expect(
            stillOwed.count == 1,
            "a batch error attributes nothing; the user's gesture must still be owed in full, not retired and not re-shaped"
        )
        guard stillOwed.count == 1 else {
            await finish(f)
            return
        }
        #expect(stillOwed[0].id == parent.id, "the retained row must be the user's original operation")
        #expect(stillOwed[0].messageIds == ["1", "2", "3"])

        // LIVENESS — the conflict clears (the message is back, the server settles)
        // and the ONE operation that was queued all along completes.
        await provider.clearMoveThrowsOnId()
        await AccountManager.shared.drainPendingQueue()

        let movedMembers = Set((await provider.movedIds).flatMap(\.ids))
        #expect(
            movedMembers == Set(["1", "2", "3"]),
            "the retained operation must still be executable — an op that can never complete is a dropped intention by the wedge corollary"
        )
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
    ///     `aNonUidPlusNonMoveServerCompletesAndReleasesItsLane`.
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
        let server = FakeIMAPServer(capabilities: Self.ownedMoveCapabilities, mailboxes: [
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
    /// `aNonUidPlusNonMoveServerCompletesAndReleasesItsLane` and
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
        let server = FakeIMAPServer(capabilities: Self.ownedMoveCapabilities, mailboxes: [
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
    /// server without UIDPLUS or MOVE has no narrower purge than a mailbox-wide
    /// `EXPUNGE`, which would irreversibly destroy unrelated mail that already
    /// carries `\Deleted`. Incomplete VISIBLE cleanup is preferred over both
    /// that and the permanent wedge. Asserting the `\Deleted` mark (rather than
    /// the source being gone) pins exactly that decision.
    ///
    /// RED PROOF (recorded): with the `supportsUIDPlus` refusal restored, this
    /// fails at property 1 — `Archive` is empty — and at properties 2 and 3.
    @Test("A move on a server without UIDPLUS or MOVE completes and releases its lane")
    @MainActor
    func aNonUidPlusNonMoveServerCompletesAndReleasesItsLane() async throws {
        let target = "nouidplus-target@example.com"
        let bystander = "nouidplus-bystander@example.com"
        let server = FakeIMAPServer(
            capabilities: Self.ownedMoveCapabilities.filter { $0 != "UIDPLUS" },
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
        let server = FakeIMAPServer(capabilities: Self.ownedMoveCapabilities, mailboxes: [
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
        let server = FakeIMAPServer(capabilities: Self.ownedMoveCapabilities, mailboxes: [
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
        let server = FakeIMAPServer(capabilities: Self.ownedMoveCapabilities, mailboxes: [
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

    // MARK: - Round-4 H3 — a COMMITTED copy the server described unparseably

    /// **THE INVARIANT: a COPY the server acknowledged with a tagged OK is never
    /// issued a second time, whatever its `COPYUID` looked like.**
    ///
    /// The direct sibling of `aWithheldCopyUidMoveCompletesAndReleasesItsLane`
    /// above, and the same wedge in a shape that harness could not reach. That one
    /// models a server with NO response code to give; this one models a server
    /// that gives one we cannot parse. Both are RFC 3501 §6.4.7 tagged-OK copies —
    /// an unsuccessful COPY MUST leave the destination as it was, so the copy
    /// PROVABLY LANDED in both — and in both cases the app has no `COPYUID`
    /// mapping to work from. Handling them differently is the defect.
    ///
    /// Before the fix, `let copyEvidence = try await server.copy(...)` had no
    /// `catch`, so the error raised on a cardinality mismatch propagated out of
    /// `IMAPProvider.move` to the generic arm in `AccountManager.executeSingleOp`,
    /// which requeues the op
    /// and halts the lane. The throw happens BEFORE the `STORE \Deleted`, so the
    /// source is untouched and the next drain re-runs the whole sequence and
    /// issues ANOTHER `UID COPY`. One more duplicate at the destination per drain,
    /// forever, on an op that can never retire — durable actions retry without a
    /// cap. Sync cannot settle it, retrying makes it strictly worse, and no
    /// ordinary user gesture clears it: the wedge corollary, which is in the
    /// non-recoverable set, so this is a defect and not an accepted edge.
    ///
    /// ⚠️ **NAME THE ERROR THE APP ACTUALLY SEES, and do not restore a catch from
    /// the raw thrower.** `CopyUID.init(nio:)` does throw
    /// `IMAPError.commandFailed` on the cardinality mismatch — true of that
    /// initializer IN ISOLATION and nothing else. It is not what reaches
    /// `IMAPProvider.move`: `CopyHandler.handleTaggedOKResponse` wraps
    /// `extractCopyUID` in a `do/catch` and re-raises
    /// `IMAPError.malformedCopyUIDAfterTaggedOK(String(describing: error))`, so
    /// that is the case the provider's `catch` must key on. This distinction is
    /// not pedantry — it IS the defect `f8eb8acb9` fixed. SwiftMail PR #208
    /// introduced the re-typing, only the atomic `server.move` arm was updated,
    /// and the `server.copy` fallback arm was left catching a case the error no
    /// longer was. A typed `catch` keyed on the wrong case does not fail to
    /// compile, does not warn, and does not fire — it silently stops matching, and
    /// the wedge described above came straight back. This comment said
    /// "`IMAPError.commandFailed`" unqualified until 2026-08-12; a reader
    /// restoring `catch IMAPError.commandFailed` from that sentence re-opens the
    /// bug.
    ///
    /// **ASSERTED ON THE WIRE, deliberately.** The load-bearing assertion is the
    /// COUNT OF `UID COPY` COMMANDS ACROSS TWO DRAINS, not a flag, not the queue
    /// depth, and not the type of any error. A test that asserted "the catch
    /// exists" or "`copyEvidence` is nil" would pin the fix's mechanism and stay
    /// green on any future rewrite that reintroduced the re-copy by another route.
    /// The destination message count corroborates it from the other side: the
    /// bytes and the mailbox must agree.
    ///
    /// The source copy staying `\Deleted`-but-present is the accepted
    /// `IOS-IMAP-001` cost and is the CORRECT outcome here: with no parseable
    /// `COPYUID` there is no per-member proof, so `purgeAuthorizedUIDs` is empty
    /// and the irreversible `UID EXPUNGE` is structurally unreachable. The
    /// reversible half is authorized by the tagged OK ANDed with `liveSourceUIDs`.
    ///
    /// RED PROOF (recorded): against the pre-fix provider this fails at the
    /// `UID COPY` count — 2 across two drains instead of 1 — and at the
    /// destination holding two copies, at the `\Deleted` mark, and at the queue
    /// being empty.
    @Test("A tagged-OK copy whose COPYUID cannot be parsed is never re-issued")
    @MainActor
    func anUnparseableCopyUidMoveIsNeverReCopied() async throws {
        let target = "unparseable-copyuid@example.com"
        let bystander = "unparseable-copyuid-bystander@example.com"
        let server = FakeIMAPServer(capabilities: Self.ownedMoveCapabilities, mailboxes: [
            "INBOX": [Self.message(uid: 77, id: target), Self.message(uid: 88, id: bystander)],
            "Archive": [],
        ])
        // UIDPLUS advertised and a `COPYUID` sent — but with one more destination
        // UID than source UID. `CopyUID.init(nio:)` rejects that with
        // `IMAPError.commandFailed`, but the app never sees that case:
        // `CopyHandler.handleTaggedOKResponse` catches it and re-raises
        // `IMAPError.malformedCopyUIDAfterTaggedOK`, which is what
        // `IMAPProvider.move` must catch. See the doc comment above for why the
        // distinction is the defect `f8eb8acb9` fixed.
        server.reportCopyUIDWithCardinalityMismatch()
        server.setUidValidity(10, for: "INBOX")
        server.setUidValidity(10, for: "Archive")
        server.expectMutation(rfc822MessageId: target)
        try server.start()
        defer { server.stop() }

        let f = try fixture(accountId: "closure-unparseable-copyuid")
        let provider = try await registeredIMAPProvider(server: server, fixture: f)

        var move = PendingOperation(
            type: .move, messageIds: ["77"], accountId: f.accountId,
            folderPath: "INBOX", destinationPath: "Archive", observedUidValidity: 10)
        move.createdAt = Date().addingTimeInterval(-60)
        // Issued after the move on the SAME message, so `buildLanes` seats it in
        // the move's lane behind it: if the move wedges, this starves.
        var laneMate = PendingOperation(
            type: .markFlagged, messageIds: ["77"], accountId: f.accountId,
            folderPath: "INBOX", observedUidValidity: 10)
        laneMate.createdAt = Date().addingTimeInterval(-40)
        try insert([move, laneMate], into: f.pool)

        await AccountManager.shared.drainPendingQueue()
        await AccountManager.shared.drainPendingQueue()

        // THE INVARIANT, on the wire.
        let copies = server.recordedCommands().filter { $0.uppercased().contains("UID COPY") }
        #expect(
            copies.count == 1,
            """
            the COPY was re-issued after the server had already acknowledged it — every drain seats \
            another duplicate at the destination and the op can never retire — UID COPY commands: \
            \(copies)
            """)

        // The same fact from the mailbox side.
        #expect(
            server.messageIDs(in: "Archive") == ["<\(target)>"],
            """
            the destination does not hold exactly one copy of the moved message after two drains — \
            Archive: \(server.messageIDs(in: "Archive"))
            """)

        // The move completed: reversible half only.
        let sourceFlags = server.flags(in: "INBOX", uid: 77)
        #expect(
            sourceFlags.contains("\\Deleted"),
            "the source copy was not soft-deleted, so the move only half happened — flags: \(sourceFlags)")
        #expect(server.messageIDs(in: "INBOX").contains("<\(bystander)>"))

        // No irreversible half — with no parseable COPYUID there is no per-member
        // proof, so nothing may be purged.
        #expect(
            server.recordedCommands().filter { $0.uppercased().contains("EXPUNGE") }.isEmpty,
            "an expunge was issued without any per-member COPYUID proof")

        // Nothing is starved: the op retired and its lane-mate executed.
        #expect(
            try operations(f.pool).isEmpty,
            "an op remained queued after a move that completed, so the lane is still held")
        #expect(
            sourceFlags.contains("\\Flagged"),
            """
            the lane-mate gesture never reached the server — its predecessor completed, so nothing \
            legitimately holds it — flags: \(sourceFlags)
            """)
        #expect(server.wrongMessageViolations().isEmpty)
        try? await provider.disconnect()
        await finish(f)
    }

    // MARK: - SwiftMail PR #208 — tagged failure after MOVE changed state

    /// PR #208 distinguishes two tagged failures after a MOVE that may already
    /// have changed server state, and they are NOT one class (GitHub #115):
    ///  - `moveFailedAfterPartialCompletion(copyUID:)` carries the server's own
    ///    `COPYUID` for the members it moved. That IS a fact the provider
    ///    asserted, so the attempt retires with its verified mapping and both
    ///    mailboxes are reconciled — `aVerifiedPartialAtomicMoveIsNeverReissued`.
    ///  - `moveFailedAfterPossiblePartialCompletion` is raised for ANY tagged
    ///    NO/BAD with no retained `COPYUID`, including a refusal that mutated
    ///    nothing. It is an absence of evidence, so the op stays queued and is
    ///    retried; the property is that the retry CONVERGES — exactly one
    ///    destination copy, source empty, queue empty — never how many wire
    ///    attempts that took. The zero-mutation form is pinned by
    ///    `aRefusedAtomicMoveStaysQueuedAndTheNextDrainLandsIt` below; this
    ///    one is the committed-then-NO world state, where a retry could
    ///    duplicate on a server that violates RFC 6851 §3.3 and must not on a
    ///    conforming one (RFC 3501 §6.4.8 ignores the now-absent UID).
    @Test("A possibly-partial UID MOVE converges to exactly one destination copy with the queue empty")
    @MainActor
    func aPossiblyPartialAtomicMoveConvergesToExactlyOneDestinationCopy() async throws {
        let target = "atomic-possible-partial@example.com"
        let server = FakeIMAPServer(mailboxes: [
            "INBOX": [Self.message(uid: 77, id: target)],
            "Archive": [],
        ])
        server.setUidValidity(10, for: "INBOX")
        server.setUidValidity(10, for: "Archive")
        // The fake COMMITS the move, then answers tagged NO with no COPYUID.
        server.failUIDMoveAfterPossiblePartialCompletion()
        server.expectMutation(rfc822MessageId: target)
        try server.start()
        defer { server.stop() }

        let f = try fixture(accountId: "closure-atomic-possible-partial")
        let provider = try await registeredIMAPProvider(server: server, fixture: f)
        let move = PendingOperation(
            type: .move, messageIds: ["77"], accountId: f.accountId,
            folderPath: "INBOX", destinationPath: "Archive", observedUidValidity: 10)
        try insert([move], into: f.pool)

        await AccountManager.shared.drainPendingQueue()
        await AccountManager.shared.drainPendingQueue()

        let archive = server.messageIDs(in: "Archive")
        #expect(archive == ["<\(target)>"], "expected exactly one destination copy: \(archive)")
        #expect(server.messageIDs(in: "INBOX").isEmpty)
        let remaining = try operations(f.pool)
        #expect(remaining.isEmpty, "the move did not retire after converging: \(remaining.map(\.type))")
        #expect(server.wrongMessageViolations().isEmpty)

        try? await provider.disconnect()
        await finish(f)
    }

    /// #115 round 4b (round-3 test-coverage finding). Every other
    /// possible-partial witness in this suite moves a SINGLE message, so the
    /// server either mutated nothing or mutated everything: the "partial" the
    /// error is named for was never actually reproduced. RFC 6851 §3.3 permits
    /// the real shape — a `UID MOVE` may move SOME of the requested members and
    /// then end with a tagged NO — and with no `COPYUID` the client cannot tell
    /// WHICH ones moved.
    ///
    /// THE INVARIANT, which is the never-drop invariant restricted to that wire
    /// shape: an evidence-unavailable refusal preserves the WHOLE durable
    /// operation — every member id, its source, its destination, its observed
    /// epoch, queued, retry advanced — and the next drain converges every
    /// member to EXACTLY ONE destination copy, with no destructive fallback
    /// (`UID COPY`, `+FLAGS (\Deleted)` on the source, `EXPUNGE`) and no
    /// collateral mutation of a bystander.
    ///
    /// Dropping the already-moved member from the requeued row would look
    /// harmless — the server really did move it — but it is exactly exit 2
    /// taken on an ABSENCE of evidence (`MIS-IOS-004`): this server publishes
    /// no `COPYUID`, so "the first member landed" is the TEST's knowledge and
    /// never the client's. The convergence half is the other side of the same
    /// coin: re-issuing the whole set must not seat a second copy of the member
    /// that already moved (RFC 3501 §6.4.8 — a UID command silently ignores a
    /// UID that is no longer present).
    @Test("A partially completed UID MOVE keeps every member queued and converges on the retry")
    @MainActor
    func aPartiallyCompletedAtomicMoveKeepsEveryMemberAndConvergesOnRetry() async throws {
        let first = "atomic-partial-first@example.com"
        let second = "atomic-partial-second@example.com"
        let bystander = "atomic-partial-bystander@example.com"
        let server = FakeIMAPServer(mailboxes: [
            "INBOX": [
                Self.message(uid: 77, id: first),
                Self.message(uid: 78, id: second),
                Self.message(uid: 88, id: bystander),
            ],
            "Archive": [],
        ])
        server.setUidValidity(10, for: "INBOX")
        server.setUidValidity(10, for: "Archive")
        server.setFlags(["\\Seen"], in: "INBOX", uid: 88)
        // The genuinely PARTIAL shape: commit the FIRST requested member only,
        // leave the second where it was, then answer tagged NO with no COPYUID.
        server.failUIDMoveAfterPossiblePartialCompletion(committingOnlyFirst: 1)
        server.expectMutation(rfc822MessageId: first)
        server.expectMutation(rfc822MessageId: second)
        try server.start()
        defer { server.stop() }

        let f = try fixture(accountId: "closure-atomic-partial-batch")
        let provider = try await registeredIMAPProvider(server: server, fixture: f)
        let move = PendingOperation(
            type: .move, messageIds: ["77", "78"], accountId: f.accountId,
            folderPath: "INBOX", destinationPath: "Archive", observedUidValidity: 10)
        try insert([move], into: f.pool)

        await AccountManager.shared.drainPendingQueue()

        // NON-VACUITY: the server really did complete only half of the batch.
        #expect(
            server.messageIDs(in: "Archive") == ["<\(first)>"],
            """
            the fake did not commit exactly the first member, so this run is not the partial \
            shape the test is named for — Archive: \(server.messageIDs(in: "Archive"))
            """)
        #expect(
            Set(server.messageIDs(in: "INBOX")) == Set(["<\(second)>", "<\(bystander)>"]),
            """
            the source does not hold exactly the uncommitted member and the bystander — INBOX: \
            \(server.messageIDs(in: "INBOX"))
            """)
        let firstDrainMoves = server.recordedCommands().filter {
            $0.uppercased().contains("UID MOVE")
        }
        #expect(
            firstDrainMoves.count == 1,
            "the refused batch was attempted \(firstDrainMoves.count) time(s) in one drain: \(firstDrainMoves)")

        // THE DURABLE ROW IS WHOLE. Losing the already-moved member here is the
        // drop: nothing on the wire said it moved.
        let afterFirstDrain = try operations(f.pool)
        let parked = try #require(
            afterFirstDrain.first { $0.id == move.id },
            "the partially completed move left the queue on an absence of evidence")
        #expect(
            Set(parked.messageIds) == Set(["77", "78"]),
            """
            the requeued operation no longer names every member the user acted on — the server \
            published no COPYUID, so no member may be retired — members: \(parked.messageIds)
            """)
        #expect(parked.folderPath == "INBOX")
        #expect(parked.destinationPath == "Archive")
        #expect(parked.observedUidValidity == 10)
        #expect(parked.status == PendingStatus.queued.rawValue)
        #expect(
            parked.retryCount == 1,
            "the retry count is \(parked.retryCount) after one drain, so the op was claimed more than once")

        await AccountManager.shared.drainPendingQueue()

        // CONVERGENCE: each member exactly once at the destination, gone from
        // the source, and the bystander untouched.
        let archive = server.messageIDs(in: "Archive")
        #expect(
            archive.filter { $0 == "<\(first)>" }.count == 1,
            "the already-moved member was duplicated or lost by the retry — Archive: \(archive)")
        #expect(
            archive.filter { $0 == "<\(second)>" }.count == 1,
            "the member the server never moved did not land on the retry — Archive: \(archive)")
        #expect(archive.count == 2, "the destination holds unexpected extra mail: \(archive)")
        let inbox = server.messageIDs(in: "INBOX")
        #expect(
            inbox == ["<\(bystander)>"],
            "the source is not left holding exactly the bystander — INBOX: \(inbox)")
        #expect(
            server.flags(in: "INBOX", uid: 88) == ["\\Seen"],
            "the bystander's flags changed — flags: \(server.flags(in: "INBOX", uid: 88))")
        let remaining = try operations(f.pool)
        #expect(
            remaining.isEmpty,
            "the move did not retire after converging: \(remaining.map { "\($0.type):\($0.id)" })")

        // No destructive fallback at any point in the run.
        let commands = server.recordedCommands().map { $0.uppercased() }
        #expect(
            commands.filter { $0.contains("UID COPY") }.isEmpty,
            "a partial atomic move fell back to COPY: \(commands.filter { $0.contains("UID COPY") })")
        #expect(
            commands.filter { $0.contains("+FLAGS") && $0.contains("\\DELETED") }.isEmpty,
            "the source was soft-deleted on a route that never proved a destination copy")
        #expect(
            commands.filter { $0.contains("EXPUNGE") }.isEmpty,
            "an expunge was issued without any per-member COPYUID proof")
        #expect(server.wrongMessageViolations().isEmpty)

        try? await provider.disconnect()
        await finish(f)
    }

    @Test("A COPYUID-proven partial UID MOVE is reconciled and never re-issued")
    @MainActor
    func aVerifiedPartialAtomicMoveIsNeverReissued() async throws {
        try await assertPostCommitAtomicMoveFailureIsNeverReissued(
            accountId: "closure-atomic-verified-partial",
            target: "atomic-verified-partial@example.com",
            configure: { $0.failUIDMoveAfterVerifiedPartialCompletion() })
    }

    @MainActor
    private func assertPostCommitAtomicMoveFailureIsNeverReissued(
        accountId: String,
        target: String,
        configure: (FakeIMAPServer) -> Void
    ) async throws {
        let server = FakeIMAPServer(mailboxes: [
            "INBOX": [Self.message(uid: 77, id: target)],
            "Archive": [],
        ])
        server.setUidValidity(10, for: "INBOX")
        server.setUidValidity(10, for: "Archive")
        configure(server)
        server.expectMutation(rfc822MessageId: target)
        try server.start()
        defer { server.stop() }

        let f = try fixture(accountId: accountId)
        let provider = try await registeredIMAPProvider(server: server, fixture: f)
        let move = PendingOperation(
            type: .move, messageIds: ["77"], accountId: f.accountId,
            folderPath: "INBOX", destinationPath: "Archive", observedUidValidity: 10)
        try insert([move], into: f.pool)

        let context = AccountManager.DrainContext()
        let outcome = await AccountManager.shared.executeSingleOp(
            move, provider: provider, context: context)

        #expect(outcome == .proceed)
        #expect(
            context.foldersToSync == ["\(f.accountId)|INBOX", "\(f.accountId)|Archive"],
            "a post-completion failure must reconcile both the source and destination")
        #expect(
            server.messageIDs(in: "Archive") == ["<\(target)>"],
            "the server-side move must have landed before its tagged failure")

        // A later drain is the real retry boundary. The completed attempt must
        // already be gone from the durable queue, so no second UID MOVE appears.
        await AccountManager.shared.drainPendingQueue()
        await AccountManager.shared.drainPendingQueue()
        let moves = server.recordedCommands().filter {
            $0.uppercased().contains("UID MOVE")
        }
        #expect(moves.count == 1, "the original UID MOVE was re-issued: \(moves)")
        #expect(try operations(f.pool).isEmpty)
        #expect(server.messageIDs(in: "INBOX").isEmpty)
        #expect(server.messageIDs(in: "Archive") == ["<\(target)>"])
        #expect(server.wrongMessageViolations().isEmpty)

        try? await provider.disconnect()
        await finish(f)
    }

    // MARK: - #115 — a tagged NO with no COPYUID evidence is a refusal, not a disposition

    /// GitHub #115. SwiftMail raises `moveFailedAfterPossiblePartialCompletion`
    /// for ANY tagged NO/BAD on `UID MOVE` that carried no `COPYUID` — including
    /// a refusal the server answered before touching either mailbox. The
    /// production shape: a transport loss in the one-RTT window between the
    /// pre-move `SELECT` and the `UID MOVE` makes SwiftMail re-open a raw
    /// channel (no LOGIN, no SELECT) and send the MOVE anyway, and the server
    /// answers `NO No mailbox selected` with zero mutation. The provider used to
    /// catch that case and retire every member as dispositioned: the queue
    /// emptied, the message stayed in the source folder on the server, and the
    /// UI had already shown the move as done — a dropped intention by none of
    /// the four exits (`MIS-IOS-004`; `IOS-IMAP-013`'s recorded disposition is
    /// that a tagged NO/BAD stays a typed, retryable failure).
    ///
    /// THE PROPERTY, in two halves: the intention survives the refusal (still
    /// queued, nothing moved), and it is actually re-attemptable — the next
    /// drain lands the message in the destination exactly once, with the
    /// source empty and the queue empty. The `UID MOVE` count is deliberately
    /// NOT asserted: how many wire attempts convergence takes is the mechanism.
    ///
    /// `failNextCommand` answers the injected NO BEFORE the fake's handler runs,
    /// so the first attempt mutates nothing — the exact world state the fuzzer
    /// observed (`providerIdQueueFuzz`, seed `0x70D8000000000002`).
    ///
    /// Parameterised over the server's refusal text because the property holds
    /// REGARDLESS of it (#115 round 2). The refusal carries the server's raw
    /// tagged response text as a diagnostic payload, and the queue's
    /// message-not-found classifier ends in a substring match on the error's
    /// description — so a refusal that happens to carry an RFC 5530
    /// `[NONEXISTENT]` code (which names a missing MAILBOX, not a missing
    /// message) or the words `UID not found` used to be read as a
    /// provider-authoritative "already gone" and the op was deleted: the same
    /// intention drop, on a different response text. The original
    /// `No mailbox selected` argument contains none of the classifier's
    /// fragments and never reached that path. Round 3 made the exemption
    /// structural on the `ProviderEvidenceUnavailable` protocol rather than on
    /// one transport library's enum, and this matrix is what keeps it honest.
    ///
    /// This is the DESTINATION-PRESENT side of the round-3 pair; its sibling
    /// `aRefusedAtomicMoveIntoAListOmittedDestinationStaysQueuedAndLands` runs
    /// the same refusals against a destination the exact-name LIST omits. The
    /// two together say the LIST result never decides this outcome.
    ///
    /// RED PROOF (recorded, #115): on the pre-fix provider the first drain
    /// retires the op with the message still in INBOX — `operations(f.pool)` is
    /// empty after the refused drain and Archive is still empty after both.
    /// RED PROOF (recorded, #115 round 2): on `2bbeba9e5` the two added
    /// arguments fail the same way — the op is deleted after the refused drain —
    /// while the original argument stays green.
    @Test(
        "A UID MOVE refused before any mutation stays queued, and the next drain lands it",
        arguments: [
            "No mailbox selected",
            // ROUND 3B — this row used to read `[NONEXISTENT] No mailbox
            // selected`. A LEADING `[NONEXISTENT]` is now a permanent response
            // code and RETIRES the operation by owner decision, so that world
            // state moved to
            // `aMoveRefusedWithAPermanentResponseCodeRetiresWithoutMutation`
            // and is replaced here by a TRANSIENT code. `UNAVAILABLE` (RFC 5530
            // §3) describes a condition that clears, so it keeps the round-3
            // property this test exists for, and it keeps the matrix
            // non-vacuous about codes: a coded refusal that is NOT in the
            // permanent set must still stay queued.
            "[UNAVAILABLE] Backend temporarily unavailable",
            "UID not found",
            // ROUND 4 — an UNCLOSED bracket whose atom IS in the permanent set.
            // NIOIMAP parses this as plain text with no response code, so the
            // server stated nothing: it must stay queued and land on the next
            // drain, exactly like the uncoded rows above.
            "[TRYCREATE temporary diagnostic",
        ])
    @MainActor
    func aRefusedAtomicMoveStaysQueuedAndTheNextDrainLandsIt(refusal: String) async throws {
        let target = "atomic-refused-before-mutation@example.com"
        let server = FakeIMAPServer(mailboxes: [
            "INBOX": [Self.message(uid: 77, id: target)],
            "Archive": [],
        ])
        server.setUidValidity(10, for: "INBOX")
        server.setUidValidity(10, for: "Archive")
        // Exactly ONE refusal, answered before the handler runs: the first
        // UID MOVE is refused with zero mutation, every later one is served.
        server.failNextCommand(containing: "UID MOVE", message: refusal)
        server.expectMutation(rfc822MessageId: target)
        try server.start()
        defer { server.stop() }

        // One account id per argument so no per-account state in the shared
        // manager can leak between the serialized cases.
        let f = try fixture(
            accountId: "closure-atomic-refused-" + refusal.lowercased().filter(\.isLetter))
        let provider = try await registeredIMAPProvider(server: server, fixture: f)
        let move = PendingOperation(
            type: .move, messageIds: ["77"], accountId: f.accountId,
            folderPath: "INBOX", destinationPath: "Archive", observedUidValidity: 10)
        try insert([move], into: f.pool)

        await AccountManager.shared.drainPendingQueue()

        // HALF 1 — the intention survived the refusal, and nothing moved.
        let afterRefusedDrain = try operations(f.pool)
        #expect(
            afterRefusedDrain.map(\.id) == [move.id],
            """
            a tagged NO that carried no COPYUID evidence retired the durable move — an absence of \
            evidence was read as a provider disposition, which is none of the four exits — \
            remaining ops: \(afterRefusedDrain.map(\.type))
            """)
        let inboxAfterRefusal = server.messageIDs(in: "INBOX")
        #expect(
            inboxAfterRefusal == ["<\(target)>"],
            "the refused UID MOVE must have mutated nothing: INBOX=\(inboxAfterRefusal)")
        #expect(server.messageIDs(in: "Archive").isEmpty)

        // The second drain is the retry boundary (`failedAccounts` is per drain).
        await AccountManager.shared.drainPendingQueue()

        // HALF 2 — and it was actually re-attemptable: the message is in the
        // destination exactly once, the source is empty, the queue is empty.
        let archiveAfterRetry = server.messageIDs(in: "Archive")
        #expect(
            archiveAfterRetry == ["<\(target)>"],
            "the retry did not land exactly one copy in Archive: \(archiveAfterRetry)")
        let inboxAfterRetry = server.messageIDs(in: "INBOX")
        #expect(
            inboxAfterRetry.isEmpty,
            "the message is still in the source after the retry: \(inboxAfterRetry)")
        let afterRetryDrain = try operations(f.pool)
        #expect(
            afterRetryDrain.isEmpty,
            "the op did not retire after the move actually landed: \(afterRetryDrain.map(\.type))")
        #expect(server.wrongMessageViolations().isEmpty)

        try? await provider.disconnect()
        await finish(f)
    }

    // MARK: - #115 round 3 — a LIST omission is not absence; the transport-loss witness

    /// #115 round 3 (correctness finding P1). This test was
    /// `aRefusedAtomicMoveIntoAListConfirmedAbsentDestinationRetiresAsANoOp`
    /// and it BLESSED the defect. It pinned "an exact-name LIST that omits the
    /// destination retires the whole operation as a provider-authoritative
    /// no-op", driven by `markMailboxDeleted` — a fixture in which "the mailbox
    /// is gone" and "the mailbox is omitted from LIST" are the SAME state, so
    /// the test structurally could not tell the two apart.
    ///
    /// A LIST omission proves nothing about existence. RFC 4314 §4 defines `l`
    /// (visibility to LIST) and `i` (permission to COPY/MOVE into) as
    /// INDEPENDENT rights, so a mailbox may be invisible to LIST and still be a
    /// legal MOVE target; RFC 9051 §6.3.9 separately lets a server silently
    /// ignore a syntactically valid pattern under a tagged OK. Retiring a
    /// zero-mutation refusal on that omission is a dropped intention — the very
    /// defect #115 exists to close, re-entered through a different door.
    ///
    /// THE PROPERTY, stated as the invariant rather than the routing: a tagged
    /// NO/BAD on `UID MOVE` that carries no `COPYUID` is an ABSENCE OF
    /// EVIDENCE, so the operation stays durably queued with its retry count
    /// advancing and a later drain lands it — regardless of the server's
    /// response text, and regardless of what an exact-name LIST says about the
    /// destination. Nothing here asserts a command count, an error type, or
    /// which branch of the provider ran.
    ///
    /// `hideMailboxFromList` is what makes the LIST half non-vacuous, and it is
    /// two-sided. Forward: the destination is omitted from LIST for the whole
    /// test and the move still completes into it on the second drain, so the
    /// mailbox provably exists while hidden (the seam's own wire contract is
    /// pinned by `FakeIMAPServerOracleTests.hiddenFromListMailboxStillExists`:
    /// LIST omits the name under a tagged OK while SELECT and `UID MOVE`
    /// succeed). Backward: on the parent commit the LIST probe fires on exactly
    /// this fixture and retires the op, which is the red proof below — a
    /// fixture whose omission were inert could not produce it.
    ///
    /// Parameterised over the same refusal texts as
    /// `aRefusedAtomicMoveStaysQueuedAndTheNextDrainLandsIt`, `[NONEXISTENT]`
    /// included, so no response text can decide this either.
    ///
    /// RED PROOF (recorded, #115 round 3): on the parent `977958c37` the first
    /// drain RETIRES the operation for all three arguments —
    /// `Expectation failed: (afterRefusedDrain.map(\.id) → []) == ([move.id] → [...])`,
    /// with `status` and `retryCount` both `nil` because the row is gone, and
    /// `Archive` still empty after the second drain. The queue is empty where
    /// this test requires the move to still be there.
    @Test(
        "A UID MOVE refused into a destination an exact LIST omits stays queued, and the next drain lands it",
        arguments: [
            "No mailbox selected",
            // ROUND 3B — this row used to read `[NONEXISTENT] No mailbox
            // selected`. A LEADING `[NONEXISTENT]` is now a permanent response
            // code and RETIRES the operation by owner decision, so that world
            // state moved to
            // `aMoveRefusedWithAPermanentResponseCodeRetiresWithoutMutation`
            // and is replaced here by a TRANSIENT code. `UNAVAILABLE` (RFC 5530
            // §3) describes a condition that clears, so it keeps the round-3
            // property this test exists for, and it keeps the matrix
            // non-vacuous about codes: a coded refusal that is NOT in the
            // permanent set must still stay queued.
            "[UNAVAILABLE] Backend temporarily unavailable",
            "UID not found",
        ])
    @MainActor
    func aRefusedAtomicMoveIntoAListOmittedDestinationStaysQueuedAndLands(
        refusal: String
    ) async throws {
        let target = "atomic-list-omitted-destination@example.com"
        let server = FakeIMAPServer(mailboxes: [
            "INBOX": [Self.message(uid: 77, id: target)],
            "Archive": [],
        ])
        server.setUidValidity(10, for: "INBOX")
        server.setUidValidity(10, for: "Archive")
        // The destination EXISTS and accepts MOVE; it is merely invisible to
        // LIST (an ACL `l` revocation, or a pattern the server chose to ignore).
        server.hideMailboxFromList("Archive")
        // Exactly ONE refusal, answered before the handler runs: the first
        // UID MOVE is refused with zero mutation, every later one is served.
        server.failNextCommand(containing: "UID MOVE", message: refusal)
        server.expectMutation(rfc822MessageId: target)
        try server.start()
        defer { server.stop() }

        // One account id per argument so no per-account state in the shared
        // manager can leak between the serialized cases.
        let f = try fixture(
            accountId: "closure-atomic-list-omitted-" + refusal.lowercased().filter(\.isLetter))
        let provider = try await registeredIMAPProvider(server: server, fixture: f)
        let move = PendingOperation(
            type: .move, messageIds: ["77"], accountId: f.accountId,
            folderPath: "INBOX", destinationPath: "Archive", observedUidValidity: 10)
        try insert([move], into: f.pool)

        await AccountManager.shared.drainPendingQueue()

        // NON-VACUITY, wire side: the atomic MOVE really was issued and really
        // was refused, so what follows is about the refusal and not about a
        // fixture that never got that far.
        let firstDrain = server.recordedCommands().map { $0.uppercased() }
        #expect(
            firstDrain.contains { $0.contains("UID MOVE") && $0.contains("ARCHIVE") },
            "the atomic UID MOVE never reached the wire: \(firstDrain)")
        #expect(server.consumedInjectedFailureCount() == 1)

        // HALF 1 — the intention survived a refusal into a destination the
        // exact-name LIST omits, and nothing moved.
        let afterRefusedDrain = try operations(f.pool)
        #expect(
            afterRefusedDrain.map(\.id) == [move.id],
            """
            a tagged NO that carried no COPYUID evidence retired the durable move because an \
            exact-name LIST omitted the destination. A LIST omission is not proof of absence \
            (RFC 4314 §4 separates the l and i rights; RFC 9051 §6.3.9 permits silent pattern \
            omission), so this retired a user intention on an absence of evidence — remaining \
            ops: \(afterRefusedDrain.map(\.type))
            """)
        #expect(afterRefusedDrain.first?.status == PendingStatus.queued.rawValue)
        #expect(
            afterRefusedDrain.first?.retryCount == 1,
            "the refused attempt was not recorded as a retry: \(String(describing: afterRefusedDrain.first?.retryCount))")
        #expect(server.messageIDs(in: "INBOX") == ["<\(target)>"])
        #expect(server.messageIDs(in: "Archive").isEmpty)
        #expect(server.flags(in: "INBOX", uid: 77).isEmpty)
        #expect(firstDrain.filter { $0.contains("UID COPY") }.isEmpty)
        #expect(firstDrain.filter { $0.contains("UID STORE") && $0.contains("\\DELETED") }.isEmpty)
        #expect(firstDrain.filter { $0.contains("EXPUNGE") }.isEmpty)

        // The second drain is the retry boundary (`failedAccounts` is per drain).
        await AccountManager.shared.drainPendingQueue()

        // HALF 2 — the destination was there all along: the move lands in it
        // exactly once, the source empties, the queue empties.
        let archiveAfterRetry = server.messageIDs(in: "Archive")
        #expect(
            archiveAfterRetry == ["<\(target)>"],
            "the retry did not land exactly one copy in the LIST-omitted destination: \(archiveAfterRetry)")
        let inboxAfterRetry = server.messageIDs(in: "INBOX")
        #expect(
            inboxAfterRetry.isEmpty,
            "the message is still in the source after the retry: \(inboxAfterRetry)")
        let afterRetryDrain = try operations(f.pool)
        #expect(
            afterRetryDrain.isEmpty,
            "the op did not retire after the move actually landed: \(afterRetryDrain.map(\.type))")
        #expect(server.wrongMessageViolations().isEmpty)

        try? await provider.disconnect()
        await finish(f)
    }

    // MARK: - #115 round 3b — a response code that says "never" retires the op

    /// GitHub #115 round 3b, and the case the OWNER decided on 2026-09-05: *"if
    /// server has deleted folder, we should retire that op"*, *"if server says op
    /// is broken, we should retire it. and then later on full sync would catch
    /// that back"*.
    ///
    /// A conforming server whose MOVE destination has genuinely been deleted
    /// answers `NO [TRYCREATE] …` (RFC 3501 §6.4.7, carried onto MOVE by RFC 6851
    /// §3.3). Unlike the LIST omission its sibling above is about, that is a
    /// POSITIVE statement the server chose to make about the command it just
    /// refused, so it is provider authority and never-drop exit 2.
    ///
    /// THE PROPERTY, and it is an end state, not a mechanism: after ONE drain the
    /// queue is EMPTY, the message is still in the SOURCE mailbox on the server,
    /// and the refusal cost zero wire mutation — no `UID COPY`, no `\Deleted`
    /// STORE, no EXPUNGE, no wrong-message mutation. Nothing here asserts which
    /// error type was thrown, which catch arm ran, or how many commands it took.
    /// The message surviving in the source is the half that makes retiring
    /// SAFE: the local optimistic row is reclaimed by the next sync of that
    /// folder, so the cost is a stale row and never a lost message.
    ///
    /// `markMailboxDeleted` is the fixture rather than `failNextCommand` because
    /// this is the WORLD STATE the owner decided about — a destination that is
    /// really gone — and the fake answers `UID MOVE` into a deleted mailbox with
    /// the `[TRYCREATE]` shape a conforming server sends. `includeNonexistentCode`
    /// governs only the SELECT/LIST responses, which the atomic route never
    /// issues for a destination, so the MOVE refusal is identical either way.
    ///
    /// RED PROOF (recorded, #115 round 3b): on the parent `f9dcd71ec` the op is
    /// still queued after the drain —
    /// `Expectation failed: (afterDrain.map(\.id) → [move.id]).isEmpty`, i.e.
    /// `a UID MOVE the server refused with a permanent response code …` — because
    /// round 3 routed every refusal, coded or not, to the lane-local park.
    @Test("A UID MOVE refused with [TRYCREATE] because the destination was deleted retires with zero mutation")
    @MainActor
    func aMoveRefusedIntoADeletedDestinationRetiresWithoutMutation() async throws {
        let target = "atomic-deleted-destination@example.com"
        let server = FakeIMAPServer(mailboxes: [
            "INBOX": [Self.message(uid: 77, id: target)],
            "Archive": [],
        ])
        server.setUidValidity(10, for: "INBOX")
        server.setUidValidity(10, for: "Archive")
        // The destination is genuinely gone: `UID MOVE` into it is answered
        // `NO [TRYCREATE] UID MOVE destination does not exist`, every time.
        server.markMailboxDeleted("Archive", includeNonexistentCode: false)
        server.expectMutation(rfc822MessageId: target)
        try server.start()
        defer { server.stop() }

        let f = try fixture(accountId: "closure-atomic-deleted-destination")
        let provider = try await registeredIMAPProvider(server: server, fixture: f)
        let move = PendingOperation(
            type: .move, messageIds: ["77"], accountId: f.accountId,
            folderPath: "INBOX", destinationPath: "Archive", observedUidValidity: 10)
        try insert([move], into: f.pool)

        await AccountManager.shared.drainPendingQueue()

        // NON-VACUITY: the atomic MOVE really was issued and really was refused
        // by the destination-deleted branch, so what follows is about the
        // refusal and not about a fixture that never got that far.
        let commands = server.recordedCommands().map { $0.uppercased() }
        #expect(
            commands.contains { $0.contains("UID MOVE") && $0.contains("ARCHIVE") },
            "the atomic UID MOVE never reached the wire: \(commands)")

        // THE PROPERTY — the operation retired.
        let afterDrain = try operations(f.pool)
        #expect(
            afterDrain.isEmpty,
            """
            a UID MOVE the server refused with a permanent response code is still queued. The \
            server said the command can never succeed as issued, so retrying it forever parks the \
            lane and holds every same-lane successor behind it — still queued: \
            \(afterDrain.map { "\($0.type):retry \($0.retryCount)" })
            """)

        // …and it retired on evidence, having mutated NOTHING: the message is
        // still in the source, so the next sync of that folder reclaims the
        // local row and the user's mail is where it always was.
        let inbox = server.messageIDs(in: "INBOX")
        #expect(
            inbox == ["<\(target)>"],
            "the refused move must leave the message in the source mailbox: \(inbox)")
        #expect(server.messageIDs(in: "Archive").isEmpty)
        #expect(server.flags(in: "INBOX", uid: 77).isEmpty)
        #expect(commands.filter { $0.contains("UID COPY") }.isEmpty)
        #expect(commands.filter { $0.contains("UID STORE") && $0.contains("\\DELETED") }.isEmpty)
        #expect(commands.filter { $0.contains("EXPUNGE") }.isEmpty)
        #expect(server.wrongMessageViolations().isEmpty)

        try? await provider.disconnect()
        await finish(f)
    }

    /// GitHub #115 round 3b — the same property as the test above, for the codes
    /// a server sends WITHOUT having deleted anything. `NOPERM`, `CANNOT` and
    /// `NONEXISTENT` are RFC 5530 §3 response codes, and each of them says the
    /// command cannot succeed as issued: no permission for this operation, the
    /// operation is not allowed, the named mailbox does not exist. By the same
    /// owner decision they retire the operation.
    ///
    /// Parameterised because the property is about the CLASS of code, not about
    /// any one of them, and because a set that quietly lost a member would
    /// otherwise pass. Its complement is pinned by the two round-3 matrices,
    /// which now carry the transient `[UNAVAILABLE]` and stay queued.
    ///
    /// The refusal is injected with `failNextCommand`, which answers BEFORE the
    /// fake's MOVE handler runs, so every one of these mutates nothing at all —
    /// the world state that makes retiring safe rather than a guess.
    ///
    /// RED PROOF (recorded, #115 round 3b): on the parent `f9dcd71ec` all three
    /// arguments fail the same way — the op is still queued after the drain,
    /// `Expectation failed: (afterDrain.map(\.id) → [move.id]).isEmpty`.
    @Test(
        "A UID MOVE refused with a permanent RFC 5530 response code retires with zero mutation",
        arguments: [
            "[NOPERM] Permission denied",
            "[CANNOT] Policy forbids this move",
            "[NONEXISTENT] No such mailbox",
        ])
    @MainActor
    func aMoveRefusedWithAPermanentResponseCodeRetiresWithoutMutation(
        refusal: String
    ) async throws {
        let target = "atomic-permanent-code@example.com"
        let server = FakeIMAPServer(mailboxes: [
            "INBOX": [Self.message(uid: 77, id: target)],
            "Archive": [],
        ])
        server.setUidValidity(10, for: "INBOX")
        server.setUidValidity(10, for: "Archive")
        server.failNextCommand(containing: "UID MOVE", message: refusal)
        server.expectMutation(rfc822MessageId: target)
        try server.start()
        defer { server.stop() }

        // One account id per argument so no per-account state in the shared
        // manager can leak between the serialized cases.
        let f = try fixture(
            accountId: "closure-atomic-permanent-" + refusal.lowercased().filter(\.isLetter))
        let provider = try await registeredIMAPProvider(server: server, fixture: f)
        let move = PendingOperation(
            type: .move, messageIds: ["77"], accountId: f.accountId,
            folderPath: "INBOX", destinationPath: "Archive", observedUidValidity: 10)
        try insert([move], into: f.pool)

        await AccountManager.shared.drainPendingQueue()

        // NON-VACUITY: the MOVE reached the wire and the injected refusal is
        // what answered it.
        let commands = server.recordedCommands().map { $0.uppercased() }
        #expect(
            commands.contains { $0.contains("UID MOVE") && $0.contains("ARCHIVE") },
            "the atomic UID MOVE never reached the wire: \(commands)")
        #expect(server.consumedInjectedFailureCount() == 1)

        // THE PROPERTY — retired, with the message untouched in the source.
        let afterDrain = try operations(f.pool)
        #expect(
            afterDrain.isEmpty,
            """
            a UID MOVE the server refused with a permanent response code is still queued. The \
            server said the command can never succeed as issued, so retrying it forever parks the \
            lane and holds every same-lane successor behind it — still queued: \
            \(afterDrain.map { "\($0.type):retry \($0.retryCount)" })
            """)
        let inbox = server.messageIDs(in: "INBOX")
        #expect(
            inbox == ["<\(target)>"],
            "the refused move must leave the message in the source mailbox: \(inbox)")
        #expect(server.messageIDs(in: "Archive").isEmpty)
        #expect(server.flags(in: "INBOX", uid: 77).isEmpty)
        #expect(commands.filter { $0.contains("UID COPY") }.isEmpty)
        #expect(commands.filter { $0.contains("UID STORE") && $0.contains("\\DELETED") }.isEmpty)
        #expect(commands.filter { $0.contains("EXPUNGE") }.isEmpty)
        #expect(server.wrongMessageViolations().isEmpty)

        try? await provider.disconnect()
        await finish(f)
    }

    /// GitHub #115 round 3b — the STRUCTURE half, and the reason the extractor is
    /// not a substring search.
    ///
    /// RFC 3501 §7.1 defines `resp-text = ["[" resp-text-code "]" SP] text`: a
    /// response code is a protocol statement ONLY in the leading position. The
    /// same word inside the server's human sentence is prose. A server that
    /// answers `NO Move refused, see [TRYCREATE] semantics` is explaining itself,
    /// not invoking §6.4.7, and reading that as authority would let a server's
    /// wording retire a user's intention — the #115 defect class exactly, entered
    /// through the newest door.
    ///
    /// THE PROPERTY: such a refusal keeps the round-3 disposition — still queued
    /// after the refused drain, nothing mutated — and the next drain lands it.
    /// Its unit-level counterpart, over the exact rendered shapes SwiftMail
    /// produces, is `IMAPMoveWireContractTests.leadingResponseCodeIsReadStructurally`;
    /// these two are the fragile-contract pins for that rendering.
    @Test("A refusal that mentions a response code later in its human text is not a response code")
    @MainActor
    func aRefusalWhoseHumanTextMentionsACodeLaterStaysQueued() async throws {
        let target = "atomic-code-in-prose@example.com"
        let server = FakeIMAPServer(mailboxes: [
            "INBOX": [Self.message(uid: 77, id: target)],
            "Archive": [],
        ])
        server.setUidValidity(10, for: "INBOX")
        server.setUidValidity(10, for: "Archive")
        // The word appears, but NOT as a leading `resp-text-code`.
        server.failNextCommand(
            containing: "UID MOVE", message: "Move refused, see [TRYCREATE] semantics")
        server.expectMutation(rfc822MessageId: target)
        try server.start()
        defer { server.stop() }

        let f = try fixture(accountId: "closure-atomic-code-in-prose")
        let provider = try await registeredIMAPProvider(server: server, fixture: f)
        let move = PendingOperation(
            type: .move, messageIds: ["77"], accountId: f.accountId,
            folderPath: "INBOX", destinationPath: "Archive", observedUidValidity: 10)
        try insert([move], into: f.pool)

        await AccountManager.shared.drainPendingQueue()

        #expect(server.consumedInjectedFailureCount() == 1)
        let afterRefusedDrain = try operations(f.pool)
        #expect(
            afterRefusedDrain.map(\.id) == [move.id],
            """
            a response code named in the middle of the server's human text retired the durable \
            move. RFC 3501 §7.1 puts a resp-text-code only at the START of the response text, so \
            this is the server's prose and not an assertion it can never perform the command — \
            remaining ops: \(afterRefusedDrain.map(\.type))
            """)
        #expect(server.messageIDs(in: "INBOX") == ["<\(target)>"])
        #expect(server.messageIDs(in: "Archive").isEmpty)

        // And it is genuinely re-attemptable, not merely undropped.
        await AccountManager.shared.drainPendingQueue()

        #expect(server.messageIDs(in: "Archive") == ["<\(target)>"])
        #expect(server.messageIDs(in: "INBOX").isEmpty)
        #expect(try operations(f.pool).isEmpty)
        #expect(server.wrongMessageViolations().isEmpty)

        try? await provider.disconnect()
        await finish(f)
    }

    /// #115 round 3 (architecture finding A-1 / robustness finding R1). The
    /// sibling of `unprovableOpDoesNotWedgeTheAccountsOtherGestures`, for the
    /// refusal this issue is about, and for the case its one-shot fixtures
    /// cannot reach: a server that refuses `UID MOVE` on EVERY attempt.
    ///
    /// Before this round the refusal reached the drain's GENERIC catch, which
    /// does `context.failedAccounts.insert(...)` — account-wide suppression the
    /// drain documents as reserved for facts about the CONNECTION. A tagged
    /// command refusal says nothing about the connection, and `ADR-IOS-073`
    /// expressly accepts that a server may advertise MOVE and then permanently
    /// reject it ("can park the lane until its configuration is corrected").
    /// Parking a LANE is the accepted cost; parking the ACCOUNT is not: every
    /// disjoint gesture the user made would be denied on every drain, which is
    /// preserving one intention by dropping all the others.
    ///
    /// THREE PROPERTIES, all asserted at the server across repeated drains:
    ///  1. the refused MOVE is still queued with its retry count advancing, and
    ///     its same-lane successor is still held — `buildLanes` unions on shared
    ///     message ids, so running a lane-mate ahead of an unresolved
    ///     predecessor is the race `.haltLane` exists to prevent;
    ///  2. FIVE disjoint-lane gestures on a different message all reach the
    ///     server and retire WITHIN THE FIRST DRAIN, leaving the queue holding
    ///     exactly the two lane-A rows. Five rather than one, and asserted after
    ///     one drain rather than four, because `failedAccounts` is per-drain and
    ///     is re-evaluated before every op of a lane: a poisoned account lets
    ///     the gesture already past that check slip through, requeues the rest,
    ///     and then releases roughly one more per drain — so measured only at
    ///     the end, a starved account and a healthy one look identical.
    ///  3. (round 4b) the refused op is attempted AT MOST ONCE per
    ///     `drainPendingQueue()` call, asserted EXACTLY — one `UID MOVE` on the
    ///     wire, one consumed refusal and `retryCount == 1` after the first
    ///     drain, four consumed refusals and `retryCount == 4` after four. The
    ///     bystander lane succeeds, which sets `executedAny` and makes the outer
    ///     loop take another pass, so the op WOULD be re-claimed; a lower bound
    ///     cannot reject that, and it is the property `evidenceRefused` exists
    ///     for.
    ///
    /// It never inspects `failedAccounts`, `evidenceRefused` or any other drain
    /// internal: those are mechanism, and a test written against them would stay
    /// green if the poisoning simply moved somewhere else.
    ///
    /// RED PROOF (recorded, #115 round 3): on the parent `977958c37` NOT ONE
    /// bystander gesture reaches the server in the poisoned drain —
    /// `Expectation failed: (unrelated → []).contains("\\Seen")`, likewise
    /// `\Flagged` and `\Answered`, and `Set(afterFirstDrain.map(\.id))` holds
    /// FIVE rows where the property allows two. The two gestures that did
    /// execute were the flag REMOVALS, which leave no trace on a message that
    /// never had the flags — which is why the lane is five gestures long and
    /// why the assertion is made after one drain.
    @Test("A permanently refused UID MOVE parks its own lane and never the account")
    @MainActor
    func aPermanentlyRefusedAtomicMoveParksOnlyItsOwnLane() async throws {
        let refused = "permanent-refusal-target@example.com"
        let bystander = "permanent-refusal-bystander@example.com"
        let server = FakeIMAPServer(mailboxes: [
            "INBOX": [
                Self.message(uid: 77, id: refused),
                Self.message(uid: 88, id: bystander),
            ],
            "Archive": [],
        ])
        server.setUidValidity(10, for: "INBOX")
        server.setUidValidity(10, for: "Archive")
        // A PERMANENT refusal: every `UID MOVE`, on every drain, is answered
        // with a tagged NO carrying no COPYUID and mutating nothing. The fake's
        // injected failures are a FIFO whose head must have `skip == 0` to fire,
        // so "always refuse" is armed as one `onMatch: 1` entry per possible
        // attempt rather than one entry per ordinal. The response text
        // deliberately carries none of the queue classifier's substring
        // fragments, so this case is decided structurally and not by wording.
        let drains = 4
        for _ in 0..<(drains * 3) {
            server.failCommand(
                containing: "UID MOVE", onMatch: 1,
                message: "Move rejected by server policy")
        }
        server.expectMutation(rfc822MessageId: refused)
        server.expectMutation(rfc822MessageId: bystander)
        try server.start()
        defer { server.stop() }

        let f = try fixture(accountId: "closure-permanent-move-refusal")
        let provider = try await registeredIMAPProvider(server: server, fixture: f)

        // Lane A — the refused move, and a successor the user issued after it on
        // the SAME message, which must stay held behind it.
        var refusedMove = PendingOperation(
            type: .move, messageIds: ["77"], accountId: f.accountId,
            folderPath: "INBOX", destinationPath: "Archive", observedUidValidity: 10)
        refusedMove.createdAt = Date().addingTimeInterval(-60)

        func later(
            _ type: OperationType, on uid: String, _ secondsAgo: TimeInterval
        ) -> PendingOperation {
            var op = PendingOperation(
                type: type, messageIds: [uid], accountId: f.accountId,
                folderPath: "INBOX", observedUidValidity: 10)
            op.createdAt = Date().addingTimeInterval(-secondsAgo)
            return op
        }
        let laneMate = later(.markFlagged, on: "77", 50)
        try insert(
            [
                refusedMove,
                laneMate,
                // Lane B — a different message, therefore a different lane,
                // therefore nothing to do with the refusal. FIVE gestures, and
                // the number is load-bearing: the account-wide skip is
                // re-evaluated before EVERY op of a lane, so a poisoned account
                // lets the one already past that check slip through and requeues
                // all the rest. A single bystander gesture would be
                // indistinguishable from a healthy account.
                later(.markUnread, on: "88", 34),
                later(.markUnflagged, on: "88", 32),
                later(.markRead, on: "88", 30),
                later(.markFlagged, on: "88", 20),
                later(.markReplied, on: "88", 10),
            ],
            into: f.pool)

        // ONE drain first, because `failedAccounts` is per-drain: a starved lane
        // trickles through at roughly a gesture per drain, so after four drains
        // a poisoned account and a healthy one reach the SAME end state. The
        // difference is only observable inside a single drain.
        await AccountManager.shared.drainPendingQueue()

        // PROPERTY 2 — every disjoint-lane gesture reached the server, in the
        // very drain in which the MOVE was refused.
        let unrelated = server.flags(in: "INBOX", uid: 88)
        #expect(
            unrelated.contains("\\Seen"),
            "a disjoint-lane gesture never reached the server — flags: \(unrelated)")
        #expect(
            unrelated.contains("\\Flagged"),
            """
            a gesture on an UNRELATED message was denied because a MOVE on a different message was \
            refused. A refused command is not a provider outage, and one intention may never be \
            preserved by denying every intention behind it — flags: \(unrelated)
            """)
        #expect(
            unrelated.contains("\\Answered"),
            """
            the account is still suppressed after the earlier gestures got through — the \
            account-wide skip is re-evaluated before every op in a lane, so a later one is denied \
            even once an earlier one slipped past — flags: \(unrelated)
            """)
        let afterFirstDrain = try operations(f.pool)
        #expect(
            Set(afterFirstDrain.map(\.id)) == Set([refusedMove.id, laneMate.id]),
            """
            one drain did not retire every disjoint-lane gesture: a MOVE refused on ONE message \
            suppressed unrelated work elsewhere on the same account, so the user's other \
            intentions were denied to preserve this one — still queued: \
            \(afterFirstDrain.map { "\($0.type)" })
            """)

        // PROPERTY 3 (round 4b) — THE PER-DRAIN BOUND, and it is EXACT: an
        // evidence-refused operation is attempted AT MOST ONCE per
        // `drainPendingQueue()` call. A lower bound cannot express this. The
        // bystander lane above SUCCEEDS, which sets `executedAny`, so the outer
        // drain loop takes another pass and would re-claim this op; only
        // `DrainContext.evidenceRefused` stops the second attempt. Without it
        // the wire sees two `UID MOVE`s and the durable `retryCount` advances
        // twice in one drain, and every `>=` form here stays green.
        let firstDrainMoves = server.recordedCommands()
            .map { $0.uppercased() }
            .filter { $0.contains("UID MOVE") && $0.contains("77") }
        #expect(
            firstDrainMoves.count == 1,
            """
            the refused move was attempted \(firstDrainMoves.count) time(s) in ONE drain. A \
            refusal that re-attempts within a drain hammers the server for as long as any other \
            lane keeps making progress — commands: \(firstDrainMoves)
            """)
        #expect(
            server.consumedInjectedFailureCount() == 1,
            "the injected refusal fired \(server.consumedInjectedFailureCount()) times in one drain")
        let refusedRowAfterFirstDrain = try #require(
            afterFirstDrain.first { $0.id == refusedMove.id })
        #expect(
            refusedRowAfterFirstDrain.retryCount == 1,
            """
            the durable retry count advanced to \(refusedRowAfterFirstDrain.retryCount) in a \
            single drain, so the op was claimed and refused more than once in that pass
            """)

        // The remaining drains are for property 1: the refusal keeps being
        // retried, drain after drain, and is neither dropped nor applied.
        for _ in 1..<drains {
            await AccountManager.shared.drainPendingQueue()
        }

        // NON-VACUITY: the MOVE really was attempted, repeatedly, and really was
        // refused every time.
        let commands = server.recordedCommands().map { $0.uppercased() }
        #expect(
            commands.filter { $0.contains("UID MOVE") }.count >= 3,
            "the refused move stopped being attempted: \(commands.filter { $0.contains("UID MOVE") }.count) UID MOVE command(s)")
        // EXACT across the whole run, by the same per-drain bound: four drains,
        // one attempt each, four consumed refusals.
        #expect(
            server.consumedInjectedFailureCount() == drains,
            """
            \(drains) drains consumed \(server.consumedInjectedFailureCount()) refusals rather \
            than one per drain
            """)

        // PROPERTY 1 — the refused move is still queued and still advancing, its
        // lane-mate is still held, and nothing else is left in the queue.
        let remaining = try operations(f.pool)
        #expect(
            Set(remaining.map(\.id)) == Set([refusedMove.id, laneMate.id]),
            """
            the queue does not hold exactly the refused move and its held lane-mate — either the \
            refusal dropped an intention or a disjoint-lane gesture was starved: \
            \(remaining.map { "\($0.type):\($0.id)" })
            """)
        guard remaining.count == 2 else {
            try? await provider.disconnect()
            await finish(f)
            return
        }
        let refusedRow = try #require(remaining.first { $0.id == refusedMove.id })
        #expect(refusedRow.status == PendingStatus.queued.rawValue)
        #expect(
            refusedRow.retryCount == drains,
            "the repeatedly refused move advanced its retry count \(refusedRow.retryCount) times over \(drains) drains — the bound is exactly one per drain")
        // The lane-mate is HELD, not executed: it names the same message as an
        // unresolved predecessor. NON-VACUOUS by construction — the identical
        // `.markFlagged` gesture on uid 88 provably landed above.
        let heldLane = server.flags(in: "INBOX", uid: 77)
        #expect(
            !heldLane.contains("\\Flagged"),
            """
            a lane-mate of the refused move executed while that move was still queued. They name \
            the SAME message by construction, so this ran ahead of a predecessor the user issued \
            FIRST and whose eventual retry will act against state it never observed — flags: \
            \(heldLane)
            """)
        // Nothing was mutated at the source or the destination by the refusals.
        #expect(server.messageIDs(in: "Archive").isEmpty)
        #expect(server.messageIDs(in: "INBOX").contains("<\(refused)>"))
        #expect(commands.filter { $0.contains("UID COPY") }.isEmpty)
        #expect(commands.filter { $0.contains("EXPUNGE") }.isEmpty)
        #expect(server.wrongMessageViolations().isEmpty)

        try? await provider.disconnect()
        await finish(f)
    }

    /// #115 round 2 (test-coverage finding T4). The ORIGINAL #115 world state,
    /// pinned deterministically: the transport dies mid-`UID MOVE`. The fake
    /// closes the socket with NO response — the same seam the fuzzer's
    /// transient-kill step arms (`killConnectionOnNextCommand`, see
    /// `ProviderIdQueueFuzzTests.performStep`). `killFragments` gained
    /// `"UID MOVE"` for this, but neither checked-in seed ever draws that
    /// member, so this test is its deterministic witness:
    /// `consumedInjectedFailureCount() == 1` proves the kill landed on a
    /// `UID MOVE` and on nothing else.
    ///
    /// THE PROPERTY, in two halves: the first attempt left the intention
    /// durable and re-attemptable — row still queued, `retryCount` bumped,
    /// INBOX still holding the message, Archive empty, no COPY/STORE/EXPUNGE
    /// fallback — and a later drain converges: Archive holds exactly the
    /// message, INBOX is empty, the queue is empty, no wrong-message mutation.
    /// How many wire attempts or drains convergence takes is the mechanism and
    /// is bounded, not pinned.
    @Test("A transport loss mid-UID MOVE leaves the op queued and retryable, and a later drain lands it")
    @MainActor
    func aTransportLossMidAtomicMoveLeavesTheOpQueuedAndALaterDrainLandsIt() async throws {
        let target = "atomic-transport-loss@example.com"
        let server = FakeIMAPServer(mailboxes: [
            "INBOX": [Self.message(uid: 77, id: target)],
            "Archive": [],
        ])
        server.setUidValidity(10, for: "INBOX")
        server.setUidValidity(10, for: "Archive")
        // A real dead TCP connection on the next UID MOVE — no response at all.
        server.killConnectionOnNextCommand(containing: "UID MOVE")
        server.expectMutation(rfc822MessageId: target)
        try server.start()
        defer { server.stop() }

        let f = try fixture(accountId: "closure-atomic-transport-loss")
        let provider = try await registeredIMAPProvider(server: server, fixture: f)
        let move = PendingOperation(
            type: .move, messageIds: ["77"], accountId: f.accountId,
            folderPath: "INBOX", destinationPath: "Archive", observedUidValidity: 10)
        try insert([move], into: f.pool)

        await AccountManager.shared.drainPendingQueue()

        // NON-VACUITY: the kill was consumed, and by a UID MOVE — the only
        // command it was armed for.
        #expect(server.consumedInjectedFailureCount() == 1)
        let firstAttempt = server.recordedCommands().map { $0.uppercased() }
        #expect(
            firstAttempt.contains { $0.contains("UID MOVE") && $0.contains("ARCHIVE") },
            "the atomic UID MOVE never reached the wire: \(firstAttempt)")

        // HALF 1 — durable and re-attemptable, nothing mutated.
        let afterKilledDrain = try operations(f.pool)
        #expect(
            afterKilledDrain.map(\.id) == [move.id],
            """
            a transport loss mid-MOVE retired the durable move — an absence of evidence was read as \
            a provider disposition, which is none of the four exits — remaining ops: \
            \(afterKilledDrain.map(\.type))
            """)
        #expect(afterKilledDrain.first?.status == PendingStatus.queued.rawValue)
        #expect(
            afterKilledDrain.first?.retryCount == 1,
            "the failed attempt was not recorded as a retry: \(String(describing: afterKilledDrain.first?.retryCount))")
        #expect(server.messageIDs(in: "INBOX") == ["<\(target)>"])
        #expect(server.messageIDs(in: "Archive").isEmpty)
        #expect(firstAttempt.filter { $0.contains("UID COPY") }.isEmpty)
        #expect(firstAttempt.filter { $0.contains("UID STORE") && $0.contains("\\DELETED") }.isEmpty)
        #expect(firstAttempt.filter { $0.contains("EXPUNGE") }.isEmpty)

        // HALF 2 — a later drain converges. Bounded, not pinned: convergence
        // within a few drains IS the property; the exact count is the mechanism.
        var retryDrains = 0
        while retryDrains < 3, try !operations(f.pool).isEmpty {
            await AccountManager.shared.drainPendingQueue()
            retryDrains += 1
        }
        let archiveAfterRetry = server.messageIDs(in: "Archive")
        #expect(
            archiveAfterRetry == ["<\(target)>"],
            "the retry did not land exactly one copy in Archive after \(retryDrains) drain(s): \(archiveAfterRetry)")
        let inboxAfterRetry = server.messageIDs(in: "INBOX")
        #expect(
            inboxAfterRetry.isEmpty,
            "the message is still in the source after the retry: \(inboxAfterRetry)")
        let afterRetryDrain = try operations(f.pool)
        #expect(
            afterRetryDrain.isEmpty,
            "the op did not retire after the move actually landed: \(afterRetryDrain.map(\.type))")
        #expect(server.wrongMessageViolations().isEmpty)

        try? await provider.disconnect()
        await finish(f)
    }

    // MARK: - A-6 — the completed-send flag producer, at the wire

    /// A-6, the OUTBOX half. `imapUserLabelGestureReachesTheWire` above pins the
    /// user-label producer; this pins the other one.
    /// `AccountManager.deleteCompletedSendAtomic` queued its `.markReplied` /
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
    /// `AccountManager.persistQueuedSend`, writes
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

    // MARK: - Round-5 M1 — a THROWN draft save must not retire its Save producer

    /// **THE INVARIANT: a provider throw on `.saveDraft` leaves the user's Save
    /// intention durably queued AND leaves the draft admissible, so the next drain
    /// actually re-attempts the push and completes it on the wire.**
    ///
    /// Both halves are load-bearing and neither alone is the fix (MIS-005). Before
    /// the round-5 fix, `DraftStore.pushDraftToServer` CAUGHT the provider throw,
    /// stamped `serverPushStatus = "unconfirmed"` and **returned normally**
    /// (`.terminalUnconfirmed`); a normal return is what `executeSingleOp`'s success
    /// path reads as completion, so it ran `PendingOperation.deleteOne` and the
    /// user's Save intention was retired after ONE ordinary network failure.
    /// Nothing re-enqueues on `serverPushStatus` (`IOS-DRAFT-011` says so outright),
    /// so only a later authored edit could ever mint a fresh producer. A thrown
    /// provider call is an ABSENCE OF EVIDENCE — none of the four exits — and
    /// shipped `07a4bb703` awaited the throwing call directly and let the queue
    /// retry it. The mirror image, "keep the op queued but leave the row
    /// `unconfirmed`", is a permanent WEDGE: the push entry guard never admits
    /// `"unconfirmed"`, so every retry would return `.notApplied` forever. Only a
    /// drain that REACHES THE WIRE distinguishes the fix from that wedge, which is
    /// why the second drain is asserted on `APPEND` commands and on the mailbox.
    ///
    /// 🚨 CORRECTED 2026-08-06. That sentence used to read *"the push entry guard
    /// admits only `nil`/`dirty`"*. The reasoning it supports is unchanged —
    /// `"unconfirmed"` is still refused — but the absolute is no longer true: the
    /// entry also admits a `"pushing"` row when this process holds no live claim on
    /// the draft (`DraftStore.reAdmitOrphanedPushingDraft`, `IOS-DRAFT-016`).
    ///
    /// **ASSERTED ON THE WIRE, deliberately.** The load-bearing assertions are the
    /// count of `APPEND` commands across the two drains and the Drafts mailbox's
    /// contents — not `serverPushStatus`, and not the disposition enum. A test that
    /// pinned the status would pin the fix's MECHANISM (MIS-015) and would stay
    /// green on any re-implementation that re-admitted the row another way while
    /// still dropping the op.
    ///
    /// Accepted residual (`IOS-DRAFT-015`): a throw whose APPEND had actually
    /// committed leaves one stray server draft. Not exercised here — this fake
    /// server refuses the command outright, so the first attempt lands nothing,
    /// which is why the mailbox holds exactly one copy at the end.
    ///
    /// RED PROOF (recorded): against the pre-fix `DraftStore` this fails on the
    /// first assertion — `operations(f.pool)` is empty after the failing drain,
    /// i.e. the durable producer was retired by a thrown call.
    @Test("A thrown draft APPEND never retires the Save producer, and the next drain lands it")
    @MainActor
    func aThrownDraftAppendKeepsItsSaveProducerAndTheNextDrainLandsIt() async throws {
        let server = FakeIMAPServer(mailboxes: ["INBOX": [], "Drafts": []])
        server.setUidValidity(10, for: "INBOX")
        server.setUidValidity(10, for: "Drafts")
        // Exactly ONE injected failure: the first APPEND is refused, every later
        // one is served normally. That is what makes "did the retry reach the
        // wire?" a decidable question rather than a tautology.
        server.failNextCommand(containing: "APPEND", message: "Injected APPEND failure")
        try server.start()
        defer { server.stop() }

        let f = try fixture(
            accountId: "closure-draft-append",
            folders: [("INBOX", .inbox, 10), ("Drafts", .drafts, 10)])
        let provider = try await registeredIMAPProvider(server: server, fixture: f)

        let draftId = "draft-append-1"
        try await f.pool.write { db in
            var draft = Draft(
                id: draftId, accountId: f.accountId, toJSON: "[]", ccJSON: "[]", bccJSON: "[]",
                subject: "closure draft", body: "draft body", replyToId: nil, isForward: false,
                editHistoryJSON: nil, createdAt: 1, updatedAt: 1,
                serverDraftId: nil, serverPushStatus: nil,
                rfc822MessageId: nil, attachmentsDirName: nil)
            draft.instanceEpoch = "E1"
            try draft.insert(db)
        }
        var save = PendingOperation(
            type: .saveDraft, messageIds: [draftId], accountId: f.accountId,
            folderPath: "Drafts", instanceEpoch: "E1", draftId: draftId)
        save.createdAt = Date().addingTimeInterval(-60)
        try insert([save], into: f.pool)

        await AccountManager.shared.drainPendingQueue()

        // HALF 1 — the intention survived the throw.
        let afterFailedDrain = try operations(f.pool)
        #expect(
            afterFailedDrain.map(\.id) == [save.id],
            """
            the Save producer was retired by a THROWN provider call — an unknown outcome retired a \
            durable user intention, which is none of the four exits — remaining ops: \
            \(afterFailedDrain.map(\.type))
            """)
        let draftsAfterFailure = server.messageIDs(in: "Drafts")
        #expect(
            draftsAfterFailure.isEmpty,
            "the refused APPEND must have landed nothing: \(draftsAfterFailure)")

        await AccountManager.shared.drainPendingQueue()

        // HALF 2 — and it was actually re-attemptable: the retry reached the wire.
        let appends = server.recordedCommands().filter { $0.uppercased().contains("APPEND") }
        #expect(
            appends.count == 2,
            """
            the second drain never issued an APPEND, so the failed attempt left the draft in a \
            state the push entry guard refuses — the op is wedged rather than retryable, and a \
            wedge never recovers by sync — APPEND commands: \(appends)
            """)
        let draftsAfterRetry = server.messageIDs(in: "Drafts")
        #expect(
            draftsAfterRetry.count == 1,
            """
            the retry did not land exactly one copy of the draft in the Drafts mailbox: \
            \(draftsAfterRetry)
            """)
        let afterRetryDrain = try operations(f.pool)
        #expect(
            afterRetryDrain.isEmpty,
            "the producer did not retire after the push actually completed: \(afterRetryDrain.map(\.type))")
        #expect(server.wrongMessageViolations().isEmpty)
        try? await provider.disconnect()
        await finish(f)
    }

    // MARK: - R12-T4 — the OTHER throw type the `.saveDraft` arm can now raise

    /// **THE INVARIANT, and it is the DELIBERATELY HELD direction — read the
    /// adjudication before "fixing" what this test pins.** A `.saveDraft` op whose
    /// provider kind is unresolvable throws `ProviderError.actionIdentityResolutionFailed`,
    /// and the drain **TERMINALIZES** that error: the durable `PendingOperation` row
    /// is DELETED. This test asserts that end state on the ASSEMBLED SYSTEM, together
    /// with the two bounds that make it acceptable — nothing reached the wire, and the
    /// user's authored text survives in the local `Draft` row and is still pushable.
    ///
    /// ⚠️ **WHY THIS TEST EXISTS AT ALL.** Round 11's `eff3ded9d` replaced a normal
    /// return with `throw ProviderError.actionIdentityResolutionFailed(draftId)`,
    /// believing the classifier would requeue. It does not — that error is the drain's
    /// drop-now signal — so the fix changed the PATH and not the OUTCOME, and three
    /// production comments plus the commit body stated the opposite. Nothing caught it,
    /// because the only test covering the new throw
    /// (`DraftGenerationSafetyTests.unknownRuntimeKindThrowsAndLostCasStillRetires`)
    /// calls `pushDraftToServer` **directly** and never runs the drain classifier, and
    /// the drain-level sibling above drives a GENERIC throw that lands in the generic
    /// requeue arm. The throw TYPE was covered by no drain-level test at all. This is
    /// that test: whatever a future round decides the disposition should be, it will
    /// now have to decide it deliberately.
    ///
    /// ⚠️ **THIS IS AN ANCHOR, NOT A BLESSING** (`MIS-026` — the two are the same
    /// artifact seen from opposite sides, told apart by asking what breaks if it goes
    /// the other way). The other way is `ProviderEvidenceUnavailable`, which requeues
    /// with `retryCount += 1` and `.haltLane`. `draftRuntimeIdentityKind(for:)` is
    /// DETERMINISTIC PER PROVIDER CLASS, so an `.unknown` kind is `.unknown` on every
    /// retry: the op would starve forever and halt its lane behind it — the wedge
    /// corollary, which is in the non-recoverable set. The held direction loses strictly
    /// less, and the loss is bounded to the queue producer. Adjudicated at
    /// `KNOWN_ISSUES.md` `IOS-QUEUE-003` item 4 and `IOS-DRAFT-018`.
    ///
    /// ⚠️ **ASSERTED ON THE END STATE, deliberately** (`MIS-015`): the durable queue's
    /// contents, the provider call log, and the `Draft` row's authored body — never the
    /// throw type, never the disposition enum, never a status column. A test that pinned
    /// the throw type would pin `eff3ded9d`'s mechanism and would have stayed green on
    /// exactly the defect that produced this item.
    @Test("An unresolvable draft provider kind retires the Save producer, and the authored text survives")
    @MainActor
    func anUnresolvableDraftKindRetiresTheProducerButNotTheAuthoredText() async throws {
        let f = try fixture(
            accountId: "closure-draft-unknown-kind",
            folders: [("INBOX", .inbox, 10), ("Drafts", .drafts, 10)])

        // A provider that is NOT one of the four concrete classes
        // `draftRuntimeIdentityKind(for:)` maps, so it resolves to `.unknown`.
        let mock = MockEmailProvider()
        await AccountManager.shared.registerProviderForTesting(
            accountId: f.accountId, provider: mock)
        defer {
            Task { await AccountManager.shared.unregisterProviderForTesting(accountId: f.accountId) }
        }

        let draftId = "draft-unknown-kind-1"
        let authored = "the user typed this and it must not vanish"
        try await f.pool.write { db in
            var draft = Draft(
                id: draftId, accountId: f.accountId, toJSON: "[]", ccJSON: "[]", bccJSON: "[]",
                subject: "closure draft", body: authored, replyToId: nil, isForward: false,
                editHistoryJSON: nil, createdAt: 1, updatedAt: 1,
                serverDraftId: nil, serverPushStatus: nil,
                rfc822MessageId: nil, attachmentsDirName: nil)
            draft.instanceEpoch = "E1"
            try draft.insert(db)
        }
        var save = PendingOperation(
            type: .saveDraft, messageIds: [draftId], accountId: f.accountId,
            folderPath: "Drafts", instanceEpoch: "E1", draftId: draftId)
        save.createdAt = Date().addingTimeInterval(-60)
        try insert([save], into: f.pool)

        // ANCHOR THE FIXTURE BEFORE ASSERTING AN ABSENCE (`MIS-030`): the producer and
        // the authored row both exist before the drain, so a later "it is gone" is a
        // statement about the drain and not about a row that was never created.
        let queuedBefore = try operations(f.pool)
        #expect(queuedBefore.map(\.id) == [save.id],
                "precondition: the Save producer is durably queued")
        let draftBefore = try await f.pool.read { try Draft.fetchOne($0, key: draftId) }
        #expect(draftBefore?.body == authored,
                "precondition: the authored text is in the local Draft row")

        await AccountManager.shared.drainPendingQueue()

        // THE HELD DISPOSITION — the durable producer is retired, not requeued.
        let remaining = try operations(f.pool)
        #expect(
            remaining.isEmpty,
            """
            the `.saveDraft` producer survived an `actionIdentityResolutionFailed` throw. \
            That is a REAL CHANGE OF DISPOSITION, not a test failure to paper over: read \
            `IOS-QUEUE-003` item 4 and `IOS-DRAFT-018` and update them, or restore the \
            terminalizing arm — remaining: \(remaining.map(\.type))
            """)

        // BOUND 1 — the throw is PRE-WIRE. Nothing was sent, so no server-side object
        // exists that the retirement could have orphaned.
        let calls = await mock.callLog
        #expect(
            calls.filter { $0.hasPrefix("saveDraft") }.isEmpty,
            "the unresolvable kind must be refused BEFORE the provider is touched: \(calls)")

        // BOUND 2 — and this is what makes the retirement survivable: the user's text
        // is still on disk, unchanged, and still pushable once the kind resolves.
        let live = try await f.pool.read { try Draft.fetchOne($0, key: draftId) }
        #expect(
            live?.body == authored,
            "the authored text was destroyed along with the producer — that would be a real data loss, not a bounded one")
        #expect(live?.serverDraftId == nil, "and nothing was recorded as pushed")

        await finish(f)
    }

    // MARK: - R13-U5 — `"pushing"` residue left INSIDE a live process

    /// **THE INVARIANT: a `.saveDraft` intention whose attempt left `"pushing"`
    /// residue behind in this same process still terminates honestly — it is either
    /// still durably queued, or it actually reached the wire. It is never retired on
    /// the residue itself.**
    ///
    /// The hole this pins, and why the launch sweep does not cover it.
    /// `performStageA` durably commits `serverPushStatus = "pushing"` before the
    /// provider call, and every in-process arm that clears it does so with a DB
    /// WRITE THAT CAN ITSELF THROW — `restorePushableAfterProviderThrow` on the
    /// provider-throw path, `applyPushCompletion` on the success path. When one of
    /// those writes throws, the error propagates, the op requeues (correct so far),
    /// and the row is left `"pushing"` **while the process runs on**. The very next
    /// drain then re-claimed the op, `pushDraftToServer`'s entry guard refused the
    /// row, `.notApplied` returned NORMALLY, and `executeOperation`'s `.saveDraft`
    /// arm fell through to `.allMembers` — so `executeSingleOp` DELETED the durable
    /// Save producer. `DraftStore.resetOrphanedPushingDrafts` runs only at launch,
    /// by which time the `PendingOperation` is already gone; the row it then flips
    /// to `"dirty"` has no producer left to re-admit. A local row state meaning "an
    /// attempt was interrupted" is an UNKNOWN, and never-drop clause 2 names a
    /// failed durable write as retryable, never provider-authoritative.
    /// (`KNOWN_ISSUES.md` `IOS-DRAFT-016`, whose original closure premise —
    /// "recoverable at the next launch" — this falsifies.)
    ///
    /// **ASSERTED THROUGH `IntentionLedger`, deliberately.** The oracle is the
    /// never-drop law itself: the recorded intention must settle `.executed` (no
    /// `PendingOperation` still carries the draft id AND the end state was reached)
    /// or be reported. A test that asserted the disposition enum, the entry guard's
    /// verdict, or `serverPushStatus == "dirty"` would pin the fix's MECHANISM
    /// (`MIS-015`) and would stay green on any re-implementation that re-admitted
    /// the row while still dropping the op. The wire assertions below are the second
    /// half of the same property: "did not drop" must not be satisfiable by "did
    /// nothing".
    ///
    /// **THE MIRROR IMAGE IS PINNED SEPARATELY** — a `"pushing"` row whose push is
    /// GENUINELY LIVE in this process must NOT be re-pushed, or this fix would
    /// duplicate a draft under a live race, which is strictly worse than the bug it
    /// closes. That direction is
    /// `DraftGenerationSafetyTests.aLivePushBlocksASecondPushForTheSameDraft`.
    ///
    /// RED PROOF (recorded): against the pre-fix `DraftStore` this fails twice —
    /// `IntentionLedger: 1/1 intention(s) UNACCOUNTED FOR (never-drop violation)`
    /// with `stillQueued=false endStateAchieved=false`, and zero `APPEND` commands
    /// on the wire.
    @Test("A draft push orphaned INSIDE a live process keeps its Save producer and reaches the wire")
    @MainActor
    func inProcessPushingResidueNeverRetiresItsSaveProducer() async throws {
        let server = FakeIMAPServer(mailboxes: ["INBOX": [], "Drafts": []])
        server.setUidValidity(10, for: "INBOX")
        server.setUidValidity(10, for: "Drafts")
        try server.start()
        defer { server.stop() }

        let f = try fixture(
            accountId: "closure-draft-residue",
            folders: [("INBOX", .inbox, 10), ("Drafts", .drafts, 10)])
        let provider = try await registeredIMAPProvider(server: server, fixture: f)

        let draftId = "draft-residue-1"
        let authored = "the user typed this and it must reach the server"
        try await f.pool.write { db in
            var draft = Draft(
                id: draftId, accountId: f.accountId, toJSON: "[]", ccJSON: "[]", bccJSON: "[]",
                subject: "closure draft", body: authored, replyToId: nil, isForward: false,
                editHistoryJSON: nil, createdAt: 1, updatedAt: 1,
                serverDraftId: nil, serverPushStatus: nil,
                rfc822MessageId: nil, attachmentsDirName: nil)
            draft.instanceEpoch = "E1"
            // EXACTLY the state Stage A commits before the provider call, left behind
            // by an in-process arm whose own write threw. `serverDraftId` stays nil
            // because that attempt never reached `applyPushCompletion`.
            draft.serverPushStatus = "pushing"
            draft.pushAttemptVersion = 1
            draft.rfc822MessageId = "draft-interrupted@example.com"
            try draft.insert(db)
        }
        var save = PendingOperation(
            type: .saveDraft, messageIds: [draftId], accountId: f.accountId,
            folderPath: "Drafts", instanceEpoch: "E1", draftId: draftId)
        save.createdAt = Date().addingTimeInterval(-60)
        try insert([save], into: f.pool)

        // ANCHOR THE FIXTURE BEFORE ASSERTING ANYTHING ABOUT IT (`MIS-030`): the
        // producer exists, and the server holds nothing, so a later "one copy
        // landed" is a statement about this drain.
        #expect(try operations(f.pool).map(\.id) == [save.id],
                "precondition: the Save producer is durably queued")
        #expect(server.messageIDs(in: "Drafts").isEmpty,
                "precondition: the interrupted attempt landed nothing")

        let ledger = IntentionLedger()
        ledger.record(label: "saveDraft \(draftId)", durableIdentity: draftId) { db in
            try Draft.fetchOne(db, key: draftId)?.serverPushStatus == "pushed"
        }
        #expect(ledger.recordedCount == 1)

        await AccountManager.shared.drainPendingQueue()

        // THE INVARIANT — the never-drop law, mechanised. Pre-fix this settles
        // `.unaccounted`: the op is gone and the end state was never reached.
        await ledger.settle(pool: f.pool, reportedIds: [])

        // AND "DID NOT DROP" MUST NOT BE SATISFIABLE BY "DID NOTHING".
        let appends = server.recordedCommands().filter { $0.uppercased().contains("APPEND") }
        #expect(
            appends.count == 1,
            """
            the drain never issued an APPEND — the `"pushing"` residue left the draft in a state \
            the push entry guard refuses, so the user's Save reached neither the wire nor a \
            surviving queue entry — APPEND commands: \(appends)
            """)
        let landed = server.messageIDs(in: "Drafts")
        #expect(
            landed.count == 1,
            "the retry did not land exactly one copy of the draft in the Drafts mailbox: \(landed)")
        let live = try await f.pool.read { try Draft.fetchOne($0, key: draftId) }
        #expect(live?.body == authored, "the authored text must survive the re-admission")
        #expect(server.wrongMessageViolations().isEmpty)
        try? await provider.disconnect()
        await finish(f)
    }

}
