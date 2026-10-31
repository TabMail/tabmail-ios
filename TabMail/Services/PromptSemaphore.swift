/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Synchronization

/// Why the prompt store refused a call (DS-SEMAPHORE, DS-COUNTER).
enum PromptRefusal: Error, Equatable, Sendable {
    /// Another caller held the semaphore for the whole wait, or the call was made inside a hold (DS-NESTED).
    case busy
    /// An AI writer's counter moved since it read (DS-AI), or its hold ran past its lease (DS-LEASE).
    case changed
}

/// DS-COUNTER: the device's change counter, an opaque value, readable from any thread. The disabled-reminders
/// map, which is not a prompt field and has its own lock, compares it inside its transaction (DS-DEMO).
final class ChangeCounter: Sendable {
    /// The one counter of this device's prompt store.
    static let device = ChangeCounter()

    private let value = Mutex(UUID())
    private let switchValue = Mutex(0)

    var current: UUID { value.withLock { $0 } }

    /// How many times the demo was entered or left (DS-DEMO). Unlike `current`, ordinary commits leave it
    /// alone, so a brief operation that waited in line behind other edits is still of its mode.
    var switches: Int { switchValue.withLock { $0 } }

    func renew() { value.withLock { $0 = UUID() } }

    /// The demo was entered or left: moves the count and renews the counter, together.
    func renewForSwitch() {
        switchValue.withLock { $0 += 1 }
        renew()
    }
}

/// A caller's hold of the semaphore (DS-LEASE): a write checks `isHolder` immediately before the storage
/// write, after every await, so an expired holder saves nothing wherever it was.
@MainActor
struct PromptHold {
    let token: UUID
    fileprivate let semaphore: PromptSemaphore

    /// Whether this hold is still the holder: not released and not past its lease.
    var isHolder: Bool { semaphore.holds(token) }

    /// The change counter as it is now (DS-AI step 1 takes it in the read hold).
    var counter: UUID { semaphore.counter }

    /// DS-AI step 3, DS-LEASE: refuses a write that is no longer the holder, or whose read counter moved.
    func requireUnchanged(since read: UUID) throws {
        guard isHolder, semaphore.counter == read else { throw PromptRefusal.changed }
    }
}

/// The one semaphore of this device's prompt store (DS-SEMAPHORE): the knowledge base, the writing style
/// and the action rules are read and written only while holding it, through
/// `PromptStore.withPromptStore`.
///
/// Never an infinite block: a hold is released on every exit of its body (DS-SEMAPHORE); a hold past
/// its lease loses the semaphore (DS-LEASE); a call made inside a hold is refused at once (DS-NESTED,
/// a task-local marks the holding task); a waiting caller waits in one first-in-first-out queue for a
/// capped time, so the user's later gesture never lands before an earlier one. Sign-in
/// state never refuses a hold: the texts are the device's, and only the AI calls and Device Sync need
/// an account (DS-DEVICE).
///
/// ⚠️ A `Task { }` created inside a hold inherits the task-local `holding` mark and would be refused
/// as nested: create it under `PromptSemaphore.$holding.withValue(nil)` (MIS-IOS-028).
@MainActor
final class PromptSemaphore {
    struct Config: Sendable {
        /// DS-LEASE: a hold running longer than this loses the semaphore.
        var leaseSeconds: Double
        /// DS-SEMAPHORE, request order: how long a caller refused because another holds the semaphore
        /// waits, in one first-in-first-out queue, before it is refused as busy.
        var acquireWaitSeconds: Double

        /// DS-DEMO: how many times entering or leaving the demo asks for the semaphore before it gives up: enough
        /// waits to outlast one lease.
        var switchAttempts: Int = 3

        static let standard = Config(leaseSeconds: 15, acquireWaitSeconds: 6)
    }

    /// DS-NESTED: the holding task's hold, so a nested call is refused instead of waiting on itself.
    @TaskLocal static var holding: UUID?

    var config: Config

    /// DS-COUNTER: an opaque value renewed on every commit that saved a change (an edit, a refine, a
    /// merge or legacy import that changed a field, a reset, every accepted restore). Its only users
    /// are AI writers (DS-AI). Sign-in, sign-out, an upgrade's save and lease expiry do not renew it.
    var counter: UUID { changeCounter.current }
    private let changeCounter: ChangeCounter

