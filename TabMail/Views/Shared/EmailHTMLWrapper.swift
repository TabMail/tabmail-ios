/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// Wraps email message HTML with TabMail's viewport, CSS, and unwrap-full-document
/// handling. Produces the HTML string that HTMLWebView loads into WKWebView.
///
/// Pure string transformation — no view state, no side effects. Callable from any
/// isolation context.
enum EmailHTMLWrapper {

    /// The app-owned Content-Security-Policy embedded in the `<head>` of **every**
    /// document `wrapHTML` emits (ADR-IOS-076 decision 1, including the 2026-08-12
    /// owner-directed `font-src` relaxation). This constant is the live value.
    ///
    /// ## ⚠️ THE INVARIANT THIS DEPENDS ON — do not weaken it, and do not add a second builder
    ///
    /// **`wrapHTML` MUST always emit ONE complete, app-owned document with this policy in
    /// `<head>` before any author-controlled element; no caller may load raw message HTML
    /// into a render web view.**
    ///
    /// This is what makes a `<meta>`-delivered CSP sound here. Meta delivery is appropriate for
    /// `loadHTMLString` with a custom-scheme base URL (ADR-IOS-076, confirmed), and the *fragment*
    /// branch of `wrapHTML` is safe **because of the sentence above**: the author's bytes are
    /// interpolated into `<body>`, strictly after our `<head>`, so the policy is already in force
    /// when the parser reaches them. An author CSP `<meta>` inside the body can only combine
    /// **restrictively** with ours, never relax it — so a hostile document cannot widen this by
    /// declaring its own. Break the invariant (load a raw fragment, or build a second document
    /// somewhere else) and the whole layer is gone with no compile error to say so.
    ///
    /// `frame-ancestors`, `sandbox` and `report-uri` are **header-only** and are SILENTLY IGNORED
    /// in a `<meta>` CSP. They are deliberately absent; do not add them here and assume coverage.
    ///
    /// ## Why each directive, derived from what this render path actually does
    ///
    /// - `default-src 'none'` — the backstop (plan §8.2, accepted vet finding). Without it, any
    ///   resource class nobody thought to name stays permitted. Every directive below is a
    ///   deliberate widening of this one.
    /// - `script-src 'none'` — belt-and-braces with `allowsContentJavaScript = false`, and it also
    ///   covers `javascript:` URLs. It does **not** touch the 17 `WKUserScript`s that drive this
    ///   pipeline: WebKit evaluates injected user-script source directly, while `script-src`
    ///   governs *document-requested* script mechanisms — `<script>` elements, `javascript:` URLs,
    ///   `eval`/`Function` (plan §8.1, refuting round 1's premise). Independently: those scripts
    ///   contain **zero** eval-family constructs, re-counted at implementation time, so even under
    ///   the wrong premise nothing here is `script-src`-sensitive. Measured, not reasoned:
    ///   `EmailRenderSecurityCanaryTests.authorScriptExecutesToday` reads the app's own bridge
    ///   function back out of a live render under this exact policy.
    ///   ⚠️ **Re-counting needs care — this sentence is now part of the search space.** The census
    ///   is over `AutoSizingHTMLView.swift` (where the scripts live), and it counts the four
    ///   eval-family spellings *as JS source in the user scripts*; this paragraph names them in
    ///   prose, so a repo-wide grep will match HERE and score a false positive. Count call sites,
    ///   not identifier hits — the same trap the content-world note in `AutoSizingHTMLView.swift`
    ///   documents. At implementation time: 17 `WKUserScript(` call sites in `makeUIView`, all four
    ///   eval-family spellings at 0.
    ///   ⚠️ A future injected script that calls `eval`, builds a `Function`, or appends a `<script>`
    ///   element **is** document-requested script and this directive will block it.
    /// - `style-src 'unsafe-inline'` — **mandatory, not a corner to harden.** This wrapper emits its
    ///   own `<style>` block, `unwrapFullHTMLDocument` lifts the author's `<style>` blocks out of
    ///   `<head>` into the content, our own scripts write inline styles (dark-mode fixing, width
    ///   constraint, gutter cropping), and essentially all real HTML email depends on `style=`
    ///   attributes. A policy without `'unsafe-inline'` here destroys rendering. No scheme source
    ///   and no `'self'`: external stylesheets stay blocked — `wrapHTML` already strips
    ///   `<link rel=stylesheet>` by regex, and this is the backstop for the shapes that regex
    ///   misses (plan §9.2 records that the wrapper's regexes do not preserve HTML parsing
    ///   semantics), plus `@import` inside a `<style>` block.
    /// - `img-src https: data: <asset scheme>:` — the three sources that actually load. `https:`
    ///   for remote images (`deferredImageLoadJS` restores the original URL after first paint);
    ///   `data:` because the compose-quote, `.eml`-preview and tooltip paths register no scheme
    ///   handler and `BodyRenderer` falls back to base64 data URIs there; the asset scheme for
    ///   `BodyAssetSchemeHandler`-served inline images on a persisted body. `http:` is absent
    ///   *because* `upgrade-insecure-requests` below rewrites it to `https:` before the policy is
    ///   enforced. **`cid:` is deliberately absent**: `BodyRenderer` replaces every resolvable
    ///   `cid:` with an asset URL or a data URI and no `cid:` handler is registered, so a leftover
    ///   `cid:` is by definition unresolved and cannot load whatever the policy says (plan §3,
    ///   round-1 vet — the original justification for including it was false).
    /// - `font-src https:` — **relaxed from `'none'` by explicit owner directive, 2026-08-12.**
    ///   P1b shipped `font-src 'none'`, justified as closing the `@font-face` + `unicode-range`
    ///   conditional-request channel (T9), which survives disabling JavaScript. The owner's
    ///   runtime smoke test the same day measured the cost: an HTTPS web font was refused by the
    ///   enforced policy and the message rendered in a fallback font — a visible change from `v1.7.8` under the standing directive
    ///   *"no behaviour changes, just security"*.
    ///   **The anti-tracking rationale did not survive contact with the rest of this policy.**
    ///   `img-src` is `https:`, and the same capture shows image subresource requests leaving the
    ///   device regardless, so the correlation channel `font-src 'none'` closed is wide open through
    ///   images. Visible cost, ~zero marginal privacy gain.
    ///   **The counter-argument was weighed and DECLINED — recorded so it is not rediscovered:**
    ///   downloadable-font parsing is a real remote-code-execution surface (recurring
    ///   CoreText/FreeType CVEs) and `'none'` removed it. The owner priced that against the shipped
    ///   rendering behaviour on 2026-08-12 and chose the behaviour. **That is the decision. Do not
    ///   re-argue it here, and do not hedge it into a domain allowlist.**
    ///   `https:` and *not* `*`, *not* `https: data:`: it mirrors the `img-src` posture — remote
    ///   fetch over TLS only — so the two remote-content directives stay consistent.
    ///
    ///   **⚠️ Scope, stated negatively, because it is easy to get wrong in BOTH directions.** This
    ///   restores **every remote font that ever worked** — i.e. fonts fetched over absolute
    ///   `https:`. Two classes stay blocked, and only the first is a behaviour delta:
    ///   1. **`data:`-URI fonts — a real, if small, regression against `v1.7.8`.** That release's
    ///      entire policy was `upgrade-insecure-requests`, with no `font-src` and no `default-src`,
    ///      so a `data:` font loaded there and is refused here. Accepted deliberately: `https:`
    ///      mirrors `img-src`, and nothing legitimate in this pipeline needs a `data:` font.
    ///   2. **Protocol-relative `//host/path` font URLs in author CSS — NOT a loss.** They resolve
    ///      against the document base `BodyAssetConfig.baseURL` (`tabmail-asset://asset/`), so
    ///      `//fonts.gstatic.com/x.woff` becomes `tabmail-asset://fonts.gstatic.com/x.woff` — host
    ///      `fonts.gstatic.com`, not `asset`. `v1.7.8` passed that same base URL for persisted
    ///      bodies, and its `BodyAssetStore.assetId(fromURL:)` required the host to be a
    ///      fixed-length hex hash, so the request was already failed with
    ///      `URLError(.resourceUnavailable)` at the scheme handler. **These have never been
    ///      fetchable; the CSP only moved the rejection point.** Measured in one device capture:
    ///      45 such blocks alongside 59 absolute-`https:` ones.
    ///      ⚠️ **Do NOT add `\(BodyAssetConfig.urlScheme):` here to "fix" them** — the request would
    ///      simply reach `BodyAssetSchemeHandler` again, whose `canonicalAssetId` rejects a non-hex
    ///      host. It would widen policy surface and load exactly zero additional fonts.
    /// - `media-src 'none'` — nothing in this pipeline plays media; `enforceMediaDisplayJS` is about
    ///   CSS `@media` display rules, not `<video>`/`<audio>`. Cost: a `<video>`/`<audio>` source in
    ///   an email does not load. **RETAINED in the same 2026-08-12 directive that relaxed
    ///   `font-src`** — the owner declined to relax it. Scope of that decision, stated rather than
    ///   implied: it rests on the smoke test recording **zero** `media-src` violations, i.e. no
    ///   observed cost — not on a claim that no email anywhere embeds media.
    /// - `object-src 'none'`, `frame-src 'none'` — the render document legitimately needs neither.
    ///   `frame-src` additionally means a sender `<iframe>` never becomes a nested browsing context,
    ///   so the subframe branch of the navigation policy becomes belt-and-braces rather than the
    ///   only line of defence.
    /// - `connect-src 'none'` — no fetch/XHR/beacon/WebSocket. It does **not** affect
    ///   `webkit.messageHandlers`, which is not a fetch surface (ADR-IOS-076 decision 7), so the
    ///   `heightChanged` / `consoleLog` / `gutterAdjust` bridge is unaffected.
    /// - `form-action 'none'` — an auto-submitted form is a main-frame navigation with no script.
    /// - `base-uri 'none'` — an author `<base href>` would re-point every relative URL in the
    ///   document, including asset references, after our head has been parsed.
    /// - `upgrade-insecure-requests` — **kept**; it is the policy that shipped, and it is what makes
    ///   omitting `http:` from `img-src` a no-op rather than a regression (the upgrade runs before
    ///   CSP enforcement in the fetch algorithm).
    ///
    /// Pinned by `EmailRenderSecurityCanaryTests` — the directive list, the in-`<head>`-before-author
    /// ordering on **both** `wrapHTML` branches, and the measured behaviour under a real `WKWebView`.
    static let contentSecurityPolicy: String = [
        "default-src 'none'",
        "script-src 'none'",
        "style-src 'unsafe-inline'",
        "img-src https: data: \(BodyAssetConfig.urlScheme):",
        "font-src https:",
        "media-src 'none'",
        "object-src 'none'",
        "frame-src 'none'",
        "connect-src 'none'",
        "form-action 'none'",
        "base-uri 'none'",
        "upgrade-insecure-requests"
    ].joined(separator: "; ")

