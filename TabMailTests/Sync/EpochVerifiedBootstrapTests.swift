/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
import Synchronization
@testable import TabMail

/// T4.S6b — the VERIFIED epoch bootstrap for a pre-populated, nil-epoch folder.
///
/// `Folder.lastKnownUidValidity == nil` means UNKNOWN. It is NOT evidence of an
/// empty or fresh folder, and two production lifecycles manufacture "populated, yet
/// nil-epoch": a folder populated before migration `v63` added the column, and a
/// folder row deleted on a remote disappearance and RE-CREATED for the same path
/// (migration `v2` dropped the `messageHeader.folderId` FK, so its headers survive
/// orphaned and the deterministic `"accountId:path"` id re-adopts them). Until this
/// item the first observation simply ASSERTED those rows belonged to the epoch just
/// observed — the assertion that makes the deletion-reconcile walk's stored-vs-live
/// comparison equal, disarms its abort guard (ADR-IOS-051) and admits a bare-UID
/// durable op against a numbering nobody checked (C3).
///
/// Every expectation below names a durable SYSTEM END STATE — the mail that is
/// still there, the op row that does or does not exist, the epoch the folder ends
/// carrying, the WIRE's own answer about who occupies a UID — never a mechanism.
///
/// ## The invariants
///
///  - **INV-1 (C3 admission)** no durable operation is admitted against a numbering
///    that was never verified — and, both-sided, one IS admitted once it has been;
///  - **INV-2 (no unverified stamp)** no folder row ever simultaneously holds an
///    epoch and a header whose UID the SERVER says belongs to someone else.
///    Expressed against the `FakeIMAPServer` wire, not a column;
///  - **INV-3 (an intact numbering is NOT purged)** the over-refusal control: the
///    whole point of verified bootstrap over mark-and-purge is that a healthy
///    pre-populated folder costs one small FETCH and keeps all its mail;
///  - **INV-4 (a genuine first sync still stamps)** and pays no verification FETCH;
///  - **INV-5 🚨 (a server that reports no UIDVALIDITY is not bricked)** — the
///    ANTI-BRICK;
///  - **INV-6 (bounded, no loop)** a resolved folder issues zero further
///    verification FETCHes;
///  - **INV-7 (the walk's new refusal is not a global off-switch)** a KNOWN,
///    AGREEING epoch must still let the walk delete genuine ghosts.
///
/// ## Why INV-5 is written first and must never be relaxed
///
/// It is the mirror image of this whole item. The fix's instinct — "an unproven
/// folder is dangerous, so hand it to the reaction" — applied to a server that
/// reports no UIDVALIDITY produces a PERMANENT BRICK: the reaction purges the
/// folder, then its own step-5 `observeFreshUidValidity` returns nil and aborts, and
/// every abort leg deliberately LEAVES `uidValidityResetPendingAt` set so the folder
/// stays re-drivable. The folder is then quarantined forever — every sync skipped,
/// every gesture refused, every re-drive re-aborting — WITH ITS MAIL ALREADY
/// DELETED. Doing nothing instead leaves the column nil, which is the
/// `IOS-EPOCH-001` accepted window: refused gestures, no data touched, self-healing
/// the moment one SELECT reports an epoch.
///
/// ## Red-first evidence — MEASURED, not predicted (2026-07-31)
///
/// Four independent inversions of the fix, each built and run on its own, each
/// reverted before the next. Verbatim, trimmed to the failing expectations.
///
/// **(d) the ANTI-BRICK removed** — `guard let observedEpoch = fetched.observedEpoch,
/// observedEpoch != 0 else { return .unobservable }` replaced by
/// `let observedEpoch = fetched.observedEpoch ?? 0`:
///
/// ```
/// ✘ Test "INV-5 ANTI-BRICK: a server reporting no UIDVALIDITY never quarantines,
///   even on a proven renumber" recorded an issue at
///   EpochVerifiedBootstrapTests.swift:251:9: Expectation failed:
///   (outcome → .handedToReaction(agreements: 0, mismatches: 8)) == .unobservable
/// ✘ … :253:9: Expectation failed:
///   (folder.uidValidityResetPendingAt → 2026-08-01 01:44:24 +0000) == nil
///   ↳ the door quarantined a folder whose server reports NO UIDVALIDITY …
/// ✘ Test "INV-5: a suppressed epoch stalls the bootstrap, and one conformant SELECT
///   completes it" recorded an issue at :308:9: Expectation failed:
///   (stalled → .verified(epoch: 0)) == .unobservable
/// ```
///
/// `.verified(epoch: 0)` in the second is the whole reason `0` may never be treated
/// as an epoch: a stamped `0` makes every later `stored == live` check vacuous.
///
/// **(c) the fail-closed decision inverted** — `epochVerificationStampAllowed`
/// returning `true` unconditionally (stamp on zero agreements AND on mismatch):
///
/// ```
/// ✘ Test "INV-1: no op is admitted against an unverified numbering — and one IS
///   once it is verified" … :394:9: Expectation failed:
///   try Self.opCount(pool: pool, folderPath: "INBOX") == 0
///   … :414:9: Expectation failed: try Self.opCount(…) == 1   (4 issues)
/// ✘ Test "INV-2: a stamped folder never holds a header the wire says belongs to
///   somebody else" … :474:13: Expectation failed: (violations → [[FakeIMAPServer
///   oracle] epoch stamp mailbox=INBOX uid=1 local rfc822MessageId="msg-1@example.com"
///   but the server serves "stranger-1@example.com" at that UID, … uid=12 …]).isEmpty
///   → false
/// ✘ Test "A folder populated before its first epoch observation is quarantined, then
///   converged …" … Expectation failed: (quarantined.lastKnownUidValidity → 222222)
///   == nil ; (quarantined.uidValidityResetPendingAt → nil) != nil
/// ✘ Test run with 14 tests in 2 suites failed after 7.094 seconds with 13 issues.
/// ```
///
/// Twelve wire-oracle violations in one line is the defect stated in its own terms:
/// the folder carries epoch 900002 while the SERVER says every one of its UIDs
/// addresses a stranger's message.
///
/// **(a) the `NOT EXISTS` term dropped** from `bootstrapFolderUidValidity`'s
/// statement AND the `folderHoldsRows` guard dropped from the three-argument
/// `uidValidityBootstrapWrite`:
///
/// ```
/// ✘ Test "The pure bootstrap decision refuses once the folder holds rows" … :977:9
/// ✘ Test "The blind bootstrap statement refuses a folder that already holds rows" … :1067:9
/// ✘ Test "A folder populated before its first epoch observation …" … Expectation
///   failed: (quarantined.lastKnownUidValidity → 222222) == nil
/// ✘ Test "A delete/re-create lifecycle …" … (readopted.lastKnownUidValidity → 222222)
///   == nil ; (readopted.uidValidityResetPendingAt → nil) != nil
/// ✘ Test run with 21 tests in 3 suites failed after 4.617 seconds with 7 issues.
/// ```
///
/// **(b) the walk's nil-stored ADOPT-AND-DELETE branch restored** — see
/// `SyncEngineDeletionReconcileTests`, where the two refusal tests fail with
/// `searchedChunks → 2` and `searchCalls → [[1, 2], [3, 4]]`: the walk searched and
/// judged against an epoch it had just made up.
///
/// The suites' remaining tests stayed GREEN through every inversion, which is what
/// makes each of these a targeted red rather than a broken fixture. The deliberate
/// controls — `INV-4 control`, `INV-7`, and the CONTROL half of the blind-bootstrap
/// test — are green on BOTH shapes by construction: they exist to catch a fix that
/// became a global off-switch, so an inversion of the fix must not move them.
///
/// ## Fixture
///
/// A real `IMAPProvider` over a socket to `FakeIMAPServer`, a real GRDB folder row,
/// and the production door itself. Nothing about the epoch is injected: the
/// `INTACT` server serves the same UIDs carrying the same Message-IDs the local rows
/// hold, and the `RENUMBERED` server serves the same UIDs carrying DIFFERENT
/// Message-IDs under a new epoch — which is what a UIDVALIDITY turnover looks like
/// from the only place a client can observe it.
///
/// `.serialized, .processGlobalState` — replaces `AppDatabase.shared`, touches
/// `AccountManager.shared`'s single-flight sets and provider table, and binds a
/// listening socket.
@Suite("T4.S6b — the verified epoch bootstrap", .serialized, .processGlobalState)
struct EpochVerifiedBootstrapTests {

