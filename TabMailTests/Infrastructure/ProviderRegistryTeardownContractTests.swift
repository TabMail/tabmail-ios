/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Testing
@testable import TabMail

/// `IOS-TEST-008` — a scoped provider registration must leave the registry
/// SETTLED when it returns.
///
/// **The invariant is the end state of the registry at the scope boundary, not
/// the shape of the teardown statement.** `AccountManager` is an `actor`, so an
/// unregister launched from `defer { Task { … } }` is an actor job that is merely
/// ENQUEUED when the scope returns. The job then runs at the next suspension —
/// which is inside the NEXT test's very first `await` — and removes the provider
/// that test just registered and is about to read. The code under test sees
/// `providers[accountId] == nil`, silently early-returns at its provider guard
/// (whose only witness is a `DebugModeManager.isLoggingEnabled()`-gated print,
/// false under test), and the later leg reads as "the reaction did nothing" when
/// in truth it never started. Twelve sites across six suites had that shape and
/// now route through `TestProviderRegistry.withRegisteredProvider`.
///
/// A test that asserted "no `defer { Task {` appears in the corpus" would pin the
/// mechanism and stay green the first time someone writes the same defect a
/// different way (MIS-015). These assert the property instead: after the scope,
/// the registry holds nothing of that scope's, and nothing left over from it can
/// land on a later registration.
@Suite("Scoped provider registration leaves the registry settled", .serialized, .processGlobalState)
struct ProviderRegistryTeardownContractTests {

    private struct ScopeFailure: Error {}

    /// How many cooperative yields a stale teardown job gets to land. An actor
    /// job enqueued before these yields runs during them; the point of the loop
    /// is that with a correctly awaited teardown there is no such job at all.
    private static let yieldsForAStaleJobToLand = 200

    @Test("A normal-exit scope leaves nothing that can unregister a LATER scope's provider")
    func normalExitLeavesTheRegistrySettled() async throws {
        let accountId = "provider-teardown-normal-\(UUID().uuidString)"

        var sawItRegistered = false
        await TestProviderRegistry.withRegisteredProvider(
            accountId: accountId, provider: MockEmailProvider()
        ) {
            // NON-VACUITY: the scope really did register something, so the
            // absence asserted below is a teardown and not a no-op.
            sawItRegistered = await AccountManager.shared.providers[accountId] != nil
        }
        #expect(sawItRegistered, "fixture is vacuous — the scope never registered a provider at all")

        #expect(await AccountManager.shared.providers[accountId] == nil,
                "the scope returned with its provider still registered — the teardown was not applied")

        // THE PROPERTY THE LEAK ACTUALLY BREAKS: a later scope registers the same
        // account and then suspends, which is precisely where a merely-enqueued
        // teardown from the previous scope runs.
        let second = MockEmailProvider()
        await AccountManager.shared.registerProviderForTesting(accountId: accountId, provider: second)
        for _ in 0..<Self.yieldsForAStaleJobToLand { await Task.yield() }
        #expect(await AccountManager.shared.providers[accountId] != nil,
                """
                a teardown left over from an earlier scope unregistered THIS scope's provider — \
                the code under test would read nil and silently early-return at its provider \
                guard, and the test would report "it did nothing" for work that never started
                """)
        await AccountManager.shared.unregisterProviderForTesting(accountId: accountId)
    }

    @Test("A THROWING scope leaves nothing that can unregister a LATER scope's provider")
    func throwingExitLeavesTheRegistrySettled() async throws {
        let accountId = "provider-teardown-throwing-\(UUID().uuidString)"

        await #expect(throws: ScopeFailure.self) {
            try await TestProviderRegistry.withRegisteredProvider(
                accountId: accountId, provider: MockEmailProvider()
            ) {
                throw ScopeFailure()
            }
        }

        #expect(await AccountManager.shared.providers[accountId] == nil,
                "a thrown scope returned with its provider still registered — the error exit skipped the teardown")

        let second = MockEmailProvider()
        await AccountManager.shared.registerProviderForTesting(accountId: accountId, provider: second)
        for _ in 0..<Self.yieldsForAStaleJobToLand { await Task.yield() }
        #expect(await AccountManager.shared.providers[accountId] != nil,
                "a teardown left over from a THROWN earlier scope unregistered this scope's provider")
        await AccountManager.shared.unregisterProviderForTesting(accountId: accountId)
    }
}
