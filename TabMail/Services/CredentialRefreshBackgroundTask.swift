/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import UIKit
import Synchronization

/// Acquire execution time before a refresh can take a shared storage lock.
/// The extension already runs within its notification execution allowance.
enum CredentialRefreshBackgroundTask {
    struct Platform: Sendable {
        var begin: @MainActor @Sendable (@escaping @MainActor @Sendable () -> Void) -> UIBackgroundTaskIdentifier = {
            UIApplication.shared.beginBackgroundTask(withName: "credential-refresh", expirationHandler: $0)
        }
        var end: @MainActor @Sendable (UIBackgroundTaskIdentifier) -> Void = {
            UIApplication.shared.endBackgroundTask($0)
        }
    }
    @TaskLocal static var platform = Platform()

    private struct State {
        var expired = false
        var identifier: UIBackgroundTaskIdentifier = .invalid
        var cancel: (@Sendable () -> Void)?
    }

    static func run<T: Sendable>(
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let platform = Self.platform
        let state = Mutex(State())
        let identifier = await MainActor.run {
            platform.begin {
                let (cancel, toEnd) = state.withLock { value in
                    value.expired = true
                    let identifier = value.identifier
                    value.identifier = .invalid
                    return (value.cancel, identifier)
                }
                cancel?()
                if toEnd != .invalid {
                    platform.end(toEnd)
                }
            }
        }
        guard identifier != .invalid else { throw CredentialRefreshError.unavailable }
        let alreadyExpired = state.withLock { value in
            guard !value.expired else { return true }
            value.identifier = identifier
            return false
        }
        if alreadyExpired {
            await MainActor.run { platform.end(identifier) }
            throw CancellationError()
        }
        let task = Task {
            try Task.checkCancellation()
            return try await operation()
        }
        let expired = state.withLock { value in
            value.cancel = { task.cancel() }
            return value.expired
        }
        if expired { task.cancel() }
        let result = await withTaskCancellationHandler {
            await task.result
        } onCancel: {
            task.cancel()
        }
        let toEnd = state.withLock { value in
            let identifier = value.identifier
            value.identifier = .invalid
            value.cancel = nil
            return identifier
        }
        if toEnd != .invalid {
            await MainActor.run { platform.end(toEnd) }
        }
        return try result.get()
    }
}
