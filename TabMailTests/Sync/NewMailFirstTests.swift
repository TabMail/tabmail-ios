/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Testing
@testable import TabMail

/// THE PROPERTY (#1360): new mail goes ahead of the background chunks already
/// waiting for the account's turn. A new-mail trigger (push, IDLE, the poll)
/// that arrives while a catch-up slice holds the turn sets the account's
/// follow-up flag; once the follow-up is in line, only the running slice is
/// ahead of it. The slices other readers queued before it start after its
/// read, in the order they queued. The sync design block at the top of
/// SyncEngineOneSyncAtATime.swift ("New mail goes first").
///
/// The timing tests drive production code end to end on `FakeHTTP` with a real
/// `GmailProvider` and a real `DatabasePool`. The background readers are
/// real catch-up runs (`runCatchUpRun`), one slice each. Each trigger is fired
/// through the engine call its production path makes:
/// - push: `backgroundSyncOne(inboxOnly: true)`
/// - IDLE: `backgroundSyncForAccount`
/// - poll: `foregroundSyncOne`
/// The turn is above the provider boundary, so Gmail stands in for IDLE's IMAP
/// account. A runner stands in for `SyncScheduler.runSyncFollowUp`
/// (`SyncFollowUpTests.FollowUps`). The folder view's listing takes the same
/// place (owner 2026-11-26): its test opens and pulls to refresh a folder
/// through `InboxViewModel` on `AccountManager.shared`. The last test drives
/// the turn line itself (`SyncEngine.oneSyncAtATime` with each `SyncTurnPlace`).
@Suite("New mail goes ahead of background chunks waiting for the turn (#1360)", .serialized, .processGlobalState)
struct NewMailFirstTests {
    typealias O = OneSyncAtATimeTests
    private static let accountId = O.accountId

    /// A new-mail trigger, fired through the engine call its production path makes.
    enum Trigger: String, CaseIterable, Sendable {
        /// A push, silent or with the app open: `syncStartup(inboxOnly: true)`
        /// -> `backgroundSyncOne(inboxOnly: true)` -> stage 1 of the Inbox.
        case push
        /// An IMAP IDLE event: `backgroundPoll(accountEmail:)` ->
        /// `backgroundSyncForAccount` -> stage 1 of every folder.
        case idle
        /// The foreground poll: `foregroundSyncOne` -> stage 2 as a trigger
        /// (`syncOrFollowUp`).
        case poll

        /// Fires the trigger. True when it found the account busy and read nothing.
        func firedOnABusyAccount(_ engine: SyncEngine, _ account: Account) async throws -> Bool {
            let deadline = Date().addingTimeInterval(SyncConfig.perAccountSyncTimeoutSeconds)
            switch self {
            case .push:
                return try await engine.backgroundDeltaSync(account: account, inboxOnly: true, deadline: deadline) == nil
            case .idle:
                return try await engine.backgroundDeltaSync(account: account, deadline: deadline) == nil
            case .poll:
                return try await engine.syncOrFollowUp(account: account, deadline: deadline) == nil
            }
        }
    }

    /// The paths of the three folders a background reader each asks: the
    /// running slice's, then the two queued behind it.
    static let runningPath = "INBOX"
    static let firstQueuedPath = "SENT"
    static let secondQueuedPath = "TRASH"

