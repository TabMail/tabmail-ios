/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

/// `IOS-IMAP-001`, decision **D3** — *a message the server reports with
/// `\Deleted` is not presented in any folder listing, and a move on a server
/// without UIDPLUS does not relist its source copy after the protection TTL
/// expires.*
///
/// ## What D3 was blocked on, and what the code answered
///
/// The register recorded the fix option (*"hiding `\Deleted` rows at the local
/// merge layer is option (b) and destroys nothing server-side; a server-side
/// mailbox-wide purge is FORBIDDEN"*) but left the factual question open:
/// **is a `\Deleted`-but-present source copy even rendered?** It was.
/// `IMAPProvider.mapMessageInfo` read `.seen`, `.flagged`, `.answered` and
/// `.custom("$Forwarded")` and never inspected `.deleted`; the flag appeared in
/// that file only at its three STORE sites.
///
/// ## The defect is worse than "incomplete visible cleanup"
///
/// On a server without UIDPLUS a move leaves the source copy `\Deleted`-but-
/// present, and the purge stays gated on `COPYUID`, which such a server can never
/// supply. `finishMove` cannot re-key the local row without it, so the row keeps
/// its source primary key while its `folderPath` names the destination — i.e. the
/// Inbox holds NO row for that UID any more. The next merge of the source folder
/// sees the UID still present and, once the ~30 s `recentlyCompleted` and the
/// `pendingDestructiveIds` protections expire, **re-materialises it in the
/// Inbox**. The user archives again → another `UID COPY` seats a SECOND copy at
/// the destination → another `\Deleted` STORE on an already-`\Deleted` source →
/// still no expunge. Repeating the ordinary gesture does not reach a correct
/// state, it compounds; that is why this closes with a fix rather than a
/// registered decision.
///
/// ## A1 — shipped `v1.6.38`, as a sequence, and why it is a PROHIBITION
///
/// `git show v1.6.38:TabMail/Providers/IMAPProvider.swift`, `idempotentMove`:
/// after probing the destination by RFC-822 `SEARCH` it took one of two arms.
/// The recovery arm ran `store(flags: [.deleted], on: srcUIDs, operation: .add)`
/// and then `if await server.supportsUIDPlus { try await server.expunge(messages:
/// srcUIDs) } else { try await server.expunge() }` — a **bare, mailbox-wide
/// EXPUNGE**, under a comment that accepted it outright (*"May remove other
/// \Deleted messages from this folder, which is acceptable…"*). The ordinary arm
/// ran `server.move(messages: srcUIDs, to: destination)`, and SwiftMail's
/// `IMAPNamedConnection.move` takes its `MOVE` branch only when
/// `capabilities.contains(.move) && (T.self != UID.self || capabilities
/// .contains(.uidPlus))`; a `UIDSet` on a server without UIDPLUS therefore falls
/// to `copy` + `store [.deleted]` + `expungeMoveFallback`, whose own
/// `T.self == UID.self && capabilities.contains(.uidPlus)` test fails and issues a
/// bare `expunge()`.
///
/// So shipped users never saw the relist because the source copy was
/// **destroyed — along with any unrelated pre-deleted mail in that mailbox.**
/// That is exactly why it was removed. **Shipped's architecture is INAPPLICABLE
/// here (A1 step 3) and must not be restored.** These tests assert the absence of
/// every one of those wire operations, so a future "fix" that reaches for the
/// shipped sequence fails them.
///
/// ## What the fix is, and what it deliberately is not
///
/// `MessageHeaderInfo.isDeletedOnServer` is surfaced from
/// `info.flags.contains(.deleted)` and consumed at the merge in exactly two
/// places: `selectStaleHeaders` subtracts `\Deleted` records from the PRESENT set
/// (never from the window's count or UID floor — that would be the ADR-IOS-042 /
/// MIS-IOS-002 over-deletion shape), and `runSyncMessages` adds them to the
/// upsert loop's skip set so the row cannot be re-created in the same
/// transaction. **No server-side operation is issued at all** — that claim is
/// asserted directly, on the wire, by
/// `theMergeHidesAnExistingRowWithoutTouchingTheServer`.
///
/// ## The negative case, stated because a closure without one is unfinished
///
/// Another client may mark a message `\Deleted` without expunging, and TabMail
/// then hides a message still on the server. That is strictly safer than shipped,
/// which EXPUNGED exactly those messages; it matches IMAP semantics (RFC 3501
/// §2.3.2 — `\Deleted` means pending removal); and it is recoverable, because the
/// merge re-evaluates the flag every pass. `clearingTheDeletedFlagRelistsTheMessage`
/// is that recovery made mechanical rather than asserted.
///
/// `.serialized, .processGlobalState` — every case binds a listening socket via
/// `FakeIMAPServer` (parallel cases would contend on ephemeral port allocation)
/// and swaps `AppDatabase.shared`.
@Suite("IOS-IMAP-001 / D3 — a \\Deleted message is not presented", .serialized, .processGlobalState)
struct DeletedFlagMergeVisibilityTests {

    /// Arbitrary non-zero epoch. `requireUidValidity` rejects 0 on either side,
    /// so every fixture must report a real UIDVALIDITY.
    private static let epoch: UInt32 = 94_301

