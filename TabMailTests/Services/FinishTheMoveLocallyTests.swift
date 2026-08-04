/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
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
    /// this app has recorded for that folder, the user's next gesture on the
    /// re-keyed row is RETAINED FOR RETRY — never terminally dropped.**
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
    /// this at the property assertion — the gesture comes back `.terminalStale`,
    /// so its id lands in `failedIds`.
    @Test("A destination epoch the folder does not share leaves the next gesture retryable")
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
        let applied = try await f.pool.write { db -> [HeaderRekeyRecord] in
            guard let op = try PendingOperation.fetchAll(db).first(where: { $0.type == .move })
            else { return [] }
            let records = try MessageHeaderRekey.finishMove(
                op,
                destinations: [ProvenDestinationAddress(
                    sourceProviderId: "77", destinationUid: 1,
                    destinationUidValidity: 20_260_803)],
                db: db)
            _ = try PendingOperation.deleteOne(db, key: op.id)
            return records
        }

        // NON-VACUITY: the re-key itself DID happen, so the only thing the guard
        // under test changed is the stamp. Without this the property below would
        // hold vacuously for a `finishMove` that did nothing at all.
        #expect(applied.count == 1)
        let afterArchive = try rows(f)
        #expect(afterArchive.count == 1)
        guard afterArchive.count == 1 else { return }
        #expect(
            afterArchive[0].messageId == "1",
            "the row was never re-keyed, so the stamp under test was never reached")

        let outcome = await AccountManager.shared.move([afterArchive[0]], to: "Trash")

        // THE PROPERTY — the gesture is preserved, not destroyed. Either it was
        // durably admitted (the epoch agreed after all) or it is retained for
        // retry; what it must NEVER be is terminally stale.
        #expect(
            outcome.failedIds.isEmpty,
            """
            the next gesture was TERMINALLY dropped because the row was stamped fresher than the \
            folder it lives in — the exact inverse of the bug this change fixes: \(outcome.failedIds)
            """)
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
            try UserLabel(
                id: "work", accountId: f.accountId, name: "Work", isSystem: false).insert(db)
            try MessageUserLabel(messageId: threaded.id, userLabelId: "work").insert(db)
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
            labels == ["work"],
            "the move silently destroyed a label the USER applied — nothing can rebuild it: \(labels)")
        #expect(server.wrongMessageViolations().isEmpty)
        try? await provider.disconnect()
        await finish(f)
    }
}
