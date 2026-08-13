/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

/// `searchFTSOnly` computes `snippet()` in a second pass, over the rows that
/// survived `ORDER BY dateMs DESC, rank ASC LIMIT ?`, instead of over every
/// candidate the `MATCH` produced. That is a pure cost change, so what these
/// tests pin is the SYSTEM PROPERTY the rewrite must not disturb:
///
/// > the same rows, in the same order, and **the snippet belonging to that row**
/// > present on every one of them.
///
/// They are deliberately NOT written against the mechanism ("phase 2 ran",
/// "the dictionary had N entries"). A two-phase rewrite has exactly three ways
/// to be wrong, and each one is a green mechanism test:
///
/// 1. **Mis-association** — row *i* is handed row *j*'s snippet. Caught by giving
///    every document a marker token that appears in no other document and
///    asserting each result's snippet carries its OWN marker, never a
///    neighbour's. A snippet that is merely "present and non-empty" passes a
///    mis-associating implementation.
/// 2. **Wrong shard** — the survivors are grouped by shard year, and looking a
///    rowid up in the wrong shard's table silently returns nothing (or, if the
///    rowid spaces ever overlapped, the wrong document). Caught by
///    `snippetsSpanTwoShards`, whose survivor set straddles a year boundary.
/// 3. **Dropped or degraded snippet** — the field returns empty, truncated, or
///    without its highlight delimiters. Caught by asserting the delimiters and
///    the marker, not just non-emptiness.
///
/// Each test's LIMIT is deliberately SMALLER than its candidate count, so the
/// deferral is non-vacuous: if it were not, phase 1 and phase 2 would see the
/// same row set and a mis-association could not be distinguished from a
/// correct implementation.
@Suite("FTS snippets are deferred to the surviving rows without changing them",
       .serialized, .processGlobalState)
struct SearchSnippetDeferralTests {

    private var index: SearchIndex { SearchIndex.shared }

    /// The token every fixture document shares, so one query matches them all.
    /// Long and nonsensical so no other suite's fixtures collide with it.
    private let sharedToken = "snippetdeferralsharedtoken"

    private func marker(_ i: Int) -> String { "snippetdeferralmarker\(i)zz" }

    /// `dateMs` for 1 March of `year`, plus `offsetDays` — used both to place a
    /// document in a known year shard and to give it a known sort position.
    private func dateMs(year: Int, offsetDays: Int) -> Int64 {
        var components = DateComponents()
        components.year = year
        components.month = 3
        components.day = 1
        components.timeZone = TimeZone(identifier: "UTC")
        let base = Calendar(identifier: .gregorian).date(from: components)!
        return Int64((base.timeIntervalSince1970 + Double(offsetDays) * 86_400) * 1000)
    }

    /// Indexes one document whose BODY carries the shared token next to a marker
    /// unique to this document. The subject deliberately does NOT contain the
    /// shared token: `snippet(table, -1, …)` auto-selects the column with the
    /// match, so keeping the match in the body only makes the returned text
    /// predictable.
    private func seed(headerId: String, folderId: String, dateMs: Int64,
                      markerIndex: Int) async throws {
        let key = ContentKey(rawValue: headerId)
        try await index.removeMessages(contentKeys: [key])
        _ = try await index.indexHeaders([
            FTSHeaderRecord(
                contentKey: key, headerId: headerId, messageId: "m\(markerIndex)",
                subject: "deferral fixture number \(markerIndex)",
                from: "sender@example.com", to: "recipient@example.com",
                dateMs: dateMs, folderId: folderId)
        ])
        try await index.updateBody(
            contentKey: key,
            body: "lorem ipsum filler text \(sharedToken) \(marker(markerIndex)) "
                + "trailing filler so the snippet window has somewhere to run")
    }

    private func cleanup(_ headerIds: [String]) async {
        try? await index.removeMessages(contentKeys: headerIds.map(ContentKey.init(rawValue:)))
    }

    // MARK: - 1. Every surviving row carries its OWN snippet