    /// `FakeIMAPServer.defaultCapabilities` minus `UIDPLUS` — the server class
    /// this row is about. Such a server can never furnish `COPYUID`, so the
    /// `COPYUID`-gated purge never fires and the source copy is always left
    /// `\Deleted`-but-present. `MOVE` is kept so nothing else about the fixture
    /// changes shape (`IMAPProvider.move` issues its own sequence and never calls
    /// `server.move`, so the capability is inert here either way).
    private static let nonUidplusCapabilities =
        ["IMAP4rev1", "AUTH=PLAIN", "LITERAL+", "ID", "NAMESPACE", "MOVE", "IDLE"]

    private static func message(_ uid: Int, _ id: String) -> FakeIMAPServer.Message {
        FakeIMAPServer.makeMessage(uid: uid, rfc822Text: """
        From: Sender <sender@example.com>\r
        To: Recipient <recipient@example.com>\r
        Subject: deleted-flag merge fixture\r
        Date: Thu, 01 Jan 2026 00:00:00 +0000\r
        Message-ID: <\(id)>\r
        Content-Type: text/plain; charset=utf-8\r
        \r
        body\r

        """)
    }

    /// The same fixture dated explicitly. Paging windows are DATE windows, so a
    /// scenario about continuing past a page needs distinct dates; they are
    /// computed from `Date()` at the call site rather than written down.
    private static func message(_ uid: Int, _ id: String, date: Date) -> FakeIMAPServer.Message {
        let rfc2822 = DateFormatter()
        rfc2822.locale = Locale(identifier: "en_US_POSIX")
        rfc2822.timeZone = TimeZone(identifier: "UTC")
        rfc2822.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return FakeIMAPServer.makeMessage(uid: uid, rfc822Text: """
        From: Sender <sender@example.com>\r
        To: Recipient <recipient@example.com>\r
        Subject: deleted-flag paging fixture\r
        Date: \(rfc2822.string(from: date))\r
        Message-ID: <\(id)>\r
        Content-Type: text/plain; charset=utf-8\r
        \r
        body\r

        """)
    }

    private static func provider(_ server: FakeIMAPServer) -> IMAPProvider {
        IMAPProvider(
            host: "127.0.0.1", port: server.port,
            username: server.username, password: server.password,
            smtpHost: "127.0.0.1", smtpPort: 587, useTLS: false)
    }

    private static func commands(_ server: FakeIMAPServer, containing fragment: String) -> [String] {
        server.recordedCommands().filter { $0.uppercased().contains(fragment) }
    }

    /// A BARE, mailbox-wide `EXPUNGE` (RFC 3501 §6.4.3) — the shipped operation
    /// this fix must never reach for. The fake logs a command as `VERB ARGS`, so a
    /// plain expunge is exactly `EXPUNGE` while a UID-scoped one is
    /// `UID EXPUNGE <set>`; the two are distinguishable without parsing.
    private static func bareExpunges(_ server: FakeIMAPServer) -> [String] {
        server.recordedCommands().filter { command in
            let upper = command.uppercased()
            return upper == "EXPUNGE" || upper.hasPrefix("EXPUNGE ")
        }
    }

    /// Every command that MUTATES server state. A merge pass must add none of
    /// these: hiding is a purely local decision.
    private static func mutatingCommands(_ commands: [String]) -> [String] {
        commands.filter { command in
            let upper = command.uppercased()
            return upper.contains("STORE") || upper.contains("EXPUNGE")
                || upper.contains("COPY") || upper.contains("MOVE")
                || upper.contains("APPEND") || upper.hasPrefix("DELETE ")
        }
    }

    /// The local header ids present in one folder, keyed by IMAP UID
    /// (`MessageHeader.messageId` IS the UID). This is the LISTING — what the
    /// Inbox and folder views read — so asserting on it is asserting on what the
    /// user is shown, not on the mechanism that decided it.
    private static func listedUIDs(accountId: String, path: String, pool: DatabasePool) throws -> Set<String> {
        let folderId = "\(accountId):\(path)"
        return try pool.read { db in
            try Set(String.fetchAll(db, MessageHeader
                .select(Column("messageId"))
                .filter(Column("folderId") == folderId)))
        }
    }

