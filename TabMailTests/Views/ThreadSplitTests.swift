/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

@Suite("Thread Split — earlierMessages / laterMessages")
struct ThreadSplitTests {

    /// Helper to create a MessageHeader with a specific date and ID for thread split testing.
    private func makeHeader(
        db: DatabaseQueue,
        messageId: String,
        date: Date,
        accountId: String = "acc1",
        folderId: String = "acc1:INBOX",
        folderPath: String = "INBOX"
    ) throws -> MessageHeader {
        try TestDatabase.insertMessageHeader(
            db,
            messageId: messageId,
            date: date,
            folderId: folderId,
            accountId: accountId,
            folderPath: folderPath
        )
    }

    /// Replicate the split algorithm from MessageDetailViewModel.recomputeThreadSplit
    private func splitThread(
        threadMessages: [MessageHeader],
        focusDate: Date,
        focusId: String
    ) -> (earlier: [MessageHeader], later: [MessageHeader]) {
        let earlier = threadMessages
            .filter { $0.date < focusDate || ($0.date == focusDate && $0.id < focusId) }
            .sorted { ($0.date, $0.id) < ($1.date, $1.id) }
        let later = threadMessages
            .filter { $0.date > focusDate || ($0.date == focusDate && $0.id > focusId) }
            .sorted { ($0.date, $0.id) < ($1.date, $1.id) }
        return (earlier, later)
    }

