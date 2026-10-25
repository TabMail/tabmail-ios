/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import WebKit
@testable import TabMail

/// Where WebKit breaks the lines of links and code in a wrapped email (tabmail-ios#287). The bodies are
/// laid out by a real web view with the CSS of `EmailHTMLWrapper.wrapHTML`, and the tests read the
/// line boxes back: a word that fits on a line is never split, and a token longer than a whole line
/// still never makes the page wider than the view.
@MainActor
@Suite("Email link and code wrapping", .serialized)
struct EmailLinkWrapTests {

    private static let viewWidth: CGFloat = 390

    /// Loads `body` through `wrapHTML` and returns what `script` evaluates to, as a string.
    private func layOut(_ body: String, _ script: String) async throws -> String {
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: Self.viewWidth, height: 800))
        webView.loadHTMLString(EmailHTMLWrapper.wrapHTML(body), baseURL: nil)
        let loaded = await CanaryKit.waitUntil { !webView.isLoading }
        try #require(loaded, "the page never finished loading")
        return await CanaryKit.eval(webView, script)
    }

    /// The words of the text inside `#id` that the layout put on more than one line. A word laid out
    /// with no glyphs at all is reported as `"unlaid:<word>"`, and no words at all as `"no words"`, so
    /// text missing from the layout can never pass as text that is not split.
    private static func splitWords(_ id: String) -> String {
        """
        (function () {
          const el = document.getElementById('\(id)');
          const walker = document.createTreeWalker(el, NodeFilter.SHOW_TEXT);
          const split = [];
          let words = 0;
          for (let node = walker.nextNode(); node; node = walker.nextNode()) {
            const re = /\\S+/g;
            let m;
            while ((m = re.exec(node.data))) {
              words++;
              const range = document.createRange();
              range.setStart(node, m.index);
              range.setEnd(node, m.index + m[0].length);
              // A range starting at a wrap point can carry an empty rect at the end of the line
              // before it; only rects with width hold the word's glyphs.
              const rects = Array.from(range.getClientRects()).filter(r => r.width > 0.5);
              if (rects.length === 0) { split.push('unlaid:' + m[0]); continue; }
              const tops = new Set(rects.map(r => Math.round(r.top)));
              if (tops.size > 1) split.push(m[0]);
            }
          }
          return words === 0 ? 'no words' : JSON.stringify(split);
        })()
        """
    }

    /// How far the page reaches past the view's width, and how far the text of `#id` reaches past
    /// the element's container (0 when inside). The text's own line boxes are measured, not the
    /// element's box, because a block such as `pre` keeps its box inside while its text overflows.
    /// A long token must also wrap: text missing from the layout reports `"no text"`, and text left
    /// on one line `"one line"`.
    private static func overflow(_ id: String) -> String {
        """
        (function () {
          const el = document.getElementById('\(id)');
          const box = el.parentElement.getBoundingClientRect();
          const range = document.createRange();
          range.selectNodeContents(el);
          const rects = Array.from(range.getClientRects()).filter(r => r.width > 0.5);
          if (rects.length === 0) return 'no text';
          if (new Set(rects.map(r => Math.round(r.top))).size < 2) return 'one line';
          const page = Math.max(document.documentElement.scrollWidth, document.body.scrollWidth) - window.innerWidth;
          const own = Math.max(...rects.map(r => r.right)) - box.right;
          return JSON.stringify([Math.max(0, Math.round(page)), Math.max(0, Math.round(own))]);
        })()
        """
    }

    private static let headline = "B.C. Election Day Live: The latest news, results and reaction"
    private static let longURL = "https://www.example.com/" + String(repeating: "abcdefghij", count: 30)

    @Test("a link's words that fit on a line are never split across lines",
          arguments: [120, 160, 200, 260])
    func linkWordsStayWhole(width: Int) async throws {
        let body = #"<div style="width:\#(width)px;font-size:18px"><a id="t" href="https://www.example.com/a">\#(Self.headline)</a></div>"#
        let split = try await layOut(body, Self.splitWords("t"))
        #expect(split == "[]")
    }

    @Test("code's words that fit on a line are never split across lines",
          arguments: ["<p id=\"t\" style=\"width:150px\">Run <code>make release target</code> after the merge finishes</p>",
                      "<div style=\"width:150px\"><pre id=\"t\">install the package then restart the service</pre></div>"])
    func codeWordsStayWhole(body: String) async throws {
        let split = try await layOut(body, Self.splitWords("t"))
        #expect(split == "[]")
    }

    @Test("a link longer than a whole line still wraps inside its box and never widens the page",
          arguments: [#"<div style="width:200px"><a id="u" href="https://www.example.com/a">URL</a></div>"#,
                      #"<p><a id="u" href="https://www.example.com/a">URL</a></p>"#,
                      #"<table><tr><td><a id="u" href="https://www.example.com/a">URL</a></td></tr></table>"#,
                      #"<table><tr><td>Read</td><td><a id="u" href="https://www.example.com/a">URL</a></td></tr></table>"#])
    func longLinkStaysInside(shape: String) async throws {
        let body = shape.replacingOccurrences(of: ">URL<", with: ">\(Self.longURL)<")
        let overflow = try await layOut(body, Self.overflow("u"))
        #expect(overflow == "[0,0]")
    }

    @Test("code longer than a whole line never widens the page",
          arguments: [#"<p><code id="u">URL</code></p>"#,
                      #"<table><tr><td><code id="u">URL</code></td></tr></table>"#,
                      #"<div style="width:200px"><pre id="u">URL</pre></div>"#,
                      #"<table><tr><td><pre id="u">URL</pre></td></tr></table>"#])
    func longCodeStaysInside(shape: String) async throws {
        let body = shape.replacingOccurrences(of: ">URL<", with: ">\(Self.longURL)<")
        let overflow = try await layOut(body, Self.overflow("u"))
        #expect(overflow == "[0,0]")
    }
}
