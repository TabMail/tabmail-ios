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

    /// `UserDefaults` flags gating the one-time **cached-mail** resets, in run
    /// order. Keep this in sync with the `bool(forKey:)` checks in
    /// `run(_:resetFTS:legacyLogDirectory:)` — it's the single source of truth
    /// for `allResetsComplete`.
    ///
    /// ⚠️ It lists only the resets that are SLOW on a populated mailbox, because
    /// `allResetsComplete` is what decides whether launch shows the "Updating…"
    /// splash. `didDeleteLegacyLogFiles_v1` is a one-shot too, but unlinking at
    /// most fifteen small files is not splash-worthy work, so it is gated the
    /// same way and deliberately kept out of this list.
    static let resetFlagKeys = [
        "didMigrateHeaderIds_v2",
        "didClearBodiesForAttachmentEncoding_v1",
        "didResetImapDatesForInternalDate_v1",
        "didCleanResetMessageData_v1",
    ]

    /// One-shot flag for the legacy per-subsystem log-file cleanup. Not in
    /// `resetFlagKeys` — see the note there.
    static let legacyLogCleanupFlagKey = "didDeleteLegacyLogFiles_v1"

    /// The fifteen per-subsystem log files the main app wrote before
    /// `AppLogStore` consolidated every channel into `tabmail.log` (GitHub #83).
    ///
    /// On upgrade these are STRANDED: nothing writes them, nothing reads them,
    /// and the Debug menu's "Clear All Logs" no longer knows they exist — so
    /// their bytes sit in Application Support forever. That is not merely
    /// untidy: `StorageEstimator.totalSizeMB()` measures Application Support
    /// recursively, `isOverBudget()` compares it to the user's budget, and
    /// `SyncEngine.runPruneIfOverBudget` responds by deleting `MessageBody` and
    /// header rows. Orphaned log bytes can therefore buy their size in pruned
    /// mail — CONDITIONALLY, not categorically: `isOverBudget()` short-circuits
    /// on `budgetMB != Int.max` and `defaultBudgetMB` is `Int.max`, so it bites
    /// only once a user has configured a finite budget and usage reaches it.
    ///
    /// ⚠️ `tabmail.log` (the live app log) and `nse.log` (the NSE's, in the App
    /// Group container, not here) are NOT in this list and must never be.
    static let legacyLogFileNames = [
        "background_sync.log",
        "error.log",
        "chat_error.log",
        "bg_app_refresh.log",
        "bg_processing.log",
        "ai_processing.log",
        "push.log",
        "backfill_ai.log",
        "backfill.log",
        "inbox.log",
        "boot.log",
        "body_render.log",
        "stuck_messages.log",
        "device_sync.log",
        "auth_diagnostics.log",
    ]

    /// Application Support / TabMail — where the legacy log files were written
    /// and where `AppLogStore` writes `tabmail.log` today. Does NOT create the
    /// directory: a missing directory means there is nothing to clean up.
    static var defaultLegacyLogDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TabMail", isDirectory: true)
    }

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
    ///   - legacyLogDirectory: directory the orphaned pre-`AppLogStore` log
    ///     files are deleted from. Injectable for the same reason as `resetFTS`
    ///     — tests must not unlink files in the real Application Support.
    static func run(
        _ writer: some DatabaseWriter,
        resetFTS: () -> Void = { deleteFTSDirectory() },
        legacyLogDirectory: URL = defaultLegacyLogDirectory
    ) {
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

        if !UserDefaults.standard.bool(forKey: legacyLogCleanupFlagKey) {
            // Armed ONLY on a fully clean pass, so a name that could not be
            // unlinked leaves the flag unset and the next launch retries the
            // whole (cheap) list. That is what makes a TRANSIENT obstruction
            // self-heal. It is NOT a promise of progress against a PERMANENTLY
            // undeletable file (immutable flag, unwritable parent): that pins the
            // flag unset and re-runs the fifteen-name scan every launch, forever.
            // The cost is bounded — fifteen `unlink` syscalls, fourteen of which
            // return ENOENT immediately once the removable names are gone — and
            // arming after a partial pass would be strictly worse, stranding
            // whatever was left, permanently, with no UI that can reach it.
            let cleanup = deleteLegacyLogFiles(in: legacyLogDirectory)
            if cleanup.failed == 0 {
                UserDefaults.standard.set(true, forKey: legacyLogCleanupFlagKey)
            }
            // Rule 12: diagnostic, so it must be a no-op in a production build.
            if DebugModeManager.isLoggingEnabled() {
                print("[Migration] Deleted \(cleanup.deleted) orphaned legacy log file(s); "
                    + "\(cleanup.failed) failed, \(legacyLogCleanupFlagKey) armed: \(cleanup.failed == 0)")
            }
        }

        let ms = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
        print("[Migration] Startup data resets completed in \(ms)ms")
    }

    /// Outcome of one legacy-log cleanup pass: how many of the fifteen names
    /// were unlinked, and how many were present but could not be. The caller
    /// arms `legacyLogCleanupFlagKey` only when `failed == 0`.
    struct LegacyLogCleanup: Equatable, Sendable {
        var deleted = 0
        var failed = 0
    }

    /// Unlink every `legacyLogFileNames` entry present in `directory`, and
    /// report how many were removed and how many were present but could not be.
    ///
    /// A name that is not there is NOT an error — a fresh install has none of
    /// them, and a partially-completed previous attempt has some. Only the
    /// fifteen listed names are touched; the directory is never enumerated, so
    /// `tabmail.log` and anything else living there cannot be caught by a
    /// widened pattern.
    ///
    /// Removal is `unlink(2)`, NOT `FileManager.removeItem(at:)`. Three
    /// properties follow from that, and they are the whole reason for the choice:
    ///
    /// * **It can never recurse, and there is no check/use window.**
    ///   `removeItem(at:)` is documented recursive, so a directory bearing one of
    ///   these names would be deleted along with its whole contents —
    ///   irreversibly, at launch, before any UI exists to report it. Guarding it
    ///   with an `isRegularFile` query does not close that: the query and the
    ///   removal are two syscalls with a window between them. `unlink` is one
    ///   syscall that refuses a directory outright (Darwin returns `EPERM`), so
    ///   there is no type check to race and nothing to recurse into (THE MANTRA:
    ///   failing closed is always acceptable, a wrong irreversible delete is not).
    /// * **A symlink loses the LINK, never its target.** `unlink` operates on the
    ///   directory entry, so a legacy name that is a symlink — dangling or valid —
    ///   has the entry removed and whatever it pointed at is left untouched. That
    ///   is the correct outcome: the stranded name goes, and this function never
    ///   reaches through a name it was handed.
    /// * **Each name's failure is isolated.** One unremovable name must not
    ///   abort the pass. It used to: `try` propagated straight out of the loop,
    ///   so the first failure skipped every later name — and because the
    ///   one-shot flag is armed only after a full pass, every subsequent launch
    ///   aborted at the same index, forever. `device_sync.log` and
    ///   `auth_diagnostics.log` are the last two names AND two of the five
    ///   channels written in production, so "abort at the first failure" left
    ///   behind exactly the bytes this function exists to reclaim.
    ///
    /// A directory at a legacy name is SKIPPED, and a skip is NOT a failure. It
    /// is a permanent, deliberate refusal — no later launch could make a
    /// directory removable by this function — so it must not block the flag;
    /// counting it would re-scan all fifteen names on every launch forever with
    /// no progress to show for it. Every OTHER failure IS counted, including one
    /// whose cause cannot be determined: erasing an unresolved error into a clean
    /// skip would arm the one-shot flag and strand that name's bytes forever.
    /// "Directory" there means a directory ENTRY at this name, classified with
    /// `lstat(2)` — a link whose unlink failed is a failure and is retried next
    /// launch.
    @discardableResult
    static func deleteLegacyLogFiles(in directory: URL) -> LegacyLogCleanup {
        var result = LegacyLogCleanup()
        for name in legacyLogFileNames {
            let url = directory.appendingPathComponent(name)
            // `unlink` and not `FileManager.removeItem`: one atomic syscall with
            // no check/use window, and it can NEVER recurse. `removeItem` is
            // documented recursive, so a directory that appeared at a legacy name
            // between a type check and the removal would be deleted WITH ITS
            // CONTENTS, at launch, before any UI exists to report it.
            if unlink(url.path) == 0 {
                result.deleted += 1
                continue
            }
            let err = errno   // capture before any call below can clobber it
            if err == ENOENT { continue }   // already gone — the common path
            // Darwin returns EPERM for BOTH a directory and an immutable file, and
            // the two are not the same outcome, so the ambiguity has to be
            // resolved. This query is safe where the old one was not: NO removal
            // follows it, it only classifies. An unresolvable answer counts as a
            // FAILURE, never as a clean skip — that keeps the one-shot flag unset
            // and the name retried, rather than stranding it forever on a
            // transient metadata error.
            //
            // `lstat(2)` rather than `URL.resourceValues(forKeys: [.isDirectoryKey])`.
            // ⚠️ This is a BEHAVIOUR-PRESERVING simplification, NOT a bug fix, and
            // the distinction is worth the comment because it was reported as a
            // defect and is not one. Foundation's `.isDirectoryKey` does NOT follow
            // symlinks: on a symlink to a directory it answers `isDirectory ==
            // false` and `isSymbolicLink == true`, so the old predicate ALSO fell
            // through to the failure branch. Verified twice, because the docs do
            // not say so plainly — directly against Foundation, and by inverting
            // this line and re-running `StartupMigrationsTests`, which stays green
            // precisely because both spellings agree.
            // `lstat` is kept because it states the intent in the syscall itself:
            // one call, no Foundation round-trip, and "does not follow symlinks" is
            // its defined contract rather than an empirical finding a future reader
            // would have to re-establish. Only a REAL directory entry is the
            // permanent refusal this skip exists for; a symlink whose unlink failed
            // is a FAILURE either way.
            var entry = stat()
            if lstat(url.path, &entry) == 0, (entry.st_mode & S_IFMT) == S_IFDIR {
                continue                    // a directory at this name: deliberate, permanent refusal
            }
            result.failed += 1
            // Rule 12: diagnostic, so it must be a no-op in a production build.
            if DebugModeManager.isLoggingEnabled() {
                print("[Migration] Could not unlink legacy log \(name): "
                    + "\(String(cString: strerror(err))) — will retry next launch")
            }
        }
        return result
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
