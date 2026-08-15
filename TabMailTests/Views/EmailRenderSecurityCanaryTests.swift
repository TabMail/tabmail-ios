/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import Synchronization
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
// P1b LANDED (2026-08-12). The "INVERTS AT P1b" assertions have been flipped in place and
// re-labelled "INVERTED AT P1b", each carrying the value it previously pinned, so the
// pre-hardening behaviour stays readable next to the post-hardening one. Section 11 adds
// the CSP's own tests. Two knock-on changes worth knowing before editing:
//   • `subframeAndNewWindowActions` now loads a RAW (unwrapped, CSP-free) document. Under
//     `frame-src 'none'` a wrapped document's iframe is blocked before it ever reaches the
//     delegate — correct, and asserted in `shippedCSPBlocksSubframesAndPlugins` — but C2
//     still needs the subframe CALLBACK SHAPE on record, and that shape only exists where
//     the policy is not in force. Both halves are load-bearing; deleting either loses a
//     fact P1c is built from.
//   • P1b does NOT close main-frame navigation. `metaRefreshForgesAnAppLoadShape` and
//     `appScriptsSurviveTheJavaScriptGate` both still pass: a `<meta http-equiv="refresh">`
//     navigates with JavaScript disabled. Only P1c's per-load nonce closes it.
//
// P1c LANDED. Section 12 adds the permit's end-to-end half. Read this before "fixing" the
// two tests just named: they run against ALLOW-EVERYTHING probe delegates on synthetic
// configurations, and they still pass BY DESIGN — they measure that WebKit delivers the
// forged navigation and that its shape is indistinguishable from an app load, which is the
// premise the permit is built on. `metaRefreshIsRefusedByTheProductionCoordinator` is the
// one that points the same document at the REAL delegate and asserts refusal. Deleting
// either half loses the pair. One assertion in `terminationRecoveryAndAppearanceReload`
// inverts here (the recovery load's base URL), and one that LOOKS like it should invert
// deliberately does not — see the note there.
//
// FIDELITY. Where possible the measurements run against the REAL production surface:
// `HostedRenderView` hosts `AutoSizingHTMLView` in a live `UIWindow`, so
// `HTMLWebView.makeUIView` builds the actual `WKWebViewConfiguration` (the JS gate, the
// user scripts, the four message handlers, and `BodyAssetSchemeHandler` when
// `bodyContentKey != nil`). Probe web views are then constructed FROM that configuration, so
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

    /// Evaluate in the **page world** — the document's own world.
    ///
    /// ⚠️ Since P3 this is the ATTACKER's vantage point, not the app's. The render pipeline
    /// runs in `RenderContentWorld.isolated`, so a probe for one of our own globals through
    /// this function asks *"can the document see it?"* and the answer must be no. To ask
    /// *"did our script run?"* use `eval(_:_:in:)` with `RenderContentWorld.isolated`.
    /// Probing app state here and reading `undefined` as "the script did not run" is the
    /// single easiest way to misread this suite.
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

    /// Evaluate in an explicit `WKContentWorld`.
    ///
    /// P3 split one question into two: *"did our script run"* is asked of
    /// `RenderContentWorld.isolated`, and *"can the document read our state"* is asked of
    /// `WKContentWorld.pageWorld`. Both are needed — a one-sided probe cannot distinguish
    /// a working isolated pipeline from a pipeline that did not run at all.
    ///
    /// `nil` is normalised to `"null"` so the two spellings agree with `eval(_:_:)` above;
    /// WebKit hands back `NSNull` here where the older overload hands back `nil`, and a
    /// silent `"<null>"` vs `"null"` mismatch would make an assertion fail for a reason
    /// that has nothing to do with what it is testing.
    static func eval(_ webView: WKWebView, _ js: String, in world: WKContentWorld) async -> String {
        await withCheckedContinuation { (cont: CheckedContinuation<String, Never>) in
            webView.evaluateJavaScript(js, in: nil, in: world) { result in
                switch result {
                case .failure(let error):
                    cont.resume(returning: "JSERR:\((error as NSError).domain)/\((error as NSError).code)")
                case .success(let value):
                    cont.resume(returning: value is NSNull ? "null" : String(describing: value))
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

    /// Records every `securitypolicyviolation` the document reports, as
    /// `"<effective-directive>|<blocked-uri>"`.
    ///
    /// Installed as a `WKUserScript` rather than inline script because under P1b's
    /// configuration author script does not run at all — and a page-world user script
    /// working here is itself part of what P1b claims.
    static func violationRecorder() -> WKUserScript {
        WKUserScript(source: """
        window.__tmCSPViolations = [];
        document.addEventListener('securitypolicyviolation', function (e) {
            window.__tmCSPViolations.push(
                String(e.effectiveDirective || e.violatedDirective || '?') + '|' + String(e.blockedURI || ''));
        });
        """, injectionTime: .atDocumentStart, forMainFrameOnly: true)
    }

    /// Synthetic stand-in for production's `deferredImageLoadJS`, which is `private` to
    /// `AutoSizingHTMLView`. Re-arms `data-tmsrc` the same way.
    static func imageRearmScript() -> WKUserScript {
        WKUserScript(source: """
        (function(){
          var imgs = document.querySelectorAll('img[data-tmsrc]');
          for (var i = 0; i < imgs.length; i++) { imgs[i].src = imgs[i].getAttribute('data-tmsrc'); }
          window.__tmProbeSwapped = imgs.length;
        })();
        """, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
    }

    static func violations(_ webView: WKWebView) async -> [String] {
        let raw = await eval(webView, "JSON.stringify(window.__tmCSPViolations || [])")
        guard let data = raw.data(using: .utf8),
              let arr = (try? JSONSerialization.jsonObject(with: data)) as? [String] else { return [] }
        return arr
    }
}

/// Hosts the REAL `AutoSizingHTMLView` in a live window so `HTMLWebView.makeUIView`
/// builds the production `WKWebViewConfiguration` — the JS gate, the user scripts, the
/// message handlers, and `BodyAssetSchemeHandler` when `bodyContentKey != nil` (P1d).
@MainActor
final class HostedRenderView {
    let window: UIWindow
    let controller: UIViewController
    let webView: WKWebView

    init?(
        html: String,
        headerId: String?,
        previewFilename: String? = nil,
        onUserDisclosureToggle: @escaping () -> Void = {}
    ) async {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).first else {
            print("[P1A] NO UIWindowScene in the test host — cannot host SwiftUI")
            return nil
        }
        // P1d: the scheme-handler opt-in moved from `headerId` to `bodyContentKey`
        // (the body's authoritative `MessageBody.id`). The canary hosts the two
        // together so it keeps measuring the production shape — every real call site
        // that supplies one supplies both.
        let view = AutoSizingHTMLView(
            html: html,
            previewFilename: previewFilename,
            headerId: headerId,
            bodyContentKey: headerId.map { ContentKey(rawValue: $0) },
            onUserDisclosureToggle: onUserDisclosureToggle
        )
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
@Suite("P1a render-security canary — measured WKWebView behaviour", .serialized, .processGlobalState)
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

        // INVERTED AT P1b (was `== true`). T1's root cut: sender-authored <script>, inline
        // handler attributes and javascript: URLs no longer execute.
        #expect(cfg.defaultWebpagePreferences.allowsContentJavaScript == false,
                "P1b: author JS is OFF in the production render configuration")

        // RE-INVERTED 2026-08-12 by owner directive, back to the `[.link, .phoneNumber]` this
        // pinned before P1b briefly set it to `[]`. It stays a POSITIVE pin, not a blessing:
        // the affordance is deliberate (tap-to-call and tappable bare URLs in a phone mail
        // client), so a silent change in EITHER direction fails here.
        // ⚠️ Blocker B2 is still TRUE, and enabling detectors does not make it false: they
        // synthesize taps OUTSIDE the navigation delegate, so no permit state machine — and no
        // delegate-level test, including this file — can observe them. While this value is
        // non-empty, "every externally dispatched target passes our http/https allowlist" is
        // FALSE; it is a documented exception, registered as IOS-UI-002 in KNOWN_ISSUES.md.
        // Authored <a href> links are unaffected either way: they are WKNavigationActions and
        // still reach decidePolicyFor. Detectors govern only plain-text numbers and bare URLs.
        // ⚠️ It is not the only exception any more — link preview below is the second (IOS-UI-003).
        #expect(cfg.dataDetectorTypes == [.link, .phoneNumber],
                "detectors are deliberately ON (owner, 2026-08-12): tap-to-call and tappable bare URLs. They dispatch OUTSIDE decidePolicyFor, so the http/https allowlist has a documented exception (IOS-UI-002) and is NOT an absolute")

        // RE-INVERTED 2026-08-12 by owner directive, back to the WebKit default this pinned
        // before P1b briefly set it to `false`. It stays a POSITIVE pin, not a blessing: the
        // affordance is deliberate, so a silent change in EITHER direction fails here.
        // ⚠️ The security fact is unchanged: long-press preview FETCHES and PRESENTS the remote
        // URL with no decidePolicyFor decision we ever see, so it is a SECOND non-delegate route
        // out of the render view and a SECOND exception to "every externally dispatched target
        // passes our http/https allowlist" — data detectors above are the first. No
        // delegate-level test, including this one, can observe either route.
        #expect(hostedAsset.webView.allowsLinkPreview == true,
                "link preview is deliberately ON (owner, 2026-08-12): the unset WebKit default that v1.7.8 shipped. It is a non-delegate fetch route, so the http/https allowlist carries a SECOND documented exception (IOS-UI-003) alongside the detector one (IOS-UI-002)")

        // RE-INVERTED 2026-08-12 by owner directive, back to the shipped default store. T5 is
        // therefore OPEN and accepted: ONE process-wide PERSISTENT jar shared across every
        // message and every sender, surviving launches, reachable by remote subresources alone
        // with no sender script. This pin is POSITIVE so the open exposure stays measured, and so
        // a silent re-hardening is caught too — it must be an owner decision either way.
        #expect(cfg.websiteDataStore.isPersistent == true,
                "the render web view deliberately uses the DEFAULT PERSISTENT data store (owner, 2026-08-12), so T5 — one cookie jar shared across every message and sender — is OPEN and accepted (IOS-PRIVACY-001). Do NOT describe this path as isolated")

        // C3/C4/C5: the scheme handler is registered exactly when an OWNERSHIP KEY is
        // present. P1d moved the predicate off `headerId` — the handler now authorizes
        // every asset against the body's `MessageBody.id`, so a call site that cannot
        // supply one gets no handler at all rather than an unrestricted lookup.
        #expect(cfg.urlSchemeHandler(forURLScheme: BodyAssetConfig.urlScheme) != nil,
                "bodyContentKey != nil must register BodyAssetSchemeHandler")

        let scripts = cfg.userContentController.userScripts
        #expect(!scripts.isEmpty, "the app injects user scripts; they must survive P1b's JS gate")
        #expect(scripts.first?.injectionTime == .atDocumentStart)
        #expect(scripts.first?.source.contains("window.__tmConsumeUserDisclosure = function()") == true,
                "the fail-soft height bridge bootstrap must not depend on quote parsing")
        print("[P1A] production userScripts.count=\(scripts.count) " +
              "dataDetectorTypes=\(cfg.dataDetectorTypes.rawValue) " +
              "contentJS=\(cfg.defaultWebpagePreferences.allowsContentJavaScript) " +
              "persistentStore=\(cfg.websiteDataStore.isPersistent) " +
              "linkPreview=\(hostedAsset.webView.allowsLinkPreview)")

        guard let hostedNil = await HostedRenderView(html: "<p>config probe</p>", headerId: nil) else {
            #expect(Bool(false), "could not host the headerId == nil variant"); return
        }
        defer { hostedNil.tearDown() }
        #expect(hostedNil.webView.configuration.urlSchemeHandler(forURLScheme: BodyAssetConfig.urlScheme) == nil,
                "bodyContentKey == nil must NOT register the scheme handler — C5's explicit 'local assets are unavailable' choice, taken by compose quote and .eml preview")

        // RE-INVERTED 2026-08-12 by owner directive. `isPersistent` alone does not measure T5 —
        // a per-view ephemeral store and one shared ephemeral singleton both report `false`, and
        // identity is what distinguishes them. So the sharing is pinned DIRECTLY, in the
        // direction the owner chose: every render view resolves to the SAME
        // `WKWebsiteDataStore.default()` instance, which is exactly the cross-message,
        // cross-sender correlation channel T5 names. Asserted positively so the exposure stays
        // measured rather than assumed, and so a silent change back is caught.
        #expect(hostedNil.webView.configuration.websiteDataStore.isPersistent == true,
                "the headerId == nil (compose / .eml) path also uses the default PERSISTENT store")
        #expect(hostedAsset.webView.configuration.websiteDataStore
                === hostedNil.webView.configuration.websiteDataStore,
                "T5 is OPEN by owner decision (IOS-PRIVACY-001): two render views SHARE one process-wide data store instance. This is the shipped v1.7.8 behaviour, deliberately restored")
    }

    // -------------------------------------------------------------------------------
    // 2. Script execution — author vs app.
    // -------------------------------------------------------------------------------
    @Test("Canary: an author inline script does NOT execute, and the app's user scripts still do")
    func authorScriptExecutesToday() async {
        let body = """
        <script>window.__tmCanaryAuthorRan = true;
        document.documentElement.setAttribute('data-author','yes');</script>
        <p onclick="window.__tmCanaryHandlerRan = true">author script probe</p>
        <a id="jsurl" href="javascript:window.__tmCanaryJsUrlRan = true">js url</a>
        """
        guard let host = await HostedRenderView(html: body, headerId: "canary-author-script") else {
            #expect(Bool(false), "could not host AutoSizingHTMLView"); return
        }
        defer { host.tearDown() }
        let wv = host.webView
        try? await Task.sleep(for: .seconds(3))

        let authorRan = await CanaryKit.eval(wv, "String(window.__tmCanaryAuthorRan)")
        let authorDOM = await CanaryKit.eval(wv, "String(document.documentElement.getAttribute('data-author'))")
        // ⚠️ P3 CHANGED WHICH WORLD THIS QUESTION IS ASKED OF, and the change is the point.
        // Until P3 this read `CanaryKit.eval(wv, "typeof window.__tmReportHeight")` — the
        // PAGE world — and expected `"function"`. That probe is now the exact opposite
        // measurement: our scripts live in `RenderContentWorld.isolated`, so a page-world
        // `"undefined"` is the SECURITY PROPERTY P3 buys, not a regression. The
        // "did the app's script run" oracle moved to the isolated world. Read both.
        let appScript = await CanaryKit.eval(wv, "typeof window.__tmReportHeight",
                                             in: RenderContentWorld.isolated)
        let appScriptFromPageWorld = await CanaryKit.eval(wv, "typeof window.__tmReportHeight")
        print("[P1A] authorRan=\(authorRan) authorDOM=\(authorDOM) appScript=\(appScript) "
              + "appScriptFromPageWorld=\(appScriptFromPageWorld)")

        // INVERTED AT P1b (was `== "true"` / `== "yes"`).
        #expect(authorRan == "undefined",
                "P1b: the author's inline <script> does not run")
        #expect(authorDOM == "null",
                "P1b: the author's script produced no DOM mutation")

        // The other two author-script surfaces the same gate closes. Driven from an
        // app-side evaluateJavaScript so the click itself is not author script — what is
        // measured is whether WebKit runs the AUTHOR-supplied handler / URL body.
        _ = await CanaryKit.eval(wv, "document.querySelector('p[onclick]').click(); 'clicked'")
        _ = await CanaryKit.eval(wv, "document.getElementById('jsurl').click(); 'clicked'")
        try? await Task.sleep(for: .milliseconds(500))
        #expect(await CanaryKit.eval(wv, "String(window.__tmCanaryHandlerRan)") == "undefined",
                "P1b: an inline event-handler attribute does not run")
        #expect(await CanaryKit.eval(wv, "String(window.__tmCanaryJsUrlRan)") == "undefined",
                "P1b: a javascript: URL does not run")

        // MUST NOT invert: the hardening depends on app user scripts still running.
        // This is the HARD-STOP oracle named in the P1b brief — if it fails, the phase is
        // wrong, not the test. P3 re-aimed it at the isolated world; what it asserts is
        // unchanged, because the question is unchanged.
        #expect(appScript == "function",
                "the app's WKUserScript must execute (height reporting); P1b must not break this, and P3's world migration must not either")
        // P3, the other side of the same fact — and the one that makes the phase worth
        // shipping. `__tmReportHeight` is our bridge into Swift; a document that can read
        // it can read our render state, and a document that can WRITE it can forge heights.
        // It must not exist in the document's world at all.
        #expect(appScriptFromPageWorld == "undefined",
                "P3: the DOCUMENT's world must NOT see the app's render state — __tmReportHeight is defined only in RenderContentWorld.isolated")
        #expect(await CanaryKit.eval(wv, "1 + 1") == "2",
                "app-side evaluateJavaScript still works with the gate closed")

        // INVERTED AT P1b (was `== "upgrade-insecure-requests"`). Compared against the
        // stored constant, not a literal: the document must carry the policy the app
        // believes it shipped, and a re-typed literal here could only ever agree with
        // itself.
        let csp = await CanaryKit.eval(wv,
            "String((document.querySelector('meta[http-equiv=\"Content-Security-Policy\"]')||{}).content)")
        #expect(csp == EmailHTMLWrapper.contentSecurityPolicy,
                "the rendered document carries EmailHTMLWrapper.contentSecurityPolicy verbatim")
        print("[P1A] rendered csp=\(csp)")
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
        // ⚠️ CHANGED AT P1b — this document is deliberately NOT run through
        // `EmailHTMLWrapper.wrapHTML`. P1b's `frame-src 'none'` blocks a wrapped
        // document's iframe before WebKit ever asks the delegate about it (asserted in
        // `shippedCSPBlocksSubframesAndPlugins` below), which is the intended outcome —
        // but C2 still needs the SUBFRAME CALLBACK SHAPE on record, and that shape only
        // exists where the policy is not in force. So the shape is measured on a raw
        // document and the policy is measured on a wrapped one; deleting either half
        // loses a fact P1c is built from.
        let doc = """
        <!DOCTYPE html><html><head>
        <meta name="viewport" content="width=device-width, initial-scale=1">
        </head><body>
        <iframe id="f" src="\(BodyAssetConfig.urlScheme)://asset/sub-frame.html" width="100" height="50"></iframe>
        <a id="blanklnk" href="\(BodyAssetConfig.urlScheme)://asset/blank-target" target="_blank">new window</a>
        </body></html>
        """
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
        // INVERTED AT P1c (was `== BodyAssetConfig.baseURL.absoluteString`, "recovery
        // re-derives the base URL from the retained headerId"). The recovery load is now
        // an ordinary load: it mints a FRESH per-load nonce base URL like every other one,
        // and the fixed base URL it used to re-derive is exactly the forgeable shape C1
        // replaced.
        #expect(probe.policyEvents.first?.url?
                    .hasPrefix("\(BodyAssetConfig.urlScheme)://asset/\(RenderDocumentURL.pathPrefix)/") == true,
                "P1c: the recovery reload carries its own nonce base URL")
        #expect(probe.policyEvents.first?.url != BodyAssetConfig.baseURL.absoluteString,
                "P1c: and it is NOT the fixed base URL a message document could name")
        // ⚠️ NOT INVERTED AT P1c, and the reason matters. This assertion never observed
        // the app at all: `NavProbe.labels` is the TEST's map, populated only by
        // `probe.label(nav, …)` on a navigation the test itself started. An app-initiated
        // load is unlabelled from here whether or not `Coordinator.wrapAndLoad` keeps the
        // `WKNavigation` it returns — which it now does (P1c), so the old failure message
        // would have been a false statement about shipped code. What the probe can still
        // say is that the recovery load produced exactly one navigation's worth of
        // callbacks, asserted by the `order` expectation above.
        #expect(probe.events.allSatisfy { $0.navLabel == nil || $0.navLabel == "UNLABELLED" },
                "an app-initiated load carries no TEST-side label; this says nothing about the app's own correlation")
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

    // -------------------------------------------------------------------------------
    // 11. P1b — the shipped Content Security Policy.
    // -------------------------------------------------------------------------------

    @Test("P1b: wrapHTML emits one complete document with the app CSP in <head> before any author element")
    func cspIsUnconditionalAndPrecedesAuthorContent() {
        // The invariant, stated in `EmailHTMLWrapper.contentSecurityPolicy`'s doc comment
        // and checked here: `wrapHTML` MUST always emit ONE complete document with the app
        // CSP in <head> before any author-controlled element, and no caller may load raw
        // message HTML. A meta CSP only governs what follows it, so "the policy is in the
        // document" is not the property that matters — "the policy precedes the content"
        // is. The production caller's half is covered end-to-end by
        // `authorScriptExecutesToday`, which reads the policy back out of a REAL render.
        let marker = "tm-author-marker"
        let cases: [(String, String)] = [
            ("fragment", "<p id=\"\(marker)\">fragment body</p>"),
            ("full document",
             "<!DOCTYPE html><html><head><style>p{color:red}</style></head>"
             + "<body><p id=\"\(marker)\">full document body</p></body></html>"),
            ("author supplies its own CSP",
             "<!DOCTYPE html><html><head>"
             + "<meta http-equiv=\"Content-Security-Policy\" content=\"img-src *; script-src *\">"
             + "</head><body><p id=\"\(marker)\">author tried to set a policy</p></body></html>")
        ]
        for (label, input) in cases {
            for preview in [nil, "attached.eml"] as [String?] {
                let tag = "\(label) / preview=\(preview ?? "nil")"
                let out = EmailHTMLWrapper.wrapHTML(input, previewFilename: preview)
                #expect(out.hasPrefix("<!DOCTYPE html>"),
                        "\(tag): wrapHTML emits a COMPLETE document, never a bare fragment")

                let appMeta = "<meta http-equiv=\"Content-Security-Policy\" content=\"\(EmailHTMLWrapper.contentSecurityPolicy)\">"
                guard let cspRange = out.range(of: appMeta) else {
                    #expect(Bool(false), "\(tag): the app CSP meta tag is missing from the output"); continue
                }
                guard let headEnd = out.range(of: "</head>"), let bodyOpen = out.range(of: "<body") else {
                    #expect(Bool(false), "\(tag): no <head>…</head><body> structure"); continue
                }
                #expect(cspRange.upperBound <= headEnd.lowerBound, "\(tag): the CSP sits inside <head>")
                #expect(cspRange.upperBound <= bodyOpen.lowerBound, "\(tag): the CSP precedes <body>")

                guard let author = out.range(of: marker) else {
                    // If the marker did not survive the wrap, every ordering assertion
                    // above is comparing against nothing.
                    #expect(Bool(false), "\(tag): the author marker must survive into the output or this case is vacuous")
                    continue
                }
                #expect(cspRange.upperBound <= author.lowerBound,
                        "\(tag): the CSP precedes every author-controlled element")

                guard let firstPolicy = out.range(of: "Content-Security-Policy") else {
                    #expect(Bool(false), "\(tag): unreachable — the app meta was already found"); continue
                }
                #expect(cspRange.lowerBound <= firstPolicy.lowerBound && firstPolicy.upperBound <= cspRange.upperBound,
                        "\(tag): the APP's policy is the FIRST Content-Security-Policy in the document — an author meta arriving later can only add restrictions, never relax ours")
            }
        }
    }

    @Test("P1b: the shipped CSP is exactly the ADR-IOS-076 policy, backstop first, no header-only directives")
    func cspDirectiveCensus() {
        let raw = EmailHTMLWrapper.contentSecurityPolicy
        let directives = raw.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
        let expected = [
            "default-src 'none'",
            "script-src 'none'",
            "style-src 'unsafe-inline'",
            "img-src https: data: \(BodyAssetConfig.urlScheme):",
            "font-src https:",
            "media-src 'none'",
            "object-src 'none'",
            "frame-src 'none'",
            "connect-src 'none'",
            "form-action 'none'",
            "base-uri 'none'",
            "upgrade-insecure-requests"
        ]
        #expect(directives == expected,
                "the policy is ADR-IOS-076 decision 1, in order, as amended 2026-08-12 by the owner-directed font-src relaxation")
        guard directives.count == expected.count else { return }

        // OWNER-DIRECTED, 2026-08-12 — pinned POSITIVELY and in BOTH directions, because this
        // value REVERSES a P1b hardening and either drift is a defect:
        //   * back to 'none'   => a silent behaviour regression. It broke sender typography on
        //     a runtime smoke test: an HTTPS web font was refused and the message then rendered in
        //     a fallback font.
        //   * out to * or data: => a silent widening past what was actually directed.
        #expect(directives.contains("font-src https:"),
                "font-src is `https:` BY OWNER DIRECTIVE (2026-08-12), mirroring img-src's TLS-only posture. The font leg of T9 is OPEN and owner-accepted (IOS-PRIVACY-002). Do not restore 'none' — that is a behaviour regression, not a hardening — and do not widen to * or add data:.")
        #expect(!raw.contains("font-src 'none'"),
                "font-src 'none' was REVERSED by owner directive on 2026-08-12 after a device smoke test measured it blocking real web fonts; restoring it needs the owner, not a reviewer")
        #expect(directives.contains("media-src 'none'"),
                "media-src 'none' was deliberately RETAINED in the same owner directive — the smoke test recorded zero media-src violations, so it costs nothing observed and must not be relaxed alongside font-src")

        #expect(directives.first == "default-src 'none'",
                "default-src 'none' is the BACKSTOP — every later directive is a deliberate widening of it, and an allowlist without it leaves every unlisted class permitted")

        let names = directives.map { String($0.split(separator: " ").first ?? "") }
        #expect(Set(names).count == names.count,
                "no directive is declared twice — a duplicate is ignored, silently")

        // Header-only directives are SILENTLY IGNORED in a <meta> CSP (ADR-IOS-076
        // decision 8). Present here they would read as coverage that does not exist.
        for headerOnly in ["frame-ancestors", "sandbox", "report-uri", "report-to"] {
            #expect(!names.contains(headerOnly),
                    "\(headerOnly) is header-only and is ignored in a meta CSP; it must not appear here")
        }

        // WITHDRAWN in the round-1 vet, verified: `BodyRenderer` replaces every resolvable
        // cid: with a tabmail-asset:// URL or a base64 data: URI, and no cid: scheme
        // handler is registered — so a leftover cid: is by definition unresolvable and
        // cannot load whatever the policy says. Listing it would be harmless but not
        // load-bearing, and the reasoning originally given for it was false.
        #expect(!raw.contains("cid:"), "cid: is deliberately absent from img-src")

        // http: is absent because upgrade-insecure-requests rewrites the request before
        // CSP enforcement. Measured in `httpImageHandlingIsUnchangedByP1b`, not assumed.
        #expect(!raw.contains(" http:"), "http: is deliberately absent from img-src")
    }

    @Test("P1b: the shipped CSP blocks a subframe and an <object>, while asset images still load")
    func shippedCSPBlocksSubframesAndPlugins() async {
        let handler = RecordingSchemeHandler()
        let cfg = WKWebViewConfiguration()
        cfg.defaultWebpagePreferences.allowsContentJavaScript = false   // production shape
        cfg.setURLSchemeHandler(handler, forURLScheme: BodyAssetConfig.urlScheme)
        let ucc = WKUserContentController()
        ucc.addUserScript(CanaryKit.violationRecorder())
        cfg.userContentController = ucc

        let probe = NavProbe()
        let wv = CanaryKit.probeWebView(cfg, probe)
        let scheme = BodyAssetConfig.urlScheme
        let doc = EmailHTMLWrapper.wrapHTML("""
        <iframe id="f" src="\(scheme)://asset/blocked-frame.html" width="100" height="50"></iframe>
        <object id="o" data="\(scheme)://asset/blocked-object.bin"></object>
        <img id="ok" src="\(scheme)://asset/allowed-pixel.gif" width="10" height="10">
        """)
        _ = wv.loadHTMLString(doc, baseURL: CanaryKit.nonceBase(CanaryKit.nonce()))
        await CanaryKit.waitForFinish(probe)
        try? await Task.sleep(for: .seconds(3))

        let asked = handler.urls
        let reported = await CanaryKit.violations(wv)
        print("[P1B] CSP-BLOCK handler.urls=\(asked)\n[P1B] CSP-BLOCK violations=\(reported)")

        // POSITIVE CONTROL FIRST. Without it the two negatives below are vacuous — they
        // would hold just as well if the scheme handler had never been wired up.
        #expect(asked.contains { $0.hasSuffix("allowed-pixel.gif") },
                "img-src permits tabmail-asset: — the handler IS reached for images")
        #expect(await CanaryKit.eval(wv, "String(document.getElementById('ok').naturalWidth)") == "1",
                "and the asset image actually decoded")

        #expect(!asked.contains { $0.hasSuffix("blocked-frame.html") },
                "frame-src 'none': the iframe never reaches the network layer")
        #expect(!asked.contains { $0.hasSuffix("blocked-object.bin") },
                "object-src 'none': the <object> never reaches the network layer")
        #expect(reported.contains { $0.hasPrefix("frame-src") },
                "the document reports the frame-src violation")
    }

    @Test("P1b: http: image handling is UNCHANGED from the pre-P1b policy")
    func httpImageHandlingIsUnchangedByP1b() async {
        // The pre-P1b policy was `upgrade-insecure-requests` AND NOTHING ELSE, so any
        // change in how a plain-http image is treated would be P1b's doing. Measured as a
        // DIFFERENCE between the two policies rather than argued from the Fetch spec's
        // ordering (upgrade at main-fetch step 4, CSP enforcement at step 5) — the
        // spec-reading is exactly the kind of claim this canary exists to replace.
        //
        // 127.0.0.1:1 — no external traffic, no DNS, no real-world domain, fails fast.
        func measure(_ policy: String) async -> (violations: [String], asked: [String]) {
            let handler = RecordingSchemeHandler()
            let cfg = WKWebViewConfiguration()
            cfg.defaultWebpagePreferences.allowsContentJavaScript = false
            cfg.setURLSchemeHandler(handler, forURLScheme: BodyAssetConfig.urlScheme)
            let ucc = WKUserContentController()
            ucc.addUserScript(CanaryKit.violationRecorder())
            cfg.userContentController = ucc
            let probe = NavProbe()
            let wv = CanaryKit.probeWebView(cfg, probe)
            // Hand-built, NOT wrapHTML: the point is to vary the policy, and wrapHTML
            // always emits the shipped one (which is the invariant the sibling test pins).
            let doc = """
            <!DOCTYPE html><html><head>
            <meta http-equiv="Content-Security-Policy" content="\(policy)">
            </head><body>
            <img id="http" src="http://127.0.0.1:1/tm-canary-http.gif" width="10" height="10">
            <iframe id="frame" src="\(BodyAssetConfig.urlScheme)://asset/diff-frame.html" width="50" height="20"></iframe>
            </body></html>
            """
            _ = wv.loadHTMLString(doc, baseURL: CanaryKit.nonceBase(CanaryKit.nonce()))
            await CanaryKit.waitForFinish(probe)
            try? await Task.sleep(for: .seconds(3))
            return (await CanaryKit.violations(wv), handler.urls)
        }

        let legacy = await measure("upgrade-insecure-requests")
        let shipped = await measure(EmailHTMLWrapper.contentSecurityPolicy)
        print("[P1B] LEGACY  violations=\(legacy.violations) asked=\(legacy.asked)")
        print("[P1B] SHIPPED violations=\(shipped.violations) asked=\(shipped.asked)")

        let httpOnly: ([String]) -> [String] = { $0.filter { $0.contains("127.0.0.1") }.sorted() }
        #expect(httpOnly(legacy.violations) == httpOnly(shipped.violations),
                "P1b did not change how a plain-http image is treated — upgrade-insecure-requests was already the ENTIRE pre-P1b policy and still runs ahead of CSP enforcement")

        // NON-VACUITY, two-sided: the same harness must record a DIFFERENCE exactly where
        // P1b intends one. Without this leg, two empty violation lists would "agree".
        #expect(legacy.asked.contains { $0.hasSuffix("diff-frame.html") },
                "under the pre-P1b policy the subframe DID reach the network layer")
        #expect(!shipped.asked.contains { $0.hasSuffix("diff-frame.html") },
                "under the shipped policy frame-src 'none' stops it — so both the harness and the recorder are live")
    }

    @Test("P1b: a benign real-world-shaped email still renders — quote collapse, tables, inline image, live bridge")
    func benignEmailRendersUnderTheShippedPolicy() async {
        // 1×1 transparent GIF as a data: URI — the inline-image shape BodyRenderer
        // produces for a small cid: part.
        let pixel = "data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7"
        let headerId = "canary-benign-\(CanaryKit.nonce())"
        let body = """
        <div>Hi — confirming the numbers below.</div>
        <table role="presentation" width="100%" cellpadding="0" cellspacing="0">
          <tr><td style="padding:8px">Item</td><td style="padding:8px">Qty</td></tr>
          <tr><td style="padding:8px">Widget</td><td style="padding:8px">2</td></tr>
        </table>
        <img id="inline" src="\(pixel)" width="1" height="1">
        <div>-----Original Message-----</div>
        <div>From: Someone &lt;someone@example.com&gt;</div>
        <div>Subject: Re: numbers</div>
        <div>Original text that should end up inside the collapsed quote.</div>
        """
        guard let host = await HostedRenderView(html: body, headerId: headerId) else {
            #expect(Bool(false), "could not host AutoSizingHTMLView"); return
        }
        defer { host.tearDown() }
        let wv = host.webView
        try? await Task.sleep(for: .seconds(4))

        #expect(await CanaryKit.eval(wv, "String(document.getElementById('inline').naturalWidth)") == "1",
                "img-src's data: source: an inline image still decodes under the shipped policy")
        #expect(await CanaryKit.eval(wv, "String(document.querySelectorAll('.tm-quote-wrapper').length)") == "1",
                "collapseQuotesJS (a WKUserScript) still transforms the DOM under the shipped policy")
        #expect(await CanaryKit.eval(wv, "String(document.querySelectorAll('table').length)") == "1",
                "the table layout survives")

        // BRIDGE LIVENESS, end to end, WITHOUT trusting a JS-side self-report: a
        // HeightSeedCache entry is only ever written from the NUMERIC branch of
        // `Coordinator.handleHeightMessage`, so its presence proves the whole chain —
        // user script → ResizeObserver → postMessage → WKScriptMessageHandler → applied
        // height. This is the same fact the Swift-side liveness beacon reports in the
        // log; asserting it here makes the P1b brief's HARD STOP machine-checked instead
        // of eyeballed.
        let seeded = await CanaryKit.waitUntil(10) {
            (AutoSizingHTMLView.seededHeight(headerId: headerId) ?? 0) > 1
        }
        #expect(seeded, "the app's height bridge delivered a real measurement for this message")
        print("[P1B] benign render seededHeight=\(String(describing: AutoSizingHTMLView.seededHeight(headerId: headerId)))")
    }

    // -------------------------------------------------------------------------------
    // 12. P1c — the navigation permit, measured end to end against the REAL Coordinator.
    //
    // The unit-level enumeration of action shapes lives in `RenderNavigationPolicyTests`
    // (the `Coordinator` is nested in a `private struct` and cannot be reached from a
    // test). What only this harness can do is fire a real `<meta http-equiv="refresh">`
    // from a real message body at the real delegate, which is the vector the permit
    // exists for and the one P1b explicitly did NOT close.
    // -------------------------------------------------------------------------------

    @Test("P1c: a meta refresh no longer navigates the main frame — the forged .other action is REFUSED")
    func metaRefreshIsRefusedByTheProductionCoordinator() async {
        // Same document as `metaRefreshForgesAnAppLoadShape`, but pointed at the
        // PRODUCTION coordinator instead of an allow-everything probe. That test still
        // passes and still asserts the forged action is delivered and shape-identical to
        // an app load; this one asserts the app now REFUSES it. Both halves are needed:
        // the threat is only interesting because the shape is indistinguishable.
        //
        // ⚠️ THE DECISION IS ASSERTED, NOT ITS SIDE EFFECT — and that distinction was
        // caught by running this test against a deliberately inverted gate. Asserting only
        // that `location.href` did not become the forged URL BLESSES THE BUG: the forged
        // target is a `tabmail-asset://` URL, `BodyAssetSchemeHandler` fails it (its host
        // is not a 16-char hash), and a navigation that is ALLOWED and then fails to load
        // leaves `location.href` exactly where a refused one does. The inverted build
        // passed that version of the test. So the probe records the coordinator's own
        // `.allow`/`.cancel` and the refusal is read off that.
        let forged = "\(BodyAssetConfig.urlScheme)://asset/forged-target-p1c.html"
        // 3 seconds, so the probe can be installed on the REAL coordinator before the
        // refresh fires — a 0-second refresh races the initial load.
        let body = """
        <meta http-equiv="refresh" content="3;url=\(forged)">
        <p id="p1c">meta refresh probe</p>
        """
        guard let host = await HostedRenderView(html: body, headerId: "canary-p1c-metarefresh") else {
            #expect(Bool(false), "could not host AutoSizingHTMLView"); return
        }
        defer { host.tearDown() }
        let wv = host.webView
        try? await Task.sleep(for: .milliseconds(800))

        let coordinator = wv.navigationDelegate
        #expect(coordinator != nil, "the production view installs a navigation delegate")
        let probe = NavProbe()
        probe.forward = coordinator          // observe the REAL coordinator, do not replace it
        wv.navigationDelegate = probe
        defer { wv.navigationDelegate = coordinator }

        try? await Task.sleep(for: .seconds(6))
        print("[P1C] META-REFRESH trace:\n\(probe.trace)")

        // NON-VACUITY: the forged action must actually have been DELIVERED. Without this
        // leg, "no allowed forged navigation" would hold just as well on a build where the
        // meta refresh never fired at all.
        let forgedEvents = probe.policyEvents.filter { $0.url == forged }
        #expect(!forgedEvents.isEmpty,
                "the meta refresh still fires with JavaScript disabled — P1b did not close this")
        #expect(forgedEvents.allSatisfy { $0.navType == .other && $0.target == .main },
                "and it is still SHAPE-IDENTICAL to an app load: .other on the main frame")
        #expect(forgedEvents.allSatisfy { $0.detail.hasSuffix("→ cancel") },
                "THE INVARIANT: no unapproved new main-frame document is admitted — the production coordinator refuses it")

        let href = await CanaryKit.eval(wv, "location.href")
        print("[P1C] META-REFRESH href=\(href)")
        #expect(href.hasPrefix("\(BodyAssetConfig.urlScheme)://asset/\(RenderDocumentURL.pathPrefix)/"),
                "the document on screen is still the one the app loaded, under its own per-load nonce")

        // NEGATIVE CONTROL, and it is the load-bearing half: default-deny must not deny
        // the app's own load. If this fails the phase is wrong, not the test.
        #expect(await CanaryKit.eval(wv, "String((document.getElementById('p1c')||{}).textContent)")
                == "meta refresh probe",
                "the legitimate app load WAS admitted and its body rendered")
    }

    @Test("P1c: every call site loads under a per-load nonce base URL, including headerId == nil")
    func everyCallSiteLoadsUnderANonceBaseURL() async {
        // C1 as AMENDED by P1a case D: unconditional, at every call site, whether or not a
        // scheme handler is registered. Under `baseURL: nil` the action arrived as
        // `about:blank` with a `null` origin, so the permit was not weak there — it was
        // inexpressible. This also discharges the phase's HARD STOP: the `headerId == nil`
        // sites (compose quote, `.eml` preview, tooltip) must still RENDER.
        var seenNonceURLs: [String] = []
        for (label, headerId) in [("persisted", "canary-p1c-base"), ("nil-header", nil)] as [(String, String?)] {
            guard let host = await HostedRenderView(html: "<p id=\"m\">\(label) marker</p>",
                                                    headerId: headerId) else {
                #expect(Bool(false), "could not host the \(label) variant"); continue
            }
            defer { host.tearDown() }
            let wv = host.webView
            try? await Task.sleep(for: .seconds(3))

            let baseURI = await CanaryKit.eval(wv, "document.baseURI")
            let origin = await CanaryKit.eval(wv, "String(window.origin)")
            print("[P1C] \(label) baseURI=\(baseURI) origin=\(origin)")
            #expect(baseURI.hasPrefix("\(BodyAssetConfig.urlScheme)://asset/\(RenderDocumentURL.pathPrefix)/"),
                    "\(label): loaded under a nonce base URL")
            #expect(baseURI != BodyAssetConfig.baseURL.absoluteString,
                    "\(label): NOT the fixed base URL a document can name")
            #expect(origin == "\(BodyAssetConfig.urlScheme)://asset",
                    "\(label): the nonce is in the PATH, so the origin is unchanged")
            #expect(await CanaryKit.eval(wv, "String((document.getElementById('m')||{}).textContent)")
                    == "\(label) marker",
                    "\(label): the message still renders — the nonce base URL breaks no call site")
            seenNonceURLs.append(baseURI)
        }
        #expect(seenNonceURLs.count == 2)
        guard seenNonceURLs.count == 2 else { return }
        #expect(seenNonceURLs[0] != seenNonceURLs[1], "each load mints its own nonce")
    }

    @Test("P1c: an in-document fragment click still works and does not replace the document")
    func inDocumentFragmentStillWorks() async {
        // The non-security defect P1a found alongside the allowlist: every `.linkActivated`
        // was cancelled and handed to `UIApplication.shared.open`, so an in-document
        // `#anchor` reached the SYSTEM OPENER as a `tabmail-asset://` URL. The allowlist
        // half is enumerated in `RenderLinkPolicyTests`; what is asserted here is the
        // user-visible half — the anchor still behaves like an anchor.
        let body = """
        <a id="lnk" href="#target">jump</a>
        <div style="height:2000px"></div>
        <div id="target">target</div>
        """
        guard let host = await HostedRenderView(html: body, headerId: "canary-p1c-fragment") else {
            #expect(Bool(false), "could not host AutoSizingHTMLView"); return
        }
        defer { host.tearDown() }
        let wv = host.webView
        try? await Task.sleep(for: .seconds(3))

        let before = await CanaryKit.eval(wv, "location.href")
        _ = await CanaryKit.eval(wv, "document.getElementById('lnk').click(); 'clicked'")
        try? await Task.sleep(for: .seconds(1))
        let after = await CanaryKit.eval(wv, "location.href")
        print("[P1C] FRAGMENT before=\(before) after=\(after)")

        #expect(after == before + "#target",
                "the same-document jump still happens — P1a measured that .cancel does not prevent it")
        #expect(await CanaryKit.eval(wv, "String((document.getElementById('lnk')||{}).id)") == "lnk",
                "and the document was NOT replaced")
    }
}

