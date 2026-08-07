/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

// MARK: - R13-U6 — the D statement's rewrite changed the SQL TEXT, nothing else
//
// INVARIANT (system property): **`InboxListReader.durableQuerySQL` selects
// exactly the rows, in exactly the order, that the GRDB query-interface form it
// replaced selected.** The rewrite exists only because GRDB cannot express
// `INDEXED BY`; the predicate, its clause order, the `ORDER BY` and the `LIMIT`
// are meant to be untouched. This suite is what makes "meant to be" checkable.
//
// ⚠️ THIS IS NOT CEREMONY. Writing the builder, I transcribed the triage keyset
// cursor's second placeholder as `cursor.date` where the predicate reads
// `tagSortOrder > ?`. Hand-porting a parameterised predicate to string
// concatenation moves the argument/placeholder correspondence out of the
// compiler's reach, and that is precisely the class this pins: a wrong argument
// ORDER still compiles, still runs, and silently returns a different page.
//
// The oracle is the query-interface form, spelled out below verbatim from the
// pre-rewrite source, so the two statements are compared rather than one being
// compared with itself.

@Suite("R13-U6 — the D statement's SQL matches the query interface it replaced")
struct InboxListReaderStatementTests {

    /// The pre-rewrite D query, verbatim (`InboxListReader.gather` at
    /// `74dd0cfba`). Kept in GRDB form on purpose: an oracle that shares the
    /// implementation cannot detect a defect in it.
    private func referenceRequest(folderId: String, query: InboxListQuery) -> QueryInterfaceRequest<MessageHeader> {
        var q = MessageHeader.filter(Column("folderId") == folderId)
            .filter(Column("headerComplete") == true)
        if query.filterUnread {
            q = q.filter(Column("isRead") == false)
        }
        for labelId in query.filterLabelIds.sorted() {
            q = q.filter(
                sql: """
                EXISTS (
                    SELECT 1 FROM messageUserLabel
                    WHERE messageUserLabel.messageId = messageHeader.id
                      AND messageUserLabel.userLabelId = ?
                )
                """,
                arguments: [labelId]
            )
        }
        if let cursor = query.before {
            if query.mode == .triage {
                q = q.filter(
                    sql: "tagSortOrder >= ? AND (tagSortOrder > ? OR date < ? OR (date = ? AND id > ?))",
                    arguments: [cursor.tagSortOrder, cursor.tagSortOrder, cursor.date, cursor.date, cursor.id]
                )
            } else {
                q = q.filter(
                    sql: "date <= ? AND (date < ? OR id > ?)",
                    arguments: [cursor.date, cursor.date, cursor.id]
                )
            }
        }
        if query.mode == .triage {
            q = q.order(Column("tagSortOrder").asc, Column("date").desc, Column("id").asc)
        } else {
            q = q.order(Column("date").desc, Column("id").asc)
        }
        return q.limit(query.targetCount)
    }

