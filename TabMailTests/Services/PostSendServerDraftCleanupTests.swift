/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

/// 🚨 THE SYSTEM PROPERTY: **once a send completes, the copy it left in the
/// server's Drafts folder is actually gone.**
///
/// Asserted against a real `FakeIMAPServer` through a real `IMAPProvider` and a
/// real `drainPendingQueue`, so what is measured is the state of the SERVER —
/// not `PendingOperation.messageIds`, not whether some field is non-nil. A test
/// that asserted "the op carries an rfc822" would pin the fix's mechanism and
/// stay green on any later rewrite that carried the id and still failed to use
/// it; the only thing that matters is whether the draft survives.
///
/// **The defect this pins (confirmed 2026-08-01).** `IMAPProvider.saveDraft`
/// returns a BARE NUMERIC UID as the draft's `serverDraftId`, and a UID is a
/// mutable ADDRESS — `IMAPProvider.deleteDraft` refuses to build a destructive
/// command from one, because after a renumber it names a different message
/// (constraint C3). The post-send cleanup backstops
/// (`AccountManager.finalizeOutboxMessage` and the crash-recovery sweep in
/// `reconcileOutbox`) had nothing BUT that UID to hand `queueDraftDelete`: the
/// local `Draft` row is deleted before the first one runs, and the second runs
/// in a process where it never existed. So the durable `.deleteDraft` they
/// queued could only be refused and
/// be deleted as "confirmed stale" — a confirmation no server ever gave. The
/// optimistic local removal had already happened, so the next Drafts sync
/// re-fetched the draft and it came back as a permanent duplicate of the message
/// the user had just sent.
///
/// The closure WAS `OutboxMessage.draftRfc822MessageId` (v71): the DRAFT's own
/// RFC 822 Message-ID, snapshotted at queue-send time from the same caller
/// snapshot as `serverDraftId`, so both backstops could name the Drafts copy by
/// an identity that survives any renumbering. ⚠ NOT `sentMessageId` — that
/// belonged to the message SMTP delivered, which the Drafts copy never carries.
///
/// `e0d3d30e0` ("Bind draft mutations to provider UID, epoch, and generation")
/// superseded that identity-first scheme with the strong address+epoch arm, and
/// the property was deleted 2026-08-05 once a census showed no production reader
/// (the v71 COLUMN stays — migrations are immutable once applied). The cases
/// below are unchanged and still assert exactly the same wire invariants: they
/// never depended on the snapshot, which is precisely how it went dead unnoticed.
///
/// **…and identity alone was never enough.** A Message-ID is not unique across a
/// Drafts folder, and a bare UID is an address in a numbering nothing recorded, so
/// the cases below also pin the two ways this cleanup can mutate the WRONG message:
/// adopting the identity of whatever row occupies a stale address, and deleting a
/// legitimate same-Message-ID sibling once the gesture's own target has gone.
/// `OutboxMessage.draftServerUidValidity` (v72) is what closes the second —
/// `v2final` carries the same pair of columns, added by two separate migrations for
/// exactly this reason.
///
/// `.serialized, .processGlobalState` — replaces `AppDatabase.shared`, drives the
/// shared `AccountManager`'s provider registry and drain, and the fake binds a
/// listening socket (parallel suites would contend on ephemeral ports).
@Suite("A sent draft is really removed from the server", .serialized, .processGlobalState)
struct PostSendServerDraftCleanupTests {

    private static let draftsEpoch = 820_001

    private static func rfc822(messageId: String) -> String {
        """
        From: Test Sender <sender@example.com>\r
        To: Recipient <recipient@example.com>\r
        Subject: post-send cleanup\r
        Date: Thu, 01 Jan 2026 00:00:00 +0000\r
        Message-ID: <\(messageId)>\r
        Content-Type: text/plain; charset=utf-8\r
        \r
        draft body.\r

        """
    }

