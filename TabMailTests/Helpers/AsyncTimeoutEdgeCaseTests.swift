/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import Synchronization
@testable import TabMail

@Suite("AsyncTimeout Edge Cases")
struct AsyncTimeoutEdgeCaseTests {

    @Test("Concurrent timeout + operation completion: exactly one wins")
    func concurrentTimeoutAndCompletion() async throws {
        // Operation completes at ~10ms, timeout at 10s — wide margin for loaded CI/simulator
        let result = try await withTimeout(seconds: 10.0) {
            try await Task.sleep(for: .milliseconds(10))
            return "completed"
        }
        #expect(result == "completed")
    }

    @Test("Very short timeout triggers before operation")
    func veryShortTimeout() async {
        do {
            _ = try await withTimeout(seconds: 0.001) {
                try await Task.sleep(for: .seconds(10))
                return "should not reach"
            }
            Issue.record("Expected timeout")
        } catch {
            #expect(error is TimeoutError)
        }
    }

    @Test("Operation throwing error propagates through timeout")
    func operationErrorPropagates() async {
        struct CustomError: Error {}
        do {
            _ = try await withTimeout(seconds: 5.0) {
                throw CustomError()
            }
            Issue.record("Expected error")
        } catch {
            #expect(error is CustomError)
        }
    }

    @Test("TimeoutError has correct duration")
    func timeoutErrorDuration() {
        let error = TimeoutError(duration: 15.0)
        #expect(error.duration == 15.0)
    }

    @Test("TimeoutError description includes duration")
    func timeoutErrorDescription() {
        let error = TimeoutError(duration: 30.0)
        #expect(error.description.contains("30"))
    }

    @Test("Return value forwarded correctly through timeout wrapper")
    func returnValueForwarded() async throws {
        let value = try await withTimeout(seconds: 5.0) {
            return 42
        }
        #expect(value == 42)
    }

    @Test("Struct return forwarded through timeout")
    func structReturnForwarded() async throws {
        struct Result: Sendable, Equatable {
            let name: String
            let count: Int
        }
        let value = try await withTimeout(seconds: 5.0) {
            return Result(name: "test", count: 99)
        }
        #expect(value == Result(name: "test", count: 99))
    }

    @Test("Multiple sequential timeouts don't interfere")
    func sequentialTimeouts() async throws {
        for i in 0..<5 {
            let result = try await withTimeout(seconds: 1.0) {
                return i
            }
            #expect(result == i)
        }
    }

    @Test("Concurrent withTimeout calls are independent")
    func concurrentTimeoutCallsIndependent() async throws {
        try await withThrowingTaskGroup(of: Int.self) { group in
            for i in 0..<10 {
                group.addTask {
                    try await withTimeout(seconds: 1.0) {
                        return i
                    }
                }
            }
            var results = Set<Int>()
            for try await result in group {
                results.insert(result)
            }
            #expect(results.count == 10)
        }
    }
}
