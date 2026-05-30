/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

// MARK: - extractPills

@Suite("MarkdownChatText.extractPills")
struct ExtractPillsTests {

    @Test("Plain text without pills passes through unchanged")
    func noPills() {
        let input = "Hello, world. No pills here."
        let (text, pills) = MarkdownChatText.extractPills(input)
        #expect(text == input)
        #expect(pills.isEmpty)
    }

    @Test("Single email pill extracted to sentinel + table entry")
    func singleEmailPill() {
        let input = "See [📧 Q3 Budget](tabmail://email/501) for details."
        let (text, pills) = MarkdownChatText.extractPills(input)
        #expect(pills.count == 1)
        guard pills.count == 1 else { return }
        #expect(pills[0].index == 0)
        #expect(pills[0].numericId == 501)
        #expect(pills[0].type == "email")
        #expect(pills[0].label == "📧 Q3 Budget")
        #expect(text == "See \u{E000}0\u{E001} for details.")
        #expect(!text.contains("tabmail://"))
    }

    @Test("Multiple pills get sequential indices in occurrence order")
    func multiplePills() {
        let input = "[📧 A](tabmail://email/10) and [👤 Bob](tabmail://contact/20) plus [📅 Mtg](tabmail://event/30)."
        let (text, pills) = MarkdownChatText.extractPills(input)
        #expect(pills.count == 3)
        guard pills.count == 3 else { return }
        #expect(pills[0].index == 0 && pills[0].numericId == 10 && pills[0].type == "email")
        #expect(pills[1].index == 1 && pills[1].numericId == 20 && pills[1].type == "contact")
        #expect(pills[2].index == 2 && pills[2].numericId == 30 && pills[2].type == "event")
        #expect(text == "\u{E000}0\u{E001} and \u{E000}1\u{E001} plus \u{E000}2\u{E001}.")
    }

    @Test("Pill inside list-item context is extracted (key fix for the bug)")
    func pillInListItem() {
        let input = "- [📧 Re: Tenant](tabmail://email/433) — open this first"
        let (text, pills) = MarkdownChatText.extractPills(input)
        #expect(pills.count == 1)
        // Critical: the dash + sentinel survives so the line classifier still
        // sees the line as a list item, but no tabmail:// URL is left for
        // AttributedString markdown to turn into a tappable system link.
        #expect(text == "- \u{E000}0\u{E001} — open this first")
        #expect(!text.contains("tabmail://"))
    }

    @Test("Pill inside blockquote context is extracted")
    func pillInBlockquote() {
        let input = "> Quoted: [📧 Note](tabmail://email/77)"
        let (text, pills) = MarkdownChatText.extractPills(input)
        #expect(pills.count == 1)
        #expect(text == "> Quoted: \u{E000}0\u{E001}")
    }

    @Test("Pill inside header context is extracted")
    func pillInHeader() {
        let input = "## Topic: [📧 Plan](tabmail://email/9)"
        let (text, pills) = MarkdownChatText.extractPills(input)
        #expect(pills.count == 1)
        #expect(text == "## Topic: \u{E000}0\u{E001}")
    }

    @Test("Same pill appearing twice produces two table entries (occurrence order)")
    func duplicatePill() {
        let input = "[📧 X](tabmail://email/5) and again [📧 X](tabmail://email/5)"
        let (text, pills) = MarkdownChatText.extractPills(input)
        #expect(pills.count == 2)
        guard pills.count == 2 else { return }
        #expect(pills[0].numericId == 5)
        #expect(pills[1].numericId == 5)
        #expect(text == "\u{E000}0\u{E001} and again \u{E000}1\u{E001}")
    }

