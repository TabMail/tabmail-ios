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
    private static func makePool() throws -> (pool: DatabasePool, directory: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("retrywrite_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let pool = try DatabasePool(path: directory.appendingPathComponent("test.sqlite").path, configuration: {
            var config = Configuration()
            config.foreignKeysEnabled = true
            return config
        }())
        return (pool, directory)
    }

    @Test("Succeeds on first attempt")
    func successFirstAttempt() async throws {
        let (pool, directory) = try Self.makePool()
        defer { TestDatabaseTeardown.retire(pool: pool, directory: directory) }
        let db = PrioritizedDatabase(pool: pool)
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
        let (pool, directory) = try Self.makePool()
        defer { TestDatabaseTeardown.retire(pool: pool, directory: directory) }
        let db = PrioritizedDatabase(pool: pool)
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
            let (pool, directory) = try Self.makePool()
            defer { TestDatabaseTeardown.retire(pool: pool, directory: directory) }
            let db = PrioritizedDatabase(pool: pool)
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
        let (pool, directory) = try Self.makePool()
        defer { TestDatabaseTeardown.retire(pool: pool, directory: directory) }
        let db = PrioritizedDatabase(pool: pool)
        try await retryWrite(db, maxAttempts: 1, retryDelay: .milliseconds(10), label: "test") { db in
            try db.execute(sql: "SELECT 1")
        }
    }

    @Test("Respects maxAttempts = 1 (no retry)")
    func singleAttemptNoRetry() async {
        do {
            let (pool, directory) = try Self.makePool()
            defer { TestDatabaseTeardown.retire(pool: pool, directory: directory) }
            let db = PrioritizedDatabase(pool: pool)
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
