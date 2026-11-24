import Foundation
import GRDB

/// Reads the HTML-cache pair: `messageHeader.htmlCachedAt`, the `fetchedAt` of the
/// message's cached HTML (its `messageBody` row), NULL when none is cached. SQLite's
/// triggers keep it exact whatever code writes either table (migration
/// `v116_addMessageHeaderHTMLCachedAt`), the way `bodyComplete` pairs the search text
/// (ADR-IOS-050).
///
/// Every question "is this message's HTML cached?" goes through this type; no other
/// code probes `messageBody` for existence or writes the column
/// (`HTMLCachePairFenceTests`). Reading the HTML itself still reads `messageBody`.
///
/// ## Before the deferred index step
///
/// v116 adds the column empty and its triggers; the bodies cached before it are
/// recorded by the fill (`fillSQL`), which runs in the deferred index step
/// (`SyncEngine.deferredIndexes`) of the first background maintenance pass after the
/// upgrade, in the same write that builds `indexName` and analyzes it. Until that
/// write commits, a message whose HTML was cached before v116
/// and not written since reads as not cached here. That is the only difference:
///
/// - `AccountManager.fetchBody` and the thread bubble's load fetch its body again;
/// - the notification merge re-merges a staged row whose body predates v116, because
///   its body insert is ignored and leaves the pair empty;
/// - the AI queue's diagnostic line says `hasMessageBody=false`.
///
/// None of them deletes a body or uses another message's content, and the evict
/// waits for `indexName` (`SyncEngine.runEvictStaleBodiesIfIndexed`). The one-time
/// `bodyComplete` restore, which runs at startup and can come first, keeps its own
/// probe of `messageBody` for this reason. The index existing is the proof the fill
/// ran: both commit in one write, and nothing else records it.
///
/// ⚠ STAGE E1: the triggers match a body to its header by id, which is exact while
/// `ContentKey.forHeader` returns the header id. Every answer here is about a HEADER,
/// so callers pass header ids and never content keys.
enum HTMLCachePair {

    /// The column, for code that has to name it (`InboxNotificationObserver`).
    static let column = "htmlCachedAt"

    /// The index the evict's page seeks, built by the deferred index step.
    static let indexName = "messageHeader_htmlCachedAt"

    /// A partial index: it holds only the headers outside every inbox whose HTML is
    /// cached, the set the evict seeks (`isInInbox = 0 AND htmlCachedAt < cutoff`), so
    /// only a statement whose WHERE implies `isInInbox = 0 AND htmlCachedAt IS NOT NULL`
    /// can use it. Built over every header, it was also chosen for an `isInInbox = 1`
    /// read without planner statistics (the query plan check: `NotificationActionRouter`'s
    /// inbox lookup then walked every inbox header). `isInInbox` stays its first column, one value
    /// throughout: the evict's `isInInbox = 0` is then an equality on the index, so
    /// without statistics the planner still seeks it (equality and range) rather than
    /// `messageHeader_isInInbox_date` (equality only) and a sort. A header enters it only
    /// while it is outside the inbox with cached HTML, so an inbox header's writes and a
    /// header with no cached HTML never write to it. Building it reads `messageHeader`
    /// once.
    ///
    /// QUERY COST (keep this note; QueryCostNoteFenceTests checks it): every query, index,
    /// table or column added here, and every query that reads them, must be as cheap as
    /// the data allows. It must not add a new table or index scan unless no index or
    /// plainer query can avoid it; then state why at the query. Prove a query or index
    /// change on a mail-sized database with the DBProof harness
    /// (TabMailTests/Helpers/DBProofHarness.swift).
    static let indexSQL = """
        CREATE INDEX IF NOT EXISTS messageHeader_htmlCachedAt
        ON messageHeader(isInInbox, htmlCachedAt)
        WHERE isInInbox = 0 AND htmlCachedAt IS NOT NULL
        """

    /// Records the bodies cached before v116: each body's header gets its `fetchedAt`.
    /// Runs once, in the deferred step's write and before `indexSQL`, so the index is
    /// built once from the filled column. It reads every cached body once (`fetchedAt`
    /// is stored after the HTML, so each read walks that body's pages) and seeks each
    /// one's header by primary key; headers with no body keep NULL, which the triggers
    /// have kept exact since v116.
    static let fillSQL = """
        UPDATE messageHeader
        SET htmlCachedAt = (SELECT fetchedAt FROM messageBody WHERE messageBody.id = messageHeader.id)
        WHERE id IN (SELECT id FROM messageBody)
        """

    /// Whether `headerId`'s HTML is cached. Reads one header row by primary key, never
    /// the body row (which holds the HTML). A header that does not exist reads as not
    /// cached.
    static func isCached(_ db: Database, headerId: String) throws -> Bool {
        try Bool.fetchOne(
            db,
            sql: "SELECT htmlCachedAt IS NOT NULL FROM messageHeader WHERE id = ?",
            arguments: [headerId]
        ) ?? false
    }

    // MARK: - The body-cache evict's candidates

    /// Where the evict's walk stopped: the last candidate's `htmlCachedAt` as stored
    /// (compared in the column's own representation, never re-encoded through `Date`)
    /// and its header rowid.
    struct EvictCursor: Sendable {
        let cachedAt: DatabaseValue
        let rowId: Int64
    }

    /// A message outside every inbox whose HTML was cached before the cutoff.
    struct EvictCandidate: Sendable {
        let headerId: String
        let folderId: String
    }

    /// One page of candidates, and the cursor after its last one (nil when the page is
    /// empty: the walk is done).
    struct EvictPage: Sendable {
        let candidates: [EvictCandidate]
        let last: EvictCursor?
    }

    /// The evict's page: the next `limit` headers outside an inbox whose HTML was cached
    /// before the cutoff, after the cursor, in `messageHeader_htmlCachedAt` order
    /// (`htmlCachedAt`, then rowid). A seek on that index that starts at the cursor and
    /// stops after `limit` entries; inbox headers are not in it. The WHERE keeps the
    /// literal `isInInbox = 0`: SQLite matches a partial index's WHERE against literal
    /// terms, not against parameters bound after the statement is prepared.
    /// Arguments: `[cutoff, limit]` for the first page, and
    /// `[cutoff, cursor cachedAt, cursor rowid, limit]` after it.
    static func evictCandidatesPageSQL(afterCursor: Bool) -> String {
        """
        SELECT rowid AS headerRowId, id, folderId, htmlCachedAt FROM messageHeader
        WHERE isInInbox = 0 AND htmlCachedAt < ?\(afterCursor ? " AND (htmlCachedAt, rowid) > (?, ?)" : "")
        ORDER BY htmlCachedAt, rowid LIMIT ?
        """
    }

    /// Reads one page of `evictCandidatesPageSQL`.
    static func evictCandidatesPage(
        _ db: Database, cachedBefore cutoff: Date, after cursor: EvictCursor?, limit: Int
    ) throws -> EvictPage {
        let arguments: StatementArguments
        if let cursor {
            arguments = [cutoff, cursor.cachedAt, cursor.rowId, limit]
        } else {
            arguments = [cutoff, limit]
        }
        let rows = try Row.fetchAll(
            db, sql: evictCandidatesPageSQL(afterCursor: cursor != nil), arguments: arguments)
        let candidates = rows.map { row in
            EvictCandidate(headerId: row["id"], folderId: row["folderId"])
        }
        let last = rows.last.map { row in
            EvictCursor(cachedAt: row["htmlCachedAt"], rowId: row["headerRowId"])
        }
        return EvictPage(candidates: candidates, last: last)
    }
}
