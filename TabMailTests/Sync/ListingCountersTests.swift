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
            _ = await w.engine.listFolder(try w.folder(), provider: w.provider, limit: SyncConfig.syncMessageLimit)
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

    @Test("The header walk reads done only when the folder read succeeded, a real folder is known and every one finished: a failed read, no rows, placeholder rows only, or one unfinished folder all read not done")
    func folderWalkDoneFailsClosed() {
        func folder(_ path: String, complete: Bool) -> Folder {
            var f = Folder(name: path, path: path, role: .custom, accountId: "a")
            f.backfillComplete = complete
            return f
        }
        #expect(!SyncEngine.folderWalkDone(nil), "a failed read is not done")
        #expect(!SyncEngine.folderWalkDone([]), "an account with no folders discovered is not done")
        #expect(!SyncEngine.folderWalkDone([folder("", complete: true)]), "placeholder rows only are not done")
        #expect(!SyncEngine.folderWalkDone([folder("A", complete: true), folder("B", complete: false)]))
        #expect(SyncEngine.folderWalkDone([folder("A", complete: true), folder("", complete: false)]), "control: every real folder done")
    }

    @Test("A folder the folder list discovers gets no counters from STATUS: before a listing proves its window, count, UIDNEXT and MODSEQ are unset")
    func discoveredFolderHasNoCountersBeforeAProvenListing() async throws {
        try await E.withWorld("lc-discover", capabilities: Self.condstoreNoReader, serverUIDs: [1], localUIDs: [1]) { w in
            w.server.setMessages([1, 2, 3].map(IMAPChangeReaderTests.message), in: Self.archivePath)
            w.server.setUidValidity(E.epoch, for: Self.archivePath)
            w.server.suppressSelectExists(true, for: Self.archivePath)
            _ = try await w.engine.fullSync(account: w.account, provider: w.provider)
            let folder = try Self.archive(w).folder
            #expect(folder.totalCount == 0, "STATUS's 3 is a trigger, never written")
            #expect(folder.lastKnownUidNext == nil)
            #expect(folder.lastKnownHighestModSeq == nil)
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
            _ = await w.engine.listFolder(folder, provider: w.provider, limit: SyncConfig.syncMessageLimit)
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
            _ = await w.engine.listFolder(folder, provider: w.provider, limit: 3)
            let after = try Self.archive(w)
            #expect(after.uids.contains("7"), "a message above the listing's fetched window is not judged by it")
            #expect(!after.uids.contains("4"), "a message gone inside the window is removed")
            #expect(after.uids.isSuperset(of: ["1", "2", "3", "5", "6"]))
        }
    }

    @Test("Two real listings interleaved: A selects, its FETCH is held; an expunge and an arrival happen; B lists and commits; A resumes and writes. No live row is lost at any step, and the next pass lists the folder and converges",
          arguments: [SyncConfig.syncMessageLimit, 2])
    func interleavedListingsConverge(_ limitA: Int) async throws {
        try await E.withWorld("lc-interleave-\(limitA)", capabilities: Self.condstoreNoReader, serverUIDs: [1], localUIDs: [1]) { w in
            try Self.addArchive(w, serverUIDs: [1, 2, 3], localUIDs: [1, 2, 3])
            let providerB = IMAPProvider(
                host: "127.0.0.1", port: w.server.port, username: w.server.username, password: w.server.password,
                smtpHost: "127.0.0.1", smtpPort: 587, useTLS: false)
            try await providerB.connect()
            defer { Task { try? await providerB.disconnect() } }

            // A's FETCH is held AFTER the fake has read the mailbox for it: the
            // expunge and the arrival below are invisible to A's answer, so A
            // answers with 2 (gone) and without 4 (B's arrival).
            w.server.holdNextFetchAfterSnapshot(in: Self.archivePath)
            defer { w.server.releaseFetchAfterSnapshot(in: Self.archivePath) }
            let folder = try Self.archive(w).folder
            let listingA = Task { await w.engine.listFolder(folder, provider: w.provider, limit: limitA) }
            // Wait until A's FETCH has read the mailbox and is held at the server.
            let deadline = Date().addingTimeInterval(10)
            while Date() < deadline, !w.server.isHoldingFetchAfterSnapshot(in: Self.archivePath) {
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            #expect(w.server.isHoldingFetchAfterSnapshot(in: Self.archivePath), "precondition: A's listing FETCH read the mailbox and is held")

            w.server.setMessages([1, 3, 4].map(IMAPChangeReaderTests.message), in: Self.archivePath)
            _ = await SyncEngine().listFolder(folder, provider: providerB, limit: SyncConfig.syncMessageLimit)
            #expect(try Self.archive(w).uids == ["1", "3", "4"], "after B: the server's rows exactly")

            w.server.releaseFetchAfterSnapshot(in: Self.archivePath)
            _ = await listingA.value
            let afterA = try Self.archive(w)
            #expect(afterA.uids.isSuperset(of: ["1", "3", "4"]), "A's late write removes no live row, B's arrival 4 included: \(afterA.uids.sorted())")

            let next = try await w.engine.fullSync(account: w.account, provider: w.provider)
            #expect(next.listedFolderIds.contains(Self.archiveId(w)), "A's late counters do not suppress the next listing")
            let converged = try Self.archive(w)
            #expect(converged.uids == ["1", "3", "4"])
            #expect(converged.folder.totalCount == 3 && converged.folder.lastKnownUidNext == 5)
        }
    }

    @Test("A whole-folder listing with no UIDNEXT: bounded by the highest UID it saw (2 removed, 5 above it kept); with no UID seen either it removes nothing",
          arguments: [true, false])
    func noUidNextBoundsTheSweep(_ withMessages: Bool) async throws {
        try await E.withWorld("lc-nouidnext-\(withMessages)", capabilities: Self.condstoreNoReader, serverUIDs: [1], localUIDs: [1]) { w in
            try Self.addArchive(w, serverUIDs: withMessages ? [1, 3] : [], localUIDs: [1, 2, 3, 5])
            w.server.suppressSelectUidNext(for: Self.archivePath)
            let folder = try Self.archive(w).folder
            _ = await w.engine.listFolder(folder, provider: w.provider, limit: SyncConfig.syncMessageLimit)
            let after = try Self.archive(w).uids
            if withMessages {
                #expect(after == ["1", "3", "5"], "the sweep judges only up to UID 3: \(after.sorted())")
            } else {
                #expect(after == ["1", "2", "3", "5"], "no bound at all: nothing is removed")
            }
        }
    }

    // MARK: - Phase 2 runs on the count of this pass's own listing

    /// 52 messages on the server (UIDs 2...53), 53 held: UID 1 is a ghost below
    /// the 50-message window, so only phase 2 can remove it.
    static let belowWindowServer = Array(2...53)
    static let belowWindowHeld = Array(1...53)

    @Test("Full sync: phase 2 takes the count from this pass's listing, not STATUS (which sends no MESSAGES) nor the stored count (which equals the rows held): the ghost below the window is removed")
    func phaseTwoUsesTheListingsCount() async throws {
        try await E.withWorld("lc-p2-full", capabilities: Self.condstoreNoReader, serverUIDs: [1], localUIDs: [1]) { w in
            try Self.addArchive(w, serverUIDs: Self.belowWindowServer, localUIDs: Self.belowWindowHeld)
            w.server.setStatusOmits(["MESSAGES"], for: Self.archivePath)
            let pass = try await w.engine.fullSync(account: w.account, provider: w.provider)
            #expect(pass.listedFolderIds.contains(Self.archiveId(w)), "a STATUS without MESSAGES lists the folder")
            let after = try Self.archive(w)
            #expect(!after.uids.contains("1"), "the walk ran on the listing's 52 and removed the ghost")
            #expect(after.uids == Set(Self.belowWindowServer.map(String.init)))
        }
    }

    @Test("Full sync: a short listing drives no phase 2: the ghost below the window stays and the folder is not searched")
    func shortListingDrivesNoPhaseTwo() async throws {
        try await E.withWorld("lc-p2-short", capabilities: Self.condstoreNoReader, serverUIDs: [1], localUIDs: [1]) { w in
            try Self.addArchive(w, serverUIDs: Self.belowWindowServer, localUIDs: Self.belowWindowHeld)
            w.server.suppressFetchRecord(in: Self.archivePath, uids: [53])
            let start = w.server.recordedCommands().count
            _ = try await w.engine.fullSync(account: w.account, provider: w.provider)
            #expect(try Self.archive(w).uids.contains("1"), "no proof, no walk, no removal")
            let searches = w.server.recordedCommands().dropFirst(start).filter { $0.uppercased().contains("SEARCH") }
            #expect(searches.isEmpty, "no count walk for an unproven listing: \(Array(searches))")
        }
    }

    @Test("Untracked route: a re-listed folder's phase 2 runs on that listing's count, not the stored count equal to the rows held, under the caller's deadline (none, or a distant one), not the reader's earlier cutoff",
          arguments: [nil, 600.0] as [Double?])
    func untrackedPhaseTwoUsesTheListingsCount(_ deadlineIn: Double?) async throws {
        try await E.withWorld("lc-p2-untracked-\(deadlineIn.map { "\(Int($0))" } ?? "none")", capabilities: E.condstoreOnly,
                              serverUIDs: Self.belowWindowServer, localUIDs: Self.belowWindowHeld) { w in
            // Nothing stored to compare UIDNEXT with: the change pass lists.
            let folderId = w.folderId
            try await w.pool.write { db in
                try db.execute(sql: "UPDATE folder SET lastKnownUidNext = NULL WHERE id = ?", arguments: [folderId])
            }
            await TestProviderRegistry.withRegisteredProvider(accountId: w.account.id, provider: w.provider) {
                _ = try? await w.engine.performDeltaSync(
                    account: w.account, provider: w.provider,
                    deadline: deadlineIn.map { Date().addingTimeInterval($0) })
            }
            #expect(try !w.uids().contains("1"), "the walk ran on the listing's 52 and removed the ghost")
            #expect(try w.folder().totalCount == 52)
        }
    }

    static func archiveDue(_ w: E.World) throws -> Bool {
        FolderChangeState(raw: try Self.archive(w).folder.changeState).listingDue
    }

    @Test("Full-sync route, deadline already past: the listing commits, phase 2 does not start (no SEARCH), the folder is left due; the next pass lists it again, walks, removes the ghost and clears the due bit")
    func pastDeadlineLeavesDueAndTheNextPassWalks() async throws {
        try await E.withWorld("lc-p7-past", capabilities: Self.condstoreNoReader, serverUIDs: [1], localUIDs: [1]) { w in
            try Self.addArchive(w, serverUIDs: Self.belowWindowServer, localUIDs: Self.belowWindowHeld)
            let start = w.server.recordedCommands().count
            _ = try await w.engine.fullSync(account: w.account, provider: w.provider,
                                             plan: SyncEngine.FullSyncPlan(deadline: Date().addingTimeInterval(-1)))
            let searches = w.server.recordedCommands().dropFirst(start).filter { $0.uppercased().contains("SEARCH") }
            #expect(searches.isEmpty, "no walk after the deadline: \(Array(searches))")
            #expect(try Self.archive(w).uids.contains("1"))
            #expect(try Self.archiveDue(w), "the owed walk is recorded")

            let next = try await w.engine.fullSync(account: w.account, provider: w.provider)
            #expect(next.listedFolderIds.contains(Self.archiveId(w)), "a due folder is listed even with its counters unchanged")
            #expect(try !Self.archive(w).uids.contains("1"), "the owed walk ran and removed the ghost")
            #expect(try !Self.archiveDue(w), "a finished walk whose counts agree clears the due bit")
        }
    }

    @Test("Full-sync route, deadline passes while the walk's SEARCH answer is held: the late answer is not applied and the folder stays due")
    func lateSearchAnswerIsNotApplied() async throws {
        try await E.withWorld("lc-p7-late", capabilities: Self.condstoreNoReader, serverUIDs: [1], localUIDs: [1]) { w in
            try Self.addArchive(w, serverUIDs: Self.belowWindowServer, localUIDs: Self.belowWindowHeld)
            w.server.holdNextCommand(containing: "SEARCH")
            let deadline = Date().addingTimeInterval(3)
            let pass = Task {
                try await w.engine.fullSync(account: w.account, provider: w.provider,
                                            plan: SyncEngine.FullSyncPlan(deadline: deadline))
            }
            let waitUntil = Date().addingTimeInterval(10)
            while Date() < waitUntil, !w.server.isHoldingCommand(containing: "SEARCH") {
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            let held = w.server.isHoldingCommand(containing: "SEARCH")
            #expect(held, "precondition: the walk's SEARCH is held")
            while Date() <= deadline { try await Task.sleep(nanoseconds: 20_000_000) }
            w.server.releaseHeldCommand(containing: "SEARCH")
            _ = try await pass.value
            #expect(try Self.archive(w).uids.contains("1"), "an answer that arrived after the deadline removes nothing")
            #expect(try Self.archiveDue(w), "the walk did not finish: the folder stays due")
        }
    }

    @Test("Foreground pass, caller's deadline already past: the deadline reaches the full sync through `sync(account:deadline:)`, so phase 2 sends no SEARCH and the folder is left due")
    func foregroundDeadlineReachesTheCountCheck() async throws {
        try await E.withWorld("lc-p7-foreground", capabilities: Self.condstoreNoReader, serverUIDs: [1], localUIDs: [1]) { w in
            try Self.addArchive(w, serverUIDs: Self.belowWindowServer, localUIDs: Self.belowWindowHeld)
            let start = w.server.recordedCommands().count
            _ = try await w.engine.sync(account: try Self.account(w), deadline: Date().addingTimeInterval(-1))
            let searches = w.server.recordedCommands().dropFirst(start).filter { $0.uppercased().contains("SEARCH") }
            #expect(searches.isEmpty, "no walk past the caller's deadline: \(Array(searches))")
            #expect(try Self.archive(w).uids.contains("1"), "nothing removed")
            #expect(try Self.archiveDue(w), "the owed walk is recorded for the next pass")
        }
    }

    // MARK: - The full-sync stamp, by this pass's server answer per folder

    static func fullSyncStamp(_ w: E.World) throws -> Date? {
        let id = w.account.id
        return try w.pool.read { db in try Account.fetchOne(db, key: id)?.lastFullSyncAt }
    }

    static func account(_ w: E.World) throws -> Account {
        let id = w.account.id
        return try #require(try w.pool.read { db in try Account.fetchOne(db, key: id) })
    }

    /// A SELECT of the Archive refused with NO, every time.
    static func refuseArchiveSelect(_ w: E.World) {
        for fragment in ["SELECT \(archivePath)", "SELECT \"\(archivePath)\""] {
            w.server.failEveryCommand(containing: fragment, message: "Mailbox unavailable")
        }
    }

    @Test("The full-sync stamp after a foreground pass, by the Archive's server answer: proven listing stamps; SELECT refused or SELECT without EXISTS (not listable) stamps; a short FETCH or a contradicted EXISTS 0 (unproven) does not",
          arguments: ["proven", "selectRefused", "noExists", "shortFetch", "contradictedZero"])
    func fullSyncStampByListingClass(_ answer: String) async throws {
        try await E.withWorld("lc-stamp-\(answer)", capabilities: Self.condstoreNoReader, serverUIDs: [1], localUIDs: [1]) { w in
            try Self.addArchive(w, serverUIDs: [1, 2, 3], localUIDs: [1, 2])
            switch answer {
            case "selectRefused": Self.refuseArchiveSelect(w)
            case "noExists": w.server.suppressSelectExists(true, for: Self.archivePath)
            case "shortFetch": w.server.suppressFetchRecord(in: Self.archivePath, uids: [2])
            case "contradictedZero": w.server.setSelectExists(0, for: Self.archivePath)
            default: break
            }
            #expect(try Self.fullSyncStamp(w) == nil, "precondition: the full sync is due")
            _ = try await w.engine.sync(account: try Self.account(w))
            let stamped = try Self.fullSyncStamp(w) != nil
            let held = try Self.archive(w)
            switch answer {
            case "proven":
                #expect(stamped, "a proven listing counts toward the stamp")
                #expect(held.uids == ["1", "2", "3"])
            case "selectRefused", "noExists":
                #expect(stamped, "a folder the server made not listable does not withhold the stamp")
                #expect(held.uids == ["1", "2"], "nothing listed, nothing removed")
                #expect(held.folder.totalCount == 2 && held.folder.lastKnownUidNext == 3, "its counters stay unwritten")
            default:
                #expect(!stamped, "a started listing that failed to prove its window withholds the stamp: the full sync stays due")
                #expect(held.uids.isSuperset(of: ["1", "2"]), "nothing removed")
            }
        }
    }

    @Test("EXISTS 0 against held mail, confirmed by a SEARCH answer that lists nothing (tagged OK alone, or ESEARCH with COUNT but no ALL): the folder is unproven, so its rows and the full-sync stamp stay untouched",
          arguments: ["plainNoResult", "esearchCountNoAll"])
    func unlistedConfirmationLeavesRowsAndStamp(_ answer: String) async throws {
        try await E.withWorld("lc-confirm-\(answer)", capabilities: Self.condstoreNoReader, serverUIDs: [1], localUIDs: [1]) { w in
            try Self.addArchive(w, serverUIDs: [1, 2], localUIDs: [1, 2])
            w.server.setSelectExists(0, for: Self.archivePath)
            switch answer {
            case "plainNoResult": w.server.answerNextUIDSearchWithNoResult(in: Self.archivePath)
            default: w.server.answerNextUIDSearch(in: Self.archivePath, esearchData: "COUNT 2")
            }
            let before = try Self.archive(w)
            _ = try await w.engine.sync(account: try Self.account(w))
            #expect(w.server.compactUIDSearchAnswersServed() == 1, "precondition: the confirmation SEARCH got the answer under test")
            let after = try Self.archive(w)
            #expect(after.uids == ["1", "2"], "an answer that lists nothing proves no message absent")
            #expect(after.folder.totalCount == before.folder.totalCount
                    && after.folder.lastKnownUidNext == before.folder.lastKnownUidNext, "its counters stay unwritten")
            #expect(try Self.fullSyncStamp(w) == nil, "an unproven folder withholds the full-sync stamp")
        }
    }

    @Test("A listing whose connection dies is retried once: a retry that proves the whole window stamps the full sync; a short retry withholds it, and the failed attempt wrote no row or counter",
          arguments: [true, false])
    func connectionLossRetryDecidesTheStamp(_ retryProves: Bool) async throws {
        try await E.withWorld("lc-retry-\(retryProves)", capabilities: Self.condstoreNoReader, serverUIDs: [1], localUIDs: [1]) { w in
            try Self.addArchive(w, serverUIDs: [1, 2, 3], localUIDs: [1, 2])
            w.server.killConnectionOnNextCommand(containing: "FETCH")
            if !retryProves { w.server.suppressFetchRecord(in: Self.archivePath, uids: [3]) }
            _ = try await w.engine.sync(account: try Self.account(w))
            let archiveSelects = w.server.recordedCommands().filter {
                ($0.hasPrefix("SELECT") || $0.hasPrefix("EXAMINE")) && $0.contains(Self.archivePath)
            }
            #expect(archiveSelects.count >= 2, "precondition: the Archive's listing lost its connection and was retried")
            let held = try Self.archive(w)
            if retryProves {
                #expect(try Self.fullSyncStamp(w) != nil, "the retry proved the window: the folder counts as proven")
                #expect(held.uids == ["1", "2", "3"])
            } else {
                #expect(try Self.fullSyncStamp(w) == nil, "the retry was short: the folder is unproven and the stamp withheld")
                #expect(held.uids == ["1", "2"], "nothing removed, nothing half-written")
                #expect(held.folder.totalCount == 2 && held.folder.lastKnownUidNext == 3,
                        "neither the failed attempt nor the short retry wrote the counters")
            }
        }
    }

    @Test("A folder whose SELECT is always refused: over three foreground passes the full sync runs once and is not due on every pass")
    func alwaysRefusedFolderDoesNotKeepTheFullSyncDue() async throws {
        try await E.withWorld("lc-stamp-always", capabilities: Self.condstoreNoReader, serverUIDs: [1], localUIDs: [1]) { w in
            try Self.addArchive(w, serverUIDs: [1, 2], localUIDs: [1])
            Self.refuseArchiveSelect(w)
            _ = try await w.engine.sync(account: try Self.account(w))
            let first = try Self.fullSyncStamp(w)
            #expect(first != nil, "the first pass's full sync is stamped")
            for pass in 2...3 {
                // Each pass really runs: no early return through the short
                // repeat-sync guard on `lastSyncedAt`.
                let id = w.account.id
                try await w.pool.write { db in
                    try db.execute(sql: "UPDATE account SET lastSyncedAt = NULL WHERE id = ?", arguments: [id])
                }
                let before = w.server.recordedCommands().count
                _ = try await w.engine.sync(account: try Self.account(w))
                #expect(w.server.recordedCommands().count > before, "pass \(pass) reached the server")
                #expect(try Self.fullSyncStamp(w) == first, "pass \(pass) runs no full sync: the stamp is the first pass's")
            }
        }
    }

    // MARK: - Content-free logs with debug logging off

    @Test("With debug logging off, each unproven-confirmation path (SEARCH refused, SEARCH contradicting EXISTS 0, SEARCH listing nothing) is reached and writes neither the folder name nor the server's words to the app log",
          arguments: ["refused", "contradiction", "unlisted"])
    func unconfirmedListingLogsNoContentWithDebugOff(_ path: String) async throws {
        let previous = DebugModeManager.loggingEnabledOverrideForTesting.withLock { $0 }
        DebugModeManager.loggingEnabledOverrideForTesting.withLock { $0 = false }
        defer { DebugModeManager.loggingEnabledOverrideForTesting.withLock { $0 = previous } }
        let marker = "Qz7ServerWords"
        let error = ProviderListingUnconfirmed(folder: "Qz7Folder", refusal: marker)
        #expect(!"\(error)".contains("Qz7"), "the description is content-free: \(error)")
        #expect(String(reflecting: error).contains("Qz7Folder"), "the detail stays for the debug-gated lines")

        try await E.withWorld("lc-logs-off-\(path)", capabilities: Self.condstoreNoReader, serverUIDs: [1], localUIDs: [1]) { w in
            try Self.addArchive(w, serverUIDs: [1, 2], localUIDs: [1])
            w.server.setSelectExists(0, for: Self.archivePath)
            switch path {
            case "refused": w.server.failEveryCommand(containing: "UID SEARCH", message: marker)
            case "unlisted": w.server.answerNextUIDSearch(in: Self.archivePath, esearchData: "COUNT 2")
            default: break // the SEARCH lists UIDs 1 and 2 against EXISTS 0
            }
            let before = AppLogStore.read()
            let searchesBefore = w.server.recordedCommands().filter { $0.uppercased().contains("SEARCH") }.count
            _ = try await w.engine.sync(account: try Self.account(w))
            let all = AppLogStore.read()
            // A rotated log is shorter than before: read all of it then.
            let written = all.hasPrefix(before) ? String(all.dropFirst(before.count)) : all
            let searches = w.server.recordedCommands().filter { $0.uppercased().contains("SEARCH") }.count - searchesBefore
            #expect(searches >= 1, "precondition: the confirmation SEARCH ran")
            if path == "unlisted" { #expect(w.server.compactUIDSearchAnswersServed() == 1, "precondition: the unlisted answer was served") }
            #expect(try Self.fullSyncStamp(w) == nil, "precondition: the folder came out unproven")
            #expect(!written.contains(marker), "no server words in the app log")
            #expect(!written.contains(Self.archivePath), "no folder name in the app log")
        }
    }

    @Test("The CONDSTORE decision goes with its connection: after eviction, a reconnect to a server that no longer advertises CONDSTORE lists with no (CONDSTORE) and stores no MODSEQ, even if the SELECT reports one")
    func condStoreDecisionDoesNotSurviveReconnect() async throws {
        try await E.withWorld("lc-reconnect", capabilities: Self.condstoreNoReader, serverUIDs: [1, 2], localUIDs: [1]) { w in
            _ = await w.engine.listFolder(try w.folder(), provider: w.provider, limit: SyncConfig.syncMessageLimit)
            #expect(try w.folder().lastKnownHighestModSeq != nil, "precondition: the first session stored the MODSEQ")
            w.server.setCapabilities(FakeIMAPServer.defaultCapabilities.filter { $0 != "UIDPLUS" })
            #expect(await w.provider.evictLRUFolderForTesting(), "precondition: the folder connection was evicted")
            let enableBefore = w.server.enableCondStoreCountByConnection.values.reduce(0, +)
            let condSelectBefore = w.server.condStoreSelectCount
            _ = await w.engine.listFolder(try w.folder(), provider: w.provider, limit: SyncConfig.syncMessageLimit)
            #expect(w.server.enableCondStoreCountByConnection.values.reduce(0, +) == enableBefore, "no ENABLE CONDSTORE on the new session")
            #expect(w.server.condStoreSelectCount == condSelectBefore, "no SELECT (CONDSTORE) on the new session")
            #expect(try w.folder().lastKnownHighestModSeq == nil, "no negotiated CONDSTORE: no MODSEQ stored")
            #expect(try w.uids() == ["1", "2"], "the listing still ran")
        }
    }

    // MARK: - The connection-limit retry leg

    @Test("A folder connection created on the connection-limit retry leg negotiates CONDSTORE too: the listing on it stores the server's MODSEQ")
    func connectionLimitRetryLegNegotiatesCondStore() async throws {
        try await E.withWorld("lc-limit-retry", capabilities: Self.condstoreNoReader, serverUIDs: [1, 2], localUIDs: [1]) { w in
            // INBOX's folder connection is the one the retry evicts.
            _ = await w.engine.listFolder(try w.folder(), provider: w.provider, limit: SyncConfig.syncMessageLimit)
            try Self.addArchive(w, serverUIDs: [1, 2, 3], localUIDs: [1])
            w.server.setMaxLoggedInSessions(50)
            w.server.refuseNextLogins(1)
            let archive = try Self.archive(w).folder
            _ = await w.engine.listFolder(archive, provider: w.provider, limit: SyncConfig.syncMessageLimit)
            #expect(w.server.refusedLoginCount() == 1, "precondition: the first LOGIN was refused with the limit wording, so the retry leg ran")
            let after = try Self.archive(w)
            #expect(after.uids == ["1", "2", "3"])
            #expect(after.folder.lastKnownHighestModSeq == w.server.qresyncHighestModSeq(for: Self.archivePath),
                    "the retry leg's connection carries CONDSTORE")
        }
    }

    @Test("A cold folder connection to a server that refuses the (CONDSTORE) SELECT parameter still opens: the pool's open-the-folder SELECT is plain, and the listing's own SELECT falls back to a plain one and lists the folder")
    func coldConnectionRefusingCondStoreSelectStillLists() async throws {
        try await E.withWorld("lc-cold-condstore-refused", capabilities: Self.condstoreNoEnableNoReader, serverUIDs: [1], localUIDs: [1]) { w in
            try Self.addArchive(w, serverUIDs: [1, 2, 3], localUIDs: [1])
            // The server refuses the first (CONDSTORE) SELECT it sees. With no
            // ENABLE advertised the session decides `selectParameter`; the first
            // SELECT on the cold Archive connection must not be that one.
            w.server.failNextCommand(containing: "(CONDSTORE)")
            let outcome = await w.engine.listFolder(try Self.archive(w).folder, provider: w.provider, limit: SyncConfig.syncMessageLimit)
            if case .proven = outcome {} else { Issue.record("the folder opens and lists despite the refused parameter: \(outcome)") }
            #expect(try Self.archive(w).uids == ["1", "2", "3"])
        }
    }

    @Test("A FETCH answer naming two UIDs for one sequence slot proves nothing: the held mail below the window survives and the folder is not published")
    func conflictingFetchRecordsLeaveHeldMailBelowTheWindow() async throws {
        try await E.withWorld("lc-conflicting-records", capabilities: Self.condstoreNoReader, serverUIDs: [1], localUIDs: [1]) { w in
            let server = Array(1...53)
            try Self.addArchive(w, serverUIDs: server, localUIDs: server)
            let before = try Self.archive(w).folder
            // The window is sequences 4...53 (UIDs 4...53). The server also sends
            // a record at sequence 4 with UID 1, which would lower the sweep floor
            // to UID 1 and judge 2 and 3, held and on the server, as absent.
            w.server.setConflictingFetchRecord(templateUID: 4, sequence: 4, uid: 1, in: Self.archivePath)
            let outcome = await w.engine.listFolder(before, provider: w.provider, limit: SyncConfig.syncMessageLimit)
            if case .proven = outcome { Issue.record("a conflicting record set is never proof") }
            let after = try Self.archive(w)
            #expect(after.uids == Set(server.map(String.init)), "held mail below the window survives")
            #expect(after.folder.totalCount == before.totalCount && after.folder.lastKnownUidNext == before.lastKnownUidNext,
                    "nothing is published from a conflicting answer")
        }
    }

    @Test("A session lost between the listing's SELECT and its proof makes the listing unproven: no new session logs in to answer the proof, and nothing is published")
    func sessionLostBetweenSelectAndProofIsUnproven() async throws {
        try await E.withWorld("lc-proof-session", capabilities: Self.condstoreNoReader, serverUIDs: [1], localUIDs: [1]) { w in
            try Self.addArchive(w, serverUIDs: [1, 2, 3], localUIDs: [1, 2])
            let before = try Self.archive(w)
            // The listing's own SELECT carries (CONDSTORE) on this server; the
            // pool's open-the-folder SELECT is plain. Answer the listing's SELECT,
            // then end its session before the confirming FETCH.
            w.server.closeConnectionAfterAnsweringNextCommand(containing: "(CONDSTORE)")
            let logBefore = w.server.recordedCommands().count
            let outcome = await w.engine.listFolder(before.folder, provider: w.provider, limit: SyncConfig.syncMessageLimit)
            let after = try Self.archive(w)
            let sent = Array(w.server.recordedCommands().dropFirst(logBefore))
            let selectIndex = try #require(sent.firstIndex { $0.uppercased().contains("(CONDSTORE)") }, "precondition: the listing's SELECT was sent: \(sent)")
            let afterSelect = sent[(selectIndex + 1)...]
            if case .unproven = outcome {} else { Issue.record("a proof that lost its session proves nothing: \(outcome)") }
            #expect(!afterSelect.contains { $0.uppercased().hasPrefix("LOGIN") || $0.uppercased().hasPrefix("AUTHENTICATE") },
                    "no new session is opened to answer the proof: \(Array(afterSelect))")
            #expect(after.uids == before.uids, "nothing is listed or removed")
            #expect(after.folder.totalCount == before.folder.totalCount && after.folder.lastKnownUidNext == before.folder.lastKnownUidNext,
                    "nothing is published")
        }
    }

    // MARK: - Races the owner asked to see end to end

    @Test("A CONDSTORE SELECT refused on a live session sends no ENABLE after it (RFC 5161: only before a session selects); after a teardown the next connection starts clean: its own ENABLE before its SELECT, (CONDSTORE) on that SELECT, the server's MODSEQ stored")
    func refusedCondStoreSelectThenTeardownStartsClean() async throws {
        try await E.withWorld("lc-reneg-teardown", capabilities: Self.condstoreNoReader, serverUIDs: [1, 2], localUIDs: [1]) { w in
            _ = await w.engine.listFolder(try w.folder(), provider: w.provider, limit: SyncConfig.syncMessageLimit)
            #expect(try w.folder().lastKnownHighestModSeq != nil, "precondition: the first session stored the MODSEQ")

            // On the live, already-selected session the next (CONDSTORE) SELECT is refused.
            w.server.failNextCommand(containing: "(CONDSTORE)")
            let enableBefore = w.server.enableCondStoreCountByConnection.values.reduce(0, +)
            let refused = await w.engine.listFolder(try w.folder(), provider: w.provider, limit: SyncConfig.syncMessageLimit)
            #expect(w.server.enableCondStoreCountByConnection.values.reduce(0, +) == enableBefore,
                    "no ENABLE on a session that has already selected a mailbox")
            if case .proven = refused {} else { Issue.record("the plain SELECT after the refusal still lists the folder: \(refused)") }
            #expect(try w.folder().lastKnownHighestModSeq == nil, "a listing without CONDSTORE stores no MODSEQ")

            // Teardown: the connection leaves the pool; the next one decides for itself.
            #expect(await w.provider.evictLRUFolderForTesting(), "precondition: the connection was torn down")
            let condSelectBefore = w.server.condStoreSelectCount
            _ = await w.engine.listFolder(try w.folder(), provider: w.provider, limit: SyncConfig.syncMessageLimit)
            #expect(w.server.enableCondStoreCountByConnection.values.reduce(0, +) > enableBefore,
                    "the new connection negotiates its own CONDSTORE before its first SELECT")
            #expect(w.server.condStoreSelectCount > condSelectBefore,
                    "its listing SELECT carries (CONDSTORE): nothing carried over from the torn-down session")
            #expect(try w.folder().lastKnownHighestModSeq == w.server.qresyncHighestModSeq(for: "INBOX"))
            #expect(try w.uids() == ["1", "2"])
        }
    }

    @Test("Two count walks race and the older finishes last: the newer listing's evidence stands, so the next full sync walks the folder and the message the server removed in between is gone")
    func olderCountWalkFinishingLastLeavesTheNewerEvidence() async throws {
        try await E.withWorld("lc-walk-race", capabilities: Self.condstoreNoReader, serverUIDs: [1], localUIDs: [1]) { w in
            try Self.addArchive(w, serverUIDs: Self.belowWindowServer, localUIDs: Self.belowWindowHeld)
            let providerB = IMAPProvider(
                host: "127.0.0.1", port: w.server.port, username: w.server.username, password: w.server.password,
                smtpHost: "127.0.0.1", smtpPort: 587, useTLS: false)
            try await providerB.connect()
            defer { Task { try? await providerB.disconnect() } }

            // The older pass: its walk's SEARCH reads the mailbox, then is held.
            w.server.holdNextSearchAfterSnapshot(in: Self.archivePath)
            defer { w.server.releaseSearchAfterSnapshot(in: Self.archivePath) }
            let older = Task { try await w.engine.fullSync(account: w.account, provider: w.provider) }
            let waitUntil = Date().addingTimeInterval(10)
            while Date() < waitUntil, !w.server.isHoldingSearchAfterSnapshot(in: Self.archivePath) {
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            #expect(w.server.isHoldingSearchAfterSnapshot(in: Self.archivePath), "precondition: the older walk's answer is in flight")

            // The server removes message 2 (below every listing window); a newer
            // pass lists the folder and sees more rows held than the server counts,
            // its own count check out of time.
            let remaining = Array(3...53)
            w.server.setMessages(remaining.map(IMAPChangeReaderTests.message), in: Self.archivePath)
            _ = try await SyncEngine().fullSync(account: w.account, provider: providerB,
                                                plan: SyncEngine.FullSyncPlan(deadline: Date().addingTimeInterval(-1)))

            // The older walk finishes last, on its answer from before the removal.
            w.server.releaseSearchAfterSnapshot(in: Self.archivePath)
            _ = try await older.value
            #expect(try Self.archive(w).uids.contains("2"), "precondition: the older walk could not see the removal")

            // Force the next full sync to be NOT a deep pass, so only the newer
            // evidence can make it list the folder: run the cadence through a deep
            // pass now (which resets it); the next decision is then shallow.
            let everyN = SyncConfig.fullSyncDeepEveryN
            try #require(everyN > 1, "a cadence of 1 makes every pass deep: this race cannot be shown")
            let archiveId = Self.archiveId(w)
            while !SyncEngine.fullSyncIsDeepPass(folderId: archiveId, everyN: everyN) {}

            // What the user sees: the next full sync acts on the newer evidence.
            _ = try await w.engine.fullSync(account: w.account, provider: w.provider)
            #expect(try Self.archive(w).uids == Set(remaining.map(String.init)),
                    "the message the server removed is gone; the older walk did not erase the newer evidence")
        }
    }

    static let projectsPath = "Projects"

    static func listingDue(_ w: E.World, path: String) throws -> Bool {
        let folderId = "\(w.account.id):\(path)"
        return try w.pool.read { db in
            FolderChangeState(raw: try String.fetchOne(db, sql: "SELECT changeState FROM folder WHERE id = ?", arguments: [folderId])).listingDue
        }
    }

    @Test("An on-demand listing that proves nothing while a scheduled pass runs belongs to no pass: the pass's own proven listings stamp the full sync, and the folder opened on demand is made due so the next pass lists it")
    func onDemandFailureDuringAPassNeverWithholdsItsStamp() async throws {
        try await E.withWorld("lc-ondemand-during-pass", capabilities: Self.condstoreNoReader, serverUIDs: [1], localUIDs: [1]) { w in
            try Self.addArchive(w, serverUIDs: [1, 2, 3], localUIDs: [1, 2])
            // A custom folder the pass does not list, opened by the user meanwhile.
            w.server.setMessages([1, 2, 3].map(IMAPChangeReaderTests.message), in: Self.projectsPath)
            w.server.setUidValidity(E.epoch, for: Self.projectsPath)
            try FolderEpochTestFixture.insertFolder(
                accountId: w.account.id, path: Self.projectsPath, role: .custom, pool: w.pool,
                totalCount: 2, lastKnownUidNext: 3, lastKnownUidValidity: E.epoch)
            try FolderEpochTestFixture.insertHeaders(accountId: w.account.id, path: Self.projectsPath, uids: [1, 2], pool: w.pool)
            w.server.suppressFetchRecord(in: Self.projectsPath, uids: [2])
            #expect(try Self.fullSyncStamp(w) == nil, "precondition: the full sync is due")

            // The pass is held inside its Archive listing; the on-demand listing
            // fails in the middle of it, after the pass started.
            w.server.holdNextFetchAfterSnapshot(in: Self.archivePath)
            defer { w.server.releaseFetchAfterSnapshot(in: Self.archivePath) }
            let account = try Self.account(w)
            let pass = Task { try await w.engine.sync(account: account) }
            let waitUntil = Date().addingTimeInterval(10)
            while Date() < waitUntil, !w.server.isHoldingFetchAfterSnapshot(in: Self.archivePath) {
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            #expect(w.server.isHoldingFetchAfterSnapshot(in: Self.archivePath), "precondition: the pass is inside its listing")
            let projects = try #require(try await w.pool.read { db in try Folder.fetchOne(db, key: "\(w.account.id):\(Self.projectsPath)") })
            let onDemand = await w.engine.listFolder(projects, provider: w.provider, limit: SyncConfig.syncMessageLimit)
            guard case .unproven = onDemand else { Issue.record("precondition: the on-demand listing is unproven: \(onDemand)"); return }
            w.server.releaseFetchAfterSnapshot(in: Self.archivePath)
            _ = try await pass.value

            #expect(try Self.fullSyncStamp(w) != nil, "the pass's own listings all proved their windows: it stamps")
            #expect(try Self.listingDue(w, path: Self.projectsPath), "the unproven on-demand listing made its folder due")
        }
    }

    @Test("Two folders in one pass: the first listing proves nothing, the second proves its window; the pass's unproven state survives the later folder, so the stamp stays withheld")
    func unprovenStateOnlyGrowsWithinAPass() async throws {
        try await E.withWorld("lc-unproven-acc", capabilities: Self.condstoreNoReader, serverUIDs: [1, 2], localUIDs: [1]) { w in
            try Self.addArchive(w, serverUIDs: [1, 2, 3], localUIDs: [1, 2])
            w.server.suppressFetchRecord(in: Self.archivePath, uids: [2])
            _ = try await w.engine.sync(account: try Self.account(w))
            #expect(try w.uids() == ["1", "2"], "precondition: the Inbox listing proved its window")
            #expect(try Self.fullSyncStamp(w) == nil, "the Archive's unproven listing withholds the pass's stamp")
        }
    }

    @Test("An unproven on-demand listing makes its folder due: the next pass lists it although STATUS shows nothing changed, and nothing was published from the failed listing")
    func unprovenOnDemandListingMakesTheFolderDue() async throws {
        try await E.withWorld("lc-ondemand-due", capabilities: Self.condstoreNoReader, serverUIDs: [1], localUIDs: [1]) { w in
            try Self.addArchive(w, serverUIDs: [1, 2, 3], localUIDs: [1, 2])
            w.server.suppressFetchRecord(in: Self.archivePath, uids: [2])
            let before = try Self.archive(w)
            let outcome = await w.engine.listFolder(before.folder, provider: w.provider, limit: SyncConfig.syncMessageLimit)
            guard case .unproven = outcome else { Issue.record("precondition: unproven: \(outcome)"); return }
            let after = try Self.archive(w)
            #expect(try Self.listingDue(w, path: Self.archivePath), "the folder is due")
            #expect(after.uids == before.uids && after.folder.totalCount == before.folder.totalCount
                    && after.folder.lastKnownUidNext == before.folder.lastKnownUidNext, "nothing published")
            #expect(SyncEngine.untrackedFolderChanged(
                observation: UntrackedObservation(messageCount: after.folder.totalCount, uidNext: after.folder.lastKnownUidNext ?? 0,
                                                  highestModSeq: after.folder.lastKnownHighestModSeq, uidValidity: nil),
                lastKnownUidNext: after.folder.lastKnownUidNext, totalCount: after.folder.totalCount,
                lastKnownHighestModSeq: after.folder.lastKnownHighestModSeq,
                listingDue: try Self.listingDue(w, path: Self.archivePath)),
                    "an unchanged STATUS does not skip a due folder")
        }
    }

    // MARK: - Every on-demand entry point lists through the one classifier

    enum OnDemandEntry: String, CaseIterable, Sendable {
        /// Opening a folder, after a send (the Sent folder), after a move: all
        /// three call `SyncEngine.syncFolderMessages` (fenced below).
        case syncFolderMessages
        /// Step 6 of an epoch rebuild.
        case epochRebuildStep6
    }

    static func runEntry(_ entry: OnDemandEntry, _ w: E.World) async throws {
        let folder = try Self.archive(w).folder
        switch entry {
        case .syncFolderMessages:
            _ = try await w.engine.syncFolderMessages(folder: folder, provider: w.provider)
        case .epochRebuildStep6:
            await AccountManager.shared.uidValidityResetResyncFolder(
                accountId: w.account.id, folderPath: Self.archivePath, folderId: folder.id, provider: w.provider)
        }
    }

    @Test("Every on-demand listing route, on a server answer that proves nothing (short FETCH, no EXISTS, SELECT refused, unconfirmed EXISTS 0), never publishes the folder as listed: the ghost stays, the counters stay as they were",
          arguments: OnDemandEntry.allCases, ["shortFetch", "noExists", "selectRefused", "contradictedZero"])
    func onDemandEntryNeverPublishesAnUnprovenListing(_ entry: OnDemandEntry, _ answer: String) async throws {
        try await E.withWorld("lc-entry-\(entry.rawValue)-\(answer)", capabilities: Self.condstoreNoReader, serverUIDs: [1], localUIDs: [1]) { w in
            // Server 2, 3, 4; held 1 (gone on the server), 2, 3. A listing that
            // proved its window would remove 1 and write the counters 3 / 5.
            try Self.addArchive(w, serverUIDs: [2, 3, 4], localUIDs: [1, 2, 3])
            switch answer {
            case "shortFetch": w.server.suppressFetchRecord(in: Self.archivePath, uids: [3])
            case "noExists": w.server.suppressSelectExists(true, for: Self.archivePath)
            case "selectRefused": Self.refuseArchiveSelect(w)
            default: w.server.setSelectExists(0, for: Self.archivePath)
            }
            let before = try Self.archive(w)
            try await Self.runEntry(entry, w)
            let after = try Self.archive(w)
            #expect(after.uids.isSuperset(of: ["1", "2", "3"]), "nothing removed on an unproven answer: \(after.uids.sorted())")
            #expect(after.folder.totalCount == before.folder.totalCount
                    && after.folder.lastKnownUidNext == before.folder.lastKnownUidNext
                    && after.folder.lastKnownHighestModSeq == before.folder.lastKnownHighestModSeq,
                    "the counters are written only by a proven listing")
        }
    }

    @Test("Control: the same routes on a proving answer publish the listing (the ghost removed, the counters written)",
          arguments: OnDemandEntry.allCases)
    func onDemandEntryPublishesAProvenListing(_ entry: OnDemandEntry) async throws {
        try await E.withWorld("lc-entry-proven-\(entry.rawValue)", capabilities: Self.condstoreNoReader, serverUIDs: [1], localUIDs: [1]) { w in
            try Self.addArchive(w, serverUIDs: [2, 3, 4], localUIDs: [1, 2, 3])
            try await Self.runEntry(entry, w)
            let after = try Self.archive(w)
            #expect(after.uids == ["2", "3", "4"])
            #expect(after.folder.totalCount == 3 && after.folder.lastKnownUidNext == 5)
        }
    }
}
