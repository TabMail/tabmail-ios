/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

/// Regression guards: the aggressive Outlook/.eml normalization (forced 16px font,
/// 1.4 line-height, table→block, empty-p hidden, consecutive-br collapse) MUST only
/// apply inside `.tm-eml-section .tm-email-body`. If the selector regresses to bare
/// `.tm-email-body`, top-level full-document emails (which get that class from
/// `unwrapFullHTMLDocument` for CSS body-selector redirection) would have their
/// intentional spacing collapsed — e.g. 25 `<br>` tags used as visual separators
/// would get halved.
///
/// All HTML in these tests is synthetic — no real email content.
@Suite("EmailHTMLWrapper / AutoSizingHTMLView — aggressive rules scope")
struct EmailHTMLWrapperScopeTests {

    // MARK: - wrapHTML CSS scope

    @Test("Main-mode wrapHTML hides .tm-eml-section globally")
    func mainModeHidesMarker() {
        let out = EmailHTMLWrapper.wrapHTML("<p>Synthetic body.</p>")
        #expect(out.contains(".tm-eml-section { display: none !important"))
    }

    @Test("Preview-mode wrapHTML shows only the matching section")
    func previewModeIsolatesSection() {
        let out = EmailHTMLWrapper.wrapHTML("<p>X</p>", previewFilename: "sample.eml")
        #expect(out.contains("body.tm-preview-mode"))
        #expect(out.contains(".tm-eml-section[data-filename=\"sample.eml\"]"))
        // Preview mode also hides the duplicated in-HTML envelope (native Swift
        // header renders it), avoiding a double header.
        #expect(out.contains(".tm-eml-headers { display: none !important"))
        // <body class="tm-preview-mode"> on the wrapper
        #expect(out.contains("<body class=\"tm-preview-mode\">"))
    }

    @Test("Main-mode body has no preview class")
    func mainModeBodyNoPreviewClass() {
        let out = EmailHTMLWrapper.wrapHTML("<p>X</p>")
        #expect(out.contains("<body>"))
        #expect(!out.contains("tm-preview-mode"))
    }

    @Test("Aggressive font/line-height is scoped to nested .eml only")
    func aggressiveFontScopedToNested() {
        let out = EmailHTMLWrapper.wrapHTML("<p>X</p>")
        // The forced 16px rule targets nested content only. Top-level full-doc
        // newsletters (which also carry the tm-email-body class via
        // unwrapFullHTMLDocument) must NOT be targeted.
        #expect(out.contains(".tm-eml-section .tm-email-body, .tm-eml-section .tm-email-body *"))
        // A bare `.tm-email-body, .tm-email-body * { font-size: 16px` rule
        // would be the pre-fix bug. Assert it's gone — specifically, no line
        // that starts the font override with the un-scoped selector.
        let lines = out.components(separatedBy: "\n")
        let hasBareFontRule = lines.contains { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.hasPrefix(".tm-email-body, .tm-email-body *")
        }
        #expect(!hasBareFontRule)
    }

    @Test("Aggressive table→block is scoped to nested .eml only")
    func aggressiveTableScopedToNested() {
        let out = EmailHTMLWrapper.wrapHTML("<p>X</p>")
        #expect(out.contains(".tm-eml-section .tm-email-body table"))
        // A bare `.tm-email-body table { display: block` is the pre-fix bug.
        let lines = out.components(separatedBy: "\n")
        let hasBareTableRule = lines.contains { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.hasPrefix(".tm-email-body table")
        }
        #expect(!hasBareTableRule)
    }

    @Test("Empty-paragraph hiding is scoped to nested .eml only")
    func emptyParagraphHidingScoped() {
        let out = EmailHTMLWrapper.wrapHTML("<p>X</p>")
        #expect(out.contains(".tm-eml-section .tm-email-body p:empty"))
        let lines = out.components(separatedBy: "\n")
        let hasBareEmpty = lines.contains { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.hasPrefix(".tm-email-body p:empty")
        }
        #expect(!hasBareEmpty)
    }

