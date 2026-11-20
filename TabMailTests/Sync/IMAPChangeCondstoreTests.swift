/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import SwiftMail
import Testing
@testable import TabMail

/// The IMAP change reader on a server with CONDSTORE but no QRESYNC (#755,
/// ADR-IOS-111): the real `IMAPProvider.fetchChanges` and the real engine
/// against `FakeIMAPServer`'s per-message mod-sequence model, where an expunge
/// need not raise HIGHESTMODSEQ (RFC 7162 allows it without QRESYNC) and
/// `UID SEARCH` honours `UID <set>`. Each case asserts what the folder shows or
/// what the reader reports; the wire oracle only where the invariant is about
/// the wire.
@Suite("IMAP change reader (CONDSTORE, no QRESYNC)", .serialized, .processGlobalState)
struct IMAPChangeCondstoreTests {
    typealias R = IMAPChangeReaderTests
    typealias E = IMAPChangeEngineTests

    static let condstore = FakeIMAPServer.defaultCapabilities + ["ENABLE", "CONDSTORE"]
    static let condstoreNoEnable = FakeIMAPServer.defaultCapabilities + ["CONDSTORE"]
    static let qresync = FakeIMAPServer.defaultCapabilities + ["ENABLE", "CONDSTORE", "QRESYNC"]

    static func withWorld(
        capabilities: [String] = condstore, inbox: [Int], _ body: (R.World) async throws -> Void
    ) async throws {
        try await R.withWorld(capabilities: capabilities, inbox: inbox) { w in
            w.server.setExpungeKeepsHighestModSeq(true, for: R.inboxPath)
            try await body(w)
        }
    }

    static func remove(_ uids: Set<Int>, from w: FakeIMAPServer, _ path: String = R.inboxPath) {
        w.setMessages(w.messages(in: path).filter { !uids.contains($0.uid) }, in: path)
    }

    static func add(_ uids: [Int], to w: FakeIMAPServer, _ path: String = R.inboxPath) {
        w.setMessages(w.messages(in: path) + uids.map(R.message), in: path)
    }

    // MARK: - T3: entry

    @Test("T3: CONDSTORE + ENABLE + UIDPLUS: a baseline, then tracked reads; ENABLE CONDSTORE once per session; no window listing")
    func condstoreServerIsTracked() async throws {
        try await Self.withWorld(inbox: [1, 2, 3]) { w in
            let first = try await R.inbox(w, R.read(w))
            #expect({ if case .baselineReady = first.status { return true }; return false }(), "got \(first.status)")
            w.server.setFlags(["\\Seen"], in: R.inboxPath, uid: 1)
            let second = try await R.inbox(w, R.read(w, cursors: [w.inboxId: first.cursor]))
            #expect(R.isTracked(second.status), "got \(second.status)")
            #expect(second.records.first { $0.messageId == "1" }?.isRead == true)
            let enables = w.server.enableCondStoreCountByConnection
            #expect(!enables.isEmpty && enables.values.allSatisfy { $0 == 1 }, "ENABLE CONDSTORE once per session: \(enables)")
            #expect(w.server.recordedCommands().allSatisfy { !$0.uppercased().contains("QRESYNC") })
        }
    }

    @Test("T3: CONDSTORE + UIDPLUS without ENABLE: tracked through SELECT (CONDSTORE), no ENABLE sent")
    func condstoreWithoutEnableSelectsWithCondstore() async throws {
        try await Self.withWorld(capabilities: Self.condstoreNoEnable, inbox: [1, 2, 3]) { w in
            let first = try await R.inbox(w, R.read(w))
            w.server.setFlags(["\\Flagged"], in: R.inboxPath, uid: 2)
            let second = try await R.inbox(w, R.read(w, cursors: [w.inboxId: first.cursor]))
            #expect(R.isTracked(second.status), "got \(second.status)")
            #expect(second.records.first { $0.messageId == "2" }?.isFlagged == true)
            #expect(w.server.recordedCommands().allSatisfy { !$0.uppercased().hasPrefix("ENABLE") }, "no ENABLE without it")
            #expect(w.server.condStoreSelectCount > 0, "the SELECT carried (CONDSTORE)")
        }
    }

