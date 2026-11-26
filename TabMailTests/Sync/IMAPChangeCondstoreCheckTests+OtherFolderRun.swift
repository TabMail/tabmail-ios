/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Testing
@testable import TabMail

// MARK: - The removal check in a slice of an other-folder run (#1110)

/// A slice of an other-folder run takes at most one step of the CONDSTORE
/// removal check (the proof, or one window chunk's SEARCH), started only while
/// the slice has time, each request bounded by the run's request limit. The
/// progress rides in the bookmark the engine stores, and later slices take the
/// next steps. Each slice here is read as the engine reads it (the stored
/// bookmark and rows) and applied as the engine applies it
/// (`SyncEngine.applyFolderChanges`).
extension IMAPChangeCondstoreCheckTests {

    /// Most slices a run's check is given here before it counts as stuck.
    static let runSliceCap = 10

    /// A slice of an other-folder run on a clock that stands still, with room
    /// for every step of the check at the run's request limit: only the
    /// one-step rule can end the check's work inside the slice.
    static func roomySlice(_ clock: IMAPChangeEngineTests.StillClock) -> ChangeContext {
        let room = SyncConfig.catchUpRequestTimeoutSeconds * 3 * Double(runSliceCap)
        return ChangeContext(deadline: clock.read().addingTimeInterval(room), clock: { clock.read() }, onProgress: { _ in })
    }

    /// The device's store of the world's Inbox as the engine keeps it: the
    /// folder with its bookmark, and its rows.
    struct Store: Sendable {
        let pool: DatabasePool
        let folderId: String

        func bookmark() async throws -> String? {
            let folderId = folderId
            return try await pool.read { db in
                try String.fetchOne(db, sql: "SELECT changeCursor FROM folder WHERE id = ?", arguments: [folderId])
            }
        }

        /// The removal check's progress the stored bookmark carries.
        func progress() async throws -> IMAPRemovalCheckProgress? {
            let raw = try await bookmark()
            return IMAPChangeCursor.decode(raw)?.pendingCheck
        }

        func uids() async throws -> Set<Int> {
            let folderId = folderId
            let ids = try await pool.read { db in
                try String.fetchAll(db, sql: "SELECT messageId FROM messageHeader WHERE folderId = ?", arguments: [folderId])
            }
            return Set(ids.compactMap { Int($0) })
        }
    }

