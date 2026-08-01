/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
import Synchronization
@testable import TabMail

/// **THE INVARIANT: no SYNC DELETER destroys local mail on a UIDVALIDITY
/// turnover.**
///
/// Every assertion here is on the SYSTEM PROPERTY — pre-turnover messages still
/// exist — never on the mechanism that delivers it ("the column was not
/// written"). A mechanism test inherits the spec's error; this one cannot.
///
/// ⚠ **T4.S6 SHARPENED THE INVARIANT, and did not weaken it.** The reaction that
/// landed with it (`AccountManager.runUidValidityResetReaction`) DELIBERATELY
/// deletes the old epoch's rows — that is the *recover* half this file's own
/// closing note asked for, and it deletes only after quarantining the folder,
/// parking its durable ops and committing to a resync. So the invariant is not
/// "nothing ever deletes"; it is "**nothing deletes as a SIDE EFFECT of merging or
/// reconciling** — deletion happens only through the reaction, which is answerable
/// for replacing what it removed". These two blocker tests pin the first half: the
/// deletion-reconcile walk and the merge pass must not destroy mail on a turnover.
/// They stub the reaction out (each installs a capturing
/// `setUidValidityChangeHandlerForTesting`) precisely so that the
/// deleters, not the recoverer, are what is under test. The reaction has its own
/// suite, `UidValidityResetReactionTests`.
///
/// ## Why the existing reconcile tests could not see this
///
/// Every case in `SyncEngineDeletionReconcileTests` calls
/// `SyncEngine.runDeletionReconcileWalk` as a pure function and passes
/// `storedUidValidity:` **as a parameter** (`:146, :157, :191, :206, …`). The
/// regression lived in who WRITES that value, so a suite that supplies it by
/// hand is structurally blind to it — which is exactly how 7,750 green tests sat
/// on top of a mass-deletion defect. These tests therefore drive the REAL
/// entry points end-to-end: a real `SyncEngine`, a real GRDB `folder` row, a real
/// `IMAPProvider` over a socket to `FakeIMAPServer`, and the production
/// `reconcileExternallyDeletedMessages` call that `performDeltaSync` / `fullSync`
/// make themselves. Nothing about the epoch is injected.
///
/// ## Red-first evidence — MEASURED, not predicted (2026-07-30)
///
/// The bootstrap-only rule was reverted in place (`uidValidityBootstrapWrite`
/// made unconditional, and the `lastKnownUidValidity IS NULL` predicate dropped
/// from both conditional UPDATEs), reproducing the uncommitted T1.2 shape where
/// every sync path keeps the column synced to the LIVE server epoch. Verbatim
/// from that run:
///
/// ```
/// [BGSyncLog] reconcileWalk: INBOX deleted=2100 failed=0 aborted=false
/// ✘ Test "A UIDVALIDITY turnover deletes no local mail (delta sync)" recorded an
///   issue at UidValidityTurnoverDeletionGuardTests.swift:223:9: Expectation
///   failed: try Self.survivingPreTurnoverCount(...) == Self.localHeaderCount
///   ↳ a UIDVALIDITY turnover must delete NO local mail: every local UID belongs
///     to the old numbering …
/// ✘ Test "… (delta sync)" failed after 1.544 seconds with 1 issue.
///
/// [BGSyncLog] reconcileWalk: INBOX deleted=2100 failed=0 aborted=false
/// ✘ Test "A UIDVALIDITY turnover deletes no local mail (full sync)" recorded an
///   issue at UidValidityTurnoverDeletionGuardTests.swift:260:9: Expectation
///   failed: try Self.survivingPreTurnoverCount(...) == Self.localHeaderCount
/// ✘ Test "… (full sync)" failed after 1.391 seconds with 1 issue.
///
/// ✘ Test run with 3 tests in 1 suite failed after 4.007 seconds with 3 issues
///   (including 1 known issue).
/// ```
///
/// `deleted=2100 … aborted=false` is the whole defect in one line: the walk did
/// not abort, and every pre-turnover header in the folder was destroyed — the
/// stored epoch had been overwritten to the live one, so its
/// stored-vs-live comparison was vacuously equal.
///
/// With the fix the stored epoch stays `111111`, the walk aborts on its first
/// chunk, and `survivors == 2100`.
///
/// ## Fixture shape — and why it is NOT "10 messages at the top of the window"
///
/// The turnover must be isolated from a SECOND, independent deletion path that
/// would otherwise mask it: `runSyncMessages`'s windowed stale sweep. That sweep
/// has **no UIDVALIDITY guard at all** and its complete-knowledge branch
/// (`selectStaleHeaders`, `fetched.count < limit`) deletes *every* local row not
/// in the fetch — so any fixture where the server returns fewer than
/// `SyncConfig.syncMessageLimit` messages loses all the local mail BEFORE the
/// reconcile walk runs, on the pre-fix AND post-fix tree alike, and can prove
/// nothing about the walk. (That sweep is a separate pre-existing turnover
/// hazard; see this task's report.) The fixture therefore pins the sweep out:
///
/// - the fake serves **60** messages (> `syncMessageLimit` = 50) so the fetch
///   fills its window and the complete-knowledge branch is unreachable;
/// - every server UID (5000+) is ABOVE every local UID (1000-3099), so the
///   windowed branch's UID floor excludes all pre-turnover rows;
/// - the folder holds **2100** rows (> `SyncConfig.staleDetectionMaxFullScan` =
///   2000), so even a short/partial fetch cannot reach the complete-knowledge
///   branch. Belt AND braces: a parse hiccup in the fetch cannot turn this test
///   into a false red.
///
/// What remains is exactly one deleter: the deletion-reconcile walk.
///
/// ⚠ **Read the scope of THIS fixture honestly.** Because it pins the windowed
/// sweep out, a green run here proves only that *the reconcile walk* deletes
/// nothing on a turnover. The sweep is the second, independent deleter.
///
/// 🚨 **THE SWEEP WAS NOT CLOSED WHEN THIS WAS WRITTEN.** `runSyncMessages` deleted
/// stale rows with no UIDVALIDITY guard on HEAD, and that item deliberately left the
/// path byte-equivalent rather than widening it — an unclosed *residual*, not a
/// regression introduced there. It was pinned executably, NOT fixed, by
/// `SyncFullSyncFolderEpochTests.turnoverFetchIsAnUnguardedDeleter`
/// (`withKnownIssue`), with the paired control `sameEpochStillLetsTheStaleSweepDelete`
/// proving a future guard must not become a global off-switch.
///
/// Closing it meant porting `v2final`'s §5.5 universal in-txn merge guard
/// (`git show v2final:TabMail/Services/Sync/SyncEngineFullSync.swift`, ~1046-1072,
/// `uidValidityWriteAllowed`) into `runSyncMessages` — but **that guard must not
/// ship alone.** Ported by itself under bootstrap-only semantics it correctly
/// refuses the old-epoch merge while nothing ever stamps the new epoch, so the
/// folder never recovers: a deletion bug becomes a permanent-stall bug. It is the
/// *stop* half of a stop-and-recover pair whose *recover* half is the D5
/// purge-and-resync reaction (plan item T4.S6). Land them together.
///
/// ✅ **T4.S6 landed them together.** `runSyncMessages` now re-reads the folder row
/// inside its own write transaction and, when a KNOWN stored epoch disagrees with the
/// epoch the SELECT that served this fetch reported, abandons the whole pass before
/// any deletion or upsert and raises the turnover on the trigger channel. Both sides
/// nil-known is required, so a non-UIDPLUS server or a first sync still fails OPEN —
/// which is why `turnoverFetchIsAnUnguardedDeleter` (whose mock reports no bound
/// fetch epoch) legitimately still records its known issue: it pins the
/// UNKNOWN-epoch arm, which the guard deliberately does not refuse.
///
/// `.serialized, .processGlobalState` — replaces `AppDatabase.shared` and binds a
/// listening socket.
@Suite("UIDVALIDITY turnover deletes no local mail", .serialized, .processGlobalState)
struct UidValidityTurnoverDeletionGuardTests {

