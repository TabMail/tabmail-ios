//
//  QuotedFallbackTrailingRunTests.swift
//  TabMailTests
//
//  The bare ">" quote fallback in collapseQuotesJS must only fire on a run of
//  ">" lines that is TRAILING. Invariant pinned here: a ">" run followed by
//  substantial non-quoted content (a digest that embeds an excerpt, a
//  bottom-posted reply) is embedded content and is never a collapse boundary.
//
//  Regression: a Reddit daily digest whose second post quoted a notice with
//  three ">" lines collapsed every following post and the footer behind
//  "Show quoted text" on both iOS and the Thunderbird addon. Mirrors the TB
//  tests in test/quoteAndSignature.test.js ("quoted fallback requires a
//  TRAILING \">\" run").
//

import Testing
import Foundation
import JavaScriptCore
import WebKit
import UIKit
@testable import TabMail

@Suite("Bare \">\" quote fallback — trailing run (shared JS helper)")
struct QuotedFallbackBoundaryHelperTests {

    /// Evaluates the SHARED production source in a fresh JSContext.
    private func boundary(_ lines: [String], hasBlockquote: Bool = false) -> Int32 {
        boundary(lines,
                 minRun: QuotedFallbackConfig.minConsecutiveLines,
                 maxTrailing: QuotedFallbackConfig.maxTrailingLines,
                 minAnswerLen: QuotedFallbackConfig.inlineAnswerMinLineLength,
                 hasBlockquote: hasBlockquote)
    }

    private func boundary(_ lines: [String], minRun: Int, maxTrailing: Int, minAnswerLen: Int, hasBlockquote: Bool) -> Int32 {
        let ctx = JSContext()!
        ctx.evaluateScript(quotedFallbackBoundaryJS)
        let fn = ctx.objectForKeyedSubscript("findQuotedFallbackBoundary")!
        return fn.call(withArguments: [lines, minRun, maxTrailing, minAnswerLen, hasBlockquote])?.toInt32() ?? -99
    }

    private func digestTail(_ n: Int) -> [String] {
        (1...n).flatMap { ["Post \($0) title", "\($0) upvotes", "\($0) comments"] }
    }

    @Test("does NOT collapse a digest that embeds a \">\" excerpt followed by more content")
    func digestEmbeddedExcerptIsNotABoundary() {
        let lines = [
            "r/example",
            "Some notice about a data breach",
            "> Dear Customer,",
            ">",
            "> We are writing to inform you of a recent data s...",
            "Read More",
        ] + digestTail(12) + ["Unsubscribe from daily digest messages."]
        #expect(boundary(lines) == -1)
    }

    @Test("does NOT collapse a bottom-posted reply (quote first, answer below)")
    func bottomPostedReplyIsNotABoundary() {
        let lines = ["> Can we meet on Tuesday?", "> Let me know what works.", ""]
            + (1...12).map { "Answer paragraph \($0)." }
        #expect(boundary(lines) == -1)
    }

    @Test("still collapses a trailing quote followed by a short sign-off and undelimited signature")
    func trailingQuoteWithSignOffStillCollapses() {
        let lines = [
            "Sure, sounds good.",
            "",
            "> Can we meet on Tuesday?",
            "> Let me know what works.",
            "",
            "Thanks,",
            "Name",
            "Title, Company",
            "+1 555 0100",
        ]
        #expect(boundary(lines) == 2)
    }

    @Test("ignores a long tail that sits under a non-quoted \"-- \" signature delimiter")
    func delimitedSignatureTailIsIgnored() {
        let lines = ["> Quoted one", "> Quoted two", "-- "] + (1...12).map { "Signature line \($0)" }
        #expect(boundary(lines) == 0)
    }

    @Test("still rejects a lone \">>\" newsletter link (min-run guard retained)")
    func loneNewsletterLinkIsNotABoundary() {
        let lines = ["Story summary", "", ">> Read the full story", "", "Next story"]
        #expect(boundary(lines) == -1)
    }

    @Test("threshold is exact: maxTrailingLines non-quoted lines collapse, one more does not")
    func thresholdIsExact() {
        let max = QuotedFallbackConfig.maxTrailingLines
        let atMax = ["> One", "> Two"] + (1...max).map { "Tail \($0)" }
        let overMax = ["> One", "> Two"] + (1...(max + 1)).map { "Tail \($0)" }
        #expect(boundary(atMax) == 0)
        #expect(boundary(overMax) == -1)
    }

    @Test("blank tail lines are not counted")
    func blankTailLinesNotCounted() {
        let max = QuotedFallbackConfig.maxTrailingLines
        let tail = (1...max).flatMap { ["Tail \($0)", "", "   "] }
        #expect(boundary(["> One", "> Two"] + tail) == 0)
    }

    @Test("an interleaved (inline) reply never gets a boundary at a LATER run, however long the answers")
    func inlineReplyNeverMovesToALaterRun() {
        // Invariant: the trailing-run rule never moves an inline reply's boundary
        // to a later run (which would hide the answers in between). With a
        // blockquote present the first run is the boundary and the blockquote
        // based trailing-quote logic decides; with none the message stays visible.
        let lines = ["Hi,", "> Question one?", "> More of question one."]
            + (1...12).map { "Answer one line \($0)" }
            + ["> Question two?", "> More of question two."]
            + (1...4).map { "Answer two line \($0)" }
        #expect(boundary(lines, hasBlockquote: true) == 1)
        #expect(boundary(lines, hasBlockquote: false) == -1)
    }

