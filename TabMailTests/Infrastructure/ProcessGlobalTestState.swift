/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Testing
@testable import TabMail

/// Serializes each test that mutates TabMail's process-wide test state.
///
/// Swift Testing's `.serialized` trait only orders tests inside one suite. It
/// does not stop a different suite from replacing `AppDatabase.shared`, the
/// provider registry, the undo stack, or another singleton at the same time.
/// Applying this recursive trait to every suite that touches those globals
/// gives all of them one shared, async-safe critical section.
struct ProcessGlobalTestStateTrait: TestTrait, SuiteTrait, TestScoping {
    let isRecursive = true

    func provideScope(
        for test: Test,
        testCase: Test.Case?,
        performing function: @Sendable () async throws -> Void
    ) async throws {
        try await ProcessGlobalTestState.withLock(function)
    }
}

extension Trait where Self == ProcessGlobalTestStateTrait {
    static var processGlobalState: Self { Self() }
}

/// Shared implementation behind `ProcessGlobalTestStateTrait`.
///
/// The task-local owner token makes nested annotated suites re-entrant. Each
/// re-entrant acquisition owns a lease, so an outer scope cannot hand the lock
/// to another test until child work that already acquired a lease releases it.
/// An inherited token that is first used after its owner released is stale and
/// must queue as a new owner instead of bypassing the current test. The actor
/// gate is FIFO and cancellation-safe: cancelling a queued test removes and
/// resumes its continuation instead of leaving the whole test process locked.
enum ProcessGlobalTestState {
    @TaskLocal private static var ownerToken: UUID?
    @TaskLocal private static var queuedObserver: (@Sendable () -> Void)? = nil

    private static let lock = AsyncTestLock()

    static func withLock(
        _ function: @Sendable () async throws -> Void
    ) async throws {
        // Publish the sink database BEFORE the scoped body captures anything.
        // Every annotated suite swaps `AppDatabase.shared` and later restores
        // the value it captured; if that captured value is nil (the host app
        // publishes asynchronously, so early tests observe nil), the restore
        // re-arms a nil `AppDatabase.shared` that a task escaping the test —
        // `drainOutbox()`, `redriveDurableQueue()` — trips over inside
        // `AppDatabase.rawPool`, killing the entire test process and silently
        // dropping every test that had not run yet. Guaranteeing non-nil here
        // makes that nil unreachable without weakening `rawPool`'s deliberate
        // force-unwrap. See `TestAppDatabaseSink`.
        TestAppDatabaseSink.installIfNeeded()
        try await lock.withLock(
            ownerToken: ownerToken,
            queuedObserver: queuedObserver
        ) { acquiredOwnerToken in
            // 🚨 INSIDE the critical section, never before acquiring it.
            // `AccountManager.recentlyCompleted` is process-global sync-protection
            // state keyed by a BARE message id — an IMAP UID — so ids one suite
            // completes (`FakeIMAPServer`'s COPY hands out 1/2/3 for an empty
            // destination) protect the identically numbered rows of an unrelated
            // suite's folder for the whole 30 s TTL, and the stale sweep that must
            // delete them keeps them instead. `IOS-TEST-006`. `.serialized` only
            // orders tests inside ONE suite, so this scope is the only boundary
            // that composes across suites. Clearing it BEFORE acquiring would let
            // a queued test wipe the entries the RUNNING test just recorded.
            await AccountManager.shared.clearRecentlyCompletedForTesting()
            try await $ownerToken.withValue(acquiredOwnerToken) {
                try await function()
            }
        }
    }

    /// Lets the isolation regression distinguish "the second scope queued"
    /// from "the second scope entered" without sleeps or timing guesses.
    static func withQueuedObserverForTesting(
        _ observer: @escaping @Sendable () -> Void,
        performing function: @Sendable () async throws -> Void
    ) async throws {
        try await $queuedObserver.withValue(observer) {
            try await function()
        }
    }
}

