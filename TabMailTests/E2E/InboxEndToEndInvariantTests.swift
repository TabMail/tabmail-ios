/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Synchronization
import Testing
@testable import TabMail

// MARK: - PLAN_INBOX_UNIFIED_READ.md §5B Phase 7 — the END-TO-END invariant layer.
//
// The pure-layer harness (`InboxComposeScenarioTests`) drives
// `InboxListComposer.compose` over VALUE `SimWorld` states — no I/O, no
// database, thousands of compositions per second. It caught every
// individually-testable bug, but two HIGH findings in the 5-round adversarial
// audit lived BETWEEN layers: F1 (a signal-orchestration gap — every layer
// green, nobody asserted "a render signal actually fires after a mutation")
// and F2 (a cross-layer ordering gap — composer trim tested, VM dedup tested,
// their COMPOSITION untested). This file is the missing layer: the SAME
// scenario histories, driven through the REAL pipeline — a real temp
// `AppDatabase`, a real NSE staging SQLite file merged via
// `NSEDataBridge.mergeNSEStagingData(stagingPathOverride:)`, real
// `AccountManager` overlay mutations, real `NotificationCenter` posts, and a
// real `InboxViewModel` — asserting invariants on `vm.loadedMessages`/
// `displayGroups` (what the user's screen actually shows), not on `compose`'s
// return value.
//
// E2E step vocabulary is COARSER than the pure layer's 16 steps: staging a
// message and running ONE `mergeNSEStagingData` call performs phase-1 (header
// insert) + the FTS flush (headerComplete flip) + phase-2 (body/AI) + the
// staging drain ALL within one real "wake" (see `NSEGradualMergeTests.
// terminalRowInOnePass` / `mergeFlipsHeaderCompleteSynchronously` — the merge
// awaits its own FTS flush, so a terminal staged row lands fully durable
// before `mergeNSEStagingData` returns). The pure layer's `phase1Commit`/
// `ftsFlushCommit`/`phase2Commit`/`drainStaging` steps are therefore NOT
// separately observable here — `pushArrives` covers all four in one call.
// This is a DELIBERATE granularity choice, not a gap: §5B says "the E2E
// granularity is per-wake" — where the pure layer proves invariants hold at
// every micro-step, this layer proves they hold across real wake boundaries,
// which is the actual unit of observability a production reload/render cycle
// has.
//
// NOTE (build/discovery): all `@Test` functions live directly in this
// struct's primary declaration rather than in separate `extension` blocks —
// `xcodebuild -only-testing:` filtering silently found zero tests when they
// were split across extensions (the binary still contained the symbols, but
// xcodebuild's static test enumeration did not), matching every other test
// file's convention in this repo. Non-`@Test` helpers live in `private`
// members below.
// `.processGlobalState` is REQUIRED here, not decorative: this suite swaps
// `AppDatabase.shared` (`makeFixture` below at line 83; restored in `cleanup`
// at line 134) and mutates `AccountManager.shared`'s overlay in `cleanup`.
// `.serialized` only orders tests INSIDE one
// suite — it does nothing to stop a *different* suite replacing those same
// singletons concurrently (see `ProcessGlobalTestState.swift:8-14`). Without
// this trait the suite ran outside the shared critical section, and the I8
// signal-liveness check below failed intermittently with `captured=[]` once a
// fifth long-running annotated suite (T0.7's UIDVALIDITY fuzzer) widened the
// overlap window. Diagnosed 2026-07-30 — do NOT "fix" a recurrence by relaxing
// the I8 assertion or adding a wait; the trait is the fix.
@Suite(
    "Inbox end-to-end invariant layer (PLAN_INBOX_UNIFIED_READ §5B Phase 7)",
    .serialized, .processGlobalState
)
@MainActor
struct InboxEndToEndInvariantTests {

    // MARK: - Harness (mirrors NSEStaleStagedRowInvalidationTests / NSEGradualMergeTests / InboxListBehaviorPinningTests)

    struct DBFixture {
        let dir: URL
        let pool: DatabasePool
        let previous: AppDatabase?
        let stagingPath: String
        let stagingQueue: DatabaseQueue
        let accountId: String
        let inbox: Folder
        let archive: Folder
    }

    /// One account, one inbox, one archive folder — the shape every named
    /// scenario except `crossAccountIsolation` uses.
    private func makeFixture(accountId: String = "acc1") throws -> DBFixture {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var config = Configuration()
        config.journalMode = .wal
        config.busyMode = .timeout(5)
        config.foreignKeysEnabled = true
        config.maximumReaderCount = 64
        let pool = try DatabasePool(path: dir.appendingPathComponent("tabmail.sqlite").path, configuration: config)
        let appDb = try AppDatabase(dbPool: pool)
        let previous = AppDatabase.shared.withLock { current -> AppDatabase? in
            let prev = current
            current = appDb
            return prev
        }
        let inbox = Folder(name: "INBOX", path: "INBOX", role: .inbox, accountId: accountId)
        let archive = Folder(name: "Archive", path: "Archive", role: .archive, accountId: accountId)
        try pool.writeWithoutTransaction { db in
            var acc = Account(emailAddress: "\(accountId)@example.com", displayName: "Test", provider: .gmail)
            acc.id = accountId
            try acc.insert(db)
            try inbox.insert(db)
            try archive.insert(db)
        }
        let stagingPath = dir.appendingPathComponent("nse_staging.sqlite").path
        AppDatabase.createNSEStagingDB(atPath: stagingPath)
        let stagingQueue = try DatabaseQueue(path: stagingPath)
        return DBFixture(
            dir: dir, pool: pool, previous: previous, stagingPath: stagingPath,
            stagingQueue: stagingQueue, accountId: accountId, inbox: inbox, archive: archive
        )
    }

    /// Two accounts sharing one `AppDatabase`/staging file (a unified inbox
    /// spans accounts, but the NSE staging DB is per-device, not per-account)
    /// — the shape `crossAccountIsolation` needs.
    private func makeTwoAccountFixture() throws -> (DBFixture, acc2Id: String, inbox2: Folder, archive2: Folder) {
        let fixture = try makeFixture(accountId: "acc1")
        let acc2Id = "acc2"
        let inbox2 = Folder(name: "INBOX", path: "INBOX", role: .inbox, accountId: acc2Id)
        let archive2 = Folder(name: "Archive", path: "Archive", role: .archive, accountId: acc2Id)
        try fixture.pool.writeWithoutTransaction { db in
            var acc = Account(emailAddress: "\(acc2Id)@example.com", displayName: "Test2", provider: .gmail)
            acc.id = acc2Id
            try acc.insert(db)
            try inbox2.insert(db)
            try archive2.insert(db)
        }
        return (fixture, acc2Id, inbox2, archive2)
    }

    private func cleanup(_ fixture: DBFixture) {
        AppDatabase.shared.withLock { $0 = fixture.previous }
        TestDatabaseTeardown.retire(
            pools: [fixture.pool],
            queues: [fixture.stagingQueue],
            directory: fixture.dir
        )
        resetGlobals()
    }

    /// Mirrors `InboxListBehaviorPinningTests.clearOverlay` +
    /// `NSEStaleStagedRowInvalidationTests.resetGlobals` — process-wide
    /// globals every suite in this repo resets around itself.
    private func resetGlobals() {
        let snapshot = AccountManager.shared.snapshotOverlay()
        AccountManager.shared.removeOverlayEntries(ids: Array(snapshot.keys))
        NSEDataBridge.latestStagedRows.withLock { $0 = [] }
        NSEDataBridge.latestStagedBodies.withLock { $0 = [:] }
        NSEDataBridge.resetStageMemoForTesting()
        // NOTE: `NSEDataBridge`'s `lastPostedStagedRows` memo (gates
        // `.messagesStaged` re-post suppression) has no public test seam —
        // it's `private static`. Every scenario below uses a distinct
        // `accountId`/`messageId`/date per message key, so a stale memo from
        // a prior test can never content-match a later test's staged row and
        // spuriously suppress its post. Documented here instead of papered
        // over — see PLAN_INBOX_UNIFIED_READ.md §5B / CLAUDE.md "no
        // fallbacks" rule (a seam would need production code changes, out of
        // scope for a test-only phase).
    }

    // MARK: - Staging helpers (mirror NSEGradualMergeTests' stageHeaderRow / stageBodyRow / stageAIRow)

    /// Stage a message id deterministically the way the real NSE does —
    /// `"<accountId>:<messageId>"`, independent of folder (a re-stage under a
    /// different push-time folder still lands on the SAME staging row, which
    /// is exactly the shape `silentStateChangePush`/`redeliver` need).
    private func stagingId(accountId: String, messageId: String) -> String { "\(accountId):\(messageId)" }

    /// One-shot TERMINAL stage (header + body + AI in a single row) — what
    /// `pushArrives`/`silentStateChangePush`/`redeliver` write before calling
    /// `mergeNSEStagingData` ONCE. Mirrors `NSEGradualMergeTests.stageAIRow`'s
    /// full-row shape (a complete `terminalRowInOnePass`-style push).
    private func stageTerminalRow(
        _ world: E2EWorld, key: String, folderPath: String
    ) throws {
        let spec = world.specs[key]!
        try world.stagingQueue.write { db in
            try db.execute(sql: """
                INSERT OR REPLACE INTO nse_processed_message
                    (id, accountId, accountEmail, provider, messageId, rfc822MessageId,
                     folderPath, subject, senderName, senderEmail, snippet, date,
                     processedAt, aiCompleted, notified, populated,
                     htmlContent, textContent, hasUnresolvedCIDs,
                     summaryBlurb, summaryTodos, actionTag)
                VALUES (?, ?, 'user@example.com', 'gmail', ?, ?, ?,
                        ?, 'Sender', 's@example.com', 'snip', ?,
                        ?, 1, 1, 1,
                        ?, ?, 0,
                        ?, ?, ?)
                """, arguments: [
                    self.stagingId(accountId: spec.accountId, messageId: spec.pushMessageId),
                    spec.accountId, spec.pushMessageId, spec.rfc822, folderPath,
                    "Subj \(key)", spec.date.timeIntervalSince1970,
                    Date().timeIntervalSince1970,
                    "<p>Body</p>", "Body text",
                    spec.actionTag != nil || spec.summaryBlurb != nil ? (spec.summaryBlurb ?? "summary") : nil,
                    spec.actionTag != nil || spec.summaryBlurb != nil ? "todo" : nil,
                    spec.actionTag
                ])
        }
    }