// =====================================================================================
// 13. P1d — view identity includes the body ContentKey (plan §10.1 C4).
//
// THE INVARIANT: *a web view built to serve message A's assets is never reused to render
// message B's document.*
//
// A `WKURLSchemeHandler` is installed ONCE on the configuration, inside `makeUIView`;
// `updateUIView` cannot replace it. SwiftUI may reuse the platform view across an update
// in which the body ContentKey changes (row identity is `stableId`), so a handler bound
// at construction goes stale in BOTH directions — legitimate assets denied for the new
// document, and an old asset servable to a new document that names its id. Asset ids are
// not secrets, so this is measured rather than argued.
// =====================================================================================

@MainActor
@Suite("P1d view identity — the web view is recreated when the body ContentKey changes", .serialized, .processGlobalState)
struct RenderViewIdentityTests {

    /// Hosts `AutoSizingHTMLView` with a mutable root so the test can rebind it the way
    /// SwiftUI rebinds a recycled `List` row.
    private func host(html: String, key: ContentKey?) -> (UIWindow, UIHostingController<AnyView>)? {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).first else {
            print("[P1D] NO UIWindowScene in the test host — cannot host SwiftUI")
            return nil
        }
        let hc = UIHostingController(rootView: Self.root(html: html, key: key))
        let w = UIWindow(windowScene: scene)
        w.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        w.rootViewController = hc
        w.isHidden = false
        w.makeKeyAndVisible()
        w.layoutIfNeeded()
        return (w, hc)
    }

    private static func root(html: String, key: ContentKey?) -> AnyView {
        AnyView(VStack(spacing: 0) {
            AutoSizingHTMLView(html: html, headerId: key?.rawValue, bodyContentKey: key)
            Spacer()
        })
    }

    @Test("A body ContentKey change recreates the WKWebView; an html change does NOT")
    func contentKeyChangeRecreatesTheWebView() async {
        let keyA = ContentKey(rawValue: "acct-1:INBOX:5001")
        let keyB = ContentKey(rawValue: "acct-1:Archive:5001")
        guard let (window, hc) = host(html: "<p>message A</p>", key: keyA) else {
            #expect(Bool(false), "could not host AutoSizingHTMLView"); return
        }
        defer { window.isHidden = true; window.rootViewController = nil }

        var first: WKWebView?
        _ = await CanaryKit.waitUntil(10) {
            window.layoutIfNeeded()
            first = HostedRenderView.findWebView(window)
            return first != nil && first!.bounds.width > 50
        }
        guard let original = first else {
            #expect(Bool(false), "no WKWebView appeared for the first document"); return
        }

        // NON-VACUITY FIRST, and it is the half that would silently pass if `.id(…)` were
        // attached to something that changes on every update: a NEW DOCUMENT under the
        // SAME key must REUSE the platform view. Recreating per document would be the
        // rejected alternative (view churn on the appearance and process-recovery paths).
        hc.rootView = Self.root(html: "<p>message A, edited</p>", key: keyA)
        window.layoutIfNeeded()
        try? await Task.sleep(for: .milliseconds(500))
        window.layoutIfNeeded()
        #expect(HostedRenderView.findWebView(window) === original,
                "an html change under the same body ContentKey must NOT churn the web view")

        // THE PROPERTY: the key changed — as it does when a move re-keys the row under a
        // row identity that is `stableId` and therefore did not change — so the platform
        // view, and with it the scheme handler bound to the old key, must be replaced.
        hc.rootView = Self.root(html: "<p>message B</p>", key: keyB)
        window.layoutIfNeeded()
        let recreated = await CanaryKit.waitUntil(10) {
            window.layoutIfNeeded()
            let current = HostedRenderView.findWebView(window)
            return current != nil && current !== original
        }
        #expect(recreated,
                "a body ContentKey change must recreate the WKWebView — the scheme handler is installed once in makeUIView and updateUIView cannot replace it")
    }
}

