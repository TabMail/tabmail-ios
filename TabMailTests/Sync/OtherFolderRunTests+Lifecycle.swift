/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Synchronization
import Testing
@testable import TabMail

// MARK: - A run's lifecycle and its slot (#1110)

extension OtherFolderIMAPTests {

    /// The folders of a run held inside its first slice (`holdTheFirstSlice`).
    struct HeldSlice: Sendable {
        /// The folder whose STATUS the server holds.
        let first: String
        /// The folder the slice did not reach, with new mail at `newUid`.
        let second: String
        let newUid: Int
    }

    /// Starts the account's run and holds it inside its first slice, which asks
    /// both other folders: the second folder gets new mail, the first folder's
    /// STATUS is held at the server, and the slice's time runs out while it is
    /// held, so once released its read stops after the first folder and leaves
    /// the second for the run's next slice. Nil, with the issue recorded and the
    /// run let go, when the run never got there.
    static func holdTheFirstSlice(_ w: World) async throws -> HeldSlice? {
        let first = OtherFolderShared<String?>(nil)
        let second = OtherFolderShared<String?>(nil)
        let newUid = OtherFolderShared<Int?>(nil)
        await w.watchSlices { folderIds in
            guard first.get == nil, folderIds.count == Self.others.count else { return }
            let paths = folderIds.map { w.path(ofId: $0) }
            let uid = w.nextUid(in: paths[1])
            w.deliver(uid, to: paths[1])
            newUid.set(uid)
            second.set(paths[1])
            first.set(paths[0])
            w.holdStatus(of: paths[0])
        }
        let account = try w.account()
        await w.engine.startOtherFolderRun(account: account)
        guard await OneSyncAtATimeTests.eventually({ w.isHoldingStatus(of: first.get) }),
              let firstPath = first.get, let secondPath = second.get, let uid = newUid.get else {
            Issue.record("precondition: the run's first slice is held at its first folder's read")
            await w.watchSlices()
            w.releaseStatus(of: first.get)
            await w.settle()
            return nil
        }
        w.offset.add(SyncConfig.catchUpSliceSeconds + 1)
        return HeldSlice(first: firstPath, second: secondPath, newUid: uid)
    }

    @Test("Removing the account during a run's slice ends the run when that slice ends: it takes no next slice, asks nothing of the folder it had not reached, and leaves no run and no read order behind")
    func removingTheAccountEndsTheRun() async throws {
        try await Self.withWorld("removed", .plain) { w in
            guard let held = try await Self.holdTheFirstSlice(w) else { return }
            let engine = w.engine
            let accountId = w.accountId
            // The run took the account's work queue when it started, so only
            // its cancellation keeps it from a next slice once the slice ends.
            let removal = Task { await engine.remove(accountId: accountId) }
            guard await OneSyncAtATimeTests.eventually({ await engine.workQueues[accountId] == nil }) else {
                Issue.record("precondition: the removal started while the slice is held")
                w.releaseStatus(of: held.first)
                await removal.value
                return
            }
            w.releaseStatus(of: held.first)
            await removal.value

            let asked = w.runSlices.map { $0.folderIds.map { w.path(ofId: $0) } }
            let reads = w.statusCount(held.second)
            let arrived = try w.holds(held.newUid, in: held.second)
            let run = await engine.otherFolderRunTasks[accountId]
            let order = await engine.otherFolderAttemptedAt[accountId]
            #expect(asked.count == 1, "the run took no slice after the removal: \(asked)")
            #expect(reads == 0, "nothing was asked of \(held.second)")
            #expect(!arrived, "so its new mail did not arrive")
            #expect(run == nil, "no run is left")
            #expect(order == nil, "and no read order")
        }
    }