    /// Stage 1 of a GRADUAL push — header only, `aiCompleted=0`. Used ONLY by
    /// `aiNeverFlashesAcrossWakes` to model a genuine two-wake AI landing
    /// (see that test's doc comment for why `pushArrives` itself can't
    /// exercise this — a terminal stage is atomic at E2E granularity).
    private func stageHeaderOnlyRow(_ world: E2EWorld, key: String, folderPath: String) throws {
        let spec = world.specs[key]!
        try world.stagingQueue.write { db in
            try db.execute(sql: """
                INSERT OR REPLACE INTO nse_processed_message
                    (id, accountId, accountEmail, provider, messageId, rfc822MessageId,
                     folderPath, subject, senderName, senderEmail, snippet, date,
                     processedAt, aiCompleted, notified, populated)
                VALUES (?, ?, 'user@example.com', 'gmail', ?, ?, ?,
                        ?, 'Sender', 's@example.com', 'snip', ?,
                        ?, 0, 0, 1)
                """, arguments: [
                    self.stagingId(accountId: spec.accountId, messageId: spec.pushMessageId),
                    spec.accountId, spec.pushMessageId, spec.rfc822, folderPath,
                    "Subj \(key)", spec.date.timeIntervalSince1970,
                    Date().timeIntervalSince1970
                ])
        }
    }

    /// Stage 2/3 of a GRADUAL push — attaches body + terminal AI to an
    /// EXISTING header-only staging row (mirrors `stageBodyRow` + `stageAIRow`
    /// combined).
    private func stageBodyAndAIRow(_ world: E2EWorld, key: String) throws {
        let spec = world.specs[key]!
        try world.stagingQueue.write { db in
            try db.execute(sql: """
                UPDATE nse_processed_message SET
                    htmlContent = ?, textContent = ?, hasUnresolvedCIDs = 0,
                    summaryBlurb = ?, summaryTodos = ?, actionTag = ?, aiCompleted = 1
                WHERE id = ?
                """, arguments: [
                    "<p>Body</p>", "Body text",
                    spec.summaryBlurb, spec.summaryBlurb != nil ? "todo" : nil, spec.actionTag,
                    self.stagingId(accountId: spec.accountId, messageId: spec.pushMessageId)
                ])
        }
    }

    // MARK: - waitUntil (mirrors MessageDetailHeaderRecoveryTests / MessageDetailStagedPublishTests)

    private func waitUntil(_ deadline: TimeInterval = 3, _ cond: () -> Bool) async {
        let end = Date().addingTimeInterval(deadline)
        while !cond() && Date() < end {
            try? await Task.sleep(for: .milliseconds(25))
        }
    }

    // MARK: - Invariant assertions (I1-I10)

    private func identityKey(accountId: String, messageId: String, rfc822: String?) -> String {
        if let rfc = rfc822, !rfc.isEmpty { return "\(accountId)|rfc|\(rfc)" }
        return "\(accountId)|mid|\(messageId)"
    }

    /// Runs I1-I10 against the REAL `vm.loadedMessages`/`displayGroups` and
    /// the REAL `InboxListReader.fetchSync` truth (I10). `context` carries
    /// scenario/step identification for debuggable failures — mirrors
    /// `InboxComposeScenarioTests.assertInvariants`'s `context` contract.
    ///
    /// I1/I2/I4/I6 (presence invariants) are gated by `presenceApplies`
    /// (default: `vm.loadedMessages.count < SyncConfig.inboxPageSize`) for the
    /// SAME reason the pure layer gates them — a full/trimmed window
    /// legitimately excludes rows (§4.3). Every named scenario below keeps
    /// its message population small enough that this always holds; the
    /// dedicated I9 pagination scenarios do NOT call this helper mid-`loadMore`
    /// loop (see their own doc comments) — they run their own coverage +
    /// exhaustion assertions, then this helper once at the end.
    private func assertE2EInvariants(
        world: E2EWorld,
        vm: InboxViewModel,
        ai: inout E2EAITracker,
        context: String,
        presenceApplies: Bool? = nil
    ) async throws {
        let composed = vm.loadedMessages
        let displayedFolderIds = Set(vm.folders.map(\.id))
        let composedIdentityList = composed.map {
            identityKey(accountId: $0.accountId, messageId: $0.messageId, rfc822: $0.rfc822MessageId)
        }
        let composedIdentities = Set(composedIdentityList)
        let detail = "\(context) loadedIds=[\(composed.map(\.id).joined(separator: ", "))]"
        let presence = presenceApplies ?? (composed.count < SyncConfig.inboxPageSize)

        for key in world.messageKeys {
            guard let state = world.states[key] else { continue }
            let identity = world.identity(of: key)
            let durable = try await world.durableRow(forKey: key)
            let staged = world.stagedRow(forKey: key)

            // I1 no-resurrection: identity durably present outside the
            // displayed set (or isInInbox=false) ⟹ NOT on screen — unless an
            // undo overlay is actively pinning it back in (P-step).
            if let d = durable,
               !displayedFolderIds.contains(d.folderId) || !d.isInInbox,
               !state.undoActive {
                #expect(
                    !composedIdentities.contains(identity),
                    "I1 no-resurrection VIOLATED for \(key): durable copy is in \(d.folderPath) (isInInbox=\(d.isInInbox)) yet the identity is on screen — \(detail)"
                )
            }

            // I6 move-hides: from userArchive onward (until undo), the
            // identity must be in NO composed list.
            if state.movedAwayByUser {
                #expect(
                    !composedIdentities.contains(identity),
                    "I6 move-hides VIOLATED for \(key): user moved it out but it is on screen — \(detail)"
                )
            }