// =====================================================================================
// 13. P3 — `WKContentWorld` isolation and the `frameInfo.isMainFrame` frame gate.
//
// WHAT P3 IS: defense-in-depth, and nothing else. It did NOT enable the CSP — `script-src
// 'none'` shipped in P1b while all 17 user scripts were still in the page world, and every
// one of them ran (§2 measured it). The ordering claim that made this world a prerequisite
// was refuted in the plan and is not re-derived here. What isolation buys is that author
// content can no longer READ or FORGE `__tmReportHeight` and friends, and cannot reach
// `webkit.messageHandlers` at all: a partial mitigation for bridge spoofing (T3).
//
// WHY THESE TESTS ARE BEHAVIOURAL RATHER THAN A CONFIG CENSUS. The obvious test — "assert
// every installed `WKUserScript` names the isolated world" — CANNOT BE WRITTEN: `WKUserScript`
// exposes `source`, `injectionTime` and `isForMainFrameOnly`, but **not** `contentWorld`
// (verified against the SDK header). So the census is proven by consequence instead, on a
// real `WKWebView` running the production configuration. That is the stronger test anyway:
// it fails for a script left behind in the page world AND for a handler or an
// `evaluateJavaScript` call left behind, which a property check would miss.
//
// THE FAILURE MODE THESE GUARD. A world is a NAMESPACE. A half-migrated pipeline is not
// degraded, it is dead: a script writing `window.__tmReportHeight` in one world while the
// caller reads it from another sees a different global object and finds `undefined` — no
// height reporting, no dark mode, no quote collapse, no deferred images. Nothing except a
// real `WKWebView` can observe that, which is exactly why these live here and not in a unit
// suite.
// =====================================================================================

