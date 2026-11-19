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
}
