/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Testing
@testable import TabMail

/// Folder counters (count, UIDNEXT, HIGHESTMODSEQ) have one writer, the folder's
/// own window listing (ADR-IOS-111, amendment of 2026-11-17). STATUS only decides
/// whether a folder is listed.
@Suite("Folder counters: one writer, the listing", .serialized, .processGlobalState)
struct ListingCountersTests {
    typealias E = IMAPChangeEngineTests
    static let archivePath = "Archive"

    /// CONDSTORE and ENABLE, no QRESYNC and no UIDPLUS: no change reader, so the
    /// full sync's listing is the folder's only reader.
    static let condstoreNoReader = FakeIMAPServer.defaultCapabilities.filter { $0 != "UIDPLUS" } + ["ENABLE", "CONDSTORE"]
    static let condstoreNoEnableNoReader = FakeIMAPServer.defaultCapabilities.filter { $0 != "UIDPLUS" } + ["CONDSTORE"]

    /// A second untracked folder, listed after INBOX in the full sync.
    static func addArchive(_ w: E.World, serverUIDs: [Int], localUIDs: [Int]) throws {
        w.server.setMessages(serverUIDs.map(IMAPChangeReaderTests.message), in: archivePath)
        w.server.setUidValidity(E.epoch, for: archivePath)
        try FolderEpochTestFixture.insertFolder(
            accountId: w.account.id, path: archivePath, role: .archive, pool: w.pool,
            totalCount: localUIDs.count, lastKnownUidNext: (localUIDs.max() ?? 0) + 1, lastKnownUidValidity: E.epoch)
        try FolderEpochTestFixture.insertHeaders(accountId: w.account.id, path: archivePath, uids: localUIDs, pool: w.pool)
    }

    static func archive(_ w: E.World) throws -> (uids: Set<String>, folder: Folder) {
        let folderId = "\(w.account.id):\(archivePath)"
        return try w.pool.read { db in
            (Set(try String.fetchAll(db, sql: "SELECT messageId FROM messageHeader WHERE folderId = ?", arguments: [folderId])),
             try #require(try Folder.fetchOne(db, key: folderId)))
        }
    }

    static func archiveId(_ w: E.World) -> String { "\(w.account.id):\(Self.archivePath)" }

    @Test("An expunge that leaves HIGHESTMODSEQ unchanged on a CONDSTORE-only server: the next full sync lists the untracked folder and the row is gone in that pass")
    func expungeWithoutModSeqMoveIsListed() async throws {
        try await E.withWorld("lc-skip", capabilities: Self.condstoreNoReader, serverUIDs: [1], localUIDs: [1]) { w in
            try Self.addArchive(w, serverUIDs: [1, 2, 3], localUIDs: [1, 2, 3])
            w.server.setExpungeKeepsHighestModSeq(true, for: Self.archivePath)
            _ = try await w.engine.fullSync(account: w.account, provider: w.provider)
            let listed = try Self.archive(w).folder
            #expect(listed.lastKnownHighestModSeq != nil, "precondition: the listing stored the folder's MODSEQ")
            #expect(listed.totalCount == 3)

            let modSeqBefore = w.server.qresyncHighestModSeq(for: Self.archivePath)
            w.server.setMessages([1, 3].map(IMAPChangeReaderTests.message), in: Self.archivePath)
            #expect(w.server.qresyncHighestModSeq(for: Self.archivePath) == modSeqBefore,
                    "precondition: the expunge left HIGHESTMODSEQ where it was")

            let next = try await w.engine.fullSync(account: w.account, provider: w.provider)
            #expect(next.listedFolderIds.contains(Self.archiveId(w)), "the changed STATUS count lists the folder")
            let after = try Self.archive(w)
            #expect(after.uids == ["1", "3"], "the row deleted elsewhere is gone in the same pass")
            #expect(after.folder.totalCount == 2)
        }
    }

    @Test("A listing that proves no count (its SELECT leaves EXISTS out) writes no counter, whatever STATUS said, and the next pass lists the folder again")
    func listingWithoutACountWritesNothing() async throws {
        try await E.withWorld("lc-nocount", capabilities: Self.condstoreNoReader, serverUIDs: [1], localUIDs: [1]) { w in
            // The stored row says 2 messages, UIDNEXT 3; the server holds 3.
            try Self.addArchive(w, serverUIDs: [1, 2, 3], localUIDs: [1, 2])
            w.server.suppressSelectExists(true, for: Self.archivePath)
            let first = try await w.engine.fullSync(account: w.account, provider: w.provider)
            let folder = try Self.archive(w).folder
            #expect(folder.totalCount == 2, "STATUS's 3 is a trigger, never written")
            #expect(folder.lastKnownUidNext == 3, "STATUS's UIDNEXT is a trigger, never written")
            #expect(folder.lastKnownHighestModSeq == nil, "no MODSEQ without a proven listing")
            _ = first

            w.server.suppressSelectExists(false, for: Self.archivePath)
            let next = try await w.engine.fullSync(account: w.account, provider: w.provider)
            #expect(next.listedFolderIds.contains(Self.archiveId(w)), "nothing stored to skip on: the folder is listed")
            let after = try Self.archive(w).folder
            #expect(after.totalCount == 3)
            #expect(after.lastKnownUidNext == 4)
            #expect(after.lastKnownHighestModSeq == w.server.qresyncHighestModSeq(for: Self.archivePath))
        }
    }

