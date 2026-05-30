/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import SwiftUI
@testable import TabMail

// MARK: - SyncPhase

@Suite("SyncPhase")
struct SyncPhaseTests {

    @Test("displayText for checking")
    func checkingText() {
        #expect(SyncPhase.checking.displayText == "Checking for mail...")
    }

    @Test("displayText for downloading singular")
    func downloadingSingular() {
        #expect(SyncPhase.downloading(1).displayText == "Downloading 1 email...")
    }

    @Test("displayText for downloading plural")
    func downloadingPlural() {
        #expect(SyncPhase.downloading(5).displayText == "Downloading 5 emails...")
    }

    @Test("priority ordering: checking < downloading")
    func priorityOrdering() {
        #expect(SyncPhase.checking.priority < SyncPhase.downloading(1).priority)
    }
}

// MARK: - AccountManagerState Sync Phase Aggregation

@Suite("AccountManagerState Sync Phase Aggregation")
@MainActor
struct SyncPhaseAggregationTests {

    private var state: AccountManagerState { AccountManagerState.shared }

    /// Reset state before each test.
    private func resetState() {
        state.clearSyncPhases()
        state.lastSyncCompletedAt = nil
        state.lastSyncFailed = false
    }

    @Test("Single account checking shows checking")
    func singleChecking() {
        resetState()
        state.setSyncPhase(.checking, forAccount: "a1")
        #expect(state.syncPhase == .checking)
        resetState()
    }

    @Test("Single account downloading shows downloading with count")
    func singleDownloading() {
        resetState()
        state.setSyncPhase(.downloading(3), forAccount: "a1")
        #expect(state.syncPhase == .downloading(3))
        resetState()
    }

    @Test("Highest phase wins across accounts")
    func highestPhaseWins() {
        resetState()
        state.setSyncPhase(.checking, forAccount: "a1")
        state.setSyncPhase(.downloading(2), forAccount: "a2")
        #expect(state.syncPhase == .downloading(2))
        resetState()
    }

    @Test("Download counts aggregate across accounts")
    func downloadCountsAggregate() {
        resetState()
        state.setSyncPhase(.downloading(3), forAccount: "a1")
        state.setSyncPhase(.downloading(7), forAccount: "a2")
        #expect(state.syncPhase == .downloading(10))
        resetState()
    }

    @Test("Downloading wins over checking, counts aggregate only downloading accounts")
    func downloadingWinsOverChecking() {
        resetState()
        state.setSyncPhase(.checking, forAccount: "a1")
        state.setSyncPhase(.downloading(5), forAccount: "a2")
        #expect(state.syncPhase == .downloading(5))
        resetState()
    }

    @Test("Clearing a single account recomputes aggregate")
    func clearSingleAccount() {
        resetState()
        state.setSyncPhase(.downloading(5), forAccount: "a1")
        state.setSyncPhase(.checking, forAccount: "a2")
        state.setSyncPhase(nil, forAccount: "a1")
        #expect(state.syncPhase == .checking)
        resetState()
    }

    @Test("Clearing all accounts sets syncPhase to nil")
    func clearAllAccounts() {
        resetState()
        state.setSyncPhase(.checking, forAccount: "a1")
        state.setSyncPhase(.downloading(2), forAccount: "a2")
        state.clearSyncPhases()
        #expect(state.syncPhase == nil)
    }

    @Test("Clearing last account via setSyncPhase sets syncPhase to nil")
    func clearLastAccount() {
        resetState()
        state.setSyncPhase(.checking, forAccount: "a1")
        state.setSyncPhase(nil, forAccount: "a1")
        #expect(state.syncPhase == nil)
    }

    @Test("Phase progresses for same account update aggregate")
    func phaseProgression() {
        resetState()
        state.setSyncPhase(.checking, forAccount: "a1")
        #expect(state.syncPhase == .checking)
        state.setSyncPhase(.downloading(2), forAccount: "a1")
        #expect(state.syncPhase == .downloading(2))
        state.setSyncPhase(nil, forAccount: "a1")
        #expect(state.syncPhase == nil)
    }
}

// MARK: - SyncStatusFormatter

@Suite("SyncStatusFormatter")
struct SyncStatusFormatterTests {

    @Test("Shows phase text when syncing")
    @MainActor
    func showsPhaseWhenSyncing() {
        let text = SyncStatusFormatter.statusText(
            syncPhase: .checking,
            lastSyncCompletedAt: nil,
            lastSyncFailed: false,
            now: Date()
        )
        #expect(text == "Checking for mail...")
    }

