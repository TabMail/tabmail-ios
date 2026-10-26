/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import UIKit
import WebKit
@testable import TabMail

/// A forwarded ticket or receipt table wider than the column sat inside a collapsed quote, where
/// the page fit never measures it, and once expanded the quote box clipped its right side. Like
/// Apple Mail, the expanded quote scales the over-wide block down to the quote's width, and leaves
/// alone overflow the sender already contains or transforms. Most bodies render through the
/// production view and scripts (`HostedRenderView`); the geometry rules of `tmFitQuoteContent`
/// itself run on a bare page with the same `fitQuoteContentJS` source.
@MainActor
@Suite("An expanded quote fits a table wider than the column", .serialized, .processGlobalState)
struct EmailQuoteFitTests {

    private nonisolated static let attribution = "<div>On Monday, Placeholder Sender &lt;sender@example.com&gt; wrote:</div>"

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

    /// A one-cell table that cannot wrap, with `#wide` as its id.
    private nonisolated static let wideTable = """
        <table id="wide"><tr><td style="white-space:nowrap">Placeholder receipt row with enough words to exceed a phone column several times without wrapping</td></tr><tr><td>Placeholder second row</td></tr></table>
        """

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

    /// `#wide`'s painted width, its layout width, and the quote content box's right edge.
    private struct Edges: Decodable {
        let right: Double
        let edge: Double
        let paint: Double
        let layout: Double
    }

    private func edges(_ webView: WKWebView) async throws -> Edges {
        let json = await CanaryKit.eval(webView, """
            (function () {
                var c = document.querySelector('.tm-quote-content'), s = getComputedStyle(c), r = c.getBoundingClientRect();
                var t = document.getElementById('wide'), tr = t.getBoundingClientRect();
                return JSON.stringify({
                    right: tr.right, edge: r.right - parseFloat(s.paddingRight) - parseFloat(s.borderRightWidth),
                    paint: tr.width, layout: t.offsetWidth
                });
            })()
            """)
        return try JSONDecoder().decode(Edges.self, from: Data(json.utf8))
    }

    /// Polls until `#wide` ends at the quote's right edge, then checks it does.
    private func expectFits(_ webView: WKWebView, _ what: String) async throws {
        var e = try await edges(webView)
        for _ in 0..<40 where e.right > e.edge + 1 || e.right < e.edge - 2 {
            try await Task.sleep(for: .milliseconds(25))
            e = try await edges(webView)
        }
        #expect(e.right <= e.edge + 1 && e.right >= e.edge - 2, "\(what): table ends at \(e.right), quote content at \(e.edge)")
    }

    private func toggle(_ webView: WKWebView) async throws {
        let click = await CanaryKit.eval(webView, "document.querySelector('.tm-quote-toggle').click(); 'clicked'",
                                         in: RenderContentWorld.isolated)
        try #require(click == "clicked", "quote toggle click failed: \(click)")
    }

    private func hosted(_ html: String = Self.body) async throws -> HostedRenderView {
        let hosted = try #require(await HostedRenderView(html: html, headerId: nil))
        var ready = false
        for _ in 0..<400 where !ready {
            ready = await CanaryKit.eval(hosted.webView, """
                String(!!document.querySelector('.tm-quote-toggle') && getComputedStyle(document.documentElement).opacity === '1')
                """) == "true"
            if !ready { try await Task.sleep(for: .milliseconds(25)) }
        }
        if !ready { hosted.tearDown() }
        try #require(ready, "the page was never revealed with a collapsed quote")
        return hosted
    }