    @Test("accepts an indented \">\" run")
    func indentedRunAccepted() {
        #expect(boundary(["Reply.", "", "  > Quoted one", "  > Quoted two"]) == 2)
    }

    @Test("a digest embedding TWO excerpts (no blockquote) is never a boundary; with a blockquote the first run is")
    func embeddedRunFollowedByLaterRun() {
        let lines = ["Intro.", "> One", "> Two"] + (1...20).map { "Tail \($0)" } + ["> Trailing one", "> Trailing two"]
        #expect(boundary(lines, hasBlockquote: false) == -1)
        #expect(boundary(lines, hasBlockquote: true) == 1)
    }

    @Test("an INDENTED embedded run with a long tail is not a boundary")
    func indentedEmbeddedRunWithLongTail() {
        #expect(boundary(["Intro.", "  > Quoted one", "  > Quoted two"] + (1...20).map { "Tail \($0)" }) == -1)
    }

    @Test("a \"-- \" delimiter after a long answer does not rescue a bottom-posted reply")
    func delimiterAfterLongAnswerDoesNotRescue() {
        #expect(boundary(["> One", "> Two"] + (1...12).map { "Answer line \($0)" } + ["-- ", "Name", "Title"]) == -1)
    }

    @Test("\">\" runs separated only by blank lines are ONE trailing quote, with or without a blockquote")
    func blankSeparatedRunsAreOneQuote() {
        // TB parity: the inline-answer cycle needs an answer-like line between
        // the runs; a blank gap is just paragraph spacing inside the quote.
        let lines = ["Thanks!", "", "> Para one a", "> Para one b", "", "> Para two a", "> Para two b"]
        #expect(boundary(lines, hasBlockquote: false) == 2)
        #expect(boundary(lines, hasBlockquote: true) == 2)
    }

    @Test("a 1-character gap between \">\" runs is not an answer either")
    func oneCharGapIsNotAnAnswer() {
        let lines = ["Thanks!", "> Para one", "> Para one b", "x", "> Para two", "> Para two b"]
        #expect(boundary(lines, hasBlockquote: false) == 1)
    }

    @Test("a 2-character line between \">\" runs IS an answer (threshold is exact)")
    func twoCharGapIsAnAnswer() {
        let lines = ["Thanks!", "> Q1", "> Q1b", "ok", "> Q2", "> Q2b"]
        #expect(boundary(lines, hasBlockquote: false) == -1)
        #expect(boundary(lines, hasBlockquote: true) == 1)
    }

    @Test("an answer between ANY two later \">\" runs makes it an inline reply, not just after the first run")
    func inlineCycleAfterABlankSeparatedRun() {
        // Invariant (TB detectInlineAnswersInPlainText): quoted -> answer -> quoted
        // anywhere after the boundary means the answers are interleaved; with no
        // blockquote to isolate a trailing section the message stays visible.
        let lines = ["Thanks!", "> a", "> b", "", "> c", "> d", "My answer here.", "> e", "> f"]
        #expect(boundary(lines, hasBlockquote: false) == -1)
        #expect(boundary(lines, hasBlockquote: true) == 1)
    }

    @Test("blank-separated runs followed by a long non-quoted tail still collapse (any later run accepts, as in TB)")
    func blankSeparatedRunsThenLongTailStillCollapse() {
        let lines = ["Thanks!", "> a", "> b", "", "> c", "> d"] + (1...20).map { "Tail \($0)" }
        #expect(boundary(lines, hasBlockquote: false) == 1)
    }

    @Test("every threshold is LIVE: non-default minRun / maxTrailing / minAnswerLen change the result")
    func thresholdsAreLive() {
        // minRun 3 rejects a 2-line run that the default accepts.
        #expect(boundary(["Sure.", "> a", "> b"], minRun: 3, maxTrailing: 10, minAnswerLen: 2, hasBlockquote: false) == -1)
        #expect(boundary(["Sure.", "> a", "> b"], minRun: 2, maxTrailing: 10, minAnswerLen: 2, hasBlockquote: false) == 1)
        // maxTrailing 1 rejects a 2-line tail that the default accepts.
        #expect(boundary(["> a", "> b", "Thanks,", "Name"], minRun: 2, maxTrailing: 1, minAnswerLen: 2, hasBlockquote: false) == -1)
        // minAnswerLen 1 turns a 1-char gap into an answer (inline cycle -> -1).
        #expect(boundary(["Hi", "> a", "> b", "x", "> c", "> d"], minRun: 2, maxTrailing: 10, minAnswerLen: 1, hasBlockquote: false) == -1)
        #expect(boundary(["Hi", "> a", "> b", "x", "> c", "> d"], minRun: 2, maxTrailing: 10, minAnswerLen: 2, hasBlockquote: false) == 1)
    }

