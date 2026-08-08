/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

/// v1.7.1 — the one-shot epoch rebuild, asserted on SYSTEM END STATES.
///
/// The defect: the 1.6.38 → 1.7.0 upgrade left inherited rows with a nil
/// `MessageHeader.observedUidValidity` and no path that fills it. Admission
/// (`AccountManagerActions.admittedOrdinaryActionTargets`) requires the row epoch
/// and the folder epoch both non-nil and EQUAL, so every gesture below the newest
/// ~50 UIDs per folder is refused, permanently and silently. On the reference
/// device that is 213,526 of 213,884 rows.
///
/// The fix arms the already-shipped purge-and-resync reaction on every IMAP/iCloud
/// folder, so each folder's rows are re-inserted stamped by their own FETCH.
///
/// Every expectation below names a durable property of the database, never a
/// mechanism. In particular `armEverySchedulesRebuildForInheritedRows` asserts the
/// ABSENCE OF THE DEFECT ITSELF — "no IMAP folder is left holding nil-epoch rows
/// with nothing scheduled" — rather than "the flag was written on folder X". A
/// mechanism-pinning test inherits a wrong spec's error and stays green on a broken
/// system; this project has shipped two regressions that way.
///
/// `.serialized, .processGlobalState` — replaces `AppDatabase.shared`, mutates
/// `AccountManager.shared`'s provider table, reads and writes the one-shot
/// `UserDefaults` key, and (for the re-drive case) binds a listening socket via
/// `FakeIMAPServer`.
@Suite("v1.7.1 — the one-shot UIDVALIDITY epoch rebuild", .serialized, .processGlobalState)
struct EpochRebuildArmMigrationTests {

    // MARK: - Fixture

    private static let oneShotKey = "didArmImapUidValidityResetForEpochRebuild_v1"
    private static let oldEpoch = 810_001
    private static let newEpoch = 810_002

    /// The migration is a ONE-SHOT keyed on `UserDefaults`, and the test process
    /// shares that suite across the whole run. Clearing it before AND after keeps
    /// these cases order-independent and stops them from disarming each other.
    /// `isolation: isolated (any Actor)? = #isolation` keeps `body` on the CALLER's
    /// isolation instead of sending it across an actor boundary — the same shape
    /// `TestProviderRegistry.withRegisteredProvider` uses, and required here because
    /// the target builds with `SWIFT_STRICT_CONCURRENCY: complete`.
    private static func withClearedOneShot(
        isolation: isolated (any Actor)? = #isolation,
        _ body: () async throws -> Void
    ) async rethrows {
        UserDefaults.standard.removeObject(forKey: oneShotKey)
        defer { UserDefaults.standard.removeObject(forKey: oneShotKey) }
        try await body()
    }

    private static func rfc822(messageId: String) -> String {
        """
        From: Test Sender <sender@example.com>\r
        To: Recipient <recipient@example.com>\r
        Subject: epoch rebuild fixture\r
        Date: Thu, 01 Jan 2026 00:00:00 +0000\r
        Message-ID: <\(messageId)>\r
        Content-Type: text/plain; charset=utf-8\r
        \r
        epoch rebuild fixture body.\r

        """
    }

    private static func message(uid: Int, id: String) -> FakeIMAPServer.Message {
        FakeIMAPServer.makeMessage(uid: uid, rfc822Text: rfc822(messageId: id))
    }

    private static func imapProvider(for server: FakeIMAPServer) -> IMAPProvider {
        IMAPProvider(
            host: "127.0.0.1", port: server.port,
            username: server.username, password: server.password,
            smtpHost: "127.0.0.1", smtpPort: 587, useTLS: false
        )
    }

    /// The defect, stated as a query. A folder is UNREPAIRED when it holds at least
    /// one row with no observed epoch and is NOT scheduled for a rebuild — because
    /// nothing else in the tree will ever fill that column for an inherited row.
    /// Returns the offending folder ids so a failure names them.
    private static func unrepairedFolderIds(_ pool: DatabasePool) throws -> [String] {
        try pool.read { db in
            try String.fetchAll(db, sql: """
                SELECT DISTINCT f.id
                FROM folder f
                JOIN account a ON a.id = f.accountId
                JOIN messageHeader h ON h.folderId = f.id
                WHERE a.provider IN (?, ?)
                  AND h.observedUidValidity IS NULL
                  AND f.uidValidityResetPendingAt IS NULL
                ORDER BY f.id
                """, arguments: [AccountProvider.imap.rawValue, AccountProvider.icloud.rawValue])
        }
    }

