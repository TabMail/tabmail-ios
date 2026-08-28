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
/// token — a per-token, therefore per-subject, hazard. Sharing across subjects
/// returns `.success(A_accessToken)` to B, so B makes backend requests as A and
/// a `/whoami` fetched that way describes A while carrying B's epoch. This is
/// the same harm class as the session-slot clobber.
@Suite("TabMailTokenCoordinator refresh-join ownership")
struct TokenCoordinatorRefreshJoinTests {
    @Test("Same subject → JOIN (deduplication is preserved where it is actually needed)")
    func sameSubjectJoins() {
        #expect(TabMailTokenCoordinator.canJoinInFlightRefresh(
            inFlightUserId: "user-A",
            requestingUserId: "user-A"
        ))
    }

    @Test("Different subject → REFUSE to join (never hand B a bearer minted for A)")
    func differentSubjectRefusesToJoin() {
        #expect(!TabMailTokenCoordinator.canJoinInFlightRefresh(
            inFlightUserId: "user-A",
            requestingUserId: "user-B"
        ))
    }

    @Test("Untagged in-flight refresh → REFUSE to join (an unprovable owner is not a matching owner)")
    func untaggedRefreshRefusesToJoin() {
        #expect(!TabMailTokenCoordinator.canJoinInFlightRefresh(
            inFlightUserId: nil,
            requestingUserId: "user-A"
        ))
    }

    /// Refusing to join is ALWAYS auth-safe, which is why this guard cannot
    /// break login: the refusing caller simply starts its own refresh with its
    /// own refresh token. Two subjects necessarily hold two different refresh
    /// tokens — each is read from that subject's own session blob — so
    /// declining to share cannot produce the Supabase rotation conflict the
    /// dedup exists to prevent. Within one subject, joining still happens.
    @Test("The join decision depends ONLY on subject identity, never on token values")
    func joinDecisionIsPurelyAboutIdentity() {
        // Same subject joins regardless of how different the rest of the
        // session looks; a different subject never joins even if everything
        // else about the request is identical.
        #expect(TabMailTokenCoordinator.canJoinInFlightRefresh(
            inFlightUserId: "shared-subject",
            requestingUserId: "shared-subject"
        ))
        #expect(!TabMailTokenCoordinator.canJoinInFlightRefresh(
            inFlightUserId: "shared-subject",
            requestingUserId: "shared-subject-2"
        ))
    }
}
