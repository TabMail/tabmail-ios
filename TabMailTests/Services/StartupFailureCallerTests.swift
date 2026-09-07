/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Synchronization
import Testing
import UIKit
@testable import TabMail

@Suite("Startup failure caller lifetimes", .processGlobalState)
@MainActor
struct StartupFailureCallerTests {
    @Test("Every notification action finishes once after either startup failure")
    func notificationActionsFinishAfterStartupFailure() async throws {
        for stage in ["probe", "build"] {
            for action in ["MARK_READ", "ARCHIVE", "DELETE"] {
                let fixture = try StartupReadinessFixture()
                let startup = fixture.startup(failingAt: stage)
                let calls = Mutex<[String]>([])
                let finished = OneShotGate()
                let initialWorkCount = DatabaseSuspension.shared.backgroundWorkCountForTesting
                let delegate = NotificationDelegate(
                    readiness: {
                        calls.withLock { $0.append("readiness") }
                        return await startup.awaitLaunchReady(background: true)
                    },
                    action: { _, _, _ in calls.withLock { $0.append("action") } }
                )
                delegate.handleNotificationResponse(
                    actionId: action,
                    userInfo: ["messageId": "test-message", "accountId": "test-account"]
                ) {
                    #expect(Thread.isMainThread)
                    calls.withLock { $0.append("finish") }
                    finished.open()
                }
                try await withTimeout(seconds: 3) { await finished.wait() }
                #expect(calls.withLock { $0 } == ["readiness", "finish"])
                #expect(startup.failureMessage != nil && !startup.dbReady)
                #expect(DatabaseSuspension.shared.backgroundWorkCountForTesting == initialWorkCount)
            }
        }
    }

    @Test("Ready notification actions execute and then finish once")
    func readyNotificationActionsExecute() async throws {
        for action in ["MARK_READ", "ARCHIVE", "DELETE"] {
            let fixture = try StartupReadinessFixture()
            let startup = fixture.startup()
            let calls = Mutex<[String]>([])
            let finished = OneShotGate()
            let initialWorkCount = DatabaseSuspension.shared.backgroundWorkCountForTesting
            let delegate = NotificationDelegate(
                readiness: { await startup.awaitLaunchReady(background: true) },
                action: { receivedAction, message, account in
                    #expect(receivedAction == action && message == "test-message" && account == "test-account")
                    calls.withLock { $0.append("action") }
                }
            )
            delegate.handleNotificationResponse(
                actionId: action,
                userInfo: ["messageId": "test-message", "accountId": "test-account"]
            ) { calls.withLock { $0.append("finish") }; finished.open() }
            try await withTimeout(seconds: 3) { await finished.wait() }
            #expect(calls.withLock { $0 } == ["action", "finish"])
            #expect(DatabaseSuspension.shared.backgroundWorkCountForTesting == initialWorkCount)
        }
    }

    @Test("Invalid notification action payload finishes without starting readiness")
    func invalidNotificationActionFinishesWithoutReadiness() {
        for action in ["MARK_READ", "ARCHIVE", "DELETE"] {
            let calls = Mutex<[String]>([])
            let delegate = NotificationDelegate(
                readiness: { calls.withLock { $0.append("readiness") }; return false },
                action: { _, _, _ in calls.withLock { $0.append("action") } }
            )
            delegate.handleNotificationResponse(actionId: action, userInfo: [:]) {
                calls.withLock { $0.append("finish") }
            }
            #expect(calls.withLock { $0 } == ["finish"])
        }
    }

    @Test("Silent push reports failure and balances work after either startup failure")
    func silentPushReturnsFailureWithoutServiceWork() async throws {
        for stage in ["probe", "build"] {
            let fixture = try StartupReadinessFixture()
            let startup = fixture.startup(failingAt: stage)
            let calls = Mutex(0)
            let initialWorkCount = DatabaseSuspension.shared.backgroundWorkCountForTesting
            let delegate = AppDelegate(
                silentPushReadiness: { await startup.awaitLaunchReady(background: true) },
                silentPushWork: { calls.withLock { $0 += 1 }; return .newData }
            )
            let result = await delegate.application(UIApplication.shared, didReceiveRemoteNotification: [:])
            #expect(result == .failed)
            #expect(calls.withLock { $0 } == 0)
            #expect(startup.failureMessage != nil)
            #expect(DatabaseSuspension.shared.backgroundWorkCountForTesting == initialWorkCount)
        }
    }

