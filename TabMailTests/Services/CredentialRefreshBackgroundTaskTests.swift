/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import UIKit
import Synchronization
import Testing
@testable import TabMail

@MainActor
@Suite("Credential refresh execution lifetime")
struct CredentialRefreshBackgroundTaskTests {
    @MainActor
    final class Allowance {
        var mode = "success"
        var begins = 0
        var outstanding: [UIBackgroundTaskIdentifier] = []
        var ended: [UIBackgroundTaskIdentifier] = []
        var expiration: (@MainActor @Sendable () -> Void)?

        var platform: CredentialRefreshBackgroundTask.Platform {
            .init(begin: { expiration in
                self.begins += 1
                if self.mode == "denied" { return .invalid }
                let id = UIBackgroundTaskIdentifier(rawValue: self.begins)
                self.outstanding.append(id)
                self.expiration = expiration
                if self.mode == "early-expiry" { expiration() }
                return id
            }, end: { id in
                #expect(self.outstanding.contains(id), "An allowance must end exactly once")
                self.outstanding.removeAll { $0 == id }
                self.ended.append(id)
            })
        }
    }

    @Test("Every completion and admission outcome releases its allowance", arguments: ["success", "failure", "denied", "early-expiry"])
    func completion(mode: String) async throws {
        let allowance = Allowance()
        allowance.mode = mode
        let calls = Mutex(0)
        var succeeded = false
        do {
            try await CredentialRefreshBackgroundTask.$platform.withValue(allowance.platform) {
                try await CredentialRefreshBackgroundTask.run {
                    calls.withLock { $0 += 1 }
                    if mode == "failure" { throw URLError(.notConnectedToInternet) }
                }
            }
            succeeded = true
        } catch {}
        #expect(succeeded == (mode == "success"))
        #expect(calls.withLock { $0 } == (["success", "failure"].contains(mode) ? 1 : 0))
        #expect(allowance.begins == 1)
        #expect(allowance.outstanding.isEmpty)
        #expect(allowance.ended.count == (mode == "denied" ? 0 : 1))
        // A late or repeated expiration cannot end the completed allowance twice.
        allowance.expiration?()
        allowance.expiration?()
        #expect(allowance.ended.count == (mode == "denied" ? 0 : 1))
        try await assertNextAttemptWorks(allowance)
    }

    @Test("Expiration and caller cancellation stop a suspended operation's follow-up", arguments: ["expiration", "caller-cancellation"])
    func interrupted(reason: String) async throws {
        let allowance = Allowance()
        let started = CredentialTestLatch(), release = CredentialTestLatch()
        let forbidden = Mutex(0)
        let task = Task {
            try await CredentialRefreshBackgroundTask.$platform.withValue(allowance.platform) {
                try await CredentialRefreshBackgroundTask.run {
                    await started.signal()
                    await release.wait()
                    try Task.checkCancellation()
                    forbidden.withLock { $0 += 1 }
                }
            }
        }
        await started.wait()
        #expect(allowance.outstanding.count == 1)
        if reason == "expiration" {
            allowance.expiration?()
            #expect(allowance.outstanding.isEmpty)
            allowance.expiration?()
        } else { task.cancel() }
        await release.signal()
        switch await task.result {
        case .success: Issue.record("An interrupted operation reported success")
        case .failure(let error): #expect(error is CancellationError)
        }
        #expect(forbidden.withLock { $0 } == 0)
        #expect(allowance.outstanding.isEmpty)
        #expect(allowance.ended.count == 1)
        allowance.expiration?()
        #expect(allowance.ended.count == 1)
        try await assertNextAttemptWorks(allowance)
    }

    private func assertNextAttemptWorks(_ allowance: Allowance) async throws {
        allowance.mode = "success"
        let endedBefore = allowance.ended.count
        let result = try await CredentialRefreshBackgroundTask.$platform.withValue(allowance.platform) {
            try await CredentialRefreshBackgroundTask.run { "synthetic-next-operation" }
        }
        #expect(result == "synthetic-next-operation")
        #expect(allowance.outstanding.isEmpty)
        #expect(allowance.ended.count == endedBefore + 1)
    }
}
