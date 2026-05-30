/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

/// Tests for the deferred-add state machine that connects the merged
/// OAuth in `TabMailLoginView` to the consent gate in
/// `RootView.routedContent`. The behaviour we want to lock in:
///
/// * `PendingAccountAdd.shared.pending` starts `nil`.
/// * Setting / clearing flips it. `RootView` shows the gate while
///   non-nil and falls through to `AddAccountGeneralView` once cleared.
/// * `Pending` is `Equatable` so SwiftUI `.task(id:)` and
///   `onChange(of:)` can diff cleanly.
/// * The three providers are distinct values (no accidental aliasing
///   between gmail / outlook / icloud).
@MainActor
@Suite("PendingAccountAdd state")
struct PendingAccountAddTests {

    // Each test resets the singleton so order doesn't matter. The
    // singleton is `@MainActor` so all tests in this suite run on
    // MainActor (note the suite-level annotation above).
    private func resetPending() {
        PendingAccountAdd.shared.clear()
    }

    @Test("Singleton starts cleared after `clear()`")
    func startsCleared() {
        resetPending()
        #expect(PendingAccountAdd.shared.pending == nil)
    }

    @Test("Setting then clearing returns to nil")
    func setAndClear() {
        resetPending()
        PendingAccountAdd.shared.pending = .init(provider: .gmail, email: "test@gmail.com")
        #expect(PendingAccountAdd.shared.pending != nil)
        #expect(PendingAccountAdd.shared.pending?.email == "test@gmail.com")
        #expect(PendingAccountAdd.shared.pending?.provider == .gmail)

        PendingAccountAdd.shared.clear()
        #expect(PendingAccountAdd.shared.pending == nil)
    }

    @Test("Replacing pending overwrites the previous value")
    func replacingPending() {
        resetPending()
        PendingAccountAdd.shared.pending = .init(provider: .gmail, email: "first@gmail.com")
        PendingAccountAdd.shared.pending = .init(provider: .outlook, email: "second@outlook.com")
        #expect(PendingAccountAdd.shared.pending?.provider == .outlook)
        #expect(PendingAccountAdd.shared.pending?.email == "second@outlook.com")
    }

    @Test("Three provider cases are distinct (no aliasing)")
    func providerCasesAreDistinct() {
        let g = PendingAccountAdd.Pending(provider: .gmail, email: "x@example.com")
        let o = PendingAccountAdd.Pending(provider: .outlook, email: "x@example.com")
        let i = PendingAccountAdd.Pending(provider: .icloud, email: "x@example.com")
        #expect(g != o)
        #expect(o != i)
        #expect(g != i)
    }

    @Test("Same provider + same email is Equatable-equal")
    func equatableSameValues() {
        let a = PendingAccountAdd.Pending(provider: .gmail, email: "kw@example.com")
        let b = PendingAccountAdd.Pending(provider: .gmail, email: "kw@example.com")
        #expect(a == b)
    }

    @Test("Same provider, different email → not equal")
    func equatableDifferentEmail() {
        let a = PendingAccountAdd.Pending(provider: .gmail, email: "one@example.com")
        let b = PendingAccountAdd.Pending(provider: .gmail, email: "two@example.com")
        #expect(a != b)
    }

    // MARK: - Bug-fix regression coverage
    //
    // The behaviour we explicitly do NOT want: `PendingAccountAdd`
    // being silently cleared by a failed Connect. The cleanup
    // contract documented in `RootView.commitGmailOutlookAdd` is:
    // success clears, every other path leaves it set so the gate
    // stays visible. These tests don't drive `RootView` directly
    // (it would need DI for OAuth + AccountManager), but they pin
    // the *invariant* — `clear()` is the only way to nil out
    // pending, so anywhere we find a stray `clear()` in error paths
    // it becomes obvious in code review.

    @Test("`clear()` is idempotent — calling it twice doesn't crash")
    func clearIsIdempotent() {
        resetPending()
        PendingAccountAdd.shared.clear()
        PendingAccountAdd.shared.clear()
        #expect(PendingAccountAdd.shared.pending == nil)
    }

    @Test("Clear after set leaves the singleton ready for reuse")
    func reuseAfterClear() {
        resetPending()
        PendingAccountAdd.shared.pending = .init(provider: .icloud, email: "user@icloud.com")
        PendingAccountAdd.shared.clear()
        // Subsequent set should still work — verifies the singleton
        // doesn't latch into an unusable state.
        PendingAccountAdd.shared.pending = .init(provider: .gmail, email: "next@gmail.com")
        #expect(PendingAccountAdd.shared.pending?.provider == .gmail)
    }
}
