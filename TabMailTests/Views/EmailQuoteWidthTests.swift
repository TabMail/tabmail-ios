/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import WebKit
@testable import TabMail

/// #286: a quote level costs only its left border and padding. Every level keeps
/// the right edge of the text column, so a deep reply stays readable.
@Suite("Quoted text keeps the column's width (#286)", .serialized)
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
}