    private static func message(uid: Int, id: String) -> FakeIMAPServer.Message {
        FakeIMAPServer.makeMessage(uid: uid, rfc822Text: rfc822(messageId: id))
    }

    private static func provider(for server: FakeIMAPServer) -> IMAPProvider {
        IMAPProvider(
            host: "127.0.0.1",
            port: server.port,
            username: server.username,
            password: server.password,
            smtpHost: "127.0.0.1",
            smtpPort: 587,
            useTLS: false
        )
    }

    /// One IMAP account whose Drafts folder is stamped with a KNOWN epoch, so the
    /// unknown-epoch admission guard in `queueDraftDelete` is not what any of these
    /// cases ends up measuring.
    @MainActor
    private static func makeFixture(
        accountId: String
    ) throws -> (pool: DatabasePool, dir: URL, previous: AppDatabase?) {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        _ = try FolderEpochTestFixture.makeAccount(id: accountId, provider: .imap, pool: pool)
        try FolderEpochTestFixture.insertFolder(
            accountId: accountId, path: "INBOX", role: .inbox, pool: pool,
            lastKnownUidValidity: draftsEpoch)
        try FolderEpochTestFixture.insertFolder(
            accountId: accountId, path: "Drafts", role: .drafts, pool: pool,
            lastKnownUidValidity: draftsEpoch)
        return (pool, dir, previous)
    }

    /// A fully-completed send, exactly as `reconcileOutbox` finds it after a crash:
    /// claimed (`sending`), SMTP done (`sentAt`), Sent-append done — the state whose
    /// only remaining work is removing the server-side draft.
    private static func insertCompletedSend(
        accountId: String,
        serverDraftId: String,
        draftUidValidity: Int? = nil,
        draftServerFolderPath: String? = nil,
        pool: DatabasePool
    ) throws {
        var msg = OutboxMessage(
            accountId: accountId,
            draft: DraftMessage(to: ["recipient@example.com"], subject: "post-send cleanup",
                                body: "sent already")
        )
        msg.status = OutboxStatus.sending.rawValue
        msg.sentAt = Date()
        msg.appendedToSent = true
        msg.sentMessageId = "sent-message-not-the-draft@example.com"
        msg.serverDraftId = serverDraftId
        msg.draftServerUidValidity = draftUidValidity
        msg.draftServerFolderPath = draftServerFolderPath
        let toInsert = msg
        try pool.write { db in try toInsert.insert(db) }
    }

    /// The server-synced Drafts header sitting at the primary key
    /// `accountId:folderPath:serverDraftId`. Its `rfc822MessageId` is a parameter on
    /// purpose: whether that row IS the gesture's target or a STRANGER occupying a
    /// reused UID is the whole variable these cases turn on.
    private static func insertServerDraftHeader(
        accountId: String, uid: Int, rfc822MessageId: String?, pool: DatabasePool
    ) throws {
        try pool.write { db in
            var header = MessageHeader(
                messageId: "\(uid)", subject: "post-send cleanup", from: "Test Sender",
                fromAddress: "sender@example.com", to: "recipient@example.com",
                date: Date(timeIntervalSince1970: 1_700_000_000), snippet: "draft body.",
                folderId: "\(accountId):Drafts", accountId: accountId, folderPath: "Drafts",
                isInInbox: false
            )
            header.rfc822MessageId = rfc822MessageId
            header.headerComplete = true
            try header.insert(db)
        }
    }