    /// Every column of every `folder` AND `account` row for the given accounts, as
    /// an opaque comparable snapshot. Used to assert Gmail/Outlook come through the
    /// migration BYTE-IDENTICAL — a weaker "the quarantine column is still nil"
    /// would pass on a migration that clobbered cursors or epochs on the way past.
    ///
    /// `account` is in scope deliberately: the migration writes `lastFullSyncAt`
    /// there to make the rebuild due, and that write must be scoped to IMAP/iCloud
    /// exactly as tightly as the folder arming is. A snapshot covering only `folder`
    /// would not have caught a mis-scoped forced resync of every Gmail account.
    private static func rowSnapshot(_ pool: DatabasePool, accountIds: [String]) throws -> [String] {
        let placeholders = accountIds.map { _ in "?" }.joined(separator: ",")
        return try pool.read { db in
            let folders = try Row.fetchAll(db, sql: """
                SELECT * FROM folder WHERE accountId IN (\(placeholders)) ORDER BY id
                """, arguments: StatementArguments(accountIds)).map { "folder:" + $0.description }
            let accounts = try Row.fetchAll(db, sql: """
                SELECT * FROM account WHERE id IN (\(placeholders)) ORDER BY id
                """, arguments: StatementArguments(accountIds)).map { "account:" + $0.description }
            return folders + accounts
        }
    }

    // MARK: - 1/4 — the defect is gone on an upgraded database

    /// 🚨 THE DEFECT ITSELF. An upgraded database is reconstructed: IMAP and iCloud
    /// accounts whose folders span the three real shapes measured on the reference
    /// device — a stamped primary-role folder, an UNSTAMPED custom non-favourite
    /// folder (26 of 41 IMAP folders, holding 85% of all inherited rows), and an
    /// empty folder — every header row carrying a nil epoch.
    ///
    /// After the one-shot, `unrepairedFolderIds` must be EMPTY: no IMAP/iCloud
    /// folder is left holding an unrepairable row with nothing scheduled to repair
    /// it. That is the user-visible property — gestures work again — and it is what
    /// a future refactor must not break, whatever mechanism it chooses.
    ///
    /// The custom non-favourite folder is the case that matters. It is invisible to
    /// both `syncableFolders` passes, so a migration scoped to "folders full sync
    /// visits" would leave 85% of the corpus unrepaired and still report success.
    @Test("An upgraded database is left with no IMAP folder holding unrepairable rows")
    @MainActor
    func armEverySchedulesRebuildForInheritedRows() async throws {
        try await Self.withClearedOneShot {
            let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
            defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }

            let imapId = "rebuild-imap"
            let icloudId = "rebuild-icloud"
            _ = try FolderEpochTestFixture.makeAccount(id: imapId, provider: .imap, pool: pool)
            _ = try FolderEpochTestFixture.makeAccount(id: icloudId, provider: .icloud, pool: pool)

            // Shape 1 — a stamped primary-role folder (15 of 41 on the device).
            try FolderEpochTestFixture.insertFolder(
                accountId: imapId, path: "INBOX", role: .inbox, pool: pool,
                lastKnownUidValidity: Self.oldEpoch)
            try FolderEpochTestFixture.insertHeaders(
                accountId: imapId, path: "INBOX", uids: [101, 102], pool: pool)

            // Shape 2 — an UNSTAMPED custom NON-FAVOURITE folder. `Archive-2021` on
            // the device: 48,856 rows, `lastKnownUidValidity` nil, and reached by
            // NEITHER `fullSync`'s nor `imapDeltaSync`'s `syncableFolders` filter.
            try FolderEpochTestFixture.insertFolder(
                accountId: imapId, path: "Archive-2021", role: .custom, pool: pool)
            try FolderEpochTestFixture.insertHeaders(
                accountId: imapId, path: "Archive-2021", uids: [201, 202, 203], pool: pool)

            // Shape 3 — an empty folder. Nothing to repair, but it must not be a
            // reason the one-shot reports partial failure and retries forever.
            try FolderEpochTestFixture.insertFolder(
                accountId: imapId, path: "Notes", role: .custom, pool: pool)

            // iCloud rides the same reaction — the provider guard admits both.
            try FolderEpochTestFixture.insertFolder(
                accountId: icloudId, path: "INBOX", role: .inbox, pool: pool,
                lastKnownUidValidity: Self.oldEpoch)
            try FolderEpochTestFixture.insertHeaders(
                accountId: icloudId, path: "INBOX", uids: [301], pool: pool)

            let before = try Self.unrepairedFolderIds(pool)
            #expect(before.count == 3,
                    """
                    the fixture did not reproduce the defect, so this test cannot prove the fix \
                    removes it. Expected all three populated folders unrepaired before the \
                    migration; got \(before).
                    """)

