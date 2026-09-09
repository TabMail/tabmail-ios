/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

// MARK: - TabMailTokenCoordinator.RefreshResult

@Suite("TabMailTokenCoordinator.RefreshResult")
struct RefreshResultTests {

    @Test("success carries access token string")
    func successCarriesToken() {
        let result = TabMailTokenCoordinator.RefreshResult.success("test_token_abc")
        if case .success(let token) = result {
            #expect(token == "test_token_abc")
        } else {
            #expect(Bool(false), "Expected success case")
        }
    }

    @Test("success with empty token")
    func successEmptyToken() {
        let result = TabMailTokenCoordinator.RefreshResult.success("")
        if case .success(let token) = result {
            #expect(token == "")
        } else {
            #expect(Bool(false), "Expected success case")
        }
    }

    @Test("permanentFailure is a distinct case")
    func permanentFailure() {
        let result = TabMailTokenCoordinator.RefreshResult.permanentFailure
        if case .permanentFailure = result {
            // pass
        } else {
            #expect(Bool(false), "Expected permanentFailure case")
        }
    }

    @Test("transientFailure is a distinct case")
    func transientFailure() {
        let result = TabMailTokenCoordinator.RefreshResult.transientFailure
        if case .transientFailure = result {
            // pass
        } else {
            #expect(Bool(false), "Expected transientFailure case")
        }
    }

    @Test("noSession is a distinct case")
    func noSession() {
        let result = TabMailTokenCoordinator.RefreshResult.noSession
        if case .noSession = result {
            // pass
        } else {
            #expect(Bool(false), "Expected noSession case")
        }
    }

    @Test("All four cases are distinguishable")
    func allCasesDistinguishable() {
        let cases: [TabMailTokenCoordinator.RefreshResult] = [
            .success("tok"),
            .permanentFailure,
            .transientFailure,
            .noSession,
        ]

        // Each case should match only itself
        for (i, result) in cases.enumerated() {
            switch result {
            case .success:
                #expect(i == 0)
            case .permanentFailure:
                #expect(i == 1)
            case .transientFailure:
                #expect(i == 2)
            case .noSession:
                #expect(i == 3)
            }
        }
    }

    @Test("RefreshResult conforms to Sendable")
    func sendableConformance() {
        // This test verifies at compile time that RefreshResult is Sendable.
        // If it weren't, this would fail to compile in strict concurrency mode.
        let result: any Sendable = TabMailTokenCoordinator.RefreshResult.success("token")
        _ = result
    }

    @Test("success preserves long token strings")
    func longToken() {
        let longToken = String(repeating: "a", count: 2048)
        let result = TabMailTokenCoordinator.RefreshResult.success(longToken)
        if case .success(let token) = result {
            #expect(token.count == 2048)
            #expect(token == longToken)
        } else {
            #expect(Bool(false), "Expected success case")
        }
    }
}

/// Refresh deduplication must never hand one user another user's bearer.
///
/// `validToken`/`forceRefresh` used to await ANY in-flight refresh task. The
/// dedup exists only to stop two callers burning the same rotated refresh
/// token — a per-token, therefore per-generation, hazard. Sharing across generations
/// returns `.success(A_accessToken)` to B, so B makes backend requests as A and
/// a `/whoami` fetched that way describes A while carrying B's epoch. This is
/// the same harm class as the session-slot clobber.
@Suite("TabMailTokenCoordinator refresh-join ownership")
struct TokenCoordinatorRefreshJoinTests {
    @Test("Same generation → JOIN (deduplication is preserved where it is actually needed)")
    func sameGenerationJoins() {
        #expect(TabMailTokenCoordinator.canJoinInFlightRefresh(
            inFlightGeneration: "generation-A",
            requestingGeneration: "generation-A"
        ))
    }

    @Test("Different generation → REFUSE to join (never hand B a bearer minted for A)")
    func differentGenerationRefusesToJoin() {
        #expect(!TabMailTokenCoordinator.canJoinInFlightRefresh(
            inFlightGeneration: "generation-A",
            requestingGeneration: "generation-B"
        ))
    }

    @Test("Untagged in-flight refresh → REFUSE to join (an unprovable owner is not a matching owner)")
    func untaggedRefreshRefusesToJoin() {
        #expect(!TabMailTokenCoordinator.canJoinInFlightRefresh(
            inFlightGeneration: nil,
            requestingGeneration: "generation-A"
        ))
    }

    /// Refusing to join is ALWAYS auth-safe, which is why this guard cannot
    /// break login: the refusing caller simply starts its own refresh with its
    /// own refresh token. Two generations necessarily hold two different refresh
    /// tokens — each is read from that generation's own session blob — so
    /// declining to share cannot produce the Supabase rotation conflict the
    /// dedup exists to prevent. Within one generation, joining still happens.
    @Test("The join decision depends ONLY on generation identity, never on token values")
    func joinDecisionIsPurelyAboutIdentity() {
        // Same generation joins regardless of how different the rest of the
        // session looks; a different generation never joins even if everything
        // else about the request is identical.
        #expect(TabMailTokenCoordinator.canJoinInFlightRefresh(
            inFlightGeneration: "shared-generation",
            requestingGeneration: "shared-generation"
        ))
        #expect(!TabMailTokenCoordinator.canJoinInFlightRefresh(
            inFlightGeneration: "shared-generation",
            requestingGeneration: "shared-generation-2"
        ))
    }
}