    @Test("Ready silent push reaches its service and forwards its result")
    func readySilentPushForwardsServiceResult() async throws {
        let fixture = try StartupReadinessFixture()
        let startup = fixture.startup()
        let calls = Mutex(0)
        let initialWorkCount = DatabaseSuspension.shared.backgroundWorkCountForTesting
        let delegate = AppDelegate(
            silentPushReadiness: { await startup.awaitLaunchReady(background: true) },
            silentPushWork: { calls.withLock { $0 += 1 }; return .newData }
        )
        #expect(await delegate.application(UIApplication.shared, didReceiveRemoteNotification: [:]) == .newData)
        #expect(calls.withLock { $0 } == 1)
        #expect(DatabaseSuspension.shared.backgroundWorkCountForTesting == initialWorkCount)
    }
}

private final class BackgroundReadinessEvents: Sendable {
    let completions = Mutex<[Bool]>([])
    let schedules = Mutex<[Bool]>([])
    let work = Mutex<[Bool]>([])
    let expirationEffects = Mutex<[String]>([])
    let expiration = Mutex<(@Sendable () -> Void)?>(nil)
    let cancellationReceived = OneShotGate()
}

@MainActor
private final class BackgroundReadinessFixture {
    let events: BackgroundReadinessEvents
    let context: BGTaskContext
    let scheduler: SyncScheduler

    init(
        startup: AppStartup,
        remainingWork: Bool = false,
        connected: Bool = true,
        pollActive: Bool = false
    ) {
        let events = BackgroundReadinessEvents()
        self.events = events
        context = BGTaskContext(
            label: "test-handler",
            completion: { success in events.completions.withLock { $0.append(success) } },
            cancelQueues: { inboxOnly in
                events.expirationEffects.withLock { $0.append(inboxOnly ? "cancel-refresh" : "cancel-processing") }
                events.cancellationReceived.open()
            },
            suspend: { reason in
                #expect(!Thread.isMainThread)
                events.expirationEffects.withLock { $0.append(reason) }
            }
        )
        scheduler = SyncScheduler(
            backgroundReadiness: { await startup.awaitLaunchReady(background: true) },
            backgroundWork: { inboxOnly in events.work.withLock { $0.append(inboxOnly) } },
            processingHasWork: { remainingWork },
            backgroundSchedule: { processing in events.schedules.withLock { $0.append(processing) } },
            refreshNetworkAvailable: connected,
            pollActive: pollActive
        )
    }

    func start(processing: Bool, expireBeforeRegistration: Bool = false) {
        let events = self.events
        let install: (@escaping @Sendable () -> Void) -> Void = { callback in
            events.expiration.withLock { $0 = callback }
            if expireBeforeRegistration {
                // The installer runs before the owner creates/registers its Task.
                let finished = DispatchSemaphore(value: 0)
                DispatchQueue.global().async {
                    callback()
                    finished.signal()
                }
                #expect(finished.wait(timeout: .now() + 3) == .success)
            }
        }
        if processing {
            scheduler.handleBackgroundAIProcessing(context: context, installExpirationHandler: install)
        } else {
            scheduler.handleBackgroundSync(context: context, installExpirationHandler: install)
        }
    }

    func expireOffMain() async throws {
        let callback = try #require(events.expiration.withLock { $0 })
        await Task.detached { callback() }.value
        try await withTimeout(seconds: 3) { [events] in await events.cancellationReceived.wait() }
    }

    func join() async throws {
        try await withTimeout(seconds: 3) { [context] in await context.waitForTaskForTesting() }
    }

    func assertFailed(processing: Bool, initialWorkCount: Int) async throws {
        try await join()
        #expect(events.completions.withLock { $0 } == [false])
        #expect(events.work.withLock { $0.isEmpty })
        try await observeStartup { self.events.schedules.withLock { $0.count } >= (processing ? 1 : 2) }
        #expect(events.schedules.withLock { $0 } == (processing ? [true] : [false, true]))
        #expect(DatabaseSuspension.shared.backgroundWorkCountForTesting == initialWorkCount)
    }
}

@Suite("Background startup handler ownership", .processGlobalState)
@MainActor
struct BackgroundStartupHandlerTests {
    @Test("Both BG handlers refuse both startup failures and finish once")
    func startupFailureCompletesWithoutWork() async throws {
        for processing in [false, true] {
            for stage in ["probe", "build"] {
                let startupFixture = try StartupReadinessFixture()
                let startup = startupFixture.startup(failingAt: stage)
                let fixture = BackgroundReadinessFixture(startup: startup)
                let initialWorkCount = DatabaseSuspension.shared.backgroundWorkCountForTesting
                fixture.start(processing: processing)
                try await fixture.assertFailed(processing: processing, initialWorkCount: initialWorkCount)
                #expect(startup.failureMessage != nil)
            }
        }
    }

