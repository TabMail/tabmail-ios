/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import Security
import WebKit
import SwiftUI
import UIKit
@testable import TabMail

// =====================================================================================
// P1a — THE EMAIL-RENDER SECURITY CANARY
//
// This suite is a MEASUREMENT HARNESS that lands BEFORE the hardening it will gate.
// Its assertions pin WKWebView's *currently observed* behaviour in this app's real
// configuration so that a later phase changing that behaviour fails loudly here first.
//
// SCOPE. P1a is not the hardening. `allowsContentJavaScript = false`, the injected CSP,
// the navigation-permit state machine and the asset-ownership binding are P1b / P1c /
// P1d. Several assertions below therefore pin behaviour that is *currently unsafe* —
// each one carries an "INVERTS AT" comment naming the phase that will flip it. Do not
// "fix" the app to satisfy this file; flip the assertion in the phase that changes the
// behaviour.
//
// FIDELITY. Where possible the measurements run against the REAL production surface:
// `HostedRenderView` hosts `AutoSizingHTMLView` in a live `UIWindow`, so
// `HTMLWebView.makeUIView` builds the actual `WKWebViewConfiguration` (the JS gate, the
// user scripts, the three message handlers, and `BodyAssetSchemeHandler` when
// `headerId != nil`). Probe web views are then constructed FROM that configuration, so
// they inherit the real user-script set. Two things are measured on synthetic configs
// and are labelled as such: the subresource-origin probes (they need a recording scheme
// handler to observe the exact URL WebKit asks for) and the `allowsContentJavaScript =
// false` probe (P1b's load-bearing assumption, measured ahead of P1b without touching
// production code).
//
// COVERAGE GAP: only one simulator runtime is installed (iOS 26.5) and the deployment
// target is iOS 26.0, so the "min OS" leg of "min + current supported iOS" was NOT
// exercised. Every number below is from iOS 26.5 on iPhone 17 Pro.
//
// -------------------------------------------------------------------------------------
// MEASURED CALLBACK-ORDER TABLE — the deliverable P1c is built from.
// Recorded 2026-08-12, iOS 26.5 simulator (iPhone 17 Pro), debug build.
// `nav=` identifies the `WKNavigation` returned by the load call; `UNLABELLED` means the
// caller discarded the return value and the callback could not be correlated.
//
// (1) loadHTMLString(baseURL: nil) — compose quote / .eml preview / tooltip shape
//     1. decidePolicyFor  type=other  targetFrame=main  sourceMain=true  url=about:blank  → allow
//     2. didStartProvisionalNavigation  nav=L1
//     3. didCommit  nav=L1
//     4. didFinish  nav=L1
//     document.baseURI = about:blank      window.origin = null
//     ⇒ the action URL carries NO per-load information. See UNCERTAIN #1 below.
//
// (2) loadHTMLString(baseURL: tabmail-asset://asset/) — persisted-body shape shipping today
//     1. decidePolicyFor  type=other  targetFrame=main  sourceMain=true
//        url=tabmail-asset://asset/  → allow
//     2. didStartProvisionalNavigation  nav=L1   3. didCommit  nav=L1   4. didFinish  nav=L1
//     document.baseURI = tabmail-asset://asset/   window.origin = tabmail-asset://asset
//
// (3) loadHTMLString(baseURL: tabmail-asset://asset/_tm-document/<128-bit nonce>/)
//     — C1's proposed shape, WITH the scheme handler registered
//     1. decidePolicyFor  type=other  targetFrame=main  sourceMain=true
//        url=tabmail-asset://asset/_tm-document/<nonce>/  → allow   (byte-exact)
//     2. didStartProvisionalNavigation  nav=L1   3. didCommit  nav=L1   4. didFinish  nav=L1
//     document.baseURI = <the same exact URL>     window.origin = tabmail-asset://asset
//
// (4) Same nonce URL, scheme handler NOT registered (the nil-base call sites' config)
//     — byte-identical to (3). Substitute-data loads do not consult the scheme handler.
//
// (5) In-document fragment click, delegate returns .allow
//     1. decidePolicyFor  type=linkActivated  targetFrame=main  sourceMain=true
//        url=tabmail-asset://asset/#target  → allow
//     (no didStartProvisionalNavigation / didCommit / didFinish at all)
//     location.href afterwards = tabmail-asset://asset/#target ; canGoBack = false
//
// (6) In-document fragment click, delegate returns .cancel (what ships today)
//     1. decidePolicyFor  type=linkActivated  targetFrame=main  sourceMain=true
//        url=tabmail-asset://asset/#target  → cancel
//     location.href afterwards = tabmail-asset://asset/#target  ← THE CANCEL DID NOT PREVENT IT
//     history.length 1 → 1 ; canGoBack = false
//
// (7) history.pushState(...)  → (no delegate callbacks); location.href changes
//     history.back()          → (no delegate callbacks); location.href does NOT change
//     goBack() after two loadHTMLString loads → returns nil, no callbacks, document unchanged
//     canGoBack = false and history.length = 1 after two substitute-data loads
//     ⇒ substitute-data loads build no back/forward list; `.backForward` is unreachable here.
//
// (8) Two overlapping app loads, each with its own nonce base URL
//     1. decidePolicyFor  type=other  targetFrame=main  url=<nonce A>  → allow
//     2. decidePolicyFor  type=other  targetFrame=main  url=<nonce B>  → allow
//     3. didStartProvisionalNavigation  nav=B
//     4. didCommit  nav=B
//     5. didFinish  nav=B
//     The superseded load A receives NO didStart / didCommit / didFinish / didFail* at all.
//     ⇒ supersession is silent. A permit for A can only be retired by issuing B, never by a
//       failure callback. Both policy calls DO occur, each carrying its own nonce.
//
// (9) Subframe (iframe src) under a nonce base URL
//     1. decidePolicyFor  type=other  targetFrame=main  url=<nonce>  → allow
//     2. didStartProvisionalNavigation  nav=main
//     3. didCommit  nav=main
//     4. decidePolicyFor  type=other  targetFrame=SUB  sourceMain=true
//        url=tabmail-asset://asset/sub-frame.html  → allow      ← between commit and finish
//     5. didFinish  nav=main
//
// (10) <a target="_blank"> click
//     1. decidePolicyFor  type=linkActivated  targetFrame=nil  sourceMain=true
//        url=tabmail-asset://asset/blank-target  → allow
//
// (11) <meta http-equiv="refresh"> in the email body, NO script involved
//     1. decidePolicyFor  type=other  targetFrame=main  url=<nonce base>  → allow
//     2. didStartProvisionalNavigation   3. didCommit   4. didFinish
//     5. decidePolicyFor  type=other  targetFrame=main  sourceMain=true
//        url=tabmail-asset://asset/forged-target.html  → allow
//     6. didStartProvisionalNavigation   7. didCommit   8. didFinish
//     ⇒ a script-free document produces an action SHAPE-IDENTICAL to an app load
//       (.other + main frame + sourceMain). Only the URL distinguishes them, which is
//       exactly why C1's per-load nonce is load-bearing. Still fires with JS disabled.
//
// (12) webViewWebContentProcessDidTerminate → the production recovery reload
//     1. decidePolicyFor  type=other  targetFrame=main  url=tabmail-asset://asset/  → allow
//     2. didStartProvisionalNavigation  nav=UNLABELLED
//     3. didCommit  nav=UNLABELLED
//     4. didFinish  nav=UNLABELLED
//     JS context is fresh (a marker set before termination is gone).
//
// (13) Appearance (light → dark) reload — identical 4-step trace, nav=UNLABELLED.
//
//  (12) and (13) are UNLABELLED because `Coordinator.wrapAndLoad` DISCARDS the
//  `WKNavigation` that `loadHTMLString` returns. Correlating a permit to its navigation
//  (C2) requires capturing that value; it is available, non-nil, and distinct per load.
// =====================================================================================

