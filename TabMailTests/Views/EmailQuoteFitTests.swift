/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import UIKit
import WebKit
@testable import TabMail

/// A forwarded ticket or receipt table wider than the column sat inside a collapsed quote, where
/// the page fit never measures it, and once expanded the quote box clipped its right side. Like
/// Apple Mail, the expanded quote scales the over-wide block down to the quote's width. The bodies
/// render through the production view and scripts (`HostedRenderView`).
@MainActor
@Suite("An expanded quote fits a table wider than the column", .serialized, .processGlobalState)
struct EmailQuoteFitTests {

    /// A table that cannot wrap below about 600px, forwarded under a short reply.
    private nonisolated static let body = #"""
        <p id="reply">Placeholder reply line.</p>
        <div>On Monday, Placeholder Sender &lt;sender@example.com&gt; wrote:</div>
        <blockquote type="cite"><p id="qtext">Placeholder quoted line.</p>
        <table id="wide"><tr><td><span id="row" style="white-space:nowrap">Placeholder ticket row, a line laid out in one piece that is far wider than a phone</span><img id="pic" width="1" height="1" src="data:image/gif;base64,R0lGODlhAQABAAAAACw="></td></tr>
        <tr><td>Placeholder row two</td></tr><tr><td>Placeholder row three</td></tr><tr><td>Placeholder row four</td></tr>
        <tr><td>Placeholder row five</td></tr><tr><td>Placeholder row six</td></tr></table>
        <p id="after">Placeholder line after the table.</p>
        </blockquote>
        """#

    private struct Fit: Decodable {
        let collapsed: Bool
        /// The quote content box's right edge, and the table's left and right edges.
        let contentRight: Double
        let tableLeft: Double
        let tableRight: Double
        /// Line heights of the quoted paragraph and the top-level reply: equal while only the
        /// over-wide block is scaled.
        let quotedLine: Double
        let replyLine: Double
        /// Space between the table's painted bottom and the next paragraph, and that
        /// paragraph's top margin: equal when the scaled table leaves no blank space.
        let gapBelow: Double
        let afterMargin: Double
    }

    private func fit(_ webView: WKWebView) async throws -> Fit {
        let json = await CanaryKit.eval(webView, """
            (function () {
                var c = document.querySelector('.tm-quote-content'), s = getComputedStyle(c), r = c.getBoundingClientRect();
                var t = document.getElementById('wide').getBoundingClientRect();
                return JSON.stringify({
                    collapsed: document.querySelector('.tm-quote-wrapper').classList.contains('tm-collapsed'),
                    contentRight: r.right - parseFloat(s.paddingRight) - parseFloat(s.borderRightWidth),
                    tableLeft: t.left, tableRight: t.right,
                    quotedLine: document.getElementById('qtext').getBoundingClientRect().height,
                    replyLine: document.getElementById('reply').getBoundingClientRect().height,
                    gapBelow: document.getElementById('after').getBoundingClientRect().top - t.bottom,
                    afterMargin: parseFloat(getComputedStyle(document.getElementById('after')).marginTop)
                });
            })()
            """)
        return try JSONDecoder().decode(Fit.self, from: Data(json.utf8))
    }

    private func toggle(_ webView: WKWebView) async throws {
        let click = await CanaryKit.eval(webView, "document.querySelector('.tm-quote-toggle').click(); 'clicked'",
                                         in: RenderContentWorld.isolated)
        try #require(click == "clicked", "quote toggle click failed: \(click)")
    }

    private func hosted() async throws -> HostedRenderView {
        let hosted = try #require(await HostedRenderView(html: Self.body, headerId: nil))
        var ready = false
        for _ in 0..<400 where !ready {
            ready = await CanaryKit.eval(hosted.webView, """
                String(!!document.querySelector('.tm-quote-toggle') && getComputedStyle(document.documentElement).opacity === '1')
                """) == "true"
            if !ready { try await Task.sleep(for: .milliseconds(25)) }
        }
        try #require(ready, "the page was never revealed with a collapsed quote")
        return hosted
    }

    @Test("Expanding the quote scales the wide table to the quote's width and leaves its text alone")
    func expandedQuoteFitsTheWideTable() async throws {
        let hosted = try await hosted()
        try await toggle(hosted.webView)
        let f = try await fit(hosted.webView)
        #expect(!f.collapsed)
        #expect(f.tableRight <= f.contentRight + 1, "table ends at \(f.tableRight), quote content at \(f.contentRight)")
        // Scaled just enough: it still spans the quote, not a thumbnail of it.
        #expect(f.tableRight >= f.contentRight - 2, "table ends at \(f.tableRight), quote content at \(f.contentRight)")
        #expect(abs(f.quotedLine - f.replyLine) < 1, "quoted text line \(f.quotedLine) vs reply line \(f.replyLine)")
        #expect(abs(f.gapBelow - f.afterMargin) < 2, "gap below the table \(f.gapBelow), paragraph margin \(f.afterMargin)")
    }

    @Test("Collapsing and expanding again gives the same fit")
    func refitIsIdempotent() async throws {
        let hosted = try await hosted()
        try await toggle(hosted.webView)
        let first = try await fit(hosted.webView)
        try await toggle(hosted.webView)
        try await toggle(hosted.webView)
        let second = try await fit(hosted.webView)
        #expect(!second.collapsed)
        #expect(abs(second.tableRight - first.tableRight) < 0.5)
        #expect(abs(second.tableLeft - first.tableLeft) < 0.5)
    }

    @Test("An image loading inside the expanded quote refits content it widened")
    func imageLoadRefits() async throws {
        let hosted = try await hosted()
        try await toggle(hosted.webView)
        // Stand-in for an image that arrives and widens its table: the row doubles, then the
        // image fires its load event.
        let grown = await CanaryKit.eval(hosted.webView, """
            (function () {
                var row = document.getElementById('row');
                row.textContent = row.textContent + ' ' + row.textContent;
                document.getElementById('pic').dispatchEvent(new Event('load'));
                return 'grown';
            })()
            """)
        try #require(grown == "grown")
        var f = try await fit(hosted.webView)
        for _ in 0..<40 where f.tableRight > f.contentRight + 1 {
            try await Task.sleep(for: .milliseconds(25))
            f = try await fit(hosted.webView)
        }
        #expect(f.tableRight <= f.contentRight + 1, "table ends at \(f.tableRight), quote content at \(f.contentRight)")
        #expect(f.tableRight >= f.contentRight - 2, "table ends at \(f.tableRight), quote content at \(f.contentRight)")
    }
}
