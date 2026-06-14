/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB

/// One-time destructive **cached-mail resets** (NOT GRDB schema migrations —
/// those live in `AppDatabase.runMigrations`). Each is gated by a `UserDefaults`
/// flag so it runs exactly once, ever. They blow away locally-cached headers /
/// bodies / backfill cursors (and, for the clean reset, the FTS index) when an
/// app upgrade changed or corrupted the cache format; the data re-syncs from the
/// server (source of truth) afterwards.
///
/// **Runs synchronously inside `AppDatabase.init()`**, right after the schema
/// migrator and BEFORE the pool is exposed (`AppDatabase.shared` set) or the
/// inbox observer is wired. That is the whole point: the DB opens → migrates →
/// only THEN can anything (UI load, sync, NSE merge, demo/screenshot seed) touch
/// it. Nothing can race these deletes, so there's no async "migrations complete"
/// gate anymore.
enum StartupMigrations {

    /// `UserDefaults` flags gating the one-time resets, in run order. Keep this
    /// in sync with the `bool(forKey:)` checks in `run(_:resetFTS:)` — it's the
    /// single source of truth for `allResetsComplete`.
    static let resetFlagKeys = [
        "didMigrateHeaderIds_v2",
        "didClearBodiesForAttachmentEncoding_v1",
        "didResetImapDatesForInternalDate_v1",
        "didCleanResetMessageData_v1",
    ]

    /// True once every one-time reset has run (all flags set). Lets startup tell
    /// — without opening or scanning the mailbox — whether `run(_:)` will do
    /// (possibly slow, destructive) work, so it can decide to show the migration
    /// splash. See `AppStartup` / `AppDatabase.hasPendingMigrationWork`.
    static var allResetsComplete: Bool {
        resetFlagKeys.allSatisfy { UserDefaults.standard.bool(forKey: $0) }
    }

    /// Run all pending one-time resets. Already-completed ones (flag set) are
    /// no-ops, so this is cheap on every launch after the first.
    ///
    /// - Parameters:
    ///   - writer: the main DB writer (production: `AppDatabase.dbPool`).
    ///   - resetFTS: side effect that clears the FTS index, invoked in lockstep
    ///     with the clean-reset's main-DB deletes (so the flag is set only once
    ///     both halves are done — crash-safe). Injectable so tests don't touch
    ///     the real FTS directory.
    static func run(_ writer: some DatabaseWriter, resetFTS: () -> Void = { deleteFTSDirectory() }) {
        let t0 = CFAbsoluteTimeGetCurrent()

        if !UserDefaults.standard.bool(forKey: "didMigrateHeaderIds_v2") {
            do {
                try writer.write { db in
                    try db.execute(sql: "DELETE FROM messageHeader")
                }
                print("[Migration] Batch-deleted old-format MessageHeaders")
                UserDefaults.standard.set(true, forKey: "didMigrateHeaderIds_v2")
            } catch {
                print("[Migration] didMigrateHeaderIds_v2 failed: \(error) — will retry next launch")
            }
        }

        if !UserDefaults.standard.bool(forKey: "didClearBodiesForAttachmentEncoding_v1") {
            do {
                try writer.write { db in
                    try db.execute(sql: "DELETE FROM messageBody")
                }
                print("[Migration] Batch-deleted MessageBody entries for attachment encoding fix")
                UserDefaults.standard.set(true, forKey: "didClearBodiesForAttachmentEncoding_v1")
            } catch {
                print("[Migration] didClearBodiesForAttachmentEncoding_v1 failed: \(error) — will retry next launch")
            }
        }

        if !UserDefaults.standard.bool(forKey: "didResetImapDatesForInternalDate_v1") {
            do {
                try writer.write { db in
                    let imapAccountIds = try String.fetchAll(db,
                        Account.select(Column("id")).filter(Column("provider") == AccountProvider.imap.rawValue)
                    )
                    guard !imapAccountIds.isEmpty else { return }
                    try Folder.filter(imapAccountIds.contains(Column("accountId")))
                        .updateAll(db,
                            Column("backfillComplete").set(to: false),
                            Column("oldestSyncedDate").set(to: nil as Date?),
                            Column("backfillUidCursor").set(to: nil as Int?),
                            Column("backfillPageToken").set(to: nil as String?)
                        )
                    try Account.filter(imapAccountIds.contains(Column("id")))
                        .updateAll(db, Column("lastFullSyncAt").set(to: nil as Date?))
                    print("[Migration] Reset backfill state on IMAP folders for INTERNALDATE fix")
                }
                UserDefaults.standard.set(true, forKey: "didResetImapDatesForInternalDate_v1")
            } catch {
                print("[Migration] didResetImapDatesForInternalDate_v1 failed: \(error) — will retry next launch")
            }
        }

        if !UserDefaults.standard.bool(forKey: "didCleanResetMessageData_v1") {
            do {
                try writer.write { db in
                    try db.execute(sql: "DELETE FROM messageBody")
                    try db.execute(sql: "DELETE FROM messageHeader")
                    try Folder.updateAll(db,
                        Column("backfillComplete").set(to: false),
                        Column("oldestSyncedDate").set(to: nil as Date?),
                        Column("lastKnownUidNext").set(to: nil as Int?),
                        Column("backfillUidCursor").set(to: nil as Int?),
                        Column("backfillPageToken").set(to: nil as String?)
                    )
                    try Account.updateAll(db, Column("lastFullSyncAt").set(to: nil as Date?))
                }
                print("[Migration] Clean reset: batch deleted all headers + bodies")
                // FTS lives in a separate DB; clear it in the SAME step so the flag
                // is set only once both halves are done (crash → re-run next launch).
                resetFTS()
                UserDefaults.standard.set(true, forKey: "didCleanResetMessageData_v1")
            } catch {
                print("[Migration] didCleanResetMessageData_v1 failed: \(error) — will retry next launch")
            }
        }

        let ms = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
        print("[Migration] Startup data resets completed in \(ms)ms")
    }

    /// Delete the FTS database directory so `SearchIndex.initialize()` rebuilds it
    /// fresh from the (now-empty) main DB. Safe to call at DB-open: SearchIndex has
    /// not initialized yet, so no pool/connection is open on these files (this is
    /// why we can just `removeItem` instead of `SearchIndex.resetAll()`, which
    /// carries vec0-finalization logic needed only when a pool is live).
    static func deleteFTSDirectory() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let ftsDir = appSupport.appendingPathComponent("tabmail_fts", isDirectory: true)
        let fm = FileManager.default
        guard fm.fileExists(atPath: ftsDir.path) else { return }
        do {
            try fm.removeItem(at: ftsDir)
            print("[Migration] Deleted FTS directory (clean reset)")
        } catch {
            print("[Migration] FTS directory delete failed: \(error)")
        }
    }
}