// MARK: - Probes

/// Records every navigation-delegate callback in order, with the fields C1/C2 reason about.
/// Optionally forwards to a real delegate so the production `Coordinator` can be observed
/// in place rather than replaced.
@MainActor
final class NavProbe: NSObject, WKNavigationDelegate {
    enum Target: String { case main, sub, newWindow }

    struct Event {
        let callback: String
        let detail: String
        var navType: WKNavigationType?
        var target: Target?
        var url: String?
        var navLabel: String?
    }

    private(set) var events: [Event] = []
    var labels: [ObjectIdentifier: String] = [:]
    var policy: (WKNavigationAction) -> WKNavigationActionPolicy = { _ in .allow }
    var forward: WKNavigationDelegate?

    private static let decidePolicySelector =
        NSSelectorFromString("webView:decidePolicyForNavigationAction:decisionHandler:")

    func label(_ nav: WKNavigation?, _ name: String) {
        guard let nav else { return }
        labels[ObjectIdentifier(nav)] = name
    }
    private func name(_ nav: WKNavigation?) -> String {
        guard let nav else { return "nil" }
        return labels[ObjectIdentifier(nav)] ?? "UNLABELLED"
    }
    func reset() { events.removeAll() }

    /// Only the navigation-policy callbacks.
    var policyEvents: [Event] { events.filter { $0.callback == "decidePolicyFor" } }
    /// The ordered list of callback names — the shape the table above records.
    var order: [String] { events.map(\.callback) }

    var trace: String {
        if events.isEmpty { return "  (no delegate callbacks)" }
        return events.enumerated()
            .map { "  \($0.offset + 1). \($0.element.callback) \($0.element.detail)" }
            .joined(separator: "\n")
    }

    static func typeName(_ t: WKNavigationType) -> String {
        switch t {
        case .linkActivated: return "linkActivated"
        case .formSubmitted: return "formSubmitted"
        case .backForward: return "backForward"
        case .reload: return "reload"
        case .formResubmitted: return "formResubmitted"
        case .other: return "other"
        @unknown default: return "unknown(\(t.rawValue))"
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        let frame = navigationAction.targetFrame
        let target: Target = frame == nil ? .newWindow : (frame!.isMainFrame ? .main : .sub)
        let url = navigationAction.request.url?.absoluteString
        let fields = "type=\(Self.typeName(navigationAction.navigationType)) "
            + "targetFrame=\(target.rawValue) "
            + "sourceMain=\(navigationAction.sourceFrame.isMainFrame) "
            + "url=\(url ?? "nil")"

        let decision: WKNavigationActionPolicy
        if let forward, forward.responds(to: Self.decidePolicySelector) {
            // Drive the REAL coordinator's decision so its behaviour, not the probe's, is measured.
            decision = await withCheckedContinuation { (cont: CheckedContinuation<WKNavigationActionPolicy, Never>) in
                forward.webView?(webView, decidePolicyFor: navigationAction, decisionHandler: { cont.resume(returning: $0) })
            }
        } else {
            decision = policy(navigationAction)
        }
        events.append(Event(callback: "decidePolicyFor",
                            detail: fields + " → \(decision == .allow ? "allow" : "cancel")",
                            navType: navigationAction.navigationType,
                            target: target,
                            url: url,
                            navLabel: nil))
        return decision
    }

    private func recordNav(_ cb: String, _ navigation: WKNavigation?, extra: String = "") {
        let label = name(navigation)
        events.append(Event(callback: cb, detail: "nav=\(label)\(extra)",
                            navType: nil, target: nil, url: nil, navLabel: label))
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        recordNav("didStartProvisionalNavigation", navigation)
        forward?.webView?(webView, didStartProvisionalNavigation: navigation)
    }
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        recordNav("didCommit", navigation)
        forward?.webView?(webView, didCommit: navigation)
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        recordNav("didFinish", navigation)
        forward?.webView?(webView, didFinish: navigation)
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        recordNav("didFailProvisionalNavigation", navigation,
                  extra: " err=\((error as NSError).domain)/\((error as NSError).code)")
        forward?.webView?(webView, didFailProvisionalNavigation: navigation, withError: error)
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        recordNav("didFail", navigation,
                  extra: " err=\((error as NSError).domain)/\((error as NSError).code)")
        forward?.webView?(webView, didFail: navigation, withError: error)
    }
    func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
        recordNav("didReceiveServerRedirectForProvisionalNavigation", navigation)
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        events.append(Event(callback: "webViewWebContentProcessDidTerminate", detail: ""))
        forward?.webViewWebContentProcessDidTerminate?(webView)
    }
}