    @Test("Label with nested [bracketed tag] is extracted (Korean banking subjects)")
    func pillWithNestedBracketsInLabel() {
        // Real-world case from logmain.log: subject `[NH농협카드]표준 …` produces
        // a label that contains an inner `]`. The original `[^\]]+` regex stopped
        // at the first inner `]` and missed the pill — the link survived as a
        // tappable system URL ("Absorbed stray tabmail://" log line).
        let input = "Re: [📧 [NH농협카드]표준 전자금융거래 기본 약관 개정 안내](tabmail://email/504) info"
        let (text, pills) = MarkdownChatText.extractPills(input)
        #expect(pills.count == 1)
        guard pills.count == 1 else { return }
        #expect(pills[0].numericId == 504)
        #expect(pills[0].type == "email")
        #expect(pills[0].label == "📧 [NH농협카드]표준 전자금융거래 기본 약관 개정 안내")
        #expect(text == "Re: \u{E000}0\u{E001} info")
        #expect(!text.contains("tabmail://"))
    }

    @Test("Multiple consecutive pills with nested brackets each get their own opener")
    func multiplePillsWithNestedBrackets() {
        let input = "[📧 [tag1]A](tabmail://email/1) then [📧 [tag2]B](tabmail://email/2)"
        let (text, pills) = MarkdownChatText.extractPills(input)
        #expect(pills.count == 2)
        guard pills.count == 2 else { return }
        #expect(pills[0].label == "📧 [tag1]A")
        #expect(pills[1].label == "📧 [tag2]B")
        #expect(text == "\u{E000}0\u{E001} then \u{E000}1\u{E001}")
    }

    @Test("Unbalanced label (stray `]` with no matching `[`) leaves link intact")
    func unbalancedLabelLeavesLinkIntact() {
        // Defensive: if the input is truly broken (no `[` before the `]`), we
        // bail rather than producing nonsense. The literal markdown link stays;
        // handleExternalURL still absorbs the tap.
        let input = "stray ] before](tabmail://email/9) tail"
        let (text, pills) = MarkdownChatText.extractPills(input)
        #expect(pills.isEmpty)
        #expect(text == input)
    }

    @Test("Template pill is extracted to sentinel + table entry (regression)")
    func templatePill() {
        let input = "Use [📝 Polite reply](tabmail://template/77) for this thread."
        let (text, pills) = MarkdownChatText.extractPills(input)
        #expect(pills.count == 1)
        guard pills.count == 1 else { return }
        #expect(pills[0].numericId == 77)
        #expect(pills[0].type == "template")
        #expect(pills[0].label == "📝 Polite reply")
        #expect(text == "Use \u{E000}0\u{E001} for this thread.")
        #expect(!text.contains("tabmail://"))
    }

    @Test("Template + email + contact pills coexist in one line (regression)")
    func mixedPillsIncludingTemplate() {
        let input = "[📧 Q3](tabmail://email/1) for [👤 Bob](tabmail://contact/2) using [📝 Polite](tabmail://template/3)."
        let (_, pills) = MarkdownChatText.extractPills(input)
        #expect(pills.count == 3)
        guard pills.count == 3 else { return }
        #expect(pills[0].type == "email")
        #expect(pills[1].type == "contact")
        #expect(pills[2].type == "template" && pills[2].numericId == 3)
    }
}

// MARK: - splitAtSentinels

@Suite("MarkdownChatText.splitAtSentinels")
struct SplitAtSentinelsTests {

    @Test("Text without sentinels returns single .text run")
    func noSentinels() {
        let runs = MarkdownChatText.splitAtSentinels("just plain text", pills: [])
        #expect(runs.count == 1)
        guard runs.count == 1, case .text(let attr) = runs[0] else { return }
        #expect(String(attr.characters) == "just plain text")
    }