    /// A server whose every change read appends "read" to `log` and finds no
    /// change, and whose listings are empty.
    private static func scenario(log: O.PassLog) -> FakeHTTP.Scenario {
        let scenario = FakeHTTP.Scenario()
        scenario.register(path: "/history", method: "GET") { _ in
            log.append("read")
            return .json(raw: #"{ "historyId": "2001" }"#)
        }
        scenario.register(path: "/labels", method: "GET", response: .json(raw: """
            { "labels": [ { "id": "INBOX", "name": "INBOX", "type": "system" },
                          { "id": "SENT", "name": "SENT", "type": "system" },
                          { "id": "TRASH", "name": "TRASH", "type": "system" } ] }
            """))
        scenario.register(path: "/messages", method: "GET", response: .json(raw: #"{ "resultSizeEstimate": 0 }"#))
        scenario.register(path: "/profile", method: "GET", response: .json(
            raw: #"{ "emailAddress": "one-sync-gmail@example.com", "historyId": "2000" }"#))
        return scenario
    }

    /// A catch-up run of one slice that asks only `folderId`. With no pacing
    /// window, a slice that gets the turn always starts its work, so a queued
    /// slice is seen the moment it takes the turn.
    private static func oneSlice(_ folderId: String) -> SyncEngine.CatchUpRun {
        SyncEngine.CatchUpRun(
            storageLimitInForce: false, deadline: nil, sliceSeconds: SyncConfig.catchUpSliceSeconds,
            intervalSeconds: 0, accessedFolderIds: [folderId], clock: { Date() })
    }

    /// RED before #1360: the follow-up joined the back of the line, so both
    /// queued slices started before its read (the log read "slice INBOX",
    /// "slice SENT", "slice TRASH", "read"). RED if a catch-up slice is not
    /// marked as a background chunk, or the follow-up does not ask for its place
    /// ahead of them: the follow-up then queues behind both. RED if the
    /// follow-up went in before the last slice rather than the first: one slice
    /// then reads first. Pinned for each trigger kind (r2: push, IDLE and the
    /// poll each).
    @Test("A new-mail trigger during a catch-up slice reads right after that slice, ahead of the other readers' slices already waiting",
          arguments: Trigger.allCases)
    func newMailReadsAheadOfQueuedSlices(trigger: Trigger) async throws {
        try await O.withAppDB { pool in
            let account = try O.makeAccount(pool: pool, lastFullSyncAt: Date())
            let folders = [
                Folder(name: Self.firstQueuedPath, path: Self.firstQueuedPath, role: .sent, accountId: Self.accountId),
                Folder(name: Self.secondQueuedPath, path: Self.secondQueuedPath, role: .trash, accountId: Self.accountId),
            ]
            try await pool.write { db in for folder in folders { try folder.insert(db) } }
            let inboxId = try await pool.read { db in
                try Folder.filter(Column("accountId") == Self.accountId && Column("role") == FolderRole.inbox.rawValue)
                    .fetchOne(db)?.id
            }
            guard let inboxId else {
                Issue.record("precondition: the account has an Inbox")
                return
            }
            let pathOf = [inboxId: Self.runningPath, folders[0].id: Self.firstQueuedPath, folders[1].id: Self.secondQueuedPath]

            let log = O.PassLog()
            let scenario = Self.scenario(log: log)
            defer { scenario.close() }
            let followUps = SyncFollowUpTests.FollowUps()
            let provider = GmailProvider(
                userEmail: account.emailAddress, accessToken: { _ in "fake-access-token" }, session: scenario.session)
            let engine = await O.engine(provider: provider, syncFollowUp: { followUps.ask($0) })
            followUps.runStageTwo(engine: engine)

            // Every slice logs the folders it asks as it starts its work. The
            // first reader's slice (the Inbox alone) then holds the turn until
            // the test lets it go; finishing the stream lets it go for good.
            let hold = AsyncStream<Void>.makeStream()
            defer { hold.continuation.finish() }
            let holdStream = hold.stream
            await engine.setCatchUpSliceStartHookForTesting { folderIds in
                log.append("slice " + folderIds.map { pathOf[$0] ?? $0 }.joined(separator: ","))
                if folderIds == [inboxId] { for await _ in holdStream { break } }
            }

            let running = Task { await engine.runCatchUpRun(account: account, run: Self.oneSlice(inboxId)) }
            let sliceRuns = await O.eventually { log.snapshot == ["slice \(Self.runningPath)"] }
            #expect(sliceRuns, "precondition: the first reader's slice holds the turn: \(log.snapshot)")
            let firstQueued = Task { await engine.runCatchUpRun(account: account, run: Self.oneSlice(folders[0].id)) }
            let oneQueued = await O.eventually { await engine.syncPassWaiters[Self.accountId]?.count == 1 }
            #expect(oneQueued, "precondition: the second reader's slice waits for the turn")
            let secondQueued = Task { await engine.runCatchUpRun(account: account, run: Self.oneSlice(folders[1].id)) }
            let twoQueued = await O.eventually { await engine.syncPassWaiters[Self.accountId]?.count == 2 }
            #expect(twoQueued, "precondition: the third reader's slice waits for the turn")

            let busy = try await trigger.firedOnABusyAccount(engine, account)
            #expect(busy, "the \(trigger) found the account busy and must read nothing itself")
            let followUpInLine = await O.eventually { await engine.syncPassWaiters[Self.accountId]?.count == 3 }
            #expect(followUpInLine, "precondition: the \(trigger)'s follow-up waits in line")

            hold.continuation.finish()
            _ = await (running.value, firstQueued.value, secondQueued.value)
            let followUpDone = await O.eventually { followUps.running == 0 && !followUps.outcomes.isEmpty }
            await engine.stopBackfillWorkerForTesting(accountId: Self.accountId)
            let entries = log.snapshot
            await engine.remove(accountId: Self.accountId)

            #expect(followUpDone, "the \(trigger)'s follow-up never finished")
            #expect(followUps.outcomes == ["ran"], "the \(trigger)'s follow-up did not run its stage 2: \(followUps.outcomes)")
            let firstSlice = "slice \(Self.firstQueuedPath)"
            let secondSlice = "slice \(Self.secondQueuedPath)"
            guard let read = entries.firstIndex(of: "read"),
                  let first = entries.firstIndex(of: firstSlice),
                  let second = entries.firstIndex(of: secondSlice) else {
                Issue.record("the follow-up's read or a queued slice never happened: \(entries)")
                return
            }
            #expect(Array(entries[..<read]) == ["slice \(Self.runningPath)"],
                    "only the running slice may be ahead of the \(trigger)'s read: \(entries)")
            #expect(read < first && read < second,
                    "a slice queued before the \(trigger)'s follow-up started before its read: \(entries)")
            #expect(first < second, "the queued slices did not keep their order: \(entries)")
            #expect(entries.filter { $0 == firstSlice }.count == 1 && entries.filter { $0 == secondSlice }.count == 1,
                    "each queued slice runs once: \(entries)")
        }
    }

    /// How the folder view syncs the folders on screen. Both run
    /// `InboxViewModel.performSync` -> `AccountManager.syncFolders`.
    enum FolderViewSync: String, CaseIterable, Sendable {
        /// Opening the folder: `InboxView.onAppear` -> `startSync()`, after its debounce.
        case open
        /// Pull to refresh: `.refreshable` -> `refreshSync()`.
        case pull
    }

    /// THE PROPERTY for the folder view (owner 2026-11-26; sync timing promise
    /// 7 for the pull): the listing of the folder on screen takes the
    /// follow-up's place in the turn line, so opening a folder or pulling to
    /// refresh it during a catch-up slice lists the folder right after that
    /// slice, ahead of the other readers' slices already waiting, which then
    /// run in their order. Driven through the view's own entry points on
    /// `AccountManager.shared`, the app's engine. The scheduler takes the
    /// follow-up that the view's busy change read asks for and starts nothing:
    /// this test is about the listing. RED before: the listing joined the back
    /// of the line, so both queued slices started before it (the log read
    /// "slice INBOX", "slice SENT", "slice TRASH", "listing"). RED if
    /// `syncFolders` or `syncFolderMessages` drops the place.
    @Test("Opening or pulling to refresh a folder during a catch-up slice lists it right after that slice, ahead of the slices already waiting",
          arguments: FolderViewSync.allCases)
    @MainActor
    func folderViewListsAheadOfQueuedSlices(sync: FolderViewSync) async throws {
        let scheduler = SyncScheduler.shared
        let savedScheduler = (scheduler.applicationStateForTesting, scheduler.foregroundReadinessHook, scheduler.stageTwoHook)
        scheduler.applicationStateForTesting = .active
        scheduler.foregroundReadinessHook = { true }
        scheduler.stageTwoHook = { _ in }
        let state = AccountManagerState.shared
        let savedState = (state.syncErrorBanner, state.lastSyncCompletedAt, state.lastSyncFailed)
        // Restored only after the account has left the engine (the end of the
        // body below), so an ask still on its way to the main actor finds no account.
        defer {
            scheduler.applicationStateForTesting = savedScheduler.0
            scheduler.foregroundReadinessHook = savedScheduler.1
            scheduler.stageTwoHook = savedScheduler.2
            state.setSyncPhase(nil, forAccount: Self.accountId)
            state.syncErrorBanner = savedState.0
            state.lastSyncCompletedAt = savedState.1
            state.lastSyncFailed = savedState.2
        }
        // The app's database, as `O.withAppDB` installs it, here in the test's
        // own main-actor body (the view model is main-actor isolated).
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
        }
        let account = try O.makeAccount(pool: pool, lastFullSyncAt: Date())
        let folders = [
            Folder(name: Self.firstQueuedPath, path: Self.firstQueuedPath, role: .sent, accountId: Self.accountId),
            Folder(name: Self.secondQueuedPath, path: Self.secondQueuedPath, role: .trash, accountId: Self.accountId),
        ]
        try await pool.write { db in for folder in folders { try folder.insert(db) } }
        let inbox = try await pool.read { db in
            try Folder.filter(Column("accountId") == Self.accountId && Column("role") == FolderRole.inbox.rawValue)
                .fetchOne(db)
        }
        guard let inbox else {
            Issue.record("precondition: the account has an Inbox")
            return
        }
        let log = O.PassLog()
        let scenario = Self.scenario(log: log)
        defer { scenario.close() }
        let provider = GmailProvider(
            userEmail: account.emailAddress, accessToken: { _ in "fake-access-token" }, session: scenario.session)
        await AccountManager.shared.connectProviderForTesting(account: account, provider: provider)
        let engine = await AccountManager.shared.syncEngine

        SyncEngine.standaloneListingAfterLookupTestHook.withLock {
            $0 = { accountId in if accountId == Self.accountId { log.append("listing") } }
        }
        let hold = AsyncStream<Void>.makeStream()
        let slices = await Self.runningSliceAndTwoQueued(
            engine: engine, account: account, folderIds: (inbox.id, folders[0].id, folders[1].id),
            log: log, hold: hold.stream)

        let view = InboxViewModel(folders: [inbox])
        var pull: Task<Void, Never>?
        switch sync {
        case .open: view.startSync()
        case .pull: pull = Task { await view.refreshSync() }
        }
        let listingInLine = await O.eventually { await engine.syncPassWaiters[Self.accountId]?.count == 3 }
        #expect(listingInLine, "precondition: the \(sync)'s listing waits in line")

        hold.continuation.finish()
        for slice in slices { await slice.value }
        await pull?.value
        let viewDone = await O.eventually { !view.isRefreshing && log.snapshot.contains("listing") }
        let entries = log.snapshot
        SyncEngine.standaloneListingAfterLookupTestHook.withLock { $0 = nil }
        await engine.setCatchUpSliceStartHookForTesting(nil)
        // Also stops the access run the view started after its change read.
        await AccountManager.shared.disconnectProviderForTesting(accountId: Self.accountId)

        #expect(viewDone, "the \(sync)'s sync never finished: \(entries)")
        let firstSlice = "slice \(Self.firstQueuedPath)"
        let secondSlice = "slice \(Self.secondQueuedPath)"
        guard let listing = entries.firstIndex(of: "listing"),
              let first = entries.firstIndex(of: firstSlice),
              let second = entries.firstIndex(of: secondSlice) else {
            Issue.record("the \(sync)'s listing or a queued slice never happened: \(entries)")
            return
        }
        #expect(Array(entries[..<listing]) == ["slice \(Self.runningPath)"],
                "only the running slice may be ahead of the \(sync)'s listing: \(entries)")
        #expect(listing < first && listing < second,
                "a slice queued before the \(sync)'s listing started before it: \(entries)")
        #expect(first < second, "the queued slices did not keep their order: \(entries)")
        #expect(entries.filter { $0 == firstSlice }.count == 1 && entries.filter { $0 == secondSlice }.count == 1,
                "each queued slice runs once: \(entries)")
        #expect(entries.filter { $0 == "listing" }.count == 1, "the \(sync) listed the folder once: \(entries)")
    }

    /// The other single-folder listings keep their place in line (owner
    /// 2026-11-26): an open email's, after a send, after the outbox empties,
    /// after a drain's moves, step 6 of an epoch rebuild. Each calls
    /// `syncFolderMessages` without a place, so its listing during a catch-up
    /// slice waits behind the slices already waiting. RED if that default were
    /// the follow-up's place: the listing would then pass both queued slices.
    @Test("Any other single-folder listing during a catch-up slice waits behind the slices already waiting")
    func otherListingsKeepTheirPlace() async throws {
        try await O.withAppDB { pool in
            let account = try O.makeAccount(pool: pool, lastFullSyncAt: Date())
            let folders = [
                Folder(name: Self.firstQueuedPath, path: Self.firstQueuedPath, role: .sent, accountId: Self.accountId),
                Folder(name: Self.secondQueuedPath, path: Self.secondQueuedPath, role: .trash, accountId: Self.accountId),
            ]
            try await pool.write { db in for folder in folders { try folder.insert(db) } }
            let inbox = try await pool.read { db in
                try Folder.filter(Column("accountId") == Self.accountId && Column("role") == FolderRole.inbox.rawValue)
                    .fetchOne(db)
            }
            guard let inbox else {
                Issue.record("precondition: the account has an Inbox")
                return
            }

            let log = O.PassLog()
            let scenario = Self.scenario(log: log)
            defer { scenario.close() }
            let provider = GmailProvider(
                userEmail: account.emailAddress, accessToken: { _ in "fake-access-token" }, session: scenario.session)
            let engine = await O.engine(provider: provider)
            SyncEngine.standaloneListingAfterLookupTestHook.withLock {
                $0 = { accountId in if accountId == Self.accountId { log.append("listing") } }
            }
            defer { SyncEngine.standaloneListingAfterLookupTestHook.withLock { $0 = nil } }
            let hold = AsyncStream<Void>.makeStream()
            let slices = await Self.runningSliceAndTwoQueued(
                engine: engine, account: account, folderIds: (inbox.id, folders[0].id, folders[1].id),
                log: log, hold: hold.stream)

            let listing = Task { _ = try? await engine.syncFolderMessages(folder: inbox, provider: provider) }
            let listingInLine = await O.eventually { await engine.syncPassWaiters[Self.accountId]?.count == 3 }
            #expect(listingInLine, "precondition: the listing waits in line")

            hold.continuation.finish()
            for slice in slices { await slice.value }
            await listing.value
            let entries = log.snapshot
            await engine.remove(accountId: Self.accountId)
            await MainActor.run { AccountManagerState.shared.setSyncPhase(nil, forAccount: Self.accountId) }

            let expected = ["slice \(Self.runningPath)", "slice \(Self.firstQueuedPath)", "slice \(Self.secondQueuedPath)", "listing"]
            #expect(Array(entries.prefix(4)) == expected,
                    "the listing did not wait behind the slices already waiting: \(entries)")
        }
    }

    /// The background readers for the folder view's and the other listings'
    /// tests: the first reader's slice (`folderIds.running`) starts and holds
    /// the turn until `hold` finishes; two other readers' slices
    /// (`folderIds.first`, then `folderIds.second`) wait in line behind it.
    /// Every slice logs the folders it asks as it starts its work. Returns
    /// the three runs, in that order.
    private static func runningSliceAndTwoQueued(
        engine: SyncEngine, account: Account, folderIds: (running: String, first: String, second: String),
        log: O.PassLog, hold: AsyncStream<Void>
    ) async -> [Task<Void, Never>] {
        let pathOf = [
            folderIds.running: Self.runningPath, folderIds.first: Self.firstQueuedPath, folderIds.second: Self.secondQueuedPath,
        ]
        let running = folderIds.running
        await engine.setCatchUpSliceStartHookForTesting { ids in
            log.append("slice " + ids.map { pathOf[$0] ?? $0 }.joined(separator: ","))
            if ids == [running] { for await _ in hold { break } }
        }
        var runs = [Task<Void, Never>]()
        for (index, folderId) in [folderIds.running, folderIds.first, folderIds.second].enumerated() {
            runs.append(Task { _ = await engine.runCatchUpRun(account: account, run: Self.oneSlice(folderId)) })
            let ready: Bool
            if index == 0 {
                ready = await O.eventually { log.snapshot == ["slice \(Self.runningPath)"] }
            } else {
                ready = await O.eventually { await engine.syncPassWaiters[Self.accountId]?.count == index }
            }
            #expect(ready, "precondition: slice \(index) holds the turn or waits in line in order: \(log.snapshot)")
        }
        return runs
    }

    /// A pass that logs its name when it takes the account's turn, waiting at
    /// `place`, and holds the turn until `release` ends when given one.
    private static func pass(
        _ engine: SyncEngine, _ name: String, place: SyncTurnPlace, log: O.PassLog, release: AsyncStream<Void>? = nil
    ) -> Task<Void, Never> {
        Task {
            await engine.oneSyncAtATime(accountId: Self.accountId, place: place) {
                log.append(name)
                if let release { for await _ in release { break } }
            }
        }
    }

    /// The follow-up's place in the line: right before the first background
    /// chunk waiting, never ahead of a pass that is not a chunk and joined
    /// before it; a chunk that joins later queues behind it; with no chunk
    /// waiting it joins the back. RED if the follow-up went to the front (it
    /// passes the listing), or if a later chunk could pass it.
    @Test("The follow-up goes in before the first waiting slice only: earlier passes stay ahead, later slices queue behind",
          arguments: [true, false])
    func followUpTakesItsPlaceBeforeTheFirstWaitingSlice(sliceWaiting: Bool) async {
        let engine = SyncEngine()
        let log = O.PassLog()
        let hold = AsyncStream<Void>.makeStream()
        defer { hold.continuation.finish() }
        var passes = [Self.pass(engine, "running", place: .backgroundChunk, log: log, release: hold.stream)]
        let holds = await O.eventually { log.snapshot == ["running"] }
        #expect(holds, "precondition: the running pass holds the turn")

        typealias Arrival = (name: String, place: SyncTurnPlace)
        var arrivals: [Arrival] = [(name: "listing", place: SyncTurnPlace.arrivalOrder)]
        if sliceWaiting { arrivals.append((name: "slice 1", place: SyncTurnPlace.backgroundChunk)) }
        arrivals.append((name: "follow-up", place: SyncTurnPlace.aheadOfBackgroundChunks))
        arrivals.append((name: "slice 2", place: SyncTurnPlace.backgroundChunk))
        for (index, arrival) in arrivals.enumerated() {
            passes.append(Self.pass(engine, arrival.name, place: arrival.place, log: log))
            let inLine = await O.eventually { await engine.syncPassWaiters[Self.accountId]?.count == index + 1 }
            #expect(inLine, "precondition: \(arrival.name) joined the line in order")
        }

        hold.continuation.finish()
        for pass in passes { await pass.value }
        let expected = sliceWaiting
            ? ["running", "listing", "follow-up", "slice 1", "slice 2"]
            : ["running", "listing", "follow-up", "slice 2"]
        #expect(log.snapshot == expected, "the passes took the turn in the wrong order: \(log.snapshot)")
    }
}