            await AccountManager.shared.armImapUidValidityResetForEpochRebuildIfNeeded()

            let after = try Self.unrepairedFolderIds(pool)
            #expect(after.isEmpty,
                    """
                    \(after.count) IMAP/iCloud folder(s) still hold rows with no observed epoch and \
                    have no rebuild scheduled: \(after). Nothing in the tree fills that column for \
                    an inherited row, so every gesture on those rows is refused forever — the \
                    1.7.0 defect, unfixed. A custom non-favourite folder in this list means the \
                    migration was scoped to the folders full sync visits and missed 85% of the \
                    corpus.
                    """)
        }
    }

    // MARK: - 1b — the rebuild must be DUE, not parked behind the sync interval

    /// 🚨 THE 1.7.1 REGRESSION, pinned. Arming alone only sets durable flags; the
    /// reaction runs when a re-drive owner next reaches the folder, and
    /// `SyncEngine.sync(account:)` gates full sync on `lastFullSyncAt` +
    /// `fullSyncInterval` (900s). A launch that has just full-synced therefore left
    /// every armed folder quarantined for up to 15 minutes — and a quarantined
    /// folder's merge pass is SKIPPED, so the mailbox silently stops showing new
    /// mail with nothing to explain it. Observed on the 1.7.1 TestFlight build:
    /// mail returned only after a manual quit-and-relaunch forced a sync.
    ///
    /// The invariant is about the SYSTEM being ready to rebuild, not about which
    /// call performs it: no account owning an armed folder may still be holding a
    /// full-sync cursor that defers the rebuild. Asserted on the durable end state
    /// so it survives any future change to how the kick is issued.
    @Test("No account owning an armed folder is left waiting on the full-sync interval")
    @MainActor
    func armLeavesNoAccountWaitingOnTheFullSyncInterval() async throws {
        try await Self.withClearedOneShot {
            let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
            defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }

            let imapId = "rebuild-due-imap"
            _ = try FolderEpochTestFixture.makeAccount(id: imapId, provider: .imap, pool: pool)
            try FolderEpochTestFixture.insertFolder(
                accountId: imapId, path: "INBOX", role: .inbox, pool: pool,
                lastKnownUidValidity: Self.oldEpoch)
            try FolderEpochTestFixture.insertHeaders(
                accountId: imapId, path: "INBOX", uids: [101], pool: pool)

            // The state that produced the regression: a full sync JUST completed, so
            // the next one is not due for `fullSyncInterval`. Without the fix the
            // armed folder waits that long with its merge pass skipped.
            try await pool.write { db in
                _ = try Account.filter(Column("id") == imapId)
                    .updateAll(db, Column("lastFullSyncAt").set(to: Date()))
            }

            await AccountManager.shared.armImapUidValidityResetForEpochRebuildIfNeeded()

            let stillDeferred = try await pool.read { db in
                try String.fetchAll(db, sql: """
                    SELECT DISTINCT a.id
                    FROM account a
                    JOIN folder f ON f.accountId = a.id
                    WHERE f.uidValidityResetPendingAt IS NOT NULL
                      AND a.lastFullSyncAt IS NOT NULL
                    ORDER BY a.id
                    """)
            }
            #expect(stillDeferred.isEmpty,
                    """
                    \(stillDeferred.count) account(s) own an armed folder but still carry a \
                    full-sync cursor: \(stillDeferred). Their folders are quarantined, so every \
                    merge pass is skipped, and the reaction that would rebuild them does not run \
                    until the 900s full-sync interval elapses — the mailbox shows no new mail and \
                    gives the user no way to know why. This is the 1.7.1 regression.
                    """)
        }
    }

    // MARK: - 2/4 — blast radius

    /// Gmail and Outlook never populate `lastKnownUidValidity`; the reaction refuses
    /// their providers outright. They must come through the migration BYTE-IDENTICAL
    /// — asserted on a full-row snapshot, not on the quarantine column alone, so a
    /// migration that clobbered a cursor or an epoch on the way past still fails.
    @Test("Gmail and Outlook folders are byte-identical across the migration")
    @MainActor
    func armLeavesNonImapProvidersUntouched() async throws {
        try await Self.withClearedOneShot {
            let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
            defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }

            let gmailId = "rebuild-gmail"
            let outlookId = "rebuild-outlook"
            let imapId = "rebuild-imap-neighbour"
            _ = try FolderEpochTestFixture.makeAccount(id: gmailId, provider: .gmail, pool: pool)
            _ = try FolderEpochTestFixture.makeAccount(id: outlookId, provider: .outlook, pool: pool)
            _ = try FolderEpochTestFixture.makeAccount(id: imapId, provider: .imap, pool: pool)

            try FolderEpochTestFixture.insertFolder(
                accountId: gmailId, path: "INBOX", role: .inbox, pool: pool,
                totalCount: 12, lastKnownUidNext: 500, lastKnownHighestModSeq: 900)
            try FolderEpochTestFixture.insertFolder(
                accountId: gmailId, path: "Custom", role: .custom, pool: pool)
            try FolderEpochTestFixture.insertFolder(
                accountId: outlookId, path: "INBOX", role: .inbox, pool: pool, totalCount: 7)
            // An IMAP neighbour on the SAME database, so the test proves SCOPING and
            // not merely "the migration did nothing".
            try FolderEpochTestFixture.insertFolder(
                accountId: imapId, path: "INBOX", role: .inbox, pool: pool,
                lastKnownUidValidity: Self.oldEpoch)

            let untouchedIds = [gmailId, outlookId]
            let before = try Self.rowSnapshot(pool, accountIds: untouchedIds)

            await AccountManager.shared.armImapUidValidityResetForEpochRebuildIfNeeded()

            let after = try Self.rowSnapshot(pool, accountIds: untouchedIds)
            #expect(after == before,
                    """
                    a Gmail/Outlook folder row changed across the migration. Those providers have \
                    no UIDVALIDITY at all and the reaction refuses them, so any write here is the \
                    selector leaking across accounts.
                    """)

            let imapFolder = try FolderEpochTestFixture.readFolder(accountId: imapId, path: "INBOX", pool: pool)
            #expect(imapFolder?.uidValidityResetPendingAt != nil,
                    """
                    the IMAP neighbour was NOT armed, so this test proved nothing about scoping — \
                    it would pass identically on a migration that did nothing at all.
                    """)
        }
    }

    // MARK: - 3/4 — the one-shot must never fire twice

    /// A rebuilt folder must not be re-armed on the next launch. The reaction PURGES
    /// the folder's local mail before resyncing it, so a migration that re-armed
    /// would destroy and re-download the entire mailbox on every launch, forever.
    ///
    /// End state after a completed rebuild + a second migration run: the folder is
    /// NOT quarantined and still carries the epoch the reaction stamped.
    @Test("A folder already rebuilt is not re-armed on the next launch")
    @MainActor
    func armDoesNotFireASecondTime() async throws {
        try await Self.withClearedOneShot {
            let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
            defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }

            let accountId = "rebuild-once"
            _ = try FolderEpochTestFixture.makeAccount(id: accountId, provider: .imap, pool: pool)
            try FolderEpochTestFixture.insertFolder(
                accountId: accountId, path: "INBOX", role: .inbox, pool: pool,
                lastKnownUidValidity: Self.oldEpoch)
            try FolderEpochTestFixture.insertHeaders(
                accountId: accountId, path: "INBOX", uids: [101], pool: pool)

            await AccountManager.shared.armImapUidValidityResetForEpochRebuildIfNeeded()
            #expect(try FolderEpochTestFixture.readFolder(accountId: accountId, path: "INBOX", pool: pool)?
                .uidValidityResetPendingAt != nil,
                    "the first run did not arm the folder, so the second-run assertion proves nothing")

            // Stand in for a reaction that ran to completion: quarantine cleared and
            // the fresh epoch stamped, in the one write the reaction uses.
            try await pool.write { db in
                try db.execute(sql: """
                    UPDATE folder SET uidValidityResetPendingAt = NULL, lastKnownUidValidity = ?
                    WHERE id = ?
                    """, arguments: [Self.newEpoch, "\(accountId):INBOX"])
                try db.execute(sql: """
                    UPDATE messageHeader SET observedUidValidity = ? WHERE folderId = ?
                    """, arguments: [Self.newEpoch, "\(accountId):INBOX"])
            }

            await AccountManager.shared.armImapUidValidityResetForEpochRebuildIfNeeded()

            let folder = try FolderEpochTestFixture.readFolder(accountId: accountId, path: "INBOX", pool: pool)
            #expect(folder?.uidValidityResetPendingAt == nil,
                    """
                    a folder that had already been rebuilt was armed again. The reaction purges \
                    local mail before resyncing, so this destroys and re-downloads the whole \
                    mailbox on every launch, forever.
                    """)
            #expect(folder?.lastKnownUidValidity == Self.newEpoch,
                    "the second migration run overwrote the epoch a completed reaction had stamped")
        }
    }

    // MARK: - 4/4 — the re-drive that makes arming a custom folder safe

    /// 🚨 THE INVARIANT THAT CLOSES THE BRICK. `fullSync`'s per-folder loop and
    /// `imapDeltaSync` both branch into the reaction for a quarantined folder, and
    /// both iterate `syncableFolders` (primary ∪ secondary ∪ favourite). A custom
    /// non-favourite folder is in NEITHER, and `runSyncMessages`'s in-transaction
    /// quarantine term correctly SKIPS the merge pass while `isFolderWalkComplete`
    /// refuses the crawl — so before this fix a quarantined custom folder stayed
    /// quarantined and unsynced FOREVER, with its mail already purged. Every abort
    /// leg of the reaction deliberately leaves the flag set on the premise that some
    /// owner re-drives it; for this folder class no owner existed.
    ///
    /// The invariant: a quarantined folder reached through the ON-DEMAND door ends
    /// up REBUILT — not quarantined, stamped with the server's live epoch, holding
    /// the server's mail and none of the discarded numbering's. Asserted on the end
    /// state, so it holds for any future owner, not just the current call site.
    @Test("A quarantined custom folder opened by the user is rebuilt, not stranded")
    @MainActor
    func onDemandNavigationRedrivesAQuarantinedCustomFolder() async throws {
        let server = FakeIMAPServer(mailboxes: [
            "INBOX": [],
            "Archive-2021": [Self.message(uid: 9001, id: "post-rebuild-9001@example.com")]
        ])
        server.setUidValidity(Self.newEpoch, for: "INBOX")
        server.setUidValidity(Self.newEpoch, for: "Archive-2021")
        try server.start()
        defer { server.stop() }

        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }

        let accountId = "rebuild-ondemand"
        _ = try FolderEpochTestFixture.makeAccount(id: accountId, provider: .imap, pool: pool)
        try FolderEpochTestFixture.insertFolder(
            accountId: accountId, path: "INBOX", role: .inbox, pool: pool,
            lastKnownUidValidity: Self.oldEpoch)
        // Custom role, NOT favourited — invisible to both `syncableFolders` passes.
        try FolderEpochTestFixture.insertFolder(
            accountId: accountId, path: "Archive-2021", role: .custom, pool: pool,
            lastKnownUidValidity: Self.oldEpoch)
        try FolderEpochTestFixture.insertHeaders(
            accountId: accountId, path: "Archive-2021", uids: [201, 202, 203], pool: pool)

        let folderId = "\(accountId):Archive-2021"
        // Armed exactly as the one-shot arms it.
        _ = await AccountManager.shared.uidValidityResetArmFlag(folderId: folderId)
        #expect(try FolderEpochTestFixture.readFolder(accountId: accountId, path: "Archive-2021", pool: pool)?
            .uidValidityResetPendingAt != nil,
                "the fixture is not quarantined, so this test does not exercise the re-drive at all")

        let provider = Self.imapProvider(for: server)
        try await provider.connect()
        defer { Task { try? await provider.disconnect() } }

        let folder = try #require(try FolderEpochTestFixture.readFolder(
            accountId: accountId, path: "Archive-2021", pool: pool))

        // The on-demand door: `AccountManager.syncFolders(_:)` → here → the merge pass.
        let engine = SyncEngine()
        try await TestProviderRegistry.withRegisteredProvider(accountId: accountId, provider: provider) {
            try await engine.syncFolderMessages(folder: folder, provider: provider)
        }

        let rebuilt = try FolderEpochTestFixture.readFolder(accountId: accountId, path: "Archive-2021", pool: pool)
        #expect(rebuilt?.uidValidityResetPendingAt == nil,
                """
                a custom non-favourite folder is STILL quarantined after the user opened it. \
                Neither `syncableFolders` pass visits this folder, so nothing else will ever \
                re-drive it: its mail is purged and it never syncs again.
                """)
        #expect(rebuilt?.lastKnownUidValidity == Self.newEpoch,
                """
                the folder was released from quarantine without being stamped with the epoch its \
                rows now belong to — the two are written by one transaction and observing the \
                second without the first should be impossible.
                """)

        let survivingOldEpochUIDs = try await pool.read { db in
            try MessageHeader
                .filter(Column("folderId") == folderId)
                .filter(["201", "202", "203"].contains(Column("messageId")))
                .fetchCount(db)
        }
        #expect(survivingOldEpochUIDs == 0,
                """
                an old-epoch header survived. Its bare UID addresses a numbering the server has \
                discarded, so a later gesture on it resolves against whichever message the new \
                epoch put at that number — C3.
                """)
    }
}
