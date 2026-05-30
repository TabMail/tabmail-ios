/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

/// Regression guards for the email rendering pipeline that lives in
/// `EmailHTMLWrapper` and `AutoSizingHTMLView`. These are string-level
/// tests on the injected CSS / JS — they guard against someone silently
/// reverting a subtle fix that cost us multiple debug sessions to find.
///
/// Specifically:
///   - CSS overrides that defeat WKWebView feedback loops and WebKit bugs
///   - fitViewportJS widening policy (only-when-overflow, STANDARD_MIN floor,
///     `window.__tmLayoutVp` stamp to bypass WebKit bug 170595)
///   - monitorHeightJS push-based height pipeline
///     (ResizeObserver → heightChanged message with the right payload)
@Suite("Email render pipeline — CSS + JS regressions")
struct EmailRenderPipelineTests {

    // MARK: - wrapHTML CSS regressions

    @Test("Body has no horizontal or bottom padding (SwiftUI owns the gutters)")
    func bodyPaddingIsZero() {
        let out = EmailHTMLWrapper.wrapHTML("<p>X</p>")
        // Both horizontal and vertical gutters live in SwiftUI on
        // AutoSizingHTMLView. Padding in body CSS would be scaled by the
        // fitViewportJS widening ratio (12px → 8.6pt when widened to 400),
        // making the gap inconsistent across emails. Keep body at 0.
        #expect(out.contains("padding: 0;"))
        // Guard against the previous values: any padding with a bottom
        // component means the gutter regressed back into CSS.
        #expect(!out.contains("padding: 0 16px 12px"))
        #expect(!out.contains("padding: 0 0 12px"))
    }

    @Test("html and body are forced content-sized to defeat viewport-floor feedback")
    func htmlBodyHeightAuto() {
        let out = EmailHTMLWrapper.wrapHTML("<p>X</p>")
        // Without this override, WebKit's default html { height: 100% }
        // cascades into body { min-height: 100% } via email-authored CSS,
        // which makes documentElement.scrollHeight grow with the WKWebView
        // frame height — the classic feedback loop that also bleeds sub-
        // pixel scroll into the rendered view.
        #expect(out.contains("height: auto !important"))
        #expect(out.contains("min-height: 0 !important"))
        #expect(out.contains("max-height: none !important"))
    }

    @Test("html has overflow-x hidden (WebKit bug 153852 workaround)")
    func htmlOverflowXHidden() {
        let out = EmailHTMLWrapper.wrapHTML("<p>X</p>")
        // body { overflow-x: hidden } alone is ignored on iOS (WebKit bug
        // 153852). Applying it to html too kills the 1-pixel horizontal
        // scroll when a descendant (e.g. footer-wrapper w=289 in a 288
        // viewport) is slightly wider than body.
        #expect(out.contains("html { overflow-x: hidden !important"))
    }

    @Test("No max-width: 100vw CSS declaration on html or body (iOS viewport quirk)")
    func noMaxWidth100vw() {
        let out = EmailHTMLWrapper.wrapHTML("<p>X</p>")
        // `100vw` in iOS WebKit resolves to the VISUAL viewport (device
        // width), not the layout viewport the meta tag controls. Setting
        // `max-width: 100vw` on html/body silently undoes fitViewportJS's
        // widening. Guard against any variant of the actual CSS declaration.
        // (The warning comment inside EmailHTMLWrapper.swift itself contains
        // the string `max-width: 100vw`, so we can't just grep the output —
        // check for the declaration-shaped forms with `!important`.)
        #expect(!out.contains("max-width: 100vw !important"))
        #expect(!out.contains("max-width:100vw !important"))
        #expect(!out.contains("max-width: 100vw;"))
        #expect(!out.contains("max-width:100vw;"))
    }

    // MARK: - fitViewportJS regressions

    @Test("fitViewportJS widens only when content actually overflows")
    func fitViewportOnlyOnOverflow() {
        let js = _fitViewportJS
        // Plain-text and responsive emails that fit at device width must
        // keep the native 1.0× scale. The widening check is the guard —
        // if someone removes the `contentWidth <= vw` early return,
        // text-only emails render at 0.72× (16 px → 11.5 px visual).
        #expect(js.contains("if (contentWidth <= vw)"))
        #expect(js.contains("return false"))
    }

    @Test("fitViewportJS floors widening to STANDARD_MIN = 400")
    func fitViewportStandardMin() {
        let js = _fitViewportJS
        // When we DO widen, floor at 400 so slightly-overflowing emails
        // all render at a consistent 0.72× scale on a 288pt device
        // rather than drifting between 0.80× and 0.94× across emails.
        #expect(js.contains("STANDARD_MIN = 400"))
    }

    @Test("fitViewportJS caps widening at 1200 to avoid extreme shrink")
    func fitViewportCap() {
        let js = _fitViewportJS
        // Pathologically wide content (e.g. the ~800px spam-quarantine
        // table) is still capped so we don't render at 0.10× scale.
        #expect(js.contains("1200"))
    }