    @Test("Single sentinel produces text + pill + text runs")
    func oneSentinel() {
        let pills = [PillRef(index: 0, numericId: 42, type: "email", label: "📧 Hi")]
        let runs = MarkdownChatText.splitAtSentinels("before \u{E000}0\u{E001} after", pills: pills)
        #expect(runs.count == 3)
        guard runs.count == 3 else { return }
        if case .text(let a) = runs[0] { #expect(String(a.characters) == "before ") } else { Issue.record("Run 0 was not .text") }
        if case .pill(let p) = runs[1] { #expect(p.numericId == 42 && p.type == "email") } else { Issue.record("Run 1 was not .pill") }
        if case .text(let a) = runs[2] { #expect(String(a.characters) == " after") } else { Issue.record("Run 2 was not .text") }
    }

    @Test("Sentinel at start emits pill first")
    func sentinelAtStart() {
        let pills = [PillRef(index: 0, numericId: 1, type: "email", label: "X")]
        let runs = MarkdownChatText.splitAtSentinels("\u{E000}0\u{E001} after", pills: pills)
        #expect(runs.count == 2)
        guard runs.count == 2 else { return }
        if case .pill = runs[0] {} else { Issue.record("Run 0 was not .pill") }
        if case .text(let a) = runs[1] { #expect(String(a.characters) == " after") } else { Issue.record("Run 1 was not .text") }
    }

    @Test("Multiple sentinels interleave correctly")
    func multipleSentinels() {
        let pills = [
            PillRef(index: 0, numericId: 1, type: "email", label: "A"),
            PillRef(index: 1, numericId: 2, type: "email", label: "B"),
        ]
        let runs = MarkdownChatText.splitAtSentinels("\u{E000}0\u{E001} and \u{E000}1\u{E001}", pills: pills)
        #expect(runs.count == 3)
        guard runs.count == 3 else { return }
        if case .pill(let p) = runs[0] { #expect(p.numericId == 1) } else { Issue.record("Run 0 was not .pill(1)") }
        if case .text(let a) = runs[1] { #expect(String(a.characters) == " and ") } else { Issue.record("Run 1 was not .text") }
        if case .pill(let p) = runs[2] { #expect(p.numericId == 2) } else { Issue.record("Run 2 was not .pill(2)") }
    }

    @Test("Sentinel index out of range is skipped (defensive)")
    func outOfRange() {
        let pills = [PillRef(index: 0, numericId: 1, type: "email", label: "A")]
        // Index 5 doesn't exist in pills table — should be silently dropped.
        let runs = MarkdownChatText.splitAtSentinels("before \u{E000}5\u{E001} after", pills: pills)
        // Two text runs (before/after), pill skipped.
        #expect(runs.count == 2)
    }

    @Test("Pill with nested-bracket label round-trips: extract → splice → chip")
    func nestedBracketLabelRoundTrip() {
        // End-to-end: extractPills must recover the full label, and splitAtSentinels
        // must hand the same label back as a .pill run. The original ASCII brackets
        // survive into the rendered chip — that's the visible-text guarantee that
        // motivated the scanner over source-side sanitization.
        let input = "Re: [📧 [NH농협카드]표준 약관](tabmail://email/77) info"
        let (sentinelText, pills) = MarkdownChatText.extractPills(input)
        #expect(pills.count == 1)
        guard pills.count == 1 else { return }

        let runs = MarkdownChatText.splitAtSentinels(sentinelText, pills: pills)
        #expect(runs.count == 3)
        guard runs.count == 3 else { return }
        if case .text(let a) = runs[0] { #expect(String(a.characters) == "Re: ") } else { Issue.record("Run 0 was not .text") }
        if case .pill(let p) = runs[1] {
            #expect(p.numericId == 77)
            #expect(p.label == "📧 [NH농협카드]표준 약관")
        } else { Issue.record("Run 1 was not .pill") }
        if case .text(let a) = runs[2] { #expect(String(a.characters) == " info") } else { Issue.record("Run 2 was not .text") }
    }
}

// MARK: - End-to-end pipeline

@Suite("MarkdownChatText sentinel pipeline")
struct SentinelPipelineTests {

    @Test("Pill in list item: extract + parseIntoLines preserves sentinel inside .listItem")
    func pillInListItemSurvivesPipeline() {
        let input = "- [📧 Tenant Issue](tabmail://email/433) is the next one"
        let (sentinelText, pills) = MarkdownChatText.extractPills(input)
        #expect(pills.count == 1)

        let lines = MarkdownChatText.parseIntoLines(sentinelText)
        #expect(lines.count == 1)
        guard lines.count == 1, lines[0].segments.count == 1 else { return }

        // Must be classified as a list item — sentinel doesn't disrupt the leading dash.
        guard case .listItem(_, _, _, let text) = lines[0].segments[0].kind else {
            Issue.record("Expected .listItem segment")
            return
        }
        // Text must contain the sentinel — confirms the pill rides INSIDE the list-item
        // text and will be spliced back to a chip by inlineRuns at render time.
        #expect(text.contains("\u{E000}0\u{E001}"))
        #expect(!text.contains("tabmail://"))
    }

    @Test("Pill in blockquote: extract + parseIntoLines preserves sentinel inside .blockquote")
    func pillInBlockquoteSurvivesPipeline() {
        let input = "> Reference: [📧 Plan](tabmail://email/9)"
        let (sentinelText, pills) = MarkdownChatText.extractPills(input)
        #expect(pills.count == 1)

        let lines = MarkdownChatText.parseIntoLines(sentinelText)
        #expect(lines.count == 1)
        guard lines.count == 1, lines[0].segments.count == 1 else { return }

        guard case .blockquote(let text) = lines[0].segments[0].kind else {
            Issue.record("Expected .blockquote segment")
            return
        }
        #expect(text.contains("\u{E000}0\u{E001}"))
        #expect(!text.contains("tabmail://"))
    }

    @Test("Pill in header: extract + parseIntoLines preserves sentinel inside .header")
    func pillInHeaderSurvivesPipeline() {
        let input = "## Topic: [📧 Notes](tabmail://email/42)"
        let (sentinelText, pills) = MarkdownChatText.extractPills(input)
        #expect(pills.count == 1)

        let lines = MarkdownChatText.parseIntoLines(sentinelText)
        #expect(lines.count == 1)
        guard lines.count == 1, lines[0].segments.count == 1 else { return }

        guard case .header(let level, let text) = lines[0].segments[0].kind else {
            Issue.record("Expected .header segment")
            return
        }
        #expect(level == 2)
        #expect(text.contains("\u{E000}0\u{E001}"))
        #expect(!text.contains("tabmail://"))
    }

    @Test("Pill in table cell: extract + parseIntoLines stores sentinel in cell string")
    func pillInTableCellSurvivesPipeline() {
        let input = "| Subject | Link |\n|---|---|\n| Q3 Plan | [📧 Plan](tabmail://email/8) |"
        let (sentinelText, pills) = MarkdownChatText.extractPills(input)
        #expect(pills.count == 1)

        let lines = MarkdownChatText.parseIntoLines(sentinelText)
        // Table is captured as a single ContentLine with a `.table` segment.
        #expect(lines.count == 1)
        guard lines.count == 1, lines[0].segments.count == 1 else { return }

        guard case .table(let rows) = lines[0].segments[0].kind else {
            Issue.record("Expected .table segment")
            return
        }
        // 2 rows (header + body); separator row is filtered.
        #expect(rows.count == 2)
        guard rows.count == 2, rows[1].count == 2 else { return }
        // Body row, second cell holds the sentinel.
        #expect(rows[1][1].contains("\u{E000}0\u{E001}"))
        #expect(!rows[1][1].contains("tabmail://"))
    }

    @Test("AttributedString markdown preserves sentinel chars (PUA invariant)")
    func attributedStringPreservesSentinels() throws {
        // The whole sentinel scheme depends on AttributedString(markdown:) treating
        // PUA chars as inert. If Apple ever started normalizing them away, the
        // splice would lose its anchor. Lock the invariant down with a test.
        let raw = "before \u{E000}0\u{E001} after"
        let attr = try #require(try? AttributedString(
            markdown: raw,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ))
        let roundTripped = String(attr.characters)
        #expect(roundTripped.contains("\u{E000}"))
        #expect(roundTripped.contains("\u{E001}"))
        #expect(roundTripped == raw)
    }

    // MARK: - Nested-bracket labels in every block context
    //
    // Real-world labels (Korean/JP banking subjects, IETF tags like `[draft-ietf-…]`)
    // commonly embed `[…]` pairs. The original `[^\]]+` regex stopped at the first
    // inner `]` and silently dropped these pills in every block branch. The scanner
    // now walks backward to find the matching opener; these tests pin that behavior
    // for each branch the line classifier produces.

    @Test("Nested-bracket pill in list item survives pipeline")
    func nestedBracketPillInListItemSurvivesPipeline() {
        let input = "- [📧 [NH농협카드]표준 약관](tabmail://email/433) — open this first"
        let (sentinelText, pills) = MarkdownChatText.extractPills(input)
        #expect(pills.count == 1)
        guard pills.count == 1 else { return }
        #expect(pills[0].label == "📧 [NH농협카드]표준 약관")

        let lines = MarkdownChatText.parseIntoLines(sentinelText)
        #expect(lines.count == 1)
        guard lines.count == 1, lines[0].segments.count == 1 else { return }
        guard case .listItem(_, _, _, let text) = lines[0].segments[0].kind else {
            Issue.record("Expected .listItem segment")
            return
        }
        #expect(text.contains("\u{E000}0\u{E001}"))
        #expect(!text.contains("tabmail://"))
    }

    @Test("Nested-bracket pill in blockquote survives pipeline")
    func nestedBracketPillInBlockquoteSurvivesPipeline() {
        let input = "> Quoted: [📧 [NH농협카드]표준 약관](tabmail://email/77)"
        let (sentinelText, pills) = MarkdownChatText.extractPills(input)
        #expect(pills.count == 1)
        guard pills.count == 1 else { return }
        #expect(pills[0].label == "📧 [NH농협카드]표준 약관")

        let lines = MarkdownChatText.parseIntoLines(sentinelText)
        #expect(lines.count == 1)
        guard lines.count == 1, lines[0].segments.count == 1 else { return }
        guard case .blockquote(let text) = lines[0].segments[0].kind else {
            Issue.record("Expected .blockquote segment")
            return
        }
        #expect(text.contains("\u{E000}0\u{E001}"))
        #expect(!text.contains("tabmail://"))
    }

    @Test("Nested-bracket pill in header survives pipeline")
    func nestedBracketPillInHeaderSurvivesPipeline() {
        let input = "## Topic: [📧 [NH농협카드]표준 약관](tabmail://email/9)"
        let (sentinelText, pills) = MarkdownChatText.extractPills(input)
        #expect(pills.count == 1)
        guard pills.count == 1 else { return }
        #expect(pills[0].label == "📧 [NH농협카드]표준 약관")

        let lines = MarkdownChatText.parseIntoLines(sentinelText)
        #expect(lines.count == 1)
        guard lines.count == 1, lines[0].segments.count == 1 else { return }
        guard case .header(let level, let text) = lines[0].segments[0].kind else {
            Issue.record("Expected .header segment")
            return
        }
        #expect(level == 2)
        #expect(text.contains("\u{E000}0\u{E001}"))
        #expect(!text.contains("tabmail://"))
    }

    @Test("Nested-bracket pill in table cell survives pipeline")
    func nestedBracketPillInTableCellSurvivesPipeline() {
        let input = "| Subject | Link |\n|---|---|\n| Q3 Plan | [📧 [NH농협카드]표준 약관](tabmail://email/8) |"
        let (sentinelText, pills) = MarkdownChatText.extractPills(input)
        #expect(pills.count == 1)
        guard pills.count == 1 else { return }
        #expect(pills[0].label == "📧 [NH농협카드]표준 약관")

        let lines = MarkdownChatText.parseIntoLines(sentinelText)
        #expect(lines.count == 1)
        guard lines.count == 1, lines[0].segments.count == 1 else { return }
        guard case .table(let rows) = lines[0].segments[0].kind else {
            Issue.record("Expected .table segment")
            return
        }
        #expect(rows.count == 2)
        guard rows.count == 2, rows[1].count == 2 else { return }
        #expect(rows[1][1].contains("\u{E000}0\u{E001}"))
        #expect(!rows[1][1].contains("tabmail://"))
    }
}
