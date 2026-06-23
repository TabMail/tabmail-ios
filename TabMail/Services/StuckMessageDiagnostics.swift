/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB

/// READ-ONLY diagnostic for the "searchable but can't open / no snippet / not in
/// its folder" class of stuck messages (most often seen on IMAP accounts).
///
/// Background: a message that shows up in local search but cannot be opened still
/// has a real `MessageHeader` row — an FTS hit whose GRDB header is missing is
/// dropped from results for IMAP (`SearchView.ftsResultsToSearchResults`). So the
/// header exists; what's broken is its *state*. The likely culprits are:
///   • `folderId` references a folder that isn't in the local `folder` table (or is
///     empty) → invisible in every folder browse, yet still searchable.
///   • the PK `id` ("accountId:folderPath:messageId") disagrees with the current
///     `folderPath`/`messageId` columns → an optimistic-move remnant whose
///     destination-folder UID-remap never reconciled (rfc822 missing or the message
///     fell outside the sync overlap window).
///   • `bodyComplete = 0` → no snippet and the body fetch keeps failing because the
///     stored UID is stale for the folder it now claims to live in.
///
/// This scan only READS the DB + FTS and writes a human-readable report to the
/// `stuck_messages` log channel (shareable from the Debug menu). It mutates nothing.
/// Debug-gated per CLAUDE.md rule 12; only reachable from the hidden Debug menu.
enum StuckMessageDiagnostics {
    /// Bounded per-class sample size — display-only, full data stays in the DB.
    private static let sampleLimit = 40

    private struct Row: Sendable {
        let id: String
        let folderId: String
        let folderPath: String
        let messageId: String
        let subject: String
        let dateStr: String
        let provider: String
        let folderRole: String
        let hasRfc822: Bool
        let bodyComplete: Bool
        let bodyEmptyConfirmed: Bool
        let isInInbox: Bool
        let folderExists: Bool
        let hasHealthySibling: Bool
        let emptyFetchCount: Int
    }