    // MARK: - Fixture

    private static let intactEpoch = 900_001
    private static let renumberedEpoch = 900_002
    private static let localUIDs = Array(1...12)

    private static func localRfc(uid: Int) -> String { "msg-\(uid)@example.com" }
    private static func strangerRfc(uid: Int) -> String { "stranger-\(uid)@example.com" }

    private static func rfc822Text(messageId: String) -> String {
        """
        From: Test Sender <sender@example.com>\r
        To: Recipient <recipient@example.com>\r
        Subject: epoch-verify fixture\r
        Date: Thu, 01 Jan 2026 00:00:00 +0000\r
        Message-ID: <\(messageId)>\r
        Content-Type: text/plain; charset=utf-8\r
        \r
        epoch verify fixture body.\r

        """
    }

    /// The mailbox as it stands when the numbering NEVER turned over: the same UIDs
    /// the local rows hold, carrying the same messages.
    private static func intactMailbox() -> [FakeIMAPServer.Message] {
        localUIDs.map {
            FakeIMAPServer.makeMessage(uid: $0, rfc822Text: rfc822Text(messageId: localRfc(uid: $0)))
        }
    }

    /// The mailbox after a UIDVALIDITY turnover: the numbering restarted, so the
    /// SAME UIDs now address COMPLETELY DIFFERENT messages. This is the only shape
    /// from which a client can prove a turnover happened.
    private static func renumberedMailbox() -> [FakeIMAPServer.Message] {
        localUIDs.map {
            FakeIMAPServer.makeMessage(uid: $0, rfc822Text: rfc822Text(messageId: strangerRfc(uid: $0)))
        }
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

    /// Account + folder + headers whose `rfc822MessageId` matches what the INTACT
    /// server serves at the same UID.
    @discardableResult
    private static func seed(
        pool: DatabasePool, accountId: String, folderPath: String = "INBOX",
        storedEpoch: Int? = nil, uids: [Int] = localUIDs
    ) throws -> Account {
        var account = Account(emailAddress: "\(accountId)@example.com",
                              displayName: "epoch verify fixture", provider: .imap)
        account.id = accountId
        let toInsert = account
        let folderId = "\(accountId):\(folderPath)"
        try pool.write { db in
            try toInsert.insert(db)
            var folder = Folder(name: folderPath, path: folderPath, role: .inbox, accountId: accountId)
            folder.totalCount = uids.count
            folder.lastKnownUidNext = (uids.max() ?? 0) + 1
            folder.lastKnownUidValidity = storedEpoch
            try folder.insert(db)
            for uid in uids {
                var header = MessageHeader(
                    messageId: "\(uid)", subject: "verify \(uid)", from: "Sender",
                    fromAddress: "sender@example.com", to: "recipient@example.com",
                    date: Date(timeIntervalSince1970: 1_700_000_000), snippet: "verify",
                    folderId: folderId, accountId: accountId, folderPath: folderPath,
                    isInInbox: true
                )
                header.rfc822MessageId = localRfc(uid: uid)
                header.headerComplete = true
                try header.insert(db)
            }
        }
        return account
    }

    private static func readFolder(pool: DatabasePool, folderId: String) throws -> Folder? {
        try pool.read { db in try Folder.fetchOne(db, key: folderId) }
    }

    private static func headerCount(pool: DatabasePool, folderId: String) throws -> Int {
        try pool.read { db in try MessageHeader.filter(Column("folderId") == folderId).fetchCount(db) }
    }

    /// Every local header of `folderId` as `uid -> rfc822`, the shape
    /// `FakeIMAPServer.epochStampViolations` checks against the wire.
    private static func localRfc822ByUID(pool: DatabasePool, folderId: String) throws -> [Int: String] {
        try pool.read { db in
            var map: [Int: String] = [:]
            for header in try MessageHeader.filter(Column("folderId") == folderId).fetchAll(db) {
                guard let uid = Int(header.messageId), let rfc = header.rfc822MessageId, !rfc.isEmpty
                else { continue }
                map[uid] = rfc
            }
            return map
        }
    }

    private static func opCount(pool: DatabasePool, folderPath: String) throws -> Int {
        try pool.read { db in
            try PendingOperation.fetchAll(db).filter { $0.folderPath == folderPath }.count
        }
    }

    /// Neutralise the door's spawned reaction so a phase measures the DOOR alone.
    /// The spawn is admitted through the same single-flight gate, so a seeded entry
    /// makes it a no-op. (The spawn itself is proved in INV-1 phase 1, where the
    /// recheck request the refusal records is the deterministic evidence.)
    private static func parkTheReaction(folderId: String) async {
        await AccountManager.shared.seedUidValidityReactionInFlightForTesting(folderId: folderId)
    }

    private static func unparkTheReaction(folderId: String) async {
        await AccountManager.shared.clearUidValidityReactionInFlightForTesting(folderId: folderId)
        await AccountManager.shared.clearUidValidityReactionRecheckRequestedForTesting(folderId: folderId)
    }

    private static func waitUntil(
        _ deadline: TimeInterval = 3, _ condition: () async -> Bool
    ) async {
        let end = Date().addingTimeInterval(deadline)
        while Date() < end {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    // MARK: - INV-5 🚨 THE ANTI-BRICK (written first, on purpose)

    /// 🚨 **INV-5, the adversarial half.** The numbering HAS turned over — every
    /// sampled UID now holds a stranger's message, the strongest evidence this
    /// design can obtain — but the SELECT that served the sample reports no
    /// UIDVALIDITY at all (`suppressSelectUidValidity`, which models a nonconforming
    /// server; see that seam's own doc comment). The door must STILL do nothing.
    ///
    /// A test whose sample AGREED would take the stamp path for a reason unrelated
    /// to the guard and would stay green against a door that quarantined on every
    /// unreported epoch. Here step 3 is the only thing between this fixture and a
    /// permanently bricked folder.
    ///
    /// RED: remove the `observedEpoch == nil` guard (or move it BELOW the
    /// classification) and `uidValidityResetPendingAt` is armed — the second
    /// expectation fails.
    @Test("INV-5 ANTI-BRICK: a server reporting no UIDVALIDITY never quarantines, even on a proven renumber")
    func unreportedEpochNeverQuarantinesEvenOnARenumber() async throws {
        let server = FakeIMAPServer(mailboxes: ["INBOX": Self.renumberedMailbox()])
        server.setUidValidity(Self.renumberedEpoch, for: "INBOX")
        server.suppressSelectUidValidity(for: "INBOX")
        try server.start()
        defer { server.stop() }

        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }

        let accountId = "t4s6b-antibrick"
        try Self.seed(pool: pool, accountId: accountId)
        let folderId = "\(accountId):INBOX"
        await Self.parkTheReaction(folderId: folderId)
        defer { Task { await Self.unparkTheReaction(folderId: folderId) } }

        let provider = Self.provider(for: server)
        try await provider.connect()
        let outcome = await SyncEngine.verifyAndBootstrapPrePopulatedFolderEpoch(
            folderId: folderId, folderPath: "INBOX", accountId: accountId,
            provider: provider, dbPool: AppDatabase.dbPool)

        #expect(outcome == .unobservable)
        let folder = try #require(try Self.readFolder(pool: pool, folderId: folderId))
        #expect(folder.uidValidityResetPendingAt == nil,
                """
                the door quarantined a folder whose server reports NO UIDVALIDITY. The reaction \
                purges first and only then reads the fresh epoch — which will be nil, so it \
                aborts LEAVING the quarantine set. That is a permanent brick with the mail \
                already deleted, and it is strictly worse than the accepted IOS-EPOCH-001 window.
                """)
        #expect(folder.lastKnownUidValidity == nil,
                "nothing was proved, so nothing may be stamped")
        #expect(try Self.headerCount(pool: pool, folderId: folderId) == Self.localUIDs.count,
                "the door itself must never delete mail")