    @Test("Each returned row's snippet is that row's own text, with highlights intact")
    func snippetBelongsToItsOwnRow() async throws {
        let folderId = "snippetdeferral_own:INBOX"
        let ids = (0..<8).map { "snippetdeferral_own:INBOX:\($0)" }
        await cleanup(ids)
        defer { Task { await cleanup(ids) } }

        // Eight candidates, newest last so the expected survivors are unambiguous.
        for i in 0..<8 {
            try await seed(headerId: ids[i], folderId: folderId,
                           dateMs: dateMs(year: 2026, offsetDays: i), markerIndex: i)
        }

        // LIMIT 3 of 8 candidates: the deferral has real work to skip.
        let results = try await index.keywordSearch(
            query: sharedToken, limit: 3, folderIds: [folderId])

        #expect(results.count == 3, "the LIMIT must cut the candidate set, or this test is vacuous")
        guard results.count == 3 else { return }

        // Order: the three newest, dateMs descending.
        #expect(results.map(\.dateMs) == [7, 6, 5].map { dateMs(year: 2026, offsetDays: $0) })
        #expect(results.map(\.contentKey.rawValue) == [ids[7], ids[6], ids[5]])

        for result in results {
            let docIndex = ids.firstIndex(of: result.contentKey.rawValue)
            #expect(docIndex != nil)
            guard let docIndex else { continue }

            // (a) present, (b) ITS OWN, (c) nobody else's, (d) still highlighted.
            #expect(!result.snippet.isEmpty,
                    "row \(result.contentKey.rawValue) came back with no snippet")
            #expect(result.snippet.contains(marker(docIndex)),
                    "row \(result.contentKey.rawValue) got a snippet without its own marker: \(result.snippet)")
            for other in 0..<8 where other != docIndex {
                #expect(!result.snippet.contains(marker(other)),
                        "row \(result.contentKey.rawValue) got row \(other)'s snippet: \(result.snippet)")
            }
            #expect(result.snippet.contains("[") && result.snippet.contains("]"),
                    "highlight delimiters were dropped: \(result.snippet)")
        }
    }

    // MARK: - 2. The survivor set may straddle year shards

    @Test("Snippets are correct when the surviving rows come from two different shards")
    func snippetsSpanTwoShards() async throws {
        let folderId = "snippetdeferral_shards:INBOX"
        // Two documents per year so each shard also has a candidate that the
        // LIMIT discards — a phase 2 that ignored the LIMIT would still pass the
        // marker assertions, but the count assertion pins it.
        let ids = [
            "snippetdeferral_shards:INBOX:2024a", "snippetdeferral_shards:INBOX:2024b",
            "snippetdeferral_shards:INBOX:2026a", "snippetdeferral_shards:INBOX:2026b",
        ]
        await cleanup(ids)
        defer { Task { await cleanup(ids) } }

        try await seed(headerId: ids[0], folderId: folderId,
                       dateMs: dateMs(year: 2024, offsetDays: 0), markerIndex: 20)
        try await seed(headerId: ids[1], folderId: folderId,
                       dateMs: dateMs(year: 2024, offsetDays: 1), markerIndex: 21)
        try await seed(headerId: ids[2], folderId: folderId,
                       dateMs: dateMs(year: 2026, offsetDays: 0), markerIndex: 22)
        try await seed(headerId: ids[3], folderId: folderId,
                       dateMs: dateMs(year: 2026, offsetDays: 1), markerIndex: 23)

        // LIMIT 3 of 4: both 2026 rows plus the newer 2024 row survive, so the
        // survivor set spans both shards and phase 2 must query both tables.
        let results = try await index.keywordSearch(
            query: sharedToken, limit: 3, folderIds: [folderId])

        #expect(results.count == 3)
        guard results.count == 3 else { return }
        #expect(results.map(\.contentKey.rawValue) == [ids[3], ids[2], ids[1]])

        let expectedMarkers = [23, 22, 21]
        for (result, expected) in zip(results, expectedMarkers) {
            #expect(result.snippet.contains(marker(expected)),
                    "cross-shard row \(result.contentKey.rawValue) lost or swapped its snippet: \(result.snippet)")
        }
        // The discarded 2024 row's marker must appear nowhere.
        for result in results {
            #expect(!result.snippet.contains(marker(20)))
        }
    }

    // MARK: - 3. Degenerate inputs

    @Test("A query that matches nothing returns no rows and does not fail")
    func noMatchReturnsEmpty() async throws {
        let results = try await index.keywordSearch(
            query: "snippetdeferralabsenttokenzz", limit: 10, folderIds: nil)
        #expect(results.isEmpty)
    }

    @Test("A survivor set smaller than the limit still gets every snippet")
    func fewerCandidatesThanLimit() async throws {
        let folderId = "snippetdeferral_few:INBOX"
        let ids = ["snippetdeferral_few:INBOX:0", "snippetdeferral_few:INBOX:1"]
        await cleanup(ids)
        defer { Task { await cleanup(ids) } }

        try await seed(headerId: ids[0], folderId: folderId,
                       dateMs: dateMs(year: 2026, offsetDays: 0), markerIndex: 30)
        try await seed(headerId: ids[1], folderId: folderId,
                       dateMs: dateMs(year: 2026, offsetDays: 1), markerIndex: 31)

        let results = try await index.keywordSearch(
            query: sharedToken, limit: 50, folderIds: [folderId])

        #expect(results.count == 2)
        guard results.count == 2 else { return }
        #expect(results[0].snippet.contains(marker(31)))
        #expect(results[1].snippet.contains(marker(30)))
    }
}