    @Test("A run under way when the app leaves the screen goes on: once its slice ends it takes its next slice, which reads the folder it had not reached and brings its new mail")
    func aRunGoesOnWhenTheAppLeavesTheScreen() async throws {
        try await Self.withWorld("left-screen", .plain) { w in
            guard let held = try await Self.holdTheFirstSlice(w) else { return }
            let engine = w.engine
            let accountId = w.accountId
            // The engine's part of the app leaving the screen
            // (`SyncScheduler.stopPolling`). The run reads no lifecycle state of
            // its own, so this is the whole of what the leave can reach.
            await engine.cancelMaintenance()
            let running = await engine.otherFolderRunTasks[accountId]
            w.releaseStatus(of: held.first)
            await w.settle()

            let asked = w.runSlices.map { $0.folderIds.map { w.path(ofId: $0) } }
            let next = asked.dropFirst().first?.first
            let arrived = try w.holds(held.newUid, in: held.second)
            #expect(running != nil, "the run was still under way after the app left the screen")
            #expect(next == held.second, "its next slice asked the folder it had not reached: \(asked)")
            #expect(arrived, "and its new mail arrived")
        }
    }

    @Test("A run's slice waits for its slot in the older-mail tier: with every slot of the account taken, a user action that asked after it is let in first, and the slice is let in before a download that asked before it")
    func aSliceTakesTheOlderMailSlot() async throws {
        try await Self.withWorld("slot", .plain) { w in
            let engine = w.engine
            let accountId = w.accountId
            let server = w.server
            let account = try w.account()
            let registered = await engine.workQueues[accountId]
            let queue = try #require(registered)
            let width = SyncConfig.imapMaxConnectionCeiling

            // Every slot is taken, each by work the test lets go.
            let gates = (0..<width).map { _ in AsyncStream<Void>.makeStream() }
            let holders = gates.map { gate in
                Task { await queue.execute(priority: .userAction) { for await _ in gate.stream { break } } }
            }
            // Where the server's log stood when each waiter was let in.
            let downloadAt = OtherFolderShared<Int?>(nil)
            let userActionAt = OtherFolderShared<Int?>(nil)
            var waiters: [Task<Void, Never>] = []
            func letGo() async {
                for gate in gates { gate.continuation.finish() }
                for holder in holders { await holder.value }
                for waiter in waiters { await waiter.value }
                await w.settle()
            }
            guard await OneSyncAtATimeTests.eventually({ await queue.activeOperations == width }) else {
                Issue.record("precondition: every slot of the account is taken")
                return await letGo()
            }
            waiters.append(Task {
                await queue.execute(priority: .bodyFetch) { downloadAt.set(server.recordedCommands().count) }
            })
            guard await OneSyncAtATimeTests.eventually({ await queue.waitingCount == 1 }) else {
                Issue.record("precondition: the download waits for a slot")
                return await letGo()
            }
            await engine.startOtherFolderRun(account: account)
            guard await OneSyncAtATimeTests.eventually({ await queue.waitingCount == 2 }) else {
                Issue.record("precondition: the run's slice waits for a slot after the download")
                return await letGo()
            }
            waiters.append(Task {
                await queue.execute(priority: .userAction) { userActionAt.set(server.recordedCommands().count) }
            })
            guard await OneSyncAtATimeTests.eventually({ await queue.waitingCount == 3 }) else {
                Issue.record("precondition: the user action waits for a slot after the slice")
                return await letGo()
            }

            // One slot frees: the waiters are let in one at a time, by tier.
            gates[0].continuation.finish()
            await w.settle()
            for waiter in waiters { await waiter.value }
            let commands = server.recordedCommands()
            let sliceAt = commands.firstIndex { command in Self.others.contains { Self.isStatus(command, of: $0) } }
            let userFirst = userActionAt.get.flatMap { user in sliceAt.map { user <= $0 } } ?? false
            let sliceBeforeDownload = sliceAt.flatMap { slice in downloadAt.get.map { slice < $0 } } ?? false
            #expect(userFirst, "the user action was let in before the slice sent anything: user \(String(describing: userActionAt.get)), slice \(String(describing: sliceAt))")
            #expect(sliceBeforeDownload, "the slice was let in before the download that asked first: slice \(String(describing: sliceAt)), download \(String(describing: downloadAt.get))")
            await letGo()
        }
    }
}

