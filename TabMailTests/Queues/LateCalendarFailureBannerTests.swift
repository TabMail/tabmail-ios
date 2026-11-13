/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

// A queued calendar change that fails for good is told to the user exactly once:
// on its confirmation card when the chat turn is still waiting for it, otherwise
// as an inbox banner that stays (across relaunches too) until the user dismisses it.
//
// Every op below is a delete with no event id, which the drain retires as a
// permanent failure without reaching the provider.

@Suite("Late calendar failures reach the inbox", .serialized, .processGlobalState)
@MainActor
struct LateCalendarFailureBannerTests {

    private func makeTestDB(accountId: String) throws -> (pool: DatabasePool, dir: URL, previous: AppDatabase?) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var config = Configuration()
        config.foreignKeysEnabled = true
        let pool = try DatabasePool(path: dir.appendingPathComponent("test.sqlite").path, configuration: config)
        let appDb = try AppDatabase(dbPool: pool)
        let previous = AppDatabase.shared.withLock { current -> AppDatabase? in
            let prev = current; current = appDb; return prev
        }
        try pool.writeWithoutTransaction { db in
            var acc = Account(emailAddress: "cal@example.com", displayName: "Cal", provider: .gmail)
            acc.id = accountId
            try acc.insert(db)
        }
        return (pool, dir, previous)
    }

    private func unexecutableDelete(accountId: String, title: String) -> PendingCalendarOperation {
        PendingCalendarOperation(
            operationType: .delete, accountId: accountId, eventId: nil,
            calendarId: "primary", arguments: [:], eventTitle: title)
    }

    /// What the inbox shows after a relaunch: the database opened again with its per-launch
    /// recovery (the flag-gated one-time resets stay off, as in every test), read by a
    /// store that has never seen it.
    private func relaunchedFailures(pool: DatabasePool) async throws -> [LateCalendarFailure] {
        let reopened = try AppDatabase(pool: pool, runStartupResets: false)
        AppDatabase.shared.withLock { $0 = reopened }
        let store = LateCalendarFailureStore()
        await store.reload()
        return store.failures
    }

    @Test("A calendar change that fails after its chat turn ended shows one banner naming the event and a plain reason, also after a relaunch")
    func lateFailureShowsOneBanner() async throws {
        let accountId = "late-cal-shown"
        let (pool, dir, previous) = try makeTestDB(accountId: accountId)
        let mock = MockCalendarProvider()
        await AccountManager.shared.registerCalendarProviderForTesting(accountId: accountId, provider: mock)
        defer {
            Task { await AccountManager.shared.unregisterCalendarProviderForTesting(accountId: accountId) }
            InstalledTestDatabaseLifetime.finish(previous: previous, pool: pool, directory: dir)
        }

        let op = unexecutableDelete(accountId: accountId, title: "Team sync")
        try await pool.write { db in try op.insert(db) }

        // Nobody waits: the chat turn that queued it is over.
        await AccountManager.shared.drainCalendarQueue()

        let reason = try await pool.read { db in try PendingCalendarOperation.fetchOne(db, key: op.id)?.failureReason }
        let store = LateCalendarFailureStore()
        await store.reload()
        #expect(store.failures.count == 1,
                "a calendar change that failed with nobody watching must show exactly one inbox banner; got \(store.failures.count)")
        guard store.failures.count == 1 else { return }
        #expect(!(reason ?? "").isEmpty, "the failure must carry a reason")
        #expect(store.failures[0].bannerText
                == "A calendar change couldn't be made: Team sync. This calendar can't make this kind of change.")
        #expect(!store.failures[0].bannerText.contains(reason ?? "\u{0}"),
                "the banner shows the text written for the assistant: \(store.failures[0].bannerText)")

        // Showing it does not consume it, and another drain does not add a second one.
        await AccountManager.shared.drainCalendarQueue()
        await store.reload()
        #expect(store.failures.count == 1, "the banner must stay single; got \(store.failures.count)")

        let afterRelaunch = try await relaunchedFailures(pool: pool)
        #expect(afterRelaunch.map(\.id) == [op.id],
                "the banner must come back after a relaunch until it is dismissed; got \(afterRelaunch.map(\.id))")
        #expect(await mock.deletedEvents.isEmpty)
    }

    @Test("A failure already shown on the waiting card shows no banner; one nobody waited for still does")
    func failureToldInsideTheWaitShowsNoBanner() async throws {
        let accountId = "late-cal-told"
        let (pool, dir, previous) = try makeTestDB(accountId: accountId)
        let mock = MockCalendarProvider()
        await AccountManager.shared.registerCalendarProviderForTesting(accountId: accountId, provider: mock)
        defer {
            Task { await AccountManager.shared.unregisterCalendarProviderForTesting(accountId: accountId) }
            InstalledTestDatabaseLifetime.finish(previous: previous, pool: pool, directory: dir)
        }

        let awaited = unexecutableDelete(accountId: accountId, title: "Awaited meeting")
        let unawaited = unexecutableDelete(accountId: accountId, title: "Unattended meeting")
        try await pool.write { db in
            try awaited.insert(db)
            try unawaited.insert(db)
        }

        async let outcome = AccountManager.shared.awaitCalendarOpOutcome(opId: awaited.id, timeoutSeconds: 5.0)
        // Let the awaiter register before the drain can signal it.
        try? await Task.sleep(nanoseconds: 300_000_000)
        await AccountManager.shared.drainCalendarQueue()
        let result = await outcome
        guard case .permanentFailure = result else {
            #expect(Bool(false), "fixture check: the waiting tool must have been told of the failure (its card turned red); got \(result)")
            return
        }

        let store = LateCalendarFailureStore()
        await store.reload()
        #expect(store.failures.map(\.id) == [unawaited.id],
                "only the failure nobody saw may show a banner; the card already showed the other one. Got \(store.failures.map(\.title))")

        let afterRelaunch = try await relaunchedFailures(pool: pool)
        #expect(afterRelaunch.map(\.id) == [unawaited.id],
                "a failure the card showed must not come back as a banner after a relaunch; got \(afterRelaunch.map(\.title))")

        // Not shown is not forgotten: the failure the card showed keeps its record.
        let shown = try await pool.read { db in try PendingCalendarOperation.fetchOne(db, key: awaited.id) }
        #expect(shown?.status == PendingStatus.failed.rawValue && !(shown?.failureReason ?? "").isEmpty,
                "the failure the card showed must stay recorded as failed with its reason; got \(String(describing: shown?.status))")
    }

    /// The drain counts a failure as seen exactly when its signal reaches a waiting tool, and then
    /// no banner shows it. So a signal that takes the waiting tool's awaiter must reach that tool
    /// even when the wait's timeout fired first: here the signal runs after the timeout returned
    /// and before the wait gives the awaiter up.
    @Test("A failure signalled after the wait timed out, but before it gave up, still reaches the waiting card")
    func signalInsideTheTimeoutGapReachesTheCard() async throws {
        let opId = "late-cal-gap-\(UUID().uuidString)"
        let timeout = 0.2
        let start = ContinuousClock.now
        async let outcome = AccountManager.shared.awaitCalendarOpOutcome(opId: opId, timeoutSeconds: timeout)

        let registrationDeadline = start + .seconds(timeout / 2)
        var registered = false
        while !registered, ContinuousClock.now < registrationDeadline {
            registered = await AccountManager.shared.hasCalendarOpAwaiter(opId: opId)
            if !registered { await Task.yield() }
        }
        #expect(registered, "fixture check: the wait must register before its timeout")

        // One job on the manager: the timeout fires while it holds the manager, so the wait
        // can only resume after the signal below has taken its awaiter.
        let told = await AccountManager.shared.signalAfterHolding(
            until: start + .seconds(timeout + 1), opId: opId,
            outcome: .permanentFailure(reason: "event not found on server"))
        let result = await outcome

        #expect(told, "fixture check: the signal must find the awaiter the timed-out wait had not given up yet")
        guard case .permanentFailure = result else {
            #expect(Bool(false), "the drain counted the failure as seen, so it shows no banner, but the waiting card got \(result): the failure is shown nowhere")
            return
        }
    }

    /// The error each terminal arm of the drain claims, as a provider throws it from a delete.
    private func providerError(for kind: CalendarFailureKind) -> any Error {
        switch kind {
        case .notFound: return GoogleCalendarError.eventNotFound
        case .missingPermission: return GoogleCalendarError.missingScope
        case .signInFailed: return CalDAVError.authFailed
        case .unsupported: return CalendarProviderError.notSupported("this provider can't delete this event")
        case .refused: return GoogleCalendarError.httpError(400, nil)
        }
    }

    @Test("Each kind of failure shows its own plain line, and never the text written for the assistant",
          arguments: CalendarFailureKind.allCases)
    func eachKindShowsItsPlainLine(_ kind: CalendarFailureKind) async throws {
        let expected: String = switch kind {
        case .notFound: "The event no longer exists."
        case .missingPermission: "TabMail doesn't have permission to change this calendar."
        case .signInFailed: "The calendar account needs you to sign in again."
        case .unsupported: "This calendar can't make this kind of change."
        case .refused: "The calendar refused the change."
        }
        let accountId = "late-cal-kind-\(kind.rawValue)"
        let (pool, dir, previous) = try makeTestDB(accountId: accountId)
        let mock = MockCalendarProvider()
        await mock.setDeleteEventThrows(providerError(for: kind))
        await AccountManager.shared.registerCalendarProviderForTesting(accountId: accountId, provider: mock)
        defer {
            Task {
                await AccountManager.shared.clearAuthFailed(accountId)
                await AccountManager.shared.unregisterCalendarProviderForTesting(accountId: accountId)
            }
            InstalledTestDatabaseLifetime.finish(previous: previous, pool: pool, directory: dir)
        }

        let op = PendingCalendarOperation(
            operationType: .delete, accountId: accountId, eventId: "event-\(kind.rawValue)",
            calendarId: "primary", arguments: [:], eventTitle: "Planning")
        try await pool.write { db in try op.insert(db) }
        await AccountManager.shared.drainCalendarQueue()

        let row = try await pool.read { db in try PendingCalendarOperation.fetchOne(db, key: op.id) }
        #expect(row?.status == PendingStatus.failed.rawValue,
                "fixture check: the \(kind) error must retire the change; got \(String(describing: row?.status))")
        let store = LateCalendarFailureStore()
        await store.reload()
        #expect(store.failures.map(\.bannerText) == ["A calendar change couldn't be made: Planning. \(expected)"])
        let reason = row?.failureReason ?? ""
        #expect(!reason.isEmpty && !store.failures.contains { $0.bannerText.contains(reason) },
                "the banner shows the text written for the assistant (\(reason)): \(store.failures.map(\.bannerText))")
    }

    @Test("Dismiss removes the banner for good, also after a reload or a relaunch")
    func dismissRemovesForGood() async throws {
        let accountId = "late-cal-dismissed"
        let (pool, dir, previous) = try makeTestDB(accountId: accountId)
        let mock = MockCalendarProvider()
        await AccountManager.shared.registerCalendarProviderForTesting(accountId: accountId, provider: mock)
        defer {
            Task { await AccountManager.shared.unregisterCalendarProviderForTesting(accountId: accountId) }
            InstalledTestDatabaseLifetime.finish(previous: previous, pool: pool, directory: dir)
        }

        let op = unexecutableDelete(accountId: accountId, title: "Dismissed meeting")
        try await pool.write { db in try op.insert(db) }
        await AccountManager.shared.drainCalendarQueue()

        let store = LateCalendarFailureStore()
        await store.reload()
        guard store.failures.count == 1 else {
            #expect(Bool(false), "fixture check: the failure must show before it can be dismissed; got \(store.failures.count)")
            return
        }
        await store.dismiss(store.failures[0])
        #expect(store.failures.isEmpty, "the dismissed banner is still shown")

        await store.reload()
        #expect(store.failures.isEmpty, "the dismissed banner came back on a reload")

        let afterRelaunch = try await relaunchedFailures(pool: pool)
        #expect(afterRelaunch.isEmpty, "the dismissed banner came back after a relaunch")
        let row = try await pool.read { db in try PendingCalendarOperation.fetchOne(db, key: op.id) }
        #expect(row == nil, "a dismissed failure must leave no row behind")
    }
}

extension AccountManager {
    func hasCalendarOpAwaiter(opId: String) -> Bool { calendarOpAwaiters[opId] != nil }

    /// Holds the manager until `deadline`, then signals `opId`, all as one job: nothing else on
    /// the manager (such as a wait whose timeout fired meanwhile) runs before the signal.
    func signalAfterHolding(until deadline: ContinuousClock.Instant, opId: String, outcome: CalendarOpOutcome) -> Bool {
        while ContinuousClock.now < deadline { Thread.sleep(forTimeInterval: 0.005) }
        return signalCalendarOpOutcome(opId: opId, outcome: outcome)
    }
}
