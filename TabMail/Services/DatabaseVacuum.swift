/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB

/// The `auto_vacuum` mode of the email database (`AppDatabase`) and the search
/// database (`SearchIndex`), and every `VACUUM` the app runs (ADR-IOS-121).
///
/// Both databases use `auto_vacuum = INCREMENTAL`. A delete still moves the pages
/// it frees to the database's freelist; `PRAGMA incremental_vacuum(N)` then gives up
/// to N of them back to the device, by moving pages from the end of the file into
/// them and cutting the end off (`giveBackEmptyPages`). Nothing gives pages back on
/// its own: the background processing job does it in short steps
/// (`SyncEngine.runOvernightSpaceReturn`).
///
/// The mode can be set in two ways only: before the database file's first page is
/// written (a new install, `setIncrementalOnNewFile`), or by a `VACUUM` run after
/// the setting (`vacuum`). A database created before this change is on
/// `auto_vacuum = NONE` until one of those runs: the one-time upgrade the user
/// starts (`DatabaseUpgrade`), or a `VACUUM` the app already ran for another
/// reason (Delete All Email Index Data).
enum DatabaseVacuum {

    /// `PRAGMA auto_vacuum` of a database whose empty pages stay in the file.
    static let noneMode = 0
    /// `PRAGMA auto_vacuum` of a database that gives its empty pages back on
    /// `incremental_vacuum` (the app's databases since ADR-IOS-121).
    static let incrementalMode = 2

    /// For `Configuration.prepareDatabase`, before anything else writes: on a new
    /// database file (no page written yet), sets `auto_vacuum = INCREMENTAL`. On an
    /// existing file it does nothing.
    ///
    /// It has to come before WAL mode: switching a new file to WAL writes its first
    /// page, and after that the setting no longer changes the file (measured on SQLite
    /// 3.54.1: set before WAL, the first table finds INCREMENTAL; set after, NONE).
    /// GRDB runs `prepareDatabase` before it sets up WAL mode on a pool's writer.
    ///
    /// Writer connection only: GRDB opens a pool's readers read-only, and on an
    /// INCREMENTAL database the setting is a write, which fails there ("attempt to
    /// write a readonly database", measured).
    static func setIncrementalOnNewFile(_ db: Database) throws {
        guard !db.configuration.readonly,
              try Int.fetchOne(db, sql: "PRAGMA page_count") == 0 else { return }
        try db.execute(sql: "PRAGMA auto_vacuum = INCREMENTAL")
    }

    /// THE `VACUUM`. Every one the app runs goes through here: the one-time
    /// upgrade the user starts (`switchToIncremental`), "Delete All Email Index
    /// Data", the wipe of the app's data and the search database's after a reset.
    /// It sets `auto_vacuum = INCREMENTAL` on the connection first, so the
    /// rewritten database is INCREMENTAL, whatever it was before.
    ///
    /// On the writer connection, outside any transaction. It holds the database's
    /// writer for its whole run and cannot be stopped once its copy is being
    /// written back (ADR-IOS-121).
    static func vacuum(_ db: Database) throws {
        try db.execute(sql: "PRAGMA auto_vacuum = INCREMENTAL")
        try db.execute(sql: "VACUUM")
    }

    /// The one-time switch of a database on `auto_vacuum = NONE` (ADR-IOS-121):
    /// `vacuum`, with its temporary copy in a file (`temp_store = FILE`), and the
    /// connection's own `temp_store` restored afterwards, also when the `VACUUM`
    /// throws. The search database's connections keep temporary data in memory,
    /// which would hold the whole copy in memory (measured, #1450: 595 MB at the peak
    /// for a 462 MB database, against 182 MB with a file).
    static func switchToIncremental(_ db: Database) throws {
        let tempStore = try Int.fetchOne(db, sql: "PRAGMA temp_store") ?? 0
        try db.execute(sql: "PRAGMA temp_store = FILE")
        defer { try? db.execute(sql: "PRAGMA temp_store = \(tempStore)") }
        try vacuum(db)
    }

    /// One step of giving empty pages back: up to `pages` pages of the freelist go
    /// back to the device. Returns the empty pages left. Never the argument-less
    /// `incremental_vacuum`, which gives every page back in one write, and `pages`
    /// is at least 1: SQLite reads 0 or less the same way.
    ///
    /// The statement returns one row per page it frees, and frees one page per row
    /// read, so it frees all `pages` only when it is read to its end, which
    /// `execute` does (a caller that steps it once frees one page, measured). On a
    /// database that is not INCREMENTAL it frees nothing.
    ///
    /// On the writer connection, outside any transaction: one write, which commits
    /// at its end.
    static func giveBackEmptyPages(_ db: Database, upTo pages: Int) throws -> Int {
        try db.execute(sql: "PRAGMA incremental_vacuum(\(pages))")
        return try Int.fetchOne(db, sql: "PRAGMA freelist_count") ?? 0
    }

    /// A database's `auto_vacuum` mode and its pages, read from its header (no table).
    struct SpaceState: Equatable, Sendable {
        let autoVacuum: Int
        let pageCount: Int64
        let freePages: Int64
        let pageSize: Int64

        /// The database's size: all its pages, the empty ones included.
        var allBytes: Int64 { pageCount * pageSize }

        /// nil if SQLite returns no row.
        static func read(_ db: Database) throws -> SpaceState? {
            guard let row = try Row.fetchOne(db, sql: """
                SELECT mode.auto_vacuum AS autoVacuum, pageCount.page_count AS pageCount,
                    freePages.freelist_count AS freePages, pageSize.page_size AS pageSize
                FROM pragma_auto_vacuum() AS mode, pragma_page_count() AS pageCount,
                    pragma_freelist_count() AS freePages, pragma_page_size() AS pageSize
                """) else { return nil }
            return SpaceState(
                autoVacuum: row["autoVacuum"], pageCount: row["pageCount"],
                freePages: row["freePages"], pageSize: row["pageSize"])
        }
    }
}