    // MARK: - T2: a flag change far below the window

    @Test("T2: a flag change on a message far below the listing window is shown after one read")
    func oldFlagChangeArrives() async throws {
        try await Self.withWorld(inbox: Array(1...(SyncConfig.syncMessageLimit + 10))) { w in
            let cursor = try await R.baseline(w)
            w.server.setFlags(["\\Seen"], in: R.inboxPath, uid: 2)
            let changes = try await R.inbox(w, R.read(w, cursors: [w.inboxId: cursor]))
            #expect(R.isTracked(changes.status), "got \(changes.status)")
            #expect(changes.records.first { $0.messageId == "2" }?.isRead == true)
            #expect(changes.removals.isEmpty)
        }
    }

    // MARK: - T8: a moved-in row expunged elsewhere

    @Test("T8: a moved-in row the server no longer has is removed, while the other arrivals are fetched")
    func movedInRowExpungedElsewhereIsRemoved() async throws {
        try await Self.withWorld(inbox: [1, 2, 3]) { w in
            let cursor = try await R.baseline(w)
            // UID 4 was moved in (re-keyed from COPYUID) and expunged elsewhere; 5 arrived.
            w.local.add(w.inboxId, [4])
            Self.add([4, 5], to: w.server)
            Self.remove([4], from: w.server)
            let changes = try await R.inbox(w, R.read(w, cursors: [w.inboxId: cursor]))
            #expect(changes.removals.contains("4"), "the gone moved-in row is removed: \(changes.removals) \(changes.status)")
            #expect(changes.records.contains { $0.messageId == "5" }, "the arrival is fetched")
            #expect(!changes.removals.contains("5"))
        }
    }

    // MARK: - T10: refusals and the untracked path

    @Test("T10: a new UIDVALIDITY refuses the bookmark and removes nothing")
    func epochChangeRefuses() async throws {
        try await Self.withWorld(inbox: [1, 2, 3]) { w in
            let cursor = try await R.baseline(w)
            w.server.setUidValidity(R.epoch + 1, for: R.inboxPath)
            let changes = try await R.inbox(w, R.read(w, cursors: [w.inboxId: cursor]))
            guard case .refused(.addressEpochChanged(let served)) = changes.status else {
                Issue.record("expected an epoch refusal, got \(changes.status)"); return
            }
            #expect(served == R.epoch + 1)
            #expect(changes.removals.isEmpty)
        }
    }

    @Test("T10: a bookmark without a count starts a baseline on a CONDSTORE session; NOMODSEQ and a SELECT without EXISTS leave the folder untracked with nothing removed")
    func incompleteBookmarkOrSelection() async throws {
        try await Self.withWorld(inbox: [1, 2, 3]) { w in
            let countless = IMAPChangeCursor(
                uidValidity: UInt32(R.epoch), highestModSeq: UInt64(w.server.qresyncHighestModSeq(for: R.inboxPath)),
                uidNext: 4).encoded
            let changes = try await R.inbox(w, R.read(w, cursors: [w.inboxId: countless]))
            #expect({ if case .baselineReady = changes.status { return true }; return false }(), "got \(changes.status)")
        }
        try await Self.withWorld(inbox: [1, 2, 3]) { w in
            let cursor = try await R.baseline(w)
            Self.remove([1], from: w.server)
            w.server.suppressSelectExists(true, for: R.inboxPath)
            let changes = try await R.inbox(w, R.read(w, cursors: [w.inboxId: cursor]))
            #expect({ if case .untracked = changes.status { return true }; return false }(), "no EXISTS: untracked, got \(changes.status)")
            #expect(changes.removals.isEmpty)
            #expect(changes.cursor == nil, "the bookmark is unchanged")
        }
        try await Self.withWorld(inbox: [1, 2, 3]) { w in
            let cursor = try await R.baseline(w)
            w.server.setNoModSeq(true, for: R.inboxPath)
            Self.remove([1], from: w.server)
            let changes = try await R.inbox(w, R.read(w, cursors: [w.inboxId: cursor]))
            #expect({ if case .untracked = changes.status { return true }; return false }(), "NOMODSEQ: untracked, got \(changes.status)")
            #expect(changes.removals.isEmpty)
        }
    }