    /// Runs `action` (a JS expression returning a JSON string) after loading `body` on a bare
    /// page that defines `tmFitQuoteContent`. `#c` is a 300px column.
    private func bare(_ body: String, _ action: String) async throws -> [String: Double] {
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 800))
        webView.loadHTMLString("""
            <meta name="viewport" content="width=device-width,initial-scale=1">
            <style>body{margin:0;font:16px sans-serif} #c{width:300px}</style>
            """ + body, baseURL: nil)
        try #require(await CanaryKit.waitUntil { !webView.isLoading })
        let json = await CanaryKit.eval(webView, fitQuoteContentJS + ";" + action)
        return try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Double], "bad result: \(json)")
    }

    @Test("Expanding the quote scales the wide table to the quote's width and leaves its text alone")
    func expandedQuoteFitsTheWideTable() async throws {
        let hosted = try await hosted()
        defer { hosted.tearDown() }
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
        defer { hosted.tearDown() }
        try await toggle(hosted.webView)
        let first = try await fit(hosted.webView)
        // The replay is only worth comparing against a first run that fitted.
        try #require(first.tableRight <= first.contentRight + 1 && first.tableRight >= first.contentRight - 2,
                     "first fit: table ends at \(first.tableRight), quote content at \(first.contentRight)")
        try await toggle(hosted.webView)
        try await toggle(hosted.webView)
        let second = try await fit(hosted.webView)
        #expect(!second.collapsed)
        #expect(abs(second.tableRight - first.tableRight) < 0.5)
        #expect(abs(second.tableLeft - first.tableLeft) < 0.5)
    }

    @Test("An image load inside the expanded quote refits a table it widened without changing the quote's height")
    func imageLoadRefits() async throws {
        let hosted = try await hosted("<p>Placeholder reply</p>" + Self.attribution + "<blockquote>" + Self.wideTable
                                      + "<img id=\"pic\" width=\"1\" height=\"1\"></blockquote>")
        defer { hosted.tearDown() }
        try await toggle(hosted.webView)
        try await expectFits(hosted.webView, "before the load")
        // Stand-in for an image that arrives and widens its table: the nowrap cell doubles,
        // which widens the table without changing the observed quote box, then the image
        // fires its load event. Dispatch is synchronous, so the edges are read in the same
        // turn: a later refit (the resize observer, the page's own timers) cannot stand in.
        let json = await CanaryKit.eval(hosted.webView, """
            (function () {
                var c = document.querySelector('.tm-quote-content'), t = document.getElementById('wide'), cell = t.querySelector('td');
                var before = t.offsetWidth, h1 = c.getBoundingClientRect().height;
                cell.textContent = cell.textContent + ' ' + cell.textContent;
                var after = t.offsetWidth, h2 = c.getBoundingClientRect().height;
                document.getElementById('pic').dispatchEvent(new Event('load'));
                var s = getComputedStyle(c), r = c.getBoundingClientRect();
                return JSON.stringify({ before: before, after: after, h1: h1, h2: h2, right: t.getBoundingClientRect().right,
                                        edge: r.right - parseFloat(s.paddingRight) - parseFloat(s.borderRightWidth) });
            })()
            """)
        let d = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Double], "bad result: \(json)")
        let before = try #require(d["before"]), after = try #require(d["after"])
        let h1 = try #require(d["h1"]), h2 = try #require(d["h2"])
        let right = try #require(d["right"]), edge = try #require(d["edge"])
        #expect(after > before + 50, "the table must widen: \(before) to \(after)")
        #expect(abs(h2 - h1) < 0.5, "the quote box must keep its height, so only the load event can refit")
        #expect(right <= edge + 1 && right >= edge - 2, "after the load: table ends at \(right), quote content at \(edge)")
    }

    @Test("The expanded quote refits when its column narrows")
    func narrowingRefits() async throws {
        let hosted = try await hosted("<p>Placeholder reply</p>" + Self.attribution + "<blockquote>" + Self.wideTable + "</blockquote>")
        defer { hosted.tearDown() }
        try await toggle(hosted.webView)
        try await expectFits(hosted.webView, "expanded")
        let narrowed = await CanaryKit.eval(hosted.webView,
            "document.querySelector('.tm-quote-content').style.setProperty('width', '220px', 'important'); 'narrowed'")
        try #require(narrowed == "narrowed")
        let e = try await edges(hosted.webView)
        try #require(e.edge < 260, "the quote content must have narrowed, edge \(e.edge)")
        try await expectFits(hosted.webView, "narrowed")
    }

    @Test("A wide table in the quote after an inline answer fits when expanded")
    func trailingQuoteAfterAnInlineAnswerFits() async throws {
        let hosted = try await hosted("<p>Placeholder reply</p>" + Self.attribution
            + "<blockquote id=\"earlier\">Placeholder earlier quotation</blockquote><p id=\"answer\">Placeholder interleaved answer</p>"
            + "<blockquote id=\"trailing\">" + Self.wideTable + "</blockquote>")
        defer { hosted.tearDown() }
        let shape = await CanaryKit.eval(hosted.webView, """
            (function () {
                var c = document.querySelector('.tm-quote-content');
                return String(c.contains(document.getElementById('trailing')) && !c.contains(document.getElementById('answer')));
            })()
            """)
        try #require(shape == "true", "the inline-reply layout must keep the answer outside the collapsed quote")
        try await toggle(hosted.webView)
        try await expectFits(hosted.webView, "expanded")
    }

    @Test("A table inside the sender's own horizontal scroller keeps its full size")
    func containedOverflowKeepsItsSize() async throws {
        let hosted = try await hosted("<p>Placeholder reply</p>" + Self.attribution
            + "<blockquote><div id=\"scroller\" style=\"overflow-x:auto\">" + Self.wideTable + "</div></blockquote>")
        defer { hosted.tearDown() }
        try await toggle(hosted.webView)
        try await Task.sleep(for: .milliseconds(150))
        let e = try await edges(hosted.webView)
        let room = await CanaryKit.eval(hosted.webView, "String(document.getElementById('scroller').clientWidth)")
        let scroller = try #require(Double(room))
        #expect(e.layout > scroller + 50, "the fixture needs real overflow inside the scroller")
        #expect(abs(e.paint - e.layout) < 1, "the table pans in its scroller at full size: painted \(e.paint), laid out \(e.layout)")
    }

    @Test("Overflow inside an ancestor with overflow-x of auto, scroll, hidden or clip is left alone",
          arguments: ["auto", "scroll", "hidden", "clip"])
    func containedOverflowIsLeftAlone(_ overflow: String) async throws {
        let d = try await bare("""
            <div id="c"><div style="overflow-x:\(overflow)"><table id="t" style="width:600px;height:120px"><tr><td>Placeholder</td></tr></table></div></div>
            """, """
            JSON.stringify((function () {
                var c = document.getElementById('c'), t = document.getElementById('t');
                return { picks: tmFitQuoteContent(c), paint: t.getBoundingClientRect().width, layout: t.offsetWidth };
            })())
            """)
        #expect(d["picks"] == 0)
        #expect(abs((d["paint"] ?? 0) - (d["layout"] ?? -1)) < 0.5, "overflow-x:\(overflow): \(d)")
    }

    @Test("The sender's own transform on a wide block survives expanding and refitting")
    func authoredTransformSurvives() async throws {
        let transformed = Self.wideTable.replacingOccurrences(of: "id=\"wide\"", with: "id=\"wide\" style=\"transform:scale(0.8);transform-origin:0 0\"")
        let hosted = try await hosted("<p>Placeholder reply</p>" + Self.attribution + "<blockquote>" + transformed + "</blockquote>")
        defer { hosted.tearDown() }
        try await toggle(hosted.webView)
        try await Task.sleep(for: .milliseconds(150))
        let e = try await edges(hosted.webView)
        #expect(e.layout * 0.8 > e.edge + 50, "the fixture needs the transformed table to overflow")
        #expect(abs(e.paint - e.layout * 0.8) < 1, "the sender's scale(0.8) still sets the width: painted \(e.paint), laid out \(e.layout)")
        let widened = await CanaryKit.eval(hosted.webView, """
            (function () {
                var c = document.querySelector('.tm-quote-content');
                c.style.setProperty('max-width', 'none', 'important');
                c.style.setProperty('width', '900px', 'important');
                return 'widened';
            })()
            """)
        try #require(widened == "widened")
        try await Task.sleep(for: .milliseconds(150))
        let wide = try await edges(hosted.webView)
        #expect(abs(wide.paint - wide.layout * 0.8) < 1, "after a refit with room: painted \(wide.paint), laid out \(wide.layout)")
        let inline = await CanaryKit.eval(hosted.webView, "document.getElementById('wide').style.getPropertyValue('transform')")
        #expect(inline == "scale(0.8)")
    }

    @Test("A wide block under an ancestor the sender transformed is left alone")
    func overflowUnderAnAuthoredTransformIsLeftAlone() async throws {
        let d = try await bare("""
            <div id="c"><div style="transform:scale(0.9);transform-origin:0 0"><table id="t" style="width:600px;height:120px"><tr><td>Placeholder</td></tr></table></div></div>
            """, """
            JSON.stringify((function () {
                var c = document.getElementById('c'), t = document.getElementById('t');
                return { picks: tmFitQuoteContent(c), paint: t.getBoundingClientRect().width, layout: t.offsetWidth };
            })())
            """)
        #expect(d["picks"] == 0)
        #expect(abs((d["paint"] ?? 0) - (d["layout"] ?? 0) * 0.9) < 0.5, "\(d)")
    }

    @Test("A scaled table's text is scaled once, with the table")
    func textInsideTheScaledTableScalesOnce() async throws {
        let d = try await bare("""
            <div id="c"><table id="t" style="width:600px;height:120px"><tr><td><div style="width:600px"><span id="text">Placeholder quoted text</span></div></td></tr></table></div>
            """, """
            JSON.stringify((function () {
                var c = document.getElementById('c'), t = document.getElementById('t'), range = document.createRange();
                range.selectNodeContents(document.getElementById('text'));
                var before = range.getBoundingClientRect().height;
                tmFitQuoteContent(c);
                return { before: before, after: range.getBoundingClientRect().height, scale: t.getBoundingClientRect().width / t.offsetWidth };
            })())
            """)
        let before = try #require(d["before"]), after = try #require(d["after"]), scale = try #require(d["scale"])
        #expect(before > 10 && scale > 0 && scale < 1, "\(d)")
        #expect(abs(after - before * scale) < 0.5, "text height \(after), expected \(before * scale)")
    }

    @Test("The sender's bottom margin returns once the block fits without scaling")
    func authoredMarginReturns() async throws {
        let d = try await bare("""
            <div id="c"><table id="t" style="width:600px;height:120px;margin-bottom:13px!important"><tr><td>Placeholder</td></tr></table><div id="after">Placeholder after</div></div>
            """, """
            JSON.stringify((function () {
                var c = document.getElementById('c'), t = document.getElementById('t'), a = document.getElementById('after');
                var before = a.getBoundingClientRect().top - t.getBoundingClientRect().bottom;
                var picks = tmFitQuoteContent(c);
                c.style.width = '1000px';
                tmFitQuoteContent(c);
                return { picks: picks, before: before, after: a.getBoundingClientRect().top - t.getBoundingClientRect().bottom,
                         priority: t.style.getPropertyPriority('margin-bottom') === 'important' ? 1 : 0 };
            })())
            """)
        #expect(d["picks"] == 1)
        #expect(abs((d["before"] ?? 0) - 13) < 0.5, "\(d)")
        #expect(abs((d["after"] ?? 0) - 13) < 0.5, "\(d)")
        #expect(d["priority"] == 1)
    }

    @Test("A wide inline-block inside an inline wrapper is the block that is scaled")
    func inlineBlockInAnInlineWrapperFits() async throws {
        let d = try await bare("""
            <div id="c"><span><span id="t" style="display:inline-block;width:600px;height:120px">Placeholder quoted text</span></span></div>
            """, """
            JSON.stringify((function () {
                var c = document.getElementById('c'), t = document.getElementById('t');
                var before = t.getBoundingClientRect().right;
                tmFitQuoteContent(c);
                return { before: before, right: t.getBoundingClientRect().right, edge: c.getBoundingClientRect().right };
            })())
            """)
        let before = try #require(d["before"]), right = try #require(d["right"]), edge = try #require(d["edge"])
        #expect(before > edge + 50)
        #expect(right <= edge + 1 && right >= edge - 2, "inline-block ends at \(right), column at \(edge)")
    }
}
