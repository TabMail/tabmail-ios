//
//  JapaneseOutlookReplyHeaderTests.swift
//  TabMailTests
//
//  A reply quoted below a Japanese Outlook header block (差出人 / 送信 / 宛先 /
//  件名) must be detected as quoted text, with or without a dash separator
//  line, with an ASCII or full-width colon. Mirrors the TB tests in
//  test/quoteAndSignature.test.js ("Japanese Outlook reply header").
//

import Testing
import Foundation
import WebKit
import UIKit
@testable import TabMail

private enum JapaneseHeaderFixture {
    static let reply = "Thanks, that works for us.\n\nBest,\n Alex"

    static func sentLine(colon: String) -> String {
        let d = Calendar(identifier: .gregorian).date(byAdding: .day, value: -3, to: Date()) ?? Date()
        let c = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: d)
        return "\u{9001}\u{4FE1}\(colon)\(c.year ?? 0) \u{5E74} \(c.month ?? 0) \u{6708} \(c.day ?? 0) \u{65E5} 9:30"
    }

    /// 差出人 / 送信 / 宛先 / Cc / 件名 header block followed by the earlier message.
    static func block(colon: String) -> [String] {
        [
            "\u{5DEE}\u{51FA}\u{4EBA}\(colon)Sender Name <sender@example.com>",
            sentLine(colon: colon),
            "\u{5B9B}\u{5148}\(colon)Recipient One <one@example.com>; Recipient Two <two@example.com>",
            "Cc: Recipient Three <three@example.com>",
            "\u{4EF6}\u{540D}\(colon)Re: Example subject",
            "",
            "Hi Alex,",
            "Earlier message body.",
        ]
    }

    static let fromLabel = "\u{5DEE}\u{51FA}\u{4EBA}"
}

@Suite("Japanese Outlook reply header — splitMessageAndQuotes")
struct JapaneseOutlookReplyHeaderSplitTests {

    @Test("ASCII colon: the quote starts at 差出人", arguments: [": ", ":"])
    func asciiColon(colon: String) {
        let body = JapaneseHeaderFixture.reply + "\n\n" + JapaneseHeaderFixture.block(colon: colon).joined(separator: "\n")
        let (message, quotes) = EmailFilter.splitMessageAndQuotes(body)
        #expect(message.trimmingCharacters(in: .whitespacesAndNewlines) == JapaneseHeaderFixture.reply)
        #expect(quotes.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(JapaneseHeaderFixture.fromLabel))
    }

    @Test("full-width colon with surrounding spaces: the quote starts at 差出人", arguments: ["\u{FF1A}", " \u{FF1A} "])
    func fullWidthColon(colon: String) {
        let body = JapaneseHeaderFixture.reply + "\n\n" + JapaneseHeaderFixture.block(colon: colon).joined(separator: "\n")
        let (message, quotes) = EmailFilter.splitMessageAndQuotes(body)
        #expect(message.trimmingCharacters(in: .whitespacesAndNewlines) == JapaneseHeaderFixture.reply)
        #expect(quotes.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(JapaneseHeaderFixture.fromLabel))
    }

    @Test("a lone 件名 line in the body is not a boundary")
    func loneSubjectLineIsNotABoundary() {
        let body = "Please use this subject line.\n\u{4EF6}\u{540D}: Example subject\nThanks."
        #expect(EmailFilter.splitMessageAndQuotes(body).quotes.isEmpty)
    }
}

/// End-to-end through the production `collapseQuotesJS` in a hosted WKWebView.
@MainActor
@Suite("Japanese Outlook reply header — hosted WKWebView", .serialized, .processGlobalState)
struct JapaneseOutlookReplyHeaderHostedTests {

    /// Returns "<wrapper count>|<wrapper text starts with 差出人 or dash line>|<reply visible outside wrapper>".
    private func probe(html: String, tag: String) async -> String {
        let headerId = "ja-outlook-\(tag)-\(CanaryKit.nonce())"
        guard let host = await HostedRenderView(html: html, headerId: headerId) else {
            #expect(Bool(false), "could not host AutoSizingHTMLView"); return "host-failed"
        }
        defer { host.tearDown() }
        try? await Task.sleep(for: .seconds(4))
        return await CanaryKit.eval(host.webView, """
        (function(){
          var ws = document.querySelectorAll('.tm-quote-wrapper');
          var inside = ws.length ? ws[0].textContent : '';
          var replyInside = inside.indexOf('Thanks, that works for us.') >= 0;
          var fromInside = inside.indexOf('\\u5DEE\\u51FA\\u4EBA') >= 0;
          return ws.length + '|' + fromInside + '|' + replyInside;
        })()
        """)
    }

    private func html(colon: String, dashLine: Bool) -> String {
        var rows = JapaneseHeaderFixture.block(colon: colon).map { line in
            line.replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        }
        if dashLine { rows.insert(String(repeating: "-", count: 72), at: 0) }
        return """
        <div>Thanks, that works for us.</div>
        <div><br></div>
        <div>Best,<br> Alex</div>
        <div><br></div>
        <div>\(rows.joined(separator: "<br>\n"))</div>
        """
    }

    @Test("no dash line, ASCII colon: the block is collapsed, the reply stays visible")
    func standaloneAsciiColon() async {
        #expect(await probe(html: html(colon: ": ", dashLine: false), tag: "ascii") == "1|true|false")
    }

    @Test("no dash line, full-width colon: the block is collapsed, the reply stays visible")
    func standaloneFullWidthColon() async {
        #expect(await probe(html: html(colon: " \u{FF1A} ", dashLine: false), tag: "fullwidth") == "1|true|false")
    }

    @Test("dash line before the Japanese block: the block is collapsed, the reply stays visible")
    func dashSeparated() async {
        #expect(await probe(html: html(colon: "\u{FF1A}", dashLine: true), tag: "dash") == "1|true|false")
    }

    @Test("control: a lone 件名 line is not collapsed")
    func loneSubjectLineIsNotCollapsed() async {
        let html = "<div>Please use this subject line.</div><div>\u{4EF6}\u{540D}: Example subject</div><div>Thanks.</div>"
        #expect(await probe(html: html, tag: "lone").hasPrefix("0|"))
    }
}