    @Test("fitViewportJS stamps window.__tmLayoutVp (WebKit bug 170595 workaround)")
    func fitViewportStampsGlobal() {
        let js = _fitViewportJS
        // `window.innerWidth` is unreliable in iOS WebKit after a runtime
        // viewport-meta change (WebKit bug 170595: innerWidth is bogus
        // after resize in WKWebView). We stash the authoritative widened
        // target in a global so monitorHeightJS can read it reliably.
        #expect(js.contains("window.__tmLayoutVp"))
    }

    @Test("fitViewportJS forces synchronous reflow after meta change")
    func fitViewportForcesReflow() {
        let js = _fitViewportJS
        // Reading `documentElement.offsetHeight` triggers a layout pass.
        // Without this, the first measurement after widening still sees
        // the pre-widening innerWidth, reporting a too-tall frame that
        // snaps smaller on the next pass — visible as a brief flicker.
        #expect(js.contains("document.documentElement.offsetHeight"))
    }

    // MARK: - monitorHeightJS regressions

    @Test("monitorHeightJS uses ResizeObserver as the primary trigger")
    func monitorUsesResizeObserver() {
        let js = _monitorHeightJS
        // ResizeObserver is the canonical push-based signal for "layout
        // changed". Fires once per genuine change (image decoded, font
        // loaded, CSS settled). Replacing this with polling or KVO
        // reintroduces all the problems we documented in previous
        // iterations.
        #expect(js.contains("new ResizeObserver"))
        #expect(js.contains(".observe(document.body)"))
    }

    @Test("monitorHeightJS has MutationObserver fallback for pre-iOS-13.4")
    func monitorHasFallback() {
        let js = _monitorHeightJS
        // ResizeObserver is iOS 13.4+. The fallback covers older
        // deployments; feature-detected at runtime.
        #expect(js.contains("if (window.ResizeObserver)"))
        #expect(js.contains("MutationObserver"))
    }

    @Test("monitorHeightJS reports both body.scrollHeight and bounding rect")
    func monitorPostsScrollAndRect() {
        let js = _monitorHeightJS
        // Reports both so we can detect cases where body.scrollHeight is
        // inflated by a `min-height: 100vh` cascade that survives our
        // override. When rect < scroll, rect is what the user actually
        // sees on screen; we prefer it.
        #expect(js.contains("document.body.scrollHeight"))
        #expect(js.contains("document.body.getBoundingClientRect"))
        // Payload has all four diagnostic fields.
        #expect(js.contains("h:"))
        #expect(js.contains("vp:"))
        #expect(js.contains("scroll:"))
        #expect(js.contains("rect:"))
    }

    @Test("monitorHeightJS reads window.__tmLayoutVp for scale conversion")
    func monitorReadsLayoutVpGlobal() {
        let js = _monitorHeightJS
        // Must read the global fitViewportJS stamps, falling back to
        // window.innerWidth only when we never widened. Bypasses WebKit
        // bug 170595 which left us with vp=288 post-widening, scaling
        // by 1.0× instead of 0.72× and overshooting the frame by ~30 %.
        #expect(js.contains("window.__tmLayoutVp"))
        #expect(js.contains("|| window.innerWidth"))
    }

    @Test("monitorHeightJS posts via heightChanged message handler")
    func monitorUsesMessageHandler() {
        let js = _monitorHeightJS
        #expect(js.contains("window.webkit.messageHandlers.heightChanged.postMessage"))
    }

    @Test("monitorHeightJS debounces identical heights")
    func monitorDebouncesSameHeight() {
        let js = _monitorHeightJS
        // Don't post if height didn't change — avoids churning the
        // SwiftUI binding for no-op ResizeObserver fires.
        #expect(js.contains("h !== lastH"))
    }

    // MARK: - Safety: no removed escape hatches

    @Test("No +24pt overshoot bandaid re-introduced in monitorHeightJS")
    func noOvershoot() {
        let js = _monitorHeightJS
        // Previous rev had `+ 24` as a hack to compensate for WebKit's
        // scrollView.contentSize vs body.scrollHeight gap. That gap is
        // now handled structurally by preferring bodyRect over scroll
        // when they differ. A `+ 24` or similar literal shouldn't come
        // back unless someone justifies it in the regression case.
        #expect(!js.contains("+ 24"))
    }

    @Test("No polling-based measurement in monitorHeightJS")
    func noPolling() {
        let js = _monitorHeightJS
        // We do NOT want to re-introduce the didFinish+0.3s+0.8s triple
        // polling or any setInterval-based pulling. The push architecture
        // is the whole point of ResizeObserver. The only setTimeout that
        // should remain is the initial "fire report() shortly after load"
        // belt-and-suspenders. Forbid periodic polling intervals.
        #expect(!js.contains("setInterval"))
    }
}
