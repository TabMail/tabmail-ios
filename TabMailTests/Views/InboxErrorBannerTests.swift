/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
@testable import TabMail

/// **A debug unlock must never decide whether the user is TOLD that something
/// failed.**
///
/// ## The defect this pins
///
/// `InboxView`'s error banner read
/// `if let error = viewModel.error, DebugModeManager.isLoggingEnabled()`. The gate
/// sat in the BRANCH CONDITION, so it suppressed no log — it decided whether the
/// banner was constructed at all. `InboxView` is the ONLY render site of
/// `InboxViewModel.error` in `TabMail/Views/` (the two `MessageCardView` hits
/// belong to `MessageDetailViewModel`), so **in a production build the banner was
/// unreachable**. `InboxViewModel` writes that property at exactly two sites — the
/// infinite-scroll catch (`"Failed to load older messages: …"`) and the
/// `performSync` catch — and both are genuine user-facing failures. A user whose
/// pagination failed watched the list stop growing with no explanation.
///
/// ## Why the invariant is stated as an INDEPENDENCE, not as a list of cases
///
/// `bannerPresenceIsIndependentOfTheDebugFlag` is the load-bearing test. Asserting
/// "with logging off, a non-nil error yields a banner" pins one instance; asserting
/// that PRESENCE is the same function of `error` under both flag values pins the
/// property, so any future re-gating **of `InboxErrorBanner.text(for:loggingEnabled:)`**
/// fails regardless of which direction it is written in (`MIS-015` — pin the
/// invariant, never the fix's mechanism).
///
/// > ⚠️ **The qualifier above is load-bearing, and without it this doc claimed reach
/// > the suite does not have** (`MIS-019` — an absolute owes its negative case).
/// > Every test here exercises the PURE function; **none constructs `InboxView`**.
/// > So the last hop — from the function's return value to the view actually
/// > rendering it — is covered by no test, and re-adding
/// > `, DebugModeManager.isLoggingEnabled()` to the view's `if` restores the exact
/// > original defect with all five tests GREEN. That is the same shape as the defect
/// > this file was written to close, which is why it is stated rather than assumed
/// > away. Closing it needs a ViewInspector-style render assertion or a snapshot
/// > test; the repo has neither, and adding that harness for one banner is
/// > machinery `A3`/`MIS-003` forbids. **The guard is therefore this sentence plus
/// > the topic-105 §4 note, not a test** — if you re-gate the view, nothing will
/// > catch you. Found by the final-train Claude audit half, 2026-08-05.
///
/// ## Non-vacuity is two-sided, and it was measured, not reasoned
///
/// Under the sanctioned inversion (restoring the pre-fix
/// `guard let error, loggingEnabled else { return nil }` inside
/// `InboxErrorBanner.text(for:loggingEnabled:)`) three cases go RED and
/// `debugBuildsStillShowTheRawDetail` + `noErrorMeansNoBannerUnderEitherFlag` stay
/// GREEN. The green half matters: a test already red after the fix is red under
/// every inversion and proves nothing.
///
/// ## A1
///
/// Shipped `07a4bb703` and `v2final` `e28dd4edb` carry the SAME gated line, so this
/// is authored work rather than a v3 regression — but the SHAPE is restored from
/// `MessageCardView.bodyContent`, which is byte-identical across both of those tags
/// and HEAD and already solves this correctly: ungated branch, debug-gated detail.
@Suite("Inbox error banner — a debug unlock never decides whether the user is told")
struct InboxErrorBannerTests {

    /// Representative of the real payload: `InboxViewModel` stores
    /// `error.localizedDescription`, which is developer text.
    private static let rawDeveloperText =
        "Failed to load older messages: The operation couldn't be completed. (NIOCore.IOError error 1.)"

    /// **THE INVARIANT.** Whether the banner appears is a function of `error`
    /// ALONE. Any re-gating changes one side and fails here.
    @Test("banner PRESENCE is independent of the debug flag")
    func bannerPresenceIsIndependentOfTheDebugFlag() {
        let cases: [String?] = [
            nil,
            "",
            "boom",
            Self.rawDeveloperText,
            "Failed to load older messages: connection reset"
        ]
        for error in cases {
            let shownWithLogging = InboxErrorBanner.text(for: error, loggingEnabled: true) != nil
            let shownWithout = InboxErrorBanner.text(for: error, loggingEnabled: false) != nil
            #expect(
                shownWithLogging == shownWithout,
                "the debug flag changed whether the banner appears for \(String(describing: error))"
            )
        }
    }

    /// The production build is the one that matters: locked logging is what every
    /// real user runs.
    @Test("a non-nil error is surfaced when logging is DISABLED")
    func nonNilErrorIsSurfacedWithLoggingDisabled() {
        #expect(InboxErrorBanner.text(for: Self.rawDeveloperText, loggingEnabled: false) != nil)
    }

    /// The detail half of the shape: the user gets copy, not a domain/errno dump.
    @Test("production copy is generic, never the raw localizedDescription")
    func productionCopyIsGenericNotRaw() {
        let shown = InboxErrorBanner.text(for: Self.rawDeveloperText, loggingEnabled: false)
        #expect(shown == InboxErrorBanner.genericMessage)
        #expect(shown != Self.rawDeveloperText)
    }

    /// Non-vacuity anchor — stays GREEN under the inversion. The gate still does
    /// its real job: diagnostics remain available to a debug build.
    @Test("debug builds still show the raw detail")
    func debugBuildsStillShowTheRawDetail() {
        #expect(InboxErrorBanner.text(for: Self.rawDeveloperText, loggingEnabled: true)
                == Self.rawDeveloperText)
    }

    /// Non-vacuity anchor — stays GREEN under the inversion. A presence rule driven
    /// by `error` alone must also be able to say NO, or the first test passes
    /// trivially by always showing a banner.
    @Test("no error means no banner under either flag")
    func noErrorMeansNoBannerUnderEitherFlag() {
        #expect(InboxErrorBanner.text(for: nil, loggingEnabled: true) == nil)
        #expect(InboxErrorBanner.text(for: nil, loggingEnabled: false) == nil)
    }
}