    // MARK: - T11: the mode follows each session

    @Test("T11: a server that changes from QRESYNC to CONDSTORE only between sessions is read in each session's mode, and no live row is removed")
    func modeFollowsTheSession() async throws {
        try await Self.withWorld(capabilities: Self.qresync, inbox: [1, 2, 3]) { w in
            let cursor = try await R.baseline(w)
            w.server.setCapabilities(Self.condstore)
            try await w.provider.disconnect()
            try await w.provider.connect()
            Self.remove([2], from: w.server)
            Self.add([4], to: w.server)
            let changes = try await R.inbox(w, R.read(w, cursors: [w.inboxId: cursor]))
            #expect(R.isTracked(changes.status), "got \(changes.status)")
            #expect(changes.removals == ["2"], "only the expunged message goes: \(changes.removals)")
            #expect(changes.records.contains { $0.messageId == "4" })
            #expect(w.server.recordedCommands().filter { $0.uppercased().contains("QRESYNC (") }.isEmpty,
                    "no QRESYNC SELECT on the CONDSTORE session")
        }
    }

    // MARK: - T14: EXISTS 0 with live UIDs

    @Test("T14: a first baseline whose SELECT says EXISTS 0 while the folder holds live UIDs stores no bookmark and removes nothing")
    func existsZeroBaselineWithLiveUIDs() async throws {
        for capabilities in [Self.qresync, Self.condstore] {
            try await Self.withWorld(capabilities: capabilities, inbox: [1, 2, 3]) { w in
                w.server.setSelectExists(0, for: R.inboxPath)
                let changes = try await R.inbox(w, R.read(w))
                #expect(changes.cursor == nil, "no bookmark with count 0 over live UIDs (\(capabilities))")
                #expect({ if case .baselineReady = changes.status { return false }; return true }(), "got \(changes.status)")
                #expect(changes.removals.isEmpty)
            }
        }
    }

    // MARK: - T1: through the engine

    /// Holds the listing window and one old message far below it (the rows a
    /// partly loaded folder holds), so the folder holds fewer rows than the
    /// server counts and no count difference ever shows the old row's loss.
    static func partlyLoaded() -> (server: [Int], local: [Int], old: Int) {
        let server = Array(1...(SyncConfig.syncMessageLimit + 10))
        let old = 3
        return (server, [old] + Array(server.suffix(SyncConfig.syncMessageLimit)), old)
    }

    /// FETCH commands that list a UID range of more than one message, other
    /// than a CHANGEDSINCE read (a window listing).
    static func listings(_ commands: ArraySlice<String>) -> [String] {
        commands.filter { command in
            let upper = command.uppercased()
            guard upper.contains("FETCH"), !upper.contains("CHANGEDSINCE") else { return false }
            return upper.split(separator: " ").contains { token in
                let ends = token.split(separator: ":")
                guard ends.count == 2, let lo = Int(ends[0]) else { return false }
                return ends[1] == "*" || (Int(ends[1]).map { $0 > lo } ?? false)
            }
        }
    }

    @Test("T1: an old message deleted on another device while a new one arrives, HIGHESTMODSEQ not raised: after one pass the row is gone, the new one shown, and no folder listing ran")
    func expungeFarBelowTheWindowWithAnArrival() async throws {
        let world = Self.partlyLoaded()
        let arrival = world.server.count + 1
        try await E.withWorld("cs-t1", capabilities: Self.condstore, serverUIDs: world.server, localUIDs: world.local) { w in
            w.server.honorSearchUIDSetCriterion()
            w.server.setExpungeKeepsHighestModSeq(true, for: E.path)
            // A baseline pass, then a tracked one.
            _ = try await w.engine.performDeltaSync(account: w.account, provider: w.provider)
            _ = try await w.engine.performDeltaSync(account: w.account, provider: w.provider)
            let held = try w.uids()
            Self.remove([world.old], from: w.server, E.path)
            Self.add([arrival], to: w.server, E.path)
            let start = w.server.recordedCommands().count
            _ = try await w.engine.performDeltaSync(account: w.account, provider: w.provider)
            let rows = try w.uids()
            #expect(!rows.contains(String(world.old)), "the message deleted elsewhere is gone")
            #expect(rows == held.subtracting([String(world.old)]).union([String(arrival)]), "nothing else changed: \(rows.count)")
            let listed = Self.listings(w.server.recordedCommands().dropFirst(start))
            #expect(listed.isEmpty, "no folder listing ran: \(listed)")
        }
    }

    @Test("T1 control: with nothing deleted, a pass that reads an arrival removes no row")
    func arrivalAloneRemovesNothing() async throws {
        let world = Self.partlyLoaded()
        let arrival = world.server.count + 1
        try await E.withWorld("cs-t1c", capabilities: Self.condstore, serverUIDs: world.server, localUIDs: world.local) { w in
            w.server.honorSearchUIDSetCriterion()
            w.server.setExpungeKeepsHighestModSeq(true, for: E.path)
            _ = try await w.engine.performDeltaSync(account: w.account, provider: w.provider)
            _ = try await w.engine.performDeltaSync(account: w.account, provider: w.provider)
            let held = try w.uids()
            Self.add([arrival], to: w.server, E.path)
            _ = try await w.engine.performDeltaSync(account: w.account, provider: w.provider)
            #expect(try w.uids() == held.union([String(arrival)]))
        }
    }

    // MARK: - The notification merge after a tracked read

    /// Stages a header-only notification row for `uid` in INBOX (as the
    /// notification service writes one), then merges staging; returns whether
    /// the staged row is still there after the merge.
    static func stageAndMerge(_ uid: Int, _ w: E.World) async throws -> Bool {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("nse_staging.sqlite").path
        _ = AppDatabase.createNSEStagingDB(atPath: path)
        let staging = try DatabaseQueue(path: path)
        defer { TestDatabaseTeardown.retire(pools: [], queues: [staging], directory: dir) }
        let accountId = w.account.id
        let id = "\(accountId):\(uid)"
        try await staging.write { db in
            try db.execute(sql: """
                INSERT INTO nse_processed_message
                    (id, accountId, accountEmail, provider, messageId, rfc822MessageId,
                     folderPath, subject, senderName, senderEmail, snippet, date,
                     processedAt, aiCompleted, notified, populated)
                VALUES (?, ?, 'user@example.com', 'imap_new_mail', ?, ?, ?,
                        'Staged subject', 'Sender', 'sender@example.com', 'snippet', ?, ?, 0, 0, 1)
                """, arguments: [
                    id, accountId, String(uid), "rfc-\(uid)@example.com", E.path,
                    Date().timeIntervalSince1970, Date().timeIntervalSince1970,
                ])
        }
        await NSEDataBridge.mergeNSEStagingData(stagingPathOverride: path)
        return try await staging.read { db in
            try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM nse_processed_message WHERE id = ?)", arguments: [id]) ?? false
        }
    }

    static func tracked(_ w: E.World) throws -> Bool {
        let folder = try w.folder()
        return FolderChangeState(raw: folder.changeState).tracking && folder.changeCursor != nil
    }

    /// One real foreground pass (`SyncEngine.sync`): the change read, the
    /// listings it needs, and the baseline commit that alone turns tracking on
    /// (`commitChangeBaseline`). The recent-sync throttle is cleared so the pass
    /// runs; `listing` also makes the scheduled full sync due.
    static func foregroundPass(_ w: E.World, listing: Bool = false) async throws {
        let id = w.account.id
        try await w.pool.write { db in
            try db.execute(sql: "UPDATE account SET lastSyncedAt = NULL WHERE id = ?", arguments: [id])
            if listing {
                try db.execute(sql: "UPDATE account SET lastFullSyncAt = NULL WHERE id = ?", arguments: [id])
            }
        }
        let account = try #require(try w.pool.read { db in try Account.fetchOne(db, key: id) })
        _ = try await w.engine.sync(account: account)
    }

    static func bookmarkDropped(_ w: E.World) throws -> Bool {
        let folder = try w.folder()
        return !FolderChangeState(raw: folder.changeState).tracking && folder.changeCursor == nil
    }

    @Test("A staged notification for a message a tracked read removed comes back with the merge, and the next sync removes it for good")
    func stagedMessageARemovalProvedGoneIsSettledByTheNextSync() async throws {
        try await E.withWorld("cs-nse-gone", capabilities: Self.condstore, serverUIDs: [1, 2, 3, 4], localUIDs: [1, 2, 3, 4]) { w in
            w.server.honorSearchUIDSetCriterion()
            w.server.setExpungeKeepsHighestModSeq(true, for: E.path)
            try await Self.foregroundPass(w)
            #expect(try Self.tracked(w), "setup: the baseline pass's listing and commit track the folder")
            Self.remove([2], from: w.server, E.path)
            try await Self.foregroundPass(w)
            #expect(try !w.uids().contains("2"), "setup: the tracked read removed 2")
            #expect(try Self.tracked(w), "before the merge: tracked")

            let kept = try await Self.stageAndMerge(2, w)
            #expect(kept, "the staged row is kept")
            #expect(try w.uids().contains("2"), "the merge brought 2 back")
            #expect(try Self.bookmarkDropped(w), "after the merge: the bookmark is dropped and the folder untracked")
            try await Self.foregroundPass(w)
            #expect(try w.uids() == ["1", "3", "4"], "the next sync removes the merged-back message")
            #expect(try Self.tracked(w), "and tracks the folder again")
            try await Self.foregroundPass(w)
            #expect(try w.uids() == ["1", "3", "4"], "and it stays gone")
        }
    }

    // MARK: - A staged UID at the old UIDNEXT merged between the read and the apply

    /// What happens to UID 2 on the server before the raced read.
    enum ArrivalFate { case live, expunged, softDeleted }

    /// A tracked inbox holding 1 (bookmark UIDNEXT 2, catch-up completed). UID 2
    /// arrives; `.expunged` expunges it again before the next read,
    /// `.softDeleted` flags it `\Deleted` without expunging it. The raced pass:
    /// the real reader reads the inbox (the database's rows), then the real
    /// staging merge inserts a notification row for 2 (the stored bookmark does
    /// not claim 2 yet, so the merge keeps it), then the read is applied. Then
    /// ordinary foreground passes run until the folder settles.
    struct ArrivalRaceOutcome {
        var racedApplyRejected = true
        var afterRace: IMAPChangeCursor?
        var rowsAfterRace: Set<String> = []
        var staged = false
        var rows: Set<String> = []
        var trackedAfter = false
        var finalUidNext: UInt32?
    }

    static func stagedArrivalMergedBetweenReadAndApply(_ name: String, fate: ArrivalFate, mergeAfterApply: Bool = false) async throws -> ArrivalRaceOutcome {
        let gone = fate != .live
        var outcome = ArrivalRaceOutcome()
        try await E.withWorld(name, capabilities: Self.condstore, serverUIDs: [1], localUIDs: [1]) { w in
            w.server.honorSearchUIDSetCriterion()
            w.server.setExpungeKeepsHighestModSeq(true, for: E.path)
            try await Self.foregroundPass(w)
            try #require(try Self.tracked(w), "setup: the baseline pass's listing and commit track the folder")
            try #require(IMAPChangeCursor.decode(try w.folder().changeCursor)?.uidNext == 2, "setup: the bookmark's UIDNEXT is 2")
            try #require(IMAPCatchUpState.decode(try w.folder().catchUpState)?.lastCompletedAt != nil,
                         "setup: the catch-up has completed, so no periodic listing repairs a ghost")

            Self.add([2], to: w.server, E.path)
            _ = w.server.qresyncHighestModSeq(for: E.path)  // the server has assigned UID 2
            switch fate {
            case .live: break
            case .expunged: Self.remove([2], from: w.server, E.path)
            case .softDeleted: w.server.setFlags(["\\Deleted"], in: E.path, uid: 2)
            }

            let folder = try w.folder()
            let issuedWith = folder.changeCursor
            let request = ChangeRequest(
                folders: [ChangeFolder(
                    id: folder.id, path: folder.path, role: folder.role, cursor: issuedWith, isSynced: true,
                    heldSince: folder.oldestSyncedDate, addressEpoch: SyncEngine.knownUidValidity(folder.lastKnownUidValidity),
                    olderMailComplete: folder.backfillComplete, olderMailCursor: folder.backfillUidCursor)],
                scope: .all, recheck: [:], context: ChangeContext(onProgress: { _ in }),
                localRows: SyncEngineCatchUpRowReader(pool: AppDatabase.syncPool))
            let set = try #require(try await w.provider.fetchChanges(since: ChangeCursor(account: nil), request: request))
            var raced = try #require(set.folders.first { $0.folderId == folder.id })
            try #require(R.isTracked(raced.status), "setup: the raced read is tracked, got \(raced.status)")
            raced.readFrom = FolderChanges.ReadFrom(cursor: issuedWith)

            if !mergeAfterApply {
                outcome.staged = try await Self.stageAndMerge(2, w)
                try #require(try w.uids().contains("2"), "setup: the merge inserted 2 between the read and the apply")
            }
            let racedChanges = raced
            let applied = try await w.pool.write { db in try SyncEngine.applyFolderChanges(racedChanges, db: db) }
            outcome.racedApplyRejected = applied.rejected
            outcome.afterRace = IMAPChangeCursor.decode(try w.folder().changeCursor)
            outcome.rowsAfterRace = try w.uids()
            if mergeAfterApply { outcome.staged = try await Self.stageAndMerge(2, w) }

            for _ in 0..<IMAPChangeCondstoreCheckTests.raceSettlePassCap {
                try await Self.foregroundPass(w)
                if try (gone ? !w.uids().contains("2") : true) && Self.tracked(w) { break }
            }
            try await Self.foregroundPass(w)  // and it stays settled
            outcome.rows = try w.uids()
            outcome.trackedAfter = try Self.tracked(w)
            outcome.finalUidNext = IMAPChangeCursor.decode(try w.folder().changeCursor)?.uidNext
        }
        return outcome
    }

    @Test("A staged UID at the old UIDNEXT that the merge inserts between the read and the apply is never covered unchecked: the bookmark stays, ordinary passes remove the expunged message and track the folder")
    func stagedArrivalAtOldUidNextMergedBeforeApplyIsNotAGhost() async throws {
        let outcome = try await Self.stagedArrivalMergedBetweenReadAndApply("cs-nse-arrival-gone", fate: .expunged)
        #expect(!outcome.racedApplyRejected, "the raced apply reached the proof")
        #expect(outcome.afterRace?.uidNext == 2, "the bookmark covered UID 2 without checking it: \(String(describing: outcome.afterRace))")
        #expect(outcome.staged, "the staged payload is kept")
        #expect(outcome.rows == ["1"], "the expunged staged message stays as a ghost: \(outcome.rows)")
        #expect(outcome.trackedAfter, "the folder is tracked again")
        #expect(outcome.finalUidNext == 3, "the bookmark moves on past 2: \(String(describing: outcome.finalUidNext))")
    }

    @Test("A staged UID at the old UIDNEXT flagged \\Deleted (not expunged) that the merge inserts between the read and the apply is removed, never stranded behind the bookmark: ordinary passes leave no ghost and keep the folder tracked")
    func stagedSoftDeletedArrivalMergedBeforeApplyIsNotAGhost() async throws {
        let outcome = try await Self.stagedArrivalMergedBetweenReadAndApply("cs-nse-arrival-soft-deleted", fate: .softDeleted)
        #expect(!outcome.racedApplyRejected, "the raced apply reached the proof")
        // Either the raced apply removed the row it covered, or it kept the
        // bookmark behind it; never a covered row that stays.
        #expect(outcome.rowsAfterRace == ["1"], "the apply removes the positively observed \\Deleted arrival the merge inserted: \(outcome.rowsAfterRace)")
        let coveredAndKept = outcome.afterRace?.uidNext == 3 && outcome.rowsAfterRace.contains("2")
        #expect(!coveredAndKept, "the bookmark covered the soft-deleted UID 2 while its row stayed: \(String(describing: outcome.afterRace)) rows \(outcome.rowsAfterRace)")
        #expect(outcome.staged, "the staged payload is kept")
        #expect(outcome.rows == ["1"], "the soft-deleted staged message stays as a ghost: \(outcome.rows)")
        #expect(outcome.trackedAfter, "the folder is tracked again")
        #expect(outcome.finalUidNext == 3, "the bookmark moves on past 2: \(String(describing: outcome.finalUidNext))")
    }

    @Test("A soft-deleted arrival never outlives the next pass: a staged UID at the old UIDNEXT flagged \\Deleted (not expunged), merged after the apply already covered it, is gone after the next ordinary pass")
    func softDeletedArrivalNeverOutlivesTheNextPass() async throws {
        let outcome = try await Self.stagedArrivalMergedBetweenReadAndApply(
            "cs-nse-arrival-soft-deleted-late", fate: .softDeleted, mergeAfterApply: true)
        #expect(!outcome.racedApplyRejected, "the apply reached the proof")
        #expect(outcome.rowsAfterRace == ["1"], "the apply leaves no row for the soft-deleted UID 2: \(outcome.rowsAfterRace)")
        #expect(outcome.staged, "the staged payload is kept")
        #expect(outcome.rows == ["1"], "the soft-deleted staged message stays as a ghost: \(outcome.rows)")
        #expect(outcome.trackedAfter, "the folder is tracked again")
        #expect(outcome.finalUidNext == 3, "the bookmark moves on past 2: \(String(describing: outcome.finalUidNext))")
    }

    @Test("Control: a staged live arrival at the old UIDNEXT merged between the read and the apply stays, and the bookmark moves on in the same apply")
    func stagedLiveArrivalAtOldUidNextMergedBeforeApplyStays() async throws {
        let outcome = try await Self.stagedArrivalMergedBetweenReadAndApply("cs-nse-arrival-live", fate: .live)
        #expect(!outcome.racedApplyRejected, "the raced apply reached the proof")
        #expect(outcome.afterRace?.uidNext == 3, "a read that fetched the arrival covers it: \(String(describing: outcome.afterRace))")
        #expect(outcome.rowsAfterRace == ["1", "2"], "the live arrival is held after the race: \(outcome.rowsAfterRace)")
        #expect(outcome.staged, "the staged payload is kept")
        #expect(outcome.rows == ["1", "2"], "the live arrival survives ordinary passes: \(outcome.rows)")
        #expect(outcome.trackedAfter, "the folder stays tracked")
        #expect(outcome.finalUidNext == 3)
    }

    @Test("A staged notification for a live older message the window never loaded merges into a tracked folder, survives the next sync, and the folder is tracked again")
    func stagedLiveOlderMessageMergesAfterATrackedRead() async throws {
        let world = Self.partlyLoaded()
        let arrival = world.server.count + 1
        let live = world.old + 1
        try await E.withWorld("cs-nse", capabilities: Self.condstore, serverUIDs: world.server, localUIDs: world.local) { w in
            w.server.honorSearchUIDSetCriterion()
            w.server.setExpungeKeepsHighestModSeq(true, for: E.path)
            try await Self.foregroundPass(w)
            #expect(try Self.tracked(w), "setup: the baseline pass's listing and commit track the folder")
            Self.add([arrival], to: w.server, E.path)
            try await Self.foregroundPass(w)
            #expect(try w.uids().contains(String(arrival)), "setup: the tracked read applied the arrival")
            #expect(try Self.tracked(w), "before the merge: tracked")
            #expect(try !w.uids().contains(String(live)), "setup: the live older message is not held")

            let kept = try await Self.stageAndMerge(live, w)
            #expect(try w.uids().contains(String(live)), "the live staged message materialises")
            #expect(kept, "its header-only staged copy stays for the rest of its stages")
            #expect(try Self.bookmarkDropped(w), "after the merge: the bookmark is dropped and the folder untracked")
            try await Self.foregroundPass(w)
            #expect(try w.uids().contains(String(live)), "the live message survives the listing")
            #expect(try Self.tracked(w), "the folder is tracked again")
        }
    }
}
