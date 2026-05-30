/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

@Suite("SearchIndex Folder Scope", .serialized)
struct SearchIndexFolderScopeTests {

    private var index: SearchIndex { SearchIndex.shared }

    // Use unique prefixes to avoid collisions with other tests
    private let prefix = "test_fscope"

    private func cleanup(_ headerIds: [String]) async {
        try? await index.removeMessages(headerIds: headerIds)
    }

    // MARK: - FTSHeaderRecord folderId

    @Test("indexHeaders writes folderId to message_meta")
    func indexHeadersWritesFolderId() async throws {
        let hid = "\(prefix)_write:INBOX:1"
        await cleanup([hid])

        let record = FTSHeaderRecord(
            headerId: hid, messageId: "m1",
            subject: "Folderscopewritetest unique phrase",
            from: "a@a.com", to: "b@b.com",
            dateMs: Int64(Date().timeIntervalSince1970 * 1000),
            folderId: "\(prefix)_write:INBOX"
        )
        let inserted = try await index.indexHeaders([record])
        #expect(inserted == 1)

        // Verify folderId was written by searching with folder filter
        let scoped = try await index.keywordSearch(
            query: "folderscopewritetest", folderIds: ["\(prefix)_write:INBOX"])
        #expect(scoped.contains { $0.headerId == hid })

        await cleanup([hid])
    }

    // MARK: - keywordSearch with folderIds

    @Test("keywordSearch with folderIds filters to matching folder")
    func keywordSearchFolderFilter() async throws {
        let hidInbox = "\(prefix)_filter:INBOX:1"
        let hidArchive = "\(prefix)_filter:Archive:2"
        await cleanup([hidInbox, hidArchive])

        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let records = [
            FTSHeaderRecord(headerId: hidInbox, messageId: "m1",
                subject: "Uniquefolderscopefilter inbox message",
                from: "a@a.com", to: "b@b.com", dateMs: now,
                folderId: "\(prefix)_filter:INBOX"),
            FTSHeaderRecord(headerId: hidArchive, messageId: "m2",
                subject: "Uniquefolderscopefilter archive message",
                from: "a@a.com", to: "b@b.com", dateMs: now,
                folderId: "\(prefix)_filter:Archive"),
        ]
        let inserted = try await index.indexHeaders(records)
        #expect(inserted == 2)

        // Scoped to INBOX — should find only inbox message
        let inboxResults = try await index.keywordSearch(
            query: "uniquefolderscopefilter", folderIds: ["\(prefix)_filter:INBOX"])
        #expect(inboxResults.count == 1)
        guard inboxResults.count == 1 else { await cleanup([hidInbox, hidArchive]); return }
        #expect(inboxResults[0].headerId == hidInbox)

        // Scoped to Archive — should find only archive message
        let archiveResults = try await index.keywordSearch(
            query: "uniquefolderscopefilter", folderIds: ["\(prefix)_filter:Archive"])
        #expect(archiveResults.count == 1)
        guard archiveResults.count == 1 else { await cleanup([hidInbox, hidArchive]); return }
        #expect(archiveResults[0].headerId == hidArchive)

        await cleanup([hidInbox, hidArchive])
    }

    @Test("keywordSearch with nil folderIds returns all results")
    func keywordSearchNilFolderIds() async throws {
        let hidA = "\(prefix)_nil:FolderA:1"
        let hidB = "\(prefix)_nil:FolderB:2"
        await cleanup([hidA, hidB])

        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let records = [
            FTSHeaderRecord(headerId: hidA, messageId: "m1",
                subject: "Uniquenilfolder testword",
                from: "a@a.com", to: "b@b.com", dateMs: now,
                folderId: "\(prefix)_nil:FolderA"),
            FTSHeaderRecord(headerId: hidB, messageId: "m2",
                subject: "Uniquenilfolder testword",
                from: "a@a.com", to: "b@b.com", dateMs: now,
                folderId: "\(prefix)_nil:FolderB"),
        ]
        try await index.indexHeaders(records)

        let allResults = try await index.keywordSearch(
            query: "uniquenilfolder", folderIds: nil)
        let matchingIds = Set(allResults.map(\.headerId))
        #expect(matchingIds.contains(hidA))
        #expect(matchingIds.contains(hidB))

        await cleanup([hidA, hidB])
    }

    @Test("keywordSearch with empty folderIds array returns zero results")
    func keywordSearchEmptyFolderIds() async throws {
        let hid = "\(prefix)_empty:INBOX:1"
        await cleanup([hid])

        let record = FTSHeaderRecord(
            headerId: hid, messageId: "m1",
            subject: "Uniqueemptyfolder testphrase",
            from: "a@a.com", to: "b@b.com",
            dateMs: Int64(Date().timeIntervalSince1970 * 1000),
            folderId: "\(prefix)_empty:INBOX"
        )
        try await index.indexHeaders([record])

        // Empty array = no folders match = zero results
        let results = try await index.keywordSearch(
            query: "uniqueemptyfolder", folderIds: [])
        #expect(results.isEmpty)

        await cleanup([hid])
    }