    @Test("A positive EXISTS answered by a short or empty header FETCH proves nothing: the folder is not listed this pass, no counter is written, no row is removed, and the next pass lists it",
          arguments: [Set([1, 2, 3]), Set([2])])
    func shortFetchProvesNoListing(_ suppressed: Set<Int>) async throws {
        try await E.withWorld("lc-short", capabilities: Self.condstoreNoReader, serverUIDs: [1], localUIDs: [1]) { w in
            try Self.addArchive(w, serverUIDs: [1, 2, 3], localUIDs: [1, 2])
            w.server.suppressFetchRecord(in: Self.archivePath, uids: suppressed)
            let first = try await w.engine.fullSync(account: w.account, provider: w.provider)
            #expect(!first.listedFolderIds.contains(Self.archiveId(w)), "a listing that missed records is not the folder's listing")
            let held = try Self.archive(w)
            #expect(held.folder.totalCount == 2, "no counter from a listing that proved nothing")
            #expect(held.folder.lastKnownUidNext == 3)
            #expect(held.folder.lastKnownHighestModSeq == nil)
            #expect(held.uids.contains("1") && held.uids.contains("2"), "nothing removed")

            w.server.suppressFetchRecord(in: Self.archivePath, uids: [])
            let next = try await w.engine.fullSync(account: w.account, provider: w.provider)
            #expect(next.listedFolderIds.contains(Self.archiveId(w)))
            let after = try Self.archive(w)
            #expect(after.uids == ["1", "2", "3"])
            #expect(after.folder.totalCount == 3)
        }
    }

    @Test("The listing's MODSEQ: with ENABLE, an acknowledged ENABLE CONDSTORE; without ENABLE, SELECT (CONDSTORE); either way the stored MODSEQ is the server's",
          arguments: ["enable", "selectParameter"])
    func listingStoresTheServersModSeq(_ mode: String) async throws {
        let caps = mode == "enable" ? Self.condstoreNoReader : Self.condstoreNoEnableNoReader
        try await E.withWorld("lc-modseq-\(mode)", capabilities: caps, serverUIDs: [1], localUIDs: [1]) { w in
            try Self.addArchive(w, serverUIDs: [1, 2], localUIDs: [1, 2])
            _ = try await w.engine.fullSync(account: w.account, provider: w.provider)
            let folder = try Self.archive(w).folder
            #expect(folder.lastKnownHighestModSeq == w.server.qresyncHighestModSeq(for: Self.archivePath))
            #expect(w.server.enableInSelectedStateCount == 0, "no ENABLE after a SELECT (RFC 5161)")
            if mode == "enable" {
                #expect(w.server.enableCondStoreCountByConnection.values.allSatisfy { $0 == 1 }, "ENABLE CONDSTORE once per session")
                // On every connection that sent it, ENABLE CONDSTORE came before the first SELECT.
                for (fd, count) in w.server.enableCondStoreCountByConnection where count > 0 {
                    let log = w.server.commandLogByConnection[fd] ?? []
                    let enable = log.firstIndex { $0.uppercased().hasPrefix("ENABLE") }
                    let select = log.firstIndex { $0.uppercased().hasPrefix("SELECT") }
                    #expect(enable != nil && (select == nil || enable! < select!), "ENABLE before the session's first SELECT: \(log)")
                }
                // A second full sync reuses the sessions: no second ENABLE on any of them.
                _ = try await w.engine.fullSync(account: w.account, provider: w.provider)
                #expect(w.server.enableCondStoreCountByConnection.values.allSatisfy { $0 == 1 }, "the session's decision is kept, never asked again")
            } else {
                #expect(w.server.condStoreSelectCount > 0, "the listing's SELECT carries (CONDSTORE)")
                #expect(w.server.enableCondStoreCountByConnection.isEmpty, "no ENABLE on a server without it")
            }
        }
    }