    /// Drain until the queue is EMPTY *and* no drain is in flight, or the bound is
    /// exhausted. A single `drainPendingQueue()` silently under-tests: both
    /// `queueDraftDelete` and `reconcileOutbox` end with unstructured `Task { … }`
    /// work, and the `isDraining` guard turns a call that races one into an
    /// immediate return. Copied from `DraftDeleteEpochBoundaryTests` for the same
    /// reason it exists there.
    @MainActor
    private static func drainUntilSettled(_ pool: DatabasePool) async {
        for _ in 0..<60 {
            await AccountManager.shared.drainPendingQueue()
            let remaining = (try? await pool.read { db in try PendingOperation.fetchCount(db) }) ?? 1
            let quiescent = await AccountManager.shared.pendingQueueIsQuiescentForTesting()
            if remaining == 0 && quiescent { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    // MARK: - 1. The invariant

    @Test("After a completed send, the draft it left on the server is gone")
    @MainActor
    func completedSendRemovesTheServerDraft() async throws {
        let accountId = "post-send-cleanup"
        let draftRfc822 = "post-send-draft@example.com"
        let draftUID = 4711
        let (pool, dir, previous) = try Self.makeFixture(accountId: accountId)
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }

        let server = FakeIMAPServer(mailboxes: [
            "INBOX": [],
            "Drafts": [Self.message(uid: draftUID, id: draftRfc822)],
        ])
        server.setUidValidity(Self.draftsEpoch, for: "Drafts")
        server.expectMutation(rfc822MessageId: draftRfc822)
        try server.start()
        defer { server.stop() }

        // PORT — model the UID + UIDVALIDITY pair v2final snapshots from `Draft`.
        // ⚑ NO REFERENCE — INVENTED adaptation: the current provider-native tuple also
        // snapshots the exact mailbox. v2final resolves the Drafts role later and has no
        // persisted folder field; the v3 address must keep the UID in its minted space.
        try Self.insertCompletedSend(
            accountId: accountId, serverDraftId: "\(draftUID)",
            draftUidValidity: Self.draftsEpoch,
            draftServerFolderPath: "Drafts",
            pool: pool)

        let provider = Self.provider(for: server)
        try await provider.connect()
        defer { Task { try? await provider.disconnect() } }

        await TestProviderRegistry.withRegisteredProvider(accountId: accountId, provider: provider) {
            await AccountManager.shared.reconcileOutbox()
            await Self.drainUntilSettled(pool)
        }

        #expect(server.messageIDs(in: "Drafts").isEmpty,
                """
                the draft the user just sent is STILL in the server's Drafts folder \
                (it holds \(server.messageIDs(in: "Drafts"))). The completed-send row \
                carried the exact Drafts/UIDVALIDITY/UID address, so its durable cleanup \
                should have deleted that exact server draft. The next Drafts sync would \
                otherwise bring it back as a duplicate of the sent message.
                """)
        #expect(server.wrongMessageViolations().isEmpty,
                "the cleanup mutated a message the send never named: \(server.wrongMessageViolations())")
        let remaining = try await pool.read { db in try PendingOperation.fetchAll(db) }
        #expect(remaining.isEmpty,
                "the cleanup op neither completed nor terminated — it is parked, which wedges this lane")
    }

    // MARK: - 2. The legacy row: a delete with no identity of its own

    @Test("A delete with no identity of its own never adopts the one at its stale address")
    @MainActor
    func aDeleteWithNoIdentityNeverAdoptsTheOneAtItsStaleAddress() async throws {
        // 🚨 THE INVARIANT: **no mutation lands on a message whose identity differs from
        // the gesture's target.**
        //
        // ⚠ THIS TEST REPLACES ONE THAT BLESSED A DEFECT.
        // `legacyOutboxRowAdoptsTheIdentityFromTheServerHeader` asserted the OUTCOME of a
        // "LEGACY RESCUE" in `queueDraftDelete`: when the caller had no rfc822, the
        // admission site read the `MessageHeader` sitting at the primary key
        // `accountId:folderPath:serverDraftId` and ADOPTED that row's Message-ID as the
        // delete's identity. It seeded that PK row with the CORRECT identity, so it never
        // crossed the only case that matters — the row at the PK being a DIFFERENT
        // message — and it therefore reported success on code that could destroy a
        // stranger. Reproducing its scenario proves nothing about the rescue's safety;
        // this case reproduces the crossing instead.
        //
        // WHY THE PK CAN NAME A STRANGER. `serverDraftId` is, on IMAP, a bare UID: an
        // address scoped to one `(folderPath, UIDVALIDITY)` pair, and nothing in the
        // `outboxMessage` row records the epoch it was minted under. A UIDVALIDITY reset
        // purges `messageHeader` rows but deliberately PRESERVES `draft`/`outboxMessage`
        // rows, so a delayed cleanup still names an address from the discarded numbering;
        // resync then puts an UNRELATED draft at that number. (`draftsFolderPath`'s
        // literal `"Drafts"` fallback reaching a real mailbox before folder-list sync
        // assigns the role elsewhere produces the same crossing without any reset.)
        //
        // Here the gesture targets a draft that had NO Message-ID and is already gone;
        // the address it left behind now belongs to someone else's draft. Adopting that
        // stranger's identity and resolving it by SEARCH ends in `STORE \Deleted` + `UID
        // EXPUNGE` on the stranger. Refusing costs the user nothing they can see.
        let accountId = "post-send-legacy"
        let strangerRfc822 = "unrelated-occupant@example.com"
        let gestureTarget = "the-rfc-less-draft-that-is-already-gone@example.com"
        let reusedUID = 4712
        let (pool, dir, previous) = try Self.makeFixture(accountId: accountId)
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }

        // The Drafts folder now holds ONE message, and it is not the one the gesture
        // means: an unrelated draft that resync placed at the reused UID.
        let server = FakeIMAPServer(mailboxes: [
            "INBOX": [],
            "Drafts": [Self.message(uid: reusedUID, id: strangerRfc822)],
        ])
        server.setUidValidity(Self.draftsEpoch, for: "Drafts")
        // The oracle is armed with the GESTURE'S target, so any mutation touching the
        // stranger is reported as a wrong-message mutation on the wire.
        server.expectMutation(rfc822MessageId: gestureTarget)
        try server.start()
        defer { server.stop() }

        // The local header at that PK is the STRANGER's — this is the whole crossing.
        try Self.insertServerDraftHeader(
            accountId: accountId, uid: reusedUID, rfc822MessageId: strangerRfc822, pool: pool)
        // …and the cleanup that names the address, with no identity of its own to give.
        try Self.insertCompletedSend(
            accountId: accountId, serverDraftId: "\(reusedUID)", pool: pool)

        let provider = Self.provider(for: server)
        try await provider.connect()
        defer { Task { try? await provider.disconnect() } }

        await TestProviderRegistry.withRegisteredProvider(accountId: accountId, provider: provider) {
            await AccountManager.shared.reconcileOutbox()
            await Self.drainUntilSettled(pool)
        }

        #expect(server.messageIDs(in: "Drafts") == ["<\(strangerRfc822)>"],
                """
                the unrelated draft occupying the reused UID \(reusedUID) was destroyed \
                (Drafts holds \(server.messageIDs(in: "Drafts"))). The cleanup carried no \
                identity of its own, so the only way it could resolve anything is by \
                adopting the identity of whatever row happened to sit at its stale \
                address — which is a different message. Failing closed here leaves a \
                draft the user can still see and still delete; adopting destroys mail \
                they never gestured on (C3).
                """)
        #expect(server.wrongMessageViolations().isEmpty,
                "a mutation landed on a message the gesture never named: \(server.wrongMessageViolations())")
        let remaining = try await pool.read { db in try PendingOperation.fetchAll(db) }
        #expect(remaining.isEmpty,
                "the unresolvable cleanup is parked rather than terminated, which wedges this lane")
    }

    // MARK: - 2b. The same-Message-ID sibling

    @Test("A post-send cleanup whose own draft is gone never deletes a same-Message-ID sibling")
    @MainActor
    func aCleanupWhoseTargetIsGoneNeverDeletesASameRfcSibling() async throws {
        // 🚨 THE INVARIANT: **when the gesture's target is gone, a same-Message-ID
        // sibling is not deleted.**
        //
        // Two distinct drafts may legitimately carry the same rfc822 Message-ID — a copy,
        // another client's save. v2final's legacy RFC arm refuses 2+ exact matches, but
        // that refusal only holds while BOTH are present. Here the send gesture named A
        // (UID 10) and another client removed A before the post-send cleanup ran. An
        // identity-only SEARCH would find exactly one match — B, the sibling at UID 11 —
        // and delete the wrong copy. The provider-ID port must never enter that arm.
        //
        // The closure is the epoch: `OutboxMessage.draftServerUidValidity` (v72) carries
        // the UIDVALIDITY that UID 10 was MINTED under, so the delete resolves through the
        // STRONG arm — SELECT's live epoch must equal it, then FETCH UID 10 — and an
        // absent FETCH is a clean no-op. B is never a candidate. This is exactly what
        // `v2final` records on its own `v85` migration; v71's rfc822 column alone was
        // never the closure.
        let accountId = "post-send-sibling"
        let sharedRfc822 = "shared-draft-identity@example.com"
        let sentDraftUID = 10        // A — the copy this send actually named
        let siblingUID = 11          // B — a legitimate sibling sharing the Message-ID
        let (pool, dir, previous) = try Self.makeFixture(accountId: accountId)
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }

        // A is already gone — another client deleted it. Only B remains. The strong
        // cleanup must FETCH A's exact UID, observe absence, and never SEARCH for B.
        let server = FakeIMAPServer(mailboxes: [
            "INBOX": [],
            "Drafts": [Self.message(uid: siblingUID, id: sharedRfc822)],
        ])
        server.setUidValidity(Self.draftsEpoch, for: "Drafts")
        try server.start()
        defer { server.stop() }

        try Self.insertCompletedSend(
            accountId: accountId, serverDraftId: "\(sentDraftUID)",
            draftUidValidity: Self.draftsEpoch,
            draftServerFolderPath: "Drafts",
            pool: pool)

        let provider = Self.provider(for: server)
        try await provider.connect()
        defer { Task { try? await provider.disconnect() } }

        await TestProviderRegistry.withRegisteredProvider(accountId: accountId, provider: provider) {
            await AccountManager.shared.reconcileOutbox()
            await Self.drainUntilSettled(pool)
        }

        // Non-vacuity: the post-send handoff reached the provider with A's exact UID.
        // Without this assertion, a missing folder/epoch makes the cleanup fail closed
        // before the wire and the sibling-survival assertion becomes green-always.
        #expect(server.recordedCommands().contains {
            $0.uppercased().hasPrefix("UID FETCH \(sentDraftUID) ")
        }, "the cleanup never addressed its intended UID \(sentDraftUID)")

        // ⚠ The mutation oracle keys on rfc822 Message-ID and CANNOT see this one: both
        // copies carry the same id, so a mutation on the sibling looks expected to it.
        // The observation has to be the sibling's own survival, by UID.
        #expect(server.messageIDs(in: "Drafts") == ["<\(sharedRfc822)>"],
                """
                the sibling draft at UID \(siblingUID) was destroyed (Drafts holds \
                \(server.messageIDs(in: "Drafts"))). The cleanup named UID \(sentDraftUID), \
                which was already gone; resolving it by Message-ID alone found the only \
                remaining exact match and deleted it. A Message-ID is not unique across a \
                Drafts folder, so identity alone can never establish that a survivor IS \
                the copy the gesture named.
                """)
        #expect(!server.flags(in: "Drafts", uid: siblingUID).contains("\\Deleted"),
                """
                the sibling at UID \(siblingUID) was marked \\Deleted (flags: \
                \(server.flags(in: "Drafts", uid: siblingUID))). A soft delete on a message \
                the gesture never named is still a wrong-message mutation — it is the \
                recorded intent to destroy it, which the next UIDPLUS-capable client \
                completes.
                """)
        let remaining = try await pool.read { db in try PendingOperation.fetchAll(db) }
        #expect(remaining.isEmpty,
                "the cleanup neither completed nor terminated — it is parked, which wedges this lane")
    }

}