            if presence {
                // I2 no-vanish (durable-visible limb).
                if let d = durable, d.headerComplete, d.isInInbox,
                   displayedFolderIds.contains(d.folderId), !state.movedAwayByUser {
                    #expect(
                        composedIdentities.contains(identity),
                        "I2 no-vanish (durable) VIOLATED for \(key): headerComplete durable row in displayed folder missing from screen — \(detail)"
                    )
                }
                // I2 no-vanish (staged limb) — not stale-by-move.
                if let s = staged, displayedFolderIds.contains(s.folderId), !state.movedAwayByUser {
                    let staleByMove = durable.map { $0.folderId != s.folderId || !$0.isInInbox } ?? false
                    if !staleByMove {
                        #expect(
                            composedIdentities.contains(identity),
                            "I2 no-vanish (staged) VIOLATED for \(key): staged row present but identity missing from screen — \(detail)"
                        )
                    }
                }
                // I4 undo-visible.
                if state.undoActive {
                    #expect(
                        composedIdentities.contains(identity),
                        "I4 undo-visible VIOLATED for \(key): undone message missing from screen — \(detail)"
                    )
                }
            }
        }

        // I5 no-duplicates.
        #expect(
            Set(composed.map(\.id)).count == composed.count,
            "I5 no-duplicates VIOLATED: duplicate ids on screen — \(detail)"
        )
        #expect(
            composedIdentities.count == composedIdentityList.count,
            "I5 no-duplicates VIOLATED: duplicate identities on screen — \(detail)"
        )

        // I3 AI-monotonic: once a row shows non-nil AI fields, no later
        // settle shows nil for that identity (undo carve-out — mirrors the
        // pure layer: an undone row renders via the P-step from an AI-less
        // durable header until the AI repaint lands).
        let identityToKey: [String: String] = Dictionary(
            uniqueKeysWithValues: world.messageKeys.map { (world.identity(of: $0), $0) }
        )
        for row in composed {
            let identity = identityKey(accountId: row.accountId, messageId: row.messageId, rfc822: row.rfc822MessageId)
            let key = identityToKey[identity]
            let undoActive = key.flatMap { world.states[$0]?.undoActive } ?? false
            var durableRowForKey: MessageHeader?
            if let key { durableRowForKey = try await world.durableRow(forKey: key) }
            if ai.tagSeen.contains(identity), !(undoActive && durableRowForKey?.actionTag == nil) {
                #expect(row.actionTag != nil, "I3 AI-monotonic VIOLATED: actionTag flashed to nil for \(identity) — \(detail)")
            }
            if row.actionTag != nil { ai.tagSeen.insert(identity) }
            if ai.blurbSeen.contains(identity), !(undoActive && durableRowForKey?.summaryBlurb == nil) {
                #expect(row.summaryBlurb != nil, "I3 AI-monotonic VIOLATED: summaryBlurb flashed to nil for \(identity) — \(detail)")
            }
            if row.summaryBlurb != nil { ai.blurbSeen.insert(identity) }
        }

        // I7 window-sanity: sort order + label filter. (Length-vs-window is
        // not checked generically here — `targetWindowSize` is VM-private;
        // the dedicated I9 scenarios check window growth explicitly.)
        if composed.count >= 2 {
            for i in 0..<(composed.count - 1) {
                let a = composed[i], b = composed[i + 1]
                let ordered: Bool
                switch vm.mode {
                case .triage:
                    ordered = a.tagSortOrder < b.tagSortOrder
                        || (a.tagSortOrder == b.tagSortOrder && a.date >= b.date)
                case .normal:
                    ordered = a.date >= b.date
                }
                #expect(ordered, "I7 window-sanity VIOLATED: rows \(i)/\(i + 1) out of \(vm.mode) order — \(detail)")
            }
        }
        if !vm.filterLabelIds.isEmpty {
            for row in composed {
                #expect(
                    vm.filterLabelIds.isSubset(of: Set(row.userLabels.map(\.id))),
                    "I7 window-sanity VIOLATED: row \(row.id) lacks required labels — \(detail)"
                )
            }
        }

        // I8-adjacent structural check: displayGroups is a pure re-projection
        // of loadedMessages — every id must round-trip through it (a
        // divergence would mean the thread grouper silently dropped/duplicated
        // a row the invariants above already validated).
        let groupedIds = Set(vm.displayGroups.flatMap(\.members).map(\.id))
        #expect(
            groupedIds == Set(composed.map(\.id)),
            "displayGroups VIOLATED: grouped ids diverge from loadedMessages — \(detail)"
        )

        // I10 screen-truth convergence: the screen never diverges from a
        // fresh direct reader call built with the VM's own query shape.
        // `targetCount: SyncConfig.inboxPageSize` matches the VM's real
        // internal `targetWindowSize` as long as `loadMoreMessages` was never
        // called in this world (true for every named/fuzz scenario below —
        // the dedicated I9 pagination scenarios do their own convergence
        // check with the grown window size instead of calling this helper).
        let query = InboxListQuery(
            displayedFolderIds: displayedFolderIds, filterUnread: vm.filterUnread,
            filterLabelIds: vm.filterLabelIds, mode: vm.mode,
            targetCount: SyncConfig.inboxPageSize, beforeDate: nil
        )
        let readerTruth = InboxListReader.fetchSync(folders: vm.folders, query: query)
        #expect(
            Set(composed.map(\.id)) == Set(readerTruth.map(\.id)),
            "I10 screen-truth convergence VIOLATED: screen diverges from InboxListReader — \(detail) readerIds=\(readerTruth.map(\.id))"
        )
    }

    // MARK: - Scenario-running helpers (mirror InboxComposeScenarioTests.runSteps / composeRepeatedly)

    /// CAPTURED mode: apply one real step, then settle via a manual
    /// `vm.reloadMessages()` (deterministic — no production listener races).
    private func applyAndSettle(
        _ step: E2EWorld.Step, _ key: String, world: E2EWorld, vm: InboxViewModel,
        ai: inout E2EAITracker, scenario: String
    ) async throws {
        world.clearSignals()
        try await world.apply(step, key, vm: vm, stageTerminal: stageTerminalRow)
        await vm.reloadMessages()
        try await assertE2EInvariants(
            world: world, vm: vm, ai: &ai, context: "scenario=\(scenario) step=\(step.rawValue)(\(key))"
        )
    }

    /// Reloads N times with no step in between (a "reload storm") — mirrors
    /// `InboxComposeScenarioTests.composeRepeatedly`.
    private func reloadRepeatedly(
        _ times: Int, world: E2EWorld, vm: InboxViewModel, ai: inout E2EAITracker, scenario: String, note: String
    ) async throws {
        for n in 0..<times {
            await vm.reloadMessages()
            try await assertE2EInvariants(
                world: world, vm: vm, ai: &ai, context: "scenario=\(scenario) reload#\(n) (\(note))"
            )
        }
    }

    private func containsIdentity(_ vm: InboxViewModel, _ world: E2EWorld, _ key: String) -> Bool {
        let identity = world.identity(of: key)
        return vm.loadedMessages.contains {
            identityKey(accountId: $0.accountId, messageId: $0.messageId, rfc822: $0.rfc822MessageId) == identity
        }
    }

    /// Wires the SAME glue `InboxView` provides at the VIEW layer (VM itself
    /// does not self-subscribe to `.messagesStaged` — see InboxView.swift
    /// ~1749) so a WIRED-mode scenario can exercise the real
    /// merge-publish → instant-insert → reload-eviction pipeline end to end.
    /// Caller must remove the returned observer token.
    private func wireStagedRowViewGlue(_ vm: InboxViewModel) -> NSObjectProtocol {
        NotificationCenter.default.addObserver(forName: .messagesStaged, object: nil, queue: .main) { note in
            guard let rows = note.object as? [StagedInboxRow] else { return }
            Task { @MainActor in vm.insertStagedRows(rows) }
        }
    }

    /// Drives `vm.loadMoreMessages()` in a loop, GUARDED to never call it once
    /// `loadedMessages.count >= totalReachable` — `loadMoreMessages`'s local
    /// (Phase 1) branch resolves synchronously whenever `fetchPage` returns
    /// ANY local rows, but an EXACTLY-EMPTY local page falls through to Phase
    /// 2's REAL network fetch (`manager.fetchOlderMessages`), which this
    /// unit-test host cannot service. Since the harness seeds and controls
    /// every reachable row, `totalReachable` is known exactly — stopping the
    /// instant it's reached is both correct (nothing legitimate remains to
    /// load) and safe (never risks the network branch).
    private func loadMoreToExhaustion(_ vm: InboxViewModel, totalReachable: Int, maxIterations: Int = 20) async {
        var iterations = 0
        while vm.hasMoreMessages && vm.loadedMessages.count < totalReachable && iterations < maxIterations {
            vm.loadMoreMessages()
            try? await Task.sleep(for: .milliseconds(30))
            iterations += 1
        }
    }

    // MARK: - Named scenarios, batch 1 (real-push lifecycle + F1)

    @Test("archivedThenRestagedNeverReappears — boot_logs 3: a silent state-change push re-stages an archived message through the REAL merge; it must never resurrect on the real VM (I1/I6)")
    func archivedThenRestagedNeverReappears() async throws {
        let fixture = try makeFixture()
        defer { cleanup(fixture) }
        let world = E2EWorld(
            pool: fixture.pool, stagingPath: fixture.stagingPath, stagingQueue: fixture.stagingQueue,
            accountId: fixture.accountId, inbox: fixture.inbox, archive: fixture.archive
        )
        defer { world.teardown() }
        let base = Date()
        world.addMessage("m1", uid: "101", minutesAgo: 5, base: base, tag: "reply", blurb: "b1")

        let vm = InboxViewModel(folders: [fixture.inbox])
        var ai = E2EAITracker()

        try await applyAndSettle(.pushArrives, "m1", world: world, vm: vm, ai: &ai, scenario: "archivedThenRestagedNeverReappears")
        #expect(containsIdentity(vm, world, "m1"))

        try await applyAndSettle(.userArchive, "m1", world: world, vm: vm, ai: &ai, scenario: "archivedThenRestagedNeverReappears")
        try await applyAndSettle(.overlayDrain, "m1", world: world, vm: vm, ai: &ai, scenario: "archivedThenRestagedNeverReappears")
        #expect(!containsIdentity(vm, world, "m1"), "setup assumption violated: archived message must be off-screen before the re-stage")

        // §0A driver: a LATER, unrelated push re-stages the SAME message with
        // push-time INBOX folder truth — the merge's stale-by-move detection
        // must suppress it, permanently, at the real DB layer.
        try await applyAndSettle(.silentStateChangePush, "m1", world: world, vm: vm, ai: &ai, scenario: "archivedThenRestagedNeverReappears")
        #expect(!containsIdentity(vm, world, "m1"), "archived message resurrected via re-staged row")

        // Hammer it — the resurrection was flaky/reload-storm-triggered in prod.
        try await reloadRepeatedly(10, world: world, vm: vm, ai: &ai, scenario: "archivedThenRestagedNeverReappears", note: "post re-stage storm")
        #expect(!containsIdentity(vm, world, "m1"))

        // At-least-once redelivery of the same stale identity.
        try await applyAndSettle(.redeliver, "m1", world: world, vm: vm, ai: &ai, scenario: "archivedThenRestagedNeverReappears")
        #expect(!containsIdentity(vm, world, "m1"), "archived message resurrected after redelivery")
    }

    @Test("scrubOnlyWakeStillConverges — F1's exact history, WIRED mode: a scrub-only merge wake must post a render signal that evicts the phantom from the REAL VM without any test-driven manual reload")
    func scrubOnlyWakeStillConverges() async throws {
        let fixture = try makeFixture()
        defer { cleanup(fixture) }
        let world = E2EWorld(
            pool: fixture.pool, stagingPath: fixture.stagingPath, stagingQueue: fixture.stagingQueue,
            accountId: fixture.accountId, inbox: fixture.inbox, archive: fixture.archive
        )
        defer { world.teardown() }
        let base = Date()
        world.addMessage("m1", uid: "101", minutesAgo: 5, base: base)

        let vm = InboxViewModel(folders: [fixture.inbox])
        vm.start()
        let glueObs = wireStagedRowViewGlue(vm)
        defer { NotificationCenter.default.removeObserver(glueObs) }
        var ai = E2EAITracker()

        // Land it durably in inbox, then archive it (setup — not under test).
        try await world.apply(.pushArrives, "m1", vm: vm, stageTerminal: stageTerminalRow)
        await waitUntil { vm.loadedMessages.contains { $0.messageId == "101" } }
        try await world.apply(.userArchive, "m1", vm: vm, stageTerminal: stageTerminalRow)
        await vm.reloadMessages()
        try await world.apply(.overlayDrain, "m1", vm: vm, stageTerminal: stageTerminalRow)
        await vm.reloadMessages()
        #expect(!vm.loadedMessages.contains { $0.messageId == "101" }, "setup assumption violated: archived row must be off-screen before the scrub-only wake")
        try await assertE2EInvariants(world: world, vm: vm, ai: &ai, context: "scrubOnlyWakeStillConverges pre-scrub settle")

        // THE SCRUB-ONLY WAKE under test: a later, unrelated push re-stages
        // the SAME message with push-time INBOX truth. The merge finds the
        // durable copy stale-by-move (now in Archive) — no durable write
        // happens this wake, only a staging scrub — but the wired View glue
        // above inserts the pre-detection `.messagesStaged` payload as an
        // IN-MEMORY phantom, exactly boot_logs 3's shape. I8 requires a
        // render signal to follow that evicts it — WITHOUT any manual
        // reloadMessages() call from this test.
        world.clearSignals()
        try await world.apply(.silentStateChangePush, "m1", vm: vm, stageTerminal: stageTerminalRow)

        await waitUntil(5) { !vm.loadedMessages.contains { $0.messageId == "101" } }

        #expect(
            !vm.loadedMessages.contains { $0.messageId == "101" },
            "F1 REGRESSION: scrub-only wake's phantom never left the WIRED VM's screen — the render signal that should evict it did not converge"
        )
        #expect(
            world.capturedSignals.contains("inboxDataDidChange") || world.capturedSignals.contains("messagesStaged"),
            "I8 signal-liveness VIOLATED: scrub-only wake changed the expected-visible set (evicted the phantom) but posted no .inboxDataDidChange/.messagesStaged — captured=\(world.capturedSignals)"
        )
        try await assertE2EInvariants(world: world, vm: vm, ai: &ai, context: "scrubOnlyWakeStillConverges post-scrub settle")
    }

    @Test("stagedSurvivesReloadStorm — a staged row published with no durable write yet survives arbitrarily many REAL reloads through InboxListReader (I2)")
    func stagedSurvivesReloadStorm() async throws {
        let fixture = try makeFixture()
        defer { cleanup(fixture) }
        let world = E2EWorld(
            pool: fixture.pool, stagingPath: fixture.stagingPath, stagingQueue: fixture.stagingQueue,
            accountId: fixture.accountId, inbox: fixture.inbox, archive: fixture.archive
        )
        defer { world.teardown() }
        world.addMessage("m1", uid: "101", minutesAgo: 5, base: Date())
        world.publishStagedOnly("m1")

        let vm = InboxViewModel(folders: [fixture.inbox])
        var ai = E2EAITracker()
        try await reloadRepeatedly(25, world: world, vm: vm, ai: &ai, scenario: "stagedSurvivesReloadStorm", note: "no durable write — pre-durability")
        #expect(containsIdentity(vm, world, "m1"), "staged row vanished during a reload storm")
    }

    @Test("readOverlayDoesNotEvictStaged — an isRead-only overlay mutation never evicts a staged row through a REAL reload (race 1, f843c02 class)")
    func readOverlayDoesNotEvictStaged() async throws {
        let fixture = try makeFixture()
        defer { cleanup(fixture) }
        let world = E2EWorld(
            pool: fixture.pool, stagingPath: fixture.stagingPath, stagingQueue: fixture.stagingQueue,
            accountId: fixture.accountId, inbox: fixture.inbox, archive: fixture.archive
        )
        defer { world.teardown() }
        world.addMessage("m1", uid: "101", minutesAgo: 5, base: Date())
        world.publishStagedOnly("m1")

        let vm = InboxViewModel(folders: [fixture.inbox])
        var ai = E2EAITracker()
        try await applyAndSettle(.userRead, "m1", world: world, vm: vm, ai: &ai, scenario: "readOverlayDoesNotEvictStaged")
        #expect(containsIdentity(vm, world, "m1"), "staged row evicted by a non-removing (isRead) overlay mutation")
        #expect(vm.loadedMessages.first { $0.messageId == "101" }?.isRead == true, "overlay isRead not applied to the staged row")
    }

    @Test("aiNeverFlashesAcrossWakes — a gradual TWO-wake push (header-only, then body+AI) never regresses actionTag/summaryBlurb to nil across the wake boundary or subsequent reloads (I3; E2E granularity is per-wake, see file header doc)")
    func aiNeverFlashesAcrossWakes() async throws {
        let fixture = try makeFixture()
        defer { cleanup(fixture) }
        let world = E2EWorld(
            pool: fixture.pool, stagingPath: fixture.stagingPath, stagingQueue: fixture.stagingQueue,
            accountId: fixture.accountId, inbox: fixture.inbox, archive: fixture.archive
        )
        defer { world.teardown() }
        world.addMessage("m1", uid: "101", minutesAgo: 5, base: Date(), tag: "reply", blurb: "real blurb")

        let vm = InboxViewModel(folders: [fixture.inbox])
        var ai = E2EAITracker()

        // Wake 1: header only, aiCompleted=0.
        try stageHeaderOnlyRow(world, key: "m1", folderPath: world.inboxPath)
        await NSEDataBridge.mergeNSEStagingData(stagingPathOverride: world.stagingPath)
        world.markStagedAndDurable("m1")
        await vm.reloadMessages()
        try await assertE2EInvariants(world: world, vm: vm, ai: &ai, context: "aiNeverFlashesAcrossWakes after wake 1 (header-only)")
        #expect(vm.loadedMessages.first { $0.messageId == "101" }?.actionTag == nil, "wake-1 setup assumption violated: AI must not be present yet")

        // Wake 2: body + terminal AI lands on the SAME staging row.
        try stageBodyAndAIRow(world, key: "m1")
        await NSEDataBridge.mergeNSEStagingData(stagingPathOverride: world.stagingPath)
        await vm.reloadMessages()
        try await assertE2EInvariants(world: world, vm: vm, ai: &ai, context: "aiNeverFlashesAcrossWakes after wake 2 (body+AI)")
        #expect(vm.loadedMessages.first { $0.messageId == "101" }?.actionTag == .reply)
        #expect(vm.loadedMessages.first { $0.messageId == "101" }?.summaryBlurb == "real blurb")

        // Storm it — monotonicity must hold across every subsequent reload.
        try await reloadRepeatedly(10, world: world, vm: vm, ai: &ai, scenario: "aiNeverFlashesAcrossWakes", note: "post-AI-landing storm")
        #expect(vm.loadedMessages.first { $0.messageId == "101" }?.actionTag == .reply)
    }

    // MARK: - Named scenarios, batch 2 (undo / stale-delete self-heal / UID remap / redelivery / filters)

    @Test("undoSurvivesEveryReload — from undo onward the row is in EVERY REAL reload, before AND after the restore write, across overlay drain (I4)")
    func undoSurvivesEveryReload() async throws {
        let fixture = try makeFixture()
        defer { cleanup(fixture) }
        let world = E2EWorld(
            pool: fixture.pool, stagingPath: fixture.stagingPath, stagingQueue: fixture.stagingQueue,
            accountId: fixture.accountId, inbox: fixture.inbox, archive: fixture.archive
        )
        defer { world.teardown() }
        world.addMessage("m1", uid: "101", minutesAgo: 5, base: Date())

        let vm = InboxViewModel(folders: [fixture.inbox])
        var ai = E2EAITracker()

        // Land it, then archive it (write lands, overlay drains) — setup.
        try await applyAndSettle(.pushArrives, "m1", world: world, vm: vm, ai: &ai, scenario: "undoSurvivesEveryReload")
        try await applyAndSettle(.userArchive, "m1", world: world, vm: vm, ai: &ai, scenario: "undoSurvivesEveryReload")
        try await applyAndSettle(.overlayDrain, "m1", world: world, vm: vm, ai: &ai, scenario: "undoSurvivesEveryReload")
        #expect(!containsIdentity(vm, world, "m1"))

        // Undo: overlay back-to-inbox + insertUndoneMessages, DB restore
        // write still DEFERRED (mirrors UndoService.undo()'s real timeline).
        try await applyAndSettle(.undo, "m1", world: world, vm: vm, ai: &ai, scenario: "undoSurvivesEveryReload")
        #expect(containsIdentity(vm, world, "m1"), "undone row missing immediately after undo (P-step hole)")

        // The latent hole the P-step closes: reloads between undo and the
        // restore write must never evict the row.
        try await reloadRepeatedly(15, world: world, vm: vm, ai: &ai, scenario: "undoSurvivesEveryReload", note: "pre-restore-write storm")
        #expect(containsIdentity(vm, world, "m1"), "undone row vanished during pre-restore-write reload storm")

        try await applyAndSettle(.undoRestoreWrite, "m1", world: world, vm: vm, ai: &ai, scenario: "undoSurvivesEveryReload")
        try await applyAndSettle(.overlayDrain, "m1", world: world, vm: vm, ai: &ai, scenario: "undoSurvivesEveryReload")
        #expect(containsIdentity(vm, world, "m1"), "undone row vanished after restore write / overlay drain")
    }

    @Test("staleDeleteSelfHeals — a real sync stale-delete of the durable row leaves a still-published staged row eligible again; the REAL VM never blanks (§2.3 emergent property)")
    func staleDeleteSelfHeals() async throws {
        let fixture = try makeFixture()
        defer { cleanup(fixture) }
        let world = E2EWorld(
            pool: fixture.pool, stagingPath: fixture.stagingPath, stagingQueue: fixture.stagingQueue,
            accountId: fixture.accountId, inbox: fixture.inbox, archive: fixture.archive
        )
        defer { world.teardown() }
        world.addMessage("m1", uid: "101", minutesAgo: 5, base: Date())

        let vm = InboxViewModel(folders: [fixture.inbox])
        var ai = E2EAITracker()

        // Durable row lands via an ordinary sync-created header (no NSE
        // staging involved at all) — then a REAL merge publish keeps the
        // identity ALSO present in S (models the window where a kept
        // gradual staging row co-exists with an already-durable header —
        // NSEGradualMergeTests' shape — via the same real publish seam
        // `publishStagedOnly` documents).
        try await world.apply(.syncCreatesHeader, "m1", vm: vm, stageTerminal: stageTerminalRow)
        world.publishStagedOnly("m1")
        await vm.reloadMessages()
        try await assertE2EInvariants(world: world, vm: vm, ai: &ai, context: "staleDeleteSelfHeals pre-delete settle")
        #expect(containsIdentity(vm, world, "m1"))

        // Sync transiently stale-deletes the durable row (a real GRDB DELETE).
        try await world.apply(.staleDelete, "m1", vm: vm, stageTerminal: stageTerminalRow)
        await vm.reloadMessages()
        try await assertE2EInvariants(world: world, vm: vm, ai: &ai, context: "staleDeleteSelfHeals post-delete settle")
        #expect(
            containsIdentity(vm, world, "m1"),
            "display blanked after a transient sync stale-delete — the still-published S row did not become re-eligible"
        )
    }

    @Test("uidRemapArchiveSuppressesStaged — a REAL server-side MOVE re-keys the durable row; the stale re-staged INBOX row is suppressed via the rfc822 fallback through the real merge (I1/I5, 485a4d1 class)")
    func uidRemapArchiveSuppressesStaged() async throws {
        let fixture = try makeFixture()
        defer { cleanup(fixture) }
        let world = E2EWorld(
            pool: fixture.pool, stagingPath: fixture.stagingPath, stagingQueue: fixture.stagingQueue,
            accountId: fixture.accountId, inbox: fixture.inbox, archive: fixture.archive
        )
        defer { world.teardown() }
        world.addMessage("m1", uid: "101", minutesAgo: 5, base: Date())

        let vm = InboxViewModel(folders: [fixture.inbox])
        var ai = E2EAITracker()

        try await applyAndSettle(.pushArrives, "m1", world: world, vm: vm, ai: &ai, scenario: "uidRemapArchiveSuppressesStaged")
        try await applyAndSettle(.uidRemap, "m1", world: world, vm: vm, ai: &ai, scenario: "uidRemapArchiveSuppressesStaged")
        #expect(!containsIdentity(vm, world, "m1"), "setup assumption violated: remapped/archived row must already be off-screen")

        // Stale re-stage under the OLD uid + INBOX folder — the merge's
        // rfc822-fallback identity lookup must find the re-keyed Archive row.
        try await applyAndSettle(.silentStateChangePush, "m1", world: world, vm: vm, ai: &ai, scenario: "uidRemapArchiveSuppressesStaged")
        #expect(
            !containsIdentity(vm, world, "m1"),
            "UID-remapped archived message resurrected — rfc822 fallback identity lookup failed to suppress the stale staged row"
        )
    }

    @Test("pushRedeliveryIsIdempotent — REAL at-least-once duplicates through the merge never produce a second row (I5) at any lifecycle stage")
    func pushRedeliveryIsIdempotent() async throws {
        let fixture = try makeFixture()
        defer { cleanup(fixture) }
        let world = E2EWorld(
            pool: fixture.pool, stagingPath: fixture.stagingPath, stagingQueue: fixture.stagingQueue,
            accountId: fixture.accountId, inbox: fixture.inbox, archive: fixture.archive
        )
        defer { world.teardown() }
        world.addMessage("m1", uid: "101", minutesAgo: 5, base: Date())

        let vm = InboxViewModel(folders: [fixture.inbox])
        var ai = E2EAITracker()

        try await applyAndSettle(.pushArrives, "m1", world: world, vm: vm, ai: &ai, scenario: "pushRedeliveryIsIdempotent")
        #expect(vm.loadedMessages.count == 1)

        for i in 0..<4 {
            try await applyAndSettle(.redeliver, "m1", world: world, vm: vm, ai: &ai, scenario: "pushRedeliveryIsIdempotent redelivery#\(i)")
        }
        #expect(vm.loadedMessages.count == 1, "push redelivery produced a duplicate row")
        #expect(containsIdentity(vm, world, "m1"))
    }

    @Test("unreadFilter — a REAL vm.filterUnread excludes read staged rows AND read durable rows through InboxListReader's SQL + compose paths")
    func unreadFilterScenario() async throws {
        let fixture = try makeFixture()
        defer { cleanup(fixture) }
        let world = E2EWorld(
            pool: fixture.pool, stagingPath: fixture.stagingPath, stagingQueue: fixture.stagingQueue,
            accountId: fixture.accountId, inbox: fixture.inbox, archive: fixture.archive
        )
        defer { world.teardown() }
        let base = Date()
        world.addMessage("mReadStaged", uid: "101", minutesAgo: 1, base: base, isReadAtPush: true)
        world.addMessage("mUnreadStaged", uid: "102", minutesAgo: 2, base: base)
        world.addMessage("mUnreadDurable", uid: "103", minutesAgo: 3, base: base)

        let vm = InboxViewModel(folders: [fixture.inbox])
        // `pushArrives` runs a REAL merge, which REPLACES `latestStagedRows`
        // wholesale with whatever the staging FILE currently holds (mirrors
        // production: the merge is the snapshot's ONLY publisher). It must
        // run BEFORE the `publishStagedOnly` calls below — those write
        // DIRECTLY into the in-memory snapshot and would otherwise be wiped
        // out by the next real merge's replace-all (the merge has no idea
        // about identities it never staged to the file).
        try await world.apply(.pushArrives, "mUnreadDurable", vm: vm, stageTerminal: stageTerminalRow)
        world.publishStagedOnly("mReadStaged")
        world.publishStagedOnly("mUnreadStaged")

        vm.filterUnread = true
        vm.resetMessages()

        #expect(vm.loadedMessages.count == 2)
        #expect(!containsIdentity(vm, world, "mReadStaged"), "read staged row leaked through filterUnread")
        #expect(containsIdentity(vm, world, "mUnreadStaged"))
        #expect(containsIdentity(vm, world, "mUnreadDurable"))

        // A userRead overlay on the staged row must also drop it (S is
        // filtered POST-overlay — insertStagedRows parity, §2.1 step 4).
        try await world.apply(.userRead, "mUnreadStaged", vm: vm, stageTerminal: stageTerminalRow)
        await vm.reloadMessages()
        #expect(!containsIdentity(vm, world, "mUnreadStaged"), "post-overlay read staged row leaked through filterUnread")
    }

    // MARK: - Named scenarios, batch 3 (labels / triage order / window trim / cross-account)

    @Test("labelFilter — an unlabeled staged row drops through a REAL vm.filterLabelIds while a genuinely labeled durable row survives IN THE SAME query (negative + positive paths)")
    func labelFilterScenario() async throws {
        let fixture = try makeFixture()
        defer { cleanup(fixture) }
        let world = E2EWorld(
            pool: fixture.pool, stagingPath: fixture.stagingPath, stagingQueue: fixture.stagingQueue,
            accountId: fixture.accountId, inbox: fixture.inbox, archive: fixture.archive
        )
        defer { world.teardown() }
        let base = Date()
        world.addMessage("mLabeledDurable", uid: "101", minutesAgo: 1, base: base)
        world.addMessage("mUnlabeledStaged", uid: "102", minutesAgo: 2, base: base)

        let vm = InboxViewModel(folders: [fixture.inbox])
        try await world.apply(.pushArrives, "mLabeledDurable", vm: vm, stageTerminal: stageTerminalRow)
        let labeledId = try await world.currentId(forKey: "mLabeledDurable")
        try await fixture.pool.writeWithoutTransaction { db in
            try UserLabel(id: "label-x", accountId: fixture.accountId, name: "Filtered", isSystem: false).insert(db)
            try MessageUserLabel(messageId: labeledId, userLabelId: "label-x").insert(db)
        }
        world.publishStagedOnly("mUnlabeledStaged")

        vm.filterLabelIds = ["label-x"]
        vm.resetMessages()

        #expect(vm.loadedMessages.count == 1, "expected exactly the labeled durable row to survive, got ids=\(vm.loadedMessages.map(\.id))")
        #expect(containsIdentity(vm, world, "mLabeledDurable"), "labeled durable row dropped by the active label filter — positive path failed")
        #expect(!containsIdentity(vm, world, "mUnlabeledStaged"), "staged (unlabeled) row leaked through an active label filter — negative path failed")
        #expect(vm.loadedMessages.first?.userLabels.map(\.id) == ["label-x"], "userLabels not carried onto the composed durable row")
    }

    @Test("triageOrder — REAL durable rows sort by tagSortOrder asc then date desc through the real VM in .triage mode")
    func triageOrderScenario() async throws {
        let fixture = try makeFixture()
        defer { cleanup(fixture) }
        let world = E2EWorld(
            pool: fixture.pool, stagingPath: fixture.stagingPath, stagingQueue: fixture.stagingQueue,
            accountId: fixture.accountId, inbox: fixture.inbox, archive: fixture.archive
        )
        defer { world.teardown() }
        let base = Date()
        world.addMessage("mReplyOld", uid: "101", minutesAgo: 60, base: base, tag: "reply")
        world.addMessage("mArchiveNew", uid: "102", minutesAgo: 1, base: base, tag: "archive")

        let vm = InboxViewModel(folders: [fixture.inbox])
        vm.mode = .triage
        try await world.apply(.pushArrives, "mReplyOld", vm: vm, stageTerminal: stageTerminalRow)
        try await world.apply(.pushArrives, "mArchiveNew", vm: vm, stageTerminal: stageTerminalRow)
        world.addMessage("mReplyStaged", uid: "103", minutesAgo: 120, base: base, tag: "reply")
        world.publishStagedOnly("mReplyStaged")
        vm.resetMessages()

        #expect(vm.loadedMessages.count == 3)
        guard vm.loadedMessages.count == 3 else { return }
        // reply(0) tier first (newest-first within tier), archive tier last.
        #expect(vm.loadedMessages[0].messageId == "101")
        #expect(vm.loadedMessages[1].messageId == "103")
        #expect(vm.loadedMessages[2].messageId == "102")
    }

    @Test("windowTrim — REAL InboxListReader (real DB + real staged snapshot) trims to a small targetCount; a newer staged row displaces the oldest durable row (§4.3). Driven directly against InboxListReader (not the VM) since production's VM window is fixed at SyncConfig.inboxPageSize — this reproduces compose's trim logic against real inputs at a size the VM can't be coerced into.")
    func windowTrimScenario() async throws {
        let fixture = try makeFixture()
        defer { cleanup(fixture) }
        let world = E2EWorld(
            pool: fixture.pool, stagingPath: fixture.stagingPath, stagingQueue: fixture.stagingQueue,
            accountId: fixture.accountId, inbox: fixture.inbox, archive: fixture.archive
        )
        defer { world.teardown() }
        let base = Date()
        world.addMessage("d1", uid: "101", minutesAgo: 10, base: base)
        world.addMessage("d2", uid: "102", minutesAgo: 20, base: base)
        world.addMessage("d3", uid: "103", minutesAgo: 30, base: base)
        world.addMessage("sNew", uid: "104", minutesAgo: 1, base: base)

        let vm = InboxViewModel(folders: [fixture.inbox])
        for key in ["d1", "d2", "d3"] {
            try await world.apply(.pushArrives, key, vm: vm, stageTerminal: stageTerminalRow)
        }
        world.publishStagedOnly("sNew")

        let query = InboxListQuery(
            displayedFolderIds: [fixture.inbox.id], filterUnread: false, filterLabelIds: [],
            mode: .normal, targetCount: 3, beforeDate: nil
        )
        let composed = InboxListReader.fetchSync(folders: [fixture.inbox], query: query)
        #expect(composed.count == 3)
        guard composed.count == 3 else { return }
        #expect(composed[0].messageId == "104", "newest staged row missing from the trimmed window")
        #expect(composed[1].messageId == "101")
        #expect(composed[2].messageId == "102")
        #expect(!composed.contains { $0.messageId == "103" }, "oldest durable row not displaced by the window trim")
    }

    @Test("crossAccountIsolation — a second account's push/archive lifecycle is fully isolated: identity dedup, stale-by-move suppression, and overlay scoping never leak across accountId in a real unified-inbox VM")
    func crossAccountIsolationScenario() async throws {
        let (fixture, acc2Id, inbox2, archive2) = try makeTwoAccountFixture()
        defer { cleanup(fixture) }
        let world1 = E2EWorld(
            pool: fixture.pool, stagingPath: fixture.stagingPath, stagingQueue: fixture.stagingQueue,
            accountId: fixture.accountId, inbox: fixture.inbox, archive: fixture.archive
        )
        let world2 = E2EWorld(
            pool: fixture.pool, stagingPath: fixture.stagingPath, stagingQueue: fixture.stagingQueue,
            accountId: acc2Id, inbox: inbox2, archive: archive2
        )
        defer { world1.teardown(); world2.teardown() }
        let base = Date()
        // SAME raw uid across accounts — a legitimate collision (no shared
        // identity space across accountId; DurableIdentityLookup step 1/2
        // both scope on accountId).
        world1.addMessage("acc1msg", uid: "101", minutesAgo: 5, base: base)
        world2.addMessage("acc2msg", uid: "101", minutesAgo: 5, base: base)

        let vm = InboxViewModel(folders: [fixture.inbox, inbox2])
        try await world1.apply(.pushArrives, "acc1msg", vm: vm, stageTerminal: stageTerminalRow)
        try await world2.apply(.pushArrives, "acc2msg", vm: vm, stageTerminal: stageTerminalRow)
        await vm.reloadMessages()

        #expect(vm.loadedMessages.count == 2, "same-UID cross-account messages must not collide/dedupe")
        var ai1 = E2EAITracker()
        try await assertE2EInvariants(world: world1, vm: vm, ai: &ai1, context: "crossAccountIsolation acc1 after both pushes")
        var ai2 = E2EAITracker()
        try await assertE2EInvariants(world: world2, vm: vm, ai: &ai2, context: "crossAccountIsolation acc2 after both pushes")

        // Archive account 1's message — account 2's message must be
        // completely unaffected (folderId/overlay scoping is per-identity,
        // not per-raw-uid).
        try await world1.apply(.userArchive, "acc1msg", vm: vm, stageTerminal: stageTerminalRow)
        await vm.reloadMessages()
        try await world1.apply(.overlayDrain, "acc1msg", vm: vm, stageTerminal: stageTerminalRow)
        await vm.reloadMessages()

        #expect(!containsIdentity(vm, world1, "acc1msg"), "account 1's archived message still on screen")
        #expect(containsIdentity(vm, world2, "acc2msg"), "account 2's message was collaterally evicted by account 1's archive — cross-account leak")

        // A stale re-stage of account 1's (now archived) identity must not
        // resurrect it OR touch account 2's identical-UID message.
        try await world1.apply(.silentStateChangePush, "acc1msg", vm: vm, stageTerminal: stageTerminalRow)
        await vm.reloadMessages()
        #expect(!containsIdentity(vm, world1, "acc1msg"), "account 1's archived message resurrected via re-stage")
        #expect(containsIdentity(vm, world2, "acc2msg"), "account 2's message evicted by account 1's stale-by-move scrub — cross-account leak")
        #expect(vm.loadedMessages.count == 1)
    }

    // MARK: - I9 pagination-completeness scenarios (dedicated — not per-step invariant checks)

    @Test("paginationCompletenessNormal — I9: loadMoreToExhaustion over 2.5 pages of durable mail across 2 folders surfaces every reachable id exactly once; hasMoreMessages goes false only at true exhaustion")
    func paginationCompletenessNormalScenario() async throws {
        let fixture = try makeFixture()
        defer { cleanup(fixture) }
        let second = Folder(name: "Second", path: "Second", role: .inbox, accountId: fixture.accountId)
        try await fixture.pool.writeWithoutTransaction { db in try second.insert(db) }

        let base = Date()
        let total = Int(Double(SyncConfig.inboxPageSize) * 2.5) // non-exact multiple — see loadMoreToExhaustion's doc comment
        // Build ids INSIDE the (Sendable) write closure and return them —
        // Swift 6 strict concurrency forbids mutating a captured `var` from
        // within `writeWithoutTransaction`'s closure; merge into a plain
        // local afterward instead.
        let insertedIds: [String] = try await fixture.pool.writeWithoutTransaction { db in
            var ids: [String] = []
            for i in 0..<total {
                let folder = i.isMultiple(of: 2) ? fixture.inbox : second
                var header = MessageHeader(
                    messageId: "pg-\(i)", subject: "Subj \(i)", from: "Sender", fromAddress: "s@example.com",
                    to: "me@example.com", date: base.addingTimeInterval(-60 * Double(i + 1)), snippet: "snip",
                    folderId: folder.id, accountId: fixture.accountId, folderPath: folder.path, isInInbox: true
                )
                header.rfc822MessageId = "rfc-pg-\(i)@example.com"
                header.headerComplete = true
                try header.insert(db)
                ids.append(header.id)
            }
            return ids
        }
        let expectedIds = Set(insertedIds)
        #expect(expectedIds.count == total)

        let vm = InboxViewModel(folders: [fixture.inbox, second])
        #expect(vm.loadedMessages.count == SyncConfig.inboxPageSize)
        #expect(vm.hasMoreMessages == true)

        await loadMoreToExhaustion(vm, totalReachable: total)

        let loadedIds = Set(vm.loadedMessages.map(\.id))
        #expect(loadedIds == expectedIds, "I9 VIOLATED: pagination did not surface every reachable id exactly once — missing=\(expectedIds.subtracting(loadedIds).count) extra=\(loadedIds.subtracting(expectedIds).count)")
        #expect(vm.loadedMessages.count == vm.loadedMessages.map(\.id).count, "I9 VIOLATED: duplicate ids across pages") // reinforces I5 at scale
        #expect(!vm.hasMoreMessages, "I9 VIOLATED: hasMoreMessages still true at true exhaustion")
    }

    /// F2 repro shape (PLAN_INBOX_UNIFIED_READ.md audit): one folder carries a
    /// single very-OLD but tag-first row that sorts AHEAD of everything in
    /// triage mode; the OTHER folder carries enough rows that page 1's trim
    /// bumps exactly one "newer" row into page 2's candidate set. Before the
    /// F2 fix, `compose` trimmed to `targetCount` BEFORE excluding
    /// already-loaded ids, so `replyOld` re-entering page 2's D query ate a
    /// trim slot and silently dropped a legitimately older, not-yet-loaded
    /// row. Mirrors `InboxListBehaviorPinningTests.
    /// loadMoreMessagesExcludeIdsOrderingMultiFolder`'s exact seed shape, but
    /// driven to FULL exhaustion (I9) rather than stopping at page 2.
    @Test("paginationCompletenessTriage — I9/F2: an old, low-tagSortOrder row from a second folder re-entering later pages never shrinks a page or drops reachable rows in triage mode")
    func paginationCompletenessTriageScenario() async throws {
        let fixture = try makeFixture()
        defer { cleanup(fixture) }
        let priority = Folder(name: "Priority", path: "Priority", role: .inbox, accountId: fixture.accountId)
        try await fixture.pool.writeWithoutTransaction { db in try priority.insert(db) }

        let pageSize = SyncConfig.inboxPageSize
        let base = Date()

        // Build ids INSIDE the (Sendable) write closure and return them — see
        // paginationCompletenessNormalScenario's comment on the same pattern.
        let insertedIds: [String] = try await fixture.pool.writeWithoutTransaction { db in
            var ids: [String] = []
            // Priority folder: ONE reply-tagged row, far older than
            // everything else — triage sorts it FIRST on tagSortOrder alone.
            var replyOld = MessageHeader(
                messageId: "reply-old", subject: "Old reply", from: "Sender", fromAddress: "s@example.com",
                to: "me@example.com", date: base.addingTimeInterval(-60 * 200), snippet: "snip",
                folderId: priority.id, accountId: fixture.accountId, folderPath: priority.path, isInInbox: true
            )
            replyOld.rfc822MessageId = "rfc-reply-old@example.com"
            replyOld.headerComplete = true
            replyOld.actionTag = .reply
            replyOld.tagSortOrder = ActionTag.reply.sortOrder
            try replyOld.insert(db)
            ids.append(replyOld.id)

            // Inbox folder: pageSize "newer" rows + pageSize "older" rows —
            // total = 1 + pageSize + pageSize = 2*pageSize + 1, NOT an exact
            // multiple of pageSize (see paginationCompletenessNormalScenario
            // doc — loadMoreToExhaustion relies on the terminal local page
            // being a nonzero PARTIAL page so hasMoreMessages flips false
            // without ever reaching the empty-page network branch).
            for i in 0..<pageSize {
                var h = MessageHeader(
                    messageId: "newer-\(i)", subject: "Subj", from: "Sender", fromAddress: "s@example.com",
                    to: "me@example.com", date: base.addingTimeInterval(-60 * Double(i + 1)), snippet: "snip",
                    folderId: fixture.inbox.id, accountId: fixture.accountId, folderPath: fixture.inbox.path, isInInbox: true
                )
                h.rfc822MessageId = "rfc-newer-\(i)@example.com"
                h.headerComplete = true
                try h.insert(db)
                ids.append(h.id)
            }
            for i in 0..<pageSize {
                var h = MessageHeader(
                    messageId: "older-\(i)", subject: "Subj", from: "Sender", fromAddress: "s@example.com",
                    to: "me@example.com", date: base.addingTimeInterval(-60 * Double(pageSize + 1 + i)), snippet: "snip",
                    folderId: fixture.inbox.id, accountId: fixture.accountId, folderPath: fixture.inbox.path, isInInbox: true
                )
                h.rfc822MessageId = "rfc-older-\(i)@example.com"
                h.headerComplete = true
                try h.insert(db)
                ids.append(h.id)
            }
            return ids
        }
        let expectedIds = Set(insertedIds)
        let total = expectedIds.count // 1 + pageSize + pageSize = 2*pageSize + 1, not an exact multiple of pageSize

        let vm = InboxViewModel(folders: [priority, fixture.inbox])
        vm.mode = .triage
        vm.resetMessages()

        #expect(vm.loadedMessages.count == pageSize)
        #expect(vm.hasMoreMessages == true)

        await loadMoreToExhaustion(vm, totalReachable: total)

        let loadedIds = Set(vm.loadedMessages.map(\.id))
        #expect(loadedIds == expectedIds, "I9/F2 VIOLATED: pagination did not surface every reachable id exactly once — missing=\(expectedIds.subtracting(loadedIds).count) extra=\(loadedIds.subtracting(expectedIds).count)")
        #expect(!vm.hasMoreMessages, "I9/F2 VIOLATED: hasMoreMessages still true at true exhaustion")
    }

    // MARK: - Seeded fuzz (bounded — real DB/merge per step, so kept much smaller
    // than the pure layer's thousands-of-compositions fuzz per §5B's "small
    // seeded fuzz (real-DB bounded)" scale note)

    /// `SplitMix64` is defined once, at file scope, in
    /// `InboxComposeScenarioTests.swift` (same target) — reused here rather
    /// than redeclared, per repo rule "check if a similar function exists
    /// before implementing" (CLAUDE.md). Fixed seeds only, no
    /// `SystemRandomNumberGenerator`/`Date()`-derived entropy in test logic.
    @Test(
        "seeded fuzz: I1-I10 hold across random legal step sequences through the REAL pipeline (bounded — 2 seeds × 15 sequences × ≤8 steps)",
        arguments: [UInt64(0x5EED_0000_0000_0001), UInt64(0x5EED_0000_0000_0002)]
    )
    func seededFuzzInvariants(seed: UInt64) async throws {
        var rng = SplitMix64(seed: seed)
        for sequence in 0..<15 {
            let fixture = try makeFixture()
            defer { cleanup(fixture) }
            let world = E2EWorld(
                pool: fixture.pool, stagingPath: fixture.stagingPath, stagingQueue: fixture.stagingQueue,
                accountId: fixture.accountId, inbox: fixture.inbox, archive: fixture.archive
            )
            defer { world.teardown() }
            let base = Date()
            world.addMessage("f1", uid: "201", minutesAgo: 1, base: base, tag: "reply", blurb: "blurb-f1")
            world.addMessage("f2", uid: "202", minutesAgo: 2, base: base)
            world.addMessage("f3", uid: "203", minutesAgo: 3, base: base, tag: "archive", blurb: "blurb-f3")

            let vm = InboxViewModel(folders: [fixture.inbox])
            var ai = E2EAITracker()

            let stepCount = 2 + rng.pick(7) // 2...8 steps
            for stepIndex in 0..<stepCount {
                var legal: [(E2EWorld.Step, String)] = []
                for step in E2EWorld.Step.allCases {
                    for key in world.messageKeys where world.isLegal(step, key) {
                        legal.append((step, key))
                    }
                }
                guard !legal.isEmpty else { break }
                let (step, key) = legal[rng.pick(legal.count)]
                try await world.apply(step, key, vm: vm, stageTerminal: stageTerminalRow)
                await vm.reloadMessages()
                try await assertE2EInvariants(
                    world: world, vm: vm, ai: &ai,
                    context: "fuzz seed=0x\(String(seed, radix: 16)) sequence=\(sequence) step[\(stepIndex)]=\(step.rawValue)(\(key))"
                )
            }
        }
    }
}

