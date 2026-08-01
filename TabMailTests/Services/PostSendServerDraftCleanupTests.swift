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
/// queued could only be refused, burn `SyncConfig.maxUidResolutionRetries`, and
/// be deleted as "confirmed stale" — a confirmation no server ever gave. The
/// optimistic local removal had already happened, so the next Drafts sync
/// re-fetched the draft and it came back as a permanent duplicate of the message
/// the user had just sent.
///
/// The closure is `OutboxMessage.draftRfc822MessageId` (v71): the DRAFT's own
/// RFC 822 Message-ID, snapshotted at queue-send time from the same caller
/// snapshot as `serverDraftId`, so both backstops can name the Drafts copy by an
/// identity that survives any renumbering. ⚠ NOT `sentMessageId` — that belongs
/// to the message SMTP delivered, which the Drafts copy never carries.
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
        draftRfc822: String?,
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
        msg.draftRfc822MessageId = draftRfc822
        let toInsert = msg
        try pool.write { db in try toInsert.insert(db) }
    }

    /// The server-synced Drafts header the user was looking at — the row a legacy
    /// outbox message (queued before the v71 snapshot existed) can still be resolved
    /// through, because it carries the draft's Message-ID next to its UID.
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

    @MainActor
    private static func withRegisteredProvider(
        accountId: String, provider: any EmailProvider, _ body: () async throws -> Void
    ) async rethrows {
        await AccountManager.shared.registerProviderForTesting(accountId: accountId, provider: provider)
        defer { Task { await AccountManager.shared.unregisterProviderForTesting(accountId: accountId) } }
        try await body()
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
        server.expectMutation(rfc822MessageId: draftRfc822)
        try server.start()
        defer { server.stop() }

        // `saveDraft` handed the outbox a BARE UID as the server draft id. That is the
        // ordinary shape on IMAP, and on its own it is unusable for a destructive
        // command.
        try Self.insertCompletedSend(
            accountId: accountId, serverDraftId: "\(draftUID)",
            draftRfc822: draftRfc822, pool: pool)

        let provider = Self.provider(for: server)
        try await provider.connect()
        defer { Task { try? await provider.disconnect() } }

        await Self.withRegisteredProvider(accountId: accountId, provider: provider) {
            await AccountManager.shared.reconcileOutbox()
            await Self.drainUntilSettled(pool)
        }

        #expect(server.messageIDs(in: "Drafts").isEmpty,
                """
                the draft the user just sent is STILL in the server's Drafts folder \
                (it holds \(server.messageIDs(in: "Drafts"))). The post-send cleanup had \
                only the bare UID \(draftUID) to work with, which `IMAPProvider.deleteDraft` \
                refuses as an ADDRESS rather than an identity, so the durable op was \
                refused, burned its retry budget and was deleted as "confirmed stale" — a \
                confirmation no server gave. The local header was already removed \
                optimistically, so the next Drafts sync brings this back as a permanent \
                duplicate of the sent message.
                """)
        #expect(server.wrongMessageViolations().isEmpty,
                "the cleanup mutated a message the send never named: \(server.wrongMessageViolations())")
        let remaining = try await pool.read { db in try PendingOperation.fetchAll(db) }
        #expect(remaining.isEmpty,
                "the cleanup op neither completed nor terminated — it is parked, which wedges this lane")
    }

    // MARK: - 2. The legacy row (no snapshot to inherit)

    @Test("A pre-v71 outbox row still resolves its draft through the synced header")
    @MainActor
    func legacyOutboxRowAdoptsTheIdentityFromTheServerHeader() async throws {
        // An outbox row queued before `draftRfc822MessageId` existed carries only the
        // UID, and there is no `Draft` row left to read. Dropping the cleanup here
        // would leave the same permanent duplicate as the defect above, for the whole
        // population of rows that were in flight across the upgrade. The server-synced
        // Drafts header for that very UID already carries the draft's Message-ID, so
        // the admission site adopts it — the same resolution `queueDraftSave` applies
        // to the same gap.
        let accountId = "post-send-legacy"
        let draftRfc822 = "legacy-draft-identity@example.com"
        let draftUID = 4712
        let (pool, dir, previous) = try Self.makeFixture(accountId: accountId)
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }

        let server = FakeIMAPServer(mailboxes: [
            "INBOX": [],
            "Drafts": [Self.message(uid: draftUID, id: draftRfc822)],
        ])
        server.expectMutation(rfc822MessageId: draftRfc822)
        try server.start()
        defer { server.stop() }

        try Self.insertServerDraftHeader(
            accountId: accountId, uid: draftUID, rfc822MessageId: draftRfc822, pool: pool)
        try Self.insertCompletedSend(
            accountId: accountId, serverDraftId: "\(draftUID)",
            draftRfc822: nil, pool: pool)

        let provider = Self.provider(for: server)
        try await provider.connect()
        defer { Task { try? await provider.disconnect() } }

        await Self.withRegisteredProvider(accountId: accountId, provider: provider) {
            await AccountManager.shared.reconcileOutbox()
            await Self.drainUntilSettled(pool)
        }

        #expect(server.messageIDs(in: "Drafts").isEmpty,
                """
                a legacy outbox row with no captured rfc822 left its draft on the server \
                (Drafts holds \(server.messageIDs(in: "Drafts"))) even though the synced \
                header for UID \(draftUID) carried the draft's Message-ID all along.
                """)
        #expect(server.wrongMessageViolations().isEmpty)
    }

    // MARK: - 3. An unexecutable op must not block the ops behind it

    @Test("A draft delete nothing can resolve does not stall the deletes queued after it")
    @MainActor
    func anUnresolvableDeleteDoesNotHoldUpTheLane() async throws {
        // The classification half. A bare-UID `.deleteDraft` that the provider refuses
        // WITHOUT touching the wire is a deterministic verdict: the same string is
        // refused on every future drain. Treating it as a UID-RESOLUTION failure — the
        // "the SEARCH ran and matched nothing, which can be transient" signal — spends
        // the dedicated retry budget on it and halts the account's lane for each of
        // those passes, so every draft delete queued behind it waits three drains for
        // an answer that was already final. The user-visible property is here: the
        // delete that CAN be resolved happens, on the same pass, regardless.
        let accountId = "post-send-headofline"
        let unresolvableUID = 4713
        let resolvableRfc822 = "second-draft-behind-it@example.com"
        let resolvableUID = 4714
        let (pool, dir, previous) = try Self.makeFixture(accountId: accountId)
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }

        let server = FakeIMAPServer(mailboxes: [
            "INBOX": [],
            "Drafts": [
                Self.message(uid: unresolvableUID, id: "first-draft-no-identity@example.com"),
                Self.message(uid: resolvableUID, id: resolvableRfc822),
            ],
        ])
        server.expectMutation(rfc822MessageId: resolvableRfc822)
        try server.start()
        defer { server.stop() }

        // First: an op carrying nothing but an address — no rfc822 anywhere to adopt,
        // so nothing can ever resolve it.
        await AccountManager.shared.queueDraftDelete(
            serverDraftId: "\(unresolvableUID)", accountId: accountId)
        // Second: an ordinary delete with the identity present.
        await AccountManager.shared.queueDraftDelete(
            serverDraftId: "\(resolvableUID)", accountId: accountId,
            rfc822MessageId: resolvableRfc822)

        let provider = Self.provider(for: server)
        try await provider.connect()
        defer { Task { try? await provider.disconnect() } }

        await Self.withRegisteredProvider(accountId: accountId, provider: provider) {
            // ONE pass. Under the old classification the first op halts the lane here
            // and the second is not even attempted.
            await AccountManager.shared.drainPendingQueue()
        }

        #expect(!server.messageIDs(in: "Drafts").contains("<\(resolvableRfc822)>"),
                """
                the second draft delete never ran (Drafts still holds \
                \(server.messageIDs(in: "Drafts"))). An op the provider refused without \
                touching the wire is a FINAL answer, not a transient miss, and must not \
                hold the account's lane while it pretends to retry.
                """)
        #expect(server.wrongMessageViolations().isEmpty,
                "a delete landed on a message no gesture named: \(server.wrongMessageViolations())")
    }
}