    @Test("A listing that proves no MODSEQ (ENABLE CONDSTORE not acknowledged, or a NOMODSEQ folder) clears the stored one and still lists",
          arguments: ["notAcknowledged", "noModSeq"])
    func listingWithoutModSeqClearsIt(_ cause: String) async throws {
        try await E.withWorld("lc-clear-\(cause)", capabilities: Self.condstoreNoReader, serverUIDs: [1], localUIDs: [1]) { w in
            try Self.addArchive(w, serverUIDs: [1, 2], localUIDs: [1])
            let archiveId = Self.archiveId(w)
            try await w.pool.write { db in
                try db.execute(sql: "UPDATE folder SET lastKnownHighestModSeq = 999999 WHERE id = ?", arguments: [archiveId])
            }
            if cause == "notAcknowledged" { w.server.setIgnoresEnableCondStore(true) } else { w.server.setNoModSeq(true, for: Self.archivePath) }
            let listing = try await w.engine.fullSync(account: w.account, provider: w.provider)
            #expect(listing.listedFolderIds.contains(archiveId))
            let after = try Self.archive(w)
            #expect(after.uids == ["1", "2"], "the listing ran")
            #expect(after.folder.lastKnownHighestModSeq == nil, "no proven MODSEQ: the stored one is cleared")
            #expect(after.folder.totalCount == 2)
        }
    }

