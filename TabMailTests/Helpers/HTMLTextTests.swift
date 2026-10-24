/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

/// #251: the HTML-to-text rules, each pinned as an exact spec. A draft's text
/// (`keepingSpacing`) reads the CSS the owner's spec lists; every other caller
/// (search, AI, previews, the notification extension) hides only on inline
/// `display: none`.
@Suite("HTMLText rules (#251)")
struct HTMLTextTests {
    private func draft(_ html: String) -> String {
        EmailFilter.htmlToPlainText(html, keepingSpacing: true)
    }

    private func collapsed(_ html: String) -> String {
        EmailFilter.htmlToPlainText(html)
    }

    // MARK: - Cases checked against WebKit's innerText

    @Test("A comment inside a word leaves one word, in every mode")
    func commentInsideWord() {
        let html = "<div>un<!-- marker -->believable</div>"
        #expect(draft(html) == "unbelievable")
        #expect(collapsed(html) == "unbelievable")
    }

    @Test("A block after <pre> starts its own line, and the pre's spacing stays")
    func blockAfterPre() {
        let html = "<pre>one\n  </pre><div>two</div>"
        #expect(draft(html) == "one\n  \ntwo")
        #expect(collapsed(html) == "one\ntwo")
    }

    @Test("Zero-width joiner and non-joiner are text, written or as references", arguments: [
        ("<div>\u{1F469}\u{200D}\u{1F4BB}</div>", "\u{1F469}\u{200D}\u{1F4BB}"),
        ("<div>\u{1F469}&#x200D;\u{1F4BB}</div>", "\u{1F469}\u{200D}\u{1F4BB}"),
        ("<div>\u{1F469}&zwj;\u{1F4BB}</div>", "\u{1F469}\u{200D}\u{1F4BB}"),
        ("<div>\u{0645}\u{06CC}\u{200C}\u{0631}\u{0648}\u{0645}</div>", "\u{0645}\u{06CC}\u{200C}\u{0631}\u{0648}\u{0645}"),
        ("<div>\u{0645}\u{06CC}&zwnj;\u{0631}\u{0648}\u{0645}</div>", "\u{0645}\u{06CC}\u{200C}\u{0631}\u{0648}\u{0645}"),
    ])
    func joinersKept(html: String, expected: String) {
        #expect(draft(html) == expected)
        #expect(collapsed(html) == expected)
    }

    /// Measured on 1,278 real HTML bodies (owner's mail, 2026-10-24): all 9,033
    /// joiners were filler beside spaces or split digits, none joined two letters.
    @Test("A joiner anywhere else is dropped, so filler and split digits read as text", arguments: [
        ("<div>Starts at 1&zwnj;1&zwj;:&zwj;59 tomorrow</div>", "Starts at 11:59 tomorrow"),
        ("<div>1\u{200C}2\u{200D}3</div>", "123"),
        ("<div>Preview text&nbsp;&zwnj;&nbsp;&zwnj;&nbsp;&zwnj;</div><div>Body</div>", "Preview text\nBody"),
        ("<div>&zwnj;\u{1F469}\u{200D}</div>", "\u{1F469}"),
        ("<div>caf\u{00E9}&zwnj; bar</div>", "caf\u{00E9} bar"),
        ("<div>\u{1F469}&zwj;x</div>", "\u{1F469}x"),
        ("<div>\u{1F469}&zwj;<br>\u{1F4BB}</div>", "\u{1F469}\n\u{1F4BB}"),
    ])
    func strayJoinersDropped(html: String, expected: String) {
        #expect(draft(html) == expected)
        #expect(collapsed(html) == expected)
    }

    @Test("Characters that show nothing are dropped")
    func invisiblesDropped() {
        let html = "a\u{200B}b&shy;c\u{2060}d\u{FEFF}e\u{034F}f"
        #expect(draft(html) == "abcdef")
        #expect(collapsed(html) == "abcdef")
    }

    // MARK: - Spacing CSS keeps

