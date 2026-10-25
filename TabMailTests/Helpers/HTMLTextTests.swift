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
        "<style>.sig{display:none}</style><p style=\"margin:0\">a</p><div class=\"note sig\">x</div>",
        "<style>DIV.sig{display:none}</style><p style=\"margin:0\">a</p><div class=\"sig\">x</div>",
        "<style>div.sig{display:none}</style><p style=\"margin:0\">a</p><div class=\"sig\">x</div>",
        "<style>#sig{display:none}</style><p style=\"margin:0\">a</p><div id=\"sig\">x</div>",
        "<style>h1, #sig , p.y{display:none}</style><p style=\"margin:0\">a</p><div id=\"sig\">x</div>",
    ])
    func selectorForms(html: String) {
        #expect(draft(html) == "a")
    }

    @Test("Class and id match exactly, as in a standards-mode page", arguments: [
        "<style>.sig{display:none}</style><div class=\"SIG\">x</div>",
        "<style>.SIG{display:none}</style><div class=\"sig\">x</div>",
        "<style>#sig{display:none}</style><div id=\"Sig\">x</div>",
    ])
    func classAndIDMatchExactly(html: String) {
        #expect(draft(html) == "x")
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
        let leading = "<div>&nbsp;</div><div>Visible</div>"
        #expect(draft(leading) == "\nVisible")
        #expect(collapsed(leading) == "\nVisible")
        #expect(adopted(leading) == "\nVisible")
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
        // The longest name in the HTML table, and a name that decodes to two scalars.
        let long = "a&CounterClockwiseContourIntegral;b &NotEqualTilde; c"
        #expect(collapsed(long) == "a\u{2233}b \u{2242}\u{0338} c")
        #expect(draft(long) == "a\u{2233}b \u{2242}\u{0338} c")
        #expect(adopted(long) == "a\u{2233}b \u{2242}\u{0338} c")
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

    // MARK: - Round-1 review cases, each checked against WebKit

    @Test("A block or list item ends the paragraph or item left open, with its style", arguments: [
        ("<style>.x{display:none}</style><p class=x>hidden<p>shown", "shown", "hidden\nshown"),
        ("<style>.x{display:none}</style><ul><li class=x>hidden<li>shown</ul>", "shown", "hidden\nshown"),
        ("<style>.x{display:none}</style><dl><dt class=x>hidden<dd>shown</dl>", "shown", "hidden shown"),
        ("<p>a<div>b</div>", "a\n\nb", "a\nb"),
        // An element in between keeps the outer one open.
        ("<p>a</p><style>.x{display:none}</style><p class=x>hidden<object><div>inner</div></object></p><p>b</p>", "a\n\nb", "a\nhidden\ninner\nb"),
        ("<style>.x{display:none}</style><ul><li class=x>hidden<ul><li>inner</ul></ul><p>b</p>", "b", "hidden\ninner\nb"),
    ])
    func impliedEnds(html: String, draft expectedDraft: String, collapsed expectedCollapsed: String) {
        #expect(draft(html) == expectedDraft)
        #expect(collapsed(html) == expectedCollapsed)
    }

    @Test("!important beats a later or inline declaration without it", arguments: [
        ("<div>a</div><div style=\"display:none !important;display:block\">x</div><div>b</div>", "a\nb", "a\nb"),
        ("<style>.x{display:none !important}</style><div>a</div><div class=x style=\"display:block\">x</div><div>b</div>", "a\nb", "a\nx\nb"),
        ("<style>.x{display:none !important}</style><div class=x style=\"display:block !important\">x</div>", "x", "x"),
        ("<style>p{margin:0 !important}</style><p style=\"margin:1em 0\">a</p><p>b</p>", "a\nb", "a\nb"),
        // An !important rule beats a later rule without it, for the same selector or another.
        ("<style>.x{display:none !important} .x{display:block} div{display:block}</style><div>a</div><div class=x>x</div><div>b</div>", "a\nb", "a\nx\nb"),
    ])
    func importantDeclarations(html: String, draft expectedDraft: String, collapsed expectedCollapsed: String) {
        #expect(draft(html) == expectedDraft)
        #expect(collapsed(html) == expectedCollapsed)
    }

    @Test("An invalid display value is ignored, never undoing a valid one", arguments: [
        ("<div>a</div><div style=\"display:none;display:garbage\">x</div><div>b</div>", "a\nb"),
        ("<div>a</div><div style=\"display:none garbage\">x</div><div>b</div>", "a\nx\nb"),
        ("<div>a</div><div style=\"display:block;display:none garbage\">x</div><div>b</div>", "a\nx\nb"),
        ("<div>a</div><div style=\"display:none;display:inline flex\">x</div><div>b</div>", "a\nx\nb"),
    ])
    func invalidDisplayIgnored(html: String, expected: String) {
        #expect(draft(html) == expected)
        #expect(collapsed(html) == expected)
    }

    @Test("A style sheet applies to the whole document, wherever it sits")
    func styleSheetAfterContent() {
        let html = "<div class=x>hidden</div><style>.x{display:none}</style><div>shown</div>"
        #expect(draft(html) == "shown")
        #expect(collapsed(html) == "hidden\nshown")
        // Not a style sheet: inside a comment, or text in a script.
        #expect(draft("<!-- <style>.x{display:none}</style> --><div class=x>a</div>") == "a")
        #expect(draft("<script>s = \"<style>.x{display:none}</style>\"</script><div class=x>a</div>") == "a")
    }

    @Test("The end of a style sheet closes a rule left open")
    func ruleOpenAtEnd() {
        #expect(draft("<style>.x{display:none</style><div class=x>hidden</div><div>shown</div>") == "shown")
        #expect(draft("<style>p{margin:0</style><p>a</p><p>b</p>") == "a\nb")
    }

    @Test("A CSS comment separates the words around it", arguments: [
        ("<div>a</div><div style=\"dis/**/play:none\">x</div>", "a\nx"),
        ("<div>a</div><div style=\"display:/**/none\">x</div>", "a"),
    ])
    func commentSeparatesTokens(html: String, expected: String) {
        #expect(draft(html) == expected)
        #expect(collapsed(html) == expected)
    }

    @Test("An escaped quote in a CSS string never starts a comment")
    func escapedQuoteInString() {
        let html = "<div>a</div><div style=\"font-family:'a\\'/*';display:none\">x</div><div>b</div>"
        #expect(draft(html) == "a\nb")
        #expect(collapsed(html) == "a\nb")
    }

    @Test("A declaration of another property leaves the white-space as it was")
    func unrelatedDeclarationKeepsWhiteSpace() {
        let html = "<style>p{margin:0}</style><pre style=\"color:red\">a  b\nc</pre>"
        #expect(draft(html) == "a  b\nc")
        #expect(collapsed(html) == "a b c")
    }

    @Test("A block's margin inside a link still applies after the link")
    func marginAfterBlockInLink() {
        let html = "<a href=\"https://example.com/\"><p>Label</p></a><div>Next</div>"
        #expect(draft(html) == "[Label](https://example.com/)\n\nNext")
        #expect(collapsed(html) == "[Label](https://example.com/)\nNext")
    }

    @Test("A joiner after an ASCII character is dropped in every mode", arguments: [
        ("x\u{200D}\u{1F469}", "x\u{1F469}"),
        ("1&zwnj;\u{4E2D}", "1\u{4E2D}"),
        ("a&#x200D;\u{1F4BB}", "a\u{1F4BB}"),
    ])
    func joinerAfterASCII(html: String, expected: String) {
        #expect(draft(html) == expected)
        #expect(collapsed(html) == expected)
    }

    @Test("A raw-text end tag needs white space, / or > after its name")
    func rawTextEndTagDelimiter() {
        let html = "<style>/* </style-x> hidden */</style><div>shown</div>"
        #expect(draft(html) == "shown")
        #expect(collapsed(html) == "shown")
        #expect(collapsed("<script>a</script-x>b</script/>c") == "c")
    }

    // MARK: - Round-2 review cases, each checked against WebKit

    @Test("A cell, row or row group ends the one left open, with its style, within its own table", arguments: [
        ("<style>.x{display:none}</style><table><tr><td class=x>hidden<td>shown</tr></table><div>end</div>", "shown\nend", "hidden shown\nend"),
        ("<style>.x{display:none}</style><table><tr class=x><td>hidden<tr><td>shown</table>", "shown", "hidden\nshown"),
        ("<style>.x{display:none}</style><table><tbody class=x><tr><td>hidden<tbody><tr><td>shown</table>", "shown", "hidden\nshown"),
        ("<style>.x{display:none}</style><table><tr><td class=x>hidden</td><td>shown</td></tr></table>", "shown", "hidden shown"),
        ("<style>.x{display:none}</style><table><tr><th class=x>hidden<th>shown</table>", "shown", "hidden shown"),
        ("<style>.x{display:none}</style><table><tr><th class=x>hidden<td>shown</table>", "shown", "hidden shown"),
        // A nested table's cells end only its own: the outer hidden cell stays open around it.
        ("<style>.x{display:none}</style><table><tr><td class=x><table><tr><td>inner<td>inner</table>hidden<td>shown</table>", "shown", "inner inner\nhidden shown"),
    ])
    func impliedTableEnds(html: String, draft expectedDraft: String, collapsed expectedCollapsed: String) {
        #expect(draft(html) == expectedDraft)
        #expect(collapsed(html) == expectedCollapsed)
    }

    @Test("A draft keeps a cell's visible sibling when a hidden cell's end tag is left out", arguments: ["td", "th"])
    func draftKeepsSiblingOfHiddenCell(cell: String) {
        let html = "<style>.x{display:none}</style><table><tr><\(cell) class=x>hidden<\(cell)>shown</tr></table>"
        #expect(ExternalDraftAdoption.editableBody(text: nil, html: html, bodyEmptyConfirmed: true, hasAttachments: false) == "shown")
    }

    /// A `<style>` styles the screen only when it is CSS for the screen; WebKit agrees on each case.
    @Test("A style sheet for other media, or not CSS, hides nothing", arguments: [
        ("media='print'", false), ("media=speech", false), ("type='text/plain'", false),
        ("type='text/javascript' media=screen", false), ("media='not all'", false),
        ("", true), ("media=''", true), ("type=''", true), ("type='text/css'", true), ("type=TEXT/CSS", true),
        ("media=screen", true), ("media='all'", true), ("media='print, screen'", true),
        ("media='only screen and (max-width: 600px)'", true), ("media='(min-width: 1px)'", true), ("media='not print'", true),
        ("type=' text/css '", false), ("type='text/css '", false), ("media='print, '", false), ("media='print,'", false),
        ("media=','", false), ("media='only'", false), ("media='not'", false), ("media='only screen'", true),
        ("media='print, , screen'", true),
    ])
    func styleSheetApplicability(attributes: String, applies: Bool) {
        let html = "<style \(attributes)>.x{display:none}</style><div class=x>Keep this draft text</div><div>Footer</div>"
        let expected = applies ? "Footer" : "Keep this draft text\nFooter"
        #expect(draft(html) == expected)
        #expect(ExternalDraftAdoption.editableBody(text: nil, html: html, bodyEmptyConfirmed: true, hasAttachments: false) == expected)
        #expect(collapsed(html) == "Keep this draft text\nFooter")
    }

    @Test("CSS white space before important keeps the priority", arguments: ["! important", "!\nimportant", "!\rimportant", "!\u{0C}important", "!\timportant ", "!IMPORTANT"])
    func whiteSpaceBeforeImportant(bang: String) {
        let html = "<div>before</div><div style='display:none \(bang);display:block'>hidden</div><div>after</div>"
        #expect(draft(html) == "before\nafter")
        #expect(collapsed(html) == "before\nafter")
    }

    @Test("A display value shows only in a valid combination of its keywords", arguments: [
        ("block", true), ("inline flex", true), ("flex inline", true), ("block math", true), ("list-item", true),
        ("list-item block", true), ("inline flow-root list-item", true), ("table-cell", true), ("inline-block", true),
        ("contents", true), ("inherit", true),
        ("block block", false), ("inline block", false), ("flex grid", false), ("list-item table", false),
        ("list-item list-item", false), ("block flow list-item list-item", false), ("table-cell block", false),
        ("inline-block flow", false), ("contents block", false), ("inherit block", false), ("inline-math", false),
    ])
    func displayGrammar(value: String, shows: Bool) {
        let html = "<div>a</div><div style='display:none;display:\(value)'>x</div><div>b</div>"
        #expect(draft(html) == (shows ? "a\nx\nb" : "a\nb"), "\(value)")
        #expect(collapsed(html) == (shows ? "a\nx\nb" : "a\nb"), "\(value)")
    }

    @Test("A raw CR, LF or CRLF is one line feed; a CR reference is a space", arguments: ["\r", "\n", "\r\n"])
    func rawNewlines(newline: String) {
        let html = "<div style='white-space:pre-wrap'>a" + newline + "b</div>"
        #expect(draft(html) == "a\nb")
        #expect(collapsed(html) == "a b")
        #expect(ExternalDraftAdoption.editableBody(text: nil, html: html, bodyEmptyConfirmed: true, hasAttachments: false) == "a\nb")
        #expect(draft("<pre>" + newline + "a" + newline + newline + "b</pre>") == "a\n\nb")
    }

    @Test("A character reference to CR is a space in preserved white space")
    func carriageReturnReference() {
        #expect(draft("<div style='white-space:pre-wrap'>a&#13;b</div>") == "a b")
        #expect(draft("<div style='white-space:pre-line'>a&#13;b</div>") == "a b")
    }

    @Test("A sheet's !important white-space beats an inline one without it")
    func importantSheetWhiteSpace() {
        #expect(draft("<style>.x{white-space:pre !important}</style><div class=x style='white-space:normal'>a  b</div>") == "a  b")
        #expect(draft("<style>.x{white-space:pre}</style><div class=x style='white-space:normal'>a  b</div>") == "a b")
        #expect(collapsed("<style>.x{white-space:pre !important}</style><div class=x>a  b</div>") == "a b")
    }

    @Test("A tag.class rule applies only to that tag, a .class rule to every tag")
    func tagQualifiedClassRule() {
        #expect(draft("<style>span.x{display:none}</style><div class=x>shown</div><span class=x>hidden</span>") == "shown")
        #expect(draft("<style>.x{display:none}</style><div class=x>hidden</div><span class=x>hidden</span><div>shown</div>") == "shown")
    }

    @Test("A hidden block adds no line between the text around it")
    func hiddenBlockAddsNoLine() {
        let html = "<div>before <div style='display:none'>hidden</div> after</div>"
        #expect(draft(html) == "before after")
        #expect(collapsed(html) == "before after")
        let visible = "<div>before <div>visible</div> after</div>"
        #expect(draft(visible) == "before\nvisible\nafter")
        #expect(collapsed(visible) == "before\nvisible\nafter")
    }

    @Test("An element left open stays hidden to the end of the input")
    func hiddenThroughEnd() {
        #expect(draft("before<div style='display:none'>hidden") == "before")
        #expect(collapsed("before<div style='display:none'>hidden <b>more</b> text") == "before")
        #expect(draft("before<div>visible") == "before\nvisible")
    }

    /// Before only each property's winning rule was kept, every element replayed every rule
    /// naming it: 2,048 `p` rules and paragraphs took 2.8 s, four times as long per doubling.
    @Test("Many rules naming an element cost it no more than one", .timeLimit(.minutes(1)))
    func manyMatchingRules() {
        let count = 20_000
        let html = "<style>" + String(repeating: "p{margin:0}", count: count) + "</style>" + String(repeating: "<p>x</p>", count: count)
        let start = ContinuousClock.now
        let text = draft(html)
        let elapsed = ContinuousClock.now - start
        #expect(text.split(separator: "\n").count == count)
        #expect(elapsed < .seconds(5))
    }

    /// When a `tag.class` lookup built a key holding the tag for each class, a long tag name with
    /// many classes cost their product: 64,000 of each took 1.2 s, 60 times as long for 8 times
    /// the input.
    @Test("A long tag name with many classes costs no more than its length", .timeLimit(.minutes(1)))
    func longTagWithManyClasses() {
        let count = 128_000
        let tag = String(repeating: "t", count: count)
        let html = "<style>.unused{white-space:pre}</style><\(tag) class='" + String(repeating: "c ", count: count) + "'>visible</\(tag)>"
        let start = ContinuousClock.now
        let text = draft(html)
        let elapsed = ContinuousClock.now - start
        #expect(text == "visible")
        #expect(elapsed < .seconds(1))
    }

    /// Before rules were indexed, every element checked every rule: 4,000 of each took
    /// 2.8 s, and the time grew with their product.
    @Test("Many unused rules cost an element nothing", .timeLimit(.minutes(1)))
    func manyRules() {
        let count = 20_000
        let rules = (0..<count).map { ".r\($0){margin:0}" }.joined()
        let body = String(repeating: "<div>line</div>", count: count)
        let start = ContinuousClock.now
        let text = draft("<style>\(rules)</style>" + body)
        let elapsed = ContinuousClock.now - start
        #expect(text.split(separator: "\n").count == count)
        #expect(elapsed < .seconds(5))
    }

    private func adopted(_ html: String) -> String? {
        ExternalDraftAdoption.editableBody(text: nil, html: html, bodyEmptyConfirmed: false, hasAttachments: false)
    }

    @Test("A line feed reference reads as a written line feed, in every white-space mode",
          arguments: ["&#10;", "&#x0a;", "&#X0A;", "&#010;", "&NewLine;"])
    func lineFeedReference(reference: String) {
        for style in ["normal", "nowrap", "pre", "pre-wrap", "break-spaces", "pre-line"] {
            let html = "<div style='white-space:\(style)'>one\(reference)two</div>"
            let expected = style == "normal" || style == "nowrap" ? "one two" : "one\ntwo"
            #expect(draft(html) == expected, "\(style)")
            #expect(adopted(html) == expected, "\(style)")
            #expect(collapsed(html) == "one two", "\(style)")
        }
        #expect(draft("<div>one\(reference)two</div>") == "one two")
        // HTML drops one line feed right after `<pre>`, a reference's as well as a written one.
        #expect(draft("<div>x</div><pre>\(reference)one</pre>") == "x\none")
        #expect(draft("<div>x</div><pre>\(reference)\(reference)one</pre>") == "x\n\none")
        #expect(draft("<div>x</div><pre>\n\(reference)one</pre>") == "x\n\none")
        #expect(draft("<div>x</div><pre>\r\(reference)one</pre>") == "x\n\none")
        #expect(collapsed("<div>x</div><pre>\(reference)one</pre>") == "x\none")
        // Only right after `<pre>`: anywhere else a leading line feed stays.
        #expect(draft("<div>x</div><div style='white-space:pre'>\(reference)one</div>") == "x\n\none")
        #expect(draft("<div>x</div><pre><b></b>\(reference)one</pre>") == "x\n\none")
    }

    @Test("Only a line feed is dropped after <pre>: a CR reference stays a space")
    func carriageReturnReferenceAfterPre() {
        #expect(draft("<div>x</div><pre>&#13;one</pre>") == "x\n one")
        #expect(draft("<div>x</div><pre>&amp;one</pre>") == "x\n&one")
    }

    /// CSS and HTML class lists split on ASCII white space only; a no-break space is a
    /// character of the word, so the value it sits in is invalid (CSS) or one class (HTML).
    @Test("A no-break space is part of a CSS word, never white space", arguments: [
        ("display:\u{00A0}none", true), ("display:none\u{00A0}", true), ("display:none\u{00A0}!important", true),
        ("display:none;display:inline\u{00A0}flex", false), ("display:none;display:block\u{00A0}", false),
        ("display:\tnone", false), ("display: none\u{0C}", false), ("display:none\t!important;display:block", false),
        ("display:none;display:inline\tflex", true), ("display:none;display:block ", true),
    ])
    func noBreakSpaceInCSS(declarations: String, shows: Bool) {
        let html = "<div style='\(declarations)'>Keep text</div><div>Footer</div>"
        let expected = shows ? "Keep text\nFooter" : "Footer"
        #expect(draft(html) == expected)
        #expect(adopted(html) == expected)
        #expect(collapsed(html) == expected)
    }

    @Test("A no-break space in white-space or a class list is part of the word")
    func noBreakSpaceInWhiteSpaceAndClasses() {
        #expect(draft("<div style='white-space:pre\u{00A0}'>a  b</div>") == "a b")
        #expect(draft("<div style='white-space:\u{00A0}pre'>a  b</div>") == "a b")
        #expect(draft("<div style='white-space:\tpre '>a  b</div>") == "a  b")
        #expect(draft("<div style='white-space:normal;white-space:pre\u{00A0}!important'>a  b</div>") == "a b")
        let sheet = "<style>.x{display:none}</style>"
        #expect(adopted(sheet + "<div class='x\u{00A0}y'>Keep text</div><div>Footer</div>") == "Keep text\nFooter")
        #expect(adopted(sheet + "<div class='y\u{00A0}x'>Keep text</div><div>Footer</div>") == "Keep text\nFooter")
        #expect(adopted(sheet + "<div class='y\tx'>Keep text</div><div>Footer</div>") == "Footer")
        #expect(adopted(sheet + "<div class='y\u{0C}x\ny'>Keep text</div><div>Footer</div>") == "Footer")
    }

    /// A `<template>`'s content is inert: its style sheets apply to nothing and its text never shows.
    @Test("A template's style sheet and text do nothing")
    func templateIsInert() {
        let rule = "<style>.x{display:none}</style>"
        let target = "<div class=x>Keep text</div><div>Footer</div>"
        #expect(adopted("<template>\(rule)</template>" + target) == "Keep text\nFooter")
        #expect(adopted("<TEMPLATE><div>\(rule)</div></TEMPLATE>" + target) == "Keep text\nFooter")
        #expect(adopted("<template><template></template>\(rule)</template>" + target) == "Keep text\nFooter")
        #expect(adopted("<template><template>\(rule)</template></template>" + target) == "Keep text\nFooter")
        // Outside every template, and after a stray end tag, a sheet still applies.
        #expect(adopted("<template></template>\(rule)" + target) == "Footer")
        #expect(adopted("<template><template></template></template>\(rule)" + target) == "Footer")
        #expect(adopted("</template>\(rule)" + target) == "Footer")
        #expect(adopted("</template><template></template>\(rule)" + target) == "Footer")
        #expect(adopted(rule + target) == "Footer")
        for html in ["<div>a</div><template><div>inert</div></template><div>b</div>",
                     "<div>a</div><template><template>inert</template>inert</template><div>b</div>"] {
            #expect(draft(html) == "a\nb")
            #expect(collapsed(html) == "a\nb")
        }
    }
}
