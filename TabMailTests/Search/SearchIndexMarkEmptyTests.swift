/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

/// Tests verifying that SearchIndex only handles FTS content — no flag management.
/// All flags (bodyComplete, bodyEmptyConfirmed) are in GRDB only.
@Suite("SearchIndex body writes (no flags)", .serialized)
struct SearchIndexBodyWriteTests {

    private var index: SearchIndex { SearchIndex.shared }

    @Test("updateBody writes body text to FTS")
    func updateBodyWritesToFTS() async throws {
        let hid = "test_bodywrite:INBOX:1"
        let record = FTSHeaderRecord(
            headerId: hid, messageId: "m1",
            subject: "Body write test",
            from: "a@a.com", to: "b@b.com",
            dateMs: Int64(Date().timeIntervalSince1970 * 1000)
        )
        try await index.removeMessages(headerIds: [hid])
        _ = try await index.indexHeaders([record])

        try await index.updateBody(headerId: hid, body: "Uniquebodywritetest content here")

        let results = try await index.keywordSearch(query: "uniquebodywritetest")
        #expect(results.contains { $0.headerId == hid })

        try await index.removeMessages(headerIds: [hid])
    }

    @Test("updateBody silently skips whitespace-only body")
    func updateBodySkipsWhitespace() async throws {
        let hid = "test_bodywrite_ws:INBOX:1"
        let record = FTSHeaderRecord(
            headerId: hid, messageId: "m1",
            subject: "Whitespace body test",
            from: "a@a.com", to: "b@b.com",
            dateMs: Int64(Date().timeIntervalSince1970 * 1000)
        )
        try await index.removeMessages(headerIds: [hid])
        _ = try await index.indexHeaders([record])

        // Write whitespace — should be silently skipped
        try await index.updateBody(headerId: hid, body: "   \n\t  ")

        // Body should not be searchable
        let results = try await index.keywordSearch(query: "\"   \"")
        #expect(!results.contains { $0.headerId == hid })

        try await index.removeMessages(headerIds: [hid])
    }

    @Test("updateBodies filters out whitespace entries, writes real ones")
    func updateBodiesMixed() async throws {
        let hids = ["test_bulkwrite:INBOX:1", "test_bulkwrite:INBOX:2"]
        let records = hids.enumerated().map { i, hid in
            FTSHeaderRecord(
                headerId: hid, messageId: "m\(i)",
                subject: "Bulk \(i)",
                from: "a@a.com", to: "b@b.com",
                dateMs: Int64(Date().timeIntervalSince1970 * 1000)
            )
        }
        try await index.removeMessages(headerIds: hids)
        _ = try await index.indexHeaders(records)

        try await index.updateBodies([
            (headerId: hids[0], body: "Uniquebulkwritereal content"),
            (headerId: hids[1], body: "   "),  // whitespace — skipped
        ])

        let r1 = try await index.keywordSearch(query: "uniquebulkwritereal")
        #expect(r1.contains { $0.headerId == hids[0] })

        try await index.removeMessages(headerIds: hids)
    }

    @Test("clearBodies removes body text from FTS")
    func clearBodiesRemovesText() async throws {
        let hid = "test_clearbody:INBOX:1"
        let record = FTSHeaderRecord(
            headerId: hid, messageId: "m1",
            subject: "Clear test",
            from: "a@a.com", to: "b@b.com",
            dateMs: Int64(Date().timeIntervalSince1970 * 1000)
        )
        try await index.removeMessages(headerIds: [hid])
        _ = try await index.indexHeaders([record])

        try await index.updateBody(headerId: hid, body: "Uniqueclearbodytest text")
        let before = try await index.keywordSearch(query: "uniqueclearbodytest")
        #expect(before.contains { $0.headerId == hid })

        try await index.clearBodies(headerIds: [hid])
        let after = try await index.keywordSearch(query: "uniqueclearbodytest")
        #expect(!after.contains { $0.headerId == hid })

        try await index.removeMessages(headerIds: [hid])
    }
}
