/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import SwiftUI
import WebKit
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
///
/// `.processGlobalState`: the test makes its own window key and restores the
/// previous key window on exit, as the other key-window suites do, so it must not
/// interleave with them.
@Suite("AutoSizingHTMLView reveal seeding (T4.V17)", .serialized, .processGlobalState)
struct AutoSizingHTMLViewRevealSeedingTests {

    @MainActor
    @Test("The native reveal consumer keeps an uncommitted message loading")
    func nativeRevealWaitsForCommit() async {
        var revealed = false
        let driver = AutoSizingHTMLView.makeRevealTestDriver(
            hasRevealed: Binding(get: { revealed }, set: { revealed = $0 })
        )
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first else {
            Issue.record("no UIWindowScene is available to host the reveal driver")
            return
        }
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        let controller = UIViewController()
        window.rootViewController = controller
        controller.view.addSubview(driver.webView)
        window.makeKeyAndVisible()
        defer {
            driver.webView.stopLoading()
            driver.webView.removeFromSuperview()
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKeyAndVisible()
        }
        #expect(driver.webView.bounds.width > 0)
        #expect(!driver.committed())
        driver.acknowledge()
        #expect(!revealed, "the binding driving the loading placeholder must remain false")
        driver.load()
        driver.acknowledge()
        #expect(!revealed, "queued wrapping is not a committed document")
        let deadline = ProcessInfo.processInfo.systemUptime + 15
        while !driver.committed() && ProcessInfo.processInfo.systemUptime < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        #expect(driver.committed(), "the real WebKit navigation must commit")
        guard driver.committed() else { return }
        driver.acknowledge()
        #expect(revealed, "committed content must dismiss the loading placeholder")
        driver.acknowledge()
        #expect(revealed)
    }

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
