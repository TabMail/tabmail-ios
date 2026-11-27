/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Synchronization
import Testing
@testable import TabMail

/// THE ADDRESS PROBLEM, closed: a move changes the message's address, the
/// server hands us the new one in `COPYUID`, and the drain now applies it to
/// the local row instead of discarding it.
///
/// Every test here asserts a SYSTEM PROPERTY — what the user can still do to
/// the message, and what reached the wire — never the mechanism. In
/// particular, none of them assert "the stamp is non-nil"; a test written that
/// way inherits the spec error it was meant to catch.
@Suite("Finish the move locally", .serialized, .processGlobalState)
struct FinishTheMoveLocallyTests {
    private struct Fixture {
        let pool: DatabasePool
        let directory: URL
        let previous: AppDatabase?
        let accountId: String
    }

    /// Folders are `(path, role, lastKnownUidValidity)`.
    @MainActor
    private func fixture(
        accountId: String,
        folders: [(String, FolderRole, Int?)] = [
            ("INBOX", .inbox, 10), ("Archive", .archive, 10), ("Trash", .trash, 10),
        ]
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
                emailAddress: "address@example.com", displayName: "Address", provider: .imap)
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

    private static func rfc822(messageId: String) -> String {
        """
        From: Sender <sender@example.com>\r
        To: Receiver <receiver@example.com>\r
        Subject: address\r
        Date: Thu, 01 Jan 2026 00:00:00 +0000\r
        Message-ID: <\(messageId)>\r
        Content-Type: text/plain; charset=utf-8\r
        \r
        address body\r

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

    /// The local header a swipe acts on, seeded as sync would leave it: at its
    /// source address, stamped with the source folder's live epoch.
    @discardableResult
    private func seedHeader(
        _ fixture: Fixture, uid: Int, rfc: String,
        folderPath: String = "INBOX", epoch: Int? = 10
    ) throws -> MessageHeader {
        var header = MessageHeader(
            messageId: String(uid),
            subject: "address \(uid)",
            from: "Sender",
            fromAddress: "sender@example.com",
            to: "address@example.com",
            date: Date(),
            snippet: "address body",
            folderId: MessageIdentity.folderId(
                accountId: fixture.accountId, folderPath: folderPath),
            accountId: fixture.accountId,
            folderPath: folderPath,
            isInInbox: folderPath == "INBOX")
        header.rfc822MessageId = rfc
        header.observedUidValidity = epoch
        let seeded = header
        try fixture.pool.writeWithoutTransaction { db in try seeded.insert(db) }
        return seeded
    }

    /// Drain until the queue is empty AND no drain is in flight. Ported from
    /// `ProviderIdQueueFuzzTests.drainProviderQueue` — the quiescence read comes
    /// FIRST so the barrier cannot re-arm itself.
    @MainActor
    private func drainToQuiescence(_ fixture: Fixture) async throws {
        for _ in 0..<300 {
            let isEmpty = try await fixture.pool.read { db in
                try PendingOperation.fetchCount(db) == 0
            }
            let isQuiescent = await AccountManager.shared.pendingQueueIsQuiescentForTesting()
            if isEmpty && isQuiescent { return }
            if isQuiescent && !isEmpty {
                await AccountManager.shared.drainPendingQueue()
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func rows(_ fixture: Fixture) throws -> [MessageHeader] {
        try fixture.pool.read { db in
            try MessageHeader.order(Column("id").asc).fetchAll(db)
        }
    }

    // MARK: - THE HEADLINE — a gesture on a just-moved message is not a dead gesture

    /// **THE PROPERTY: after a move completes, the message the user can see is
    /// still a message the user can act on.** Swipe-archive, then swipe-delete
    /// from Archive, and the delete reaches the server.
    ///
    /// It did not. `optimisticMoveToFolder` moves the row's folder but leaves
    /// its primary key and `messageId` at the SOURCE address and NILS
    /// `observedUidValidity`, and `admittedOrdinaryActionTargets` admits an IMAP
    /// row only when its epoch equals the folder's live epoch and its
    /// `messageId` parses as a positive UID. So from the instant of the first
    /// swipe the row was refused for EVERY ordinary action — silently, with no
    /// error and no queued operation — until a sync happened to repair it. That
    /// repair is conditional (it needs the remnant to be selected as stale by a
    /// UID comparison across two different address spaces, AND its rfc822
    /// Message-ID to match a new remote message) and it deliberately leaves the
    /// epoch unread even when it fires, so the second gesture stayed dead.
    ///
    /// Asserted as END STATE ON THE SERVER, so it holds regardless of how the
    /// address is repaired.
    ///
    /// RED PROOF (recorded): with `IMAPProvider.copyProvenDestinations` returning
    /// `[]` — i.e. the destination half of `COPYUID` discarded exactly as it was
    /// before this change — this fails at the `Trash` assertion: the second
    /// gesture is refused, no `PendingOperation` is ever written for it, and the
    /// message stays in Archive forever.
    @Test("A second gesture on a just-moved message still reaches the server")
    @MainActor
    func aSecondGestureOnAJustMovedMessageReachesTheServer() async throws {
        let target = "second-gesture@example.com"
        let server = FakeIMAPServer(mailboxes: [
            "INBOX": [Self.message(uid: 77, id: target)],
            "Archive": [],
            "Trash": [],
        ])
        for mailbox in ["INBOX", "Archive", "Trash"] { server.setUidValidity(10, for: mailbox) }
        server.expectMutation(rfc822MessageId: target)
        try server.start()
        defer { server.stop() }

        let f = try fixture(accountId: "address-second-gesture")
        let provider = try await registeredIMAPProvider(server: server, fixture: f)
        let seeded = try seedHeader(f, uid: 77, rfc: target)

        // GESTURE 1 — swipe-archive.
        await AccountManager.shared.move([seeded], to: "Archive")
        try await drainToQuiescence(f)
        #expect(
            server.messageIDs(in: "Archive") == ["<\(target)>"],
            "the archive itself did not happen, so the second half of this test would prove nothing")

        // GESTURE 2 — swipe-delete, on whatever row the user is now looking at.
        let afterArchive = try rows(f)
        #expect(afterArchive.count == 1)
        guard afterArchive.count == 1 else { return }
        await AccountManager.shared.move([afterArchive[0]], to: "Trash")
        try await drainToQuiescence(f)

        // THE PROPERTY.
        #expect(
            server.messageIDs(in: "Trash") == ["<\(target)>"],
            """
            the user's second gesture never reached the server — the row they were looking at was \
            refused because the move left it addressed by its SOURCE address. Trash: \
            \(server.messageIDs(in: "Trash")), Archive: \(server.messageIDs(in: "Archive"))
            """)
        #expect(server.wrongMessageViolations().isEmpty)
        try? await provider.disconnect()
        await finish(f)
    }

    // MARK: - G4 — a move the server did not name leaves no remnant

    /// **THE PROPERTY: once the destination has synced after a move whose
    /// `COPYUID` named no destination, the local destination folder is exactly
    /// the server's — every message at its real address with its epoch read —
    /// and the moved message is actionable again.**
    ///
    /// Before: the optimistic row kept its SOURCE UID with a nil epoch. Nothing
    /// could ever stamp it, so it was refused for every gesture, and sync took it
    /// as a row at that numeric UID in the destination. Here the destination
    /// already holds a DIFFERENT message at that UID, so the folder ended with a
    /// permanent inert extra row beside the real copies (`IOS-MOVE-002`).
    @Test("A move with no COPYUID leaves no remnant row once the destination syncs")
    @MainActor
    func aMoveWithNoCopyUidLeavesNoRemnantRow() async throws {
        let target = "remnant-target@example.com"
        let resident = "remnant-resident@example.com"
        let server = FakeIMAPServer(mailboxes: [
            "INBOX": [Self.message(uid: 88, id: target)],
            "Archive": [Self.message(uid: 88, id: resident)],
            "Trash": [],
        ])
        for mailbox in ["INBOX", "Archive", "Trash"] { server.setUidValidity(10, for: mailbox) }
        server.withholdCopyUID(forSourceUIDs: [88])
        server.withholdMoveCOPYUID(forSourceUIDs: [88])
        server.expectMutation(rfc822MessageId: target)
        try server.start()
        defer { server.stop() }

        let f = try fixture(accountId: "address-no-copyuid-remnant")
        let provider = try await registeredIMAPProvider(server: server, fixture: f)
        let seeded = try seedHeader(f, uid: 88, rfc: target)
        // The resident as an earlier sync of Archive left it.
        try seedHeader(f, uid: 88, rfc: resident, folderPath: "Archive")

        await AccountManager.shared.move([seeded], to: "Archive")
        try await drainToQuiescence(f)
        // NON-VACUITY: the move landed; the server only withheld where.
        #expect(Set(server.messageIDs(in: "Archive")) == ["<\(target)>", "<\(resident)>"])

        if let archive = try await f.pool.read({ db in
            try Folder.filter(Column("accountId") == f.accountId && Column("path") == "Archive")
                .fetchOne(db)
        }) {
            try await AccountManager.shared.syncEngine.syncFolderMessages(
                folder: archive, provider: provider)
        }

        // THE PROPERTY: local Archive == server Archive, every row proven.
        let serverArchive = Set(server.snapshotMessagesWithFlags(in: "Archive").map {
            "\($0.message.uid)|\($0.message.messageID)"
        })
        let local = try rows(f).filter { $0.folderPath == "Archive" }
        let localArchive = Set(local.map { "\($0.messageId)|<\($0.rfc822MessageId ?? "")>" })
        #expect(local.count == serverArchive.count && localArchive == serverArchive,
                "local Archive \(local.map(\.id)) is not the server's \(serverArchive)")
        #expect(local.allSatisfy { $0.observedUidValidity == 10 },
                "a row in Archive has an unread epoch: \(local.map { ($0.id, $0.observedUidValidity) })")

        // And the moved message takes a gesture again.
        let moved = local.filter { $0.rfc822MessageId == target }
        #expect(moved.count == 1)
        if moved.count == 1 {
            await AccountManager.shared.move(moved, to: "Trash")
            try await drainToQuiescence(f)
            #expect(server.messageIDs(in: "Trash") == ["<\(target)>"])
            #expect(server.messageIDs(in: "Archive") == ["<\(resident)>"])
        }
        #expect(server.wrongMessageViolations().isEmpty)
        try? await provider.disconnect()
        await finish(f)
    }

    // MARK: - A lost reply, a sync, then the retry

    /// The move's first attempt only, which fails and leaves the op queued.
    /// `move` starts its own drain, and a second drain request made while that
    /// one runs is merged into a redrain that retries at once, so this asks for
    /// no drain: it waits until the move's own drain has tried the op and let
    /// it go.
    @MainActor
    private func waitForTheFailedFirstAttempt(_ fixture: Fixture) async throws {
        for _ in 0..<300 {
            let op = try await fixture.pool.read { db in try PendingOperation.fetchOne(db) }
            let quiescent = await AccountManager.shared.pendingQueueIsQuiescentForTesting()
            guard let op else { break }
            if op.everAttempted && op.status == PendingStatus.queued.rawValue && quiescent { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let kept = try await fixture.pool.read { db in try PendingOperation.fetchAll(db) }
        let keptAfterOneAttempt = kept.count == 1 && kept.allSatisfy(\.everAttempted)
        #expect(keptAfterOneAttempt,
                "precondition: the first attempt's reply was lost, so the op must still be queued: \(kept.map { ($0.id, $0.everAttempted, $0.status) })")
    }

    /// The catch-up run the normal sync path makes after the drain. The drop's
    /// write owed both folders a listing (ADR-IOS-111 item 11); this is the
    /// listing that loads a copy the window does not reach. The completed
    /// move's 30 s protection has lapsed by then, as in production. The run
    /// needs the account registered with the engine that makes it (it returns
    /// at once for an account it has no work queue for), so it runs on an
    /// engine of its own, as `IMAPMoveIntoTrackedFolderTests` does.
    @MainActor
    private func runOwedCatchUp(_ fixture: Fixture, provider: IMAPProvider) async throws {
        await AccountManager.shared.clearRecentlyCompletedForTesting()
        let account = try await fixture.pool.read { db in try Account.fetchOne(db, key: fixture.accountId) }
        guard let account else {
            Issue.record("the fixture's account is missing")
            return
        }
        let engine = SyncEngine()
        await engine.register(accountId: fixture.accountId, provider: provider,
                              workQueue: ProviderWorkQueue(provider: provider, maxConcurrency: SyncConfig.imapMaxConnectionCeiling))
        let ran = await engine.runCatchUpRun(
            account: account, run: .snapshot(deadline: Date().addingTimeInterval(30)))
        #expect(ran, "precondition: the catch-up run made no progress, so it loaded nothing")
    }

    /// The moved messages not yet stored in local Archive.
    private func missingFromArchive(_ fixture: Fixture, _ targets: [String]) throws -> [String] {
        let stored = Set(try rows(fixture).filter { $0.folderPath == "Archive" }.compactMap(\.rfc822MessageId))
        return targets.filter { !stored.contains($0) }
    }

    @MainActor
    private func syncArchive(_ fixture: Fixture, provider: IMAPProvider) async throws {
        if let archive = try await fixture.pool.read({ db in
            try Folder.filter(Column("accountId") == fixture.accountId && Column("path") == "Archive")
                .fetchOne(db)
        }) {
            try await AccountManager.shared.syncEngine.syncFolderMessages(folder: archive, provider: provider)
        }
    }

    /// **THE PROPERTY: every message a move copied ends up stored in the
    /// destination even when the attempt that copied it lost its reply, a sync
    /// of the destination then stored newer rows, and only the retry retired
    /// the move.** More copies than the window holds, so the ones it does not
    /// reach are stored by the catch-up the drop owed the folder.
    @Test("A lost MOVE reply, then a destination sync, then the retry: every copy is stored")
    @MainActor
    func aLostReplyThenASyncThenTheRetryStoresEveryCopy() async throws {
        let movedCount = SyncConfig.syncMessageLimit + 10
        let sourceUids = (0..<movedCount).map { 5000 + $0 }
        let targets = sourceUids.map { "lost-reply-\($0)@example.com" }
        let residentUids = Array(1...10)
        let residents = residentUids.map { "lost-reply-resident-\($0)@example.com" }
        let server = FakeIMAPServer(mailboxes: [
            "INBOX": zip(sourceUids, targets).map { Self.message(uid: $0, id: $1) },
            "Archive": zip(residentUids, residents).map { Self.message(uid: $0, id: $1) },
            "Trash": [],
        ])
        for mailbox in ["INBOX", "Archive", "Trash"] { server.setUidValidity(10, for: mailbox) }
        server.withholdCopyUID(forSourceUIDs: Set(sourceUids))
        server.withholdMoveCOPYUID(forSourceUIDs: Set(sourceUids))
        server.disconnectAfterNextUIDMoveCommit()
        server.expectMutations(targets)
        try server.start()
        defer { server.stop() }

        let f = try fixture(accountId: "address-lost-reply-retry")
        let provider = try await registeredIMAPProvider(server: server, fixture: f)
        var seeded: [MessageHeader] = []
        for (uid, rfc) in zip(sourceUids, targets) { seeded.append(try seedHeader(f, uid: uid, rfc: rfc)) }
        for (uid, rfc) in zip(residentUids, residents) {
            try seedHeader(f, uid: uid, rfc: rfc, folderPath: "Archive")
        }
        try await f.pool.write { db in
            _ = try Folder.filter(Column("accountId") == f.accountId)
                .updateAll(db, Column("backfillComplete").set(to: true))
            _ = try Folder.filter(Column("accountId") == f.accountId && Column("path") == "Archive")
                .updateAll(db, Column("backfillUidCursor").set(to: 1))
        }

        await AccountManager.shared.move(seeded, to: "Archive")
        try await waitForTheFailedFirstAttempt(f)
        // NON-VACUITY: attempt 1 committed every copy on the server.
        #expect(server.messageIDs(in: "Archive").count == movedCount + residentUids.count)

        // A window sync of Archive stores the newest copies (above the oldest).
        try await syncArchive(f, provider: provider)

        // The retry retires the move with no destination named.
        try await drainToQuiescence(f)
        // NON-VACUITY: the window alone does not reach every copy.
        #expect(!(try missingFromArchive(f, targets)).isEmpty,
                "precondition: every copy is stored before the catch-up, so it is not exercised")
        try await runOwedCatchUp(f, provider: provider)

        // THE PROPERTY: local Archive is the server's Archive.
        let serverArchive = Set(server.snapshotMessagesWithFlags(in: "Archive").map {
            "\($0.message.uid)|\($0.message.messageID)"
        })
        let local = try rows(f).filter { $0.folderPath == "Archive" }
        let localArchive = Set(local.map { "\($0.messageId)|<\($0.rfc822MessageId ?? "")>" })
        let localRfcs = Set(local.compactMap(\.rfc822MessageId))
        let missing = targets.filter { !localRfcs.contains($0) }
        #expect(missing.isEmpty, "\(missing.count) of \(movedCount) copies are absent from local Archive")
        #expect(local.count == serverArchive.count && localArchive == serverArchive,
                "local Archive (\(local.count) rows) is not the server's (\(serverArchive.count))")
        #expect(local.allSatisfy { $0.observedUidValidity == 10 })
        #expect(server.wrongMessageViolations().isEmpty)
        try? await provider.disconnect()
        await finish(f)
    }

    /// **THE PROPERTY: AI content survives a no-COPYUID move even when a sync
    /// stored the copy before the move's retry dropped the optimistic row.**
    /// The copy's row then exists before the AI handoff reaches the cache, so
    /// no insert restores it; the drop's own write fills it.
    @Test("A copy stored before the drop still gets the moved message's AI content")
    @MainActor
    func aCopyStoredBeforeTheDropGetsTheAIContent() async throws {
        let target = "lost-reply-ai@example.com"
        let server = FakeIMAPServer(mailboxes: [
            "INBOX": [Self.message(uid: 88, id: target)],
            "Archive": [Self.message(uid: 3, id: "lost-reply-ai-resident@example.com")],
            "Trash": [],
        ])
        for mailbox in ["INBOX", "Archive", "Trash"] { server.setUidValidity(10, for: mailbox) }
        server.withholdCopyUID(forSourceUIDs: [88])
        server.withholdMoveCOPYUID(forSourceUIDs: [88])
        server.disconnectAfterNextUIDMoveCommit()
        server.expectMutation(rfc822MessageId: target)
        try server.start()
        defer { server.stop() }

        let f = try fixture(accountId: "address-lost-reply-ai")
        let provider = try await registeredIMAPProvider(server: server, fixture: f)
        var seeded = try seedHeader(f, uid: 88, rfc: target)
        seeded.summaryBlurb = "summary of the moved message"
        seeded.summaryTodos = "todo of the moved message"
        seeded.reminderDate = "2099-01-02"
        seeded.reminderTime = "09:30"
        seeded.reminderContent = "reminder of the moved message"
        seeded.cachedReply = "reply to the moved message"
        let summarized = seeded
        try await f.pool.write { db in try summarized.update(db) }

        await AccountManager.shared.move([summarized], to: "Archive")
        try await waitForTheFailedFirstAttempt(f)
        try await syncArchive(f, provider: provider)
        // NON-VACUITY: the sync stored the copy before the retry, beside the
        // optimistic row, and with no AI content (the cache held none yet), so
        // only the drop's own write can fill it.
        let storedBefore = try rows(f).filter {
            $0.folderPath == "Archive" && $0.rfc822MessageId == target && $0.id != summarized.id
        }
        let storedWithoutAI = storedBefore.count == 1
            && storedBefore.allSatisfy { $0.summaryBlurb == nil && $0.cachedReply == nil }
        #expect(storedWithoutAI,
                "precondition: the copy is not stored exactly once without AI content before the retry: \(storedBefore.map(\.id))")
        try await drainToQuiescence(f)
        try await syncArchive(f, provider: provider)

        let all = try rows(f)
        let moved = all.filter { $0.folderPath == "Archive" && $0.rfc822MessageId == target }
        #expect(moved.count == 1, "the moved message is not in local Archive exactly once: \(all.map(\.id))")
        guard moved.count == 1 else { return }
        #expect(moved[0].observedUidValidity == 10)
        #expect(moved[0].summaryBlurb == "summary of the moved message")
        #expect(moved[0].summaryTodos == "todo of the moved message")
        #expect(moved[0].reminderDate == "2099-01-02")
        #expect(moved[0].reminderTime == "09:30")
        #expect(moved[0].reminderContent == "reminder of the moved message")
        #expect(moved[0].cachedReply == "reply to the moved message")
        #expect(server.wrongMessageViolations().isEmpty)
        try? await provider.disconnect()
        await finish(f)
    }

    /// **THE PROPERTY: existing AI content survives a move whatever the server
    /// reports about the destination.** The COPYUID path keeps it by re-keying
    /// the row; a move with no COPYUID drops the row, so its AI state must reach
    /// the row the destination sync inserts.
    @Test("A move with no COPYUID keeps the message's AI content in the destination")
    @MainActor
    func aMoveWithNoCopyUidKeepsItsAIContent() async throws {
        let target = "remnant-ai-target@example.com"
        let server = FakeIMAPServer(mailboxes: [
            "INBOX": [Self.message(uid: 88, id: target)],
            "Archive": [Self.message(uid: 3, id: "remnant-ai-resident@example.com")],
            "Trash": [],
        ])
        for mailbox in ["INBOX", "Archive", "Trash"] { server.setUidValidity(10, for: mailbox) }
        server.withholdCopyUID(forSourceUIDs: [88])
        server.withholdMoveCOPYUID(forSourceUIDs: [88])
        server.expectMutation(rfc822MessageId: target)
        try server.start()
        defer { server.stop() }

        let f = try fixture(accountId: "address-no-copyuid-ai-content")
        let provider = try await registeredIMAPProvider(server: server, fixture: f)
        var seeded = try seedHeader(f, uid: 88, rfc: target)
        seeded.summaryBlurb = "summary of the moved message"
        seeded.summaryTodos = "todo of the moved message"
        seeded.cachedReply = "reply to the moved message"
        seeded.reminderDate = "2099-01-02"
        seeded.reminderTime = "09:30"
        seeded.reminderContent = "reminder of the moved message"
        let summarized = seeded
        // As the AI path leaves it: on the row, and in the cache under the
        // folder the row was in when the AI ran.
        try await f.pool.write { db in
            try summarized.update(db)
            try MessageAICache.writeThrough(
                accountId: f.accountId, folderPath: "INBOX", rfc822MessageId: target,
                summaryBlurb: summarized.summaryBlurb, summaryTodos: summarized.summaryTodos,
                reminderDate: summarized.reminderDate, reminderTime: summarized.reminderTime,
                reminderContent: summarized.reminderContent,
                cachedReply: summarized.cachedReply, db: db)
        }

        await AccountManager.shared.move([summarized], to: "Archive")
        try await drainToQuiescence(f)
        // NON-VACUITY: the move landed; the server only withheld where.
        #expect(server.messageIDs(in: "Archive").contains("<\(target)>"))

        let all = try rows(f)
        let moved = all.filter { $0.folderPath == "Archive" && $0.rfc822MessageId == target }
        #expect(moved.count == 1, "the moved message is not in local Archive: \(all.map(\.id))")
        guard moved.count == 1 else { return }
        #expect(moved[0].observedUidValidity == 10, "the row in Archive is not the synced copy")
        #expect(moved[0].summaryBlurb == "summary of the moved message")
        #expect(moved[0].summaryTodos == "todo of the moved message")
        #expect(moved[0].cachedReply == "reply to the moved message")
        #expect(moved[0].reminderDate == "2099-01-02")
        #expect(moved[0].reminderTime == "09:30")
        #expect(moved[0].reminderContent == "reminder of the moved message")
        #expect(server.wrongMessageViolations().isEmpty)
        try? await provider.disconnect()
        await finish(f)
    }

    /// **THE PROPERTY: every message of a move the server did not name is back in
    /// the destination after the normal sync path, however many there were.**
    /// The window sync reads only the newest messages and the older-mail walk is
    /// complete here (its cursor at the bottom), so the copies the window does
    /// not reach are stored by the catch-up listing the drop owed the folder
    /// (ADR-IOS-111 item 11, #1062).
    @Test("A large move with no COPYUID is complete in the destination after the drain and its catch-up")
    @MainActor
    func aLargeMoveWithNoCopyUidIsCompleteAfterTheDrain() async throws {
        let window = SyncConfig.syncMessageLimit
        let movedCount = window + 10
        let residentCount = window + 10
        let sourceUids = (0..<movedCount).map { 5000 + $0 }
        let targets = sourceUids.map { "large-move-\($0)@example.com" }
        let residentUids = Array(1...residentCount)
        let residents = residentUids.map { "large-resident-\($0)@example.com" }
        let server = FakeIMAPServer(mailboxes: [
            "INBOX": zip(sourceUids, targets).map { Self.message(uid: $0, id: $1) },
            "Archive": zip(residentUids, residents).map { Self.message(uid: $0, id: $1) },
            "Trash": [],
        ])
        for mailbox in ["INBOX", "Archive", "Trash"] { server.setUidValidity(10, for: mailbox) }
        server.withholdCopyUID(forSourceUIDs: Set(sourceUids))
        server.withholdMoveCOPYUID(forSourceUIDs: Set(sourceUids))
        for target in targets { server.expectMutation(rfc822MessageId: target) }
        try server.start()
        defer { server.stop() }

        let f = try fixture(accountId: "address-no-copyuid-large-move")
        let provider = try await registeredIMAPProvider(server: server, fixture: f)
        var seeded: [MessageHeader] = []
        for (uid, rfc) in zip(sourceUids, targets) { seeded.append(try seedHeader(f, uid: uid, rfc: rfc)) }
        for (uid, rfc) in zip(residentUids, residents) {
            try seedHeader(f, uid: uid, rfc: rfc, folderPath: "Archive")
        }
        // Every folder fully walked, as on a device that finished its fill-in;
        // Archive's walk saved its cursor at the bottom, so a resumed walk (as
        // opposed to a restarted one) would never look above it.
        try await f.pool.write { db in
            _ = try Folder.filter(Column("accountId") == f.accountId)
                .updateAll(db, Column("backfillComplete").set(to: true))
            _ = try Folder.filter(Column("accountId") == f.accountId && Column("path") == "Archive")
                .updateAll(db, Column("backfillUidCursor").set(to: 1))
        }

        await AccountManager.shared.move(seeded, to: "Archive")
        try await drainToQuiescence(f)
        // NON-VACUITY: every member landed; the server only withheld where.
        #expect(server.messageIDs(in: "Archive").count == movedCount + residentCount)
        // NON-VACUITY: the window alone does not reach every moved message.
        #expect(!(try missingFromArchive(f, targets)).isEmpty,
                "precondition: every moved message is stored before the catch-up, so it is not exercised")
        try await runOwedCatchUp(f, provider: provider)

        // THE PROPERTY: local Archive is the server's Archive — every moved
        // message present at its real address with its epoch read.
        let serverArchive = Set(server.snapshotMessagesWithFlags(in: "Archive").map {
            "\($0.message.uid)|\($0.message.messageID)"
        })
        let local = try rows(f).filter { $0.folderPath == "Archive" }
        let localArchive = Set(local.map { "\($0.messageId)|<\($0.rfc822MessageId ?? "")>" })
        let localRfcs = Set(local.compactMap(\.rfc822MessageId))
        let missing = targets.filter { !localRfcs.contains($0) }
        #expect(missing.isEmpty,
                "\(missing.count) of \(movedCount) moved messages are absent from local Archive after the drain and its catch-up")
        #expect(local.count == serverArchive.count && localArchive == serverArchive,
                "local Archive (\(local.count) rows) is not the server's (\(serverArchive.count))")
        #expect(local.allSatisfy { $0.observedUidValidity == 10 },
                "\(local.filter { $0.observedUidValidity != 10 }.count) Archive rows have an unread epoch")
        #expect(server.wrongMessageViolations().isEmpty)
        try? await provider.disconnect()
        await finish(f)
    }

    /// **THE PROPERTY: a message moved INTO the inbox gets its window-exempt AI
    /// jobs even when the server named no destination for it** — on the row the
    /// destination sync inserted, never on the message already holding the
    /// source UID there. Driven through the real drain, so the handoff from the
    /// retirement to the entered-inbox recorder is what is under test.
    @Test("A move into the inbox with no COPYUID still enqueues AI for the moved message only")
    @MainActor
    func aMoveIntoTheInboxWithNoCopyUidStillEnqueuesAI() async throws {
        let target = "remnant-inbox-target@example.com"
        let resident = "remnant-inbox-resident@example.com"
        let server = FakeIMAPServer(mailboxes: [
            "INBOX": [Self.message(uid: 88, id: resident)],
            "Archive": [Self.message(uid: 88, id: target)],
            "Trash": [],
        ])
        for mailbox in ["INBOX", "Archive", "Trash"] { server.setUidValidity(10, for: mailbox) }
        server.withholdCopyUID(forSourceUIDs: [88])
        server.withholdMoveCOPYUID(forSourceUIDs: [88])
        server.expectMutation(rfc822MessageId: target)
        try server.start()
        defer { server.stop() }

        let ai = ActiveAIQueue.shared
        await ai.setDispatchSuppressedForTesting(true)
        await ai.clearForTesting()

        let f = try fixture(accountId: "address-no-copyuid-inbox-ai")
        let provider = try await registeredIMAPProvider(server: server, fixture: f)
        let seeded = try seedHeader(f, uid: 88, rfc: target, folderPath: "Archive")

        await AccountManager.shared.move([seeded], to: "INBOX")
        try await drainToQuiescence(f)
        // NON-VACUITY: the move landed; the server only withheld where.
        #expect(Set(server.messageIDs(in: "INBOX")) == ["<\(target)>", "<\(resident)>"])

        let inbox = try rows(f).filter { $0.folderPath == "INBOX" }
        let moved = inbox.filter { $0.rfc822MessageId == target }
        #expect(moved.count == 1, "the destination sync did not insert the moved message: \(inbox.map(\.id))")
        let exempt = await ai.queuedJobsForTesting.filter { $0.windowExempt }
        #expect(Set(exempt.map(\.headerId)) == Set(moved.map(\.id)) && moved.count == 1,
                "window-exempt AI jobs \(exempt.map(\.headerId)) are not exactly the moved message \(moved.map(\.id))")
        #expect(Set(exempt.map(\.jobType)) == [.summary, .reply])
        // The source keeps its guard against a stale listing re-inserting the
        // moved message (#106): only the dropped row's rfc822 key was released.
        #expect(await AccountManager.shared.isRecentlyCompleted("88"),
                "the bare source-UID shield key was released along with the rfc822 key")
        #expect(server.wrongMessageViolations().isEmpty)
        await ai.clearForTesting()
        await ai.setDispatchSuppressedForTesting(false)
        try? await provider.disconnect()
        await finish(f)
    }

    /// **THE PROPERTY: a move the server refused outright never takes the
    /// message out of the local view.** The refusal retires the operation with
    /// no destination evidence, exactly like a move that landed without
    /// `COPYUID`, but here nothing left the source, so no destination sync will
    /// ever bring a dropped row back.
    @Test("A refused move keeps the local row")
    @MainActor
    func aRefusedMoveKeepsTheLocalRow() async throws {
        let target = "refused-move@example.com"
        let server = FakeIMAPServer(mailboxes: [
            "INBOX": [Self.message(uid: 66, id: target)],
            "Archive": [],
            "Trash": [],
        ])
        for mailbox in ["INBOX", "Archive", "Trash"] { server.setUidValidity(10, for: mailbox) }
        server.failNextCommand(containing: "UID MOVE", message: "[NOPERM] Permission denied")
        try server.start()
        defer { server.stop() }

        let f = try fixture(accountId: "address-refused-move")
        let provider = try await registeredIMAPProvider(server: server, fixture: f)
        let seeded = try seedHeader(f, uid: 66, rfc: target)

        await AccountManager.shared.move([seeded], to: "Archive")
        try await drainToQuiescence(f)
        // NON-VACUITY: the refusal was answered and the message never moved.
        #expect(server.messageIDs(in: "INBOX") == ["<\(target)>"])
        #expect(server.messageIDs(in: "Archive").isEmpty)

        let local = try rows(f).filter { $0.rfc822MessageId == target }
        #expect(local.count == 1,
                "a refused move removed the only local row of a message that never left the source")
        try? await provider.disconnect()
        await finish(f)
    }

    // MARK: - A dropped row's chat pill

    /// Gives the INBOX row at UID 88 a chat pill, then moves it to Archive on a
    /// server that names no destination. Archive already holds, at UID 4, a
    /// DIFFERENT message with the same Message-ID that this device never
    /// stored, so the copy lands at UID 5. Returns the pill's number and the
    /// dropped row's id.
    @MainActor
    private func moveAPilledRowWithNoCopyUid(
        accountId: String, target: String
    ) async throws -> (server: FakeIMAPServer, fixture: Fixture, provider: IMAPProvider, numericId: Int, oldId: String) {
        let server = FakeIMAPServer(mailboxes: [
            "INBOX": [Self.message(uid: 88, id: target)],
            "Archive": [Self.message(uid: 4, id: target)],
            "Trash": [],
        ])
        for mailbox in ["INBOX", "Archive", "Trash"] { server.setUidValidity(10, for: mailbox) }
        server.withholdCopyUID(forSourceUIDs: [88])
        server.withholdMoveCOPYUID(forSourceUIDs: [88])
        server.expectMutation(rfc822MessageId: target)
        try server.start()

        let f = try fixture(accountId: accountId)
        await ChatIdTranslator.shared.clearAll()
        let provider = try await registeredIMAPProvider(server: server, fixture: f)
        let seeded = try seedHeader(f, uid: 88, rfc: target)
        let numericId = await ChatIdTranslator.shared.toNumericId(seeded.id)

        await AccountManager.shared.move([seeded], to: "Archive")
        try await drainToQuiescence(f)
        // The pill's in-memory retirement runs on the outside-stores lane.
        await MailPointerMoves.outsideStoresSettledForTesting()
        return (server, f, provider, numericId, seeded.id)
    }

    /// The copy (UID 5) is deleted by another client and Archive syncs, so the
    /// only stored message with the moved message's Message-ID is NOT the copy.
    /// A later message arrives at UID 6 as well: without its QRESYNC model the
    /// fake reports UIDNEXT as its highest live UID plus one, so deleting the
    /// top message would lower UIDNEXT below the copy, which no real server
    /// does, and the sync rightly never judges a UID at or above UIDNEXT.
    @MainActor
    private func leaveOnlyTheSameIdNonCopy(
        _ fixture: Fixture, server: FakeIMAPServer, provider: IMAPProvider, target: String, oldId: String
    ) async throws {
        // NON-VACUITY: the move landed beside the same-id message, and the
        // remnant row is gone.
        let archiveUids = server.snapshotMessagesWithFlags(in: "Archive").map(\.message.uid).sorted()
        #expect(archiveUids == [4, 5], "the move did not land beside the same-id message: \(archiveUids)")
        let remnantKept = try rows(fixture).contains { $0.id == oldId }
        #expect(!remnantKept, "the remnant row was not dropped")
        let laterArrival = Self.message(uid: 6, id: "pill-later-arrival@example.com")
        server.setMessages(
            server.snapshotMessagesWithFlags(in: "Archive").map(\.message).filter { $0.uid != 5 } + [laterArrival],
            in: "Archive")
        try await syncArchive(fixture, provider: provider)
        let sameId = try rows(fixture).filter { $0.rfc822MessageId == target }.map(\.messageId)
        #expect(sameId == ["4"], "the only same-id row left should be the non-copy at UID 4: \(sameId)")
    }

    /// **THE PROPERTY: a dropped row's chat pill is never moved to a message by
    /// its Message-ID alone.** Without `COPYUID` nothing proves which message is
    /// the copy: here the copy is gone and the only candidate left is a
    /// different message with the same Message-ID. The pill is retired with the
    /// row, renders unavailable, and opens nothing.
    @Test("A dropped row's chat pill is never moved by Message-ID alone")
    @MainActor
    func aDroppedRowsPillIsNeverMovedByMessageIdAlone() async throws {
        let target = "pill-id-only@example.com"
        let (server, f, provider, numericId, oldId) = try await moveAPilledRowWithNoCopyUid(
            accountId: "address-pill-id-only", target: target)
        defer { server.stop() }
        try await leaveOnlyTheSameIdNonCopy(f, server: server, provider: provider, target: target, oldId: oldId)

        let realId = await ChatIdTranslator.shared.toRealId(numericId)
        #expect(realId == ChatIdTranslator.retiredRealId(numericId: numericId, realId: oldId),
                "the pill was not retired with its row: it names \(String(describing: realId))")
        let detail = await ChatIdTranslator.shared.resolveEmailDetail(numericId)
        #expect(detail == nil, "a tap on the retired pill must open nothing")
        let retired = await ChatIdTranslator.shared.isRetiredPill(numericId)
        #expect(retired, "the retired pill is not reported as retired")
        #expect(MarkdownChatText.pillIsUnavailable(isHistory: false, isRetired: retired),
                "the retired pill does not render as unavailable")
        await ChatIdTranslator.shared.clearAll()
        try? await provider.disconnect()
        await finish(f)
    }

    /// **THE PROPERTY: resuming the moved message's chat session never binds
    /// its old pill to a message by Message-ID alone.** The session's
    /// Message-ID fallback (`ChatStore.resolveMessageHeaderId`) still finds a
    /// same-id row for the session's context, but the pill was retired with
    /// the dropped row, so the resumed session's remap binds nothing.
    @Test("A resumed chat session does not rebind a dropped row's pill by Message-ID")
    @MainActor
    func aResumedSessionDoesNotRebindADroppedRowsPill() async throws {
        let target = "pill-resume@example.com"
        let (server, f, provider, numericId, oldId) = try await moveAPilledRowWithNoCopyUid(
            accountId: "address-pill-resume", target: target)
        defer { server.stop() }
        try await leaveOnlyTheSameIdNonCopy(f, server: server, provider: provider, target: target, oldId: oldId)

        // Resume the moved message's own chat session, as the chat surface does:
        // a missing primary key falls back to the session's Message-ID, then the
        // old pill is remapped onto whatever that resolved to.
        let sessionId = "msg:\(f.accountId):\(target)"
        let resolved = try await f.pool.read { db in
            try ChatStore.resolveMessageHeaderId(originalId: oldId, sessionId: sessionId, db: db)
        }
        // NON-VACUITY: the fallback finds the same-id message that is not the copy.
        let nonCopyId = try rows(f).first { $0.rfc822MessageId == target }?.id
        #expect(resolved != nil && resolved == nonCopyId)
        if let resolved {
            _ = await ChatIdTranslator.shared.remapRealId(from: oldId, to: resolved)
        }
        let realId = await ChatIdTranslator.shared.toRealId(numericId)
        #expect(realId == ChatIdTranslator.retiredRealId(numericId: numericId, realId: oldId),
                "the resumed session bound the pill to \(String(describing: realId)) by Message-ID alone")
        let detail = await ChatIdTranslator.shared.resolveEmailDetail(numericId)
        #expect(detail == nil)
        await ChatIdTranslator.shared.clearAll()
        try? await provider.disconnect()
        await finish(f)
    }

    /// **THE PROPERTY: a retired pill's number is never handed to another
    /// message, even after the translator reloads from storage.**
    @Test("A dropped row's retired pill number is not reused after a reload")
    @MainActor
    func aRetiredPillsNumberIsNotReusedAfterAReload() async throws {
        let target = "pill-reload@example.com"
        // The pill is the only, and so the highest, mapping.
        let (server, f, provider, numericId, oldId) = try await moveAPilledRowWithNoCopyUid(
            accountId: "address-pill-reload", target: target)
        defer { server.stop() }
        let remnantKept = try rows(f).contains { $0.id == oldId }
        #expect(!remnantKept, "the remnant row was not dropped")

        await ChatIdTranslator.shared.reloadFromDBForTesting()
        let other = MessageIdentity.headerId(accountId: f.accountId, folderPath: "Archive", messageId: "4")
        let otherNumeric = await ChatIdTranslator.shared.toNumericId(other)
        #expect(otherNumeric != numericId, "the retired pill's number was handed to another message")
        let detail = await ChatIdTranslator.shared.resolveEmailDetail(numericId)
        #expect(detail == nil)
        await ChatIdTranslator.shared.clearAll()
        try? await provider.disconnect()
        await finish(f)
    }

    /// **THE PROPERTY: the same address retired twice (reused after a source
    /// reset) retires both pills, and the retiring write never fails.** A
    /// failed write would abort the move's settlement and stop the queue.
    @Test("An address retired twice retires both pills without a write failure")
    @MainActor
    func anAddressRetiredTwiceRetiresBothPills() async throws {
        let f = try fixture(accountId: "address-pill-reuse")
        await ChatIdTranslator.shared.clearAll()
        let address = MessageIdentity.headerId(accountId: f.accountId, folderPath: "Archive", messageId: "88")
        // Each writer on its own: the move's write (the shared stored rewrite
        // `finishMove` runs) for the first retirement, then the translator's
        // own (its stored rewrite does the work, nothing pre-retired).
        let first = await ChatIdTranslator.shared.toNumericId(address)
        try await AppDatabase.dbPool.write { db in
            try ChatIdTranslator.retireStoredMappings(db, realId: address)
        }
        await ChatIdTranslator.shared.retireMappings(realIds: [address])
        // The address is reused by a new message, whose pill is retired in turn.
        let second = await ChatIdTranslator.shared.toNumericId(address)
        #expect(second != first)
        await ChatIdTranslator.shared.retireMappings(realIds: [address])
        // And the move's write once more, for a third reuse.
        let third = await ChatIdTranslator.shared.toNumericId(address)
        try await AppDatabase.dbPool.write { db in
            try ChatIdTranslator.retireStoredMappings(db, realId: address)
        }

        await ChatIdTranslator.shared.reloadFromDBForTesting()
        for numeric in [first, second, third] {
            let retired = await ChatIdTranslator.shared.isRetiredPill(numeric)
            #expect(retired, "pill \(numeric) was not retired")
            let detail = await ChatIdTranslator.shared.resolveEmailDetail(numeric)
            #expect(detail == nil)
        }
        await ChatIdTranslator.shared.clearAll()
        await finish(f)
    }

    /// **THE PROPERTY: a remap that lands between the retiring write and the
    /// translator's in-memory retirement does not bring the pill back.**
    @Test("A remap between the retiring write and the in-memory retirement is refused")
    @MainActor
    func aRemapBeforeTheInMemoryRetirementIsRefused() async throws {
        let f = try fixture(accountId: "address-pill-window")
        await ChatIdTranslator.shared.clearAll()
        let oldId = MessageIdentity.headerId(accountId: f.accountId, folderPath: "Archive", messageId: "88")
        let other = MessageIdentity.headerId(accountId: f.accountId, folderPath: "INBOX", messageId: "4")
        let numeric = await ChatIdTranslator.shared.toNumericId(oldId)
        // The move's retiring write, exactly as `finishMove` issues it.
        try await AppDatabase.dbPool.write { db in
            try ChatIdTranslator.retireStoredMappings(db, realId: oldId)
        }
        // A resumed session remaps before the in-memory retirement runs.
        let moved = await ChatIdTranslator.shared.remapRealId(from: oldId, to: other)
        await ChatIdTranslator.shared.retireMappings(realIds: [oldId])

        #expect(moved == 0, "the remap moved a retired pill")
        let afterRetire = await ChatIdTranslator.shared.toRealId(numeric)
        #expect(afterRetire != other)
        let stored = try await AppDatabase.dbPool.read { db in
            try String.fetchOne(db, sql: "SELECT realId FROM chatIdMapping WHERE numericId = ?", arguments: [numeric])
        }
        #expect(stored == ChatIdTranslator.retiredRealId(numericId: numeric, realId: oldId),
                "the stored mapping was rebound: \(String(describing: stored))")
        await ChatIdTranslator.shared.reloadFromDBForTesting()
        let afterReload = await ChatIdTranslator.shared.toRealId(numeric)
        #expect(afterReload != other)
        await ChatIdTranslator.shared.clearAll()
        await finish(f)
    }

    /// **THE PROPERTY: a pill whose row was re-keyed just before a move dropped
    /// it ends retired, even when the re-key's pill follow had not run yet.**
    /// A producer (a sync UID repair, a placeholder replacement) re-keys the
    /// row and hands the pill's follow to the outside-stores lane; the user
    /// moves the message before the lane reaches it, on a server that names no
    /// destination. When the follow then runs it must not leave the pill bound
    /// to the dropped row, which a later reopen heal could rebind to another
    /// message by Message-ID.
    @Test("A pill whose re-key follow is still waiting when its row is dropped ends retired")
    @MainActor
    func aPillFollowWaitingWhenItsRowIsDroppedEndsRetired() async throws {
        let target = "pill-lane@example.com"
        let server = FakeIMAPServer(mailboxes: [
            "INBOX": [Self.message(uid: 88, id: target)],
            "Archive": [],
            "Trash": [],
        ])
        for mailbox in ["INBOX", "Archive", "Trash"] { server.setUidValidity(10, for: mailbox) }
        server.withholdCopyUID(forSourceUIDs: [88])
        server.withholdMoveCOPYUID(forSourceUIDs: [88])
        server.expectMutation(rfc822MessageId: target)
        try server.start()
        defer { server.stop() }

        let f = try fixture(accountId: "address-pill-lane")
        await ChatIdTranslator.shared.clearAll()
        let provider = try await registeredIMAPProvider(server: server, fixture: f)
        let seeded = try seedHeader(f, uid: 88, rfc: target)
        // The pill was made under the row's earlier id; the re-key to the row's
        // id has committed and its pill follow waits on the lane.
        let earlierId = MessageIdentity.headerId(accountId: f.accountId, folderPath: "INBOX", messageId: "87")
        let numericId = await ChatIdTranslator.shared.toNumericId(earlierId)
        let release = MailPointerMoves.holdOutsideStoresForTesting()
        defer { release() }
        MailPointerMoves.followOutsideStoresInOrder([HeaderRekeyRecord(
            oldHeaderId: earlierId, newHeaderId: seeded.id,
            newProviderMessageId: seeded.messageId, newObservedUidValidity: 10)])

        await AccountManager.shared.move([seeded], to: "Archive")
        try await drainToQuiescence(f)
        // NON-VACUITY: the move dropped the row while the follow still waited.
        let remnantKept = try rows(f).contains { $0.id == seeded.id }
        #expect(!remnantKept, "the remnant row was not dropped")
        let waiting = await ChatIdTranslator.shared.toRealId(numericId)
        #expect(waiting == earlierId, "the lane was not held: the follow ran before the drop")

        release()
        await MailPointerMoves.outsideStoresSettledForTesting()
        let realId = await ChatIdTranslator.shared.toRealId(numericId)
        #expect(realId == ChatIdTranslator.retiredRealId(numericId: numericId, realId: seeded.id),
                "the follow left the pill bound to \(String(describing: realId)) after the drop")
        let stored = try await AppDatabase.dbPool.read { db in
            try String.fetchOne(db, sql: "SELECT realId FROM chatIdMapping WHERE numericId = ?", arguments: [numericId])
        }
        #expect(stored == ChatIdTranslator.retiredRealId(numericId: numericId, realId: seeded.id),
                "the stored mapping names \(String(describing: stored))")
        let detail = await ChatIdTranslator.shared.resolveEmailDetail(numericId)
        #expect(detail == nil, "a tap on the pill must open nothing")
        await ChatIdTranslator.shared.clearAll()
        try? await provider.disconnect()
        await finish(f)
    }

    // MARK: - G1 — a pairing that cannot be trusted is not an address

    /// **THE PROPERTY: no local row ever adopts an address from a `COPYUID`
    /// whose two lists cannot be trusted to correspond.**
    ///
    /// `CopyUID.init(nio:)` pairs the expanded source and destination lists
    /// POSITIONALLY and validates only their cardinality. While the destination
    /// half was merely sanity-checked that was harmless; as a MUTATION address
    /// it is C3-critical, because a row seated at somebody else's destination
    /// UID is CONFIRMED by later syncs rather than caught, and every subsequent
    /// gesture then lands on a message the user never selected.
    ///
    /// NON-VACUITY, both sides: the wire side proves the response really was
    /// produced and really was acted on (both copies landed), so the refusal is
    /// about the ORDERING and not about missing evidence; the durable side
    /// proves no row is seated at a foreign address.
    ///
    /// RED PROOF (recorded): deleting the `isStrictlyAscending` guard from
    /// `copyProvenDestinations` fails this at the seating assertions — both
    /// rows are re-keyed, each to the OTHER member's destination UID.
    @Test("A COPYUID whose destination list is not ascending re-keys nothing")
    @MainActor
    func aNonAscendingCopyUidRekeysNothing() async throws {
        let first = "pairing-first@example.com"
        let second = "pairing-second@example.com"
        let server = FakeIMAPServer(mailboxes: [
            "INBOX": [Self.message(uid: 21, id: first), Self.message(uid: 22, id: second)],
            "Archive": [],
            "Trash": [],
        ])
        for mailbox in ["INBOX", "Archive", "Trash"] { server.setUidValidity(10, for: mailbox) }
        server.reportCopyUIDDestinationsDescending()
        try server.start()
        defer { server.stop() }

        let f = try fixture(accountId: "address-pairing")
        let provider = try await registeredIMAPProvider(server: server, fixture: f)
        let a = try seedHeader(f, uid: 21, rfc: first)
        let b = try seedHeader(f, uid: 22, rfc: second)

        await AccountManager.shared.move([a, b], to: "Archive")
        try await drainToQuiescence(f)

        // NON-VACUITY, wire side: the move ran, and the evidence path ran with
        // it — both copies landed and the server named what it copied.
        #expect(Set(server.messageIDs(in: "Archive")) == ["<\(first)>", "<\(second)>"])

        // THE PROPERTY: no row is seated at ANOTHER member's address.
        //
        // Stated this way, and not as "nothing was re-keyed", because a later
        // sync of the destination folder legitimately re-keys each row to its
        // OWN destination UID on rfc822 evidence — that is the repair path, and
        // it pairs correctly. What must never happen is a row adopting the
        // address the OTHER member was copied to, which is precisely what
        // positional pairing of a non-corresponding COPYUID produces.
        let seated = try rows(f).reduce(into: [String: String]()) { acc, row in
            acc[row.rfc822MessageId ?? ""] = row.messageId
        }
        #expect(
            seated[first] == "21" || seated[first] == "1",
            """
            the first message is seated at \(seated[first] ?? "nothing") — it adopted an address \
            from a COPYUID whose lists are not both strictly ascending, so positional pairing \
            cannot be trusted to have matched them: \(seated)
            """)
        #expect(
            seated[second] == "22" || seated[second] == "2",
            """
            the second message is seated at \(seated[second] ?? "nothing") — it adopted an address \
            from a COPYUID whose lists are not both strictly ascending, so positional pairing \
            cannot be trusted to have matched them: \(seated)
            """)
        #expect(server.wrongMessageViolations().isEmpty)
        try? await provider.disconnect()
        await finish(f)
    }

    // MARK: - G2 — fresher than the folder is worse than unknown

    /// **THE PROPERTY: when the destination epoch the drain proved is not one
    /// this app has recorded for that folder, local finish refuses to bind that
    /// destination address.** The optimistic source-address row survives with
    /// its epoch unread, so every later provider mutation remains closed until
    /// sync supplies a corroborated address.
    ///
    /// This is the mirror-image guard. `Folder.lastKnownUidValidity` is written
    /// by sync paths alone and the drain runs ahead of them, so a drain-time
    /// stamp can leave the row FRESHER than the folder row — and
    /// `roleMoveRejectDispositions` treats a POSITIVE disagreement as
    /// `.terminalStale`, its ONLY terminal arm. Stamping optimistically would
    /// therefore TERMINALLY DROP the very next gesture, which is the exact
    /// inverse of the bug this change fixes. Leaving the stamp unread is an
    /// ABSENCE of evidence, which is retryable forever: the next sync of that
    /// folder supplies it.
    ///
    /// **Why this one is driven through `finishMove` rather than through the
    /// wire like its three siblings.** Both wire-level constructions of the
    /// disagreement are closed before `finishMove` ever sees them, and each was
    /// measured, not assumed:
    ///
    ///   * *`COPYUID` states an epoch the destination probe did not.*
    ///     `IMAPProvider.move` compares the two itself and, on disagreement,
    ///     refuses ALL source cleanup and keeps the op retryable
    ///     (`movedAcrossCopy`). Measured: the move never completes, so nothing
    ///     is ever re-keyed — the op simply re-COPIES on every drain.
    ///   * *The destination folder's epoch has genuinely turned over.* Then the
    ///     probe and `COPYUID` agree, the move completes — and the post-drain
    ///     sync of that same folder observes the turnover, runs the
    ///     purge-and-resync reaction and writes the new epoch onto the `Folder`
    ///     row. By the time the next gesture is evaluated the two agree again.
    ///     Measured: with `Archive` at `20_260_803` on the server, this test
    ///     PASSED with the guard inverted — a false green.
    ///
    /// What remains reachable in production is the window those two constructions
    /// close by accident and the app cannot rely on: the drain retires the move
    /// and re-keys the row, and the sync that would refresh the `Folder` row has
    /// not run or has failed (offline, connection error, backgrounded). That
    /// window is exactly this test's input, applied at the seam where the stamp
    /// is decided; everything after it — admission, disposition, outcome — is the
    /// real production path.
    ///
    /// RED PROOF (recorded): stamping unconditionally (dropping the
    /// `folderEpoch == …` comparison in `MessageHeaderRekey.finishMove`) fails
    /// this at the property assertion — the gesture is admitted against the
    /// wrong destination address instead of remaining retryable.
    @Test("A destination epoch the folder does not share refuses the local re-key")
    @MainActor
    func aDisagreeingDestinationEpochKeepsTheNextGestureRetryable() async throws {
        let target = "epoch-disagreement@example.com"
        let f = try fixture(accountId: "address-epoch")
        let seeded = try seedHeader(f, uid: 77, rfc: target)

        // The optimistic half of the gesture, through the production path — so
        // the row and the operation both have the exact shape the drain meets:
        // the row is already shown in `Archive` but still keyed by its SOURCE
        // address with its epoch unread, and the op names it by that address.
        // No provider is registered for this account, so nothing drains and the
        // op survives for the step below to consume.
        await AccountManager.shared.move([seeded], to: "Archive")

        // The drain's own step 3, verbatim — `finishMove` and the retirement of
        // the operation in ONE write — with a destination epoch the `Folder` row
        // (still 10, as the fixture seeded it) has never observed.
        let finishResult = try await f.pool.write { db -> MoveFinishResult in
            guard let op = try PendingOperation.fetchAll(db).first(where: { $0.type == .move })
            else { return .empty }
            let result = try MessageHeaderRekey.finishMove(
                op,
                destinations: [ProvenDestinationAddress(
                    sourceProviderId: "77", destinationProviderId: "1",
                    destinationUidValidity: 20_260_803)],
                addressChangesOnMove: true,
                // IMAP: a UID is mailbox-local, so the row is located by primary
                // key at `destinationPath` and no queued follower is re-addressed.
                accountScopedIds: false,
                copiedNothing: false, db: db)
            _ = try PendingOperation.deleteOne(db, key: op.id)
            return result
        }

        #expect(finishResult.applied.isEmpty)
        #expect(finishResult.unsafeUndoOldHeaderIds == [seeded.id])
        let afterArchive = try rows(f)
        #expect(afterArchive.count == 1)
        guard afterArchive.count == 1 else { return }
        #expect(
            afterArchive[0].id == seeded.id && afterArchive[0].messageId == "77",
            "positive epoch disagreement must not bind an uncorroborated destination address")
        #expect(afterArchive[0].observedUidValidity == nil)
        #expect(BodyAddressGate.addressIsInFlight(
            id: afterArchive[0].id,
            accountId: afterArchive[0].accountId,
            folderPath: afterArchive[0].folderPath,
            messageId: afterArchive[0].messageId))

        let outcome = await AccountManager.shared.move([afterArchive[0]], to: "Trash")

        // The surviving uncorroborated row is fail-closed: no wrong-address
        // provider operation is admitted. An unread epoch is UNKNOWN, so the
        // gesture remains retryable rather than being reported terminally stale.
        #expect(
            outcome.pendingIds == [seeded.id] && outcome.failedIds.isEmpty,
            "the next gesture must remain pending while the destination address is uncorroborated")
        await finish(f)
    }

    // MARK: - The two child tables the re-key used to destroy

    /// **THE PROPERTY: re-addressing a message does not destroy what the
    /// message IS.** Its threading references and the labels the user put on it
    /// survive the move.
    ///
    /// `messageReference` and `messageUserLabel` are both FK
    /// `onDelete: .cascade` on `messageHeader`, and the re-key deletes the row.
    /// Threading references can be REBUILT from the header's own
    /// `References`/`In-Reply-To` content, so the rebuild is exact. User labels
    /// have NO rebuild source anywhere in the database — nothing else knows
    /// which labels the user applied — so they must be carried across. Both
    /// losses are SILENT: no assertion anywhere else in the suite notices them.
    ///
    /// RED PROOF (recorded): deleting the `ThreadUtils.insertMessageReferences`
    /// call from `MessageHeaderRekey.apply` fails the references assertion;
    /// deleting the `carriedLabels` capture and re-insert fails the label
    /// assertion. Each independently.
    @Test("Threading references and user labels survive the re-key")
    @MainActor
    func childRowsSurviveTheRekey() async throws {
        let target = "children@example.com"
        let parent = "children-parent@example.com"
        let root = "children-root@example.com"
        let server = FakeIMAPServer(mailboxes: [
            "INBOX": [Self.message(uid: 77, id: target)],
            "Archive": [],
            "Trash": [],
        ])
        for mailbox in ["INBOX", "Archive", "Trash"] { server.setUidValidity(10, for: mailbox) }
        try server.start()
        defer { server.stop() }

        let f = try fixture(accountId: "address-children")
        let provider = try await registeredIMAPProvider(server: server, fixture: f)
        var header = try seedHeader(f, uid: 77, rfc: target)
        header.inReplyTo = parent
        header.referencesJSON = MessageHeader.encodeReferences([root])
        let threaded = header
        try await f.pool.write { db in
            try threaded.update(db)
            try ThreadUtils.insertMessageReferences(for: threaded, db: db)
            try UserLabel(accountId: f.accountId, providerLabelId: "work", name: "Work", isSystem: false).insert(db)
            try MessageUserLabel(messageId: threaded.id, userLabelId: "\(f.accountId):work").insert(db)
        }

        await AccountManager.shared.move([threaded], to: "Archive")
        try await drainToQuiescence(f)

        let surviving = try rows(f)
        #expect(surviving.count == 1)
        guard let moved = surviving.first else { return }
        // NON-VACUITY: the row really was re-addressed, so the child rows really
        // did have to survive a delete rather than simply never being touched.
        #expect(
            moved.id != threaded.id,
            "the row was never re-keyed, so this test proves nothing about surviving a re-key")

        let (references, labels) = try await f.pool.read { db -> ([String], [String]) in
            (
                try String.fetchAll(
                    db,
                    sql: "SELECT referencedRfc822Id FROM messageReference WHERE messageHeaderId = ?",
                    arguments: [moved.id]),
                try String.fetchAll(
                    db,
                    sql: "SELECT userLabelId FROM messageUserLabel WHERE messageId = ?",
                    arguments: [moved.id])
            )
        }
        #expect(
            Set(references) == [parent, root],
            "the move silently destroyed this message's threading references: \(references)")
        #expect(
            labels == ["\(f.accountId):work"],
            "the move silently destroyed a label the USER applied — nothing can rebuild it: \(labels)")
        #expect(server.wrongMessageViolations().isEmpty)
        try? await provider.disconnect()
        await finish(f)
    }

    // MARK: - Undo after the drain — an ordinary reverse move

    /// Push the undo entry the way the UI does: BEFORE the gesture, from a
    /// snapshot of the row at its source address. Everything the drain then does
    /// to that address has to be followed by the stack, which is the point.
    @MainActor
    private func pushUndo(_ header: MessageHeader, to destinationPath: String) {
        UndoService.shared.push(UndoableAction(
            type: .move(fromPath: header.folderPath, toPath: destinationPath),
            messages: [header],
            originalFolderId: header.folderId,
            originalFolderPath: header.folderPath,
            accountId: header.accountId,
            timestamp: Date()))
    }

    /// Undo dispatches its inverse through the write queue, so the operation it
    /// inserts is not durable the instant `undo()` returns. `awaitWriteQueueDrain`
    /// is that queue's own FIFO barrier — deterministic, not a poll — and only
    /// after it can the pending queue be drained meaningfully.
    ///
    /// A settle loop keyed on "the message is back" would be WRONG here: a move
    /// with no `COPYUID` leaves the source copy `\Deleted`-but-present, so in the
    /// negative test below that condition is already true before undo runs and
    /// the loop would exit before the undo write had landed — the test would
    /// pass without ever exercising undo.
    @MainActor
    private func settleUndo(_ fixture: Fixture) async throws {
        await AccountManager.shared.awaitWriteQueueDrain()
        try await drainToQuiescence(fixture)
    }

    /// **THE PROPERTY: undoing a move that has already reached the server puts
    /// the message back where it was — on the SERVER, not merely on screen.**
    ///
    /// Undo is just a reverse move and always was. Before this change it could
    /// not be one on IMAP for a single reason: the move had changed the
    /// message's address and nothing had recorded the new one, so undo could not
    /// NAME the message in its new folder and fell back to a closed no-op. With
    /// the drain finishing the move locally, the row already carries the
    /// destination address `COPYUID` proved, and the inverse is admitted through
    /// the same predicate as any ordinary forward gesture.
    ///
    /// Asserted as END STATE ON THE SERVER: where the mail actually is, not what
    /// the local rows or the queue say about it.
    ///
    /// RED PROOF (recorded): restoring `guard !isIMAP` in `undoMove`'s
    /// non-annihilate arm fails this — the message stays in `Archive`. So does
    /// deleting the `UndoService.applyRekeys` call from the drain, which is the
    /// sharper of the two: the re-key then invalidates the very key undo
    /// authenticates by, and undo refuses a message that IS addressable.
    @Test("Undo after the move has drained puts the message back on the server")
    @MainActor
    func undoAfterTheDrainMovesTheMessageBack() async throws {
        let target = "undo-after-drain@example.com"
        let server = FakeIMAPServer(mailboxes: [
            "INBOX": [Self.message(uid: 88, id: target)],
            "Archive": [],
            "Trash": [],
        ])
        for mailbox in ["INBOX", "Archive", "Trash"] { server.setUidValidity(10, for: mailbox) }
        try server.start()
        defer { server.stop() }

        let f = try fixture(accountId: "address-undo")
        let provider = try await registeredIMAPProvider(server: server, fixture: f)
        let seeded = try seedHeader(f, uid: 88, rfc: target)

        pushUndo(seeded, to: "Archive")
        await AccountManager.shared.move([seeded], to: "Archive")
        try await drainToQuiescence(f)

        // NON-VACUITY: the forward move really did complete on the server, so
        // what is undone below is a DRAINED move and not a queued one — the
        // annihilate branch has always handled that case and is not under test.
        #expect(server.messageIDs(in: "Archive") == ["<\(target)>"])
        #expect(server.messageIDs(in: "INBOX").isEmpty)

        await UndoService.shared.undo()
        try await settleUndo(f)

        // THE PROPERTY.
        #expect(
            server.messageIDs(in: "INBOX") == ["<\(target)>"],
            """
            undo of an already-drained move did not reach the server — the message is still \
            wherever the forward move left it. INBOX: \(server.messageIDs(in: "INBOX")), \
            Archive: \(server.messageIDs(in: "Archive"))
            """)
        #expect(server.messageIDs(in: "Archive").isEmpty)
        #expect(server.wrongMessageViolations().isEmpty)
        try? await provider.disconnect()
        await finish(f)
    }

    /// **THE PROPERTY: a member the server never named is never named by us
    /// either — undo of it changes nothing, locally or on the wire.**
    ///
    /// `COPYUID` is a MAY (RFC 4315 §3) and a mailbox property, so a server can
    /// copy a message perfectly well and report nothing about where it landed.
    /// That member is not re-keyed, its row still carries the SOURCE address
    /// with its epoch unread, and admission refuses it. The refusal is
    /// WHOLE-COMMAND and silent, and it is the accepted limitation this change
    /// registers rather than fixes: nothing is lost, the copy is still in the
    /// destination, and a later sync repairs the row.
    ///
    /// This is the negative case of the test above, and it is built so that the
    /// naive version of that fix — drop `guard !isIMAP`, queue the inverse
    /// naming the SOURCE UIDs the command already holds — is a C3 wrong-message
    /// mutation rather than a harmless no-op. `Archive` already contains an
    /// unrelated message AT THE SOURCE UID (88), so an inverse that names 88 in
    /// `Archive` moves the BYSTANDER to the inbox, and the user's undo of one
    /// message silently relocates another. Re-admitting the row through
    /// `admittedOrdinaryActionTargets` is what refuses it: the row still carries
    /// the source address with its epoch unread, and an unread epoch is an
    /// absence of evidence.
    ///
    /// RED PROOF (recorded): replacing the admission with the naive inverse
    /// (`messageIds: providerIds`, `observedUidValidity: sourceEpoch`) fails
    /// this — the bystander lands in `INBOX` and the wire oracle records the
    /// mutation against a message the gesture never selected.
    @Test("An address-changing move with no COPYUID evidence removes its unsafe undo member")
    @MainActor
    func undoDoesNothingForAMemberCopyUidNeverNamed() async throws {
        let target = "undo-unnamed@example.com"
        let bystander = "undo-bystander@example.com"
        let server = FakeIMAPServer(mailboxes: [
            "INBOX": [Self.message(uid: 88, id: target)],
            // Occupies the very UID the source address names, in the folder the
            // inverse would be issued against.
            "Archive": [Self.message(uid: 88, id: bystander)],
            "Trash": [],
        ])
        for mailbox in ["INBOX", "Archive", "Trash"] { server.setUidValidity(10, for: mailbox) }
        server.withholdCopyUID(forSourceUIDs: [88])
        server.withholdMoveCOPYUID(forSourceUIDs: [88])
        server.expectMutation(rfc822MessageId: target)
        try server.start()
        defer { server.stop() }

        let f = try fixture(accountId: "address-undo-unnamed")
        let provider = try await registeredIMAPProvider(server: server, fixture: f)
        let seeded = try seedHeader(f, uid: 88, rfc: target)

        pushUndo(seeded, to: "Archive")
        defer { UndoService.shared.dismissAll() }
        await AccountManager.shared.move([seeded], to: "Archive")
        try await drainToQuiescence(f)

        // NON-VACUITY: the copy landed. The server did the work and simply did
        // not say where — this is an evidence gap, not a failed move.
        #expect(Set(server.messageIDs(in: "Archive")) == ["<\(target)>", "<\(bystander)>"])

        #expect(
            UndoService.shared.undoStack.isEmpty,
            "an undo member with no safe destination address must not remain executable")

        // THE PROPERTY: nothing was reversed, and — the part that matters —
        // nothing can later be reversed WRONGLY with the stale source UID.
        #expect(
            Set(server.messageIDs(in: "Archive")) == ["<\(target)>", "<\(bystander)>"],
            "undo mutated in a folder where it could not name its own message")
        #expect(
            server.messageIDs(in: "INBOX").contains("<\(bystander)>") == false,
            """
            undo of a member the server never named a destination for moved a DIFFERENT message \
            that happened to hold the stale source UID: \(server.messageIDs(in: "INBOX"))
            """)
        #expect(server.wrongMessageViolations().isEmpty)
        try? await provider.disconnect()
        await finish(f)
    }

    // MARK: - W — the ordering oracle for mark-as-read-on-archive

    /// **THE PROPERTY: when "Mark as read on archive & delete" archives a
    /// message, the read reaches the server AT THE ADDRESS THE MESSAGE STILL
    /// HAS — before the move takes that address away.**
    ///
    /// This is THE ADDRESS PROBLEM applied to a composed pair. A
    /// `PendingOperation` addresses its members in the SOURCE folder, and on
    /// IMAP an address is `(folder, UID, UIDVALIDITY)`; a move changes all
    /// three. So a read op recorded AFTER the move names a UID that, in the
    /// source folder, is either gone or now somebody else's message — the
    /// wrong-message mutation C3 exists to prevent — and in the best case is
    /// simply refused, leaving the message archived but still unread.
    ///
    /// Asserted as END STATE ON THE SERVER, not as local row state and not as
    /// the shape of the queue: the archived copy carries `\Seen`. That is only
    /// reachable if the `UID STORE` ran in INBOX before the copy, because the
    /// server propagates the source flags to the destination copy at copy time.
    /// The explicit wire-order assertion below is the same fact stated
    /// directly, kept so a failure says WHICH half broke.
    ///
    /// RED PROOF (recorded): with the setting forced OFF — i.e. the composition
    /// removed, exactly the pre-feature behaviour — no `\Seen` `UID STORE` is
    /// issued at all, the archived copy has no `\Seen`, and this fails at the
    /// first assertion.
    @Test("A mark-read-on-archive read reaches the server BEFORE the move takes the address away")
    @MainActor
    func markReadOnArchiveIsIssuedAtTheSourceAddressBeforeTheMove() async throws {
        let target = "markread-before-move@example.com"
        let server = FakeIMAPServer(mailboxes: [
            "INBOX": [Self.message(uid: 55, id: target)],
            "Archive": [],
            "Trash": [],
        ])
        for mailbox in ["INBOX", "Archive", "Trash"] { server.setUidValidity(10, for: mailbox) }
        server.expectMutation(rfc822MessageId: target)
        try server.start()
        defer { server.stop() }

        UserDefaults.standard.set(true, forKey: AccountManager.markReadOnArchiveDeleteKey)
        defer { UserDefaults.standard.removeObject(forKey: AccountManager.markReadOnArchiveDeleteKey) }

        let f = try fixture(accountId: "address-markread-order")
        let provider = try await registeredIMAPProvider(server: server, fixture: f)
        let seeded = try seedHeader(f, uid: 55, rfc: target)
        #expect(seeded.isRead == false, "premise: the archived message is unread")
        #expect(
            server.flags(in: "INBOX", uid: 55).contains("\\Seen") == false,
            "premise: the server has no \\Seen on it either")

        await AccountManager.shared.performCoordinatedRoleMove(
            ids: [seeded.id], role: .archive, expectedIdentities: [:])
        try await drainToQuiescence(f)

        // NON-VACUITY: the archive itself happened, so the flag assertion below
        // is about the copy the user will actually open.
        #expect(server.messageIDs(in: "Archive") == ["<\(target)>"])

        // THE PROPERTY.
        #expect(
            server.flags(in: "Archive", rfc822MessageId: target)?.contains("\\Seen") == true,
            """
            the archived copy is still UNREAD on the server. Either the read was never issued, or \
            it was issued after the move — at which point it names an address the message no \
            longer has. Archive flags: \
            \(String(describing: server.flags(in: "Archive", rfc822MessageId: target)))
            """)

        // The same fact on the wire, so a failure names the broken half.
        let commands = server.recordedCommands()
        let seenStore = commands.firstIndex {
            let upper = $0.uppercased()
            return upper.contains("UID STORE") && upper.contains("\\SEEN")
        }
        let relocation = commands.firstIndex {
            let upper = $0.uppercased()
            return upper.contains("UID COPY") || upper.contains("UID MOVE")
        }
        #expect(seenStore != nil, "no \\Seen STORE reached the wire at all: \(commands)")
        #expect(relocation != nil, "no COPY/MOVE reached the wire at all: \(commands)")
        if let seenStore, let relocation {
            #expect(
                seenStore < relocation,
                """
                the read was issued AFTER the move — it names the source address the move already \
                invalidated: \(commands)
                """)
        }

        // C3: nothing was mutated that the gesture did not select.
        #expect(server.wrongMessageViolations().isEmpty)
        try? await provider.disconnect()
        await finish(f)
    }

    // MARK: - The retirement REPLAY publishes what the direct path publishes

    /// A GRDB `TransactionObserver` that REFUSES the commit of any transaction
    /// which wrote `messageHeader`, and counts the refusals.
    ///
    /// The same shape a full disk, an I/O error at COMMIT, or GRDB's own
    /// suspension when the app is backgrounded mid-drain produces. Copied
    /// file-private from `OutlookQueueHandoffTests` exactly as that one was
    /// copied from `QueueCoreInvariantTests` and `SyncEngineRunSyncTests`: there
    /// is no shared test utility for it and this change does not invent one.
    private final class HeaderCommitRefuser: TransactionObserver, Sendable {
        struct CommitRefused: Error {}
        private let sawHeaderWrite = Mutex(false)
        let refusals = Mutex(0)

        func observes(eventsOfKind eventKind: DatabaseEventKind) -> Bool {
            eventKind.tableName == MessageHeader.databaseTableName
        }
        func databaseDidChange(with event: DatabaseEvent) {
            sawHeaderWrite.withLock { $0 = true }
        }
        func databaseWillCommit() throws {
            guard sawHeaderWrite.withLock({ $0 }) else { return }
            refusals.withLock { $0 += 1 }
            throw CommitRefused()
        }
        func databaseDidCommit(_ db: Database) {
            sawHeaderWrite.withLock { $0 = false }
        }
        func databaseDidRollback(_ db: Database) {
            sawHeaderWrite.withLock { $0 = false }
        }
    }

    /// **THE PROPERTY: an Undo recorded while a proven move's retirement could
    /// not commit is still carried out, at the address the server proved, when
    /// that retirement is recovered by the REPLAY.**
    ///
    /// A committed retirement is not only a durable write. It also
    /// MATERIALIZES the deferred inverse an Undo left waiting behind the
    /// in-flight forward move: `undoMove` cannot queue that inverse itself,
    /// because while the forward `COPY` is on the wire the only address it could
    /// name is the SOURCE UID the move is about to invalidate — naming it would
    /// move whatever now occupies that UID (C3). So the inverse is recorded as a
    /// `DeferredMoveSuccessor` and `materializeDeferredMoveSuccessors` turns it
    /// into an ordinary reverse move once `COPYUID` has named the destination.
    ///
    /// The direct retirement path calls that. The REPLAY path is a second
    /// caller of the same transaction, and if it commits the retirement without
    /// publishing what the retirement publishes, the user's Undo is silently
    /// dropped — the button was pressed, the message stays in `Archive`, and the
    /// waiting successor is stranded in memory for the life of the process with
    /// nothing left to materialize it.
    ///
    /// Driven end to end through the real callers: a real drain against
    /// `FakeIMAPServer`, a real retention (`HeaderCommitRefuser` refusing the
    /// retirement's write), the real `undoMove`, and recovery by a real drain.
    /// Asserted as END STATE ON THE SERVER, plus the fake's wrong-message wire
    /// oracle.
    ///
    /// 🚨 WHY THIS WITNESS LIVES IN THE IMAP SUITE and not beside the other
    /// retention tests in `OutlookQueueHandoffTests`. `undoMove` registers a
    /// `DeferredMoveSuccessor` only on its `isIMAP` branch — `account.provider`
    /// must be `.imap` or `.icloud` — because deferral exists for the address
    /// space where the forward move renumbers the message's UID and the inverse
    /// therefore cannot be named until `COPYUID` answers. On a Graph account the
    /// same gesture is admitted as an ordinary reverse move immediately, so
    /// `deferredMoveSuccessors` can never be populated there and the replay's
    /// `materializeDeferredMoveSuccessors` call is unreachable from an Outlook
    /// fixture. The retention machinery itself (`pendingRetirements`, the
    /// replay) is provider-agnostic, which is what lets the two halves of this
    /// property be witnessed in the two suites that can each reach one.
    @Test("A deferred Undo behind a retirement that could not commit is materialized by the replay")
    @MainActor
    func aDeferredUndoIsMaterializedByTheRetirementReplay() async throws {
        let target = "replay-deferred-undo@example.com"
        let server = FakeIMAPServer(mailboxes: [
            "INBOX": [Self.message(uid: 88, id: target)],
            "Archive": [],
            "Trash": [],
        ])
        for mailbox in ["INBOX", "Archive", "Trash"] { server.setUidValidity(10, for: mailbox) }
        try server.start()
        defer { server.stop() }

        let f = try fixture(accountId: "address-replay-defer")
        let seeded = try seedHeader(f, uid: 88, rfc: target)

        await AccountManager.shared.clearDeferredMoveSuccessorsForTesting()
        #expect(await !AccountManager.shared.hasPendingOperationSettlement,
                "a previous test left a retained retirement on the shared AccountManager")

        // The gesture is issued with NO provider registered, so its own drain
        // does nothing and the refuser below can be installed before the
        // retirement — the optimistic header write has already committed.
        await AccountManager.shared.move([seeded], to: "Archive")

        let provider = try await registeredIMAPProvider(server: server, fixture: f)
        let refuser = HeaderCommitRefuser()
        f.pool.add(transactionObserver: refuser, extent: .databaseLifetime)

        await AccountManager.shared.drainPendingQueue()

        // NON-VACUITY: the forward move really did land on the server, and its
        // LOCAL retirement really was refused — this is a proven move whose
        // address the app has not recorded yet.
        #expect(server.messageIDs(in: "Archive") == ["<\(target)>"], """
            the forward move did not reach the server, so there is no proven \
            destination address for the replay to publish: \
            Archive=\(server.messageIDs(in: "Archive")) INBOX=\(server.messageIDs(in: "INBOX"))
            """)
        #expect(refuser.refusals.withLock { $0 } == 3, """
            the refusal did not land on the retirement write for exactly its \
            three attempts: \(refuser.refusals.withLock { $0 })
            """)
        #expect(await AccountManager.shared.hasPendingOperationSettlement,
                "the provider's proven result was not retained, so no replay happens")

        // THE UNDO, pressed inside the held window. It cannot be queued yet, so
        // it is recorded as a successor waiting on the forward operation.
        let restored = await AccountManager.shared.undoMove(
            accountId: f.accountId,
            forwardDestinationPath: "Archive",
            members: [UndoMember(header: seeded)])
        #expect(restored == [seeded.id], """
            undo was refused inside the held window, so nothing is waiting on \
            the replay and this test proves nothing: \(restored)
            """)
        #expect(await AccountManager.shared.deferredMoveSuccessorCountForTesting() == 1, """
            the inverse was not deferred behind the in-flight forward move, so \
            the replay has no successor to materialize
            """)

        // The database accepts writes again; recovery runs through the replay.
        f.pool.remove(transactionObserver: refuser)
        await AccountManager.shared.drainPendingQueue()
        try await settleUndo(f)

        // 🚨 THE ORACLE: where the mail actually is. The user pressed Undo and
        // the message is back, at the address `COPYUID` proved rather than the
        // one the forward move invalidated.
        #expect(server.messageIDs(in: "INBOX") == ["<\(target)>"], """
            the Undo deferred behind a retirement that could not commit was \
            silently dropped by the recovery — the message is still wherever \
            the forward move left it. INBOX: \(server.messageIDs(in: "INBOX")), \
            Archive: \(server.messageIDs(in: "Archive"))
            """)
        #expect(server.messageIDs(in: "Archive").isEmpty,
                "a copy was left behind in the destination: \(server.messageIDs(in: "Archive"))")
        #expect(server.wrongMessageViolations().isEmpty, """
            the materialized inverse named a message the gesture never selected: \
            \(server.wrongMessageViolations())
            """)
        #expect(await AccountManager.shared.deferredMoveSuccessorCountForTesting() == 0, """
            the successor is still waiting after its predecessor was retired, so \
            nothing will ever materialize it
            """)
        let survivors = try await f.pool.read { db in try PendingOperation.fetchAll(db) }
        #expect(survivors.isEmpty, """
            the queue did not converge: \
            \(survivors.map { "\($0.type.rawValue)/\($0.status)" })
            """)
        #expect(await !AccountManager.shared.hasPendingOperationSettlement,
                "the retained proof was not cleared by the replay that committed it")

        try? await provider.disconnect()
        await finish(f)
    }
}
