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

    /// Root-cause guard for the "Show invite details" pill clipped at the bottom
    /// bug. Switching html/body to `overflow-x: clip` (commit d242454) dropped the
    /// block formatting context that `overflow-x: hidden` used to establish as a
    /// side effect. Without a BFC, a calendar invite's body-level
    /// `.tm-ics-collapsible` wrapper had its collapsing top/bottom margins escape
    /// the body, so the measured height was short and the toggle pill was clipped.
    /// `display: flow-root` restores the BFC (margins contained → measured) without
    /// being a scrolling value (so it can't recreate the inner-scroll container the
    /// `clip` change removed). This test fails if `flow-root` regresses away.
    @Test("body establishes a BFC via flow-root so child margins can't escape the measured height")
    func bodyEstablishesBlockFormattingContext() {
        let out = EmailHTMLWrapper.wrapHTML("<p>X</p>")
        #expect(out.contains("display: flow-root;"))
        // The fix must NOT re-introduce a scroll container: the body must keep
        // `overflow-x: clip` (not regress to `hidden`, which is a BFC trigger but
        // also promotes overflow-y to a Y-scroll container — the d242454 bug).
        // `.tm-quote-wrapper` legitimately uses the `overflow: hidden` shorthand
        // for border-radius clipping, so we assert on the body's axis rule only.
        #expect(out.contains("overflow-x: clip;"))
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

/// `EmailHTMLWrapper.unwrapFullHTMLDocument` extracts the `<head>` block from two
/// bounds. Unlike the `<body>` pair in `EmlMarker.extractBodyContent` — which
/// mixes a forward search with a `.backwards` one — **both `<head>` searches run
/// FORWARD**, taking the first match each. So the trap condition here is simply
/// *the first `</head>` precedes the first `<head…>`*, and when they were
/// searched independently that reversed BOTH slices built from the pair: the
/// `headContent` read, and the `replaceSubrange` that swaps the head for its
/// hoisted styles. `String` traps on a reversed `Range` — an uncatchable
/// precondition failure, not a throwable error.
///
/// The sender controls this HTML: `wrapHTML` routes any body whose trimmed text
/// starts with `<!doctype` or `<html` through here, so the crash is "user opens
/// a crafted message". Narrower than a background-sync wedge, and stated that
/// way rather than overstated.
///
/// These pin the **invariant** — *for any input the head extraction either
/// slices correctly-ordered bounds or skips the block entirely; it never traps
/// and never drops the message body* — over a table that varies the pair on each
/// axis independently, plus literal-valued benign controls.
///
/// All HTML here is synthetic.
@Suite("EmailHTMLWrapper.unwrapFullHTMLDocument — head bound-pair invariant")
struct EmailHTMLWrapperHeadBoundPairTests {

    struct Shape: CustomStringConvertible, Sendable {
        let name: String
        let html: String
        /// The message payload must survive on whichever branch runs.
        let mustRetain: [String]
        var description: String { name }
    }

    static let shapes: [Shape] = [
        // --- first close precedes first open: the reversed-Range family ---
        Shape(name: "close before open, adjacent",
              html: "<html></head><head></head><body>x</body></html>",
              mustRetain: ["x"]),
        Shape(name: "close before open, gap wider than the </head> token",
              html: "<html></head>xxxxxxxxxxxxxxxxxxxx<head></head><body>payload</body></html>",
              mustRetain: ["payload"]),
        Shape(name: "close before open, uppercase tags",
              html: "<html></HEAD><HEAD></HEAD><body>x</body></html>",
              mustRetain: ["x"]),
        Shape(name: "close before open, attributes on the open tag",
              html: "<html></head><head profile=\"p\"></head><body>x</body></html>",
              mustRetain: ["x"]),
        Shape(name: "close before open, behind a DOCTYPE",
              html: "<!DOCTYPE html><html></head><head></head><body>x</body></html>",
              mustRetain: ["x"]),
        Shape(name: "close before open, style block stranded outside",
              html: "<html></head><style>.z{color:red}</style><head></head><body>x</body></html>",
              mustRetain: ["x"]),

        // --- one bound only: the block must be skipped, not half-applied ---
        Shape(name: "close only",
              html: "<html></head><body>x</body></html>",
              mustRetain: ["x"]),
        Shape(name: "open only",
              html: "<html><head><body>x</body></html>",
              mustRetain: ["x"]),
        Shape(name: "neither bound",
              html: "<html><body>x</body></html>",
              mustRetain: ["x"]),

        // --- multiplicity, and the directional negative control ---
        Shape(name: "multiple opens",
              html: "<html><head><head></head><body>x</body></html>",
              mustRetain: ["x"]),
        Shape(name: "multiple closes",
              html: "<html><head></head></head><body>x</body></html>",
              mustRetain: ["x"]),
        // Both searches are forward, so an unclosed SECOND <head> after a
        // well-formed pair does NOT cross. A fix that special-cased a leading
        // `</head>` would pass the crossed rows above and still be wrong; this
        // row and `orderedPairWithTrailingOpenUnchanged` below are what separate
        // the condition from the example.
        Shape(name: "open, close, open (does NOT cross)",
              html: "<html><head></head><head><body>x</body></html>",
              mustRetain: ["x"]),
    ]

    @Test("Any head bound-pair shape returns and never traps", arguments: shapes)
    func headBoundPairNeverTraps(shape: Shape) {
        let out = EmailHTMLWrapper.unwrapFullHTMLDocument(shape.html)
        // Reaching this line IS the first half of the invariant: a reversed
        // Range is a `fatalError`, which Swift Testing cannot catch — a
        // regression kills the test host rather than recording a failure.
        for needle in shape.mustRetain {
            #expect(out.contains(needle), "\(shape.name): dropped \(needle.debugDescription)")
        }
    }

    @Test("wrapHTML survives a crossed head pair on its full-document route")
    func wrapHTMLSurvivesCrossedHead() {
        // `wrapHTML` is `unwrapFullHTMLDocument`'s only caller in the app, and
        // the `<html`-prefix test is what routes a sender's document into it.
        let out = EmailHTMLWrapper.wrapHTML("<html></head><head></head><body>x</body></html>")
        #expect(out.contains("x"))
        #expect(out.contains("<body>"))
    }

    // MARK: - Benign controls (literal expectations)

    @Test("Benign empty-head document is byte-identical to the pre-fix output")
    func benignEmptyHeadUnchanged() {
        let out = EmailHTMLWrapper.unwrapFullHTMLDocument("<html><head></head><body>hi</body></html>")
        #expect(out == "<div><div class=\"tm-email-body\">hi</div></div>")
    }

    @Test("Benign document still hoists its head styles out of the head block")
    func benignHeadStylesHoisted() {
        let out = EmailHTMLWrapper.unwrapFullHTMLDocument(
            "<html><head><style>.a{color:red}</style></head><body>hi</body></html>"
        )
        #expect(out == "<div><style>.a{color:red}</style><div class=\"tm-email-body\">hi</div></div>")
    }

    @Test("An ordered pair followed by a stray open tag is byte-identical to pre-fix")
    func orderedPairWithTrailingOpenUnchanged() {
        // The boundary case for the trap CONDITION: first open at 5, first close
        // at 11 — ordered — so the fix must not change this at all.
        let out = EmailHTMLWrapper.unwrapFullHTMLDocument("<html><head></head><head><body>hi</body></html>")
        #expect(out == "<div><head><div class=\"tm-email-body\">hi</div></div>")
    }
}