    /// `deadline` is when the lease ends on the monotonic clock: the lease timer hands the semaphore over, but
    /// a timer the MainActor runs late must not leave an overdue holder with write authority (DS-LEASE).
    private var holder: (token: UUID, label: String, lease: Task<Void, Never>, deadline: ContinuousClock.Instant)?

    /// DS-SEMAPHORE, request order: the callers waiting, oldest first. A request never takes the
    /// semaphore while an earlier one still waits; a release hands it to the head.
    private struct Waiter {
        let token: UUID
        let label: String
        let resolve: (Bool) -> Void
    }

    private var queue: [Waiter] = []

    init(config: Config = .standard, counter: ChangeCounter = ChangeCounter()) {
        self.config = config
        changeCounter = counter
    }

    /// Runs `body` holding the semaphore, waiting for its turn in the queue for at most
    /// `config.acquireWaitSeconds` while another caller holds it, and releasing it on every exit.
    func hold<T>(_ label: String, _ body: (PromptHold) async throws -> T) async throws -> T {
        if let outer = Self.holding {
            BackgroundSyncLogger.logDebug("[PromptStore] \(label) refused: called inside the hold \(outer.uuidString.prefix(8))")
            throw PromptRefusal.busy
        }
        let token = UUID()
        if holder != nil {
            guard await waitForTurn(token, label) else {
                BackgroundSyncLogger.logDebug("[PromptStore] \(label) refused: the prompt store stayed held for \(config.acquireWaitSeconds) s")
                throw PromptRefusal.busy
            }
        } else {
            acquire(token, label)
        }
        defer { release(token) }
        return try await Self.$holding.withValue(token) { try await body(PromptHold(token: token, semaphore: self)) }
    }

    /// Whether `token` still holds the semaphore (not released, not past its lease).
    func holds(_ token: UUID) -> Bool {
        guard let current = holder, current.token == token else { return false }
        return ContinuousClock.now < current.deadline
    }

    /// DS-DEMO: how many times the demo was entered or left, as `ChangeCounter.switches`.
    var switches: Int { changeCounter.switches }

    /// DS-COUNTER: a commit saved a change; a write that read the previous value is refused.
    func renewCounter() {
        changeCounter.renew()
    }

    /// DS-DEMO: the demo was entered or left, inside the switch's hold: the counter moves and so does
    /// the switch count.
    func renewCounterForSwitch() {
        changeCounter.renewForSwitch()
    }

    /// Takes the semaphore for `token` with its lease.
    private func acquire(_ token: UUID, _ label: String) {
        let lease = Task { [weak self, leaseSeconds = config.leaseSeconds] in
            try? await Task.sleep(for: .seconds(leaseSeconds))
            guard !Task.isCancelled, let self, self.holder?.token == token else { return }
            BackgroundSyncLogger.logDebug("[PromptStore] \(label) ran past its lease: it lost the prompt store")
            self.holder = nil
            self.grantNext()
        }
        holder = (token, label, lease, ContinuousClock.now + .seconds(config.leaseSeconds))
    }

    /// Waits in the queue; true when the semaphore was handed over, false at the deadline or when the
    /// waiting task was cancelled (the waiter is then dropped from the queue).
    private func waitForTurn(_ token: UUID, _ label: String) async -> Bool {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                guard !Task.isCancelled else { return continuation.resume(returning: false) }
                let deadline = Task { [weak self, wait = config.acquireWaitSeconds] in
                    try? await Task.sleep(for: .seconds(wait))
                    self?.drop(token)
                }
                queue.append(Waiter(token: token, label: label) { granted in
                    deadline.cancel()
                    continuation.resume(returning: granted)
                })
            }
        } onCancel: {
            Task { @MainActor in self.drop(token) }
        }
    }

    /// Removes `token` from the queue and refuses it, when it still waits.
    private func drop(_ token: UUID) {
        guard let at = queue.firstIndex(where: { $0.token == token }) else { return }
        queue.remove(at: at).resolve(false)
    }

    /// Hands the free semaphore to the oldest waiter.
    private func grantNext() {
        guard holder == nil, !queue.isEmpty else { return }
        let next = queue.removeFirst()
        acquire(next.token, next.label)
        next.resolve(true)
    }

    private func release(_ token: UUID) {
        guard let current = holder, current.token == token else { return }
        current.lease.cancel()
        holder = nil
        grantNext()
    }
}
