/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Testing
@testable import TabMail

/// PORT — v2final's claim-time UIDVALIDITY refusal, adapted to the reduced
/// provider-native `.imap(folder:uidValidity:uid:)` delete tuple. Compatibility
/// and RFC fallback cases are SUBTRACTED.
@Suite("Draft delete epoch boundary", .serialized, .processGlobalState)
@MainActor
struct DraftDeleteEpochBoundaryTests {
    private static let e1 = 810_001
    private static let e2 = 810_002

    private func fixture(
        accountId: String
    ) throws -> (pool: DatabasePool, directory: URL, previous: AppDatabase?) {
        let (pool, directory, previous) = try FolderEpochTestFixture.makeAppDB()
        _ = try FolderEpochTestFixture.makeAccount(
            id: accountId, provider: .imap, pool: pool)
        try FolderEpochTestFixture.insertFolder(
            accountId: accountId, path: "Drafts", role: .drafts, pool: pool,
            lastKnownUidValidity: Self.e1)
        return (pool, directory, previous)
    }

    private func finish(
        _ fixture: (pool: DatabasePool, directory: URL, previous: AppDatabase?)
    ) {
        AppDatabase.shared.withLock { $0 = fixture.previous }
        TestDatabaseTeardown.retire(
            pool: fixture.pool, directory: fixture.directory)
    }

    private func message(uid: Int, id: String) -> FakeIMAPServer.Message {
        FakeIMAPServer.makeMessage(uid: uid, rfc822Text: """
        From: Sender <sender@example.com>\r
        To: Recipient <recipient@example.com>\r
        Subject: draft\r
        Message-ID: <\(id)>\r
        Content-Type: text/plain\r
        \r
        body\r

        """)
    }

    private func provider(_ server: FakeIMAPServer) -> IMAPProvider {
        IMAPProvider(
            host: "127.0.0.1", port: server.port,
            username: server.username, password: server.password,
            smtpHost: "127.0.0.1", smtpPort: 587, useTLS: false)
    }

    private func drainUntilSettled(_ pool: DatabasePool) async {
        for _ in 0..<60 {
            await AccountManager.shared.drainPendingQueue()
            let remaining = (try? await pool.read {
                try PendingOperation.fetchCount($0)
            }) ?? 1
            let quiescent = await AccountManager.shared.pendingQueueIsQuiescentForTesting()
            if remaining == 0, quiescent { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test("A queued E1 IMAP delete never reaches the provider after E2 turnover")
    func staleQueuedDeleteIsDroppedBeforeProvider() async throws {
        let accountId = "draft-delete-stale"
        let fixture = try fixture(accountId: accountId)
        defer { finish(fixture) }
        let stranger = "stranger@example.com"
        let server = FakeIMAPServer(mailboxes: [
            "Drafts": [message(uid: 5150, id: stranger)],
        ])
        server.setUidValidity(Self.e2, for: "Drafts")
        try server.start()
        defer { server.stop() }
        let provider = provider(server)
        try await provider.connect()
        defer { Task { try? await provider.disconnect() } }

        #expect(await AccountManager.shared.queueDraftDelete(
            identity: .imap(folder: "Drafts", uidValidity: Self.e1, uid: 5150),
            accountId: accountId,
            folderPath: "Drafts"))
        #expect(try await fixture.pool.read {
            try PendingOperation.fetchCount($0)
        } == 1)
        let liveEpoch = Self.e2
        try await fixture.pool.write { db in
            try db.execute(
                sql: "UPDATE folder SET lastKnownUidValidity = ? WHERE id = ?",
                arguments: [liveEpoch, "\(accountId):Drafts"])
        }

        let commandsBeforeDrain = server.recordedCommands()
        await AccountManager.shared.registerProviderForTesting(
            accountId: accountId, provider: provider)
        await drainUntilSettled(fixture.pool)
        await AccountManager.shared.unregisterProviderForTesting(accountId: accountId)