    @Test("TabMail's earlier HTML uploads reopen with their spacing")
    func earlierTabMailUpload() {
        #expect(draft("<div style=\"white-space:pre-wrap;\">one\n  two</div>") == "one\n  two")
        let text = "Hi Bob,\n\n  indented  twice\nAlice"
        #expect(draft(EmailFilter.plainTextToHTML(text)) == text)
    }

    @Test("white-space keeps or collapses spacing as CSS says, only in a draft", arguments: [
        ("<div style=\"white-space:pre\">a\tb  c</div>", "a\tb  c", "a b c"),
        ("<div style=\"white-space:pre-wrap\">a  b\nc</div>", "a  b\nc", "a b c"),
        ("<div style=\"white-space:break-spaces\">a  b</div>", "a  b", "a b"),
        ("<div style=\"white-space:pre-line\">a  b\n  c</div>", "a b\nc", "a b c"),
        ("<pre>a  <span style=\"white-space:normal\">b   c</span></pre>", "a  b c", "a b c"),
        ("<pre style=\"white-space:nowrap\">a  b</pre>", "a b", "a b"),
    ])
    func whiteSpace(html: String, draft expectedDraft: String, collapsed expectedCollapsed: String) {
        #expect(draft(html) == expectedDraft)
        #expect(collapsed(html) == expectedCollapsed)
    }

    @Test("No-break spaces in a link label are kept in a draft")
    func noBreakSpacesInLinkLabel() {
        let html = "<div><a href=\"https://example.com/a\">a&nbsp;&nbsp;b</a></div>"
        #expect(draft(html) == "[a  b](https://example.com/a)")
        #expect(collapsed(html) == "[a b](https://example.com/a)")
    }

    // MARK: - Inline style declarations

    @Test("Quotes, url() and comments never split a declaration", arguments: [
        ("<div style=\"font-family:'a;display:none'; white-space:pre\">x  y</div>", "x  y"),
        ("<div style=\"background:url(data:image/png;base64,iVBO;display:none); white-space:pre-wrap\">x  y</div>", "x  y"),
        ("<div style=\"/* display:none; */ white-space:pre-line\">x  y</div>", "x y"),
        ("<div style=\"content:&quot;;display:none&quot;; white-space:pre\">x  y</div>", "x  y"),
    ])
    func declarationsSplitAtTopLevel(html: String, expected: String) {
        #expect(draft(html) == expected)
    }

    @Test("Inline display:none hides in every mode, however it is written", arguments: [
        "<div>a</div><div style=\"display:none\">x</div><div>b</div>",
        "<div>a</div><div style=\"DISPLAY : NONE !important\">x</div><div>b</div>",
        "<div>a</div><div style=\"color:red;display:none;\">x<div>y</div></div><div>b</div>",
        "<div>a</div><div style=\"display:none\">x<span>y</span></div><div>b</div>",
    ])
    func inlineDisplayNone(html: String) {
        #expect(draft(html) == "a\nb")
        #expect(collapsed(html) == "a\nb")
    }

    @Test("A display other than none shows the element")
    func otherDisplayShows() {
        let html = "<style>.x{display:none}</style><div>a</div><div class=\"x\" style=\"display:block\">b</div>"
        #expect(draft(html) == "a\nb")
    }

    // MARK: - Style sheets

    @Test("A style sheet hides only in a draft")
    func styleSheetHidesOnlyInDraft() {
        let html = "<style>.x{display:none}</style><div>a</div><div class=\"x\">secret</div><div>b</div>"
        #expect(draft(html) == "a\nb")
        #expect(collapsed(html) == "a\nsecret\nb")
    }

    @Test("Each selector form a rule applies to", arguments: [
        "<style>div{display:none}</style><p style=\"margin:0\">a</p><div>x</div>",
        "<style>.sig{display:none}</style><p style=\"margin:0\">a</p><div class=\"note SIG\">x</div>",
        "<style>div.sig{display:none}</style><p style=\"margin:0\">a</p><div class=\"sig\">x</div>",
        "<style>#sig{display:none}</style><p style=\"margin:0\">a</p><div id=\"sig\">x</div>",
        "<style>h1, #sig , p.y{display:none}</style><p style=\"margin:0\">a</p><div id=\"sig\">x</div>",
    ])
    func selectorForms(html: String) {
        #expect(draft(html) == "a")
    }

