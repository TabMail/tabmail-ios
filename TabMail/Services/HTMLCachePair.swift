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
/// ⚠ STAGE E1: the triggers match a body to its header by id, which is exact while
/// `ContentKey.forHeader` returns the header id. Every answer here is about a HEADER,
/// so callers pass header ids and never content keys.
enum HTMLCachePair {

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

    /// The ids among `headerIds` whose HTML is cached; every other id has none, or no
    /// header. One primary-key seek per id; the caller passes a bounded batch (each id
    /// is one bound argument).
    static func cachedHeaderIds(_ db: Database, among headerIds: [String]) throws -> Set<String> {
        guard !headerIds.isEmpty else { return [] }
        let placeholders = headerIds.map { _ in "?" }.joined(separator: ",")
        return try Set(String.fetchAll(
            db,
            sql: "SELECT id FROM messageHeader WHERE id IN (\(placeholders)) AND htmlCachedAt IS NOT NULL",
            arguments: StatementArguments(headerIds)
        ))
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
    /// (`isInInbox`, `htmlCachedAt`, then rowid). A seek on that index that starts at
    /// the cursor and stops after `limit` entries; old inbox entries are never visited.
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
