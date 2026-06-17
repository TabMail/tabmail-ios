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
        <meta http-equiv="Content-Security-Policy" content="upgrade-insecure-requests">
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
               up". `body { overflow-x: hidden }` alone is not enough —
               WebKit bug 153852 tracks body's overflow being ignored on
               iOS. Clamping html with overflow-x:hidden closes that leak
               at the root.

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
            html { overflow-x: hidden !important; opacity: 0; transition: opacity 0.07s linear; }
            body {
                font-family: -apple-system, sans-serif;
                font-size: 16px;
                line-height: 1.5;
                padding: 0;
                margin: 0;
                -webkit-text-size-adjust: 100%;
                color-scheme: light dark;
                color: #15141a;
                background-color: transparent;
                overflow-wrap: break-word;
                word-wrap: break-word;
                overflow-x: hidden;
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
               when only width or neither is specified). */
            img { max-width: 100%; }
            img[width] { height: auto; }
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
    /// - Note: `internal` (not private) for use by `renderBodyWithEmbeddedHeaders`.
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
        if let headStart = result.range(of: #"<head[^>]*>"#, options: [.regularExpression, .caseInsensitive]),
           let headEnd = result.range(of: "</head>", options: .caseInsensitive) {
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
