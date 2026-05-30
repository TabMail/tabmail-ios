/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Synchronization

/// Error thrown when an async operation exceeds its deadline.
struct TimeoutError: Error, CustomStringConvertible {
    let duration: TimeInterval
    var description: String { "Operation timed out after \(duration)s" }
}

/// Run `operation` with a hard timeout. If the operation doesn't complete
/// within `seconds`, the operation's Task is cancelled and `TimeoutError` is thrown.
///
/// Uses unstructured tasks so the caller is NOT blocked waiting for a stuck
/// operation to respond to cancellation (e.g., NIO TCP connect, raw continuations).
/// The cancelled operation task is abandoned — it will clean up when it eventually
/// finishes or when the process exits.
///
/// - Important: The operation should check `Task.isCancelled` or use
///   `try Task.checkCancellation()` at `await` points to respond to cancellation promptly.
func withTimeout<T: Sendable>(
    seconds: TimeInterval,
    operation: @Sendable @escaping () async throws -> T
) async throws -> T {
    let operationTask = Task { try await operation() }

    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
            // Single Mutex guards the continuation — first consumer (timer or result)
            // takes it; second one gets nil and is a no-op. Prevents double-resume.
            let state = Mutex<CheckedContinuation<T, any Error>?>(continuation)

            // Timeout timer
            Task { @Sendable in
                try? await Task.sleep(for: .seconds(seconds))
                if let cont = state.withLock({ c in let v = c; c = nil; return v }) {
                    operationTask.cancel()
                    cont.resume(throwing: TimeoutError(duration: seconds))
                }
            }

            // Operation result collector
            Task { @Sendable in
                do {
                    let result = try await operationTask.value
                    if let cont = state.withLock({ c in let v = c; c = nil; return v }) {
                        cont.resume(returning: result)
                    }
                } catch {
                    if let cont = state.withLock({ c in let v = c; c = nil; return v }) {
                        cont.resume(throwing: error)
                    }
                }
            }
        }
    } onCancel: {
        operationTask.cancel()
    }
}
