/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Synchronization
import Testing
@testable import TabMail

private enum StartupFixtureError: Error { case probe, build, observationTimedOut }

/// Each instance owns an unmigrated temporary pool. It never replaces the app DB.
final class StartupReadinessFixture: Sendable {
    let directory: URL
    let pool: DatabasePool
    let events = Mutex<[String]>([])
    let entered = OneShotGate()
    let release = OneShotGate()

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        pool = try DatabasePool(path: directory.appendingPathComponent("startup.sqlite").path)
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    @MainActor
    func startup(failingAt stage: String? = nil, pauseAt: String? = nil) -> AppStartup {
        AppStartup(
            probe: { [self] in
                events.withLock { $0.append("probe") }
                if pauseAt == "probe" { entered.open(); await release.wait() }
                if stage == "probe" { throw StartupFixtureError.probe }
                return (pool, false)
            },
            buildAndPublish: { [self] receivedPool in
                #expect(receivedPool === pool)
                events.withLock { $0.append("build") }
                if pauseAt == "build" { entered.open(); await release.wait() }
                if stage == "build" { throw StartupFixtureError.build }
                events.withLock { $0.append("published") }
            },
            preparation: { [self] in
                events.withLock { $0.append("preparation") }
                if pauseAt == "preparation" { entered.open(); await release.wait() }
            },
            upkeep: { [self] in events.withLock { $0.append("upkeep") } }
        )
    }
}

@MainActor
func observeStartup(_ condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(3)
    while !condition() {
        guard Date() < deadline else { throw StartupFixtureError.observationTimedOut }
        await Task.yield()
    }
}

@Suite("AppStartup usable database readiness")
@MainActor
struct AppStartupReadinessTests {
    @Test("Probe failure releases actual concurrent waiters and rejects late callers")
    func probeFailureReleasesConcurrentAndLateWaiters() async throws {
        try await assertFailure(stage: "probe")
    }

    @Test("Build failure releases actual concurrent waiters and rejects late callers")
    func buildFailureReleasesConcurrentAndLateWaiters() async throws {
        try await assertFailure(stage: "build")
    }

    private func assertFailure(stage: String) async throws {
        let fixture = try StartupReadinessFixture()
        let startup = fixture.startup(failingAt: stage, pauseAt: stage)
        #expect(!startup.dbReady && !startup.isReady && startup.failureMessage == nil)
        let initial = Task { await startup.ensureDatabaseReady() }
        defer { fixture.release.open() }
        try await withTimeout(seconds: 3) { await fixture.entered.wait() }
        let direct = Task { await startup.ensureDatabaseReady() }
        let foreground = Task { await startup.awaitLaunchReady(background: false) }
        let background = Task { await startup.awaitLaunchReady(background: true) }
        try await observeStartup { startup.databaseWaiterCountForTesting == 3 }
        #expect(!startup.dbReady)
        fixture.release.open()
        for waiter in [initial, direct, foreground, background] {
            let usable = try await withTimeout(seconds: 3) { await waiter.value }
            #expect(!usable)
        }
        #expect(startup.databaseWaiterCountForTesting == 0)
        #expect(!startup.dbReady && !startup.isReady && startup.failureMessage != nil)
        #expect(startup.paintPollCountForTesting == 0)
        let expected = stage == "probe" ? ["probe"] : ["probe", "build"]
        #expect(fixture.events.withLock { $0 } == expected)
        let lateDirect = try await withTimeout(seconds: 3) { await startup.ensureDatabaseReady() }
        let lateForeground = try await withTimeout(seconds: 3) { await startup.awaitLaunchReady(background: false) }
        let lateBackground = try await withTimeout(seconds: 3) { await startup.awaitLaunchReady(background: true) }
        #expect(!lateDirect && !lateForeground && !lateBackground)
        #expect(fixture.events.withLock { $0 } == expected)
        #expect(startup.databaseWaiterCountForTesting == 0)
    }

    @Test("Usability follows publication and required preparation, without requiring paint")
    func usableReadinessFollowsPublicationAndPreparation() async throws {
        let fixture = try StartupReadinessFixture()
        let startup = fixture.startup(pauseAt: "preparation")
        let initial = Task { await startup.ensureDatabaseReady() }
        defer { fixture.release.open() }
        try await withTimeout(seconds: 3) { await fixture.entered.wait() }
        #expect(fixture.events.withLock { $0 } == ["probe", "build", "published", "preparation"])
        #expect(!startup.dbReady && !startup.isReady)
        let follower = Task { await startup.awaitLaunchReady(background: true) }
        try await observeStartup { startup.databaseWaiterCountForTesting == 1 }
        fixture.release.open()
        #expect(try await withTimeout(seconds: 3) { await initial.value })
        #expect(try await withTimeout(seconds: 3) { await follower.value })
        #expect(startup.dbReady && !startup.isReady && startup.failureMessage == nil)
        #expect(await startup.ensureDatabaseReady())
        #expect(fixture.events.withLock { $0 } == ["probe", "build", "published", "preparation", "upkeep"])
    }