/// Collects `WKScriptMessage`s together with the frame each arrived from.
///
/// Exists because the production `Coordinator` is nested in a `private struct` and no test
/// can reach it (the same constraint that put `RenderBridgeInput` in its own file). This
/// handler is NOT a copy of the production dispatch and does not assert anything about it —
/// its single job is to establish the PLATFORM fact the production gate rests on: that
/// `WKScriptMessage.frameInfo.isMainFrame` actually discriminates main frame from subframe.
/// Without that fact pinned, the production guard could be vacuously always-true and no
/// test would notice.
@MainActor
final class FrameProbeHandler: NSObject, WKScriptMessageHandler {
    private(set) var received: [(body: String, isMainFrame: Bool)] = []

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        received.append((String(describing: message.body), message.frameInfo.isMainFrame))
    }
}

@MainActor
@Suite("P3 content-world isolation — the render pipeline is out of the document's reach", .serialized, .processGlobalState)
struct RenderContentWorldIsolationTests {

    /// Ungated render-state globals. The debug-only ones (`__tmDiagId`,
    /// `__tmImageDiagWillAssign`, `__tmImageDiagInstalled`) are deliberately EXCLUDED: they
    /// are injected only when `DebugModeManager.isLoggingEnabled()`, so asserting they are
    /// absent from the page world would pass for the wrong reason in a build where they were
    /// never injected anywhere. Everything listed here is installed unconditionally.
    static let renderStateGlobals = [
        "__tmReportHeight", "__tmFixImgAspect", "__tmLayoutVp",
        "__tmDeviceWidth", "__tmFitDone", "__tmFitRequested",
        "__tmUserDisclosurePending", "__tmUserDisclosureAnchorTop",
        "__tmArmUserDisclosure", "__tmConsumeUserDisclosure",
    ]