        // …and it SELF-HEALS. One conformant SELECT is enough: with the epoch line
        // restored the same door now reaches the classification and — the numbering
        // really did turn over — hands the folder to the reaction. Without this half
        // the anti-brick would be indistinguishable from a door that never works.
        server.restoreSelectUidValidity(for: "INBOX")
        let afterRestore = await SyncEngine.verifyAndBootstrapPrePopulatedFolderEpoch(
            folderId: folderId, folderPath: "INBOX", accountId: accountId,
            provider: provider, dbPool: AppDatabase.dbPool)
        try? await provider.disconnect()

        #expect(afterRestore == .handedToReaction(agreements: 0, mismatches: 8),
                "one conformant SELECT must un-stick the folder: refusing forever is its own brick")
        #expect(try #require(try Self.readFolder(pool: pool, folderId: folderId))
            .uidValidityResetPendingAt != nil)
    }

    /// **INV-5, the healthy half.** Same suppression, but the numbering is INTACT.
    /// Nothing happens on the suppressed pass; the moment the server reports an
    /// epoch, the folder is stamped. The `IOS-EPOCH-001` window is BOUNDED, not
    /// permanent.
    @Test("INV-5: a suppressed epoch stalls the bootstrap, and one conformant SELECT completes it")
    func suppressedEpochStallsThenStamps() async throws {
        let server = FakeIMAPServer(mailboxes: ["INBOX": Self.intactMailbox()])
        server.setUidValidity(Self.intactEpoch, for: "INBOX")
        server.suppressSelectUidValidity(for: "INBOX")
        try server.start()
        defer { server.stop() }

        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }

        let accountId = "t4s6b-antibrick-healthy"
        try Self.seed(pool: pool, accountId: accountId)
        let folderId = "\(accountId):INBOX"
        await Self.parkTheReaction(folderId: folderId)
        defer { Task { await Self.unparkTheReaction(folderId: folderId) } }

        let provider = Self.provider(for: server)
        try await provider.connect()

        let stalled = await SyncEngine.verifyAndBootstrapPrePopulatedFolderEpoch(
            folderId: folderId, folderPath: "INBOX", accountId: accountId,
            provider: provider, dbPool: AppDatabase.dbPool)
        #expect(stalled == .unobservable)
        #expect(try #require(try Self.readFolder(pool: pool, folderId: folderId))
            .lastKnownUidValidity == nil)
        #expect(try Self.headerCount(pool: pool, folderId: folderId) == Self.localUIDs.count)

        server.restoreSelectUidValidity(for: "INBOX")
        let healed = await SyncEngine.verifyAndBootstrapPrePopulatedFolderEpoch(
            folderId: folderId, folderPath: "INBOX", accountId: accountId,
            provider: provider, dbPool: AppDatabase.dbPool)
        try? await provider.disconnect()

        #expect(healed == .verified(epoch: UInt32(Self.intactEpoch)))
        let folder = try #require(try Self.readFolder(pool: pool, folderId: folderId))
        #expect(folder.lastKnownUidValidity == Self.intactEpoch)
        #expect(folder.uidValidityResetPendingAt == nil)
        #expect(try Self.headerCount(pool: pool, folderId: folderId) == Self.localUIDs.count)
    }

    // MARK: - INV-1 — the C3 admission property, both-sided

    /// 🚨 **INV-1.** The property is about DURABLE OPERATIONS, not about a column:
    /// no `PendingOperation` may exist against a folder whose numbering was never
    /// verified, because executing one resolves a bare UID against a numbering
    /// nobody checked and mutates whichever message the server put there (C3).
    ///
    /// BOTH HALVES, in one run. A one-sided version — "no op is created" — is
    /// satisfied by a global off-switch that never admits anything, which is a
    /// different, silent product failure.
    ///
    /// The recheck request asserted in phase 1 is the deterministic evidence that
    /// the door really HANDED the folder to the reaction rather than merely arming a
    /// flag nobody will resolve: the reaction is parked behind its own single-flight
    /// gate, and a trigger arriving while it is held is RECORDED, never dropped.
    ///
    /// RED: make the door's zero-agreements leg stamp instead of react, and phase 1's
    /// `opCount == 0` fails (the folder reads as verified, so the gesture is
    /// admitted against the discarded numbering).
    @Test("INV-1: no op is admitted against an unverified numbering — and one IS once it is verified")
    func gesturesAreRefusedUntilTheNumberingIsVerified() async throws {
        let server = FakeIMAPServer(mailboxes: ["INBOX": Self.renumberedMailbox()])
        server.setUidValidity(Self.renumberedEpoch, for: "INBOX")
        try server.start()
        defer { server.stop() }

        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }

        let accountId = "t4s6b-admission"
        try Self.seed(pool: pool, accountId: accountId)
        let folderId = "\(accountId):INBOX"
        await Self.parkTheReaction(folderId: folderId)

        let provider = Self.provider(for: server)
        try await provider.connect()

        // ── Phase 1: the numbering is unverified. A gesture must not become durable.
        let beforeVerification = try #require(try await pool.read { db in
            try MessageHeader.filter(Column("folderId") == folderId).fetchOne(db)
        })
        await AccountManager.shared.markRead([beforeVerification])
        #expect(try Self.opCount(pool: pool, folderPath: "INBOX") == 0,
                """
                a durable op was admitted against a folder whose epoch is unknown. Its message ids \
                are bare UIDs in a numbering nobody has verified — the drain would resolve them \
                against whatever the server has there now (C3).
                """)

        _ = await SyncEngine.verifyAndBootstrapPrePopulatedFolderEpoch(
            folderId: folderId, folderPath: "INBOX", accountId: accountId,
            provider: provider, dbPool: AppDatabase.dbPool)
        #expect(try #require(try Self.readFolder(pool: pool, folderId: folderId))
            .uidValidityResetPendingAt != nil,
                "a proven renumber must quarantine the folder")
        await Self.waitUntil {
            await AccountManager.shared.isUidValidityReactionRecheckRequestedForTesting(folderId: folderId)
        }
        let handedOff = await AccountManager.shared
            .isUidValidityReactionRecheckRequestedForTesting(folderId: folderId)
        #expect(handedOff,
                """
                the door armed the quarantine but never handed the folder to the reaction. The \
                folder would stay quarantined with nobody to resolve it — every sync skipped and \
                every gesture refused, forever.
                """)

        await AccountManager.shared.markRead([beforeVerification])
        #expect(try Self.opCount(pool: pool, folderPath: "INBOX") == 0,
                "a folder mid-reset must refuse gestures too — the stamp would sweep them anyway")

        // ── Phase 2: let the reaction converge the folder, then re-drive the gesture.
        await Self.unparkTheReaction(folderId: folderId)
        await AccountManager.shared.registerProviderForTesting(accountId: accountId, provider: provider)
        await AccountManager.shared.runUidValidityResetReaction(accountId: accountId, folderPath: "INBOX")
        await AccountManager.shared.unregisterProviderForTesting(accountId: accountId)

        let converged = try #require(try Self.readFolder(pool: pool, folderId: folderId))
        #expect(converged.lastKnownUidValidity == Self.renumberedEpoch,
                "the reaction must leave the folder stamped with the epoch its rows now belong to")
        #expect(converged.uidValidityResetPendingAt == nil,
                "a converged folder must be out of quarantine, or every later gesture is refused forever")

        let afterVerification = try #require(try await pool.read { db in
            try MessageHeader.filter(Column("folderId") == folderId).fetchOne(db)
        })
        await AccountManager.shared.markRead([afterVerification])
        try? await provider.disconnect()
        #expect(try Self.opCount(pool: pool, folderPath: "INBOX") == 1,
                """
                the OTHER half: once the numbering is verified the user's gesture must be admitted. \
                A refusal that never lifts is a silent, total loss of agency in that folder — the \
                same failure the fix exists to avoid, wearing green.
                """)
    }

    // MARK: - INV-2 — no unverified stamp, expressed on the WIRE

    /// **INV-2.** The property is not "the column is nil"; it is that no folder ever
    /// holds an epoch TOGETHER WITH a header the SERVER says belongs to somebody
    /// else. That is a statement about the wire, so it is checked against the wire:
    /// `FakeIMAPServer.epochStampViolations` resolves every local UID to the mailbox's
    /// CURRENT occupant and reports each one whose Message-ID differs.
    ///
    /// The mid-flight reset (`resetMailboxAfterNextSuccessfulResponse`) is the chaos
    /// point for the door's own read → FETCH → write window: the mailbox is
    /// re-numbered immediately after the SELECT that serves the verification FETCH
    /// succeeds, so the door's write lands into a world that changed under it. The
    /// in-transaction re-proof of the agreeing rows is what has to hold here.
    ///
    /// RED: drop the `NOT EXISTS` term from `bootstrapFolderUidValidity` and the
    /// ordinary (non-chaos) sync pass stamps the folder while every local row still
    /// belongs to the old numbering — `epochStampViolations` returns 12.
    @Test("INV-2: a stamped folder never holds a header the wire says belongs to somebody else")
    func aStampedFolderNeverHoldsAForeignHeader() async throws {
        let server = FakeIMAPServer(mailboxes: ["INBOX": Self.intactMailbox()])
        server.setUidValidity(Self.intactEpoch, for: "INBOX")
        try server.start()
        defer { server.stop() }

        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }

        let accountId = "t4s6b-wire"
        try Self.seed(pool: pool, accountId: accountId)
        let folderId = "\(accountId):INBOX"
        await Self.parkTheReaction(folderId: folderId)
        defer { Task { await Self.unparkTheReaction(folderId: folderId) } }

        // The mailbox is re-numbered the instant the verification FETCH's SELECT
        // succeeds: the sample the door classified describes a world that no longer
        // exists by the time it writes.
        server.resetMailboxAfterNextSuccessfulResponse(
            containing: "SELECT", mailbox: "INBOX",
            uidValidity: Self.renumberedEpoch, messages: Self.renumberedMailbox())

        let provider = Self.provider(for: server)
        try await provider.connect()
        _ = await SyncEngine.verifyAndBootstrapPrePopulatedFolderEpoch(
            folderId: folderId, folderPath: "INBOX", accountId: accountId,
            provider: provider, dbPool: AppDatabase.dbPool)
        try? await provider.disconnect()

        let folder = try #require(try Self.readFolder(pool: pool, folderId: folderId))
        if folder.lastKnownUidValidity != nil {
            let violations = server.epochStampViolations(
                mailbox: "INBOX",
                localRfc822ByUID: try Self.localRfc822ByUID(pool: pool, folderId: folderId))
            #expect(violations.isEmpty,
                    """
                    the folder carries an epoch while the SERVER says \(violations.count) of its \
                    UIDs address different messages. Every one of those rows is a wrong-message \
                    mutation waiting for its first gesture (C3): \(violations)
                    """)
        }
        // Non-vacuity: whichever way the race lands, the folder must be in a state
        // SOMETHING owns — proved, or quarantined for the reaction. "Still nil and
        // not quarantined" is the pre-fix state and is not an acceptable landing.
        #expect(folder.lastKnownUidValidity != nil || folder.uidValidityResetPendingAt != nil,
                "the door left the folder exactly as unprovable as it found it")
    }

    // MARK: - INV-3 — the over-refusal control

    /// 🚨 **INV-3, the control that stops this item from becoming mark-and-purge.**
    /// A pre-populated nil-epoch folder whose numbering is INTACT — the overwhelmingly
    /// common shape, every folder that predates migration `v63` — must keep ALL its
    /// mail, get stamped, and never see the reaction. The whole justification for
    /// verifying instead of quarantining-on-sight is that this case costs one small
    /// FETCH.
    ///
    /// A capturing turnover handler records ZERO events: if this folder ever reached
    /// the trigger channel, the fix would be purging healthy mailboxes on every
    /// upgrade.
    ///
    /// RED: make the door's stamp decision unconditionally fail closed (react on
    /// every folder) and the header count drops to 0 while the handler records a
    /// turnover.
    @Test("INV-3: an intact numbering is verified and stamped — never purged, never reacted to")
    func anIntactNumberingIsStampedNotPurged() async throws {
        let server = FakeIMAPServer(mailboxes: ["INBOX": Self.intactMailbox()])
        server.setUidValidity(Self.intactEpoch, for: "INBOX")
        try server.start()
        defer { server.stop() }

        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }

        let accountId = "t4s6b-intact"
        let account = try Self.seed(pool: pool, accountId: accountId)
        let folderId = "\(accountId):INBOX"

        let raised = Mutex<Int>(0)
        AccountManager.shared.setUidValidityChangeHandlerForTesting { _, _, _, _ in
            raised.withLock { $0 += 1 }
        }
        defer { AccountManager.shared.resetUidValidityChangeHandlerForTesting() }

        let provider = Self.provider(for: server)
        try await provider.connect()
        let engine = SyncEngine()
        await engine.register(
            accountId: accountId, provider: provider,
            workQueue: ProviderWorkQueue(provider: provider,
                                         maxConcurrency: SyncConfig.imapMaxConnectionCeiling))
        try await engine.fullSync(account: account, provider: provider)
        try? await provider.disconnect()

        #expect(try Self.headerCount(pool: pool, folderId: folderId) == Self.localUIDs.count,
                """
                a healthy pre-populated folder lost mail. Verified bootstrap exists precisely so \
                this case costs ONE small FETCH instead of a purge-and-redownload of the mailbox.
                """)
        let folder = try #require(try Self.readFolder(pool: pool, folderId: folderId))
        #expect(folder.lastKnownUidValidity == Self.intactEpoch,
                "an intact numbering IS provable, and proving it is the point of the item")
        #expect(folder.uidValidityResetPendingAt == nil,
                "a proved folder must never be quarantined")
        #expect(raised.withLock { $0 } == 0,
                "a healthy folder reached the turnover trigger channel — that is a purge waiting to happen")
        #expect(server.epochStampViolations(
            mailbox: "INBOX",
            localRfc822ByUID: try Self.localRfc822ByUID(pool: pool, folderId: folderId)).isEmpty,
                "INV-2 over the stamped end state")
    }

    // MARK: - INV-4 — a genuine first sync

    /// **INV-4.** Zero local rows is a genuine first sync: there is nothing to
    /// verify, the blind bootstrap owns the case, and a verification FETCH here
    /// would tax every new folder of every account on every pass.
    ///
    /// The FETCH claim is made against the SERVER's own command log, not against a
    /// mock's call counter.
    @Test("INV-4: a genuine first sync is stamped directly and pays no verification FETCH")
    func aGenuineFirstSyncPaysNoVerificationFetch() async throws {
        let server = FakeIMAPServer(mailboxes: ["INBOX": Self.intactMailbox()])
        server.setUidValidity(Self.intactEpoch, for: "INBOX")
        try server.start()
        defer { server.stop() }

        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }

        let accountId = "t4s6b-first-sync"
        try Self.seed(pool: pool, accountId: accountId, uids: [])   // folder row, no headers
        let folderId = "\(accountId):INBOX"

        let provider = Self.provider(for: server)
        try await provider.connect()
        let commandsBefore = server.recordedCommands().count
        let outcome = await SyncEngine.verifyAndBootstrapPrePopulatedFolderEpoch(
            folderId: folderId, folderPath: "INBOX", accountId: accountId,
            provider: provider, dbPool: AppDatabase.dbPool)
        let issued = Array(server.recordedCommands().dropFirst(commandsBefore))
        try? await provider.disconnect()

        #expect(outcome == .notApplicable)
        #expect(issued.isEmpty,
                "the door spent \(issued.count) command(s) on a folder with nothing to verify: \(issued)")
        #expect(try #require(try Self.readFolder(pool: pool, folderId: folderId))
            .lastKnownUidValidity == nil,
                "the door does not stamp an empty folder — the blind bootstrap path owns that case")
    }

    /// The paired half of INV-4: the blind bootstrap really does still stamp an
    /// empty folder. Without this, INV-4 above is satisfied by a door that broke
    /// first-sync stamping entirely.
    @Test("INV-4 control: an empty folder is still stamped by the ordinary sync path")
    func anEmptyFolderIsStillStampedByTheOrdinaryPath() async throws {
        let server = FakeIMAPServer(mailboxes: ["INBOX": Self.intactMailbox()])
        server.setUidValidity(Self.intactEpoch, for: "INBOX")
        try server.start()
        defer { server.stop() }

        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }

        let accountId = "t4s6b-first-sync-control"
        let account = try Self.seed(pool: pool, accountId: accountId, uids: [])
        let folderId = "\(accountId):INBOX"

        let provider = Self.provider(for: server)
        try await provider.connect()
        let engine = SyncEngine()
        await engine.register(
            accountId: accountId, provider: provider,
            workQueue: ProviderWorkQueue(provider: provider,
                                         maxConcurrency: SyncConfig.imapMaxConnectionCeiling))
        try await engine.fullSync(account: account, provider: provider)
        try? await provider.disconnect()

        #expect(try #require(try Self.readFolder(pool: pool, folderId: folderId))
            .lastKnownUidValidity == Self.intactEpoch,
                "the NOT EXISTS term must not become a global off-switch on the blind bootstrap")
    }

    // MARK: - INV-6 — bounded, no loop

    /// **INV-6.** Once a folder carries an epoch the door is inert. This is what
    /// makes the reaction's step-6 resync safe: it re-enters `runSyncMessages`, whose
    /// head calls the door again, on a folder the reaction has just stamped. A door
    /// that re-verified would be a per-pass network tax at best and, through the
    /// reaction, an unbounded purge loop at worst.
    @Test("INV-6: a resolved folder issues zero further verification commands")
    func aResolvedFolderIssuesNoFurtherVerification() async throws {
        let server = FakeIMAPServer(mailboxes: ["INBOX": Self.intactMailbox()])
        server.setUidValidity(Self.intactEpoch, for: "INBOX")
        try server.start()
        defer { server.stop() }

        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }

        let accountId = "t4s6b-no-loop"
        try Self.seed(pool: pool, accountId: accountId)
        let folderId = "\(accountId):INBOX"
        await Self.parkTheReaction(folderId: folderId)
        defer { Task { await Self.unparkTheReaction(folderId: folderId) } }

        let provider = Self.provider(for: server)
        try await provider.connect()
        let first = await SyncEngine.verifyAndBootstrapPrePopulatedFolderEpoch(
            folderId: folderId, folderPath: "INBOX", accountId: accountId,
            provider: provider, dbPool: AppDatabase.dbPool)
        let afterFirst = server.recordedCommands().count
        let second = await SyncEngine.verifyAndBootstrapPrePopulatedFolderEpoch(
            folderId: folderId, folderPath: "INBOX", accountId: accountId,
            provider: provider, dbPool: AppDatabase.dbPool)
        let issuedBySecond = Array(server.recordedCommands().dropFirst(afterFirst))
        try? await provider.disconnect()

        #expect(first == .verified(epoch: UInt32(Self.intactEpoch)))
        #expect(second == .notApplicable, "the second pass had nothing left to prove")
        #expect(issuedBySecond.isEmpty,
                "the door re-verified an already-stamped folder: \(issuedBySecond)")
    }

    /// A QUARANTINED folder belongs to the reaction, not to the door: verifying it
    /// would race the purge and could stamp an epoch over rows the reaction is midway
    /// through deleting.
    @Test("A quarantined folder is the reaction's — the door does not touch it")
    func aQuarantinedFolderIsNotTheDoorsToStamp() async throws {
        let server = FakeIMAPServer(mailboxes: ["INBOX": Self.intactMailbox()])
        server.setUidValidity(Self.intactEpoch, for: "INBOX")
        try server.start()
        defer { server.stop() }

        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }

        let accountId = "t4s6b-quarantined"
        try Self.seed(pool: pool, accountId: accountId)
        let folderId = "\(accountId):INBOX"
        try await pool.write { db in
            guard var folder = try Folder.fetchOne(db, key: folderId) else { return }
            folder.uidValidityResetPendingAt = Date()
            try folder.update(db)
        }

        let provider = Self.provider(for: server)
        try await provider.connect()
        let commandsBefore = server.recordedCommands().count
        let outcome = await SyncEngine.verifyAndBootstrapPrePopulatedFolderEpoch(
            folderId: folderId, folderPath: "INBOX", accountId: accountId,
            provider: provider, dbPool: AppDatabase.dbPool)
        let issued = Array(server.recordedCommands().dropFirst(commandsBefore))
        try? await provider.disconnect()

        #expect(outcome == .notApplicable)
        #expect(issued.isEmpty)
        #expect(try #require(try Self.readFolder(pool: pool, folderId: folderId))
            .lastKnownUidValidity == nil,
                "stamping a folder mid-purge would leave the reaction stamping over its own work")
    }

    // MARK: - INV-7 — the walk's refusal is not a global off-switch

    /// 🚨 **INV-7.** Change (C) made `runDeletionReconcileWalk` REFUSE on an
    /// unproven epoch. The mirror-image failure is that it now refuses on
    /// EVERYTHING — a silent end to external-deletion reconciliation, which nothing
    /// else in the tree would notice.
    ///
    /// With a KNOWN stored epoch that AGREES with the live one, the walk must still
    /// delete genuine ghosts: rows the server no longer serves. This is the direct
    /// sibling of `SyncFullSyncFolderEpochTests.sameEpochStillLetsTheStaleSweepDelete`,
    /// for the other deleter.
    @Test("INV-7: with a proven, agreeing epoch the walk still deletes genuine ghosts")
    func aProvenEpochStillLetsTheWalkDelete() async throws {
        // The server serves only the first four of the twelve local UIDs: the other
        // eight were deleted by another client, which is exactly what this walk is for.
        let survivingUIDs = Array(Self.localUIDs.prefix(4))
        let messages = survivingUIDs.map {
            FakeIMAPServer.makeMessage(uid: $0, rfc822Text: Self.rfc822Text(messageId: Self.localRfc(uid: $0)))
        }
        let server = FakeIMAPServer(mailboxes: ["INBOX": messages])
        server.setUidValidity(Self.intactEpoch, for: "INBOX")
        try server.start()
        defer { server.stop() }

        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }

        let accountId = "t4s6b-walk-control"
        // Stored epoch is KNOWN and AGREES with the server — the walk's guard is
        // satisfied, so nothing about the epoch may stop it.
        try Self.seed(pool: pool, accountId: accountId, storedEpoch: Self.intactEpoch)
        let folderId = "\(accountId):INBOX"

        let provider = Self.provider(for: server)
        try await provider.connect()
        let engine = SyncEngine()
        await engine.register(
            accountId: accountId, provider: provider,
            workQueue: ProviderWorkQueue(provider: provider,
                                         maxConcurrency: SyncConfig.imapMaxConnectionCeiling))
        let folder = try #require(try Self.readFolder(pool: pool, folderId: folderId))
        await engine.reconcileExternallyDeletedMessages(
            folder: folder, provider: provider,
            expectedGhosts: Self.localUIDs.count - survivingUIDs.count)
        try? await provider.disconnect()

        #expect(try Self.headerCount(pool: pool, folderId: folderId) == survivingUIDs.count,
                """
                the walk deleted nothing even though its epoch guard was satisfied. Change (C) \
                narrows the walk to a PROVEN epoch; a walk that refuses unconditionally has \
                silently ended external-deletion reconciliation.
                """)
    }
}

