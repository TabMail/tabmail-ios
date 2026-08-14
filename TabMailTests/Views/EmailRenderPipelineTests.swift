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
        // The cap itself is `!important` (2026-07-07 composer-reset fix,
        // see imgMaxWidthCapIsImportant below) — assert the `!important`
        // form here too so this test doesn't drift from the real output.
        #expect(out.contains("img { max-width: 100% !important; }"))
        #expect(out.contains("img[width] { height: auto; }"))
        // The unscoped form that stripped width-less images' height must be gone.
        #expect(!out.contains("img { max-width: 100%; height: auto; }"))
    }

    @Test("img max-width cap is !important — an author reset cannot defeat the responsive cap")
    func imgMaxWidthCapIsImportant() {
        let out = EmailHTMLWrapper.wrapHTML("<p>X</p>")
        // A webmail-composer email shipped a body-scoped reset —
        // `#note-contents, #note-contents * { ...; max-width: none;
        // ...; }` (no !important of its own) — that beat the plain-
        // specificity `img { max-width: 100%; }` cap on a 900px-wide inline-
        // styled banner. The image laid out at its full 900px and, once
        // images settled, postImageWidthRecheckJS requested a re-fit that
        // widened the whole (otherwise-fitting) email to 910px → 0.34x
        // shrink (logmain.log 2026-07-07). The cap is now !important so no
        // author reset — regardless of its own specificity — can remove it.
        #expect(out.contains("img { max-width: 100% !important; }"))
        // Guard against the pre-fix plain-specificity form silently returning.
        #expect(!out.contains("img { max-width: 100%; }"))
    }

    @Test("img[style*=width][style*=height] forces height:auto — inline-style analog of img[width]")
    func imgInlineStyleHeightAutoAnalog() {
        let out = EmailHTMLWrapper.wrapHTML("<p>X</p>")
        // The attribute-selector rule `img[width] { height: auto; }` only
        // matches images sized via the `width=` HTML attribute. An email
        // that sizes images entirely via an inline `style="width:900px;
        // height:274px"` (the composer-reset banner above) isn't covered by
        // it, so once the !important cap clamps the width, the inline
        // height:274px stays fixed and the image distorts. This rule is the
        // inline-style analog, also !important so it survives the same kind
        // of author reset. Requiring BOTH `width` and `height` substrings
        // keeps the loose [style*=] match harmless: an inline max-width /
        // max-height also contains "width"/"height" as substrings, but
        // forcing height:auto on those is harmless (aspect-correct once
        // loaded, collapses instead of leaving a fixed-height hole if never
        // loaded).
        #expect(out.contains("img[style*=\"width\"][style*=\"height\"] { height: auto !important; }"))
        // Do NOT touch the existing width-attribute rule (no evidence to
        // change it — see imgHeightAutoScopedToWidthAttr above).
        #expect(out.contains("img[width] { height: auto; }"))
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

    @Test("fitViewportJS aborts a runaway widen on a fluid culprit (Scholar Inbox logo)")
    func fitViewportRunawayGuard() {
        let js = _fitViewportJS
        // A width:auto / max-width:100% element (classically a deferred, not-yet-
        // loaded <img> whose src we strip to data-tmsrc) grows with whatever
        // viewport the loop sets, so it never converges — the loop chases it and
        // commits a tiny sub-0.5x scale ("desktop size" shrink). Scholar Inbox
        // digest header logo: 43px overflow at vw=288 ran 288→400→499→648→873 →
        // 0.33x (logmain.log 2026-06-29).
        //
        // The guard distinguishes FLUID (never converges, still overflows the
        // width we set) from genuinely-WIDE FIXED content (converges, fits the
        // width we set) and, for the fluid case below the 1200 cap, reverts to
        // device width + 1.0x (Apple-Mail-like) instead of shrinking.
        #expect(js.contains("var converged = false"))                  // tracks convergence
        #expect(js.contains("converged = true"))                       // set on the no-progress break
        // Abort condition: not converged, below cap, still overflowing.
        #expect(js.contains("if (!converged && targetWidth < 1200 && maxRight > targetWidth + OVERFLOW_SLOP)"))
        // Abort action: revert the viewport meta to device width (no shrink).
        #expect(js.contains("'width=device-width, initial-scale=1, maximum-scale=5, user-scalable=yes'"))
        // Must bail BEFORE stamping __tmLayoutVp (which would lock the widen via
        // the idempotency guard) — verify the abort returns before that commit.
        guard let abortIdx = js.range(of: "RUNAWAY widen aborted")?.lowerBound,
              let stampIdx = js.range(of: "window.__tmLayoutVp = targetWidth")?.lowerBound else {
            Issue.record("expected both the runaway-abort log and the layoutVp commit in fitViewportJS")
            return
        }
        #expect(abortIdx < stampIdx)
    }

    @Test("fitViewportJS widen target includes the culprit's own width (centered content)")
    func fitViewportWidenTargetsCulpritWidth() {
        let js = _fitViewportJS
        // A margin:auto / align=center culprit RE-CENTERS on every widen pass,
        // so its rect.right only closes half the remaining overflow per pass —
        // a 515px centered table at vw=288 walks 402→459→487→501, exhausts
        // MAX_PASSES still clipped, and the not-converged end state can trip
        // the runaway guard into reverting a fixed-width email to 1.0x
        // (FleetOptics delivery template, logmain.log 2026-07-04). The
        // culprit's own width is the exact one-pass viewport for centered
        // content; for left-anchored content width <= rect.right so the max()
        // is a no-op.
        #expect(js.contains("Math.ceil(Math.max(maxRight, culpritWidth))"))
        // Measured while the deferred images are still hidden — the same
        // phantom-overflow discipline as maxRight itself.
        #expect(js.contains("culpritWidth: cw"))
        // Refreshed on every remeasure pass, not just the initial measure.
        #expect(js.contains("culpritWidth = re.culpritWidth"))
    }

    @Test("post-image width recheck — event-driven, one-shot, requests the sanctioned re-fit")
    func postImageWidthRecheckPolicy() {
        let js = _postImageWidthRecheckJS
        // fit() measures with the deferred images HIDDEN (phantom-overflow fix),
        // so an image-driven width (FleetOptics: centered 515px table, 12 remote
        // imgs) under-widens and then clips forever once the images load — the
        // idempotency guard blocks fit re-entry. This script re-measures once
        // the LAST deferred/in-flight image settles and asks Swift for a re-fit
        // through the viewportResetJS path.
        // Only after fit() committed a baseline:
        #expect(js.contains("window.__tmFitDone"))
        // One-shot — can never loop reset/fit:
        #expect(js.contains("__tmWidthRefitRequested"))
        // Waits for the last pending image, keyed exactly like measureMaxRight's
        // hide (deferred data-tmsrc/srcset or in-flight !complete):
        #expect(js.contains("data-tmsrc"))
        #expect(js.contains("data-tmsrcset"))
        #expect(js.contains("!im.complete"))
        // Compares against the committed layout viewport, never bare innerWidth
        // (WebKit bug 170595) — same fallback chain as monitorHeightJS:
        #expect(js.contains("window.__tmLayoutVp || window.__tmDeviceWidth || window.innerWidth"))
        // Same 8px slop as fitViewportJS's OVERFLOW_SLOP:
        #expect(js.contains("vp + 8"))
        // Requests the Swift-side reset+fit; never mutates the viewport itself
        // (no meta writes, no direct fit() re-entry from JS):
        #expect(js.contains("requestWidthRefit"))
        #expect(!js.contains("setAttribute('content'"))
    }

    // MARK: - Post-image-load width pipeline (behavioral, via JSContext + mock DOM)
    //
    // Runs the PRODUCTION fitViewportJS → postImageWidthRecheckJS →
    // deferredImageLoadJS → viewportResetJS+fitViewportJS lifecycle against a
    // synthetic DOM that reproduces the 2026-07-04 clipped-right bug with
    // GENERIC content: a delivery-notification-style template whose CENTERED
    // (margin:auto) fixed-width table is sized by remote images — a 326px
    // skeleton while the deferred images are hidden/unloaded, `trueWidth`
    // (515px) once they load. Every rect is computed from the CURRENT layout
    // viewport (`_vw`, driven by the viewport meta), so the scripts get the
    // same layout feedback a real WebKit pass gives them: widening re-centers
    // the table, the fluid wrapper tracks the viewport, hiding an image
    // shrinks the table back to its skeleton width.
    //
    // Timers and rAF run synchronously in the mock, so the recheck script is
    // evaluated (arms its listeners) BEFORE deferredImageLoadJS — in
    // production the swap is deferred until after all documentEnd scripts.
    private static func widthPipelineHarness(trueWidth: Int) -> String {
        """
        var DEVICE_W = 288, TRUE_W = \(trueWidth), SKELETON_W = 326;
        var _vw = DEVICE_W;      // current layout viewport (CSS px) — driven by the meta
        var _msgs = [];
        var _imgs = [];
        function _imgsDriveFullWidth() {
            for (var i = 0; i < _imgs.length; i++) { if (!_imgs[i]._loaded || _imgs[i]._hidden) return false; }
            return true;
        }
        function _tableW() { return _imgsDriveFullWidth() ? TRUE_W : SKELETON_W; }
        function _centered(w) { return { left: (_vw - w) / 2, right: (_vw + w) / 2, width: w, height: 100 }; }
        function _mkStyle(el) { return {
            getPropertyValue: function (k) { return ''; },
            getPropertyPriority: function (k) { return ''; },
            setProperty: function (k, v, p) { if (k === 'display' && v === 'none') el._hidden = true; },
            removeProperty: function (k) { if (k === 'display') el._hidden = false; }
        }; }
        function _baseEl(tag, cls) {
            var el = {
                tagName: tag, className: cls || '', innerText: '', outerHTML: '<' + tag.toLowerCase() + '>',
                parentElement: null, naturalWidth: 0, naturalHeight: 0, offsetWidth: 0, offsetHeight: 0,
                _attrs: {}, _hidden: false, _listeners: {},
                getAttribute: function (k) { return (k in el._attrs) ? el._attrs[k] : null; },
                setAttribute: function (k, v) { el._attrs[k] = v; if (el.tagName === 'IMG' && k === 'src') el.complete = false; },
                removeAttribute: function (k) { delete el._attrs[k]; },
                hasAttribute: function (k) { return (k in el._attrs); },
                querySelectorAll: function (s) { return []; },
                addEventListener: function (t, fn) { (el._listeners[t] = el._listeners[t] || []).push(fn); }
            };
            el.style = _mkStyle(el);
            return el;
        }
        var fluidDiv = _baseEl('DIV', 'wrapper');           // width:100% — tracks the viewport
        fluidDiv.getBoundingClientRect = function () { return { left: 0, right: _vw, width: _vw, height: 400 }; };
        var table = _baseEl('TABLE', 'main');               // centered, image-driven width
        table.getBoundingClientRect = function () { return _centered(_tableW()); };
        table.parentElement = fluidDiv;
        function _mkImg() {
            var img = _baseEl('IMG', '');
            img._attrs['data-tmsrc'] = 'https://example.com/banner.png';
            img.complete = true;      // deferred: no src yet, nothing pending
            img._loaded = false;
            img.getBoundingClientRect = function () {
                if (img._hidden) return { left: 0, right: 0, width: 0, height: 0 };
                return _centered(_tableW());
            };
            img.parentElement = table;
            _imgs.push(img);
            return img;
        }
        _mkImg(); _mkImg();
        var _all = [fluidDiv, table].concat(_imgs);
        var _meta = {
            _content: 'width=device-width, initial-scale=1, maximum-scale=5, user-scalable=yes',
            getAttribute: function (k) { return _meta._content; },
            setAttribute: function (k, v) {
                _meta._content = v;
                var m = v.match(/width=(device-width|\\d+)/);
                if (m) _vw = (m[1] === 'device-width') ? DEVICE_W : parseInt(m[1], 10);
            }
        };
        var document = {
            readyState: 'complete',
            documentElement: { offsetHeight: 100, style: { setProperty: function () {} } },
            querySelector: function (s) { return s.indexOf('meta') >= 0 ? _meta : null; },
            querySelectorAll: function (s) { return _imgs.filter(function (im) { return im.hasAttribute('data-tmsrc') || im.hasAttribute('data-tmsrcset'); }); },
            getElementsByTagName: function (t) { return t === 'img' ? _imgs.slice() : _all.slice(); },
            body: {
                scrollHeight: 1200,
                scrollTop: 0,
                style: { setProperty: function () {} },
                getBoundingClientRect: function () { return { left: 0, right: _vw, width: _vw, height: 1200 }; },
                getElementsByTagName: function (t) { return t === 'img' ? _imgs.slice() : _all.slice(); },
                querySelectorAll: function (s) { return [fluidDiv]; }
            }
        };
        var window = {
            innerWidth: DEVICE_W, innerHeight: 800, devicePixelRatio: 3,
            screen: { width: DEVICE_W },
            addEventListener: function () {},
            getComputedStyle: function (el) { return { width: '', height: '', maxWidth: '' }; },
            webkit: { messageHandlers: {
                consoleLog: { postMessage: function (s) {} },
                heightChanged: { postMessage: function (m) { _msgs.push(m); } }
            } }
        };
        function requestAnimationFrame(fn) { fn(); }
        function setTimeout(fn, t) { fn(); }
        function fireImgEvent(idx, type) {
            var img = _imgs[idx];
            if (type === 'load') { img.complete = true; img._loaded = true; }
            if (type === 'error') { img.complete = true; }
            var ls = img._listeners[type] || [];
            for (var i = 0; i < ls.length; i++) ls[i]();
        }
        function refitRequests() {
            var n = 0;
            for (var i = 0; i < _msgs.length; i++) { if (_msgs[i] && _msgs[i].requestWidthRefit === true) n++; }
            return n;
        }
        """
    }

    private func makeWidthPipelineContext(trueWidth: Int) -> JSContext {
        let ctx = JSContext()!
        ctx.evaluateScript(Self.widthPipelineHarness(trueWidth: trueWidth))
        #expect(ctx.exception == nil, "harness threw: \(ctx.exception?.toString() ?? "")")
        return ctx
    }

    private func layoutVp(_ ctx: JSContext) -> Int32 {
        ctx.evaluateScript("window.__tmLayoutVp || 0")?.toInt32() ?? -1
    }

    private func refitRequests(_ ctx: JSContext) -> Int32 {
        ctx.evaluateScript("refitRequests()")?.toInt32() ?? -1
    }

    @Test("image-driven wide email: first fit under-widens, recheck requests ONE refit, refit converges to the true width")
    func widthPipelineRecheckRefitsImageDrivenWidth() {
        let ctx = makeWidthPipelineContext(trueWidth: 515)

        // Phase 1 — first fit at device width 288 (what Coordinator.fit runs).
        // The deferred images are hidden for measurement, so only the 326px
        // skeleton overflows → the widen floors at STANDARD_MIN (400). This IS
        // the under-widened state: the true 515px layout is invisible to fit.
        ctx.evaluateScript("window.__tmDeviceWidth = 288;" + _fitViewportJS)
        #expect(ctx.exception == nil, "phase-1 fit threw: \(ctx.exception?.toString() ?? "")")
        #expect(layoutVp(ctx) == 400)

        // Phase 2 — recheck arms its listeners (documentEnd), then the deferred
        // swap runs and the images stream in one at a time.
        ctx.evaluateScript(_postImageWidthRecheckJS)
        ctx.evaluateScript(_deferredImageLoadJS(diagnosticsEnabled: false))
        #expect(ctx.exception == nil, "phase-2 scripts threw: \(ctx.exception?.toString() ?? "")")
        #expect(refitRequests(ctx) == 0)
        ctx.evaluateScript("fireImgEvent(0, 'load')")
        #expect(refitRequests(ctx) == 0)                 // second image still pending — no refit yet
        ctx.evaluateScript("fireImgEvent(1, 'load')")
        #expect(refitRequests(ctx) == 1)                 // LAST image settled → overflow detected
        ctx.evaluateScript("fireImgEvent(1, 'load')")
        #expect(refitRequests(ctx) == 1)                 // one-shot — a re-fire can never loop

        // Phase 3 — what Coordinator.resetAndFit evaluates, in one JS turn.
        ctx.evaluateScript(viewportResetJS(deviceWidth: 288) + ";" + _fitViewportJS)
        #expect(ctx.exception == nil, "phase-3 refit threw: \(ctx.exception?.toString() ?? "")")
        // Converges to EXACTLY the table's width, in one pass, via the
        // culpritWidth target. A rect.right-only target would stall (the
        // centered table re-centers each pass: 402→459→487→501) and leave the
        // right edge clipped — this assertion fails if that regresses.
        #expect(layoutVp(ctx) == 515)
        let metaContent = ctx.evaluateScript("_meta._content")?.toString() ?? ""
        #expect(metaContent.contains("width=515"))
    }

    @Test("images that load without changing the layout width never trigger a refit")
    func widthPipelineNoRefitWhenImagesFit() {
        // Loaded width == skeleton width: the images add no horizontal extent,
        // so after the last one settles the 326px table sits well inside the
        // 400px viewport (right edge 363) and no refit request may be posted.
        let ctx = makeWidthPipelineContext(trueWidth: 326)
        ctx.evaluateScript("window.__tmDeviceWidth = 288;" + _fitViewportJS)
        #expect(layoutVp(ctx) == 400)
        ctx.evaluateScript(_postImageWidthRecheckJS)
        ctx.evaluateScript(_deferredImageLoadJS(diagnosticsEnabled: false))
        ctx.evaluateScript("fireImgEvent(0, 'load'); fireImgEvent(1, 'load')")
        #expect(ctx.exception == nil, "scripts threw: \(ctx.exception?.toString() ?? "")")
        #expect(refitRequests(ctx) == 0)
    }

    // MARK: - postImageWidthRecheckJS clip-aware discipline (mirrors measureMaxRight)

    /// Minimal DOM stub for `postImageWidthRecheckJS`'s `check()`: a 490px
    /// TABLE inside a DIV.w-full.overflow-auto "scroller" (286px), plus one
    /// deferred `<img>` inside the table whose settle event is what drives
    /// `check()` to run. `scrollerOverflowX` controls whether the scroller
    /// clips (nil models a genuine desktop-width email with no clipping
    /// ancestor — the regression guard that a real overflow still refits).
    private static func clipAwareRecheckHarness(scrollerOverflowX: String?) -> String {
        let overflowAssignment = scrollerOverflowX.map { "scroller._overflowX = '\($0)';" } ?? ""
        return """
        var _msgs = [];
        function _baseEl(tag, cls) {
            var el = {
                tagName: tag, className: cls || '', parentElement: null, complete: true,
                _attrs: {}, _overflowX: undefined, _listeners: {},
                getAttribute: function (k) { return (k in el._attrs) ? el._attrs[k] : null; },
                setAttribute: function (k, v) { el._attrs[k] = v; },
                hasAttribute: function (k) { return (k in el._attrs); },
                addEventListener: function (t, fn) { (el._listeners[t] = el._listeners[t] || []).push(fn); }
            };
            return el;
        }
        // Sender's own horizontal-scroll wrapper (markdown-render table pattern).
        var scroller = _baseEl('DIV', 'w-full overflow-auto');
        scroller.getBoundingClientRect = function () { return { left: 0, right: 286, width: 286, height: 120 }; };
        \(overflowAssignment)
        // The 490px pricing table, wider than the 288pt viewport, INSIDE the
        // scroller — the cloud-console notification pattern (logmain.log 2026-07-07).
        var table = _baseEl('TABLE', 'w-max min-w-full');
        table.getBoundingClientRect = function () { return { left: 0, right: 490, width: 490, height: 100 }; };
        table.parentElement = scroller;
        // One deferred image inside the table — just enough to drive
        // postImageWidthRecheckJS's settle-then-check() event; the table's
        // own width does not depend on the image loading.
        var img = _baseEl('IMG', '');
        img._attrs['data-tmsrc'] = 'https://example.com/thumb.png';
        img.getBoundingClientRect = function () { return { left: 0, right: 10, width: 10, height: 10 }; };
        img.parentElement = table;
        var _all = [scroller, table, img];
        var _imgs = [img];
        var document = {
            getElementsByTagName: function (t) { return t === 'img' ? _imgs.slice() : _all.slice(); },
            body: {
                getElementsByTagName: function (t) { return t === 'img' ? _imgs.slice() : _all.slice(); }
            }
        };
        var window = {
            innerWidth: 288,
            getComputedStyle: function (el) { return { width: '', height: '', maxWidth: '', overflowX: el._overflowX }; },
            webkit: { messageHandlers: {
                consoleLog: { postMessage: function (s) {} },
                heightChanged: { postMessage: function (m) { _msgs.push(m); } }
            } }
        };
        function setTimeout(fn, t) { fn(); }
        // Simulates deferredImageLoadJS's swap (data-tmsrc → src) firing the
        // image's real 'load' event once the swapped-in resource resolves.
        function fireImgEvent(type) {
            img._attrs['src'] = img._attrs['data-tmsrc'];
            delete img._attrs['data-tmsrc'];
            img.complete = true;
            var ls = img._listeners[type] || [];
            for (var i = 0; i < ls.length; i++) ls[i]();
        }
        function refitRequests() {
            var n = 0;
            for (var i = 0; i < _msgs.length; i++) { if (_msgs[i] && _msgs[i].requestWidthRefit === true) n++; }
            return n;
        }
        """
    }

    private func makeClipAwareRecheckContext(scrollerOverflowX: String?) -> JSContext {
        let ctx = JSContext()!
        // Harness first — it defines `var window`; a bare JSContext has no
        // window global, so setting the fit flags before it throws.
        ctx.evaluateScript(Self.clipAwareRecheckHarness(scrollerOverflowX: scrollerOverflowX))
        ctx.evaluateScript("window.__tmFitDone = true; window.__tmDeviceWidth = 288;")
        #expect(ctx.exception == nil, "harness threw: \(ctx.exception?.toString() ?? "")")
        return ctx
    }

    @Test("post-image width recheck stays quiet when the settled overflow is entirely inside a clipped author container")
    func widthPipelineRecheckSkipsClippedOverflow() {
        // Same clip-aware discipline as measureMaxRight (fitViewportJS): the
        // 490px table is contained by its own DIV.w-full.overflow-auto
        // scroller (286px), so even after the table's image settles and
        // `check()` re-measures, the overflow must not trigger a re-fit.
        let ctx = makeClipAwareRecheckContext(scrollerOverflowX: "auto")
        ctx.evaluateScript(_postImageWidthRecheckJS)
        #expect(ctx.exception == nil, "recheck script threw: \(ctx.exception?.toString() ?? "")")
        ctx.evaluateScript("fireImgEvent('load')")
        #expect(ctx.exception == nil, "fire threw: \(ctx.exception?.toString() ?? "")")
        #expect(refitRequests(ctx) == 0)
    }

    // MARK: - P4 image-failure census (behavioral, via JSContext + mock DOM)
    //
    // THE INVARIANT, and it is what every test below pins:
    //
    //     `postImageWidthRecheckJS` reports a failure census IF AND ONLY IF at
    //     least one armed image has settled, it reports it NEVER BEFORE THE LAST
    //     ARMED IMAGE SETTLES, exactly ONCE, and the count it reports is the
    //     number of images WE DEFERRED (remote `http(s)`, i.e. `data-tmsrc` /
    //     `data-tmsrcset`) that ended in `error` — not the number that ended in
    //     `load`, and not local/`cid:` images that failed.
    //
    // This census is diagnostic-only as of 2026-08-13. Both directions still
    // matter because a false or incomplete count makes the device log misleading.
    //
    // The harness models the state machine the real pipeline produces: an image
    // we deferred carries `data-tmsrc` and reports `complete === true` (no src
    // assigned yet); `simulateSwap()` reproduces `deferredImageLoadJS`'s
    // attribute removal, which is why the "is this remote" fact MUST be captured
    // at arm time; and a BROKEN image reports `complete === true` exactly like a
    // loaded one, which is why the count comes from the `error` listener and not
    // from any property of the element.

    /// Minimal DOM stub for the failure census. `remoteCount` images carry
    /// `data-tmsrc` (deferred by `wrapHTML` because they are remote http(s));
    /// `localCount` images are in-flight non-deferred ones (a `cid:` inline
    /// attachment mid-decode) — armed by `!complete`, but never counted.
    private static func imageFailureHarness(
        remoteCount: Int, localCount: Int = 0, withheldCount: Int = 0
    ) -> String {
        """
        var _failMsgs = [];
        var _msgs = [];
        var _fires = 0;
        function _baseEl(tag) {
            var el = {
                tagName: tag, className: '', parentElement: null, complete: true,
                _attrs: {}, _listeners: {},
                getAttribute: function (k) { return (k in el._attrs) ? el._attrs[k] : null; },
                setAttribute: function (k, v) { el._attrs[k] = v; },
                removeAttribute: function (k) { delete el._attrs[k]; },
                hasAttribute: function (k) { return (k in el._attrs); },
                getBoundingClientRect: function () { return { left: 0, right: 10, width: 10, height: 10 }; },
                addEventListener: function (t, fn) { (el._listeners[t] = el._listeners[t] || []).push(fn); }
            };
            return el;
        }
        // `_imgs` is the ARM-TIME population and keeps stable indices for
        // `fireImgEvent`. `_domImgs` is what `getElementsByTagName` returns, i.e.
        // the LIVE document. They start identical and `removeFromDom` separates
        // them — which is the only way to model author script detaching a node,
        // and the only way to see the census's undercount race.
        var _imgs = [], _domImgs = [];
        function _addImg(im) { _imgs.push(im); _domImgs.push(im); }
        for (var r = 0; r < \(remoteCount); r++) {
            var rim = _baseEl('IMG');
            // Deferred by EmailHTMLWrapper.wrapHTML: the real URL is parked in
            // data-tmsrc and no src is assigned, so complete is true and nothing
            // is pending yet.
            rim._attrs['data-tmsrc'] = 'https://example.com/pixel-' + r + '.png';
            rim._remote = true;
            _addImg(rim);
        }
        for (var w = 0; w < \(withheldCount); w++) {
            // T8: inside a hidden `.eml` section, so `swap()` marks it withheld
            // and leaves data-tmsrc in place. Armed (it is not skippable), but it
            // will never load and never error.
            var wim = _baseEl('IMG');
            wim._attrs['data-tmsrc'] = 'https://example.com/withheld-' + w + '.png';
            wim._attrs['data-tmwithheld'] = '1';
            wim._remote = true;
            _addImg(wim);
        }
        for (var l = 0; l < \(localCount); l++) {
            var lim = _baseEl('IMG');
            // A cid: inline attachment mid-decode: never rewritten by wrapHTML,
            // so no data-tmsrc — armed only because it is not complete.
            lim._attrs['src'] = 'cid:inline-' + l;
            lim.complete = false;
            lim._remote = false;
            _addImg(lim);
        }
        var document = {
            getElementsByTagName: function (t) { return _domImgs.slice(); },
            body: {
                getElementsByTagName: function (t) { return _domImgs.slice(); }
            }
        };
        var window = {
            innerWidth: 288,
            getComputedStyle: function (el) { return { overflowX: undefined }; },
            webkit: { messageHandlers: {
                consoleLog: { postMessage: function (s) {} },
                heightChanged: { postMessage: function (m) { _msgs.push(m); } },
                imageLoadFailure: { postMessage: function (m) { _failMsgs.push(m); } }
            } }
        };
        function setTimeout(fn, t) { fn(); }
        // Reproduces deferredImageLoadJS's swap(): the attribute is REMOVED before
        // the src is assigned, so by the time load/error fires the element no
        // longer says it was ever remote. A WITHHELD image is skipped exactly as
        // `hiddenByViewMode` makes swap() skip it — it keeps data-tmsrc, gets no
        // src, and therefore can never fire either terminal event.
        function simulateSwap() {
            for (var i = 0; i < _imgs.length; i++) {
                var im = _imgs[i];
                if (im.hasAttribute('data-tmwithheld')) continue;
                if (im.hasAttribute('data-tmsrc')) {
                    var s = im.getAttribute('data-tmsrc');
                    im.removeAttribute('data-tmsrc');
                    im.setAttribute('src', s);
                    im.complete = false;   // now genuinely in flight
                }
            }
        }
        function fireImgEvent(idx, type) {
            var img = _imgs[idx];
            // A BROKEN image reports complete === true, exactly like a loaded one
            // — the whole reason the census cannot be derived from the element.
            img.complete = true;
            var ls = img._listeners[type] || [];
            // `_fires` counts LISTENER INVOCATIONS, not calls to this function, so
            // a test can assert that its setup actually reached a handler rather
            // than trusting that it did (an unarmed image has an empty list and
            // this call is a silent no-op).
            for (var i = 0; i < ls.length; i++) { _fires++; ls[i](); }
        }
        // Author script detaching a node from the document. The element and its
        // listeners survive — the browser keeps firing events at a detached image
        // whose request is still in flight — but the live-DOM walk stops seeing it.
        function removeFromDom(idx) {
            var p = _domImgs.indexOf(_imgs[idx]);
            if (p >= 0) _domImgs.splice(p, 1);
        }
        // Makes one image overflow the 288pt viewport so check()'s re-fit branch
        // is reachable; without it every rect is 10pt wide and check() always
        // takes the "no overflow" exit.
        function setRight(idx, px) {
            var im = _imgs[idx];
            im.getBoundingClientRect = function () {
                return { left: 0, right: px, width: px, height: 10 };
            };
        }
        function listenerFires() { return _fires; }
        function domImageCount() { return _domImgs.length; }
        function armedListenerCount(idx) {
            var ls = _imgs[idx]._listeners;
            return ((ls['load'] || []).length) + ((ls['error'] || []).length);
        }
        function refitRequests() {
            var n = 0;
            for (var i = 0; i < _msgs.length; i++) {
                if (_msgs[i] && _msgs[i].requestWidthRefit) n++;
            }
            return n;
        }
        function failureReports() { return _failMsgs.length; }
        function reportedFailed() { return _failMsgs.length ? _failMsgs[0].failed : -1; }
        function reportedDeferred() { return _failMsgs.length ? _failMsgs[0].deferred : -1; }
        """
    }

    /// Arms `postImageWidthRecheckJS` over the failure harness and performs the
    /// deferred swap, i.e. the production ordering: the recheck script installs
    /// its listeners at documentEnd, and `deferredImageLoadJS` assigns the real
    /// URLs afterwards.
    private func makeImageFailureContext(
        remoteCount: Int, localCount: Int = 0, withheldCount: Int = 0
    ) -> JSContext {
        let ctx = JSContext()!
        ctx.evaluateScript(Self.imageFailureHarness(
            remoteCount: remoteCount, localCount: localCount, withheldCount: withheldCount))
        // The census deliberately does NOT depend on __tmFitDone (a failed load is
        // not a layout fact), so it is left unset here — a test that set it could
        // not tell the two designs apart.
        #expect(ctx.exception == nil, "harness threw: \(ctx.exception?.toString() ?? "")")
        ctx.evaluateScript(_postImageWidthRecheckJS)
        #expect(ctx.exception == nil, "recheck script threw: \(ctx.exception?.toString() ?? "")")
        ctx.evaluateScript("simulateSwap()")
        #expect(ctx.exception == nil, "swap threw: \(ctx.exception?.toString() ?? "")")
        return ctx
    }

    private func failureReports(_ ctx: JSContext) -> Int32 {
        ctx.evaluateScript("failureReports()")?.toInt32() ?? -1
    }

    private func reportedFailed(_ ctx: JSContext) -> Int32 {
        ctx.evaluateScript("reportedFailed()")?.toInt32() ?? -99
    }

    @Test("image-failure census: one remote image errors → exactly one report, count 1, only after the LAST image settles")
    func imageFailureCensusReportsErroredRemoteImages() {
        let ctx = makeImageFailureContext(remoteCount: 2)

        // Nothing has settled — the census must not have fired.
        #expect(failureReports(ctx) == 0)

        // First image fails. The SECOND is still in flight, so reporting now
        // would be reporting before the last image settles — forbidden.
        ctx.evaluateScript("fireImgEvent(0, 'error')")
        #expect(ctx.exception == nil, "error fire threw: \(ctx.exception?.toString() ?? "")")
        #expect(failureReports(ctx) == 0, "the census must never fire before the LAST armed image settles")

        // Last image loads → the census fires, once, counting the one failure.
        ctx.evaluateScript("fireImgEvent(1, 'load')")
        #expect(ctx.exception == nil, "load fire threw: \(ctx.exception?.toString() ?? "")")
        #expect(failureReports(ctx) == 1)
        #expect(reportedFailed(ctx) == 1)
        #expect(ctx.evaluateScript("reportedDeferred()")?.toInt32() == 2)

        // A re-fire (WebKit can re-deliver, and the listeners are deliberately
        // not {once}) must not produce a second report for one document.
        ctx.evaluateScript("fireImgEvent(1, 'load'); fireImgEvent(0, 'error')")
        #expect(failureReports(ctx) == 1, "the census is one-shot per document")
    }

    @Test("image-failure census: every remote image loading reports zero failures")
    func imageFailureCensusReportsZeroWhenEverythingLoads() {
        // The required negative control: an image-heavy newsletter where nothing
        // went wrong must report a true zero.
        let ctx = makeImageFailureContext(remoteCount: 3)
        ctx.evaluateScript("fireImgEvent(0, 'load'); fireImgEvent(1, 'load')")
        #expect(failureReports(ctx) == 0, "still one image pending")
        ctx.evaluateScript("fireImgEvent(2, 'load')")
        #expect(ctx.exception == nil, "load fires threw: \(ctx.exception?.toString() ?? "")")
        #expect(failureReports(ctx) == 1, "the diagnostic still reports its true zero")
        #expect(reportedFailed(ctx) == 0)
    }

    @Test("image-failure census: a message with no images arms nothing and never reports")
    func imageFailureCensusStaysSilentWithNoImages() {
        // Second required negative control: no remote images at all. Nothing is
        // armed, so nothing can ever call the census — structurally, not by luck.
        let ctx = makeImageFailureContext(remoteCount: 0)
        #expect(ctx.exception == nil, "empty-document arming threw: \(ctx.exception?.toString() ?? "")")
        #expect(failureReports(ctx) == 0)
    }

    @Test("image-failure census counts only the images WE deferred — a failing cid: image is not a remote failure")
    func imageFailureCensusExcludesLocalImages() {
        // The census reports deferred remote-image failures. A `cid:` inline
        // attachment that fails to decode is a different class, so it drives settle
        // (it is armed on !complete) without inflating the count. Without the
        // arm-time capture this test cannot pass: by the
        // time the error fires, `simulateSwap()` has removed `data-tmsrc` from the
        // remote images, so a fire-time read would classify everything as local.
        let ctx = makeImageFailureContext(remoteCount: 1, localCount: 1)
        ctx.evaluateScript("fireImgEvent(1, 'error')")   // the cid: image fails
        #expect(failureReports(ctx) == 0, "the remote image has not settled yet")
        ctx.evaluateScript("fireImgEvent(0, 'load')")    // the remote one loads
        #expect(ctx.exception == nil, "fires threw: \(ctx.exception?.toString() ?? "")")
        #expect(failureReports(ctx) == 1)
        #expect(reportedFailed(ctx) == 0, "a cid: failure is not a deferred-remote failure")
        #expect(ctx.evaluateScript("reportedDeferred()")?.toInt32() == 1,
                "only the deferred remote image counts toward the deferred total")
    }

    @Test("image-failure census: every remote image erroring reports them all")
    func imageFailureCensusCountsEveryFailure() {
        let ctx = makeImageFailureContext(remoteCount: 3)
        ctx.evaluateScript("fireImgEvent(0, 'error'); fireImgEvent(1, 'error'); fireImgEvent(2, 'error')")
        #expect(ctx.exception == nil, "error fires threw: \(ctx.exception?.toString() ?? "")")
        #expect(failureReports(ctx) == 1)
        #expect(reportedFailed(ctx) == 3)
    }

    @Test("image-failure census counts IMAGES, not error EVENTS")
    func imageFailureCensusCountsImagesNotErrorEvents() {
        // THE INVARIANT: `failed` is the number of deferred images that ENDED in
        // `error`, so it can never exceed `deferred`. The listeners are
        // deliberately not `{once}` — a deferred <img> only fires `load` after
        // swap() assigns its real src — which means one broken image can deliver
        // `error` as many times as author script re-assigns its `src`. Counting
        // fires rather than images let a sender drive the count past the number
        // of images that existed, making the diagnostic census false.
        let ctx = makeImageFailureContext(remoteCount: 2)

        // MIS-IOS-016 — assert the setup's effect actually happened. An unarmed
        // image has an empty listener list and `fireImgEvent` is then a silent
        // no-op, so "three errors were delivered" has to be observed, not assumed.
        #expect(ctx.evaluateScript("armedListenerCount(0)")?.toInt32() == 2,
                "image 0 must carry both a load and an error listener")
        let firesBefore = ctx.evaluateScript("listenerFires()")?.toInt32() ?? -1
        ctx.evaluateScript("fireImgEvent(0, 'error'); fireImgEvent(0, 'error'); fireImgEvent(0, 'error')")
        #expect(ctx.exception == nil, "error fires threw: \(ctx.exception?.toString() ?? "")")
        #expect(ctx.evaluateScript("listenerFires()")?.toInt32() == firesBefore + 3,
                "all three error events must really have reached the handler")
        #expect(failureReports(ctx) == 0, "image 1 has not settled")

        ctx.evaluateScript("fireImgEvent(1, 'load')")
        #expect(ctx.exception == nil, "load fire threw: \(ctx.exception?.toString() ?? "")")
        #expect(failureReports(ctx) == 1)
        // ONE image failed, however many times it said so.
        #expect(reportedFailed(ctx) == 1)
        #expect(ctx.evaluateScript("reportedDeferred()")?.toInt32() == 2)
        // The relation, stated directly: a census that claims more failures than
        // there were deferred images is unreadable as English and impossible now.
        #expect(reportedFailed(ctx) <= (ctx.evaluateScript("reportedDeferred()")?.toInt32() ?? -1))
    }

    @Test("image-failure census settles on the ARMED SET — detaching an in-flight image does not settle it")
    func imageFailureCensusSettlesOnTheArmedSetNotTheLiveDOM() {
        // THE INVARIANT: the census reports only once every image WE ARMED has
        // reached a terminal state. Asking that question of the live DOM instead
        // made it answerable by author script: detach a still-loading <img> and
        // the walk stops counting it, the one-shot report publishes early, and
        // the image's later `error` has nowhere to go. The one-shot diagnostic
        // then under-reports permanently for that document.
        //
        // A detached image is NOT a hypothetical: the browser keeps servicing an
        // in-flight request for a removed element and still fires its events.
        let ctx = makeImageFailureContext(remoteCount: 2)
        #expect(ctx.evaluateScript("domImageCount()")?.toInt32() == 2)

        ctx.evaluateScript("removeFromDom(1)")

        // MIS-IOS-016 — both halves of the precondition, and neither implies the
        // other: the detach really took (the live DOM is down to one image), and
        // image 1 is really still armed (its listeners survived the detach), so
        // "it errors later" is a reachable event rather than a story.
        #expect(ctx.evaluateScript("domImageCount()")?.toInt32() == 1)
        #expect(ctx.evaluateScript("armedListenerCount(1)")?.toInt32() == 2)

        ctx.evaluateScript("fireImgEvent(0, 'error')")
        #expect(ctx.exception == nil, "error fire threw: \(ctx.exception?.toString() ?? "")")
        #expect(failureReports(ctx) == 0,
                "the detached image has reached no terminal state — the census is not complete")

        ctx.evaluateScript("fireImgEvent(1, 'error')")
        #expect(ctx.exception == nil, "error fire threw: \(ctx.exception?.toString() ?? "")")
        #expect(failureReports(ctx) == 1)
        #expect(reportedFailed(ctx) == 2, "leaving the document is not reaching a terminal state")
        #expect(ctx.evaluateScript("reportedDeferred()")?.toInt32() == 2)
    }

    @Test("image-failure census is observational — the script never retries, probes or re-requests a failed URL")
    func imageFailureCensusNeverRetries() {
        // Static guard on the one property that makes this phase acceptable at
        // all. A retry, a HEAD probe or a re-assignment of a failed src would
        // manufacture exactly the tracking hit the deferred-load design bounds,
        // and would also be the reverted 2026-06-17 design creeping back in a
        // different direction.
        let js = _postImageWidthRecheckJS
        #expect(!js.contains("fetch("))
        #expect(!js.contains("XMLHttpRequest"))
        #expect(!js.contains("new Image"))
        #expect(!js.contains("HEAD"))
        // The census must not assign a src/srcset anywhere — only
        // deferredImageLoadJS is allowed to do that, and only once.
        #expect(!js.contains("setAttribute('src'"))
        #expect(!js.contains("setAttribute('srcset'"))
        #expect(!js.contains(".src ="))
        // It must not be able to remove the deferral marker either, which would
        // change WHICH images load — the standing "no behaviour changes" line.
        #expect(!js.contains("removeAttribute('data-tmsrc'"))
        // And it posts on its own dedicated channel, not by widening an existing one.
        #expect(js.contains("messageHandlers.imageLoadFailure.postMessage"))
    }

    @Test("image-failure census reuses the settle keying rather than inventing a second one")
    func imageFailureCensusReusesTheSettleKeying() {
        // Memory/037 bullet 15's lockstep constraint: `measureMaxRight`'s
        // hide-for-scan and this script's settle predicate encode the SAME
        // "not yet displayable" key. The census must ride on that predicate, not
        // add a third spelling — and in particular must NOT use
        // `naturalWidth === 0`, which bullet 14 rules out because it also
        // classifies a LOADED intrinsic-size-less SVG as pending.
        let js = _postImageWidthRecheckJS
        // ONE definition of the width pipeline's settle predicate — never two
        // divergent copies of it.
        //
        // ⚠️ Twice-corrected, and the corrections are the interesting part.
        // (1) This test once asserted the literal `"if (pendingImgs() > 0) return;"`
        // — that BOTH arms made the identical bare call. That pinned a mechanism
        // which was itself the defect: sharing one predicate let a withheld image
        // disarm the width re-fit permanently, and the test stayed green through
        // all of it. (2) Its replacement then said "ONE predicate function, asked
        // TWO different questions by argument", which stopped being true on
        // 2026-08-13: the census no longer calls `pendingImgs` at all, because the
        // two arms differ in POPULATION (armed set vs live DOM) and not only in
        // predicate, and no argument expresses that. What survives both rounds is
        // the narrow, checkable property below — the width pipeline's predicate is
        // singular — plus the ruled-out spelling. Which question each arm asks is
        // behaviour, and is pinned by driving the script in
        // `widthRefitIgnoresWithheldImagesButTheCensusDoesNot`.
        #expect(js.contains("function pendingImgs(ignoreWithheld)"),
                "the width settle predicate must remain a single function")
        #expect(js.components(separatedBy: "function pendingImgs").count == 2,
                "a second pendingImgs definition would be a divergent copy")
        #expect(!js.contains("naturalWidth"))
        // Own one-shot, deliberately not check()'s: a message that both loses
        // images AND needs a width re-fit must still report.
        #expect(js.contains("__tmImageFailureReported"))
        #expect(js.contains("__tmWidthRefitRequested"))
    }

    @Test("The width re-fit ignores withheld images; the failure census does not")
    func widthRefitIgnoresWithheldImagesButTheCensusDoesNot() {
        // THE INVARIANT: a T8-withheld image (inside a hidden `.eml` section)
        // must never be able to stall the post-image-load WIDTH RE-FIT, and must
        // still count as unsettled for the FAILURE CENSUS.
        //
        // Why both halves are load-bearing:
        //   • Drop the first and T8 silently disarms a re-fit that shipped in
        //     v1.7.8 — every message carrying an attached `.eml` renders with
        //     uncorrected horizontal overflow, recoverable only by rotating the
        //     device. That regression shipped inside a "security only" commit
        //     and survived because the two arms shared one predicate.
        //   • Drop the second and the diagnostic publishes a census while an
        //     armed image has reached no terminal state — a count that is not
        //     merely early but wrong, on a channel that describes this message
        //     as having lost content. IOS-UI-004 is preserved deliberately, not
        //     incidentally.
        //
        // ⚠️ Both halves were asserted as LITERAL SOURCE STRINGS
        // (`"if (pendingImgs(true) > 0) return;"` and its `false` twin) until
        // 2026-08-13. That pinned the spelling of the mechanism, not the
        // behaviour: the census arm has since stopped calling `pendingImgs` at
        // all — it settles on the armed set's terminal marks, because the two
        // arms differ in POPULATION as well as in predicate — and a
        // string-matching test would have reported that as a regression while
        // being unable to notice an actual one. Rewritten to drive the script.
        let ctx = makeImageFailureContext(remoteCount: 1, withheldCount: 1)

        // MIS-IOS-016 — the three preconditions this test's verdict rests on,
        // asserted rather than assumed:
        //   * the withheld image really was skipped by the swap, so it still
        //     holds `data-tmsrc` and can never reach a terminal state;
        //   * it really IS armed, so "it never settles" is a fact about a
        //     listener that exists, not about an image nobody is watching;
        //   * the visible image really did receive its src, so its `load` below
        //     is a real settle and not a no-op.
        #expect(ctx.evaluateScript("_imgs[1].hasAttribute('data-tmsrc')")?.toBool() == true,
                "swap() must leave a withheld image deferred")
        #expect(ctx.evaluateScript("_imgs[1].hasAttribute('data-tmwithheld')")?.toBool() == true)
        #expect(ctx.evaluateScript("armedListenerCount(1)")?.toInt32() == 2,
                "a withheld image is still armed — that is why it can block the census")
        #expect(ctx.evaluateScript("_imgs[0].hasAttribute('data-tmsrc')")?.toBool() == false,
                "the visible image must have been swapped")

        // fit() has committed its baseline, and the visible image turns out to
        // overflow the 288pt viewport once it loads — the exact situation the
        // post-load width re-fit exists for.
        ctx.evaluateScript("window.__tmFitDone = true; setRight(0, 400);")
        ctx.evaluateScript("fireImgEvent(0, 'load')")
        #expect(ctx.exception == nil, "load fire threw: \(ctx.exception?.toString() ?? "")")

        // Half one: the withheld image did not stall the re-fit. Pre-`v1.7.8`
        // parity — with a shared predicate this request is never posted and the
        // message keeps its horizontal overflow until the device is rotated.
        #expect(ctx.evaluateScript("refitRequests()")?.toInt32() == 1,
                "the width re-fit must not wait on an image that will never load")
        // Half two: the census did NOT publish, because an armed image has
        // reached no terminal state. This is IOS-UI-004, preserved on purpose.
        #expect(failureReports(ctx) == 0,
                "the census must still wait for every armed image to settle")

        // The exclusion is keyed to the mark `swap()` writes, not to a second
        // copy of the visibility predicate — one source of truth for "withheld".
        let js = _postImageWidthRecheckJS
        #expect(js.contains("data-tmwithheld"),
                "the width arm must key off the mark, not re-derive visibility")

        // And the producer of that mark sets AND clears it, so the attribute
        // records the current verdict rather than a historical one: an image
        // that becomes visible between the two swap arms must still be swapped.
        let deferJS = _deferredImageLoadJS(diagnosticsEnabled: false)
        #expect(deferJS.contains("setAttribute('data-tmwithheld'"),
                "swap() must mark a withheld image")
        #expect(deferJS.contains("removeAttribute('data-tmwithheld')"),
                "swap() must clear the mark when an image is no longer withheld")
    }

    // MARK: - Width-strip pass includes <hr> (OWA quoted-content separator)

    /// Minimal DOM stub for the width-strip pass only (line ~2862): a single
    /// fixed-width `<hr>` — modeling Outlook/OWA's quoted-content separator
    /// `<hr class="_qc_B" style="width: 1457.4px;">` — is the ONLY oversized
    /// element; everything else in the (mocked) body already fits the device
    /// width. Unlike widthPipelineHarness's stubs, `document.body.querySelectorAll`
    /// here actually parses the selector's comma-separated tag list and only
    /// returns elements whose tag is in it — so this harness is selector-
    /// faithful and the resulting test FAILS against the pre-fix
    /// `'div,p,section'` selector (the hr is never returned, never stripped).
    /// `hr.getBoundingClientRect()` reports the sender's hard pixel width
    /// until the strip sets `width:auto`, at which point it reports the
    /// container width — mirroring real WebKit layout of an unconstrained
    /// `<hr>`.
    private func makeHrStripContext(deviceWidth: Int = 288) -> JSContext {
        let ctx = JSContext()!
        ctx.evaluateScript("""
        var DEVICE_W = \(deviceWidth);
        var _vw = DEVICE_W;
        var _msgs = [];
        var hrStripped = false;
        var hrWidthCalls = [];
        function _baseEl(tag, cls) {
            var el = {
                tagName: tag, className: cls || '', innerText: '', outerHTML: '<' + tag.toLowerCase() + '>',
                parentElement: null, complete: true, _attrs: {},
                getAttribute: function (k) { return (k in el._attrs) ? el._attrs[k] : null; },
                setAttribute: function (k, v) { el._attrs[k] = v; },
                hasAttribute: function (k) { return (k in el._attrs); },
                querySelectorAll: function () { return []; }
            };
            el.style = {
                setProperty: function (k, v, p) {
                    if (el.tagName === 'HR' && k === 'width') { hrWidthCalls.push(v); if (v === 'auto') hrStripped = true; }
                },
                getPropertyValue: function () { return ''; },
                getPropertyPriority: function () { return ''; },
                removeProperty: function () {}
            };
            return el;
        }
        // The OWA quoted-content separator: a hard-coded pixel width baked in
        // from the sender's desktop window, far wider than the phone
        // viewport (logmain.log 2026-07-07: w=1459, style="width: 1457.4px").
        var hr = _baseEl('HR', '_qc_B');
        hr._attrs['style'] = 'width: 1457.4px;';
        hr.getBoundingClientRect = function () {
            if (hrStripped) return { left: 0, right: _vw, width: _vw, height: 2 };
            return { left: 0, right: 1457, width: 1457, height: 2 };
        };
        var _all = [hr];
        var _meta = {
            _content: 'width=device-width, initial-scale=1, maximum-scale=5, user-scalable=yes',
            getAttribute: function (k) { return _meta._content; },
            setAttribute: function (k, v) {
                _meta._content = v;
                var m = v.match(/width=(device-width|\\d+)/);
                if (m) _vw = (m[1] === 'device-width') ? DEVICE_W : parseInt(m[1], 10);
            }
        };
        var document = {
            readyState: 'complete',
            documentElement: { offsetHeight: 100, style: { setProperty: function () {} } },
            querySelector: function (s) { return s.indexOf('meta') >= 0 ? _meta : null; },
            body: {
                scrollHeight: 300,
                style: { setProperty: function () {} },
                getBoundingClientRect: function () { return { left: 0, right: _vw, width: _vw, height: 300 }; },
                getElementsByTagName: function (t) { return t === 'img' ? [] : _all.slice(); },
                // Selector-faithful (unlike widthPipelineHarness's fixed-array
                // stubs): splits on ',' and matches by tag, exercising the
                // EXACT selector string fitViewportJS passes.
                querySelectorAll: function (sel) {
                    var tags = sel.split(',').map(function (s) { return s.trim().toUpperCase(); });
                    return _all.filter(function (el) { return tags.indexOf(el.tagName) >= 0; });
                }
            }
        };
        var window = {
            innerWidth: DEVICE_W, innerHeight: 800, devicePixelRatio: 3,
            screen: { width: DEVICE_W },
            addEventListener: function () {},
            getComputedStyle: function () { return { width: '', height: '', maxWidth: '' }; },
            webkit: { messageHandlers: {
                consoleLog: { postMessage: function (s) {} },
                heightChanged: { postMessage: function (m) { _msgs.push(m); } }
            } }
        };
        function requestAnimationFrame(fn) { fn(); }
        function setTimeout(fn, t) { fn(); }
        """)
        #expect(ctx.exception == nil, "harness threw: \(ctx.exception?.toString() ?? "")")
        return ctx
    }

    @Test("fitViewportJS strips a fixed-width <hr> — the sole overflowing element — and stays at 1.0x (OWA quoted-content separator)")
    func fitViewportStripsOversizedHrAndSkipsWiden() {
        // Content that fits the device width except one <hr> carrying a
        // sender-side fixed pixel width. Before the fix, the width-strip
        // pass's selector ('div,p,section') never touched <hr>, so
        // measureMaxRight() saw a genuine 1457px culprit and widened the
        // layout viewport to the 1200px cap — the whole email rendered at
        // 0.24x scale. After the fix ('div,p,section,hr'), the hr's inline
        // width is stripped to `auto` before measurement, so no overflow
        // remains and fitViewportJS never widens.
        let ctx = makeHrStripContext()
        ctx.evaluateScript("window.__tmDeviceWidth = 288;" + _fitViewportJS)
        #expect(ctx.exception == nil, "fit threw: \(ctx.exception?.toString() ?? "")")

        // The strip pass actually targeted the hr — this is exactly what the
        // pre-fix selector misses (hr never appears in the querySelectorAll
        // result), so this assertion alone fails without the fix.
        #expect(ctx.evaluateScript("hrStripped")?.toBool() == true)
        let widthCalls = ctx.evaluateScript("hrWidthCalls.join(',')")?.toString() ?? ""
        #expect(widthCalls.contains("auto"))

        // No overflow remains once the hr is content-driven — fitViewportJS
        // must stay at 1.0x: no widened viewport stamped, meta left at
        // device-width. (Pre-fix, this would be 1200 / "width=1200".)
        #expect(layoutVp(ctx) == 0)
        let metaContent = ctx.evaluateScript("_meta._content")?.toString() ?? ""
        #expect(metaContent.contains("device-width"))
    }

    @Test("eatGutterMarginsJS measures the email's inset and posts a reduced gutter (min-indent, no content fiddle)")
    func eatGutterMeasuresAndPostsReducedGutter() {
        let js = _eatGutterMarginsJS
        // The 16pt gutter is a MINIMUM that absorbs the email's own inset instead of
        // stacking. Implementation MEASURES the inset and posts the SwiftUI padding
        // to apply (= 16 − inset, clamped) — it must NOT touch the email layout
        // (no body margin/pull), so it can't clip or perturb rendering.
        #expect(js.contains("var GUTTER = 16"))                                   // matches SwiftUI default
        #expect(js.contains("var WIDE = bw * 0.6"))                               // main-column width filter
        #expect(js.contains("if (r.width < WIDE || r.height <= 0) continue"))     // wide text leaves only
        // SYMMETRIC reduction by the smaller side's inset, clamped [0,16] — never
        // lopsided (no flush-on-one-side regression), and overflow → 0 → no change.
        #expect(js.contains("var x = Math.max(0, Math.min(minLeft, minRight, GUTTER))"))
        #expect(js.contains("var pad = GUTTER - x"))
        #expect(js.contains("{ l: pad, r: pad }"))                                // same padding both sides
        #expect(js.contains("messageHandlers.gutterAdjust.postMessage"))          // posts reduced outer gutter to Swift
        // The sender's body/layout is never pulled. Only the dedicated app-owned,
        // body-level invite wrapper receives the measured content inset.
        #expect(js.contains("window.__tmICSDisclosureWrappers || []"))
        #expect(js.contains("bw - WIDE"))
        #expect(!js.contains("document.body.style"))
    }

    @Test("User disclosure toggles atomically tag the height applied by native")
    func disclosureTogglesTagAppliedHeight() {
        let disclosureMark = "window.__tmUserDisclosurePending = true"
        let taggedHeight = "userDisclosure: \(_consumeUserDisclosureExpression)"
        let domToggle = ".classList.toggle('tm-collapsed')"

        func assertEveryClickMarksFirst(_ js: String, expectedClicks: Int) {
            let handlers = js.components(separatedBy: "addEventListener('click'").dropFirst()
            #expect(handlers.count == expectedClicks)
            for handler in handlers {
                let mark = handler.range(of: disclosureMark)
                let toggle = handler.range(of: domToggle)
                #expect(mark != nil)
                #expect(toggle != nil)
                if let mark, let toggle {
                    #expect(mark.lowerBound < toggle.lowerBound)
                }
            }
            #expect(js.components(separatedBy: taggedHeight).count - 1 == expectedClicks)
        }

        assertEveryClickMarksFirst(_collapseQuotesJS, expectedClicks: 2)
        assertEveryClickMarksFirst(_collapseICSJS, expectedClicks: 1)
        #expect(_monitorHeightJS.contains(taggedHeight))
        #expect(_fitViewportJS.contains(taggedHeight))
        #expect(_userDisclosureOwnershipJS.contains("window.__tmUserDisclosurePending = false"))
        #expect(_userDisclosureOwnershipJS.contains("window.__tmConsumeUserDisclosure = function()"))
        #expect(_postDisclosureHeightJS.contains("vp: tmVp"))
        #expect(_postDisclosureHeightJS.contains("scroll: tmScroll"))
        #expect(_postDisclosureHeightJS.contains("rect: tmRect"))
        #expect(!_renderBridgeChannels.contains("userDisclosureToggle"),
                "disclosure must travel in the height payload, not race it on a separate channel")

        let stickyHeight = "userDisclosure: window.__tmUserDisclosurePending === true"
        #expect(!_collapseQuotesJS.contains(stickyHeight))
        #expect(!_collapseICSJS.contains(stickyHeight))
        #expect(!_monitorHeightJS.contains(stickyHeight))
        #expect(!_fitViewportJS.contains(stickyHeight))

        let ctx = JSContext()!
        ctx.evaluateScript("var window = this; \(_userDisclosureOwnershipJS)")
        ctx.evaluateScript("window.__tmUserDisclosurePending = true")
        #expect(ctx.evaluateScript("window.__tmConsumeUserDisclosure()")?.toBool() == true)
        #expect(ctx.evaluateScript("window.__tmConsumeUserDisclosure()")?.toBool() == false,
                "only the first height after a tap may claim disclosure ownership")
        ctx.evaluateScript("window.__tmConsumeUserDisclosure = undefined")
        #expect(ctx.evaluateScript(_consumeUserDisclosureExpression)?.toBool() == false,
                "a missing disclosure helper must fail soft instead of dropping the height post")
    }

    @Test("Body-level invite disclosure aligns to the measured email content inset")
    func inviteDisclosureAlignsToEmailInset() {
        #expect(_collapseICSJS.contains("tm-ics-wrapper"))
        #expect(_collapseICSJS.contains("window.__tmICSDisclosureWrappers = ownedWrappers"))
        #expect(_collapseICSJS.contains("ownedWrappers.push(wrapper)"))
        #expect(!_alignBodyLevelDisclosureJS.contains("querySelectorAll"))

        let ctx = JSContext()!
        ctx.evaluateScript("""
        var ownedApplied = {};
        var spoofedApplied = {};
        var ownedWrapper = { style: { setProperty: function(name, value, priority) {
            ownedApplied[name] = value + '|' + priority;
        } } };
        var spoofedClassWrapper = { style: { setProperty: function(name, value, priority) {
            spoofedApplied[name] = value + '|' + priority;
        } } };
        \(_alignBodyLevelDisclosureJS)
        alignBodyLevelDisclosure([ownedWrapper], 24, 12, 160);
        """)
        #expect(ctx.exception == nil, "alignment JS threw: \(ctx.exception?.toString() ?? "")")
        #expect(ctx.evaluateScript("ownedApplied['margin-left']")?.toString() == "24px|important")
        #expect(ctx.evaluateScript("ownedApplied['margin-right']")?.toString() == "12px|important")
        #expect(ctx.evaluateScript("spoofedApplied['margin-left']").isUndefined)

        // A desktop layout that overflows one side must never pull app chrome
        // outside the body with a negative margin.
        ctx.evaluateScript("alignBodyLevelDisclosure([ownedWrapper], -8, 5, 160);")
        #expect(ctx.evaluateScript("ownedApplied['margin-left']")?.toString() == "0px|important")
        #expect(ctx.evaluateScript("ownedApplied['margin-right']")?.toString() == "5px|important")

        // Extreme finite geometry is proportionally bounded so left+right never
        // consumes more than the space outside the 60%-wide main-column floor.
        ctx.evaluateScript("alignBodyLevelDisclosure([ownedWrapper], 1000, 1000, 40);")
        #expect(ctx.evaluateScript("ownedApplied['margin-left']")?.toString() == "20px|important")
        #expect(ctx.evaluateScript("ownedApplied['margin-right']")?.toString() == "20px|important")
    }

    @Test("fixDarkModeColorsJS dims only LIGHT LOW-SATURATION text fills — preserves textless + saturated colors")
    func darkModeDimScopedToLightLowSatTextFills() {
        let js = _fixDarkModeColorsJS
        // The colored-bg dim normalizes a fill to luminance ~80 so white text on it
        // stays legible. Applied to (a) TEXTLESS decorations (accent bars) or (b)
        // DELIBERATE SATURATED colors (score badges/chips/buttons), it collapses
        // sender color-coding: Scholar's score bars AND badges (#C14600 vs #E57C4F)
        // both flattened to lum~80. So the dim is gated on text AND low saturation;
        // textless and saturated colors keep their hue (text contrast handled by the
        // safety net).
        #expect(js.contains("var elHasText = (el.textContent || '')"))
        #expect(js.contains("var saturated = bgS > 100"))
        #expect(js.contains("if (coloredBg && bgL > 80 && elHasText && !saturated)"))
        // Regression guards: neither the bare form nor the text-only form may return.
        #expect(!js.contains("if (coloredBg && bgL > 80) {"))
        #expect(!js.contains("if (coloredBg && bgL > 80 && elHasText) {"))
    }

    // MARK: - constrainLeftOverflowJS (behavioral, via JSContext + mock DOM)
    //
    // These run the PRODUCTION `constrainLeftOverflowJS` source against a minimal
    // synthetic DOM (positions + computed styles supplied per element), so they
    // exercise the real decision logic — not just its text. Content is generic
    // (no real senders/domains). `applied(key)` returns the inline styles the pass
    // set on the element created with that key. requestAnimationFrame/setTimeout
    // are stubbed to no-ops, so only the synchronous documentEnd pass runs.
    private static let leftFixDomHarness = """
    var _applied = {}, _byKey = {}, _roots = [];
    function _el(tag, o, kids) {
        o = o || {}; kids = kids || [];
        var key = o.key || ('k' + Object.keys(_byKey).length);
        var n = {
            tagName: tag.toUpperCase(), className: o.cls || '', textContent: o.text || '',
            children: kids, parentElement: null, _key: key,
            _comp: { marginLeft: (o.ml || 0) + 'px', textIndent: (o.ti || 0) + 'px',
                     paddingLeft: (o.pl || 0) + 'px', borderLeftWidth: '0px', display: o.disp || 'block' },
            _rect: { left: (o.left || 0), width: (o.w == null ? 200 : o.w), height: (o.h == null ? 20 : o.h) },
            getBoundingClientRect: function () { return this._rect; },
            style: { setProperty: function (k, v, p) { (_applied[key] = _applied[key] || {})[k] = v; } }
        };
        for (var i = 0; i < kids.length; i++) kids[i].parentElement = n;
        _byKey[key] = n; return n;
    }
    function _flatten(node, out) { for (var i = 0; i < node.children.length; i++) { out.push(node.children[i]); _flatten(node.children[i], out); } return out; }
    function _allDesc() { var out = []; for (var i = 0; i < _roots.length; i++) { out.push(_roots[i]); _flatten(_roots[i], out); } return out; }
    var document = { body: {
        getBoundingClientRect: function () { return { left: 0, width: 288, height: 2000 }; },
        getElementsByTagName: function (t) { return _allDesc(); },
        querySelectorAll: function (s) { return _allDesc().filter(function (n) { return n.tagName === 'UL' || n.tagName === 'OL'; }); }
    } };
    var window = { getComputedStyle: function (n) { return n._comp; },
                   webkit: { messageHandlers: { consoleLog: { postMessage: function () {} } } } };
    function requestAnimationFrame(fn) {}
    function setTimeout(fn, t) {}
    function applied(key) { return _applied[key] || {}; }
    function setBody(roots) { _roots = roots; }
    """

    /// Fresh JSContext with the DOM mock + the tree built by `bodyJS` (which must
    /// call `setBody([...])`), then runs the production left-overflow pass.
    private func runLeftFix(_ bodyJS: String) -> JSContext {
        let ctx = JSContext()!
        ctx.evaluateScript(Self.leftFixDomHarness)
        ctx.evaluateScript(bodyJS)
        ctx.evaluateScript(_constrainLeftOverflowJS)
        #expect(ctx.exception == nil, "left-overflow JS threw: \(ctx.exception?.toString() ?? "")")
        return ctx
    }

    private func appliedValue(_ ctx: JSContext, _ key: String, _ prop: String) -> String? {
        let v = ctx.evaluateScript("applied('\(key)')['\(prop)']")
        return (v?.isUndefined ?? true) ? nil : v?.toString()
    }

    @Test("constrainLeftOverflowJS normalizes a hanging-bullet list to a clean indent")
    func leftFixNormalizesHangingBulletList() {
        // Generic list using the desktop hanging-bullet hack: <li> with negative
        // margin-left + text-indent. Expect the <ul> normalized (sane padding,
        // outside markers, margin 0) and each <li>'s negatives zeroed.
        let ctx = runLeftFix("""
        setBody([ _el('ul', { key: 'list', pl: 8 }, [
            _el('li', { key: 'i1', ml: -47, ti: -17, left: 9, text: 'Item one' }),
            _el('li', { key: 'i2', ml: -47, ti: -17, left: 9, text: 'Item two' })
        ]) ]);
        """)
        #expect(appliedValue(ctx, "list", "padding-left") == "24px")           // marker gutter restored
        #expect(appliedValue(ctx, "list", "margin-left") == "0")
        #expect(appliedValue(ctx, "list", "list-style-position") == "outside")
        for li in ["i1", "i2"] {
            #expect(appliedValue(ctx, li, "margin-left") == "0")
            #expect(appliedValue(ctx, li, "text-indent") == "0")               // no more broken hang
        }
    }

    @Test("constrainLeftOverflowJS zeroes a negative text-indent that spills text past the left edge")
    func leftFixZeroesTextIndentSpill() {
        // A block whose BOX fits (left = 0) but whose small negative text-indent
        // pushes the first line's text left of the body edge (content-left 8 +
        // (-17) = -9 < 0). No inline child, so only the text-indent check catches it.
        let ctx = runLeftFix("""
        setBody([ _el('p', { key: 'foot', pl: 8, ti: -17, left: 0, text: 'Help topics' }) ]);
        """)
        #expect(appliedValue(ctx, "foot", "text-indent") == "0")
    }

    @Test("constrainLeftOverflowJS leaves image-replacement text-indent (huge negative) alone")
    func leftFixIgnoresImageReplacementTextIndent() {
        // text-indent:-9999px is the classic "hide text, show background image"
        // trick — zeroing it would reveal hidden label text. Must be excluded.
        let ctx = runLeftFix("""
        setBody([ _el('span', { key: 'hidden', ti: -9999, left: 0, text: 'Logo label' }) ]);
        """)
        #expect(appliedValue(ctx, "hidden", "text-indent") == nil)             // untouched
    }

    @Test("constrainLeftOverflowJS walks ancestors to zero a box-overflowing negative margin")
    func leftFixWalksAncestorsForBoxOverflow() {
        // A non-list block whose own box overflows the left edge via a negative
        // margin (an inline child rides along). The pass walks up from the child
        // and zeroes the block's negative margin-left.
        let ctx = runLeftFix("""
        setBody([ _el('div', { key: 'wrap', ml: -20, left: -8 }, [
            _el('a', { key: 'link', left: -8, text: 'A link' })
        ]) ]);
        """)
        #expect(appliedValue(ctx, "wrap", "margin-left") == "0")
    }

    @Test("constrainLeftOverflowJS leaves well-formed content untouched")
    func leftFixLeavesWellFormedContentAlone() {
        // A normal list (no negative offsets) and normal paragraph — nothing
        // overflows or spills, so the pass must not mutate anything.
        let ctx = runLeftFix("""
        setBody([
            _el('ul', { key: 'ok-list', pl: 40 }, [ _el('li', { key: 'ok-li', left: 40, text: 'Fine' }) ]),
            _el('p', { key: 'ok-p', left: 16, text: 'Fine paragraph' })
        ]);
        """)
        #expect(appliedValue(ctx, "ok-list", "padding-left") == nil)
        #expect(appliedValue(ctx, "ok-list", "list-style-position") == nil)
        #expect(appliedValue(ctx, "ok-li", "text-indent") == nil)
        #expect(appliedValue(ctx, "ok-p", "text-indent") == nil)
    }

    // MARK: - normalizeIndentJS (behavioral, via JSContext + mock DOM)
    //
    // These run the PRODUCTION `normalizeIndentJS` source against a minimal
    // synthetic DOM — the same zero-drift pattern as `runLeftFix` above. Direct
    // text is modeled as a REAL text node (nodeType 3) linked via
    // firstChild/nextSibling so `hasDirectText`'s walk exercises the actual
    // production code path, not a stand-in. `applied(key)` / `priorityOf(key,
    // prop)` return what the pass set via `style.setProperty`; `attrOf(key)`
    // returns the `data-tm-indentcrop` marker set via `setAttribute`. Body width
    // is fixed at 288 (matches the other harnesses' device viewport), so
    // WIDE = 172.8 — every element below defaults to rect width 250 (a "wide"
    // text leaf) unless overridden. Content is generic (no real senders/domains).
    private static let indentCropDomHarness = """
    var _applied = {}, _appliedPriority = {}, _byKey = {}, _roots = [];
    function _txtNode(text) { return { nodeType: 3, textContent: text }; }
    function _el(tag, o, kids) {
        o = o || {}; kids = kids || [];
        var key = o.key || ('k' + Object.keys(_byKey).length);
        var chain = [];
        if (o.text !== undefined) chain.push(_txtNode(o.text));
        for (var i = 0; i < kids.length; i++) chain.push(kids[i]);
        for (var j = 0; j < chain.length; j++) chain[j].nextSibling = (j + 1 < chain.length) ? chain[j + 1] : null;
        var n = {
            tagName: tag.toUpperCase(), className: o.cls || '', children: kids,
            firstChild: chain.length ? chain[0] : null, parentElement: null, _attrs: {},
            _comp: { marginLeft: (o.ml || 0) + 'px', marginRight: (o.mr != null ? o.mr : 0) + 'px', direction: o.dir || 'ltr' },
            _rect: { left: (o.left || 0), width: (o.w == null ? 250 : o.w), height: (o.h == null ? 20 : o.h) },
            getBoundingClientRect: function () { return this._rect; },
            setAttribute: function (k, v) { n._attrs[k] = v; },
            getAttribute: function (k) { return (k in n._attrs) ? n._attrs[k] : null; },
            style: { setProperty: function (k, v, p) {
                (_applied[key] = _applied[key] || {})[k] = v;
                (_appliedPriority[key] = _appliedPriority[key] || {})[k] = p;
            } }
        };
        for (var m = 0; m < kids.length; m++) kids[m].parentElement = n;
        _byKey[key] = n; return n;
    }
    function _flatten(node, out) { for (var i = 0; i < node.children.length; i++) { out.push(node.children[i]); _flatten(node.children[i], out); } return out; }
    function _allDesc() { var out = []; for (var i = 0; i < _roots.length; i++) { out.push(_roots[i]); _flatten(_roots[i], out); } return out; }
    var document = { body: {
        getBoundingClientRect: function () { return { left: 0, width: 288, height: 2000 }; },
        getElementsByTagName: function (t) { return _allDesc(); }
    } };
    var window = {
        getComputedStyle: function (el) { return (el === document.body) ? { direction: 'ltr' } : el._comp; },
        webkit: { messageHandlers: { consoleLog: { postMessage: function () {} } } }
    };
    function applied(key) { return _applied[key] || {}; }
    function priorityOf(key, prop) { return (_appliedPriority[key] || {})[prop]; }
    function attrOf(key) { return _byKey[key]._attrs; }
    function setBody(roots) { _roots = roots; for (var i = 0; i < roots.length; i++) roots[i].parentElement = document.body; }
    """

    /// Fresh JSContext with the DOM mock + the tree built by `bodyJS` (which must
    /// call `setBody([...])`), then runs the production per-region indent-crop
    /// pass. Mirrors `runLeftFix`.
    private func runIndentCrop(_ bodyJS: String) -> JSContext {
        let ctx = JSContext()!
        ctx.evaluateScript(Self.indentCropDomHarness)
        ctx.evaluateScript(bodyJS)
        ctx.evaluateScript(_normalizeIndentJS)
        #expect(ctx.exception == nil, "indent-crop JS threw: \(ctx.exception?.toString() ?? "")")
        return ctx
    }

    private func attrValue(_ ctx: JSContext, _ key: String, _ attr: String) -> String? {
        let v = ctx.evaluateScript("attrOf('\(key)')['\(attr)']")
        return (v?.isUndefined ?? true) ? nil : v?.toString()
    }

    private func appliedPriority(_ ctx: JSContext, _ key: String, _ prop: String) -> String? {
        let v = ctx.evaluateScript("priorityOf('\(key)', '\(prop)')")
        return (v?.isUndefined ?? true) ? nil : v?.toString()
    }

    @Test("normalizeIndentJS crops a uniform OWA-style whole-column indent to 0 — the full-width footer at inset 0 stays untouched")
    func indentCropCropsUniformOwaIndent() {
        // The OWA idiom: every main-content block carries margin: 0px 0px 16px
        // 40px, but a mailing-list footer sits at inset 0 — the exact shape that
        // defeats eatGutterMarginsJS's global min-inset measurement (its min
        // pins to the footer's 0, so it correctly does nothing). Per-region
        // cropping fixes this: all three indented paragraphs collapse to 0
        // (dominance share 3/4 = 0.75), the footer is never touched.
        let ctx = runIndentCrop("""
        setBody([
            _el('p', { key: 'p1', ml: 40, text: 'First paragraph of the message body with real content.' }),
            _el('p', { key: 'p2', ml: 40, text: 'Second paragraph, indented the OWA way as well.' }),
            _el('p', { key: 'p3', ml: 40, text: 'Third paragraph, same indent as the first two.' }),
            _el('p', { key: 'footer', ml: 0, mr: 0, text: 'Unsubscribe from this mailing list at example.com/unsubscribe.' })
        ]);
        """)
        for key in ["p1", "p2", "p3"] {
            #expect(appliedValue(ctx, key, "margin-left") == "0px")
            #expect(appliedPriority(ctx, key, "margin-left") == "important")
            #expect(attrValue(ctx, key, "data-tm-indentcrop") == "1")
        }
        #expect(appliedValue(ctx, "footer", "margin-left") == nil)
        #expect(attrValue(ctx, "footer", "data-tm-indentcrop") == nil)
    }

    @Test("normalizeIndentJS preserves relative indent deltas — 40px/80px carriers become 0px/40px")
    func indentCropPreservesRelativeDeltas() {
        // Crop is a SHIFT (subtract the tightest bounding inset), not a flatten
        // to zero — a mixed-depth email keeps its intentional relative nesting.
        let ctx = runIndentCrop("""
        setBody([
            _el('p', { key: 'shallow', ml: 40, text: 'Shallow indented paragraph with real content.' }),
            _el('p', { key: 'deep', ml: 80, text: 'Deeply indented paragraph with real content too.' })
        ]);
        """)
        #expect(appliedValue(ctx, "shallow", "margin-left") == "0px")
        #expect(appliedValue(ctx, "deep", "margin-left") == "40px")
    }

    @Test("normalizeIndentJS dominance guard leaves a single indented aside alone among normal paragraphs")
    func indentCropDominanceGuardLeavesMinorityIndentAlone() {
        // Only ONE of five wide text leaves is indented (share 1/5 = 0.2 <
        // DOMINANCE 0.6) — a deliberately indented aside among normal body
        // paragraphs is meaningful indentation, not compose-tool chrome, so
        // nothing is touched.
        let ctx = runIndentCrop("""
        setBody([
            _el('p', { key: 'para1', ml: 0, text: 'Normal paragraph one with regular body text.' }),
            _el('p', { key: 'para2', ml: 0, text: 'Normal paragraph two with regular body text.' }),
            _el('p', { key: 'para3', ml: 0, text: 'Normal paragraph three with regular body text.' }),
            _el('p', { key: 'para4', ml: 0, text: 'Normal paragraph four with regular body text.' }),
            _el('div', { key: 'aside', ml: 40, text: 'A deliberately indented aside, such as a pull quote.' })
        ]);
        """)
        #expect(appliedValue(ctx, "aside", "margin-left") == nil)
        for key in ["para1", "para2", "para3", "para4"] {
            #expect(appliedValue(ctx, key, "margin-left") == nil)
        }
    }

    @Test("normalizeIndentJS excludes centered content (equal left/right margins) from carrier detection")
    func indentCropExcludesCenteredContent() {
        // margin:auto centering produces EQUAL left/right margins — the
        // asymmetry test (margin-left - margin-right >= INDENT_MIN) must reject
        // it even though margin-left alone clears INDENT_MIN. Genuinely
        // asymmetric siblings still get cropped, proving the exclusion is the
        // asymmetry check and not an early bail.
        let ctx = runIndentCrop("""
        setBody([
            _el('table', { key: 'centered', ml: 40, mr: 40, text: 'A centered table using margin:auto styling.' }),
            _el('p', { key: 'p1', ml: 40, text: 'An indented paragraph carrying real content.' }),
            _el('p', { key: 'p2', ml: 40, text: 'Another indented paragraph, same indent as above.' })
        ]);
        """)
        #expect(appliedValue(ctx, "centered", "margin-left") == nil)
        #expect(appliedValue(ctx, "p1", "margin-left") == "0px")
        #expect(appliedValue(ctx, "p2", "margin-left") == "0px")
    }

    @Test("normalizeIndentJS leaves BLOCKQUOTE and UL/OL/LI margins untouched (owned by other passes)")
    func indentCropExcludesBlockquoteAndLists() {
        // BLOCKQUOTE is real quote semantics (owned by the quote-collapse pass);
        // UL/OL/LI list geometry belongs to constrainLeftOverflowJS. Both are
        // excluded from carrier candidacy regardless of their margin-left. Four
        // genuinely indented paragraphs keep dominance above threshold so the
        // exclusion is proven structural, not an incidental dominance bail.
        let ctx = runIndentCrop("""
        setBody([
            _el('blockquote', { key: 'quote', ml: 40, text: 'A genuinely quoted reply, indented on purpose.' }),
            _el('ul', { key: 'list', ml: 40 }, [ _el('li', { key: 'item', ml: 40, text: 'A list item with a large indent.' }) ]),
            _el('p', { key: 'p1', ml: 40, text: 'Indented paragraph one carrying real content.' }),
            _el('p', { key: 'p2', ml: 40, text: 'Indented paragraph two carrying real content.' }),
            _el('p', { key: 'p3', ml: 40, text: 'Indented paragraph three carrying real content.' }),
            _el('p', { key: 'p4', ml: 40, text: 'Indented paragraph four carrying real content.' })
        ]);
        """)
        #expect(appliedValue(ctx, "quote", "margin-left") == nil)
        #expect(appliedValue(ctx, "list", "margin-left") == nil)
        #expect(appliedValue(ctx, "item", "margin-left") == nil)
        for key in ["p1", "p2", "p3", "p4"] {
            #expect(appliedValue(ctx, key, "margin-left") == "0px")
        }
    }

    @Test("normalizeIndentJS crops only the OUTERMOST carrier when one is nested inside another")
    func indentCropCropsOutermostOnly() {
        // A 40px carrier nested inside another 40px carrier: only the outer one
        // is cropped (its wide-text-leaf qualification comes from the nested
        // paragraph's content) — the inner carrier is left with its own margin
        // untouched, preserving its delta relative to the (now-zeroed) outer.
        let ctx = runIndentCrop("""
        setBody([
            _el('div', { key: 'outer', ml: 40, w: 260 }, [
                _el('p', { key: 'inner', ml: 40, text: 'A nested indented paragraph inside an indented wrapper.' })
            ]),
            _el('p', { key: 'p2', ml: 40, text: 'A sibling indented paragraph with its own direct text.' })
        ]);
        """)
        #expect(appliedValue(ctx, "outer", "margin-left") == "0px")
        #expect(appliedValue(ctx, "inner", "margin-left") == nil)
        #expect(appliedValue(ctx, "p2", "margin-left") == "0px")
    }

    @Test("fixDarkModeColorsJS makes the outermost near-white surface a darker panel (not erased)")
    func darkModeNearWhitePanelDarkening() {
        let js = _fixDarkModeColorsJS
        // White paper panels were being erased (nearWhite → transparent → blends
        // into the card). The OUTERMOST near-white surface now gets a translucent
        // black overlay so it reads as a panel darker than its surroundings; nested
        // near-whites stay transparent so overlays don't stack into mud.
        #expect(js.contains("data-tm-panel"))
        #expect(js.contains("el.parentElement.closest('[data-tm-panel]')"))
        #expect(js.contains("rgba(0,0,0,0.22)"))
    }

    @Test("fitViewportJS overflow measurement excludes not-yet-loaded images (layer 2 upstream fix)")
    func fitViewportHidesUnloadedImagesForMeasurement() {
        let js = _fitViewportJS
        // UPSTREAM fix for the Scholar-Inbox runaway: a deferred (data-tmsrc, src
        // stripped for first paint) or still-loading <img> has unreliable extent
        // and, with width:auto, can balloon far past its container — a phantom
        // overflow that makes fitViewportJS widen. measureMaxRight must hide such
        // images (so their — and their inline <a> wrapper's — bogus extent is
        // excluded), measure, then RESTORE (no lasting mutation). Once loaded,
        // img{max-width:100%} clamps them, so they never need to drive a widen.
        //
        // Scope invariant: keyed on data-tmsrc (deferred imgs are complete===true,
        // no src — the reverted `!complete`-only guard skipped 0 of them) PLUS
        // !complete for in-flight loads. NEVER naturalWidth===0, which would also
        // hide a loaded intrinsic-size-less SVG and wrongly drop its real width.
        #expect(js.contains("hm.hasAttribute('data-tmsrc')"))
        #expect(js.contains("!hm.complete"))
        #expect(js.contains("hm.style.setProperty('display', 'none', 'important')"))
        // Restored after measuring — measurement-time only, no lasting layout change.
        // Faithful restore preserves the original value AND priority (captured via
        // getPropertyPriority) so an enforceMediaDisplayJS `!important` survives.
        #expect(js.contains("getPropertyPriority('display')"))
        #expect(js.contains("rEl.style.removeProperty('display')"))
        // The hide/measure/restore lives INSIDE measureMaxRight, so the loop's
        // re-measures are guarded too (not just the first measurement).
        guard let fnIdx = js.range(of: "function measureMaxRight()")?.lowerBound,
              let hideIdx = js.range(of: "hm.hasAttribute('data-tmsrc')")?.lowerBound,
              let retIdx = js.range(of: "return { maxRight: mr, culprit: cp, culpritWidth: cw };")?.lowerBound else {
            Issue.record("expected the image-hide guard to live inside measureMaxRight")
            return
        }
        #expect(fnIdx < hideIdx && hideIdx < retIdx)
    }

    // MARK: - fixDarkModeColorsJS PAGE_DOMINANCE pre-pass (behavioral, via JSContext + mock DOM)
    //
    // These run the PRODUCTION `fixDarkModeColorsJS` source against a minimal
    // synthetic DOM — the same zero-drift pattern as `runLeftFix`/`runIndentCrop`
    // above. Elements are flat siblings of a stubbed `document.body` (no nesting
    // needed for these scenarios); `textContent`/`innerText` are plain strings
    // (no text-node walk in this script, unlike normalizeIndentJS). `applied(key)`
    // / `attrOf(key)` are the SAME helper names/shapes used by the indent-crop
    // harness, so the existing `appliedValue`/`attrValue` Swift helpers work
    // unchanged. Content is generic (no real senders/domains).
    private static let darkModeDomHarness = """
    var _applied = {}, _appliedPriority = {}, _byKey = {}, _roots = [];
    function _el(tag, o) {
        o = o || {};
        var key = o.key || ('k' + Object.keys(_byKey).length);
        var n = {
            tagName: tag.toUpperCase(), className: o.cls || '', textContent: o.text || '', innerText: o.text || '',
            parentElement: null, _attrs: {},
            _comp: {
                backgroundColor: o.bg || 'rgba(0, 0, 0, 0)',
                color: o.color || 'rgb(0,0,0)',
                borderTopWidth: (o.border ? '1px' : '0px'), borderRightWidth: (o.border ? '1px' : '0px'),
                borderBottomWidth: (o.border ? '1px' : '0px'), borderLeftWidth: (o.border ? '1px' : '0px'),
                borderTopLeftRadius: '0px', boxShadow: 'none'
            },
            _rect: { width: (o.w == null ? 288 : o.w), height: (o.h == null ? 20 : o.h) },
            getBoundingClientRect: function () { return this._rect; },
            getAttribute: function (k) { return (k in n._attrs) ? n._attrs[k] : null; },
            setAttribute: function (k, v) { n._attrs[k] = v; },
            hasAttribute: function (k) { return (k in n._attrs); },
            removeAttribute: function (k) { delete n._attrs[k]; },
            querySelectorAll: function () { return []; },
            closest: function (sel) {
                var cur = this;
                while (cur) {
                    if (sel === 'a' && cur.tagName === 'A') return cur;
                    if (sel === '[data-tm-panel]' && cur._attrs && ('data-tm-panel' in cur._attrs)) return cur;
                    cur = cur.parentElement;
                }
                return null;
            },
            style: { background: '', setProperty: function (k, v, p) {
                (_applied[key] = _applied[key] || {})[k] = v;
                (_appliedPriority[key] = _appliedPriority[key] || {})[k] = p;
            } }
        };
        _byKey[key] = n; return n;
    }
    var _bodyRect = { width: 288, height: 1000 };
    var _body = {
        tagName: 'BODY', className: '', _attrs: {},
        _comp: { backgroundColor: 'rgba(0, 0, 0, 0)', color: 'rgb(0,0,0)', borderTopWidth: '0px', borderRightWidth: '0px',
                 borderBottomWidth: '0px', borderLeftWidth: '0px', borderTopLeftRadius: '0px', boxShadow: 'none' },
        getBoundingClientRect: function () { return _bodyRect; },
        getAttribute: function (k) { return (k in _body._attrs) ? _body._attrs[k] : null; },
        setAttribute: function (k, v) { _body._attrs[k] = v; },
        hasAttribute: function (k) { return (k in _body._attrs); },
        removeAttribute: function (k) { delete _body._attrs[k]; },
        closest: function () { return null; },
        style: { background: '', setProperty: function () {} }
    };
    function setBodyRect(w, h) { _bodyRect = { width: w, height: h }; }
    function setBody(elements) {
        _roots = elements;
        for (var i = 0; i < elements.length; i++) elements[i].parentElement = _body;
    }
    var document = {
        body: _body,
        querySelectorAll: function () { return [_body].concat(_roots); }
    };
    var window = {
        matchMedia: function () { return { matches: true }; },
        getComputedStyle: function (el) { return el._comp; },
        webkit: { messageHandlers: { consoleLog: { postMessage: function () {} } } }
    };
    function applied(key) { return _applied[key] || {}; }
    function attrOf(key) { return _byKey[key]._attrs; }
    """

    /// Fresh JSContext with the DOM mock + the tree built by `bodyJS` (which must
    /// call `setBodyRect(w, h)` then `setBody([...])`), then runs the production
    /// `fixDarkModeColorsJS` pass. Mirrors `runLeftFix`/`runIndentCrop`.
    private func runDarkMode(_ bodyJS: String) -> JSContext {
        let ctx = JSContext()!
        ctx.evaluateScript(Self.darkModeDomHarness)
        ctx.evaluateScript(bodyJS)
        ctx.evaluateScript(_fixDarkModeColorsJS)
        #expect(ctx.exception == nil, "dark mode JS threw: \(ctx.exception?.toString() ?? "")")
        return ctx
    }

    @Test("fixDarkModeColorsJS PAGE_DOMINANCE: chrome-less near-white blocks covering most of the body all go transparent, none becomes a panel")
    func darkModePageColorModeMakesChromelessBlocksTransparent() {
        // A cloud-console notification bakes background-color: rgb(250,250,248)
        // inline on every paragraph/heading (logmain.log 2026-07-07) — no shared
        // wrapper carries the page color, so each block is independently
        // "outermost". Before the fix each got its own sunken-panel overlay (103
        // hits); after the fix the dominance pre-pass recognizes this as the
        // email's PAGE color and every chrome-less block goes transparent instead.
        let ctx = runDarkMode("""
        setBodyRect(288, 1000);
        setBody([
            _el('p', { key: 'p1', bg: 'rgb(250,250,248)', w: 288, h: 180, text: 'First paragraph of a notification email.' }),
            _el('p', { key: 'p2', bg: 'rgb(250,250,248)', w: 288, h: 180, text: 'Second paragraph, same inline background.' }),
            _el('h2', { key: 'h1', bg: 'rgb(250,250,248)', w: 288, h: 180, text: 'A heading, also carrying the page background.' }),
            _el('p', { key: 'p3', bg: 'rgb(250,250,248)', w: 288, h: 180, text: 'Third paragraph, still the page color.' }),
            _el('p', { key: 'p4', bg: 'rgb(250,250,248)', w: 288, h: 180, text: 'Fourth paragraph, still the page color.' })
        ]);
        """)
        for key in ["p1", "p2", "h1", "p3", "p4"] {
            #expect(appliedValue(ctx, key, "background-color") == "transparent")
            #expect(attrValue(ctx, key, "data-tm-panel") == nil)
        }
    }

    @Test("fixDarkModeColorsJS PAGE_DOMINANCE regression guard: a single bounded near-white panel below the dominance threshold still gets the sunken-panel treatment")
    func darkModeMinorityPanelStaysPanelized() {
        // Scholar-style case: ONE bright paper card covering a minority of the
        // body area. Dominance share stays well under 0.6, so pageColorMode is
        // false and the pre-existing outermost-near-white → panel behavior is
        // unchanged (darkModeNearWhitePanelDarkening covers the same treatment
        // at the string level; this exercises it behaviorally end-to-end).
        let ctx = runDarkMode("""
        setBodyRect(288, 1000);
        setBody([
            _el('div', { key: 'card', bg: 'rgb(255,255,255)', w: 200, h: 100, text: 'A single bright paper-style citation card.' })
        ]);
        """)
        #expect(appliedValue(ctx, "card", "background-color") == "rgba(0,0,0,0.22)")
        #expect(attrValue(ctx, "card", "data-tm-panel") == "1")
    }

    @Test("fixDarkModeColorsJS PAGE_DOMINANCE: a bordered/chrome near-white box stays panelized even inside page-color mode")
    func darkModeChromeBoxStaysPanelizedInPageColorMode() {
        // Four page-color paragraphs trip pageColorMode on their own (share
        // 0.72 >= 0.6). A fifth near-white element carries a border (chrome) —
        // a deliberate card/callout, e.g. an "Important" note — and must stay
        // panelized regardless of the page-color regime: chrome boxes are
        // excluded from the dominance measurement (never "page color") and
        // always fall through to the panel treatment.
        let ctx = runDarkMode("""
        setBodyRect(288, 1000);
        setBody([
            _el('p', { key: 'p1', bg: 'rgb(250,250,248)', w: 288, h: 180, text: 'First paragraph carrying the page background.' }),
            _el('p', { key: 'p2', bg: 'rgb(250,250,248)', w: 288, h: 180, text: 'Second paragraph, same inline background.' }),
            _el('p', { key: 'p3', bg: 'rgb(250,250,248)', w: 288, h: 180, text: 'Third paragraph, still the page color.' }),
            _el('p', { key: 'p4', bg: 'rgb(250,250,248)', w: 288, h: 180, text: 'Fourth paragraph, still the page color.' }),
            _el('div', { key: 'callout', bg: 'rgb(255,255,255)', border: true, w: 250, h: 80, text: 'A deliberately bordered callout box.' })
        ]);
        """)
        for key in ["p1", "p2", "p3", "p4"] {
            #expect(appliedValue(ctx, key, "background-color") == "transparent")
            #expect(attrValue(ctx, key, "data-tm-panel") == nil)
        }
        #expect(appliedValue(ctx, "callout", "background-color") == "rgba(0,0,0,0.22)")
        #expect(attrValue(ctx, "callout", "data-tm-panel") == "1")
    }

    // MARK: - Clip-aware overflow measurement (author overflow-x ancestor)

    /// Minimal DOM stub for `measureMaxRight()`'s clip-aware ancestor walk: a
    /// 490px-wide TABLE (a cloud-console notification's pricing table,
    /// nowrap cells) sitting inside a DIV.w-full.overflow-auto "scroller"
    /// (286px — the sender's own markdown-render horizontal-pan wrapper,
    /// logmain.log 2026-07-07). `scrollerOverflowX` controls whether
    /// `getComputedStyle(scroller).overflowX` reports a containing value —
    /// nil models a genuine desktop-width email with no clipping ancestor
    /// (the regression guard: must still widen).
    private func makeClipAwareContext(deviceWidth: Int = 288, scrollerOverflowX: String?) -> JSContext {
        let ctx = JSContext()!
        let overflowAssignment = scrollerOverflowX.map { "scroller._overflowX = '\($0)';" } ?? ""
        ctx.evaluateScript("""
        var DEVICE_W = \(deviceWidth);
        var _vw = DEVICE_W;
        var _msgs = [];
        function _baseEl(tag, cls) {
            var el = {
                tagName: tag, className: cls || '', innerText: '', outerHTML: '<' + tag.toLowerCase() + '>',
                parentElement: null, complete: true, _attrs: {}, _overflowX: undefined,
                getAttribute: function (k) { return (k in el._attrs) ? el._attrs[k] : null; },
                setAttribute: function (k, v) { el._attrs[k] = v; },
                hasAttribute: function (k) { return (k in el._attrs); },
                querySelectorAll: function () { return []; }
            };
            el.style = {
                setProperty: function () {},
                getPropertyValue: function () { return ''; },
                getPropertyPriority: function () { return ''; },
                removeProperty: function () {}
            };
            return el;
        }
        // The sender's own horizontal-scroll wrapper (markdown-render table
        // pattern) — fits the 288pt viewport on its own.
        var scroller = _baseEl('DIV', 'w-full overflow-auto');
        scroller.getBoundingClientRect = function () { return { left: 0, right: 286, width: 286, height: 120 }; };
        \(overflowAssignment)
        // The 490px pricing table with nowrap cells, INSIDE the scroller —
        // never widens the page on the web because the scroller clips/pans it.
        var table = _baseEl('TABLE', 'w-max min-w-full');
        table.getBoundingClientRect = function () { return { left: 0, right: 490, width: 490, height: 100 }; };
        table.parentElement = scroller;
        var _all = [scroller, table];
        var _meta = {
            _content: 'width=device-width, initial-scale=1, maximum-scale=5, user-scalable=yes',
            getAttribute: function (k) { return _meta._content; },
            setAttribute: function (k, v) {
                _meta._content = v;
                var m = v.match(/width=(device-width|\\d+)/);
                if (m) _vw = (m[1] === 'device-width') ? DEVICE_W : parseInt(m[1], 10);
            }
        };
        var document = {
            readyState: 'complete',
            documentElement: { offsetHeight: 100, style: { setProperty: function () {} } },
            querySelector: function (s) { return s.indexOf('meta') >= 0 ? _meta : null; },
            body: {
                scrollHeight: 300,
                style: { setProperty: function () {} },
                getBoundingClientRect: function () { return { left: 0, right: _vw, width: _vw, height: 300 }; },
                getElementsByTagName: function (t) { return t === 'img' ? [] : _all.slice(); },
                querySelectorAll: function (sel) {
                    var tags = sel.split(',').map(function (s) { return s.trim().toUpperCase(); });
                    return _all.filter(function (el) { return tags.indexOf(el.tagName) >= 0; });
                }
            }
        };
        var window = {
            innerWidth: DEVICE_W, innerHeight: 800, devicePixelRatio: 3,
            screen: { width: DEVICE_W },
            addEventListener: function () {},
            getComputedStyle: function (el) { return { width: '', height: '', maxWidth: '', overflowX: el._overflowX }; },
            webkit: { messageHandlers: {
                consoleLog: { postMessage: function (s) {} },
                heightChanged: { postMessage: function (m) { _msgs.push(m); } }
            } }
        };
        function requestAnimationFrame(fn) { fn(); }
        function setTimeout(fn, t) { fn(); }
        """)
        #expect(ctx.exception == nil, "harness threw: \(ctx.exception?.toString() ?? "")")
        return ctx
    }

    @Test("measureMaxRight skips a would-be culprit contained by an author overflow-x:auto ancestor — no widen")
    func fitViewportSkipsClippedAncestorOverflow() {
        // cloud-console notification email: 491px pricing table (nowrap cells) inside
        // its own DIV.w-full.overflow-auto scroller (286px) — on the web the
        // table pans inside its box and never widens the page. Pre-fix,
        // measureMaxRight saw the table as the rightmost edge (maxRight=492)
        // and widened to 493px → 0.58x shrink (logmain.log 2026-07-07).
        let ctx = makeClipAwareContext(scrollerOverflowX: "auto")
        ctx.evaluateScript("window.__tmDeviceWidth = 288;" + _fitViewportJS)
        #expect(ctx.exception == nil, "fit threw: \(ctx.exception?.toString() ?? "")")
        // No widen: the clipped table never becomes the measured max, so the
        // scroller (286px, fits) is the only candidate — no overflow.
        #expect(layoutVp(ctx) == 0)
        let metaContent = ctx.evaluateScript("_meta._content")?.toString() ?? ""
        #expect(metaContent.contains("device-width"))
    }

    @Test("measureMaxRight still widens the SAME overflow with no clipping ancestor (regression guard)")
    func fitViewportWidensWithoutClippingAncestor() {
        // Identical geometry to the test above, MINUS the ancestor's
        // overflow-x:auto — this is what a genuine desktop-width email looks
        // like, and it must still trigger the scale-to-fit widen.
        let ctx = makeClipAwareContext(scrollerOverflowX: nil)
        ctx.evaluateScript("window.__tmDeviceWidth = 288;" + _fitViewportJS)
        #expect(ctx.exception == nil, "fit threw: \(ctx.exception?.toString() ?? "")")
        #expect(layoutVp(ctx) == 490)
        let metaContent = ctx.evaluateScript("_meta._content")?.toString() ?? ""
        #expect(metaContent.contains("width=490"))
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
        // The PRODUCTION form — this script is injected unconditionally, so what
        // ships is the ungated one.
        let js = _deferredImageLoadJS(diagnosticsEnabled: false)
        // Restores the real URL automatically, only AFTER a paint cycle (double
        // rAF) so the remote loads can't re-block the first paint. Failsafe timeout.
        #expect(js.contains("img[data-tmsrc]"))
        #expect(js.contains("setAttribute('src'"))
        #expect(js.contains("swap('post-paint')"))
        // Pin the failsafe's actual DELAY, not just its label: the reason string
        // spells "1500ms" but is only a diagnostic tag, so asserting the label
        // alone would stay green if the timeout were retuned to 3000ms.
        #expect(js.contains("setTimeout(function() { swap('failsafe-1500ms'); }, 1500)"))
        // The `__tmImageDiagWillAssign` assertion that used to live here — "the
        // swap notifies the diagnostic hook" — has NOT been dropped: it moved to
        // `deferredImageSwapHookIsDebugGated` below, which pins it on the GATED
        // form (where the hook belongs) and pins its absence here. Asserting it
        // on this form is what the fix makes wrong, not the property itself.
    }

    @Test("the diagnostic hook is emitted ONLY under the debug gate")
    func deferredImageSwapHookIsDebugGated() {
        // `deferredImageLoadJS` is a PRODUCTION render path, injected
        // unconditionally at .atDocumentEnd — unlike `imageLoadDiagnosticJS`,
        // which returns "" when diagnostics are off. So in an ungated build the
        // only party that could define `window.__tmImageDiagWillAssign` is
        // sender-authored script (author JS is still enabled in the message
        // webview). The swap must therefore not name that global at all.
        let production = _deferredImageLoadJS(diagnosticsEnabled: false)
        #expect(!production.contains("__tmImageDiagWillAssign"))
        #expect(!production.contains("diag("))
        // Non-vacuity: it is the HOOK that is gone, not the swap.
        #expect(production.contains("im.setAttribute('src', s)"))
        #expect(production.contains("im.setAttribute('srcset', ss)"))

        // Gated build: the hook is called on both attribute arms, and the
        // installing script (imageLoadDiagnosticJS) defines it.
        let gated = _deferredImageLoadJS(diagnosticsEnabled: true)
        #expect(gated.contains("window.__tmImageDiagWillAssign(im, attribute, raw, trigger)"))
        #expect(gated.contains("diag(im, 'srcset', ss, trigger)"))
        #expect(gated.contains("diag(im, 'src', s, trigger)"))
        #expect(
            _imageLoadDiagnosticJS(enabled: true)
                .contains("Object.defineProperty(window, '__tmImageDiagWillAssign'")
        )
    }

    @Test("a throwing diagnostic hook cannot abort the deferred-image swap")
    func deferredImageSwapSurvivesHostileDiagnosticHook() {
        // BEHAVIOURAL, not string-shaped: the production JS runs in JSContext
        // against the width-pipeline mock DOM, so this asserts the END STATE
        // (every deferred image swapped) rather than the presence of a
        // try/catch. `Object.defineProperty` on `__tmImageDiagId` is the same
        // class of abort — it throws inside OUR hook body — and is covered by
        // the same wrapper.
        let ctx = makeWidthPipelineContext(trueWidth: 515)
        // Give one image a srcset too, so BOTH assignment arms are exercised.
        ctx.evaluateScript("_imgs[0]._attrs['data-tmsrcset'] = 'https://example.com/banner-2x.png 2x';")
        // What a hostile message body can do today: define the global our own
        // swap used to call unguarded. Pre-fix this threw out of swap() before
        // the removeAttribute/setAttribute pair, aborting the loop — so every
        // deferred image on the message stayed hidden, on BOTH the post-paint
        // arm and the 1500ms failsafe.
        ctx.evaluateScript("""
            var _hookCalls = 0;
            window.__tmImageDiagWillAssign = function() { _hookCalls++; throw new Error('hostile'); };
            """)
        ctx.evaluateScript(_deferredImageLoadJS(diagnosticsEnabled: true))
        #expect(ctx.exception == nil, "swap script threw: \(ctx.exception?.toString() ?? "")")

        // The invariant: no deferred attribute survives, and every image now
        // carries the real URL.
        let unswapped = ctx.evaluateScript(
            "_imgs.filter(function (im) { return im.hasAttribute('data-tmsrc') || im.hasAttribute('data-tmsrcset'); }).length"
        )?.toInt32()
        #expect(unswapped == 0)
        let withSrc = ctx.evaluateScript(
            "_imgs.filter(function (im) { return im.getAttribute('src') === 'https://example.com/banner.png'; }).length"
        )?.toInt32()
        #expect(withSrc == 2)
        let withSrcset = ctx.evaluateScript(
            "_imgs.filter(function (im) { return im.getAttribute('srcset') === 'https://example.com/banner-2x.png 2x'; }).length"
        )?.toInt32()
        #expect(withSrcset == 1)
        // Non-vacuity, the half that makes the assertions above mean anything:
        // the hostile hook really did run and really did throw, once per
        // assignment (2 src + 1 srcset). A wrapper that skipped the call
        // entirely would also pass the swap assertions.
        let hookCalls = ctx.evaluateScript("_hookCalls")?.toInt32()
        #expect(hookCalls == 3)
    }

    // MARK: - Deferred swap: no remote fetch from a hidden section (T8)
    //
    // Behavioural, via JSContext + a mock DOM whose `getComputedStyle` reproduces
    // `EmailHTMLWrapper.wrapHTML`'s ACTUAL view-mode cascade rather than a
    // hand-set "hidden" flag — the four `!important` rules for main view and
    // preview mode, plus the `.tm-collapsed .tm-quote-content` quote-collapse
    // rule. Per real CSS, `display:none` on an ancestor does NOT change a
    // descendant's own computed `display`, and the mock models that, because it
    // is exactly what forces the predicate to walk ancestors.
    //
    // `requestAnimationFrame` and `setTimeout` QUEUE here instead of running
    // synchronously (unlike `widthPipelineHarness`), so the post-paint arm and
    // the 1500ms failsafe arm can be driven independently. That separation is
    // the point: a predicate applied at the call sites instead of inside
    // `swap()` would leave the failsafe re-fetching everything the post-paint
    // arm withheld, and a test that only ever fires one arm cannot see it.
    private static func hiddenSectionHarness(
        previewFilename: String?, includeEmlSections: Bool = true,
        includeHeadersProbe: Bool = false
    ) -> String {
        let previewSetup = previewFilename.map {
            "_previewMode = true; _selected = '\($0)'; _bodyClasses = ['tm-preview-mode'];"
        } ?? ""
        let emlSetup = includeEmlSections ? """
            var secA = _append(_body, _mkEl('DIV', 'tm-eml-section'));
            secA._attrs['data-filename'] = 'a.eml';
            var hdrA = _append(secA, _mkEl('DIV', 'tm-eml-headers'));
            _mkImg(_append(secA, _mkEl('DIV', 'tm-email-body')), 'emlA');
            var secB = _append(_body, _mkEl('DIV', 'tm-eml-section'));
            secB._attrs['data-filename'] = 'b.eml';
            _mkImg(_append(secB, _mkEl('DIV', 'tm-email-body')), 'emlB');
            """ : ""
        // Opt-in (it changes every id set and census count, so the existing tests
        // must not inherit it). Two `.tm-eml-headers` nodes that differ ONLY in
        // who authored them and therefore in whose CSS hides them:
        //
        //   `emlHdrA`   — ours, emitted by `EmlMarker.build` INSIDE `secA`,
        //                 hidden in preview by `body.tm-preview-mode
        //                 .tm-eml-headers`.
        //   `senderHdr` — the sender copying our class name, hidden by the
        //                 SENDER's own stylesheet. Nested one level below <body>
        //                 and outside every section, so neither the
        //                 direct-<body>-child arm nor a `.tm-eml-section`
        //                 ancestor can be what decides it: the class arm is the
        //                 only thing in the predicate that could.
        let headersProbe = includeHeadersProbe ? """
            _mkImg(hdrA, 'emlHdrA');
            var senderWrap = _append(_body, _mkEl('DIV', ''));
            var senderHdr = _append(senderWrap, _mkEl('DIV', 'tm-eml-headers'));
            senderHdr._senderHidden = true;
            _mkImg(senderHdr, 'senderHdr');
            """ : ""
        return """
        var _previewMode = false, _selected = null, _bodyClasses = [];
        var _imgs = [], _rafQ = [], _timerQ = [], _logs = [];
        \(previewSetup)
        function _mkEl(tag, classes) {
            var list = (classes || '').split(' ').filter(function (c) { return c.length > 0; });
            var el = {
                tagName: tag, className: classes || '', parentElement: null, _attrs: {},
                classList: { contains: function (c) { return list.indexOf(c) >= 0; } },
                getAttribute: function (k) { return (k in el._attrs) ? el._attrs[k] : null; },
                setAttribute: function (k, v) { el._attrs[k] = v; },
                removeAttribute: function (k) { delete el._attrs[k]; },
                hasAttribute: function (k) { return (k in el._attrs); }
            };
            return el;
        }
        function _append(parent, child) { child.parentElement = parent; return child; }
        function _mkImg(parent, id) {
            var img = _mkEl('IMG', '');
            img._id = id;
            img._attrs['data-tmsrc'] = 'https://example.com/' + id + '.png';
            _append(parent, img);
            _imgs.push(img);
            return img;
        }
        function _hasClass(el, c) { return !!(el && el.classList && el.classList.contains(c)); }
        var _body = _mkEl('BODY', '');
        _body.classList = { contains: function (c) { return _bodyClasses.indexOf(c) >= 0; } };
        // The parent message's own body, and a COLLAPSED quote — the in-document
        // reveal ("Show quoted text") that a general visibility predicate would
        // strand. Both live in every message; the .eml sections do not.
        _mkImg(_append(_body, _mkEl('DIV', 'tm-email-body')), 'parent');
        var quoteWrap = _append(_body, _mkEl('DIV', 'tm-quote-wrapper tm-collapsed'));
        _mkImg(_append(quoteWrap, _mkEl('DIV', 'tm-quote-content')), 'quoted');
        \(emlSetup)
        \(headersProbe)
        // EmailHTMLWrapper.wrapHTML's cascade, per element (NOT inherited).
        function _display(el) {
            if (_previewMode) {
                if (_hasClass(el, 'tm-eml-section')) {
                    return el.getAttribute('data-filename') === _selected ? 'block' : 'none';
                }
                if (el.parentElement === _body) return 'none';   // > *:not(.tm-eml-section)
                if (_hasClass(el, 'tm-eml-headers')) return 'none';
            } else if (_hasClass(el, 'tm-eml-section')) {
                return 'none';
            }
            if (_hasClass(el, 'tm-quote-content') && _hasClass(el.parentElement, 'tm-collapsed')) {
                return 'none';
            }
            // Not one of ours: the SENDER's stylesheet. Last, so an app rule
            // always wins the attribution when both would hide the node.
            if (el._senderHidden) return 'none';
            return 'block';
        }
        var document = {
            readyState: 'complete',
            body: _body,
            querySelectorAll: function (s) {
                return _imgs.filter(function (im) {
                    return im.hasAttribute('data-tmsrc') || im.hasAttribute('data-tmsrcset');
                });
            }
        };
        var window = {
            addEventListener: function () {},
            getComputedStyle: function (el) { return { display: _display(el) }; },
            webkit: { messageHandlers: { consoleLog: { postMessage: function (s) { _logs.push(s); } } } }
        };
        function requestAnimationFrame(fn) { _rafQ.push(fn); }
        function setTimeout(fn, t) { _timerQ.push(fn); }
        // Drains nested rAF (the swap arms a double rAF) without running timers.
        function runPostPaint() {
            var guard = 0;
            while (_rafQ.length && guard++ < 10) {
                var q = _rafQ; _rafQ = [];
                for (var i = 0; i < q.length; i++) q[i]();
            }
        }
        function runFailsafe() {
            var q = _timerQ; _timerQ = [];
            for (var i = 0; i < q.length; i++) q[i]();
        }
        // Ids of images that have been assigned a real URL, and of those still
        // holding a deferred attribute — asserted as SETS so the two halves
        // cannot both be satisfied by an empty swap.
        function fetchedIds() {
            return _imgs.filter(function (im) { return im.hasAttribute('src') || im.hasAttribute('srcset'); })
                        .map(function (im) { return im._id; }).sort().join(',');
        }
        function deferredIds() {
            return _imgs.filter(function (im) { return im.hasAttribute('data-tmsrc') || im.hasAttribute('data-tmsrcset'); })
                        .map(function (im) { return im._id; }).sort().join(',');
        }
        """
    }

    private func makeHiddenSectionContext(
        previewFilename: String? = nil, includeEmlSections: Bool = true,
        includeHeadersProbe: Bool = false
    ) -> JSContext {
        let ctx = JSContext()!
        ctx.evaluateScript(Self.hiddenSectionHarness(
            previewFilename: previewFilename, includeEmlSections: includeEmlSections,
            includeHeadersProbe: includeHeadersProbe))
        #expect(ctx.exception == nil, "harness threw: \(ctx.exception?.toString() ?? "")")
        ctx.evaluateScript(_deferredImageLoadJS(diagnosticsEnabled: false))
        #expect(ctx.exception == nil, "swap script threw: \(ctx.exception?.toString() ?? "")")
        return ctx
    }

    private func fetchedIds(_ ctx: JSContext) -> String {
        ctx.evaluateScript("fetchedIds()")?.toString() ?? "<nil>"
    }

    private func deferredIds(_ ctx: JSContext) -> String {
        ctx.evaluateScript("deferredIds()")?.toString() ?? "<nil>"
    }

    @Test("main view: an attached .eml's images are never fetched, on BOTH swap arms")
    func deferredSwapWithholdsHiddenEmlSectionImages() {
        // The common manifestation of T8 and the one needing no preview sheet at
        // all: `.tm-eml-section { display:none !important }` hides every embedded
        // .eml, but WebKit fetches an <img> regardless — so opening an ordinary
        // message fired the tracking pixels of every .eml attached to it.
        let ctx = makeHiddenSectionContext()

        ctx.evaluateScript("runPostPaint()")
        #expect(ctx.exception == nil, "post-paint threw: \(ctx.exception?.toString() ?? "")")
        // The invariant, both directions at once: the parent body and the
        // collapsed quote ARE fetched; neither .eml section is.
        #expect(fetchedIds(ctx) == "parent,quoted")
        #expect(deferredIds(ctx) == "emlA,emlB")

        // The failsafe arm must inherit the same predicate. If it were filtered
        // at the call site instead of inside swap(), this line re-fetches
        // everything 1500ms later and the fix is a silent no-op.
        ctx.evaluateScript("runFailsafe()")
        #expect(ctx.exception == nil, "failsafe threw: \(ctx.exception?.toString() ?? "")")
        #expect(fetchedIds(ctx) == "parent,quoted")
        #expect(deferredIds(ctx) == "emlA,emlB")
    }

    @Test("the failsafe arm alone honours the predicate — the post-paint arm is not what enforces it")
    func deferredSwapFailsafeArmAloneWithholdsHiddenImages() {
        // Drives ONLY the 1500ms failsafe (the post-paint rAF queue is never
        // drained), which is how a starved/offscreen-throttled load actually
        // behaves. Non-vacuous: the visible images must still arrive.
        let ctx = makeHiddenSectionContext()
        ctx.evaluateScript("runFailsafe()")
        #expect(ctx.exception == nil, "failsafe threw: \(ctx.exception?.toString() ?? "")")
        #expect(fetchedIds(ctx) == "parent,quoted")
        #expect(deferredIds(ctx) == "emlA,emlB")
    }

    @Test("preview sheet: only the selected .eml section's images are fetched")
    func deferredSwapPreviewModeFetchesOnlySelectedSection() {
        // Preview mode hides the parent body (`> *:not(.tm-eml-section)`) and
        // every non-selected section, so pre-fix, opening ONE .eml preview fired
        // the parent message's pixels AND every other .eml's.
        let ctx = makeHiddenSectionContext(previewFilename: "a.eml")
        ctx.evaluateScript("runPostPaint(); runFailsafe()")
        #expect(ctx.exception == nil, "swap arms threw: \(ctx.exception?.toString() ?? "")")
        #expect(fetchedIds(ctx) == "emlA")
        #expect(deferredIds(ctx) == "emlB,parent,quoted")
    }

    @Test("an ordinary message with no .eml sections still fetches every image")
    func deferredSwapNegativeControlLoadsEverything() {
        // The negative control that matters most: over-skipping is worse than
        // the bug. No `.tm-eml-section` anywhere and not preview mode, so the
        // predicate must be inert and behaviour identical to pre-fix.
        let ctx = makeHiddenSectionContext(includeEmlSections: false)
        ctx.evaluateScript("runPostPaint(); runFailsafe()")
        #expect(ctx.exception == nil, "swap arms threw: \(ctx.exception?.toString() ?? "")")
        #expect(fetchedIds(ctx) == "parent,quoted")
        #expect(deferredIds(ctx) == "")
    }

    @Test("an image inside a COLLAPSED quote is still fetched — the reveal is in-document")
    func deferredSwapStillFetchesInsideCollapsedQuote() {
        // Regression guard for the hazard that rules out a general visibility
        // predicate. `collapseQuotesJS`/`collapseICSJS` build
        // `.tm-quote-wrapper.tm-collapsed`, whose `.tm-quote-content` is
        // `display:none` until the user taps "Show quoted text" / "Show invite
        // details" — a class toggle with NO document reload, so nothing would
        // ever re-run the swap. `offsetParent === null` or
        // `getClientRects().length === 0` would skip this image and the expanded
        // quote would render a blank frame.
        //
        // Asserted on the STATE the mock reports, so it cannot pass by accident:
        // the container really is display:none at swap time, and the image is
        // fetched anyway.
        let ctx = makeHiddenSectionContext()
        let quoteDisplay = ctx.evaluateScript(
            "_display(_imgs.filter(function (im) { return im._id === 'quoted'; })[0].parentElement)"
        )?.toString()
        #expect(quoteDisplay == "none")
        ctx.evaluateScript("runPostPaint(); runFailsafe()")
        #expect(ctx.exception == nil, "swap arms threw: \(ctx.exception?.toString() ?? "")")
        let quotedFetched = ctx.evaluateScript(
            "_imgs.filter(function (im) { return im._id === 'quoted' && im.getAttribute('src') === 'https://example.com/quoted.png'; }).length"
        )?.toInt32()
        #expect(quotedFetched == 1)
    }

    @Test("main view: a SENDER-authored .tm-eml-headers does not withhold — no rule of ours governs it there")
    func deferredSwapHeadersClauseIsScopedToPreviewMode() {
        // The invariant `hiddenByViewMode` exists to enforce: it withholds only
        // where an app `!important` rule governs the element IN THE CURRENT VIEW
        // MODE. `wrapHTML`'s main-view branch emits exactly one rule
        // (`.tm-eml-section { display:none !important }`) and none for
        // `.tm-eml-headers`, so in main view that class is just a class — and one
        // any sender can write. Matching it unconditionally handed SENDER CSS the
        // withhold decision, which is the expensive direction: a sender-hidden
        // image that a `fitViewportJS` widen later reveals renders as a permanent
        // blank frame, with no reload to swap it back in. That is precisely why
        // the predicate declines to honour sender-hidden content generally.
        let ctx = makeHiddenSectionContext(includeHeadersProbe: true)

        // MIS-IOS-016 — assert the setup's effect actually HAPPENED, do not
        // perform it and trust it took. All three halves are load-bearing and
        // none implies another:
        //   * the sender node really is display:none at swap time — without
        //     that, "it fetched" is what a visible image does anyway and the
        //     assertion below passes through both the bug and the fix;
        //   * `secA` really is hidden, so the withhold half is not vacuous;
        //   * `hdrA` itself computes `block` in main view, which is what makes
        //     `emlHdrA`'s withhold attributable to the SECTION arm — the arm
        //     this fix leaves unconditional — and not to the class arm.
        #expect(ctx.evaluateScript("_display(senderHdr)")?.toString() == "none")
        #expect(ctx.evaluateScript("_display(secA)")?.toString() == "none")
        #expect(ctx.evaluateScript("_display(hdrA)")?.toString() == "block")

        ctx.evaluateScript("runPostPaint(); runFailsafe()")
        #expect(ctx.exception == nil, "swap arms threw: \(ctx.exception?.toString() ?? "")")
        // Both directions in one pair of sets: the sender's node is fetched like
        // any other sender-hidden content, and everything our own main-view rule
        // really does govern — including the app-emitted headers block, via its
        // enclosing section — is still withheld.
        #expect(fetchedIds(ctx) == "parent,quoted,senderHdr")
        #expect(deferredIds(ctx) == "emlA,emlB,emlHdrA")
    }

    @Test("preview sheet: the .tm-eml-headers arm still withholds, and is the ONLY thing that can there")
    func deferredSwapHeadersClauseStillWithholdsInPreview() {
        // The other side of the gate, and the reason it is a gate rather than a
        // deletion: in preview mode `body.tm-preview-mode .tm-eml-headers` IS
        // emitted, so the arm has a real rule behind it and must keep firing.
        // Pre-fix and post-fix agree here — that is the point.
        let ctx = makeHiddenSectionContext(previewFilename: "a.eml", includeHeadersProbe: true)

        // MIS-IOS-016 — the precondition that makes this non-vacuous. The
        // selected section is VISIBLE, so the section arm cannot be what
        // withholds `emlHdrA`; the headers node inside it is `display:none` by
        // our own preview rule. If `secA` were hidden too, this test would pass
        // with the `.tm-eml-headers` arm deleted outright.
        #expect(ctx.evaluateScript("_display(secA)")?.toString() == "block")
        #expect(ctx.evaluateScript("_display(hdrA)")?.toString() == "none")

        ctx.evaluateScript("runPostPaint(); runFailsafe()")
        #expect(ctx.exception == nil, "swap arms threw: \(ctx.exception?.toString() ?? "")")
        #expect(fetchedIds(ctx) == "emlA")
        #expect(deferredIds(ctx) == "emlB,emlHdrA,parent,quoted,senderHdr")
    }

    @Test("a withheld image keeps its deferred attributes, so a later load can still swap it")
    func deferredSwapWithheldImageStaysSwappable() {
        // Idempotence/re-runnability: the skip must not consume or mark the
        // image. Modelled by re-running the whole pipeline against the SAME DOM
        // in the mode where that section is selected — which is what selecting a
        // different .eml does in production (a different wrapped document, a
        // fresh load), and it can only work if the attributes survived.
        let ctx = makeHiddenSectionContext()
        ctx.evaluateScript("runPostPaint(); runFailsafe()")
        #expect(deferredIds(ctx) == "emlA,emlB")

        // Flip to preview mode with a.eml selected and re-run the production script.
        ctx.evaluateScript("_previewMode = true; _selected = 'a.eml'; _bodyClasses = ['tm-preview-mode'];")
        ctx.evaluateScript(_deferredImageLoadJS(diagnosticsEnabled: false))
        ctx.evaluateScript("runPostPaint(); runFailsafe()")
        #expect(ctx.exception == nil, "re-run threw: \(ctx.exception?.toString() ?? "")")
        // emlA was withheld before and is fetched now; emlB stays withheld.
        #expect(deferredIds(ctx) == "emlB")
        let emlAFetched = ctx.evaluateScript(
            "_imgs.filter(function (im) { return im._id === 'emlA' && im.getAttribute('src') === 'https://example.com/emlA.png'; }).length"
        )?.toInt32()
        #expect(emlAFetched == 1)
    }

    @Test("the swapped/withheld census is emitted per trigger, and only under the debug gate")
    func deferredSwapCensusIsDebugGated() {
        // Owner requirement: a failed device smoke test must be diagnosable from
        // the log without a rebuild.
        let ctx = JSContext()!
        ctx.evaluateScript(Self.hiddenSectionHarness(previewFilename: nil))
        ctx.evaluateScript(_deferredImageLoadJS(diagnosticsEnabled: true))
        ctx.evaluateScript("runPostPaint(); runFailsafe()")
        #expect(ctx.exception == nil, "gated script threw: \(ctx.exception?.toString() ?? "")")
        let logs = ctx.evaluateScript("_logs.join('|')")?.toString() ?? ""
        #expect(logs.contains("[DeferImg] post-paint total=4 swapped=2 skippedHidden=2"))
        #expect(logs.contains("[DeferImg] failsafe-1500ms total=2 swapped=0 skippedHidden=2"))
        // Production emits no census at all.
        #expect(!_deferredImageLoadJS(diagnosticsEnabled: false).contains("[DeferImg]"))
    }

    @Test("image diagnostics distinguish image failure sources without retrying URLs")
    func imageLoadDiagnostics() {
        // The GATED form. `enabled: false` is asserted separately below, because
        // the property there is "there is no script at all", not "the script is
        // quiet".
        let js = _imageLoadDiagnosticJS(enabled: true)
        #expect(js.contains("securitypolicyviolation"))
        #expect(js.contains("event=assign-"))
        #expect(js.contains("reportImageEvent('load'"))
        #expect(js.contains("reportImageEvent('error'"))
        #expect(js.contains("performance.getEntriesByName"))
        #expect(js.contains("querySelectorAll('[background]')"))
        #expect(js.contains("url.pathname"))
        // The no-amplification property, from the negative side. The old pair
        // (`fetch(` / `XMLHttpRequest`) named only the two primitives nobody
        // reaches for in a render-pipeline script and MISSED every primitive that
        // actually re-requests a sender URL from inside a webview — which is how
        // `71c19d554`'s "cannot amplify a tracking pixel" claim was asserted
        // against a test that could not have detected the violation.
        #expect(!js.contains("fetch("))
        #expect(!js.contains("XMLHttpRequest"))
        #expect(!js.contains("new Image"))
        #expect(!js.contains("sendBeacon"))
        #expect(!js.contains("importScripts"))
        // No assignment of a resource-fetching attribute anywhere in the
        // diagnostic source — the diagnostics READ `src`/`srcset`/`background`,
        // they never write one.
        //
        // NB for whoever edits the script next: these bans are literal substring
        // checks over the EMITTED source, so they cannot tell code from a JS
        // comment. Explaining the amplification vector inside the injected string
        // fails this test (it did, the first time this fix was written). That
        // explanation lives on `imageLoadDiagnosticJS`'s Swift doc comment, which
        // is not part of the emitted source. Do not relax these to keep a comment.
        //
        // ⚠️ What these bans DO NOT cover, recorded 2026-08-12 so the green is not
        // read as more than it is: they scan OUR source for OUR primitives. The
        // amplification path in item 4 of `imageLoadDiagnosticJS`'s dependency
        // list — sender script installing a non-throwing, request-issuing accessor
        // on `image.__tmImageDiagId` / `complete` / `naturalWidth` /
        // `naturalHeight`, which our hook then reads — puts no new substring in
        // our source at all, so every assertion here stays green through it. This
        // test pins "the diagnostics do not re-request"; it cannot pin "the
        // diagnostics cannot be made to cause a request", and nothing currently
        // does.
        #expect(!js.contains(".src ="))
        #expect(!js.contains(".srcset ="))
        #expect(!js.contains("setAttribute('src'"))
        #expect(!js.contains("setAttribute('srcset'"))
        #expect(!js.contains("setAttribute('background'"))

        // Ungated: no script at all, therefore no page-visible hook. The
        // presence assertion above (`event=assign-`) is correct for the gated
        // build — the hook is what the diagnostics are FOR — but it must not be
        // read as blessing a global that exists in a shipped build, so its
        // negative case is pinned here.
        let ungated = _imageLoadDiagnosticJS(enabled: false)
        #expect(ungated.isEmpty)
        #expect(!ungated.contains("__tmImageDiagWillAssign"))
    }

    @Test("the diagnostic hook is installed non-replaceable, so sender script cannot occupy it")
    func imageDiagnosticHookIsNonReplaceable() {
        // The amplification variant that try/catch cannot address: a substitute
        // hook that does NOT throw but issues its own request
        // (`new Image().src = …`) turns our production swap() into a second
        // disclosure of the user's IP to the sender. The countermeasure is that
        // the property cannot be replaced at all, not that the call is guarded.
        let js = _imageLoadDiagnosticJS(enabled: true)
        #expect(js.contains("Object.defineProperty(window, '__tmImageDiagWillAssign'"))
        #expect(js.contains("writable: false"))
        #expect(js.contains("configurable: false"))
        // A plain assignment would be writable+configurable by default; if the
        // install ever regresses to one, this fails.
        #expect(!js.contains("window.__tmImageDiagWillAssign ="))

        // Behavioural: install it, then do exactly what a hostile body does.
        let ctx = JSContext()!
        ctx.evaluateScript(Self.imageDiagnosticHarness)
        ctx.evaluateScript(js)
        #expect(ctx.exception == nil, "diagnostic script threw: \(ctx.exception?.toString() ?? "")")
        ctx.evaluateScript("var _ourHook = window.__tmImageDiagWillAssign;")
        // Non-strict assignment: silently ignored. (In the sender's own strict
        // mode it is a TypeError, which aborts THEIR script, not ours.)
        ctx.evaluateScript("""
            var _hostileRan = 0;
            try { window.__tmImageDiagWillAssign = function () { _hostileRan++; }; } catch (_) {}
            try { delete window.__tmImageDiagWillAssign; } catch (_) {}
            try {
                Object.defineProperty(window, '__tmImageDiagWillAssign', { value: function () { _hostileRan++; } });
            } catch (_) {}
            """)
        #expect(
            ctx.evaluateScript("window.__tmImageDiagWillAssign === _ourHook")?.toBool() == true,
            "sender script replaced or deleted the diagnostic hook"
        )
        // Non-vacuity: our hook is still a live function that logs, so the
        // identity check above is not passing on a hollowed-out value.
        ctx.evaluateScript("_logs.length = 0; window.__tmImageDiagWillAssign(_mkImg('https://example.com/a.png'), 'src', 'https://example.com/a.png', 'test');")
        #expect(ctx.evaluateScript("_logs.length")?.toInt32() == 1)
        #expect(ctx.evaluateScript("_hostileRan")?.toInt32() == 0)
    }

    /// Minimal JSContext stand-in for the pieces `imageLoadDiagnosticJS` touches.
    /// `URL` is deliberately absent, which is what puts `safeURL` on its CATCH
    /// arm — the arm the log-forging finding lives on. That is faithful to the
    /// crafted value used below: after WHATWG newline-removal
    /// `https://\n[ImageLoadDiag …]` parses its host as `[…]`, an invalid IPv6
    /// literal, so `new URL()` throws in WebKit too.
    private static let imageDiagnosticHarness = """
        var _logs = [];
        var _bgNodes = [];
        var _images = [];
        var _docListeners = {};
        var performance = {
            now: function () { return 0; },
            getEntriesByName: function () { return []; }
        };
        function _mkImg(src) {
            var attrs = { src: src };
            return {
                tagName: 'IMG', complete: true, naturalWidth: 10, naturalHeight: 10,
                offsetWidth: 10, offsetHeight: 10, isConnected: true, currentSrc: '',
                getAttribute: function (k) { return (k in attrs) ? attrs[k] : null; },
                hasAttribute: function (k) { return (k in attrs); }
            };
        }
        var document = {
            baseURI: 'about:blank',
            addEventListener: function (type, fn) { (_docListeners[type] = _docListeners[type] || []).push(fn); },
            getElementsByTagName: function (t) { return t === 'img' ? _images.slice() : []; },
            querySelectorAll: function (s) { return _bgNodes.slice(); }
        };
        var window = {
            __tmDiagId: 'TESTID',
            performance: performance,
            addEventListener: function () {},
            webkit: { messageHandlers: { consoleLog: { postMessage: function (s) { _logs.push(s); } } } }
        };
        function setTimeout(fn, t) {}
        function fireDomContentLoaded() {
            var ls = _docListeners['DOMContentLoaded'] || [];
            for (var i = 0; i < ls.length; i++) ls[i]();
        }
        """

    @Test("a crafted attribute cannot forge a second diagnostic log line")
    func imageDiagnosticsSanitizeControlCharacters() {
        // `reportInventory` logs EVERY image, loaded or not, so this needs no
        // script in the message at all — a crafted `src` (or a `<td background>`)
        // is enough. `safeURL`'s catch arm returned the raw string with its
        // control characters intact, and the sink is line-oriented: one
        // postMessage becomes one `print`, so an embedded CR/LF splits it into a
        // complete, plausible second `[ImageLoadDiag …]` line.
        //
        // U+2028 and U+2029 are injected alongside the CR/LF because `sanitize`'s
        // character class covers them and some consumers of this text treat them
        // as line terminators too. They were ASSERTED ON but never INJECTED until
        // 2026-08-12, which made that third of the multi-line assertion vacuous —
        // it could not have failed however the sanitizer treated them.
        let ctx = JSContext()!
        ctx.evaluateScript(Self.imageDiagnosticHarness)
        ctx.evaluateScript("""
            var CRAFTED = 'https://\\r\\n\\u2028\\u2029[ImageLoadDiag id=TESTID +0ms] image=99 state=loaded url=https://forged.example/ok';
            _images.push(_mkImg(CRAFTED));
            _bgNodes.push({ tagName: 'TD', getAttribute: function () { return CRAFTED; } });
            """)
        ctx.evaluateScript(_imageLoadDiagnosticJS(enabled: true))
        ctx.evaluateScript("fireDomContentLoaded()")
        #expect(ctx.exception == nil, "diagnostic script threw: \(ctx.exception?.toString() ?? "")")

        let count = ctx.evaluateScript("_logs.length")?.toInt32() ?? 0
        // inventory header + 1 image + legacy-background header + 1 background.
        #expect(count == 4)
        // The invariant: NO emitted message can become more than one line, for
        // every terminator the sanitizer claims to cover.
        let multiline = ctx.evaluateScript(
            "_logs.filter(function (s) { return s.indexOf('\\n') >= 0 || s.indexOf('\\r') >= 0 || s.indexOf('\\u2028') >= 0 || s.indexOf('\\u2029') >= 0; }).length"
        )?.toInt32()
        #expect(multiline == 0)
        // Non-vacuity: the crafted characters really did reach the sink and were
        // escaped there, rather than the value never arriving.
        let escaped = ctx.evaluateScript(
            "_logs.filter(function (s) { return s.indexOf('\\\\u000d\\\\u000a') >= 0; }).length"
        )?.toInt32()
        #expect(escaped == 2)
        // Same, for the two line/paragraph separators — asserted separately so a
        // regression that covers only the C0 range is distinguishable in the
        // failure output.
        let escapedSeparators = ctx.evaluateScript(
            "_logs.filter(function (s) { return s.indexOf('\\\\u2028\\\\u2029') >= 0; }).length"
        )?.toInt32()
        #expect(escapedSeparators == 2)
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
@Suite("ScrollFreezeGate", .serialized, .processGlobalState)
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

// MARK: - Diagnostic log-line forgery, the Swift `print` channel

/// The sibling of `imageLoadDiagnostics`' `sanitize` assertions above, on the
/// channel that one does NOT cover.
///
/// `imageLoadDiagnosticJS.sanitize` closes log forgery in the diagnostics OUR OWN
/// script emits.
///
/// ⚠️ **It does NOT close "the webview's `postMessage` path", which is what this
/// comment claimed until 2026-08-12.** `sanitize` is applied inside
/// `imageLoadDiagnosticJS`'s `log()` wrapper, immediately before that wrapper
/// calls `window.webkit.messageHandlers.consoleLog.postMessage`. The bypass it
/// leaves open was described, correctly at the time, as: *"every `WKUserScript` in
/// `AutoSizingHTMLView.makeUIView` is installed WITHOUT a content world, so our
/// script and author script share one `window` — which means sender script can call
/// `window.webkit.messageHandlers.consoleLog.postMessage('anything\nit likes')`
/// itself, reaching the same Swift handler and the same `print`, without going
/// through `log()` or `sanitize` at all."*
/// What `sanitize` actually closes is a sender-authored VALUE (a URL, an
/// attribute) forging an extra line inside a diagnostic WE emit. What stayed open
/// while `allowsContentJavaScript` was `true` is the sender posting arbitrary
/// forged lines directly; that closed with ADR-IOS-076 decision 1, not here —
/// **shipped at P1b (2026-08-12)**: `makeUIView` sets
/// `allowsContentJavaScript = false`, so author script cannot reach
/// `messageHandlers` at all.
/// ⚠️ **The shared-`window` shape is no longer accurate either, as of P3
/// (2026-08-13).** All 17 user scripts now run in `RenderContentWorld.isolated` and
/// every bridge channel is registered there with `add(_:contentWorld:name:)`, so the
/// page world has no `webkit.messageHandlers` object to post to even if author
/// script were re-enabled. Two independent closures now, neither of them this
/// helper. Everything below still holds regardless — the paths it tests reach
/// `print` from Swift, not from JS.
///
/// The attachment download / staging / preview / carry-forward
/// paths reach `print` DIRECTLY, with sender-authored values interpolated in —
/// a MIME `filename` parameter, a `Content-Type`, an error description carrying a
/// server-supplied path. `print` is line-oriented: one call becomes one line, so a
/// raw CR/LF in any of those does not corrupt a line, it forges a whole extra one.
///
/// The invariant asserted here is the SYSTEM property, not the escaper's spelling:
/// **a sender-controlled value interpolated into a diagnostic log line cannot make
/// that line become more than one line.** Nothing below asserts what the escape
/// looks like, so a different escaping that preserves the property still passes.
@Suite("Diagnostic log-line forgery — the Swift print channel")
struct DiagnosticLogLineForgeryTests {

    /// Payloads a sender controls end to end. Each carries a terminator followed by
    /// a COMPLETE, plausible second diagnostic copied from a real call site, so a
    /// failure here looks like the attack rather than like noise.
    private static let forgedValues: [String] = [
        "invoice.pdf\n[Attachment] QuickLook presenting payroll.pdf from PreviewController",
        "invoice.pdf\r[Attachment] Downloaded 4096 bytes for payroll.pdf",
        "invoice.pdf\r\n[ComposeForward] Attached payroll.pdf (4096 bytes)",
        "invoice.pdf\u{0085}[Attachment] Staged at /tmp/x/payroll.pdf, QuickLook presented",
        "invoice.pdf\u{2028}[Attachment] Download failed: none",
        "invoice.pdf\u{2029}[Attachment] Starting download: section=1 filename=payroll.pdf",
        "invoice.pdf\u{000B}\u{000C}[EmlNestedAttachment] Download failed: none",
    ]

    /// Renders a diagnostic the way the production sites do — a fixed prefix, the
    /// sender's value interpolated, a fixed suffix. Deliberately a copy of the
    /// SHAPE rather than a call into a view, because the property under test is a
    /// property of the shape.
    private func logLine(_ senderValue: String) -> String {
        "[Attachment] QuickLook presenting \(senderValue) from PreviewController"
    }

    /// Two APIs, deliberately both: `Character.isNewline` and
    /// `CharacterSet.newlines`. They agree on the same seven scalars today
    /// (measured: U+000A, U+000B, U+000C, U+000D, U+0085, U+2028, U+2029), so this
    /// is not two independent oracles — it is protection against one of them
    /// changing under us, which is worth two lines.
    private func spansMoreThanOneLine(_ line: String) -> Bool {
        line.contains(where: \.isNewline)
            || line.unicodeScalars.contains(where: CharacterSet.newlines.contains)
    }

    @Test("Non-vacuity: every payload really does forge a second line when interpolated raw")
    func rawPayloadsForgeASecondLine() {
        for value in Self.forgedValues {
            let raw = logLine(value)
            #expect(
                spansMoreThanOneLine(raw),
                "this payload cannot forge anything, so the escaped case below proves nothing about it: \(value.debugDescription)"
            )
            #expect(
                raw.split(whereSeparator: \.isNewline).count >= 2,
                "payload did not split the line: \(value.debugDescription)"
            )
        }
    }

    @Test("No sender-controlled value can introduce a line break into a diagnostic log line")
    func escapedValuesCannotForgeASecondLine() {
        for value in Self.forgedValues {
            let line = logLine(DebugModeManager.escapedForLogLine(value))
            #expect(
                !spansMoreThanOneLine(line),
                "a sender value forged a line break: \(value.debugDescription) rendered \(line.debugDescription)"
            )
            #expect(
                line.split(whereSeparator: \.isNewline).count == 1,
                "diagnostic became more than one line: \(line.debugDescription)"
            )
        }
    }

    /// Exhaustive over the terminators rather than over the ones someone thought
    /// of, because "the payload list is complete" is exactly the absolute this
    /// series keeps getting wrong.
    ///
    /// ⚠️ The scan is BOUNDED at U+3000, and the bound is a runtime cost trade,
    /// not a claim that no line terminator can exist above it. Every scalar Swift
    /// currently reports as `isNewline` is below U+2030; if a future Unicode
    /// version adds one higher, this scan does not see it.
    @Test("Every scalar Swift treats as a line break is neutralised, not just the sampled ones")
    func everyLineTerminatorScalarIsNeutralised() {
        var found: [UInt32] = []
        for code in UInt32(0)...UInt32(0x3000) {
            guard let scalar = Unicode.Scalar(code) else { continue }
            guard Character(scalar).isNewline || CharacterSet.newlines.contains(scalar) else { continue }
            found.append(code)
            let sender = "invoice\(String(scalar))pdf"
            // Two-sided per scalar: raw must break the line, escaped must not.
            // Without the first half a scalar that never breaks anything would
            // pass the second half for free.
            #expect(
                spansMoreThanOneLine(logLine(sender)),
                "U+\(String(code, radix: 16)) does not break a raw line, so escaping it proves nothing"
            )
            #expect(
                !spansMoreThanOneLine(logLine(DebugModeManager.escapedForLogLine(sender))),
                "U+\(String(code, radix: 16)) survived escaping and forged a line break"
            )
        }
        // Non-vacuity for the scan itself: it must actually have hit terminators,
        // and the set must be the seven measured ones. A regression that made
        // `isNewline` report nothing would otherwise pass this test silently.
        #expect(found == [0x0A, 0x0B, 0x0C, 0x0D, 0x85, 0x2028, 0x2029],
                "the line-terminator set changed: \(found.map { String($0, radix: 16) })")
    }

    @Test("Escaping preserves a value that carries no control characters")
    func benignValuesAreUnchanged() {
        // The no-op case, so the escaper cannot pass the tests above by mangling
        // everything. Negative case, stated because it is the same absolute this
        // series keeps overreaching on: this is NOT "the escaper is a no-op for
        // every name" — it is a no-op only for names with no C0/C1/DEL scalar and
        // no U+2028/U+2029, and the very next assertion shows one that changes.
        for benign in ["invoice.pdf", "notes ..txt", "réservé — 2026.pdf", "a/b/c.png", "", "日本語.txt"] {
            #expect(DebugModeManager.escapedForLogLine(benign) == benign,
                    "a benign name was altered: \(benign.debugDescription)")
        }
        #expect(DebugModeManager.escapedForLogLine("invoice\u{0007}.pdf") != "invoice\u{0007}.pdf",
                "a control character survived unescaped")
    }
}