// MARK: - E2EWorld — the real-mechanism counterpart of InboxComposeScenarioTests.SimWorld

/// Drives REAL mechanisms (staging DB + `mergeNSEStagingData` + GRDB writes +
/// `AccountManager` overlay + `InboxViewModel`) instead of synthesizing value
/// states. Tracks the SAME lifecycle bookkeeping shape as the pure layer's
/// `SimWorld.MessageState` (`everStaged`/`movedAwayByUser`/`undoActive`/etc.)
/// so the fuzz mode's legality function can enumerate legal (step, key) pairs
/// WITHOUT a database round-trip per check — the bookkeeping is kept in sync
/// with reality because this World is the sole writer for the identities it
/// tracks. Captures `.inboxDataDidChange`/`.messagesStaged` posts for I8.
@MainActor
final class E2EWorld {
    let pool: DatabasePool
    let stagingPath: String
    let stagingQueue: DatabaseQueue
    let accountId: String
    let inbox: Folder
    let archive: Folder
    var inboxFolderId: String { inbox.id }
    var archiveFolderId: String { archive.id }
    let inboxPath = "INBOX"
    let archivePath = "Archive"

    struct MessageSpec {
        let key: String
        let accountId: String
        /// The UID the PUSH captured — staging always uses this; only
        /// `uidRemap` gives the durable row a different messageId.
        let pushMessageId: String
        let rfc822: String
        let date: Date
        let actionTag: String?
        let summaryBlurb: String?
        let isReadAtPush: Bool
    }

