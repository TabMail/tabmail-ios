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
            try UserLabel(id: "urgent", accountId: f.accountId, name: "Urgent", isSystem: false)
                .insert(db)
        }

        let model = UserLabelMenuModel(messageSnapshot: MessageSnapshot(from: storedHeader))
        model.supportsRemoteUserLabels = true
        let applied = await model.applyLabel(
            UserLabel(id: "urgent", accountId: f.accountId, name: "Urgent", isSystem: false))
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

    /// B-1. Both of `IMAPProvider.move`'s refusals — no UIDPLUS advertised, and
    /// a COPYUID the server declined to send — threw
    /// `ProviderError.actionIdentityResolutionFailed`, which lands in a drain
    /// arm that DELETES the op. Every premise in that arm's comment was
    /// `.deleteDraft`-specific. `v1.6.38` called `server.move` and this worked
    /// on non-UIDPLUS servers, so the effect was that upgrading silently
    /// discarded archives on exactly the servers least able to prove anything.
    ///
    /// ACCEPTED COST, documented at the production site: each retry re-issues
    /// the COPY, so such a server accumulates an unproven duplicate at the
    /// destination while the source stays intact. Duplicated mail is
    /// recoverable; a silently discarded archive is not.
    ///
    /// RED PROOF (recorded): restoring
    /// `throw ProviderError.actionIdentityResolutionFailed` on the no-UIDPLUS
    /// gate fails this at `after.count == 1` — the row is deleted by the generic
    /// identity-resolution arm.
    @Test("A move on a server that cannot prove COPYUID keeps the op queued")
    @MainActor
    func unprovableMoveKeepsTheOpQueued() async throws {
        let target = "unprovable-move@example.com"
        let server = FakeIMAPServer(
            capabilities: FakeIMAPServer.defaultCapabilities.filter { $0 != "UIDPLUS" },
            mailboxes: [
                "INBOX": [Self.message(uid: 77, id: target)],
                "Archive": [],
            ])
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
            "a server that cannot furnish COPYUID has told us nothing about whether the move should happen — the intention must survive"
        )
        guard after.count == 1 else {
            try? await provider.disconnect()
            await finish(f)
            return
        }
        #expect(after[0].id == op.id)
        #expect(after[0].status == PendingStatus.queued.rawValue)
        // The source is untouched, so nothing was lost by refusing.
        #expect(server.messageIDs(in: "INBOX") == ["<\(target)>"])
        #expect(server.wrongMessageViolations().isEmpty)
        try? await provider.disconnect()
        await finish(f)
    }

    // MARK: - B-2 — retirement is per member, never per batch

    /// B-2. When COPYUID named only SOME of the requested UIDs, `move` returned
    /// normally and the drain retired the WHOLE op as provider success. The
    /// members COPYUID never named were never moved, are still in the source
    /// folder, and their move was thrown away — a silent partial loss that no
    /// later sync recovers, because the durable row is gone.
    ///
    /// THE PROPERTY: the provider received a mutation for every still-live
    /// member. Asserted across TWO drains against the server's own mailbox
    /// contents, so it holds regardless of how retirement is implemented.
    ///
    /// RED PROOF (recorded): making `IMAPProvider.move` return `ids` instead of
    /// the proven subset — the pre-fix whole-batch retirement — fails this at
    /// the second drain: `Work` still contains the withheld member and the queue
    /// is empty, so nothing will ever move it.
    @Test("A partial COPYUID retires only the proven member and re-queues the rest")
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

        // The unproven member's intention survives.
        let after = try operations(f.pool)
        #expect(
            after.count == 1,
            "the member COPYUID never named was not moved — its intention must remain: \(after.map(\.messageIds))"
        )
        guard after.count == 1 else {
            try? await provider.disconnect()
            await finish(f)
            return
        }
        #expect(
            after[0].messageIds == ["82"],
            "retirement is per member: the proven one is done, the unproven one is not"
        )
        // The proven member really did leave the source; the unproven one did not.
        #expect(!server.messageIDs(in: "INBOX").contains("<\(proven)>"))
        #expect(server.messageIDs(in: "INBOX").contains("<\(withheld)>"))
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
    /// window, where refusing to queue is the specified behaviour and there is no
    /// wire effect to assert.
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
}
