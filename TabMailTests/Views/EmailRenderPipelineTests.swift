/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import Synchronization
import JavaScriptCore
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

    @Test("html clips overflow-x with `clip` (153852 workaround, no scroll-container promotion)")
    func htmlOverflowXClip() {
        let out = EmailHTMLWrapper.wrapHTML("<p>X</p>")
        // Applying overflow-x to html too kills the 1-pixel horizontal scroll
        // when a descendant (e.g. footer-wrapper w=289 in a 288 viewport) is
        // slightly wider than body (body's overflow alone is ignored on iOS —
        // WebKit bug 153852). MUST be `clip`, NOT `hidden`: a scrolling value
        // (hidden/scroll/auto) on one axis promotes the visible other axis to
        // `auto` (CSS Overflow L3), turning html/body into Y-scroll containers
        // that hold a stray body.scrollTop after a late image-swap reflow (the
        // "inner content scrolls, not the page" bug). `clip` is not a scrolling
        // value, so it clips X without that promotion.
        #expect(out.contains("html { overflow-x: clip !important"))
        #expect(!out.contains("html { overflow-x: hidden !important"))
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

    @Test("fitViewportJS widens only when content overflows beyond the slop")
    func fitViewportOnlyOnOverflow() {
        let js = _fitViewportJS
        // Plain-text and responsive emails that fit at device width must keep
        // the native 1.0x scale. The guard is the early return; if someone
        // removes it, text-only emails render at 0.72x (16px -> 11.5px).
        #expect(js.contains("if (maxRight <= vw + OVERFLOW_SLOP)"))
        #expect(js.contains("return false"))
    }

    @Test("fitViewportJS ignores sub-pixel overflow (OVERFLOW_SLOP)")
    func fitViewportSubPixelSlop() {
        let js = _fitViewportJS
        // WebKit reports fractional layout widths (e.g. a column at 288.2 in a
        // 288 viewport). `Math.ceil` turned that into 289 > 288 -> a FALSE
        // overflow that floored to STANDARD_MIN (400) and shrank a fitting
        // 107KB newsletter to 0.72x on a second fit. A few-px slop absorbs the
        // jitter (and stops the widen loop creeping ~1px/pass on width:100%
        // content). Genuine desktop emails overflow far past the slop.
        #expect(js.contains("OVERFLOW_SLOP = 8"))
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

    @Test("img height:auto is scoped to images with an explicit width attribute")
    func imgHeightAutoScopedToWidthAttr() {
        let out = EmailHTMLWrapper.wrapHTML("<p>X</p>")
        // The bug: `img { max-width: 100%; height: auto; }` overrode the
        // `height="29"` presentational attribute on the Apple Support survey's
        // logo (which has NO width attr), so the logo lost its height cap and
        // ballooned to the container's full width (~29px logo rendered ~420px),
        // overflowing 288pt → fitViewport widened the whole email → right edge
        // clipped. Apple Mail / Thunderbird keep the logo small by honoring the
        // height attribute. Fix: cap all images with max-width:100% but force
        // height:auto ONLY for images that carry an explicit width attribute
        // (where capping the width must scale height to avoid distortion).
        #expect(out.contains("img { max-width: 100%; }"))
        #expect(out.contains("img[width] { height: auto; }"))
        // The unscoped form that stripped width-less images' height must be gone.
        #expect(!out.contains("img { max-width: 100%; height: auto; }"))
    }

    @Test("fitViewportJS re-measures and widens again after a breakpoint flip")
    func fitViewportIterativeWiden() {
        let js = _fitViewportJS
        // Widening the layout viewport can cross the email's own
        // `@media (max-width:N)` breakpoint and reveal a WIDER layout (fixed-px
        // buttons, no-wrap rows) than the width we just set — a single
        // measure-then-widen clips the right edge ("still cut on the right a
        // bit", Apple survey: 288→420 crosses its max-width:415 query). The
        // widen loop must re-measure after a forced reflow and widen again,
        // bounded by a pass cap and the 1200px ceiling.
        #expect(js.contains("function measureMaxRight()"))
        #expect(js.contains("MAX_PASSES"))
        // Re-measures INSIDE the widen loop, not just once before widening.
        #expect(js.contains("re = measureMaxRight()"))
    }

    @Test("fitViewportJS widen loop terminates — bounded, monotonic, capped")
    func fitViewportWidenTerminates() {
        let js = _fitViewportJS
        // The widen loop must not be able to run away (this view has a history
        // of width/height feedback loops — ADR-IOS-039). Three independent
        // stops, verified structurally:
        //  (1) hard pass cap,
        //  (2) monotonic non-decreasing target with a no-progress break,
        //  (3) absolute 1200px ceiling with an explicit break.
        #expect(js.contains("pass < MAX_PASSES"))                       // (1) bounded
        #expect(js.contains("if (want <= targetWidth + OVERFLOW_SLOP)")) // (2) no-progress break
        #expect(js.contains("targetWidth = want"))                      // (2) only grows
        #expect(js.contains("if (targetWidth >= 1200)"))                // (3) ceiling break
    }

    // MARK: - monitorHeightJS regressions

    @Test("monitorHeightJS requests an early fit on first layout (not blocked on didFinish)")
    func monitorRequestsEarlyFit() {
        let js = _monitorHeightJS
        // A big newsletter's body lays out (~100ms) long before didFinish, which
        // waits on external images (~500ms+). Leaving the frame at 1px (gated)
        // until didFinish-driven fit() is the "still slow" blank. Instead,
        // report() asks Swift to fit on the FIRST real layout so the frame is
        // sized + revealed as soon as the width is known. Once only.
        #expect(js.contains("requestFit: true"))
        #expect(js.contains("__tmFitRequested"))
        #expect(js.contains("document.body.scrollHeight > 1"))
    }

    @Test("monitorHeightJS gates the first height post until fit() runs (no load flicker)")
    func monitorGatesUntilFit() {
        let js = _monitorHeightJS
        // Before fit() decides whether to widen, body is laid out at the
        // un-widened device width; posting that height applies a too-tall frame
        // that snaps smaller once fit() widens — the 1→881→466 load flicker.
        // report() must suppress HEIGHT posts until fit() opens the __tmFitDone
        // gate (the early-fit request is the only thing that goes out before it).
        #expect(js.contains("if (!window.__tmFitDone) {"))
        // Liveness fallback so a fit() that never runs can't strand the frame
        // at its seed height. Must be a one-shot timeout, never a polling loop.
        #expect(js.contains("window.__tmFitDone = true"))
        #expect(!js.contains("setInterval"))
    }

    @Test("fitViewportJS opens the __tmFitDone gate on every exit and re-reports")
    func fitOpensGate() {
        let js = _fitViewportJS
        // fit() must set the gate (so suppressed reports can flow) and trigger a
        // fresh report so the FINAL height applies immediately rather than
        // waiting on monitorHeightJS's settling timers.
        #expect(js.contains("window.__tmFitDone = true"))
        #expect(js.contains("window.__tmReportHeight()"))
    }

    // MARK: - Anti-blink: never show the un-scaled paint

    @Test("EmailHTMLWrapper strips render-blocking external stylesheet links")
    func wrapperStripsExternalStylesheets() {
        // WebKit blocks first paint until external stylesheets load; a slow
        // Google Fonts <link> left a 107KB newsletter an empty box for ~2.6s
        // (first compositor frame didn't fire until readyState=complete). These
        // are web-font imports — drop them so the email paints immediately with
        // fallback fonts. Also a privacy win (external CSS = remote tracking).
        let gfont = "<link href=\"https://fonts.googleapis.com/css2?family=Playfair+Display&display=swap\" rel=\"stylesheet\" type=\"text/css\">"
        let out = EmailHTMLWrapper.wrapHTML("<html><head>\(gfont)</head><body><p>Hi</p></body></html>")
        #expect(!out.contains("fonts.googleapis.com"))
        #expect(!out.contains("rel=\"stylesheet\""))
        // Inline <style> must be preserved (only external <link> is stripped).
        let withStyle = EmailHTMLWrapper.wrapHTML("<html><head><style>p{color:red}</style>\(gfont)</head><body><p>Hi</p></body></html>")
        #expect(withStyle.contains("color:red"))
        #expect(!withStyle.contains("fonts.googleapis.com"))
    }

    @Test("EmailHTMLWrapper defers remote <img> src so they don't block first paint")
    func wrapperDefersRemoteImages() {
        // WebKit holds the first paint until readyState=complete, which waits on
        // every pending remote image; the Vancouver Sun newsletter's 28 remote
        // images blocked paint for ~2.7s. Rewriting remote src → data-tmsrc means
        // the initial document has no pending image loads → instant paint; the real
        // URLs are auto-swapped back after first paint (deferredImageLoadJS).
        let html = "<html><body><img src=\"https://cdn.example.com/banner.png\" width=\"600\"><p>Hi</p></body></html>"
        let out = EmailHTMLWrapper.wrapHTML(html)
        #expect(out.contains("data-tmsrc=\"https://cdn.example.com/banner.png\""))
        // Leading space: the original ` src="…"` must be gone. (Can't check
        // `src="…"` without the space — `data-tmsrc="…"` contains that substring.)
        #expect(!out.contains(" src=\"https://cdn.example.com/banner.png\""))
        // Auto-load approach — NO blocking banner (smoke-tested block-with-banner
        // broke too many messages, 2026-06-17).
        #expect(!out.contains("tm-remote-banner"))
    }

    @Test("EmailHTMLWrapper leaves local/cid/data images alone (only remote deferred)")
    func wrapperKeepsLocalImages() {
        // cid:, data:, and local scheme-handler images are fast and load-bearing.
        let html = "<html><body><img src=\"cid:logo123\"><img src=\"data:image/png;base64,AAAA\"></body></html>"
        let out = EmailHTMLWrapper.wrapHTML(html)
        #expect(out.contains("src=\"cid:logo123\""))
        #expect(out.contains("src=\"data:image/png;base64,AAAA\""))
        #expect(!out.contains("data-tmsrc"))
    }

    @Test("deferredImageLoadJS auto-swaps data-tmsrc back to src after first paint")
    func deferredImageSwapScript() {
        let js = _deferredImageLoadJS
        // Restores the real URL automatically, only AFTER a paint cycle (double
        // rAF) so the remote loads can't re-block the first paint. Failsafe timeout.
        #expect(js.contains("img[data-tmsrc]"))
        #expect(js.contains("setAttribute('src'"))
        #expect(js.contains("requestAnimationFrame(function() { requestAnimationFrame(swap)"))
        #expect(js.contains("setTimeout(swap, 1500)"))
    }

    @Test("EmailHTMLWrapper starts the document hidden (opacity:0)")
    func wrapperStartsHidden() {
        let out = EmailHTMLWrapper.wrapHTML("<p>X</p>")
        // WebKit paints a runtime viewport-meta widen at scale 1.0 for ~one
        // frame before committing the shrink — showing that un-scaled frame is
        // the "blink". The document must start invisible and be revealed only
        // after the scale commits (fitViewportJS.reveal()).
        #expect(out.contains("html { overflow-x: clip !important; opacity: 0;"))
    }

    @Test("fitViewportJS reveals only AFTER a paint cycle (no empty-box, no un-scaled blink)")
    func fitRevealsPostCommit() {
        let js = _fitViewportJS
        // reveal() flips opacity to 1 (inline+important beats the stylesheet).
        #expect(js.contains("function reveal()"))
        #expect(js.contains("setProperty('opacity', '1', 'important')"))
        // revealAfterPaint defers the un-hide past WebKit's next compositor frame
        // via a DOUBLE requestAnimationFrame. This serves both arms: the widen
        // path's async page-scale commit (never show un-scaled), AND a big doc
        // revealed early via requestFit whose visible content hasn't painted yet
        // (never show an empty box). A single rAF can land mid-commit; two can't.
        #expect(js.contains("function revealAfterPaint()"))
        #expect(js.contains("requestAnimationFrame(function() { requestAnimationFrame(reveal)"))
        // Both the no-overflow and widen exits must use the paint-deferred reveal.
        // (Two call sites; reveal() also called directly on the idempotent/skip exits.)
        #expect(js.components(separatedBy: "revealAfterPaint();").count - 1 >= 2)
    }

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

    // MARK: - fitViewportJS idempotency (width-arm feedback loop)

    @Test("fitViewportJS bails when __tmLayoutVp is already set (idempotent re-entry)")
    func fitViewportIdempotentReEntry() {
        let js = _fitViewportJS
        // fitViewportJS measures the document and then MUTATES it (meta
        // widen, inline width strips). Re-running it on an already-widened
        // document re-measures widened CSS px against an unreliable
        // innerWidth (WebKit bug 170595) — the width-arm feedback loop:
        // fonts shrank a little more on every background→foreground cycle
        // because the foreground observer re-runs fit(). Re-entry on a
        // widened document must be a no-op; real width changes go through
        // viewportResetJS which clears the global first.
        #expect(js.contains("if (window.__tmLayoutVp)"))
    }

    @Test("fitViewportJS measures against the Swift-stamped device width")
    func fitViewportUsesStampedWidth() {
        let js = _fitViewportJS
        // fit() stamps window.__tmDeviceWidth from webView.bounds.width
        // immediately before running the script. At the device-width
        // baseline 1 CSS px == 1 pt, so that IS the layout viewport —
        // window.innerWidth is only a fallback (bug 170595 makes it
        // untrustworthy after meta/bounds changes).
        #expect(js.contains("window.__tmDeviceWidth || window.innerWidth"))
    }

    @Test("monitorHeightJS prefers stamped device width over innerWidth for vp")
    func monitorHeightVpFallbackChain() {
        let js = _monitorHeightJS
        // Fallback chain: widened layout viewport (authoritative after a
        // widen) → Swift-stamped device width (authoritative baseline) →
        // innerWidth (only before the first fit() has stamped anything).
        #expect(js.contains("window.__tmLayoutVp || window.__tmDeviceWidth || window.innerWidth"))
    }

    @Test("viewportResetJS clears the layout-vp stamp so the next fit re-derives")
    func viewportResetClearsStamp() {
        let js = viewportResetJS(deviceWidth: 393)
        // Without clearing __tmLayoutVp, fitViewportJS's idempotency guard
        // would treat the post-width-change re-fit as a re-entry and bail,
        // and monitorHeightJS would keep scaling against the stale widened
        // viewport.
        #expect(js.contains("window.__tmLayoutVp = 0"))
        #expect(js.contains("window.__tmDeviceWidth = 393"))
        #expect(js.contains("width=device-width"))
        #expect(js.contains("initial-scale=1"))
    }
}

// MARK: - ScrollFreezeGate

/// `.serialized`: `end()` posts the global `.scrollFreezeReleased`
/// notification, so two tests of this suite running in parallel would bump
/// each other's observer counters.
@Suite("ScrollFreezeGate", .serialized)
struct ScrollFreezeGateTests {

    @Test("begin/end transitions are idempotent")
    func transitions() {
        let gate = ScrollFreezeGate()
        #expect(!gate.isFrozen)
        gate.begin()
        #expect(gate.isFrozen)
        gate.begin() // double-begin stays frozen
        #expect(gate.isFrozen)
        gate.end()
        #expect(!gate.isFrozen)
        gate.end() // double-end stays released
        #expect(!gate.isFrozen)
    }

    @Test("end posts scrollFreezeReleased exactly once per freeze")
    func releaseNotification() {
        let gate = ScrollFreezeGate()
        let count = Mutex(0)
        let obs = NotificationCenter.default.addObserver(
            forName: .scrollFreezeReleased, object: nil, queue: nil
        ) { _ in
            count.withLock { $0 += 1 }
        }
        defer { NotificationCenter.default.removeObserver(obs) }

        gate.end() // not frozen — must not post
        #expect(count.withLock { $0 } == 0)
        gate.begin()
        gate.end()
        #expect(count.withLock { $0 } == 1)
        gate.end() // already released — no double post
        #expect(count.withLock { $0 } == 1)
    }
}

// MARK: - HeightSeedCache

@Suite("HeightSeedCache")
struct HeightSeedCacheTests {

    @Test("miss returns nil, set/get round-trips, overwrite wins")
    func basicSemantics() {
        let cache = HeightSeedCache()
        #expect(cache["acct:INBOX:1"] == nil)
        cache["acct:INBOX:1"] = 444
        #expect(cache["acct:INBOX:1"] == 444)
        cache["acct:INBOX:1"] = 1084 // re-measure after content change wins
        #expect(cache["acct:INBOX:1"] == 1084)
        #expect(cache["acct:INBOX:2"] == nil) // no cross-key bleed
    }

    @Test("overflow backstop clears rather than growing unbounded")
    func overflowBackstop() {
        let cache = HeightSeedCache()
        // Push well past the cap. The exact eviction shape (clear-all) is an
        // implementation detail; the contract is (a) no unbounded growth and
        // (b) the most recent write is always retrievable — losing older
        // seeds merely restores pre-cache behavior for those rows.
        for i in 0..<1500 {
            cache["msg:\(i)"] = CGFloat(i)
        }
        #expect(cache["msg:1499"] == 1499)
    }
}

// MARK: - PreviewFreezeGate

/// `.serialized`: `end()` posts the global `.previewFreezeReleased`
/// notification, so two tests of this suite running in parallel would bump
/// each other's observer counters. `@MainActor` because `PreviewFreezeGate`
/// is main-actor isolated.
@Suite("PreviewFreezeGate", .serialized)
@MainActor
struct PreviewFreezeGateTests {

    @Test("begin/end transitions are idempotent")
    func transitions() {
        let gate = PreviewFreezeGate()
        #expect(!gate.isFrozen)
        gate.begin()
        #expect(gate.isFrozen)
        gate.begin() // double-begin stays frozen
        #expect(gate.isFrozen)
        gate.end()
        #expect(!gate.isFrozen)
        gate.end() // double-end stays released
        #expect(!gate.isFrozen)
    }

    @Test("end posts previewFreezeReleased exactly once per freeze")
    func releaseNotification() {
        let gate = PreviewFreezeGate()
        let count = Mutex(0)
        let obs = NotificationCenter.default.addObserver(
            forName: .previewFreezeReleased, object: nil, queue: nil
        ) { _ in
            count.withLock { $0 += 1 }
        }
        defer { NotificationCenter.default.removeObserver(obs) }

        gate.end() // not frozen — must not post
        #expect(count.withLock { $0 } == 0)
        gate.begin()
        gate.end()
        #expect(count.withLock { $0 } == 1)
        gate.end() // already released — no double post
        #expect(count.withLock { $0 } == 1)
    }
}

// MARK: - PreviewGatedReload (MessageCardView label buffer/flush)

/// Covers the exact regression risks introduced by the preview-blink fix:
/// (1) a normal (unfrozen) `.inboxDataDidChange` still triggers a label reload,
/// (2) a reload arriving mid-preview is suppressed, and (3) a burst of
/// suppressed reloads replays as exactly one refresh when the preview dismisses.
@Suite("PreviewGatedReload — label reload buffer/flush")
struct PreviewGatedReloadTests {

    @Test("unfrozen request reloads immediately and buffers nothing")
    func unfrozenReloadsNow() {
        var gate = PreviewGatedReload()
        #expect(gate.request(isFrozen: false) == true)   // reload runs now
        #expect(gate.isPending == false)
        #expect(gate.release() == false)                 // nothing to flush
    }

    @Test("frozen request buffers instead of reloading")
    func frozenBuffers() {
        var gate = PreviewGatedReload()
        #expect(gate.request(isFrozen: true) == false)   // suppressed
        #expect(gate.isPending == true)
    }

    @Test("a burst of frozen requests flushes exactly once on release")
    func burstCoalescesToOneFlush() {
        var gate = PreviewGatedReload()
        #expect(gate.request(isFrozen: true) == false)
        #expect(gate.request(isFrozen: true) == false)
        #expect(gate.request(isFrozen: true) == false)
        #expect(gate.isPending == true)
        #expect(gate.release() == true)                  // one flush
        #expect(gate.isPending == false)
        #expect(gate.release() == false)                 // no second flush
    }

    @Test("release with no buffered request is a no-op")
    func releaseWithoutPendingIsNoOp() {
        var gate = PreviewGatedReload()
        #expect(gate.release() == false)
    }

    @Test("after a flush, a fresh unfrozen request reloads normally")
    func resumesNormalReloadAfterFlush() {
        var gate = PreviewGatedReload()
        _ = gate.request(isFrozen: true)
        _ = gate.release()
        #expect(gate.request(isFrozen: false) == true)   // back to normal
        #expect(gate.isPending == false)
    }
}

/// Gated post-load image aspect-ratio correction (`tmFixImgAspect`).
///
/// Exercises the SHARED `fixImgAspectFnJS` source from AutoSizingHTMLView.swift
/// in a JSContext with synthetic `img` mocks — the same zero-drift pattern as
/// the `walkUpToWrapStart` tests. `tmFixImgAspect` only reads naturalWidth /
/// naturalHeight / getBoundingClientRect and writes `style.height`, so a plain
/// object stands in for the DOM node (no polyfill).
///
/// The safety-critical property under test: the gate fires ONLY when the
/// rendered ratio diverges from the natural ratio, and the fix touches ONLY
/// height — so a proportional logo is never ballooned (which would feed a
/// bogus fitViewport widen) and the document's horizontal extent is untouched.
@Suite("Image aspect-ratio correction — tmFixImgAspect gate")
struct ImageAspectRatioFixTests {

    /// Fresh JSContext with the shared fn + a mock-img factory that records
    /// whether `height` was set (and at what priority).
    private func makeContext() -> JSContext {
        let ctx = JSContext()!
        ctx.evaluateScript(fixImgAspectFnJS)
        ctx.evaluateScript("""
        function mkImg(nw, nh, rw, rh, attrW, attrH) {
            return {
                naturalWidth: nw, naturalHeight: nh,
                src: '', currentSrc: '',
                getBoundingClientRect: function() { return { width: rw, height: rh }; },
                getAttribute: function(k) {
                    if (k === 'width') return (attrW == null ? null : String(attrW));
                    if (k === 'height') return (attrH == null ? null : String(attrH));
                    return null;
                },
                style: {
                    _h: null, _prio: null,
                    setProperty: function(k, v, p) { if (k === 'height') { this._h = v; this._prio = p; } }
                }
            };
        }
        """)
        return ctx
    }

    @Test("corrects a distorted full-width image (width capped, height pinned)")
    func correctsDistorted() {
        let ctx = makeContext()
        // natural 1200x600 (2:1); rendered 390x300 (1.3:1) — width capped to the
        // card, height stuck at the authored value → vertical stretch.
        ctx.evaluateScript("var img = mkImg(1200, 600, 390, 300); var res = tmFixImgAspect(img);")
        #expect(ctx.evaluateScript("res")?.toBool() == true)
        #expect(ctx.evaluateScript("img.style._h")?.toString() == "auto")
        #expect(ctx.evaluateScript("img.style._prio")?.toString() == "important")
        #expect(ctx.evaluateScript("img.__tmAspectFixed")?.toBool() == true)
    }

    @Test("leaves a proportional height-only logo untouched (no balloon)")
    func leavesLogoUntouched() {
        let ctx = makeContext()
        // Apple-survey-style logo: natural 200x174, rendered 33x29 — already at
        // its true ratio (just small). Must NOT get height:auto, or it would
        // balloon to the container width and drive a bogus fitViewport widen.
        ctx.evaluateScript("var img = mkImg(200, 174, 33, 29); var res = tmFixImgAspect(img);")
        #expect(ctx.evaluateScript("res")?.toBool() == false)
        #expect(ctx.evaluateScript("img.style._h == null")?.toBool() == true)
    }

    @Test("leaves an already-proportional full-width image untouched")
    func leavesProportionalUntouched() {
        let ctx = makeContext()
        // natural 1200x600, rendered 390x195 — correct 2:1 (e.g. an image that
        // carried both width+height attrs, already handled by img[width] CSS).
        ctx.evaluateScript("var img = mkImg(1200, 600, 390, 195); var res = tmFixImgAspect(img);")
        #expect(ctx.evaluateScript("res")?.toBool() == false)
        #expect(ctx.evaluateScript("img.style._h == null")?.toBool() == true)
    }

    @Test("no-ops when the image is not loaded yet (naturalWidth 0)")
    func noOpWhenUnloaded() {
        let ctx = makeContext()
        // A deferred remote img before its bytes arrive: 0 natural size → skip,
        // so we never write a bogus height before the real ratio is known.
        ctx.evaluateScript("var img = mkImg(0, 0, 390, 300); var res = tmFixImgAspect(img);")
        #expect(ctx.evaluateScript("res")?.toBool() == false)
        #expect(ctx.evaluateScript("img.style._h == null")?.toBool() == true)
    }

    @Test("no-ops when the image is not laid out (zero rendered box)")
    func noOpWhenNotLaidOut() {
        let ctx = makeContext()
        ctx.evaluateScript("var img = mkImg(1200, 600, 0, 0); var res = tmFixImgAspect(img);")
        #expect(ctx.evaluateScript("res")?.toBool() == false)
        #expect(ctx.evaluateScript("img.style._h == null")?.toBool() == true)
    }

    @Test("is idempotent — a corrected image is not re-corrected")
    func isIdempotent() {
        let ctx = makeContext()
        // After the first correction sets __tmAspectFixed, a second call (even
        // with the same distorted geometry) must early-return — the flag stops
        // a re-fire loop from the re-scan / ResizeObserver path.
        ctx.evaluateScript("""
        var img = mkImg(1200, 600, 390, 300);
        var first = tmFixImgAspect(img);
        img.style._h = null;                 // pretend nothing was written
        var second = tmFixImgAspect(img);
        """)
        #expect(ctx.evaluateScript("first")?.toBool() == true)
        #expect(ctx.evaluateScript("second")?.toBool() == false)
        #expect(ctx.evaluateScript("img.style._h == null")?.toBool() == true)
    }

    @Test("emits a debug reason via the optional log callback (no throw on a DOM-like img)")
    func emitsLogReason() {
        let ctx = makeContext()
        // The log path builds an info string from getAttribute/src — exercise it
        // to guard against a future change that throws there (e.g. assuming a
        // property the real <img> may lack).
        ctx.evaluateScript("""
        var logs = [];
        var L = function(s) { logs.push(s); };
        var distorted = mkImg(1200, 600, 390, 300, null, 300); // height-only, no width attr
        tmFixImgAspect(distorted, L);
        var logo = mkImg(200, 174, 33, 29, null, 29);
        tmFixImgAspect(logo, L);
        """)
        #expect(ctx.evaluateScript("logs.length")?.toInt32() == 2)
        #expect(ctx.evaluateScript("logs[0].indexOf('FIX') === 0")?.toBool() == true)
        #expect(ctx.evaluateScript("logs[0].indexOf('attrH=300') >= 0")?.toBool() == true)
        #expect(ctx.evaluateScript("logs[1].indexOf('skip(proportional)') === 0")?.toBool() == true)
    }

    // MARK: - Production script wiring (string-level regressions)

    @Test("production script only ever sets height — never width (fitViewport safety)")
    func productionScriptNeverTouchesWidth() {
        let js = _fixImageAspectRatioJS
        #expect(js.contains("tmFixImgAspect"))
        #expect(js.contains("setProperty('height', 'auto', 'important')"))
        // The invariant the whole design rests on: touching width could perturb
        // fitViewportJS's horizontal-overflow widen decision.
        #expect(!js.contains("setProperty('width'"))
    }

    @Test("production script hooks load events (covers deferred remote images)")
    func productionScriptHooksLoad() {
        let js = _fixImageAspectRatioJS
        // Deferred remote imgs are `complete` (no src) at documentEnd, so they
        // need their own load listener attached here — not {once}, since the
        // load fires only when deferredImageLoadJS swaps the real src in.
        #expect(js.contains("addEventListener('load'"))
        #expect(js.contains("getElementsByTagName('img')"))
    }
}