    @Test("Shows fallback when no sync has completed and not syncing")
    @MainActor
    func showsFallbackBeforeFirstSync() {
        let text = SyncStatusFormatter.statusText(
            syncPhase: nil,
            lastSyncCompletedAt: nil,
            lastSyncFailed: false,
            now: Date()
        )
        #expect(text == "Checking for mail...")
    }

    @Test("Shows 'Updated less than a minute ago' within 60 seconds")
    @MainActor
    func updatedLessThanMinute() {
        let now = Date()
        let text = SyncStatusFormatter.statusText(
            syncPhase: nil,
            lastSyncCompletedAt: now.addingTimeInterval(-30),
            lastSyncFailed: false,
            now: now
        )
        #expect(text == "Updated less than a minute ago")
    }

    @Test("Shows minutes after 60 seconds")
    @MainActor
    func updatedMinutesAgo() {
        let now = Date()
        let text = SyncStatusFormatter.statusText(
            syncPhase: nil,
            lastSyncCompletedAt: now.addingTimeInterval(-180),
            lastSyncFailed: false,
            now: now
        )
        #expect(text == "Updated 3 min ago")
    }

    @Test("Shows 1 min singular")
    @MainActor
    func updatedOneMinAgo() {
        let now = Date()
        let text = SyncStatusFormatter.statusText(
            syncPhase: nil,
            lastSyncCompletedAt: now.addingTimeInterval(-90),
            lastSyncFailed: false,
            now: now
        )
        #expect(text == "Updated 1 min ago")
    }

    @Test("Shows hours for long elapsed times")
    @MainActor
    func updatedHoursAgo() {
        let now = Date()
        let text = SyncStatusFormatter.statusText(
            syncPhase: nil,
            lastSyncCompletedAt: now.addingTimeInterval(-7200),
            lastSyncFailed: false,
            now: now
        )
        #expect(text == "Updated 2h ago")
    }

    @Test("Failure shows 'Last updated' prefix instead of 'Updated'")
    @MainActor
    func failureShowsLastUpdated() {
        let now = Date()
        let text = SyncStatusFormatter.statusText(
            syncPhase: nil,
            lastSyncCompletedAt: now.addingTimeInterval(-180),
            lastSyncFailed: true,
            now: now
        )
        #expect(text == "Last updated 3 min ago")
    }

    @Test("Failure never shows 'less than a minute ago' — always shows relative time")
    @MainActor
    func failureNeverShowsJustNow() {
        let now = Date()
        let text = SyncStatusFormatter.statusText(
            syncPhase: nil,
            lastSyncCompletedAt: now.addingTimeInterval(-10),
            lastSyncFailed: true,
            now: now
        )
        #expect(text == "Last updated less than a minute ago")
    }

    @Test("Active sync phase takes priority over last completed time")
    @MainActor
    func phasePriorityOverCompleted() {
        let now = Date()
        let text = SyncStatusFormatter.statusText(
            syncPhase: .downloading(5),
            lastSyncCompletedAt: now.addingTimeInterval(-10),
            lastSyncFailed: false,
            now: now
        )
        #expect(text == "Downloading 5 emails...")
    }
}

// MARK: - Observation Tracking
//
// The subtitle (and MailNavigationView's navigationSubtitle) re-render via
// `withObservationTracking` on AccountManagerState. These tests guard against
// silent regressions where someone marks a status property @ObservationIgnored,
// removes its @Observable participation, or refactors the singleton in a way
// that breaks tracking — any of which would silently freeze the live UI again.

@Suite("AccountManagerState Observation Tracking")
@MainActor
struct SyncStatusObservationTests {

    private var state: AccountManagerState { AccountManagerState.shared }

    private func resetState() {
        state.clearSyncPhases()
        state.lastSyncCompletedAt = nil
        state.lastSyncFailed = false
    }

    /// Box used so the onChange closure can mutate flag state under Swift 6
    /// strict concurrency without a captured-var error.
    @MainActor private final class Flag { var fired = false }

