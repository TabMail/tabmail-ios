/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Synchronization
import Testing
@testable import TabMail

private struct AsyncTestSignalFinished: Error {}

private struct AsyncTestSignal<Element: Sendable>: Sendable {
    private let stream: AsyncStream<Element>
    private let continuation: AsyncStream<Element>.Continuation

    init() {
        let pair = AsyncStream<Element>.makeStream()
        stream = pair.stream
        continuation = pair.continuation
    }

    func send(_ element: Element) {
        _ = continuation.yield(element)
    }

    func finish() {
        continuation.finish()
    }

    func next() async throws -> Element {
        let stream = stream
        let element = try await withTimeout(
            seconds: SyncConfig.pendingOperationTimeoutSeconds
        ) {
            var iterator = stream.makeAsyncIterator()
            return await iterator.next()
        }
        guard let element else { throw AsyncTestSignalFinished() }
        return element
    }
}

/// Intentionally not annotated with `.processGlobalState`: these tests must
/// create independent owners and observe real handoffs. Every process-global
/// mutation below is performed inside an explicit trait/`withLock` scope.
@Suite("Process-global test-state isolation")
struct ProcessGlobalTestStateTests {
    private enum ScopeEvent: Equatable, Sendable {
        case queued
        case entered
    }

    private enum LeaseEvent: Equatable, Sendable {
        case queued
        case entered
    }

    private struct DatabaseFixture {
        let directory: URL
        let pool: DatabasePool
        let database: AppDatabase
    }