    @Test("Expiration during startup owns completion and late usable readiness starts no work")
    func expirationDuringReadinessStopsLateWork() async throws {
        for processing in [false, true] {
            let startupFixture = try StartupReadinessFixture()
            let startup = startupFixture.startup(pauseAt: "build")
            let fixture = BackgroundReadinessFixture(startup: startup)
            let initialWorkCount = DatabaseSuspension.shared.backgroundWorkCountForTesting
            fixture.start(processing: processing)
            defer { startupFixture.release.open() }
            try await withTimeout(seconds: 3) { await startupFixture.entered.wait() }
            #expect(!startup.dbReady && fixture.events.completions.withLock { $0.isEmpty })
            try await fixture.expireOffMain()
            #expect(fixture.events.completions.withLock { $0 } == [false])
            startupFixture.release.open()
            try await fixture.assertFailed(processing: processing, initialWorkCount: initialWorkCount)
            #expect(startup.dbReady)
            #expect(fixture.events.expirationEffects.withLock { $0.count } == 2)
        }
    }

    @Test("Expiration before registration completes without even starting readiness")
    func expirationBeforeRegistrationSkipsStartup() async throws {
        for processing in [false, true] {
            let startupFixture = try StartupReadinessFixture()
            let startup = startupFixture.startup()
            let fixture = BackgroundReadinessFixture(startup: startup)
            let initialWorkCount = DatabaseSuspension.shared.backgroundWorkCountForTesting
            fixture.start(processing: processing, expireBeforeRegistration: true)
            try await withTimeout(seconds: 3) { await fixture.events.cancellationReceived.wait() }
            try await fixture.assertFailed(processing: processing, initialWorkCount: initialWorkCount)
            #expect(startupFixture.events.withLock { $0.isEmpty })
            #expect(!startup.dbReady)
        }
    }

    @Test("Failure completion remains sole owner against an already retained expiration closure")
    func failureThenRetainedExpirationDoesNotCompleteOrScheduleTwice() async throws {
        for processing in [false, true] {
            let startupFixture = try StartupReadinessFixture()
            let fixture = BackgroundReadinessFixture(startup: startupFixture.startup(failingAt: "probe"))
            let initialWorkCount = DatabaseSuspension.shared.backgroundWorkCountForTesting
            fixture.start(processing: processing)
            try await fixture.assertFailed(processing: processing, initialWorkCount: initialWorkCount)
            // Models an already-in-flight retained closure; the OS clears its property on completion.
            try await fixture.expireOffMain()
            try await fixture.assertFailed(processing: processing, initialWorkCount: initialWorkCount)
        }
    }

    @Test("Ready refresh does work once and schedules both follow-up families")
    func readyRefreshCompletesAndSchedules() async throws {
        let startupFixture = try StartupReadinessFixture()
        let fixture = BackgroundReadinessFixture(startup: startupFixture.startup())
        fixture.start(processing: false)
        try await fixture.join()
        #expect(fixture.events.work.withLock { $0 } == [true])
        #expect(fixture.events.completions.withLock { $0 } == [true])
        #expect(fixture.events.schedules.withLock { $0 } == [false, true])
    }

    @Test("Refresh poll-active and offline skips complete once without starting work")
    func readyRefreshSkipPathsCompleteOnce() async throws {
        for pollActive in [false, true] {
            let startupFixture = try StartupReadinessFixture()
            let fixture = BackgroundReadinessFixture(
                startup: startupFixture.startup(), connected: pollActive, pollActive: pollActive
            )
            fixture.start(processing: false)
            try await fixture.join()
            #expect(fixture.events.work.withLock { $0.isEmpty })
            #expect(fixture.events.completions.withLock { $0 } == [true])
            #expect(fixture.events.schedules.withLock { $0 } == [false])
        }
    }

    @Test("Ready processing reschedules only when queued work remains")
    func readyProcessingSchedulesOnlyRemainingWork() async throws {
        for remainingWork in [false, true] {
            let startupFixture = try StartupReadinessFixture()
            let fixture = BackgroundReadinessFixture(startup: startupFixture.startup(), remainingWork: remainingWork)
            fixture.start(processing: true)
            try await fixture.join()
            try await observeStartup { !AccountManagerState.shared.fastSyncModeActive }
            #expect(fixture.events.work.withLock { $0 } == [false])
            #expect(fixture.events.completions.withLock { $0 } == [true])
            #expect(fixture.events.schedules.withLock { $0 } == (remainingWork ? [true] : []))
        }
    }
}