    struct MessageState {
        var everStaged = false
        var durableExists = false
        var movedAwayByUser = false
        var undoActive = false
        /// An overlay entry currently registered for this identity's current id.
        var hasOverlay = false
    }

    private(set) var specs: [String: MessageSpec] = [:]
    private(set) var states: [String: MessageState] = [:]
    /// Sorted for deterministic fuzz enumeration.
    var messageKeys: [String] { specs.keys.sorted() }

    /// I8 signal capture — every `.inboxDataDidChange`/`.messagesStaged` post
    /// observed since the last `clearSignals()`.
    private(set) var capturedSignals: [String] = []
    private var obsInboxChange: NSObjectProtocol?
    private var obsStaged: NSObjectProtocol?

    init(pool: DatabasePool, stagingPath: String, stagingQueue: DatabaseQueue, accountId: String, inbox: Folder, archive: Folder) {
        self.pool = pool
        self.stagingPath = stagingPath
        self.stagingQueue = stagingQueue
        self.accountId = accountId
        self.inbox = inbox
        self.archive = archive
        obsInboxChange = NotificationCenter.default.addObserver(
            forName: .inboxDataDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.capturedSignals.append("inboxDataDidChange") }
        }
        obsStaged = NotificationCenter.default.addObserver(
            forName: .messagesStaged, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.capturedSignals.append("messagesStaged") }
        }
    }

    func teardown() {
        if let obsInboxChange { NotificationCenter.default.removeObserver(obsInboxChange) }
        if let obsStaged { NotificationCenter.default.removeObserver(obsStaged) }
        obsInboxChange = nil
        obsStaged = nil
    }

    func clearSignals() { capturedSignals = [] }

    // MARK: Message registration

    static func date(minutesAgo: Int, base: Date) -> Date { base.addingTimeInterval(-60 * Double(minutesAgo)) }

    @discardableResult
    func addMessage(
        _ key: String, uid: String, minutesAgo: Int, base: Date,
        tag: String? = nil, blurb: String? = nil, accountId: String? = nil, isReadAtPush: Bool = false
    ) -> MessageSpec {
        let spec = MessageSpec(
            key: key, accountId: accountId ?? self.accountId, pushMessageId: uid,
            rfc822: "rfc-\(key)-\(UUID().uuidString.prefix(8))@example.com",
            date: Self.date(minutesAgo: minutesAgo, base: base),
            actionTag: tag, summaryBlurb: blurb, isReadAtPush: isReadAtPush
        )
        specs[key] = spec
        states[key] = MessageState()
        return spec
    }

    /// Publishes a `StagedInboxRow` DIRECTLY into `NSEDataBridge.
    /// latestStagedRows` — the EXACT same Mutex snapshot + replace-all
    /// semantics the real merge writes to (`NSEDataBridge.swift` ~881),
    /// WITHOUT running `mergeNSEStagingData` and therefore without any
    /// durable GRDB write. This is a REAL mechanism seam (not a mock) —
    /// `InboxListBehaviorPinningTests` uses the identical seam to model "the
    /// merge published S but hasn't executed its durable write phases yet",
    /// which is exactly the production ordering
    /// (`latestStagedRows.withLock { $0 = stagedRows }` runs BEFORE the
    /// phase-1 durable write later in the same `performMerge` call). Used
    /// where a scenario needs the pre-durability window without paying for
    /// (or being blocked by) the real merge's synchronous header write.
    func publishStagedOnly(_ key: String) {
        let spec = specs[key]!
        let row = StagedInboxRow(
            accountId: spec.accountId, folderPath: inboxPath, messageId: spec.pushMessageId,
            rfc822MessageId: spec.rfc822, threadId: nil, inReplyTo: nil, references: [],
            subject: "Subj \(key)", senderName: "Sender", senderAddress: "s@example.com",
            to: "me@example.com", snippet: "snip", date: spec.date,
            isRead: spec.isReadAtPush, isFlagged: false, hasAttachments: false, isReplied: false, isForwarded: false,
            actionTag: spec.actionTag, summaryBlurb: spec.summaryBlurb
        )
        NSEDataBridge.latestStagedRows.withLock { rows in
            rows.removeAll { $0.headerId == row.headerId }
            rows.append(row)
        }
        states[key]?.everStaged = true
    }

    /// Test seam for `aiNeverFlashesAcrossWakes`'s manual gradual-stage
    /// bookkeeping (wake 1 lands a durable header directly via
    /// `stageHeaderOnlyRow` + a real merge, bypassing `apply(.pushArrives:)`
    /// so the test controls the header/body+AI split across two wakes) —
    /// `states` is `private(set)` so callers outside this class use this
    /// instead of poking the dictionary directly.
    func markStagedAndDurable(_ key: String) {
        states[key]?.everStaged = true
        states[key]?.durableExists = true
    }

    // MARK: Real lookups

    func durableRow(forKey key: String) async throws -> MessageHeader? {
        guard let spec = specs[key] else { return nil }
        return try await pool.read { db in
            try MessageHeader
                .filter(Column("accountId") == spec.accountId && Column("rfc822MessageId") == spec.rfc822)
                .fetchOne(db)
        }
    }

    func stagedRow(forKey key: String) -> StagedInboxRow? {
        guard let spec = specs[key] else { return nil }
        return NSEDataBridge.latestStagedRows.withLock { $0 }
            .first { $0.accountId == spec.accountId && $0.rfc822MessageId == spec.rfc822 }
    }

    /// The id the user's action targets: the durable header's id when one
    /// exists, else the staged headerId under the ORIGINAL push folder
    /// (INBOX) — mirrors `SimWorld.currentId`.
    func currentId(forKey key: String) async throws -> String {
        if let d = try await durableRow(forKey: key) { return d.id }
        let spec = specs[key]!
        return MessageIdentity.headerId(accountId: spec.accountId, folderPath: inboxPath, messageId: spec.pushMessageId)
    }

    func identity(of key: String) -> String {
        let spec = specs[key]!
        return "\(spec.accountId)|rfc|\(spec.rfc822)"
    }

    // MARK: - Steps (real mechanisms — PLAN_INBOX_UNIFIED_READ.md §5B step vocabulary)

    enum Step: String, CaseIterable {
        case pushArrives
        case silentStateChangePush
        case redeliver
        case syncCreatesHeader
        case userArchive
        case overlayDrain
        case undo
        case undoRestoreWrite
        case userRead
        case staleDelete
        case uidRemap
    }

    func isLegal(_ step: Step, _ key: String) -> Bool {
        guard let state = states[key] else { return false }
        switch step {
        case .pushArrives, .syncCreatesHeader:
            return !state.everStaged && !state.durableExists
        case .silentStateChangePush, .redeliver:
            return state.everStaged
        case .userArchive:
            return state.durableExists && !state.movedAwayByUser && !state.hasOverlay
        case .overlayDrain:
            return state.hasOverlay
        case .undo:
            return state.movedAwayByUser && !state.hasOverlay
        case .undoRestoreWrite:
            return state.undoActive
        case .userRead:
            return !state.movedAwayByUser && (state.everStaged || state.durableExists)
        case .staleDelete:
            return state.durableExists && !state.hasOverlay && !state.movedAwayByUser && !state.undoActive
        case .uidRemap:
            return state.durableExists && !state.hasOverlay && !state.undoActive
        }
    }

    /// Applies one step via REAL mechanisms. `vm` is only consulted by
    /// `.undo` (mirrors `InboxView`'s `.onReceive(.messagesUndone)` glue,
    /// which — like `.messagesStaged` — lives at the VIEW layer, not inside
    /// `InboxViewModel` itself; the harness supplies that glue explicitly).
    func apply(_ step: Step, _ key: String, vm: InboxViewModel, stageTerminal: (E2EWorld, String, String) throws -> Void) async throws {
        let spec = specs[key]!
        switch step {
        case .pushArrives:
            try stageTerminal(self, key, inboxPath)
            await NSEDataBridge.mergeNSEStagingData(stagingPathOverride: stagingPath)
            states[key]?.everStaged = true
            states[key]?.durableExists = true
        case .silentStateChangePush, .redeliver:
            try stageTerminal(self, key, inboxPath)
            await NSEDataBridge.mergeNSEStagingData(stagingPathOverride: stagingPath)
            states[key]?.everStaged = true
            if states[key]?.durableExists == false {
                states[key]?.durableExists = true
            }
        case .syncCreatesHeader:
            var mutableHeader = MessageHeader(
                messageId: spec.pushMessageId, subject: "Subj \(key)", from: "Sender", fromAddress: "s@example.com",
                to: "me@example.com", date: spec.date, snippet: "snip",
                folderId: inboxFolderId, accountId: spec.accountId, folderPath: inboxPath, isInInbox: true
            )
            mutableHeader.rfc822MessageId = spec.rfc822
            mutableHeader.headerComplete = true
            mutableHeader.actionTag = spec.actionTag.flatMap(ActionTag.init(rawValue:))
            mutableHeader.tagSortOrder = mutableHeader.actionTag?.sortOrder ?? 99
            mutableHeader.summaryBlurb = spec.summaryBlurb
            // `let` copy: a Sendable write closure may not capture/reference
            // a mutable outer `var` (Swift 6 strict concurrency).
            let headerToInsert = mutableHeader
            try await pool.writeWithoutTransaction { db in try headerToInsert.insert(db) }
            states[key]?.durableExists = true
        case .userArchive:
            let id = try await currentId(forKey: key)
            // Snapshot MainActor-isolated computed properties into plain
            // locals BEFORE the Sendable closure — `self.archiveFolderId`
            // can't be referenced from inside it directly.
            let destFolderId = archiveFolderId
            let destFolderPath = archivePath
            AccountManager.shared.registerMutation(id: id, mutation: .init(
                folderId: destFolderId, folderPath: destFolderPath, isInInbox: false
            ))
            try await pool.writeWithoutTransaction { db in
                try db.execute(
                    sql: "UPDATE messageHeader SET folderId = ?, folderPath = ?, isInInbox = 0 WHERE id = ?",
                    arguments: [destFolderId, destFolderPath, id]
                )
            }
            states[key]?.movedAwayByUser = true
            states[key]?.hasOverlay = true
        case .overlayDrain:
            let id = try await currentId(forKey: key)
            AccountManager.shared.removeOverlayEntries(ids: [id])
            states[key]?.hasOverlay = false
        case .undo:
            let id = try await currentId(forKey: key)
            AccountManager.shared.registerMutation(id: id, mutation: .init(
                folderId: inboxFolderId, folderPath: inboxPath, isInInbox: true
            ))
            vm.insertUndoneMessages([id])
            states[key]?.movedAwayByUser = false
            states[key]?.undoActive = true
            states[key]?.hasOverlay = true
        case .undoRestoreWrite:
            let id = try await currentId(forKey: key)
            let restoreFolderId = inboxFolderId
            let restoreFolderPath = inboxPath
            try await pool.writeWithoutTransaction { db in
                try db.execute(
                    sql: "UPDATE messageHeader SET folderId = ?, folderPath = ?, isInInbox = 1 WHERE id = ?",
                    arguments: [restoreFolderId, restoreFolderPath, id]
                )
            }
            states[key]?.undoActive = false
        case .userRead:
            let id = try await currentId(forKey: key)
            AccountManager.shared.registerMutation(id: id, mutation: .init(isRead: true))
        case .staleDelete:
            try await pool.writeWithoutTransaction { db in
                try db.execute(
                    sql: "DELETE FROM messageHeader WHERE accountId = ? AND rfc822MessageId = ?",
                    arguments: [spec.accountId, spec.rfc822]
                )
            }
            states[key]?.durableExists = false
        case .uidRemap:
            guard let old = try await durableRow(forKey: key) else { return }
            let newUid = "9\(spec.pushMessageId)"
            let remapFolderId = archiveFolderId
            let remapFolderPath = archivePath
            let newId = MessageIdentity.headerId(accountId: spec.accountId, folderPath: remapFolderPath, messageId: newUid)
            let oldId = old.id
            var remapped = old
            remapped.id = newId
            remapped.messageId = newUid
            remapped.folderId = remapFolderId
            remapped.folderPath = remapFolderPath
            remapped.isInInbox = false
            let headerToInsert = remapped
            // DELETE + INSERT, not an in-place primary-key UPDATE: `messageHeader.id`
            // is referenced by several child tables with `onDelete: .cascade` but
            // no `onUpdate` clause (AppDatabase.swift ~547/640/993/1185) — an
            // in-place `UPDATE messageHeader SET id = ?` leaves those children
            // pointing at the now-nonexistent OLD id and trips a FOREIGN KEY
            // constraint failure (hit by the seeded fuzz once a real terminal
            // `pushArrives` had already written AI/body-linked child rows before
            // the remap). DELETE cascades those children away — correctly
            // modeling "this identity now lives under a brand-new header row",
            // exactly what a real IMAP MOVE's new-UID header represents.
            try await pool.writeWithoutTransaction { db in
                try db.execute(sql: "DELETE FROM messageHeader WHERE id = ?", arguments: [oldId])
                try headerToInsert.insert(db)
            }
            states[key]?.movedAwayByUser = true
        }
    }
}

// MARK: - I3 AI-monotonicity tracker (mirrors InboxComposeScenarioTests.AITracker)

struct E2EAITracker {
    var tagSeen: Set<String> = []
    var blurbSeen: Set<String> = []
}
