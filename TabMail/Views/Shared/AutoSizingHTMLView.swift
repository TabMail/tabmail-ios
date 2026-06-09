/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import SwiftUI
import WebKit
import CryptoKit
import Synchronization

/// Auto-sizing WKWebView that reports its content height to SwiftUI.
///
/// `headerId` opt-in: when non-nil, registers a `BodyAssetSchemeHandler` on the
/// WKWebViewConfiguration so HTML `<img src="tabmail-asset://...">` refs resolve
/// to bytes from `BodyAssetStore`. Compose preview / Eml preview / tooltip mocks
/// pass nil and get inline data URIs (legacy path, baseURL: nil).
struct AutoSizingHTMLView: View {
    let html: String
    let previewFilename: String?
    let headerId: String?
    @State private var height: CGFloat

    init(html: String, previewFilename: String? = nil, headerId: String? = nil) {
        self.html = html
        self.previewFilename = previewFilename
        self.headerId = headerId
        // Seed the initial frame height from the last applied measurement for
        // this message. SwiftUI List dismantles far-offscreen rows — when an
        // expanded card scrolls back toward the viewport, the whole view
        // (including @State) is recreated and the row would collapse to 1 pt,
        // shifting every row below up by the card's height until the fresh
        // WKWebView re-measures ~200–500 ms later, then shifting them back —
        // visible as cards jumping/overlapping mid-scroll (logmain.log
        // 2026-06-09: same message reloaded 5× with frameH=1 at onload).
        // Seeding is safe ONLY because the fit pipeline is idempotent
        // (ADR-IOS-039): same content + same width → identical re-measurement,
        // which the `!=` guard in handleHeightMessage then drops, so a seeded
        // row doesn't move at all.
        _height = State(initialValue: headerId.flatMap { HeightSeedCache.shared[$0] } ?? 1)
    }

    var body: some View {
        HTMLWebView(html: html, previewFilename: previewFilename, headerId: headerId, height: $height)
            .frame(height: max(height, 1))
            // Suppress implicit animation on height changes. Without this, the
            // initial @State height=1 grows to the first measured value with a
            // spring animation inherited from a parent (List / ScrollView /
            // sheet), which reads as visual fluctuation during load. The
            // height should snap directly to each measured value.
            .animation(.none, value: height)
            // All gutters live here in the SwiftUI container, not in body CSS.
            // The web view's content fills its frame exactly; breathing room
            // is applied outside. Doing this here ensures the padding is a
            // constant pt value regardless of whether fitViewportJS widened
            // the layout viewport — a CSS `padding: 12px` bottom would shrink
            // to 8.6 pt visually when widened (12 × 0.72 scale), producing an
            // inconsistent bubble-bottom gap across emails.
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
    }
}

/// Process-wide gate raised while the user is actively scrolling the message
/// detail List. While frozen, `HTMLWebView.Coordinator` defers APPLYING changed
/// height measurements — the WKWebView keeps measuring; only the SwiftUI frame
/// write waits. A row height change mid-pan makes the List's self-sizing
/// reposition rows under the finger, which renders as overlapping cards.
///
/// Mirrors the buffer-and-flush shape of `PreviewFreezeGate`
/// (SyncStatusSubtitle.swift) but is deliberately a separate gate:
/// PreviewFreezeGate pauses env-driven refreshes for the QuickLook sheet, and
/// coupling scroll phases into it would pause those unrelated consumers on
/// every pan. Uses `Mutex` instead of `@MainActor` so the nonisolated
/// `WKScriptMessageHandler` path can read it without isolation friction
/// (Resilience rule 5).
///
/// Driver: `MessageDetailView`'s List via `.onScrollPhaseChange` — `begin()`
/// on any non-idle phase, `end()` on idle AND in `onDisappear` (a stuck gate
/// would freeze height application process-wide).
final class ScrollFreezeGate: Sendable {
    static let shared = ScrollFreezeGate()
    private let frozen = Mutex(false)

    var isFrozen: Bool { frozen.withLock { $0 } }

    func begin() {
        let changed = frozen.withLock { (v: inout Bool) -> Bool in
            if v { return false }
            v = true
            return true
        }
        if changed, DebugModeManager.isLoggingEnabled() { print("[ScrollFreeze] begin") }
    }

    func end() {
        let changed = frozen.withLock { (v: inout Bool) -> Bool in
            guard v else { return false }
            v = false
            return true
        }
        guard changed else { return }
        if DebugModeManager.isLoggingEnabled() { print("[ScrollFreeze] end — flushing deferred heights") }
        NotificationCenter.default.post(name: .scrollFreezeReleased, object: nil)
    }
}

extension Notification.Name {
    /// Posted by `ScrollFreezeGate.end()`. `HTMLWebView.Coordinator`s apply
    /// their buffered `pendingHeight` on receipt.
    static let scrollFreezeReleased = Notification.Name("scrollFreezeReleased")
}

/// In-memory cache of the last APPLIED visual height per message
/// (`headerId`). Read once in `AutoSizingHTMLView.init` to seed `@State
/// height` so a List-recycled card re-enters the viewport at its real height
/// instead of collapsing to 1 pt and re-inflating mid-scroll. Written by the
/// Coordinator on every applied height (direct apply and scroll-freeze flush)
/// — safe to overwrite unconditionally because the fit pipeline is idempotent
/// (ADR-IOS-039), so values only change when content/width genuinely changed.
///
/// Deliberately NOT persisted to disk: the symptom is within-session scroll
/// churn; a rendered-height-per-message table on disk would be derived data
/// brushing against ADR-004's zero-retention posture for no benefit.
///
/// Width sensitivity: values are keyed by message only. After a rotation /
/// split-view resize, a seed can be briefly wrong — the recreated WKWebView's
/// idempotent re-measure corrects it in one snap (~200 ms), which is the
/// pre-cache behavior. Not worth keying by width.
final class HeightSeedCache: Sendable {
    static let shared = HeightSeedCache()
    /// Bound on retained entries — one per opened message per session, so the
    /// cap exists only as a leak backstop. Crude clear-all on overflow is fine:
    /// losing seeds merely restores pre-cache behavior for the next render.
    private static let maxEntries = 512
    private let store = Mutex<[String: CGFloat]>([:])

    subscript(headerId: String) -> CGFloat? {
        get { store.withLock { $0[headerId] } }
        set {
            store.withLock { dict in
                if dict.count >= Self.maxEntries { dict.removeAll(keepingCapacity: true) }
                dict[headerId] = newValue
            }
        }
    }
}

