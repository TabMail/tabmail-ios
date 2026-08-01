/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

/// T1.2b — the red-first proof that a folder's IMAP UIDVALIDITY epoch is
/// captured from the **SELECT** the sync/open paths already perform, not only
/// from STATUS.
///
/// T1.2 made `Folder.lastKnownUidValidity` durable from the IMAP **STATUS**
/// response. That is not enough, and the gap is a class of servers rather than
/// an edge case: SwiftMail asks for the `UIDVALIDITY` STATUS attribute **only**
/// when the server advertises UIDPLUS —
///
/// ```swift
/// // SwiftMail/IMAP/IMAPServer+Mailbox.swift, mailboxStatus(_:)
/// if capabilities.contains(.uidPlus) {
///     attributes.append(.uidNext)
///     attributes.append(.uidValidity)
/// }
/// ```
///
/// — so on a non-UIDPLUS account BOTH T1.2 writers observe nil forever. SELECT
/// does not have that problem: `OK [UIDVALIDITY n]` is core IMAP4rev1
/// (RFC 3501 §6.3.1), not a UIDPLUS extension, so the server still reports it
/// there. Without this item T1.3 (fail closed on an unknown epoch) would refuse
/// every durable action on those accounts permanently — a bricked account, not
/// a transient no-op.
///
/// **`0` IS "NOT REPORTED", NOT AN EPOCH — and that is what makes this item
/// dangerous to get wrong.** `Mailbox.Selection.uidValidity` is non-optional
/// only because SwiftMail DEFAULTS it (`public var uidValidity: UIDValidity =
/// UIDValidity(0)`); RFC 3501 §6.3.1 makes the response code a SHOULD, not a
/// MUST, so a server can legally omit it and leave the client holding that
/// default. Persisting the `0` would make every later epoch comparison
/// `0 == 0` — always true, therefore vacuous — silently defeating the one hard
/// invariant this whole line of work exists to protect. The repo had already
/// settled the convention (`UIDExistenceResult.uidValidity`: *"0 = the server
/// did not report a value (callers must treat as unknown and abort any deletion
/// decision — never delete on uncertainty)"*), and this item follows it:
/// `IMAPProvider.selectMailboxTracked` drops a `0` before it ever reaches the
/// mirror, and `SyncEngine.bootstrapFolderUidValidity` drops it again before
/// the column.
///
/// The write rule is unchanged from T1.2 — **BOOTSTRAP-ONLY**. This item adds a
/// second SOURCE for the observation, never a second rule for the write, so a
/// SELECT-sourced turnover is refused exactly like a STATUS-sourced one
/// (`selectSourcedTurnoverNeverOverwritesTheStoredEpoch`). Advancing the column
/// without first purging the rows that belong to the old epoch is what disarms
/// the deletion-reconcile walk's abort guard (ADR-IOS-051).
///
/// REFERENCE (`v2final`, tag `e28dd4edb`): the same capture, from the same
/// place. `IMAPProvider.selectMailboxTracked` (symbol-cited — the reference's
/// line numbers for this file are no longer quoted, see below) wraps
/// `server.selectMailbox`, guards `if observed != 0`, and records into
/// `lastObservedUidValidityBox`; `EmailProvider.lastObservedUidValidity(
/// folderPath:)` (`EmailProvider.swift:210`, default `nil` at `:352`) is how a
/// sync pass reads it; and `SyncEngineFullSync.swift:1019` captures it into a
/// local immediately after `runSyncMessages`' own `fetchMessages`. THREE
/// deliberate deviations. Two are narrowing: the reference routes EVERY
/// `selectMailbox` call site through the chokepoint because it also carries a
/// refusal (Stage 2) that must apply to all of them — this item adds no
/// refusal, so only the sync/open SELECTs are routed — and the reference
/// persists through its own epoch ledger (`AccountManager
/// .recordObservedUidValidity`, `AccountManager.swift:838`), whose change-
/// reaction is a later stage, so the persist here reuses v3's already-shipped
/// `SyncEngine.uidValidityBootstrapWrite` decision instead. The third is a
/// CORRECTION rather than a narrowing, and it is not cosmetic: the reference's
/// `if observed != 0 { … }` leaves any earlier entry standing when a SELECT
/// reports nothing, which is safe where its consumer COMPARES the mirror
/// (stale ⇒ mismatch ⇒ abort) and unsafe here, where the consumer WRITES it —
/// so this port CLEARS instead (see `IMAPProvider.selectMailboxTracked`, and
/// inversion E below for the measured proof).
///
/// ## Red-first evidence — five inversions, each applied ALONE, MEASURED 2026-07-30
///
/// Every quotation below is verbatim console output from a real run. Each
/// inversion was applied to the implemented tree ON ITS OWN — never stacked —
/// built, run, and then reverted by restoring byte-identical pristine copies,
/// with the restore verified by md5 (the three files any inversion touches are
/// back to `ba388bcb…` / `705b6e7f…` / `21cac7cd…`). The `.swift:NNN` line
/// numbers are as-recorded; this doc comment has changed length since, so they
/// no longer index the same assertions — the quoted test name + expectation is
/// the identifying part.
///
/// The implemented tree, same build settings, immediately before the first
/// inversion:
///
/// ```
/// ✔ Test run with 6 tests in 1 suite passed after 0.630 seconds.
/// ```
///
/// ### Inversion A — the SELECT source removed (i.e. exactly T1.2/HEAD)
///
/// `fetchMessages` and both `createFolderConnection` legs reverted to the bare
/// `server.selectMailbox(folder)`, and the `bootstrapFolderUidValidity` call
/// deleted from `runSyncMessages`. Tests unchanged.
///
/// ```
/// ✘ Test "A folder on a non-UIDPLUS server acquires its epoch from the sync SELECT" recorded an issue at SelectSourcedFolderEpochTests.swift:242:9: Expectation failed: (after?.lastKnownUidValidity → nil) == (liveEpoch → 838101)
/// ✘ Test "Opening a folder marks its epoch" recorded an issue at SelectSourcedFolderEpochTests.swift:297:9: Expectation failed: (after?.lastKnownUidValidity → nil) == (liveEpoch → 838202)
/// ✘ Test "A SELECT that stops reporting an epoch never answers with the earlier one" recorded an issue at SelectSourcedFolderEpochTests.swift:381:9: Expectation failed: (provider.lastObservedUidValidity(folderPath: "INBOX") → nil) == (UInt32(firstEpoch) → 838505)
/// ✘ Test "A SELECT-sourced turnover never overwrites the stored epoch" recorded an issue at SelectSourcedFolderEpochTests.swift:479:9: Expectation failed: (provider.lastObservedUidValidity(folderPath: "INBOX") → nil) == (UInt32(liveEpoch) → 838402)
/// ✔ Test "A SELECT that reports no epoch leaves the column nil" passed after 0.095 seconds.
/// ✔ Test "A SELECT that reports no epoch never erases a stored epoch" passed after 0.063 seconds.
/// ✘ Test run with 6 tests in 1 suite failed after 0.770 seconds with 4 issues.
/// ```
///
/// `→ nil` on the first two is the column staying empty forever on a server that
/// reports its epoch only on SELECT. The other two failures are SETUP
/// preconditions, not assertions — with nothing tracked, nothing is observed at
/// all — and each of those two tests has its own single-change proof below
/// (inversion E for the stale-mirror test, inversion D for the turnover test).
///
/// ### Inversion B — only the two zero-guards removed
///
/// `selectMailboxTracked`'s sentinel test dropped (`$0[folder] = observed`,
/// recording every value including SwiftMail's `UIDValidity(0)` default) and
/// `knownUidValidity` weakened from `value > 0` to `value >= 0`. Nothing else.
///
/// ```
/// ✘ Test "A SELECT that reports no epoch leaves the column nil" recorded an issue at SelectSourcedFolderEpochTests.swift:331:9: Expectation failed: (inbox?.lastKnownUidValidity → 0) == nil
/// ✘ Test "A SELECT that reports no epoch leaves the column nil" recorded an issue at SelectSourcedFolderEpochTests.swift:339:9: Expectation failed: (provider.lastObservedUidValidity(folderPath: "INBOX") → 0) == nil
/// ✘ Test "A SELECT that stops reporting an epoch never answers with the earlier one" recorded an issue at SelectSourcedFolderEpochTests.swift:395:9: Expectation failed: (provider.lastObservedUidValidity(folderPath: "INBOX") → 0) == nil
/// ✘ Test "A SELECT that stops reporting an epoch never answers with the earlier one" recorded an issue at SelectSourcedFolderEpochTests.swift:403:9: Expectation failed: (after?.lastKnownUidValidity → 0) == nil
/// ✔ Test "A folder on a non-UIDPLUS server acquires its epoch from the sync SELECT" passed after 0.279 seconds.
/// ✔ Test "Opening a folder marks its epoch" passed after 0.047 seconds.
/// ✔ Test "A SELECT that reports no epoch never erases a stored epoch" passed after 0.053 seconds.
/// ✔ Test "A SELECT-sourced turnover never overwrites the stored epoch" passed after 0.056 seconds.
/// ✘ Test run with 6 tests in 1 suite failed after 0.676 seconds with 4 issues.
/// ```
///
/// `→ 0` is the sentinel landing in `Folder.lastKnownUidValidity` as though it
/// were an epoch — the exact defect that would make every later comparison
/// `0 == 0` and therefore vacuous.
///
/// ### Inversion C — zero-guards removed **and** the bootstrap-only rule removed
///
/// Inversion B plus the `lastKnownUidValidity IS NULL` predicate dropped from
/// `SyncEngine.bootstrapFolderUidValidity(_:folderId:observed:)`.
///
/// ```
/// ✘ Test "A SELECT that reports no epoch leaves the column nil" recorded an issue at SelectSourcedFolderEpochTests.swift:331:9: Expectation failed: (inbox?.lastKnownUidValidity → 0) == nil
/// ✘ Test "A SELECT that reports no epoch leaves the column nil" recorded an issue at SelectSourcedFolderEpochTests.swift:339:9: Expectation failed: (provider.lastObservedUidValidity(folderPath: "INBOX") → 0) == nil
/// ✘ Test "A SELECT that stops reporting an epoch never answers with the earlier one" recorded an issue at SelectSourcedFolderEpochTests.swift:395:9: Expectation failed: (provider.lastObservedUidValidity(folderPath: "INBOX") → 0) == nil
/// ✘ Test "A SELECT that stops reporting an epoch never answers with the earlier one" recorded an issue at SelectSourcedFolderEpochTests.swift:403:9: Expectation failed: (after?.lastKnownUidValidity → 0) == nil
/// ✘ Test "A SELECT that reports no epoch never erases a stored epoch" recorded an issue at SelectSourcedFolderEpochTests.swift:440:9: Expectation failed: (after?.lastKnownUidValidity → 0) == (storedEpoch → 838303)
/// ✘ Test "A SELECT-sourced turnover never overwrites the stored epoch" recorded an issue at SelectSourcedFolderEpochTests.swift:484:9: Expectation failed: (after?.lastKnownUidValidity → 838402) == (storedEpoch → 838401)
/// ✘ Test run with 6 tests in 1 suite failed after 0.694 seconds with 6 issues.
/// ```
///
/// EXACTLY ONE test needs this composition: *"A SELECT that reports no epoch
/// never erases a stored epoch"*. It is green under B alone (the `IS NULL`
/// predicate still refuses the write) and green under D alone (the zero guards
/// still refuse to call a `0` an epoch) — it goes red only when a `0` may reach
/// the write AND the write may overwrite, which is what makes `→ 0` land on top
/// of the stored `838303`. Every other test here is reddened by a SINGLE change.
///
/// ### Inversion D — ONLY the bootstrap-only rule removed
///
/// The `lastKnownUidValidity IS NULL` predicate dropped from
/// `SyncEngine.bootstrapFolderUidValidity(_:folderId:observed:)`; both zero
/// guards left intact.
///
/// ```
/// ✔ Test "A folder on a non-UIDPLUS server acquires its epoch from the sync SELECT" passed after 0.304 seconds.
/// ✔ Test "Opening a folder marks its epoch" passed after 0.050 seconds.
/// ✔ Test "A SELECT that reports no epoch leaves the column nil" passed after 0.059 seconds.
/// ✔ Test "A SELECT that stops reporting an epoch never answers with the earlier one" passed after 0.057 seconds.
/// ✔ Test "A SELECT that reports no epoch never erases a stored epoch" passed after 0.052 seconds.
/// ✘ Test "A SELECT-sourced turnover never overwrites the stored epoch" recorded an issue at SelectSourcedFolderEpochTests.swift:484:9: Expectation failed: (after?.lastKnownUidValidity → 838402) == (storedEpoch → 838401)
/// ✘ Test run with 6 tests in 1 suite failed after 0.590 seconds with 1 issue.
/// ```
///
/// The live `838402` overwriting the stored `838401` is a SELECT-sourced writer
/// disarming the deletion-reconcile walk's abort guard: after that write the
/// walk's stored-vs-live comparison is equal, so it stops aborting and deletes
/// the old-epoch headers as ghosts (ADR-IOS-051).
///
/// ### Inversion E — ONLY the mirror's clearing removed
///
/// `selectMailboxTracked` reverted to `v2final`'s verbatim form —
/// `if observed != 0 { $0[folder] = observed }` — so an unreported epoch leaves
/// the previous entry standing instead of erasing it. Both zero guards and the
/// bootstrap-only predicate intact.
///
/// ```
/// ✔ Test "A folder on a non-UIDPLUS server acquires its epoch from the sync SELECT" passed after 0.325 seconds.
/// ✔ Test "Opening a folder marks its epoch" passed after 0.050 seconds.
/// ✔ Test "A SELECT that reports no epoch leaves the column nil" passed after 0.060 seconds.
/// ✘ Test "A SELECT that stops reporting an epoch never answers with the earlier one" recorded an issue at SelectSourcedFolderEpochTests.swift:395:9: Expectation failed: (provider.lastObservedUidValidity(folderPath: "INBOX") → 838505) == nil
/// ✘ Test "A SELECT that stops reporting an epoch never answers with the earlier one" recorded an issue at SelectSourcedFolderEpochTests.swift:403:9: Expectation failed: (after?.lastKnownUidValidity → 838505) == nil
/// ✔ Test "A SELECT that reports no epoch never erases a stored epoch" passed after 0.147 seconds.
/// ✔ Test "A SELECT-sourced turnover never overwrites the stored epoch" passed after 0.061 seconds.
/// ✘ Test run with 6 tests in 1 suite failed after 0.735 seconds with 2 issues.
/// ```
///
/// This is the one inversion whose damage is invisible at the sentinel level:
/// `838505` is a perfectly well-formed epoch, and it is written into the column
/// even though NO SELECT in that sync pass reported it — the value is a
/// leftover from an earlier SELECT of the same path on the same provider. The
/// guards a `0` would trip never fire, because there is no `0` anywhere. That is
/// why the reference's non-clearing form is safe where its consumer COMPARES
/// (stale ⇒ mismatch ⇒ abort) and unsafe here, where the consumer WRITES.
///
/// Each test runs against its OWN `AppDatabase` (T0.4's `TestDatabaseTeardown`
/// machinery) swapped into the shared slot inside a `defer`, so a throwing
/// `try` can never strand fixture rows in an ambient pool.
///
/// `.serialized, .processGlobalState` — these tests replace `AppDatabase.shared`,
/// drive the shared `SyncEngine` statics (`fullSyncSkipStreak`), and bind a
/// listening socket via `FakeIMAPServer` (parallel cases would contend on
/// ephemeral port allocation).
@Suite("T1.2b — the epoch is captured from the sync/open SELECT", .serialized, .processGlobalState)
struct SelectSourcedFolderEpochTests {