    // MARK: - Fixture

    private static let oldEpoch = 111_111
    private static let newEpoch = 222_222
    private static let localHeaderCount = 2100
    private static let firstLocalUID = 1000
    private static let serverMessageCount = 60
    private static let firstServerUID = 5000

    /// A turnover as the PRODUCTION trigger channel reports it
    /// (`AccountManager.fireUidValidityChangeHandler`). Capturing it is what keeps
    /// the two blocker tests non-vacuous now that T4.S6 stops the pass instead of
    /// letting it merge — see the preconditions in each test.
    struct RaisedTurnover: Sendable, Equatable {
        let accountId: String
        let folderPath: String
        let stored: UInt32
        let observed: UInt32
    }


    private static func rfc822(messageId: String) -> String {
        """
        From: Test Sender <sender@example.com>\r
        To: Recipient <recipient@example.com>\r
        Subject: turnover-fixture\r
        Date: Thu, 01 Jan 2026 00:00:00 +0000\r
        Message-ID: <\(messageId)>\r
        Content-Type: text/plain; charset=utf-8\r
        \r
        turnover fixture body.\r

        """
    }

    /// The mailbox as it exists AFTER the turnover: a fresh numbering, high UIDs,
    /// and more messages than one fetch window holds.
    private static func postTurnoverMessages() -> [FakeIMAPServer.Message] {
        (0..<serverMessageCount).map { i in
            FakeIMAPServer.makeMessage(
                uid: firstServerUID + i,
                rfc822Text: rfc822(messageId: "post-turnover-\(firstServerUID + i)@example.com"))
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

    /// Account + folder + `localHeaderCount` headers carrying the OLD epoch's UIDs.
    /// `storedEpoch` is what the folder row claims its local UIDs belong to.
    private static func seed(
        pool: DatabasePool, accountId: String, folderPath: String, role: FolderRole,
        storedEpoch: Int?, totalCount: Int, lastKnownUidNext: Int?
    ) throws -> Account {
        var account = Account(emailAddress: "\(accountId)@example.com", displayName: "turnover fixture", provider: .imap)
        account.id = accountId
        let toInsert = account
        let folderId = "\(accountId):\(folderPath)"
        try pool.write { db in
            try toInsert.insert(db)
            var folder = Folder(name: folderPath, path: folderPath, role: role, accountId: accountId)
            folder.totalCount = totalCount
            folder.lastKnownUidNext = lastKnownUidNext
            folder.lastKnownUidValidity = storedEpoch
            try folder.insert(db)
            for i in 0..<localHeaderCount {
                let uid = firstLocalUID + i
                var header = MessageHeader(
                    messageId: "\(uid)", subject: "pre-turnover \(uid)", from: "Sender",
                    fromAddress: "sender@example.com", to: "recipient@example.com",
                    date: Date(timeIntervalSince1970: 1_700_000_000), snippet: "pre-turnover",
                    folderId: folderId, accountId: accountId, folderPath: folderPath,
                    isInInbox: role == .inbox
                )
                header.rfc822MessageId = "pre-turnover-\(uid)@example.com"
                header.headerComplete = true
                try header.insert(db)
            }
        }
        return account
    }

    /// The only assertion that matters: how much pre-turnover mail is still here.
    private static func survivingPreTurnoverCount(pool: DatabasePool, folderId: String) throws -> Int {
        try pool.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM messageHeader
                WHERE folderId = ? AND CAST(messageId AS INTEGER) < ?
                """, arguments: [folderId, firstServerUID]) ?? -1
        }
    }

    private static func postTurnoverCount(pool: DatabasePool, folderId: String) throws -> Int {
        try pool.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM messageHeader
                WHERE folderId = ? AND CAST(messageId AS INTEGER) >= ?
                """, arguments: [folderId, firstServerUID]) ?? -1
        }
    }