    static func run() async {
        guard DebugModeManager.isLoggingEnabled() else { return }
        let pool = AppDatabase.dbPool
        BackgroundSyncLogger.clearStuckDiagLog()
        BackgroundSyncLogger.logStuckDiag("==== Stuck-message scan START ====")

        // --- Aggregate counts (read-only) ---------------------------------
        let total = await count(pool, "1 = 1")
        // Not browsable: folderId matches NO folder row (covers empty + orphan).
        let notBrowsable = await count(pool, "f.id IS NULL")
        let notBrowsableEmpty = await count(pool, "m.folderId = ''")
        let notBrowsableOrphan = await count(pool, "m.folderId <> '' AND f.id IS NULL")
        let notBrowsableBodyless = await count(pool, "f.id IS NULL AND m.bodyComplete = 0")
        // PK / folder mismatch: id was minted under a different folderPath/messageId
        // than the current columns → optimistic move that never reconciled.
        let pkMismatch = await count(pool, "m.id <> m.accountId || ':' || m.folderPath || ':' || m.messageId")
        let pkMismatchBodyless = await count(pool, "m.id <> m.accountId || ':' || m.folderPath || ':' || m.messageId AND m.bodyComplete = 0")
        // Bodyless breakdown.
        let bodyless = await count(pool, "m.bodyComplete = 0")
        let bodylessLocked = await count(pool, "m.bodyComplete = 0 AND m.bodyEmptyConfirmed = 1")
        let bodylessFailing = await count(pool, "m.bodyComplete = 0 AND m.bodyEmptyConfirmed = 0 AND m.emptyFetchCount > 0")
        let bodylessPending = await count(pool, "m.bodyComplete = 0 AND m.bodyEmptyConfirmed = 0 AND m.emptyFetchCount = 0")
        // Missing rfc822 among the not-browsable set → UID-remap can never recover.
        let notBrowsableNoRfc = await count(pool, "f.id IS NULL AND (m.rfc822MessageId IS NULL OR m.rfc822MessageId = '')")

        BackgroundSyncLogger.logStuckDiag("total messageHeader rows: \(total)")
        BackgroundSyncLogger.logStuckDiag("NOT-browsable (folderId matches no folder): \(notBrowsable)  [empty=\(notBrowsableEmpty), orphan=\(notBrowsableOrphan), bodyless=\(notBrowsableBodyless), missing-rfc822=\(notBrowsableNoRfc)]")
        BackgroundSyncLogger.logStuckDiag("PK/folder mismatch (optimistic-move remnant): \(pkMismatch)  [bodyless=\(pkMismatchBodyless)]")
        BackgroundSyncLogger.logStuckDiag("bodyless (bodyComplete=0): \(bodyless)  [lockedEmpty=\(bodylessLocked), failing=\(bodylessFailing), pending=\(bodylessPending)]")

        // --- Per-provider breakdown of not-browsable -----------------------
        let byProvider = await group(pool,
            sql: "SELECT COALESCE(a.provider,'?') AS k, COUNT(*) AS n FROM messageHeader m LEFT JOIN folder f ON m.folderId = f.id LEFT JOIN account a ON m.accountId = a.id WHERE f.id IS NULL GROUP BY a.provider ORDER BY n DESC")
        if !byProvider.isEmpty {
            BackgroundSyncLogger.logStuckDiag("not-browsable by provider: " + byProvider.map { "\($0.0)=\($0.1)" }.joined(separator: ", "))
        }

        // --- Bodyless rows that ARE in a real folder, by role --------------
        let bodylessByRole = await group(pool,
            sql: "SELECT f.role AS k, COUNT(*) AS n FROM messageHeader m JOIN folder f ON m.folderId = f.id WHERE m.bodyComplete = 0 GROUP BY f.role ORDER BY n DESC")
        if !bodylessByRole.isEmpty {
            BackgroundSyncLogger.logStuckDiag("bodyless IN a real folder, by role: " + bodylessByRole.map { "\($0.0)=\($0.1)" }.joined(separator: ", "))
        }

        // --- Samples -------------------------------------------------------
        let archiveRole = FolderRole.archive.rawValue
        let s1 = await sample(pool, label: "NOT-browsable (invisible folder)", whereSQL: "f.id IS NULL")
        let s2 = await sample(pool, label: "PK/folder mismatch (optimistic-move remnant)", whereSQL: "m.id <> m.accountId || ':' || m.folderPath || ':' || m.messageId")
        let s3 = await sample(pool, label: "bodyless in Archive-role folder", whereSQL: "m.bodyComplete = 0 AND f.role = '\(archiveRole)'")

        await logSample("SAMPLE A — \(s1.label)", s1.rows)
        await logSample("SAMPLE B — \(s2.label)", s2.rows)
        await logSample("SAMPLE C — \(s3.label)", s3.rows)

        // --- Folder coverage + per-month histogram (the date-gap hunt) -----
        await logCoverage(pool)

        // --- Interpretation hint (ranked by MAGNITUDE, not check order) ----
        let buckets: [(Int, String)] = [
            (bodyless, "bodyless body-text backlog (\(bodyless)) — searchable by header, no snippet until body is fetched/indexed. Cured by re-walk (Smart Reindex re-fetches); NOT corruption. Heaviest in custom folders (fetched last)."),
            (pkMismatch, "PK/folder mismatch (\(pkMismatch)) — optimistic move; benign where messageId is move-stable (Gmail), a stale-UID hazard on IMAP."),
            (notBrowsable, "NOT-browsable orphaned folderId (\(notBrowsable)) — searchable but in no browsable folder; needs orphan-cleanup/relocate. Smart Reindex does not touch folderId."),
        ]
        let dominant = buckets.max(by: { $0.0 < $1.0 })?.1 ?? "no signatures"
        BackgroundSyncLogger.logStuckDiag("INTERPRETATION (dominant by count): \(dominant)")
        BackgroundSyncLogger.logStuckDiag("DATE-GAP NOTE: compare each folder's per-month histogram below against the server. A contiguous missing month-range with backfillComplete=0 + a non-null cursor = re-walk still in flight (will fill). With backfillComplete=1 = a permanently-skipped range (needs a targeted re-walk of that UID window).")
        BackgroundSyncLogger.logStuckDiag("==== Stuck-message scan END ====")
    }

    // MARK: - Helpers (all read-only)

