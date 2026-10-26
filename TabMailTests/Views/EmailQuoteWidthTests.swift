/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import WebKit
@testable import TabMail

/// #286: a quote level costs only its left border and padding. Every level keeps
/// the right edge of the text column, so a deep reply stays readable.
@Suite("Quoted text keeps the column's width (#286, #327)", .serialized, .processGlobalState)
@MainActor
struct EmailQuoteWidthTests {
    /// The page width of a small iPhone; the bug costs 55px a level, so five levels
    /// already left less than one letter.
    private static let viewportWidth: CGFloat = 320
    private static let depth = 6

    @Test("Each nested quote keeps the right edge and loses only its left border and padding")
    func nestedQuotesKeepTheirWidth() async throws {
        var html = "Innermost reply text"
        for level in (1...Self.depth).reversed() {
            html = "<blockquote>Level \(level)<br>\(html)</blockquote>"
        }
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: Self.viewportWidth, height: 800))
        webView.loadHTMLString(EmailHTMLWrapper.wrapHTML("<p>Top</p>" + html), baseURL: nil)
        let loaded = await CanaryKit.waitUntil { !webView.isLoading }
        #expect(loaded)

        let json = await CanaryKit.eval(webView, """
            JSON.stringify(Array.from(document.querySelectorAll('blockquote')).map(function (q) {
                var r = q.getBoundingClientRect(), s = getComputedStyle(q);
                return [r.left, r.right, parseFloat(s.borderLeftWidth) + parseFloat(s.paddingLeft)];
            }).concat([[document.querySelector('p').getBoundingClientRect().left,
                        document.querySelector('p').getBoundingClientRect().right, 0]]))
            """)
        let rows = try JSONDecoder().decode([[Double]].self, from: Data(json.utf8))
        #expect(rows.count == Self.depth + 1)
        guard rows.count == Self.depth + 1, let column = rows.last else { return }
        let quotes = rows.dropLast()
        var expectedLeft = column[0]
        for (index, quote) in quotes.enumerated() {
            #expect(abs(quote[0] - expectedLeft) < 1, "level \(index + 1) starts where its parent's content starts")
            #expect(abs(quote[1] - column[1]) < 1, "level \(index + 1) ends at the column's right edge")
            expectedLeft += quote[2]
        }
    }

    // MARK: - #327: deep threads keep a usable width, levels are coloured bars

    /// The narrowest supported page (iPhone SE class) and a thread deeper than any indent cap.
    private static let deepDepth = 20

    private func render(_ body: String) async -> WKWebView {
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: Self.viewportWidth, height: 800))
        webView.loadHTMLString(EmailHTMLWrapper.wrapHTML(body), baseURL: nil)
        let loaded = await CanaryKit.waitUntil { !webView.isLoading }
        #expect(loaded)
        return webView
    }

    /// `[left, right, borderLeftWidth, borderLeftColor]` of every blockquote, outermost first,
    /// then the column (`p#top`) and the innermost text (`p#inner`) as `[left, right]`.
    private struct Geometry: Decodable {
        let quotes: [Quote]
        let column: [Double]
        let inner: [Double]
        struct Quote: Decodable { let left: Double; let border: Double; let color: String; let marginLeft: Double }
    }

    private func geometry(_ webView: WKWebView) async throws -> Geometry {
        let json = await CanaryKit.eval(webView, """
            (function () {
                function lr(e) { var r = e.getBoundingClientRect(); return [r.left, r.right]; }
                return JSON.stringify({
                    quotes: Array.from(document.querySelectorAll('blockquote')).map(function (q) {
                        var s = getComputedStyle(q);
                        return { left: q.getBoundingClientRect().left, border: parseFloat(s.borderLeftWidth),
                                 color: s.borderLeftColor, marginLeft: parseFloat(s.marginLeft) };
                    }),
                    column: lr(document.getElementById('top')),
                    inner: lr(document.getElementById('inner'))
                });
            })()
            """)
        return try JSONDecoder().decode(Geometry.self, from: Data(json.utf8))
    }

    private static func nested(_ depth: Int, open: String = "<blockquote>") -> String {
        var html = "<p id=\"inner\">Innermost reply text</p>"
        for level in (1...depth).reversed() {
            html = "\(open)Level \(level)<br>\(html)</blockquote>"
        }
        return "<p id=\"top\">Top</p>" + html
    }

    private static func rgb(_ hex: String) -> String {
        let value = Int(hex.dropFirst(), radix: 16) ?? 0
        return "rgb(\((value >> 16) & 0xff), \((value >> 8) & 0xff), \(value & 0xff))"
    }

    @Test("At 20 levels on the narrowest page the innermost text keeps all but the capped indent")
    func deepThreadKeepsAUsableWidth() async throws {
        let webView = await render(Self.nested(Self.deepDepth))
        let g = try await geometry(webView)
        let cap = Double(QuoteLevelConfig.maxIndentedDepth * (QuoteLevelConfig.barWidth + QuoteLevelConfig.barGap))
        let columnWidth = g.column[1] - g.column[0]
        let innerWidth = g.inner[1] - g.inner[0]
        #expect(innerWidth >= columnWidth - cap - 1, "innermost width \(innerWidth) of a \(columnWidth)px column")
        // The cap leaves a readable line, not merely a nonzero one.
        #expect(innerWidth >= columnWidth / 2, "innermost width \(innerWidth) of a \(columnWidth)px column")
    }

    @Test("Each drawn level is a thin bar in the next colour; deeper levels draw none")
    func levelsCycleColoursUpToTheCap() async throws {
        // Hosted in a window (the production view and scripts): a window-less web view never
        // takes dark appearance.
        for (style, colors) in [(UIUserInterfaceStyle.light, QuoteLevelConfig.barColors),
                                (.dark, QuoteLevelConfig.darkBarColors)] {
            let hosted = try #require(await HostedRenderView(html: Self.nested(QuoteLevelConfig.maxIndentedDepth + 2),
                                                             headerId: nil, userInterfaceStyle: style))
            var ready = false
            for _ in 0..<400 where !ready {
                ready = await CanaryKit.eval(hosted.webView, """
                    String(!!document.getElementById('inner') && getComputedStyle(document.documentElement).opacity === '1')
                    """) == "true"
                if !ready { try await Task.sleep(for: .milliseconds(25)) }
            }
            try #require(ready, "the page was never revealed")
            let g = try await geometry(hosted.webView)
            #expect(g.quotes.count == QuoteLevelConfig.maxIndentedDepth + 2)
            for (index, quote) in g.quotes.enumerated() {
                let level = index + 1
                if level <= QuoteLevelConfig.maxIndentedDepth {
                    #expect(quote.border == Double(QuoteLevelConfig.barWidth), "\(style.rawValue) level \(level) bar width")
                    #expect(quote.color == Self.rgb(colors[index % colors.count]), "\(style.rawValue) level \(level) colour \(quote.color)")
                } else {
                    #expect(quote.border == 0, "\(style.rawValue) level \(level) draws no bar")
                }
            }
        }
    }

    @Test("Gmail's inline quote style is replaced by the bounded bar; its Indent button blockquote is left alone")
    func gmailQuotesAreBoundedButItsIndentIsNot() async throws {
        let gmail = #"<blockquote class="gmail_quote" style="margin:0px 0px 0px 0.8ex;border-left:1px solid rgb(204,204,204);padding-left:1ex">"#
        var webView = await render(Self.nested(Self.deepDepth, open: gmail))
        var g = try await geometry(webView)
        let cap = Double(QuoteLevelConfig.maxIndentedDepth * (QuoteLevelConfig.barWidth + QuoteLevelConfig.barGap))
        #expect(g.inner[1] - g.inner[0] >= g.column[1] - g.column[0] - cap - 1)
        guard let first = g.quotes.first else { return }
        #expect(first.border == Double(QuoteLevelConfig.barWidth))
        #expect(first.color == Self.rgb(QuoteLevelConfig.barColors[0]))

        webView = await render(Self.nested(1, open: #"<blockquote style="margin:0 0 0 40px;border:none;padding:0px">"#))
        g = try await geometry(webView)
        guard let indent = g.quotes.first else { return }
        #expect(indent.border == 0, "an indented paragraph gets no quote bar")
        #expect(indent.marginLeft == 40, "an indented paragraph keeps the sender's indent")
    }

    @Test("Quotes inside a Gmail Indent paragraph count their levels from the first real quote")
    func gmailIndentDoesNotUseUpAQuoteLevel() async throws {
        let depth = QuoteLevelConfig.maxIndentedDepth
        let quotes = Self.nested(depth).replacingOccurrences(of: "<p id=\"top\">Top</p>", with: "")
        let webView = await render("<p id=\"top\">Top</p>"
            + #"<blockquote style="margin:0 0 0 40px;border:none;padding:0px">Indented paragraph<br>"# + quotes + "</blockquote>")
        let g = try await geometry(webView)
        #expect(g.quotes.count == depth + 1)
        guard g.quotes.count == depth + 1 else { return }
        #expect(g.quotes[0].border == 0 && g.quotes[0].marginLeft == 40, "the indent keeps its style and no bar")
        for level in 1...depth {
            let quote = g.quotes[level]
            #expect(quote.border == Double(QuoteLevelConfig.barWidth), "quote level \(level) keeps its bar")
            #expect(quote.color == Self.rgb(QuoteLevelConfig.barColors[(level - 1) % QuoteLevelConfig.barColors.count]),
                    "quote level \(level) colour \(quote.color)")
        }
    }
}
