/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import SwiftUI
import Testing
import UIKit
import WebKit
@testable import TabMail

/// #307: a newsletter draws a rule behind a centred date (a heading's border pulled up through
/// its text by a tiny line-height, with a white fill on the text hiding the rule under it). In
/// dark mode the rule must stay hidden behind the text, as in light mode, and it must span its
/// column. The bodies render through the production view and scripts (`HostedRenderView`), and
/// the tests read the pixels of the rule's row.
@MainActor
@Suite("A rule an email hides behind text stays hidden in dark mode (#307)", .serialized, .processGlobalState)
struct EmailRuleBehindTextTests {

    private nonisolated static let heading = #"""
        <h2 id="rule" style="font-size:16px;text-align:center;padding-top:25px;border-bottom:1px solid #cecccc;line-height:0.1em"><span id="mask" style="background:#ffffff;padding:0 10px;color:#555555">Placeholder Date Line</span></h2>
        """#
    /// The same look drawn with a top border, the text lifted onto it by relative positioning.
    private nonisolated static let topRule = #"""
        <div id="rule" style="font-size:16px;text-align:center;margin-top:30px;border-top:1px solid #cecccc"><span id="mask" style="position:relative;top:-0.6em;background:#ffffff;padding:0 10px;color:#555555">Placeholder Date Line</span></div>
        """#
    private nonisolated static let paragraph = "<p style=\"background:#ffffff\">" + String(repeating: "Placeholder paragraph text for the page. ", count: 12) + "</p>"
    /// A fill that ends exactly on the rule's outer edge, and one that starts exactly on it:
    /// either still covers the whole stroke.
    private nonisolated static let edgeBottom = #"""
        <div id="rule" style="box-sizing:border-box;height:21px;border-bottom:1px solid #cecccc"><span id="mask" style="display:block;width:180px;height:21px;margin:0 auto;background:#ffffff;color:#555555">Placeholder label</span></div><p>Placeholder closing line.</p>
        """#
    private nonisolated static let edgeTop = #"""
        <div id="rule" style="margin-top:30px;height:20px;border-top:1px solid #cecccc"><span id="mask" style="display:block;width:180px;height:21px;margin:-1px auto 0;background:#ffffff;color:#555555">Placeholder label</span></div><p>Placeholder closing line.</p>
        """#
    /// A thick rule the fill covers only part of, at the bottom and at the top: the covered part
    /// stays hidden. The email wrapper sizes every div border-box, so each 30px box is 18px of
    /// content and a 12px stroke.
    private nonisolated static let partBottom = #"""
        <div id="rule" style="height:30px;border-bottom:12px solid #cecccc"><span id="mask" style="display:block;width:180px;height:22px;margin:0 auto;background:#ffffff;color:#555555">Placeholder label</span></div><p>Placeholder closing line.</p>
        """#
    private nonisolated static let partTop = #"""
        <div id="rule" style="margin-top:30px;height:30px;border-top:12px solid #cecccc"><span id="mask" style="display:block;width:180px;height:22px;margin:-6px auto 0;background:#ffffff;color:#555555">Placeholder label</span></div><p>Placeholder closing line.</p>
        """#
    /// A fill inside a nearer ruled box whose rule it does not touch, hanging over an outer box's
    /// rule: the outer rule is still the one it hides. `fill` is the fill's CSS, the shorthand or
    /// the longhand alone.
    private nonisolated static func outerRule(fill: String) -> String {
        #"<div id="rule" style="height:30px;border-bottom:1px solid #cecccc"><div style="border-top:1px solid #cecccc;padding-top:2px"><span id="mask" style="display:block;width:180px;height:30px;margin:0 auto;"#
            + fill + #";color:#555555">Placeholder label</span></div></div><p>Placeholder closing line.</p>"#
    }

    /// The heading on a white page (the dark-mode script's page-colour regime) and on no page
    /// colour at all (the span is the only light fill), with the rule as a bottom or a top border.
    nonisolated static let maskShapes = [
        "<div style=\"background:#ffffff\">" + paragraph + heading + paragraph + "</div>",
        heading,
        "<div style=\"background:#ffffff\">" + paragraph + topRule + paragraph + "</div>",
        // Text after the rule gives the page height below it; it has no fill of its own.
        topRule + "<p>Placeholder closing line.</p>",
        edgeBottom,
        edgeTop,
        partBottom,
        partTop,
        outerRule(fill: "background:#ffffff"),
        outerRule(fill: "background-color:#ffffff"),
        // A rule in the heading's own text colour: the heading's text is transparent, so the
        // rule shows only once the dark-mode pass gives the text a colour.
        #"<h2 id="rule" style="font-size:16px;text-align:center;padding-top:25px;color:transparent;border-bottom:1px solid currentColor;line-height:0.1em"><span id="mask" style="background:#ffffff;padding:0 10px;color:#555555">Placeholder Date Line</span></h2>"#,
        // A rule painted by a border image over a transparent border colour.
        #"<h2 id="rule" style="font-size:16px;text-align:center;padding-top:25px;border-bottom:1px solid transparent;border-image-source:linear-gradient(#cecccc,#cecccc);border-image-slice:1;line-height:0.1em"><span id="mask" style="background:#ffffff;padding:0 10px;color:#555555">Placeholder Date Line</span></h2>"#,
    ]

    /// The heading on a panel the dark-mode pass leaves coloured, under a translucent wrapper: an
    /// opaque panel, and a translucent one over the card. The mask must take the colour they make.
    /// The panel sits inside a plain section: the email wrapper clears the fill of a top-level block.
    nonisolated static let panelShapes = [
        "background:#204030",
        "background:rgba(20,60,40,0.5)",
    ].map { panel in
        "<div><div id=\"panel\" style=\"\(panel);padding:30px 0\"><div style=\"background:rgba(80,40,20,0.25)\">" + heading + "</div></div></div>"
    }

    /// The heading inside a fixed-width table wider than the phone, the newsletter's layout.
    private static let tableShape = #"""
        <table style="width:100%;background:#ffffff"><tr><td>
        <table align="center" style="background:#ffffff" cellpadding="0" cellspacing="0">
        <tr><td><div align="center"><img id="column" width="468" style="display:block;width:468px;max-width:100%;height:40px;background:#2f5c49"></div></td></tr>
        <tr><td><table id="dates" align="center" style="width:468px"><tr><td id="cell" colspan="2">
        <h2 id="rule" style="font-size:16px;width:100%;text-align:center;padding-top:25px;border-bottom:1px solid #cecccc;line-height:0.1em"><span id="mask" style="background:#ffffff;padding:0 10px;color:#555555">Placeholder Date Line</span></h2>
        </td></tr></table></td></tr>
        </table></td></tr></table>
        """#

    private struct Box: Decodable { let left, top, right, bottom: Double }
    private struct Layout: Decodable {
        let rule, mask: Box
        let column, table, cell, container: Box?
        let maskFill, panelFill: String
        let viewport, scrollWidth: Double
    }

    /// Renders `body` in `style` through the production view, once the element `ready` exists. With
    /// no `backdrop` the view takes its own default, as the message card and attachment preview do.
    private func load(_ body: String, _ style: UIUserInterfaceStyle, ready: String = "rule",
                      backdrop: Color? = nil) async throws -> HostedRenderView {
        let hosted = try #require(await HostedRenderView(html: body, headerId: nil, userInterfaceStyle: style, backdrop: backdrop))
        // The initial about:blank is also "loaded" and fully opaque, so wait for the body itself.
        var revealed = false
        for _ in 0..<400 where !revealed {
            revealed = await CanaryKit.eval(hosted.webView, """
                String(!!document.getElementById('\(ready)') && getComputedStyle(document.documentElement).opacity === '1')
                """, in: RenderContentWorld.isolated) == "true"
            if !revealed { try await Task.sleep(for: .milliseconds(25)) }
        }
        try #require(revealed, "the page was never revealed")
        return hosted
    }

    /// The boxes of the fixtures' named elements in CSS pixels; a missing element is null.
    private static let geometryJS = """
        (function () {
          function box(id, content) {
            const el = document.getElementById(id);
            if (!el) return null;
            const r = el.getBoundingClientRect();
            const s = getComputedStyle(el);
            const inset = content ? [parseFloat(s.paddingLeft), parseFloat(s.paddingRight)] : [0, 0];
            return { left: r.left + inset[0], top: r.top, right: r.right - inset[1], bottom: r.bottom };
          }
          const empty = { left: 0, top: 0, right: 0, bottom: 0 };
          const mask = document.getElementById('mask'), panel = document.getElementById('panel');
          // With no #rule, the rule is the body's own top border.
          const page = document.body.getBoundingClientRect();
          const body = { left: page.left, top: page.top, right: page.right,
                         bottom: page.top + parseFloat(getComputedStyle(document.body).borderTopWidth) };
          return JSON.stringify({ rule: box('rule') || body, mask: box('mask') || empty, column: box('column'),
                                  table: box('dates'), cell: box('cell', true),
                                  container: box('container', true),
                                  maskFill: mask ? getComputedStyle(mask).backgroundColor : '',
                                  panelFill: panel ? getComputedStyle(panel).backgroundColor : '',
                                  viewport: window.innerWidth, scrollWidth: document.documentElement.scrollWidth });
        })()
        """

    /// Renders `body` in `style` and returns its layout in CSS pixels, with the hosted view.
    private func render(_ body: String, _ style: UIUserInterfaceStyle, ready: String = "rule",
                        backdrop: Color? = nil) async throws -> (HostedRenderView, Layout) {
        let hosted = try await load(body, style, ready: ready, backdrop: backdrop)
        let webView = hosted.webView
        let json = await CanaryKit.eval(webView, Self.geometryJS, in: RenderContentWorld.isolated)
        let layout = try JSONDecoder().decode(Layout.self, from: Data(json.utf8))
        // The view grows to the measured height after load; the snapshot needs the rule inside it.
        let tall = await CanaryKit.waitUntil {
            hosted.window.layoutIfNeeded()
            return webView.bounds.height >= (layout.rule.bottom + 5) * webView.bounds.width / layout.viewport
        }
        try #require(tall, "the view never grew to the rule")
        // Read the layout again at the view's final size: the snapshot is taken at that size, and
        // a 1px rule sampled from the first layout can miss the line.
        let settled = await CanaryKit.eval(webView, Self.geometryJS, in: RenderContentWorld.isolated)
        return (hosted, try JSONDecoder().decode(Layout.self, from: Data(settled.utf8)))
    }

    /// One snapshot of the page, read in CSS points, over what the view sits on: the page is
    /// transparent in dark mode and the snapshot keeps that transparency.
    private struct Snapshot {
        let image: CGImage
        let scale: Double
        let backdrop: (r: CGFloat, g: CGFloat, b: CGFloat)

        /// The premultiplied RGBA of the snapshot pixel at CSS point (`x`, `y`).
        func raw(x: Double, y: Double) throws -> [UInt8] {
            let px = Int(x * scale), py = Int(y * scale)
            try #require(px >= 0 && py >= 0 && px < image.width && py < image.height, "sample point outside the snapshot")
            var rgba = [UInt8](repeating: 0, count: 4)
            let context = try #require(CGContext(data: &rgba, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                                 space: CGColorSpaceCreateDeviceRGB(),
                                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: -px, y: py - image.height + 1, width: image.width, height: image.height))
            return rgba
        }

        /// The colour at CSS point (`x`, `y`) as seen over the backdrop.
        func color(x: Double, y: Double) throws -> (r: Int, g: Int, b: Int) {
            let rgba = try raw(x: x, y: y)
            let uncovered = Double(255 - Int(rgba[3])) / 255
            func over(_ premultiplied: UInt8, _ backdrop: CGFloat) -> Int { Int(premultiplied) + Int((backdrop * 255 * uncovered).rounded()) }
            return (over(rgba[0], backdrop.r), over(rgba[1], backdrop.g), over(rgba[2], backdrop.b))
        }
    }

    /// A snapshot once the page is painted at the point (`x`, `y`). Right after the view grows,
    /// WebKit can hand back a blank snapshot, which reads as the backdrop everywhere and would let
    /// a "hidden" check pass on nothing; every fixture draws its rule beside the text, so the
    /// callers name that point. `backdrop` is what the view sits on: the message card's colour
    /// unless a test hosts it on another.
    private func paintedSnapshot(_ webView: WKWebView, _ layout: Layout, x: Double, y: Double,
                                 over backdrop: Color = Theme.cardBackground) async throws -> Snapshot {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        UIColor(backdrop).resolvedColor(with: webView.traitCollection).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        var snapshot: Snapshot?
        for _ in 0..<40 {
            let cg = try #require(try await webView.takeSnapshot(configuration: nil).cgImage)
            let taken = Snapshot(image: cg, scale: webView.bounds.width / layout.viewport * Double(cg.width) / webView.bounds.width,
                                 backdrop: (red, green, blue))
            snapshot = taken
            if try taken.raw(x: x, y: y)[3] > 0 { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        return try #require(snapshot)
    }

    @Test("the rule stays hidden behind the text in dark mode, and still shows beside it",
          arguments: maskShapes)
    func ruleHiddenBehindText(body: String) async throws {
        let (hosted, layout) = try await render(body, .dark)
        defer { hosted.tearDown() }
        // The outermost row of the rule the text's fill covers (all of a thin rule, part of a thick
        // one), read from the rule's own tag: a nearer box may draw a rule of the other kind.
        let ruleTag = body.range(of: #"id="rule""#).map { body[$0.lowerBound...].prefix { $0 != ">" } } ?? ""
        let row = ruleTag.contains("border-top") ? max(layout.rule.top, layout.mask.top) + 0.5
            : min(layout.rule.bottom, layout.mask.bottom) - 0.5
        // Premise: the rule is drawn where the text is not.
        let besideX = (layout.rule.left + layout.mask.left) / 2
        let snapshot = try await paintedSnapshot(hosted.webView, layout, x: besideX, y: row)
        let beside = try snapshot.color(x: besideX, y: row)
        #expect(beside.r > 150 && beside.g > 150 && beside.b > 150, "the rule beside the text: \(beside)")
        // Inside the text's padding the rule is hidden: the pixel is the dark backdrop, not the rule.
        let behind = try snapshot.color(x: layout.mask.left + 4, y: row)
        #expect(behind.r < 80 && behind.g < 80 && behind.b < 80, "the rule behind the text: \(behind)")
    }

    /// A rule the email draws on the page's own body, with a label placed over it: the label
    /// hides it in dark mode too. The geometry stands the body's top border in for the missing `#rule`.
    @Test("a rule on the body stays hidden behind the text in dark mode")
    func bodyRuleHiddenBehindText() async throws {
        let body = #"<style>body{border-top:12px solid #cecccc}</style><span id="mask" style="position:absolute;top:0;left:120px;width:150px;height:30px;background:#ffffff;color:#555555">Placeholder label</span><p style="margin-top:40px">Placeholder closing line.</p>"#
        let (hosted, layout) = try await render(body, .dark, ready: "mask")
        defer { hosted.tearDown() }
        let row = max(layout.rule.top, layout.mask.top) + 0.5
        // Premise: the body draws the rule where the text is not.
        let besideX = (layout.rule.left + layout.mask.left) / 2
        let snapshot = try await paintedSnapshot(hosted.webView, layout, x: besideX, y: row)
        let beside = try snapshot.color(x: besideX, y: row)
        #expect(beside.r > 150 && beside.g > 150 && beside.b > 150, "the rule beside the text: \(beside)")
        let behind = try snapshot.color(x: layout.mask.left + 4, y: row)
        #expect(behind.r < 80 && behind.g < 80 && behind.b < 80, "the rule behind the text: \(behind)")
    }

    /// On a panel the dark-mode pass keeps coloured, the text's fill hides the rule in the panel's
    /// colour, so it reads as the panel, not as a patch of the card.
    @Test("the text's fill takes the colour of the panel around it", arguments: panelShapes)
    func maskMatchesItsPanel(body: String) async throws {
        let (hosted, layout) = try await render(body, .dark)
        defer { hosted.tearDown() }
        // Premise: the panel keeps a fill, so the mask has a panel to match.
        #expect(layout.panelFill != "rgba(0, 0, 0, 0)" && !layout.panelFill.isEmpty, "the panel's fill: \(layout.panelFill)")
        let row = layout.rule.bottom - 0.5
        let besideX = (layout.rule.left + layout.mask.left) / 2
        let snapshot = try await paintedSnapshot(hosted.webView, layout, x: besideX, y: row)
        let beside = try snapshot.color(x: besideX, y: row)
        #expect(beside.r > 150 && beside.g > 150 && beside.b > 150, "the rule beside the text: \(beside)")
        let behind = try snapshot.color(x: layout.mask.left + 4, y: row)
        // Above the rule, at the far left of the heading: the panel's fills and nothing else.
        let around = try snapshot.color(x: layout.rule.left + 5, y: row - 5)
        #expect(abs(behind.r - around.r) <= 3 && abs(behind.g - around.g) <= 3 && abs(behind.b - around.b) <= 3,
                "behind the text \(behind), the panel \(around)")
    }

    /// Where the view sits on another colour (the compose quote preview), the text's fill hides the
    /// rule in that colour, not the card's.
    @Test("the text's fill takes the colour the view sits on")
    func maskTakesTheSuppliedBackdrop() async throws {
        let backdrop = Palette.previewPaneBg
        let (hosted, layout) = try await render(Self.heading, .dark, backdrop: backdrop)
        defer { hosted.tearDown() }
        let row = layout.rule.bottom - 0.5
        let besideX = (layout.rule.left + layout.mask.left) / 2
        let snapshot = try await paintedSnapshot(hosted.webView, layout, x: besideX, y: row, over: backdrop)
        let beside = try snapshot.color(x: besideX, y: row)
        #expect(beside.r > 150 && beside.g > 150 && beside.b > 150, "the rule beside the text: \(beside)")
        let behind = try snapshot.color(x: layout.mask.left + 4, y: row)
        let around = try snapshot.color(x: layout.rule.left + 5, y: row - 5)
        #expect(abs(behind.r - around.r) <= 3 && abs(behind.g - around.g) <= 3 && abs(behind.b - around.b) <= 3,
                "behind the text \(behind), around it \(around)")
        // Premise: this backdrop differs from the card's, so a mask in the card's colour would fail.
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        UIColor(Theme.cardBackground).resolvedColor(with: hosted.webView.traitCollection).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        let card = (r: Int((red * 255).rounded()), g: Int((green * 255).rounded()), b: Int((blue * 255).rounded()))
        #expect(abs(around.r - card.r) + abs(around.g - card.g) + abs(around.b - card.b) > 9,
                "around the text \(around), the card \(card)")
    }

    /// Light mode is the email as sent: the text's fill stays white over the rule, and the rule
    /// keeps its colour beside it.
    @Test("in light mode the rule and the text's fill keep the email's own colours",
          arguments: maskShapes.prefix(2))
    func lightModeKeepsTheEmailsColours(body: String) async throws {
        let (hosted, layout) = try await render(body, .light)
        defer { hosted.tearDown() }
        let row = layout.rule.bottom - 0.5
        let besideX = (layout.rule.left + layout.mask.left) / 2
        let snapshot = try await paintedSnapshot(hosted.webView, layout, x: besideX, y: row)
        let beside = try snapshot.color(x: besideX, y: row)
        #expect(abs(beside.r - 0xce) <= 12 && abs(beside.g - 0xcc) <= 12 && abs(beside.b - 0xcc) <= 12, "the rule beside the text: \(beside)")
        let behind = try snapshot.color(x: layout.mask.left + 4, y: row)
        #expect(behind.r >= 250 && behind.g >= 250 && behind.b >= 250, "the text's fill over the rule: \(behind)")
        #expect(layout.maskFill == "rgb(255, 255, 255)", "the text's fill: \(layout.maskFill)")
    }

    /// A light fill that hides no drawn rule is treated exactly as the same fill with no border:
    /// a border in a transparent colour, a fill beside the ruled box (to its right, or to the left
    /// of an inset one) rather than across it, a
    /// fill that ends exactly where the rule begins, and a box across the rule whose fill is
    /// clipped clear of it (to its padding box by its own transparent border, or to its content
    /// box by its padding). Each case's premise is a variant that does cover a drawn rule, which
    /// changes the fill.
    nonisolated static let hidesNothingShapes: [(hides: String, none: String, covers: String)] = {
        func heading(_ border: String) -> String {
            #"<h2 id="rule" style="font-size:16px;text-align:center;padding-top:25px;"# + border
                + #"line-height:0.1em"><span id="mask" style="background:#ffffff;padding:0 10px;color:#555555">Placeholder Date Line</span></h2>"#
        }
        // The fill reaches down across the rule's row but sits beside the ruled box: to its right,
        // or, with the box inset 160px, to its left.
        func beside(_ border: String, left: String, inset: Bool = false) -> String {
            let box = #"<div id="rule" style="position:relative;width:150px;height:20px;"# + border
                + #""><span id="mask" style="position:absolute;top:0;left:"# + left
                + #";width:120px;height:30px;background:#ffffff;color:#555555">Placeholder label</span></div>"#
            return (inset ? #"<section style="padding-left:160px">"# + box + "</section>" : box)
                + #"<p style="margin-top:40px">Placeholder closing line.</p>"#
        }
        // The fill ends on the stroke's inner edge (20px), or one pixel into it (21px): the div is
        // border-box (the email wrapper's rule), so its 21px hold 20px of content above the stroke.
        func above(_ border: String, height: String) -> String {
            #"<div id="rule" style="height:21px;"# + border
                + #""><span id="mask" style="display:block;width:180px;height:"# + height
                + #";margin:0 auto;background:#ffffff;color:#555555">Placeholder label</span></div><p>Placeholder closing line.</p>"#
        }
        // The fill's box reaches the rule (30px of a 30px border-box div); `inset` ends its painted
        // background 4px or 6px short of it unless `clip` is `border-box`.
        func clipped(_ border: String, clip: String, inset: String) -> String {
            #"<div id="rule" style="height:30px;"# + border
                + #""><span id="mask" style="display:block;box-sizing:border-box;width:180px;height:30px;margin:0 auto;"# + inset
                + "background:#ffffff;background-clip:" + clip + #";color:#555555">Placeholder label</span></div><p>Placeholder closing line.</p>"#
        }
        let drawn = "border-bottom:1px solid #cecccc;"
        let bordered = "border-bottom:4px solid transparent;", padded = "padding-bottom:6px;"
        return [
            (heading("border-bottom:1px solid transparent;"), heading(""), heading(drawn)),
            (beside(drawn, left: "200px"), beside("", left: "200px"), beside(drawn, left: "20px")),
            (beside(drawn, left: "-140px", inset: true), beside("", left: "-140px", inset: true),
             beside(drawn, left: "10px", inset: true)),
            (above(drawn, height: "20px"), above("", height: "20px"), above(drawn, height: "21px")),
            (clipped(drawn, clip: "padding-box", inset: bordered), clipped("", clip: "padding-box", inset: bordered),
             clipped(drawn, clip: "border-box", inset: bordered)),
            (clipped(drawn, clip: "content-box", inset: padded), clipped("", clip: "content-box", inset: padded),
             clipped(drawn, clip: "border-box", inset: padded)),
        ]
    }()

    @Test("a light fill that hides no drawn rule is treated as if there were no border",
          arguments: 0..<hidesNothingShapes.count)
    func fillHidingNoRuleIsUnchanged(index: Int) async throws {
        func fill(_ body: String) async throws -> String {
            let (hosted, layout) = try await render(body, .dark)
            defer { hosted.tearDown() }
            return layout.maskFill
        }
        let shape = Self.hidesNothingShapes[index]
        let hides = try await fill(shape.hides)
        let none = try await fill(shape.none)
        let covers = try await fill(shape.covers)
        #expect(hides == none, "hides nothing \(hides), no border \(none)")
        // Premise: a fill covering a drawn rule does change, so the comparison above can fail.
        #expect(covers != none, "covers a rule \(covers), no border \(none)")
    }

    /// A light fill nested in the text's fill, above the rule, hides nothing: it is treated as it
    /// is with no rule at all (transparent inside the fill around it), not darkened as a panel.
    @Test("a light fill inside the text's fill, clear of the rule, is treated as with no rule")
    func nestedFillClearOfTheRuleIsUnchanged() async throws {
        func fills(_ border: String) async throws -> (outer: String, inner: String) {
            let body = #"<div id="rule" style="box-sizing:border-box;height:41px;"# + border
                + #""><div id="mask" style="width:180px;height:41px;margin:0 auto;background:#ffffff;color:#555555"><div id="inner" style="height:20px;background:#ffffff">Placeholder label</div></div></div><p>Placeholder closing line.</p>"#
            let (hosted, layout) = try await render(body, .dark)
            defer { hosted.tearDown() }
            let inner = await CanaryKit.eval(hosted.webView, "getComputedStyle(document.getElementById('inner')).backgroundColor",
                                             in: RenderContentWorld.isolated)
            return (layout.maskFill, inner)
        }
        let ruled = try await fills("border-bottom:1px solid #cecccc")
        let plain = try await fills("")
        #expect(ruled.inner == plain.inner, "inside a mask \(ruled.inner), inside a plain fill \(plain.inner)")
        // Premise: the outer fill is a mask only over the rule, so the two cases differ there.
        #expect(ruled.outer != plain.outer, "mask \(ruled.outer), plain \(plain.outer)")
    }

    /// A table wider than the phone, inset by margins (or centred by auto margins), fits the
    /// column with its margins rather than overflowing by them, in either appearance.
    @Test("an over-wide table fits its column with its margins",
          arguments: [UIUserInterfaceStyle.dark, .light], ["margin-left:24px;margin-right:24px", "margin:0 auto"])
    func overWideTableFitsWithItsMargins(style: UIUserInterfaceStyle, margins: String) async throws {
        let inset: Double = margins.contains("24px") ? 24 : 0
        let body = #"<div id="container"><table id="dates" style="width:600px;"# + margins
            + #""><tr><td>Placeholder cell</td></tr></table></div><p id="rule">Placeholder closing line.</p>"#
        let hosted = try await load(body, style)
        defer { hosted.tearDown() }
        let json = await CanaryKit.eval(hosted.webView, Self.geometryJS, in: RenderContentWorld.isolated)
        let layout = try JSONDecoder().decode(Layout.self, from: Data(json.utf8))
        let table = try #require(layout.table)
        let container = try #require(layout.container)
        #expect(abs(table.left - (container.left + inset)) <= 1 && abs(table.right - (container.right - inset)) <= 1,
                "table \(table.left)...\(table.right), container \(container.left)...\(container.right)")
        #expect(layout.scrollWidth <= layout.viewport + 1, "page \(layout.scrollWidth) wide in \(layout.viewport)")
    }

    /// The mask check runs for every light fill, so it must cost nothing where no ancestor of a
    /// fill draws a rule. A long, deeply nested mail of light paragraphs gets no layout reads
    /// beyond the dark-mode pass's own (at most two per fill: its page-share pre-pass and its
    /// box, and one for the body) and one per ancestor drawing a rule, however many fills sit
    /// under it. With no border anywhere it also reads no border style, colour or image and
    /// looks up no recorded rule; with one unrelated rule at the top, only that rule's border is
    /// read; with a rule under every section, only those rules' borders.
    @Test("the mask check does no work where no fill sits on a rule", arguments: ["none", "unrelated", "sections"])
    func noRuleCostsNoMeasurement(rules: String) async throws {
        let sections = 20, depth = 12, perSection = 10
        let outer = rules == "sections" ? #"<div style="border-bottom:1px solid #cecccc">"# : "<div>"
        let section = outer + String(repeating: "<div>", count: depth - 1)
            + String(repeating: #"<p style="background:#ffffff">Placeholder paragraph.</p>"#, count: perSection)
            + String(repeating: "</div>", count: depth)
        let rule = rules == "unrelated" ? #"<h2 style="border-bottom:1px solid #cecccc">Placeholder heading</h2>"# : ""
        let html = "<!DOCTYPE html><html><head><meta name=\"viewport\" content=\"width=device-width\"></head><body>"
            + rule + String(repeating: section, count: sections) + "</body></html>"
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.overrideUserInterfaceStyle = .dark
        let probe = NavProbe()
        let webView = CanaryKit.probeWebView(WKWebViewConfiguration(), probe)
        let controller = UIViewController()
        controller.view.addSubview(webView)
        window.rootViewController = controller
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        webView.loadHTMLString(html, baseURL: nil)
        try #require(await CanaryKit.waitForFinish(probe), "the page never loaded")
        let counted = await CanaryKit.eval(webView, """
            (function () {
              var reads = 0, borderReads = 0, ruleLookups = 0, measure = Element.prototype.getBoundingClientRect;
              Element.prototype.getBoundingClientRect = function () { reads++; return measure.apply(this, arguments); };
              var borderProps = { borderTopStyle: 1, borderBottomStyle: 1, borderTopColor: 1, borderBottomColor: 1, borderImageSource: 1 };
              var computed = window.getComputedStyle;
              window.getComputedStyle = function (el, pseudo) {
                var cs = computed.call(window, el, pseudo);
                return new Proxy(cs, { get: function (target, prop) {
                  if (borderProps[prop]) borderReads++;
                  var value = target[prop];
                  return typeof value === 'function' ? value.bind(target) : value;
                } });
              };
              Object.defineProperty(Element.prototype, '__tmRuleEdges', { configurable: true,
                get: function () { ruleLookups++; return this.__tmRuleEdgesRecorded; },
                set: function (value) { this.__tmRuleEdgesRecorded = value; } });
              window.__tmCounts = function () { return [reads, borderReads, ruleLookups].join(','); };
              return String(window.matchMedia('(prefers-color-scheme: dark)').matches);
            })()
            """, in: RenderContentWorld.isolated)
        try #require(counted == "true", "the page is not in dark mode: \(counted)")
        let ran = await CanaryKit.eval(webView, _fixDarkModeColorsJS, in: RenderContentWorld.isolated)
        try #require(!ran.hasPrefix("JSERR"), "the dark-mode pass failed: \(ran)")
        let counts = await CanaryKit.eval(webView, "window.__tmCounts()", in: RenderContentWorld.isolated)
            .split(separator: ",").compactMap { Int($0) }
        try #require(counts.count == 3, "counts: \(counts)")
        let (reads, borderReads, ruleLookups) = (counts[0], counts[1], counts[2])
        // Premise: the counters count. One border read and one rule lookup move them by one each.
        let control = await CanaryKit.eval(webView, """
            (function () { getComputedStyle(document.body).borderTopStyle; document.body.__tmRuleEdges; return window.__tmCounts(); })()
            """, in: RenderContentWorld.isolated)
        #expect(control == "\(reads),\(borderReads + 1),\(ruleLookups + 1)", "counters after one read each: \(control)")
        let fills = sections * perSection
        // Premise: the pass ran and treated the fills.
        let treated = await CanaryKit.eval(webView, "String(getComputedStyle(document.querySelector('p')).backgroundColor)", in: RenderContentWorld.isolated)
        #expect(treated != "rgb(255, 255, 255)", "the first fill: \(treated)")
        let ruled = rules == "sections" ? sections : 0
        #expect(reads <= 2 * fills + 1 + ruled, "\(reads) layout reads for \(fills) fills under \(ruled) rules")
        switch rules {
        case "unrelated":
            // The heading's bottom border: its style, image and colour.
            #expect(borderReads <= 3, "\(borderReads) border style, colour or image reads")
        case "sections":
            #expect(borderReads <= 3 * sections, "\(borderReads) border style, colour or image reads")
        default:
            #expect(borderReads == 0, "\(borderReads) border style, colour or image reads")
            #expect(ruleLookups == 0, "\(ruleLookups) recorded-rule lookups")
        }
    }

    /// The email gives the rule's table the column's width; a table narrowed to fit the phone must
    /// keep the column's width rather than shrink to its text, and the rule fills its cell.
    @Test("the rule spans its column, not just the text",
          arguments: [UIUserInterfaceStyle.dark, .light])
    func ruleSpansItsColumn(style: UIUserInterfaceStyle) async throws {
        let (hosted, layout) = try await render(Self.tableShape, style)
        defer { hosted.tearDown() }
        let column = try #require(layout.column)
        let table = try #require(layout.table)
        let cell = try #require(layout.cell)
        #expect(column.right - column.left > layout.mask.right - layout.mask.left + 100, "the column is wider than the text")
        #expect(abs((table.right - table.left) - (column.right - column.left)) <= 1,
                "table \(table.left)...\(table.right), column \(column.left)...\(column.right)")
        #expect(abs((layout.rule.right - layout.rule.left) - (cell.right - cell.left)) <= 1,
                "rule \(layout.rule.left)...\(layout.rule.right), cell \(cell.left)...\(cell.right)")
    }
}