    /// `'reachable'` only where the bridge channel actually exists. Every failure mode
    /// (no `webkit`, no `messageHandlers`, no channel, or a WebKit throw on touching an
    /// unregistered handler) returns its own token rather than throwing, so a page-world
    /// result is diagnosable instead of just "not reachable".
    static let bridgeProbe = """
    (function () {
      try {
        var w = window.webkit;
        if (!w) { return 'no-webkit'; }
        var m = w.messageHandlers;
        if (!m) { return 'no-messageHandlers'; }
        return m.heightChanged ? 'reachable' : 'no-channel';
      } catch (e) { return 'threw'; }
    })()
    """

    // -------------------------------------------------------------------------------
    @Test("P3: the document's world can neither read the app's render state nor reach the bridge, while the pipeline still works end to end")
    func renderStateIsUnreachableFromTheDocumentWorld() async {
        let headerId = "canary-p3-world-\(CanaryKit.nonce())"
        // A quoted body, so the same render that proves isolation also proves the DOM
        // transforms still ran — quote collapse is one of the behaviours a botched world
        // migration would silently kill.
        let body = """
        <div>P3 isolation probe</div>
        <div>-----Original Message-----</div>
        <div>From: Someone &lt;someone@example.com&gt;</div>
        <div>Quoted text that should end up inside the collapsed quote.</div>
        """
        guard let host = await HostedRenderView(html: body, headerId: headerId) else {
            #expect(Bool(false), "could not host AutoSizingHTMLView"); return
        }
        defer { host.tearDown() }
        let wv = host.webView
        try? await Task.sleep(for: .seconds(4))

        // ── Side A: our scripts DID run, and they ran in the isolated world. ──
        // This is the hard-stop half. If it fails, the migration is broken and the phase
        // must be reverted rather than the test relaxed.
        let isolatedReport = await CanaryKit.eval(wv, "typeof window.__tmReportHeight",
                                                  in: RenderContentWorld.isolated)
        let isolatedAspect = await CanaryKit.eval(wv, "typeof window.__tmFixImgAspect",
                                                  in: RenderContentWorld.isolated)
        #expect(isolatedReport == "function",
                "monitorHeightJS must have run IN RenderContentWorld.isolated — if this is undefined the world migration is broken, not the test")
        #expect(isolatedAspect == "function",
                "fixImageAspectRatioJS must have run in the same world as monitorHeightJS — a split world is the P3 failure mode")

        // ── Side B: the document cannot see ANY of it. ──
        // Enumerated rather than sampled: one global left reachable is one the sender can
        // read or forge, and `__tmReportHeight` in particular is the height bridge itself.
        for global in Self.renderStateGlobals {
            let pageWorld = await CanaryKit.eval(wv, "typeof window.\(global)")
            #expect(pageWorld == "undefined",
                    "P3: window.\(global) must NOT exist in the document's world — it is app render state and a sender that can read it can read our layout, while one that can write it can forge a height")
        }

        // ── Side C: the bridge itself. This is what P3 buys beyond hiding globals — ──
        // `add(_:contentWorld:name:)` publishes `webkit.messageHandlers.<name>` ONLY in the
        // named world, so the page world has nothing to post to even if author script ran.
        let bridgeIsolated = await CanaryKit.eval(wv, Self.bridgeProbe, in: RenderContentWorld.isolated)
        let bridgePage = await CanaryKit.eval(wv, Self.bridgeProbe)
        print("[P3] bridge isolated=\(bridgeIsolated) pageWorld=\(bridgePage) "
              + "appScriptIsolated=\(isolatedReport)")
        #expect(bridgeIsolated == "reachable",
                "the heightChanged channel must be reachable from the world our scripts run in")
        #expect(bridgePage != "reachable",
                "P3: the DOCUMENT's world must have no heightChanged channel to post to — that is the half of isolation that removes capability rather than visibility")

        // ── Side D: the DOM transforms still ran. Isolation shares one DOM; only the ──
        // globals are separate. If this regressed, isolation broke behaviour and the owner
        // directive ("no behaviour changes, just security") is violated.
        #expect(await CanaryKit.eval(wv, "String(document.querySelectorAll('.tm-quote-wrapper').length)") == "1",
                "collapseQuotesJS still transforms the shared DOM from the isolated world — a world separates globals, not documents")

        // ── Side E: the FULL round trip, without trusting a JS self-report. ──
        // A HeightSeedCache entry is only ever written from the numeric branch of
        // `Coordinator.handleHeightMessage`, so its presence proves user script →
        // ResizeObserver → postMessage → isolated-world handler → main-frame gate →
        // validation → applied height. This is the same shape §11 uses, and it is the one
        // assertion here that would catch a handler registered into the WRONG world.
        let seeded = await CanaryKit.waitUntil(10) {
            (AutoSizingHTMLView.seededHeight(headerId: headerId) ?? 0) > 1
        }
        #expect(seeded,
                "the bridge must still round-trip end to end with the handlers registered in the isolated world")
        print("[P3] seededHeight=\(String(describing: AutoSizingHTMLView.seededHeight(headerId: headerId)))")
    }

    // -------------------------------------------------------------------------------
    @Test("A disclosure-tagged height reaches native before that expanded height is applied")
    func disclosureHeightTagIsAtomic() async {
        let headerId = "canary-disclosure-height-\(CanaryKit.nonce())"
        let quotedLines = (0..<40)
            .map { "<p>Quoted line \($0): enough content to produce a material row-height change.</p>" }
            .joined()
        let body = """
        <p>Current message stays visible.</p>
        <div>-----Original Message-----</div>
        <div>From: Someone &lt;someone@example.com&gt;</div>
        \(quotedLines)
        """
        var disclosureSignals = 0
        var seedAtFirstSignal: CGFloat?
        guard let host = await HostedRenderView(
            html: body,
            headerId: headerId,
            onUserDisclosureToggle: {
                disclosureSignals += 1
                if seedAtFirstSignal == nil {
                    // Production invokes this immediately before the validated
                    // height payload enters handleHeightMessage.
                    seedAtFirstSignal = AutoSizingHTMLView.seededHeight(headerId: headerId)
                }
            }
        ) else {
            #expect(Bool(false), "could not host AutoSizingHTMLView"); return
        }
        defer { host.tearDown() }
        let wv = host.webView

        let seeded = await CanaryKit.waitUntil(10) {
            (AutoSizingHTMLView.seededHeight(headerId: headerId) ?? 0) > 1
        }
        #expect(seeded, "collapsed quote must receive its initial production height")
        try? await Task.sleep(for: .milliseconds(500))
        let collapsedHeight = AutoSizingHTMLView.seededHeight(headerId: headerId) ?? 0
        #expect(await CanaryKit.eval(
            wv,
            "String(document.querySelector('.tm-quote-wrapper').classList.contains('tm-collapsed'))",
            in: RenderContentWorld.isolated
        ) == "true")

        _ = await CanaryKit.eval(
            wv,
            "document.querySelector('.tm-quote-toggle').click(); 'clicked'",
            in: RenderContentWorld.isolated
        )
        let signalled = await CanaryKit.waitUntil(5) { seedAtFirstSignal != nil }
        let resized = await CanaryKit.waitUntil(5) {
            (AutoSizingHTMLView.seededHeight(headerId: headerId) ?? 0) > collapsedHeight
        }
        guard resized else {
            #expect(Bool(false), "expanding the material quote must apply a larger native row height")
            return
        }
        // Force a later production ResizeObserver report after the click's own
        // delayed post has also had time to run. A sticky disclosure flag would
        // invoke native again here and make the final count exceed one.
        try? await Task.sleep(for: .milliseconds(100))
        let heightBeforeLaterWitness = AutoSizingHTMLView.seededHeight(headerId: headerId) ?? 0
        #expect(heightBeforeLaterWitness > collapsedHeight)
        _ = await CanaryKit.eval(
            wv,
            "document.body.insertAdjacentHTML('beforeend','<p style=\"height:80px\">later witness</p>'); 'mutated'",
            in: RenderContentWorld.isolated
        )
        let laterHeightWasHandled = await CanaryKit.waitUntil(5) {
            (AutoSizingHTMLView.seededHeight(headerId: headerId) ?? 0) > heightBeforeLaterWitness
        }

        #expect(signalled,
                "the real production coordinator/callback wiring must consume the disclosure bit")
        #expect(seedAtFirstSignal == collapsedHeight,
                "native must disarm before handling the disclosure-tagged height")
        #expect(laterHeightWasHandled,
                "the one-shot assertion requires a witnessed later production height report")
        #expect(disclosureSignals == 1,
                "the one-shot disclosure bit must not classify later resize measurements")
        #expect(await CanaryKit.eval(
            wv,
            "String(document.querySelector('.tm-quote-wrapper').classList.contains('tm-collapsed'))",
            in: RenderContentWorld.isolated
        ) == "false")
    }

    // -------------------------------------------------------------------------------
    @Test("A collapsed height supersedes a buffered expansion before scroll-freeze release")
    func collapsedHeightClearsBufferedExpansion() async {
        let headerId = "canary-disclosure-latest-wins-\(CanaryKit.nonce())"
        var disclosureSignals = 0
        let flushHeights = Mutex<[Double]>([])
        let flushObserver = NotificationCenter.default.addObserver(
            forName: .renderHeightFlushCompletedForTests,
            object: nil,
            queue: nil
        ) { note in
            guard note.userInfo?["headerId"] as? String == headerId,
                  let height = note.userInfo?["height"] as? Double else { return }
            flushHeights.withLock { $0.append(height) }
        }
        defer { NotificationCenter.default.removeObserver(flushObserver) }
        guard let host = await HostedRenderView(
            html: "<p>Native pending-height latest-wins probe.</p>",
            headerId: headerId,
            onUserDisclosureToggle: { disclosureSignals += 1 }
        ) else {
            #expect(Bool(false), "could not host AutoSizingHTMLView"); return
        }
        defer {
            ScrollFreezeGate.shared.end()
            host.tearDown()
        }
        let wv = host.webView
        let seeded = await CanaryKit.waitUntil(10) {
            (AutoSizingHTMLView.seededHeight(headerId: headerId) ?? 0) > 1
        }
        #expect(seeded)
        try? await Task.sleep(for: .milliseconds(500))
        let collapsedHeight = AutoSizingHTMLView.seededHeight(headerId: headerId) ?? 0
        let syntheticExpandedHeight = collapsedHeight + 1_000
        let deviceWidth = wv.bounds.width
        #expect(collapsedHeight > 1 && deviceWidth > 1)

        // Positive control: prove this hosted production Coordinator really
        // receives the async release notification and flushes a buffered
        // height. Without this half, a broken/no-op flush path could make the
        // latest-wins assertion below pass vacuously.
        let controlExpandedHeight = collapsedHeight + 500
        ScrollFreezeGate.shared.begin()
        _ = await CanaryKit.eval(
            wv,
            "window.webkit.messageHandlers.heightChanged.postMessage({h:\(controlExpandedHeight),vp:\(deviceWidth),userDisclosure:true,disclosureAnchorTop:40,source:'canary-flush-control'}); 'control-buffered'",
            in: RenderContentWorld.isolated
        )
        let controlWasBuffered = await CanaryKit.waitUntil(5) {
            disclosureSignals >= 1
                && AutoSizingHTMLView.seededHeight(headerId: headerId) == collapsedHeight
        }
        #expect(controlWasBuffered)
        let controlFlushGeneration = flushHeights.withLock { $0.count }
        ScrollFreezeGate.shared.end()
        let controlFlushSettled = await CanaryKit.waitUntil(5) {
            flushHeights.withLock { $0.count } > controlFlushGeneration
        }
        let controlObservedHeight = flushHeights.withLock { $0.last }
        #expect(controlFlushSettled)
        #expect(controlObservedHeight == Double(controlExpandedHeight),
                "the positive control must witness the production async flush path")
        guard controlFlushSettled,
              controlObservedHeight == Double(controlExpandedHeight) else { return }

        // Return native state to the real collapsed measurement before the
        // show→hide case. This is unfrozen, so the bridge must apply it now.
        _ = await CanaryKit.eval(
            wv,
            "window.webkit.messageHandlers.heightChanged.postMessage({h:\(collapsedHeight),vp:\(deviceWidth),userDisclosure:false,source:'canary-control-reset'}); 'control-reset'",
            in: RenderContentWorld.isolated
        )
        let controlWasReset = await CanaryKit.waitUntil(5) {
            AutoSizingHTMLView.seededHeight(headerId: headerId) == collapsedHeight
        }
        #expect(controlWasReset)
        guard controlWasReset else { return }

        // Drive the REAL validated production bridge with a known-different
        // height. Unlike a DOM expansion, this is a positive witness by
        // construction: if native accepts the signal while frozen, it must
        // buffer (not deduplicate) the 1,000 pt larger value.
        ScrollFreezeGate.shared.begin()
        _ = await CanaryKit.eval(
            wv,
            "window.webkit.messageHandlers.heightChanged.postMessage({h:\(syntheticExpandedHeight),vp:\(deviceWidth),userDisclosure:true,disclosureAnchorTop:40,source:'canary-buffer'}); 'buffered'",
            in: RenderContentWorld.isolated
        )
        let expansionWasBuffered = await CanaryKit.waitUntil(5) {
            disclosureSignals >= 2
                && AutoSizingHTMLView.seededHeight(headerId: headerId) == collapsedHeight
        }
        #expect(expansionWasBuffered)

        _ = await CanaryKit.eval(
            wv,
            "window.webkit.messageHandlers.heightChanged.postMessage({h:\(collapsedHeight),vp:\(deviceWidth),userDisclosure:true,disclosureAnchorTop:40,source:'canary-latest'}); 'superseded'",
            in: RenderContentWorld.isolated
        )
        let collapseWasHandled = await CanaryKit.waitUntil(5) {
            disclosureSignals >= 3
        }
        #expect(collapseWasHandled,
                "the equal collapsed measurement must reach the native handler before release")

        let latestWinsFlushGeneration = flushHeights.withLock { $0.count }
        #expect(latestWinsFlushGeneration == controlFlushGeneration + 1,
                "no foreign scroll-freeze release may flush the candidate window")
        ScrollFreezeGate.shared.end()
        let latestWinsFlushSettled = await CanaryKit.waitUntil(5) {
            flushHeights.withLock { $0.count } > latestWinsFlushGeneration
        }
        let heightAtLatestWinsFlush = flushHeights.withLock { $0.last }
        let finalFlushGeneration = flushHeights.withLock { $0.count }
        #expect(latestWinsFlushSettled,
                "the negative assertion requires the production async flush turn to complete")
        #expect(finalFlushGeneration == latestWinsFlushGeneration + 1,
                "the candidate release must produce exactly one ordered flush completion")
        #expect(heightAtLatestWinsFlush == Double(collapsedHeight),
                "an obsolete buffered expansion must not flush after show→hide")
    }

    // -------------------------------------------------------------------------------
    @Test("P3: every production user script is main-frame-only, which is what makes the frame gate free")
    func everyProductionUserScriptIsMainFrameOnly() async {
        guard let host = await HostedRenderView(html: "<p>frame scope probe</p>",
                                                headerId: "canary-p3-frames") else {
            #expect(Bool(false), "could not host AutoSizingHTMLView"); return
        }
        defer { host.tearDown() }
        let scripts = host.webView.configuration.userContentController.userScripts

        // The PREMISE of `RenderBridgeInput.acceptsMessage(fromMainFrame:)`: because no
        // script of ours runs in a subframe, the gate can never refuse a legitimate
        // measurement. If a future change needs a subframe script, the gate and this
        // assertion have to move together — which is the point of pinning it.
        // ⚠️ HOISTED OUT OF `#expect` ON PURPOSE — do not inline it back.
        // `#expect(scripts.allSatisfy(\.isForMainFrameOnly), …)` does not compile:
        // `allSatisfy` is `rethrows`, and the macro re-emits the call as
        // `$0.allSatisfy($1)` with the predicate crossing a generic-parameter boundary,
        // so the compiler can no longer see a non-throwing closure and `rethrows`
        // degrades to `throws` → "call can throw, but it is not marked with 'try'".
        // ⚠️ THE DISCRIMINATOR IS NARROW — measured 2026-08-13, and stated too broadly twice
        // before this wording stuck. It breaks only when the `rethrows` call takes a KEY PATH
        // *and* is the OUTERMOST expression `#expect` decomposes. Both conditions are needed:
        //   • fails    — `#expect(scripts.allSatisfy(\.isForMainFrameOnly), …)`: the `rethrows`
        //     call IS the top-level expression, so the macro re-emits it as `$0.allSatisfy($1)`
        //     and the non-throwing proof is lost across that generic-parameter boundary.
        //   • survives — a trailing closure at top level, e.g. the four `probe.events` /
        //     `forgedEvents` sites elsewhere in this file, which are correct and untouched.
        //   • survives — a key path NESTED inside a larger expression, because the macro
        //     decomposes around the outer operator and the call stays an opaque operand:
        //     `#expect(outcomes.filter(\.outcome.isFailure).count == 2)` in IntentionLedgerTests
        //     compiles green, as do ~150 `map(\.…) == […]` sites across TabMailTests.
        // So do NOT read this note as "key paths in `#expect` are broken" and go "fix" those —
        // they are fine, and at the time of writing this hoist is the ONLY top-level key-path
        // site in the whole test tree. Do NOT "fix" it by adding `try` either: nothing here can
        // throw, and asserting a throwing possibility that cannot occur is worse than the hoist.
        // The hoist also names the boolean, so a failure prints something legible, and the
        // `print` below reuses it instead of evaluating the same predicate twice.
        let allMainFrameOnly = scripts.allSatisfy(\.isForMainFrameOnly)
        #expect(!scripts.isEmpty, "the production config must install user scripts")
        #expect(allMainFrameOnly,
                "every production user script must be forMainFrameOnly — the main-frame bridge gate assumes no legitimate message can originate in a subframe")
        print("[P3] production userScripts=\(scripts.count) allMainFrameOnly=\(allMainFrameOnly)")
    }

    // -------------------------------------------------------------------------------
    @Test("P3: frameInfo.isMainFrame really discriminates, and the gate drops the subframe")
    func subframeMessagesAreDistinguishedAndRejected() async {
        // A world of this test's own, so nothing here can perturb the production pipeline.
        let probeWorld = WKContentWorld.world(name: "P3FrameProbe")
        let handler = FrameProbeHandler()
        let cfg = WKWebViewConfiguration()
        let ucc = WKUserContentController()
        // forMainFrameOnly: FALSE — the whole point. This is the one script in the codebase
        // deliberately injected into subframes, and it exists only to make the subframe case
        // observable at all.
        ucc.addUserScript(WKUserScript(source: """
        try { window.webkit.messageHandlers.frameProbe.postMessage(String(window === window.top)); } catch (e) {}
        """, injectionTime: .atDocumentEnd, forMainFrameOnly: false, in: probeWorld))
        ucc.add(handler, contentWorld: probeWorld, name: "frameProbe")
        cfg.userContentController = ucc

        let wv = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 600), configuration: cfg)
        wv.loadHTMLString("""
        <html><body><p>main frame</p>
        <iframe srcdoc="<p>sub frame</p>" width="100" height="100"></iframe>
        </body></html>
        """, baseURL: nil)

        let sawBoth = await CanaryKit.waitUntil(12) { handler.received.count >= 2 }
        print("[P3] frame probe received=\(handler.received.map { "\($0.body)/main=\($0.isMainFrame)" })")
        guard sawBoth else {
            #expect(Bool(false),
                    "expected a post from BOTH the main frame and the subframe; got \(handler.received.count). Without both, the frame gate is untested rather than passing")
            return
        }

        // The PLATFORM fact: WebKit reports the originating frame, and the two differ.
        // Two-sided on purpose — an `isMainFrame` that were always true (or always false)
        // would make the production guard vacuous, and a one-sided assertion could not tell.
        let mainFrameMessages = handler.received.filter(\.isMainFrame)
        let subFrameMessages = handler.received.filter { !$0.isMainFrame }
        #expect(!mainFrameMessages.isEmpty, "the main frame's post must arrive with isMainFrame == true")
        #expect(!subFrameMessages.isEmpty,
                "the subframe's post must arrive with isMainFrame == false — if WebKit reported every message as main-frame, the production gate would be silently vacuous")
        // Cross-check the Swift-side signal against the JS-side one, so a mislabelling in
        // either direction shows up rather than agreeing with itself.
        #expect(mainFrameMessages.allSatisfy { $0.body == "true" },
                "the frame WebKit calls main must be the one where window === window.top")
        #expect(subFrameMessages.allSatisfy { $0.body == "false" },
                "the frame WebKit calls a subframe must be the one where window !== window.top")

        // THE DECISION the production coordinator makes on exactly this input. Fail-closed
        // direction, both ways: the subframe message is DROPPED, not defaulted and not
        // merely logged.
        #expect(mainFrameMessages.allSatisfy { RenderBridgeInput.acceptsMessage(fromMainFrame: $0.isMainFrame) },
                "a main-frame message must be admitted — a gate that drops real measurements would blank the render")
        #expect(subFrameMessages.allSatisfy { !RenderBridgeInput.acceptsMessage(fromMainFrame: $0.isMainFrame) },
                "a subframe message must be REFUSED before the liveness beacon records it, or a non-app post could forge a LIVE bridge verdict")
    }
}