    /// A store holding `uids` in the world's Inbox under `bookmark`, its
    /// older-mail check done a minute ago.
    static func withStore(
        _ w: R.World, uids: [Int], bookmark: String, _ body: (Store) async throws -> Void
    ) async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        _ = try FolderEpochTestFixture.makeAccount(id: w.accountId, provider: .imap, pool: pool)
        try FolderEpochTestFixture.insertFolder(
            accountId: w.accountId, path: R.inboxPath, role: .inbox, pool: pool,
            totalCount: uids.count, lastKnownUidNext: (uids.max() ?? 0) + 1, lastKnownUidValidity: R.epoch)
        try FolderEpochTestFixture.insertHeaders(accountId: w.accountId, path: R.inboxPath, uids: uids, pool: pool)
        let folderId = w.inboxId
        let completed = IMAPCatchUpState(
            epoch: UInt32(R.epoch), completionStamp: nil, lastCompletedAt: Date().addingTimeInterval(-60), listing: nil)
        let state = completed.encoded()
        try await pool.write { db in
            try db.execute(sql: "UPDATE folder SET changeCursor = ?, catchUpState = ? WHERE id = ?",
                           arguments: [bookmark, state, folderId])
        }
        try await body(Store(pool: pool, folderId: folderId))
    }

    /// The request of one slice over the world's Inbox, made as the engine
    /// makes it: the stored bookmark, and the stored rows. `.all` makes a
    /// pass's request over the same store instead.
    static func sliceRequest(
        _ w: R.World, _ store: Store, context: ChangeContext, scope: ChangeScope = .otherFolders
    ) async throws -> ChangeRequest {
        let stored = try await store.bookmark()
        return ChangeRequest(
            folders: R.folders(w, cursors: [w.inboxId: stored]), scope: scope, recheck: [:],
            context: context, localRows: SyncEngineCatchUpRowReader(pool: PrioritizedDatabase(pool: store.pool)))
    }

    /// The Inbox's answer in `set`, applied to the store as the engine applies a slice's.
    static func apply(_ w: R.World, _ set: ChangeSet?, to store: Store) async throws -> FolderChanges {
        let inboxId = w.inboxId
        let found = set?.folders.first { $0.folderId == inboxId }
        let answer = try #require(found, "the slice answers for the Inbox")
        _ = try await store.pool.write { db in try SyncEngine.applyFolderChanges(answer, db: db) }
        return answer
    }

    /// One slice: its read, then its apply. `.all` reads and applies a pass instead.
    static func slice(
        _ w: R.World, _ store: Store, context: ChangeContext, scope: ChangeScope = .otherFolders
    ) async throws -> FolderChanges {
        let request = try await sliceRequest(w, store, context: context, scope: scope)
        let set = try await w.provider.fetchChanges(since: ChangeCursor(account: nil), request: request)
        return try await apply(w, set, to: store)
    }

    /// Whether the check moved exactly one step from `before` (nil: not yet
    /// started) to `after`. A proof clears the candidates and leaves the window
    /// where it was; a chunk moves the window down by at most one chunk's rows.
    static func movedOneStep(from before: IMAPRemovalCheckProgress?, to after: IMAPRemovalCheckProgress) -> Bool {
        if let before, !before.unproven.isEmpty {
            return after.unproven.isEmpty && after.nextBelow == before.nextBelow && after.remaining == before.remaining
        }
        let searched = (before?.remaining ?? SyncConfig.imapChangeRemovalCheckWindow) - after.remaining
        let movedDown = before.map { after.nextBelow < $0.nextBelow } ?? true
        return searched > 0 && searched <= SyncConfig.deletionReconcileChunkSize && movedDown
    }

    /// The requests of a check step among `sent` (upper-cased): a chunk's or a
    /// proof's SEARCH, and a proof's FETCH (the changed-flags FETCH is the
    /// read's own).
    static func stepRequests(_ sent: [String]) -> (searches: Int, fetches: Int) {
        (sent.filter { $0.hasPrefix("UID SEARCH") }.count,
         sent.filter { $0.hasPrefix("UID FETCH") && !$0.contains("CHANGEDSINCE") }.count)
    }

    @Test("A slice of an other-folder run takes one step of the removal check even with room for more: each slice sends one step's requests and the engine stores the check's progress, so later slices finish it with every removal proven; a pass with the same room takes every step at once")
    func otherFolderRunTakesOneCheckStepPerSlice() async throws {
        let held = Array(1...1_500)
        let chunk = SyncConfig.deletionReconcileChunkSize
        let gone: Set<Int> = [100, 900, 1_400]
        let chunksWithACandidate = Set(gone.map { ($0 - 1) / chunk }).count
        #expect(held.count == 3 * chunk && chunksWithACandidate == gone.count,
                "precondition: one gone message in each of three window chunks")
        // Each chunk's SEARCH, then its candidate's proof, then the empty chunk
        // that ends the window.
        let steps = 2 * gone.count + 1
        let goneIds = Set(gone.map(String.init))
        try await C.withWorld(inbox: held) { w in
            let base = try await R.baseline(w)
            C.remove(gone, from: w.server)
            let clock = IMAPChangeEngineTests.StillClock(Date())

            // Control: a pass with the same room takes every step in one read,
            // so only the one-step rule ends a slice's check.
            let pass = try await R.inbox(w, R.read(w, cursors: [w.inboxId: base], context: Self.roomySlice(clock)))
            let passRemovals = Set(pass.removals)
            #expect(R.isTracked(pass.status) && passRemovals == goneIds,
                    "control: a pass with this room finishes the check: \(pass.status), \(pass.removals)")

            try await Self.withStore(w, uids: held, bookmark: base) { store in
                var removed = Set<String>()
                var last: IMAPRemovalCheckProgress?
                var slices = 0
                var finished = false
                while slices < Self.runSliceCap, !finished {
                    slices += 1
                    let before = w.server.recordedCommands().count
                    let read = try await Self.slice(w, store, context: Self.roomySlice(clock))
                    let sent = w.server.recordedCommands().dropFirst(before).map { $0.uppercased() }
                    let step = Self.stepRequests(sent)
                    #expect(step.searches <= 1 && step.fetches <= 1,
                            "slice \(slices): one step's requests, got \(step.searches) SEARCH and \(step.fetches) FETCH: \(sent)")
                    removed.formUnion(read.removals)
                    let stored = try await store.progress()
                    if R.isTracked(read.status) {
                        finished = true
                        #expect(stored == nil, "slice \(slices): the finished check leaves the stored bookmark")
                        continue
                    }
                    guard case .untracked = read.status else {
                        Issue.record("slice \(slices): expected the cut, got \(read.status)")
                        return
                    }
                    guard let stored else {
                        Issue.record("slice \(slices): the engine stores the check's progress")
                        return
                    }
                    let oneStep = Self.movedOneStep(from: last, to: stored)
                    #expect(oneStep, "slice \(slices): the stored progress moved one step: \(String(describing: last)) to \(stored)")
                    last = stored
                }
                #expect(finished && slices == steps, "one slice per step: \(slices) slices for \(steps) steps")
                #expect(removed == goneIds, "every removal proven, nothing else: \(removed.sorted())")
                let kept = try await store.uids()
                #expect(kept == Set(held).subtracting(gone), "the store keeps every live row and none gone")
            }
        }
    }

    @Test("A run's check step starts only while its slice has time, and each request waits at most the run's request limit: a slice whose time ran out takes no step and the stored progress stays; a step the server does not answer fails the folder at the limit, the progress stays, and the next slice takes it")
    func aRunsCheckStepIsBoundedByItsSliceAndItsRequestLimit() async throws {
        let held = Array(1...10)
        let candidate = 4
        try await C.withWorld(inbox: held) { w in
            // One chunk is the whole window: after its SEARCH only the proof is left.
            await w.provider.setRemovalCheckWindowForTesting(held.count)
            let base = try await R.baseline(w)
            C.remove([candidate], from: w.server)
            let clock = IMAPChangeEngineTests.StillClock(Date())
            try await Self.withStore(w, uids: held, bookmark: base) { store in
                _ = try await Self.slice(w, store, context: Self.roomySlice(clock))
                let found = try await store.progress()
                #expect(found?.unproven == [UInt32(candidate)] && found?.remaining == 0,
                        "precondition: the chunk found the candidate and only its proof is left: \(String(describing: found))")
                guard let found else { return }

                // The slice's time runs out while the server answers its changed-flags read.
                let late = Self.roomySlice(clock)
                let request = try await Self.sliceRequest(w, store, context: late)
                let provider = w.provider
                let changedFlags = "CHANGEDSINCE"
                w.server.holdNextCommand(containing: changedFlags)
                let read = Task { try await provider.fetchChanges(since: ChangeCursor(account: nil), request: request) }
                guard await OneSyncAtATimeTests.eventually({ w.server.isHoldingCommand(containing: changedFlags) }) else {
                    Issue.record("precondition: the slice's changed-flags read is held")
                    w.server.releaseHeldCommand(containing: changedFlags)
                    _ = await read.result
                    return
                }
                let afterHold = w.server.recordedCommands().count
                clock.set(late.deadline)
                w.server.releaseHeldCommand(containing: changedFlags)
                let lateSet = try await read.value
                _ = try await Self.apply(w, lateSet, to: store)
                let sentLate = w.server.recordedCommands().dropFirst(afterHold).map { $0.uppercased() }
                let lateStep = Self.stepRequests(sentLate)
                #expect(lateStep.searches == 0 && lateStep.fetches == 0, "a slice whose time ran out starts no step: \(sentLate)")
                let keptAfterCut = try await store.progress()
                #expect(keptAfterCut == found, "the stored progress stays: \(String(describing: keptAfterCut))")

                // The proof's FETCH: the server holds its answer past the run's request limit.
                let stall = SyncConfig.catchUpRequestTimeoutSeconds * 2
                w.server.stallNextCommand(containing: "UID FETCH \(candidate) ", seconds: stall)
                let started = Date()
                let timedOut = try await Self.slice(w, store, context: Self.roomySlice(clock))
                let waited = Date().timeIntervalSince(started)
                var failed = false
                if case .failed = timedOut.status { failed = true }
                #expect(failed && waited < stall, "the step's request is given up at the run's limit: \(timedOut.status) after \(waited) s")
                let keptAfterTimeout = try await store.progress()
                #expect(keptAfterTimeout == found, "the stored progress stays: \(String(describing: keptAfterTimeout))")

                // The next slice takes the step, and the check ends.
                let next = try await Self.slice(w, store, context: Self.roomySlice(clock))
                #expect(R.isTracked(next.status) && next.removals == ["\(candidate)"],
                        "the next slice proves the candidate gone: \(next.status), \(next.removals)")
                let left = try await store.progress()
                #expect(left == nil, "the finished check leaves the stored bookmark")
            }
        }
    }

    /// The requests of the check's proof step (its FETCH and its confirming
    /// SEARCH), as a pass prices the step before it starts it.
    static let proofRequests: TimeInterval = 2

    /// The clock of a slice that runs out the moment the proof's confirming
    /// SEARCH has been sent (the proof's FETCH of `candidate`, then a SEARCH):
    /// the proof finishes, and nothing after it may start.
    static func runsOutAfterTheProof(
        _ server: FakeIMAPServer, candidate: Int, from start: Date, deadline: Date
    ) -> @Sendable () -> Date {
        let proofFetch = "UID FETCH \(candidate) "
        return {
            let sent = server.recordedCommands().map { $0.uppercased() }
            guard let fetch = sent.lastIndex(where: { $0.hasPrefix(proofFetch) }) else { return start }
            return sent[(fetch + 1)...].contains { $0.hasPrefix("UID SEARCH") } ? deadline : start
        }
    }

    @Test("A slice of a run whose last check step finishes but whose arrivals cannot start keeps the finished check and what it proved: the next slice takes no step, fetches the arrivals and commits the check's bookmark")
    func aFinishedCheckStepIsKeptWhenTheArrivalsCannotStart() async throws {
        let held = Array(1...10)
        let candidate = 4
        let arrival = held.count + 1
        try await C.withWorld(inbox: held) { w in
            await w.provider.setRemovalCheckWindowForTesting(held.count)
            let base = try await R.baseline(w)
            C.remove([candidate], from: w.server)
            let clock = IMAPChangeEngineTests.StillClock(Date())
            try await Self.withStore(w, uids: held, bookmark: base) { store in
                _ = try await Self.slice(w, store, context: Self.roomySlice(clock))
                let found = try await store.progress()
                #expect(found?.unproven == [UInt32(candidate)] && found?.remaining == 0,
                        "precondition: only the candidate's proof is left: \(String(describing: found))")
                guard let found else { return }

                C.add([arrival], to: w.server)
                let start = Date()
                let deadline = start.addingTimeInterval(SyncConfig.catchUpSliceSeconds)
                let short = ChangeContext(
                    deadline: deadline,
                    clock: Self.runsOutAfterTheProof(w.server, candidate: candidate, from: start, deadline: deadline),
                    onProgress: { _ in })
                let proved = try await Self.slice(w, store, context: short)
                var cut = false
                if case .untracked = proved.status { cut = true }
                #expect(cut && proved.removals == ["\(candidate)"],
                        "the finished proof is kept: \(proved.status), removals \(proved.removals)")
                #expect(!proved.records.contains { $0.messageId == "\(arrival)" }, "precondition: the arrival was not fetched")
                let kept = try await store.progress()
                #expect(kept?.unproven.isEmpty == true && kept?.remaining == 0,
                        "the stored check is finished: \(String(describing: kept))")
                let rows = try await store.uids()
                #expect(!rows.contains(candidate), "the proven removal is applied")

                let before = w.server.recordedCommands().count
                let next = try await Self.slice(w, store, context: Self.roomySlice(clock))
                let sent = w.server.recordedCommands().dropFirst(before).map { $0.uppercased() }
                let proofAgain = sent.filter { $0.hasPrefix("UID FETCH \(candidate) ") }
                #expect(proofAgain.isEmpty, "the next slice takes no step: \(sent)")
                #expect(R.isTracked(next.status) && next.records.contains { $0.messageId == "\(arrival)" },
                        "the next slice fetches the arrival: \(next.status)")
                let committed = try await store.bookmark()
                let cursor = IMAPChangeCursor.decode(committed)
                #expect(cursor?.pendingCheck == nil && cursor?.uidNext == found.pending.uidNext,
                        "the check's own bookmark is committed: \(String(describing: cursor))")
            }
        }
    }

    @Test("A pass whose removal check finishes but whose arrivals cannot start is unchanged by the run's rule: the folder is not read this pass, nothing the check proved is applied, and the stored bookmark stays for the next pass")
    func aPassWhoseArrivalsCannotStartReadsTheFolderNextPass() async throws {
        let held = Array(1...10)
        let candidate = 4
        let arrival = held.count + 1
        try await C.withWorld(inbox: held) { w in
            await w.provider.setRemovalCheckWindowForTesting(held.count)
            let base = try await R.baseline(w)
            C.remove([candidate], from: w.server)
            let clock = IMAPChangeEngineTests.StillClock(Date())
            try await Self.withStore(w, uids: held, bookmark: base) { store in
                // A run's slice leaves the check with only the candidate's proof to take.
                _ = try await Self.slice(w, store, context: Self.roomySlice(clock))
                let found = try await store.progress()
                #expect(found?.unproven == [UInt32(candidate)] && found?.remaining == 0,
                        "precondition: only the candidate's proof is left: \(String(describing: found))")
                guard found != nil else { return }
                let stored = try await store.bookmark()

                // A pass takes the proof, and its time runs out before the arrivals' FETCH. A pass
                // starts a check step only while its time covers the step's requests at the pass's
                // request bound, so it gets exactly the proof's price.
                C.add([arrival], to: w.server)
                let start = Date()
                let deadline = start.addingTimeInterval(Self.proofRequests * SyncConfig.changeReadRequestTimeoutSeconds)
                let short = ChangeContext(
                    deadline: deadline,
                    clock: Self.runsOutAfterTheProof(w.server, candidate: candidate, from: start, deadline: deadline),
                    onProgress: { _ in })
                let before = w.server.recordedCommands().count
                let pass = try await Self.slice(w, store, context: short, scope: .all)
                let sent = w.server.recordedCommands().dropFirst(before).map { $0.uppercased() }
                let proofTaken = sent.contains { $0.hasPrefix("UID FETCH \(candidate) ") }
                #expect(proofTaken, "precondition: the pass took the proof: \(sent)")
                var notRun = false
                if case .notRun = pass.status { notRun = true }
                #expect(notRun && pass.removals.isEmpty, "the pass does not read the folder: \(pass.status), removals \(pass.removals)")
                let rows = try await store.uids()
                #expect(rows.contains(candidate), "no removal is applied")
                let after = try await store.bookmark()
                #expect(after == stored, "the stored bookmark stays: \(String(describing: after))")
            }
        }
    }
}