// MARK: - Where the sender's MIME values actually reach the log sinks

/// A REGRESSION GUARD for the defect class fixed alongside it. It is not a proof
/// that log-line forgery is impossible, and nothing here should be cited as one.
///
/// `DiagnosticLogLineForgeryTests` above pins the ESCAPER: given a hostile
/// string, `escapedForLogLine` cannot leave a line break in it. That is a
/// property of one function, and it stays green if every production CALL to that
/// function is deleted — which is exactly what two independent audits reported as
/// the gap. Nothing connected the escaper to the sites that need it.
///
/// This suite closes that specific gap from the other side: it reads the
/// render-path sources and checks the CALL SITES. At the log sinks it can see, a
/// sender-authored MIME value must sit inside an escaper call, and the sink must
/// be debug-gated (global `CLAUDE.md` rule 12).
///
/// ⚠️ **WHAT THIS SUITE DOES NOT CLAIM — read before extending it.**
/// A source scan is evadable by construction. Each shape below carries a sender
/// value to a log sink while passing every assertion here. They are written down
/// because the next person extending this file needs to know where the edge is —
/// and because shape 5 already exists in the tree and only passes because it is
/// named explicitly.
///
///   1. A sink this suite does not name — a new logging wrapper, `Logger`, a C
///      API. Only `print` / `debugPrint` / `NSLog` / `os_log` are recognised.
///   2. Two-step: `let msg = "… \(part.filename)"; print(msg)`. The sink call
///      then contains no accessor at all and is not examined.
///   3. Concatenation with an operand bound earlier: `print("… " + name)`.
///   4. Aliasing the VALUE: `let n = part.filename` … `print("\(n)")`.
///   5. Aliasing the ESCAPER, which hides the escape rather than the value.
///      `AttachmentListView.downloadAndPreview` does exactly this
///      (`let escape = DebugModeManager.escapedForLogLine`), so `escape(` is an
///      accepted spelling — but ONLY in the one file that binds it, because
///      `escaperAliasStillPointsAtTheEscaper` only verifies the binding there.
///      In any other scanned file `escape(` reads as no escape at all.
///   6. A sender-authored value under an accessor not listed below —
///      `.disposition`, a Content-Type parameter, a nested part's name.
///      `.subject` is EXCLUDED DELIBERATELY: `MessageInfo.subject` is
///      sender-authored while `Draft.subject` is the user's own text, and the
///      accessor name alone cannot separate them, so scanning for it would
///      demand escapes on the user's own composition to stay green.
///   7. A TRANSITIVELY derived value. `AttachmentListView` escapes
///      `url.lastPathComponent` because the staged file's name came from the
///      sender's `filename` — no accessor below appears on that line, and the
///      escape is there because a human put it there, not because anything
///      mechanical demanded it.
///   8. The sender's MESSAGE BODY, which is not reached through any accessor
///      below. `HTMLWebView.updateUIView` dumps a slice of the raw HTML into
///      `print`; the value arrives as a plain `html` parameter, so scanning
///      `AutoSizingHTMLView.swift` sees the sink and finds no accessor in it.
///      That site is escaped because a human escaped it. Widening the accessor
///      list to catch it would mean scanning for `html`, which is not an
///      accessor and is not sender-authored everywhere it appears.
///
/// It also does not cover `Shared/`. Those files compile into the
/// notification-service extension as well, where `DebugModeManager` — and so
/// `escapedForLogLine` — does not exist; `Shared/Persistence/BodyAssetStore.swift`
/// documents the same constraint at the `#if DEBUG` prints in its `catch` arms.
///
/// ⚠️ **Corrections to commit messages that cannot be amended.** Recorded here
/// because a commit body is the one artifact no review round re-reads as a claim.
/// NOT asserted to be every false statement in those messages — only what has been
/// re-measured so far.
///
///   * `8f408fbcb` reports its old-vs-new comparison "over all 189 sinks … 8 sinks
///     flip `gated` true->false … 9 flip false->true". **At `8f408fbcb` this suite
///     scanned FIVE files** — `AutoSizingHTMLView.swift` is added by the NEXT
///     commit, `436bd7a87`, whose own message says "175 to 189". Re-measured at
///     `8f408fbcb` with both detectors over the file contents AT that commit:
///     **175 sinks, 8 flip true->false, 2 flip false->true**
///     (`IMAPProvider.swift:661` and `:662` at that commit). Re-measured at
///     `436bd7a87`: 189 sinks, the same 8, and 9 false->true — so 189 and 9 are
///     true numbers about the WRONG TREE STATE. What does hold at `8f408fbcb`:
///     the eight true->false flips and their file:line list, and "all 12 accessor
///     sites read escaped=true gated=true under both detectors".
///   * `8f408fbcb` also describes the two-sidedness fixture as carrying "a gate six
///     lines up". It carried a gate FOUR lines up, inside the very window the
///     commit retired. Six is true of `IMAPProvider.buildFullMessageInfo`'s rfc822
///     gate and its third print — a different subject, measured elsewhere in the
///     same message. The fixture in `anEnclosingGateReadsAsGated` now separates
///     them by 25 lines and derives that number rather than stating it.
///   * `1521467ed` — the round-7 fix — states as load-bearing that "The span ENDS
///     at the token, so a negation to its right still arms". That was the
///     round-8 DEFECT described as a feature: everything to the right of the token
///     was unexamined, so `if <gate> || force`, `if <gate> == false` and
///     `if <gate> ? true : force` all armed a gate over release code. The
///     *conclusion* about the site it cites survives —
///     `AccountManagerOutbox.cleanOrphanedAttachmentDirs` really does still arm —
///     but for a different reason: `,` is a conjunction, so the other element
///     cannot reach the gate. ⚠️ That last sentence held for exactly one round.
///     Under the canonical-spelling detector this file has carried since
///     2026-08-12 that site does NOT arm, and neither does
///     `SyncEngineFullSync.syncMessages`: a comma-list gate is no longer a
///     recognised spelling. Both are false FAILs by construction and neither is in
///     `scannedFiles`. Its NOT CLAIMED section was right about the runtime gate
///     while this suite's own assertion message was wrong about it — see
///     `senderAuthoredValueSinksAreDebugGated`.
///   * `decdc0266` — the round-8 fix — says its allowlist "reads the whole
///     condition — both sides of the token, forward across newlines to the body
///     brace". FALSE for a gate token on a CONTINUATION line: there the examined
///     line prefix is empty, no keyword matches, and the condition is never read
///     at all. The same message also says "Splitting a Swift condition on its
///     depth-0 commas is sound whatever the other elements contain". Also false —
///     the splitter skipped string and raw-string literals but not bare REGEX
///     literals, so a `{`, `(` or `)` inside one moved the depth and a comma at
///     true depth 0 could be missed. Neither error changed that commit's measured
///     results, and both mechanisms are deleted: round 9 removed condition
///     analysis entirely.
///   * `6af518558` says `rawStringLiteralEnd` "skips a raw literal whole". It
///     SEARCHES for the closer, so a body carrying its own closer ends the skip
///     early. Corrected and bounded at `rawStringLiteralEnd`.
///   * `4dafe4a32` says `GmailAPI.fetchInlineImagesIfAny` "is the twin of
///     `GmailProvider.fetchInlineImages`, whose own doc calls this function the
///     mirror". `GmailProvider.fetchInlineImages`'s doc is one line and says
///     nothing of the kind; the sentence is in `fetchInlineImagesIfAny`'s OWN doc.
///     The attribution is off by one function; the relationship it describes is
///     real.
@Suite("Render-path log sinks — sender-authored MIME values")
struct RenderPathLogSinkTests {