// MARK: - The pure decisions

/// The classification is pure, so the fail-closed DIRECTION is testable without a
/// network or a database. These are the cases that decide whether the door purges a
/// healthy mailbox.
@Suite("T4.S6b — the epoch verification decisions")
struct EpochVerificationDecisionTests {

    private static func sample(_ uid: UInt32, _ rfc: String) -> SyncEngine.EpochVerificationSample {
        SyncEngine.EpochVerificationSample(uid: uid, normalizedRfc822: rfc)
    }

    private static func serverMessage(uid: Int, rfc822: String?) -> MessageHeaderInfo {
        MessageHeaderInfo(
            messageId: "\(uid)", rfc822MessageId: rfc822,
            inReplyTo: nil, references: [], threadId: nil, subject: "decision fixture",
            from: "Sender", fromAddress: "sender@example.com", to: "recipient@example.com",
            cc: "", bcc: "", replyTo: nil,
            date: Date(timeIntervalSince1970: 1_700_000_000), snippet: "decision fixture",
            isRead: false, isFlagged: false, hasAttachments: false,
            isReplied: false, isForwarded: false, actionTag: nil)
    }

    /// 🚨 The single most destructive misreading available here. A locally-known UID
    /// can be absent because ANOTHER CLIENT DELETED THE MESSAGE — routine on a
    /// perfectly intact mailbox. Counting absence as disagreement would hand healthy
    /// folders to the purge on every ordinary deletion burst.
    @Test("A UID the server did not return is NO EVIDENCE — never a mismatch")
    func notReturnedIsNeverAMismatch() {
        let sampled = [Self.sample(1, "a@example.com"), Self.sample(2, "b@example.com")]
        let classified = SyncEngine.classifyEpochVerificationSample(
            sampled: sampled, serverMessages: [])
        #expect(classified.mismatches.isEmpty,
                "absence is not disagreement — another client's DELETE looks exactly like this")
        #expect(classified.agreements.isEmpty,
                "…and it is not agreement either: after a renumber every HIGH local UID is simply absent")
    }

    /// …and the caller must therefore FAIL CLOSED on the all-absent shape. "Nothing
    /// was returned" is the renumber's NORMAL appearance, so treating zero agreements
    /// as consent would stamp precisely the folders this item exists to catch.
    @Test("Zero agreements is not consent — the stamp is refused")
    func zeroAgreementsFailsClosed() {
        #expect(!SyncEngine.epochVerificationStampAllowed(
            agreements: 0, mismatches: 0, minAgreements: 1))
        #expect(!SyncEngine.epochVerificationStampAllowed(
            agreements: 5, mismatches: 1, minAgreements: 1),
                "one positive mismatch outweighs any number of agreements")
        #expect(SyncEngine.epochVerificationStampAllowed(
            agreements: 1, mismatches: 0, minAgreements: 1))
    }

    /// A row returned WITHOUT an rfc822 proves nothing either way.
    /// `IMAPProvider.mapMessageInfo` can also drop rows outright, so this is a live
    /// shape, not a hypothetical.
    @Test("A returned row with no rfc822 is no evidence")
    func returnedWithoutIdentityIsNoEvidence() {
        let classified = SyncEngine.classifyEpochVerificationSample(
            sampled: [Self.sample(1, "a@example.com")],
            serverMessages: [Self.serverMessage(uid: 1, rfc822: nil)])
        #expect(classified.agreements.isEmpty)
        #expect(classified.mismatches.isEmpty)
    }

    /// 🚨 Both sides are normalized HERE. Elsewhere a stored value is compared against
    /// the column with no re-normalization, which is safe only because every write
    /// path normalizes — an invariant held by discipline. A `<a@x>` vs `a@x` skew
    /// costs a missed sibling flip there; HERE it would produce a FALSE MISMATCH on
    /// every row of every folder and drive a full purge-and-redownload.
    @Test("Angle-bracket skew must never manufacture a mismatch")
    func normalizationSkewIsNotAMismatch() {
        let classified = SyncEngine.classifyEpochVerificationSample(
            sampled: [Self.sample(1, "a@example.com")],
            serverMessages: [Self.serverMessage(uid: 1, rfc822: "<a@example.com>")])
        #expect(classified.agreements.count == 1,
                "the same identity, differently bracketed, is the SAME identity")
        #expect(classified.mismatches.isEmpty)
    }

    @Test("A genuinely different identity at the same UID IS a mismatch")
    func differentIdentityIsAMismatch() {
        let classified = SyncEngine.classifyEpochVerificationSample(
            sampled: [Self.sample(1, "mine@example.com")],
            serverMessages: [Self.serverMessage(uid: 1, rfc822: "<someone-else@example.com>")])
        #expect(classified.mismatches.count == 1)
        #expect(classified.agreements.isEmpty)
    }
}

