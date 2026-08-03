/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

/// T4.V17 — the reveal flag is SEEDED at construction; it is not reset from
/// `.task(id:)`.
///
/// `.task(id:)` re-runs on every RECREATION of a view (SwiftUI `List` row
/// recycling), not only when its id changes. A one-shot reset placed there
/// therefore wipes the seeded state one frame after `init` and re-flashes the
/// "Loading message…" placeholder every time a row scrolls back into view — the
/// exact symptom the seeding exists to prevent. The reset lives in
/// `.onChange(of: html)`, which fires only on a real content change.
///
/// These tests pin the SEEDING DECISION — the value `init` feeds to
/// `_hasRevealed` — because a `@State` initial value is not observable from
/// outside a SwiftUI render pass. `AutoSizingHTMLView.initialHasRevealed` is the
/// expression `init` uses, so asserting on it asserts on production behaviour.
@Suite("AutoSizingHTMLView reveal seeding (T4.V17)")
struct AutoSizingHTMLViewRevealSeedingTests {

    /// Unique per call so process-global `HeightSeedCache` state cannot leak
    /// between tests or between suites running concurrently.
    private func freshHeaderId() -> String { "v17-\(UUID().uuidString)" }

    @Test("A recycled row whose message already rendered does not re-show the loading placeholder")
    func recycledRowStaysRevealed() {
        let headerId = freshHeaderId()

        // Nothing has rendered this message yet — a genuinely new row.
        #expect(AutoSizingHTMLView.initialHasRevealed(headerId: headerId) == false)

        // The fit pipeline applies a measurement. This is the ONLY writer of the
        // seed cache, and it runs after JS `reveal()` has already fired for this
        // exact content — so a seed means "this message rendered successfully".
        HeightSeedCache.shared[headerId] = 412

        // The List dismantled the row and recreated it on scroll-back: a brand
        // new view value with brand new @State, for the same message.
        #expect(
            AutoSizingHTMLView.initialHasRevealed(headerId: headerId),
            "a recycled row must start revealed — otherwise it re-flashes the placeholder"
        )
        #expect(AutoSizingHTMLView.seededHeight(headerId: headerId) == 412)
    }

    @Test("A genuinely new row with no prior render still shows the loading placeholder")
    func newRowShowsPlaceholder() {
        let headerId = freshHeaderId()

        #expect(AutoSizingHTMLView.seededHeight(headerId: headerId) == nil)
        #expect(
            AutoSizingHTMLView.initialHasRevealed(headerId: headerId) == false,
            "without a prior successful render the placeholder must still appear"
        )
    }

    @Test("A preview with no headerId never seeds a revealed state")
    func nilHeaderIdNeverSeeds() {
        // Compose preview / .eml preview / tooltip mocks pass headerId == nil and
        // are excluded from the placeholder path entirely.
        #expect(AutoSizingHTMLView.seededHeight(headerId: nil) == nil)
        #expect(AutoSizingHTMLView.initialHasRevealed(headerId: nil) == false)
    }
}