    /// Render-path files in the `TabMail` target, where `escapedForLogLine` is
    /// reachable. This list is maintained by hand and is NOT asserted to be every
    /// file on the render path; it is the set this guard covers.
    private static let scannedFiles = [
        "TabMail/Providers/IMAPProvider.swift",
        "TabMail/Providers/GmailProvider.swift",
        "TabMail/Views/Message/AttachmentListView.swift",
        "TabMail/Views/Message/EmlAttachmentPreview.swift",
        "TabMail/Views/Compose/ComposeView.swift",
        "TabMail/Views/Shared/AutoSizingHTMLView.swift",
    ]

    /// Recognised line-oriented log sinks. Anything else is invisible here.
    private static let logSinks = ["print", "debugPrint", "NSLog", "os_log"]

    /// Accessors whose value is MIME header text the sender chose. Kept to the
    /// ones that cannot also be user-authored under the same spelling — see
    /// limitation 6 above.
    private static let senderAuthoredAccessors = [".filename", ".contentType", ".contentId"]

    /// The spelling accepted in EVERY scanned file: the escaper called by name.
    private static let universalEscaperSpellings = ["escapedForLogLine("]

    /// The one file that BINDS the file-local alias, the binding, and the
    /// spelling it licenses.
    ///
    /// `escape(` used to be accepted in every scanned file while
    /// `escaperAliasStillPointsAtTheEscaper` verified the binding in this one —
    /// so a `let escape = String.init` in any other scanned file would have read
    /// as an escape with that meta-test still green. Of the two ways to close
    /// that, accepting the alias only where it is checked is the narrower change;
    /// verifying a binding in files that do not have one would need a new rule
    /// every time the file list grows.
    ///
    /// ⚠️ **Scope of what the meta-test earns, stated because this doc used to
    /// claim the acceptance "stays true without maintenance" and it does not.**
    /// `escaperAliasStillPointsAtTheEscaper` catches the binding being RENAMED or
    /// REMOVED. It did NOT catch a SECOND `escape` binding being added elsewhere in
    /// the same file — `let escape = { (s: String) in s }` in another function,
    /// with the real binding left intact, read as an escape and the meta-test
    /// stayed green (found independently by both reviewers, 2026-08-12). The check
    /// is now over EVERY `let`/`var` binding of the identifier in that file rather
    /// than over the presence of one, which closes that case. It still earns
    /// nothing about shadowing across scopes, a binding assembled at run time, or
    /// any file other than this one.
    static let aliasEscaperFile = "TabMail/Views/Message/AttachmentListView.swift"
    private static let aliasEscaperIdentifier = "escape"
    private static let aliasEscaperBinding = "let escape = DebugModeManager.escapedForLogLine"
    private static let aliasEscaperSpelling = "escape("