private struct HTMLWebView: UIViewRepresentable {
    let html: String
    let previewFilename: String?
    let headerId: String?
    @Binding var height: CGFloat

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.dataDetectorTypes = [.link, .phoneNumber]
        // Register the BodyAssetStore scheme handler when this WebView is rendering
        // a real (persisted) message body. The handler serves bytes from the App
        // Group container in-process — required because WKWebView's sandboxed
        // WebContent process can't read those files via `file://` baseURL on device.
        // Compose / Eml / tooltip paths pass headerId=nil and use inline data URIs,
        // so the handler isn't registered (no-op).
        if headerId != nil {
            config.setURLSchemeHandler(BodyAssetSchemeHandler(), forURLScheme: BodyAssetConfig.urlScheme)
        }
        // .atDocumentStart stamp of the per-WebView correlation id. Runs
        // synchronously before any other script, so [HeightDiag id=...] log
        // lines emitted by setTimeout-scheduled callbacks always have the right
        // id. The previous approach (evaluateJavaScript queued from didFinish)
        // raced with the t100 setTimeout on image-heavy emails — Fireworks
        // consistently produced [HeightDiag id=?] entries because the stamp
        // landed after t100 fired. Debug-gated; in production the diag
        // doesn't read __tmDiagId so we skip injecting it entirely.
        let idStampJS = DebugModeManager.isLoggingEnabled()
            ? "window.__tmDiagId='\(context.coordinator.webViewId)';"
            : ""
        let idStamp = WKUserScript(source: idStampJS, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        let mediaFix = WKUserScript(source: enforceMediaDisplayJS, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
        let widthFix = WKUserScript(source: constrainWidthsJS, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
        let darkMode = WKUserScript(source: fixDarkModeColorsJS, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
        let emlCleanup = WKUserScript(source: cleanupEmlBodyJS, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
        let quoteCollapse = WKUserScript(source: collapseQuotesJS, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
        let icsCollapse = WKUserScript(source: collapseICSJS, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
        let heightMonitor = WKUserScript(source: monitorHeightJS, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
        let debugReport = WKUserScript(source: htmlDebugReportJS, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
        let heightDiag = WKUserScript(source: heightDiagnosticJS, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
        config.userContentController.addUserScript(idStamp)
        config.userContentController.addUserScript(mediaFix)
        config.userContentController.addUserScript(widthFix)
        config.userContentController.addUserScript(darkMode)
        config.userContentController.addUserScript(emlCleanup)
        config.userContentController.addUserScript(quoteCollapse)
        config.userContentController.addUserScript(icsCollapse)
        config.userContentController.addUserScript(heightMonitor)
        config.userContentController.addUserScript(debugReport)
        config.userContentController.addUserScript(heightDiag)
        config.userContentController.add(context.coordinator, name: "heightChanged")
        config.userContentController.add(context.coordinator, name: "consoleLog")

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = true
        webView.scrollView.bounces = false
        webView.navigationDelegate = context.coordinator
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.webView = webView
        let currentWidth = webView.bounds.width
        let htmlChanged = html != context.coordinator.loadedHTML

        if htmlChanged {
            context.coordinator.loadedHTML = html
            context.coordinator.loadedPreviewFilename = previewFilename
            context.coordinator.loadedHeaderId = headerId
            context.coordinator.lastMeasuredWidth = currentWidth
            // New document — a height buffered during scroll for the OLD
            // document must not flush onto the new one.
            context.coordinator.pendingHeight = nil
            if DebugModeManager.isLoggingEnabled() {
                print("[HTMLDebug] HTMLWebView.updateUIView: loading html len=\(html.count)")
            }
            let wrapped = EmailHTMLWrapper.wrapHTML(html, previewFilename: previewFilename)
            if DebugModeManager.isLoggingEnabled() {
                print("[HTMLDebug] HTMLWebView.updateUIView: wrapped len=\(wrapped.count)")
                // Log input HTML in chunks so we can see EXACTLY what's being rendered
                let inputChunkSize = 800
                let inputPreview = String(html.prefix(inputChunkSize * 3))
                for (i, chunkStart) in stride(from: 0, to: inputPreview.count, by: inputChunkSize).enumerated() {
                    let start = inputPreview.index(inputPreview.startIndex, offsetBy: chunkStart)
                    let end = inputPreview.index(start, offsetBy: min(inputChunkSize, inputPreview.count - chunkStart))
                    print("[HTMLDebug] INPUT HTML chunk #\(i): \(inputPreview[start..<end])")
                }
                // Count <style>, <p>, <span>, <br>, and font-size occurrences
                let styleCount = html.components(separatedBy: "<style").count - 1
                let pCount = html.components(separatedBy: "<p ").count - 1 + (html.components(separatedBy: "<p>").count - 1)
                let spanCount = html.components(separatedBy: "<span").count - 1
                let brCount = html.components(separatedBy: "<br").count - 1
                let fontSizeCount = html.components(separatedBy: "font-size").count - 1
                let msoCount = html.components(separatedBy: "MsoNormal").count - 1
                print("[HTMLDebug] INPUT HTML stats: <style>=\(styleCount) <p>=\(pCount) <span>=\(spanCount) <br>=\(brCount) font-size=\(fontSizeCount) MsoNormal=\(msoCount)")
            }
            // baseURL: nil is fine for compose/Eml/tooltip (no scheme handler).
            // For real bodies (headerId != nil) we hand a non-nil baseURL purely
            // so the document has a non-nil origin — required by some CORS /
            // mixed-content policies for scheme-handled subresources to load.
            // BodyAssetConfig.baseURL is a fixed `tabmail-asset://asset/`; HTML
            // `src` refs are absolute and resolve via the registered handler
            // regardless of which origin the document is loaded under.
            let base: URL? = (headerId != nil) ? BodyAssetConfig.baseURL : nil
            if DebugModeManager.isLoggingEnabled() {
                // Privacy-safe per-email fingerprint: SHA256 of the wrapped html,
                // truncated to 8 hex chars. One-way, not reversible to content.
                // Lets us match an email open to its log timeline (multiple
                // [MeasureHeight id=...] / [HeightDiag id=...] lines all share
                // the same correlation id; this [Load] event ties that id to a
                // specific html payload).
                let bytes = Data(wrapped.utf8)
                let digest = SHA256.hash(data: bytes)
                let fp = digest.prefix(4).map { String(format: "%02x", $0) }.joined()
                print("[Load id=\(context.coordinator.webViewId)] bytes=\(wrapped.count) fp=\(fp) hasHeader=\(headerId != nil)")
            }
            webView.loadHTMLString(wrapped, baseURL: base)
        } else if currentWidth > 100 && abs(currentWidth - context.coordinator.lastMeasuredWidth) > 10 {
            // Frame width changed significantly (e.g. sheet animation settled) —
            // reset viewport to device-width and re-fit. ResizeObserver picks
            // up the resulting layout change and posts the new height.
            // viewportResetJS clears window.__tmLayoutVp — REQUIRED, or
            // fitViewportJS's idempotency guard would treat the re-fit as a
            // re-entry and bail, and monitorHeightJS would keep scaling
            // heights against the stale widened viewport.
            context.coordinator.lastMeasuredWidth = currentWidth
            let resetJS = viewportResetJS(deviceWidth: Int(currentWidth.rounded()))
            webView.evaluateJavaScript(resetJS) { _, _ in
                context.coordinator.fit()
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(height: $height)
    }

    class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {

        @Binding var height: CGFloat
        var loadedHTML: String?
        var loadedPreviewFilename: String?
        var loadedHeaderId: String?
        var lastMeasuredWidth: CGFloat = 0
        weak var webView: WKWebView?
        /// Latest measured height that arrived while `ScrollFreezeGate` was
        /// frozen. Applied (and cleared) by the `.scrollFreezeReleased`
        /// listener; overwritten by newer measurements during the same freeze
        /// so only the final value flushes. Cleared on new-document load.
        var pendingHeight: CGFloat?
        private nonisolated(unsafe) var foregroundObserver: NSObjectProtocol?
        private nonisolated(unsafe) var scrollFreezeObserver: NSObjectProtocol?
        /// Per-Coordinator (i.e. per-WebView lifetime) random id. Stamped into
        /// every diag log line on both the Swift and JS sides so we can grep an
        /// entire email's render timeline out of mixed log streams (multiple
        /// WebViews coexist: focused message + thread-card messages + compose
        /// preview + .eml attachments). Six chars from a 32-glyph alphabet =
        /// ~30 bits, plenty for log correlation across a session.
        let webViewId: String = {
            let alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
            return String((0..<6).map { _ in alphabet.randomElement()! })
        }()
        /// KVO observation on scrollView.contentSize. UIScrollView updates
        /// contentSize asynchronously from the WebContent process AFTER
        /// ResizeObserver/layout settles; without observing it directly we
        /// can only sample at fixed +Nms times and easily miss the converged
        /// value. KVO logs every change so the log shows the full settling
        /// trajectory. Debug-only — released in deinit.
        private var contentSizeObservation: NSKeyValueObservation?

        init(height: Binding<CGFloat>) {
            self._height = height
            super.init()
            // Re-run fitViewport on foreground return — iOS resumes the WKWebView
            // content process which may have been suspended with incomplete
            // rendering. The injected ResizeObserver in monitorHeightJS keeps
            // reporting height changes from JS → Swift after that.
            foregroundObserver = NotificationCenter.default.addObserver(
                forName: UIApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    guard let self, let webView = self.webView else { return }
                    self.fit(webView)
                }
            }
            // Flush the height buffered during an active scroll once the
            // List reports idle. Buffer-and-flush mirrors the
            // PreviewFreezeGate pattern in MessageDetailViewModel.
            scrollFreezeObserver = NotificationCenter.default.addObserver(
                forName: .scrollFreezeReleased,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                // queue: .main guarantees delivery on the main thread; the
                // Coordinator is MainActor-inferred (WKNavigationDelegate /
                // WKScriptMessageHandler are @MainActor protocols), so assert
                // the isolation rather than smuggling access past the checker.
                MainActor.assumeIsolated {
                    guard let self, let pending = self.pendingHeight else { return }
                    self.pendingHeight = nil
                    if pending > 0 && pending != self.height {
                        self.height = pending
                        if let hid = self.loadedHeaderId { HeightSeedCache.shared[hid] = pending }
                    }
                }
            }
        }

        deinit {
            if let obs = foregroundObserver { NotificationCenter.default.removeObserver(obs) }
            if let obs = scrollFreezeObserver { NotificationCenter.default.removeObserver(obs) }
            contentSizeObservation?.invalidate()
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            self.webView = webView
            lastMeasuredWidth = webView.bounds.width
            // Wire up scrollView.contentSize KVO for diagnosis only (NOT for
            // driving the SwiftUI height — that path stays JS-push-driven via
            // ResizeObserver, since KVO would feed back into frame.height and
            // any author CSS using `vh` units would cause runaway growth).
            // Observing earlier (before makeUIView returns) is impossible since
            // we don't have the instance yet, and observing later misses the
            // first contentSize update from the initial layout. The id stamp
            // for the JS side now happens via a .atDocumentStart user script
            // baked at config time — see makeUIView.
            if DebugModeManager.isLoggingEnabled(), contentSizeObservation == nil {
                let id = webViewId
                contentSizeObservation = webView.scrollView.observe(\.contentSize, options: [.new, .old]) { [weak webView] sv, change in
                    // UIScrollView.contentSize KVO for a WKWebView fires on
                    // the main thread (layout-driven); assert rather than
                    // bypass the isolation checker for the UIKit reads.
                    MainActor.assumeIsolated {
                        guard let webView, let new = change.newValue else { return }
                        let zoom = sv.zoomScale
                        let frameH = webView.bounds.height
                        let oldH = change.oldValue?.height ?? 0
                        print(String(format: "[ContentSizeKVO id=%@] contentH=%.0f (was %.0f) zoom=%.3f frameH=%.0f",
                                     id, new.height, oldH, zoom, frameH))
                    }
                }
            }
            fit(webView)
        }

        /// Run `fitViewportJS` once to widen the viewport meta when content
        /// overflows. After that, the injected `monitorHeightJS`
        /// (ResizeObserver) pushes every subsequent height change to
        /// `handleHeightMessage`. No polling, no KVO — JS-native push via
        /// `WKScriptMessageHandler`.
        func fit(_ webView: WKWebView? = nil) {
            guard let webView = webView ?? self.webView, webView.bounds.width > 50 else { return }
            // Stamp the authoritative device-pt width BEFORE the fit script
            // runs. At the device-width baseline 1 CSS px == 1 pt, so
            // bounds.width IS the correct measurement baseline.
            // window.innerWidth is not trustworthy after meta/bounds changes
            // (WebKit bug 170595) — the same reason monitorHeightJS reads
            // __tmLayoutVp instead of innerWidth after a widen.
            let stampJS = "window.__tmDeviceWidth = \(Int(webView.bounds.width.rounded()));"
            webView.evaluateJavaScript(stampJS + fitViewportJS) { _, _ in
                // That's it. monitorHeightJS's ResizeObserver will fire
                // after the viewport change settles, and
                // handleHeightMessage will apply the result.
            }
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            // iOS killed the WKWebView content process (memory pressure).
            // Reload the content to restore rendering. Mirror the original
            // baseURL choice: nil for compose/Eml, BodyAssetConfig.baseURL when
            // a headerId is present (so scheme-handler-served images still load).
            if let html = loadedHTML {
                let wrapped = EmailHTMLWrapper.wrapHTML(html, previewFilename: loadedPreviewFilename)
                let base: URL? = (loadedHeaderId != nil) ? BodyAssetConfig.baseURL : nil
                webView.loadHTMLString(wrapped, baseURL: base)
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            if navigationAction.navigationType == .linkActivated,
               let url = navigationAction.request.url {
                // Short-circuit mailto: so the user composes in TabMail rather
                // than handing off to whichever app iOS currently considers
                // the default mail client (we don't hold the entitlement yet).
                if let request = MailtoRequest.parse(url) {
                    NotificationCenter.default.post(
                        name: .contactPillComposeTapped,
                        object: nil,
                        userInfo: request.toUserInfo()
                    )
                    return .cancel
                }
                await UIApplication.shared.open(url)
                return .cancel
            }
            return .allow
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.name == "heightChanged" {
                handleHeightMessage(message.body)
            } else if message.name == "consoleLog", let msg = message.body as? String {
                // Defense-in-depth gate: most JS-side log sites already
                // substitute an empty string when DebugModeManager is off (see
                // `htmlDebugReportJS`, `heightDiagnosticJS`, `fitViewportJS`'s
                // `log` helper, and the `logEnabled` ternaries in
                // `enforceMediaDisplayJS` / `constrainWidthsJS` /
                // `collapseQuotesJS`). But a couple of error paths (e.g.
                // `cleanupEmlBodyJS`'s catch block) post unconditionally,
                // and in principle any author JS in the email body could
                // post to this channel too. Gating here guarantees no diag
                // chatter reaches the production log regardless of upstream
                // script gaps. The message handler itself stays registered
                // because gating its registration would skip `heightChanged`,
                // which is load-bearing.
                if DebugModeManager.isLoggingEnabled() { print(msg) }
            }
        }

        /// Consume the `{ h, vp }` payload from `monitorHeightJS` (ResizeObserver-
        /// driven). `h` is `document.body.scrollHeight` in CSS px; `vp` is
        /// `window.innerWidth` (the layout viewport, in CSS px). Convert to
        /// device points using the web view's actual frame width.
        private func handleHeightMessage(_ body: Any) {
            guard let webView = webView, webView.bounds.width > 0 else { return }
            // Pinch-zoomed — the user is interactively zooming, so don't
            // fight them by snapping the frame back. Use isZooming (set ONLY
            // during user pinch) instead of `zoomScale != 1.0`, which also
            // matches the WebKit-applied pageScale from a meta-viewport widen
            // (zoomScale becomes ~0.72 once pageScale commits ~50ms after the
            // post-widen RO fire). The old check silently dropped EVERY
            // post-pageScale-commit message — including our explicit post-widen
            // re-fires that catch the body=4191→4349 image-load growth — which
            // is exactly the Fireworks bug we were chasing. isZooming is the
            // right signal for "user gesture in progress."
            if webView.scrollView.isZooming || webView.scrollView.isZoomBouncing { return }

            let h: CGFloat
            let vp: CGFloat
            var scrollForLog: CGFloat = 0
            var rectForLog: CGFloat = 0
            var sourceForLog: String = "RO"
            if let dict = body as? [String: Any] {
                h = (dict["h"] as? NSNumber).map { CGFloat(truncating: $0) } ?? 0
                vp = (dict["vp"] as? NSNumber).map { CGFloat(truncating: $0) } ?? 0
                scrollForLog = (dict["scroll"] as? NSNumber).map { CGFloat(truncating: $0) } ?? h
                rectForLog = (dict["rect"] as? NSNumber).map { CGFloat(truncating: $0) } ?? h
                if let src = dict["source"] as? String { sourceForLog = src }
            } else if let n = body as? NSNumber {
                h = CGFloat(truncating: n)
                vp = webView.bounds.width
            } else {
                return
            }
            guard h > 0 else { return }

            let boundsWidth = webView.bounds.width
            let effectiveVp = vp > 0 ? vp : boundsWidth
            let scale = (effectiveVp > boundsWidth) ? (boundsWidth / effectiveVp) : 1.0
            let visualHeight = ceil(h * scale)
            if DebugModeManager.isLoggingEnabled() {
                // [MeasureHeight] is fired ON EACH ResizeObserver event from JS.
                // It captures: the JS body measurement we received, our
                // computed visualHeight (what we'll set the SwiftUI frame to),
                // and a synchronous read of scrollView.zoomScale +
                // contentSize.height. The synchronous reads are usually stale
                // — UIScrollView updates async from the WebContent process —
                // so the [ContentSizeKVO id=...] line is the source of truth
                // for "what did contentSize end up at." Correlate by id.
                let zoom = webView.scrollView.zoomScale
                let contentH = webView.scrollView.contentSize.height
                print(String(format: "[MeasureHeight id=%@] %@ h=%.0f (scroll=%.0f rect=%.0f) vp=%.0f bounds=%.0f scale=%.3f → %.0f zoom=%.3f contentH=%.0f",
                             webViewId, sourceForLog, h, scrollForLog, rectForLog, effectiveVp, boundsWidth, scale, visualHeight, zoom, contentH))
                let visualHeightSnapshot = visualHeight
                let id = webViewId
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak webView] in
                    guard let webView else { return }
                    let z = webView.scrollView.zoomScale
                    let cH = webView.scrollView.contentSize.height
                    let frameH = webView.bounds.height
                    print(String(format: "[MeasureHeight id=%@] +300ms zoom=%.3f contentH=%.0f frameH=%.0f visual=%.0f overflow=%.0f",
                                 id, z, cH, frameH, visualHeightSnapshot, max(0, cH - frameH)))
                }
            }
            if visualHeight > 0 && visualHeight != height {
                // Scroll freeze: applying a CHANGED height while the user is
                // panning the detail List makes the row resize under the
                // finger — List self-sizing repositions neighbors mid-gesture,
                // which renders as overlapping cards. Defer the frame write;
                // the .scrollFreezeReleased listener (init) flushes the latest
                // pending value when scrolling idles. Equal heights never
                // reach this branch (the != guard above), so now that
                // fitViewportJS is idempotent, steady-state re-measurements
                // are free regardless of the gate.
                // Exception: height <= 1 means the row was never sized (fresh
                // expand / first load) — an invisible 1pt row is worse than a
                // mid-scroll layout shift, so the first real height applies
                // immediately.
                if ScrollFreezeGate.shared.isFrozen && height > 1 {
                    pendingHeight = visualHeight
                    if DebugModeManager.isLoggingEnabled() {
                        print("[MeasureHeight id=\(webViewId)] deferred during scroll: \(Int(visualHeight)) (frame stays \(Int(height)))")
                    }
                } else {
                    pendingHeight = nil
                    height = visualHeight
                    if let hid = loadedHeaderId { HeightSeedCache.shared[hid] = visualHeight }
                }
            }
        }
    }
}

// MARK: - Shared HTML + JS


/// Enforce matching @media display rules when CSS cascade fails.
/// Some email templates (e.g. Apple newsletters) have a mobile layout hidden by
/// `display:none !important` in a later stylesheet that overrides an `@media` rule's
/// Post-render cleanup for embedded .eml content. Outlook/Word HTML exported
/// to `.eml` files uses dozens of spacer elements (`<p><br></p>`, `<p><o:p>&nbsp;</o:p></p>`,
/// empty `<td height="17.05pt">`, runs of consecutive `<br>`) to emulate
/// page-layout spacing that only makes sense in a 612pt-wide print preview.
/// On a 320px mobile viewport they stack into hundreds of pixels of blank
/// space below the message body.
///
/// CSS `:empty` doesn't match these because the elements technically have
/// children (`<br>`, `<o:p>`, `&nbsp;`). We strip them with JS after render.
///
/// Scoped to `.tm-eml-section .tm-email-body` — nested `.eml` content only.
/// `unwrapFullHTMLDocument` also puts `tm-email-body` on top-level full-document
/// emails (to let `body{…}` CSS selectors be redirected via neutralizeCSSRules)
/// but those MUST NOT be cleaned up — collapsing their `<br><br>` spacers and
/// empty `<p>`s breaks newsletters (e.g. RBC statements) that use them for
/// intentional visual rhythm. The `.tm-eml-section` ancestor is emitted only
/// by `renderBodyWithEmbeddedHeaders` around nested attached .eml blocks.
/// Exposed as `internal` so unit tests can verify the scope selector is the narrowed
/// `.tm-eml-section .tm-email-body` form, preventing a regression where top-level
/// full-document emails would have their `<br>` runs collapsed.
internal var cleanupEmlBodyJS: String {
    let log = DebugModeManager.isLoggingEnabled()
        ? "try { window.webkit.messageHandlers.consoleLog.postMessage('[HTMLDebug] EmlCleanup: removed ' + removed + ' empty elements, ' + brsRemoved + ' consecutive brs'); } catch(_){}"
        : ""
    return """
    (function() {
        if (!document.body) return;
        try {
            var emailBodies = document.querySelectorAll('.tm-eml-section .tm-email-body');
            if (emailBodies.length === 0) return;
            var removed = 0;
            var brsRemoved = 0;
            for (var ei = 0; ei < emailBodies.length; ei++) {
                var root = emailBodies[ei];
                // Pass 1: remove truly empty-looking paragraphs and divs that
                // have no visible text AND no images/links/tables/iframes.
                // Multiple passes needed because removing children may make
                // parent paragraphs newly empty.
                for (var pass = 0; pass < 3; pass++) {
                    var candidates = root.querySelectorAll('p, div:not(.tm-email-body), span');
                    var passRemoved = 0;
                    for (var i = candidates.length - 1; i >= 0; i--) {
                        var el = candidates[i];
                        if (!el.parentNode) continue;
                        var text = (el.innerText || el.textContent || '').replace(/\\u00a0/g, ' ').trim();
                        if (text.length > 0) continue;
                        // Keep nodes that contain meaningful descendants
                        var hasMeaning = el.querySelector('img, a[href], table, iframe, video, audio, svg, canvas, input, button, select, textarea');
                        if (hasMeaning) continue;
                        el.parentNode.removeChild(el);
                        passRemoved++;
                    }
                    removed += passRemoved;
                    if (passRemoved === 0) break;
                }
                // Pass 2: collapse runs of consecutive <br> elements to a single <br>
                var brs = root.querySelectorAll('br');
                for (var bi = 0; bi < brs.length; bi++) {
                    var br = brs[bi];
                    var prev = br.previousSibling;
                    while (prev && prev.nodeType === 3 && !prev.textContent.trim()) {
                        prev = prev.previousSibling;
                    }
                    if (prev && prev.nodeName === 'BR') {
                        br.parentNode.removeChild(br);
                        brsRemoved++;
                    }
                }
                // Pass 3: drop empty <td> cells — but only if every td in the
                // row is empty (some tables use empty cells for alignment and
                // we shouldn't break those layouts).
                var rows = root.querySelectorAll('tr');
                for (var ri = 0; ri < rows.length; ri++) {
                    var row = rows[ri];
                    var cells = row.querySelectorAll('td, th');
                    if (cells.length === 0) continue;
                    var allEmpty = true;
                    for (var ci = 0; ci < cells.length; ci++) {
                        var t = (cells[ci].innerText || '').replace(/\\u00a0/g, ' ').trim();
                        if (t.length > 0) { allEmpty = false; break; }
                        if (cells[ci].querySelector('img, a[href], table')) { allEmpty = false; break; }
                    }
                    if (allEmpty && row.parentNode) {
                        row.parentNode.removeChild(row);
                        removed++;
                    }
                }
            }
            \(log)
        } catch(e) {
            try { window.webkit.messageHandlers.consoleLog.postMessage('[HTMLDebug] EmlCleanup error: ' + e.message); } catch(_){}
        }
    })();
    """
}

/// `display:block !important`. This script detects such conflicts and applies the
/// @media-intended display value directly via inline style, which has the highest priority.
private var enforceMediaDisplayJS: String {
    let logEnabled = DebugModeManager.isLoggingEnabled()
    let logSnippet = logEnabled
        ? "try { window.webkit.messageHandlers.consoleLog.postMessage('[HTMLDebug] enforceMediaDisplay: forced ' + ir_rule.selectorText + ' display:' + computed + ' → ' + intended); } catch(_){}"
        : ""
    return """
    (function() {
        if (!document.body) return;
        try {
            var sheets = document.styleSheets;
            for (var si = 0; si < sheets.length; si++) {
                try {
                    var rules = sheets[si].cssRules;
                    for (var ri = 0; ri < rules.length; ri++) {
                        var rule = rules[ri];
                        if (rule.type !== CSSRule.MEDIA_RULE) continue;
                        var mq = rule.conditionText || rule.media.mediaText;
                        if (!window.matchMedia(mq).matches) continue;
                        var inner = rule.cssRules;
                        if (!inner) continue;
                        for (var ir = 0; ir < inner.length; ir++) {
                            var ir_rule = inner[ir];
                            if (!ir_rule.style || !ir_rule.selectorText) continue;
                            var intended = ir_rule.style.getPropertyValue('display');
                            var priority = ir_rule.style.getPropertyPriority('display');
                            if (!intended || priority !== 'important') continue;
                            try {
                                var els = document.querySelectorAll(ir_rule.selectorText);
                                for (var ei = 0; ei < els.length; ei++) {
                                    var computed = window.getComputedStyle(els[ei]).display;
                                    if (computed !== intended) {
                                        els[ei].style.setProperty('display', intended, 'important');
                                        if (intended !== 'none') {
                                            var inW = els[ei].style.getPropertyValue('width');
                                            var inH = els[ei].style.getPropertyValue('height');
                                            if (inW === '0px' || inW === '0') els[ei].style.setProperty('width', '100%', 'important');
                                            if (inH === '0px' || inH === '0') els[ei].style.removeProperty('height');
                                            var inOv = els[ei].style.getPropertyValue('overflow');
                                            if (inOv === 'hidden') els[ei].style.setProperty('overflow', 'visible', 'important');
                                        }
                                        \(logSnippet)
                                    }
                                }
                            } catch(_) {}
                        }
                    }
                } catch(_){}
            }
        } catch(_){}
    })();
    """
}

/// Strip hardcoded widths from email layout elements (injected as WKUserScript
/// at document end). Uses inline style.setProperty which has the highest CSS
/// priority — overrides both stylesheet !important and HTML width attributes.
/// Uses screen.width as reference since the WKWebView frame may be zero at this point.
private let constrainWidthsJS = """
    (function() {
        if (!document.body) return;
        var vw = window.screen.width || 600;
        var els = document.body.querySelectorAll('table,td,th,div,p,section');
        for (var i = 0; i < els.length; i++) {
            var el = els[i];
            try { if (el.classList && (el.classList.contains('tm-quote-wrapper') || el.classList.contains('tm-quote-toggle') || el.classList.contains('tm-quote-content'))) continue; } catch(_) {}
            var w = el.offsetWidth;
            if (w > vw) {
                el.style.setProperty('width', 'auto', 'important');
                el.style.setProperty('max-width', '100%', 'important');
                el.style.setProperty('min-width', '0', 'important');
            }
        }
    })();
    """

/// Dark mode fix (injected as WKUserScript at document end — no blink).
/// - Near-white (bright + low saturation) backgrounds → stripped to transparent.
/// - Colored backgrounds → dimmed to ~brightness 80 so white text is readable.
/// - Dark inline text → forced to light #fbfbfe.
/// - Links inside colored-bg elements → forced to white (overrides CSS blue).
private let fixDarkModeColorsJS = """
    (function() {
        if (!window.matchMedia('(prefers-color-scheme: dark)').matches) return;
        var LIGHT = '#fbfbfe';
        function parseRGB(s) {
            if (!s) return null;
            var m = s.match(/rgba?\\(\\s*(\\d+),\\s*(\\d+),\\s*(\\d+)(?:,\\s*([\\d.]+))?\\)/);
            if (m) return {r:+m[1], g:+m[2], b:+m[3], a:m[4]!=null?+m[4]:1};
            return null;
        }
        function lum(r,g,b) { return (r*299+g*587+b*114)/1000; }
        function sat(r,g,b) { return Math.max(r,g,b) - Math.min(r,g,b); }
        var els = document.querySelectorAll('body, body *');
        for (var i = 0; i < els.length; i++) {
            var el = els[i];
            var cs = window.getComputedStyle(el);
            var bg = parseRGB(cs.backgroundColor);
            var hasBg = bg && bg.a > 0.1;
            var bgL = hasBg ? lum(bg.r, bg.g, bg.b) : 256;
            var bgS = hasBg ? sat(bg.r, bg.g, bg.b) : 0;
            var nearWhite = hasBg && bgL > 220 && bgS < 10;
            var coloredBg = hasBg && !nearWhite;
            if (nearWhite) {
                // Near-white → transparent so the card bubble background shows through.
                // Previously used opaque #000 to prevent "see-through stacking" in nested
                // elements, but that covers the card's background color. Transparent is
                // correct because the card itself provides the dark background in dark mode.
                el.style.setProperty('background-color', 'transparent', 'important');
                if (el.style.background) el.style.setProperty('background', 'transparent', 'important');
                if (el.hasAttribute('bgcolor')) el.removeAttribute('bgcolor');
            }
            if (coloredBg && bgL > 80) {
                var f = 80 / bgL;
                var nr = Math.round(bg.r * f);
                var ng = Math.round(bg.g * f);
                var nb = Math.round(bg.b * f);
                var dimmed = 'rgb(' + nr + ',' + ng + ',' + nb + ')';
                el.style.setProperty('background-color', dimmed, 'important');
                if (el.style.background) el.style.setProperty('background', dimmed, 'important');
            }
            var tc = parseRGB(cs.color);
            // Skip <a> AND descendants of <a>: the dark-mode @media rule sets
            // anchor color to #0a84ff (iOS system blue — high contrast on dark),
            // but Outlook/Word wraps anchor text in <span class="EmailStyle17">
            // with color:windowtext. That span has lum<128 → previously overridden
            // to near-white, producing "white text with blue underline" since the
            // anchor's text-decoration-color still resolves to its own blue.
            // Anchors set their own color via CSS; descendants should inherit.
            // The contrast safety net below still catches low-contrast edge cases.
            var inAnchor = el.tagName === 'A' || el.closest('a') !== null;
            if (tc && lum(tc.r, tc.g, tc.b) < 128 && !inAnchor) {
                el.style.setProperty('color', LIGHT, 'important');
            }
            if (el.tagName === 'FONT' && el.hasAttribute('color')) {
                var tc2 = parseRGB(cs.color);
                if (tc2 && lum(tc2.r, tc2.g, tc2.b) < 128) {
                    el.removeAttribute('color');
                    el.style.setProperty('color', LIGHT, 'important');
                }
            }
            if (coloredBg) {
                var links = el.querySelectorAll('a');
                for (var j = 0; j < links.length; j++) {
                    links[j].style.setProperty('color', LIGHT, 'important');
                }
            }
        }
        // Post-conversion contrast safety net: fix text that's too close to its effective background
        function sRGBtoLinear(v) { v /= 255; return v <= 0.04045 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4); }
        function relLum(r,g,b) { return 0.2126 * sRGBtoLinear(r) + 0.7152 * sRGBtoLinear(g) + 0.0722 * sRGBtoLinear(b); }
        function contrastRatio(l1, l2) { return (Math.max(l1,l2) + 0.05) / (Math.min(l1,l2) + 0.05); }
        function effectiveBg(el) {
            var cur = el;
            while (cur) {
                var bg2 = parseRGB(window.getComputedStyle(cur).backgroundColor);
                if (bg2 && bg2.a > 0.5) return bg2;
                cur = cur.parentElement;
            }
            return {r:0, g:0, b:0, a:1};
        }
        var all = document.querySelectorAll('body, body *');
        for (var k = 0; k < all.length; k++) {
            var el2 = all[k];
            var tc3 = parseRGB(window.getComputedStyle(el2).color);
            if (!tc3) continue;
            var ebg = effectiveBg(el2);
            var textL = relLum(tc3.r, tc3.g, tc3.b);
            var bgL2 = relLum(ebg.r, ebg.g, ebg.b);
            if (contrastRatio(textL, bgL2) < 3) {
                el2.style.setProperty('color', bgL2 > 0.5 ? '#1a1a1a' : LIGHT, 'important');
            }
        }
    })();
    """

/// Shared walk-up logic: given an initial `quoteStart` node, climb the parent
/// chain and return the highest ancestor whose preceding siblings contain only
/// whitespace / trivial text. Stops as soon as we find a preceding sibling with
/// real text content (that's the main message body — must not be collapsed).
///
/// Defined as a top-level JS string so that `collapseQuotesJS` (production) and
/// `EmailFilterTests.walkUpToWrapStart` (unit test via JSContext with synthetic
/// tree mocks) consume the **same source** — zero-drift guarantee.
///
/// The function makes no assumption about tag name (no BLOCKQUOTE exception):
/// the prior-content guard is sufficient on its own. A nested attribution
/// blockquote whose outer sibling is the real quoted content will walk up to
/// the container so the real quote gets swept into the wrapper.
let walkUpToWrapStartJS = """
function walkUpToWrapStart(quoteStart, body, logFn) {
    while (quoteStart.parentNode && quoteStart.parentNode !== body) {
        var hasPriorContent = false;
        for (var sib = quoteStart.previousSibling; sib; sib = sib.previousSibling) {
            if ((sib.textContent || '').trim().length >= 2) { hasPriorContent = true; break; }
        }
        if (hasPriorContent) {
            logFn('[QuoteDetect] Walk-up stopped: prior content found at ' + quoteStart.tagName + '.' + (quoteStart.className || ''));
            break;
        }
        quoteStart = quoteStart.parentNode;
    }
    return quoteStart;
}
"""

/// Shared "lift-attribution-out-of-block" helper.
///
/// When the attribution text node lives inside a block that ALSO holds the
/// user's reply text — e.g. a Thunderbird `moz-cite-prefix` div that folded
/// the reply *and* the "On X wrote:" line into one container, while the
/// actual `<blockquote>` of quoted content sits as the block's outer
/// sibling — the block walk-up in `collapseQuotesJS` would otherwise grab
/// the whole block and sweep the reply into the wrapper.
///
/// This helper detects that situation by scanning `targetNode`'s previous
/// siblings within the same block for non-trivial text (>= 2 chars, matching
/// `walkUpToWrapStart`'s threshold). When found, it physically lifts the
/// attribution out of the block: a new `<div class="tm-quote-split-block">`
/// is inserted immediately after the original block, and `targetNode` plus
/// all of its subsequent in-block siblings are moved into the new block.
///
/// The returned new block becomes the wrap-start. Because it now sits at
/// the original block's level (not nested inside it), the subsequent wrap
/// loop in `collapseQuotesJS` can sweep the *outer* siblings of the
/// original block — e.g. a sibling `<blockquote>` next to a moz-cite-prefix
/// div — into the wrapper. And `walkUpToWrapStart` stops at the new block
/// because its previous sibling (the original block) still carries the
/// reply text.
///
/// Returns `null` when no split is needed (no prior in-block text, non-text
/// target, or detached / root-level target).
///
/// Defined as a top-level JS string so that production (`collapseQuotesJS`)
/// and unit tests (JSContext + synthetic node trees) consume the same source.
let splitBlockBeforeTargetJS = """
function splitBlockBeforeTarget(targetNode, doc, logFn) {
    if (!targetNode || targetNode.nodeType !== 3) return null;
    var block = targetNode.parentNode;
    if (!block || !block.parentNode) return null;
    var hasPriorText = false;
    for (var ps = targetNode.previousSibling; ps; ps = ps.previousSibling) {
        if ((ps.textContent || '').trim().length >= 2) { hasPriorText = true; break; }
    }
    if (!hasPriorText) return null;
    logFn('[QuoteDetect] Prior text in same block — lifting attribution out of ' + block.tagName + '.' + (block.className || '') + ' into a new sibling block');
    var splitBlock = doc.createElement('div');
    splitBlock.className = 'tm-quote-split-block';
    var blockParent = block.parentNode;
    if (block.nextSibling) {
        blockParent.insertBefore(splitBlock, block.nextSibling);
    } else {
        blockParent.appendChild(splitBlock);
    }
    var move = targetNode;
    while (move) {
        var nextMove = move.nextSibling;
        splitBlock.appendChild(move);
        move = nextMove;
    }
    return splitBlock;
}
"""

/// Quote collapse: detect quote boundaries using comprehensive patterns
/// matching the Thunderbird addon's quoteAndSignature.js — multi-language
/// attribution lines, Outlook headers, forwarded messages, dash separators, > prefix.
/// Wraps everything from the quote boundary to end of body in a collapsible section.
///
/// `_log` is gated by `DebugModeManager.isLoggingEnabled()` at Swift compile time:
/// when debug logging is off, `_log` is injected as a no-op so per-line DOM / QuoteDetect
/// traces don't cross the JS↔native bridge (they can saturate the WebProcess message
/// queue and contribute to WebContent crashes on pathological bodies).
private var collapseQuotesJS: String {
    let logBody = DebugModeManager.isLoggingEnabled()
        ? "try { window.webkit.messageHandlers.consoleLog.postMessage(m); } catch(_) {}"
        : ""
    return """
    (function() {
        function _log(m) { \(logBody) }
        \(walkUpToWrapStartJS)
        \(splitBlockBeforeTargetJS)
        var body = document.body;
        if (!body) { _log('[QuoteDetect] No body, bailing'); return; }
        var existingWrapper = body.querySelector('.tm-quote-wrapper');
        _log('[QuoteDetect] Start. existingWrapper=' + !!existingWrapper + ', bodyChildren=' + body.children.length + ', bodyHTML=' + body.innerHTML.substring(0, 500));
        if (existingWrapper) return;

        // Build detection text by walking DOM — avoids innerText/textContent
        // offset mismatches and skips moz-main-header (current message headers
        // would otherwise trigger the Outlook "From:" detection pattern).
        var _segments = [];
        var _dt = '';
        function _appendText(nd, tx) {
            var s = String(tx || '');
            if (!s) return;
            var st = _dt.length;
            _dt += s;
            _segments.push({ kind: 'text', node: nd, start: st, end: _dt.length });
        }
        function _appendNL() { if (_dt.endsWith('\\n')) return; _dt += '\\n'; }
        var _BT = {DIV:1,P:1,TR:1,TD:1,TH:1,LI:1,UL:1,OL:1,TABLE:1,TBODY:1,THEAD:1,TFOOT:1,BLOCKQUOTE:1,PRE:1,HR:1};
        function _walkD(nd) {
            if (!nd) return;
            if (nd.nodeType === 3) { _appendText(nd, nd.textContent); return; }
            if (nd.nodeType !== 1) return;
            var tg = (nd.tagName || '').toUpperCase();
            try { if (nd.classList && (nd.classList.contains('moz-main-header') || nd.classList.contains('tm-ics-collapsible'))) return; } catch(_) {}
            if (tg === 'BR') { _appendNL(); return; }
            for (var c = nd.firstChild; c; c = c.nextSibling) _walkD(c);
            if (_BT[tg]) _appendNL();
        }
        _walkD(body);
        var lines = _dt.split('\\n');

        // DEBUG: Log detection text lines
        _log('[QuoteDetect] Total lines: ' + lines.length);
        _log('[QuoteDetect] Detection text (first 2000 chars): ' + JSON.stringify(_dt.substring(0, 2000)));
        for (var di = 0; di < lines.length; di++) {
            var dt = lines[di].trim();
            if (dt) _log('[QuoteDetect] Line ' + di + ': ' + JSON.stringify(dt));
        }

        // Find the first line that matches a quote/reply boundary pattern.
        // Patterns ordered by specificity (most specific first).
        var boundaryLine = -1;
        var isForward = false;

        for (var i = 0; i < lines.length; i++) {
            var line = lines[i];
            var trimmed = line.trim();
            if (!trimmed) continue;

            // Forwarded message header
            if (/^-+\\s*Forwarded Message\\s*-+$/i.test(trimmed)) {
                boundaryLine = i; isForward = true; break;
            }

            // Original Message (Outlook)
            if (/^-+\\s*Original Message\\s*-+\\s*$/i.test(trimmed)) {
                boundaryLine = i; break;
            }

            // Long dash separator (10+) followed by sender headers within next few lines
            if (/^-{10,}\\s*$/.test(trimmed)) {
                var hasSenderHeader = false;
                for (var j = i + 1; j < Math.min(i + 5, lines.length); j++) {
                    var next = lines[j].trim();
                    if (/^\\*?From\\s*:\\*?\\s*/i.test(next) ||
                        /^\\*?Sent\\s*:\\*?\\s*/i.test(next) ||
                        /^\\*?(\\uBCF4\\uB0B8\\s*\\uC0AC\\uB78C|\\uBCF4\\uB0B8\\s*\\uB0A0\\uC9DC)\\s*:\\*?\\s*/i.test(next) ||
                        /^\\*?(\\uBC1B\\uB294\\s*\\uC0AC\\uB78C|\\uC81C\\uBAA9)\\s*:\\*?\\s*/i.test(next) ||
                        /^\\*?(\\u53D1\\u4EF6\\u4EBA|\\u65E5\\u671F)\\s*:/.test(next) ||
                        /^\\*?(\\u6536\\u4EF6\\u4EBA|\\u4E3B\\u9898)\\s*:\\*?\\s*/.test(next)) {
                        hasSenderHeader = true; break;
                    }
                }
                if (hasSenderHeader) { boundaryLine = i; break; }
            }

            // Korean sender headers
            if (/^\\*?(\\uBCF4\\uB0B8\\s*\\uC0AC\\uB78C)\\s*:\\*?\\s*/i.test(trimmed) ||
                /^\\*?(\\uBCF4\\uB0B8\\s*\\uB0A0\\uC9DC)\\s*:\\*?\\s*/i.test(trimmed)) {
                boundaryLine = i; break;
            }

            // Chinese sender headers
            if (/^\\*?\\u53D1\\u4EF6\\u4EBA\\s*:\\*?\\s*/.test(trimmed) ||
                /^\\*?\\u65E5\\u671F\\s*:\\*?\\s*/.test(trimmed)) {
                boundaryLine = i; break;
            }

            // Outlook-style "From:" header block (check for Sent/Date, To, Subject nearby)
            if (/^From:\\s*/i.test(trimmed)) {
                var headerCount = 1;
                for (var k = i + 1; k < Math.min(i + 6, lines.length); k++) {
                    var nl = lines[k].trim();
                    if (/^(Sent|Date|To|Subject):\\s*/i.test(nl)) headerCount++;
                }
                // Also check lines before (Outlook sometimes puts From after a separator)
                for (var k2 = Math.max(0, i - 3); k2 < i; k2++) {
                    var pl = lines[k2].trim();
                    if (/^(Sent|Date|To|Subject):\\s*/i.test(pl)) headerCount++;
                }
                if (headerCount >= 3) { boundaryLine = i; break; }
            }

            // Attribution lines — multiple languages
            // Patterns from EmailFilter.quoteAttributionPatterns (single source of truth)
            \(EmailFilter.quoteAttributionPatternsAsJS())
            // "On ..." (multi-line: next line ends with "wrote:")
            if (/^On\\s+.+$/i.test(trimmed) && i + 1 < lines.length) {
                var nextLine = lines[i + 1].trim();
                _log('[QuoteDetect] On... candidate at line ' + i + ': ' + JSON.stringify(trimmed) + ' | next: ' + JSON.stringify(nextLine));
                if (/wrote:\\s*$/i.test(nextLine)) {
                    _log('[QuoteDetect] MATCH multi-line On...wrote: at lines ' + i + '-' + (i+1));
                    boundaryLine = i; break;
                }
            }
            // Multi-line attribution: join current + next line and re-test all
            // single-line patterns. Handles narrow screens where long attribution
            // lines wrap at arbitrary points (e.g., Chinese Gmail "于...写道：" splits
            // before the date, Korean "님이...작성:" splits mid-line, etc.).
            //
            // Guard: if line i+1 ALONE already matches the attribution pattern,
            // do NOT fire here — the single-line check will match cleanly at i+1.
            // Without this guard, any non-attribution preceding line (e.g. a
            // signature line) + a real attribution line on i+1 would greedily
            // match via the join, producing a false "multi-line" log entry.
            if (i + 1 < lines.length && boundaryLine === -1) {
                var joined = trimmed + ' ' + lines[i + 1].trim();
                var nextTrimmed = lines[i + 1].trim();
                // Chinese Gmail: "Name <email> 于2026年3月17日周二 01:16写道："
                var _cnRe = /^.+\\u4E8E.+\\u5199\\u9053[\\uFF1A:]\\s*$/;
                if (_cnRe.test(joined) && !_cnRe.test(nextTrimmed)) {
                    boundaryLine = i;
                    _log('[QuoteDetect] MATCH multi-line Chinese attribution at lines ' + i + '-' + (i+1) + ', boundaryLine=' + boundaryLine);
                    break;
                }
                // Korean Gmail: "...님이 작성:"
                var _krRe = /^.+\\uB2D8\\uC774\\s*\\uC791\\uC131\\s*:\\s*$/;
                if (_krRe.test(joined) && !_krRe.test(nextTrimmed)) {
                    boundaryLine = i;
                    _log('[QuoteDetect] MATCH multi-line Korean attribution at lines ' + i + '-' + (i+1) + ', boundaryLine=' + boundaryLine);
                    break;
                }
                // Generic "wrote:" across line break
                var _wrRe = /^.+\\s+wrote:\\s*$/i;
                if (_wrRe.test(joined) && !_wrRe.test(nextTrimmed)) {
                    boundaryLine = i;
                    _log('[QuoteDetect] MATCH multi-line generic wrote: at lines ' + i + '-' + (i+1) + ', boundaryLine=' + boundaryLine);
                    break;
                }
                // French/German/Spanish/Portuguese across line break
                var _frRe = /^Le\\s+.+\\s+a\\s+.+crit\\s*:\\s*$/i;
                var _deRe = /^Am\\s+.+\\s+schrieb\\s+.+:\\s*$/i;
                var _esRe = /^El\\s+.+\\s+escribi.+:\\s*$/i;
                var _ptRe = /^Em\\s+.+\\s+escreveu\\s*:\\s*$/i;
                var _intlNextAlone = _frRe.test(nextTrimmed) || _deRe.test(nextTrimmed) || _esRe.test(nextTrimmed) || _ptRe.test(nextTrimmed);
                if ((_frRe.test(joined) || _deRe.test(joined) || _esRe.test(joined) || _ptRe.test(joined)) && !_intlNextAlone) {
                    boundaryLine = i;
                    _log('[QuoteDetect] MATCH multi-line intl attribution at lines ' + i + '-' + (i+1) + ', boundaryLine=' + boundaryLine);
                    break;
                }
            }
        }

        // Fallback: look for > prefix quoted lines (only if no other pattern matched)
        if (boundaryLine === -1) {
            for (var q = 0; q < lines.length; q++) {
                if (/^>/.test(lines[q])) {
                    // Need at least 2 consecutive > lines to count
                    if (q + 1 < lines.length && /^>/.test(lines[q + 1])) {
                        boundaryLine = q; break;
                    }
                }
            }
        }

        _log('[QuoteDetect] Result: boundaryLine=' + boundaryLine + ', isForward=' + isForward);
        if (boundaryLine === -1) return;

        // Inline reply detection: if the user interleaved responses between
        // quoted blocks, don't collapse — the message IS the reply content.
        // Port of TB addon's hasInlineAnswersInDOM heuristic.
        var allBQs = body.querySelectorAll('blockquote');
        var topLevelBQs = [];
        for (var bi = 0; bi < allBQs.length; bi++) {
            var bq = allBQs[bi];
            if (!bq.parentElement || !bq.parentElement.closest('blockquote')) {
                topLevelBQs.push(bq);
            }
        }
        // Inline reply detection: if the user interleaved responses between
        // quoted blocks, find the last blockquote that has no non-trivial
        // text after it — collapse from there to end. If ALL blockquotes
        // have text after them, nothing to collapse.
        _log('[QuoteDetect] topLevelBQs: ' + topLevelBQs.length);
        if (topLevelBQs.length >= 2) {
            var hasInline = false;
            for (var ii = 0; ii < topLevelBQs.length - 1; ii++) {
                var node = topLevelBQs[ii].nextSibling;
                while (node && node !== topLevelBQs[ii + 1]) {
                    var txt = (node.textContent || '').trim();
                    if (txt.length >= 2) { hasInline = true; break; }
                    node = node.nextSibling;
                }
                if (hasInline) break;
            }
            if (hasInline) {
                // Find the last top-level blockquote with no non-trivial
                // text after it — that's the trailing quoted section.
                var trailingBQ = null;
                for (var ti = topLevelBQs.length - 1; ti >= 0; ti--) {
                    var afterNode = topLevelBQs[ti].nextSibling;
                    var hasTextAfter = false;
                    while (afterNode) {
                        var afterTxt = (afterNode.textContent || '').trim();
                        if (afterTxt.length >= 2) { hasTextAfter = true; break; }
                        afterNode = afterNode.nextSibling;
                    }
                    if (!hasTextAfter) { trailingBQ = topLevelBQs[ti]; break; }
                }
                if (!trailingBQ) { _log('[QuoteDetect] Inline reply: all BQs have text after, bailing'); return; }
                // Use the trailing blockquote directly — do NOT walk up to body child.
                // The trailing BQ may be nested inside containers (e.g. div.gmail_quote)
                // that also hold the inline reply text; walking up would collapse everything.
                var quoteStart = trailingBQ;
                // Skip the normal text-offset detection, jump straight to wrapping
                var isForwardInline = isForward;
                var showLabelI = isForwardInline ? 'Show forwarded message' : 'Show quoted text';
                var hideLabelI = isForwardInline ? 'Hide forwarded message' : 'Hide quoted text';
                var wrapperI = document.createElement('div');
                wrapperI.className = 'tm-quote-wrapper tm-collapsed';
                var toggleI = document.createElement('div');
                toggleI.className = 'tm-quote-toggle';
                toggleI.innerHTML = '<span class="tm-quote-toggle-text">' + showLabelI + '</span>';
                toggleI.addEventListener('click', function(e) {
                    e.stopPropagation();
                    wrapperI.classList.toggle('tm-collapsed');
                    var collapsed = wrapperI.classList.contains('tm-collapsed');
                    toggleI.innerHTML = '<span class="tm-quote-toggle-text">' + (collapsed ? showLabelI : hideLabelI) + '</span>';
                    setTimeout(function() {
                        try { window.webkit.messageHandlers.heightChanged.postMessage(document.body.scrollHeight); } catch(ex) {}
                    }, 50);
                });
                var contentI = document.createElement('div');
                contentI.className = 'tm-quote-content';
                quoteStart.parentNode.insertBefore(wrapperI, quoteStart);
                wrapperI.appendChild(toggleI);
                wrapperI.appendChild(contentI);
                while (quoteStart.nextSibling) {
                    var ns = quoteStart.nextSibling;
                    try { if (ns.classList && ns.classList.contains('tm-ics-collapsible')) break; } catch(_) {}
                    contentI.appendChild(ns);
                }
                contentI.insertBefore(quoteStart, contentI.firstChild);
                return;
            }
        }

        // Calculate char offset of the boundary line in the full text.
        // Skip leading whitespace on the boundary line — inter-element
        // whitespace text nodes (HTML indentation) can precede the actual
        // content node, causing the segment lookup to find the wrong node.
        var charOffset = 0;
        for (var ci = 0; ci < boundaryLine; ci++) {
            charOffset += lines[ci].length + 1; // +1 for newline
        }
        var rawBoundaryLine = lines[boundaryLine];
        var firstNonWS = rawBoundaryLine.search(/\\S/);
        if (firstNonWS > 0) charOffset += firstNonWS;

        // Find text node at charOffset using the segment map (consistent
        // with detection text offsets — no innerText/textContent mismatch).
        var targetNode = null;
        for (var si = 0; si < _segments.length; si++) {
            var seg = _segments[si];
            if (seg.kind === 'text' && charOffset >= seg.start && charOffset < seg.end) {
                targetNode = seg.node;
                break;
            }
        }
        if (!targetNode) {
            for (var si2 = 0; si2 < _segments.length; si2++) {
                if (_segments[si2].kind === 'text' && _segments[si2].start >= charOffset) {
                    targetNode = _segments[si2].node;
                    break;
                }
            }
        }
        _log('[QuoteDetect] charOffset=' + charOffset + ', targetNode=' + (targetNode ? 'found (text: ' + JSON.stringify((targetNode.textContent || '').substring(0, 80)) + ')' : 'NULL'));
        if (!targetNode) return;

        // Composer quirk: a block (e.g. Thunderbird's moz-cite-prefix div) can
        // fold both the user's reply text AND the attribution line into the
        // same container, while the actual `<blockquote>` of quoted content
        // sits as the block's outer sibling. The block walk-up below would
        // then grab the whole container and sweep the reply into the wrapper
        // — and inserting a marker INSIDE the block can't reach the outer
        // blockquote either. So we lift the attribution out: a new sibling
        // block is inserted after the original, and the attribution text +
        // any subsequent in-block siblings are moved into it. The new block
        // sits at the original's level so the wrap loop sees outer siblings.
        // Logic lives in `splitBlockBeforeTargetJS` for unit testability.
        var splitBlock = splitBlockBeforeTarget(targetNode, document, _log);
        var quoteStart;
        if (splitBlock) {
            quoteStart = splitBlock;
            _log('[QuoteDetect] Using split block as quoteStart (parent=' + splitBlock.parentNode.tagName + '.' + (splitBlock.parentNode.className || '') + ')');
        } else {
            // Find the closest block-level ancestor
            quoteStart = targetNode.parentElement;
            while (quoteStart && quoteStart !== body) {
                var display = window.getComputedStyle(quoteStart).display;
                if (display === 'block' || display === 'flex' || display === 'table' ||
                    quoteStart.tagName === 'DIV' || quoteStart.tagName === 'P' ||
                    quoteStart.tagName === 'BLOCKQUOTE' || quoteStart.tagName === 'TABLE' ||
                    quoteStart.tagName === 'BR') {
                    break;
                }
                quoteStart = quoteStart.parentElement;
            }
            _log('[QuoteDetect] quoteStart after block walk: ' + (quoteStart ? quoteStart.tagName + '.' + (quoteStart.className || '') : 'NULL/body'));
            if (!quoteStart || quoteStart === body) return;

            // If inside a blockquote, use the blockquote
            var bq = quoteStart.closest ? quoteStart.closest('blockquote') : null;
            if (bq && body.contains(bq)) {
                _log('[QuoteDetect] Using closest blockquote instead');
                quoteStart = bq;
            }
        }

        // Walk quoteStart up so we capture everything from the boundary to the
        // end of the message — including sibling blockquotes that come after.
        // Logic lives in shared `walkUpToWrapStartJS` (top-level in this file)
        // so unit tests can exercise it with synthetic tree mocks. See the
        // walkUpToWrapStartJS doc comment for semantics.
        quoteStart = walkUpToWrapStart(quoteStart, body, _log);
        _log('[QuoteDetect] Final quoteStart: ' + quoteStart.tagName + '.' + (quoteStart.className || '') + ', parent=' + (quoteStart.parentNode ? quoteStart.parentNode.tagName : 'null'));

        // Labels
        var showLabel = isForward ? 'Show forwarded message' : 'Show quoted text';
        var hideLabel = isForward ? 'Hide forwarded message' : 'Hide quoted text';

        // Create wrapper
        var wrapper = document.createElement('div');
        wrapper.className = 'tm-quote-wrapper tm-collapsed';

        var toggle = document.createElement('div');
        toggle.className = 'tm-quote-toggle';
        toggle.innerHTML = '<span class="tm-quote-toggle-text">' + showLabel + '</span>';
        toggle.addEventListener('click', function(e) {
            e.stopPropagation();
            wrapper.classList.toggle('tm-collapsed');
            var collapsed = wrapper.classList.contains('tm-collapsed');
            toggle.innerHTML = '<span class="tm-quote-toggle-text">' + (collapsed ? showLabel : hideLabel) + '</span>';
            // Signal native side to re-measure height
            setTimeout(function() {
                try { window.webkit.messageHandlers.heightChanged.postMessage(document.body.scrollHeight); } catch(ex) {}
            }, 50);
        });

        var content = document.createElement('div');
        content.className = 'tm-quote-content';

        quoteStart.parentNode.insertBefore(wrapper, quoteStart);
        wrapper.appendChild(toggle);
        wrapper.appendChild(content);

        // Move everything from quoteStart to end into content (but not ICS sections)
        while (quoteStart.nextSibling) {
            var ns = quoteStart.nextSibling;
            try { if (ns.classList && ns.classList.contains('tm-ics-collapsible')) break; } catch(_) {}
            content.appendChild(ns);
        }
        content.insertBefore(quoteStart, content.firstChild);

    })();
    """ }

/// Separate script for ICS invite collapsible sections.
/// Runs independently from quote collapse — finds `.tm-ics-collapsible` markers
/// and wraps them using the same CSS classes as quotes.
private let collapseICSJS = """
    (function() {
        var icsMarkers = document.querySelectorAll('.tm-ics-collapsible');
        if (!icsMarkers.length) return;
        for (var i = 0; i < icsMarkers.length; i++) {
            (function(icsDiv) {
                var showLabel = 'Show invite details';
                var hideLabel = 'Hide invite details';
                var wrapper = document.createElement('div');
                wrapper.className = 'tm-quote-wrapper tm-collapsed';
                wrapper.style.marginTop = '12px';
                var toggle = document.createElement('div');
                toggle.className = 'tm-quote-toggle';
                toggle.innerHTML = '<span class="tm-quote-toggle-text">' + showLabel + '</span>';
                toggle.addEventListener('click', function(e) {
                    e.stopPropagation();
                    wrapper.classList.toggle('tm-collapsed');
                    var collapsed = wrapper.classList.contains('tm-collapsed');
                    toggle.innerHTML = '<span class="tm-quote-toggle-text">' + (collapsed ? showLabel : hideLabel) + '</span>';
                    setTimeout(function() {
                        try { window.webkit.messageHandlers.heightChanged.postMessage(document.body.scrollHeight); } catch(ex) {}
                    }, 50);
                });
                var content = document.createElement('div');
                content.className = 'tm-quote-content';
                while (icsDiv.firstChild) {
                    content.appendChild(icsDiv.firstChild);
                }
                icsDiv.parentNode.insertBefore(wrapper, icsDiv);
                wrapper.appendChild(toggle);
                wrapper.appendChild(content);
                icsDiv.parentNode.removeChild(icsDiv);
            })(icsMarkers[i]);
        }
    })();
    """

/// Height monitor — the canonical "push from JS → Swift" height pipeline.
///
/// Uses `ResizeObserver` on `document.body` (the modern, native "size
/// changed" signal). Whenever body's layout dimensions change (image
/// decoded, font loaded, CSS settled, width widened), we post a
/// dictionary containing:
///   - `h`: `document.body.scrollHeight` in CSS px (content-only, since
///     our `html, body { height: auto; min-height: 0 }` override
///     prevents the viewport-height floor from inflating it)
///   - `vp`: `window.innerWidth` in CSS px (the layout viewport,
///     post-widening)
/// Swift converts the height to device points with
/// `bounds.width / vp` and sets `@State height`. One message per real
/// layout change, content-only measurement.
///
/// NOT `max(body.scrollHeight, documentElement.scrollHeight)` — that
/// includes the layout-viewport-height floor. NOT `scrollView.contentSize.height`
/// via KVO — same viewport-floor inflation on the Swift side.
///
/// Exposed as `internal var` (via `_monitorHeightJS` below) for unit tests
/// to verify the expected JS patterns (ResizeObserver primary, window.__tmLayoutVp
/// read, payload shape) haven't regressed.
internal var _monitorHeightJS: String { monitorHeightJS }
private let monitorHeightJS = """
    (function() {
        var lastH = 0;
        function report() {
            var scroll = document.body.scrollHeight;
            var rect = Math.ceil(document.body.getBoundingClientRect().height);
            // Prefer bounding rect (actual rendered height) over scrollHeight
            // (which includes any overflow-y scrollable area, e.g. from a
            // `min-height: 100vh` body cascade that survives our override).
            // They almost always agree; when they don't, rect is the visible
            // extent and what the user actually sees.
            var h = rect > 0 && rect < scroll ? rect : scroll;
            // Prefer the widened layout viewport stored by fitViewportJS —
            // window.innerWidth is unreliable in iOS WebKit after a runtime
            // viewport-meta change (WebKit bug 170595). When not widened,
            // prefer the Swift-stamped device width (__tmDeviceWidth, set by
            // fit() from webView.bounds.width — at the device-width baseline
            // 1 CSS px == 1 pt, so it IS the layout viewport). Fall back to
            // window.innerWidth only before the first fit() has stamped it
            // (initial documentEnd report).
            var vp = window.__tmLayoutVp || window.__tmDeviceWidth || window.innerWidth;
            if (h > 0 && h !== lastH) {
                lastH = h;
                try {
                    window.webkit.messageHandlers.heightChanged.postMessage({ h: h, vp: vp, scroll: scroll, rect: rect });
                } catch(e) {}
            }
        }
        // Expose report on window so fitViewportJS can call it on its own
        // settling timer after a meta widen. Necessary because ResizeObserver
        // can fire once mid-reflow with a stale body.scrollHeight (4191 in our
        // Fireworks repro) and never re-fire even though body.scrollHeight
        // settles to the correct value (4349) ~100-300ms later. The widen path
        // schedules explicit re-reads anchored to the widen event itself.
        window.__tmReportHeight = report;
        // ResizeObserver fires on every genuine layout change to body.
        // Takes over from the older MutationObserver+image-event pattern
        // — ResizeObserver is cheaper (fires only on size changes, not
        // every DOM mutation) and more accurate (catches CSS-only layout
        // shifts that don't mutate the DOM).
        if (window.ResizeObserver) {
            new ResizeObserver(report).observe(document.body);
        } else {
            // Fallback for pre-iOS 13.4: MutationObserver + periodic check.
            new MutationObserver(function() { setTimeout(report, 100); })
                .observe(document.body, { childList: true, subtree: true, attributes: true });
        }
        // Image-load listeners. ResizeObserver should fire when a loading
        // image's natural size resolves and grows body, but in practice on
        // iOS WKWebView with `BodyAssetSchemeHandler`-served inline images
        // (and external CDN images with `width=N` attributes that resolve
        // late), RO fires once mid-load with a stale body.scrollHeight (e.g.
        // 4191) and never re-fires when body grows to its final size (4349)
        // ~100ms later. Listening directly to img.load / img.error events
        // gives us a deterministic re-fire trigger anchored to the actual
        // event (image bytes ready) rather than to the layout system's
        // best-effort observer. Each fire goes through report()'s lastH
        // dedup, so no spam if body didn't actually grow.
        function attachImageListeners() {
            var imgs = document.getElementsByTagName('img');
            for (var i = 0; i < imgs.length; i++) {
                var img = imgs[i];
                if (img.__tmListenersAttached) continue;
                img.__tmListenersAttached = true;
                if (img.complete) continue; // already loaded; nothing to wait for
                img.addEventListener('load', function() { setTimeout(report, 50); }, { once: true });
                img.addEventListener('error', function() { setTimeout(report, 50); }, { once: true });
            }
        }
        attachImageListeners();
        // window.load fires after ALL subresources (images, stylesheets,
        // scheme-handler-served assets) finish loading. By then body's
        // scrollHeight has converged to its final value. One last sanity
        // re-fire belt-and-suspenders covers any image that escapes the
        // per-img listener (e.g. background-image CSS, dynamically-added
        // imgs by author scripts).
        if (document.readyState !== 'complete') {
            window.addEventListener('load', function() { setTimeout(report, 50); }, { once: true });
        }
        // Report current size once immediately, and again shortly after
        // in case body hasn't been laid out yet when this script runs.
        report();
        setTimeout(report, 100);
        setTimeout(report, 500);
    })();
    """

/// Debug report JS — logs DOM state after all other scripts have run.
/// Gated by DebugModeManager so it's a no-op in production.
private var htmlDebugReportJS: String {
    guard DebugModeManager.isLoggingEnabled() else { return "" }
    return """
    (function() {
        try {
            var body = document.body;
            if (!body) { window.webkit.messageHandlers.consoleLog.postMessage('[HTMLDebug] JS: document.body is null!'); return; }
            var bodyHTML = body.innerHTML;
            var textLen = (body.innerText || '').length;
            var childCount = body.children.length;
            var quoteWrappers = body.querySelectorAll('.tm-quote-wrapper').length;
            var collapsedQuotes = body.querySelectorAll('.tm-quote-wrapper.tm-collapsed').length;
            var hiddenEls = 0;
            var allEls = body.querySelectorAll('*');
            for (var i = 0; i < allEls.length; i++) {
                var s = window.getComputedStyle(allEls[i]);
                if (s.display === 'none' || s.visibility === 'hidden' || s.opacity === '0') hiddenEls++;
            }
            window.webkit.messageHandlers.consoleLog.postMessage(
                '[HTMLDebug] JS DOM report: bodyInnerHTML=' + bodyHTML.length + 'chars'
                + ' visibleText=' + textLen + 'chars directChildren=' + childCount
                + ' totalElements=' + allEls.length + ' hiddenElements=' + hiddenEls
                + ' quoteWrappers=' + quoteWrappers + ' collapsedQuotes=' + collapsedQuotes
                + ' scrollHeight=' + body.scrollHeight
            );
            var preview = (body.innerText || '').substring(0, 300);
            window.webkit.messageHandlers.consoleLog.postMessage('[HTMLDebug] JS visible text preview: ' + preview);

            // --- DOM structure walk ---
            var emailBody = document.querySelector('.tm-email-body');
            if (emailBody) {
                window.webkit.messageHandlers.consoleLog.postMessage(
                    '[HTMLDebug] DOM WALK: .tm-email-body children=' + emailBody.children.length
                    + ' innerHTML=' + emailBody.innerHTML.length + ' offsetH=' + emailBody.offsetHeight
                );
                function walkNode(node, depth, maxDepth, maxSiblings) {
                    if (depth > maxDepth) return;
                    var kids = node.children;
                    var count = Math.min(kids.length, maxSiblings);
                    for (var k = 0; k < count; k++) {
                        var c = kids[k];
                        var tag = c.tagName.toLowerCase();
                        var id = c.id ? '#' + c.id : '';
                        var cls = c.className ? '.' + String(c.className).trim().split(/\\s+/).join('.') : '';
                        var cs = window.getComputedStyle(c);
                        var rect = c.getBoundingClientRect();
                        var txt = (c.innerText || '').length;
                        var imgs = c.querySelectorAll('img').length;
                        var indent = '  '.repeat(depth);
                        window.webkit.messageHandlers.consoleLog.postMessage(
                            '[HTMLDebug] DOM WALK:' + indent + tag + id + cls
                            + ' rect=' + Math.round(rect.width) + 'x' + Math.round(rect.height) + '@' + Math.round(rect.top)
                            + ' display=' + cs.display + ' text=' + txt + ' imgs=' + imgs + ' innerHTML=' + c.innerHTML.length
                        );
                        if (depth < maxDepth) walkNode(c, depth + 1, maxDepth, 8);
                    }
                }
                walkNode(emailBody, 1, 3, 10);

                // Image audit
                var allImgs = emailBody.querySelectorAll('img');
                var loaded = 0, broken = 0, pending = 0, zeroSize = 0;
                for (var ii = 0; ii < allImgs.length; ii++) {
                    var img = allImgs[ii];
                    if (img.complete) { if (img.naturalWidth > 0) loaded++; else broken++; } else { pending++; }
                    if (img.offsetWidth === 0 && img.offsetHeight === 0) zeroSize++;
                }
                window.webkit.messageHandlers.consoleLog.postMessage(
                    '[HTMLDebug] IMAGE AUDIT: total=' + allImgs.length
                    + ' loaded=' + loaded + ' broken=' + broken + ' pending=' + pending + ' zeroSize=' + zeroSize
                );
                for (var ii = 0; ii < Math.min(allImgs.length, 3); ii++) {
                    var img = allImgs[ii];
                    var src = (img.getAttribute('src') || '').substring(0, 120);
                    var cs = window.getComputedStyle(img);
                    window.webkit.messageHandlers.consoleLog.postMessage(
                        '[HTMLDebug] IMAGE #' + (ii+1) + ': ' + img.offsetWidth + 'x' + img.offsetHeight
                        + ' natural=' + img.naturalWidth + 'x' + img.naturalHeight + ' complete=' + img.complete
                        + ' display=' + cs.display + ' visibility=' + cs.visibility
                        + ' loading=' + (img.getAttribute('loading') || 'none') + ' src=' + src
                    );
                }
                if (allImgs.length > 0) {
                    window.webkit.messageHandlers.consoleLog.postMessage(
                        '[HTMLDebug] IMAGE TAG outerHTML: ' + allImgs[0].outerHTML.substring(0, 500)
                    );
                }
            }

            // --- Link color audit: runs for ALL emails (fragment-mode included, not
            // just those with .tm-email-body). Classifies anchors by origin and logs
            // computed color, text-decoration-color, and inline attrs so we can
            // distinguish text-color overrides from underline-color oddities.
            try {
                var allLinks = document.querySelectorAll('a');
                var authorLinks = 0, detectorLinks = 0, whiteLinks = 0, blueLinks = 0;
                function parseRGBlocal(s) {
                    if (!s) return null;
                    var m = s.match(/rgba?\\(\\s*(\\d+),\\s*(\\d+),\\s*(\\d+)/);
                    return m ? {r:+m[1], g:+m[2], b:+m[3]} : null;
                }
                function lumLocal(r,g,b) { return (r*299+g*587+b*114)/1000; }
                for (var li = 0; li < allLinks.length; li++) {
                    var a = allLinks[li];
                    var isDetector = a.hasAttribute('x-apple-data-detectors');
                    if (isDetector) detectorLinks++; else authorLinks++;
                    var ac = parseRGBlocal(window.getComputedStyle(a).color);
                    if (ac) {
                        var al = lumLocal(ac.r, ac.g, ac.b);
                        if (al > 200) whiteLinks++;
                        else if (ac.b > Math.max(ac.r, ac.g) + 30) blueLinks++;
                    }
                }
                window.webkit.messageHandlers.consoleLog.postMessage(
                    '[HTMLDebug] LINK AUDIT: total=' + allLinks.length
                    + ' author=' + authorLinks + ' detector=' + detectorLinks
                    + ' white=' + whiteLinks + ' blue=' + blueLinks
                );
                for (var li = 0; li < Math.min(allLinks.length, 5); li++) {
                    var a = allLinks[li];
                    var href = (a.getAttribute('href') || '').substring(0, 80);
                    var cs = window.getComputedStyle(a);
                    var ac = parseRGBlocal(cs.color);
                    var al = ac ? lumLocal(ac.r, ac.g, ac.b).toFixed(1) : 'n/a';
                    var origin = a.hasAttribute('x-apple-data-detectors') ? 'DETECTOR' : 'AUTHOR';
                    var inlineColor = (a.style && a.style.color) ? a.style.color : '(none)';
                    var inlineDeco = (a.style && a.style.textDecorationColor) ? a.style.textDecorationColor : '(none)';
                    // Parent color: sometimes an ancestor carries a forced color that's
                    // inherited via unset/inherit on the anchor. Log for diagnosis.
                    var parentColor = a.parentElement ? window.getComputedStyle(a.parentElement).color : '(no parent)';
                    // Log colors of immediate DOM descendants too — Outlook wraps
                    // anchor text in <span class="EmailStyle17"> etc. If the child
                    // has a different color than the anchor, that's the visible text.
                    var childInfo = '';
                    var kids = a.querySelectorAll('*');
                    if (kids.length > 0) {
                        var kidColors = [];
                        for (var kk = 0; kk < Math.min(kids.length, 3); kk++) {
                            var k = kids[kk];
                            kidColors.push(k.tagName + ':' + window.getComputedStyle(k).color);
                        }
                        childInfo = ' children=[' + kidColors.join('; ') + ']';
                    }
                    window.webkit.messageHandlers.consoleLog.postMessage(
                        '[HTMLDebug] LINK #' + (li+1) + ' ' + origin
                        + ' color=' + cs.color + ' lum=' + al
                        + ' textDecoColor=' + cs.textDecorationColor
                        + ' textDecoLine=' + cs.textDecorationLine
                        + ' inlineColor=' + inlineColor + ' inlineDeco=' + inlineDeco
                        + ' parentColor=' + parentColor
                        + childInfo
                        + ' href=' + href
                    );
                }
            } catch(e) {
                window.webkit.messageHandlers.consoleLog.postMessage('[HTMLDebug] LINK AUDIT error: ' + e.message);
            }

            // --- Font size audit: find all elements with inline font-size styles ---
            try {
                var fontSizeInline = 0;
                var smallFontCount = 0;
                var fontSizeSamples = [];
                var allInEmail = document.querySelectorAll('.tm-email-body *, body > div[style*="white-space:pre-wrap"] *');
                for (var fi = 0; fi < allInEmail.length; fi++) {
                    var el = allInEmail[fi];
                    var inlineStyle = el.getAttribute('style') || '';
                    if (inlineStyle.indexOf('font-size') !== -1) {
                        fontSizeInline++;
                        if (fontSizeSamples.length < 5) {
                            var m = inlineStyle.match(/font-size\\s*:\\s*([^;]+)/i);
                            fontSizeSamples.push(el.tagName + '[' + (el.className || '') + ']: ' + (m ? m[1].trim() : inlineStyle));
                        }
                    }
                    var cs = window.getComputedStyle(el);
                    var cfs = parseFloat(cs.fontSize);
                    if (cfs > 0 && cfs < 14 && el.innerText && el.innerText.length > 0) {
                        smallFontCount++;
                    }
                }
                window.webkit.messageHandlers.consoleLog.postMessage(
                    '[HTMLDebug] FONT AUDIT: inlineFontSize=' + fontSizeInline + ' elementsWithFontBelow14px=' + smallFontCount
                );
                for (var fs = 0; fs < fontSizeSamples.length; fs++) {
                    window.webkit.messageHandlers.consoleLog.postMessage(
                        '[HTMLDebug] FONT SAMPLE: ' + fontSizeSamples[fs]
                    );
                }

                // Sample computed font sizes for content elements
                var sampleEls = document.querySelectorAll('.tm-email-body p, .tm-email-body span, .tm-email-body div');
                for (var si = 0; si < Math.min(sampleEls.length, 8); si++) {
                    var el = sampleEls[si];
                    var cs = window.getComputedStyle(el);
                    var txt = (el.innerText || '').substring(0, 40).replace(/\\s+/g, ' ');
                    if (txt.length > 0) {
                        window.webkit.messageHandlers.consoleLog.postMessage(
                            '[HTMLDebug] COMPUTED STYLE: <' + el.tagName.toLowerCase() + ' class="' + (el.className || '') + '"> '
                            + 'font-size=' + cs.fontSize + ' line-height=' + cs.lineHeight + ' margin=' + cs.margin
                            + ' text="' + txt + '"'
                        );
                    }
                }
            } catch(e) {
                window.webkit.messageHandlers.consoleLog.postMessage('[HTMLDebug] FONT AUDIT error: ' + e.message);
            }

            // --- Blank space audit: find elements contributing to height without content ---
            try {
                var emailBody2 = document.querySelector('.tm-email-body');
                if (emailBody2) {
                    var bigEmpty = [];
                    var allKids = emailBody2.querySelectorAll('*');
                    for (var ki = 0; ki < allKids.length; ki++) {
                        var el = allKids[ki];
                        var rect = el.getBoundingClientRect();
                        var txt = (el.innerText || '').trim();
                        // Elements with height >= 15px and no visible text (or just nbsp)
                        if (rect.height >= 15 && txt.length <= 2 && el.children.length === 0) {
                            bigEmpty.push({
                                tag: el.tagName.toLowerCase(),
                                cls: el.className || '',
                                h: Math.round(rect.height),
                                style: (el.getAttribute('style') || '').substring(0, 80),
                                txt: JSON.stringify(txt)
                            });
                        }
                    }
                    window.webkit.messageHandlers.consoleLog.postMessage(
                        '[HTMLDebug] BLANK SPACE AUDIT: ' + bigEmpty.length + ' empty elements >= 15px tall in .tm-email-body'
                    );
                    for (var bi = 0; bi < Math.min(bigEmpty.length, 10); bi++) {
                        var e = bigEmpty[bi];
                        window.webkit.messageHandlers.consoleLog.postMessage(
                            '[HTMLDebug]   EMPTY: <' + e.tag + ' class="' + e.cls + '" style="' + e.style + '"> h=' + e.h + ' text=' + e.txt
                        );
                    }
                    // Also dump first 20 children with size to understand layout
                    window.webkit.messageHandlers.consoleLog.postMessage(
                        '[HTMLDebug] ALL CHILDREN of .tm-email-body first descendant:'
                    );
                    var firstKid = emailBody2.children[0];
                    if (firstKid) {
                        var directChildren = firstKid.children;
                        for (var di = 0; di < Math.min(directChildren.length, 30); di++) {
                            var c = directChildren[di];
                            var rect = c.getBoundingClientRect();
                            var cs = window.getComputedStyle(c);
                            var txt = (c.innerText || '').substring(0, 30).replace(/\\s+/g, ' ');
                            window.webkit.messageHandlers.consoleLog.postMessage(
                                '[HTMLDebug]   #' + di + ' <' + c.tagName.toLowerCase() + ' class="' + (c.className || '')
                                + '"> h=' + Math.round(rect.height) + ' fs=' + cs.fontSize
                                + ' m=' + cs.margin + ' text="' + txt + '"'
                            );
                        }
                    }
                }
            } catch(e) {
                window.webkit.messageHandlers.consoleLog.postMessage('[HTMLDebug] BLANK SPACE AUDIT error: ' + e.message);
            }

            // --- mobile-container inline style + all CSS rules audit ---
            var mc = document.querySelector('.mobile-container');
            if (mc) {
                var mcInline = mc.getAttribute('style') || 'none';
                window.webkit.messageHandlers.consoleLog.postMessage(
                    '[HTMLDebug] .mobile-container inline style="' + mcInline + '"'
                );
                try {
                    var sheets = document.styleSheets;
                    for (var si = 0; si < sheets.length; si++) {
                        try {
                            function scanRules(rules, prefix) {
                                for (var ri = 0; ri < rules.length; ri++) {
                                    var r = rules[ri];
                                    if (r.type === CSSRule.MEDIA_RULE) {
                                        var mq = r.conditionText || r.media.mediaText;
                                        var mqMatch = window.matchMedia(mq).matches;
                                        scanRules(r.cssRules, prefix + '@media(' + (mqMatch?'MATCH':'no') + ') ');
                                    } else if (r.selectorText && r.selectorText.indexOf('mobile-container') !== -1) {
                                        window.webkit.messageHandlers.consoleLog.postMessage(
                                            '[HTMLDebug] CSS RULE for .mobile-container: ' + prefix + r.cssText.substring(0, 250)
                                        );
                                    }
                                }
                            }
                            scanRules(sheets[si].cssRules, 'sheet' + si + ': ');
                        } catch(_){}
                    }
                } catch(_){}
            }

            // --- Media query audit ---
            try {
                var sheets = document.styleSheets;
                var mediaRules = [];
                for (var si = 0; si < sheets.length; si++) {
                    try {
                        var rules = sheets[si].cssRules;
                        for (var ri = 0; ri < rules.length; ri++) {
                            if (rules[ri].type === CSSRule.MEDIA_RULE) {
                                var mq = rules[ri].conditionText || rules[ri].media.mediaText;
                                var matches = window.matchMedia(mq).matches;
                                var innerCount = rules[ri].cssRules ? rules[ri].cssRules.length : 0;
                                mediaRules.push({ query: mq, matches: matches, rules: innerCount });
                            }
                        }
                    } catch(_){}
                }
                window.webkit.messageHandlers.consoleLog.postMessage(
                    '[HTMLDebug] MEDIA QUERY audit: ' + mediaRules.length + ' @media blocks found'
                );
                for (var mi = 0; mi < mediaRules.length; mi++) {
                    var m = mediaRules[mi];
                    window.webkit.messageHandlers.consoleLog.postMessage(
                        '[HTMLDebug] @media #' + (mi+1) + ': "' + m.query + '" matches=' + m.matches + ' innerRules=' + m.rules
                    );
                }
                window.webkit.messageHandlers.consoleLog.postMessage(
                    '[HTMLDebug] Viewport: innerWidth=' + window.innerWidth + ' screen.width=' + screen.width
                    + ' devicePixelRatio=' + window.devicePixelRatio
                );
            } catch(e) {}
        } catch(e) {
            window.webkit.messageHandlers.consoleLog.postMessage('[HTMLDebug] JS debug report error: ' + e.message);
        }
    })();
    """
}

/// Multi-stage, id-correlated height diagnostic for the "WebView renders with
/// internal scroll after FitViewport widen" investigation. Fires per-load
/// (NOT once per WebView lifetime — WebKit may reload an HTMLString into the
/// same WKWebView, e.g. `webViewWebContentProcessDidTerminate` recovery, and
/// we want a fresh timeline each time).
///
/// Output shape: every emitted log line is prefixed with `[HeightDiag id=XXXXXX]`
/// where XXXXXX matches the same id on `[Load]`, `[MeasureHeight]`, and
/// `[ContentSizeKVO]` lines for the same WebView. Grep `id=XXXXXX` to extract a
/// single email's complete render timeline out of mixed log streams (multiple
/// WebViews coexist on screen for thread-card messages, focused message, etc.).
///
/// Snapshot stages: t100 / t300 / t800 / t1500 / t3000 ms after document end.
/// Each stage emits the same set of fields so they can be diff'd in column.
/// Image-heavy emails finish loading subresources up to ~1.5s in (esp. on
/// scheme-handler-served inline images that read from disk through
/// `BodyAssetSchemeHandler`); seeing how the layout converges (or doesn't)
/// across these stages is the only reliable way to distinguish "still settling"
/// from "permanent body-vs-html delta."
///
/// Each snapshot emits:
///   - env: innerWidth, innerHeight, layoutVp (window.__tmLayoutVp), DPR
///   - body: scrollHeight / offsetHeight / clientHeight / rect.h / rect.bottom
///   - html (documentElement): same set
///   - delta: html minus body for each metric (smoking gun: scroll-delta != 0)
///   - body computed style: margin / padding / display / position
///   - html computed style: margin / padding
///   - First 6 body children: tag, first class, rect, offsetH, mT/mB/pT/pB,
///     display, position
///   - Descendants whose bottom edge extends past body.bottom (max 5) — the
///     specific elements responsible for delta when present
///
/// Privacy: zero text content, zero URLs, zero hrefs. Only tag names, first
/// CSS class (template-level identifiers, safe to share), and numeric layout
/// values. The output is designed so anonymized regression fixtures can be
/// reconstructed mechanically from the logs.
///
/// Gated by `DebugModeManager.isLoggingEnabled()`; emits empty string in
/// production so the WKUserScript is a no-op.
internal var _heightDiagnosticJS: String { heightDiagnosticJS }
private var heightDiagnosticJS: String {
    guard DebugModeManager.isLoggingEnabled() else { return "" }
    return """
    (function() {
        // No once-per-load guard: this script reruns on each loadHTMLString
        // call (per-load JS context is fresh anyway). __tmDiagId is set by
        // Swift on didFinish via evaluateJavaScript and may be unset for the
        // first ~1ms; readers fall back to '?'.
        function id() { return window.__tmDiagId || '?'; }

        function log(msg) {
            try { window.webkit.messageHandlers.consoleLog.postMessage('[HeightDiag id=' + id() + '] ' + msg); } catch(_) {}
        }

        function snap(stage) {
            var b = document.body, h = document.documentElement;
            if (!b || !h) { log(stage + ' SKIP body/html missing'); return; }
            var bRect = b.getBoundingClientRect(), hRect = h.getBoundingClientRect();
            var bcs = window.getComputedStyle(b), hcs = window.getComputedStyle(h);
            var vp = window.__tmLayoutVp || window.innerWidth;
            log(stage + ' env: innerW=' + window.innerWidth + ' innerH=' + window.innerHeight + ' layoutVp=' + vp + ' dpr=' + window.devicePixelRatio + ' readyState=' + document.readyState);
            log(stage + ' body: scroll=' + b.scrollHeight + ' offset=' + b.offsetHeight + ' client=' + b.clientHeight + ' rectH=' + bRect.height.toFixed(2) + ' rectTop=' + bRect.top.toFixed(2) + ' rectBottom=' + bRect.bottom.toFixed(2));
            log(stage + ' html: scroll=' + h.scrollHeight + ' offset=' + h.offsetHeight + ' client=' + h.clientHeight + ' rectH=' + hRect.height.toFixed(2) + ' rectTop=' + hRect.top.toFixed(2) + ' rectBottom=' + hRect.bottom.toFixed(2));
            log(stage + ' delta(h-b): scroll=' + (h.scrollHeight - b.scrollHeight) + ' offset=' + (h.offsetHeight - b.offsetHeight) + ' client=' + (h.clientHeight - b.clientHeight) + ' rectH=' + (hRect.height - bRect.height).toFixed(2));
            log(stage + ' bodyCS: m=' + bcs.margin + ' p=' + bcs.padding + ' d=' + bcs.display + ' pos=' + bcs.position);
            log(stage + ' htmlCS: m=' + hcs.margin + ' p=' + hcs.padding);
        }

        function walkChildren(stage) {
            var b = document.body;
            if (!b) return;
            var kids = b.children;
            var n = Math.min(kids.length, 6);
            log(stage + ' bodyChildren count=' + kids.length + ' (showing ' + n + ')');
            for (var i = 0; i < n; i++) {
                var c = kids[i];
                var r = c.getBoundingClientRect();
                var cs = window.getComputedStyle(c);
                var cls = '';
                try {
                    var raw = (typeof c.className === 'string') ? c.className : (c.getAttribute('class') || '');
                    cls = raw.split(/\\s+/).filter(function(s){ return s; })[0] || '';
                } catch(_) {}
                log(stage + '   [' + i + '] ' + c.tagName + (cls ? '.' + cls : '')
                    + ' rect=' + Math.round(r.width) + 'x' + r.height.toFixed(1) + '@y=' + r.top.toFixed(1)
                    + ' offsetH=' + c.offsetHeight
                    + ' mT=' + cs.marginTop + ' mB=' + cs.marginBottom
                    + ' pT=' + cs.paddingTop + ' pB=' + cs.paddingBottom
                    + ' d=' + cs.display + ' pos=' + cs.position);
            }
        }

        function findOverflow(stage) {
            var b = document.body;
            if (!b) return;
            var bBottom = b.getBoundingClientRect().bottom;
            var els = b.getElementsByTagName('*');
            var hits = [];
            for (var i = 0; i < els.length && hits.length < 5; i++) {
                var e = els[i];
                var er = e.getBoundingClientRect();
                if (er.bottom > bBottom + 0.5) {
                    var cls = '';
                    try {
                        var raw = (typeof e.className === 'string') ? e.className : (e.getAttribute('class') || '');
                        cls = raw.split(/\\s+/).filter(function(s){ return s; })[0] || '';
                    } catch(_) {}
                    var pos = window.getComputedStyle(e).position;
                    hits.push(e.tagName + (cls ? '.' + cls : '')
                        + ' bottom=' + er.bottom.toFixed(2)
                        + ' (body.bottom=' + bBottom.toFixed(2) + ', overflow=+' + (er.bottom - bBottom).toFixed(2) + ')'
                        + ' pos=' + pos);
                }
            }
            if (hits.length > 0) {
                log(stage + ' overflowingDescendants:');
                for (var k = 0; k < hits.length; k++) log(stage + '   → ' + hits[k]);
            } else {
                log(stage + ' overflowingDescendants: none — delta is on body itself');
            }
        }

        function fullSnap(stage) {
            try {
                snap(stage);
                walkChildren(stage);
                findOverflow(stage);
            } catch(e) {
                log(stage + ' EXCEPTION: ' + (e && e.message ? e.message : e));
            }
        }

        // Multi-stage timeline. setTimeout is a one-shot; setInterval is
        // forbidden by the no-polling rule in EmailRenderPipelineTests.
        var stages = [100, 300, 800, 1500, 3000];
        for (var i = 0; i < stages.length; i++) {
            (function(t) { setTimeout(function() { fullSnap('t' + t); }, t); })(stages[i]);
        }

        // Also snap on the actual DOM 'load' event (after all subresources
        // including images served via BodyAssetSchemeHandler). For most
        // emails this lands somewhere between t300 and t1500; for image-heavy
        // ones it may be later than t3000.
        if (document.readyState !== 'complete') {
            window.addEventListener('load', function() {
                setTimeout(function() { fullSnap('onload'); }, 0);
            }, { once: true });
        } else {
            setTimeout(function() { fullSnap('onload-immediate'); }, 0);
        }
    })();
    """
}

/// Step 1: Find the rightmost edge of any element via getBoundingClientRect.
/// If content overflows the viewport, widen the viewport meta to content width —
/// the browser auto-scales the wider viewport to fit the device screen.
/// Cap at 1200px to prevent extreme zoom-out from very long URLs or wide tables.
///
/// **This is where the visual "shrink" comes from.** When viewport widens from
/// the native device width (e.g. 320px) to the content width (e.g. 640px), the
/// browser renders everything at 320/640 = 50% scale on-screen. A 16px CSS font
/// becomes 8px visible. To keep content readable, we must NOT widen unless the
/// overflow is truly unavoidable (e.g. wide code blocks, uncompressible images).
/// Our CSS already forces `img { max-width: 100% }` and `.tm-email-body * { max-width: 100% }`
/// so most cases shouldn't overflow. When it DOES overflow, the debug log below
/// identifies the culprit element so we can tighten the CSS.
/// Internal accessor for unit tests to inspect the emitted JS (widening
/// policy, STANDARD_MIN floor, window.__tmLayoutVp stamp, forced reflow).
/// JS that returns the document to the device-width baseline before a re-fit
/// (updateUIView's width-change path). Re-stamps `__tmDeviceWidth` with the
/// new width, clears `__tmLayoutVp` — REQUIRED: fitViewportJS's idempotency
/// guard bails while it's set, and monitorHeightJS would keep scaling heights
/// against the stale widened viewport — then restores the width=device-width
/// meta. Exposed as `internal` for unit tests (same pattern as `_fitViewportJS`).
internal func viewportResetJS(deviceWidth: Int) -> String {
    "window.__tmDeviceWidth = \(deviceWidth); window.__tmLayoutVp = 0; "
        + "document.querySelector('meta[name=\"viewport\"]').setAttribute('content','width=device-width,initial-scale=1,maximum-scale=5,user-scalable=yes')"
}

internal var _fitViewportJS: String { fitViewportJS }
private let fitViewportJS: String = {
    let debug = DebugModeManager.isLoggingEnabled()
    let logPrefix = debug ? """
        function log(s) { try { window.webkit.messageHandlers.consoleLog.postMessage('[FitViewport] ' + s); } catch(_){} }
        """ : "function log(s) {}"
    return """
    (function() {
        \(logPrefix)
        // IDEMPOTENCY GUARD — this function measures the document and then
        // MUTATES it (meta widen, inline width strips, body padding zeroing).
        // Running it again on an already-widened document re-measures widened
        // CSS px against an unreliable window.innerWidth (WebKit bug 170595),
        // so the overflow decision is garbage and the widen target / pageScale
        // can drift — the width-arm sibling of the scrollHeight feedback loop
        // that EmailHTMLWrapper's html/body CSS override closed. Observable
        // symptom before this guard: fonts shrank a little more on every
        // background→foreground cycle (the foreground observer re-runs fit()).
        // Same document + same device width → same answer: if we already
        // widened, there is nothing to re-derive. Re-fits for a REAL width
        // change (rotation, sheet resize) go through updateUIView's
        // viewportResetJS path, which restores width=device-width and clears
        // this global before calling fit again.
        if (window.__tmLayoutVp) { log('already fitted (layoutVp=' + window.__tmLayoutVp + ') — idempotent no-op'); return true; }
        // Measure against the Swift-stamped device-pt width (fit() stamps
        // __tmDeviceWidth from webView.bounds.width immediately before this
        // script runs). At the device-width baseline 1 CSS px == 1 pt, so it
        // IS the layout viewport. window.innerWidth is only the fallback for
        // a hypothetical unstamped run — it is unreliable after meta/bounds
        // changes (WebKit bug 170595).
        var vw = window.__tmDeviceWidth || window.innerWidth;
        log('enter: vw=' + vw + ' innerWidth=' + window.innerWidth + ' screenWidth=' + window.screen.width + ' devicePixelRatio=' + window.devicePixelRatio);
        if (vw < 100) { log('skip: viewport too small'); return false; }
        // Strip hardcoded widths from non-table block elements wider than
        // viewport. CSS max-width works fine on divs/p/sections, so this is
        // mostly belt-and-suspenders. Tables/cells are EXCLUDED: many email
        // templates set `width="100%"` on outer wrappers intentionally so the
        // table grows with its container. Stripping it to `width:auto` makes
        // the table content-driven, and after viewport widening the table
        // no longer fills the widened parent — leaving visible left/right
        // margins where the auto-centered table sits inside a wider body.
        var toFix = document.body.querySelectorAll('div,p,section');
        var fixCount = 0;
        var fixSamples = [];
        for (var i = 0; i < toFix.length; i++) {
            var elWidth = toFix[i].getBoundingClientRect().width;
            if (elWidth > vw + 1) {
                if (fixSamples.length < 5) {
                    fixSamples.push(toFix[i].tagName + '[' + (toFix[i].className || '') + '] w=' + Math.round(elWidth));
                }
                toFix[i].style.setProperty('width', 'auto', 'important');
                toFix[i].style.setProperty('min-width', '0', 'important');
                fixCount++;
            }
        }
        log('constrained ' + fixCount + ' oversized elements (vw=' + vw + ')');
        for (var s = 0; s < fixSamples.length; s++) log('  fix sample: ' + fixSamples[s]);

        // No Pass 2 table reflow. Prior attempts (display:block + tbody hacks,
        // word-break descendants, CSS zoom) all broke some layouts — multi-column
        // newsletters collapsed columns to one character per line, nested tables
        // with width:100% compounded zoom artifacts, etc. The only approach that
        // is both deterministic and preserves the sender's layout is to widen
        // the viewport meta to fit the content width and let WebKit scale the
        // whole document down proportionally. Fonts shrink, but so do widths,
        // images, and spacing — the email just appears slightly smaller, which
        // is what every mainstream mobile mail client does for desktop-width
        // HTML emails.

        // Measure the rightmost edge across every descendant of body.
        var maxRight = 0;
        var culprit = null;
        var els = document.body.getElementsByTagName('*');
        for (var i = 0; i < els.length; i++) {
            var r = els[i].getBoundingClientRect().right;
            if (r > maxRight) { maxRight = r; culprit = els[i]; }
        }
        log('maxRight=' + Math.round(maxRight) + ' vs vw=' + vw);
        if (culprit && maxRight > vw + 10) {
            var culpritInfo = (culprit.tagName + '.' + (culprit.className || '') + ' w=' + Math.round(culprit.getBoundingClientRect().width)
                + ' style=' + (culprit.getAttribute('style') || 'none').substring(0, 120));
            log('OVERFLOW CULPRIT: ' + culpritInfo);
            var txt = (culprit.innerText || '').substring(0, 120).replace(/\\s+/g, ' ');
            log('  culprit text: "' + txt + '"');
            log('  culprit outerHTML[0:300]: ' + (culprit.outerHTML || '').substring(0, 300));
            var nowrap = culprit.querySelectorAll('[style*="nowrap"]');
            if (nowrap.length > 0) {
                log('  culprit has ' + nowrap.length + ' nowrap descendants');
                for (var ni = 0; ni < Math.min(nowrap.length, 3); ni++) {
                    log('    nowrap: ' + nowrap[ni].tagName + ' style=' + (nowrap[ni].getAttribute('style') || '').substring(0, 80));
                }
            }
            var a = culprit.parentElement;
            var depth = 0;
            while (a && depth < 6) {
                var aw = a.getBoundingClientRect().width;
                log('  ancestor[' + depth + '] ' + a.tagName + '.' + (a.className || '') + ' w=' + Math.round(aw));
                a = a.parentElement;
                depth++;
            }
        }
        // Only widen when content actually overflows. For plain-text and
        // responsive emails that fit at device width, keep the native 1.0×
        // scale — widening those would render text smaller than the email
        // sender intended (16 px → 11.5 px at 288/400). When we DO need to
        // widen, floor at STANDARD_MIN so slightly-overflowing content
        // renders at a consistent scale rather than 0.94× vs 0.80×.
        // Cap at 1200 to avoid extreme shrink on pathologically wide pages.
        var STANDARD_MIN = 400;
        var contentWidth = Math.ceil(maxRight);
        if (contentWidth <= vw) {
            log('no overflow — viewport stays at ' + vw + 'px (content fits)');
            return false;
        }
        var targetWidth = Math.min(Math.max(contentWidth, STANDARD_MIN), 1200);
        var scaleFactor = (vw / targetWidth).toFixed(2);
        log('WIDENING viewport to ' + targetWidth + 'px → CONTENT WILL RENDER AT ' + scaleFactor + 'x SCALE');
        var meta = document.querySelector('meta[name="viewport"]');
        if (meta) {
            meta.setAttribute('content', 'width=' + targetWidth + ', maximum-scale=5, user-scalable=yes');
        }
        // Stash the widened layout viewport width in a global. window.innerWidth
        // is unreliable in iOS WebKit after a runtime viewport-meta change
        // (WebKit bug 170595: innerWidth is bogus after resize in WKWebView),
        // so monitorHeightJS's ResizeObserver reads this instead. The meta
        // above is what the layout is actually using, authoritative.
        window.__tmLayoutVp = targetWidth;
        // When widened, the scale factor already introduces implicit
        // breathing room on each side, so the body's 16px horizontal
        // padding just doubles the visible inset. Zero it out (keep
        // vertical padding intact).
        document.body.style.setProperty('padding-left', '0', 'important');
        document.body.style.setProperty('padding-right', '0', 'important');
        // Force a synchronous reflow so the new viewport meta takes
        // effect immediately. Without this, the first measurement
        // pass still sees the pre-widening innerWidth and reports a
        // too-tall frame that snaps smaller on the next pass — visible
        // as a brief flicker during load.
        void document.documentElement.offsetHeight;
        // Schedule re-measurement reports anchored to the WIDEN event,
        // not to document end. ResizeObserver can fire once mid-reflow
        // with a stale body.scrollHeight (Fireworks repro: RO reports
        // 4191 but body settles to 4349 ~100ms later) and never re-fire.
        //
        // Each scheduled callback BYPASSES monitorHeightJS's lastH dedup
        // by posting the message directly with `source` flagged. Necessary
        // because the previous version (calling __tmReportHeight, which
        // dedups on lastH) produced ZERO extra posts in 7/7 Fireworks
        // opens — either the setTimeouts didn't fire (timer throttling
        // when the WebView is briefly off-screen during sheet present),
        // or body.scrollHeight was still 4191 at fire time. The
        // diag-logged path here distinguishes the two on the next repro:
        // if `source` lines appear in [MeasureHeight], they fired; if
        // they're absent, the timers never ran. Either way, the direct
        // post means a settled-late body.scrollHeight reaches Swift's
        // `if visualHeight != height` dedup, which is the right place.
        function postAfterWiden(stage) {
            try {
                var scroll = document.body.scrollHeight;
                var rect = Math.ceil(document.body.getBoundingClientRect().height);
                var h = rect > 0 && rect < scroll ? rect : scroll;
                var vp = window.__tmLayoutVp || window.innerWidth;
                if (h > 0) {
                    log('postWiden(' + stage + ') firing: scroll=' + scroll + ' rect=' + rect + ' h=' + h + ' innerW=' + window.innerWidth);
                    window.webkit.messageHandlers.heightChanged.postMessage({ h: h, vp: vp, scroll: scroll, rect: rect, source: 'postWiden-' + stage });
                }
            } catch(e) {
                log('postWiden(' + stage + ') ERROR: ' + (e && e.message ? e.message : e));
            }
        }
        setTimeout(function() { postAfterWiden(200); }, 200);
        setTimeout(function() { postAfterWiden(600); }, 600);
        setTimeout(function() { postAfterWiden(1500); }, 1500);
        return true;
    })();
    """
}()

/// Height measurement lives in the Coordinator now (KVO on
/// scrollView.contentSize + scale by bounds/viewport). See fitAndObserve
/// and applyContentSize above. No polling, no JS height measurement, no
/// +Npt overshoot bandaid — one observer, fires when WebKit has a genuine
/// layout change to report.