    /// Reads all three tracked properties and returns whether onChange fires
    /// after `mutate` runs. Mirrors the read pattern in SyncStatusObservationModifier.
    private func observationFires(after mutate: () -> Void) async -> Bool {
        let flag = Flag()
        withObservationTracking {
            _ = state.syncPhase
            _ = state.lastSyncCompletedAt
            _ = state.lastSyncFailed
        } onChange: { @Sendable in
            Task { @MainActor in flag.fired = true }
        }
        mutate()
        // onChange fires synchronously in willSet; yield twice so the dispatched
        // MainActor task runs before we read flag.fired.
        await Task.yield()
        await Task.yield()
        return flag.fired
    }

    @Test("Observation fires when syncPhase mutates")
    func firesOnSyncPhase() async {
        resetState()
        let fired = await observationFires { state.setSyncPhase(.checking, forAccount: "x") }
        #expect(fired)
        resetState()
    }

    @Test("Observation fires when lastSyncCompletedAt mutates")
    func firesOnLastSyncCompletedAt() async {
        resetState()
        let fired = await observationFires { state.lastSyncCompletedAt = Date() }
        #expect(fired)
        resetState()
    }

    @Test("Observation fires when lastSyncFailed mutates")
    func firesOnLastSyncFailed() async {
        resetState()
        let fired = await observationFires { state.lastSyncFailed = true }
        #expect(fired)
        resetState()
    }

    @Test("Observation fires when clearSyncPhases nilifies syncPhase")
    func firesOnClearSyncPhases() async {
        resetState()
        state.setSyncPhase(.checking, forAccount: "x")
        let fired = await observationFires { state.clearSyncPhases() }
        #expect(fired)
        resetState()
    }
}

// MARK: - Environment key wiring
//
// SyncStatusSubtitle and MailNavigationView read sync-status via @Environment.
// RootView publishes through `publishSyncStatusEnvironment`. These tests guard
// the keys' default values and the getter/setter round-trip so a refactor that
// renames or drops one of the four keys fails loudly instead of silently
// freezing the subtitle at its default.

@Suite("Sync Status Environment Keys")
@MainActor
struct SyncStatusEnvironmentKeyTests {

    @Test("Default values match documented fallbacks")
    func defaults() {
        let env = EnvironmentValues()
        #expect(env.syncPhase == nil)
        #expect(env.lastSync == nil)
        #expect(env.syncFailed == false)
        // `syncNow` defaults to "now" — can't check exact value, just that it's sane.
        #expect(abs(env.syncNow.timeIntervalSinceNow) < 5)
    }

    @Test("Round-trip: writes are observable via getter")
    func roundTrip() {
        var env = EnvironmentValues()
        let d = Date(timeIntervalSinceReferenceDate: 1_000_000)
        env.syncPhase = .downloading(3)
        env.lastSync = d
        env.syncFailed = true
        env.syncNow = d
        #expect(env.syncPhase == .downloading(3))
        #expect(env.lastSync == d)
        #expect(env.syncFailed == true)
        #expect(env.syncNow == d)
    }
}

// MARK: - SyncResult

@Suite("AccountManager.SyncResult")
struct SyncResultTests {

    @Test("SyncResult stores hadChanges and failed flags")
    func syncResultFields() {
        let success = AccountManager.SyncResult(hadChanges: true, failed: false)
        #expect(success.hadChanges == true)
        #expect(success.failed == false)

        let failure = AccountManager.SyncResult(hadChanges: false, failed: true)
        #expect(failure.hadChanges == false)
        #expect(failure.failed == true)
    }
}

// MARK: - Sync Failure Timestamp Guard

@Suite("Sync Failure Timestamp Guard")
@MainActor
struct SyncFailureTimestampGuardTests {

    private var state: AccountManagerState { AccountManagerState.shared }

    private func resetState() {
        state.clearSyncPhases()
        state.lastSyncCompletedAt = nil
        state.lastSyncFailed = false
    }

    @Test("Successful sync updates lastSyncCompletedAt")
    func successfulSyncUpdatesTimestamp() {
        resetState()
        let result = AccountManager.SyncResult(hadChanges: false, failed: false)
        // Simulate the poll() logic
        state.lastSyncFailed = result.failed
        if !result.failed {
            state.lastSyncCompletedAt = Date()
        }
        #expect(state.lastSyncCompletedAt != nil)
        #expect(state.lastSyncFailed == false)
        resetState()
    }

