/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

/// THE INVARIANT: **the debug migration log accounts for the whole chain, and
/// attributes each migration's foreign-key check to the migration that pays it.**
///
/// The defect this pins is not a crash or a data loss — it is a log that pointed
/// at the wrong migration. `registerTimedMigration` timed only `try migrate(db)`,
/// but GRDB runs `PRAGMA foreign_key_check`, the COMMIT and its `grdb_migrations`
/// bookkeeping AFTER the closure returns. On a 500k-header database the chain
/// line read ~87,000 ms while the per-migration lines summed to ~19,000 ms, and
/// `v68` — whose real cost is ~9 s, essentially all foreign-key check — printed
/// `applied in 0ms`.
///
/// 🚨 **BOTH TESTS ARE NEEDED AND NEITHER SUBSUMES THE OTHER.** The first pins
/// the arithmetic (nothing is unattributed). An implementation that logged
/// `fkCheck/commit = 0` for every migration and folded the whole gap into an
/// "unattributed" bucket would FAIL it, but one that attributed the gap to the
/// WRONG side would not — so the second test is the non-vacuity control: a
/// `.deferred` migration must report a materially larger post-body interval than
/// an `.immediate` one whose body does the same amount of work, because that
/// difference IS the whole-database foreign-key check. Without it, a version
/// that measures nothing and logs zeros passes.
///
/// The control pair is taken from the SHIPPING chain rather than from synthetic
/// probe migrations: `v68` and `v71` are both a single
/// `ALTER TABLE … ADD COLUMN` against a table holding a handful of rows, so
/// their bodies cost the same nothing — and `v68` runs `.immediate` while `v71`
/// is the one deliberately-kept whole-database gate. Measuring the real pair
/// means the control also fails if `v71`'s mode is ever quietly flipped, which a
/// pair of throwaway probes would not notice.
///
/// `.serialized` + `.processGlobalState`: `MigrationTimingGate.forcedForTesting`
/// is process-wide. The ledger itself is keyed by `Database` identity, so a
/// concurrently-migrating suite records into its OWN chain and cannot contaminate
/// these numbers — but the flag is still global state and is balanced by `defer`.
@Suite("Migration timing attribution", .serialized, .processGlobalState)
struct MigrationTimingAttributionTests {

    private static let v67 = "v67_addUidResolutionRetryCount"

    /// A v67-shaped database with `refs` foreign-key-bearing child rows, built
    /// with the recording gate OFF so the setup migrations are not recorded.
    ///
    /// Raw SQL, not the model types: at v67 `MessageHeader` has no
    /// `observedUidValidity` (v77) and `Draft` has no `lastTouchedSeq` (v79), so
    /// a model insert would fail against the very schema being seeded.
    private static func makeSeededV67Database(
        headers: Int, refs: Int
    ) throws -> DatabaseQueue {
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        let db = try DatabaseQueue(configuration: configuration)
        var migrator = DatabaseMigrator()
        AppDatabase.registerAllMigrations(on: &migrator)
        try migrator.migrate(db, upTo: v67)

        try db.write { db in
            try db.execute(sql: """
                INSERT INTO account (id, emailAddress, displayName, provider, createdAt)
                VALUES ('acc1', 'acc1@example.com', 'Test', 'imap', 1)
                """)
            try db.execute(sql: """
                INSERT INTO folder (id, accountId, name, path, role)
                VALUES ('acc1:INBOX', 'acc1', 'INBOX', 'INBOX', 'inbox')
                """)
            try db.execute(sql: """
                INSERT INTO userLabel (id, accountId, name) VALUES ('Label_0', 'acc1', 'Work')
                """)
            // Generated set-at-a-time rather than row-at-a-time: the interesting
            // fixtures here are tens of thousands of rows, and a per-row
            // `db.execute` re-prepares a statement each time, which made the
            // SETUP dominate the thing being measured.
            try db.execute(sql: """
                \(Self.counter(upTo: headers))
                INSERT INTO messageHeader
                    (id, folderId, accountId, folderPath, isInInbox, messageId,
                     rfc822MessageId, subject, `from`, fromAddress, `to`, date, isRead)
                SELECT 'acc1:INBOX:' || i, 'acc1:INBOX', 'acc1', 'INBOX', 1, CAST(i AS TEXT),
                       'rfc-' || i || '@example.com', 'subject',
                       'sender@example.com', 'sender@example.com',
                       'recipient@example.com', 1, i % 10 <> 0
                FROM counter
                """)
            try db.execute(sql: """
                \(Self.counter(upTo: headers))
                INSERT INTO messageUserLabel (messageId, userLabelId)
                SELECT 'acc1:INBOX:' || i, 'Label_0' FROM counter
                """)
            // The bulk of the foreign-key check's work: every one of these rows
            // is a child key that `PRAGMA foreign_key_check` must resolve against
            // `messageHeader`.
            try db.execute(sql: """
                \(Self.counter(upTo: refs))
                INSERT INTO messageReference (messageHeaderId, referencedRfc822Id)
                SELECT 'acc1:INBOX:' || (i % \(max(1, headers))),
                       'rfc-parent-' || i || '@example.com'
                FROM counter
                """)
        }
        return db
    }

    /// `WITH counter(i) AS (…)` yielding `0 ..< limit`. Integer literal
    /// interpolation only — every caller passes a constant from this file.
    private static func counter(upTo limit: Int) -> String {
        """
        WITH RECURSIVE counter(i) AS (
            SELECT 0 UNION ALL SELECT i + 1 FROM counter WHERE i + 1 < \(limit)
        )
        """
    }

    private static func withRecording<T>(_ body: () throws -> T) rethrows -> T {
        MigrationTimingGate.forcedForTesting.withLock { $0 = true }
        defer { MigrationTimingGate.forcedForTesting.withLock { $0 = false } }
        return try body()
    }

