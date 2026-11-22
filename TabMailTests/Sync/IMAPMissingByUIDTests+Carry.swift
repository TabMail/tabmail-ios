/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Synchronization
import Testing
@testable import TabMail

/// A gate inside a slice's sync turn, after the slice's read returned and
/// before it applies anything (`SyncEngine.setCatchUpAfterReadHookForTesting`):
/// the test learns the turn is taken, then releases the slice. No IMAP command
/// is waiting meanwhile, so no command timer can race the handshake. Counts the
/// slices that reached it (`countSlice`), so a test can hold one of them.
/// *Superseded (#1062):* the gate stood before the slice sent anything, so the
/// slice it held had nothing read to apply.
final class SliceTurnGate: Sendable {
    private let state = Mutex<(inTurn: Bool, released: Bool, slices: Int)>((false, false, 0))

    var inTurn: Bool { state.withLock { $0.inTurn } }
    func enter() { state.withLock { $0.inTurn = true } }
    func release() { state.withLock { $0.released = true } }
    /// Counts one more slice at the gate; returns how many have reached it.
    func countSlice() -> Int { state.withLock { $0.slices += 1; return $0.slices } }

    /// Waits until released or `bound` seconds pass; true when released.
    func waitForRelease(bound: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(bound)
        while !state.withLock({ $0.released }), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return state.withLock { $0.released }
    }
}

/// A carried catch-up range across what can change between the slice that
/// carried it and the one that resumes it (#1062): a Settings reset, a
/// UIDVALIDITY change, the load floor, a budget that stops before an
/// unanswered UID's SEARCH, several load batches, a held UID. Same world as
/// `IMAPMissingByUIDTests`.
extension IMAPMissingByUIDTests {

    /// The header loads (`UID FETCH ... ENVELOPE`) among `commands`.
    static func headerFetches(_ commands: some Collection<String>) -> [String] {
        commands.filter { $0.uppercased().contains("FETCH") && $0.uppercased().contains("ENVELOPE") }
    }

    /// How long a step of the Settings-reset handshake (the slice taking its
    /// turn, the reset waiting for it) may take to happen before the test
    /// fails; every wait ends as soon as its step happens. The slice is held
    /// at a gate in its turn once its read returned and before its apply
    /// (`SliceTurnGate`), so no request or command timer runs while it waits.
    /// *Superseded (#1062):* the slice's listing FETCH was held on the wire
    /// under a 60 s request timeout, which the client's own FETCH command
    /// timeout could still end first; before that, 300 polls 10 ms apart,
    /// about 3 s, the production request timeout the held listing could reach.
    static let resetHandshakeStepBound: TimeInterval = 30

    /// Slices of `maxRequests` until the folder holds `expected` and its listing
    /// is done, at most `bound`; returns how many ran. `between` runs after each.
    @MainActor
    static func slicesUntilRepaired(_ w: World, expected: [Int], maxRequests: Int, clock: CatchUpTestClock,
                                    bound: Int, between: () async throws -> Void = {}) async throws -> Int {
        var slices = 0
        while try w.held() != expected || w.catchUpState()?.listing != nil, slices < bound {
            await w.slice(maxRequests: maxRequests, clock: clock)
            slices += 1
            try await between()
        }
        return slices
    }

    // MARK: - a Settings reset during the slice

    /// The two Settings resets, through the engine entry points the views call.
    enum SettingsReset: String, CaseIterable, Sendable {
        case accountMessageData
        case wipeLocalIndex
    }

    @Test("A Settings reset issued while a catch-up run's slice holds the account's sync turn, its read done (a carried header load sent) and nothing of it applied yet, waits for the slice: after it, the folder's whole catch-up state is gone (the carry, the window floor and the prune cutoff), no row the slice loaded is kept, and the next slice lists before it loads anything",
          arguments: SettingsReset.allCases)
    @MainActor
    func resetDuringASliceIsNeverUndone(_ reset: SettingsReset) async throws {
        let server = Self.carryServer
        try await Self.withWorld("carry-reset-\(reset.rawValue)", server: server, local: server,
                                 rangeMessages: SyncConfig.catchUpListingRangeMessages) { w in
            let folderId = w.folderId, accountId = w.accountId, pool = w.pool
            try await w.dropLocal(Self.carryMissing)
            try await w.pool.write { db in
                try SyncEngine.recordCatchUpWindowFloor(folderId: folderId, lowest: 1, epoch: Self.epoch, db: db)
                try SyncEngine.recordCatchUpPruneCutoff(folderId: folderId, highest: 1, epoch: Self.epoch, db: db)
            }
            try await w.markOwed()
            // The production run (`runCatchUpRun`) takes the account's turn for
            // each slice. Its first slice lists and proves the first range and
            // carries the load (two requests after the listing's start); its
            // second sends the carried header load, and once its read has
            // returned it waits at a gate inside its turn, before it applies
            // anything, until the reset waits for that turn. The run's clock then
            // passes its deadline, so no slice starts after it. Nothing is timed,
            // its requests included (`untimedRequestTimeout`).
            let clock = CatchUpTestClock()
            let gate = SliceTurnGate()
            let bound = Self.resetHandshakeStepBound
            let pastTheDeadline: TimeInterval = 120
            await w.engine.setCatchUpAfterReadHookForTesting { _ in
                guard gate.countSlice() == 2 else { return }
                gate.enter()
                _ = await gate.waitForRelease(bound: 2 * bound)
                clock.advance(by: pastTheDeadline)
            }
            let start = w.server.recordedCommands().count
            async let ran = w.workerRun(maxRequests: Self.newListingStartRequests + 2, deadlineIn: pastTheDeadline / 2,
                                        requestTimeout: Self.untimedRequestTimeout, intervalSeconds: 0, clock: { clock.now })
            var deadline = Date().addingTimeInterval(bound)
            while !gate.inTurn, Date() < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(gate.inTurn, "setup: the run's second slice holds the account's turn")
            let loadsSent = Self.headerFetches(Self.requests(to: Self.path, w.server, from: start).map { $0.command })
            #expect(!loadsSent.isEmpty, "setup: the held slice sent the carried header load to the folder before the reset")
            let before = try w.folder().catchUpState
            #expect(IMAPCatchUpState.decode(before)?.listing?.carried != nil,
                    "setup: nothing of the held slice is applied yet: the first slice's carry is still stored")
            #expect(CatchUpWindowFloor.read(before, epoch: Self.epoch) == 1 && CatchUpPruneCutoff.read(before, epoch: Self.epoch) == 1,
                    "setup: both keys are stored before the reset")
            // The Settings reset, through the production entry point the Settings
            // view calls; it waits for the slice's turn.
            let engine = w.engine
            let resetting = Task { @MainActor in
                switch reset {
                case .accountMessageData: try await engine.resetMessageData(accountId: accountId)
                case .wipeLocalIndex: try await engine.wipeLocalIndex()
                }
            }
            deadline = Date().addingTimeInterval(bound)
            while await engine.syncPassWaiterCountForTesting(accountId: accountId) == 0, Date() < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(await engine.syncPassWaiterCountForTesting(accountId: accountId) > 0,
                    "setup: the reset waits for the slice's turn")
            gate.release()
            _ = try await ran
            await w.engine.setCatchUpAfterReadHookForTesting(nil)
            try await resetting.value
            let heldAfterReset = try w.held()
            #expect(heldAfterReset.isEmpty, "#1062: no row the held slice loaded is kept after the reset: \(heldAfterReset)")
            let raw = try w.folder().catchUpState
            #expect(raw == nil, "#1062: no pre-reset catch-up state is kept, the carry and both keys included: \(String(describing: raw))")