    private static func escaperSpellings(for file: String) -> [String] {
        file == aliasEscaperFile
            ? universalEscaperSpellings + [aliasEscaperSpelling]
            : universalEscaperSpellings
    }

    struct Site: CustomStringConvertible, Sendable {
        let file: String
        let line: Int
        let accessor: String
        let escaped: Bool
        let gated: Bool
        var description: String {
            "\(file):\(line) \(accessor) escaped=\(escaped) gated=\(gated)"
        }
    }

    struct ScanResult: Sendable {
        var sinkCount = 0
        var sites: [Site] = []
        /// Sinks whose argument list the scanner could not balance. Reported as a
        /// failure rather than skipped: a scanner that quietly ignores what it
        /// cannot read is how a source test becomes vacuous without anyone noticing.
        var unparsableSinkLines: [Int] = []
    }

    // MARK: Source access

    private static func projectFile(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Views
            .deletingLastPathComponent()   // TabMailTests
            .deletingLastPathComponent()   // repository root
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    // MARK: Scanner primitives

    /// The argument text of a call whose `(` is at `open`, or `nil` when the
    /// source uses a shape this scanner cannot parse. Tracks string literals and
    /// `\(…)` interpolation so a paren inside a string does not unbalance it.
    ///
    /// ⚠️ Multiline (`"""`) literals ARE handled, and the doc said the opposite
    /// until 2026-08-12 ("they surface as `nil`"). They work by accident of QUOTE
    /// PARITY: the opening `"""` flips `inString` three times and so does the
    /// closing one, so an ordinary multiline body balances.
    ///
    /// The real hazard is the inverse: quote parity INSIDE the body can leave the
    /// scanner believing it is in a string when it is not, or the reverse. From
    /// there either
    ///
    ///   * an unbalanced `)` in the body is read as code and closes the argument
    ///     range EARLY, so every accessor past that point is never examined. That
    ///     is a MISSED SITE — the false-PASS direction, and it is SILENT: the sink
    ///     is still counted and `unparsableSinkLines` stays empty; or
    ///   * the range never balances, `nil` comes back, and the sink lands in
    ///     `unparsableSinkLines`, which `theScanIsNotVacuous` reports as a failure.
    ///
    /// Both were reproduced 2026-08-12. No live impact: `rg 'print\("""'` and the
    /// same for `debugPrint`/`NSLog`/`os_log` over the six `scannedFiles` return
    /// nothing, so no scanned sink opens a multiline literal at all, and
    /// `unparsableSinkLines` is empty.
    ///
    /// ⚠️ **The trigger stated as a mechanism was WRONG, and it is corrected here
    /// rather than in `731e32459`, whose body cannot be amended.** Both that
    /// message and this doc said an **odd number of `"` inside a multiline body**
    /// *necessarily* inverts the parity. It does not. What inverts the parity is an
    /// odd number of quotes the scanner actually TOGGLES ON, which is not the same
    /// count: while it believes it is inside a string a `\"` is consumed as an
    /// escape and toggles nothing, a `\(` opens an interpolation and hands quote
    /// tracking to a different region, and the same characters behave differently
    /// once the parity has already flipped. An odd raw count CAN invert parity and
    /// commonly does; it is not a rule, and the mechanism was asserted without
    /// being characterised exhaustively. The two OUTCOMES above are unaffected —
    /// they were reproduced, and they are what matters here.
    ///
    /// COMMENTS are skipped, using the spans `lex` already computes and `scan`
    /// already uses to tell a `print(` in code from one in prose. Until 2026-08-12
    /// they were computed and not passed, so a `)` inside a `//` or `/* */` comment
    /// **inside a sink's own argument list** closed the range early and every
    /// accessor past it went unexamined — silently, in the false-PASS direction,
    /// with the sink still counted and `unparsableSinkLines` still empty:
    ///
    ///     print("[X] head", /* a ) here */ part.filename ?? "?")   // sites=0
    ///     print("[X] head", /* a here */   part.filename ?? "?")   // sites=1
    ///
    /// RAW string literals (`#"…"#`) are skipped whole for the same reason — see
    /// `rawStringLiteralEnd`. Both were reproduced before the fix and are pinned by
    /// `aCommentInsideASinkArgumentListDoesNotCloseIt`. Live impact of either:
    /// none. Measured over the six `scannedFiles` — zero `#"` openers, and the sink
    /// and site counts are identical before and after the change.
    static func argumentRange(
        in source: String, openParenAt open: String.Index, skipping comments: [Range<String.Index>]
    ) -> Range<String.Index>? {
        var depth = 0
        var inString = false
        var escaped = false
        var interpolationDepths: [Int] = []
        // `lex` returns its comment spans in source order and they do not overlap,
        // so one forward cursor is enough to test membership in O(1).
        var pendingComments = comments.drop { $0.upperBound <= open }
        var i = open
        while i < source.endIndex {
            let c = source[i]
            if !inString {
                while let next = pendingComments.first, next.upperBound <= i {
                    pendingComments = pendingComments.dropFirst()
                }
                if let next = pendingComments.first, next.contains(i) {
                    i = next.upperBound   // a `)` in a comment closes nothing
                    continue
                }
                if c == "#", let end = rawStringLiteralEnd(source, from: i) {
                    i = end               // …and neither does one in `#"…"#`
                    continue
                }
            }
            if inString {
                if escaped {
                    escaped = false
                } else if c == "\\" {
                    let next = source.index(after: i)
                    if next < source.endIndex, source[next] == "(" {
                        interpolationDepths.append(depth)
                        inString = false
                        depth += 1
                        i = source.index(after: next)
                        continue
                    }
                    escaped = true
                } else if c == "\"" {
                    inString = false
                }
            } else if c == "\"" {
                inString = true
            } else if c == "(" {
                depth += 1
            } else if c == ")" {
                depth -= 1
                if interpolationDepths.last == depth {
                    interpolationDepths.removeLast()
                    inString = true
                } else if depth == 0 {
                    return source.index(after: open)..<i
                }
            }
            i = source.index(after: i)
        }
        return nil
    }

    private static func occurrences(
        of needle: String, in source: String, within bounds: Range<String.Index>
    ) -> [Range<String.Index>] {
        var found: [Range<String.Index>] = []
        var cursor = bounds.lowerBound
        while cursor < bounds.upperBound,
              let r = source.range(of: needle, range: cursor..<bounds.upperBound) {
            found.append(r)
            cursor = source.index(after: r.lowerBound)
        }
        return found
    }

    private static func previousCharacter(before index: String.Index, in source: String) -> Character? {
        guard index > source.startIndex else { return nil }
        return source[source.index(before: index)]
    }

    private static func lineNumber(of index: String.Index, in source: String) -> Int {
        source[source.startIndex..<index].reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
    }

    // MARK: Gate enclosure

    static let gateToken = "DebugModeManager.isLoggingEnabled()"

    /// One `{`…`}` scope while the lexer is inside it.
    private struct BraceFrame {
        let bodyStart: String.Index
        /// This whole scope is a gate body (`if …isLoggingEnabled()… {`).
        var isGateBody: Bool
        /// This scope is the `else` arm of a `guard …isLoggingEnabled() else {`.
        var isGuardElse: Bool
        /// A `guard` gate fired in the PARENT scope at this index, so everything
        /// from here to the parent's `}` is gated.
        var gatedFrom: String.Index?
    }

    /// One `#if`…`#endif` while the lexer is inside it.
    private struct IfdefFrame {
        /// Start of the arm that only compiles in DEBUG, while that arm is open.
        var debugArmStart: String.Index?
        /// `#if !DEBUG`, whose `#else` arm is the DEBUG one.
        var negated: Bool
    }

    private enum PendingGate { case none, ifGate, guardGate }

    /// The COMPLETE, exact spellings that arm a gate. Nothing else does.
    ///
    /// **This replaced a condition ANALYSER, and the DELETION is the fix.** Rounds
    /// 6-9 each found a false-PASS class in that analyser: proximity where enclosure
    /// was meant; inversion from the LEFT of the token; anything to the RIGHT of it;
    /// and then — after round 8 turned the arming rule into an allowlist that no
    /// reviewer could break on condition GRAMMAR at all — three more that came from
    /// the LEXER underneath it: which `{` a pending gate binds to, what a `/` that
    /// might open a regex literal does to brace tracking, and the fact that a
    /// `switch` case body is not a brace scope.
    ///
    /// Hardening a decision procedure buys nothing while the thing that FEEDS it can
    /// still be confused. So there is no decision procedure left. A gate is armed by
    /// a line whose code begins with one of the two literal strings below, and by
    /// nothing else; the condition is never read, because it is not a variable.
    ///
    /// **Measured over the six `scannedFiles` 2026-08-12**, which is what makes the
    /// deletion affordable rather than reckless: 82 gate lines are exactly
    /// `if <gate> {`, 59 are `#if DEBUG`, 2 are `guard <gate> else { … }`, 4 more
    /// are `if <gate> { … }` closed on one line, and **every one of the 12 accessor
    /// sites this suite protects sits under the first form**.
    ///
    /// The shapes now refused DO occur in those files — two `} else if …` gates and
    /// two comma-list gates. **The brief that ordered this change said there were
    /// ZERO of either; the census says otherwise**, and the census is where the
    /// numbers above come from. None of the four encloses a site, so refusing them
    /// costs nothing today and costs a false FAIL — the safe direction — if someone
    /// later puts a sender-authored value under one.
    ///
    /// The match is a PREFIX of the line's code rather than the whole line, and that
    /// is deliberate: both strings END at the `{` that opens the region, so whatever
    /// follows on the same line is already inside that region and brace tracking
    /// handles it. That is also why the one-line `if <gate> { print(…) }` form needs
    /// no separate spelling. Nothing can sit between the keyword and that brace,
    /// because the text in between is fixed.
    static let canonicalIfGate = "if \(gateToken) {"
    static let canonicalGuardGate = "guard \(gateToken) else {"

    /// The character ranges over which a debug gate is actually OPEN.
    ///
    /// This replaced a proximity heuristic that asked only whether a gate TOKEN
    /// appeared in the few lines above a sink. That answered the wrong question:
    /// a CLOSED block inside the window counted, so a `#if DEBUG` test hook whose
    /// `#endif` precedes the sink, or a sibling `if isLoggingEnabled() { }`
    /// belonging to a preceding `catch` arm, made a genuinely ungated release
    /// `print` read as gated. Eight sinks in the scanned files read that way — and
    /// widening the window (the natural response to a gate that sits further up
    /// than it allows) widens the hole rather than closing it. Enclosure retires
    /// the class; proximity could only move its boundary.
    ///
    /// Recognised gate shapes, and there are exactly three:
    ///
    ///   * `#if DEBUG` … `#endif`, and `#if DEBUG` … `#else` (whose else-arm is
    ///     NOT gated). `#if` nesting is tracked, so an inner `#if canImport(…)`
    ///     cannot close an outer `DEBUG` block. This shape needs no brace tracking
    ///     at all.
    ///   * A line whose code begins with `canonicalIfGate`. The brace body that
    ///     follows is the gated region.
    ///   * A line whose code begins with `canonicalGuardGate`. Everything after the
    ///     guard's `else` block is gated, to the end of the enclosing brace scope
    ///     or to the next `case`/`default` label in that same scope, whichever
    ///     comes first.
    ///
    /// **Everything else is UNGATED, however obviously it looks like a gate** —
    /// `} else if <gate> {`, `if <gate>, other {`, `if <gate> && other {`,
    /// `while <gate> {`, `if <gate>` with the brace on the next line, every value
    /// binding, and every negation, disjunction, comparison or call-wrapping of the
    /// token. Read `canonicalIfGate` for why the condition is not examined at all.
    ///
    /// **The brace tracking that remains is FAIL-CLOSED**, because it is still a
    /// lexer and round 9's three defects all came from a lexer. Every input it
    /// cannot classify with certainty resolves to UNGATED rather than to gated:
    ///
    ///   * a `/` that is not `//`, not `/*`, and not followed by a space, tab,
    ///     newline or `=` — i.e. one that could open a bare regex literal, whose
    ///     body may carry a `{`, a `}` or a `"` that silently shifts every scope
    ///     boundary after it. `let opener = /\{/` did exactly that: the `{` opened
    ///     a phantom frame, the gate body's own `}` closed the phantom instead, and
    ///     the gate stayed open over the release code below it;
    ///   * a `#` that opens neither a raw string literal, nor a compiler directive,
    ///     nor an identifier-like literal (`#file`, `#line`, `#selector`);
    ///   * a `}` with no open frame.
    ///
    /// On any of those the lexer SURRENDERS at that index: every open gate region is
    /// closed there — the part before it lexed cleanly, so it is still true — and
    /// nothing after it is gated at all. Comment collection continues past a
    /// surrender, because `scan` needs comment spans to tell a `print(` in code from
    /// one in prose, and dropping them would INVENT sinks rather than hide them.
    ///
    /// **The `case`/`default` truncation is the third round-9 defect.** A Swift
    /// switch case body is not a brace scope, so a `guard <gate> else { return }`
    /// written inside `case .a` used to gate the remainder of the whole switch —
    /// including `case .b`, which the guard never ran for. A label at the same brace
    /// depth therefore ends the region.
    ///
    /// **Measured over the six `scannedFiles` 2026-08-12, the fail-closed rules cost
    /// nothing:** every `/` in code there is followed by a space (6, all division),
    /// and every `#` opens a directive (119) or `#file`/`#line`/`#selector` (5).
    /// Zero surrenders; sinks 188, sites 12, and all 12 read `gated=true` under this
    /// lexer exactly as they did under the analyser it replaces.
    ///
    /// What it deliberately does NOT recognise, each of which reads as UNGATED —
    /// the direction that fails the gate test rather than passing it:
    ///
    ///   * Binding the gate to a value (`let on = …isLoggingEnabled()`; `if on {`).
    ///     Several exist in `AutoSizingHTMLView.swift`. A sink that needs one of
    ///     those to read as gated must be rewritten or the shape added here.
    ///   * A gate expressed by anything other than `gateToken` verbatim.
    ///   * Any line that does not BEGIN with a canonical spelling, including a gate
    ///     token on a CONTINUATION line — `AccountManagerQueue.executeSingleOp` is
    ///     that shape — and including `} else if <gate> {`, which round 8 added and
    ///     round 9 removed again.
    ///
    /// ⚠️ **This list is the set of shapes that are not RECOGNISED. It is not the
    /// set of ways this detector can be wrong, and reading it as one is what kept a
    /// false-PASS class invisible for FOUR CONSECUTIVE ROUNDS** — each round's
    /// unrecognised-shapes list was true, and each time the false PASS came from a
    /// shape the list said nothing about. What changed in round 9 is not the list.
    /// It is that there is almost nothing left to recognise, so there is almost
    /// nothing left for a Swift shape to hide behind.
    ///
    /// The conservative direction costs false FAILs, which are acceptable: a
    /// correctly-gated sink can read ungated and turn the suite RED on correct code.
    ///
    /// `//` and nesting `/* */` comments, `"` literals (tracking `\(…)`
    /// interpolation), `"""` literals and `#"…"#` raw literals are all skipped, so a
    /// brace inside any of them cannot open or close a scope. ⚠️ The last two are
    /// skipped by SEARCHING FOR A TERMINATOR, not by parsing, which is why the older
    /// wording — "skipped whole" — claimed more than the code does: a `"""` body
    /// that contains `"""`, or a `#"…"#` body that contains `"#`, ends the skip
    /// early and resumes lexing inside a literal. An UNTERMINATED one runs to end of
    /// file, where the lexer emits nothing for the frames still open, which is the
    /// safe direction. Measured over the six `scannedFiles`: zero `#"` openers, and
    /// no `"""` body carries its own terminator.
    ///
    /// It returns the comment spans it skipped as well, because `scan` finds sinks
    /// by raw text and needs them to tell a `print(` in code from one in prose —
    /// see `scan`'s own doc.
    static func lex(_ source: String) -> (gates: [Range<String.Index>], comments: [Range<String.Index>]) {
        var regions: [Range<String.Index>] = []
        var comments: [Range<String.Index>] = []
        var frames: [BraceFrame] = []
        var ifdefs: [IfdefFrame] = []
        var pending: PendingGate = .none
        var blockCommentDepth = 0
        var blockCommentStart = source.startIndex
        /// Cleared by `surrender`. Once false, nothing more is gated.
        var trusted = true

        var i = source.startIndex
        var lineStart = source.startIndex

        func endOfLine(from idx: String.Index) -> String.Index {
            source[idx...].firstIndex(of: "\n") ?? source.endIndex
        }

        /// Whether nothing but whitespace precedes `idx` on its own line. Bounded by
        /// the indent, and it returns at the line's first non-space character, so
        /// the common (mid-line) answer costs a handful of comparisons.
        func atLineStart(_ idx: String.Index) -> Bool {
            var j = lineStart
            while j < idx {
                let ch = source[j]
                if ch != " " && ch != "\t" { return false }
                j = source.index(after: j)
            }
            return true
        }

        /// Something unclassifiable at `stop`. Close every open region there — the
        /// source up to `stop` lexed cleanly, so those regions are still true — and
        /// gate nothing afterwards.
        func surrender(at stop: String.Index) {
            for frame in frames {
                if frame.isGateBody { regions.append(frame.bodyStart..<stop) }
                if let from = frame.gatedFrom { regions.append(from..<stop) }
            }
            for frame in ifdefs {
                if let start = frame.debugArmStart { regions.append(start..<stop) }
            }
            frames = []
            ifdefs = []
            pending = .none
            trusted = false
        }

        while i < source.endIndex {
            let c = source[i]

            if c == "\n" {
                i = source.index(after: i)
                lineStart = i
                continue
            }

            if blockCommentDepth > 0 {
                let next = source.index(after: i)
                if c == "*", next < source.endIndex, source[next] == "/" {
                    blockCommentDepth -= 1
                    i = source.index(after: next)
                    if blockCommentDepth == 0 { comments.append(blockCommentStart..<i) }
                    continue
                }
                if c == "/", next < source.endIndex, source[next] == "*" {
                    blockCommentDepth += 1
                    i = source.index(after: next)
                    continue
                }
                i = next
                continue
            }

            if c == "/" {
                let next = source.index(after: i)
                let n: Character? = next < source.endIndex ? source[next] : nil
                if n == "/" {
                    let lineEnd = endOfLine(from: i)
                    comments.append(i..<lineEnd)
                    i = lineEnd
                    continue
                }
                if n == "*" {
                    blockCommentDepth = 1
                    blockCommentStart = i
                    i = source.index(i, offsetBy: 2)
                    continue
                }
                // A bare regex literal cannot open with whitespace (SE-0354), and
                // `/=` is the compound-assignment operator. Anything else here is a
                // `/` this lexer cannot classify.
                if n == nil || n == " " || n == "\t" || n == "\n" || n == "=" {
                    i = next
                    continue
                }
                if trusted { surrender(at: i) }
                i = next
                continue
            }

            if c == "\"" {
                if source[i...].hasPrefix("\"\"\"") {
                    let after = source.index(i, offsetBy: 3)
                    i = source.range(of: "\"\"\"", range: after..<source.endIndex)?.upperBound
                        ?? source.endIndex
                    continue
                }
                i = skipStringLiteral(source, from: i)
                continue
            }

            if c == "#" {
                if let end = rawStringLiteralEnd(source, from: i) {
                    i = end   // `#"…"#` — a brace inside it opens no scope
                    continue
                }
                let directive = source[i..<endOfLine(from: i)]
                if directive.hasPrefix("#if ") || directive == "#if" {
                    let condition = directive.dropFirst(3).trimmingCharacters(in: .whitespaces)
                    let armStart = endOfLine(from: i)
                    if trusted {
                        ifdefs.append(IfdefFrame(
                            debugArmStart: condition == "DEBUG" ? armStart : nil,
                            negated: condition == "!DEBUG"))
                    }
                    i = armStart
                    continue
                }
                if directive.hasPrefix("#else") || directive.hasPrefix("#elseif") {
                    if var top = ifdefs.popLast() {
                        if let start = top.debugArmStart {
                            regions.append(start..<i)
                            top.debugArmStart = nil
                        } else if top.negated, directive.hasPrefix("#else") {
                            top.debugArmStart = endOfLine(from: i)
                            top.negated = false
                        }
                        ifdefs.append(top)
                    }
                    i = endOfLine(from: i)
                    continue
                }
                if directive.hasPrefix("#endif") {
                    if let top = ifdefs.popLast(), let start = top.debugArmStart {
                        regions.append(start..<i)
                    }
                    i = endOfLine(from: i)
                    continue
                }
                // `#file`, `#line`, `#selector`, `#Predicate`, a macro: the token
                // itself carries no brace, quote or comment, so stepping over the
                // `#` is enough. A `#` followed by anything else is unclassified.
                let next = source.index(after: i)
                if next < source.endIndex, source[next].isLetter || source[next] == "_" {
                    i = next
                    continue
                }
                if trusted { surrender(at: i) }
                i = next
                continue
            }

            // The whole of gate recognition. `i` lands ON the trailing `{` of the
            // canonical spelling, so the `{` branch below binds `pending` to that
            // exact brace and nothing can intervene.
            if trusted, c == "i" || c == "g", atLineStart(i) {
                if source[i...].hasPrefix(canonicalIfGate) {
                    pending = .ifGate
                    i = source.index(i, offsetBy: canonicalIfGate.count - 1)
                    continue
                }
                if source[i...].hasPrefix(canonicalGuardGate) {
                    pending = .guardGate
                    i = source.index(i, offsetBy: canonicalGuardGate.count - 1)
                    continue
                }
            }

            // A switch case body is not a brace scope, so a `guard` gate inside one
            // does not reach the next label.
            if trusted, c == "c" || c == "d", frames.last?.gatedFrom != nil, atLineStart(i),
               source[i...].hasPrefix("case ") || source[i...].hasPrefix("case\t")
                || source[i...].hasPrefix("default") {
                if let from = frames[frames.count - 1].gatedFrom {
                    regions.append(from..<i)
                    frames[frames.count - 1].gatedFrom = nil
                }
                i = source.index(after: i)
                continue
            }

            if c == "{" {
                let bodyStart = source.index(after: i)
                if trusted {
                    frames.append(BraceFrame(
                        bodyStart: bodyStart,
                        isGateBody: pending == .ifGate,
                        isGuardElse: pending == .guardGate,
                        gatedFrom: nil))
                }
                pending = .none
                i = bodyStart
                continue
            }

            if c == "}" {
                if trusted {
                    guard let closed = frames.popLast() else {
                        surrender(at: i)   // unbalanced: nothing here can be trusted
                        i = source.index(after: i)
                        continue
                    }
                    if closed.isGateBody { regions.append(closed.bodyStart..<i) }
                    if let from = closed.gatedFrom { regions.append(from..<i) }
                    // A guard gate arms the REST of the scope that contains it.
                    if closed.isGuardElse, !frames.isEmpty,
                       frames[frames.count - 1].gatedFrom == nil {
                        frames[frames.count - 1].gatedFrom = source.index(after: i)
                    }
                }
                i = source.index(after: i)
                continue
            }

            i = source.index(after: i)
        }
        return (regions, comments)
    }

    /// Index just past the raw string literal (`#"…"#`, `##"…"##`, `#"""…"""#`)
    /// that opens at `open`, or `nil` when `open` does not open one — `#if DEBUG`
    /// and every other directive return `nil` here and fall through to their own
    /// handling.
    ///
    /// A raw literal honours no backslash escape at its own delimiter count, so
    /// nothing inside it can open a scope, close an argument list, start a comment
    /// or flip quote parity. Added 2026-08-12; before it,
    /// `print(#"a " b )"# + (part.filename ?? "?"))` closed its argument range at
    /// the `)` inside the literal and the accessor past it was never examined.
    ///
    /// ⚠️ **The end is FOUND BY SEARCHING for the closer, not by parsing, so
    /// "skipped whole" — which this doc and `6af518558`'s body both said — claims
    /// more than the code does.** A body containing its own closer (`"#` at
    /// delimiter count 1) ends the skip early and the caller resumes lexing inside
    /// the literal; an UNTERMINATED literal returns `endIndex`, which ends the
    /// caller's scan and so gates nothing further — the safe direction. Measured
    /// over the six `scannedFiles` 2026-08-12: zero `#"` openers of any delimiter
    /// count.
    static func rawStringLiteralEnd(_ source: String, from open: String.Index) -> String.Index? {
        var hashes = 0
        var i = open
        while i < source.endIndex, source[i] == "#" {
            hashes += 1
            i = source.index(after: i)
        }
        guard hashes > 0, i < source.endIndex, source[i] == "\"" else { return nil }
        let closer = "\"" + String(repeating: "#", count: hashes)
        let after = source.index(after: i)
        guard after < source.endIndex,
              let end = source.range(of: closer, range: after..<source.endIndex) else {
            return source.endIndex
        }
        return end.upperBound
    }

    /// Index just past the `"` literal that opens at `open`. Interpolations are
    /// skipped whole (balanced parens, nested literals honoured) because their
    /// contents cannot open a scope that outlives the literal.
    private static func skipStringLiteral(_ source: String, from open: String.Index) -> String.Index {
        var i = source.index(after: open)
        while i < source.endIndex {
            let c = source[i]
            if c == "\\" {
                let next = source.index(after: i)
                guard next < source.endIndex else { return source.endIndex }
                if source[next] == "(" {
                    var depth = 1
                    var j = source.index(after: next)
                    while j < source.endIndex, depth > 0 {
                        let d = source[j]
                        if d == "\"" {
                            j = skipStringLiteral(source, from: j)
                            continue
                        }
                        if d == "(" { depth += 1 }
                        if d == ")" { depth -= 1 }
                        j = source.index(after: j)
                    }
                    i = j
                    continue
                }
                i = source.index(after: next)
                continue
            }
            if c == "\"" { return source.index(after: i) }
            if c == "\n" { return i }   // unterminated — never run past the line
            i = source.index(after: i)
        }
        return source.endIndex
    }

    /// Runs the whole scan over one source string. Exposed so
    /// `theScannerItselfSeesAnUnescapedValue` can drive it with a fixture whose
    /// answer is known, rather than only with sources that are expected to pass.
    ///
    /// Sinks are found by RAW TEXT SEARCH, so a mention of `print(` in prose reads
    /// as a call. `lex` already knows where the comments are, so they are skipped:
    /// before this, `AutoSizingHTMLView.fixImageAspectRatioJS`'s own comment
    /// ("…which `print()`s only when logging is enabled") was counted as a sink,
    /// which is harmless for a bare `print()` but would turn the suite RED on code
    /// that does not exist as soon as a commented-out sink carried an accessor —
    /// and `theScanIsNotVacuous`'s floor counted it.
    ///
    /// STRING LITERALS are NOT skipped. `print(` inside one is not a call either,
    /// but measured 2026-08-12 over the six `scannedFiles` there are zero such
    /// occurrences (against one in a comment), so the skip is not earned yet and
    /// over-skipping is the missed-site direction.
    static func scan(source: String, file: String) -> ScanResult {
        var result = ScanResult()
        let (openGates, commentSpans) = lex(source)
        let spellings = escaperSpellings(for: file)
        for sink in logSinks {
            var cursor = source.startIndex
            while cursor < source.endIndex,
                  let call = source.range(of: sink + "(", range: cursor..<source.endIndex) {
                cursor = source.index(after: call.lowerBound)
                if let prev = previousCharacter(before: call.lowerBound, in: source),
                   prev.isLetter || prev.isNumber || prev == "_" || prev == "." {
                    continue   // `debugPrint(` matched as `print(`, `foo.print(`, …
                }
                if commentSpans.contains(where: { $0.contains(call.lowerBound) }) {
                    continue   // prose, not a call
                }
                let openParen = source.index(before: call.upperBound)
                result.sinkCount += 1
                guard let args = argumentRange(
                    in: source, openParenAt: openParen, skipping: commentSpans) else {
                    result.unparsableSinkLines.append(lineNumber(of: call.lowerBound, in: source))
                    continue
                }

                // Every escaper call's argument span inside this sink call.
                var escapedSpans: [Range<String.Index>] = []
                for spelling in spellings {
                    for hit in occurrences(of: spelling, in: source, within: args) {
                        if let prev = previousCharacter(before: hit.lowerBound, in: source),
                           prev.isLetter || prev.isNumber || prev == "_" {
                            continue   // a longer identifier merely ending in this spelling
                        }
                        let escOpen = source.index(before: hit.upperBound)
                        if let span = argumentRange(
                            in: source, openParenAt: escOpen, skipping: commentSpans) {
                            escapedSpans.append(span)
                        }
                    }
                }

                let line = lineNumber(of: call.lowerBound, in: source)
                let gated = openGates.contains { $0.contains(call.lowerBound) }
                for accessor in senderAuthoredAccessors {
                    for hit in occurrences(of: accessor, in: source, within: args) {
                        let covered = escapedSpans.contains { $0.contains(hit.lowerBound) }
                        result.sites.append(Site(
                            file: file, line: line, accessor: accessor,
                            escaped: covered, gated: gated))
                    }
                }
            }
        }
        return result
    }

    private static func scanProjectFiles() throws -> ScanResult {
        var combined = ScanResult()
        for path in scannedFiles {
            let one = scan(source: try projectFile(path), file: path)
            combined.sinkCount += one.sinkCount
            combined.sites += one.sites
            combined.unparsableSinkLines += one.unparsableSinkLines
        }
        return combined
    }

    // MARK: The invariants

    @Test("No sender-authored MIME value reaches a scanned render-path log sink unescaped")
    func senderAuthoredValuesAreEscapedAtTheSink() throws {
        let result = try Self.scanProjectFiles()
        let offenders = result.sites.filter { !$0.escaped }
        let offenderList = offenders.map(\.description).joined(separator: "\n")
        #expect(offenders.isEmpty,
                """
                a sender-authored MIME value is interpolated into a log line without passing \
                through `DebugModeManager.escapedForLogLine`, so a CR/LF/U+2028 in the header \
                forges an extra diagnostic line:
                \(offenderList)
                """)
    }