    private func makeDatabaseFixture() throws -> DatabaseFixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        let pool = try DatabasePool(
            path: directory.appendingPathComponent("test.sqlite").path,
            configuration: configuration
        )
        let database = try AppDatabase(dbPool: pool)
        return DatabaseFixture(directory: directory, pool: pool, database: database)
    }

    private func makeTwoDatabaseFixtures() throws -> (
        first: DatabaseFixture,
        second: DatabaseFixture
    ) {
        let first = try makeDatabaseFixture()
        let second: DatabaseFixture
        do {
            second = try makeDatabaseFixture()
        } catch {
            closeThenRemove(first)
            throw error
        }
        return (first, second)
    }

    private func join(_ task: Task<Void, any Error>) async throws {
        try await withTimeout(seconds: SyncConfig.pendingOperationTimeoutSeconds) {
            try await task.value
        }
    }

    private func cancelAndSettle(_ task: Task<Void, any Error>) async -> Bool {
        task.cancel()
        do {
            try await withTimeout(seconds: SyncConfig.pendingOperationTimeoutSeconds) {
                try await task.value
            }
            return true
        } catch is TimeoutError {
            return false
        } catch {
            // A completed throwing task is settled and no longer owns a fixture.
            return true
        }
    }

    private func restoreProcessDatabase(
        _ original: (captured: Bool, database: AppDatabase?)
    ) async throws {
        guard original.captured else { return }
        try await ProcessGlobalTestState.withLock {
            AppDatabase.shared.withLock { $0 = original.database }
        }
    }

    private func closeThenRemove(
        _ fixture: DatabaseFixture,
        alreadyClosed: Bool = false
    ) {
        do {
            if !alreadyClosed {
                try fixture.pool.close()
            }
            try FileManager.default.removeItem(at: fixture.directory)
        } catch {
            Issue.record(
                "Failed to close the process-global fixture before unlinking it: \(error)"
            )
        }
    }

    @Test("two trait scopes cannot capture and later restore a sibling's closed database")
    func closedPoolRestoreOrderingIsSerialized() async throws {
        let fixtures = try makeTwoDatabaseFixtures()
        let first = fixtures.first
        let second = fixtures.second

        let currentTest = try #require(Test.current)
        let currentTestCase = Test.Case.current
        let trait = ProcessGlobalTestStateTrait()

        let processOriginal = Mutex<(captured: Bool, database: AppDatabase?)>((false, nil))
        let secondCapturedOriginal = Mutex(false)
        let secondCapturedValidPreviousState = Mutex(false)
        let firstPoolClosed = Mutex(false)
        let secondPoolClosed = Mutex(false)

        let firstInstalled = AsyncTestSignal<Void>()
        let releaseFirst = AsyncTestSignal<Void>()
        let releaseSecond = AsyncTestSignal<Void>()
        let events = AsyncTestSignal<ScopeEvent>()

        let firstTask = Task { @Sendable in
            try await trait.provideScope(for: currentTest, testCase: currentTestCase) {
                let original = AppDatabase.shared.withLock { current -> AppDatabase? in
                    let original = current
                    current = first.database
                    return original
                }
                processOriginal.withLock { $0 = (true, original) }
                defer { AppDatabase.shared.withLock { $0 = original } }
                firstInstalled.send(())
                _ = try await releaseFirst.next()
                try first.pool.close()
                firstPoolClosed.withLock { $0 = true }
            }
        }

        let secondTask = Task { @Sendable in
            _ = try await firstInstalled.next()
            try await ProcessGlobalTestState.withQueuedObserverForTesting({
                events.send(.queued)
            }) {
                try await trait.provideScope(for: currentTest, testCase: currentTestCase) {
                    let previous = AppDatabase.shared.withLock { current -> AppDatabase? in
                        let previous = current
                        current = second.database
                        return previous
                    }
                    defer { AppDatabase.shared.withLock { $0 = previous } }
                    let original = processOriginal.withLock { $0.database }
                    let capturedOriginal: Bool
                    switch (previous, original) {
                    case (nil, nil):
                        capturedOriginal = true
                    case let (previous?, original?):
                        capturedOriginal = previous === original
                    default:
                        capturedOriginal = false
                    }
                    secondCapturedOriginal.withLock { $0 = capturedOriginal }
                    events.send(.entered)
                    _ = try await releaseSecond.next()

                    let validPreviousState: Bool
                    if let previous {
                        do {
                            validPreviousState = try await previous.dbPool.read { db in
                                try Int.fetchOne(db, sql: "SELECT 1") == 1
                            }
                        } catch {
                            validPreviousState = false
                        }
                    } else {
                        validPreviousState = true
                    }
                    secondCapturedValidPreviousState.withLock { $0 = validPreviousState }
                    try second.pool.close()
                    secondPoolClosed.withLock { $0 = true }
                }
            }
        }

        do {
            let firstEvent = try await events.next()
            #expect(
                firstEvent == .queued,
                "the second process-global scope entered before the first restored its database"
            )

            releaseFirst.send(())
            try await join(firstTask)

            if firstEvent == .queued {
                let secondEvent = try await events.next()
                #expect(secondEvent == .entered)
            }
            releaseSecond.send(())
            try await join(secondTask)
        } catch {
            releaseFirst.finish()
            releaseSecond.finish()
            firstInstalled.finish()
            events.finish()
            let firstSettled = await cancelAndSettle(firstTask)
            let secondSettled = await cancelAndSettle(secondTask)
            let original = processOriginal.withLock { $0 }
            guard firstSettled && secondSettled else {
                Issue.record(
                    "A process-global fixture task did not settle; preserving its open pools"
                )
                throw error
            }
            try await restoreProcessDatabase(original)
            closeThenRemove(second, alreadyClosed: secondPoolClosed.withLock { $0 })
            closeThenRemove(first, alreadyClosed: firstPoolClosed.withLock { $0 })
            throw error
        }

        releaseFirst.finish()
        releaseSecond.finish()
        firstInstalled.finish()
        events.finish()
        let original = processOriginal.withLock { $0 }
        try await restoreProcessDatabase(original)
        closeThenRemove(second, alreadyClosed: secondPoolClosed.withLock { $0 })
        closeThenRemove(first, alreadyClosed: firstPoolClosed.withLock { $0 })

        #expect(secondCapturedOriginal.withLock { $0 })
        #expect(secondCapturedValidPreviousState.withLock { $0 })
    }

    @Test("nested trait scopes acquire a re-entrant lease without queuing")
    func nestedTraitScopeIsReentrant() async throws {
        let currentTest = try #require(Test.current)
        let currentTestCase = Test.Case.current
        let trait = ProcessGlobalTestStateTrait()
        let queued = Mutex(false)
        let nestedScopeRan = Mutex(false)

        try await trait.provideScope(for: currentTest, testCase: currentTestCase) {
            try await ProcessGlobalTestState.withQueuedObserverForTesting({
                queued.withLock { $0 = true }
            }) {
                try await trait.provideScope(for: currentTest, testCase: currentTestCase) {
                    nestedScopeRan.withLock { $0 = true }
                }
            }
        }

        #expect(queued.withLock { !$0 })
        #expect(nestedScopeRan.withLock { $0 })
    }

    @Test("a child lease acquired before outer return keeps the lock owned")
    func childLeaseExtendsOuterOwnership() async throws {
        let childEntered = AsyncTestSignal<Void>()
        let releaseChild = AsyncTestSignal<Void>()
        let contenderEvents = AsyncTestSignal<LeaseEvent>()
        let childTask = Mutex<Task<Void, any Error>?>(nil)

        let outerTask = Task {
            try await ProcessGlobalTestState.withLock {
                let task = Task {
                    try await ProcessGlobalTestState.withLock {
                        childEntered.send(())
                        _ = try await releaseChild.next()
                    }
                }
                childTask.withLock { $0 = task }
                _ = try await childEntered.next()
            }
        }

        var contenderTask: Task<Void, any Error>?
        do {
            try await join(outerTask)
            let inheritedChildTask = try #require(childTask.withLock { $0 })

            let task = Task {
                try await ProcessGlobalTestState.withQueuedObserverForTesting({
                    contenderEvents.send(.queued)
                }) {
                    try await ProcessGlobalTestState.withLock {
                        contenderEvents.send(.entered)
                    }
                }
            }
            contenderTask = task

            let firstEvent = try await contenderEvents.next()
            #expect(
                firstEvent == .queued,
                "the outer scope released ownership while its child's lease was active"
            )

            releaseChild.send(())
            try await join(inheritedChildTask)
            if firstEvent == .queued {
                #expect(try await contenderEvents.next() == .entered)
            }
            try await join(task)
        } catch {
            releaseChild.finish()
            childEntered.finish()
            contenderEvents.finish()
            _ = await cancelAndSettle(outerTask)
            if let inheritedChildTask = childTask.withLock({ $0 }) {
                _ = await cancelAndSettle(inheritedChildTask)
            }
            if let contenderTask {
                _ = await cancelAndSettle(contenderTask)
            }
            throw error
        }

        releaseChild.finish()
        childEntered.finish()
        contenderEvents.finish()
    }

    @Test("a child first acquiring after outer return queues behind the next owner")
    func staleInheritedTokenCannotBypassNextOwner() async throws {
        let allowChildAttempt = AsyncTestSignal<Void>()
        let releaseNextOwner = AsyncTestSignal<Void>()
        let events = AsyncTestSignal<LeaseEvent>()
        let staleChildTask = Mutex<Task<Void, any Error>?>(nil)

        let outerTask = Task {
            try await ProcessGlobalTestState.withLock {
                let task = Task {
                    _ = try await allowChildAttempt.next()
                    try await ProcessGlobalTestState.withQueuedObserverForTesting({
                        events.send(.queued)
                    }) {
                        try await ProcessGlobalTestState.withLock {
                            events.send(.entered)
                        }
                    }
                }
                staleChildTask.withLock { $0 = task }
            }
        }

        var nextOwnerTask: Task<Void, any Error>?
        do {
            try await join(outerTask)
            let inheritedChildTask = try #require(staleChildTask.withLock { $0 })

            let task = Task {
                try await ProcessGlobalTestState.withLock {
                    events.send(.entered)
                    _ = try await releaseNextOwner.next()
                }
            }
            nextOwnerTask = task
            #expect(try await events.next() == .entered)

            allowChildAttempt.send(())
            let childEvent = try await events.next()
            #expect(
                childEvent == .queued,
                "the child reused an inherited token after its owner's lease ended"
            )

            releaseNextOwner.send(())
            try await join(task)
            if childEvent == .queued {
                #expect(try await events.next() == .entered)
            }
            try await join(inheritedChildTask)
        } catch {
            allowChildAttempt.finish()
            releaseNextOwner.finish()
            events.finish()
            _ = await cancelAndSettle(outerTask)
            if let inheritedChildTask = staleChildTask.withLock({ $0 }) {
                _ = await cancelAndSettle(inheritedChildTask)
            }
            if let nextOwnerTask {
                _ = await cancelAndSettle(nextOwnerTask)
            }
            throw error
        }

        allowChildAttempt.finish()
        releaseNextOwner.finish()
        events.finish()
    }

    @Test("cancelling a queued waiter removes it and the next waiter acquires")
    func cancelledWaiterDoesNotLeakContinuationOrDeadlockQueue() async throws {
        let lock = AsyncTestLock()
        let firstEntered = AsyncTestSignal<Void>()
        let releaseFirst = AsyncTestSignal<Void>()
        let secondQueued = AsyncTestSignal<Void>()
        let thirdQueued = AsyncTestSignal<Void>()
        let thirdEntered = AsyncTestSignal<Void>()
        let secondRan = Mutex(false)

        let firstTask = Task {
            try await lock.withLock(queuedObserver: nil) {
                firstEntered.send(())
                _ = try await releaseFirst.next()
            }
        }
        let secondTask = Task {
            _ = try await firstEntered.next()
            try await lock.withLock(queuedObserver: {
                secondQueued.send(())
            }) {
                secondRan.withLock { $0 = true }
            }
        }

        var thirdTask: Task<Void, any Error>?
        do {
            _ = try await secondQueued.next()
            secondTask.cancel()
            do {
                try await join(secondTask)
                Issue.record("the cancelled queued waiter unexpectedly acquired the lock")
            } catch is CancellationError {
                // Expected: the lock resumed and removed the cancelled waiter.
            }

            let task = Task {
                try await lock.withLock(queuedObserver: {
                    thirdQueued.send(())
                }) {
                    thirdEntered.send(())
                }
            }
            thirdTask = task
            _ = try await thirdQueued.next()

            releaseFirst.send(())
            try await join(firstTask)
            _ = try await thirdEntered.next()
            try await join(task)
        } catch {
            releaseFirst.finish()
            firstEntered.finish()
            secondQueued.finish()
            thirdQueued.finish()
            thirdEntered.finish()
            _ = await cancelAndSettle(firstTask)
            _ = await cancelAndSettle(secondTask)
            if let thirdTask {
                _ = await cancelAndSettle(thirdTask)
            }
            throw error
        }

        releaseFirst.finish()
        firstEntered.finish()
        secondQueued.finish()
        thirdQueued.finish()
        thirdEntered.finish()
        #expect(secondRan.withLock { !$0 })
    }
}