// MARK: - Sampling

@Suite("T4.S6b — the verification sample is a spread", .serialized, .processGlobalState)
struct EpochVerificationSamplingTests {

    /// 🚨 A SPREAD, not the top N — a CORRECTNESS decision, not a performance one.
    /// After a turnover the server re-assigns `1…M`, so a LOW local UID usually
    /// EXISTS and addresses a DIFFERENT message (a positive mismatch, the strongest
    /// signal obtainable) while a HIGH local UID usually does not exist at all (no
    /// evidence). A high-only sample would reach the zero-agreements leg BY DEFAULT
    /// on a genuine renumber — still fail-closed, but purging on ABSENCE OF EVIDENCE
    /// rather than on PROOF, which is the shape that misfires on a benign
    /// top-of-folder deletion burst.
    @Test("The sample takes both the highest and the lowest UIDs")
    func theSampleIsASpread() async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }

        let accountId = "t4s6b-sample-spread"
        _ = try FolderEpochTestFixture.makeAccount(id: accountId, provider: .imap, pool: pool)
        try FolderEpochTestFixture.insertFolder(
            accountId: accountId, path: "Archive", role: .archive, pool: pool)
        try FolderEpochTestFixture.insertHeaders(
            accountId: accountId, path: "Archive", uids: Array(1...40), pool: pool)

        let sampled = try await pool.read { db in
            try SyncEngine.sampleUidsForEpochVerification(
                db, folderId: "\(accountId):Archive", highCount: 3, lowCount: 3)
        }
        #expect(Set(sampled.map(\.uid)) == Set<UInt32>([40, 39, 38, 1, 2, 3]),
                "a top-only sample can only ever produce 'no evidence' on a real renumber")
        // Ordered numerically, not lexicographically: "9" must not sort above "40".
        #expect(Array(sampled.map(\.uid).prefix(3)) == [40, 39, 38])
    }

    /// A folder smaller than the sample budget returns OVERLAPPING rows from the two
    /// halves. A duplicated row would count its agreement twice and could satisfy a
    /// higher `minAgreements` on the strength of a single message.
    @Test("A folder smaller than the budget yields each row exactly once")
    func theSampleDeduplicates() async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }

        let accountId = "t4s6b-sample-dedup"
        _ = try FolderEpochTestFixture.makeAccount(id: accountId, provider: .imap, pool: pool)
        try FolderEpochTestFixture.insertFolder(
            accountId: accountId, path: "Archive", role: .archive, pool: pool)
        try FolderEpochTestFixture.insertHeaders(
            accountId: accountId, path: "Archive", uids: [7, 8, 9], pool: pool)

        let sampled = try await pool.read { db in
            try SyncEngine.sampleUidsForEpochVerification(
                db, folderId: "\(accountId):Archive", highCount: 4, lowCount: 4)
        }
        #expect(sampled.count == 3)
        #expect(Set(sampled.map(\.uid)).count == sampled.count,
                "a duplicated row inflates the evidence count")
    }

    /// The stored value is normalized AT READ TIME, so a legacy row written before
    /// the normalization discipline cannot produce a false mismatch downstream.
    @Test("Sampled identities are normalized at read time")
    func sampledIdentitiesAreNormalized() async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }

        let accountId = "t4s6b-sample-normalize"
        _ = try FolderEpochTestFixture.makeAccount(id: accountId, provider: .imap, pool: pool)
        try FolderEpochTestFixture.insertFolder(
            accountId: accountId, path: "Archive", role: .archive, pool: pool)
        let folderId = "\(accountId):Archive"
        try await pool.write { db in
            var header = MessageHeader(
                messageId: "5", subject: "legacy", from: "Sender",
                fromAddress: "sender@example.com", to: "recipient@example.com",
                date: Date(timeIntervalSince1970: 1_700_000_000), snippet: "legacy",
                folderId: folderId, accountId: accountId, folderPath: "Archive",
                isInInbox: false)
            header.rfc822MessageId = "<legacy@example.com>"   // stored WITH brackets
            try header.insert(db)
        }

        let sampled = try await pool.read { db in
            try SyncEngine.sampleUidsForEpochVerification(
                db, folderId: folderId, highCount: 4, lowCount: 4)
        }
        #expect(sampled.count == 1)
        guard sampled.count == 1 else { return }
        #expect(sampled[0].normalizedRfc822 == "legacy@example.com")
    }

    /// A row with no identity can only ever produce "no evidence", so spending the
    /// sample budget on it weakens the verification for nothing.
    @Test("Rows without an rfc822 are excluded from the sample")
    func rowsWithoutIdentityAreNotSampled() async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }

        let accountId = "t4s6b-sample-no-id"
        _ = try FolderEpochTestFixture.makeAccount(id: accountId, provider: .imap, pool: pool)
        try FolderEpochTestFixture.insertFolder(
            accountId: accountId, path: "Archive", role: .archive, pool: pool)
        let folderId = "\(accountId):Archive"
        try FolderEpochTestFixture.insertHeaders(
            accountId: accountId, path: "Archive", uids: [1], pool: pool)
        try await pool.write { db in
            for uid in [2, 3] {
                let header = MessageHeader(
                    messageId: "\(uid)", subject: "no id", from: "Sender",
                    fromAddress: "sender@example.com", to: "recipient@example.com",
                    date: Date(timeIntervalSince1970: 1_700_000_000), snippet: "no id",
                    folderId: folderId, accountId: accountId, folderPath: "Archive",
                    isInInbox: false)
                try header.insert(db)
            }
        }

        let sampled = try await pool.read { db in
            try SyncEngine.sampleUidsForEpochVerification(
                db, folderId: folderId, highCount: 4, lowCount: 4)
        }
        #expect(sampled.map(\.uid) == [1])
    }

    /// INV-1 at the pure decision: the two `fullSync` folder-list upsert arms set
    /// several columns in one statement and so cannot route through
    /// `bootstrapFolderUidValidity`; they take the header-existence term as an
    /// argument instead. Same contract, expressed where they can consume it.
    @Test("The pure bootstrap decision refuses once the folder holds rows")
    func bootstrapDecisionRefusesWhenTheFolderHoldsRows() {
        // Holds rows ⇒ never, whatever is observed or stored.
        #expect(SyncEngine.uidValidityBootstrapWrite(
            observed: 100, stored: nil, folderHoldsRows: true) == nil)
        #expect(SyncEngine.uidValidityBootstrapWrite(
            observed: 100, stored: 100, folderHoldsRows: true) == nil)
        // Empty ⇒ exactly the two-argument contract, unchanged.
        #expect(SyncEngine.uidValidityBootstrapWrite(
            observed: 100, stored: nil, folderHoldsRows: false) == 100)
        #expect(SyncEngine.uidValidityBootstrapWrite(
            observed: 0, stored: nil, folderHoldsRows: false) == nil)
        #expect(SyncEngine.uidValidityBootstrapWrite(
            observed: 222, stored: 111, folderHoldsRows: false) == nil)
    }

    /// 🚨 The FAIL-SAFE for every OTHER mock-driven suite. The
    /// `extension EmailProvider` default for `sampleHeadersForEpochVerification`
    /// answers `([], nil)`, which the door reads as "the server reported no
    /// UIDVALIDITY ⇒ do nothing" — so a mock-driven test of the verified door that
    /// inherited the default would take the ANTI-BRICK leg and pass without ever
    /// executing the branch it was written for. `MockEmailProvider` therefore
    /// overrides it, and this test is what proves the override is wired: configure an
    /// AGREEING sample and the mock-driven door must reach the stamp.
    @Test("MockEmailProvider really overrides the verification seam (no vacuous anti-brick green)")
    func mockProviderHonoursTheVerificationSeam() async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }

        let accountId = "t4s6b-mock-seam"
        _ = try FolderEpochTestFixture.makeAccount(id: accountId, provider: .imap, pool: pool)
        try FolderEpochTestFixture.insertFolder(
            accountId: accountId, path: "Archive", role: .archive, pool: pool, totalCount: 2)
        let uids = [61, 62]
        try FolderEpochTestFixture.insertHeaders(
            accountId: accountId, path: "Archive", uids: uids, pool: pool)

        let mock = MockEmailProvider()
        await mock.setMockedEpochSample(
            messages: uids.map { uid in
                MessageHeaderInfo(
                    messageId: "\(uid)",
                    // `FolderEpochTestFixture.insertHeaders` stores this exact id.
                    rfc822MessageId: "epoch-fixture-\(uid)@example.com",
                    inReplyTo: nil, references: [], threadId: nil, subject: "seam",
                    from: "Sender", fromAddress: "sender@example.com",
                    to: "recipient@example.com", cc: "", bcc: "", replyTo: nil,
                    date: Date(timeIntervalSince1970: 1_700_000_000), snippet: "seam",
                    isRead: false, isFlagged: false, hasAttachments: false,
                    isReplied: false, isForwarded: false, actionTag: nil)
            },
            observedEpoch: 640_001, folderPath: "Archive")

        let outcome = await SyncEngine.verifyAndBootstrapPrePopulatedFolderEpoch(
            folderId: "\(accountId):Archive", folderPath: "Archive", accountId: accountId,
            provider: mock, dbPool: AppDatabase.dbPool)

        #expect(outcome == .verified(epoch: 640_001),
                """
                the mock fell through to the protocol default, so the door took the "server \
                reports no UIDVALIDITY" leg. Every mock-driven epoch test would then be \
                vacuously green.
                """)
        #expect(mock.epochSampleCalls().count == 1)
        #expect(try FolderEpochTestFixture.readFolder(
            accountId: accountId, path: "Archive", pool: pool)?.lastKnownUidValidity == 640_001)
    }

    /// INV-1 at the writer. `bootstrapFolderUidValidity` is the blind bootstrap every
    /// ordinary sync path routes through; its `NOT EXISTS` term is evaluated IN THE
    /// STATEMENT, not in a Swift `if` over a pre-suspension snapshot, so a row
    /// inserted between a read and the write cannot slip a stamp through.
    @Test("The blind bootstrap statement refuses a folder that already holds rows")
    func blindBootstrapRefusesAPopulatedFolder() async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }

        let accountId = "t4s6b-blind-writer"
        _ = try FolderEpochTestFixture.makeAccount(id: accountId, provider: .imap, pool: pool)
        try FolderEpochTestFixture.insertFolder(
            accountId: accountId, path: "Archive", role: .archive, pool: pool)
        try FolderEpochTestFixture.insertFolder(
            accountId: accountId, path: "Sent", role: .sent, pool: pool)
        try FolderEpochTestFixture.insertHeaders(
            accountId: accountId, path: "Archive", uids: [1, 2, 3], pool: pool)

        try await pool.write { db in
            try SyncEngine.bootstrapFolderUidValidity(
                db, folderId: "\(accountId):Archive", observed: 999)
            try SyncEngine.bootstrapFolderUidValidity(
                db, folderId: "\(accountId):Sent", observed: 999)
        }

        #expect(try FolderEpochTestFixture.readFolder(
            accountId: accountId, path: "Archive", pool: pool)?.lastKnownUidValidity == nil,
                """
                a folder holding rows was stamped by ASSERTION. That stamp is what makes the \
                deletion-reconcile walk's stored-vs-live comparison equal, disarming its abort \
                guard and turning it into a mass deleter (ADR-IOS-051).
                """)
        #expect(try FolderEpochTestFixture.readFolder(
            accountId: accountId, path: "Sent", pool: pool)?.lastKnownUidValidity == 999,
                """
                CONTROL: an EMPTY folder must still bootstrap. A guard that switched the blind \
                path off everywhere would leave every genuine first sync unstamped, which is a \
                different bug wearing this one's green.
                """)
    }
}