    /// 40 rows across two folders and two accounts: five tag buckets, deliberate
    /// date TIES (so the `id` tie-break is exercised), a read/unread mix, and two
    /// labels on overlapping subsets.
    private func makeFixture() throws -> DatabaseQueue {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1", email: "a@example.com")
        try TestDatabase.insertAccount(db, id: "acc2", email: "b@example.com", provider: .imap)
        try TestDatabase.insertFolder(db, accountId: "acc1")
        try TestDatabase.insertFolder(db, name: "Archive", path: "Archive", role: .archive, accountId: "acc1")
        try TestDatabase.insertFolder(db, accountId: "acc2")

        let base = Date(timeIntervalSince1970: 1_700_000_000)
        // Every bucket the order can put a row in: 0/1/2/3 plus untagged (99).
        //
        // ⚠️ `ActionTag.none` IS SPELLED IN FULL ON PURPOSE. In an `[ActionTag?]`
        // literal a bare `.none` binds to `Optional<ActionTag>.none` — i.e. `nil`
        // — not to `ActionTag.none`, and the compiler only *warns*
        // (`assuming you mean 'Optional<ActionTag>.none'`). This array shipped
        // with the bare form in `2e971a2d5`, so it seeded FOUR distinct values
        // with `nil` duplicated while this comment claimed five, and bucket 1
        // (`.none`, `sortOrder == 1`) was never exercised by either test below.
        // `feedback_swift_actiontag_none_ambiguity`.
        let tags: [ActionTag?] = [nil, .reply, ActionTag.none, .archive, .delete]
        var ids: [String] = []
        for i in 0..<40 {
            // Every fourth pair shares a date exactly — the tie-break's reason to exist.
            let date = base.addingTimeInterval(TimeInterval((i / 2) * 3600))
            let folder = i < 30 ? "acc1:INBOX" : (i < 35 ? "acc1:Archive" : "acc2:INBOX")
            let account = i < 35 ? "acc1" : "acc2"
            let h = try TestDatabase.insertMessageHeader(
                db, messageId: String(format: "%04d", i), date: date,
                folderId: folder, accountId: account,
                folderPath: folder.hasSuffix("Archive") ? "Archive" : "INBOX",
                isRead: i % 3 == 0,
                rfc822MessageId: "m\(i)@example.com",
                actionTag: tags[i % tags.count])
            ids.append(h.id)
        }
        try db.write { dbConn in
            // `MessageHeader.headerComplete` defaults to FALSE in the model, and
            // the D predicate requires it — without this the fixture is invisible
            // to both statements and every comparison below is vacuously equal.
            try dbConn.execute(sql: "UPDATE messageHeader SET headerComplete = 1")
            for name in ["work", "personal"] {
                let label = UserLabel(accountId: "acc1", providerLabelId: name, name: name, isSystem: false)
                try label.insert(dbConn)
            }
            // Label membership is deliberately NOT aligned with `isRead`
            // (`i % 3 == 0`): if it were, the `unread + both labels` shapes would
            // select nothing and their equalities would be vacuous. `work ∧
            // personal` is `i even AND i % 3 == 1` — six rows, all of them unread.
            for (i, id) in ids.enumerated() where i < 35 {
                if i % 2 == 0 { try MessageUserLabel(messageId: id, userLabelId: "acc1:work").insert(dbConn) }
                if i % 3 == 1 { try MessageUserLabel(messageId: id, userLabelId: "acc1:personal").insert(dbConn) }
            }
        }

        // 🚨 THE FIXTURE'S STATED PRECONDITION, ASSERTED RATHER THAN COMMENTED.
        // INVARIANT: **the displayed folder contains a row in every bucket the
        // triage `ORDER BY tagSortOrder ASC` can produce** — the property the
        // comment above claims. Read back out of the DATABASE, not off `tags`,
        // so it pins what was actually seeded rather than restating the literal.
        //
        // This is the check that was missing when `2e971a2d5` wrote a bare
        // `.none` into an `[ActionTag?]` literal: bucket 1 silently vanished,
        // every equality below stayed green, and nothing said the matrix had
        // stopped covering the order it exists to compare. Same role as the
        // `shapesChecked`/`nonEmptyShapes` counters (`MIS-030`) — a comparison
        // over a degraded fixture is satisfiable without proving anything.
        let buckets = try db.read { dbConn in
            try Int.fetchAll(dbConn, sql: """
                SELECT DISTINCT tagSortOrder FROM messageHeader
                WHERE folderId = 'acc1:INBOX' ORDER BY tagSortOrder
                """)
        }
        #expect(buckets == [0, 1, 2, 3, 99],
                "the fixture no longer seeds every triage bucket, so the comparisons below cover a narrower order than they claim: \(buckets)")