    /// CSS wrapper with dark mode text overrides (mirrors Thunderbird addon approach)
    /// and word-break rules to prevent long URLs from causing extreme zoom-out.
    ///
    /// If the body is already a full HTML document (starts with `<html` or `<!DOCTYPE`),
    /// the outer `<html>/<head>/<body>` tags are unwrapped first to avoid nested `<html>`
    /// which breaks WKWebView `document.body.scrollHeight` measurement.
    /// Email `<style>` blocks are preserved; `<html>`/`<body>` become `<div>` to keep
    /// any inline styles on those tags.
    ///
    /// - Parameter previewFilename: When non-nil, emits preview-mode CSS that hides
    ///   everything except the `<div class="tm-eml-section" data-filename="…">` matching
    ///   this filename. Used by `EmlAttachmentPreview` to show a single attached .eml.
    ///   When nil (default, main view mode), emits CSS that hides ALL `.tm-eml-section`
    ///   blocks so they don't appear inline in the message body.
    static func wrapHTML(_ body: String, previewFilename: String? = nil) -> String {
        var content: String
        let lower = body.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if lower.hasPrefix("<!doctype") || lower.hasPrefix("<html") {
            if DebugModeManager.isLoggingEnabled() {
                print("[HTMLDebug] wrapHTML: full document detected, inputLen=\(body.count), calling unwrapFullHTMLDocument")
            }
            content = unwrapFullHTMLDocument(body)
            if DebugModeManager.isLoggingEnabled() {
                print("[HTMLDebug] wrapHTML: after unwrap, outputLen=\(content.count), delta=\(body.count - content.count)")
                let preview = String(content.prefix(300))
                print("[HTMLDebug] wrapHTML: unwrapped content preview: \(preview)")
            }
        } else {
            if DebugModeManager.isLoggingEnabled() {
                print("[HTMLDebug] wrapHTML: fragment mode, inputLen=\(body.count)")
            }
            content = body
        }

        // Strip loading="lazy" from images — prevents chicken-and-egg deadlock
        // where lazy images in a 0-height container never enter the viewport
        // and thus never load, keeping the container at 0 height forever.
        content = content.replacingOccurrences(
            of: #"\s+loading\s*=\s*"lazy""#, with: "", options: .regularExpression
        )

        // Strip external render-blocking <link rel="stylesheet"> (e.g. Google
        // Fonts). WebKit blocks the FIRST PAINT until every external stylesheet
        // loads — a slow remote CSS leaves the email a correctly-SIZED but EMPTY
        // box until it resolves, then paints all at once. Diagnosed on a 107KB
        // newsletter (logmain.log 2026-06-17): frame sized at +196ms but the
        // first compositor frame (`first rAF`) didn't fire until +2771ms,
        // matching readyState=complete — gated on a `fonts.googleapis.com`
        // <link> taking ~2.6s; the opacity reveal (rAF-based) was starved the
        // whole time. These links are virtually always web-font imports, so
        // dropping them lets the email paint immediately with fallback fonts
        // (layout is inline/`<style>`). Also a privacy win: external CSS is a
        // remote-tracking vector, same as remote images. Matches the <link> in
        // <head>, <body>, or revealed inside an mso conditional comment, both
        // attribute orderings. `<style>` blocks are NOT touched.
        let stylesheetLinkPattern = #"<link\b[^>]*\brel\s*=\s*["']?stylesheet[^>]*>"#
        content = content.replacingOccurrences(
            of: stylesheetLinkPattern, with: "", options: [.regularExpression, .caseInsensitive]
        )

        // Defer REMOTE <img> loading so it doesn't block the first paint. WebKit
        // holds the first compositor frame until readyState=complete, which waits
        // on EVERY pending subresource — the Vancouver Sun newsletter had 28 remote
        // images (incl. tracking pixels) that took ~2.7s, leaving the email a
        // correctly-SIZED but EMPTY box (logmain.log 2026-06-17: IMAGE AUDIT
        // total=28 pending=28; `first rAF` == readyState=complete == +2732ms).
        // Rewriting remote http(s) src/srcset → data-tmsrc(set) leaves the initial
        // document with NO pending image loads → complete fires at ~DOMContentLoaded
        // → text/layout paints immediately (Apple-Mail-like). `deferredImageLoadJS`
        // swaps the real URLs back in AFTER the first paint, so images stream in and
        // the frame grows via the ResizeObserver. Only http/https is touched —
        // cid:/data:/local scheme-handler images (fast, load-bearing) are left alone.
        // (NOTE: we deliberately AUTO-load, not block-with-banner — block-with-banner
        // was smoke-tested 2026-06-17 and broke too many messages; deferred load
        // keeps every message rendering normally, just text-first.)
        let imgSrcDouble = #"(<img\b[^>]*?)\ssrc(\s*=\s*)"(https?://[^"]*)""#
        let imgSrcSingle = #"(<img\b[^>]*?)\ssrc(\s*=\s*)'(https?://[^']*)'"#
        let imgSrcsetDouble = #"(<img\b[^>]*?)\ssrcset(\s*=\s*)"([^"]*https?://[^"]*)""#
        let imgSrcsetSingle = #"(<img\b[^>]*?)\ssrcset(\s*=\s*)'([^']*https?://[^']*)'"#
        let imgOpts: NSString.CompareOptions = [.regularExpression, .caseInsensitive]
        content = content.replacingOccurrences(of: imgSrcDouble, with: "$1 data-tmsrc$2\"$3\"", options: imgOpts)
        content = content.replacingOccurrences(of: imgSrcSingle, with: "$1 data-tmsrc$2'$3'", options: imgOpts)
        content = content.replacingOccurrences(of: imgSrcsetDouble, with: "$1 data-tmsrcset$2\"$3\"", options: imgOpts)
        content = content.replacingOccurrences(of: imgSrcsetSingle, with: "$1 data-tmsrcset$2'$3'", options: imgOpts)

        let viewModeCSS: String
        let bodyClass: String
        if let filename = previewFilename {
            // Preview mode — show ONLY the matching <div class="tm-eml-section" data-filename="…">.
            // The native Swift sheet (EmlAttachmentPreview) renders the envelope (subject, from,
            // date, to/cc) from `data-*` attributes, so we also hide the embedded `.tm-eml-headers`
            // to avoid a duplicated HTML envelope below the native header.
            let escaped = escapeCSSAttrValue(filename)
            viewModeCSS = """
            body.tm-preview-mode > *:not(.tm-eml-section) { display: none !important; }
            body.tm-preview-mode .tm-eml-section { display: none !important; }
            body.tm-preview-mode .tm-eml-section[data-filename="\(escaped)"] { display: block !important; }
            body.tm-preview-mode .tm-eml-headers { display: none !important; }
            """
            bodyClass = " class=\"tm-preview-mode\""
        } else {
            // Main view mode — hide the embedded .eml marker sections (they're available
            // via the attachment list's preview sheet).
            viewModeCSS = ".tm-eml-section { display: none !important; }"
            bodyClass = ""
        }

        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=5, user-scalable=yes">
        <meta http-equiv="Content-Security-Policy" content="\(contentSecurityPolicy)">
        <style>
            /* Force html and body to content-sized. Without this, WebKit's
               layout viewport height cascades through `html { height: 100% }`
               into `body { min-height: 100% }` (via email-authored CSS or
               browser defaults), which makes `documentElement.scrollHeight`
               grow with the WKWebView frame height — the classic feedback
               loop that also bleeds ~15pt of sub-pixel scroll into the
               rendered view. Sizing html/body strictly to content closes
               that gap so `body.scrollHeight * scale` matches the rendered
               content exactly. */
            html, body { height: auto !important; min-height: 0 !important; max-height: none !important; }
            /* Prevent sub-pixel horizontal scroll in WKWebView. A single
               descendant 1 px wider than the viewport (e.g. content-box
               `width:100%` + padding, or 100vw including a scrollbar
               gutter) makes WKWebView's UIScrollView scrollable along X,
               which reads as "slight horizontal scroll that screws things
               up". `body { overflow-x: clip }` alone is not enough —
               WebKit bug 153852 tracks body's overflow being ignored on
               iOS. Clamping html with overflow-x:clip closes that leak
               at the root.

               USE `clip`, NOT `hidden`. Per CSS Overflow L3, when one axis
               is a scrolling value (hidden/scroll/auto) and the other is
               `visible`, the visible axis computes to `auto` — so
               `overflow-x: hidden` here would silently turn html/body into
               Y-scroll containers. A late reflow (the deferred-image swap in
               AutoSizingHTMLView) then leaves a stray `body.scrollTop` that
               WebKit doesn't re-clamp, so the email renders scrolled ~13px
               INSIDE the card instead of the page scrolling — the "inner
               content scrolls, not the page" bug. `clip` is NOT a scrolling
               value: it clips X without promoting overflow-y, so html/body
               never become scroll containers and the stray offset is
               structurally impossible. (WebKit implements no scroll
               anchoring / `overflow-anchor`, so that property can't help —
               removing the scroll container is the only real fix.) The
               `monitorHeightJS` image listeners also pin `body.scrollTop=0`
               as belt-and-suspenders for WebKit builds where `clip` is flaky. */

               DO NOT add `max-width: 100vw` here — `100vw` in iOS WebKit
               resolves to the *visual* viewport (device width), not the
               *layout* viewport the viewport meta tag controls. It would
               clamp html/body to device width and silently undo the
               viewport widening in fitViewportJS, making WebKit lay out
               content at 288 CSS px instead of 400, which then combines
               disastrously with our scale math. */
            /* Start invisible; revealed by fitViewportJS's reveal() only AFTER
               the final layout-viewport width + page scale are applied. WebKit
               paints a runtime viewport-meta widen at scale 1.0 for ~one frame
               before committing the shrink (zoom 1.0→0.56) — showing that
               un-scaled/clipped frame reads as an amateur "blink". Holding
               opacity:0 until post-commit guarantees the user never sees it; the
               0.07s fade makes the reveal a deliberate fade-in rather than a pop
               and masks any sub-frame scale-commit residual. A 700ms fallback in
               monitorHeightJS reveals even if fit() never runs, so content can
               never strand invisible. */
            html { overflow-x: clip !important; opacity: 0; transition: opacity 0.07s linear; }
            body {
                font-family: -apple-system, sans-serif;
                font-size: 16px;
                line-height: 1.5;
                padding: 0;
                margin: 0;
                /* Establish a block formatting context on <body> so a first/last
                   child's margin can't collapse THROUGH the body and escape the
                   measured height. The old `overflow-x: hidden` (pre-2026-06-25)
                   established a BFC as a side effect; switching to `clip` for the
                   inner-scroll fix (commit d242454) removed it (`clip` is NOT a
                   BFC trigger, unlike `hidden`). Without a BFC, a calendar
                   invite's `.tm-ics-collapsible` wrapper — appended at body level
                   with margin-top:12px / margin-bottom:20px — had its margins
                   collapse out of the body; body.scrollHeight/getBoundingClientRect
                   excluded them, so the webview frame was sized ~12px too short
                   and the bottom of the "Show invite details" pill was clipped.
                   `flow-root` restores the BFC (contains those margins, included
                   in the measured height) WITHOUT being a scrolling value — so it
                   can't re-promote overflow-y / recreate the inner-scroll
                   container that d242454 eliminated. */
                display: flow-root;
                -webkit-text-size-adjust: 100%;
                color-scheme: light dark;
                color: #15141a;
                background-color: transparent;
                overflow-wrap: break-word;
                word-wrap: break-word;
                overflow-x: clip;
                -webkit-user-select: text;
                user-select: text;
                -webkit-touch-callout: default;
            }
            /* Force transparent background on email's converted wrapper divs.
               Prevents full-document emails (Exchange/Outlook) from covering the card bubble. */
            body > div:not(.tm-quote-wrapper), .tm-email-body { background: transparent !important; background-color: transparent !important; }
            /* Responsive image cap. `height: auto` is SCOPED to images that
               carry an explicit `width` attribute — there, capping the width via
               max-width:100% must let height scale proportionally to avoid
               distortion. It must NOT be forced on width-less images: a logo
               sized only by `height="29"` (e.g. the Apple Support survey header)
               would otherwise lose its height constraint and balloon to the
               container's full width (a ~29px logo rendered ~420px tall+wide),
               which then drives a bogus fitViewport widen and right-edge
               clipping. Apple Mail / Thunderbird keep such logos small by
               honoring the height attribute — so do we. A width-less image keeps
               height:auto behavior implicitly anyway (height defaults to auto
               when only width or neither is specified).

               `max-width: 100%` is now `!important` (2026-07-07, webmail-
               composer "cafe note" email): the email shipped a composer CSS
               reset alongside its body — `#cafe-note-contents,
               #cafe-note-contents * { ...; max-height: none; max-width: none;
               ...; }` (no !important of its own) — which, at plain
               specificity, beat our cap on a 900px-wide banner
               `<img style="display:inline-block;border:0px solid;
               width:900px;height:274px">`. The image laid out at its full
               900px, and once images settled postImageWidthRecheckJS
               requested a re-fit that widened the whole (otherwise-fitting)
               email to 910px → 0.34x shrink (logmain.log 2026-07-07). The
               cap is a non-negotiable mobile-rendering invariant: an author
               reset that removes it always ends in a whole-email shrink,
               which is strictly worse for the author too — so !important
               wins over any author reset regardless of the reset's own
               specificity.

               `img[style*="width"][style*="height"] { height: auto !important; }`
               is the inline-style analog of `img[width] { height: auto; }`
               below: when the !important cap clamps an inline-styled image
               that also carries a fixed inline pixel height (like the
               900x274 banner above), that height must not stay fixed once
               the width is capped, or the image distorts. Requiring BOTH
               substrings keeps the loose `[style*=]` match harmless on false
               positives — an inline `max-width`/`max-height` (not
               `width`/`height`) also satisfies the substring check, but
               `height: auto` on an image that HAS loaded is aspect-correct,
               and on one that never loads it just collapses the box instead
               of leaving a fixed-height hole. Do NOT touch
               `img[width] { height: auto; }` itself — no evidence motivates
               changing it, and the comment above already covers its own
               hazard (Apple Support survey logo). */
            img { max-width: 100% !important; }
            img[width] { height: auto; }
            img[style*="width"][style*="height"] { height: auto !important; }
            a { color: #0060df; word-break: break-all; overflow-wrap: anywhere; }
            pre, code { overflow-x: auto; max-width: 100%; white-space: pre-wrap; word-break: break-all; }
            table, div, p { max-width: 100% !important; box-sizing: border-box !important; }
            td, th { max-width: 100% !important; box-sizing: border-box !important; }
            blockquote { border-left: 3px solid #d4d7dd; margin-left: 0; padding-left: 12px; }

            /* ---- Outlook/Word .eml attachment normalization ----
               These embedded emails carry CSS/inline-styles designed for 612pt-wide
               print pages. On a 320px viewport they render as: tiny text (10-11pt),
               massive vertical whitespace (dozens of empty MsoNormal paragraphs
               used for spacing), and sometimes CSS text leaking into the body.
               Force-override everything — inline styles and all. The .eml content
               is a quoted forwarded email; legibility > fidelity.

               SCOPED to `.tm-eml-section .tm-email-body` — nested .eml content
               ONLY. `unwrapFullHTMLDocument` also adds `tm-email-body` to top-
               level full-document emails (for CSS body-selector redirect via
               neutralizeCSSRules), but those MUST NOT be aggressively normalized
               — forcing 16px font / 1.4 line-height / table→block on a normal
               newsletter (e.g. RBC statements) collapses its intentional layout. */

            /* Size everything to our body font, overriding inline font-size. */
            .tm-eml-section .tm-email-body, .tm-eml-section .tm-email-body * {
                font-size: 16px !important;
                font-family: -apple-system, sans-serif !important;
                line-height: 1.4 !important;
            }
            /* Outlook paragraphs use zero margin + empty <p>s for spacing.
               Restore normal paragraph spacing and collapse empty paragraphs
               that only contain whitespace, &nbsp;, or Office-specific <o:p>. */
            .tm-eml-section .tm-email-body p {
                margin: 0 0 8px 0 !important;
            }
            .tm-eml-section .tm-email-body p:empty,
            .tm-eml-section .tm-email-body p.MsoNormal:empty {
                display: none !important;
            }
            /* Office-specific "continuation paragraph" element — purely structural.
               Only hidden inside nested .eml content; top-level Outlook emails
               keep native rendering. */
            .tm-eml-section o\\:p, .tm-eml-section .tm-email-body o\\:p {
                display: none !important;
            }
            /* Neutralize page-sized WordSection containers inside nested .eml. */
            .tm-eml-section .tm-email-body div[class*="WordSection"] {
                page: initial !important;
                min-height: 0 !important;
                height: auto !important;
                max-height: none !important;
                padding: 0 !important;
                margin: 0 !important;
            }
            .MsoChpDefault { font-size: inherit !important; }
            @page { size: auto !important; margin: 0 !important; }

            /* Force all elements inside nested .eml content to fit the viewport.
               Outlook uses pt-based widths (90.1pt, 468pt, etc) and pixel widths
               on <img> — any of these can trigger our fitViewportJS to widen the
               viewport and SCALE DOWN THE PAGE, making text visibly smaller.
               HTML `<table>` auto-layout IGNORES max-width (table width is driven
               by content); converting to `display: block` with horizontal scroll
               is the mobile-web-standard solution. */
            .tm-eml-section .tm-email-body, .tm-eml-section .tm-email-body * {
                max-width: 100% !important;
                box-sizing: border-box !important;
                overflow-wrap: anywhere !important;
                word-break: break-word !important;
            }
            .tm-eml-section .tm-email-body table {
                display: block !important;
                width: 100% !important;
                max-width: 100% !important;
                overflow-x: auto !important;
                table-layout: auto !important;
                border-collapse: collapse !important;
            }
            /* When table becomes block, restore tr/td display roles so rows
               still look like rows. tbody inherits block from table and
               becomes the horizontal-scroll container. */
            .tm-eml-section .tm-email-body table > tbody {
                display: table !important;
                width: auto !important;
                min-width: 100% !important;
            }
            .tm-eml-section .tm-email-body td, .tm-eml-section .tm-email-body th {
                max-width: 100% !important;
                min-width: 0 !important;
                word-break: break-word !important;
                white-space: normal !important;
            }
            .tm-eml-section .tm-email-body img {
                width: auto !important;
                height: auto !important;
                max-width: 100% !important;
            }
            /* Outlook/Word inline white-space:nowrap on spans inside paragraphs
               causes paragraphs to grow wider than the container. Force wrap. */
            .tm-eml-section .tm-email-body p,
            .tm-eml-section .tm-email-body span,
            .tm-eml-section .tm-email-body div {
                white-space: normal !important;
            }

            /* ---- Quote collapse styles ---- */
            .tm-quote-wrapper { position: relative; margin: 8px 0 20px 0; border-radius: 8px; overflow: hidden; }
            .tm-quote-wrapper.tm-collapsed { display: flex; width: fit-content; background: rgba(128,128,128,0.1); }
            .tm-quote-wrapper:not(.tm-collapsed) { display: block; background: rgba(128,128,128,0.06); border-radius: 8px; }
            .tm-quote-toggle { cursor: pointer; padding: 4px 12px; background: transparent; border: none; user-select: none; }
            .tm-collapsed .tm-quote-toggle { display: inline; }
            .tm-quote-wrapper:not(.tm-collapsed) .tm-quote-toggle { display: block; border-bottom: 1px solid rgba(128,128,128,0.15); padding: 6px 12px; }
            .tm-quote-toggle:active { background: rgba(128,128,128,0.15); border-radius: 6px; }
            .tm-quote-toggle-text { font-size: 13px; color: rgba(128,128,128,0.7); white-space: nowrap; }
            .tm-quote-content { overflow: hidden; }
            .tm-collapsed .tm-quote-content { display: none; }
            .tm-quote-wrapper:not(.tm-collapsed) .tm-quote-content { display: block; padding: 8px 12px; padding-top: 0; }

            /* ---- Dark mode: body defaults + links only. ---- */
            /* Fine-grained text/bg overrides done via JS (fixDarkModeColors) */
            /* to correctly skip elements with colored backgrounds. */
            @media (prefers-color-scheme: dark) {
                body {
                    color: #fbfbfe !important;
                    background-color: transparent !important;
                }
                a { color: #0a84ff !important; }
                a:visited { color: #b5a5ff !important; }
                blockquote { border-left-color: #52525e; }
                .tm-quote-wrapper.tm-collapsed { background: rgba(255,255,255,0.08); }
                .tm-quote-wrapper:not(.tm-collapsed) { background: rgba(255,255,255,0.05); }
                .tm-quote-toggle-text { color: rgba(255,255,255,0.5); }
            }

            /* ---- View-mode filter for embedded .eml marker sections ----
               Main view hides every `.tm-eml-section` block — attached .eml content
               is only shown via the dedicated preview sheet (EmlAttachmentPreview).
               Preview sheet reverses this: hide everything else, show only the
               section whose data-filename matches the tapped attachment. */
            \(viewModeCSS)
        </style>
        </head>
        <body\(bodyClass)>\(content)</body>
        </html>
        """
    }

    /// Escape characters that would break a CSS attribute-value selector `[…="…"]`.
    /// Filenames are arbitrary user-provided strings. Double-quote and backslash are
    /// escaped with a leading backslash per CSS syntax; other printable characters
    /// pass through (MIME-decoded filenames are already plain text).
    private static func escapeCSSAttrValue(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for c in s {
            if c == "\\" || c == "\"" { out.append("\\") }
            out.append(c)
        }
        return out
    }

    /// Unwrap a full HTML document into content suitable for embedding inside our wrapper.
    /// Converts `<html>` and `<body>` tags to `<div>` (preserving inline styles),
    /// removes `<head>` while keeping `<style>` blocks, and strips orphaned `<meta>` tags.
    /// - Note: `internal` rather than `private` only so the test target can reach
    ///   it; `wrapHTML`, in this file, is its sole caller in the app. (This note
    ///   previously claimed `renderBodyWithEmbeddedHeaders` needed the access.
    ///   That function lives in `IMAPFetchMapping`, which holds no reference to
    ///   `EmailHTMLWrapper` at all — the claim was false, not merely stale.)
    static func unwrapFullHTMLDocument(_ html: String) -> String {
        let isDbg = DebugModeManager.isLoggingEnabled()
        var result = html

        // Remove <!DOCTYPE ...>
        if let range = result.range(of: #"<!DOCTYPE[^>]*>"#, options: [.regularExpression, .caseInsensitive]) {
            if isDbg { print("[HTMLDebug] unwrap: removing DOCTYPE, len before=\(result.count)") }
            result.removeSubrange(range)
            if isDbg { print("[HTMLDebug] unwrap: after DOCTYPE removal, len=\(result.count)") }
        }

        // Convert <html ...> → <div ...> to preserve inline styles (e.g. Outlook's <html style="padding:0;...">)
        if let range = result.range(of: #"<html\b"#, options: [.regularExpression, .caseInsensitive]) {
            result.replaceSubrange(range, with: "<div")
        }
        if let range = result.range(of: "</html>", options: [.caseInsensitive, .backwards]) {
            result.replaceSubrange(range, with: "</div>")
        }

        // Extract <style> blocks from <head>, then remove the entire <head>...</head>.
        //
        // Both searches run FORWARD (first match each) — unlike the `<body>` pair
        // in `EmlMarker.extractBodyContent`, which mixes forward and `.backwards`.
        // So without the bound below the trap condition here is simply "the first
        // `</head>` precedes the first `<head…>`", and it reverses BOTH slices
        // taken from this pair: the `headContent` read just below, and the
        // `replaceSubrange` at the end of the block. Bounding the closing search
        // to start after the opening tag fixes both at once; fixing the two
        // slices separately would leave the pair itself still able to cross.
        // A reversed `Range` is an uncatchable precondition failure, and the
        // sender chooses this HTML (`wrapHTML` routes any body starting with
        // `<!doctype`/`<html` here), so it must not be reachable.
        if let headStart = result.range(of: #"<head[^>]*>"#, options: [.regularExpression, .caseInsensitive]),
           let headEnd = result.range(of: "</head>",
                                      options: .caseInsensitive,
                                      range: headStart.upperBound..<result.endIndex) {
            let headContent = String(result[headStart.upperBound..<headEnd.lowerBound])
            if isDbg { print("[HTMLDebug] unwrap: <head> found, headContent len=\(headContent.count)") }
            var styles = ""
            if let styleRegex = try? NSRegularExpression(pattern: #"<style[^>]*>[\s\S]*?</style>"#, options: .caseInsensitive) {
                let nsString = headContent as NSString
                let matches = styleRegex.matches(in: headContent, range: NSRange(location: 0, length: nsString.length))
                styles = matches.map { nsString.substring(with: $0.range) }.joined(separator: "\n")
                if isDbg { print("[HTMLDebug] unwrap: extracted \(matches.count) <style> blocks from <head>, total styles len=\(styles.count)") }
            }
            let preNeutLen = styles.count
            styles = Self.neutralizeRootSelectors(styles)
            if isDbg { print("[HTMLDebug] unwrap: after neutralizeRootSelectors on head styles, len \(preNeutLen)→\(styles.count)") }
            let lenBefore = result.count
            result.replaceSubrange(headStart.lowerBound..<headEnd.upperBound, with: styles)
            if isDbg { print("[HTMLDebug] unwrap: replaced <head>...</head> with styles, len \(lenBefore)→\(result.count)") }
        }

        // Remove orphaned <meta> tags (our wrapper provides viewport + CSP)
        result = result.replacingOccurrences(of: #"<meta[^>]*/?>"#, with: "", options: .regularExpression)

        // Convert <body ...> → <div class="tm-email-body" ...> to preserve inline styles.
        // The tm-email-body class lets CSS `body` selectors be redirected here
        // (via neutralizeCSSRules) without leaking into our wrapper's <body>.
        if let bodyTagRange = result.range(of: #"<body\b[^>]*>"#, options: [.regularExpression, .caseInsensitive]) {
            var bodyTag = String(result[bodyTagRange])
            if isDbg { print("[HTMLDebug] unwrap: converting <body> → <div>, bodyTag='\(bodyTag)'") }
            bodyTag = bodyTag.replacingOccurrences(of: #"<body\b"#, with: "<div", options: [.regularExpression, .caseInsensitive])
            if let classRange = bodyTag.range(of: #"class\s*=\s*""#, options: .regularExpression) {
                bodyTag.insert(contentsOf: "tm-email-body ", at: classRange.upperBound)
            } else {
                bodyTag = bodyTag.replacingOccurrences(of: "<div", with: "<div class=\"tm-email-body\"")
            }
            result.replaceSubrange(bodyTagRange, with: bodyTag)
        }
        if let range = result.range(of: "</body>", options: [.caseInsensitive, .backwards]) {
            result.replaceSubrange(range, with: "</div>")
        }

        // Neutralize root selectors in ALL <style> blocks — not just head.
        let preNeutLen = result.count
        result = Self.neutralizeRootSelectors(result)
        if isDbg { print("[HTMLDebug] unwrap: final neutralizeRootSelectors, len \(preNeutLen)→\(result.count)") }

        let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
        if isDbg { print("[HTMLDebug] unwrap: final trimmed len=\(trimmed.count)") }
        return trimmed
    }

    /// Remove `html`, `body`, and `:root` selectors from CSS inside `<style>` blocks.
    /// These would leak into our wrapper's html/body, overriding padding, background, etc.
    /// The original styles are already preserved as inline styles on the converted `<div>` tags.
    ///
    /// Handles comma-separated selectors: `":root, html, body { ... }"` → removed entirely.
    /// Mixed selectors: `"html, .hello { ... }"` → `".hello { ... }"`.
    private static func neutralizeRootSelectors(_ styles: String) -> String {
        // Process each <style> block's inner CSS separately
        guard let styleBlockRegex = try? NSRegularExpression(
            pattern: #"(<style[^>]*>)([\s\S]*?)(</style>)"#, options: .caseInsensitive
        ) else { return styles }

        let nsStyles = styles as NSString
        var result = styles
        let blockMatches = styleBlockRegex.matches(in: styles, range: NSRange(location: 0, length: nsStyles.length))

        for blockMatch in blockMatches.reversed() {
            guard blockMatch.numberOfRanges >= 4 else { continue }
            let cssRange = blockMatch.range(at: 2)
            let cssContent = nsStyles.substring(with: cssRange)
            let cleaned = neutralizeCSSRules(cssContent)
            if cleaned != cssContent {
                let swiftRange = Range(cssRange, in: result)!
                result.replaceSubrange(swiftRange, with: cleaned)
            }
        }
        return result
    }

    /// Process raw CSS text (without `<style>` tags) to remove rules targeting html/body/:root.
    private static func neutralizeCSSRules(_ css: String) -> String {
        let isDbg = DebugModeManager.isLoggingEnabled()
        // Strip HTML comment delimiters (<!-- -->) — common in email CSS for legacy compatibility.
        let css = css
            .replacingOccurrences(of: "<!--", with: "")
            .replacingOccurrences(of: "-->", with: "")
        guard let ruleRegex = try? NSRegularExpression(
            pattern: #"([^{}]+)\{([^}]*)\}"#, options: []
        ) else { return css }

        let nsCSS = css as NSString
        var result = css
        let rootPattern = #"^(:root|html|body)$"#
        let rootRegex = try! NSRegularExpression(pattern: rootPattern, options: .caseInsensitive)

        let ruleMatches = ruleRegex.matches(in: css, range: NSRange(location: 0, length: nsCSS.length))
        for match in ruleMatches.reversed() {
            guard match.numberOfRanges >= 3 else { continue }
            let selectorRange = match.range(at: 1)
            let bodyRange = match.range(at: 2)
            let fullRange = match.range

            let selectorText = nsCSS.substring(with: selectorRange)
            let bodyText = nsCSS.substring(with: bodyRange)
            let selectors = selectorText.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

            // Redirect body → .tm-email-body (the converted <body> div) instead of removing.
            // This preserves email styles that depend on `body` selector (e.g. `body, u+div`)
            // without leaking into our wrapper's actual <body>.
            // :root and html are still removed entirely — they target the wrapper document.
            let remapped = selectors.map { selector -> String? in
                let nsSelector = selector as NSString
                let isRoot = rootRegex.firstMatch(in: selector, range: NSRange(location: 0, length: nsSelector.length)) != nil
                if !isRoot { return selector }
                if selector.lowercased() == "body" { return ".tm-email-body" }
                return nil // remove :root, html
            }
            let filtered = remapped.compactMap { $0 }

            if filtered.isEmpty {
                if isDbg {
                    let preview = String(bodyText.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
                    print("[HTMLDebug] neutralizeCSSRules: REMOVING rule selector='\(selectorText.trimmingCharacters(in: .whitespacesAndNewlines))' preview='\(preview)'")
                }
                let swiftRange = Range(fullRange, in: result)!
                result.replaceSubrange(swiftRange, with: "")
            } else if filtered != selectors.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }) {
                if isDbg {
                    let original = selectors.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    print("[HTMLDebug] neutralizeCSSRules: REMAPPING selectors from=\(original) to=\(filtered)")
                }
                let newSelector = filtered.joined(separator: ", ")
                let swiftRange = Range(selectorRange, in: result)!
                result.replaceSubrange(swiftRange, with: newSelector)
            }
        }
        return result
    }
}