    private static func makeEngine(accountId: String, provider: IMAPProvider) async -> SyncEngine {
        let engine = SyncEngine()
        await engine.register(
            accountId: accountId, provider: provider,
            workQueue: ProviderWorkQueue(provider: provider, maxConcurrency: SyncConfig.imapMaxConnectionCeiling))
        return engine
    }

    // MARK: - The blocker

    @Test("A UIDVALIDITY turnover deletes no local mail (delta sync)")
    func turnoverThroughDeltaSyncDeletesNoLocalMail() async throws {
        let server = FakeIMAPServer(mailboxes: ["INBOX": Self.postTurnoverMessages()])
        server.setUidValidity(Self.newEpoch, for: "INBOX")
        try server.start()
        defer { server.stop() }

        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }

        let accountId = "turnover-delta"
        let folderId = "\(accountId):INBOX"
        // Swap the production change handler for a capturing one. This also keeps the
        // real reaction from being spawned mid-test: this test is about what the
        // DELETION PATHS do on a turnover, and the reaction is a separate subject
        // with its own suite (`UidValidityResetReactionTests`). Inlined rather than
        // factored into a helper because `Mutex` is `~Copyable` and cannot be passed
        // as an ordinary parameter.
        let observed = Mutex<[RaisedTurnover]>([])
        AccountManager.shared.setUidValidityChangeHandlerForTesting { acct, path, stored, live in
            observed.withLock {
                $0.append(RaisedTurnover(accountId: acct, folderPath: path, stored: stored, observed: live))
            }
        }
        defer { AccountManager.shared.resetUidValidityChangeHandlerForTesting() }
        // The folder as the last pre-turnover sync left it: its rows, its UIDNEXT,
        // and the epoch those rows belong to.
        let account = try Self.seed(
            pool: pool, accountId: accountId, folderPath: "INBOX", role: .inbox,
            storedEpoch: Self.oldEpoch, totalCount: Self.localHeaderCount,
            lastKnownUidNext: Self.firstLocalUID + Self.localHeaderCount)