    @Test("Any other selector is skipped", arguments: [
        "div p", "div > p", "p:first-child", "p[class]", "*", "p.a.b", "p#x", "p::before", "1p", ".a b",
    ])
    func skippedSelectors(selector: String) {
        let html = "<style>\(selector){display:none; margin:0}</style><p class=\"a b\" id=\"x\">a</p><p>b</p>"
        #expect(draft(html) == "a\n\nb")
    }

    @Test("At-rule blocks are skipped whole, the rules after them still apply")
    func atRulesSkipped() {
        let html = """
        <style>@import url("x.css"); @media screen { p { display:none } .x { margin:1em } }
        @font-face { font-family: x; src: url(x.woff) } p { margin: 0 }</style><p>a</p><p>b</p>
        """
        #expect(draft(html) == "a\nb")
    }

    @Test("Comments and HTML comment markers around a style sheet are not rules")
    func styleSheetComments() {
        let html = "<style><!-- /* p { display:none } */ p { margin:0 } --></style><p>a</p><p>b</p>"
        #expect(draft(html) == "a\nb")
    }

    @Test("Inline style beats a style sheet rule")
    func inlineBeatsSheet() {
        let html = "<style>p{margin:0}</style><p>a</p><p style=\"margin:1em 0\">b</p><p>c</p>"
        #expect(draft(html) == "a\n\nb\n\nc")
    }

    @Test("A later rule beats an earlier one, with no specificity", arguments: [
        ("<style>p{margin:0} p{margin:1em 0}</style><p>a</p><p>b</p>", "a\n\nb"),
        ("<style>p{margin:1em 0} p{margin:0}</style><p>a</p><p>b</p>", "a\nb"),
        ("<style>#x{margin:1em 0} p{margin:0}</style><p id=\"x\">a</p><p>b</p>", "a\nb"),
        ("<style>p{margin-bottom:0} p{margin-top:0}</style><p>a</p><p>b</p>", "a\nb"),
    ])
    func laterRuleWins(html: String, expected: String) {
        #expect(draft(html) == expected)
    }

    @Test("A style sheet in a hidden <head> still applies")
    func styleInHeadApplies() {
        let html = "<html><head><style>p{margin:0}</style></head><body><p>a</p><p>b</p></body></html>"
        #expect(draft(html) == "a\nb")
    }

    // MARK: - Margins

    @Test("Margin shorthand and longhands: only zero or not, top and bottom", arguments: [
        ("0", "a\nb\nc"),
        ("1em", "a\n\nb\n\nc"),
        ("0 1em", "a\nb\nc"),
        ("1em 0", "a\n\nb\n\nc"),
        ("1em 0 0", "a\n\nb\nc"),
        ("0 0 1em", "a\nb\n\nc"),
        ("0 1em 1em 1em", "a\nb\n\nc"),
        ("1em 0 0 0", "a\n\nb\nc"),
        ("0; margin-bottom:12px", "a\nb\n\nc"),
        ("0; margin-top:2px", "a\n\nb\nc"),
        ("1em; margin-top:0; margin-bottom:0", "a\nb\nc"),
        ("inherit", "a\n\nb\n\nc"),
        ("1px 2px 3px 4px 5px", "a\n\nb\n\nc"),
    ])
    func marginValues(margin: String, expected: String) {
        #expect(draft("<div>a</div><p style=\"margin:\(margin)\">b</p><div>c</div>") == expected)
        #expect(collapsed("<div>a</div><p style=\"margin:\(margin)\">b</p><div>c</div>") == "a\nb\nc")
    }