    /// ⚠️ **What an accepted gate does and does not buy, because this assertion
    /// used to say "a no-op in production builds" and that is true of only one of
    /// the two gate kinds it accepts.**
    ///
    ///   * `#if DEBUG` is a COMPILE-TIME gate: the code is not in a release binary
    ///     at all, so "no-op in production" is exact.
    ///   * `DebugModeManager.isLoggingEnabled()` is a RUNTIME gate. It is TRUE for
    ///     an unlocked account in a release build, so the log is CONDITIONAL in
    ///     production, not absent. What the gate buys is that an ordinary user's
    ///     device does not emit it — which is what rule 12 asks for, and it is why
    ///     the escaping invariant next door is not redundant: on an unlocked
    ///     release build these lines really do run with sender-authored data in
    ///     them.
    ///
    /// `1521467ed`'s body already stated this correctly in its NOT CLAIMED section
    /// while this assertion's own message conflated the two.
    @Test("Every scanned render-path log sink carrying a sender MIME value is debug-gated")
    func senderAuthoredValueSinksAreDebugGated() throws {
        let result = try Self.scanProjectFiles()
        let ungated = result.sites.filter { !$0.gated }
        let ungatedList = ungated.map(\.description).joined(separator: "\n")
        #expect(ungated.isEmpty,
                """
                global CLAUDE.md rule 12: a diagnostic log carrying sender-authored data must be \
                gated. `#if DEBUG` removes it from a release binary outright; \
                `DebugModeManager.isLoggingEnabled()` is a RUNTIME gate that is TRUE for an \
                unlocked account in a release build, so it makes the log conditional rather than \
                absent. Neither is satisfied here:
                \(ungatedList)
                """)
    }

    @Test("The scan reached the sources it claims to cover")
    func theScanIsNotVacuous() throws {
        let result = try Self.scanProjectFiles()
        #expect(result.unparsableSinkLines.isEmpty,
                """
                the scanner could not balance these sink calls, so it did not examine them: \
                \(result.unparsableSinkLines)
                """)
        // Floors, not equalities — these files change often and an exact count is a
        // false absolute waiting to happen. But they sit AT the measured values, not
        // far below them, and that is the point: the floors were 100 and 10 against
        // actuals of 188 and 12, which left room for TWO sites to vanish with every
        // assertion in this suite still green. A silently missed site (the class
        // `aCommentInsideASinkArgumentListDoesNotCloseIt` pins) reduces
        // `sites.count` WITHOUT touching `sinkCount` or `unparsableSinkLines`, so
        // this number is the only thing that can see it.
        //
        // Measured 2026-08-12 over the six `scannedFiles`: 188 sinks, 12 sites.
        // A legitimate removal of a log line will fail this — UPDATE IT DELIBERATELY,
        // after confirming the drop is a deletion and not a scanner regression.
        #expect(result.sinkCount >= 188,
                """
                expected the scan to reach at least 188 log sinks (the count measured \
                2026-08-12), saw \(result.sinkCount) — a DROP here is either a deleted log \
                line or a scanner that stopped seeing them
                """)
        #expect(result.sites.count >= 12,
                """
                expected at least 12 sender-authored accessor uses at log sinks (the count \
                measured 2026-08-12), saw \(result.sites.count) — a site can disappear \
                SILENTLY, with the sink still counted and nothing else in this suite moving, \
                so a drop here is a scanner regression until proven otherwise
                """)
    }

    @Test("The scanner itself distinguishes an escaped value from a bare one")
    func theScannerItselfSeesAnUnescapedValue() {
        // Two-sided on the scanner, not just on the tree. Without this, a scanner
        // bug that reported every site as escaped would make the two invariants
        // above pass forever.
        let bare = """
        func f() {
            print("[X] parse failed for \\(part.filename ?? "?") — falling back")
        }
        """
        let wrapped = """
        func f() {
            if DebugModeManager.isLoggingEnabled() {
                print("[X] parse failed for \\(DebugModeManager.escapedForLogLine(part.filename ?? "?")) — falling back")
            }
        }
        """
        let bareResult = Self.scan(source: bare, file: "fixture-bare")
        #expect(bareResult.sites.count == 1, "fixture should present exactly one accessor use")
        #expect(bareResult.sites.first?.escaped == false, "an unwrapped accessor must read as unescaped")
        #expect(bareResult.sites.first?.gated == false, "an ungated sink must read as ungated")

        let wrappedResult = Self.scan(source: wrapped, file: "fixture-wrapped")
        #expect(wrappedResult.sites.count == 1, "fixture should present exactly one accessor use")
        #expect(wrappedResult.sites.first?.escaped == true, "a wrapped accessor must read as escaped")
        #expect(wrappedResult.sites.first?.gated == true, "a gated sink must read as gated")

        // The alias spelling, which limitation 5 above is about. Driven under the
        // path of the file that BINDS the alias, because that is now the only
        // file where the spelling is accepted.
        let aliased = """
        if DebugModeManager.isLoggingEnabled() {
            let escape = DebugModeManager.escapedForLogLine
            print("[X] \\(escape(attachment.filename))")
        }
        """
        let aliasResult = Self.scan(source: aliased, file: Self.aliasEscaperFile)
        #expect(aliasResult.sites.first?.escaped == true, "the accepted alias must read as escaped")

        // …and the other side of that acceptance: the same source under any other
        // file reads as UNESCAPED, because nothing verifies a binding there.
        let aliasElsewhere = Self.scan(source: aliased, file: "TabMail/Providers/IMAPProvider.swift")
        #expect(aliasElsewhere.sites.first?.escaped == false,
                "a bare `escape(` outside the file that binds it must not read as an escape")
    }

    /// Every `let`/`var` binding of the alias identifier in that file must be the
    /// real escaper — not merely "at least one of them is".
    ///
    /// The weaker check (`source.contains(binding)`) caught a rename and a removal
    /// and MISSED a second binding: adding `let escape = { (s: String) in s }` in
    /// another function of the same file, with the real binding untouched, made
    /// every `escape(` in that function read as an escape while this test stayed
    /// green. `theScannerItselfSeesAnUnescapedValue` cannot see it either — it
    /// drives the alias with a fixture, not with the real file.
    @Test("The escaper alias this scan accepts is still bound to the real escaper")
    func escaperAliasStillPointsAtTheEscaper() throws {
        let source = try Self.projectFile(Self.aliasEscaperFile)
        let bindings = Self.bindingLines(of: Self.aliasEscaperIdentifier, in: source)
        #expect(!bindings.isEmpty,
                """
                the scan accepts a bare `escape(` as an escape in \(Self.aliasEscaperFile), and \
                that file no longer binds `\(Self.aliasEscaperIdentifier)` at all. Renamed or \
                removed, the acceptance is unearned and this scan starts passing sites it should \
                fail.
                """)
        let impostors = bindings.filter { !$0.contains(Self.aliasEscaperBinding) }
        #expect(impostors.isEmpty,
                """
                \(Self.aliasEscaperFile) binds `\(Self.aliasEscaperIdentifier)` to something that \
                is NOT `DebugModeManager.escapedForLogLine`, so a bare `escape(` there is not an \
                escape and this scan would accept it as one:
                \(impostors.map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: "\n"))
                """)
    }

    /// Every line binding `name` with `let` or `var` IN CODE, whatever type
    /// annotation or initialiser follows. Deliberately blind to scope.
    ///
    /// ⚠️ **Comments are skipped, and the doc here said the opposite until
    /// 2026-08-12: "a commented-out binding reads as one, which is the false-FAIL
    /// direction". That was affirmatively wrong in the dangerous direction.** A
    /// commented-out canonical binding satisfied BOTH halves of
    /// `escaperAliasStillPointsAtTheEscaper` — it made `bindings` non-empty and it
    /// contained `aliasEscaperBinding`, so it was not an impostor either. A real
    /// impostor binding elsewhere in the file could therefore coexist with this
    /// suite green, and the alias acceptance would be unearned with nothing red.
    ///
    /// Same root cause as round 8's `argumentRange` fix: `lex` computes the comment
    /// spans and the consumer was never given them. Pinned by
    /// `aCommentedOutAliasBindingIsNotABinding`.
    private static func bindingLines(of name: String, in source: String) -> [String] {
        let comments = lex(source).comments
        var found: [String] = []
        for keyword in ["let ", "var "] {
            var cursor = source.startIndex
            while cursor < source.endIndex,
                  let hit = source.range(of: keyword + name, range: cursor..<source.endIndex) {
                cursor = source.index(after: hit.lowerBound)
                if hit.upperBound < source.endIndex {
                    let next = source[hit.upperBound]
                    // a longer identifier that merely starts with `name`
                    if next.isLetter || next.isNumber || next == "_" { continue }
                }
                if comments.contains(where: { $0.contains(hit.lowerBound) }) { continue }
                let start = source[source.startIndex..<hit.lowerBound].lastIndex(of: "\n")
                    .map { source.index(after: $0) } ?? source.startIndex
                let end = source[hit.upperBound...].firstIndex(of: "\n") ?? source.endIndex
                found.append(String(source[start..<end]))
            }
        }
        return found
    }

    /// RED-FIRST FIXTURE for the round-9 finding above. Two-sided: a binding that
    /// exists ONLY in a comment must not count, and a real one in code must still be
    /// found — otherwise the fix could pass by reporting nothing at all, which would
    /// turn `escaperAliasStillPointsAtTheEscaper`'s non-empty check red instead.
    @Test("A binding that exists only in a comment is not a binding")
    func aCommentedOutAliasBindingIsNotABinding() {
        let onlyInAComment = """
        struct S {
            // \(Self.aliasEscaperBinding)
            /* \(Self.aliasEscaperBinding) */
            func f() { print("[X] head") }
        }
        """
        #expect(Self.bindingLines(of: Self.aliasEscaperIdentifier, in: onlyInAComment).isEmpty,
                """
                a commented-out `\(Self.aliasEscaperBinding)` satisfied both the non-empty check \
                and the no-impostor check, so a real impostor binding elsewhere in the file could \
                sit beside it with this suite green
                """)

        // The impostor that shape was hiding: the ONLY binding in code is the fake
        // one, and the canonical text present in the file is prose.
        let impostorBesideACommentedCanonical = """
        struct S {
            // \(Self.aliasEscaperBinding)
            func f(part: Part) {
                let \(Self.aliasEscaperIdentifier) = { (s: String) in s }
                print("[X] \\(\(Self.aliasEscaperIdentifier)(part.filename))")
            }
        }
        """
        let bindings = Self.bindingLines(
            of: Self.aliasEscaperIdentifier, in: impostorBesideACommentedCanonical)
        #expect(bindings.count == 1,
                "exactly the one binding written in CODE must be reported, saw \(bindings)")
        #expect(bindings.allSatisfy { !$0.contains(Self.aliasEscaperBinding) },
                """
                the impostor binding must be reported as an impostor — the commented canonical \
                line must not launder it: \(bindings)
                """)
    }

    /// `scan` finds sinks by raw text, so before the comment skip landed a
    /// `print(` written in PROSE was counted as one. Exactly one such sink existed
    /// in the scanned sources — `AutoSizingHTMLView.fixImageAspectRatioJS`'s
    /// comment — and it was harmless only because the mention is a bare `print()`
    /// with no accessor in it.
    ///
    /// The second half pins the corrected `argumentRange` doc: a multiline (`"""`)
    /// literal at a sink IS parsed, by quote parity. It used to say those surface
    /// as `nil`.
    @Test("A log sink written in a comment is not a sink, and a multiline literal at one is parsed")
    func proseIsNotASinkAndMultilineLiteralsAreParsed() {
        let commented = """
        func a(part: Part) {
            // Lands on the handler, which `print()`s only when logging is enabled.
            /* and a block comment mentioning print("\\(part.filename ?? "?")") too */
            if DebugModeManager.isLoggingEnabled() {
                print("[X] real \\(part.contentType)")
            }
        }
        """
        let commentedResult = Self.scan(source: commented, file: "fixture-commented")
        #expect(commentedResult.sinkCount == 1,
                """
                only the real call is a sink; the two mentions in comments are prose, \
                saw sinkCount=\(commentedResult.sinkCount)
                """)
        #expect(commentedResult.sites.count == 1,
                "the accessor inside the block comment must not produce a site")
        #expect(commentedResult.unparsableSinkLines.isEmpty,
                "a commented sink must not be reported as unparsable either")

        let multiline = """
        func b(part: Part) {
            if DebugModeManager.isLoggingEnabled() {
                print(\"\"\"
                [X] failed for \\(part.filename ?? "?")
                \"\"\")
            }
        }
        """
        let multilineResult = Self.scan(source: multiline, file: "fixture-multiline")
        #expect(multilineResult.unparsableSinkLines.isEmpty,
                """
                a multiline literal at a sink is parsed by quote parity, not surfaced as nil: \
                \(multilineResult.unparsableSinkLines)
                """)
        #expect(multilineResult.sites.count == 1,
                "the accessor inside the multiline literal must still be seen")
    }

    /// RED-FIRST FIXTURE for the missed-site class closed on 2026-08-12.
    ///
    /// `lex` computes comment spans and `scan` uses them to tell a `print(` in code
    /// from one in prose — but they were never passed to `argumentRange`, so a `)`
    /// inside a comment INSIDE A SINK'S OWN ARGUMENT LIST closed the range there.
    /// Every accessor past that point went unexamined while the sink was still
    /// counted and `unparsableSinkLines` stayed empty: a silently missed site, the
    /// false-PASS direction. `#"…"#` raw strings had the same effect and were also
    /// unhandled.
    ///
    /// Each case carries its own CONTROL — the identical source with the offending
    /// `)` removed — so a failure distinguishes "the fixture stopped presenting a
    /// site" from "the scanner stopped seeing it".
    @Test("A comment or raw string inside a sink's argument list does not close it")
    func aCommentInsideASinkArgumentListDoesNotCloseIt() {
        func wrap(_ sink: String) -> String {
            """
            func f(part: Part) {
                if DebugModeManager.isLoggingEnabled() {
                    \(sink)
                }
            }
            """
        }
        let cases: [(String, String, String)] = [
            ("block comment",
             wrap(#"print("[X] head", /* a ) here */ part.filename ?? "?")"#),
             wrap(#"print("[X] head", /* a here */ part.filename ?? "?")"#)),
            ("line comment",
             wrap("print(\"[X] head\",   // a ) here\n            part.filename ?? \"?\")"),
             wrap("print(\"[X] head\",   // a here\n            part.filename ?? \"?\")")),
            ("raw string literal",
             wrap(##"print(#"a " b )"# + (part.filename ?? "?"))"##),
             wrap(##"print(#"a " b "# + (part.filename ?? "?"))"##)),
        ]
        for (label, hostile, control) in cases {
            let controlResult = Self.scan(source: control, file: "fixture-control-\(label)")
            #expect(controlResult.sites.count == 1,
                    "the `\(label)` CONTROL must present one accessor use, saw \(controlResult.sites.count)")

            let result = Self.scan(source: hostile, file: "fixture-\(label)")
            #expect(result.sinkCount == 1,
                    "the `\(label)` fixture must present exactly one sink, saw \(result.sinkCount)")
            #expect(result.unparsableSinkLines.isEmpty,
                    """
                    the `\(label)` fixture must be parsable — an unparsable sink is the LOUD \
                    failure direction, and the defect this pins is the silent one: \
                    \(result.unparsableSinkLines)
                    """)
            #expect(result.sites.count == 1,
                    """
                    a `)` inside a \(label) closed the sink's argument range early, so the \
                    accessor past it was never examined — a MISSED SITE, invisible to every \
                    other assertion here because the sink is still counted
                    """)
        }
    }

    // MARK: The gate detector's own two sides

    /// RED-FIRST FIXTURE for the false-PASS the enclosure detector replaced.
    ///
    /// Both shapes below were reported `gated=true` by the proximity detector
    /// this suite used until 2026-08-12 — a `#if DEBUG` block whose `#endif`
    /// precedes the sink, and an `if isLoggingEnabled() { … }` belonging to a
    /// preceding statement. Neither encloses the sink; both sinks run in RELEASE.
    /// Captured against both detectors in `scratchpad/R6-RED-EVIDENCE.txt`.
    @Test("A CLOSED debug block above a sink is not a gate")
    func aClosedDebugBlockAboveASinkIsNotAGate() {
        let closedIfdef = """
        func f(part: Part) {
            #if DEBUG
            if let hook = testHook { hook() }
            #endif
            guard ok else {
                print("[X] failed for \\(part.filename ?? "?")")
                return
            }
        }
        """
        let ifdefResult = Self.scan(source: closedIfdef, file: "fixture-closed-ifdef")
        #expect(ifdefResult.sites.count == 1, "fixture should present exactly one accessor use")
        #expect(ifdefResult.sites.first?.gated == false,
                "a `#if DEBUG` block closed above the sink does not gate it")

        let closedRuntimeGate = """
        func g(part: Part) {
            do {
                try work()
            } catch {
                if DebugModeManager.isLoggingEnabled() {
                    print("[X] soft failure")
                }
                print("[X] hard failure for \\(part.contentType)")
            }
        }
        """
        let runtimeResult = Self.scan(source: closedRuntimeGate, file: "fixture-closed-gate")
        #expect(runtimeResult.sites.count == 1, "fixture should present exactly one accessor use")
        #expect(runtimeResult.sites.first?.gated == false,
                "a sibling `if isLoggingEnabled() { }` block does not gate what follows it")
    }

    /// The other side. A detector that answered `false` unconditionally would
    /// pass the fixture above and make `senderAuthoredValueSinksAreDebugGated`
    /// fail on correct code — so the shapes that DO enclose must stay gated,
    /// including a gate far enough above the sink that no proximity window would
    /// have reached it.
    ///
    /// The distance is not asserted as a literal here, and neither is it described
    /// in prose. It is DERIVED from the fixture at run time and checked, because
    /// this fixture previously carried a gate FOUR lines above its sink while its
    /// message, its doc and `8f408fbcb`'s body all said six — a number that was
    /// true of a real gate in `IMAPProvider.buildFullMessageInfo` and false of
    /// anything here.
    @Test("A gate that encloses the sink still reads as gated, however far above it sits")
    func anEnclosingGateReadsAsGated() {
        let enclosing = """
        func h(part: Part) {
            if DebugModeManager.isLoggingEnabled() {
                // a comment with a stray brace { in it
                let banner = "and a string with a brace { in it"
                /* a nested /* block comment */ with a } in it */
                let multi = \"\"\"
                a multiline literal with a { and a } in it
                \"\"\"
                if banner.isEmpty {
                    // an ordinary nested scope, opened and closed again
                }
                do {
                    try work()
                } catch {
                    // a catch arm, opened and closed again
                }
                switch part.section {
                case .first:
                    break
                default:
                    break
                }
                while false {
                    // and a loop, opened and closed again
                }
                for p in parts {
                    print("[X] \\(banner) \\(multi) \\(p.filename ?? "nil")")
                }
            }
            #if DEBUG
            print("[X] ifdef \\(part.contentId)")
            #endif
            guard DebugModeManager.isLoggingEnabled() else { return }
            print("[X] guarded \\(part.contentType)")
        }
        """
        // Derived, so the sentence below cannot go stale the way the old one did.
        let fixtureLines = enclosing.split(separator: "\n", omittingEmptySubsequences: false)
        let gateLine = fixtureLines.firstIndex { $0.contains("if DebugModeManager.isLoggingEnabled()") }
        let sinkLine = fixtureLines.firstIndex { $0.contains("\\(banner)") }
        #expect(gateLine != nil && sinkLine != nil,
                "the fixture no longer contains the runtime gate or the sink this test measures")
        let distance = (sinkLine ?? 0) - (gateLine ?? 0)
        // The retired proximity heuristic looked at `gateProximityLines = 6` lines
        // plus the sink's own, so anything past 7 is beyond it. 15 leaves margin
        // for editing the fixture without silently re-entering the old window.
        #expect(distance >= 15,
                """
                the enclosing gate is only \(distance) lines above the sink, which a proximity \
                window could plausibly have reached — this fixture exists to prove ENCLOSURE, so \
                the distance must stay past any such window
                """)

        let result = Self.scan(source: enclosing, file: "fixture-enclosing")
        #expect(result.sites.count == 3, "fixture should present exactly three accessor uses")
        let ungated = result.sites.filter { !$0.gated }
        #expect(ungated.isEmpty,
                """
                every sink here is enclosed by a gate — a runtime gate \(distance) lines up whose \
                body also contains a brace in a comment, in a string, in a nested block comment \
                and in a multiline literal, plus four sibling scopes opened and closed in between; \
                an open `#if DEBUG`; and a `guard` gate covering the rest of the scope: \
                \(ungated.map(\.description).joined(separator: "\n"))
                """)
    }

    /// RED-FIRST FIXTURE for the false-PASS class this detector kept producing —
    /// FOUR CONSECUTIVE ROUNDS, each fix correct and each followed by another.
    ///
    /// Round 6 found proximity where enclosure was meant. Round 7 found conditions
    /// that invert from the LEFT of the token and fixed them by REJECTING `!` and
    /// `||` there. Round 8 found the mirror — everything to the RIGHT of the token,
    /// plus two branches that never consulted the condition at all — and replaced
    /// the denylist of dangerous operators with an ALLOWLIST of provable
    /// conjunctions.
    ///
    /// **That allowlist HELD.** Round 9's two reviewers could not break it on
    /// condition grammar: not on operator precedence, not on comma injection, not on
    /// comments in the prefix, not on delimiter imbalance. They broke the LEXER
    /// underneath it instead, three times over, and `roundNineFalsePasses` below is
    /// exactly those three.
    ///
    /// So the lesson is no longer "allowlist, not denylist" — that was round 8's, it
    /// was right, and it was insufficient. It is that a decision procedure is only
    /// as sound as the thing that feeds it, and that the way to stop paying for a
    /// parser is to stop needing one. `lex` now recognises two exact strings and
    /// treats every other input as ungated, so there is no condition analysis left
    /// for a Swift shape to fool.
    ///
    /// The `armed` half is load-bearing twice over: without it the fix could pass by
    /// refusing everything, and `senderAuthoredValueSinksAreDebugGated` would then
    /// fail on correct code.
    ///
    /// Captured against both detectors in `scratchpad/R9-RED-EVIDENCE.txt` (round
    /// 8's is in `R8-RED-EVIDENCE.txt`, round 7's in `R7-RED-EVIDENCE.txt`).
    @Test("Only an exact canonical gate spelling arms a gate")
    func onlyACanonicalGateSpellingArmsTheGate() {
        /// Each fixture carries exactly one sender-authored accessor at its sink,
        /// so `sites.count == 1` is itself a check that the shape reached the
        /// scanner rather than being skipped.
        func fixture(_ condition: String, guardShape: Bool = false) -> String {
            guardShape
                ? """
                  func f(part: Part, force: Bool, changed: Bool, x: [Int], y: Bool?) {
                      \(condition)
                      print("[X] \\(part.filename ?? "?")")
                  }
                  """
                : """
                  func f(part: Part, force: Bool, changed: Bool, x: [Int], y: Bool?) {
                      \(condition)
                          print("[X] \\(part.filename ?? "?")")
                      }
                  }
                  """
        }

        func expectUngated(_ label: String, _ source: String) {
            let result = Self.scan(source: source, file: "fixture-\(label)")
            #expect(result.sites.count == 1,
                    "fixture `\(label)` should present exactly one accessor use, saw \(result.sites.count)")
            #expect(result.sites.first?.gated == false,
                    """
                    `\(label)` reads as GATED, but the sink runs in a release build: only a \
                    line that BEGINS with an exact canonical gate spelling may arm one
                    """)
        }

        // ROUND 9. None of these is a condition-grammar defect — each one confused
        // the LEXER, and each was reported `gated=true` by the round-8 detector.
        //
        //   1. BRACE BINDING. `pending` bound to the first `{` the lexer met after
        //      the keyword, which here belongs to a closure IN THE CONDITION. The
        //      guard's `gatedFrom` then covered the else arm — the code that runs
        //      when the gate is FALSE — and everything after it.
        //   2. REGEX LITERAL. `/\{/` matches a literal brace. To the old lexer the
        //      `{` opened a scope, so the gate body's own `}` closed that phantom
        //      instead and the gate stayed open over the release sink below.
        //   3. SWITCH CASE. A case body is not a brace scope, so a `guard` gate in
        //      `case .a` gated the rest of the switch, including `case .b`, which
        //      the guard never ran for.
        let roundNineFalsePasses: [(String, String)] = [
            ("brace binding — a closure in the condition", """
             func f(part: Part) {
                 guard DebugModeManager.isLoggingEnabled(), attempt({ }) else {
                     print("[X] \\(part.filename ?? "?")")
                     return
                 }
             }
             """),
            ("regex literal in a gate body", """
             func f(part: Part) {
                 if DebugModeManager.isLoggingEnabled() {
                     let opener = /\\{/
                     _ = opener
                 }
                 print("[X] \\(part.filename ?? "?")")
             }
             """),
            ("guard gate in case .a, sink in case .b", """
             func f(part: Part, which: Kind) {
                 switch which {
                 case .a:
                     guard DebugModeManager.isLoggingEnabled() else { return }
                     print("[X] genuinely gated")
                 case .b:
                     print("[X] \\(part.filename ?? "?")")
                 }
             }
             """),
        ]
        for (label, source) in roundNineFalsePasses { expectUngated(label, source) }

        // Shapes the canonical allowlist REFUSES that the round-8 allowlist armed.
        // Each is a genuine runtime gate; refusing it is a false FAIL, which is the
        // safe direction and is why none of them may enclose one of the 12 sites.
        let refusedButReal: [(String, String)] = [
            ("if gate, other", fixture("if DebugModeManager.isLoggingEnabled(), !x.isEmpty {")),
            ("if other, gate", fixture("if changed, DebugModeManager.isLoggingEnabled() {")),
            ("if gate && other", fixture("if DebugModeManager.isLoggingEnabled() && !x.isEmpty {")),
            ("if other && gate", fixture("if changed && DebugModeManager.isLoggingEnabled() {")),
            ("while gate", fixture("while DebugModeManager.isLoggingEnabled() {")),
            ("if gate, brace on the next line",
             fixture("if DebugModeManager.isLoggingEnabled()\n    {")),
            ("guard gate, other else",
             fixture("guard DebugModeManager.isLoggingEnabled(), changed else { return }",
                     guardShape: true)),
        ]
        for (label, source) in refusedButReal { expectUngated(label, source) }

        // Rounds 7 and 8, kept as regression anchors: these are NOT gates, and the
        // canonical allowlist must go on refusing them for its own reason.
        let disarmed: [(String, String)] = [
            ("if gate || force", fixture("if DebugModeManager.isLoggingEnabled() || force {")),
            ("guard gate || force else",
             fixture("guard DebugModeManager.isLoggingEnabled() || force else { return }",
                     guardShape: true)),
            ("if changed, gate || force",
             fixture("if changed, DebugModeManager.isLoggingEnabled() || force {")),
            ("if gate == false", fixture("if DebugModeManager.isLoggingEnabled() == false {")),
            ("if gate != true", fixture("if DebugModeManager.isLoggingEnabled() != true {")),
            ("if gate ? true : force",
             fixture("if DebugModeManager.isLoggingEnabled() ? true : force {")),
            ("if y ?? gate", fixture("if y ?? DebugModeManager.isLoggingEnabled() {")),
            ("if shouldLog(gate)", fixture("if shouldLog(DebugModeManager.isLoggingEnabled()) {")),
            ("if force || gate", fixture("if force || DebugModeManager.isLoggingEnabled() {")),
            ("if !gate", fixture("if !DebugModeManager.isLoggingEnabled() {")),
            ("guard !gate else",
             fixture("guard !DebugModeManager.isLoggingEnabled() else { return }",
                     guardShape: true)),
            ("if gate\\n || force",
             fixture("if DebugModeManager.isLoggingEnabled()\n        || force {")),
        ]
        for (label, source) in disarmed { expectUngated(label, source) }

        // `else if` needs a preceding `if` arm, so it cannot use `fixture`. Round 8
        // ADDED this spelling because `IMAPProvider.move` is that shape; round 9
        // removes it again, because a line beginning with `}` is not a canonical
        // spelling and `IMAPProvider.move` encloses no accessor site.
        expectUngated("} else if gate {", """
        func f(part: Part, ok: Bool) {
            if ok {
                work()
            } else if DebugModeManager.isLoggingEnabled() {
                print("[X] \\(part.filename ?? "?")")
            }
        }
        """)

        // The other side. Every canonical spelling, including the one-line body form
        // that the PREFIX match — rather than a whole-line match — is what buys.
        let armed: [(String, String)] = [
            ("if gate {", fixture("if DebugModeManager.isLoggingEnabled() {")),
            ("guard gate else",
             fixture("guard DebugModeManager.isLoggingEnabled() else { return }", guardShape: true)),
            ("if gate { SINK } on one line", """
             func f(part: Part) {
                 if DebugModeManager.isLoggingEnabled() { print("[X] \\(part.filename ?? "?")") }
             }
             """),
            ("#if DEBUG", """
             func f(part: Part) {
                 #if DEBUG
                 print("[X] \\(part.filename ?? "?")")
                 #endif
             }
             """),
        ]
        for (label, source) in armed {
            let result = Self.scan(source: source, file: "fixture-\(label)")
            #expect(result.sites.count == 1,
                    "fixture `\(label)` should present exactly one accessor use, saw \(result.sites.count)")
            #expect(result.sites.first?.gated == true,
                    "`\(label)` is a canonical spelling enclosing the sink and must read as gated")
        }
    }

    /// The fail-closed half of `lex`, driven directly: an input the lexer cannot
    /// classify must SURRENDER, and a surrender must leave everything after it
    /// ungated rather than carry a stale scope forward.
    ///
    /// Separate from the fixtures above because these are not gate SPELLINGS — they
    /// are the lexer's own error paths, and a detector can get every spelling right
    /// while silently mis-tracking braces past an input it never understood. That is
    /// precisely how rounds 6-9 kept happening.
    @Test("An input the lexer cannot classify gates nothing after it")
    func anUnclassifiableInputSurrenders() {
        // Each source gates the FIRST sink (before the unclassifiable input) and
        // must NOT gate the second (after it). Two-sided per case, so a lexer that
        // surrendered unconditionally could not pass.
        let cases: [(String, String)] = [
            ("regex literal", """
             func f(part: Part) {
                 if DebugModeManager.isLoggingEnabled() {
                     print("[X] before \\(part.filename ?? "?")")
                     let opener = /\\{/
                     _ = opener
                     print("[X] after \\(part.contentType)")
                 }
             }
             """),
            // Not valid Swift today, and that is the point: an unrecognised `#`
            // form must surrender rather than be stepped over as if understood.
            // `#"…"#`, `#if`, and `#file`-style literals are all classified.
            ("unclassified hash", """
             func f(part: Part) {
                 if DebugModeManager.isLoggingEnabled() {
                     print("[X] before \\(part.filename ?? "?")")
                     let n = #42
                     _ = n
                     print("[X] after \\(part.contentType)")
                 }
             }
             """),
            ("unbalanced closing brace", """
             func f(part: Part) {
                 if DebugModeManager.isLoggingEnabled() {
                     print("[X] before \\(part.filename ?? "?")")
                 }
             }
             }
             if DebugModeManager.isLoggingEnabled() {
                 print("[X] after \\(part.contentType)")
             }
             """),
        ]
        for (label, source) in cases {
            let result = Self.scan(source: source, file: "fixture-surrender-\(label)")
            #expect(result.sites.count == 2,
                    "the `\(label)` fixture must present two accessor uses, saw \(result.sites.count)")
            guard result.sites.count == 2 else { continue }
            #expect(result.sites[0].gated == true,
                    """
                    `\(label)`: the sink BEFORE the unclassifiable input is genuinely inside the \
                    gate body and must still read gated — otherwise this test would pass for a \
                    lexer that gives up on everything
                    """)
            #expect(result.sites[1].gated == false,
                    """
                    `\(label)`: the lexer met an input it cannot classify and then reported the \
                    sink after it as GATED. Every ambiguity must resolve to ungated — a regex \
                    body can carry a brace, and a brace it mis-tracks moves every scope boundary \
                    after it
                    """)
        }
    }
}