    @Test("Safe globals preserved — @page, MsoChpDefault, link colors")
    func safeGlobalsPreserved() {
        let out = EmailHTMLWrapper.wrapHTML("<p>X</p>")
        // @page is print-media — safe everywhere.
        #expect(out.contains("@page { size: auto !important"))
        // MsoChpDefault just restores `inherit` — lowest risk rule.
        #expect(out.contains(".MsoChpDefault { font-size: inherit !important"))
        // Global link color stays — applies to all emails.
        #expect(out.contains("a { color: #0060df"))
    }

    @Test("Transparent background still applies to .tm-email-body globally")
    func transparentBackgroundGlobal() {
        let out = EmailHTMLWrapper.wrapHTML("<p>X</p>")
        // Full-document emails still need transparent background on the
        // unwrapped body div. This one rule stays global.
        #expect(out.contains(".tm-email-body { background: transparent !important")
                || out.contains(".tm-email-body") && out.contains("background: transparent"))
    }

    // MARK: - cleanupEmlBodyJS scope

    @Test("cleanupEmlBodyJS queries `.tm-eml-section .tm-email-body` only")
    func cleanupJsUsesNarrowedSelector() {
        let js = cleanupEmlBodyJS
        // The bug we're guarding against: `querySelectorAll('.tm-email-body')`
        // would match newsletters and collapse their intentional `<br>` runs.
        #expect(js.contains("querySelectorAll('.tm-eml-section .tm-email-body')"))
        #expect(!js.contains("querySelectorAll('.tm-email-body')"))
    }

    @Test("cleanupEmlBodyJS still contains the 3-pass logic and br-collapse")
    func cleanupJsStructureIntact() {
        let js = cleanupEmlBodyJS
        // Sanity: the cleanup work itself is still there. It just targets
        // a different root.
        #expect(js.contains("for (var pass = 0; pass < 3; pass++)"))
        #expect(js.contains("BR"))
        #expect(js.contains("removeChild"))
    }

    // MARK: - html/body overflow-x: clip (NOT hidden) — inner-scroll bug guard

    /// Root-cause guard for the "inner rendered content scrolls, not the page"
    /// bug: `overflow-x: hidden` on html/body promotes the visible `overflow-y`
    /// to `auto` (CSS Overflow L3), making them Y-scroll containers that can
    /// hold a stray `body.scrollTop` after a late image-swap reflow. `clip` is
    /// not a scrolling value, so it clips X without that promotion — the only
    /// real fix on WebKit, which implements no scroll anchoring / overflow-anchor.
    @Test("html/body clip horizontal overflow with `clip`, never `hidden`")
    func htmlBodyUseOverflowClipNotHidden() {
        let out = EmailHTMLWrapper.wrapHTML("<p>X</p>")
        // Positive: both the html rule and the body rule use clip.
        #expect(out.contains("html { overflow-x: clip !important"))
        #expect(out.contains("overflow-x: clip;"))
        // Negative: the *rule* syntax must never regress to hidden (matched
        // precisely so the explanatory CSS comment's prose doesn't false-trip).
        #expect(!out.contains("overflow-x: hidden !important"))
        #expect(!out.contains("overflow-x: hidden;"))
    }

    @Test("monitorHeightJS pins only body.scrollTop (zoom-safe), never the viewport scroller")
    func monitorHeightJsPinsBodyScrollOnly() {
        let js = _monitorHeightJS
        // Defense-in-depth reset is present and wired into the image listeners.
        #expect(js.contains("function pinBodyScroll()"))
        #expect(js.contains("document.body.scrollTop = 0"))
        #expect(js.contains("pinBodyScroll(); report();"))
        // MUST NOT reset documentElement / scrollingElement — those mirror the
        // native UIScrollView (pinch-zoom pan) on iOS WKWebView; resetting them
        // would yank a zoomed user to the top.
        #expect(!js.contains("documentElement.scrollTop = 0"))
        #expect(!js.contains("scrollingElement.scrollTop"))
    }
}
