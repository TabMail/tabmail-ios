/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// Why the prompt store refused a call (DS-SEMAPHORE, DS-COUNTER).
enum PromptRefusal: Error, Equatable, Sendable {
    /// Another caller held the semaphore through every retry, or the call was made inside a hold (DS-NESTED).
    case busy
    /// An AI writer's counter moved since it read (DS-AI), or its hold ran past its lease (DS-LEASE).
    case changed
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
/// a task-local marks the holding task); a waiting caller retries a capped number of times. Sign-in
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
        /// DS-SEMAPHORE: retries after the first busy refusal. The waits double from `retryBaseDelayMs`,
        /// each plus up to `retryJitterMs` at random, so with the standard values a caller gives up as
        /// busy within about 6.7 s (200 + 400 + 800 + 1600 + 3200 ms, plus up to 5 x 100 ms).
        var retries: Int
        var retryBaseDelayMs: Int
        var retryJitterMs: Int

        static let standard = Config(leaseSeconds: 15, retries: 5, retryBaseDelayMs: 200, retryJitterMs: 100)
    }

    /// DS-NESTED: the holding task's hold, so a nested call is refused instead of waiting on itself.
    @TaskLocal static var holding: UUID?

    var config: Config

    /// DS-COUNTER: an opaque value renewed on every commit that saved a change (an edit, a refine, a
    /// merge or legacy import that changed a field, a reset, every accepted restore). Its only users
    /// are AI writers (DS-AI). Sign-in, sign-out, an upgrade's save and lease expiry do not renew it.
    private(set) var counter = UUID()

    private var holder: (token: UUID, label: String, lease: Task<Void, Never>)?

    init(config: Config = .standard) {
        self.config = config
    }

    /// Runs `body` holding the semaphore, waiting for it with capped backoff while another caller holds
    /// it, and releasing it on every exit.
    func hold<T>(_ label: String, _ body: (PromptHold) async throws -> T) async throws -> T {
        if let outer = Self.holding {
            BackgroundSyncLogger.logDebug("[PromptStore] \(label) refused: called inside the hold \(outer.uuidString.prefix(8))")
            throw PromptRefusal.busy
        }
        var retry = 0
        while let current = holder {
            guard retry < config.retries else {
                BackgroundSyncLogger.logDebug("[PromptStore] \(label) refused: \(current.label) held the prompt store through every retry")
                throw PromptRefusal.busy
            }
            let wait = (config.retryBaseDelayMs << retry) + Int.random(in: 0...max(0, config.retryJitterMs))
            retry += 1
            try? await Task.sleep(for: .milliseconds(wait))
        }
        let token = UUID()
        let lease = Task { [weak self, leaseSeconds = config.leaseSeconds] in
            try? await Task.sleep(for: .seconds(leaseSeconds))
            guard !Task.isCancelled, let self, self.holder?.token == token else { return }
            BackgroundSyncLogger.logDebug("[PromptStore] \(label) ran past its lease: it lost the prompt store")
            self.holder = nil
        }
        holder = (token, label, lease)
        defer { release(token) }
        return try await Self.$holding.withValue(token) { try await body(PromptHold(token: token, semaphore: self)) }
    }

    /// Whether `token` still holds the semaphore (not released, not past its lease).
    func holds(_ token: UUID) -> Bool {
        holder?.token == token
    }

    /// DS-COUNTER: a commit saved a change; a write that read the previous value is refused.
    func renewCounter() {
        counter = UUID()
    }

    private func release(_ token: UUID) {
        guard let current = holder, current.token == token else { return }
        current.lease.cancel()
        holder = nil
    }
}