    @Test("Foreground waits for a real paint signal after usable readiness")
    func foregroundWaitsForFirstPaint() async throws {
        let fixture = try StartupReadinessFixture()
        let startup = fixture.startup()
        #expect(await startup.ensureDatabaseReady())
        let returned = Mutex(false)
        let foreground = Task {
            let usable = await startup.awaitLaunchReady(background: false)
            returned.withLock { $0 = true }
            return usable
        }
        try await observeStartup { startup.paintPollCountForTesting > 0 }
        #expect(!returned.withLock { $0 })
        #expect(!startup.isReady && startup.dbReady)
        startup.signalFirstPaintForTesting()
        #expect(try await withTimeout(seconds: 3) { await foreground.value })
        #expect(startup.isReady && startup.dbReady)
    }

    @Test("Foreground paint timeout preserves usable database result")
    func foregroundTimeoutPreservesUsability() async throws {
        let fixture = try StartupReadinessFixture()
        let startup = fixture.startup()
        #expect(await startup.awaitLaunchReady(background: false, firstPaintTimeoutSeconds: 0))
        #expect(startup.dbReady && !startup.isReady && startup.failureMessage == nil)
    }

    @Test("Cancellation inside paint polling preserves usability but stops caller work")
    func cancellationAfterUsabilityStopsCallerWork() async throws {
        let fixture = try StartupReadinessFixture()
        let startup = fixture.startup()
        #expect(await startup.ensureDatabaseReady())
        let downstream = Mutex(false)
        let foreground = Task {
            let usable = await startup.awaitLaunchReady(background: false)
            if usable && !Task.isCancelled { downstream.withLock { $0 = true } }
            return usable
        }
        try await observeStartup { startup.paintPollCountForTesting > 0 }
        foreground.cancel()
        #expect(try await withTimeout(seconds: 3) { await foreground.value })
        #expect(!downstream.withLock { $0 })
        #expect(startup.dbReady && !startup.isReady && startup.failureMessage == nil)
    }
}

@Suite("BGTask completion ownership")
struct BGTaskCompletionTests {
    @Test("Failure completion owns the sole terminal callback before expiration")
    func failureThenExpirationCompletesOnce() {
        let context = BGTaskContext(label: "test-failure-first", completion: { _ in })
        #expect(context.claimCompletion(success: false) == false)
        context.expire()
        #expect(context.claimCompletion(success: false) == nil)
        #expect(context.claimCompletion(success: true) == nil)
    }

    @Test("Expiration wins completion and late usable readiness cannot complete again")
    func expirationThenReadinessCompletesOnce() {
        let context = BGTaskContext(label: "test-expiration-first", completion: { _ in })
        context.expire()
        #expect(context.claimCompletion(success: false) == false)
        #expect(context.claimCompletion(success: true) == nil)
    }

    @Test("An expired unclaimed task cannot report success")
    func expiredSuccessBecomesFailure() {
        let context = BGTaskContext(label: "test-expired-success", completion: { _ in })
        context.expire()
        #expect(context.claimCompletion(success: true) == false)
        #expect(context.claimCompletion(success: false) == nil)
    }

    @Test("Concurrent completion attempts produce one terminal callback")
    func concurrentClaimsCompleteOnce() async {
        let context = BGTaskContext(label: "test-concurrent", completion: { _ in })
        let completions = Mutex<[Bool]>([])
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<64 {
                group.addTask { @Sendable in
                    if index.isMultiple(of: 2) { context.expire() }
                    if let result = context.claimCompletion(success: !index.isMultiple(of: 2)) {
                        completions.withLock { $0.append(result) }
                    }
                }
            }
        }
        #expect(completions.withLock { $0.count } == 1)
    }

    @Test("Expiration before task registration cancels the eventual task")
    func expirationBeforeRegistrationCancelsTask() async throws {
        let context = BGTaskContext(label: "test-expiration-before-task", completion: { _ in })
        let release = OneShotGate()
        let cancelled = Mutex(false)
        context.expire()
        let task = Task {
            await release.wait()
            cancelled.withLock { $0 = Task.isCancelled }
        }
        context.setTask(task)
        release.open()
        try await withTimeout(seconds: 3) { await task.value }
        #expect(cancelled.withLock { $0 })
    }
}