    @Test("Thread messages split correctly into earlier and later")
    func basicSplit() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)

        let now = Date()
        let h1 = try makeHeader(db: db, messageId: "1", date: now.addingTimeInterval(-3600))
        let h2 = try makeHeader(db: db, messageId: "2", date: now.addingTimeInterval(-1800))
        let focused = try makeHeader(db: db, messageId: "3", date: now)
        let h4 = try makeHeader(db: db, messageId: "4", date: now.addingTimeInterval(1800))
        let h5 = try makeHeader(db: db, messageId: "5", date: now.addingTimeInterval(3600))

        let (earlier, later) = splitThread(
            threadMessages: [h1, h2, h4, h5],
            focusDate: focused.date,
            focusId: focused.id
        )

        #expect(earlier.count == 2)
        #expect(later.count == 2)
        guard earlier.count == 2 else { return }
        guard later.count == 2 else { return }
        #expect(earlier[0].id == h1.id)
        #expect(earlier[1].id == h2.id)
        #expect(later[0].id == h4.id)
        #expect(later[1].id == h5.id)
    }

    @Test("All messages earlier when focused is newest")
    func allEarlier() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)

        let now = Date()
        let h1 = try makeHeader(db: db, messageId: "1", date: now.addingTimeInterval(-3600))
        let h2 = try makeHeader(db: db, messageId: "2", date: now.addingTimeInterval(-1800))
        let focused = try makeHeader(db: db, messageId: "3", date: now)

        let (earlier, later) = splitThread(
            threadMessages: [h1, h2],
            focusDate: focused.date,
            focusId: focused.id
        )

        #expect(earlier.count == 2)
        #expect(later.isEmpty)
    }

    @Test("All messages later when focused is oldest")
    func allLater() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)

        let now = Date()
        let focused = try makeHeader(db: db, messageId: "1", date: now)
        let h2 = try makeHeader(db: db, messageId: "2", date: now.addingTimeInterval(1800))
        let h3 = try makeHeader(db: db, messageId: "3", date: now.addingTimeInterval(3600))

        let (earlier, later) = splitThread(
            threadMessages: [h2, h3],
            focusDate: focused.date,
            focusId: focused.id
        )

        #expect(earlier.isEmpty)
        #expect(later.count == 2)
    }

    @Test("Same-second timestamps use ID as tiebreaker")
    func sameTimestampTiebreaker() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)

        let now = Date()
        let h1 = try makeHeader(db: db, messageId: "1", date: now)
        let focused = try makeHeader(db: db, messageId: "3", date: now)
        let h5 = try makeHeader(db: db, messageId: "5", date: now)

        let (earlier, later) = splitThread(
            threadMessages: [h1, h5],
            focusDate: focused.date,
            focusId: focused.id
        )

        // h1.id < focused.id ("acc1:INBOX:1" < "acc1:INBOX:3") → earlier
        // h5.id > focused.id ("acc1:INBOX:5" > "acc1:INBOX:3") → later
        #expect(earlier.count == 1)
        #expect(later.count == 1)
        guard earlier.count == 1 else { return }
        guard later.count == 1 else { return }
        #expect(earlier[0].id == h1.id)
        #expect(later[0].id == h5.id)
    }

    @Test("Empty thread messages produces empty splits")
    func emptyThread() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)

        let now = Date()
        let focused = try makeHeader(db: db, messageId: "1", date: now)

        let (earlier, later) = splitThread(
            threadMessages: [],
            focusDate: focused.date,
            focusId: focused.id
        )

        #expect(earlier.isEmpty)
        #expect(later.isEmpty)
    }

    @Test("Earlier messages sorted ascending (oldest first) regardless of input order")
    func earlierSortedAscending() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)

        let now = Date()
        // Insert in reverse order to verify sorting
        let h3 = try makeHeader(db: db, messageId: "3", date: now.addingTimeInterval(-600))
        let h1 = try makeHeader(db: db, messageId: "1", date: now.addingTimeInterval(-3600))
        let h2 = try makeHeader(db: db, messageId: "2", date: now.addingTimeInterval(-1800))
        let focused = try makeHeader(db: db, messageId: "4", date: now)

        // Feed in non-sorted order
        let (earlier, _) = splitThread(
            threadMessages: [h3, h1, h2],
            focusDate: focused.date,
            focusId: focused.id
        )

        #expect(earlier.count == 3)
        guard earlier.count == 3 else { return }
        // Should be sorted oldest first
        #expect(earlier[0].id == h1.id) // -3600
        #expect(earlier[1].id == h2.id) // -1800
        #expect(earlier[2].id == h3.id) // -600
    }

    @Test("Later messages sorted ascending (oldest first)")
    func laterSortedAscending() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)

        let now = Date()
        let focused = try makeHeader(db: db, messageId: "1", date: now)
        // Insert in reverse order
        let h4 = try makeHeader(db: db, messageId: "4", date: now.addingTimeInterval(3600))
        let h2 = try makeHeader(db: db, messageId: "2", date: now.addingTimeInterval(600))
        let h3 = try makeHeader(db: db, messageId: "3", date: now.addingTimeInterval(1800))

        let (_, later) = splitThread(
            threadMessages: [h4, h2, h3],
            focusDate: focused.date,
            focusId: focused.id
        )

        #expect(later.count == 3)
        guard later.count == 3 else { return }
        // Should be sorted oldest first
        #expect(later[0].id == h2.id) // +600
        #expect(later[1].id == h3.id) // +1800
        #expect(later[2].id == h4.id) // +3600
    }

    @Test("Focused message excluded from both splits")
    func focusedExcluded() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)

        let now = Date()
        let h1 = try makeHeader(db: db, messageId: "1", date: now.addingTimeInterval(-3600))
        let focused = try makeHeader(db: db, messageId: "2", date: now)
        let h3 = try makeHeader(db: db, messageId: "3", date: now.addingTimeInterval(3600))

        // Even if focused message is in threadMessages, it should not appear in either split
        // (because its date == focusDate and its id == focusId)
        let (earlier, later) = splitThread(
            threadMessages: [h1, focused, h3],
            focusDate: focused.date,
            focusId: focused.id
        )

        #expect(earlier.count == 1)
        #expect(later.count == 1)
        guard earlier.count == 1 else { return }
        guard later.count == 1 else { return }
        #expect(earlier[0].id == h1.id)
        #expect(later[0].id == h3.id)
    }
}