// MARK: - The older-mail check's order (#1110)

extension OtherFolderOutlookTests {

    @Test("Outlook: an older-mail slice works a due folder of the syncable set before a due other folder tried longer ago, so one shared budget goes to the syncable folder")
    func olderMailWorksTheSyncableFolderFirst() async throws {
        let c = C.Clock()
        try await C.withWorld(seeds: [
            C.seed("a-1", in: R.archive, at: c.daysAgo(2)),
            C.seed("o-1", in: Self.projects, at: c.daysAgo(2)),
        ]) { w, engine in
            w.server.addFolder(id: Self.projects, name: "Projects")
            var custom = Folder(name: "Projects", path: Self.projects, role: .custom, accountId: w.accountId)
            custom.oldestSyncedDate = R.daysAgo(30)
            let toInsert = custom
            try await w.pool.write { db in try toInsert.insert(db) }
            try C.setWalkComplete(w, Self.projects, true)
            try w.insertRow("a-1", in: R.archive, date: c.daysAgo(2))
            try w.insertRow("o-1", in: Self.projects, date: c.daysAgo(2))
            try await w.baselineAll()
            for _ in 0..<Self.runs {
                try await Self.run(w, engine)
                if try w.cursor(Self.projects)?.phase == .tracking { break }
            }
            let phases = try [R.archive, Self.projects].map { try w.cursor($0)?.phase }
            let bothTrack = phases.allSatisfy { $0 == .tracking }
            let syncable = SyncEngine.isSyncable(try w.folder(Self.projects))
            #expect(bothTrack, "setup: both folders track, so both may be listed: \(phases)")
            #expect(!syncable, "setup: Projects is outside the syncable set")

            // Both are due (never listed); the other folder was tried longer
            // ago, so only its place among the other folders puts it second.
            // Every other folder of the account is done.
            let now = Date()
            let syncableTried = now.addingTimeInterval(-3_600)
            let done = ExchangeCatchUpState(lastCompletedAt: now, lastAttemptAt: now).encoded()
            let syncableDue = ExchangeCatchUpState(lastAttemptAt: syncableTried).encoded()
            let otherDue = ExchangeCatchUpState(lastAttemptAt: now.addingTimeInterval(-2 * 86_400)).encoded()
            let accountId = w.accountId
            let archiveId = w.folderId(R.archive)
            let projectsId = w.folderId(Self.projects)
            try await w.pool.write { db in
                try db.execute(sql: "UPDATE folder SET catchUpState = ? WHERE accountId = ?", arguments: [done, accountId])
                try db.execute(sql: "UPDATE folder SET catchUpState = ? WHERE id = ?", arguments: [syncableDue, archiveId])
                try db.execute(sql: "UPDATE folder SET catchUpState = ? WHERE id = ?", arguments: [otherDue, projectsId])
            }

            // One older-mail slice, through the engine's own run, with a budget
            // of one request: the run's clock moves one second per request.
            let server = w.server
            let before = server.http.recordedCalls().count
            let base = Date()
            let run = SyncEngine.CatchUpRun.snapshot(
                deadline: base.addingTimeInterval(1),
                clock: { base.addingTimeInterval(TimeInterval(server.http.recordedCalls().count - before)) })
            let account = try w.account()
            _ = await engine.runCatchUpRun(account: account, run: run)

            let spent = server.http.recordedCalls().count - before
            let archiveState = try C.state(w, R.archive)
            let projectsState = try w.folder(Self.projects).catchUpState
            let archiveWorked = archiveState?.lastAttemptAt.map { $0 > syncableTried } ?? false
            #expect(spent == 1, "setup: the slice had a budget of one request: \(spent)")
            #expect(archiveWorked, "the slice worked the Archive, a due folder of the syncable set")
            #expect(projectsState == otherDue, "and left Projects, tried longer ago, for later")
        }
    }
}
