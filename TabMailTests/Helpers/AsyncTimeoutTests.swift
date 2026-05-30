/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

@Suite("AsyncTimeout")
struct AsyncTimeoutTests {

    // MARK: - TimeoutError

    @Test("TimeoutError description includes duration")
    func errorDescription() {
        let err = TimeoutError(duration: 3.5)
        #expect(err.description.contains("3.5"))
    }

    @Test("TimeoutError description includes 'timed out'")
    func errorDescriptionContainsTimedOut() {
        let err = TimeoutError(duration: 10.0)
        #expect(err.description.lowercased().contains("timed out"))
    }

    @Test("TimeoutError stores duration correctly")
    func errorStoresDuration() {
        let err = TimeoutError(duration: 42.0)
        #expect(err.duration == 42.0)
    }

    @Test("TimeoutError conforms to Error")
    func errorConformsToError() {
        let err: any Error = TimeoutError(duration: 1.0)
        #expect(err is TimeoutError)
    }

    @Test("TimeoutError with fractional seconds")
    func errorFractionalSeconds() {
        let err = TimeoutError(duration: 0.001)
        #expect(err.description.contains("0.001"))
    }

    // MARK: - withTimeout success

    @Test("Operation completes before timeout returns value")
    func completesBeforeTimeout() async throws {
        let result = try await withTimeout(seconds: 10.0) {
            try await Task.sleep(for: .milliseconds(10))
            return 42
        }
        #expect(result == 42)
    }

    @Test("String return value forwarded correctly")
    func stringReturnForwarded() async throws {
        let result = try await withTimeout(seconds: 1.0) {
            return "hello"
        }
        #expect(result == "hello")
    }

    @Test("Struct return forwarded through timeout")
    func structReturnForwarded() async throws {
        struct Payload: Sendable, Equatable {
            let name: String
            let count: Int
        }
        let value = try await withTimeout(seconds: 5.0) {
            return Payload(name: "test", count: 99)
        }
        #expect(value == Payload(name: "test", count: 99))
    }

    // MARK: - withTimeout failure

    @Test("Operation exceeding timeout throws TimeoutError")
    func exceedsTimeout() async {
        do {
            _ = try await withTimeout(seconds: 0.05) {
                try await Task.sleep(for: .seconds(10))
                return "never"
            }
            Issue.record("Expected TimeoutError")
        } catch {
            #expect(error is TimeoutError)
            let te = error as! TimeoutError
            #expect(te.duration == 0.05)
        }
    }

    @Test("Operation error propagated, not masked by timeout")
    func operationErrorPropagated() async {
        struct CustomError: Error {}
        do {
            _ = try await withTimeout(seconds: 5.0) {
                throw CustomError()
            }
            Issue.record("Expected CustomError")
        } catch {
            #expect(error is CustomError)
        }
    }

    @Test("Timeout with zero seconds throws TimeoutError")
    func zeroTimeout() async {
        do {
            _ = try await withTimeout(seconds: 0) {
                try await Task.sleep(for: .seconds(1))
                return "late"
            }
            Issue.record("Expected TimeoutError")
        } catch {
            #expect(error is TimeoutError)
        }
    }

    @Test("Very short timeout triggers before slow operation")
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

    // MARK: - Concurrency

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
    func concurrentCalls() async throws {
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