/// Records the exact URL WebKit asks the custom-scheme handler for, so subresource
/// resolution under a nonce-bearing base URL can be observed rather than assumed.
@MainActor
final class RecordingSchemeHandler: NSObject, WKURLSchemeHandler {
    private(set) var urls: [String] = []

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else { return }
        urls.append(url.absoluteString)
        let isHTML = url.absoluteString.hasSuffix(".html")
        let body = isHTML
            ? Data("<html><body>sub</body></html>".utf8)
            // 1×1 transparent GIF.
            : Data([0x47, 0x49, 0x46, 0x38, 0x39, 0x61, 1, 0, 1, 0, 0x80, 0, 0, 0, 0, 0, 0xFF, 0xFF, 0xFF,
                    0x21, 0xF9, 0x04, 0x01, 0, 0, 0, 0, 0x2C, 0, 0, 0, 0, 1, 0, 1, 0, 0, 2, 0x02, 0x44, 0x01, 0, 0x3B])
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": isHTML ? "text/html" : "image/gif",
                                                      "Content-Length": String(body.count)])!
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(body)
        urlSchemeTask.didFinish()
    }
    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
}

@MainActor
enum CanaryKit {
    /// Polls on the main actor; WebKit callbacks are main-actor, so a plain sleep loop is
    /// sufficient and avoids the continuation-leak hazards of expectation bridging.
    @discardableResult
    static func waitUntil(_ timeout: TimeInterval = 12, _ cond: @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if cond() { return true }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return cond()
    }

    @discardableResult
    static func waitForFinish(_ probe: NavProbe, _ timeout: TimeInterval = 12) async -> Bool {
        await waitUntil(timeout) { probe.events.contains { $0.callback == "didFinish" } }
    }

    static func eval(_ webView: WKWebView, _ js: String) async -> String {
        await withCheckedContinuation { (cont: CheckedContinuation<String, Never>) in
            webView.evaluateJavaScript(js) { value, error in
                if let error {
                    cont.resume(returning: "JSERR:\((error as NSError).domain)/\((error as NSError).code)")
                } else if let value {
                    cont.resume(returning: String(describing: value))
                } else {
                    cont.resume(returning: "null")
                }
            }
        }
    }

    /// 128 random bits, lowercase hex — the entropy C1 specifies for the permit nonce.
    static func nonce() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, 16, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    static func nonceBase(_ nonce: String) -> URL {
        URL(string: "\(BodyAssetConfig.urlScheme)://asset/_tm-document/\(nonce)/")!
    }

    /// A probe web view sharing the production configuration (and therefore the real user scripts).
    static func probeWebView(_ configuration: WKWebViewConfiguration, _ probe: NavProbe) -> WKWebView {
        let wv = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 600), configuration: configuration)
        wv.navigationDelegate = probe
        return wv
    }
}

/// Hosts the REAL `AutoSizingHTMLView` in a live window so `HTMLWebView.makeUIView`
/// builds the production `WKWebViewConfiguration` — the JS gate, the user scripts, the
/// message handlers, and `BodyAssetSchemeHandler` when `headerId != nil`.
@MainActor
final class HostedRenderView {
    let window: UIWindow
    let controller: UIViewController
    let webView: WKWebView

    init?(html: String, headerId: String?, previewFilename: String? = nil) async {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).first else {
            print("[P1A] NO UIWindowScene in the test host — cannot host SwiftUI")
            return nil
        }
        let view = AutoSizingHTMLView(html: html, previewFilename: previewFilename, headerId: headerId)
        let hc = UIHostingController(rootView: VStack(spacing: 0) { view; Spacer() })
        let w = UIWindow(windowScene: scene)
        w.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        w.rootViewController = hc
        w.isHidden = false
        w.makeKeyAndVisible()
        w.layoutIfNeeded()
        self.window = w
        self.controller = hc

        var found: WKWebView?
        await CanaryKit.waitUntil(10) {
            w.layoutIfNeeded()
            found = HostedRenderView.findWebView(w)
            return found != nil && found!.bounds.width > 50
        }
        guard let wv = found else {
            print("[P1A] hosted, but no WKWebView wider than 50pt appeared")
            return nil
        }
        self.webView = wv
    }

    func tearDown() {
        window.isHidden = true
        window.rootViewController = nil
    }

    static func findWebView(_ v: UIView) -> WKWebView? {
        if let w = v as? WKWebView { return w }
        for sub in v.subviews {
            if let w = findWebView(sub) { return w }
        }
        return nil
    }
}

// MARK: - The canary

@MainActor
@Suite("P1a render-security canary — measured WKWebView behaviour", .serialized)
struct EmailRenderSecurityCanaryTests {

    // -------------------------------------------------------------------------------
    // 1. The production configuration this canary measures.
    // -------------------------------------------------------------------------------
    @Test("Canary: the production WKWebView configuration is the one measured here")
    func productionConfiguration() async {
        guard let hostedAsset = await HostedRenderView(html: "<p>config probe</p>",
                                                       headerId: "canary-config-asset") else {
            #expect(Bool(false), "could not host AutoSizingHTMLView"); return
        }
        defer { hostedAsset.tearDown() }
        let cfg = hostedAsset.webView.configuration

        // INVERTS AT P1b — the whole point of P1b is to set this to false.
        #expect(cfg.defaultWebpagePreferences.allowsContentJavaScript == true,
                "author JS is enabled today; P1b sets allowsContentJavaScript = false and this inverts")