    @Test("keywordSearch with multiple folderIds (unified view)")
    func keywordSearchMultipleFolderIds() async throws {
        let hid1 = "\(prefix)_multi:Inbox1:1"
        let hid2 = "\(prefix)_multi:Inbox2:2"
        let hid3 = "\(prefix)_multi:Sent:3"
        await cleanup([hid1, hid2, hid3])

        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let records = [
            FTSHeaderRecord(headerId: hid1, messageId: "m1",
                subject: "Uniquemultifolder meeting notes",
                from: "a@a.com", to: "b@b.com", dateMs: now,
                folderId: "\(prefix)_multi:Inbox1"),
            FTSHeaderRecord(headerId: hid2, messageId: "m2",
                subject: "Uniquemultifolder meeting notes",
                from: "c@c.com", to: "d@d.com", dateMs: now,
                folderId: "\(prefix)_multi:Inbox2"),
            FTSHeaderRecord(headerId: hid3, messageId: "m3",
                subject: "Uniquemultifolder meeting notes",
                from: "e@e.com", to: "f@f.com", dateMs: now,
                folderId: "\(prefix)_multi:Sent"),
        ]
        try await index.indexHeaders(records)

        // Unified inbox = both inbox folders, exclude Sent
        let results = try await index.keywordSearch(
            query: "uniquemultifolder",
            folderIds: ["\(prefix)_multi:Inbox1", "\(prefix)_multi:Inbox2"])
        #expect(results.count == 2)
        let ids = Set(results.map(\.headerId))
        #expect(ids.contains(hid1))
        #expect(ids.contains(hid2))
        #expect(!ids.contains(hid3))

        await cleanup([hid1, hid2, hid3])
    }

    // MARK: - updateFolderIds

    @Test("updateFolderIds changes folderId in place")
    func updateFolderIdsInPlace() async throws {
        let hid = "\(prefix)_update:INBOX:1"
        await cleanup([hid])

        let record = FTSHeaderRecord(
            headerId: hid, messageId: "m1",
            subject: "Uniqueupdatefolder testmsg",
            from: "a@a.com", to: "b@b.com",
            dateMs: Int64(Date().timeIntervalSince1970 * 1000),
            folderId: "\(prefix)_update:INBOX"
        )
        try await index.indexHeaders([record])

        // Verify in INBOX scope
        var inboxResults = try await index.keywordSearch(
            query: "uniqueupdatefolder", folderIds: ["\(prefix)_update:INBOX"])
        #expect(inboxResults.count == 1)

        // Update to Archive
        try await index.updateFolderIds(headerIds: [hid], newFolderId: "\(prefix)_update:Archive")

        // No longer in INBOX scope
        inboxResults = try await index.keywordSearch(
            query: "uniqueupdatefolder", folderIds: ["\(prefix)_update:INBOX"])
        #expect(inboxResults.isEmpty)

        // Now in Archive scope
        let archiveResults = try await index.keywordSearch(
            query: "uniqueupdatefolder", folderIds: ["\(prefix)_update:Archive"])
        #expect(archiveResults.count == 1)

        await cleanup([hid])
    }

    @Test("updateFolderIds with unknown headerId is a no-op")
    func updateFolderIdsUnknownId() async throws {
        // Should not crash
        try await index.updateFolderIds(
            headerIds: ["nonexistent:folder:id"], newFolderId: "acct:Archive")
    }

    // MARK: - headerIdsWithEmptyFolderId

    @Test("headerIdsWithEmptyFolderId returns only empty entries")
    func headerIdsWithEmptyFolderId() async throws {
        let hidEmpty = "\(prefix)_backfill:INBOX:1"
        let hidFilled = "\(prefix)_backfill:INBOX:2"
        await cleanup([hidEmpty, hidFilled])

        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let records = [
            FTSHeaderRecord(headerId: hidEmpty, messageId: "m1",
                subject: "Backfill empty folderId",
                from: "a@a.com", to: "b@b.com", dateMs: now,
                folderId: ""),  // empty — needs backfill
            FTSHeaderRecord(headerId: hidFilled, messageId: "m2",
                subject: "Backfill filled folderId",
                from: "a@a.com", to: "b@b.com", dateMs: now,
                folderId: "\(prefix)_backfill:INBOX"),  // already set
        ]
        try await index.indexHeaders(records)

        let emptyIds = try await index.headerIdsWithEmptyFolderId(limit: 100)
        #expect(emptyIds.contains(hidEmpty))
        #expect(!emptyIds.contains(hidFilled))

        await cleanup([hidEmpty, hidFilled])
    }

    // MARK: - Default folderId backwards compat

    @Test("FTSHeaderRecord default folderId is empty string")
    func defaultFolderIdEmpty() {
        let record = FTSHeaderRecord(
            headerId: "test:INBOX:1", messageId: "m1",
            subject: "Test", from: "a@a.com", to: "b@b.com",
            dateMs: 1_700_000_000_000
        )
        #expect(record.folderId == "")
    }
}