    // MARK: - Fixtures

    /// `FakeIMAPServer.defaultCapabilities` minus `UIDPLUS`. This is the whole
    /// point of the suite: with UIDPLUS absent SwiftMail never asks STATUS for
    /// `UIDVALIDITY`, so the STATUS-sourced writes T1.2 added can contribute
    /// nothing and any epoch that lands in the column can only have come from a
    /// SELECT. `MOVE` is kept so nothing else about the fixture changes shape.
    private static let nonUidplusCapabilities =
        ["IMAP4rev1", "AUTH=PLAIN", "LITERAL+", "ID", "NAMESPACE", "MOVE", "IDLE"]

    private static func rfc822(messageId: String) -> String {
        """
        From: Test Sender <sender@example.com>\r
        To: Recipient <recipient@example.com>\r
        Subject: t1.2b-fixture\r
        Date: Thu, 01 Jan 2026 00:00:00 +0000\r
        Message-ID: <\(messageId)>\r
        Content-Type: text/plain; charset=utf-8\r
        \r
        t1.2b fixture body.\r

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

    private static func makeEngine(accountId: String, provider: IMAPProvider) async -> SyncEngine {
        let engine = SyncEngine()
        await engine.register(
            accountId: accountId, provider: provider,
            workQueue: ProviderWorkQueue(provider: provider, maxConcurrency: SyncConfig.imapMaxConnectionCeiling))
        return engine
    }

    // MARK: - The property this item delivers

    /// THE headline case. A non-UIDPLUS server tells STATUS nothing about the
    /// epoch, so before this item a healthy folder on such an account stayed at
    /// `nil` through every sync it would ever run — permanently, not until some
    /// later pass. (The one pre-existing writer that is not STATUS-sourced, the
    /// deletion-reconcile walk, needs a local-vs-server count mismatch to run at
    /// all — `SyncEngine.shouldReconcileDeletions` — so it is a repair path, not
    /// a source.) The SELECT the sync already performs is what still answers.
    @Test("A folder on a non-UIDPLUS server acquires its epoch from the sync SELECT")
    func nonUidplusFolderAcquiresItsEpochFromTheSyncSelect() async throws {
        let liveEpoch = 838_101
        let server = FakeIMAPServer(
            capabilities: Self.nonUidplusCapabilities,
            mailboxes: ["INBOX": [Self.message(uid: 1, id: "t12b-nonuidplus@example.com")]])
        server.setUidValidity(liveEpoch, for: "INBOX")
        try server.start()
        defer { server.stop() }

        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }

        let accountId = "t12b-nonuidplus"
        let account = try FolderEpochTestFixture.makeAccount(id: accountId, provider: .imap, pool: pool)
        try FolderEpochTestFixture.insertFolder(
            accountId: accountId, path: "INBOX", role: .inbox, pool: pool, totalCount: 1)

        let before = try FolderEpochTestFixture.readFolder(accountId: accountId, path: "INBOX", pool: pool)
        #expect(before?.lastKnownUidValidity == nil, "precondition: no epoch stored yet")

        let provider = Self.provider(for: server)
        try await provider.connect()

        // Precondition that makes this test about SELECT and nothing else: the
        // STATUS source T1.2 added genuinely reports nothing on this server.
        let status = try await provider.folderStatus(path: "INBOX")
        #expect(status.uidValidity == nil,
                "precondition: a non-UIDPLUS server carries no UIDVALIDITY on STATUS, so T1.2's writers see nil")

        let engine = await Self.makeEngine(accountId: accountId, provider: provider)
        try await engine.fullSync(account: account, provider: provider)
        try? await provider.disconnect()

        let after = try FolderEpochTestFixture.readFolder(accountId: accountId, path: "INBOX", pool: pool)
        #expect(after?.lastKnownUidValidity == liveEpoch,
                """
                a folder must end up with a usable epoch even on a server that reports it \
                only on SELECT — otherwise every durable action on that account is refused \
                forever once admission fails closed
                """)
    }

    /// The second entry point named by the item: a user navigating to a folder.
    /// This drives the REAL on-open entry point —
    /// `SyncEngine.syncFolderMessages(folder:provider:)`, *"On-demand sync for a
    /// single folder (called when user navigates to it)"*, the method
    /// `AccountManager.syncFolders(_:)` (`AccountManagerFetch.swift`) calls for every folder the user
    /// navigates to (`AccountManagerFetch.swift:132`) — not the `runSyncMessages`
    /// core it currently delegates to through `syncMessages(for:provider:limit:)`.
    /// Driving the core directly would leave this test green if the on-open
    /// wrapper stopped delegating, which pins the mechanism rather than the
    /// system property.
    ///
    /// The fixture mailbox is EMPTY on purpose. `IMAPProvider.fetchMessages`
    /// SELECTs before its `selection.messageCount > 0` early return
    /// (symbol-cited, no line number), so the epoch observation this test is
    /// about happens either way — while an empty result keeps
    /// `SyncMessagesResult.newHeaders` empty, so the wrapper's post-merge
    /// side-effect branches (`indexHeadersForFTS`, `ActiveBodyQueue.shared`,
    /// `SyncEngineFullSync.swift:429-433`) never fire against process-global
    /// singletons this suite does not own.
    @Test("Opening a folder marks its epoch")
    func openingAFolderMarksItsEpoch() async throws {
        let liveEpoch = 838_202
        let server = FakeIMAPServer(
            capabilities: Self.nonUidplusCapabilities,
            mailboxes: ["Archive": []])
        server.setUidValidity(liveEpoch, for: "Archive")
        try server.start()
        defer { server.stop() }

        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }

        let accountId = "t12b-open"
        _ = try FolderEpochTestFixture.makeAccount(id: accountId, provider: .imap, pool: pool)
        try FolderEpochTestFixture.insertFolder(
            accountId: accountId, path: "Archive", role: .archive, pool: pool, totalCount: 0)
        let folder = try #require(
            try FolderEpochTestFixture.readFolder(accountId: accountId, path: "Archive", pool: pool))
        #expect(folder.lastKnownUidValidity == nil, "precondition: no epoch stored yet")

        let provider = Self.provider(for: server)
        try await provider.connect()
        let engine = await Self.makeEngine(accountId: accountId, provider: provider)
        try await engine.syncFolderMessages(folder: folder, provider: provider)
        try? await provider.disconnect()

        let after = try FolderEpochTestFixture.readFolder(accountId: accountId, path: "Archive", pool: pool)
        #expect(after?.lastKnownUidValidity == liveEpoch,
                "opening a folder is a SELECT, so it must be enough to make that folder's epoch readable")
    }

    // MARK: - The safety property: `0` is not an epoch

    /// The safety test. A server that omits `OK [UIDVALIDITY n]` from its SELECT
    /// hands SwiftMail its `UIDValidity(0)` default, and RFC 3501 §6.3.1 permits
    /// exactly that (SHOULD, not MUST). The column must stay nil — an honestly
    /// unknown epoch — because a stored `0` compares equal to the next `0` and
    /// turns every guard built on this column into a no-op.
    @Test("A SELECT that reports no epoch leaves the column nil")
    func aSelectThatReportsNoEpochLeavesTheColumnNil() async throws {
        let server = FakeIMAPServer(
            capabilities: Self.nonUidplusCapabilities,
            mailboxes: ["INBOX": [Self.message(uid: 1, id: "t12b-zero@example.com")]])
        server.suppressSelectUidValidity(for: "INBOX")
        try server.start()
        defer { server.stop() }

        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }

        let accountId = "t12b-zero"
        let account = try FolderEpochTestFixture.makeAccount(id: accountId, provider: .imap, pool: pool)
        try FolderEpochTestFixture.insertFolder(
            accountId: accountId, path: "INBOX", role: .inbox, pool: pool, totalCount: 1)

        let provider = Self.provider(for: server)
        try await provider.connect()
        let engine = await Self.makeEngine(accountId: accountId, provider: provider)
        try await engine.fullSync(account: account, provider: provider)

        let inbox = try FolderEpochTestFixture.readFolder(accountId: accountId, path: "INBOX", pool: pool)
        #expect(inbox?.lastKnownUidValidity == nil,
                """
                `0` is "the server did not report a value", never an epoch: storing it makes \
                every later epoch comparison 0 == 0, i.e. vacuously true, which silently \
                disarms the guards this column exists for
                """)
        // The sentinel is dropped at the SELECT boundary, before anything
        // downstream could mistake it for an observation.
        #expect(provider.lastObservedUidValidity(folderPath: "INBOX") == nil,
                "an unreported epoch must not even be recorded as observed")
        try? await provider.disconnect()
    }

    /// The no-fallback property, on the SAME provider instance. The observation
    /// mirror is keyed by folder path and lives as long as the provider, so a
    /// SELECT that once reported an epoch leaves an entry behind that a LATER
    /// SELECT of the same path — one that reported nothing — could still be read
    /// as an answer. It must not: `nil` is the honest value for *"the SELECT that
    /// served this fetch did not report"*, and anything else is a silent fallback
    /// (project rule 4) that hands `runSyncMessages` a value the current pass
    /// never observed and lets it persist that value as this folder's epoch.
    ///
    /// The first observation is driven through `provider.fetchMessages` alone —
    /// the same call `runSyncMessages` makes, but without the engine — so the
    /// mirror is populated exactly as production populates it while the column is
    /// still untouched. Only the SECOND pass runs the engine, so the column can
    /// only be written from what the second, non-reporting SELECT observed.
    @Test("A SELECT that stops reporting an epoch never answers with the earlier one")
    func aSelectThatStopsReportingNeverAnswersWithTheEarlierEpoch() async throws {
        let firstEpoch = 838_505
        let server = FakeIMAPServer(
            capabilities: Self.nonUidplusCapabilities,
            mailboxes: ["INBOX": [Self.message(uid: 1, id: "t12b-stale-mirror@example.com")]])
        server.setUidValidity(firstEpoch, for: "INBOX")
        try server.start()
        defer { server.stop() }

        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }

        let accountId = "t12b-stale-mirror"
        let account = try FolderEpochTestFixture.makeAccount(id: accountId, provider: .imap, pool: pool)
        try FolderEpochTestFixture.insertFolder(
            accountId: accountId, path: "INBOX", role: .inbox, pool: pool, totalCount: 1)

        let provider = Self.provider(for: server)
        try await provider.connect()

        _ = try await provider.fetchMessages(
            folder: "INBOX", limit: SyncConfig.syncMessageLimit, offset: 0)
        #expect(provider.lastObservedUidValidity(folderPath: "INBOX") == UInt32(firstEpoch),
                "precondition: the first SELECT reported an epoch and it was recorded")
        let beforeSecondPass = try FolderEpochTestFixture.readFolder(
            accountId: accountId, path: "INBOX", pool: pool)
        #expect(beforeSecondPass?.lastKnownUidValidity == nil,
                "precondition: fetching alone persists nothing, so the column is still nil")

        // The server stops reporting `OK [UIDVALIDITY n]` for this mailbox. Every
        // later SELECT of INBOX hands SwiftMail its `UIDValidity(0)` default.
        server.suppressSelectUidValidity(for: "INBOX")

        let engine = await Self.makeEngine(accountId: accountId, provider: provider)
        try await engine.fullSync(account: account, provider: provider)

        #expect(provider.lastObservedUidValidity(folderPath: "INBOX") == nil,
                """
                the entry the first SELECT left behind must be CLEARED by the second, not \
                merely left unwritten — otherwise "unknown now" reads as "known before"
                """)
        try? await provider.disconnect()

        let after = try FolderEpochTestFixture.readFolder(accountId: accountId, path: "INBOX", pool: pool)
        #expect(after?.lastKnownUidValidity == nil,
                """
                the sync pass observed nothing, so it must persist nothing: a stale mirror \
                entry would be written into the column as this folder's epoch even though no \
                SELECT in this pass ever reported it
                """)
    }

    /// The other half of the safety property, and the one a naive "just write
    /// what SELECT said" implementation gets wrong: an unreported epoch arriving
    /// at a folder that already HAS one must not clear it.
    @Test("A SELECT that reports no epoch never erases a stored epoch")
    func aSelectThatReportsNoEpochNeverErasesAStoredEpoch() async throws {
        let storedEpoch = 838_303
        let server = FakeIMAPServer(
            capabilities: Self.nonUidplusCapabilities,
            mailboxes: ["INBOX": [Self.message(uid: 1, id: "t12b-zero-keep@example.com")]])
        server.suppressSelectUidValidity(for: "INBOX")
        try server.start()
        defer { server.stop() }

        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }

        let accountId = "t12b-zero-keep"
        let account = try FolderEpochTestFixture.makeAccount(id: accountId, provider: .imap, pool: pool)
        try FolderEpochTestFixture.insertFolder(
            accountId: accountId, path: "INBOX", role: .inbox, pool: pool, totalCount: 1,
            lastKnownUidValidity: storedEpoch)

        let provider = Self.provider(for: server)
        try await provider.connect()
        let engine = await Self.makeEngine(accountId: accountId, provider: provider)
        try await engine.fullSync(account: account, provider: provider)
        try? await provider.disconnect()

        let after = try FolderEpochTestFixture.readFolder(accountId: accountId, path: "INBOX", pool: pool)
        #expect(after?.lastKnownUidValidity == storedEpoch,
                "an unknown observation is not evidence of anything and must never clear a known epoch")
    }

    // MARK: - The write rule is unchanged: BOOTSTRAP-ONLY

    /// A second SOURCE for the observation must not become a second RULE for the
    /// write. The stored value means *the epoch the LOCAL UIDs belong to*; a
    /// SELECT reporting a different one is a turnover, and stamping it here —
    /// without first purging the rows that belong to the old epoch — makes the
    /// deletion-reconcile walk's stored-vs-live comparison equal and lets it
    /// delete every local header as a ghost (ADR-IOS-051).
    @Test("A SELECT-sourced turnover never overwrites the stored epoch")
    func selectSourcedTurnoverNeverOverwritesTheStoredEpoch() async throws {
        let storedEpoch = 838_401
        let liveEpoch = 838_402
        let server = FakeIMAPServer(
            capabilities: Self.nonUidplusCapabilities,
            mailboxes: ["INBOX": [Self.message(uid: 1, id: "t12b-turnover@example.com")]])
        server.setUidValidity(liveEpoch, for: "INBOX")
        try server.start()
        defer { server.stop() }

        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }

        let accountId = "t12b-turnover"
        let account = try FolderEpochTestFixture.makeAccount(id: accountId, provider: .imap, pool: pool)
        try FolderEpochTestFixture.insertFolder(
            accountId: accountId, path: "INBOX", role: .inbox, pool: pool, totalCount: 1,
            lastKnownUidValidity: storedEpoch)

        let provider = Self.provider(for: server)
        try await provider.connect()
        let engine = await Self.makeEngine(accountId: accountId, provider: provider)
        try await engine.fullSync(account: account, provider: provider)

        // The SELECT really did report the new epoch — so this test measures a
        // refused WRITE, not a missed observation.
        #expect(provider.lastObservedUidValidity(folderPath: "INBOX") == UInt32(liveEpoch),
                "precondition: the sync's SELECT must actually have observed the turnover")
        try? await provider.disconnect()

        let after = try FolderEpochTestFixture.readFolder(accountId: accountId, path: "INBOX", pool: pool)
        #expect(after?.lastKnownUidValidity == storedEpoch,
                """
                the stored epoch describes the LOCAL UIDs, not the live server: advancing it \
                here would make the deletion-reconcile walk's stored-vs-live comparison equal \
                and delete every local header as a ghost (ADR-IOS-051)
                """)
    }

    // MARK: - Round 10, blocker 3 — the stamp must describe the MERGED batch

    /// 🚨 The epoch a sync pass stamps must be the one that served ITS OWN fetch,
    /// never whatever a concurrent SELECT last recorded in the shared mirror.
    ///
    /// Round 8 routed the backfill walk's three SELECTs through
    /// `IMAPProvider.selectMailboxTracked`, and through
    /// `fetchMessageHeaders(folder:uids:batchSize:interBatchDelay:)` that reroute
    /// also reaches self-heal and deep backfill — neither of them epoch-guarded,
    /// and `rg -n "fetchMessageHeaders\("` finds six call sites across three
    /// files, not the one the commit claimed. Any of them SELECTing this folder
    /// path between `runSyncMessages`' fetch and its read of the mirror made the
    /// pass bootstrap the LIVE epoch while merging the PREVIOUS one's headers.
    ///
    /// THE INVARIANT: **`Folder.lastKnownUidValidity` names the epoch the folder's
    /// rows belong to.** A stamp taken from the live mirror instead describes the
    /// server, and once it agrees with the live epoch the deletion-reconcile
    /// walk's abort guard compares equal-to-equal and proceeds to delete
    /// old-epoch UIDs as ghosts (ADR-IOS-051) — the mass deletion this whole
    /// train exists to prevent, relocated into another consumer.
    ///
    /// The mock reports the two SEPARATELY (`setMockedBoundFetchEpoch` is the
    /// fetch's own SELECT; `setMockedUidValidity` is the shared mirror an
    /// interloping SELECT has since advanced), because a double that cannot tell
    /// them apart cannot tell which one the pass stamped.
    @Test("The epoch stamped by a sync pass is the one that served its own fetch")
    func syncStampsTheEpochBoundToItsOwnFetch() async throws {
        let fetchEpoch: UInt32 = 838_601   // the SELECT that returned these headers
        let mirrorEpoch: UInt32 = 838_602  // a concurrent backfill SELECT, after it

        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }

        let accountId = "t12b-bound-epoch"
        _ = try FolderEpochTestFixture.makeAccount(id: accountId, provider: .imap, pool: pool)
        try FolderEpochTestFixture.insertFolder(
            accountId: accountId, path: "INBOX", role: .inbox, pool: pool, totalCount: 0)

        let folder = try #require(
            try FolderEpochTestFixture.readFolder(accountId: accountId, path: "INBOX", pool: pool))

        let mock = MockEmailProvider()
        await mock.setFetchMessagesResult([
            MessageHeaderInfo(
                messageId: "11", rfc822MessageId: "bound-epoch@example.com",
                inReplyTo: nil, references: [], threadId: nil,
                subject: "merged under fetchEpoch", from: "Sender",
                fromAddress: "sender@example.com", to: "recipient@example.com",
                cc: "", bcc: "", replyTo: nil,
                date: Date(timeIntervalSince1970: 1_700_000_000), snippet: "bound",
                isRead: false, isFlagged: false, hasAttachments: false,
                isReplied: false, isForwarded: false, actionTag: nil)
        ])
        await mock.setMockedBoundFetchEpoch(fetchEpoch, folderPath: "INBOX")
        await mock.setMockedUidValidity(mirrorEpoch, folderPath: "INBOX")

        _ = try await SyncEngine.runSyncMessages(
            for: folder, provider: mock, limit: 50, dbPool: PrioritizedDatabase(pool: pool))

        let after = try FolderEpochTestFixture.readFolder(accountId: accountId, path: "INBOX", pool: pool)
        #expect(after?.lastKnownUidValidity == Int(fetchEpoch),
                """
                the pass stamped \(String(describing: after?.lastKnownUidValidity)) — that is the \
                shared mirror's value, which a concurrent backfill/self-heal SELECT wrote AFTER \
                this fetch, not the epoch the merged headers came from (\(fetchEpoch)). The \
                column then agrees with the live server while old-epoch rows sit under it, which \
                is precisely how the deletion-reconcile walk's abort guard gets disarmed
                """)
        #expect(try FolderEpochTestFixture.headerCount(accountId: accountId, path: "INBOX", pool: pool) == 1,
                "precondition: the pass really did merge the batch it stamped for")
    }

    /// 🚨 What a conformer that does NOT override
    /// `fetchMessagesWithObservedEpoch` actually produces.
    ///
    /// The test above drives `MockEmailProvider`, which DOES override — so on its
    /// own it pins the fix's shape and says nothing about the shape everything
    /// else inherits. A mock that mirrors the fix instead of the contract has
    /// hidden a mismatch here before, and the first draft of this default
    /// delegated to `lastObservedUidValidity(folderPath:)`, which reproduces
    /// exactly the unbound read blocker 3 exists to remove: a conformer that
    /// forgot to override would silently get the defective path.
    ///
    /// THE INVARIANT: **the inherited path can never contribute an epoch it did
    /// not bind.**
    ///
    /// ⚠ The witness has to be built, and that is the finding, not an
    /// inconvenience. On today's tree the set {does not override the bound fetch}
    /// ∩ {has a populated epoch mirror} is EMPTY — the only two types that
    /// override `lastObservedUidValidity` (`IMAPProvider`, `MockEmailProvider`)
    /// also override the bound fetch. So no existing type can tell the two
    /// defaults apart, and a test written against one would pass under BOTH: that
    /// is precisely why the delegating default was invisible to review, and a
    /// non-distinguishing test would have inherited the same blindness.
    /// `MirrorOnlyProvider` below is the missing case made real — the future
    /// non-IMAP conformer that starts populating a mirror and forgets to
    /// override — and it is the one that makes this red-provable.
    /// `DemoProvider` is asserted alongside it as a PRODUCTION witness that the
    /// inheritance is real (`GmailProvider`/`ExchangeProvider` are the others;
    /// both need OAuth credentials to construct, and all three inherit the same
    /// `extension EmailProvider` implementation).
    @Test("A provider that does not override the bound fetch reports NO epoch, never the mirror")
    func aConformerThatDoesNotOverrideReportsNoEpoch() async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }

        let accountId = "t12b-default-conformer"
        _ = try FolderEpochTestFixture.makeAccount(id: accountId, provider: .imap, pool: pool)
        try FolderEpochTestFixture.insertFolder(
            accountId: accountId, path: "INBOX", role: .inbox, pool: pool, totalCount: 0)

        // The distinguishing witness: a mirror that ANSWERS, and no override.
        let mirrorOnly = MirrorOnlyProvider(mirrorEpoch: 838_701)
        #expect(mirrorOnly.lastObservedUidValidity(folderPath: "INBOX") == 838_701,
                "non-vacuity: the mirror this default must not read is populated")
        let inherited = try await mirrorOnly.fetchMessagesWithObservedEpoch(
            folder: "INBOX", limit: 50, offset: 0)
        #expect(inherited.observedEpoch == nil,
                """
                a conformer inheriting the default reported epoch \
                \(String(describing: inherited.observedEpoch)) — it came from the shared mirror, \
                which no SELECT of THIS fetch wrote. The default must pair the fetch with an \
                explicit nil, or every type that forgets to override silently gets back the \
                unbound value blocker 3 removed, and `runSyncMessages` stamps it
                """)

        // The production witness: a real conformer really does inherit this.
        let demo = DemoProvider(accountId: accountId)
        let demoFetched = try await demo.fetchMessagesWithObservedEpoch(
            folder: "INBOX", limit: 50, offset: 0)
        #expect(demoFetched.observedEpoch == nil,
                "a production conformer that does not override must contribute no epoch")
    }
}

/// A conformer with a populated `lastObservedUidValidity` mirror that does NOT
/// override `fetchMessagesWithObservedEpoch` — the one combination no existing
/// type occupies, and therefore the only witness that can distinguish the
/// explicit-nil default from a mirror-delegating one. Every other requirement is
/// an inert stub; nothing here is under test except the inherited default.
private actor MirrorOnlyProvider: EmailProvider {
    private let epoch: UInt32
    init(mirrorEpoch: UInt32) { self.epoch = mirrorEpoch }

    nonisolated func lastObservedUidValidity(folderPath: String) -> UInt32? { epoch }

    func connect() async throws {}
    func disconnect() async throws {}
    func fetchFolders() async throws -> [FolderInfo] { [] }
    func fetchMessages(folder: String, limit: Int, offset: Int) async throws -> [MessageHeaderInfo] { [] }
    func fetchMessage(id: String, folder: String) async throws -> FullMessageInfo {
        FullMessageInfo(header: MessageHeaderInfo(
            messageId: id, rfc822MessageId: nil, inReplyTo: nil, references: [], threadId: nil,
            subject: "", from: "", fromAddress: "", to: "", cc: "", bcc: "",
            replyTo: nil, date: Date(), snippet: "", isRead: false, isFlagged: false,
            hasAttachments: false, isReplied: false, isForwarded: false, actionTag: nil
        ), htmlBody: nil, textBody: nil)
    }
    func search(query: String, folder: String, after: Date?, before: Date?, from: String?, to: String?) async throws -> [MessageHeaderInfo] { [] }
    func markRead(ids: [String], folder: String) async throws {}
    func markUnread(ids: [String], folder: String) async throws {}
    func markFlagged(ids: [String], flagged: Bool, folder: String) async throws {}
    func move(ids: [String], from: String, to: String) async throws {}
    func send(draft: DraftMessage) async throws {}
    func appendToSentFolder(draft: DraftMessage, sentFolderPath: String, messageId: String) async throws -> Bool { true }
    func saveDraft(_ draft: DraftMessage, existingDraftId: String?, previousRfc822MessageId: String?, draftsFolderPath: String) async throws -> DraftSaveResult { DraftSaveResult(serverId: "") }
    func deleteDraft(draftId: String, draftsFolderPath: String) async throws {}
    func fetchHistory(since historyId: String) async throws -> HistoryResponse? { nil }
    func fetchMessageHeaders(ids: [String]) async throws -> [MessageHeaderInfo] { [] }
    func fetchTextBodies(ids: [String], folder: String) async throws -> [TextBodyFetchResult] { [] }
}