        return db
    }

    /// Every shape the builder can emit: 2 modes × unread on/off × 0/1/2 labels
    /// × no-cursor/cursor. The cursor is taken from the reference form's own
    /// 3rd row for that shape, so it is a cursor the mode actually produces.
    @Test("Every shape of the rewritten D statement returns the same rows in the same order as the query interface")
    func rewrittenStatementMatchesTheQueryInterface() throws {
        let db = try makeFixture()
        var shapesChecked = 0
        var nonEmptyShapes = 0

        for mode in [InboxMode.normal, .triage] {
            for filterUnread in [false, true] {
                for labels in [Set<String>(), ["acc1:work"], ["acc1:work", "acc1:personal"]] {
                    for withCursor in [false, true] {
                        var cursor: InboxPageCursor?
                        if withCursor {
                            let probe = InboxListQuery(
                                displayedFolderIds: ["acc1:INBOX"], filterUnread: filterUnread,
                                filterLabelIds: labels, mode: mode, targetCount: 3, before: nil)
                            let rows = try db.read { try referenceRequest(folderId: "acc1:INBOX", query: probe).fetchAll($0) }
                            guard let last = rows.last else { continue }
                            cursor = InboxPageCursor(tagSortOrder: last.tagSortOrder, date: last.date, id: last.id)
                        }
                        let query = InboxListQuery(
                            displayedFolderIds: ["acc1:INBOX"], filterUnread: filterUnread,
                            filterLabelIds: labels, mode: mode, targetCount: 7, before: cursor)

                        let (sql, arguments) = InboxListReader.durableQuerySQL(folderId: "acc1:INBOX", query: query)
                        let produced = try db.read { try MessageHeader.fetchAll($0, sql: sql, arguments: arguments) }
                        let expected = try db.read { try referenceRequest(folderId: "acc1:INBOX", query: query).fetchAll($0) }

                        let label = "mode=\(mode) unread=\(filterUnread) labels=\(labels.sorted()) cursor=\(withCursor)"
                        #expect(produced.map(\.id) == expected.map(\.id), "row set or order diverged — \(label)\nSQL: \(sql)")
                        shapesChecked += 1
                        if !expected.isEmpty { nonEmptyShapes += 1 }
                    }
                }
            }
        }

        // NON-VACUITY (MIS-030). Without these, a fixture that returns nothing —
        // or a loop whose `continue` swallowed every shape — satisfies every
        // equality above.
        #expect(shapesChecked == 24, "the shape matrix did not run to completion: \(shapesChecked)")
        #expect(nonEmptyShapes == 24, "some shape returned no rows at all, so its equality proved nothing: \(nonEmptyShapes)")
    }

    /// The mutation this suite exists for. A deliberately wrong ARGUMENT ORDER
    /// in the triage keyset predicate — the exact slip made while writing the
    /// builder — compiles, runs, and must be caught by returning a different
    /// page. Without this, "the two forms agree" could be true because the
    /// cursor shapes are never actually discriminating.
    @Test("CONTROL — a swapped argument in the triage keyset predicate does change the page, so the comparison above can see one")
    func aSwappedKeysetArgumentIsDetectable() throws {
        let db = try makeFixture()
        let probe = InboxListQuery(
            displayedFolderIds: ["acc1:INBOX"], filterUnread: false, filterLabelIds: [],
            mode: .triage, targetCount: 3, before: nil)
        let head = try db.read { try referenceRequest(folderId: "acc1:INBOX", query: probe).fetchAll($0) }
        #expect(head.count == 3)
        guard let last = head.last else { return }
        let query = InboxListQuery(
            displayedFolderIds: ["acc1:INBOX"], filterUnread: false, filterLabelIds: [],
            mode: .triage, targetCount: 7,
            before: InboxPageCursor(tagSortOrder: last.tagSortOrder, date: last.date, id: last.id))

        let correct = try db.read { try referenceRequest(folderId: "acc1:INBOX", query: query).fetchAll($0) }
        // `tagSortOrder > ?` fed the cursor's DATE instead of its tag order.
        let corrupted = try db.read { dbConn in
            try MessageHeader.fetchAll(dbConn, sql: """
                SELECT * FROM messageHeader INDEXED BY messageHeader_triage_display
                WHERE folderId = ? AND headerComplete = 1
                  AND tagSortOrder >= ? AND (tagSortOrder > ? OR date < ? OR (date = ? AND id > ?))
                ORDER BY tagSortOrder ASC, date DESC, id ASC LIMIT ?
                """, arguments: ["acc1:INBOX", last.tagSortOrder, last.date, last.date, last.date, last.id, 7])
        }
        #expect(correct.map(\.id) != corrupted.map(\.id),
                "a swapped keyset argument produced an identical page, so the equivalence test above cannot detect one")
    }
}