    // MARK: - 1. The arithmetic reconciles

    @Test("Bodies plus post-body intervals account for the whole v68…v83 chain")
    func chainAttributionReconciles() throws {
        let db = try Self.makeSeededV67Database(headers: 400, refs: 4_000)

        let report: MigrationTimingLedger.Report? = try Self.withRecording {
            try AppDatabase.runMigrations(on: db)
            return db.writeWithoutTransaction {
                MigrationTimingLedger.shared.consumeReport(db: $0)
            }
        }

        guard let report else {
            Issue.record("no attribution report was produced for this writer")
            return
        }

        var registered = DatabaseMigrator()
        AppDatabase.registerAllMigrations(on: &registered)
        let expected = Array(registered.migrations.drop(while: { $0 != Self.v67 }).dropFirst())
        #expect(report.entries.map(\.identifier) == expected,
                "every migration that ran must appear once, in order")

        #expect(report.entries.allSatisfy { $0.postBodyMs != nil },
                """
                a migration whose post-body interval was never closed is exactly the \
                unattributed time the old log hid — the reconciliation line would then \
                under-report it instead of naming it
                """)

        // Each entry truncates DOWN to whole milliseconds twice (body and gap),
        // so a 16-migration chain can shed ~32 ms to rounding alone; the rest is
        // GRDB's own pre-first-body setup.
        let tolerance = report.entries.count * 2 + 60
        #expect(abs(report.unattributedMs) <= tolerance,
                """
                chain \(report.chainMs)ms vs bodies \(report.bodyMsTotal)ms + \
                fkCheck/commit \(report.postBodyMsTotal)ms leaves \
                \(report.unattributedMs)ms unattributed (tolerance \(tolerance)ms) — \
                the whole point of this instrumentation is that the chain total and the \
                per-migration lines agree
                """)

        // The mode label is the diagnostic: it is what lets a reader see that a
        // multi-second gap is a whole-database check and not a slow commit.
        let deferred = Set(report.entries.filter { $0.mode == "deferred" }.map(\.identifier))
        #expect(deferred == [
            "v71_addOutboxDraftRfc822MessageId",
            "v82_accountScopedUserLabelIdentity",
        ], "the two deliberately-deferred migrations must be labelled as such")
        #expect(report.entries.allSatisfy { $0.mode == "deferred" || $0.mode == "immediate" })
    }

    // MARK: - 2. Non-vacuity — the gap really is the foreign-key check

    @Test("A deferred migration's post-body interval dwarfs an equivalent immediate one's")
    func deferredPostBodyIntervalDwarfsImmediate() throws {
        // Enough child rows that a whole-database `PRAGMA foreign_key_check` is
        // unmistakably more expensive than a commit, without making the fixture
        // slow. Sized deliberately generously: at 40,000 refs the measured gap was
        // 6ms against 0ms, and the assertion rounds to whole milliseconds — a
        // margin that thin would turn into a flake on faster hardware.
        let db = try Self.makeSeededV67Database(headers: 2_000, refs: 120_000)

        let report: MigrationTimingLedger.Report? = try Self.withRecording {
            try AppDatabase.runMigrations(on: db)
            return db.writeWithoutTransaction {
                MigrationTimingLedger.shared.consumeReport(db: $0)
            }
        }
        guard let report else {
            Issue.record("no attribution report was produced for this writer")
            return
        }

        // The matched pair: one `ALTER TABLE … ADD COLUMN` each, against `folder`
        // (1 row) and `outboxMessage` (0 rows) respectively. Same body cost,
        // opposite foreign-key mode.
        guard
            let immediate = report.entries.first(where: {
                $0.identifier == "v68_addFolderUidValidityResetPending"
            }),
            let deferred = report.entries.first(where: {
                $0.identifier == "v71_addOutboxDraftRfc822MessageId"
            })
        else {
            Issue.record("the v68/v71 control pair is missing from the report")
            return
        }
        #expect(immediate.mode == "immediate")
        #expect(deferred.mode == "deferred",
                """
                v71 is the range's single whole-database gate; if it ever becomes \
                `.immediate` this control silently stops controlling anything, so the \
                mode is asserted rather than assumed
                """)

        let immediateGap = immediate.postBodyMs ?? -1
        let deferredGap = deferred.postBodyMs ?? -1
        #expect(deferredGap > 0,
                """
                the deferred migration reported a \(deferredGap)ms post-body interval over \
                a database with 120,000 foreign-key-bearing child rows — an implementation \
                that measures nothing and logs zeros would look exactly like this, which \
                is what this control exists to catch
                """)
        #expect(deferredGap > immediateGap,
                """
                deferred \(deferredGap)ms vs immediate \(immediateGap)ms for two migrations \
                whose bodies are the same single ADD COLUMN — the gap is supposed to BE the \
                whole-database `PRAGMA foreign_key_check`, and `.immediate` runs no such \
                check, so this ordering is the evidence that the interval is attributed to \
                the right thing
                """)

        // The mirror image: the deferred migration's own BODY is not being charged
        // the check either — the point of the split is that BOTH numbers are right,
        // not merely that one of them is large. An `ALTER TABLE … ADD COLUMN` is a
        // schema-only rewrite of `sqlite_master`; anything beyond a few ms here
        // means the check leaked back into the body timer.
        #expect(immediate.bodyMs <= 20 && deferred.bodyMs <= 20,
                """
                body times were immediate \(immediate.bodyMs)ms / deferred \
                \(deferred.bodyMs)ms — an ADD COLUMN touches no row, so a large value \
                means post-body work is being attributed to the body
                """)
    }
}