    @Test("Zero is zero in every unit", arguments: ["0px", "0cm", "0mm", "0in", "0pt", "0pc", "0em", "0rem", "0ex", "0%", "0.0vh", "+0px", "-0em", "auto"])
    func zeroInEveryUnit(value: String) {
        #expect(draft("<p style=\"margin:\(value)\">a</p><p style=\"margin:\(value)\">b</p>") == "a\nb")
    }

    @Test("Nonzero is a blank line in every unit", arguments: ["1px", ".5cm", "2mm", "1in", "10pt", "1pc", "1em", "1rem", "1ex", "5%", "-1px"])
    func nonzeroInEveryUnit(value: String) {
        #expect(draft("<div style=\"margin:\(value)\">a</div><div>b</div>") == "a\n\nb")
    }

    @Test("A <div> has no margin unless its style gives one")
    func divMargin() {
        #expect(draft("<div>a</div><div>b</div>") == "a\nb")
        #expect(draft("<div style=\"margin-bottom:8px\">a</div><div>b</div>") == "a\n\nb")
    }

    @Test("Margins between blocks give one blank line, not one each")
    func marginsJoin() {
        #expect(draft("<p>a</p><p>b</p><p>c</p>") == "a\n\nb\n\nc")
        #expect(draft("<div><p>a</p></div><div><p>b</p></div>") == "a\n\nb")
    }

    // MARK: - Three editors' Return

    @Test("Each editor's Return markup reads back as the page shows it", arguments: [
        // Thunderbird writes a new <p>, which shows a gap.
        ("<p>Hi Bob,</p><p>Thanks</p>", "Hi Bob,\n\nThanks"),
        // Gmail web writes a new <div>, with no gap.
        ("<div dir=\"ltr\"><div>Hi Bob,</div><div>Thanks</div></div>", "Hi Bob,\nThanks"),
        // Word writes a <p> whose style sheet sets the margin to 0.
        ("""
        <html><head><style><!--
        /* Style Definitions */
        p.MsoNormal, li.MsoNormal, div.MsoNormal
        \t{margin:0cm;
        \tfont-size:11.0pt;
        \tfont-family:"Calibri",sans-serif;}
        @page WordSection1 {size:612.0pt 792.0pt; margin:72.0pt 72.0pt 72.0pt 72.0pt;}
        div.WordSection1 {page:WordSection1;}
        --></style></head><body lang=EN-US><div class=WordSection1>
        <p class=MsoNormal>Hi Bob,<o:p></o:p></p>
        <p class=MsoNormal><o:p>&nbsp;</o:p></p>
        <p class=MsoNormal>Thanks<o:p></o:p></p>
        <p class=MsoNormal>Alice<o:p></o:p></p>
        </div></body></html>
        """, "Hi Bob,\n\nThanks\nAlice"),
    ])
    func editorsReturn(html: String, expected: String) {
        #expect(draft(html) == expected)
    }

    @Test("A paragraph holding only a no-break space is one blank line")
    func noBreakSpaceParagraph() {
        #expect(draft("<p>a</p><p>&nbsp;</p><p>b</p>") == "a\n\nb")
        #expect(draft("<p>a</p><p>&nbsp;</p><p>&nbsp;</p><p>b</p>") == "a\n\n\nb")
        #expect(draft("<div>a</div><div>&nbsp;</div><div>&nbsp;</div><div>b</div>") == "a\n\n\nb")
    }

    @Test("A space after a no-break space is not at the line start, so a draft keeps it", arguments: [
        ("<div>&nbsp;&nbsp;&nbsp; indented</div>", "    indented"),
        ("<div> &nbsp;x</div>", " x"),
        ("<div>&nbsp; &nbsp;x</div>", "   x"),
        ("<p>a &nbsp;b</p>", "a  b"),
        ("<p>a&nbsp; b</p>", "a  b"),
    ])
    func spaceAfterNoBreakSpace(html: String, expected: String) {
        #expect(draft(html) == expected)
    }

    // MARK: - Markup and entities

