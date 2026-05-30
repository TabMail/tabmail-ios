/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
import Synchronization
@testable import TabMail

@Suite("retryWrite")
struct RetryWriteTests {

    /// Creates a file-based DatabasePool for retryWrite testing.
    /// DatabasePool requires WAL mode which doesn't work with :memory:.
    private static func makePool() throws -> DatabasePool {
        let dir = NSTemporaryDirectory() + "retrywrite_\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = dir + "/test.sqlite"
        return try DatabasePool(path: path, configuration: {
            var config = Configuration()
            config.foreignKeysEnabled = true
            return config
        }())
    }

    @Test("Succeeds on first attempt")
    func successFirstAttempt() async throws {
        let db = try Self.makePool()
        let callCount = Mutex(0)
        let result = try await retryWrite(db, maxAttempts: 3, retryDelay: .milliseconds(10), label: "test") { db in
            callCount.withLock { $0 += 1 }
            return 42
        }
        #expect(result == 42)
        #expect(callCount.withLock { $0 } == 1)
    }

    @Test("Retries on transient failure then succeeds")
    func retryThenSucceed() async throws {
        let db = try Self.makePool()
        let callCount = Mutex(0)
        let result = try await retryWrite(db, maxAttempts: 3, retryDelay: .milliseconds(10), label: "test") { db in
            let count = callCount.withLock { $0 += 1; return $0 }
            if count < 3 {
                throw TestError.transient
            }
            return "done"
        }
        #expect(result == "done")
        #expect(callCount.withLock { $0 } == 3)
    }

    @Test("Throws after exhausting all attempts")
    func exhaustRetries() async {
        do {
            let db = try Self.makePool()
            _ = try await retryWrite(db, maxAttempts: 2, retryDelay: .milliseconds(10), label: "test") { _ -> Int in
                throw TestError.transient
            }
            Issue.record("Expected error to be thrown")
        } catch {
            // Expected
        }
    }

    @Test("Passes Database handle to operation")
    func passesDatabase() async throws {
        let db = try Self.makePool()
        try await retryWrite(db, maxAttempts: 1, retryDelay: .milliseconds(10), label: "test") { db in
            try db.execute(sql: "SELECT 1")
        }
    }

    @Test("Respects maxAttempts = 1 (no retry)")
    func singleAttemptNoRetry() async {
        do {
            let db = try Self.makePool()
            _ = try await retryWrite(db, maxAttempts: 1, retryDelay: .milliseconds(10), label: "test") { _ -> Int in
                throw TestError.transient
            }
            Issue.record("Expected error to be thrown")
        } catch {
            // Should fail after 1 attempt
        }
    }
}

private enum TestError: Error {
    case transient
}