            // Then a window listing records a floor again, as the next full sync
            // does, so a kept carry would load.
            try await pool.write { db in
                try SyncEngine.recordCatchUpWindowFloor(folderId: folderId, lowest: 1, epoch: Self.epoch, db: db)
            }
            let next = w.server.recordedCommands().count
            await w.slice(clock: clock)
            let commands = Self.requests(to: Self.path, w.server, from: next).map { $0.command }
            let firstListing = commands.firstIndex { !Self.listingRanges([$0]).isEmpty }
            #expect(firstListing != nil, "#1062: the next slice lists the folder: \(commands)")
            let early = Self.headerFetches(commands[..<(firstListing ?? commands.endIndex)])
            #expect(early.isEmpty, "#1062: nothing is loaded from the old carry before a listing: \(early)")
        }
    }

    @Test("A window floor and a prune cutoff written after a slice's read and before its apply are what the apply's state write keeps, each under its own epoch, not the values the read began with")
    @MainActor
    func applyKeepsTheKeysWrittenDuringTheRead() async throws {
        let server = Self.carryServer
        try await Self.withWorld("carry-keys-during-read", server: server, local: server,
                                 rangeMessages: SyncConfig.catchUpListingRangeMessages) { w in
            let folderId = w.folderId, pool = w.pool
            try await w.dropLocal(Self.carryMissing)
            try await w.pool.write { db in
                try SyncEngine.recordCatchUpWindowFloor(folderId: folderId, lowest: 1, epoch: Self.epoch, db: db)
                try SyncEngine.recordCatchUpPruneCutoff(folderId: folderId, highest: 1, epoch: Self.epoch, db: db)
            }
            try await w.markOwed()
            let otherEpoch = Self.epoch + 1, raisedCutoff = 3, newFloor = 2
            // Entered once both writes committed.
            let wrote = SliceTurnGate()
            // Between the provider's read and the apply: a window listing of a
            // new numbering records its floor, and a prune raises the cutoff.
            await w.engine.setCatchUpAfterReadHookForTesting { _ in
                do {
                    try await pool.write { db in
                        try SyncEngine.recordCatchUpWindowFloor(folderId: folderId, lowest: newFloor, epoch: otherEpoch, db: db)
                        try SyncEngine.recordCatchUpPruneCutoff(folderId: folderId, highest: raisedCutoff, epoch: Self.epoch, db: db)
                    }
                    wrote.enter()
                } catch {}
            }
            let clock = CatchUpTestClock()
            await w.slice(maxRequests: Self.newListingStartRequests + 2, clock: clock)
            await w.engine.setCatchUpAfterReadHookForTesting(nil)
            #expect(wrote.inTurn, "setup: both keys were written between the read and the apply")
            let raw = try w.folder().catchUpState
            #expect(try w.catchUpState()?.listing?.carried != nil, "setup: the apply wrote the slice's state (its carry): \(String(describing: raw))")
            #expect(CatchUpWindowFloor.read(raw, epoch: otherEpoch) == newFloor && CatchUpWindowFloor.read(raw, epoch: Self.epoch) == nil,
                    "#1062: the window floor written during the read is kept, under its own epoch: \(String(describing: raw))")
            #expect(CatchUpPruneCutoff.read(raw, epoch: Self.epoch) == raisedCutoff,
                    "#1062: the prune cutoff raised during the read is kept: \(String(describing: raw))")
        }
    }

    // MARK: - a UIDVALIDITY change between the carry and its resume

    @Test("The server numbers the folder anew between the slice that carried a proven range and the one that resumes it: no header FETCH of the carried UIDs is sent and nothing loads")
    @MainActor
    func epochChangeBeforeTheResumeSendsNoFetch() async throws {
        let server = Self.carryServer
        try await Self.withWorld("carry-epoch", server: server, local: server,
                                 rangeMessages: SyncConfig.catchUpListingRangeMessages) { w in
            try await w.dropLocal(Self.carryMissing)
            try await w.markOwed()
            let clock = CatchUpTestClock()
            await w.slice(maxRequests: Self.newListingStartRequests + 2, clock: clock)
            let carried = try #require(try w.catchUpState()?.listing?.carried, "setup: the range is carried")
            #expect(carried.proven && carried.missing == [UInt32(Self.carryMissing[0])],
                    "setup: proven, its load owed: \(carried.missing)")
            w.server.setUidValidity(Self.epoch + 1, for: Self.path)
            let start = w.server.recordedCommands().count
            await w.slice(clock: clock)
            let loads = Self.headerFetches(w.server.recordedCommands().dropFirst(start))
            #expect(loads.isEmpty, "#1062: no UID of the old numbering is fetched: \(loads)")
            #expect(!(try w.held()).contains(Self.carryMissing[0]), "#1062: nothing loads under the new numbering")
        }
    }

    // MARK: - the load floor between the carry and its resume

    @Test("The load floor changes between the carry and its resume: a range listed with no floor proves only its candidates and holds nothing once a floor is set; a floor that rises loads nothing below it",
          arguments: [false, true])
    @MainActor
    func floorChangeBetweenCarryAndResume(rising: Bool) async throws {
        let server = Self.carryServer
        let below = Self.carryMissing[0]
        try await Self.withWorld("carry-floor-\(rising)", server: server, local: server,
                                 olderMailCursor: rising ? 1 : nil, walkStarted: rising,
                                 rangeMessages: SyncConfig.catchUpListingRangeMessages) { w in
            let folderId = w.folderId
            let clock = CatchUpTestClock()
            var expected = server
            if rising {
                try await w.dropLocal([below])
                try await w.markOwed()
                await w.slice(maxRequests: Self.newListingStartRequests + 2, clock: clock)
                let carried = try #require(try w.catchUpState()?.listing?.carried, "setup: the range is carried")
                #expect(carried.missing == [UInt32(below)] && carried.loadsFrom == 2, "setup: \(below) carried, listed from 2")
                // The walk's cursor moves past it: loads start above it now.
                try await w.pool.write { db in
                    try db.execute(sql: "UPDATE folder SET backfillUidCursor = ? WHERE id = ?", arguments: [below + 5, folderId])
                }
                expected = server.filter { $0 != below }
            } else {
                // A local row the server no longer holds is a candidate, so the
                // range owes a proof with no floor set.
                let gone = 7
                w.server.setMessages(server.filter { $0 != gone }.map(Self.message), in: Self.path)
                try await w.dropLocal([below])
                try await w.markOwed()
                #expect(CatchUpWindowFloor.read(try w.folder().catchUpState, epoch: Self.epoch) == nil, "setup: no load floor yet")
                await w.slice(maxRequests: Self.newListingStartRequests + 1, clock: clock)
                let carried = try #require(try w.catchUpState()?.listing?.carried, "setup: the range is carried")
                #expect(carried.loadsFrom == nil && carried.candidates == [UInt32(gone)] && !carried.proven,
                        "setup: listed with no floor, its proof owed")
                try await w.pool.write { db in try SyncEngine.recordCatchUpWindowFloor(folderId: folderId, lowest: 1, epoch: Self.epoch, db: db) }
                expected = server.filter { $0 != gone && $0 != below }
            }
            let start = w.server.recordedCommands().count
            await w.slice(clock: clock)
            let listing = try w.catchUpState()?.listing
            #expect(listing?.loadHeldSince == nil && listing?.passedOver != true,
                    "#1062: nothing in the carried range is held: \(String(describing: listing))")
            let loaded = Self.headerFetches(w.server.recordedCommands().dropFirst(start)).filter { Self.uidSet($0).contains(below) }
            #expect(loaded.isEmpty, "#1062: nothing below the range's floor is loaded: \(loaded)")
            try w.expectHeldExactly(expected, "#1062 floor \(rising ? "rises" : "set after the listing")")
        }
    }

    // MARK: - the budget stop before an unanswered UID's SEARCH

    @Test("The budget runs out after a load batch and before the SEARCH for a UID it did not answer: that SEARCH is carried, the next slice asks only it, and no range is listed twice")
    @MainActor
    func budgetStopBeforeTheUnansweredSearchIsCarried() async throws {
        let server = Self.carryServer
        let expunged = Self.carryMissing[0]
        try await Self.withWorld("carry-unanswered", server: server, local: server,
                                 rangeMessages: SyncConfig.catchUpListingRangeMessages) { w in
            try await w.dropLocal(Self.carryMissing)
            try await w.markOwed()
            let clock = CatchUpTestClock()
            let start = w.server.recordedCommands().count
            await w.slice(maxRequests: Self.newListingStartRequests + 2, clock: clock)
            #expect(try w.catchUpState()?.listing?.carried?.missing == [UInt32(expunged)], "setup: its load is carried")
            let expected = server.filter { $0 != expunged }
            w.server.setMessages(expected.map(Self.message), in: Self.path)
            // One request: the load batch, which does not answer the expunged UID.
            await w.slice(maxRequests: 1, clock: clock)
            let afterStop = try w.catchUpState()?.listing
            let carried = afterStop?.carried
            #expect(carried?.unanswered == [UInt32(expunged)] && carried?.missing.isEmpty == true,
                    "#1062: the SEARCH the budget left is carried: \(String(describing: carried))")
            // A budget stop is not a failed request: it starts no hold, so the
            // carried SEARCH is never passed over however long the next slice waits.
            #expect(afterStop?.loadHeldSince == nil && afterStop?.passedOver != true,
                    "#1062: the budget stop holds nothing: \(String(describing: afterStop))")
            let slices = try await Self.slicesUntilRepaired(w, expected: expected, maxRequests: 1, clock: clock,
                                                            bound: 2 * (Self.carryRequestsNeeded + 1))
            #expect(slices <= Self.carryRequestsNeeded + 1, "#1062: converges within the bound: \(slices)")
            try w.expectHeldExactly(expected, "#1062 unanswered SEARCH carried")
            let commands = Array(w.server.recordedCommands().dropFirst(start))
            let asked = Self.listingRanges(commands)
            #expect(Set(asked.map(\.lowerBound)).count == asked.count, "#1062: no range is listed again: \(asked)")
            let fetchedTwice = Self.headerFetches(commands).filter { Self.uidSet($0).contains(expunged) }
            #expect(fetchedTwice.count == 1, "#1062: the expunged UID's header is asked once: \(fetchedTwice)")
        }
    }

    // MARK: - a carry over several load batches

    @Test("A range whose missing UIDs need several load batches, one request per slice: each slice loads one batch of the carry, no range is listed twice and no batch is asked twice")
    @MainActor
    func carrySpanningSeveralLoadBatches() async throws {
        let server = Self.carryServer
        let size = SyncConfig.catchUpLoadBatchSize
        let missing = Array(101...(100 + 2 * size + size / 4))
        try await Self.withWorld("carry-batches", server: server, local: server,
                                 rangeMessages: SyncConfig.catchUpListingRangeMessages) { w in
            try await w.dropLocal(missing)
            try await w.markOwed()
            let clock = CatchUpTestClock()
            let start = w.server.recordedCommands().count
            let batches = (missing.count + size - 1) / size
            let bound = Self.carryRequestsNeeded + batches + 1
            let slices = try await Self.slicesUntilRepaired(w, expected: server, maxRequests: 1, clock: clock, bound: 2 * bound)
            #expect(slices <= bound, "#1062: converges within \(bound) slices: \(slices)")
            try w.expectHeldExactly(server, "#1062 several batches")
            let commands = Array(w.server.recordedCommands().dropFirst(start))
            let asked = Self.listingRanges(commands)
            #expect(Set(asked.map(\.lowerBound)).count == asked.count, "#1062: no range is listed again: \(asked)")
            #expect(Self.headerFetches(commands).count == batches,
                    "#1062: \(batches) load batches, each asked once: \(Self.headerFetches(commands).count)")
        }
    }

    // MARK: - one request per call, owed folder (#1062)

    @Test("An owed folder, one request per call: the listing completes within a bounded number of calls and never asks a UID above the server's top")
    @MainActor
    func owedFolderOneRequestPerCallStaysUnderTheTop() async throws {
        let server = Self.carryServer
        let top = try #require(server.last)
        try await Self.withWorld("carry-one-request-top", server: server, local: server,
                                 rangeMessages: SyncConfig.catchUpListingRangeMessages) { w in
            try await w.dropLocal(Self.carryMissing)
            try await w.markOwed()
            let clock = CatchUpTestClock()
            let start = w.server.recordedCommands().count
            // The listing's UIDNEXT read, every request of the repair, and one
            // call that finds the listing complete.
            let bound = Self.carryRequestsNeeded + 2
            let slices = try await Self.slicesUntilRepaired(w, expected: server, maxRequests: 1, clock: clock, bound: 2 * bound)
            #expect(slices <= bound, "#1062: one request per call converges within \(bound) calls: \(slices)")
            try w.expectHeldExactly(server, "#1062 one request per call")
            let asked = Self.listingRanges(Array(w.server.recordedCommands().dropFirst(start)))
            let above = asked.filter { $0.upperBound > top }
            #expect(above.isEmpty, "#1062: no listing range asks above the server's top \(top): \(above)")
        }
    }

    @Test("An owed folder whose top falls inside a listing range, one request per call: the last range is cut at the server's top and no range asks above it")
    @MainActor
    func topInsideARangeCutsTheLastRange() async throws {
        // A top half a range past a range boundary, so a range of the full width
        // would end above it.
        let span = SyncConfig.catchUpListingMinRangeSpan
        let server = Array(1...(2 * span + span / 2))
        let top = try #require(server.last)
        let missing = [5, top - 5]
        try await Self.withWorld("carry-top-inside-a-range", server: server, local: server,
                                 rangeMessages: SyncConfig.catchUpListingRangeMessages) { w in
            try await w.dropLocal(missing)
            try await w.markOwed()
            let clock = CatchUpTestClock()
            let start = w.server.recordedCommands().count
            // Per range its listing FETCH, its membership SEARCH and one header
            // batch; the listing's UIDNEXT read; one call that finds it complete.
            let ranges = (server.count + span - 1) / span
            let bound = 3 * ranges + 2
            let slices = try await Self.slicesUntilRepaired(w, expected: server, maxRequests: 1, clock: clock, bound: 2 * bound)
            #expect(slices <= bound, "#1062: one request per call converges within \(bound) calls: \(slices)")
            try w.expectHeldExactly(server, "#1062 top inside a range")
            let asked = Self.listingRanges(Array(w.server.recordedCommands().dropFirst(start)))
            let above = asked.filter { $0.upperBound > top }
            let lastUpper = asked.last?.upperBound
            #expect(above.isEmpty, "#1062: no listing range asks above the server's top \(top): \(above)")
            #expect(lastUpper == top, "#1062: the last range ends at the server's top \(top): \(asked)")
        }
    }

    @Test("The server's UIDNEXT grows during an owed folder's listing: the arrivals are listed and loaded, and no range asks above the top the server had when it was asked")
    @MainActor
    func topGrowsDuringTheListing() async throws {
        let server = Self.carryServer
        let firstTop = try #require(server.last)
        let arrivals = Array((firstTop + 1)...(firstTop + SyncConfig.catchUpListingMinRangeSpan / 2))
        try await Self.withWorld("carry-top-grows", server: server, local: server,
                                 rangeMessages: SyncConfig.catchUpListingRangeMessages) { w in
            try await w.dropLocal(Self.carryMissing)
            try await w.markOwed()
            let clock = CatchUpTestClock()
            let start = w.server.recordedCommands().count
            // The listing's start (its UIDNEXT read) and the first range: the
            // listing has its top.
            await w.slice(maxRequests: Self.newListingStartRequests + 1, clock: clock)
            #expect(try w.catchUpState()?.listing != nil, "setup: the listing is in progress")
            let beforeArrivals = w.server.recordedCommands().count
            w.server.setMessages(w.server.messages(in: Self.path) + arrivals.map { Self.message($0) }, in: Self.path)
            let all = server + arrivals
            // Every request of the carry repair, the arrivals' range (its listing
            // FETCH and membership SEARCH), one call per load batch of the
            // arrivals, and a slack of two calls: the call that finds the listing
            // complete and one more range cut at the grown top.
            let arrivalBatches = (arrivals.count + SyncConfig.catchUpLoadBatchSize - 1) / SyncConfig.catchUpLoadBatchSize
            let bound = Self.carryRequestsNeeded + 2 + arrivalBatches + 2
            var before = (held: try w.held().count, listing: try w.catchUpState()?.listing?.withoutWidthCap)
            let slices = try await Self.slicesUntilRepaired(w, expected: all, maxRequests: 1, clock: clock, bound: 2 * bound) {
                let after = (held: try w.held().count, listing: try w.catchUpState()?.listing?.withoutWidthCap)
                #expect(after.held > before.held || after.listing != before.listing,
                        "#1062: every call loads a message or moves the listing: \(String(describing: before.listing)) -> \(String(describing: after.listing))")
                before = after
            }
            #expect(slices <= bound, "#1062: the listing completes within \(bound) calls: \(slices)")
            try w.expectHeldExactly(all, "#1062 top grows")
            let commands = w.server.recordedCommands()
            let early = Self.listingRanges(Array(commands[start..<beforeArrivals])).filter { $0.upperBound > firstTop }
            let late = Self.listingRanges(Array(commands.dropFirst(beforeArrivals))).filter { $0.upperBound > all.count }
            #expect(early.isEmpty && late.isEmpty, "#1062: no range above the live top: \(early) \(late)")
        }
    }

    @Test("A server whose SELECT omits UIDNEXT: an owed folder's listing stores no top, lists nothing above the last local UID, completes not clean so the owed mark stays, and is listed at most once per daily check")
    @MainActor
    func unknownTopKeepsTheFolderOwed() async throws {
        let server = Self.carryServer
        let missing = Array((server.count - 5)...server.count)
        let lastLocal = server.count - missing.count
        try await Self.withWorld("carry-no-uidnext", server: server, local: server,
                                 rangeMessages: SyncConfig.catchUpListingRangeMessages) { w in
            try await w.dropLocal(missing)
            try await w.markOwed()
            w.server.suppressSelectUidNext(for: Self.path)
            defer { w.server.restoreSelectUidNext(for: Self.path) }
            let clock = CatchUpTestClock()
            let start = w.server.recordedCommands().count
            var listingRuns = 0
            for _ in 0..<3 {
                let before = w.server.recordedCommands().count
                await w.slice(clock: clock)
                #expect(try w.catchUpState()?.listing?.top == nil, "#1062: no top is stored on an unknown UIDNEXT")
                if !Self.listingRanges(Array(w.server.recordedCommands().dropFirst(before))).isEmpty { listingRuns += 1 }
            }
            #expect(listingRuns == 1, "#1062: the first listing runs and completes, and no other before the daily check: \(listingRuns)")
            #expect(try w.catchUpState()?.listing == nil, "#1062: the first listing completed")
            #expect((try w.changeState()).selfHealDue, "#1062: an unknown top never settles the owed mark")
            let asked = Self.listingRanges(Array(w.server.recordedCommands().dropFirst(start)))
            let above = asked.filter { $0.upperBound > lastLocal }
            #expect(above.isEmpty, "#1062: nothing above the last local UID \(lastLocal) is listed: \(above)")
            #expect(asked.contains { $0.upperBound == lastLocal }, "#1062: the listing reaches the last local UID \(lastLocal): \(asked)")
            try w.expectNotHeld(missing, "#1062: nothing is loaded above an unknown top")
            // The daily check lists it once more, still unsettled.
            clock.advance(by: Self.pastTheNextCheck)
            let dayStart = w.server.recordedCommands().count
            await w.slice(clock: clock)
            #expect(!Self.listingRanges(Array(w.server.recordedCommands().dropFirst(dayStart))).isEmpty,
                    "#1062: the daily check lists the folder again")
            #expect((try w.changeState()).selfHealDue, "#1062: still owed after the daily listing")
        }
    }

    /// Whether `commands` hold a SELECT and no UID command: a call that only read UIDNEXT.
    static func onlyReadUidNext(_ commands: some Collection<String>) -> Bool {
        let upper = commands.map { $0.uppercased() }
        return upper.contains { $0.contains("SELECT") } && !upper.contains { $0.contains("UID ") }
    }

    @Test("A server whose SELECT omits UIDNEXT: a folder not owed a check, at its daily check, reads UIDNEXT, lists up to its highest local UID and gets its flag changes and removals")
    @MainActor
    func unknownTopStillReconcilesFlagsAndRemovals() async throws {
        let flagged = 20, expunged = 21
        let server = Array(1...40)
        let highest = try #require(server.last)
        try await Self.withWorld("no-uidnext-flags", server: server, local: server) { w in
            w.server.suppressSelectUidNext(for: Self.path)
            defer { w.server.restoreSelectUidNext(for: Self.path) }
            w.server.setMessages(server.filter { $0 != expunged }.map { Self.message($0) }, in: Self.path)
            w.server.setFlags(["\\Seen"], in: Self.path, uid: flagged)
            let clock = CatchUpTestClock()
            // The setup's run completed the folder's listing: the next one is the daily check.
            clock.advance(by: Self.pastTheNextCheck)
            let start = w.server.recordedCommands().count
            await w.slice(clock: clock)
            let commands = Array(w.server.recordedCommands().dropFirst(start)).map { $0.uppercased() }
            let firstSelect = commands.firstIndex { $0.contains("SELECT") }
            let firstUid = commands.firstIndex { $0.contains("UID ") }
            #expect(firstSelect != nil && firstUid.map { firstSelect! < $0 } != false,
                    "#1062: the call's first request is the UIDNEXT-only read, before any UID command")
            #expect(try w.catchUpState()?.listing == nil, "#1062: the listing completed, with no top stored")
            let asked = Self.listingRanges(commands)
            #expect(asked.contains { $0.upperBound == highest }, "#1062: a listing range was sent, up to the highest local UID: \(asked)")
            let folderId = w.folderId
            let isRead = try await w.pool.read { db in
                try Bool.fetchOne(db, sql: "SELECT isRead FROM messageHeader WHERE folderId = ? AND messageId = ?",
                                  arguments: [folderId, "\(flagged)"])
            }
            #expect(isRead == true, "#1062: the flag change is applied under an unknown top")
            try w.expectHeldExactly(server.filter { $0 != expunged }, "#1062: the removal is applied under an unknown top")
        }
    }

    @Test("A server whose SELECT omits UIDNEXT, a folder with a load floor and no local rows: the listing completes in one call, sends no range and leaves the folder owed")
    @MainActor
    func unknownTopWithNoLocalRowsCompletesAtOnce() async throws {
        let server = Array(1...40)
        try await Self.withWorld("no-uidnext-empty", server: server, local: server) { w in
            try await w.dropLocal(server)
            try await w.markOwed()
            w.server.suppressSelectUidNext(for: Self.path)
            defer { w.server.restoreSelectUidNext(for: Self.path) }
            let clock = CatchUpTestClock()
            let start = w.server.recordedCommands().count
            await w.slice(clock: clock)
            let asked = Self.listingRanges(Array(w.server.recordedCommands().dropFirst(start)))
            #expect(asked.isEmpty, "#1062: no range is listed with no local rows and an unknown top: \(asked)")
            #expect(try w.catchUpState()?.listing == nil, "#1062: the listing completed in one call")
            #expect((try w.changeState()).selfHealDue, "#1062: the folder stays owed")
        }
    }

    @Test("A server whose SELECT omits UIDNEXT: a listing that read it, then lost every local row before its next call, completes in that call, sends no range and leaves the folder owed")
    @MainActor
    func unknownTopListingWhoseLocalRowsGoCompletesAtOnce() async throws {
        let server = Array(1...40)
        try await Self.withWorld("no-uidnext-rows-go", server: server, local: server) { w in
            try await w.markOwed()
            w.server.suppressSelectUidNext(for: Self.path)
            defer { w.server.restoreSelectUidNext(for: Self.path) }
            let clock = CatchUpTestClock()
            // The first call reads UIDNEXT and has no budget left for a range.
            await w.slice(maxRequests: Self.newListingStartRequests, clock: clock)
            let started = try w.catchUpState()?.listing
            #expect(started?.topUnknown == true, "setup: the listing goes on with an unknown top: \(String(describing: started))")
            try await w.dropLocal(server)
            let start = w.server.recordedCommands().count
            await w.slice(clock: clock)
            let asked = Self.listingRanges(Array(w.server.recordedCommands().dropFirst(start)))
            #expect(asked.isEmpty, "#1062: with an unknown top and no local row left, no range is listed: \(asked)")
            #expect(try w.catchUpState()?.listing == nil, "#1062: the listing completed in that call")
            #expect((try w.changeState()).selfHealDue, "#1062: the folder stays owed")
        }
    }

    @Test("A server whose SELECT omits UIDNEXT, one request per call: the listing reads UIDNEXT exactly once, still lists its ranges, loads what is missing up to the last local UID and completes, not clean")
    @MainActor
    func unknownTopOneRequestPerCallCompletes() async throws {
        let server = Self.carryServer
        try await Self.withWorld("no-uidnext-one-request", server: server, local: server,
                                 rangeMessages: SyncConfig.catchUpListingRangeMessages) { w in
            try await w.dropLocal(Self.carryMissing.filter { $0 < server.count })
            try await w.markOwed()
            w.server.suppressSelectUidNext(for: Self.path)
            defer { w.server.restoreSelectUidNext(for: Self.path) }
            let clock = CatchUpTestClock()
            let bound = Self.carryRequestsNeeded + 2
            var calls = 0, uidNextReads = 0
            while try w.held() != server || w.catchUpState()?.listing != nil, calls < 2 * bound {
                let before = w.server.recordedCommands().count
                await w.slice(maxRequests: 1, clock: clock)
                calls += 1
                if Self.onlyReadUidNext(w.server.recordedCommands().dropFirst(before)) { uidNextReads += 1 }
            }
            #expect(calls <= bound, "#1062: one request per call completes within \(bound) calls: \(calls)")
            #expect(uidNextReads == 1, "#1062: one UIDNEXT read per listing: \(uidNextReads)")
            try w.expectHeldExactly(server, "#1062 unknown top, one request per call")
            #expect((try w.changeState()).selfHealDue, "#1062: completed not clean: the owed mark stays")
        }
    }

    @Test("A listing that began with an unknown top, then a SELECT reports UIDNEXT: the top is stored, the listing goes on to it and loads the mail above the last local UID, and completes not clean")
    @MainActor
    func laterUidNextStoresTheTopButStaysUnclean() async throws {
        let server = Self.carryServer
        let missing = Array((server.count - 5)...server.count)
        try await Self.withWorld("no-uidnext-then-uidnext", server: server, local: server,
                                 rangeMessages: SyncConfig.catchUpListingRangeMessages) { w in
            try await w.dropLocal(missing)
            try await w.markOwed()
            let clock = CatchUpTestClock()
            w.server.suppressSelectUidNext(for: Self.path)
            // The listing's one UIDNEXT read reports none.
            await w.slice(maxRequests: 1, clock: clock)
            #expect(try w.catchUpState()?.listing?.topUnknown == true, "setup: the top is unknown")
            w.server.restoreSelectUidNext(for: Self.path)
            var storedTop: Int?
            var calls = 0
            let bound = Self.carryRequestsNeeded + 2
            while try w.catchUpState()?.listing != nil, calls < 2 * bound {
                await w.slice(maxRequests: 1, clock: clock)
                calls += 1
                if let top = try w.catchUpState()?.listing?.top { storedTop = top }
            }
            #expect(storedTop == server.last, "#1062: a later SELECT's UIDNEXT is stored as the top: \(String(describing: storedTop))")
            try w.expectHeldExactly(server, "#1062: the mail above the last local UID loads once the top is known")
            #expect((try w.changeState()).selfHealDue, "#1062: a listing that began on an unknown top completes not clean")
        }
    }

    // MARK: - a carried listing on a slow link (#1062)

    /// One call whose slice is shorter than one request: time is left until the
    /// call's first UID request goes out, and spent from then on.
    @MainActor
    static func callSpentByItsFirstRequest(_ w: World) async {
        await AccountManager.shared.clearRecentlyCompletedForTesting()
        let server = w.server
        let start = server.recordedCommands().count
        let opened = Date()
        let context = CatchUpContext(
            deadline: opened.addingTimeInterval(1),
            clock: {
                let sent = server.recordedCommands().dropFirst(start).contains { $0.uppercased().contains("UID ") }
                return sent ? opened.addingTimeInterval(2) : opened
            },
            listingRangeMessages: w.rangeMessages)
        await w.engine.runCatchUp(provider: w.provider, folderIds: [w.folderId], context: context)
    }

    @Test("A carried listing on a slow link whose slice is shorter than one request: it completes within a bounded number of calls, and a call that moves nothing never widens the width cap")
    @MainActor
    func carriedListingOnASlowLinkCompletes() async throws {
        let server = Self.carryServer
        try await Self.withWorld("carry-slow-link", server: server, local: server,
                                 rangeMessages: SyncConfig.catchUpListingRangeMessages) { w in
            try await w.dropLocal(Self.carryMissing)
            try await w.markOwed()
            // A cap from earlier timeouts, so a call that answers a range raises it.
            try await Self.setListing(w, nextUid: 1, rangeWidth: SyncConfig.catchUpListingMinRangeSpan,
                                      widthCap: SyncConfig.catchUpListingMinRangeSpan)
            let bound = Self.carryRequestsNeeded + 2
            var calls = 0
            while try w.held() != server || w.catchUpState()?.listing != nil, calls < 2 * bound {
                let before = try w.catchUpState()?.listing
                let heldBefore = try w.held()
                await Self.callSpentByItsFirstRequest(w)
                calls += 1
                let after = try w.catchUpState()?.listing
                guard let after, after.withoutWidthCap == before?.withoutWidthCap, try w.held() == heldBefore else { continue }
                let capBefore = before?.widthCap ?? Int.max, capAfter = after.widthCap ?? Int.max
                #expect(capAfter <= capBefore, "#1062: a call that moved nothing widened the cap: \(capBefore) -> \(capAfter)")
            }
            #expect(calls <= bound, "#1062: the carried listing completes within \(bound) calls: \(calls)")
            try w.expectHeldExactly(server, "#1062 slow link")
        }
    }

    // MARK: - a held UID inside a carry

    @Test("A held UID inside a carried range keeps its first hold start across slices that load the rest of the carry; if another path writes its row meanwhile, the hold is dropped with its clock, and the next UID that fails, after the old hold's bound, gets a hold of its own instead of being passed over",
          arguments: [false, true])
    @MainActor
    func heldUidInsideACarry(resolvedElsewhere: Bool) async throws {
        let server = Self.carryServer
        let size = SyncConfig.catchUpLoadBatchSize
        let unreadable = 5
        let missing = Array(unreadable...(unreadable + 3 * size + 5))
        try await Self.withWorld("carry-held-\(resolvedElsewhere)", server: server, local: server,
                                 rangeMessages: SyncConfig.catchUpListingRangeMessages) { w in
            let folderId = w.folderId
            try await w.pool.write { db in
                try db.execute(sql: "CREATE TEMP TABLE keptHeldRow AS SELECT * FROM messageHeader WHERE folderId = ? AND messageId = ?",
                               arguments: [folderId, "\(unreadable)"])
            }
            var messages = server.map(Self.message)
            messages[server.firstIndex(of: unreadable)!] = Self.message(unreadable, date: "not a date")
            w.server.setMessages(messages, in: Self.path)
            w.server.suppressFetchInternalDate(in: Self.path, uids: [unreadable])
            try await w.dropLocal(missing)
            try await w.markOwed()
            let clock = CatchUpTestClock()
            // The listing, its proof, the first batch and the SEARCH that finds
            // the unreadable UID still on the server: held, the rest carried.
            await w.slice(maxRequests: Self.newListingStartRequests + 4, clock: clock)
            let first = try #require(try w.catchUpState()?.listing, "setup: the listing goes on")
            let holdStart = try #require(first.loadHeldSince, "setup: the unreadable UID is held")
            #expect(first.nextUid == unreadable && first.carried?.heldFloor == UInt32(unreadable),
                    "setup: held at \(unreadable), carried: \(String(describing: first.carried))")
            clock.advance(by: SyncConfig.backfillPageHoldMinutes * 60 / 2)
            if resolvedElsewhere {
                try await w.pool.write { db in try db.execute(sql: "INSERT INTO messageHeader SELECT * FROM keptHeldRow") }
            }
            // One request: the next batch; the budget stops before the one after.
            await w.slice(maxRequests: 1, clock: clock)
            let second = try #require(try w.catchUpState()?.listing, "setup: the listing goes on")
            if resolvedElsewhere {
                #expect(second.nextUid != unreadable && second.carried?.heldFloor == nil,
                        "#1062: a held UID now local is held no longer: \(String(describing: second))")
                #expect(second.loadHeldSince == nil,
                        "#1062: the hold clock belongs to the held UID and goes with it, never to the UID the cursor moved to: \(String(describing: second.loadHeldSince))")
                // Past the old hold's bound, the next header load fails: the UID
                // the cursor now names is held from now, not passed over on the
                // old hold's clock.
                clock.advance(by: SyncConfig.backfillPageHoldMinutes * 60)
                w.server.failNextCommand(containing: "ENVELOPE")
                await w.slice(maxRequests: 1, clock: clock)
                let third = try #require(try w.catchUpState()?.listing, "setup: the listing goes on")
                #expect(third.passedOver != true && third.nextUid == second.nextUid && third.loadHeldSince == clock.now,
                        "#1062: the failed UID gets a hold of its own: \(String(describing: third))")
            } else {
                #expect(second.loadHeldSince == holdStart && second.nextUid == unreadable,
                        "#1062: the hold keeps its first start across the carry: \(String(describing: second.loadHeldSince)) vs \(holdStart)")
                #expect(second.carried?.heldFloor == UInt32(unreadable), "#1062: the carry still names the held UID")
            }
            let expected = resolvedElsewhere ? server : server.filter { $0 != unreadable }
            let bound = Self.carryRequestsNeeded + missing.count / size + 2
            let slices = try await Self.slicesUntilRepaired(w, expected: expected, maxRequests: 1, clock: clock, bound: 2 * bound) {
                clock.advance(by: SyncConfig.backfillPageHoldMinutes * 60)
            }
            #expect(slices <= bound, "#1062: converges within \(bound) slices: \(slices)")
            try w.expectHeldExactly(expected, "#1062 held UID in a carry")
        }
    }

    @Test("A hold started by a failed membership proof keeps its start when the next call proves the range and its budget stops before the header load of that same UID; past the first hold's bound, a failed load there is passed over, not held anew")
    @MainActor
    func budgetStopOnTheHeldUidKeepsItsHoldClock() async throws {
        let server = Self.carryServer
        let first = 1
        try await Self.withWorld("carry-same-uid-hold", server: server, local: server,
                                 rangeMessages: SyncConfig.catchUpListingRangeMessages) { w in
            try await w.dropLocal([first])
            try await w.markOwed()
            let clock = CatchUpTestClock()
            let holdSeconds = SyncConfig.backfillPageHoldMinutes * 60
            // The listing, then its membership proof fails: the range is held
            // from its first UID, which is the missing one.
            w.server.failNextCommand(containing: "SEARCH")
            await w.slice(maxRequests: Self.newListingStartRequests + 2, clock: clock)
            let held = try #require(try w.catchUpState()?.listing, "setup: the listing goes on")
            let holdStart = try #require(held.loadHeldSince, "setup: the failed proof holds the range")
            #expect(held.nextUid == first && held.carried?.lo == first && held.carried?.proven == false,
                    "setup: held at the range's first UID \(first), the missing one, carried unproven: \(String(describing: held))")
            // One request: the proof answers; the budget stops before the header
            // load of the same UID, with no UID held.
            clock.advance(by: holdSeconds / 2)
            await w.slice(maxRequests: 1, clock: clock)
            let stopped = try #require(try w.catchUpState()?.listing, "setup: the listing goes on")
            #expect(stopped.carried?.proven == true && stopped.carried?.missing == [UInt32(first)] && stopped.nextUid == first,
                    "setup: proven, the load of \(first) carried: \(String(describing: stopped))")
            #expect(stopped.loadHeldSince == holdStart,
                    "#1062: a budget stop on the UID already held keeps its hold start: \(String(describing: stopped.loadHeldSince)) vs \(holdStart)")
            // Past the first hold's bound, the header load fails.
            clock.advance(by: holdSeconds)
            w.server.failNextCommand(containing: "ENVELOPE")
            await w.slice(maxRequests: 1, clock: clock)
            let after = try #require(try w.catchUpState()?.listing, "setup: the listing goes on")
            #expect(after.passedOver == true,
                    "#1062: past the first hold's bound the UID is passed over, not held anew: \(String(describing: after))")
        }
    }

    // MARK: - a failed request on a carried range

    /// Which request of a carried range fails.
    enum CarriedRequestFails: String, CaseIterable, Sendable {
        /// The membership SEARCH of a range carried unproven.
        case proof
        /// The header load of a range carried proven.
        case load
    }

    @Test("A request of a carried range fails (its proof SEARCH, or its header load): the range stays carried, the retry asks only what failed, and the range is never listed again",
          arguments: CarriedRequestFails.allCases)
    @MainActor
    func failedRequestKeepsTheCarry(_ fails: CarriedRequestFails) async throws {
        let server = Self.carryServer
        let missing = Self.carryMissing[0]
        try await Self.withWorld("carry-fails-\(fails.rawValue)", server: server, local: server,
                                 rangeMessages: SyncConfig.catchUpListingRangeMessages) { w in
            try await w.dropLocal([missing])
            try await w.markOwed()
            let clock = CatchUpTestClock()
            let start = w.server.recordedCommands().count
            await w.slice(maxRequests: Self.newListingStartRequests + (fails == .proof ? 1 : 2), clock: clock)
            let carried = try #require(try w.catchUpState()?.listing?.carried, "setup: the range is carried")
            #expect(carried.proven == (fails == .load) && carried.missing == [UInt32(missing)], "setup: \(carried)")
            w.server.failNextCommand(containing: fails == .proof ? "SEARCH" : "ENVELOPE")
            await w.slice(clock: clock)
            let kept = try w.catchUpState()?.listing?.carried
            #expect(kept?.lo == carried.lo && kept?.missing == [UInt32(missing)],
                    "#1062: the failed request leaves the range carried: \(String(describing: kept))")
            _ = try await Self.slicesUntilRepaired(w, expected: server, maxRequests: .max, clock: clock, bound: 4)
            try w.expectHeldExactly(server, "#1062 carried request fails (\(fails.rawValue))")
            let asked = Self.listingRanges(w.server.recordedCommands().dropFirst(start))
            #expect(asked.filter { $0.lowerBound == carried.lo }.count == 1, "#1062: the carried range is listed once: \(asked)")
        }
    }

    // MARK: - a carried candidate gone before the resume

    @Test("A carried range's only candidate loses its local row before the resume, with no load floor: the range needs no proof and the resume sends no SEARCH")
    @MainActor
    func candidateGoneBeforeTheResumeNeedsNoProof() async throws {
        let server = Self.carryServer
        let gone = 7
        try await Self.withWorld("carry-candidate", server: server, local: server, walkStarted: false,
                                 rangeMessages: SyncConfig.catchUpListingRangeMessages) { w in
            w.server.setMessages(server.filter { $0 != gone }.map(Self.message), in: Self.path)
            try await w.markOwed()
            let clock = CatchUpTestClock()
            await w.slice(maxRequests: Self.newListingStartRequests + 1, clock: clock)
            let carried = try #require(try w.catchUpState()?.listing?.carried, "setup: the range is carried")
            #expect(carried.candidates == [UInt32(gone)] && carried.loadsFrom == nil, "setup: \(carried)")
            try await w.dropLocal([gone])
            let start = w.server.recordedCommands().count
            await w.slice(clock: clock)
            let commands = Array(w.server.recordedCommands().dropFirst(start))
            let firstListing = commands.firstIndex { !Self.listingRanges([$0]).isEmpty } ?? commands.endIndex
            let searches = Self.listingCost(commands[..<firstListing]).searches
            #expect(searches == 0, "#1062: a candidate no longer local is proven no more: \(searches) SEARCH(es)")
        }
    }
}