    @Test("Doctypes, processing instructions, comments and empty end tags show nothing")
    func markupShowsNothing() {
        let html = "<!DOCTYPE html><?xml version=\"1.0\"?>a<!---->b<!-->c</>d<![CDATA[x]]>e"
        #expect(draft(html) == "abcde")
        #expect(collapsed(html) == "abcde")
    }

    @Test("A < that starts no tag is text")
    func lessThanAsText() {
        #expect(collapsed("a < b and 1 <3 you") == "a < b and 1 <3 you")
        #expect(collapsed("x<2y") == "x<2y")
    }

    @Test("Every named reference decodes; an unknown name stays as written")
    func namedReferences() {
        let html = "caf&eacute; &hellip; &euro;5 &unknown; R&amp;D AT&T; &#x2014;"
        #expect(collapsed(html) == "caf\u{00E9} \u{2026} \u{20AC}5 &unknown; R&D AT&T; \u{2014}")
    }

    @Test("A raw-text end tag may carry space before its >")
    func rawTextEndTagWithSpace() {
        #expect(draft("<style>p{margin:0}</style ><p>a</p><p>b</p>") == "a\nb")
        #expect(collapsed("<script>if (a</b) {}</script >x") == "x")
    }

    @Test("Nesting deeper than the open-element cap neither crashes nor loses text")
    func deepNesting() {
        let depth = HTMLText.maxOpenElements + 10
        let html = String(repeating: "<div><span>", count: depth) + "a" + String(repeating: "</span></div>", count: depth) + "b"
        #expect(collapsed(html) == "a\nb")
        #expect(draft(html) == "a\nb")
    }

    // MARK: - Shapes measured in real mail, with placeholder text

    @Test("A mobile-only copy hidden by the sheet shows once in a draft")
    func mobileOnlyCopy() {
        let html = "<style>.mobile{display:none}@media (max-width:600px){.mobile{display:block !important}}</style>"
            + "<div class=\"desktop\">Pay your bill</div><div class=\"mobile\">Pay your bill</div><p>Thanks</p>"
        #expect(draft(html) == "Pay your bill\n\nThanks")
        #expect(collapsed(html) == "Pay your bill\nPay your bill\nThanks")
    }

    @Test("Links that each wrap a block keep their own lines")
    func blockInsideLinks() {
        let html = "<p>Top picks</p><a href=\"https://example.com/1\"><div>1. First pick</div></a>"
            + "<a href=\"https://example.com/2\"><div>2. Second pick</div></a><p>End</p>"
        #expect(draft(html) == "Top picks\n\n[1. First pick](https://example.com/1)\n[2. Second pick](https://example.com/2)\n\nEnd")
        #expect(collapsed(html) == "Top picks\n[1. First pick](https://example.com/1)\n[2. Second pick](https://example.com/2)\nEnd")
    }

    @Test("A later display declaration wins; an unknown property name hides nothing", arguments: [
        "<span style=\"display:none;display:block\">shown</span>",
        "<span style=\"&#8221;display:none\">shown</span>",
    ])
    func displayDeclarationCascade(html: String) {
        #expect(draft("<p>a</p>" + html) == "a\n\nshown")
        #expect(collapsed("<p>a</p>" + html) == "a\nshown")
    }

    @Test("Word's conditional list markers and comments add nothing of their own")
    func wordConditionals() {
        let list = "<p class=MsoListParagraph><![if !supportLists]>1.&nbsp;&nbsp;<![endif]>First item</p>"
            + "<p class=MsoListParagraph><![if !supportLists]>2.&nbsp;&nbsp;<![endif]>Second item</p>"
        #expect(draft(list) == "1.  First item\n\n2.  Second item")
        #expect(collapsed(list) == "1. First item\n2. Second item")
        let mso = "<!--[if mso]><table><tr><td><![endif]--><p>Body text</p><!--[if mso]></td></tr></table><![endif]-->"
        #expect(draft(mso) == "Body text")
        #expect(collapsed(mso) == "Body text")
    }
}