        #expect(try Self.survivingPreTurnoverCount(pool: pool, folderId: folderId) == Self.localHeaderCount,
                "precondition: the folder starts with all its pre-turnover mail")

        let provider = Self.provider(for: server)
        try await provider.connect()
        let engine = await Self.makeEngine(accountId: accountId, provider: provider)
        let outcome = try await engine.performDeltaSync(account: account, provider: provider)
        try? await provider.disconnect()

        #expect(outcome.succeeded == true)
        // NON-VACUITY. This used to assert that the pass had fetched the new epoch's
        // messages. T4.S6 made that unsatisfiable BY DESIGN: delta sync now compares
        // the STATUS epoch against the stored one and skips the folder outright on a
        // proven turnover, so nothing is merged and nothing is fetched. What still
        // proves the turnover reached production code is the trigger itself — the
        // same channel the reaction listens on — captured here with the exact epochs
        // the fixture set up. If the sync path stopped observing the turnover, this
        // is empty and the survivor assertion below can no longer pass vacuously.
        //
        // The COUNT is deliberately not pinned. A sync pass may pass more than one
        // independent guard that observes the same turnover (the full-sync sibling
        // below passes two), and the reaction's single-flight admission is what
        // collapses them — "exactly once" would be an assertion about how many
        // guards happen to exist today, not about the invariant.
        let events = observed.withLock { $0 }
        #expect(events.isEmpty == false,
                "precondition: the turnover must have been observed and raised")
        #expect(events.allSatisfy {
                    $0.accountId == accountId && $0.folderPath == "INBOX"
                        && $0.stored == UInt32(Self.oldEpoch)
                        && $0.observed == UInt32(Self.newEpoch)
                },
                "precondition: every raised turnover must be THIS folder's, old → new")

        #expect(try Self.survivingPreTurnoverCount(pool: pool, folderId: folderId) == Self.localHeaderCount,
                """
                a UIDVALIDITY turnover must delete NO local mail: every local UID belongs to \
                the old numbering, so 'the server does not have UID n' is not evidence that \
                message n is gone (ADR-IOS-051 — never delete on uncertainty)
                """)
    }

    @Test("A UIDVALIDITY turnover deletes no local mail (full sync)")
    func turnoverThroughFullSyncDeletesNoLocalMail() async throws {
        let server = FakeIMAPServer(mailboxes: ["INBOX": Self.postTurnoverMessages()])
        server.setUidValidity(Self.newEpoch, for: "INBOX")
        try server.start()
        defer { server.stop() }

        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }

        let accountId = "turnover-fullsync"
        let folderId = "\(accountId):INBOX"
        // Swap the production change handler for a capturing one. This also keeps the
        // real reaction from being spawned mid-test: this test is about what the
        // DELETION PATHS do on a turnover, and the reaction is a separate subject
        // with its own suite (`UidValidityResetReactionTests`). Inlined rather than
        // factored into a helper because `Mutex` is `~Copyable` and cannot be passed
        // as an ordinary parameter.
        let observed = Mutex<[RaisedTurnover]>([])
        AccountManager.shared.setUidValidityChangeHandlerForTesting { acct, path, stored, live in
            observed.withLock {
                $0.append(RaisedTurnover(accountId: acct, folderPath: path, stored: stored, observed: live))
            }
        }
        defer { AccountManager.shared.resetUidValidityChangeHandlerForTesting() }
        let account = try Self.seed(
            pool: pool, accountId: accountId, folderPath: "INBOX", role: .inbox,
            storedEpoch: Self.oldEpoch, totalCount: Self.localHeaderCount,
            lastKnownUidNext: Self.firstLocalUID + Self.localHeaderCount)

        #expect(try Self.survivingPreTurnoverCount(pool: pool, folderId: folderId) == Self.localHeaderCount,
                "precondition: the folder starts with all its pre-turnover mail")

        let provider = Self.provider(for: server)
        try await provider.connect()
        let engine = await Self.makeEngine(accountId: accountId, provider: provider)
        try await engine.fullSync(account: account, provider: provider)
        try? await provider.disconnect()

        // NON-VACUITY — see the delta case. The full-sync merge pass now ABANDONS
        // itself in-transaction on a proven turnover, so "it fetched the new epoch's
        // messages" is no longer a reachable precondition. The walk still runs (it
        // logs `aborted=true`), and the trigger below is the evidence the turnover
        // was seen at all.
        //
        // This path raises the SAME turnover from two independent guards — the merge
        // pass abandoning in-transaction, and the deletion-reconcile walk aborting —
        // which is why the count is not pinned. Both are real observations of a real
        // turnover; the reaction's single-flight admission (`uidValidityReactionInFlight`
        // + the recheck flag) is what makes raising it twice harmless.
        let events = observed.withLock { $0 }
        #expect(events.isEmpty == false,
                "precondition: the turnover must have been observed and raised")
        #expect(events.allSatisfy {
                    $0.accountId == accountId && $0.folderPath == "INBOX"
                        && $0.stored == UInt32(Self.oldEpoch)
                        && $0.observed == UInt32(Self.newEpoch)
                },
                "precondition: every raised turnover must be THIS folder's, old → new")

        #expect(try Self.survivingPreTurnoverCount(pool: pool, folderId: folderId) == Self.localHeaderCount,
                """
                a UIDVALIDITY turnover must delete NO local mail, whichever sync path \
                observed the new epoch
                """)
    }

    // MARK: - The hole the bootstrap rule did NOT close — CLOSED by T4.S6b

    /// ⚠ **EVERYTHING FROM HERE TO THE "✅ T4.S6b CLOSED" NOTE DESCRIBES THE STATE
    /// BEFORE T4.S6b.** It is preserved verbatim because it is the derivation of
    /// the two lifecycles the tests below still drive, and because the reasoning
    /// about WHY `nil` is unprovable is what the fix had to answer. Read it as
    /// history; the current contract is the ✅ note.
    ///
    /// **KNOWN OPEN DEFECT — recorded, not blessed.** `withKnownIssue` keeps this
    /// executable and honest: it documents the hole in code instead of prose, and
    /// it will start FAILING ("known issue was not recorded") the moment the hole
    /// is closed, forcing this test to be promoted rather than forgotten.
    ///
    /// The bootstrap rule protects a folder whose epoch is KNOWN. It cannot
    /// protect one whose epoch is nil, because nil is ambiguous: it means both
    /// "brand-new folder" and "folder full of old-epoch mail we never stamped".
    /// This lifecycle manufactures the second meaning through production code
    /// only:
    ///
    /// 1. Archive syncs normally at epoch E1 → row + headers, epoch stamped E1.
    /// 2. The mailbox disappears server-side. Full sync deletes the `folder` row —
    ///    and its headers SURVIVE, orphaned: migration `v2_dropMessageHeaderFolderFK`
    ///    removed the `messageHeader.folderId → folder` foreign key, so there is no
    ///    cascade (the comment at the deletion site claiming one is stale).
    /// 3. The same path reappears at epoch E2. `Folder.id` is the deterministic
    ///    `"\(accountId):\(path)"`, so the freshly inserted row — with a **nil**
    ///    epoch — re-adopts the orphaned E1 headers.
    /// 4. Bootstrap stamps E2 onto that row, the walk reads E2, the live SELECT
    ///    reports E2, the guard compares equal, and the E1 mail is deleted.
    ///
    /// Closing it requires a whole-folder epoch-ADVANCEMENT protocol (the
    /// `v2final` line's ADR-IOS-061 quarantine → purge → stamp → resync), or a
    /// decision about what a nil epoch over a non-empty folder may assert. That is
    /// an owner-level design call, deliberately not made inside this fix.
    /// **KNOWN OPEN DEFECT — residual path (a), the OTHER way a nil epoch arises.**
    ///
    /// The delete/re-create test below covers path (b): a folder row deleted and
    /// re-created, re-adopting orphaned headers. This one covers path (a): a folder
    /// that was POPULATED BEFORE ITS EPOCH WAS EVER OBSERVED — the state of every
    /// folder that existed before migration v63 added the column, and of any folder
    /// whose mail arrived through a path that never recorded an epoch.
    ///
    /// The two are genuinely independent, and that is the whole point of pinning
    /// them separately: a narrow fix aimed at orphan re-adoption (path b) would make
    /// the other test start passing while THIS exposure is untouched — a green suite
    /// certifying a still-broken invariant. Neither test may be retired until a
    /// whole-folder epoch-ADVANCEMENT protocol makes `nil` mean something provable.
    ///
    /// The sequence uses production code only: a non-empty folder with a nil epoch
    /// is handed a live epoch by the bootstrap, which ASSERTS that the rows already
    /// present belong to it. They do not — they predate any observation — and the
    /// walk then deletes them as ghosts.
    ///
    /// ✅ **T4.S6b CLOSED BOTH RESIDUALS. The two tests below are REWRITTEN, not
    /// retired** — same two lifecycles, same fixtures, asserting the invariant the
    /// fix delivers instead of the defect it removed.
    ///
    /// ⚠ **The rewritten expectation is NOT `survivors == localHeaderCount`, and
    /// that is not a weakened fix.** `nil` means UNKNOWN, so the fix cannot make
    /// unprovable mail provable; what it can do — and now does — is refuse to
    /// ASSERT. The door FETCHes a spread of the folder's own UIDs and asks the
    /// server whether they still address the same messages. Here they do not (the
    /// server is on a fresh numbering starting at 5000, so not one local UID
    /// resolves), the stamp is refused, and the folder is quarantined and handed to
    /// the purge-and-resync reaction. The reaction then deletes the old-epoch rows
    /// AND replaces them with the server's current mail, which is the "answerable
    /// for replacing what it removed" half of this suite's own invariant.
    ///
    /// So both tests now assert, in ONE run and in this order:
    ///  1. **the sync pass itself deleted nothing** and left the folder QUARANTINED
    ///     and UNSTAMPED — the silent mass deletion is gone, replaced by a state a
    ///     component is accountable for;
    ///  2. **the reaction, driven explicitly and AWAITED**, converges the folder:
    ///     old-epoch rows gone, new-epoch mail present, epoch stamped, quarantine
    ///     cleared.
    ///
    /// The reaction is driven by hand rather than left to the door's spawned `Task`
    /// so the assertions cannot race it. The door's own spawn is proved separately
    /// and deterministically in `EpochVerifiedBootstrapTests` (INV-1 phase 1).
    ///
    /// ## Red-first evidence for the REWRITTEN assertions — MEASURED (2026-07-31)
    ///
    /// Two independent inversions, each built and run on its own:
    ///
    /// **The fail-closed decision inverted** (`epochVerificationStampAllowed`
    /// returning `true`, i.e. the door stamps on zero agreements and on mismatch):
    ///
    /// ```
    /// ✘ Test "A folder populated before its first epoch observation is quarantined,
    ///   then converged — never silently swept" recorded an issue at
    ///   UidValidityTurnoverDeletionGuardTests.swift:507:9: Expectation failed:
    ///   try Self.survivingPreTurnoverCount(pool: pool, folderId: folderId) ==
    ///   Self.localHeaderCount
    ///   … :514:9: (quarantined.lastKnownUidValidity → 222222) == nil
    ///   … :520:9: (quarantined.uidValidityResetPendingAt → nil) != nil
    /// ✘ Test "A delete/re-create lifecycle quarantines the orphaned mail instead of
    ///   asserting it into the new epoch" … :595:9 … :598:9:
    ///   (readopted.lastKnownUidValidity → 222222) == nil … :604:9
    /// ```
    ///
    /// **The `NOT EXISTS` term dropped** from `bootstrapFolderUidValidity` and the
    /// `folderHoldsRows` guard dropped from `uidValidityBootstrapWrite`:
    ///
    /// ```
    /// ✘ "A folder populated before its first epoch observation …" :507:9 (mail swept)
    ///   … :514:9: (quarantined.lastKnownUidValidity → 222222) == nil
    /// ✘ "A delete/re-create lifecycle …" :595:9, :598:9, :604:9
    /// ✘ Test run with 21 tests in 3 suites failed after 4.617 seconds with 7 issues.
    /// ```
    ///
    /// `lastKnownUidValidity → 222222` over surviving pre-turnover rows is the
    /// defect in one value: the folder now claims its 2100 old-numbering headers
    /// belong to the epoch the server moved to. The two blocker tests above stayed
    /// GREEN through both inversions — they pin a KNOWN stored epoch, which neither
    /// inversion touches.
    @Test("A folder populated before its first epoch observation is quarantined, then converged — never silently swept")
    func nilEpochOverPrePopulatedFolderStillLosesMail() async throws {
        let server = FakeIMAPServer(mailboxes: ["INBOX": Self.postTurnoverMessages()])
        server.setUidValidity(Self.newEpoch, for: "INBOX")
        try server.start()
        defer { server.stop() }

        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }

        let accountId = "turnover-prepopulated"
        let folderId = "\(accountId):INBOX"
        // The pre-v63 shape: rows present, epoch NEVER observed (nil ≠ "fresh folder").
        let account = try Self.seed(
            pool: pool, accountId: accountId, folderPath: "INBOX", role: .inbox,
            storedEpoch: nil, totalCount: Self.localHeaderCount,
            lastKnownUidNext: Self.firstLocalUID + Self.localHeaderCount)

        // Neutralise the door's spawned reaction for phase 1: it is admitted through
        // the same single-flight gate, so a seeded entry makes the spawn a no-op and
        // phase 1 measures the SYNC PASS alone.
        await AccountManager.shared.seedUidValidityReactionInFlightForTesting(folderId: folderId)

        let provider = Self.provider(for: server)
        try await provider.connect()
        let engine = await Self.makeEngine(accountId: accountId, provider: provider)
        _ = try await engine.performDeltaSync(account: account, provider: provider)

        // ── Phase 1: the sync pass. It must destroy nothing and must not stamp.
        #expect(try Self.survivingPreTurnoverCount(pool: pool, folderId: folderId) == Self.localHeaderCount,
                """
                the sync pass deleted mail that predates any epoch observation. Every one of \
                those UIDs belongs to a numbering nobody has verified, so "the server did not \
                return UID n" is not evidence that message n is gone (ADR-IOS-051).
                """)
        let quarantined = try #require(try await pool.read { db in try Folder.fetchOne(db, key: folderId) })
        #expect(quarantined.lastKnownUidValidity == nil,
                """
                the pass stamped a folder whose rows provably do NOT resolve under the observed \
                epoch. That stamp is what makes the deletion-reconcile walk's stored-vs-live \
                comparison equal and turns it into a mass deleter.
                """)
        #expect(quarantined.uidValidityResetPendingAt != nil,
                """
                the folder was left neither proved nor quarantined, i.e. exactly as unprovable \
                as before — the door must hand an unprovable populated folder to the reaction.
                """)

        // ── Phase 2: the recoverer, driven explicitly and fully awaited.
        await AccountManager.shared.clearUidValidityReactionInFlightForTesting(folderId: folderId)
        await AccountManager.shared.clearUidValidityReactionRecheckRequestedForTesting(folderId: folderId)
        await AccountManager.shared.registerProviderForTesting(accountId: accountId, provider: provider)
        await AccountManager.shared.runUidValidityResetReaction(accountId: accountId, folderPath: "INBOX")
        await AccountManager.shared.unregisterProviderForTesting(accountId: accountId)
        try? await provider.disconnect()

        #expect(try Self.survivingPreTurnoverCount(pool: pool, folderId: folderId) == 0,
                """
                old-epoch rows outlived the reaction. Their bare UIDs address a numbering the \
                server has discarded, so any later gesture on one mutates whichever message the \
                new epoch put at that number (C3).
                """)
        #expect(try Self.postTurnoverCount(pool: pool, folderId: folderId) > 0,
                """
                the reaction removed the old mail without replacing it. Deletion is only \
                legitimate here because the same component commits to a resync — otherwise this \
                is the mass deletion wearing a different hat.
                """)
        let converged = try #require(try await pool.read { db in try Folder.fetchOne(db, key: folderId) })
        #expect(converged.lastKnownUidValidity == Self.newEpoch,
                "the folder must end stamped with the epoch its rows now genuinely belong to")
        #expect(converged.uidValidityResetPendingAt == nil,
                "a converged folder must be out of quarantine, or it is bricked")
    }

    @Test("A delete/re-create lifecycle quarantines the orphaned mail instead of asserting it into the new epoch")
    func deleteRecreateLifecycleStillLosesOrphanedMail() async throws {
        let server = FakeIMAPServer(mailboxes: ["INBOX": [], "Archive": Self.postTurnoverMessages()])
        server.setUidValidity(Self.oldEpoch, for: "Archive")
        try server.start()
        defer { server.stop() }

        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }

        let accountId = "turnover-lifecycle"
        let folderId = "\(accountId):Archive"
        // Step 1 — a folder that has synced normally at E1: its rows and a stamped
        // epoch. (Seeded directly; the point under test is steps 2-4.)
        let account = try Self.seed(
            pool: pool, accountId: accountId, folderPath: "Archive", role: .archive,
            storedEpoch: Self.oldEpoch, totalCount: Self.localHeaderCount,
            lastKnownUidNext: Self.firstLocalUID + Self.localHeaderCount)

        await AccountManager.shared.seedUidValidityReactionInFlightForTesting(folderId: folderId)

        let provider = Self.provider(for: server)
        try await provider.connect()
        let engine = await Self.makeEngine(accountId: accountId, provider: provider)

        // Step 2 — the mailbox disappears. Full sync deletes the folder ROW; the
        // headers are orphaned, not cascaded.
        server.markMailboxDeleted("Archive", includeNonexistentCode: true)
        try await engine.fullSync(account: account, provider: provider)
        let folderRowGone = try await pool.read { db in try Folder.fetchOne(db, key: folderId) == nil }
        #expect(folderRowGone, "precondition: the vanished folder's row is deleted")
        #expect(try Self.survivingPreTurnoverCount(pool: pool, folderId: folderId) == Self.localHeaderCount,
                "precondition: its headers survive orphaned — there is no FK cascade")

        // Step 3/4 — the same path reappears under a NEW epoch. The re-created row
        // is born with a nil epoch and re-adopts the orphaned E1 headers.
        server.markMailboxRestored("Archive")
        server.setUidValidity(Self.newEpoch, for: "Archive")
        try await engine.fullSync(account: account, provider: provider)

        // ── Phase 1: the folder-list upsert re-created the row. It must NOT have
        // been born stamped, because the headers it re-adopted are not its own.
        #expect(try Self.survivingPreTurnoverCount(pool: pool, folderId: folderId) == Self.localHeaderCount,
                "the re-create pass itself must not sweep the orphaned mail")
        let readopted = try #require(try await pool.read { db in try Folder.fetchOne(db, key: folderId) })
        #expect(readopted.lastKnownUidValidity == nil,
                """
                a freshly INSERTED folder row was born carrying an epoch even though it \
                immediately re-adopted 2100 orphaned headers through its deterministic \
                "accountId:path" id. Being new is not evidence of being empty.
                """)
        #expect(readopted.uidValidityResetPendingAt != nil,
                "the re-adopted rows are unprovable, so the folder belongs to the reaction")

        // ── Phase 2: converge it.
        await AccountManager.shared.clearUidValidityReactionInFlightForTesting(folderId: folderId)
        await AccountManager.shared.clearUidValidityReactionRecheckRequestedForTesting(folderId: folderId)
        await AccountManager.shared.registerProviderForTesting(accountId: accountId, provider: provider)
        await AccountManager.shared.runUidValidityResetReaction(accountId: accountId, folderPath: "Archive")
        await AccountManager.shared.unregisterProviderForTesting(accountId: accountId)
        try? await provider.disconnect()

        #expect(try Self.survivingPreTurnoverCount(pool: pool, folderId: folderId) == 0,
                "orphaned old-epoch rows must not outlive the reaction that took responsibility for them")
        #expect(try Self.postTurnoverCount(pool: pool, folderId: folderId) > 0,
                "the reaction must replace what it removed")
        let converged = try #require(try await pool.read { db in try Folder.fetchOne(db, key: folderId) })
        #expect(converged.lastKnownUidValidity == Self.newEpoch)
        #expect(converged.uidValidityResetPendingAt == nil)
    }
}