        // Blocker B2: Data Detectors synthesize taps OUTSIDE the navigation delegate, so a
        // permit state machine cannot see them. Pinned so P1b's decision here is deliberate.
        #expect(cfg.dataDetectorTypes == [.link, .phoneNumber],
                "data detectors are on today (B2: their taps bypass decidePolicyFor)")

        // INVERTS AT P1b if link preview is disabled there.
        #expect(hostedAsset.webView.allowsLinkPreview == true,
                "link preview is on today; P1b may disable it")

        // INVERTS AT P1b if the store is made non-persistent.
        #expect(cfg.websiteDataStore.isPersistent == true,
                "the render web view uses the PERSISTENT data store today")

        // C4: the scheme handler is registered exactly when a headerId is present.
        #expect(cfg.urlSchemeHandler(forURLScheme: BodyAssetConfig.urlScheme) != nil,
                "headerId != nil must register BodyAssetSchemeHandler")

        let scripts = cfg.userContentController.userScripts
        #expect(!scripts.isEmpty, "the app injects user scripts; they must survive P1b's JS gate")
        print("[P1A] production userScripts.count=\(scripts.count) " +
              "dataDetectorTypes=\(cfg.dataDetectorTypes.rawValue)")

        guard let hostedNil = await HostedRenderView(html: "<p>config probe</p>", headerId: nil) else {
            #expect(Bool(false), "could not host the headerId == nil variant"); return
        }
        defer { hostedNil.tearDown() }
        #expect(hostedNil.webView.configuration.urlSchemeHandler(forURLScheme: BodyAssetConfig.urlScheme) == nil,
                "headerId == nil must NOT register the scheme handler (C5: compose/.eml resolve differently)")
    }

    // -------------------------------------------------------------------------------
    // 2. Script execution — author vs app.
    // -------------------------------------------------------------------------------
    @Test("Canary: an author inline script executes today, alongside the app's user scripts")
    func authorScriptExecutesToday() async {
        let body = """
        <script>window.__tmCanaryAuthorRan = true;
        document.documentElement.setAttribute('data-author','yes');</script>
        <p>author script probe</p>
        """
        guard let host = await HostedRenderView(html: body, headerId: "canary-author-script") else {
            #expect(Bool(false), "could not host AutoSizingHTMLView"); return
        }
        defer { host.tearDown() }
        let wv = host.webView
        try? await Task.sleep(for: .seconds(3))

        let authorRan = await CanaryKit.eval(wv, "String(window.__tmCanaryAuthorRan)")
        let authorDOM = await CanaryKit.eval(wv, "String(document.documentElement.getAttribute('data-author'))")
        let appScript = await CanaryKit.eval(wv, "typeof window.__tmReportHeight")
        print("[P1A] authorRan=\(authorRan) authorDOM=\(authorDOM) appScript=\(appScript)")

        // INVERTS AT P1b — with allowsContentJavaScript = false both become "undefined"/"null".
        #expect(authorRan == "true",
                "author inline script RUNS today; P1b sets allowsContentJavaScript = false and this inverts")
        #expect(authorDOM == "yes",
                "author script mutates the DOM today; P1b inverts this")

        // MUST NOT invert: the hardening depends on app user scripts still running.
        #expect(appScript == "function",
                "the app's WKUserScript must execute (height reporting); P1b must not break this")

        // The wrapper's CSP today is upgrade-insecure-requests only.
        let csp = await CanaryKit.eval(wv,
            "String((document.querySelector('meta[http-equiv=\"Content-Security-Policy\"]')||{}).content)")
        #expect(csp == "upgrade-insecure-requests",
                "P1b extends this CSP; this assertion changes there")
    }

    // -------------------------------------------------------------------------------
    // 3. Images — remote deferral and custom-scheme assets.
    // -------------------------------------------------------------------------------
    @Test("Canary: remote images are deferred by the wrapper and re-armed by the app script")
    func remoteImageDeferral() async {
        // 127.0.0.1:1 — no external traffic, no real-world domain, fails fast.
        let body = "<img id=\"remote\" src=\"https://127.0.0.1:1/tm-canary-pixel.gif\" width=\"10\" height=\"10\">"
        guard let host = await HostedRenderView(html: body, headerId: "canary-remote-image") else {
            #expect(Bool(false), "could not host AutoSizingHTMLView"); return
        }
        defer { host.tearDown() }
        let wv = host.webView
        try? await Task.sleep(for: .seconds(4))   // past deferredImageLoadJS's 1500 ms failsafe

        let dataAttr = await CanaryKit.eval(wv,
            "String(document.getElementById('remote').getAttribute('data-tmsrc'))")
        let src = await CanaryKit.eval(wv, "String(document.getElementById('remote').getAttribute('src'))")
        print("[P1A] remote img data-tmsrc=\(dataAttr) src=\(src)")

        // EmailHTMLWrapper.wrapHTML rewrites remote src → data-tmsrc; deferredImageLoadJS
        // (a WKUserScript) swaps it back after paint. Both halves must survive P1b.
        #expect(dataAttr == "null", "the app script consumed data-tmsrc and restored src")
        #expect(src == "https://127.0.0.1:1/tm-canary-pixel.gif", "the original remote URL is restored verbatim")
    }

    @Test("Canary: custom-scheme subresources resolve against the base URL, origin unchanged by the nonce")
    func customSchemeSubresources() async {
        // Synthetic config: a recording handler is required to observe the exact URL WebKit asks for.
        func makeConfig(_ handler: RecordingSchemeHandler) -> WKWebViewConfiguration {
            let cfg = WKWebViewConfiguration()
            cfg.defaultWebpagePreferences.allowsContentJavaScript = true
            cfg.setURLSchemeHandler(handler, forURLScheme: BodyAssetConfig.urlScheme)
            return cfg
        }
        let assetHost = String(repeating: "a", count: BodyAssetStore.hashHexLength)
        let assetId = String(repeating: "b", count: BodyAssetStore.hashHexLength)
        let absolute = "\(BodyAssetConfig.urlScheme)://\(assetHost)/\(assetId)"
        let doc = EmailHTMLWrapper.wrapHTML("""
        <img id="abs" src="\(absolute)">
        <img id="rel" src="relative-probe.gif">
        """)

        // (a) nonce-in-path base URL
        let h1 = RecordingSchemeHandler()
        let p1 = NavProbe()
        let wv1 = CanaryKit.probeWebView(makeConfig(h1), p1)
        let n = CanaryKit.nonce()
        _ = wv1.loadHTMLString(doc, baseURL: CanaryKit.nonceBase(n))
        await CanaryKit.waitForFinish(p1)
        try? await Task.sleep(for: .seconds(2))
        print("[P1A] nonce-base handler saw \(h1.urls)")

        #expect(h1.urls.contains(absolute),
                "an ABSOLUTE tabmail-asset URL is delivered unchanged even under a nonce-bearing base")
        #expect(h1.urls.contains("\(BodyAssetConfig.urlScheme)://asset/_tm-document/\(n)/relative-probe.gif"),
                "a RELATIVE URL resolves against the nonce path — relative asset refs would move")
        #expect(await CanaryKit.eval(wv1, "String(window.origin)") == "\(BodyAssetConfig.urlScheme)://asset",
                "origin is scheme+host only: the nonce path does NOT change the document origin")
        #expect(await CanaryKit.eval(wv1, "String(document.getElementById('abs').naturalWidth)") == "1",
                "absolute asset image still loads under a nonce base URL")

        // (b) the plain base URL shipping today
        let h2 = RecordingSchemeHandler()
        let p2 = NavProbe()
        let wv2 = CanaryKit.probeWebView(makeConfig(h2), p2)
        _ = wv2.loadHTMLString(doc, baseURL: BodyAssetConfig.baseURL)
        await CanaryKit.waitForFinish(p2)
        try? await Task.sleep(for: .seconds(2))
        print("[P1A] plain-base handler saw \(h2.urls)")
        #expect(h2.urls.contains(absolute), "absolute asset URL unchanged under the plain base too")
        #expect(h2.urls.contains("\(BodyAssetConfig.urlScheme)://asset/relative-probe.gif"),
                "relative URLs resolve against the plain base today")
    }

    // -------------------------------------------------------------------------------
    // 4. UNCERTAIN #1 — nonce-in-path, under every base-URL case the app uses.
    // -------------------------------------------------------------------------------
    @Test("Canary: the nonce-in-path base URL arrives byte-exact at decidePolicyFor; a nil base URL does not")
    func nonceInPathUnderEveryBaseCase() async {
        guard let hostedAsset = await HostedRenderView(html: "<p>seed</p>", headerId: "canary-nonce-asset"),
              let hostedNil = await HostedRenderView(html: "<p>seed</p>", headerId: nil) else {
            #expect(Bool(false), "could not host both AutoSizingHTMLView variants"); return
        }
        defer { hostedAsset.tearDown(); hostedNil.tearDown() }
        let cfgAsset = hostedAsset.webView.configuration      // scheme handler registered
        let cfgNil = hostedNil.webView.configuration          // no scheme handler

        let n = CanaryKit.nonce()
        #expect(n.count == 32, "the probe nonce carries 128 bits, C1's floor")
        let nonceURL = CanaryKit.nonceBase(n).absoluteString

        struct LoadFacts { let policyURL: String; let baseURI: String; let origin: String; let order: [String] }
        func measure(_ label: String, _ cfg: WKWebViewConfiguration, _ base: URL?) async -> LoadFacts {
            let probe = NavProbe()
            let wv = CanaryKit.probeWebView(cfg, probe)
            let nav = wv.loadHTMLString(EmailHTMLWrapper.wrapHTML("<p id=\"p\">probe</p>"), baseURL: base)
            probe.label(nav, "L1")
            // C2: loadHTMLString DOES return a WKNavigation — production discards it.
            #expect(nav != nil, "loadHTMLString returns a non-nil WKNavigation to correlate on")
            await CanaryKit.waitForFinish(probe)
            try? await Task.sleep(for: .milliseconds(500))
            print("[P1A] \(label) trace:\n\(probe.trace)")
            return LoadFacts(policyURL: probe.policyEvents.first?.url ?? "MISSING",
                          baseURI: await CanaryKit.eval(wv, "document.baseURI"),
                          origin: await CanaryKit.eval(wv, "String(window.origin)"),
                          order: probe.order)
        }

        let expectedOrder = ["decidePolicyFor", "didStartProvisionalNavigation", "didCommit", "didFinish"]

        // (A) nil base URL — compose quote, .eml preview, tooltip.
        let a = await measure("A/nil-base", cfgNil, nil)
        #expect(a.policyURL == "about:blank",
                "a nil baseURL surfaces about:blank at policy time — NO per-load information survives")
        #expect(a.baseURI == "about:blank")
        #expect(a.origin == "null")
        #expect(a.order == expectedOrder)

        // (B) the plain asset base URL shipping today.
        let b = await measure("B/asset-base", cfgAsset, BodyAssetConfig.baseURL)
        #expect(b.policyURL == BodyAssetConfig.baseURL.absoluteString,
                "the plain base URL is delivered exactly — but it is a FIXED string a document can forge")
        #expect(b.order == expectedOrder)

        // (C) C1's proposed shape, scheme handler registered.
        let c = await measure("C/nonce-with-handler", cfgAsset, CanaryKit.nonceBase(n))
        #expect(c.policyURL == nonceURL,
                "the nonce URL arrives byte-exact — C1's exact-string-equality permit is expressible")
        #expect(c.baseURI == nonceURL)
        #expect(c.origin == "\(BodyAssetConfig.urlScheme)://asset",
                "the nonce lives in the PATH, so the origin is unchanged and absolute asset URLs are unaffected")
        #expect(c.order == expectedOrder)

        // (D) C1's shape on a config with NO scheme handler — the nil-base call sites' config.
        // This is the migration path for compose/.eml/tooltip: they can adopt a synthetic
        // nonce base URL without registering a handler, because substitute-data loads never
        // consult one for the document itself.
        let d = await measure("D/nonce-without-handler", cfgNil, CanaryKit.nonceBase(n))
        #expect(d.policyURL == nonceURL,
                "the nonce URL works with NO scheme handler registered — the nil-base sites can adopt it")
        #expect(d.baseURI == nonceURL)
        #expect(d.origin == c.origin)
        #expect(d.order == expectedOrder)
    }

    // -------------------------------------------------------------------------------
    // 5. UNCERTAIN #2 — same-document navigation and history.
    // -------------------------------------------------------------------------------
    @Test("Canary: a fragment click surfaces exactly one callback, and cancelling it does not prevent it")
    func fragmentClickCallbacks() async {
        guard let host = await HostedRenderView(html: "<p>seed</p>", headerId: "canary-fragment") else {
            #expect(Bool(false), "could not host AutoSizingHTMLView"); return
        }
        defer { host.tearDown() }
        let doc = EmailHTMLWrapper.wrapHTML("""
        <a id="lnk" href="#target">jump</a>
        <div style="height:2000px"></div>
        <div id="target">target</div>
        """)

        // (a) delegate allows the action.
        let probe = NavProbe()
        let wv = CanaryKit.probeWebView(host.webView.configuration, probe)
        _ = wv.loadHTMLString(doc, baseURL: BodyAssetConfig.baseURL)
        await CanaryKit.waitForFinish(probe)
        try? await Task.sleep(for: .milliseconds(600))
        probe.reset()
        _ = await CanaryKit.eval(wv, "document.getElementById('lnk').click(); 'clicked'")
        try? await Task.sleep(for: .seconds(1))
        print("[P1A] FRAGMENT-ALLOW trace:\n\(probe.trace)")

        #expect(probe.order == ["decidePolicyFor"],
                "a same-document fragment navigation surfaces ONLY decidePolicyFor — no start/commit/finish")
        #expect(probe.policyEvents.first?.navType == .linkActivated)
        #expect(probe.policyEvents.first?.target == .main)
        #expect(probe.policyEvents.first?.url == "\(BodyAssetConfig.baseURL.absoluteString)#target",
                "the action carries the FULL url including the fragment, so a fragment-based nonce would leak into it")
        #expect(await CanaryKit.eval(wv, "location.href") == "\(BodyAssetConfig.baseURL.absoluteString)#target")

        // (b) delegate cancels the action — what the app's Coordinator does today for
        //     .linkActivated. The cancel does NOT undo the same-document navigation.
        let probe2 = NavProbe()
        probe2.policy = { $0.navigationType == .linkActivated ? .cancel : .allow }
        let wv2 = CanaryKit.probeWebView(host.webView.configuration, probe2)
        _ = wv2.loadHTMLString(doc, baseURL: BodyAssetConfig.baseURL)
        await CanaryKit.waitForFinish(probe2)
        try? await Task.sleep(for: .milliseconds(600))
        probe2.reset()
        _ = await CanaryKit.eval(wv2, "document.getElementById('lnk').click(); 'clicked'")
        try? await Task.sleep(for: .seconds(1))
        print("[P1A] FRAGMENT-CANCEL trace:\n\(probe2.trace)")

        #expect(probe2.order == ["decidePolicyFor"])
        #expect(await CanaryKit.eval(wv2, "location.href") == "\(BodyAssetConfig.baseURL.absoluteString)#target",
                "RETURNING .cancel DOES NOT PREVENT a same-document fragment navigation — §10.2's hedge is measured fact")
    }

    @Test("Canary: history is inert — pushState, history.back and goBack surface no delegate callbacks")
    func historyIsInert() async {
        guard let host = await HostedRenderView(html: "<p>seed</p>", headerId: "canary-history") else {
            #expect(Bool(false), "could not host AutoSizingHTMLView"); return
        }
        defer { host.tearDown() }
        let cfg = host.webView.configuration

        let probe = NavProbe()
        let wv = CanaryKit.probeWebView(cfg, probe)
        _ = wv.loadHTMLString(EmailHTMLWrapper.wrapHTML("<p id=\"d\">DOC-1</p>"), baseURL: BodyAssetConfig.baseURL)
        await CanaryKit.waitForFinish(probe)
        try? await Task.sleep(for: .milliseconds(600))

        // pushState
        probe.reset()
        _ = await CanaryKit.eval(wv, "history.pushState({}, '', 'pushed-state'); 'ok'")
        try? await Task.sleep(for: .milliseconds(600))
        print("[P1A] PUSHSTATE trace:\n\(probe.trace)")
        #expect(probe.events.isEmpty,
                "history.pushState produces NO navigation-delegate callback; a permit machine cannot observe it")
        #expect(await CanaryKit.eval(wv, "location.href") == "\(BodyAssetConfig.urlScheme)://asset/pushed-state",
                "…yet it DOES change location.href, so the URL is not a reliable identity for the loaded document")

        // history.back()
        probe.reset()
        _ = await CanaryKit.eval(wv, "history.back(); 'back'")
        try? await Task.sleep(for: .seconds(1))
        print("[P1A] HISTORY.BACK trace:\n\(probe.trace)")
        #expect(probe.events.isEmpty, "history.back() surfaces no delegate callbacks")
        #expect(await CanaryKit.eval(wv, "location.href") == "\(BodyAssetConfig.urlScheme)://asset/pushed-state",
                "history.back() did not move: substitute-data loads build no back/forward list")

        // Cross-document: two loadHTMLString loads still leave no back/forward entry.
        let probe2 = NavProbe()
        let wv2 = CanaryKit.probeWebView(cfg, probe2)
        _ = wv2.loadHTMLString(EmailHTMLWrapper.wrapHTML("<p id=\"d\">DOC-1</p>"), baseURL: BodyAssetConfig.baseURL)
        await CanaryKit.waitForFinish(probe2)
        try? await Task.sleep(for: .milliseconds(600))
        probe2.reset()
        _ = wv2.loadHTMLString(EmailHTMLWrapper.wrapHTML("<p id=\"d\">DOC-2</p>"),
                               baseURL: URL(string: "\(BodyAssetConfig.urlScheme)://asset/second/")!)
        await CanaryKit.waitForFinish(probe2)
        try? await Task.sleep(for: .milliseconds(600))
        #expect(wv2.canGoBack == false,
                "two substitute-data loads leave canGoBack == false — .backForward is unreachable in this configuration")
        probe2.reset()
        let backNav = wv2.goBack()
        try? await Task.sleep(for: .seconds(2))
        #expect(backNav == nil, "goBack() returns nil: there is nothing to go back to")
        #expect(probe2.events.isEmpty, "goBack() produced no callbacks")
        #expect(await CanaryKit.eval(wv2, "String((document.getElementById('d')||{}).textContent)") == "DOC-2",
                "the document did not change")
    }

    // -------------------------------------------------------------------------------
    // 6. Overlapping app loads — C2's "supersession, not an assertion failure".
    // -------------------------------------------------------------------------------
    @Test("Canary: an overlapping app load supersedes the first silently, each carrying its own nonce")
    func overlappingLoadsSupersedeSilently() async {
        guard let host = await HostedRenderView(html: "<p>seed</p>", headerId: "canary-overlap") else {
            #expect(Bool(false), "could not host AutoSizingHTMLView"); return
        }
        defer { host.tearDown() }

        let probe = NavProbe()
        let wv = CanaryKit.probeWebView(host.webView.configuration, probe)
        let nA = CanaryKit.nonce()
        let nB = CanaryKit.nonce()
        #expect(nA != nB, "each load gets a fresh nonce")

        let a = wv.loadHTMLString(EmailHTMLWrapper.wrapHTML("<p id=\"which\">FIRST</p>"),
                                  baseURL: CanaryKit.nonceBase(nA))
        probe.label(a, "A")
        let b = wv.loadHTMLString(EmailHTMLWrapper.wrapHTML("<p id=\"which\">SECOND</p>"),
                                  baseURL: CanaryKit.nonceBase(nB))
        probe.label(b, "B")
        #expect(a != nil && b != nil, "both loads return a WKNavigation")
        #expect(a !== b, "the two loads return DISTINCT WKNavigation objects — correlation is possible")

        await CanaryKit.waitForFinish(probe)
        try? await Task.sleep(for: .seconds(1))
        print("[P1A] OVERLAP trace:\n\(probe.trace)")

        let policyURLs = probe.policyEvents.compactMap(\.url)
        #expect(policyURLs == [CanaryKit.nonceBase(nA).absoluteString, CanaryKit.nonceBase(nB).absoluteString],
                "BOTH loads reach decidePolicyFor, in order, each with its own nonce")
        #expect(probe.order == ["decidePolicyFor", "decidePolicyFor",
                                "didStartProvisionalNavigation", "didCommit", "didFinish"],
                "only the surviving load produces start/commit/finish")
        #expect(probe.events.filter { $0.callback.hasPrefix("didFail") }.isEmpty,
                "the SUPERSEDED load produces NO failure callback — supersession is silent, so a permit for the superseded load can only be retired by issuing the next one")
        let navLabels = Set(probe.events.compactMap(\.navLabel))
        #expect(navLabels == ["B"], "every navigation callback belongs to the second load")
        #expect(await CanaryKit.eval(wv, "String((document.getElementById('which')||{}).textContent)") == "SECOND")
    }

    // -------------------------------------------------------------------------------
    // 7. Frames — the two shapes C2 must special-case.
    // -------------------------------------------------------------------------------
    @Test("Canary: subframe and new-window actions are distinguishable at policy time")
    func subframeAndNewWindowActions() async {
        let handler = RecordingSchemeHandler()
        let cfg = WKWebViewConfiguration()
        cfg.defaultWebpagePreferences.allowsContentJavaScript = true
        cfg.setURLSchemeHandler(handler, forURLScheme: BodyAssetConfig.urlScheme)
        let probe = NavProbe()
        let wv = CanaryKit.probeWebView(cfg, probe)

        let n = CanaryKit.nonce()
        let doc = EmailHTMLWrapper.wrapHTML("""
        <iframe id="f" src="\(BodyAssetConfig.urlScheme)://asset/sub-frame.html" width="100" height="50"></iframe>
        <a id="blanklnk" href="\(BodyAssetConfig.urlScheme)://asset/blank-target" target="_blank">new window</a>
        """)
        _ = wv.loadHTMLString(doc, baseURL: CanaryKit.nonceBase(n))
        await CanaryKit.waitForFinish(probe)
        try? await Task.sleep(for: .seconds(2))
        print("[P1A] SUBFRAME trace:\n\(probe.trace)")

        let sub = probe.policyEvents.first { $0.target == .sub }
        #expect(sub != nil, "an iframe src produces a policy call with targetFrame.isMainFrame == false")
        #expect(sub?.url == "\(BodyAssetConfig.urlScheme)://asset/sub-frame.html")
        #expect(sub?.navType == .other, "an iframe load is .other, exactly like an app load — only the frame differs")
        // Ordering matters for C2: the subframe action arrives AFTER the main frame commits.
        if let subIndex = probe.events.firstIndex(where: { $0.callback == "decidePolicyFor" && $0.target == .sub }),
           let commitIndex = probe.events.firstIndex(where: { $0.callback == "didCommit" }) {
            #expect(subIndex > commitIndex,
                    "the subframe action arrives after the main frame's didCommit — a permit consumed at policy time must already be gone by then")
        }

        probe.reset()
        _ = await CanaryKit.eval(wv, "document.getElementById('blanklnk').click(); 'clicked'")
        try? await Task.sleep(for: .seconds(1))
        print("[P1A] TARGET-BLANK trace:\n\(probe.trace)")
        #expect(probe.order == ["decidePolicyFor"], "a _blank click surfaces exactly one policy call")
        #expect(probe.policyEvents.first?.target == .newWindow,
                "target=_blank surfaces targetFrame == nil — C2's new-window case")
        #expect(probe.policyEvents.first?.navType == .linkActivated)
    }

    // -------------------------------------------------------------------------------
    // 8. The threat the permit exists for: a script-free document navigating the main frame.
    // -------------------------------------------------------------------------------
    @Test("Canary: a meta refresh navigates the main frame with an action shape identical to an app load")
    func metaRefreshForgesAnAppLoadShape() async {
        let handler = RecordingSchemeHandler()
        let cfg = WKWebViewConfiguration()
        cfg.defaultWebpagePreferences.allowsContentJavaScript = true
        cfg.setURLSchemeHandler(handler, forURLScheme: BodyAssetConfig.urlScheme)
        let probe = NavProbe()
        let wv = CanaryKit.probeWebView(cfg, probe)

        let n = CanaryKit.nonce()
        let forged = "\(BodyAssetConfig.urlScheme)://asset/forged-target.html"
        let doc = EmailHTMLWrapper.wrapHTML("""
        <meta http-equiv="refresh" content="0;url=\(forged)">
        <p>meta refresh probe</p>
        """)
        #expect(doc.contains("http-equiv=\"refresh\""),
                "EmailHTMLWrapper.wrapHTML does NOT strip a meta refresh from a body fragment")

        _ = wv.loadHTMLString(doc, baseURL: CanaryKit.nonceBase(n))
        await CanaryKit.waitForFinish(probe)
        try? await Task.sleep(for: .seconds(3))
        print("[P1A] META-REFRESH trace:\n\(probe.trace)")

        let second = probe.policyEvents.dropFirst().first
        #expect(second != nil, "the meta refresh produced a SECOND main-frame navigation with no script involved")
        #expect(second?.url == forged)
        #expect(second?.navType == .other,
                "the forged navigation is .other — SHAPE-IDENTICAL to an app load; only the URL distinguishes them")
        #expect(second?.target == .main)
        #expect(second?.url != CanaryKit.nonceBase(n).absoluteString,
                "the document cannot name the per-load nonce, which is exactly what makes C1's permit work")
        #expect(await CanaryKit.eval(wv, "location.href") == forged,
                "the main frame DID navigate — this is the live behaviour P1c must stop")
    }

    // -------------------------------------------------------------------------------
    // 9. P1b's load-bearing assumption, measured ahead of P1b.
    // -------------------------------------------------------------------------------
    @Test("Canary: app user scripts and image deferral survive allowsContentJavaScript = false")
    func appScriptsSurviveTheJavaScriptGate() async {
        // Synthetic config ONLY — this measures what P1b will do, without changing production code.
        let handler = RecordingSchemeHandler()
        let cfg = WKWebViewConfiguration()
        cfg.defaultWebpagePreferences.allowsContentJavaScript = false
        cfg.setURLSchemeHandler(handler, forURLScheme: BodyAssetConfig.urlScheme)
        let ucc = WKUserContentController()
        ucc.addUserScript(WKUserScript(source: "window.__tmProbeUserScript = 'ran';",
                                       injectionTime: .atDocumentStart, forMainFrameOnly: true))
        ucc.addUserScript(WKUserScript(source: """
        (function(){
          var imgs = document.querySelectorAll('img[data-tmsrc]');
          for (var i = 0; i < imgs.length; i++) { imgs[i].src = imgs[i].getAttribute('data-tmsrc'); }
          window.__tmProbeSwapped = imgs.length;
        })();
        """, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        cfg.userContentController = ucc

        let probe = NavProbe()
        let wv = CanaryKit.probeWebView(cfg, probe)
        let n = CanaryKit.nonce()
        let forged = "\(BodyAssetConfig.urlScheme)://asset/nojs-forged.html"
        let doc = EmailHTMLWrapper.wrapHTML("""
        <script>window.__tmAuthorRan = 'AUTHOR-RAN';
        document.documentElement.setAttribute('data-author','yes');</script>
        <img id="deferred" data-tmsrc="\(BodyAssetConfig.urlScheme)://asset/deferred-probe.gif">
        <meta http-equiv="refresh" content="1;url=\(forged)">
        <p>no-js probe</p>
        """)
        _ = wv.loadHTMLString(doc, baseURL: CanaryKit.nonceBase(n))
        await CanaryKit.waitForFinish(probe)
        try? await Task.sleep(for: .milliseconds(800))

        #expect(await CanaryKit.eval(wv, "String(window.__tmProbeUserScript)") == "ran",
                "an atDocumentStart WKUserScript STILL RUNS with allowsContentJavaScript = false")
        #expect(await CanaryKit.eval(wv, "String(window.__tmProbeSwapped)") == "1",
                "an atDocumentEnd WKUserScript still runs and can still re-arm deferred images")
        #expect(await CanaryKit.eval(wv, "String(window.__tmAuthorRan)") == "undefined",
                "the AUTHOR's inline script does not run")
        #expect(await CanaryKit.eval(wv, "String(document.documentElement.getAttribute('data-author'))") == "null",
                "the author script produced no DOM mutation")
        #expect(await CanaryKit.eval(wv, "1 + 1") == "2",
                "evaluateJavaScript from the app still works with the gate closed")
        #expect(await CanaryKit.eval(wv, "String(document.getElementById('deferred').naturalWidth)") == "1",
                "the deferred custom-scheme image loaded — image rendering survives P1b")

        try? await Task.sleep(for: .seconds(3))
        print("[P1A] NOJS trace:\n\(probe.trace)")
        #expect(probe.policyEvents.contains { $0.url == forged },
                "a meta refresh STILL navigates with JS disabled — P1b alone does not close this; P1c must")
    }

    // -------------------------------------------------------------------------------
    // 10. The two app-initiated reloads that are NOT user navigations.
    // -------------------------------------------------------------------------------
    @Test("Canary: content-process termination and an appearance flip both reload through the production coordinator")
    func terminationRecoveryAndAppearanceReload() async {
        guard let host = await HostedRenderView(html: "<p id=\"m\">alpha</p>", headerId: "canary-recovery") else {
            #expect(Bool(false), "could not host AutoSizingHTMLView"); return
        }
        defer { host.tearDown() }
        let wv = host.webView
        try? await Task.sleep(for: .seconds(3))

        let coordinator = wv.navigationDelegate
        #expect(coordinator != nil, "the production view installs a navigation delegate")
        print("[P1A] real navigationDelegate=\(coordinator.map { String(describing: type(of: $0)) } ?? "nil")")

        let probe = NavProbe()
        probe.forward = coordinator          // observe the REAL coordinator, do not replace it
        wv.navigationDelegate = probe
        defer { wv.navigationDelegate = coordinator }

        _ = await CanaryKit.eval(wv, "window.__tmCanaryMark = 'MARK-1'; 'set'")
        #expect(await CanaryKit.eval(wv, "String(window.__tmCanaryMark)") == "MARK-1")

        // No public API kills the content process, so drive the production recovery entry point.
        coordinator?.webViewWebContentProcessDidTerminate?(wv)
        let reloaded = await CanaryKit.waitForFinish(probe)
        try? await Task.sleep(for: .milliseconds(800))
        print("[P1A] TERMINATE-RECOVERY trace:\n\(probe.trace)")

        #expect(reloaded, "webViewWebContentProcessDidTerminate triggers a reload")
        #expect(probe.order == ["decidePolicyFor", "didStartProvisionalNavigation", "didCommit", "didFinish"],
                "the recovery reload produces the ordinary 4-callback app-load sequence")
        #expect(probe.policyEvents.first?.navType == .other)
        #expect(probe.policyEvents.first?.url == BodyAssetConfig.baseURL.absoluteString,
                "recovery re-derives the base URL from the retained headerId")
        #expect(probe.events.allSatisfy { $0.navLabel == nil || $0.navLabel == "UNLABELLED" },
                "Coordinator.wrapAndLoad DISCARDS the returned WKNavigation, so the recovery load cannot be correlated today; C2's correlation requires capturing it")
        #expect(await CanaryKit.eval(wv, "String(window.__tmCanaryMark)") == "undefined",
                "the JS context is fresh after recovery")

        // Appearance flip — updateUIView re-wraps and reloads when the color scheme changes.
        probe.reset()
        _ = await CanaryKit.eval(wv, "window.__tmCanaryMark = 'MARK-2'; 'set'")
        host.controller.overrideUserInterfaceStyle = .dark
        host.window.overrideUserInterfaceStyle = .dark
        host.window.layoutIfNeeded()
        let flipped = await CanaryKit.waitForFinish(probe)
        try? await Task.sleep(for: .milliseconds(800))
        print("[P1A] APPEARANCE-FLIP trace:\n\(probe.trace)")

        #expect(flipped, "a light→dark flip reloads the document")
        #expect(probe.order == ["decidePolicyFor", "didStartProvisionalNavigation", "didCommit", "didFinish"],
                "the appearance reload is indistinguishable from any other app load at the delegate")
        #expect(await CanaryKit.eval(wv, "String(window.__tmCanaryMark)") == "undefined",
                "the appearance reload also discards the JS context")
    }
}