    @Test("A pooled folder connection with CONDSTORE on serves the body queue's batch after its listing: the same session's FETCH answers carry MODSEQ and the bodies are read")
    func bodyFetchAfterListingOnTheSameConnection() async throws {
        try await E.withWorld("lc-body", capabilities: Self.condstoreNoReader, serverUIDs: [1, 2], localUIDs: [1]) { w in
            _ = try await w.engine.syncMessages(for: try w.folder(), provider: w.provider, limit: SyncConfig.syncMessageLimit)
            let enabled = w.server.enableCondStoreCountByConnection.filter { $0.value > 0 }.map(\.key)
            #expect(enabled.count == 1, "precondition: the folder's session turned CONDSTORE on")
            let bodies = try await w.provider.fetchMessagesBatch(ids: ["1", "2"], folder: E.path)
            #expect(bodies.count == 2, "both bodies are read from FETCH answers that carry MODSEQ")
            guard let fd = enabled.first else { return }
            let log = w.server.commandLogByConnection[fd] ?? []
            #expect(log.filter { $0.uppercased().hasPrefix("SELECT") }.count >= 2,
                    "the listing and the batch ran on the same CONDSTORE session: \(log)")
            #expect(w.server.enableInSelectedStateCount == 0)
        }
    }

    // MARK: - Backfill progress has its own source

    /// Main's UID-walk formula, over `lastKnownUidNext` (kept here as the oracle).
    static func mainUidWalk(_ folders: [Folder]) -> (total: Int, walked: Int) {
        var total = 0, walked = 0
        for folder in folders {
            let uidNext = folder.lastKnownUidNext ?? 0
            guard uidNext > 0 else { continue }
            total += uidNext - 1
            if folder.backfillComplete { walked += uidNext - 1 }
            else if let cursor = folder.backfillUidCursor { walked += max(0, uidNext - 1 - cursor) }
        }
        return (total, walked)
    }

    @Test("IMAP progress at a given walk position equals main's: the same UIDNEXT from the folder list gives the same total and walked count")
    func uidWalkProgressEqualsMains() {
        func folder(_ path: String, uidNext: Int?, cursor: Int?, complete: Bool) -> Folder {
            var f = Folder(name: path, path: path, role: .custom, accountId: "a")
            f.lastKnownUidNext = uidNext
            f.backfillUidCursor = cursor
            f.backfillComplete = complete
            return f
        }
        let folders = [
            folder("A", uidNext: 1001, cursor: nil, complete: true),
            folder("B", uidNext: 501, cursor: 200, complete: false),
            folder("C", uidNext: 301, cursor: nil, complete: false),
            folder("D", uidNext: nil, cursor: nil, complete: false),
            folder("E", uidNext: 1, cursor: nil, complete: false),
        ]
        let map = Dictionary(uniqueKeysWithValues: folders.compactMap { f in f.lastKnownUidNext.map { (f.path, $0) } })
        var unstored = folders
        for i in unstored.indices { unstored[i].lastKnownUidNext = nil }
        let now = SyncEngine.uidWalkProgress(folders: unstored, uidNextByPath: map)
        let main = Self.mainUidWalk(folders)
        #expect(now.total == main.total && now.walked == main.walked, "now \(now), main \(main)")
        #expect(main.total == 1000 + 500 + 300)
        #expect(main.walked == 1000 + 300)
    }

    @Test("A folder's walked count is clamped to its own denominator: a crawl that started after UIDNEXT moved past the folder list's never passes 100% or reads done early")
    func uidWalkIsClampedPerFolder() {
        func folder(_ path: String, cursor: Int?, complete: Bool) -> Folder {
            var f = Folder(name: path, path: path, role: .custom, accountId: "a")
            f.backfillUidCursor = cursor
            f.backfillComplete = complete
            return f
        }
        // The folder list saw UIDNEXT 101; the crawl started at 111 and is at 105.
        let moved = SyncEngine.uidWalkProgress(folders: [folder("A", cursor: 105, complete: false)], uidNextByPath: ["A": 101])
        #expect(moved.total == 100 && moved.walked == 0, "a cursor above the folder list's UIDNEXT counts nothing: \(moved)")
        // A cursor below 0 never counts more than the folder.
        let below = SyncEngine.uidWalkProgress(folders: [folder("A", cursor: -5, complete: false)], uidNextByPath: ["A": 101])
        #expect(below.walked == 100 && below.walked <= below.total)
        // Two folders: one moved, one walking normally; the sum never passes the total.
        let mixed = SyncEngine.uidWalkProgress(
            folders: [folder("A", cursor: 150, complete: false), folder("B", cursor: 20, complete: false)],
            uidNextByPath: ["A": 101, "B": 51])
        #expect(mixed.total == 150 && mixed.walked == 30, "\(mixed)")
        #expect(mixed.walked < mixed.total, "an incomplete walk never reads done")
    }

    @Test("IMAP progress before this launch's first folder list publishes nothing (never 0, never the row count), then the folder list's UID scope")
    func imapProgressWaitsForTheFolderList() async throws {
        try await E.withWorld("lc-progress-imap", capabilities: Self.condstoreNoReader, serverUIDs: Array(1...40), localUIDs: [1, 2]) { w in
            let folderId = w.folderId
            try await w.pool.write { db in
                try db.execute(sql: "UPDATE folder SET backfillComplete = 0, backfillUidCursor = 30 WHERE id = ?", arguments: [folderId])
            }
            await AccountManager.shared.clearBackfillProgress(accountId: w.account.id)
            await w.engine.updateBackfillProgressForAccount(w.account)
            #expect(await AccountManager.shared._backfillBacking[w.account.id] == nil, "nothing is published before the folder list")

            _ = try await w.provider.fetchFolders()
            await w.engine.updateBackfillProgressForAccount(w.account)
            let progress = try #require(await AccountManager.shared._backfillBacking[w.account.id])
            #expect(progress.uidTotal == 40, "UIDNEXT 41 from the folder list's STATUS")
            #expect(progress.uidWalked == 10)
            await AccountManager.shared.clearBackfillProgress(accountId: w.account.id)
        }
    }

    // MARK: - The stale sweep stays inside the listing's own window

    @Test("Two overlapping listings, whole folder: a message the later listing stored above the earlier listing's selection survives the earlier listing's write, and a message gone inside its window is removed")
    func overlappingListingKeepsAnArrivalAboveItsSelection() async throws {
        try await E.withWorld("lc-overlap-whole", capabilities: Self.condstoreNoReader, serverUIDs: [1], localUIDs: [1]) { w in
            // The earlier listing's server: UIDs 1 and 3 (2 is gone), UIDNEXT 4.
            // UID 4 arrived after that SELECT and a later listing already stored it.
            try Self.addArchive(w, serverUIDs: [1, 3], localUIDs: [1, 2, 3, 4])
            let folder = try Self.archive(w).folder
            _ = try await w.engine.syncMessages(for: folder, provider: w.provider, limit: SyncConfig.syncMessageLimit)
            let after = try Self.archive(w)
            #expect(after.uids.contains("4"), "a message above the listing's selection is not judged by it")
            #expect(!after.uids.contains("2"), "a message gone inside the window is removed")
            #expect(after.uids.contains("1") && after.uids.contains("3"))
        }
    }

    @Test("Two overlapping listings, windowed: a message above the highest UID the earlier listing fetched survives its write; one gone inside the window is removed and rows below the window are untouched")
    func overlappingWindowedListingKeepsAnArrivalAboveItsWindow() async throws {
        try await E.withWorld("lc-overlap-window", capabilities: Self.condstoreNoReader, serverUIDs: [1], localUIDs: [1]) { w in
            // The earlier listing fetches the newest 3 of 1, 2, 3, 5, 6: [3, 5, 6].
            // 4 is gone inside that window; 7 arrived after it and is stored.
            try Self.addArchive(w, serverUIDs: [1, 2, 3, 5, 6], localUIDs: [1, 2, 3, 4, 5, 6, 7])
            let folder = try Self.archive(w).folder
            _ = try await w.engine.syncMessages(for: folder, provider: w.provider, limit: 3)
            let after = try Self.archive(w)
            #expect(after.uids.contains("7"), "a message above the listing's fetched window is not judged by it")
            #expect(!after.uids.contains("4"), "a message gone inside the window is removed")
            #expect(after.uids.isSuperset(of: ["1", "2", "3", "5", "6"]))
        }
    }
}