        #expect(server.messageIDs(in: "Drafts") == ["<\(stranger)>"])
        #expect(server.recordedCommands() == commandsBeforeDrain)
        #expect(server.wrongMessageViolations().isEmpty)
        #expect(try await fixture.pool.read {
            try PendingOperation.fetchCount($0)
        } == 0)
    }

    @Test("An unchanged IMAP epoch still executes the addressed delete")
    func unchangedEpochExecutesDelete() async throws {
        let accountId = "draft-delete-live"
        let fixture = try fixture(accountId: accountId)
        defer { finish(fixture) }
        let target = "target@example.com"
        let server = FakeIMAPServer(mailboxes: [
            "Drafts": [message(uid: 5151, id: target)],
        ])
        server.setUidValidity(Self.e1, for: "Drafts")
        server.expectMutation(rfc822MessageId: target)
        try server.start()
        defer { server.stop() }
        let provider = provider(server)
        try await provider.connect()
        defer { Task { try? await provider.disconnect() } }

        #expect(await AccountManager.shared.queueDraftDelete(
            identity: .imap(folder: "Drafts", uidValidity: Self.e1, uid: 5151),
            accountId: accountId,
            folderPath: "Drafts"))
        await AccountManager.shared.registerProviderForTesting(
            accountId: accountId, provider: provider)
        await drainUntilSettled(fixture.pool)
        await AccountManager.shared.unregisterProviderForTesting(accountId: accountId)

        #expect(server.messageIDs(in: "Drafts").isEmpty)
        #expect(server.wrongMessageViolations().isEmpty)
        #expect(try await fixture.pool.read {
            try PendingOperation.fetchCount($0)
        } == 0)
    }

    /// PORT — the reused-UID local-header/body refusal invariant of the v2final
    /// hazard commit `a189814cc` ("Harden the IMAP Drafts-header PK delete
    /// against UID-collision wrong-deletes"): after a UIDVALIDITY turnover the
    /// composite PK `accountId:folderPath:<uid>` can address a DIFFERENT
    /// physical message, so a stale delete must remove NEITHER the local header
    /// nor its body — and must not queue an op for it either.
    ///
    /// SUBTRACT — the reference closed that hazard with `DraftHeaderDeleteGate`'s
    /// canonical-RFC uniqueness term, which its own comment classifies as a
    /// pre-F2b PRECURSOR that "proves LOCAL uniqueness — NOT physical-draft
    /// identity across a UIDVALIDITY reset" and defers the sound closure to
    /// "F2b's owner-before-delete (instanceEpoch) A/B predicate". v3 carries
    /// exactly that epoch-correlated evidence in the address itself
    /// (`.imap(folder:uidValidity:uid:)` checked against
    /// `Folder.lastKnownUidValidity`), so the uniqueness machinery — and with
    /// it the RFC-group fallback and the calendar-only admission abort — is not
    /// ported.
    ///
    /// This test PROVES the existing boundary; it does not create it. There is
    /// no red proof: production is already correct, and manufacturing a failure
    /// would require breaking it.
    @Test("A stale E1 IMAP delete cannot remove a reused-UID E2 header or body or queue an operation")
    func staleEpochCannotRemoveReusedUidHeaderOrBody() async throws {
        let accountId = "draft-delete-reused-uid"
        let fixture = try fixture(accountId: accountId)
        defer { finish(fixture) }
        let reusedUid = 5152
        let headerId = MessageIdentity.headerId(
            accountId: accountId, folderPath: "Drafts", messageId: String(reusedUid))
        // Byte-identical to the key `queueDraftDelete` would delete under.
        let bodyKey = ContentKey(rawValue: headerId)
        let occupantHTML = "<p>E2 occupant — a different physical message</p>"
        // Hoisted out of the `@Sendable` writer closures — same idiom as
        // `liveEpoch` above; `Self.e2` is main-actor isolated.
        let liveEpoch = Self.e2

        // The mailbox was recreated: folder authority is E2, and the numeric UID
        // the stale E1 caller still holds is now occupied by an E2 message.
        try await fixture.pool.write { db in
            try db.execute(
                sql: "UPDATE folder SET lastKnownUidValidity = ? WHERE id = ?",
                arguments: [liveEpoch, "\(accountId):Drafts"])
        }
        try FolderEpochTestFixture.insertHeaders(
            accountId: accountId, path: "Drafts", uids: [reusedUid], pool: fixture.pool)
        try await fixture.pool.write { db in
            try db.execute(
                sql: "UPDATE messageHeader SET observedUidValidity = ? WHERE id = ?",
                arguments: [liveEpoch, headerId])
            try MessageBody(contentKey: bodyKey, htmlContent: occupantHTML).insert(db)
        }
        let occupantBefore = try await fixture.pool.read { db in
            try MessageHeader.fetchOne(db, key: headerId)
        }
        #expect(occupantBefore != nil,
                "precondition: an E2 message occupies the reused UID")

        // The stale E1 caller addresses that very UID.
        let admitted = await AccountManager.shared.queueDraftDelete(
            identity: .imap(folder: "Drafts", uidValidity: Self.e1, uid: reusedUid),
            accountId: accountId,
            folderPath: "Drafts")

        #expect(admitted == false,
                "a stale-epoch address must be refused at admission")
        let occupantAfter = try await fixture.pool.read { db in
            try MessageHeader.fetchOne(db, key: headerId)
        }
        #expect(occupantAfter != nil,
                "the E2 header at the reused UID must survive")
        #expect(occupantAfter == occupantBefore,
                "the E2 header at the reused UID must be untouched")
        let bodyAfter = try await fixture.pool.read { db in
            try MessageBody.fetchOne(db, key: bodyKey)
        }
        #expect(bodyAfter?.htmlContent == occupantHTML,
                "the E2 body at the reused UID must survive")
        #expect(try await fixture.pool.read {
            try PendingOperation.fetchCount($0)
        } == 0,
                "a refused admission must leave no durable operation behind")
    }
}