    @Test("processes many short \">\" runs separated by blank lines in bounded time")
    func manyShortRunsAreBounded() {
        var lines = ["Reply."]
        for _ in 0..<16000 { lines += ["> a", "> b", ""] }
        let start = Date()
        let withBQ = boundary(lines, hasBlockquote: true)
        let withoutBQ = boundary(lines, hasBlockquote: false)
        let elapsed = Date().timeIntervalSince(start)
        #expect(withBQ == 1)
        #expect(withoutBQ == 1)
        #expect(elapsed < 4.0)
    }

    @Test("a REJECTED long run is walked once: 32k \">\" lines plus a long tail stay bounded")
    func rejectedLongRunIsWalkedOnce() {
        // Pins the resume-after-the-run skip: without it every line of the run
        // re-walks to the tail (quadratic; ~10 s measured).
        let lines = ["Reply."] + (1...32000).map { "> quoted line \($0)" } + (1...11).map { "Tail \($0)" }
        let start = Date()
        let result = boundary(lines, hasBlockquote: false)
        let elapsed = Date().timeIntervalSince(start)
        #expect(result == -1)
        #expect(elapsed < 2.0)
    }

    @Test("processes a long \">\" body in bounded time (each run walked once)")
    func longBodyIsBounded() {
        let lines = ["Reply."] + (1...32000).map { "> quoted line \($0)" }
        let start = Date()
        let result = boundary(lines, hasBlockquote: true)
        let elapsed = Date().timeIntervalSince(start)
        #expect(result == 1)
        #expect(elapsed < 2.0)
    }

    @Test("config mirrors the Thunderbird addon values")
    func configMirrorsTB() {
        #expect(QuotedFallbackConfig.minConsecutiveLines == 2)
        #expect(QuotedFallbackConfig.maxTrailingLines == 10)
        #expect(QuotedFallbackConfig.inlineAnswerMinLineLength == 2)
    }
}

/// End-to-end through the production `collapseQuotesJS` in a hosted WKWebView:
/// the digest shape must produce NO quote wrapper, and the control (a trailing
/// quote) must still produce one — two-sided so an inert script cannot pass.
@MainActor
@Suite("Bare \">\" quote fallback — hosted WKWebView", .serialized, .processGlobalState)
struct QuotedFallbackHostedTests {

    private func wrapperCount(html: String, tag: String) async -> String {
        let headerId = "quoted-fallback-\(tag)-\(CanaryKit.nonce())"
        guard let host = await HostedRenderView(html: html, headerId: headerId) else {
            #expect(Bool(false), "could not host AutoSizingHTMLView"); return "host-failed"
        }
        defer { host.tearDown() }
        try? await Task.sleep(for: .seconds(4))
        return await CanaryKit.eval(host.webView, "String(document.querySelectorAll('.tm-quote-wrapper').length)")
    }

    @Test("a digest embedding a \">\" excerpt keeps every later post visible (no wrapper)")
    func digestIsNotCollapsed() async {
        var posts = ""
        for n in 1...12 {
            posts += "<tr><td>Post \(n) title</td></tr><tr><td>\(n) upvotes • \(n) comments</td></tr>\n"
        }
        let html = """
        <table><tbody>
        <tr><td><strong>r/example</strong></td></tr>
        <tr><td>Some notice about a data breach</td></tr>
        <tr><td><a href="https://example.com/post">
        &gt; Dear Customer,
        &gt;
        &gt; We are writing to inform you of a recent data s...
        <span>Read More</span></a></td></tr>
        \(posts)
        <tr><td>Unsubscribe from daily digest messages.</td></tr>
        </tbody></table>
        """
        #expect(await wrapperCount(html: html, tag: "digest") == "0")
    }

    @Test("a digest embedding TWO \">\" excerpts keeps every later post visible (no wrapper)")
    func twoExcerptDigestIsNotCollapsed() async {
        var posts = ""
        for n in 1...6 {
            posts += "<tr><td>Post \(n) title</td></tr><tr><td>\(n) upvotes • \(n) comments</td></tr>\n"
        }
        let html = """
        <table><tbody>
        <tr><td><strong>r/example</strong></td></tr>
        <tr><td><a href="https://example.com/a">
        &gt; Dear Customer,
        &gt;
        &gt; We are writing to inform you of a recent data s...
        <span>Read More</span></a></td></tr>
        \(posts)
        <tr><td><a href="https://example.com/b">
        &gt; Another quoted notice
        &gt; from a later post
        <span>Read More</span></a></td></tr>
        \(posts)
        <tr><td>Unsubscribe from daily digest messages.</td></tr>
        </tbody></table>
        """
        #expect(await wrapperCount(html: html, tag: "digest2") == "0")
    }

    @Test("control: a trailing \">\" quote still collapses (one wrapper)")
    func trailingQuoteStillCollapses() async {
        let html = """
        <div>Sure, sounds good.</div>
        <div>&gt; Can we meet on Tuesday?<br>&gt; Let me know what works.</div>
        <div>Thanks,<br>Name</div>
        """
        #expect(await wrapperCount(html: html, tag: "control") == "1")
    }
}