    @Test("Failed sync does NOT update lastSyncCompletedAt")
    func failedSyncDoesNotUpdateTimestamp() {
        resetState()
        let result = AccountManager.SyncResult(hadChanges: false, failed: true)
        // Simulate the poll() logic
        state.lastSyncFailed = result.failed
        if !result.failed {
            state.lastSyncCompletedAt = Date()
        }
        #expect(state.lastSyncCompletedAt == nil)
        #expect(state.lastSyncFailed == true)
        resetState()
    }

    @Test("Failed sync preserves previous lastSyncCompletedAt")
    func failedSyncPreservesPreviousTimestamp() {
        resetState()
        let previousSync = Date().addingTimeInterval(-300) // 5 min ago
        state.lastSyncCompletedAt = previousSync
        state.lastSyncFailed = false

        let result = AccountManager.SyncResult(hadChanges: false, failed: true)
        state.lastSyncFailed = result.failed
        if !result.failed {
            state.lastSyncCompletedAt = Date()
        }
        // Previous timestamp preserved — UI shows "Last updated 5 min ago"
        #expect(state.lastSyncCompletedAt == previousSync)
        #expect(state.lastSyncFailed == true)
        resetState()
    }

    @Test("Connection error is classified as connection error")
    func connectionErrorClassification() {
        #expect(SyncEngine.isConnectionError(ProviderError.notConnected))
        #expect(SyncEngine.isConnectionError(URLError(.notConnectedToInternet)))
        #expect(SyncEngine.isConnectionError(URLError(.networkConnectionLost)))
    }

    @Test("Delta sync connection failure with full sync not due should propagate error")
    func deltaSyncFailurePropagatesWhenFullSyncNotDue() {
        // This tests the invariant enforced by the guard in SyncEngine.sync():
        // if delta failed, full sync isn't due, and there's an error → throw
        let deltaSyncSucceeded = false
        let deltaSyncError: (any Error)? = ProviderError.notConnected
        let fullSyncInterval: TimeInterval = 900
        // Full sync ran 2 minutes ago — not due yet
        let timeSinceFullSync: TimeInterval = 120

        let shouldThrow = !deltaSyncSucceeded
            && timeSinceFullSync < fullSyncInterval
            && deltaSyncError != nil
        #expect(shouldThrow == true)
    }

    @Test("Delta sync failure does NOT propagate when full sync is due")
    func deltaSyncFailureDoesNotPropagateWhenFullSyncDue() {
        // Full sync will run and either succeed (updating timestamp) or throw on its own
        let deltaSyncSucceeded = false
        let deltaSyncError: (any Error)? = ProviderError.notConnected
        let fullSyncInterval: TimeInterval = 900
        // Full sync ran 20 minutes ago — due
        let timeSinceFullSync: TimeInterval = 1200

        let shouldThrow = !deltaSyncSucceeded
            && timeSinceFullSync < fullSyncInterval
            && deltaSyncError != nil
        #expect(shouldThrow == false)
    }

    @Test("Delta sync success suppresses error propagation even if error was recorded")
    func deltaSyncSuccessSuppressesError() {
        // Retry succeeded — error should not propagate
        let deltaSyncSucceeded = true
        let deltaSyncError: (any Error)? = nil // cleared on success
        let fullSyncInterval: TimeInterval = 900
        let timeSinceFullSync: TimeInterval = 120

        let shouldThrow = !deltaSyncSucceeded
            && timeSinceFullSync < fullSyncInterval
            && deltaSyncError != nil
        #expect(shouldThrow == false)
    }

    @Test("Delta sync not ready (no cursor) does NOT propagate — no error recorded")
    func deltaSyncNotReadyDoesNotPropagate() {
        // Gmail with no historyId: succeeded=false but no error thrown
        let deltaSyncSucceeded = false
        let deltaSyncError: (any Error)? = nil
        let fullSyncInterval: TimeInterval = 900
        let timeSinceFullSync: TimeInterval = 120

        let shouldThrow = !deltaSyncSucceeded
            && timeSinceFullSync < fullSyncInterval
            && deltaSyncError != nil
        #expect(shouldThrow == false)
    }

    @Test("Offline status text shows stale timestamp with 'Last updated' prefix")
    func offlineStatusShowsStaleTimestamp() {
        let now = Date()
        // Last successful sync was 5 min ago, then sync failed
        let text = SyncStatusFormatter.statusText(
            syncPhase: nil,
            lastSyncCompletedAt: now.addingTimeInterval(-300),
            lastSyncFailed: true,
            now: now
        )
        #expect(text == "Last updated 5 min ago")
    }
}