    /// Drive the REAL merge core the two sync entry points funnel into: full sync
    /// reaches it through `syncFolderMessages` → `syncMessages`, and IMAP delta
    /// sync through `imapDeltaSync` → `syncMessages`. `recentlyCompleted` is left
    /// empty on purpose — that IS the post-TTL state this row is about, and no
    /// `PendingOperation` is queued either, so neither protection can mask the
    /// result.
    private static func merge(
        folderPath: String, accountId: String, provider: any EmailProvider, pool: DatabasePool,
        limit: Int = SyncConfig.syncMessageLimit
    ) async throws {
        let folder = try #require(
            try FolderEpochTestFixture.readFolder(accountId: accountId, path: folderPath, pool: pool))
        _ = try await SyncEngine.runSyncMessages(
            for: folder, provider: provider, limit: limit,
            dbPool: PrioritizedDatabase(pool: pool))
    }

    /// A `SyncEngine` wired to `provider`. The crawl and paging paths reach the
    /// server through the engine's own `providers` / `workQueues` registry rather
    /// than through an argument, so they cannot be driven without this.
    private static func engine(accountId: String, provider: any EmailProvider) async -> SyncEngine {
        let engine = SyncEngine()
        await engine.register(
            accountId: accountId, provider: provider,
            workQueue: ProviderWorkQueue(provider: provider, maxConcurrency: 1))
        return engine
    }

    // MARK: - The headline: no relist after the protections expire

    /// THE property this row closes. A completed move on a server without UIDPLUS
    /// leaves the source copy on the server, `\Deleted`; the merge that follows —
    /// with every protection expired — must not put it back in the Inbox.
    ///
    /// The Inbox deliberately holds NO local row for the moved UID at merge time.
    /// That is not a simplification, it is the state the optimistic move produces:
    /// `optimisticMoveToFolder` repoints the row's `folderId`/`folderPath` at the
    /// destination while `finishMove` cannot re-key it without `COPYUID`, so the
    /// source folder is empty of it and the merge's insert path is exactly what
    /// re-materialises it.
    @Test("A soft-deleted source copy is not relisted once the protections expire")
    func aSoftDeletedSourceCopyIsNotRelistedAfterTheProtectionsExpire() async throws {
        let target = "d3-relist-target@example.com"
        let bystander = "d3-relist-bystander@example.com"
        let server = FakeIMAPServer(
            capabilities: Self.nonUidplusCapabilities,
            mailboxes: [
                "INBOX": [Self.message(41, bystander), Self.message(42, target)],
                "Archive": [],
            ])
        server.setUidValidity(Int(Self.epoch), for: "INBOX")
        server.setUidValidity(Int(Self.epoch), for: "Archive")
        server.expectMutation(rfc822MessageId: target)
        try server.start()
        defer { server.stop() }

        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }

        let accountId = "d3-relist"
        _ = try FolderEpochTestFixture.makeAccount(id: accountId, provider: .imap, pool: pool)
        try FolderEpochTestFixture.insertFolder(
            accountId: accountId, path: "INBOX", role: .inbox, pool: pool,
            totalCount: 2, lastKnownUidValidity: Int(Self.epoch))
        try FolderEpochTestFixture.insertFolder(
            accountId: accountId, path: "Archive", role: .archive, pool: pool,
            totalCount: 0, lastKnownUidValidity: Int(Self.epoch))
        // Only the bystander is still listed locally — UID 42's row went to the
        // destination with the optimistic move.
        try FolderEpochTestFixture.insertHeaders(
            accountId: accountId, path: "INBOX", uids: [41], pool: pool)

        let provider = Self.provider(server)
        try await provider.connect()
        defer { Task { try? await provider.disconnect() } }

        try await provider.move(
            ids: ["42"], from: "INBOX", to: "Archive", admittedUidValidity: Self.epoch)

        // Preconditions — this is the accepted `IOS-IMAP-001` end state, and it is
        // what makes the relist reachable in the first place.
        #expect(server.messageIDs(in: "Archive") == ["<\(target)>"],
                "precondition: the move landed")
        #expect(server.messageIDs(in: "INBOX").count == 2,
                "precondition: the source copy was NOT expunged — no UIDPLUS, no COPYUID, no purge")
        #expect(server.flags(in: "INBOX", uid: 42).contains("\\Deleted"),
                "precondition: the source copy is soft-deleted, which is the whole state under test")
        #expect(Self.bareExpunges(server).isEmpty,
                "precondition: the shipped mailbox-wide EXPUNGE is not reached")

        try await Self.merge(folderPath: "INBOX", accountId: accountId, provider: provider, pool: pool)

        let listed = try Self.listedUIDs(accountId: accountId, path: "INBOX", pool: pool)
        #expect(!listed.contains("42"),
                """
                the merge re-materialised the soft-deleted source copy in the Inbox. The user \
                archived it, it came back, and archiving it again seats a second copy at the \
                destination — a gesture-driven duplication loop whose "recovery" gesture is the \
                thing that makes it worse (IOS-IMAP-001 / D3)
                """)
        // Two-sided: hiding must not become a folder-wide blackout.
        #expect(listed.contains("41"),
                "an ordinary undeleted message must still list — otherwise this fix hid the folder, not the flag")
        #expect(server.wrongMessageViolations().isEmpty)
    }

    // MARK: - The loop itself: the second gesture must be unreachable

    /// The duplication loop, driven end to end rather than argued about. After the
    /// merge, the test asks the DB whether the Inbox is showing the message — and
    /// only then issues the second archive, exactly as the user would. Pre-fix the
    /// row is there, the gesture fires, and the destination ends with two copies.
    @Test("Archiving cannot seat a second destination copy after the merge")
    func theArchiveGestureCannotSeatASecondDestinationCopy() async throws {
        let target = "d3-loop-target@example.com"
        let server = FakeIMAPServer(
            capabilities: Self.nonUidplusCapabilities,
            mailboxes: ["INBOX": [Self.message(52, target)], "Archive": []])
        server.setUidValidity(Int(Self.epoch), for: "INBOX")
        server.setUidValidity(Int(Self.epoch), for: "Archive")
        server.expectMutation(rfc822MessageId: target)
        try server.start()
        defer { server.stop() }

        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }

        let accountId = "d3-loop"
        _ = try FolderEpochTestFixture.makeAccount(id: accountId, provider: .imap, pool: pool)
        try FolderEpochTestFixture.insertFolder(
            accountId: accountId, path: "INBOX", role: .inbox, pool: pool,
            totalCount: 1, lastKnownUidValidity: Int(Self.epoch))
        try FolderEpochTestFixture.insertFolder(
            accountId: accountId, path: "Archive", role: .archive, pool: pool,
            totalCount: 0, lastKnownUidValidity: Int(Self.epoch))

        let provider = Self.provider(server)
        try await provider.connect()
        defer { Task { try? await provider.disconnect() } }

        try await provider.move(
            ids: ["52"], from: "INBOX", to: "Archive", admittedUidValidity: Self.epoch)
        try await Self.merge(folderPath: "INBOX", accountId: accountId, provider: provider, pool: pool)

        let relisted = try Self.listedUIDs(accountId: accountId, path: "INBOX", pool: pool).contains("52")
        if relisted {
            // The user does the only thing the UI offers: archives it again.
            try await provider.move(
                ids: ["52"], from: "INBOX", to: "Archive", admittedUidValidity: Self.epoch)
        }

        #expect(!relisted, "precondition of the loop: the message must not be showing in the Inbox at all")
        #expect(Self.commands(server, containing: "UID COPY").count == 1,
                "a repeated archive gesture re-COPIES the still-present source, seating another destination copy")
        #expect(server.messageIDs(in: "Archive") == ["<\(target)>"],
                """
                the destination holds \(server.messageIDs(in: "Archive").count) copies. Repeating the \
                ordinary gesture must reach a correct state, not compound the wrong one
                """)
        #expect(Self.bareExpunges(server).isEmpty)
        #expect(server.wrongMessageViolations().isEmpty)
    }

    // MARK: - "Destroys nothing server-side" — proved, not asserted

    /// The other half of "not present for display": an EXISTING local row for a
    /// message another client soft-deleted leaves the listing — and the merge that
    /// removes it issues **no wire mutation of any kind**. That is the register's
    /// pre-authorisation of option (b) made checkable: the local row goes, the
    /// server keeps the message, its flags are untouched, and nothing is expunged.
    ///
    /// No move happens here at all. The `\Deleted` flag is set directly by the
    /// fixture, modelling a second client — which is precisely the case whose
    /// residual risk this fix accepts, and which shipped `v1.6.38` handled by
    /// EXPUNGING the message.
    @Test("The merge hides an existing row for a soft-deleted message without touching the server")
    func theMergeHidesAnExistingRowWithoutTouchingTheServer() async throws {
        let hidden = "d3-hidden@example.com"
        let visible = "d3-visible@example.com"
        let server = FakeIMAPServer(
            capabilities: Self.nonUidplusCapabilities,
            mailboxes: ["INBOX": [Self.message(61, visible), Self.message(62, hidden)]])
        server.setUidValidity(Int(Self.epoch), for: "INBOX")
        // Another IMAP client marked it for removal and has not expunged yet.
        server.setFlags(["\\Deleted"], in: "INBOX", uid: 62)
        try server.start()
        defer { server.stop() }

        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }

        let accountId = "d3-hide"
        _ = try FolderEpochTestFixture.makeAccount(id: accountId, provider: .imap, pool: pool)
        try FolderEpochTestFixture.insertFolder(
            accountId: accountId, path: "INBOX", role: .inbox, pool: pool,
            totalCount: 2, lastKnownUidValidity: Int(Self.epoch))
        try FolderEpochTestFixture.insertHeaders(
            accountId: accountId, path: "INBOX", uids: [61, 62], pool: pool)

        let provider = Self.provider(server)
        try await provider.connect()
        defer { Task { try? await provider.disconnect() } }

        let before = server.recordedCommands().count
        try await Self.merge(folderPath: "INBOX", accountId: accountId, provider: provider, pool: pool)
        let issued = Array(server.recordedCommands().dropFirst(before))

        let listed = try Self.listedUIDs(accountId: accountId, path: "INBOX", pool: pool)
        #expect(!listed.contains("62"),
                "a message the server reports as pending removal must not stay in the listing")
        #expect(listed.contains("61"),
                "non-vacuity: the co-resident undeleted message must survive the same pass")

        // THE CLAIM: this fix destroys nothing server-side. Proved on the wire.
        #expect(Self.mutatingCommands(issued).isEmpty,
                """
                the merge issued \(Self.mutatingCommands(issued)) — hiding is a LOCAL decision. \
                Shipped v1.6.38 reached a mailbox-wide EXPUNGE here, both directly and through \
                SwiftMail's move fallback, and that is exactly what must never come back
                """)
        #expect(server.messageIDs(in: "INBOX").count == 2,
                "the message is still on the server: hidden, not deleted")
        #expect(server.flags(in: "INBOX", uid: 62) == ["\\Deleted"],
                "its flags are exactly what the other client left — the merge added nothing")
    }

    // MARK: - Recoverability, made mechanical

    /// The accepted residual's recovery path, executed rather than promised. Any
    /// client clearing `\Deleted` brings the message straight back, because the
    /// merge re-evaluates presence every pass — there is no durable "hidden"
    /// state, no column, and no migration.
    @Test("Clearing the deleted flag relists the message on the next merge")
    func clearingTheDeletedFlagRelistsTheMessage() async throws {
        let subject = "d3-restored@example.com"
        let server = FakeIMAPServer(
            capabilities: Self.nonUidplusCapabilities,
            mailboxes: ["INBOX": [Self.message(71, subject)]])
        server.setUidValidity(Int(Self.epoch), for: "INBOX")
        server.setFlags(["\\Deleted"], in: "INBOX", uid: 71)
        try server.start()
        defer { server.stop() }

        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }

        let accountId = "d3-restore"
        _ = try FolderEpochTestFixture.makeAccount(id: accountId, provider: .imap, pool: pool)
        try FolderEpochTestFixture.insertFolder(
            accountId: accountId, path: "INBOX", role: .inbox, pool: pool,
            totalCount: 1, lastKnownUidValidity: Int(Self.epoch))

        let provider = Self.provider(server)
        try await provider.connect()
        defer { Task { try? await provider.disconnect() } }

        try await Self.merge(folderPath: "INBOX", accountId: accountId, provider: provider, pool: pool)
        let whileFlagged = try Self.listedUIDs(accountId: accountId, path: "INBOX", pool: pool)
        #expect(!whileFlagged.contains("71"),
                "precondition: while the flag is set the message is not presented")

        // Some other client changed its mind.
        server.setFlags([], in: "INBOX", uid: 71)
        try await Self.merge(folderPath: "INBOX", accountId: accountId, provider: provider, pool: pool)

        let afterClearing = try Self.listedUIDs(accountId: accountId, path: "INBOX", pool: pool)
        #expect(afterClearing.contains("71"),
                """
                hiding must be a re-evaluated view of the server's current flags, never a durable \
                local state — otherwise the accepted residual (another client soft-deletes without \
                expunging) becomes unrecoverable mail loss instead of a transient hide
                """)
    }

    // MARK: - Non-vacuity control: the COPYUID-gated purge is untouched

    /// The other direction, and the one that matters more. The `COPYUID`-gated
    /// source expunge is the only irreversible operation performed on a MESSAGE —
    /// it removes a duplicate the COPY already proved landed — and nothing here
    /// may widen or narrow its evidence. On a UIDPLUS server the move must still
    /// purge exactly the named source UID, must still spare a co-resident message
    /// somebody else marked `\Deleted`, and must still never reach a mailbox-wide
    /// `EXPUNGE`.
    ///
    /// ⚠️ This comment used to call it "the SINGLE irreversible wire operation in
    /// this system". That absolute is false and is corrected here because it
    /// walks a reviewer past three siblings. **Drafts are the negative case:**
    /// `IMAPProvider.deleteDraftStrong` and `saveDraft`'s old-copy replacement
    /// both `STORE \Deleted` then `expungeScopedToTargets` (UIDPLUS only; fail
    /// closed otherwise), and `GmailProvider.deleteDraft`'s resource arm issues
    /// `DELETE /drafts/{id}`, which Google documents as permanent and not a
    /// trash. Those DESTROY a draft rather than moving it to Trash, so
    /// "TabMail never permanently deletes" holds for messages, not for drafts.
    /// Full enumeration:
    /// `Companion/Memory/Current/102-there-are-four-irreversible-wire-operations-not-one.md`.
    @Test("A UIDPLUS move still purges only the named UID and spares a co-resident deleted message")
    func aUidPlusMoveStillPurgesOnlyTheNamedUID() async throws {
        let target = "d3-uidplus-target@example.com"
        let bystander = "d3-uidplus-bystander@example.com"
        let server = FakeIMAPServer(mailboxes: [
            "INBOX": [Self.message(81, bystander), Self.message(82, target)],
            "Archive": [],
        ])
        server.setFlags(["\\Deleted"], in: "INBOX", uid: 81)
        server.setUidValidity(Int(Self.epoch), for: "INBOX")
        server.setUidValidity(Int(Self.epoch), for: "Archive")
        server.expectMutation(rfc822MessageId: target)
        try server.start()
        defer { server.stop() }

        let provider = Self.provider(server)
        try await provider.connect()
        defer { Task { try? await provider.disconnect() } }

        try await provider.move(
            ids: ["82"], from: "INBOX", to: "Archive", admittedUidValidity: Self.epoch)

        #expect(Self.commands(server, containing: "UID EXPUNGE").count == 1,
                "COPYUID named the member, so the source copy is purged — this fix must not disarm that")
        #expect(Self.bareExpunges(server).isEmpty)
        #expect(server.messageIDs(in: "Archive") == ["<\(target)>"])
        #expect(server.messageIDs(in: "INBOX") == ["<\(bystander)>"],
                "the purge is UID-scoped, so the pre-deleted bystander survives on the server")
        #expect(server.flags(in: "INBOX", uid: 81).contains("\\Deleted"))
        #expect(server.wrongMessageViolations().isEmpty)
    }

    // MARK: - The OTHER materialisation paths (D3 covered 2 of 4)

    /// **THE PROPERTY, asserted at the STORE and not at any one function's filter:
    /// a message the server reports with `\Deleted` is not present locally after
    /// ANY sync path that could observe it.**
    ///
    /// `MessageHeaderInfo.isDeletedOnServer` had exactly two consumers, both in
    /// `SyncEngineFullSync` (`selectStaleHeaders`, `runSyncMessages`). Two further
    /// paths build a `MessageHeader` from the same `MessageHeaderInfo`s and never
    /// read the flag: `SyncEngine.insertBackfillBatchGuardable` — the single funnel
    /// for `backfillWindow`, `deepBackfillFolder`, the header-crawl walk and
    /// self-heal — and `SyncEngine.fetchOlderMessages`, the "load older" pull.
    /// ⚠️ That funnel list is a STRUCTURAL enumeration, not a reachability claim:
    /// `deepBackfillFolder` has zero callers and `backfillWindow` is reached only
    /// from inside it, so the live feeders are the walk and self-heal.
    ///
    /// ⚠️ And the census behind "four" enumerated `MessageHeader` CONSTRUCTION
    /// sites, so it structurally could not see a path that PRESENTS a message
    /// without constructing one. `SearchView.searchAccount` is exactly that —
    /// a fifth path, still OPEN on `KNOWN_ISSUES.md` `IOS-IMAP-001`, out of scope
    /// for this file's assertions (which are all at the local store).
    ///
    /// The reachable scenario is the one this whole file is about: on a server
    /// without UIDPLUS a move soft-deletes the source, `runSyncMessages` hides it
    /// and the stale channel removes the local row, so `existingIds` no longer
    /// contains that UID — and the next crawl window or paging pull covering it
    /// re-materialises it as an ordinary visible row. The user archives, it comes
    /// back, and the recovery gesture compounds the wrong state.
    ///
    /// ## A1 — shipped `v1.6.38`
    ///
    /// `git show v1.6.38:TabMail/Providers/EmailProvider.swift` contains **zero**
    /// occurrences of `isDeletedOnServer`, and shipped `SyncEngineFullSync` builds
    /// plain unfiltered `remoteIds` (`Set(fetched.map(\.messageId))`,
    /// `Set(messages.map(\.messageId))`). The shipped architecture for this problem
    /// is **NONEXISTENT** — it "solved" the relist by EXPUNGING the source copy
    /// mailbox-wide, which is precisely what must not come back (see the file
    /// header). Authoring is therefore the correct A1 branch, and this row is an
    /// **incompleteness of new work**, not a regression.
    @Test("A backfill crawl does not materialise a message the server reports as \\Deleted")
    func aBackfillCrawlDoesNotMaterialiseASoftDeletedMessage() async throws {
        let hidden = "d3-backfill-hidden@example.com"
        let visible = "d3-backfill-visible@example.com"
        let server = FakeIMAPServer(
            capabilities: Self.nonUidplusCapabilities,
            mailboxes: ["Archive": [Self.message(31, visible), Self.message(32, hidden)]])
        server.setUidValidity(Int(Self.epoch), for: "Archive")
        // The residue of a completed move on a server that can never furnish
        // COPYUID: still there, still holding its UID, pending removal.
        server.setFlags(["\\Deleted"], in: "Archive", uid: 32)
        try server.start()
        defer { server.stop() }

        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }

        let accountId = "d3-backfill"
        let account = try FolderEpochTestFixture.makeAccount(id: accountId, provider: .imap, pool: pool)
        try FolderEpochTestFixture.insertFolder(
            accountId: accountId, path: "Archive", role: .archive, pool: pool,
            totalCount: 2, lastKnownUidValidity: Int(Self.epoch))
        let folder = try #require(try FolderEpochTestFixture.readFolder(
            accountId: accountId, path: "Archive", pool: pool))
        // The folder holds NO local row for either UID — exactly the state the
        // merge's stale channel leaves behind, and the state in which the crawl's
        // `existingIds` dedup cannot help.

        let provider = Self.provider(server)
        try await provider.connect()
        defer { Task { try? await provider.disconnect() } }

        let engine = await Self.engine(accountId: accountId, provider: provider)
        _ = try await engine.backfillWindow(
            folder: folder, account: account,
            since: Date(timeIntervalSince1970: 0), before: Date().addingTimeInterval(86_400))

        let listed = try Self.listedUIDs(accountId: accountId, path: "Archive", pool: pool)
        #expect(!listed.contains("32"), """
                a backfill crawl re-materialised a message the server reports as \\Deleted. The \
                merge hides it and the crawl puts it back, so the two paths disagree about \
                whether the message exists — and the user sees a message they already archived \
                (IOS-IMAP-001 / D3)
                """)
        #expect(listed.contains("31"),
                "non-vacuity: the co-resident undeleted message must still be crawled in — otherwise this filter hid the window, not the flag")
        #expect(Self.mutatingCommands(server.recordedCommands()).isEmpty,
                "the crawl issued a server mutation — hiding is a LOCAL decision on every path")
        #expect(Self.bareExpunges(server).isEmpty)
    }

    /// The same store-level property on the fourth path: `fetchOlderMessages`, the
    /// pull the inbox issues when the user scrolls past the end of a folder. Its
    /// dedupe loop tested only `messageId == && folderId ==` existence, so the same
    /// soft-deleted source copy walked straight in.
    @Test("Loading older messages does not materialise a message the server reports as \\Deleted")
    func loadingOlderMessagesDoesNotMaterialiseASoftDeletedMessage() async throws {
        let hidden = "d3-older-hidden@example.com"
        let visible = "d3-older-visible@example.com"
        let server = FakeIMAPServer(
            capabilities: Self.nonUidplusCapabilities,
            mailboxes: ["Archive": [Self.message(51, visible), Self.message(52, hidden)]])
        server.setUidValidity(Int(Self.epoch), for: "Archive")
        server.setFlags(["\\Deleted"], in: "Archive", uid: 52)
        try server.start()
        defer { server.stop() }

        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }

        let accountId = "d3-older"
        _ = try FolderEpochTestFixture.makeAccount(id: accountId, provider: .imap, pool: pool)
        try FolderEpochTestFixture.insertFolder(
            accountId: accountId, path: "Archive", role: .archive, pool: pool,
            totalCount: 2, lastKnownUidValidity: Int(Self.epoch))
        let folder = try #require(try FolderEpochTestFixture.readFolder(
            accountId: accountId, path: "Archive", pool: pool))

        let provider = Self.provider(server)
        try await provider.connect()
        defer { Task { try? await provider.disconnect() } }

        let engine = await Self.engine(accountId: accountId, provider: provider)
        _ = try await engine.fetchOlderMessages(folders: [folder])

        let listed = try Self.listedUIDs(accountId: accountId, path: "Archive", pool: pool)
        #expect(!listed.contains("52"), """
                paging older mail re-materialised a message the server reports as \\Deleted — \
                scrolling to the end of a folder undid what the merge decided (IOS-IMAP-001 / D3)
                """)
        #expect(listed.contains("51"),
                "non-vacuity: the co-resident undeleted message must still be paged in")
        #expect(Self.mutatingCommands(server.recordedCommands()).isEmpty)
        #expect(Self.bareExpunges(server).isEmpty)
    }

    /// 🚨 **THE PAGING INVARIANT, asserted at the STORE: paging is never declared
    /// exhausted while an older, non-`\Deleted` message is still reachable on the
    /// server.** The test above pins that a soft-deleted record is not
    /// materialised; it uses two records, so it cannot exercise what happens to
    /// everything BEHIND one.
    ///
    /// The regression the skip introduced (`45ad66d38`) is that the scroller
    /// measured "end of folder" with the count of rows it MATERIALISED.
    /// `IMAPProvider.fetchOlderMessagesWithObservedEpoch` takes its
    /// `Array(sorted.prefix(limit))` before any flag is known, so a `\Deleted`
    /// record CONSUMES a slot in the page; skipping it then made a full page look
    /// short, `hasMoreMessages` went false, and every message older than it became
    /// unreachable by scrolling. One such record in one full page was enough —
    /// and `IMAPProvider.searchDateRange` issues its `SINCE`/`BEFORE` search with
    /// no `NOT DELETED` term, so the filter is live on exactly the mail paging
    /// walks into: on a server without UIDPLUS, soft-deleted move sources
    /// accumulate in older mail.
    ///
    /// The fixture is the smallest one that can show it: a page of exactly
    /// `SyncConfig.infiniteScrollFetchLimit` records with the newest `\Deleted`,
    /// and ONE further visible message older than the whole page. The assertion is
    /// that the deeper message ends up in the store — not that any counter has a
    /// particular value, which is the version of this test that would stay green
    /// on a re-broken system.
    ///
    /// The loop consumes the production continuation signal rather than
    /// re-deciding it, and is bounded so a non-terminating scroller fails here
    /// instead of hanging: `paging must still stop at a genuinely empty folder` is
    /// asserted on the same run.
    ///
    /// ## A1 — shipped `v1.6.38`
    ///
    /// `git show 07a4bb703:TabMail/ViewModels/InboxViewModel.swift`,
    /// `loadMoreMessages` phase 2, is byte-identical to the pre-fix v3 sequence:
    /// `let newCount = try await manager.fetchOlderMessages(folders: folders)` /
    /// `if newCount == 0 { hasMoreMessages = false }` / `else { … hasMoreMessages =
    /// freshPage.count >= SyncConfig.inboxPageSize }`, and shipped
    /// `SyncEngine.fetchOlderMessages` returns a bare `Int` with zero occurrences
    /// of `isDeletedOnServer`. Shipped therefore had NO separate exhaustion signal
    /// to restore — it was correct only because it materialised every record the
    /// server returned, so its insert count and the server's coverage were the same
    /// number. The shipped architecture for THIS problem is NONEXISTENT and
    /// authoring is the correct A1 branch.
    @Test("Paging does not stop at a full page whose slots a \\Deleted record consumed — the message behind it stays reachable")
    func pagingContinuesPastAFullPageContainingASoftDeletedRecord() async throws {
        let limit = SyncConfig.infiniteScrollFetchLimit
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        // Dynamic dates (never hardcoded — a fixed date silently ages into a
        // different relationship with `Date()`): one message per day, midday UTC
        // so no timezone can shift one across a day boundary, newest yesterday.
        // The IMAP date keys are day-granular, which is why one day of spacing is
        // the unit here.
        let noonYesterday = utc.date(byAdding: .hour, value: 12, to: utc.startOfDay(for: Date()))!
            .addingTimeInterval(-86_400)
        let deletedUID = 100 + limit + 1                    // newest, and \Deleted
        let deepestUID = deletedUID - limit                 // strictly older than the whole page
        let messages: [FakeIMAPServer.Message] = (0...limit).map { index in
            Self.message(
                deletedUID - index, "d3-paging-\(deletedUID - index)@example.com",
                date: noonYesterday.addingTimeInterval(-86_400 * Double(index)))
        }
        let server = FakeIMAPServer(
            capabilities: Self.nonUidplusCapabilities, mailboxes: ["Archive": messages])
        // The scroller's cursor IS the search window, so a server that answered
        // every window with the whole mailbox could not show a continuation at all.
        server.honorSearchDateCriteria()
        server.setUidValidity(Int(Self.epoch), for: "Archive")
        server.setFlags(["\\Deleted"], in: "Archive", uid: deletedUID)
        try server.start()
        defer { server.stop() }

        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }

        let accountId = "d3-paging"
        _ = try FolderEpochTestFixture.makeAccount(id: accountId, provider: .imap, pool: pool)
        try FolderEpochTestFixture.insertFolder(
            accountId: accountId, path: "Archive", role: .archive, pool: pool,
            totalCount: messages.count, lastKnownUidValidity: Int(Self.epoch))
        let folder = try #require(try FolderEpochTestFixture.readFolder(
            accountId: accountId, path: "Archive", pool: pool))

        let provider = Self.provider(server)
        try await provider.connect()
        defer { Task { try? await provider.disconnect() } }

        let engine = await Self.engine(accountId: accountId, provider: provider)

        // Scroll to the end of the folder exactly as the inbox does: pull, and
        // pull again for as long as the pull itself says the server may hold more.
        let maxPulls = 8
        var pulls = 1
        var pull = try await engine.fetchOlderMessages(folders: [folder])
        while pull.mayHaveMore && pulls < maxPulls {
            pull = try await engine.fetchOlderMessages(folders: [folder])
            pulls += 1
        }

        let listed = try Self.listedUIDs(accountId: accountId, path: "Archive", pool: pool)
        #expect(listed.contains(String(deepestUID)), """
                a message OLDER than a full page containing one \\Deleted record is unreachable by \
                scrolling. The server covered a full page, one slot of which held a record we \
                correctly refuse to materialise; measuring exhaustion by what we materialised \
                turned that into "end of folder" and stranded the rest of the folder \
                (IOS-IMAP-001 / D3 regression)
                """)
        #expect(listed == Set((deepestUID..<deletedUID).map { String($0) }), """
                paging did not surface exactly the visible mail: every non-\\Deleted message must \
                be reachable and the \\Deleted one must not be present — listed=\(listed.count)
                """)
        #expect(!listed.contains(String(deletedUID)),
                "the D3 filter was weakened: paging materialised the record the server reports as \\Deleted")
        #expect(!pull.mayHaveMore && pulls < maxPulls,
                "paging never terminated on a folder the server had fully shown — the scroller would spin forever")
        #expect(Self.mutatingCommands(server.recordedCommands()).isEmpty)
        #expect(Self.bareExpunges(server).isEmpty)
    }

    // MARK: - Coverage vs presence: the named data-loss direction, pinned

    /// 🚨 **THE INVARIANT THE SPLIT BETWEEN `deletedRemoteIds` AND `remoteIds`
    /// EXISTS FOR: a fetch's CARDINALITY and its UID FLOOR measure what the fetch
    /// COVERED, and a `\Deleted` record was covered.** Both consumers say so in
    /// their comments; nothing pinned it, so a "simplification" that filtered
    /// `messages` at the fetch site instead of splitting the two id sets would have
    /// been green across the whole suite while silently restoring the ADR-IOS-042 /
    /// MIS-IOS-002 mass-deletion shape.
    ///
    /// The mechanism, stated once so the fixture reads: shrinking `messages` makes
    /// `messages.count < limit` true, which is the COMPLETE-KNOWLEDGE branch —
    /// "the whole folder came back, so anything local-but-not-remote is genuinely
    /// gone". Every local row below the fetch's window is then classified stale and
    /// deleted, including rows the fetch never went near.
    ///
    /// Asserted at the STORE: five local rows, a window of three, one of the three
    /// `\Deleted`. The two rows below the floor are outside the covered slice and
    /// must survive; the `\Deleted` row inside it must still be hidden, which is
    /// what stops this passing vacuously by disabling the sweep.
    ///
    /// No blessing test exists here — nothing in the tree asserts that a `\Deleted`
    /// record IS presented (`isDeletedOnServer` appears in the test tree only in
    /// this file), so there was nothing to retire.
    @Test("A full window containing a \\Deleted record stale-deletes nothing below the fetch's UID floor")
    func aFullWindowContainingADeletedRecordSparesRowsBelowTheFloor() async throws {
        let server = FakeIMAPServer(
            capabilities: Self.nonUidplusCapabilities,
            mailboxes: ["Archive": [
                Self.message(10, "d3-floor-10@example.com"),
                Self.message(11, "d3-floor-11@example.com"),
                Self.message(12, "d3-floor-12@example.com"),
                Self.message(13, "d3-floor-13@example.com"),
                Self.message(14, "d3-floor-14@example.com"),
            ]])
        server.setUidValidity(Int(Self.epoch), for: "Archive")
        // The newest record in the window is soft-deleted. It still COUNTS toward
        // the window and still sets no floor of its own — that is the whole point.
        server.setFlags(["\\Deleted"], in: "Archive", uid: 14)
        try server.start()
        defer { server.stop() }

        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }

        let accountId = "d3-floor"
        _ = try FolderEpochTestFixture.makeAccount(id: accountId, provider: .imap, pool: pool)
        try FolderEpochTestFixture.insertFolder(
            accountId: accountId, path: "Archive", role: .archive, pool: pool,
            totalCount: 5, lastKnownUidValidity: Int(Self.epoch))
        try FolderEpochTestFixture.insertHeaders(
            accountId: accountId, path: "Archive", uids: [10, 11, 12, 13, 14], pool: pool)

        let provider = Self.provider(server)
        try await provider.connect()
        defer { Task { try? await provider.disconnect() } }

        // A window of exactly `limit`: the fetch returns the highest 3 UIDs
        // (12, 13, 14), so it is a WINDOWED fetch, not complete knowledge.
        try await Self.merge(
            folderPath: "Archive", accountId: accountId, provider: provider, pool: pool, limit: 3)

        let listed = try Self.listedUIDs(accountId: accountId, path: "Archive", pool: pool)
        #expect(listed.contains("10") && listed.contains("11"), """
                rows BELOW the fetch's UID floor were stale-deleted. The fetch returned three \
                records and the window was three, so it covered UIDs 12-14 and knows nothing \
                about 10-11 — counting the \\Deleted record out of the fetch's cardinality \
                turns a windowed pass into a false complete-knowledge pass and sweeps mail the \
                server never reported on (ADR-IOS-042 / MIS-IOS-002). Surviving: \
                \(listed.sorted())
                """)
        #expect(listed.contains("12") && listed.contains("13"),
                "the undeleted records inside the window must stay listed")
        #expect(!listed.contains("14"),
                "non-vacuity: the \\Deleted record INSIDE the window is still not presented — otherwise this passes by doing nothing at all")
    }
}
