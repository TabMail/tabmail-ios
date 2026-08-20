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

// MARK: - Clobber guard (auth-safe session persistence)

/// The invariant these pin — NOT the fix's mechanism: **a refreshed token is
/// persisted to the shared `"tabmail_session"` slot whenever the slot is
/// empty, unreadable, or still owned by the same user, and is withheld ONLY
/// when a demonstrably-different valid user now owns the slot.** The first
/// half is the auth-safety guarantee (a transient/ambiguous read must never
/// log the user out); the second half is the clobber closure (one account's
/// refresh must never overwrite another account's active session).
///
/// A sign-out cleanup can drive `performRefresh` in an unstructured task that
/// `signOut()`'s `flush.cancel()` cannot cancel, so the refreshed session can
/// land after the slot has changed owner — which, before this guard, let A's
/// session clobber an active B (B then operating under A's identity).
@Suite("TabMailTokenCoordinator clobber-guard")
struct TokenCoordinatorClobberGuardTests {

    /// Encoded-session bytes in the exact shape `TabMailSession.encode(to:)`
    /// writes (so `shouldPersistRefreshedSession`'s decode round-trips).
    private func sessionData(
        userId: String,
        accessToken: String = "acc",
        refreshToken: String = "ref",
        expiresAt: Int = 9_999_999_999
    ) -> Data {
        let json = """
        {"access_token":"\(accessToken)","refresh_token":"\(refreshToken)",\
        "expires_at":\(expiresAt),"user":{"id":"\(userId)","email":"user@example.com"}}
        """
        return Data(json.utf8)
    }

    // MARK: #1 — auth-safety / non-vacuity (the overriding priority)
    //
    // These are GREEN on pre-guard code (which always saves); their value is
    // that they go RED under a mis-implemented skip-on-absence guard, catching
    // an auth-breaking regression. See the red-evidence note in the plan.

    @Test("Same user owns the slot → SAVE (ordinary refresh persists)")
    func sameUserSaves() {
        #expect(TabMailTokenCoordinator.shouldPersistRefreshedSession(
            currentSlot: sessionData(userId: "user-A"), newUserId: "user-A") == true)
    }

    @Test("Empty slot → SAVE (never infer sign-out from a missing read)")
    func emptySlotSaves() {
        #expect(TabMailTokenCoordinator.shouldPersistRefreshedSession(
            currentSlot: nil, newUserId: "user-A") == true)
    }

    @Test("Unreadable slot → SAVE (never infer sign-out from an undecodable read)")
    func unreadableSlotSaves() {
        // Not JSON at all.
        #expect(TabMailTokenCoordinator.shouldPersistRefreshedSession(
            currentSlot: Data("not-json".utf8), newUserId: "user-A") == true)
        // Valid JSON, but not a decodable TabMailSession.
        #expect(TabMailTokenCoordinator.shouldPersistRefreshedSession(
            currentSlot: Data(#"{"unrelated":"value"}"#.utf8), newUserId: "user-A") == true)
    }

    // MARK: #2 — clobber closed (red-first; pre-guard always saves ⇒ clobbers)

    @Test("A different, valid user owns the slot → SKIP (clobber withheld)")
    func differentUserSkips() {
        #expect(TabMailTokenCoordinator.shouldPersistRefreshedSession(
            currentSlot: sessionData(userId: "user-B"), newUserId: "user-A") == false)
    }

    // MARK: #3 — same-user reordering (no identity confusion either way)

    @Test("Same user, different token/expiry in the slot → SAVE (same identity)")
    func sameUserDifferentTokenSaves() {
        // The guard keys on identity, not freshness: A refreshing over A's own
        // (differently-tokened) slot is never a clobber, so it saves.
        #expect(TabMailTokenCoordinator.shouldPersistRefreshedSession(
            currentSlot: sessionData(userId: "user-A", accessToken: "newer", expiresAt: 1_111_111_111),
            newUserId: "user-A") == true)
    }

    // MARK: #4 — atomicity: the decision keys off the FRESH read at write time
    //
    // Structural guarantee: `persistRefreshedSession` runs on the MainActor and
    // is synchronous, and every writer of the slot is also MainActor-isolated,
    // so no sign-in write interleaves the read→write. These tests prove the
    // substance of that — the compare uses the slot state AT PERSIST TIME, not
    // a value captured when the refresh began.

    @MainActor
    @Test("B signing in between refresh-start and persist is NOT clobbered (fresh re-read)")
    func persistReReadsFreshSlotNoClobber() {
        // A owned the slot when A's refresh began, but B has since signed in.
        var slot: Data? = sessionData(userId: "user-B")
        var saved: [Data] = []
        TabMailTokenCoordinator.persistRefreshedSession(
            encoded: sessionData(userId: "user-A"),
            newUserId: "user-A",
            loadCurrent: { slot },
            save: { saved.append($0); slot = $0 }
        )
        #expect(saved.isEmpty) // A's refresh withheld — B intact
        #expect(TabMailTokenCoordinator.shouldPersistRefreshedSession(
            currentSlot: slot, newUserId: "user-B") == true)
    }

    @MainActor
    @Test("Same user at write time → the legitimate save is not lost")
    func persistWritesForSameUser() {
        var slot: Data? = sessionData(userId: "user-A")
        var saved: [Data] = []
        let refreshed = sessionData(userId: "user-A", accessToken: "refreshed")
        TabMailTokenCoordinator.persistRefreshedSession(
            encoded: refreshed,
            newUserId: "user-A",
            loadCurrent: { slot },
            save: { saved.append($0); slot = $0 }
        )
        #expect(saved == [refreshed])
    }

    @MainActor
    @Test("Emptied slot at write time → SAVE (resurrection is the gen-bump's job, not the guard's; auth-safe)")
    func persistWritesIntoEmptySlot() {
        var slot: Data? = nil // signed out between refresh-start and persist
        var saved: [Data] = []
        let refreshed = sessionData(userId: "user-A")
        TabMailTokenCoordinator.persistRefreshedSession(
            encoded: refreshed,
            newUserId: "user-A",
            loadCurrent: { slot },
            save: { saved.append($0); slot = $0 }
        )
        // The guard deliberately does NOT block resurrection into an empty
        // slot (that would risk an auth-breaking skip); the sign-in gen-bump
        // closes the paywall consequence instead.
        #expect(saved == [refreshed])
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