    private static func count(_ pool: DatabasePool, _ whereSQL: String) async -> Int {
        (try? await pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM messageHeader m LEFT JOIN folder f ON m.folderId = f.id WHERE \(whereSQL)") ?? 0
        }) ?? 0
    }

    private static func group(_ pool: DatabasePool, sql: String) async -> [(String, Int)] {
        (try? await pool.read { db -> [(String, Int)] in
            try GRDB.Row.fetchAll(db, sql: sql).map { r in
                let key: String = (r["k"] as String?) ?? "?"
                let n: Int = r["n"] ?? 0
                return (key, n)
            }
        }) ?? []
    }

    /// Per-folder coverage table + per-month histograms — the date-gap hunt.
    private static func logCoverage(_ pool: DatabasePool) async {
        struct Cov: Sendable {
            let fid, provider, role, path, cursor, oldest, minD, maxD: String
            let count: Int
            let complete: Bool
        }
        let rows: [Cov] = (try? await pool.read { db -> [Cov] in
            let sql = """
            SELECT f.id AS fid, COALESCE(a.provider, '?') AS provider,
                   COALESCE(f.role, '-') AS role, f.path AS path,
                   CAST(f.backfillUidCursor AS TEXT) AS cursor,
                   CAST(f.oldestSyncedDate AS TEXT) AS oldest,
                   f.backfillComplete AS complete,
                   (SELECT COUNT(*) FROM messageHeader m WHERE m.folderId = f.id) AS cnt,
                   (SELECT CAST(MIN(m.date) AS TEXT) FROM messageHeader m WHERE m.folderId = f.id) AS minD,
                   (SELECT CAST(MAX(m.date) AS TEXT) FROM messageHeader m WHERE m.folderId = f.id) AS maxD
            FROM folder f LEFT JOIN account a ON f.accountId = a.id
            ORDER BY a.provider, f.role, cnt DESC
            """
            return try GRDB.Row.fetchAll(db, sql: sql).map { r in
                Cov(fid: (r["fid"] as String?) ?? "?",
                    provider: (r["provider"] as String?) ?? "?",
                    role: (r["role"] as String?) ?? "-",
                    path: (r["path"] as String?) ?? "",
                    cursor: (r["cursor"] as String?) ?? "nil",
                    oldest: (r["oldest"] as String?) ?? "?",
                    minD: (r["minD"] as String?) ?? "-",
                    maxD: (r["maxD"] as String?) ?? "-",
                    count: (r["cnt"] as Int?) ?? 0,
                    complete: ((r["complete"] as Int?) ?? 0) != 0)
            }
        }) ?? []

        BackgroundSyncLogger.logStuckDiag("--- FOLDER COVERAGE (count, local date range, backfill state) ---")
        for c in rows where c.count > 0 {
            BackgroundSyncLogger.logStuckDiag("  [\(c.provider)/\(c.role)] \(c.path.prefix(40)) cnt=\(c.count) dates=[\(String(c.minD.prefix(10)))..\(String(c.maxD.prefix(10)))] bfComplete=\(c.complete ? "Y" : "n") cursor=\(c.cursor) oldestSynced=\(String(c.oldest.prefix(10)))")
        }

        // Per-month histogram for the folders most likely to show the gap.
        let gapRoles: Set<String> = ["inbox", "archive", "trash", "sent"]
        let histFolders = rows.filter { $0.count > 0 && (gapRoles.contains($0.role) || $0.provider == "imap") }
        BackgroundSyncLogger.logStuckDiag("--- PER-MONTH HISTOGRAM (>= 2024-01), inbox/archive/trash/sent + all IMAP folders ---")
        for c in histFolders {
            let hist = await monthHistogram(pool, folderId: c.fid)
            BackgroundSyncLogger.logStuckDiag("  [\(c.provider)/\(c.role)] \(c.path.prefix(30)): \(hist)")
        }
    }

    private static func monthHistogram(_ pool: DatabasePool, folderId: String) async -> String {
        let pairs: [(String, Int)] = (try? await pool.read { db -> [(String, Int)] in
            try GRDB.Row.fetchAll(db, sql: """
                SELECT strftime('%Y-%m', m.date) AS ym, COUNT(*) AS n
                FROM messageHeader m
                WHERE m.folderId = ? AND m.date >= '2024-01-01'
                GROUP BY ym ORDER BY ym
                """, arguments: [folderId]).map { r in
                    ((r["ym"] as String?) ?? "?", (r["n"] as Int?) ?? 0)
                }
        }) ?? []
        guard !pairs.isEmpty else { return "(none >= 2024-01)" }
        return pairs.map { "\($0.0)=\($0.1)" }.joined(separator: " ")
    }

    private static func sample(_ pool: DatabasePool, label: String, whereSQL: String) async -> (label: String, rows: [Row]) {
        let rows: [Row] = (try? await pool.read { db -> [Row] in
            let sql = """
            SELECT m.id AS id, m.folderId AS folderId, m.folderPath AS folderPath,
                   m.messageId AS messageId, SUBSTR(m.subject, 1, 30) AS subj,
                   CAST(m.date AS TEXT) AS dateText,
                   (m.rfc822MessageId IS NOT NULL AND m.rfc822MessageId <> '') AS hasRfc,
                   m.bodyComplete AS bodyComplete, m.bodyEmptyConfirmed AS bodyEmpty,
                   m.emptyFetchCount AS emptyCnt, m.isInInbox AS isInbox,
                   (f.id IS NOT NULL) AS folderExists, COALESCE(f.role, '-') AS folderRole,
                   COALESCE(a.provider, '?') AS provider,
                   EXISTS(SELECT 1 FROM messageHeader s JOIN folder sf ON s.folderId = sf.id
                          WHERE s.accountId = m.accountId AND s.rfc822MessageId IS NOT NULL
                            AND s.rfc822MessageId <> '' AND s.rfc822MessageId = m.rfc822MessageId
                            AND s.id <> m.id) AS sibling
            FROM messageHeader m
            LEFT JOIN folder f ON m.folderId = f.id
            LEFT JOIN account a ON m.accountId = a.id
            WHERE \(whereSQL)
            ORDER BY m.date DESC
            LIMIT \(sampleLimit)
            """
            return try GRDB.Row.fetchAll(db, sql: sql).map { r in
                Row(
                    id: (r["id"] as String?) ?? "?",
                    folderId: (r["folderId"] as String?) ?? "",
                    folderPath: (r["folderPath"] as String?) ?? "",
                    messageId: (r["messageId"] as String?) ?? "",
                    subject: (r["subj"] as String?) ?? "",
                    dateStr: (r["dateText"] as String?) ?? "?",
                    provider: (r["provider"] as String?) ?? "?",
                    folderRole: (r["folderRole"] as String?) ?? "-",
                    hasRfc822: ((r["hasRfc"] as Int?) ?? 0) != 0,
                    bodyComplete: ((r["bodyComplete"] as Int?) ?? 0) != 0,
                    bodyEmptyConfirmed: ((r["bodyEmpty"] as Int?) ?? 0) != 0,
                    isInInbox: ((r["isInbox"] as Int?) ?? 0) != 0,
                    folderExists: ((r["folderExists"] as Int?) ?? 0) != 0,
                    hasHealthySibling: ((r["sibling"] as Int?) ?? 0) != 0,
                    emptyFetchCount: (r["emptyCnt"] as Int?) ?? 0
                )
            }
        }) ?? []
        return (label, rows)
    }

    private static func logSample(_ title: String, _ rows: [Row]) async {
        BackgroundSyncLogger.logStuckDiag("--- \(title) (showing \(rows.count), max \(sampleLimit)) ---")
        guard !rows.isEmpty else {
            BackgroundSyncLogger.logStuckDiag("  (none)")
            return
        }
        // FTS membership for the sampled ids (confirms "searchable") — one batch call.
        let ids = rows.map(\.id)
        let missingFromFTS: Set<String> = (try? await SearchIndex.shared.headerIdsMissingFromFTS(ids)).map(Set.init) ?? []
        for r in rows {
            let inFTS = missingFromFTS.contains(r.id) ? "n" : "Y"
            // Display-only: id/messageId/subject are abbreviated, full data stays in DB.
            BackgroundSyncLogger.logStuckDiag(
                "  id=\(r.id) prov=\(r.provider) folderId=\(r.folderId.isEmpty ? "''" : r.folderId) path=\(r.folderPath) msgId=\(r.messageId) rfc822=\(r.hasRfc822 ? "Y" : "n") body=\(r.bodyComplete ? "Y" : "n") emptyConf=\(r.bodyEmptyConfirmed ? "Y" : "n") emptyCnt=\(r.emptyFetchCount) inbox=\(r.isInInbox ? "Y" : "n") folderExists=\(r.folderExists ? "Y" : "n") role=\(r.folderRole) sibling=\(r.hasHealthySibling ? "Y" : "n") inFTS=\(inFTS) date=\(r.dateStr) subj=\"\(r.subject)\""
            )
        }
    }
}