actor AsyncTestLock {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<UUID?, Never>
    }

    private var currentOwnerToken: UUID?
    private var leaseCount = 0
    private var waiters: [Waiter] = []

    func withLock(
        queuedObserver: (@Sendable () -> Void)?,
        _ function: @Sendable () async throws -> Void
    ) async throws {
        try await withLock(ownerToken: nil, queuedObserver: queuedObserver) { _ in
            try await function()
        }
    }

    func withLock(
        ownerToken inheritedOwnerToken: UUID?,
        queuedObserver: (@Sendable () -> Void)?,
        _ function: @Sendable (UUID) async throws -> Void
    ) async throws {
        let id = UUID()
        let acquiredOwnerToken = try await acquire(
            id: id,
            inheritedOwnerToken: inheritedOwnerToken,
            queuedObserver: queuedObserver
        )

        do {
            try Task.checkCancellation()
            try await function(acquiredOwnerToken)
        } catch {
            release(ownerToken: acquiredOwnerToken)
            throw error
        }

        release(ownerToken: acquiredOwnerToken)
    }

    private func acquire(
        id: UUID,
        inheritedOwnerToken: UUID?,
        queuedObserver: (@Sendable () -> Void)?
    ) async throws -> UUID {
        if Task.isCancelled {
            throw CancellationError()
        }

        if let inheritedOwnerToken,
           inheritedOwnerToken == currentOwnerToken
        {
            leaseCount += 1
            return inheritedOwnerToken
        }

        if currentOwnerToken == nil {
            return beginNewOwnership()
        }

        let acquiredOwnerToken = await withTaskCancellationHandler {
            await withCheckedContinuation {
                (continuation: CheckedContinuation<UUID?, Never>) in
                if Task.isCancelled {
                    continuation.resume(returning: nil)
                } else {
                    waiters.append(Waiter(id: id, continuation: continuation))
                    queuedObserver?()
                }
            }
        } onCancel: {
            Task { await self.cancel(id: id) }
        }

        guard let acquiredOwnerToken else { throw CancellationError() }
        return acquiredOwnerToken
    }

    private func cancel(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(returning: nil)
    }

    private func beginNewOwnership() -> UUID {
        let ownerToken = UUID()
        currentOwnerToken = ownerToken
        leaseCount = 1
        return ownerToken
    }

    private func release(ownerToken: UUID) {
        guard currentOwnerToken == ownerToken, leaseCount > 0 else {
            assertionFailure("Attempted to release an unowned process-global test lock")
            return
        }

        leaseCount -= 1
        guard leaseCount == 0 else { return }

        if waiters.isEmpty {
            currentOwnerToken = nil
            return
        }

        let waiter = waiters.removeFirst()
        let nextOwnerToken = UUID()
        currentOwnerToken = nextOwnerToken
        leaseCount = 1
        waiter.continuation.resume(returning: nextOwnerToken)
    }
}

/// Scoped registration on the shared `AccountManager` provider registry — one of
/// the process-global surfaces `ProcessGlobalTestStateTrait` above exists to
/// serialize, which is why it lives in this file.
///
/// 🚨 **The unregister MUST be awaited on BOTH exits — never `defer { Task { … } }`.**
/// `AccountManager` is an `actor`, so an unregister launched from a `defer` is an
/// actor JOB that is merely ENQUEUED when the scope returns, not applied; the
/// registry is NOT yet quiescent. A test that registers a SECOND time then has
/// that stale first job still pending, and it runs at the next suspension —
/// which is inside the second leg's very first `await`. It removes the provider
/// the code under test is about to read, `providers[accountId]` comes back nil,
/// and the code (e.g. `runUidValidityResetReaction`) silently early-returns at
/// its provider guard, whose only witness is a
/// `DebugModeManager.isLoggingEnabled()`-gated print (false under test). The
/// second leg then looks exactly like "the reaction/purge/cleanup did nothing"
/// when in truth it never started — precisely the misreading a non-vacuity check
/// exists to prevent, and one `UidValidityResetPurgeCompanionTests`'
/// `inboxRemovalMarkersArePurgedOnlyByAnInboxRoleReset` actually suffered.
/// Awaiting on BOTH exits (normal and thrown) is what makes the teardown a
/// contract rather than a hope: when this returns, the registry state is settled
/// and no queued job from it can land inside a later leg.
///
/// This is the single definition of that contract. It was three byte-identical
/// `private static func withRegisteredProvider` copies — in
/// `PostSendServerDraftCleanupTests`, `UidValidityResetPurgeCompanionTests` and
/// `UidValidityResetReactionTests` — consolidated here for `IOS-QUEUE-003`
/// item 8. Bodies were identical; only the doc block's example phrasing
/// differed, and all three phrasings are preserved above.
enum TestProviderRegistry {
    /// `isolation:` (SE-0420) so `body` stays in the CALLER's isolation domain
    /// WHATEVER that domain is: a nonisolated helper would make the closure a
    /// value sent across an isolation boundary (`sending value of non-Sendable
    /// type '() async -> ()'`), and a hard `@MainActor` would force every
    /// caller onto the main actor — a real behavioural change for the
    /// nonisolated suites adopted for `IOS-TEST-008`. `#isolation` resolves to
    /// `MainActor.shared` for the `@MainActor` callers this helper was written
    /// for, so their behaviour is unchanged.
    static func withRegisteredProvider(
        isolation: isolated (any Actor)? = #isolation,
        accountId: String, provider: any EmailProvider, _ body: () async throws -> Void
    ) async rethrows {
        await AccountManager.shared.registerProviderForTesting(accountId: accountId, provider: provider)
        do {
            try await body()
        } catch {
            await AccountManager.shared.unregisterProviderForTesting(accountId: accountId)
            throw error
        }
        await AccountManager.shared.unregisterProviderForTesting(accountId: accountId)
    }
}
