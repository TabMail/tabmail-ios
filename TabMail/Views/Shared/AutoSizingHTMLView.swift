/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import SwiftUI
import WebKit
import CryptoKit
import Synchronization

/// Native channels exposed only to TabMail's isolated content world.
/// Kept top-level so the exact registration set is regression-testable.
internal let _renderBridgeChannels = [
    "heightChanged",
    "consoleLog",
    "gutterAdjust",
    "imageLoadFailure"
]

/// Auto-sizing WKWebView that reports its content height to SwiftUI.
///
/// `bodyContentKey` opt-in: when non-nil, registers a `BodyAssetSchemeHandler`
/// BOUND TO THAT KEY on the WKWebViewConfiguration, so HTML
/// `<img src="tabmail-asset://...">` refs resolve to bytes from `BodyAssetStore`
/// **that this message owns** and to nothing else.
///
/// ⚠️ P1d changed the opt-in from `headerId` to `bodyContentKey` (ADR-IOS-076
/// decision 5; plan §10.1 C3 + C5). The two are separate parameters on purpose:
/// `headerId` is a `MessageHeader.id` used ONLY for the height/reveal seed cache,
/// while the asset owner must be the body's authoritative `MessageBody.id`
/// (`ContentKey`). Rebuilding the owner key from `headerId` is exactly the trap
/// `MessageBody`'s own doc comment documents — a plain `String` that 35 call sites
/// pass unwrapped with no cast, no warning and no diagnostic.
///
/// **Each call site chooses EXPLICITLY**: carry the source `MessageBody.id`, or
/// accept that local assets are unavailable. Compose preview / `.eml` preview /
/// tooltip mocks pass nil and get no scheme handler. Compensating with an
/// unrestricted asset lookup is forbidden.
struct AutoSizingHTMLView: View {
    let html: String
    let previewFilename: String?
    let headerId: String?
    /// The rendered body's `MessageBody.id`, or nil for the call sites that render
    /// something other than a persisted body. Part of the web view's IDENTITY —
    /// see the `.id(…)` in `body`.
    let bodyContentKey: ContentKey?
    /// Explicit same-bytes reload trigger used by pull-to-refresh.
    let reloadToken: Int
    /// Called immediately before native applies a height payload atomically
    /// tagged as originating after app-owned quote/invite disclosure.
    let onUserDisclosureToggle: () -> Void
    @State private var height: CGFloat
    /// True once the WKWebView has actually revealed its content (the JS
    /// `reveal()` flips opacity 0→1 and posts `{revealed:true}`). Until then a
    /// real message body (headerId != nil) shows a loading placeholder so the
    /// user never stares at a blank body area during the ~1s WKWebView
    /// parse/layout (the document sits at opacity:0 until reveal). Reset when the
    /// bound `html` changes (e.g. pull-to-refresh) so the placeholder returns
    /// while the new content renders.
    @State private var hasRevealed = false
    /// Horizontal gutter per side, seeded at the 16pt minimum and REDUCED by the
    /// email's own measured content inset via the `gutterAdjust` message (see
    /// `eatGutterMarginsJS`). The 16 is never lowered as a floor — total indent
    /// stays `max(16, emailInset)` — it just stops our gutter double-counting the
    /// email's own indent.
    @State private var leadingPad: CGFloat = 16
    @State private var trailingPad: CGFloat = 16
    init(
        html: String,
        previewFilename: String? = nil,
        headerId: String? = nil,
        bodyContentKey: ContentKey? = nil,
        reloadToken: Int = 0,
        onUserDisclosureToggle: @escaping () -> Void = {}
    ) {
        self.html = html
        self.previewFilename = previewFilename
        self.headerId = headerId
        self.bodyContentKey = bodyContentKey
        self.reloadToken = reloadToken
        self.onUserDisclosureToggle = onUserDisclosureToggle
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
        let seededHeight = Self.seededHeight(headerId: headerId)
        _height = State(initialValue: seededHeight ?? 1)
        // Same row-recreation problem, applied to the reveal flag: a
        // HeightSeedCache entry is only ever written from the numeric-height
        // branch of handleHeightMessage, which the fit pipeline reaches after
        // JS `reveal()` has already fired for this exact content — so its
        // presence means this message rendered successfully earlier in this
        // session. Without this, a List-recycled row re-enters with
        // hasRevealed reset to false and flashes the "Loading message…"
        // placeholder for ~200ms-1s while the recreated WKWebView redundantly
        // redoes a load it already completed (logmain.log 2026-07-14: same
        // messageId flips content → loadingSpinner → content on scroll-back).
        // `.onChange(of: html)` still resets this if the content genuinely
        // changed (e.g. pull-to-refresh) — see below.
        _hasRevealed = State(initialValue: Self.initialHasRevealed(headerId: headerId))
    }

    /// The applied measurement this message left in `HeightSeedCache` earlier in
    /// the session, or `nil` if it has none. Single source of BOTH seeded
    /// `@State` values in `init`, extracted so the seeding invariant is
    /// assertable without a SwiftUI render pass (`@State` initial values are not
    /// observable from outside one).
    ///
    /// `nil` means "this message has never completed a render in this session"
    /// — a genuinely new row, which MUST still show the loading placeholder.
    nonisolated static func seededHeight(headerId: String?) -> CGFloat? {
        headerId.flatMap { HeightSeedCache.shared[$0] }
    }

    /// The initial `hasRevealed` for a freshly constructed view, i.e. whether
    /// this view may skip the loading placeholder outright.
    ///
    /// `true` exactly when a seed exists. A seed is written ONLY from the
    /// numeric-height branch of `handleHeightMessage`, which the fit pipeline
    /// reaches after JS `reveal()` has already fired for this exact content — so
    /// a seed present means "this message already rendered successfully in this
    /// session", which is precisely the recycled-row case that must NOT flash
    /// the placeholder again. No seed means a genuinely new row, which must.
    nonisolated static func initialHasRevealed(headerId: String?) -> Bool {
        seededHeight(headerId: headerId) != nil
    }

    /// Loading placeholder only for real message bodies (compose/eml/tooltip
    /// previews pass headerId == nil) and only until the first reveal.
    private var showsLoadingPlaceholder: Bool { headerId != nil && !hasRevealed }

    var body: some View {
        HTMLWebView(html: html, previewFilename: previewFilename, headerId: headerId, bodyContentKey: bodyContentKey, reloadToken: reloadToken, onUserDisclosureToggle: onUserDisclosureToggle, height: $height, hasRevealed: $hasRevealed, leadingPad: $leadingPad, trailingPad: $trailingPad)
            // ── P1d (ADR-IOS-076 decision 5; plan §10.1 C4): the body ContentKey is
            // part of the representable's IDENTITY, so a change to it dismantles the
            // platform view and `makeUIView` runs again.
            //
            // A `WKURLSchemeHandler` is installed ONCE on the configuration, inside
            // `makeUIView`; `updateUIView` cannot replace it. SwiftUI may reuse the
            // platform view across an update in which the body ContentKey changes
            // (row identity is `stableId`), so a handler bound at construction goes
            // stale in BOTH directions — legitimate assets denied for the new
            // document, and an old asset servable to a new document that names its
            // id. Asset ids are not secrets, so that needs a structural fix rather
            // than an argument.
            //
            // ⚠️ A MUTABLE handler key is worse and was REJECTED: in-flight
            // `WKURLSchemeTask`s would straddle the mutation.
            // ⚠️ Do NOT confuse this with the rejected alternative of recreating the
            // web view per DOCUMENT GENERATION (view churn on the appearance and
            // process-recovery paths). This recreates on body-ContentKey change —
            // a different trigger, and one that fires only when the message a view
            // is bound to actually changes identity (e.g. a move re-keys the row).
            .id(bodyContentKey?.rawValue ?? "")
            // While a real body is still rendering, reserve room for the
            // placeholder so it's visible even before the web view reports a
            // height. Once revealed (or for non-body previews) size strictly to
            // content — identical to the previous `max(height, 1)` behavior.
            .frame(height: max(height, showsLoadingPlaceholder ? 80 : 1))
            // Suppress implicit animation on height changes. Without this, the
            // initial @State height=1 grows to the first measured value with a
            // spring animation inherited from a parent (List / ScrollView /
            // sheet), which reads as visual fluctuation during load. The
            // height should snap directly to each measured value.
            .animation(.none, value: height)
            .overlay {
                if showsLoadingPlaceholder {
                    VStack(spacing: 8) {
                        ProgressView()
                        Text("Loading message…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            // All gutters live here in the SwiftUI container, not in body CSS.
            // The web view's content fills its frame exactly; breathing room
            // is applied outside. Doing this here ensures the padding is a
            // constant pt value regardless of whether fitViewportJS widened
            // the layout viewport — a CSS `padding: 12px` bottom would shrink
            // to 8.6 pt visually when widened (12 × 0.72 scale), producing an
            // inconsistent bubble-bottom gap across emails.
            // Horizontal is the dynamic gutter (16pt minimum, reduced by the
            // email's own inset via gutterAdjust). `.animation(.none)` so the
            // one-time reduce-on-load doesn't slide (it lands while the body is
            // still opacity:0, but a parent animation could otherwise pick it up).
            .padding(.leading, leadingPad)
            .padding(.trailing, trailingPad)
            .animation(.none, value: leadingPad)
            .animation(.none, value: trailingPad)
            .padding(.bottom, 12)
            // Reset the placeholder when the bound content changes (pull-to-
            // refresh swaps in a new body). MUST be `.onChange`, not a reset
            // inside the `.task` below: `.task(id:)` re-runs on every
            // RECREATION of this view (List row recycling), not only on id
            // changes, so a reset there wipes the seeded hasRevealed one frame
            // after init and re-flashes the placeholder on scroll-back — the
            // exact symptom the init seeding exists to prevent. `.onChange`
            // fires only on actual value changes, never on initial appearance.
            .onChange(of: html) { _, _ in
                guard headerId != nil else { return }
                if hasRevealed { hasRevealed = false }
            }
            // P1d diagnostics: the ONE place a ContentKey-driven view recreate is
            // observable from Swift. `.id(…)` above dismantles and rebuilds the
            // platform view without telling anyone, so a smoke test that sees
            // images vanish needs this line to tell "the view was rebound to a
            // different message" from "the handler refused the asset". Truncated
            // keys only — enough to correlate, not enough to reconstruct a mailbox
            // path. Debug-gated per development rule 12.
            .onChange(of: bodyContentKey) { old, new in
                guard DebugModeManager.isLoggingEnabled() else { return }
                let render = { (k: ContentKey?) in k.map { String($0.rawValue.prefix(12)) + "…" } ?? "(none)" }
                print("[RenderSec] body ContentKey changed \(render(old)) → \(render(new)) — recreating the web view")
            }
            // Safety timeout so a missed reveal signal can never strand the
            // placeholder forever. `.task(id: html)` restarts on every content
            // change (re-arming the timeout for the new document) and is
            // cancelled on disappear.
            .task(id: html) {
                guard headerId != nil else { return }
                try? await Task.sleep(for: .seconds(4))
                if !hasRevealed { hasRevealed = true }
            }
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
    #if DEBUG
    /// Test-only completion witness for the Coordinator's async main-queue
    /// scroll-freeze flush turn. Production behavior does not consume it.
    static let renderHeightFlushCompletedForTests = Notification.Name("renderHeightFlushCompletedForTests")
    #endif
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
///
/// ⚠️ DO NOT KEY THIS CACHE BY CONTENT. Adding `html` to the key looks like an
/// obvious tightening and would silently resurrect the bug `f93cf685f` fixed.
/// Keying by message ALONE is what makes a `List`-recycled row find its seed,
/// because SwiftUI hands the recreated row an equal-but-not-identical `html`
/// String. Key by `(headerId, html)` and every recycled row misses its seed,
/// starts un-revealed, and — since `html` is unchanged, so `updateUIView` runs
/// no reload and JS `reveal()` never fires again — sits under the "Loading
/// message…" placeholder until the 4-second backstop in `.task(id: html)`
/// releases it, on top of a body that is already fully rendered.
///
/// The accepted cost of message-only keying is its mirror image: after a
/// pull-to-refresh replaces a body, the seed written for the OLD content
/// survives, so a recreated row can start revealed for content that has never
/// rendered. That is deliberate and strictly cheaper — there `html` genuinely
/// differs, so `updateUIView` DOES reload and `reveal()` DOES fire, bounding the
/// exposure to one document load (~200 ms–1 s) of correct content with no
/// spinner. Fail-open costs a missing spinner; the fail-closed version cost four
/// seconds of hidden content. Anyone revisiting this must land the change with a
/// red-first test asserting a recycled row with UNCHANGED content still starts
/// revealed — `AutoSizingHTMLViewRevealSeedingTests` covers the seeded-true and
/// seeded-false halves but cannot express the changed-content case, precisely
/// because the key carries no content.
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
    /// The rendered body's `MessageBody.id`. Binds the asset scheme handler and is
    /// part of this representable's SwiftUI identity (see `AutoSizingHTMLView.body`).
    let bodyContentKey: ContentKey?
    let reloadToken: Int
    let onUserDisclosureToggle: () -> Void
    @Binding var height: CGFloat
    @Binding var hasRevealed: Bool
    // Dynamic horizontal gutter: starts at the 16pt minimum and is REDUCED by the
    // email's own measured content inset (eatGutterMarginsJS → gutterAdjust) so the
    // gutter absorbs the email's indent instead of stacking on it. Never below the
    // value the email's own inset frees up; clamped so it can't harm other emails.
    @Binding var leadingPad: CGFloat
    @Binding var trailingPad: CGFloat
    // Observed so SwiftUI re-invokes updateUIView on a light<->dark flip — see the
    // schemeChanged branch in updateUIView (reload so the dark-mode scripts re-run
    // for the new appearance).
    @Environment(\.colorScheme) private var colorScheme

    /// The `WKScriptMessageHandler` channel names, in ONE place so the registration
    /// loop in `makeUIView`, the P3 diagnostic beside it, and the dispatch in
    /// `Coordinator.userContentController(_:didReceive:)` cannot drift apart.
    ///
    /// Order is the historical registration order and is not load-bearing; WebKit keys
    /// delivery by name. `heightChanged` is the only one whose loss would break the
    /// render — see the `consoleLog` gating note in the coordinator.
    ///
    /// `imageLoadFailure` (P4) is diagnostic-only. Disclosure ownership travels
    /// atomically inside `heightChanged`, not on a separate channel whose native
    /// delivery could race the resize it is meant to classify.
    static let bridgeChannels = _renderBridgeChannels

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // ── P1b render hardening (ADR-IOS-076 decision 1; PLAN_EMAIL_RENDER_SECURITY.md §11) ──
        // The message document is FULLY attacker-controlled input: anyone who can mail the user
        // authors it, there is no origin authentication, and there is no user gesture between
        // arrival and render. What remains of P1b's WebKit-boundary half is exactly ONE setting —
        // `allowsContentJavaScript = false` (T1, immediately below). The other half is the CSP in
        // `EmailHTMLWrapper.contentSecurityPolicy`.
        // ⚠️ THREE of the settings P1b introduced here were REVERSED on 2026-08-12 by explicit
        // owner directive — *"no behaviour changes, just security"* — and each was returned to the
        // state `v1.7.8` shipped, which for two of them means UNSET rather than assigned:
        //   • `dataDetectorTypes` — set below, back to `[.link, .phoneNumber]`; own comment there.
        //   • `websiteDataStore` — now UNSET; T5 is OPEN. Read the comment where it used to be.
        //   • `allowsLinkPreview` — now UNSET (WebKit default ON); read the web-view comment below.
        // Do not re-introduce any of the three without asking the owner first.
        // ⚠️ "THREE" is scoped to the settings in THIS file. There is a FOURTH owner reversal under
        // the same directive, in the OTHER half of P1b: `font-src 'none'` → `font-src https:` inside
        // `EmailHTMLWrapper.contentSecurityPolicy` (font leg of T9 open, `IOS-PRIVACY-002`). So the
        // reversal count is four and the reverted-settings count is three; do not restate one as
        // the other.

        // T1 (ROOT). Sender-authored `<script>`, inline event-handler attributes and `javascript:`
        // URLs stop executing. App-injected `WKUserScript`s and `evaluateJavaScript` are UNAFFECTED
        // — WebKit evaluates injected source directly, outside the document's script gate — which
        // is load-bearing here because every single thing this view does (height reporting, reveal,
        // dark mode, quote/ICS collapse, deferred images, width fixes) is a user script. Measured,
        // not assumed: `EmailRenderSecurityCanaryTests` runs the real configuration.
        config.defaultWebpagePreferences.allowsContentJavaScript = false

        // T5 — OPEN, BY OWNER DECISION (2026-08-12), and stated plainly rather than buried.
        // `websiteDataStore` is deliberately NOT set here, so this web view gets
        // `WKWebsiteDataStore.default()`: ONE process-wide PERSISTENT cookie / localStorage /
        // cache jar shared by every message and every sender, surviving app launches. That is a
        // stable cross-sender correlation channel usable by remote subresources ALONE — no sender
        // script required, so `allowsContentJavaScript = false` does not touch it. P1b closed it
        // with a per-view `.nonPersistent()` store; the owner reversed that under *"no behaviour
        // changes, just security"*, AGAINST the implementing side's recommendation to keep the
        // ephemeral store. Registered as `IOS-PRIVACY-001`.
        // ⚠️ Consequences for anyone reading or editing this file:
        //   • Do NOT describe this render path as "isolated" or "sandboxed from other messages".
        //     It shares state with every other render and with any other WKWebView in the app that
        //     also uses the default store.
        //   • Do NOT re-add a store here — neither `.nonPersistent()` per view nor a single shared
        //     ephemeral singleton as a compromise — without asking the owner. Both were considered
        //     and the shipped persistent store was chosen over both.
        // Pinned positively by `EmailRenderSecurityCanaryTests.productionConfiguration`, which
        // asserts BOTH that the store is persistent and that two render views share one instance.

        // Data Detectors: RESTORED to `[.link, .phoneNumber]` on 2026-08-12 by explicit owner
        // directive, reversing P1b's `[]`. TabMail is a PHONE mail client: tap-to-call on a
        // plain-text number in a signature and a tappable bare URL are core affordances, and the
        // owner overruled both the removal and the narrower `[.phoneNumber]`-only compromise that
        // was recommended in its place. Do not re-remove either half without asking the owner.
        //
        // ⚠️ THE SECURITY FACT IS UNCHANGED AND STILL TRUE — §9.1 B2 (verified): Data Detectors
        // sit OUTSIDE the navigation delegate. WebKit's anchor-activation path can present
        // detector UI BEFORE `changeLocation`, so a detected target may never reach
        // `decidePolicyFor` at all. Therefore *"every externally dispatched target passes our
        // `http`/`https` allowlist"* is FALSE while detectors are enabled, and it is false in a
        // way NO delegate-side test can observe. That absolute must never be restated — here, in
        // a test, in an ADR, or in a commit body — without this exception (`MIS-019` shape).
        // This is a KNOWN, ACCEPTED exception: the affordance was chosen over an unqualified
        // absolute, registered as `IOS-UI-002` in `KNOWN_ISSUES.md`.
        // ⚠️ AND IT IS NO LONGER THE ONLY ONE. Since 2026-08-12 `allowsLinkPreview` is unset too
        // (see the web-view comment below), so long-press preview is a SECOND non-delegate fetch
        // route and a second exception to the same absolute — `IOS-UI-003`. Qualify every
        // restatement with BOTH.
        //
        // Scope of the exception, so it is not overstated: authored `<a href>` links are
        // UNAFFECTED by `dataDetectorTypes` — they are `WKNavigationAction`s and still reach
        // `decidePolicyFor`, where `mailto:` interception and P1c's allowlist live. Detectors
        // govern only PLAIN-TEXT phone numbers and BARE URLs.
        config.dataDetectorTypes = [.link, .phoneNumber]
        // ── P1d: asset ownership binding (ADR-IOS-076 decision 5; plan §10.1 C3+C5) ──
        // Register the BodyAssetStore scheme handler when this WebView is rendering
        // a real (persisted) message body. The handler serves bytes from the App
        // Group container in-process — required because WKWebView's sandboxed
        // WebContent process can't read those files via `file://` baseURL on device.
        //
        // The predicate is `bodyContentKey != nil`, NOT `headerId != nil`: the
        // handler now needs the body's authoritative `MessageBody.id` to authorize
        // against, and a call site that cannot supply one gets no handler at all.
        // That is the explicit C5 choice — "accept that local assets are
        // unavailable" — and it fails closed. Compose / `.eml` preview / tooltip
        // paths take that branch.
        //
        // ⚠️ This handler is installed ONCE, here. `updateUIView` cannot replace it,
        // which is why `AutoSizingHTMLView` puts `bodyContentKey` in the view's
        // `.id(…)`: the key can only change by recreating the whole web view.
        if let ownerKey = bodyContentKey {
            config.setURLSchemeHandler(
                BodyAssetSchemeHandler(ownerKey: ownerKey) { line in
                    // The gate lives here because `DebugModeManager` is an app-target
                    // type and `BodyAssetSchemeHandler` also compiles into the NSE.
                    // Read at call time, not captured, so toggling debug logging
                    // takes effect without recreating the web view.
                    guard DebugModeManager.isLoggingEnabled() else { return }
                    print(line)
                },
                forURLScheme: BodyAssetConfig.urlScheme
            )
        }
        // .atDocumentStart bootstrap. Disclosure ownership is installed here,
        // independently of quote parsing, so a later quote-script failure can
        // never break every height producer. The optional per-WebView diagnostic
        // stamp runs in the same first script; the previous didFinish evaluation
        // raced Fireworks' t100 callback and produced [HeightDiag id=?].
        let renderBootstrapJS = _userDisclosureOwnershipJS + (
            DebugModeManager.isLoggingEnabled()
                ? "window.__tmDiagId='\(context.coordinator.webViewId)';"
                : ""
        )
        // ── P3: every script below is built `in: RenderContentWorld.isolated` ──
        // Read `RenderContentWorld` before touching any of the 17 constructions in this
        // block, the 3 `add(…)` registrations, or the 3 `evaluateJavaScript` call sites.
        // A world is a NAMESPACE: our scripts still share ONE DOM with the document, but
        // they get their own `window`, so `__tmLayoutVp` / `__tmFitDone` /
        // `__tmReportHeight` are no longer readable or forgeable by author content. The
        // migration is ALL-OR-NOTHING and fails SILENTLY — one script left in the page
        // world writes to a `window` nobody else in this pipeline can see, and the render
        // dies whole (no height, no dark mode, no quote collapse, no deferred images) in a
        // way no non-`WKWebView` test can observe. This is defense-in-depth; it did NOT
        // enable the CSP, which shipped in P1b with every script still in the page world.
        let renderBootstrap = WKUserScript(source: renderBootstrapJS, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: RenderContentWorld.isolated)
        // Install before parsing reaches any author image/background resources so
        // debug logs can distinguish an actual WebKit load error from a deferred
        // URL that simply has not been assigned yet. Production source is empty.
        let imageLoadDiag = WKUserScript(
            source: imageLoadDiagnosticJS(enabled: DebugModeManager.isLoggingEnabled()),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true,
            in: RenderContentWorld.isolated
        )
        let mediaFix = WKUserScript(source: enforceMediaDisplayJS, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: RenderContentWorld.isolated)
        let widthFix = WKUserScript(source: constrainWidthsJS, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: RenderContentWorld.isolated)
        let darkMode = WKUserScript(source: fixDarkModeColorsJS, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: RenderContentWorld.isolated)
        let emlCleanup = WKUserScript(source: cleanupEmlBodyJS, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: RenderContentWorld.isolated)
        let quoteCollapse = WKUserScript(source: collapseQuotesJS, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: RenderContentWorld.isolated)
        let icsCollapse = WKUserScript(source: collapseICSJS, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: RenderContentWorld.isolated)
        // Production render path — always injected. Only its diagnostic hook is
        // gated, and it is gated by the SAME flag that decides whether
        // imageLoadDiagnosticJS above installs the hook at all, so an ungated
        // build's swap never names a global that only sender script could define.
        let deferImages = WKUserScript(
            source: deferredImageLoadJS(diagnosticsEnabled: DebugModeManager.isLoggingEnabled()),
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true,
            in: RenderContentWorld.isolated
        )
        // After the layout-affecting transforms (quote/ics collapse, eml cleanup)
        // and before height monitoring/fit, so it measures the settled layout.
        let leftFix = WKUserScript(source: constrainLeftOverflowJS, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: RenderContentWorld.isolated)
        // Crops a WHOLESALE per-region indent (e.g. OWA's margin:0 0 16px 40px on
        // every content block) BEFORE eatGutterMarginsJS/fitViewportJS measure, so
        // both see the post-crop layout. See normalizeIndentJS's doc comment.
        let indentCrop = WKUserScript(source: normalizeIndentJS, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: RenderContentWorld.isolated)
        let eatMargins = WKUserScript(source: eatGutterMarginsJS, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: RenderContentWorld.isolated)
        let heightMonitor = WKUserScript(source: monitorHeightJS, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: RenderContentWorld.isolated)
        // After heightMonitor so window.__tmReportHeight is defined when a
        // correction fires; its own load listeners coexist with the height
        // monitor's (a single <img> can carry multiple load listeners).
        let aspectFix = WKUserScript(source: fixImageAspectRatioJS, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: RenderContentWorld.isolated)
        // After heightMonitor: re-checks horizontal overflow once the deferred
        // images have all settled — fit() measures with them hidden, so an
        // image-driven width overflow is invisible to it (see the doc comment
        // on postImageWidthRecheckJS).
        let widthRefit = WKUserScript(source: postImageWidthRecheckJS, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: RenderContentWorld.isolated)
        let debugReport = WKUserScript(source: htmlDebugReportJS, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: RenderContentWorld.isolated)
        let heightDiag = WKUserScript(source: heightDiagnosticJS, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: RenderContentWorld.isolated)
        config.userContentController.addUserScript(renderBootstrap)
        config.userContentController.addUserScript(imageLoadDiag)
        config.userContentController.addUserScript(mediaFix)
        config.userContentController.addUserScript(widthFix)
        config.userContentController.addUserScript(darkMode)
        config.userContentController.addUserScript(emlCleanup)
        config.userContentController.addUserScript(quoteCollapse)
        config.userContentController.addUserScript(icsCollapse)
        config.userContentController.addUserScript(deferImages)
        config.userContentController.addUserScript(leftFix)
        config.userContentController.addUserScript(indentCrop)
        config.userContentController.addUserScript(eatMargins)
        config.userContentController.addUserScript(heightMonitor)
        config.userContentController.addUserScript(aspectFix)
        config.userContentController.addUserScript(widthRefit)
        config.userContentController.addUserScript(debugReport)
        config.userContentController.addUserScript(heightDiag)
        // P3 — the bridge channels, registered INTO THE ISOLATED WORLD. This is the
        // half of the isolation that changes what the DOCUMENT can do, rather than what it
        // can see: `add(_:contentWorld:name:)` publishes
        // `window.webkit.messageHandlers.<name>` only in the world it names, so the page
        // world has no bridge object to post to at all. The registration is driven from
        // `bridgeChannels` so the list, the debug line below and
        // `Coordinator.userContentController(_:didReceive:)` cannot drift apart.
        for channel in HTMLWebView.bridgeChannels {
            config.userContentController.add(context.coordinator,
                                             contentWorld: RenderContentWorld.isolated,
                                             name: channel)
        }

        // P3 diagnostics (owner requirement). A botched world migration is otherwise
        // invisible until the render dies, so say out loud which world the pipeline was
        // wired into, how many scripts landed there, and which channels were registered.
        // The script count is read back off the live `WKUserContentController` rather than
        // from a literal, so it reports what was actually installed. Debug-gated per
        // development rule 12 — a no-op in production.
        if DebugModeManager.isLoggingEnabled() {
            let world = RenderContentWorld.isolated
            print("[RenderSec id=\(context.coordinator.webViewId)] "
                  + "contentWorld=\(world.name ?? "<pageWorld>") "
                  + "userScripts=\(config.userContentController.userScripts.count)")
            for channel in HTMLWebView.bridgeChannels {
                print("[RenderSec id=\(context.coordinator.webViewId)] "
                      + "handler registered channel=\(channel) world=\(world.name ?? "<pageWorld>")")
            }
        }

        let webView = WKWebView(frame: .zero, configuration: config)
        // `allowsLinkPreview` is deliberately UNSET, so WebKit's default (ON) applies — the
        // `v1.7.8` shipped behaviour, RESTORED 2026-08-12 by explicit owner directive after P1b
        // set it to `false`. Long-press on a link previews its destination.
        //
        // ⚠️ THE SECURITY FACT IS UNCHANGED AND STILL TRUE: link preview FETCHES and PRESENTS the
        // remote URL without any `decidePolicyFor` decision we ever see. It is therefore a SECOND
        // route out of this view that P1c's `http`/`https` allowlist does not govern — data
        // detectors, set above, are the first. *"Every externally dispatched target passes our
        // `http`/`https` allowlist"* is FALSE for TWO independent reasons now, and it is false in
        // a way NO delegate-side test can observe in either case. That absolute must never be
        // restated — here, in a test, in an ADR, or in a commit body — without BOTH exceptions
        // (`MIS-019` shape). The sound form remains *"every `.linkActivated` target passes the
        // allowlist"*.
        // This is a KNOWN, ACCEPTED exception registered as `IOS-UI-003`; do not re-disable link
        // preview without asking the owner.
        webView.isOpaque = false
        webView.backgroundColor = .clear
        // Lock the inner scroll view at 1:1 zoom. The webview is sized to its
        // content height and the parent SwiftUI ScrollView owns vertical
        // scrolling, so any residual scrollable range here (e.g. a ~1px
        // sub-pixel contentSize overshoot from a descendant that overflows
        // body by <1px) reads as a dead-zone the user must drag through before
        // the page moves — a "double scroll". Disabling scroll removes it.
        // The zoomScale KVO (didFinish) re-enables scrolling only while
        // pinch-zoomed so the user can pan the magnified content. NB:
        // isScrollEnabled does NOT gate pinch-zoom (separate gesture
        // recognizer), so zoom still works at 1:1.
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        webView.navigationDelegate = context.coordinator
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.webView = webView
        // A representable's coordinator outlives individual SwiftUI value updates.
        // Keep the callback current even when the surrounding card is rebound.
        context.coordinator.onUserDisclosureToggle = onUserDisclosureToggle
        let currentWidth = webView.bounds.width
        let htmlChanged = html != context.coordinator.loadedHTML
        let reloadChanged = reloadToken != context.coordinator.loadedReloadToken

        if htmlChanged || reloadChanged {
            context.coordinator.loadedHTML = html
            context.coordinator.loadedReloadToken = reloadToken
            context.coordinator.loadedPreviewFilename = previewFilename
            context.coordinator.loadedHeaderId = headerId
            context.coordinator.lastMeasuredWidth = currentWidth
            // New document — a height buffered during scroll for the OLD
            // document must not flush onto the new one.
            context.coordinator.pendingHeight = nil
            context.coordinator.loadedColorScheme = colorScheme
            if DebugModeManager.isLoggingEnabled() {
                print("[HTMLDebug] HTMLWebView.updateUIView: loading html len=\(html.count)")
                // Log input HTML in chunks so we can see EXACTLY what's being rendered
                let inputChunkSize = 800
                let inputPreview = String(html.prefix(inputChunkSize * 3))
                // `html` is the SENDER's message body and `print` is a
                // line-oriented sink, so its newlines forge plausible extra
                // diagnostic lines. The enclosing `isLoggingEnabled()` gate is a
                // RUNTIME one that is true for unlocked accounts in RELEASE, so
                // this reaches users; and there is no precondition beyond
                // "the document changed", so every render emits it. Escaping
                // costs the dump its line breaks, which is the point — the
                // invariant `escapedForLogLine` buys outranks readability of a
                // debug dump.
                for (i, chunkStart) in stride(from: 0, to: inputPreview.count, by: inputChunkSize).enumerated() {
                    let start = inputPreview.index(inputPreview.startIndex, offsetBy: chunkStart)
                    let end = inputPreview.index(start, offsetBy: min(inputChunkSize, inputPreview.count - chunkStart))
                    let chunk = DebugModeManager.escapedForLogLine(String(inputPreview[start..<end]))
                    print("[HTMLDebug] INPUT HTML chunk #\(i): \(chunk)")
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
            // P1c: the base URL is no longer chosen here. `wrapAndLoad` mints a
            // per-load synthetic nonce base URL for EVERY load, at every call
            // site, whether or not a scheme handler is registered — see
            // `RenderDocumentURL`. The previous `headerId != nil ? … : nil`
            // conditional is deliberately GONE: under `baseURL: nil` the
            // navigation action arrives as `about:blank` with a `null` origin,
            // so a per-load permit is not merely weak there, it is
            // inexpressible.
            //
            // wrapHTML is regex-heavy (esp. full-document / large emails) — run
            // it OFF the main thread so it no longer freezes the UI at the render
            // moment. See Coordinator.wrapAndLoad; the wrapped-html fingerprint
            // logging moved there (it now exists only after the off-main wrap).
            context.coordinator.wrapAndLoad(rawHTML: html, previewFilename: previewFilename)
        } else if context.coordinator.loadedColorScheme != colorScheme {
            // Appearance flipped (light <-> dark) while the body is on screen. The
            // CSS @media (prefers-color-scheme) rules re-evaluate automatically,
            // but fixDarkModeColorsJS ran ONCE at load and baked inline color
            // overrides (!important) for the OLD appearance — those persist and
            // are wrong after the flip (e.g. light text forced for dark mode now
            // sitting on a light background, or near-white→transparent fills not
            // reapplied). Reload so every script re-runs fresh for the current
            // appearance. Cheap: wrap is off-main and WebKit caches the (deferred)
            // images. hasRevealed stays true (html is unchanged) so there's no
            // "Loading…" placeholder — the opacity:0→reveal fade covers the brief
            // re-render.
            context.coordinator.loadedColorScheme = colorScheme
            context.coordinator.wrapAndLoad(rawHTML: html, previewFilename: previewFilename)
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
            // P3: `in: RenderContentWorld.isolated`. `viewportResetJS` CLEARS
            // `window.__tmLayoutVp`, which `monitorHeightJS` (a user script) reads — so
            // this call must land in the same world those scripts live in or it would
            // clear a global nobody reads and leave the real one set, permanently bailing
            // `fitViewportJS`'s idempotency guard. `in: nil` targets the main frame.
            // The world-aware overload is `NS_REFINED_FOR_SWIFT`, so the completion handler
            // takes a single `Result` rather than the `(value, error)` pair.
            webView.evaluateJavaScript(resetJS, in: nil, in: RenderContentWorld.isolated) { _ in
                context.coordinator.fit()
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            height: $height,
            hasRevealed: $hasRevealed,
            leadingPad: $leadingPad,
            trailingPad: $trailingPad,
            onUserDisclosureToggle: onUserDisclosureToggle
        )
    }

    class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {

        @Binding var height: CGFloat
        /// Flipped true when the JS `reveal()` posts `{revealed:true}` — drives
        /// the SwiftUI loading placeholder removal in `AutoSizingHTMLView`.
        @Binding var hasRevealed: Bool
        /// Dynamic horizontal gutter, driven by the `gutterAdjust` message from
        /// `eatGutterMarginsJS` (= 16 − the email's own measured inset, clamped).
        @Binding var leadingPad: CGFloat
        @Binding var trailingPad: CGFloat
        var onUserDisclosureToggle: () -> Void
        var loadedHTML: String?
        var loadedPreviewFilename: String?
        var loadedHeaderId: String?
        var loadedReloadToken: Int?
        /// Appearance the current document was rendered under. fixDarkModeColorsJS
        /// bakes inline color overrides for ONE appearance at load; when this no
        /// longer matches the SwiftUI environment, updateUIView reloads so the
        /// scripts re-run fresh for the new light/dark mode.
        var loadedColorScheme: ColorScheme?
        var lastMeasuredWidth: CGFloat = 0
        weak var webView: WKWebView?
        /// Latest measured height that arrived while `ScrollFreezeGate` was
        /// frozen. Applied (and cleared) by the `.scrollFreezeReleased`
        /// listener; overwritten by newer measurements during the same freeze
        /// so only the final value flushes. Cleared on new-document load.
        var pendingHeight: CGFloat?
        /// Monotonic token identifying the most recent new-document load. Bumped
        /// by `wrapAndLoad` on every load (updateUIView htmlChanged + content-
        /// process reload); the off-main wrap captures the token and skips
        /// `loadHTMLString` if a newer load superseded it — so a slow wrap of an
        /// OLD body can't clobber a newer one when the card is rebound mid-wrap.
        var loadGeneration: Int = 0
        /// Arming state AND liveness evidence for the bridge-liveness verdict (P1d).
        /// See `BridgeLivenessBeacon` for the device evidence that moved the arm
        /// from `didFinish` to `didCommit`, and for why every generation it handles
        /// is a COMMITTED one.
        ///
        /// ⚠️ Both halves are keyed on `documentGate.committedGeneration`, never on
        /// `loadGeneration` — the field this coordinator used to stamp bridge
        /// messages with. `wrapAndLoad` bumps `loadGeneration` before the new
        /// document exists, so the OLD document's late messages were recorded as
        /// evidence that the NEW document's scripts had run, and a document that
        /// executed zero JavaScript could be reported `bridge=LIVE`.
        private var bridgeBeacon = BridgeLivenessBeacon()
        /// P1c — the permit half of the two-state navigation machine
        /// (ADR-IOS-076 decisions 2 and 4; plan §10.1 C1 + C2).
        ///
        /// Armed immediately before each app-owned `loadHTMLString` with the
        /// per-load nonce URL, and CONSUMED AT POLICY TIME — immediately before
        /// `decidePolicyFor` returns `.allow`, not at commit. That ordering is
        /// what makes a failure after commit unable to leak it.
        private var permit = NavigationPermitState()
        /// The `WKNavigation` returned by the load that consumed the permit —
        /// the OTHER half of the machine. `decidePolicyFor` never receives a
        /// `WKNavigation`, so a permit alone cannot be correlated to the
        /// callbacks that follow.
        ///
        /// ⚠️ P1a measured that this return value was being DISCARDED, which
        /// left the process-termination reload and the appearance reload
        /// arriving unlabelled and uncorrelatable.
        private var trackedNavigation: WKNavigation?
        /// `loadGeneration` of `trackedNavigation`.
        private var trackedGeneration: Int?
        /// The document URL of the load that was actually admitted — i.e. the
        /// identity of the document currently on screen, as WE supplied it.
        ///
        /// NEVER read `location.href` for this: P1a measured that `pushState`
        /// changes it with no delegate callback at all, so it is a value the
        /// document controls and the app cannot observe changing.
        private var loadedDocumentURL: String?
        /// Which document a bridge message belongs to, and which of its one-shot
        /// requests (`requestFit`, `requestWidthRefit`, P4's `imageLoadFailure`
        /// census) it has already spent. The JS-side guards (`__tmFitRequested`,
        /// `__tmWidthRefitRequested`, `__tmImageFailureReported`) live in the
        /// isolated world and are ADVISORY; this is the authority.
        ///
        /// ⚠️ Keyed on the COMMITTED generation, never on `loadGeneration`. See
        /// `CommittedDocumentGate` for the measured defect: `loadGeneration` is
        /// bumped by `wrapAndLoad`'s first statement, a whole off-main wrap and a
        /// provisional load before the new document exists, so the OLD document —
        /// still committed, still running its timers — was having its late
        /// messages stamped with the NEW document's generation, and the new
        /// document's own request refused as a duplicate.
        private var documentGate = CommittedDocumentGate()
        /// Grace period between `didCommit` (P1d — it was `didFinish` until then)
        /// and the bridge-liveness verdict.
        /// `monitorHeightJS`'s ResizeObserver and the double-`rAF` reveal both
        /// post well inside this window on a normal render; it is long enough
        /// that a slow first layout does not produce a false SILENT verdict, and
        /// short enough that the line lands next to the load it describes.
        private static let bridgeLivenessGraceSeconds: TimeInterval = 3.0
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
        /// KVO observation on scrollView.zoomScale. Functional (NOT debug-only):
        /// toggles `isScrollEnabled` so the inner scroll view is locked at 1:1
        /// (vertical drags pass to the parent SwiftUI ScrollView — no dead-zone)
        /// but unlocked while pinch-zoomed (so the user can pan the magnified
        /// content). We observe zoomScale rather than becoming the scrollView's
        /// delegate, because replacing a WKWebView's scrollView delegate can
        /// break WebKit's internal `viewForZooming` and disable zoom entirely.
        /// Released in deinit.
        private var zoomObservation: NSKeyValueObservation?

        init(
            height: Binding<CGFloat>,
            hasRevealed: Binding<Bool>,
            leadingPad: Binding<CGFloat>,
            trailingPad: Binding<CGFloat>,
            onUserDisclosureToggle: @escaping () -> Void
        ) {
            self._height = height
            self._hasRevealed = hasRevealed
            self._leadingPad = leadingPad
            self._trailingPad = trailingPad
            self.onUserDisclosureToggle = onUserDisclosureToggle
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
                    guard let self else { return }
                    if let pending = self.pendingHeight {
                        self.pendingHeight = nil
                        if pending > 0 && pending != self.height {
                            self.height = pending
                            if let hid = self.loadedHeaderId { HeightSeedCache.shared[hid] = pending }
                        }
                    }
                    #if DEBUG
                    // Ordered test seam: emitted synchronously at the end of
                    // this main-queue flush turn, including the no-pending
                    // latest-wins case. Tests can therefore distinguish a
                    // genuinely cleared buffer from a pre-flush cache sample.
                    NotificationCenter.default.post(
                        name: .renderHeightFlushCompletedForTests,
                        object: nil,
                        userInfo: [
                            "headerId": self.loadedHeaderId as Any,
                            "height": Double(self.height),
                        ]
                    )
                    #endif
                }
            }
        }

        deinit {
            if let obs = foregroundObserver { NotificationCenter.default.removeObserver(obs) }
            if let obs = scrollFreezeObserver { NotificationCenter.default.removeObserver(obs) }
            contentSizeObservation?.invalidate()
            zoomObservation?.invalidate()
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            self.webView = webView
            lastMeasuredWidth = webView.bounds.width
            navLog("didFinish tracked=\(isTracked(navigation))")
            // Idempotent, identity-matched. Deliberately does NOT gate the
            // rendering work below: a load whose `WKNavigation` we failed to
            // capture must still be fitted and revealed, or a nil return value
            // from `loadHTMLString` would blank the message.
            clearTrackedNavigation(matching: navigation)
            // ⚠️ The bridge-liveness verdict is NOT armed here any more (P1d). It is
            // armed at `didCommit`, because a load whose images never settle never
            // reaches this callback and used to report nothing at all. See
            // `BridgeLivenessBeacon` for the measured case (`KH4CLK`).
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
            // Functional zoom KVO (always on): keep the inner scroll locked at
            // 1:1 (parent SwiftUI ScrollView owns the gesture — no ~1px
            // dead-zone) but allow panning while pinch-zoomed. Set up once.
            if zoomObservation == nil {
                zoomObservation = webView.scrollView.observe(\.zoomScale, options: [.new]) { sv, _ in
                    // zoomScale KVO fires on the main thread (gesture/layout
                    // driven); assert isolation for the UIKit read/write.
                    MainActor.assumeIsolated {
                        let zoomed = sv.zoomScale > 1.001
                        if sv.isScrollEnabled != zoomed { sv.isScrollEnabled = zoomed }
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
            // P3: `in: RenderContentWorld.isolated`. `__tmDeviceWidth` is stamped here and
            // read by `monitorHeightJS`'s `__tmLayoutVp || __tmDeviceWidth || innerWidth`
            // fallback chain, and `fitViewportJS` sets `__tmFitDone` / `__tmLayoutVp` that
            // the same user scripts read — all one world, or the chain silently falls
            // through to the untrustworthy `innerWidth` (WebKit bug 170595).
            webView.evaluateJavaScript(stampJS + fitViewportJS, in: nil, in: RenderContentWorld.isolated) { _ in
                // That's it. monitorHeightJS's ResizeObserver will fire
                // after the viewport change settles, and
                // handleHeightMessage will apply the result.
            }
        }

        /// Reset the viewport to device-width and re-run the full fit in a
        /// SINGLE JS turn. This is the ADR-IOS-039 sanctioned re-fit (same
        /// mechanism as updateUIView's width-change path): viewportResetJS
        /// clears window.__tmLayoutVp so fitViewportJS's idempotency guard
        /// lets the re-fit through, and re-stamps __tmDeviceWidth. One
        /// evaluateJavaScript call — NOT reset-then-fit in two turns — so
        /// WebKit commits a single layout/scale change and the already-revealed
        /// content never paints an intermediate device-width frame. Used by the
        /// post-image-load width recheck (requestWidthRefit).
        func resetAndFit(_ webView: WKWebView? = nil) {
            guard let webView = webView ?? self.webView, webView.bounds.width > 50 else { return }
            let resetJS = viewportResetJS(deviceWidth: Int(webView.bounds.width.rounded()))
            // P3: `in: RenderContentWorld.isolated` — same reason as `fit()` above, and
            // still ONE evaluate call so WebKit commits a single layout/scale change.
            webView.evaluateJavaScript(resetJS + ";" + fitViewportJS, in: nil, in: RenderContentWorld.isolated) { _ in }
        }

        /// Wrap `rawHTML` OFF the main thread, then load it into the web view.
        ///
        /// `EmailHTMLWrapper.wrapHTML` is a pure, isolation-free transform, but
        /// it is regex-heavy: on a full-document / large email (the
        /// `unwrapFullHTMLDocument` → `neutralizeCSSRules` path plus the image-
        /// defer / stylesheet-strip passes) it costs 100ms–1s+ of CPU. Run
        /// synchronously in `updateUIView` it froze the main thread at the exact
        /// moment a message rendered. Here the wrap runs on a detached task and
        /// only `loadHTMLString` hops back to the main actor, gated on
        /// `loadGeneration` so a stale wrap can't overwrite a newer load. The
        /// document starts at `opacity:0` (EmailHTMLWrapper CSS) and is revealed
        /// by `fit()` after `didFinish`, so the slightly-later load shows no
        /// flash. Behaviour is otherwise identical to the previous synchronous
        /// wrap + load.
        ///
        /// P1c: this is also the ONE place a main-frame document permit is
        /// armed. The base URL is minted here rather than passed in, because
        /// every call site must get one — see `RenderDocumentURL`.
        func wrapAndLoad(rawHTML: String, previewFilename: String?) {
            loadGeneration &+= 1
            let gen = loadGeneration
            let hasHeader = loadedHeaderId != nil
            Task { @MainActor in
                let wrapped = await Task.detached(priority: .userInitiated) {
                    EmailHTMLWrapper.wrapHTML(rawHTML, previewFilename: previewFilename)
                }.value
                // A newer load superseded this one (card rebound mid-wrap), or
                // the web view went away — drop this stale result. Note this
                // returns BEFORE arming: a wrap that loses the race never arms a
                // permit, so it cannot leak one.
                guard self.loadGeneration == gen, let webView = self.webView else { return }
                if DebugModeManager.isLoggingEnabled() {
                    // Privacy-safe per-email fingerprint: SHA256 of the wrapped
                    // html, truncated to 8 hex chars (one-way, not reversible to
                    // content). Ties this load to the [MeasureHeight id=…] /
                    // [HeightDiag id=…] timeline. Moved here from updateUIView
                    // since `wrapped` is now produced off-main.
                    let bytes = Data(wrapped.utf8)
                    let digest = SHA256.hash(data: bytes)
                    let fp = digest.prefix(4).map { String(format: "%02x", $0) }.joined()
                    print("[HTMLDebug] HTMLWebView.wrapAndLoad: wrapped len=\(wrapped.count)")
                    print("[Load id=\(self.webViewId)] bytes=\(wrapped.count) fp=\(fp) hasHeader=\(hasHeader)")
                }
                self.logRenderSecurityPosture(webView: webView, generation: gen, schemeHandlerRegistered: hasHeader)

                // ── P1c: arm the permit, then load, then capture the navigation ──
                // Arming supersedes any permit still pending. That IS the only
                // retirement path for a superseded permit: P1a measured that a
                // superseded load receives NO callback at all — not even
                // `didFailProvisionalNavigation` — so a design that retired
                // permits on a failure callback would leak them forever.
                let nonce = RenderDocumentURL.nonce()
                let base = RenderDocumentURL.url(nonce: nonce)
                if let superseded = self.permit.arm(generation: gen, url: base.absoluteString) {
                    self.navLog("superseded gen=\(superseded.generation) "
                                + "nonce=\(RenderDocumentURL.logPrefix(forDocumentURL: superseded.url)) "
                                + "by gen=\(gen)")
                }
                self.navLog("issued gen=\(gen) nonce=\(RenderDocumentURL.logPrefix(nonce)) "
                            + "schemeHandler=\(hasHeader)")
                // Issuing is NOT committing: the document already on screen keeps
                // running, keeps posting, and keeps its own one-shot slots until
                // this load actually commits. See `CommittedDocumentGate`.
                self.documentGate.issue(generation: gen)
                let navigation = webView.loadHTMLString(wrapped, baseURL: base)
                self.trackedNavigation = navigation
                self.trackedGeneration = gen
                if navigation == nil {
                    self.navLog("gen=\(gen) WARNING loadHTMLString returned no WKNavigation — "
                                + "this load's callbacks cannot be correlated")
                }
            }
        }

        /// Report the render-security posture that is actually in force for this
        /// load — once per load, immediately before `loadHTMLString`.
        ///
        /// Both halves are read back from the objects that will serve the load
        /// rather than restated from the code that set them, which is the only
        /// version worth logging: a configuration line that echoes the literals
        /// in `makeUIView` would keep printing `false` after a future edit
        /// silently stopped applying them, and a CSP line assembled in the log
        /// statement would keep printing the intended policy after the wrapper
        /// began emitting a different one. `EmailHTMLWrapper.contentSecurityPolicy`
        /// is the *same stored constant the meta tag interpolates*, so it cannot
        /// drift from the document; the WebKit values come off `webView` and its
        /// live `configuration`.
        ///
        /// Debug-gated per development rule 12 — a no-op in production.
        private func logRenderSecurityPosture(webView: WKWebView, generation: Int, schemeHandlerRegistered: Bool) {
            guard DebugModeManager.isLoggingEnabled() else { return }
            let cfg = webView.configuration
            print("[RenderSec id=\(webViewId) gen=\(generation)] "
                  + "contentJS=\(cfg.defaultWebpagePreferences.allowsContentJavaScript) "
                  + "persistentStore=\(cfg.websiteDataStore.isPersistent) "
                  + "dataDetectors=\(cfg.dataDetectorTypes.rawValue) "
                  + "linkPreview=\(webView.allowsLinkPreview) "
                  + "assetSchemeHandler=\(schemeHandlerRegistered)")
            // The policy is app-authored and fixed at build time — no sender
            // content reaches it — so it needs no escaping, and printing it whole
            // is the point: a truncated CSP cannot be compared against the
            // `securitypolicyviolation` reports in the same log.
            print("[RenderSec id=\(webViewId) gen=\(generation)] csp=\(EmailHTMLWrapper.contentSecurityPolicy)")
        }

        /// Schedule the bridge-liveness verdict for the document that just
        /// COMMITTED, a short grace period after the commit.
        ///
        /// This is the one diagnostic in this file that survives a total loss of
        /// page JavaScript, and it exists because every other one does not: if
        /// `allowsContentJavaScript = false` or `script-src 'none'` ever did
        /// suppress our own `WKUserScript`s, the render would break and the logs
        /// would go quiet in the same instant, which reads exactly like a quiet
        /// success. The verdict below turns that silence into a sentence.
        ///
        /// ⚠️ **P1d moved the arm from `didFinish` to `didCommit`, and that is the
        /// whole point of the change.** On device (`logmain.log`, 2026-08-12) load
        /// `KH4CLK` logged neither `LIVE` nor `SILENT` because its images never
        /// settled and `didFinish` never fired — while its user scripts provably ran.
        /// A page that hangs mid-load therefore produced NO LINE AT ALL, which made
        /// the absence of the alarm indistinguishable from the alarm not existing.
        ///
        /// Armed at most once per generation by `BridgeLivenessBeacon`, so a second
        /// `didCommit` — or a future edit that re-adds an arm from `didFinish` —
        /// cannot produce a second verdict for one load.
        ///
        /// The arming is ungated (one integer store, no I/O), so the one-shot is a
        /// property of the state machine rather than of the log gate; only the
        /// verdict itself is debug-gated, per development rule 12.
        ///
        /// ⚠️ The generation comes from `documentGate`, not from `loadGeneration`.
        /// Passing it in was how the fourth consumer of the issued-generation
        /// keying survived `4213cb3a9`; taking it from the gate leaves no argument
        /// for a caller to get wrong.
        private func scheduleBridgeLivenessCheck() {
            guard let generation = bridgeBeacon.arm(in: documentGate) else { return }
            guard DebugModeManager.isLoggingEnabled() else { return }
            let id = webViewId
            // 3s measured from COMMIT is comfortably enough: the `.atDocumentEnd`
            // user scripts post their first bridge message within a few ms of commit
            // — `KH4CLK`'s `[ImageLoadDiag id=KH4CLK +1ms] inventory images=5` is the
            // line immediately after its `didCommit tracked=true` — and the verdict
            // only prints in a build where those diagnostics are injected in the
            // first place.
            DispatchQueue.main.asyncAfter(deadline: .now() + Coordinator.bridgeLivenessGraceSeconds) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    // A superseded load's verdict would describe a document that is no
                    // longer on screen — and supersession is itself logged
                    // (`issued gen=…` / `superseded gen=…`), so the silence is
                    // explained rather than mysterious. Pre-existing behaviour; P1d
                    // does not change it. "Superseded" is now asked of the COMMITTED
                    // document rather than of `loadGeneration`, so a load that has
                    // merely been ISSUED no longer silences the verdict of the
                    // document still on screen.
                    guard let verdict = self.bridgeBeacon.settle(
                        generation: generation,
                        in: self.documentGate
                    ) else { return }
                    switch verdict {
                    case .live:
                        print("[RenderSec id=\(id) gen=\(generation)] bridge=LIVE (app user scripts executed and reached Swift)")
                    case .silent:
                        print("[RenderSec id=\(id) gen=\(generation)] bridge=SILENT — no bridge message received for this load; user scripts may not be executing")
                    }
                }
            }
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            // iOS killed the WKWebView content process (memory pressure).
            // Reload the content to restore rendering. The base URL is no longer
            // re-derived from `loadedHeaderId` — `wrapAndLoad` mints a fresh
            // nonce base URL for this load like any other.
            if DebugModeManager.isLoggingEnabled() {
                print("[ImageLoadDiag id=\(webViewId)] web-content-process-terminated persistedBody=\(loadedHeaderId != nil)")
            }
            // P1c: invalidate BOTH states before the recovery load. The dead
            // content process cannot deliver the callbacks the old navigation
            // was waiting on, and the recovery load then arms a fresh
            // generation + nonce + permit + WKNavigation of its own.
            invalidateNavigationState(reason: "web-content-process-terminated")
            if let html = loadedHTML {
                // Off-main wrap + reload, same path as updateUIView.
                wrapAndLoad(rawHTML: html, previewFilename: loadedPreviewFilename)
            }
        }

        /// The message-render navigation boundary (ADR-IOS-076 decisions 2, 3 and 6).
        ///
        /// **The guarantee: no unapproved new main-frame document is admitted.**
        /// It deliberately does NOT claim that same-document fragment or
        /// history-state mutations are prevented — P1a measured that
        /// `pushState`/`history.back` surface no callback at all and that
        /// returning `.cancel` on a fragment click does not stop it. A
        /// same-document mutation does not replace the trusted document.
        ///
        /// What this closes that P1b did not: `<meta http-equiv="refresh">` in a
        /// sender's body navigates the main frame and STILL fires with
        /// `allowsContentJavaScript = false`. Its action is `.other` on the main
        /// frame with `sourceFrame` main — **shape-identical to a legitimate app
        /// load** — so only the per-load nonce distinguishes them.
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            let url = navigationAction.request.url
            let navigationType = navigationAction.navigationType
            let isMainFrame = navigationAction.targetFrame?.isMainFrame == true
            let isNewWindow = navigationAction.targetFrame == nil
            let matchesPermit = url != nil && url?.absoluteString == permit.pending?.url
            navLog("decidePolicyFor type=\(Coordinator.typeName(navigationType)) "
                   + "mainFrame=\(isMainFrame) newWindow=\(isNewWindow) "
                   + "permitMatch=\(matchesPermit) url=\(Coordinator.loggableURL(url))")

            // 1. The app's own document load — the ONLY way a new main-frame
            //    document is admitted. Consumed here, at POLICY time.
            switch permit.evaluate(url: url?.absoluteString,
                                   navigationType: navigationType,
                                   isMainFrame: isMainFrame) {
            case .admit(let admitted):
                loadedDocumentURL = admitted.url
                navLog("consumed gen=\(admitted.generation) "
                       + "nonce=\(RenderDocumentURL.logPrefix(forDocumentURL: admitted.url))")
                return .allow
            case .refuseAndInvalidate(let refusal):
                // It named our per-load nonce but was not a main-frame `.other`
                // action, so the permit is no longer trustworthy.
                navLog("invalidated reason=\(refusal.rawValue) gen=\(loadGeneration)")
                return .cancel
            case .refuse(let refusal):
                // Unrelated to the pending permit — which is left ARMED, so an
                // old/subframe/user action can never cancel a legitimate app load.
                navLog("refused reason=\(refusal.rawValue)")
            }

            // 2. `.linkActivated` — never a document admission (a scripted
            //    `anchor.click()` is reported identically to a real tap, so this
            //    type proves nothing about a user gesture). It is dispatched or
            //    refused, and its WebKit navigation is cancelled either way.
            if navigationType == .linkActivated, let url {
                // Short-circuit mailto: so the user composes in TabMail rather
                // than handing off to whichever app iOS currently considers
                // the default mail client (we don't hold the entitlement yet).
                if let request = MailtoRequest.parse(url) {
                    navLog("open internal=compose scheme=mailto")
                    NotificationCenter.default.post(
                        name: .contactPillComposeTapped,
                        object: nil,
                        userInfo: request.toUserInfo()
                    )
                    return .cancel
                }
                switch RenderLinkPolicy.dispatch(for: url, documentURL: loadedDocumentURL) {
                case .sameDocumentFragment:
                    // The defect P1a demonstrated on shipped code: every
                    // `.linkActivated` was handed to `UIApplication.shared.open`,
                    // so an in-document `#anchor` reached the SYSTEM OPENER as a
                    // `tabmail-asset://` URL. It is handled internally now —
                    // and the anchor still works, because the measured behaviour
                    // is that `.cancel` does not prevent the same-document jump.
                    navLog("open internal=same-document-fragment")
                    return .cancel
                case .openExternally:
                    navLog("open allowed scheme=\(RenderLinkPolicy.loggableScheme(url))")
                    await UIApplication.shared.open(url)
                    return .cancel
                case .refuse(let refusal):
                    navLog("open refused reason=\(refusal.rawValue) "
                           + "scheme=\(RenderLinkPolicy.loggableScheme(url))")
                    return .cancel
                }
            }

            // 3. Default-deny. Subframe loads, `target="_blank"`, form
            //    submissions, `.backForward`, and any main-frame `.other` action
            //    that could not present the per-load nonce (the meta-refresh
            //    vector) all land here.
            return .cancel
        }

        /// Never normal for a substitute-data load: nothing on the wire can
        /// redirect `loadHTMLString`. If it fires on the tracked navigation the
        /// document is not the one we admitted, so both states are invalidated
        /// and the load is stopped — a following `.other` must not be treated as
        /// a continuation of it.
        func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
            guard let navigation, navigation === trackedNavigation else {
                navLog("server-redirect on an UNTRACKED navigation — ignored")
                return
            }
            invalidateNavigationState(reason: "server-redirect")
            webView.stopLoading()
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            navLog("didStartProvisionalNavigation tracked=\(isTracked(navigation)) gen=\(trackedGeneration.map(String.init) ?? "-")")
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            // THE document identity a `WKScriptMessage` does not carry. Committing is
            // the moment the issued load actually replaced the document on screen, so
            // it is the moment its one-shot slots become the live ones — see
            // `CommittedDocumentGate`. WebKit runs this before document parsing, hence
            // before every `.atDocumentStart`/`.atDocumentEnd` user script, so no
            // bridge message of the new document can outrun it.
            //
            // ⚠️ IDENTITY-MATCHED, per ADR-IOS-076 decision 4 — which already required
            // it of this callback, and which the generation adoption did not honour: the
            // discriminator was computed for the log line below and then ignored, so a
            // `didCommit` belonging to a load a newer `issue` had already superseded
            // adopted the NEWER generation and labelled the OLD document with it.
            //
            // `trackedNavigation == nil` adopts, deliberately. It means there is no
            // identity to match against — `loadHTMLString` may legitimately return no
            // `WKNavigation` (this file logs a WARNING when it does) — and the same
            // reasoning already governs `didFinish`, which does its fit-and-reveal work
            // ungated for exactly that reason. Refusing there would strand a real
            // document with no committed generation and refuse all three of its
            // one-shots.
            let tracked = isTracked(navigation)
            let isIssuedLoad = NavigationCommitCorrelation.shouldAdoptIssuedGeneration(
                callbackMatchesTrackedNavigation: tracked,
                hasTrackedNavigation: trackedNavigation != nil
            )
            let committed = documentGate.commit(isIssuedLoad: isIssuedLoad)
            navLog("didCommit tracked=\(tracked) adoptedIssued=\(isIssuedLoad) "
                   + "committedGen=\(committed.map(String.init) ?? "-")")
            // Owner requirement (P1b), re-sequenced by P1d: say out loud whether app
            // JavaScript ran — for EVERY committed load, including one that never
            // finishes. Committing is the property every rendered document has;
            // finishing is one a live page may never reach.
            //
            // The generation is read back out of `documentGate` by the beacon itself.
            // It used to be `loadGeneration` — the ISSUED generation — which named the
            // wrong load whenever a rebind had already bumped it.
            scheduleBridgeLivenessCheck()
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            navLog("didFail tracked=\(isTracked(navigation)) err=\((error as NSError).domain)/\((error as NSError).code)")
            clearTrackedNavigation(matching: navigation)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            navLog("didFailProvisionalNavigation tracked=\(isTracked(navigation)) err=\((error as NSError).domain)/\((error as NSError).code)")
            clearTrackedNavigation(matching: navigation)
        }

        /// Idempotent, identity-matched cleanup. The permit is NOT touched here —
        /// it was already consumed at policy time, and a late callback from an
        /// older load must never clear newer state.
        private func clearTrackedNavigation(matching navigation: WKNavigation?) {
            guard let navigation, navigation === trackedNavigation else { return }
            trackedNavigation = nil
            trackedGeneration = nil
        }

        private func isTracked(_ navigation: WKNavigation?) -> Bool {
            navigation != nil && navigation === trackedNavigation
        }

        /// Drop both halves of the navigation state.
        private func invalidateNavigationState(reason: String) {
            if let dropped = permit.invalidate() {
                navLog("invalidated reason=\(reason) gen=\(dropped.generation) "
                       + "nonce=\(RenderDocumentURL.logPrefix(forDocumentURL: dropped.url))")
            } else {
                navLog("invalidated reason=\(reason) (no permit was armed)")
            }
            trackedNavigation = nil
            trackedGeneration = nil
            // No document is on screen any more, so nothing can legitimately post on a
            // one-shot channel until a fresh load issues AND commits. Refusing until
            // then is the fail-closed direction: the alternative leaves a dead
            // document's generation adopted by whatever posts next.
            documentGate.invalidate()
        }

        /// Debug-gated navigation diagnostic. Production must not eat the noise
        /// (development rule 12), and a failed smoke test must be diagnosable
        /// from the log alone without a rebuild.
        private func navLog(_ line: @autoclosure () -> String) {
            guard DebugModeManager.isLoggingEnabled() else { return }
            print("[NavPermit id=\(webViewId)] \(line())")
        }

        /// A navigation action's URL is SENDER-CONTROLLED. `print` is a
        /// line-oriented sink, so it is truncated and control-character-escaped
        /// before it reaches one — the same class `imageLoadDiagnosticJS`'s
        /// `sanitize` closes on the JS side.
        private static func loggableURL(_ url: URL?) -> String {
            guard let url else { return "(nil)" }
            let raw = url.absoluteString
            let capped = raw.count > 120 ? String(raw.prefix(117)) + "..." : raw
            return DebugModeManager.escapedForLogLine(capped)
        }

        private static func typeName(_ type: WKNavigationType) -> String {
            switch type {
            case .linkActivated: return "linkActivated"
            case .formSubmitted: return "formSubmitted"
            case .backForward: return "backForward"
            case .reload: return "reload"
            case .formResubmitted: return "formResubmitted"
            case .other: return "other"
            @unknown default: return "unknown(\(type.rawValue))"
            }
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            // ── P3: SUBFRAME REJECTION, before anything else reads this message ──
            // All 17 user scripts are `forMainFrameOnly: true`, so no script of OURS ever
            // runs in a subframe and a legitimate bridge message is always main-frame.
            // A post from a subframe therefore cannot be ours, and the ORDER here is the
            // point: this guard sits ABOVE the liveness beacon, because a non-app message
            // that reached the beacon would forge a LIVE verdict for a load where none of
            // our scripts ran — exactly the spoof the beacon's own comment warns about.
            // Fails closed, and says so under the debug gate. `message.name` is safe to
            // interpolate: WebKit only delivers names we registered, so it is one of
            // `bridgeChannels`, never sender-authored.
            guard RenderBridgeInput.acceptsMessage(fromMainFrame: message.frameInfo.isMainFrame) else {
                bridgeLog("rejected channel=\(message.name) reason=not-main-frame")
                return
            }
            // Bridge-liveness beacon (see `BridgeLivenessBeacon`). Recorded for
            // EVERY channel and BEFORE any dispatch, because the question this
            // answers is "did app JavaScript run at all", not "did the height
            // arrive" — a script that ran and then threw still proves the gate is
            // open. Ungated on purpose: one store, no I/O; only the verdict in
            // `scheduleBridgeLivenessCheck` prints, and that is gated.
            //
            // ⚠️ Attributed to the COMMITTED document, not to `loadGeneration`.
            // Being upstream of every dispatch is exactly why the one-shot gate
            // below cannot shield this line: it runs for every channel, before any
            // of them, so keying it on the issued generation let document A's late
            // `heightChanged` stand as proof that document B's scripts had run.
            //
            // Sound as an APP-script signal for TWO independent reasons now, and the
            // second is the durable one. (1) `allowsContentJavaScript` is false, so no
            // sender script runs at all — before P1b it shared this `window` and could
            // post to `consoleLog` itself. (2) P3 registered these channels in
            // `RenderContentWorld.isolated`, so `webkit.messageHandlers` does not exist
            // in the page world: re-enabling author JS would no longer re-open the
            // forgery, because there is nothing there to post to. The old note said this
            // beacon "would have to move to a separate `WKContentWorld`" if author JS came
            // back — it has now moved, so that migration is DONE, not pending.
            bridgeBeacon.recordBridgeMessage(in: documentGate)
            // P1c — every payload below is validated in SWIFT before it is used.
            // A clamp that lives in our injected JS is advisory: whatever runs in the
            // world the channels are registered in can post directly and simply not call
            // it. P3 narrowed WHO that is — only our own scripts share
            // `RenderContentWorld.isolated` — but it did not make the Swift-side
            // validation redundant, because a clamp WE wrote wrong produces the same
            // `NaN` height as a hostile one. Each rejection fails closed (the message is
            // dropped) and says so under the debug gate; nothing substitutes a default a
            // sender could aim.
            if message.name == "heightChanged" {
                guard let validated = RenderBridgeInput.validatedHeightBody(message.body) else {
                    bridgeLog("rejected channel=heightChanged reason=malformed-payload")
                    return
                }
                // The disclosure bit and the measurement it classifies are one
                // validated payload, so no cross-channel WebKit delivery
                // ordering is assumed.
                if let dict = validated as? [String: Any],
                   dict["userDisclosure"] as? Bool == true {
                    onUserDisclosureToggle()
                }
                handleHeightMessage(validated)
            } else if message.name == "gutterAdjust" {
                // eatGutterMarginsJS measured the email's own content inset and sent
                // the SwiftUI padding to apply (= 16 − inset, clamped). Only ever
                // ≤ the 16pt default, so the gutter stays a minimum. Guard equality
                // to avoid a redundant frame resize (which would re-fit needlessly).
                // The `[0, 16]` clamp is re-applied here because the JS one cannot
                // be trusted, and a missing side keeps the current value.
                guard let padding = RenderBridgeInput.gutterPadding(message.body,
                                                                    leading: leadingPad,
                                                                    trailing: trailingPad) else {
                    bridgeLog("rejected channel=gutterAdjust reason=malformed-payload")
                    return
                }
                if leadingPad != padding.leading { leadingPad = padding.leading }
                if trailingPad != padding.trailing { trailingPad = padding.trailing }
            } else if message.name == "consoleLog" {
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
                //
                // P1c adds the bound + escape: the line is app-authored but
                // interpolates sender-influenced values (URLs, tag names, class
                // names, error messages), and only `imageLoadDiagnosticJS`
                // sanitizes its own emissions. This is the choke point for the
                // channel itself.
                guard DebugModeManager.isLoggingEnabled() else { return }
                guard let line = RenderBridgeInput.consoleLine(message.body) else {
                    bridgeLog("rejected channel=consoleLog reason=not-a-string")
                    return
                }
                print(line)
            } else if message.name == "imageLoadFailure" {
                // P4 — `postImageWidthRecheckJS` counted the remote images that
                // ended in `error` and posted the census once, after the last
                // armed image settled. This is DIAGNOSTIC ONLY: JavaScript's bare
                // `error` cannot distinguish a routine 404/expired URL from TLS,
                // so this channel has no path to user-visible notice state.
                let disposition = ImageLoadFailureReportDisposition.classify(message.body)
                guard case .diagnosticOnly(let failed, let deferred) = disposition else {
                    bridgeLog("rejected channel=imageLoadFailure reason=malformed-payload")
                    return
                }
                // One-shot PER COMMITTED DOCUMENT, enforced in Swift for the same
                // reason `requestFit` and `requestWidthRefit` are:
                // `__tmImageFailureReported` lives in the isolated world and is only
                // advisory, so the authoritative duplicate guard remains here even
                // though this report no longer changes UI.
                guard honourOneShot(.imageFailureReport, channel: "imageLoadFailure") else { return }
                bridgeLog("imageLoadFailure failed=\(failed) deferred=\(deferred) "
                          + "notice=none diagnostic-only=true")
            }
        }

        /// Spend `oneShot` for the document currently on screen, or log why not.
        ///
        /// The whole decision lives in `CommittedDocumentGate`; this is only the
        /// log-line half, kept here because `bridgeLog` is a coordinator method.
        /// The refusal token composes as `<reason>-<request>` so the existing
        /// `duplicate-requestFit` / `duplicate-requestWidthRefit` log strings are
        /// unchanged and the new `no-committed-document-…` reason is greppable.
        private func honourOneShot(_ oneShot: RenderOneShot, channel: String) -> Bool {
            switch documentGate.evaluate(oneShot) {
            case .honour:
                return true
            case .refuse(let refusal):
                logOneShotRefusal(refusal, oneShot: oneShot, channel: channel)
                return false
            }
        }

        /// The refusal log line, in ONE place.
        ///
        /// Kept in one place so every one-shot channel uses the same refusal token.
        private func logOneShotRefusal(_ refusal: OneShotRefusal,
                                       oneShot: RenderOneShot,
                                       channel: String) {
            bridgeLog("rejected channel=\(channel) reason=\(refusal.rawValue)-\(oneShot.rawValue)")
        }

        /// Debug-gated bridge diagnostic — the rejection half of the channels'
        /// validation. The prefix names the COMMITTED generation because an outgoing
        /// document continues posting after a newer load is issued and until it commits.
        /// Same production-silence rule as `navLog`.
        private func bridgeLog(_ line: @autoclosure () -> String) {
            guard DebugModeManager.isLoggingEnabled() else { return }
            print("\(RenderBridgeDiagnostics.prefix(webViewId: webViewId, gate: documentGate)) \(line())")
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
                // Content is now visible (opacity 0→1 via JS reveal()). Drop the
                // SwiftUI loading placeholder. Idempotent — reveal() can fire on
                // re-fits; we only need the first.
                if dict["revealed"] as? Bool == true {
                    if !hasRevealed { hasRevealed = true }
                    return
                }
                // First-layout fit request from monitorHeightJS: the body is laid
                // out (width known) but fit() hasn't run. Run it NOW rather than
                // waiting for didFinish (which waits on external images), so the
                // frame is sized + revealed as soon as the width is known. fit()
                // sets __tmFitDone and re-posts the final height through here.
                if dict["requestFit"] as? Bool == true {
                    // One-shot PER COMMITTED DOCUMENT, enforced in Swift.
                    // `__tmFitRequested` in monitorHeightJS is the JS-side copy
                    // (since P3 it lives in `RenderContentWorld.isolated`, not the
                    // page world) and is only advisory; this is the authoritative
                    // guard, so a document cannot drive an unbounded re-fit loop.
                    // Losing this request is the one of the three that self-heals —
                    // `didFinish` calls `fit()` directly — so it costs timing, not
                    // correctness. That is a reason it is LOW impact, not a reason
                    // to leave it keyed on the issued generation.
                    guard honourOneShot(.fit, channel: "heightChanged") else { return }
                    fit(webView)
                    return
                }
                // Post-image-load width recheck (postImageWidthRecheckJS): the
                // deferred images finished loading and the settled layout now
                // overflows the fitted viewport — fit() measured with those
                // images hidden. Re-run the fit through the sanctioned reset
                // path. One-shot: the JS side sets __tmWidthRefitRequested
                // before posting, so this cannot loop.
                if dict["requestWidthRefit"] as? Bool == true {
                    // Same one-shot-per-COMMITTED-DOCUMENT rule as `requestFit`;
                    // `__tmWidthRefitRequested` is the advisory JS-side copy
                    // (isolated world since P3), not the authority.
                    //
                    // ⚠️ This is the arm where mis-attribution is VISIBLE. If the
                    // outgoing document's late request consumed the incoming
                    // document's slot, the incoming one's real request is refused
                    // and `fitViewportJS`'s idempotency guard (`__tmLayoutVp`
                    // already set) blocks every other re-fit path — so the message
                    // renders with the uncorrected horizontal overflow `758fac32f`
                    // restored, recoverable only by rotating the device.
                    guard honourOneShot(.widthRefit, channel: "heightChanged") else { return }
                    resetAndFit(webView)
                    return
                }
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
            if visualHeight > 0 && visualHeight == height {
                // Latest-wins while frozen: show→hide can return to the
                // already-applied height before the buffered expanded height
                // flushes. Drop that obsolete buffer instead of expanding the
                // row after the user has collapsed it again.
                pendingHeight = nil
                return
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

/// Neutralize content that overflows the LEFT edge (which `html{overflow-x:clip}`
/// hard-clips, cutting off the first character(s) of a line). `fitViewportJS`
/// only handles RIGHT overflow (it widens + scales), so left overflow is invisible
/// to it. The classic cause is a desktop email's negative `margin-left` /
/// `text-indent` (list hanging-indents, e.g. `li { margin-left:-47px;
/// text-indent:-17px }`) sized for a wide centered container; on a narrow
/// device-width render the container sits at the edge so those negatives push the
/// content off-screen-left (Meta/WhatsApp newsletter: nested `<li>` clipped ~8px,
/// "Initial"→"nitial", "Business"→"usiness"; logmain.log 2026-06-30).
///
/// Conservative + scoped: only elements whose left edge is actually PAST the body's
/// left edge get their NEGATIVE `margin-left` / `text-indent` zeroed (a block
/// element with a negative left margin is also WIDER than its container, so zeroing
/// it makes the box fit and the text reflow into view). Positive margins/indents
/// and non-overflowing elements are untouched, so well-rendered emails are
/// unaffected (their content never overflows the body's left edge). Top-down
/// document order means fixing a parent reflows its children before they're tested.
/// Runs at documentEnd before `eatGutterMarginsJS`/fit so the corrected layout
/// flows through both. Exposed for unit tests via `_constrainLeftOverflowJS`.
internal var _constrainLeftOverflowJS: String { constrainLeftOverflowJS }
private var constrainLeftOverflowJS: String {
    let ll = DebugModeManager.isLoggingEnabled()
        ? "function ll(s){try{window.webkit.messageHandlers.consoleLog.postMessage('[LeftFix] '+s);}catch(_){}}"
        : "function ll(s){}"
    return """
    (function() {
        \(ll)
        function fixLeft(tag) {
            if (!document.body) return;
            try {
                var bl = document.body.getBoundingClientRect().left;
                var els = document.body.getElementsByTagName('*');
                var fixed = 0, seen = 0, spill = 0, lists = 0;
                // (0) NORMALIZE hanging-bullet lists. Desktop emails style lists with
                // negative margin-left / text-indent on <li> (a hanging-bullet indent
                // sized for a wide container). Just zeroing those un-clips the text but
                // leaves the bullets un-indented ("bullets not indented properly"). So
                // for any <ul>/<ol> that carries the hack, reset it to a clean,
                // mobile-friendly list: outside markers, a sane padding-left for the
                // marker gutter, and zeroed item negatives. Only touches lists that
                // actually use the hack, so normal lists are unaffected.
                var listEls = document.body.querySelectorAll('ul, ol');
                for (var q = 0; q < listEls.length; q++) {
                    var L = listEls[q];
                    var Lcs = window.getComputedStyle(L);
                    var hack = (parseFloat(Lcs.marginLeft) || 0) < 0;
                    var kids = L.children;
                    for (var q2 = 0; q2 < kids.length && !hack; q2++) {
                        if (kids[q2].tagName === 'LI') {
                            var Ics = window.getComputedStyle(kids[q2]);
                            if ((parseFloat(Ics.marginLeft) || 0) < 0 || (parseFloat(Ics.textIndent) || 0) < 0) hack = true;
                        }
                    }
                    if (!hack) continue;
                    L.style.setProperty('margin-left', '0', 'important');
                    L.style.setProperty('list-style-position', 'outside', 'important');
                    if ((parseFloat(Lcs.paddingLeft) || 0) < 24) L.style.setProperty('padding-left', '24px', 'important');
                    for (var q3 = 0; q3 < kids.length; q3++) {
                        if (kids[q3].tagName === 'LI') {
                            kids[q3].style.setProperty('margin-left', '0', 'important');
                            kids[q3].style.setProperty('text-indent', '0', 'important');
                            kids[q3].style.setProperty('padding-left', '0', 'important');
                        }
                    }
                    lists++; fixed++;
                    if (lists <= 4) ll(tag + ' list-normalize ' + L.tagName + '.' + (L.className || '').toString().slice(0, 20) + ' pl=' + Lcs.paddingLeft + '→24 items=' + kids.length);
                }
                // Then the two general left-overflow mechanisms (non-list content):
                //  (A) box overflow — the element's own box is past the left edge
                //      (negative margin-left, e.g. the <li> at -47). getBoundingClientRect
                //      catches it; we walk the ancestor chain zeroing negatives.
                //  (B) text-indent SPILL — the box fits but a small negative text-indent
                //      shifts the first line's TEXT left of the body edge WITHOUT moving
                //      the box (footer "Help Center" with direct text, no inline child),
                //      so (A) can't see it. Detect via content-left + text-indent < bl.
                //      Exclude huge negatives (image-replacement, e.g. -9999px).
                for (var i = 0; i < els.length; i++) {
                    var el = els[i];
                    var r = el.getBoundingClientRect();
                    if (r.width <= 0 || r.height <= 0) continue;
                    var cs0 = window.getComputedStyle(el);
                    var ti0 = parseFloat(cs0.textIndent) || 0;
                    if (ti0 < 0 && ti0 > -1000) {
                        var contentLeft = r.left + (parseFloat(cs0.borderLeftWidth) || 0) + (parseFloat(cs0.paddingLeft) || 0);
                        if (contentLeft + ti0 < bl - 1) {
                            el.style.setProperty('text-indent', '0', 'important');
                            fixed++;
                            if (spill < 5) { ll(tag + ' textspill ' + el.tagName + '.' + (el.className || '').toString().slice(0, 20) + ' cl=' + Math.round(contentLeft) + ' ti=' + Math.round(ti0) + ' → 0'); spill++; }
                        }
                    }
                    if (r.left >= bl - 1) continue; // box not overflowing the left edge
                    seen++;
                    var node = el, depth = 0, didFix = false;
                    while (node && node !== document.body && depth < 8) {
                        var ncs = window.getComputedStyle(node);
                        var nml = parseFloat(ncs.marginLeft) || 0;
                        var nti = parseFloat(ncs.textIndent) || 0;
                        if (nml < 0) { node.style.setProperty('margin-left', '0', 'important'); didFix = true; }
                        if (nti < 0) { node.style.setProperty('text-indent', '0', 'important'); didFix = true; }
                        if (seen <= 4 && (nml < 0 || nti < 0 || depth === 0)) {
                            ll(tag + ' overflow ' + el.tagName + ' left=' + Math.round(r.left) + ' | anc[' + depth + ']='
                                + node.tagName + '.' + (node.className || '').toString().slice(0, 20)
                                + ' ml=' + Math.round(nml) + ' ti=' + Math.round(nti) + ' disp=' + ncs.display
                                + (nml < 0 ? ' ZEROml' : '') + (nti < 0 ? ' ZEROti' : ''));
                        }
                        node = node.parentElement; depth++;
                    }
                    if (didFix) fixed++;
                }
                var newMin = Infinity;
                for (var k = 0; k < els.length; k++) {
                    var rr = els[k].getBoundingClientRect();
                    if (rr.width > 0 && rr.height > 0 && (rr.left - bl) < newMin) newMin = rr.left - bl;
                }
                ll(tag + ' done: lists=' + lists + ' seen=' + seen + ' spill=' + spill + ' fixed=' + fixed + ' newMinLeftInset=' + (isFinite(newMin) ? Math.round(newMin) : 'n/a'));
            } catch (e) { ll('error: ' + (e && e.message ? e.message : e)); }
        }
        // Run at documentEnd, then RE-RUN after later reflows re-introduce left
        // overflow — notably our own gutter adjustment (eatGutterMarginsJS posts a
        // reduced SwiftUI padding → the webview widens → content reflows, and an
        // element's negative offset can land past the new left edge AFTER the
        // documentEnd pass already ran), plus deferred-image loads. Idempotent
        // (zeroing an already-zeroed value is a no-op), so extra passes are safe.
        fixLeft('docEnd');
        requestAnimationFrame(function() { requestAnimationFrame(function() { fixLeft('raf2'); }); });
        setTimeout(function() { fixLeft('t500'); }, 500);
        setTimeout(function() { fixLeft('t1500'); }, 1500);
    })();
    """
}

/// Dark mode fix (injected as WKUserScript at document end — no blink).
/// - Near-white (bright + low saturation) backgrounds → stripped to transparent,
///   OR darkened into a sunken panel — which of the two depends on the
///   PAGE_DOMINANCE pre-pass below (see the two-regime comment inside the
///   nearWhite branch: page-color-repeated-everywhere goes transparent,
///   an individual bright card stays a panel).
/// - Colored backgrounds → dimmed to ~brightness 80 so white text is readable.
/// - Dark inline text → forced to light #fbfbfe.
/// - Links inside colored-bg elements → forced to white (overrides CSS blue).
/// Exposed as `internal` for unit tests (same pattern as `_fitViewportJS`).
internal var _fixDarkModeColorsJS: String { fixDarkModeColorsJS }
private var fixDarkModeColorsJS: String {
    let dl = DebugModeManager.isLoggingEnabled()
        ? "function dl(s){try{window.webkit.messageHandlers.consoleLog.postMessage('[DarkMode] '+s);}catch(_){}}"
        : "function dl(s){}"
    return """
    (function() {
        \(dl)
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
        // "Chrome" = a deliberate box: a visible border, rounded corners, or a
        // shadow. Shared by the PAGE_DOMINANCE pre-pass below and the main
        // loop so both apply the identical predicate.
        function computeHasChrome(cs) {
            var hasBorder = (parseFloat(cs.borderTopWidth) || 0) > 0 || (parseFloat(cs.borderRightWidth) || 0) > 0
                || (parseFloat(cs.borderBottomWidth) || 0) > 0 || (parseFloat(cs.borderLeftWidth) || 0) > 0;
            return hasBorder || (parseFloat(cs.borderTopLeftRadius) || 0) > 0 || (!!cs.boxShadow && cs.boxShadow !== 'none');
        }
        var els = document.querySelectorAll('body, body *');

        // PAGE-COLOR dominance pre-pass — mirrors the dominance-guard idiom
        // used by normalizeIndentJS (the OWA whole-column-indent fix): one
        // cheap global measurement gates a DIFFERENT per-element treatment
        // below, instead of trying to decide "is THIS ONE near-white surface
        // a page background" locally — a single element can't see how many
        // sibling elements carry the identical fill.
        //
        // Why this exists: the nearWhite branch's own comment names case (a)
        // — "a full-bleed wrapper that should DISAPPEAR" — but every
        // near-white surface used to be treated as case (b) (a distinct
        // panel), because "outermost near-white" was the only signal. A
        // cloud-console notification email bakes `background-color:
        // rgb(250,250,248)` inline on EVERY paragraph/heading — no single
        // shared wrapper carries the page color — so each block is
        // independently "outermost" (no OTHER near-white is its ancestor)
        // and got its own sunken-panel overlay: 103 rgba(0,0,0,0.22) hits
        // stacking into dark stripes behind every line of text (logmain.log
        // 2026-07-07). The panel treatment is correct for a bright card
        // WITHIN a page — e.g. Scholar's paper-card digest, guarded by
        // darkModeNearWhitePanelDarkening — wrong when the near-white IS the
        // email's own page color, repeated block-by-block.
        //
        // Discriminator: what SHARE of the body's area do near-white,
        // CHROME-LESS (a bordered/rounded/shadowed box is always a
        // deliberate card, never "the page") surfaces jointly cover, keeping
        // only the OUTERMOST of them so a nested repeat of the same fill
        // isn't double-counted.
        var PAGE_DOMINANCE = 0.6; // A multi-card email's near-white area stays
            // well under half the page (individual cards); a page-color email
            // (the cloud-console case) covers most/all of it. 0.6 keeps a
            // clear margin above "roughly half the page happens to be light".
        var pageColorMode = false;
        if (document.body) {
            var bodyRect = document.body.getBoundingClientRect();
            var bodyArea = bodyRect.width * bodyRect.height;
            if (bodyArea > 0) {
                var pageCandidates = [];
                for (var pi = 0; pi < els.length; pi++) {
                    var pgEl = els[pi];
                    var pgCs = window.getComputedStyle(pgEl);
                    var pgBg = parseRGB(pgCs.backgroundColor);
                    var pgHasBg = pgBg && pgBg.a > 0.1;
                    var pgL = pgHasBg ? lum(pgBg.r, pgBg.g, pgBg.b) : 256;
                    var pgS = pgHasBg ? sat(pgBg.r, pgBg.g, pgBg.b) : 0;
                    var pgNearWhite = pgHasBg && pgL > 220 && pgS < 10;
                    if (!pgNearWhite || computeHasChrome(pgCs)) continue;
                    pgEl.__tmPageColorCandidate = true;
                    pageCandidates.push(pgEl);
                }
                var pageSum = 0, pageOuterCount = 0;
                for (var pj = 0; pj < pageCandidates.length; pj++) {
                    var pcEl = pageCandidates[pj];
                    var pcNested = false;
                    for (var pp = pcEl.parentElement; pp; pp = pp.parentElement) {
                        if (pp.__tmPageColorCandidate) { pcNested = true; break; }
                    }
                    if (pcNested) continue;
                    pageOuterCount++;
                    var pcRect = pcEl.getBoundingClientRect();
                    pageSum += Math.min(pcRect.width * pcRect.height, bodyArea);
                }
                var pageShare = pageSum / bodyArea;
                pageColorMode = pageShare >= PAGE_DOMINANCE;
                dl('pageColorMode=' + pageColorMode + ' share=' + pageShare.toFixed(2)
                    + ' outerCandidates=' + pageOuterCount + ' totalCandidates=' + pageCandidates.length);
            } else {
                dl('pageColorMode=false (zero body area)');
            }
        } else {
            dl('pageColorMode=false (no body)');
        }

        for (var i = 0; i < els.length; i++) {
            var el = els[i];
            var cs = window.getComputedStyle(el);
            var bg = parseRGB(cs.backgroundColor);
            var hasBg = bg && bg.a > 0.1;
            var bgL = hasBg ? lum(bg.r, bg.g, bg.b) : 256;
            var bgS = hasBg ? sat(bg.r, bg.g, bg.b) : 0;
            var nearWhite = hasBg && bgL > 220 && bgS < 10;
            var coloredBg = hasBg && !nearWhite;
            // "Chrome" = a deliberate box: a visible border, rounded corners, or a
            // shadow. Such boxes (cards, callouts like Scholar's "Important" note)
            // must stay DISTINCT from their surroundings in dark mode — otherwise a
            // cream callout inside a cream section both collapse to the same dimmed
            // luminance and the box's fill "disappears", leaving only its border.
            var hasChrome = computeHasChrome(cs);
            if (hasBg) {
                dl((nearWhite ? 'nearWhite' : 'colored') + ' ' + el.tagName + '.' + (el.className || '')
                    + ' bg=rgb(' + bg.r + ',' + bg.g + ',' + bg.b + ') L=' + Math.round(bgL) + ' S=' + Math.round(bgS)
                    + ' chrome=' + (hasChrome ? 1 : 0)
                    + ' w=' + Math.round(el.getBoundingClientRect().width)
                    + ' text=' + ((el.textContent || '').replace(/\\u00a0/g, ' ').trim().length > 0 ? 1 : 0)
                    + ' "' + (el.innerText || '').slice(0, 18).replace(/\\s+/g, ' ') + '"');
            }
            if (nearWhite) {
                // A near-white surface is one of two things in dark mode:
                //   (a) a full-bleed wrapper (or a wholesale page color repeated
                //       block-by-block) that should DISAPPEAR so the dark card
                //       bubble shows through, or
                //   (b) a distinct PANEL (a bright card in light mode) that should
                //       stay visible — and, per design, render DARKER than its
                //       surroundings rather than blending in (Scholar's white paper
                //       cards were vanishing because we forced transparent).
                //
                // Two regimes, gated by the PAGE_DOMINANCE pre-pass above:
                //
                //   pageColorMode = true — the near-white IS this email's page
                //   color (see the pre-pass comment for the cloud-console/103-panel
                //   failure case, logmain.log 2026-07-07). Case (a) applies
                //   unconditionally to every CHROME-LESS near-white block: go
                //   transparent, never mark data-tm-panel — regardless of whether
                //   THIS block happens to be nested under another near-white block,
                //   because in this regime there is no "outermost card", only
                //   repeated page background. A CHROME box (border/radius/shadow —
                //   a deliberate card) is never page color, so it always falls
                //   through to the case (b) treatment below, unchanged.
                //
                //   pageColorMode = false — the ordinary case (Scholar's paper
                //   cards, Anthropic/Amazon receipts): per-element case (b) logic,
                //   EXACTLY as before this pre-pass was added. The OUTERMOST
                //   near-white surface (no already-converted near-white ancestor)
                //   gets a translucent-black overlay so it reads as a slightly
                //   sunken panel, darker than whatever is behind it (the dimmed
                //   section bg, or the card). NESTED near-whites stay transparent
                //   so overlays can't stack into mud on white-heavy emails.
                //   Translucent (not opaque) so it composites over the real
                //   backdrop — that is what makes it "darker than the surrounding"
                //   for free. Darken (= make a visible sunken panel) if this is a
                //   distinct surface: the OUTERMOST near-white, OR a CHROME box
                //   even when nested (a bordered callout must keep a fill, not
                //   just its border). Only PLAIN nested wrappers (no chrome) go
                //   transparent.
                if (pageColorMode && !hasChrome) {
                    el.style.setProperty('background-color', 'transparent', 'important');
                    if (el.style.background) el.style.setProperty('background', 'transparent', 'important');
                    dl('pageColor→transparent ' + el.tagName + '.' + (el.className || '') + ' w=' + Math.round(el.getBoundingClientRect().width));
                } else {
                    var ancestorPanel = el.parentElement && el.parentElement.closest('[data-tm-panel]');
                    if (ancestorPanel && !hasChrome) {
                        el.style.setProperty('background-color', 'transparent', 'important');
                        if (el.style.background) el.style.setProperty('background', 'transparent', 'important');
                    } else {
                        el.style.setProperty('background-color', 'rgba(0,0,0,0.22)', 'important');
                        if (el.style.background) el.style.setProperty('background', 'rgba(0,0,0,0.22)', 'important');
                        el.setAttribute('data-tm-panel', '1');
                        dl('panel→darken ' + el.tagName + '.' + (el.className || '') + ' chrome=' + (hasChrome ? 1 : 0) + ' w=' + Math.round(el.getBoundingClientRect().width));
                    }
                }
                if (el.hasAttribute('bgcolor')) el.removeAttribute('bgcolor');
            }
            // Only dim a colored fill that actually carries TEXT — the dim exists
            // to keep (white) text legible on the fill. A decorative colored
            // element with NO text (score/accent bars, rule lines, swatches) must
            // keep its hue: forcing every colored bg to luminance ~80 collapses
            // sender color-coding (Scholar Inbox per-paper score bars #C14600 and
            // #E57C4F both became lum~80 → indistinguishable; logmain.log
            // 2026-06-29). textContent is recursive, so a colored WRAPPER that
            // contains text is still dimmed (its text still needs the contrast).
            var elHasText = (el.textContent || '').replace(/\\u00a0/g, ' ').trim().length > 0;
            // Preserve DELIBERATE, SATURATED colors (score badges, chips, brand
            // buttons/accents) — dimming them to a fixed luminance collapses their
            // hue and any color-coding (Scholar's score badges #C14600 vs #E57C4F
            // both flattened to lum~80). Only LIGHT, LOW-SATURATION tinted fills
            // (section backgrounds) get dimmed, where the dim is really about
            // keeping light text legible. Text contrast on a preserved saturated
            // fill is handled by the contrast safety net below. Threshold 100
            // separates the score colors (sat 150/193) from cream section fills
            // (sat 15-34) and the CAUTION banner (sat 76).
            var saturated = bgS > 100;
            if (coloredBg && bgL > 80 && elHasText && saturated) {
                dl('keep(saturated) ' + el.tagName + '.' + (el.className || '') + ' bg=rgb(' + bg.r + ',' + bg.g + ',' + bg.b + ') S=' + Math.round(bgS) + ' "' + (el.innerText || '').slice(0, 12).replace(/\\s+/g, ' ') + '"');
            }
            if (coloredBg && bgL > 80 && elHasText && !saturated) {
                // Dim light tinted fills so light text stays legible. A CHROME box
                // (bordered callout, e.g. the "Important" note) dims to a DARKER
                // target so it stands out from its dimmed surroundings instead of a
                // cream-on-cream collapse (both → lum 80 → fill looks empty). Plain
                // section fills keep the lum-80 target.
                var target = hasChrome ? 50 : 80;
                var f = target / bgL;
                var nr = Math.round(bg.r * f);
                var ng = Math.round(bg.g * f);
                var nb = Math.round(bg.b * f);
                var dimmed = 'rgb(' + nr + ',' + ng + ',' + nb + ')';
                el.style.setProperty('background-color', dimmed, 'important');
                if (el.style.background) el.style.setProperty('background', dimmed, 'important');
                if (hasChrome) dl('dim(chrome→' + target + ') ' + el.tagName + '.' + (el.className || '') + ' "' + (el.innerText || '').slice(0, 14).replace(/\\s+/g, ' ') + '"');
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
}

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

/// Resolves the boundary text node to the element the quote wrapper is
/// inserted before ("quoteStart"): climbs from the text node's parent toward
/// `body` until a block-level element is found.
///
/// The climb carries the same prior-content guard as `walkUpToWrapStart`:
/// if the current (inline) element has a previous sibling with real text,
/// climbing further would swallow the user's own reply — so the inline
/// element itself becomes the quoteStart. This handles flat webmail HTML
/// (MailPlug/Zimbra) where `<font>----- Original Message -----<br>From : …</font>`
/// is a direct sibling of the reply `<p>`s: the nearest block ancestor is the
/// whole-body container, and using it would collapse the entire message
/// (regression: only "Show quoted text" visible, reply hidden).
///
/// `getDisplay` abstracts `window.getComputedStyle(el).display` so unit tests
/// (JSContext, synthetic node trees with no CSSOM) can inject a stub.
///
/// Defined as a top-level JS string so that `collapseQuotesJS` (production)
/// and `EmailFilterTests` (unit tests) consume the same source — zero-drift
/// guarantee.
let findQuoteStartBlockJS = """
function findQuoteStartBlock(targetNode, body, getDisplay, logFn) {
    var quoteStart = targetNode.parentNode;
    while (quoteStart && quoteStart !== body) {
        var display = getDisplay(quoteStart);
        if (display === 'block' || display === 'flex' || display === 'table' ||
            quoteStart.tagName === 'DIV' || quoteStart.tagName === 'P' ||
            quoteStart.tagName === 'BLOCKQUOTE' || quoteStart.tagName === 'TABLE' ||
            quoteStart.tagName === 'BR') {
            break;
        }
        var hasPriorContent = false;
        for (var sib = quoteStart.previousSibling; sib; sib = sib.previousSibling) {
            if ((sib.textContent || '').trim().length >= 2) { hasPriorContent = true; break; }
        }
        if (hasPriorContent) {
            logFn('[QuoteDetect] Block walk stopped at inline ' + quoteStart.tagName + '.' + (quoteStart.className || '') + ': prior content sibling, climbing would swallow reply');
            break;
        }
        quoteStart = quoteStart.parentNode;
    }
    return quoteStart;
}
"""

/// Sweeps everything positioned AFTER `quoteStart` in document order — at
/// EVERY ancestor level up to (and including) the direct child of `body` —
/// into `content`.
///
/// `walkUpToWrapStart` deliberately stops climbing as soon as it finds real
/// prior content at some level (to avoid swallowing the user's own reply
/// text). That often anchors `quoteStart` several levels deep — e.g. a
/// boundary `<p>` ("----- Original Message -----") living in the SAME
/// container as the visible reply paragraphs, because a webmail composer
/// (Zimbra, Outlook web, etc.) emitted both as flat sibling `<p>` tags in
/// one div. A single-level `nextSibling` sweep then only captures content
/// within THAT one container — leaving genuinely-quoted material that sits
/// structurally outside it (a sibling of an ANCESTOR, not of `quoteStart`
/// itself — e.g. a nested "On X wrote:" blockquote one level up) visible,
/// un-collapsed. Symptom: quote detection finds the right boundary line,
/// but the collapsed region doesn't reach the true end of the message.
///
/// This sweeps `quoteStart`'s own remaining siblings first, then climbs to
/// its parent and sweeps ITS remaining siblings, and so on up to (and
/// including) the direct child of `body` — mirroring `walkUpToWrapStart`'s
/// own climb boundary. Because it only ever follows `nextSibling` chains
/// (never `previousSibling`), it can never pull in anything that appears
/// BEFORE the boundary at any level — `walkUpToWrapStart`'s "don't swallow
/// real content" guarantee holds regardless of how many levels this climbs.
///
/// Stops early if it hits a `.tm-ics-collapsible` marker (owned by the
/// separate ICS collapse pass, `collapseICSJS`).
///
/// Defined as a top-level JS string so that `collapseQuotesJS` (production)
/// and `EmailFilterTests` (unit tests via JSContext with synthetic tree
/// mocks) consume the same source — zero-drift guarantee.
let sweepQuoteContentJS = """
function sweepQuoteContent(quoteStart, content, body, logFn) {
    var node = quoteStart;
    while (node && node.parentNode) {
        var hitICS = false;
        while (node.nextSibling) {
            var ns = node.nextSibling;
            try { if (ns.classList && ns.classList.contains('tm-ics-collapsible')) { hitICS = true; break; } } catch(_) {}
            content.appendChild(ns);
        }
        if (hitICS) break;
        if (node.parentNode === body) break;
        node = node.parentNode;
        logFn('[QuoteDetect] Sweep climbed to ancestor: ' + node.tagName + '.' + (node.className || ''));
    }
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
internal var _collapseQuotesJS: String { collapseQuotesJS }
internal let _userDisclosureOwnershipJS = """
window.__tmUserDisclosurePending = false;
window.__tmConsumeUserDisclosure = function() {
    var pending = window.__tmUserDisclosurePending === true;
    window.__tmUserDisclosurePending = false;
    return pending;
};
"""
internal let _consumeUserDisclosureExpression = "(typeof window.__tmConsumeUserDisclosure === 'function' ? window.__tmConsumeUserDisclosure() : false)"
internal let _postDisclosureHeightJS = """
var tmScroll = document.body.scrollHeight;
var tmRect = Math.ceil(document.body.getBoundingClientRect().height);
var tmHeight = tmRect > 0 && tmRect < tmScroll ? tmRect : tmScroll;
var tmVp = window.__tmLayoutVp || window.__tmDeviceWidth || window.innerWidth;
if (tmHeight > 0) {
    window.webkit.messageHandlers.heightChanged.postMessage({
        h: tmHeight,
        vp: tmVp,
        scroll: tmScroll,
        rect: tmRect,
        userDisclosure: \(_consumeUserDisclosureExpression)
    });
}
"""
private var collapseQuotesJS: String {
    let logBody = DebugModeManager.isLoggingEnabled()
        ? "try { window.webkit.messageHandlers.consoleLog.postMessage(m); } catch(_) {}"
        : ""
    return """
    (function() {
        // The flag is one-shot: only the first height after a real disclosure
        // tap may disarm the detail view's opening anchor. Leaving it sticky
        // would misclassify unrelated later image/layout heights as new taps.
        function _log(m) { \(logBody) }
        \(walkUpToWrapStartJS)
        \(splitBlockBeforeTargetJS)
        \(findQuoteStartBlockJS)
        \(sweepQuoteContentJS)
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
                    window.__tmUserDisclosurePending = true;
                    wrapperI.classList.toggle('tm-collapsed');
                    var collapsed = wrapperI.classList.contains('tm-collapsed');
                    toggleI.innerHTML = '<span class="tm-quote-toggle-text">' + (collapsed ? showLabelI : hideLabelI) + '</span>';
                    setTimeout(function() {
                        try { \(_postDisclosureHeightJS) } catch(ex) {}
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
            // Find the closest block-level ancestor — with a prior-content
            // guard so a boundary living in an inline element (MailPlug/Zimbra
            // flat <font> sibling of the reply <p>s) doesn't climb to the
            // whole-body container and swallow the reply. Logic lives in
            // `findQuoteStartBlockJS` for unit testability.
            quoteStart = findQuoteStartBlock(targetNode, body, function(el) {
                return window.getComputedStyle(el).display;
            }, _log);
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
            window.__tmUserDisclosurePending = true;
            wrapper.classList.toggle('tm-collapsed');
            var collapsed = wrapper.classList.contains('tm-collapsed');
            toggle.innerHTML = '<span class="tm-quote-toggle-text">' + (collapsed ? showLabel : hideLabel) + '</span>';
            // Signal native side to re-measure height
            setTimeout(function() {
                try { \(_postDisclosureHeightJS) } catch(ex) {}
            }, 50);
        });

        var content = document.createElement('div');
        content.className = 'tm-quote-content';

        quoteStart.parentNode.insertBefore(wrapper, quoteStart);
        wrapper.appendChild(toggle);
        wrapper.appendChild(content);

        // Move everything from quoteStart to the true end of the message into
        // content (but not ICS sections) — climbs through every ancestor
        // level so trailing quoted content isn't stranded outside the
        // wrapper when quoteStart is anchored deep (see sweepQuoteContentJS).
        sweepQuoteContent(quoteStart, content, body, _log);
        content.insertBefore(quoteStart, content.firstChild);

    })();
    """ }

/// Separate script for ICS invite collapsible sections.
/// Runs independently from quote collapse — finds `.tm-ics-collapsible` markers
/// and wraps them using the same CSS classes as quotes.
internal var _collapseICSJS: String { collapseICSJS }
private let collapseICSJS = """
    (function() {
        // Keep exact app-created node references in the isolated content world.
        // A CSS class is not an ownership boundary: sender HTML can spoof any
        // class name even though sender script cannot see this isolated global.
        var ownedWrappers = [];
        window.__tmICSDisclosureWrappers = ownedWrappers;
        var icsMarkers = document.querySelectorAll('.tm-ics-collapsible');
        if (!icsMarkers.length) return;
        for (var i = 0; i < icsMarkers.length; i++) {
            (function(icsDiv) {
                var showLabel = 'Show invite details';
                var hideLabel = 'Hide invite details';
                var wrapper = document.createElement('div');
                // BodyRenderer appends the invite marker directly under body,
                // outside sender-owned inset containers. The dedicated class lets
                // eatGutterMarginsJS align this app chrome to the measured email
                // column without mutating sender content.
                wrapper.className = 'tm-quote-wrapper tm-ics-wrapper tm-collapsed';
                wrapper.style.marginTop = '12px';
                var toggle = document.createElement('div');
                toggle.className = 'tm-quote-toggle';
                toggle.innerHTML = '<span class="tm-quote-toggle-text">' + showLabel + '</span>';
                toggle.addEventListener('click', function(e) {
                    e.stopPropagation();
                    window.__tmUserDisclosurePending = true;
                    wrapper.classList.toggle('tm-collapsed');
                    var collapsed = wrapper.classList.contains('tm-collapsed');
                    toggle.innerHTML = '<span class="tm-quote-toggle-text">' + (collapsed ? showLabel : hideLabel) + '</span>';
                    setTimeout(function() {
                        try { \(_postDisclosureHeightJS) } catch(ex) {}
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
                ownedWrappers.push(wrapper);
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
///   - `userDisclosure`: true after app-owned quote/invite chrome was
///     toggled, so native disarms its opening anchor before applying `h`
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
/// Swap deferred remote images back in AFTER the first paint. `EmailHTMLWrapper`
/// rewrites remote `<img src/srcset>` → `data-tmsrc/data-tmsrcset` so the initial
/// document has NO pending image loads — WebKit then paints the text/layout
/// immediately instead of blocking the first compositor frame on dozens of remote
/// fetches (the Vancouver Sun 2.7s empty-box; 28 pending images). This restores
/// the real URLs once the first paint has happened, so images stream in and the
/// frame grows via the ResizeObserver. (We AUTO-load rather than block-with-banner
/// — banner-blocking was smoke-tested 2026-06-17 and broke too many messages.)
///
/// `swap()` withholds the URL from images our own view-mode CSS has hidden — see
/// `hiddenByViewMode` inside the emitted script for the predicate, its FOUR
/// governing CSS rules, its fail-open guard, and the explicit list of what it does
/// NOT treat as hidden. The predicate is inside `swap()` on purpose: it is called
/// from BOTH the post-paint arm and the 1500ms failsafe, and filtering at the call
/// sites instead would let the failsafe re-fetch everything the post-paint arm
/// withheld — a silent no-op.
///
/// This script is injected UNCONDITIONALLY — it is a production render path, not
/// a diagnostic — so the debug-only `window.__tmImageDiagWillAssign` hook is
/// emitted only when `diagnosticsEnabled`. **Both halves of that gating matter and
/// neither is sufficient alone:**
///
/// 1. When diagnostics are OFF the hook call is not emitted at all, so an ungated
///    build's script contains no reference to a global that only sender-authored
///    script could define. (Author JavaScript is still enabled in the message
///    webview; the CSP / `allowsContentJavaScript` hardening is a later phase.)
/// 2. When diagnostics are ON the call is still wrapped, because the hook can
///    genuinely exist on a user's device — `DebugModeManager.isLoggingEnabled()`
///    is true for unlocked accounts in release builds. An uncaught throw out of
///    the hook would skip the `removeAttribute`/`setAttribute` pair AND abort the
///    whole loop, so every remaining deferred image on that message would stay
///    hidden forever (the post-paint arm and the 1500ms failsafe abort at the
///    same element). The throw the wrap actually has to catch is one raised
///    inside OUR OWN hook body, which reads sender-controlled DOM properties off
///    the image: `imageId()` reads `image.__tmImageDiagId`, and the log line
///    reads `image.complete`, `image.naturalWidth` and `image.naturalHeight`.
///    Author script can turn any of those into a throwing accessor with
///    `Object.defineProperty` on the element — an own property shadows the
///    prototype getter — and our hook has no way to read them safely.
///
///    ⚠️ Until 2026-08-12 this clause also said the wrap was needed "because
///    author script can overwrite OUR hook after we install it". That stopped
///    being true at `cb46bc46c`, which installs `__tmImageDiagWillAssign` with
///    `writable: false, configurable: false`; the sibling doc on
///    `imageLoadDiagnosticJS` and its **Amplification** bullet now both DEPEND on
///    the sender being unable to do that. A reader who trusted the stale clause
///    would conclude the non-replaceable install is decorative and could be
///    relaxed. The wrap survives on the clause above it, not on this one — and a
///    justification that outlives its reason is not a weaker justification, it is
///    a false statement about the system sitting next to correct code.
///
/// Exposed for unit tests via `_deferredImageLoadJS(diagnosticsEnabled:)`.
internal func _deferredImageLoadJS(diagnosticsEnabled: Bool) -> String {
    deferredImageLoadJS(diagnosticsEnabled: diagnosticsEnabled)
}
private func deferredImageLoadJS(diagnosticsEnabled: Bool) -> String {
    // Emitted only under the debug gate; see the doc comment above for why the
    // gate and the try/catch are BOTH required.
    var diagHelper = ""
    var diagSrcsetCall = ""
    var diagSrcCall = ""
    var swapCensusLog = ""
    if diagnosticsEnabled {
        // Per-load, per-trigger census so a failed device smoke test is
        // diagnosable from the log without a rebuild: how many deferred images
        // this trigger assigned a URL to, and how many it withheld because the
        // section that owns them is hidden. `total` is the selector's match
        // count, so `swapped + skippedHidden == total` on every line — a line
        // where it does not is a swap that threw past the census.
        swapCensusLog = "\n" + """
                    try {
                        window.webkit.messageHandlers.consoleLog.postMessage(
                            '[DeferImg] ' + trigger + ' total=' + imgs.length +
                            ' swapped=' + swapped + ' skippedHidden=' + skippedHidden);
                    } catch (_) {}
        """
        diagHelper = "\n" + """
            // Diagnostics only, and deliberately unable to affect the swap: a
            // throwing or hostile hook must never prevent the assignment below
            // or abort the loop over the remaining deferred images.
            function diag(im, attribute, raw, trigger) {
                try {
                    if (typeof window.__tmImageDiagWillAssign === 'function') {
                        window.__tmImageDiagWillAssign(im, attribute, raw, trigger);
                    }
                } catch (_) {}
            }
        """
        diagSrcsetCall = "\n                diag(im, 'srcset', ss, trigger);"
        diagSrcCall = "\n                diag(im, 'src', s, trigger);"
    }
    return """
    (function() {\(diagHelper)
        // TRUE when `im` sits inside a part of the document that OUR OWN
        // view-mode CSS (`EmailHTMLWrapper.wrapHTML`) has hidden. WebKit fetches
        // an <img> even under `display:none`, so without this the swap below
        // fires the tracking pixels of every attached `.eml` the user never
        // opened (main view, where `.tm-eml-section` is hidden wholesale), and —
        // in the preview sheet — those of the parent message plus every
        // non-selected `.eml`.
        //
        // ⚠️ THIS IS NOT A GENERAL "IS THIS IMAGE VISIBLE" TEST, and the narrow
        // scope is deliberate. Stated negatively, it does NOT catch:
        //   * `visibility:hidden`, `opacity:0`, zero-size, `content-visibility`,
        //     clipped, or merely scrolled-off-screen images;
        //   * an image the SENDER's own CSS hides — a hidden preheader, an
        //     `@media` desktop-only block. Those still fetch, exactly as before
        //     this change. Closing them is NOT free: `fitViewportJS` WIDENS the
        //     layout viewport on overflow (288 → 400 → …), which crosses the
        //     email's own breakpoints, so a media-query-hidden image can become
        //     visible after a widen with no reload;
        //   * an image inside a COLLAPSED QUOTE OR INVITE — see below, this one
        //     is load-bearing;
        //   * a hidden <img> that is itself a direct child of <body> in main
        //     view (the direct-child arm is preview-only, see `preview`);
        //   * a hidden <img> under a SENDER-authored `.tm-eml-headers` in main
        //     view. The class is ours, but no main-view rule of ours acts on
        //     it, so a sender who copies the class name gets bullet two's
        //     treatment (fetches, like any sender-hidden image) rather than a
        //     skip our CSS never earned.
        //
        // Every ancestor this DOES test is governed by one of our own
        // `!important` rules whose value is FIXED for the lifetime of the loaded
        // document:
        //     `.tm-eml-section { display:none !important }`               (main)
        //     `body.tm-preview-mode > *:not(.tm-eml-section)`          (preview)
        //     `body.tm-preview-mode .tm-eml-section[data-filename=…]`  (preview)
        //     `body.tm-preview-mode .tm-eml-headers`                   (preview)
        //
        // ⚠️ The mode column is a GATE, not a label. `wrapHTML`'s main-view
        // branch emits exactly ONE of those four rules; the other three exist
        // only in the preview branch. So an arm may claim `governed` only where
        // a rule for the CURRENT mode exists — `.tm-eml-section`
        // unconditionally, `.tm-eml-headers` and the direct-<body>-child arm
        // under `preview` alone. Until 2026-08-13 the `.tm-eml-headers` arm was
        // unconditional, which let SENDER CSS decide a withhold in main view:
        // `governed` stopped meaning "one of our rules controls this" and the
        // predicate over-withheld on a class the sender can simply write. That
        // direction is the expensive one here — it strands images as permanent
        // blank frames, which is exactly why bullet two declines to honour
        // sender-hidden content in the first place. App-emitted markup is
        // unaffected: `EmlMarker.build` only ever emits `.tm-eml-headers`
        // INSIDE a `.tm-eml-section`, and that section's arm is unconditional,
        // so the walk still reaches a governed ancestor in both modes.
        //
        // ⚠️ SCOPE OF THAT CHANGE, stated because it was described only as WHAT
        // is withheld: it also moves WHEN the P4 failure census is SUPPRESSED. A
        // withheld image whose live candidates cannot settle keeps its deferral
        // attribute, is armed, and reaches no terminal state, so `armedPending()`
        // never falls to 0 — that is the `IOS-UI-004` dead zone. A mixed live
        // `cid:` src plus deferred remote `srcset` can settle from the live src;
        // that accepted first-terminal exception is also recorded in IOS-UI-004.
        // Narrowing this arm narrows the
        // dead zone in MAIN VIEW: a sender-authored `.tm-eml-headers` image used
        // to suppress the census for the whole message and now settles like any
        // other. Toward the honest diagnostic census, and no image's outcome is
        // invented. The note at `pendingImgs()` keeps that diagnostic decision
        // separate from the load-bearing width re-fit.
        //
        // Because the answer cannot change while the document is loaded, NO
        // re-run hook, MutationObserver or IntersectionObserver is needed:
        // `previewFilename` is a `wrapHTML` parameter, so selecting a different
        // `.eml` builds a different document and loads it fresh, and that
        // document's own `swap()` sees the newly-selected section visible.
        //
        // ⚠️ The mechanism is a REMOUNT, not a comparison. This said "the
        // coordinator reloads on `loadedPreviewFilename` change" until
        // 2026-08-13; it does not, and could not — `updateUIView` reloads on
        // `html || reloadToken` and merely RECORDS `loadedPreviewFilename`
        // alongside, and the two `.eml` previews of one message carry IDENTICAL
        // `html` (`AttachmentListView` builds every `EmlPreviewState` from the
        // same parent `bodyHtml`; only `filename` differs), so a coordinator
        // comparison would have found nothing to reload. What actually rebuilds
        // the document is `.sheet(item: $emlPreview)`: `EmlPreviewState.id` is a
        // fresh `UUID()` per selection, so a different attachment presents a new
        // sheet, which constructs a new `AutoSizingHTMLView` and a new
        // `WKWebView` whose `loadedHTML` starts nil. Correct code, false reason —
        // and the false reason is load-bearing, because a reader checking whether
        // this predicate can go stale would have looked for a comparison that
        // isn't there, found nothing, and concluded the invariant was broken.
        //
        // ⚠️ A GENERAL predicate (`offsetParent === null`,
        // `getClientRects().length === 0`) WOULD BE WRONG HERE, and not
        // marginally: `collapseQuotesJS` and `collapseICSJS` build
        // `.tm-quote-wrapper.tm-collapsed`, whose `.tm-quote-content` is
        // `display:none` until the user taps "Show quoted text" / "Show invite
        // details". That is an IN-DOCUMENT reveal — a click handler toggling a
        // class, with no reload — so a general test would skip those images and
        // nothing would ever swap them back in; every quoted reply and collapsed
        // invite would expand to blank frames. This predicate structurally
        // cannot do that: `.tm-quote-content` carries neither of the two classes
        // tested, and always lives inside its `.tm-quote-wrapper`, so it is
        // never a direct child of <body>.
        //
        // Guarded the same way the debug-only diagnostic hook call is, and for
        // the same reason — it runs inside the swap loop, so an uncaught throw
        // would abort the loop and strand every remaining deferred image on the
        // message. It FAILS OPEN (throw ⇒ treat
        // as visible ⇒ swap), preserving the pre-change behaviour; the cost is
        // that a DOM able to make `classList`/`getComputedStyle` throw would
        // defeat the skip. T8 is a privacy leak, not a wrong-message or
        // data-loss class defect, so trading a bounded privacy win for an
        // unbounded rendering regression would be the wrong way round.
        function hiddenByViewMode(im) {
            try {
                var body = document.body;
                if (!body) return false;
                var preview = !!(body.classList &&
                                 body.classList.contains('tm-preview-mode'));
                var el = im;
                while (el && el !== body) {
                    var governed = false;
                    // `.tm-eml-section` is governed in BOTH modes (main hides
                    // them all, preview hides every non-selected one), so its
                    // arm is unconditional. `.tm-eml-headers` is governed in
                    // PREVIEW ONLY — see the mode-gate note in the doc comment
                    // above — so it carries the same `preview` gate as the
                    // direct-<body>-child arm below it.
                    if (el.classList && (el.classList.contains('tm-eml-section') ||
                                         (preview &&
                                          el.classList.contains('tm-eml-headers')))) {
                        governed = true;
                    } else if (preview && el.parentElement === body) {
                        governed = true;
                    }
                    if (governed &&
                        window.getComputedStyle(el).display === 'none') return true;
                    el = el.parentElement;
                }
            } catch (_) {}
            return false;
        }
        function swap(trigger) {
            var imgs = document.querySelectorAll('img[data-tmsrc],img[data-tmsrcset]');
            var swapped = 0, skippedHidden = 0;
            for (var i = 0; i < imgs.length; i++) {
                var im = imgs[i];
                // The predicate lives INSIDE swap(), not at the two call sites,
                // so both the post-paint arm and the 1500ms failsafe inherit it
                // and neither can re-fetch what the other withheld.
                // A skipped image KEEPS its data-tmsrc/data-tmsrcset, so it stays
                // eligible for a later swap and the whole function stays
                // idempotent and re-runnable.
                //
                // It is ALSO marked `data-tmwithheld`, which is what tells the
                // width pipeline this image is never going to arrive. Without
                // that mark T8 permanently disarms the post-load width re-fit:
                // `pendingImgs()` counts a withheld image as still-pending
                // forever, `check()` returns early forever, and a message
                // carrying an attached `.eml` never gets the re-fit that shipped
                // `v1.7.8` performed. The mark is set and cleared on EVERY pass
                // rather than once, so an image that becomes visible between the
                // post-paint arm and the failsafe is un-marked and swapped
                // normally — the attribute tracks the current verdict, never a
                // historical one.
                if (hiddenByViewMode(im)) {
                    im.setAttribute('data-tmwithheld', '1');
                    skippedHidden++;
                    continue;
                }
                im.removeAttribute('data-tmwithheld');
                swapped++;
                var ss = im.getAttribute('data-tmsrcset');
                if (ss) {\(diagSrcsetCall)
                    im.removeAttribute('data-tmsrcset');
                    im.setAttribute('srcset', ss);
                }
                var s = im.getAttribute('data-tmsrc');
                if (s) {\(diagSrcCall)
                    im.removeAttribute('data-tmsrc');
                    im.setAttribute('src', s);
                }
            }\(swapCensusLog)
        }
        // Kick off remote loads only AFTER the first paint, so they can't
        // re-block it. readyState reaches 'complete' fast now (no pending
        // images); a double rAF lands after the first compositor frame.
        function arm() {
            requestAnimationFrame(function() {
                requestAnimationFrame(function() { swap('post-paint'); });
            });
        }
        if (document.readyState === 'complete') arm();
        else window.addEventListener('load', arm, { once: true });
        // Failsafe: images must load even if 'load'/rAF are starved (offscreen
        // throttling, etc.). swap() is idempotent.
        setTimeout(function() { swap('failsafe-1500ms'); }, 1500);
    })();
    """
}

/// Debug-only image network diagnostics installed at document start. This is
/// deliberately observational: nothing in the emitted script retries or probes a
/// remote URL, so viewing an email cannot generate duplicate tracking requests.
///
/// ⚠️ **That property is true of the END STATE but is NOT a property of this
/// script alone**, which is why the sentence above is scoped to what the script
/// emits. Read it together with the **Amplification** bullet in
/// `imageLoadDiagnosticJS`'s own doc comment, which records the unscoped version
/// of this exact claim (commit `71c19d554`'s) as REFUTED. Things outside this
/// script are load-bearing for it, and they include at least the following.
/// **The list below is NOT asserted to be
/// exhaustive, and the count has been removed on purpose.** It said "two" until
/// 2026-08-12 and then "four"; both times a reviewer reading this same paragraph
/// found another. An enumeration of a claim's dependencies is itself an absolute
/// and inherits this entry's whole failure mode, so the honest form is "among the
/// things outside this script that are load-bearing for it are…" — and the way to
/// find out whether the set has grown is to re-derive it, not to read this list.
/// 1. the CALL-SITE OMISSION — `deferredImageLoadJS` emits the
///    `window.__tmImageDiagWillAssign` invocation only when diagnostics are on,
///    so an ungated build never calls a global only sender script could define;
/// 2. the NON-REPLACEABLE INSTALL — `Object.defineProperty(…, writable: false,
///    configurable: false)` at `.atDocumentStart`, which is what keeps the
///    function our own swap invokes OURS rather than the sender's;
/// 3. FRAME-SCOPE PARITY between the install and the swap. Both `WKUserScript`s
///    are `forMainFrameOnly: true` today (`imageLoadDiag` at `.atDocumentStart`,
///    `deferImages` at `.atDocumentEnd`), which is what makes 1 and 2 mean
///    anything. If the SWAP is ever widened to subframes while the install stays
///    main-frame-only, then inside a sender-controlled `<iframe>` the install
///    never ran, while the swap still evaluates
///    `typeof window.__tmImageDiagWillAssign === 'function'` against THAT frame's
///    window — where the sender defined it. `writable: false` is no help:
///    non-replaceability is a property of one window object, not of the name.
///    Do NOT change either flag to fix something else without re-reading this;
///    they are correct as they stand, and they are correct TOGETHER; and
/// 4. the PURITY of every sender-controlled property the hook reads. The hook
///    itself, not just the callee, touches author-controllable state:
///    `imageId()` touches `image.__tmImageDiagId` more than once, and the log line
///    reads `image.complete`, `image.naturalWidth` and `image.naturalHeight`.
///    `Object.defineProperty` on the element installs an own accessor that shadows
///    the prototype getter, and a NON-throwing one that issues a request amplifies
///    from inside our own hook. The try/catch in `deferredImageLoadJS` is aimed at
///    a throwing accessor and does nothing here because nothing throws.
///
///    ⚠️ **This clause said `imageId()` reads the property "TWICE (the `if` test,
///    then the `return`)" until 2026-08-12. Do not restore a count, and do not
///    read the operations as all being GETs.** `imageId` is
///    `if (!image.__tmImageDiagId) image.__tmImageDiagId = nextImageId++; return
///    image.__tmImageDiagId;`. For a TRUTHY stored value that is two gets. For a
///    FALSY one — an accessor returning `0`, `''`, `null` — the `if` test gets,
///    the assignment fires the **SETTER**, and the `return` gets again: at least
///    three operations on a sender-installed accessor pair, one of which is a
///    WRITE. **The setter is a sender-reachable write channel and the old text
///    never mentioned it**: `Object.defineProperty(img, '__tmImageDiagId', {set:
///    …})` runs sender code on assignment, from inside our hook, on a path the
///    ungated build does not even reach. A sender who wants to be invoked simply
///    returns a falsy id.
/// 5. CONTENT-WORLD PARITY between our scripts and the sender's. **⚠️ THIS CLAUSE
///    WAS INVERTED BY P3 (2026-08-13) AND IS KEPT, NOT DELETED, BECAUSE ITS
///    DEPENDENCY DIRECTION IS THE POINT.** It read, correctly until P3: *"every
///    `WKUserScript` in `makeUIView` is created with the
///    `init(source:injectionTime:forMainFrameOnly:)` initialiser — the one that
///    takes no content world — so every one of them runs in the PAGE world,
///    alongside author script, sharing ONE `window`."*
///    That is now FALSE. All 17 are built `in: RenderContentWorld.isolated`, every
///    channel in `bridgeChannels` is registered with `add(_:contentWorld:name:)`,
///    and all three `evaluateJavaScript` call sites name the same world.
///    (The channel count was "three" until P4 added `imageLoadFailure`; it is read
///    from `bridgeChannels` at the registration site, so state the SOURCE here
///    rather than a number that goes stale the next time one is added.)
///    ⚠️ Re-checking this STILL needs care, and P3 made the trap worse rather than
///    better: `rg WKContentWorld` on this file already returned this comment
///    instead of nothing, and now `rg RenderContentWorld` matches the prose in
///    `makeUIView`'s own block comment too. The invariant is *"every
///    `WKUserScript` here is constructed WITH the isolated content world"* — read
///    the `WKUserScript(` call sites in `makeUIView`, do not count identifier
///    hits. (Same trap as
///    `Companion/Memory/Current/105-a-print-is-not-production-observability-on-ios.md`,
///    where a correction mentioning `freopen`/`dup2` turned a zero-hit grep into
///    a four-hit one.)
///    **What this does to clause 2, stated exactly: 2 is now REDUNDANT, and it
///    stays anyway.** Page-world sharing was precisely what made the
///    non-replaceable install load-bearing — in a separate world the sender cannot
///    see, shadow or replace `__tmImageDiagWillAssign` at all. So the
///    `writable: false, configurable: false` install now defends against nothing
///    reachable. **Do not remove it on that reasoning.** It costs one call at
///    `.atDocumentStart` in debug builds only, and it is the sole surviving
///    mitigation if this world is ever reverted — which is a live possibility, not
///    a hypothetical: four P1b settings in this same file were reversed by owner
///    directive within a day of shipping. Redundant-while-the-world-holds is the
///    correct state for a belt-and-braces guard, not a cleanup opportunity.
///    Clause 3's warning is unchanged and still applies for the same reason: a
///    change that moved only SOME scripts — of worlds OR of frame scope — breaks
///    the pairing, and P3 did not make that safer, it just moved which pairing
///    is at stake. See `RenderContentWorld` for why a partial migration fails
///    silently and totally.
///
/// Relax any of these — `writable: false` in particular — and the sender chooses,
/// or shares, what our render path does, at which point "cannot generate duplicate
/// tracking requests" stops being true of the end state too.
///
/// ⚠️ Item 4 is NOT covered by any test. `EmailRenderPipelineTests`'
/// `imageLoadDiagnostics` bans the amplification primitives as literal substrings
/// of the emitted source; an accessor installed by the SENDER contains none of
/// those substrings in our source, so that test stays green through it. Severity
/// is low for the same reason the Amplification bullet gives — while
/// `allowsContentJavaScript` is `true` the sender can issue the request directly —
/// but it must not survive into the phase where content JS is disabled.
///
/// ⚠️ **That last clause came due, and it is now discharged — by P3, not by a test.**
/// Content JS *was* disabled at P1b (2026-08-12) and item 4 survived it, exactly as
/// the sentence above feared; it stayed reachable in principle because our hook and
/// the sender shared one set of DOM wrappers. P3 (2026-08-13) closes the mechanism:
/// DOM wrapper objects and their expando properties are **per-world**, so an
/// accessor a sender installs on `img.__tmImageDiagId` lives on the page world's
/// wrapper and our hook — reading the same element through
/// `RenderContentWorld.isolated`'s wrapper — never touches it. Item 4 is therefore
/// unreachable for the same structural reason clause 2 is redundant, and it is
/// still NOT covered by a test. **Do not restate it as "fixed"**: it is closed by a
/// configuration property that an owner directive could reverse, which is precisely
/// how four P1b settings in this file were undone within a day.
///
/// **What each log line actually omits.** `safeURL`'s `return` statements do not
/// all guarantee the same thing, and the ones that produce a URL-derived string
/// are described below. **No count is given, deliberately** — this paragraph said
/// "THREE arms, not two" until 2026-08-12, which is a counted absolute in a doc
/// whose own next paragraph tells the reader to *count exits, not branches*, and
/// counting exits gives a different number than counting URL-producing arms
/// because `if (!raw) return '(none)'` is an exit that produces neither. Read the
/// function; the enumeration below is not asserted to be exhaustive of its exits.
/// Measured 2026-08-12 by running this exact function body against a
/// WHATWG-conformant `URL` implementation (node's) over the inputs named below.
/// `path` throughout is `url.pathname`, truncated to 177 characters plus `...`
/// when it exceeds 180:
/// - SUCCESS, host present — `url.protocol + '//' + url.host + url.pathname`.
///   Omits the query, the fragment AND any userinfo: `url.host` is host+port only,
///   credentials are not part of it. `https://user:pw@host/px.gif?x` logs
///   `https://host/px.gif`.
/// - SUCCESS, host EMPTY — `url.protocol + url.pathname`. Taken by every
///   opaque-path scheme (`blob:`, `data:`, `mailto:`), where there is no host and
///   the whole remainder — userinfo included — lives in `pathname`. So it drops
///   the query and the fragment and KEEPS userinfo:
///   `blob:https://user:pw@tracker.example/px.gif` logs itself back unchanged, and
///   the `?q=1` variant logs the same string with only the query gone.
/// - CATCH, taken whenever `new URL()` throws — `String(raw).split(/[?#]/, 1)[0]`
///   truncated to 200 characters. Drops the query and the fragment, KEEPS
///   userinfo. `https://user:pw@ho st/px.gif?x` (space in the host) throws and
///   logs `https://user:pw@ho st/px.gif`.
///
/// So userinfo is PRESERVED on the empty-host success arm and on the catch arm,
/// and DROPPED on the host-present success arm. That is what the three bullets
/// above measure and all this paragraph asserts — **no fraction, no count, and
/// the enumeration is not asserted exhaustive**; if a further exit is added, this
/// sentence is silently wrong and nothing will fail, which is why the security
/// conclusion below does not rest on it. A credential-bearing value needs no
/// sender script to reach those arms: `reportLegacyBackgrounds` passes the raw
/// `[background]` attribute straight to `safeURL`, and `reportInventory` does the
/// same with `imageURL`'s raw `src` / `data-tmsrc` / `data-tmsrcset`.
/// Left as it is on purpose — those are the *sender's* credentials, in a
/// `DebugModeManager`-gated `print` — so this is a description of the behaviour,
/// not a defect report. The security conclusion is unchanged by the correction;
/// only the description was wrong.
///
/// ⚠️ Until 2026-08-12 this paragraph said the success arm "omits … AND any
/// userinfo" and that a credential-bearing `src` reaches the log "only when it is
/// ALSO unparseable". Both false, for the second success arm. The ⚠️ immediately
/// below already warns that a true mechanism can carry an unreachable example —
/// and this is the same failure one level up: the arms were enumerated from the
/// `if (url.host)` branch that was being described rather than from the `return`
/// statements in the function, so the fall-through arm was never counted. Count
/// exits, not branches.
///
/// ⚠️ **A well-formed credential URL does NOT reach the catch arm**, and the
/// example that stood here from the moment this paragraph was written until it
/// was first committed claimed it did: `https://user:pw@host/px.gif?x` is a
/// VALID URL, so `new URL()` does not throw on it, it takes the SUCCESS arm, and
/// it logs `https://host/px.gif` — userinfo dropped, the opposite of what that
/// example asserted. The mechanism above was right and only the illustration was
/// wrong, which is the failure mode worth naming: this paragraph was itself
/// written to retract false absolutes, was labelled "measured, not inferred",
/// and still shipped an input→output pair nobody had run. Reachability is part
/// of the claim — an example that cannot reach the arm it illustrates is not
/// evidence about that arm.
///
/// ⚠️ Not measurable in the JSC harness. `JSContext` has no `URL` constructor, so
/// under `EmailRenderPipelineTests`' JavaScriptCore harness EVERY input takes the
/// catch arm — including the ones that take a success arm in WKWebView. Any future
/// assertion about `safeURL`'s success behaviour written against that harness is
/// vacuous by construction.
///
/// Exposed to unit tests at BOTH gate settings — the disabled form (what ships)
/// must be empty, not merely quiet, so tests can pin the absence of the
/// page-visible hook as well as the presence of the diagnostics.
internal func _imageLoadDiagnosticJS(enabled: Bool) -> String {
    imageLoadDiagnosticJS(enabled: enabled)
}

/// ### Why `window.__tmImageDiagWillAssign` is installed non-replaceable
///
/// It is the one page-visible surface these diagnostics expose, and the
/// PRODUCTION `deferredImageLoadJS` swap calls whatever occupies it. Two
/// distinct hostile substitutions exist and they need different countermeasures:
///
/// - **Denial.** A hook that throws aborts `swap()` before the
///   `removeAttribute`/`setAttribute` pair, so every remaining deferred image on
///   that message stays hidden. Countered on the *caller* side: `swap()` wraps
///   the invocation (see `deferredImageLoadJS`).
/// - **Amplification.** A hook that does NOT throw but constructs an image
///   element and assigns a sender URL to it makes *our* render path issue an
///   extra request, disclosing the user's IP to the sender a second time. A
///   try/catch does nothing against this. Countered here, on the *install* side:
///   the property cannot be replaced or deleted.
///
/// This refutes, as literally stated, commit `71c19d554`'s claim that the script
/// "never re-requests anything… cannot amplify a tracking pixel or turn a
/// diagnostic into a second disclosure of the user's IP to the sender": with the
/// hook writable, the sender chose what our swap called. Calibration: while
/// `defaultWebpagePreferences.allowsContentJavaScript` is `true` (it is, at
/// `AutoSizingHTMLView`'s webview config) the sender can issue that request
/// directly, so this is not a capability they lack today — it is LOW severity.
/// It matters because it must not survive into the phase where content JS is
/// disabled, where it would become a genuine bypass of that hardening.
///
/// **Ours always wins the race, verified rather than assumed:** this script is a
/// `WKUserScript` with `injectionTime: .atDocumentStart`, added second (right
/// after the id stamp) in `makeUIView`, and `.atDocumentStart` runs after the
/// document element is created but before any author content is parsed — so no
/// sender `<script>` can claim the name first. `writable: false` +
/// `configurable: false` then make a later assignment a no-op (a `TypeError`
/// inside the sender's own strict-mode code, aborting theirs and not ours) and
/// make `delete` fail.
///
/// **The rationale lives here and not in the injected JS on purpose.**
/// `EmailRenderPipelineTests.imageLoadDiagnostics` bans the amplification
/// primitives as literal substrings of the emitted source, which is a crude ban
/// that cannot tell code from a comment — spelling them out in a JS comment
/// fails that test, as it did when this fix was first written. Swift comments
/// are not part of the emitted string.
private func imageLoadDiagnosticJS(enabled: Bool) -> String {
    guard enabled else { return "" }
    return """
    (function() {
        if (window.__tmImageDiagInstalled) return;
        window.__tmImageDiagInstalled = true;
        var startedAt = performance.now();
        var nextImageId = 1;

        // Every logged field is sender-influenced (URLs, filenames, tag names,
        // CSP directives), and the log is a LINE-oriented channel: one
        // postMessage becomes exactly one `print`. A raw CR/LF anywhere in the
        // message therefore forges a second, entirely plausible diagnostic line.
        // Sanitizing here rather than at the one field found doing it means no
        // future field can reopen it — this is the choke point every emission
        // passes through. Escaped rather than stripped so the line still shows
        // what the sender actually sent. U+2028/U+2029 are included because they
        // are line terminators to some consumers of this text.
        function sanitize(text) {
            return String(text).replace(
                /[\\u0000-\\u001F\\u007F-\\u009F\\u2028\\u2029]/g,
                function (character) {
                    return '\\\\u' + ('000' + character.charCodeAt(0).toString(16)).slice(-4);
                }
            );
        }

        function log(message) {
            try {
                var id = window.__tmDiagId || '?';
                var elapsed = Math.round(performance.now() - startedAt);
                window.webkit.messageHandlers.consoleLog.postMessage(
                    sanitize('[ImageLoadDiag id=' + id + ' +' + elapsed + 'ms] ' + message)
                );
            } catch (_) {}
        }

        function absoluteURL(raw) {
            if (!raw) return '';
            try { return new URL(String(raw), document.baseURI).href; }
            catch (_) { return String(raw); }
        }

        function safeURL(raw) {
            if (!raw) return '(none)';
            try {
                var url = new URL(String(raw), document.baseURI);
                var path = url.pathname || '';
                if (path.length > 180) path = path.substring(0, 177) + '...';
                if (url.host) return url.protocol + '//' + url.host + path;
                return url.protocol + path;
            } catch (_) {
                return String(raw).split(/[?#]/, 1)[0].substring(0, 200);
            }
        }

        function imageId(image) {
            if (!image.__tmImageDiagId) image.__tmImageDiagId = nextImageId++;
            return image.__tmImageDiagId;
        }

        function imageURL(image) {
            return image.currentSrc || image.getAttribute('src')
                || image.getAttribute('data-tmsrc') || image.getAttribute('data-tmsrcset') || '';
        }

        function resourceTiming(raw) {
            if (!raw || !window.performance || !performance.getEntriesByName) return 'unavailable';
            var entries;
            try { entries = performance.getEntriesByName(absoluteURL(raw)); }
            catch (_) { return 'lookup-error'; }
            if (!entries || entries.length === 0) return 'none';
            var entry = entries[entries.length - 1];
            var status = (typeof entry.responseStatus === 'number') ? entry.responseStatus : 'na';
            var transfer = (typeof entry.transferSize === 'number') ? entry.transferSize : 'na';
            var encoded = (typeof entry.encodedBodySize === 'number') ? entry.encodedBodySize : 'na';
            var protocol = entry.nextHopProtocol || 'na';
            return 'present status=' + status + ' duration=' + Math.round(entry.duration || 0)
                + 'ms transfer=' + transfer + ' encoded=' + encoded + ' protocol=' + protocol;
        }

        function reportImageEvent(kind, image) {
            setTimeout(function() {
                var raw = imageURL(image);
                log('image=' + imageId(image) + ' event=' + kind
                    + ' url=' + safeURL(raw)
                    + ' complete=' + image.complete
                    + ' natural=' + image.naturalWidth + 'x' + image.naturalHeight
                    + ' rendered=' + image.offsetWidth + 'x' + image.offsetHeight
                    + ' connected=' + image.isConnected
                    + ' resourceTiming=' + resourceTiming(raw));
            }, 50);
        }

        // Capture resource outcomes even for parser-created images. `load` and
        // `error` do not bubble, so capture=true is required.
        document.addEventListener('load', function(event) {
            if (event.target && event.target.tagName === 'IMG') reportImageEvent('load', event.target);
        }, true);
        document.addEventListener('error', function(event) {
            if (event.target && event.target.tagName === 'IMG') reportImageEvent('error', event.target);
        }, true);

        document.addEventListener('securitypolicyviolation', function(event) {
            log('csp-violation directive=' + (event.effectiveDirective || event.violatedDirective || 'unknown')
                + ' blocked=' + safeURL(event.blockedURI)
                + ' disposition=' + (event.disposition || 'unknown'));
        });

        function reportInventory() {
            var images = document.getElementsByTagName('img');
            log('inventory images=' + images.length);
            for (var i = 0; i < images.length; i++) {
                var image = images[i];
                var deferred = image.hasAttribute('data-tmsrc') || image.hasAttribute('data-tmsrcset');
                var state = deferred ? 'deferred'
                    : (!image.complete ? 'pending' : (image.naturalWidth > 0 ? 'loaded' : 'broken'));
                log('image=' + imageId(image) + ' state=' + state
                    + ' url=' + safeURL(imageURL(image))
                    + ' complete=' + image.complete
                    + ' natural=' + image.naturalWidth + 'x' + image.naturalHeight);
            }
        }

        function reportLegacyBackgrounds(phase) {
            var nodes = document.querySelectorAll('[background]');
            log('legacy-backgrounds phase=' + phase + ' count=' + nodes.length);
            for (var i = 0; i < nodes.length; i++) {
                var raw = nodes[i].getAttribute('background') || '';
                log('legacy-background=' + (i + 1) + ' phase=' + phase
                    + ' element=' + nodes[i].tagName
                    + ' url=' + safeURL(raw)
                    + ' resourceTiming=' + resourceTiming(raw));
            }
        }

        // Called synchronously by deferredImageLoadJS immediately before the
        // real src/srcset is assigned. Installed NON-REPLACEABLE — see the
        // Swift doc comment on imageLoadDiagnosticJS for why, and why the
        // rationale is written there rather than here.
        Object.defineProperty(window, '__tmImageDiagWillAssign', {
            value: function(image, attribute, raw, trigger) {
                log('image=' + imageId(image) + ' event=assign-' + attribute
                    + ' trigger=' + trigger + ' url=' + safeURL(raw)
                    + ' complete-before=' + image.complete
                    + ' natural-before=' + image.naturalWidth + 'x' + image.naturalHeight);
            },
            writable: false,
            configurable: false,
            enumerable: false
        });

        document.addEventListener('DOMContentLoaded', function() {
            reportInventory();
            reportLegacyBackgrounds('dom-content-loaded');
        }, { once: true });
        window.addEventListener('load', function() {
            setTimeout(function() { reportLegacyBackgrounds('window-load'); }, 50);
        }, { once: true });
        setTimeout(function() { reportLegacyBackgrounds('t2000'); }, 2000);
    })();
    """
}

/// Crop a WHOLESALE per-region content indent — the case `eatGutterMarginsJS`
/// (below) and the negative-body-margin approach it replaced (2026-06-30) can
/// never fix, because both are bounded by the SMALLEST inset anywhere in the
/// email. An Outlook/OWA compose styles EVERY main-content block with the OWA
/// idiom `margin: 0px 0px 16px 40px` (margin-left:40px) — on a 288pt phone
/// that's 14% of the width, stacked on our own 16pt gutter → ~56pt left vs
/// 16pt right. The same email also carries a full-width mailing-list footer
/// at inset 0, so `eatGutterMarginsJS`'s min-inset measurement is (correctly)
/// 0 and it does nothing (`logmain.log` 2026-07-07: `emailInset L=0 R=0`
/// while every content block carried `margin: 0px 0px 16px 40px`). A GLOBAL
/// fix is structurally incapable here — it has to see the footer as the
/// floor. Fixing this needs to work PER-REGION instead.
///
/// Algorithm: find "indent carriers" — elements whose margin-left clears
/// `INDENT_MIN` (24px: comfortably past the 16pt SwiftUI gutter, and Gmail's
/// ~0.8ex / 4px quote indent must never trigger this) AND is ASYMMETRIC vs
/// margin-right (`margin:auto`-centered tables/sections have EQUAL used
/// margins and must not read as an indent). Keep only the OUTERMOST carriers
/// (a carrier nested inside another selected carrier is left untouched — its
/// delta relative to the outer one is exactly what step further down
/// preserves) whose subtree actually contains a wide (≥60% of body width,
/// same main-column test as `eatGutterMarginsJS`) text leaf — an indented
/// icon/spacer with no real column text isn't worth normalizing.
///
/// DOMINANCE GUARD — the safety net that makes this safe to run unconditionally:
/// count every wide text leaf in the body and how many sit inside selected
/// carriers. Only crop when that share is ≥60% (`DOMINANCE`). An email with
/// ONE intentionally indented aside among normal paragraphs is a deliberate,
/// meaningful indent — it keeps its aside. Only emails whose main column is
/// WHOLESALE indented (compose-tool chrome, not information) get cropped.
///
/// Exclusions: UL/OL/LI (list geometry is `constrainLeftOverflowJS`'s job, not
/// ours), BLOCKQUOTE (real quote semantics, owned by the quote-collapse
/// pass), and any element — or the whole body — computed RTL (this pass is
/// LTR-only scope; an RTL body skips the entire run).
///
/// Crop is a SHIFT, not a flatten: `reduction` = the tightest bounding inset
/// (the MIN margin-left) across selected carriers. Subtracting it from every
/// selected carrier preserves RELATIVE deltas: a uniform 40px OWA email
/// collapses every carrier to 0 (the SwiftUI 16pt gutter remains the total
/// indent, same as any un-indented email); a mixed 40px/80px email becomes
/// 0px/40px. Only `margin-left` is touched — the idiom's own
/// `margin-bottom:16px` etc. survive untouched. Each cropped element is
/// marked `data-tm-indentcrop` for debuggability.
///
/// Runs once per document load (WKUserScript, `.atDocumentEnd`) — appearance-
/// flip re-renders reload the document fresh (see the light↔dark reload note
/// above), so unlike `fitViewportJS`'s width arm this needs no idempotency
/// guard of its own. Injected BETWEEN `leftFix` and `eatMargins` (both in the
/// WKUserScript construction block and the `addUserScript` sequence) so
/// `eatGutterMarginsJS` and `fitViewportJS` measure the POST-crop layout.
/// Exposed for unit tests via `_normalizeIndentJS`.
internal var _normalizeIndentJS: String { normalizeIndentJS }
private var normalizeIndentJS: String {
    let il = DebugModeManager.isLoggingEnabled()
        ? "function il(s){try{window.webkit.messageHandlers.consoleLog.postMessage('[IndentCrop] '+s);}catch(_){}}"
        : "function il(s){}"
    return """
    (function() {
        \(il)
        if (!document.body) return;
        try {
            var b = document.body.getBoundingClientRect();
            var bodyWidth = b.width;
            if (bodyWidth <= 0) return;

            // An indent must exceed the app's 16pt gutter noticeably before it's
            // worth normalizing — Gmail's ~0.8ex (~4px) quote indent must never
            // trigger this; that's real quote structure the quote-collapse pass
            // (and eatGutterMarginsJS) already own.
            var INDENT_MIN = 24;
            // Same main-column test as eatGutterMarginsJS: a "wide" text leaf is
            // part of the primary reading column, not a narrow aside/badge/caption.
            var WIDE_FRAC = 0.6;
            // Dominance guard threshold — see the step below. An email whose main
            // column is only PARTIALLY indented (a deliberate aside) must be left
            // alone; only a WHOLESALE-indented column (compose-tool chrome) qualifies.
            var DOMINANCE = 0.6;

            var bodyDir = window.getComputedStyle(document.body).direction;
            if (bodyDir === 'rtl') { il('body is rtl — LTR-only scope, skipping run'); return; }

            var WIDE = bodyWidth * WIDE_FRAC;

            // Direct non-whitespace text child, &nbsp;-normalized — same idiom as
            // eatGutterMarginsJS's wide-text-leaf loop.
            function hasDirectText(el) {
                for (var n = el.firstChild; n; n = n.nextSibling) {
                    if (n.nodeType === 3 && n.textContent.replace(/\\u00a0/g, ' ').trim().length) return true;
                }
                return false;
            }

            var all = document.body.getElementsByTagName('*');

            // Step 1: find indent carriers — margin-left clears INDENT_MIN AND is
            // asymmetric vs margin-right (excludes margin:auto centered content).
            var carriers = [];
            for (var i = 0; i < all.length; i++) {
                var el = all[i];
                var tag = el.tagName;
                if (tag === 'UL' || tag === 'OL' || tag === 'LI' || tag === 'BLOCKQUOTE') continue;
                var cs = window.getComputedStyle(el);
                if (cs.direction === 'rtl') continue;
                var ml = parseFloat(cs.marginLeft) || 0;
                var mr = parseFloat(cs.marginRight) || 0;
                if (ml >= INDENT_MIN && (ml - mr) >= INDENT_MIN) {
                    el.__tmICCandidate = true;
                    carriers.push(el);
                }
            }
            if (!carriers.length) { il('no indent carriers found'); return; }

            // Step 2: keep only OUTERMOST carriers — skip any carrier that has a
            // selected ancestor (its own delta relative to the outer one is what
            // the crop step preserves by leaving it alone).
            var outer = [];
            for (var j = 0; j < carriers.length; j++) {
                var c = carriers[j];
                var nested = false;
                for (var p = c.parentElement; p; p = p.parentElement) {
                    if (p.__tmICCandidate) { nested = true; break; }
                }
                if (!nested) { c.__tmICOuter = true; outer.push(c); }
            }

            // Step 3: a carrier only qualifies if its subtree (self included) holds
            // at least one wide text leaf. Walking every wide leaf up to its nearest
            // OUTER-carrier ancestor also gives the dominance-guard counts for free:
            // totalWide = every wide leaf in the body; carrierWide = how many sit
            // inside a selected (outer + non-empty) carrier.
            var totalWide = 0, carrierWide = 0;
            for (var m = 0; m < all.length; m++) {
                var leaf = all[m];
                var r = leaf.getBoundingClientRect();
                if (r.width < WIDE || r.height <= 0) continue;
                if (!hasDirectText(leaf)) continue;
                totalWide++;
                for (var node = leaf; node && node !== document.body; node = node.parentElement) {
                    if (node.__tmICOuter) { node.__tmICHasWide = true; carrierWide++; break; }
                }
            }
            var selected = [];
            for (var k = 0; k < outer.length; k++) {
                if (outer[k].__tmICHasWide) selected.push(outer[k]);
            }
            if (!selected.length) { il('no carrier subtree has a wide text leaf — nothing to crop'); return; }

            // Step 4: DOMINANCE GUARD. Only crop when selected carriers hold most
            // of the body's wide-column text — an email with one intentionally
            // indented aside among normal paragraphs keeps its aside untouched.
            var share = carrierWide / totalWide;
            if (share < DOMINANCE) {
                il('carrier share ' + share.toFixed(2) + ' < DOMINANCE ' + DOMINANCE + ' — leaving indentation alone');
                return;
            }

            // Step 5: crop = SHIFT, not flatten. reduction is the tightest bounding
            // inset (MIN margin-left) across selected carriers; subtracting it from
            // every carrier preserves RELATIVE deltas (a 40/80 mix becomes 0/40)
            // while a uniform indent (the OWA case) collapses to 0 — the SwiftUI
            // 16pt gutter remains the total indent, same as any un-indented email.
            // Only margin-left is touched, so the idiom's own margin-bottom etc.
            // survive.
            var reduction = Infinity;
            for (var s = 0; s < selected.length; s++) {
                var msL = parseFloat(window.getComputedStyle(selected[s]).marginLeft) || 0;
                if (msL < reduction) reduction = msL;
            }
            for (var t = 0; t < selected.length; t++) {
                var elT = selected[t];
                var mlT = parseFloat(window.getComputedStyle(elT).marginLeft) || 0;
                var newMl = mlT - reduction;
                elT.style.setProperty('margin-left', newMl + 'px', 'important');
                elT.setAttribute('data-tm-indentcrop', '1');
                il('crop ' + elT.tagName + '.' + (elT.className || '').toString().slice(0, 20) + ' ' + mlT + 'px → ' + newMl + 'px');
            }
            il('summary: carriers=' + carriers.length + ' outer=' + outer.length + ' selected=' + selected.length
                + ' reduction=' + reduction + ' share=' + share.toFixed(2));
        } catch (e) { il('error: ' + (e && e.message ? e.message : e)); }
    })();
    """
}

/// App-owned disclosure chrome appended directly under `<body>` does not inherit
/// the sender's content container inset. Align only the exact app-created nodes
/// retained by `collapseICSJS`; a class selector would let sender HTML spoof
/// ownership. The combined positive inset is bounded so the aligned control keeps
/// at least the same 60%-wide floor as the measured main column. Kept standalone
/// so ownership and bounds are executable in JSContext.
internal let _alignBodyLevelDisclosureJS = """
function alignBodyLevelDisclosure(wrappers, leftInset, rightInset, maxCombinedInset) {
    var limit = isFinite(maxCombinedInset) ? Math.max(0, maxCombinedInset) : 0;
    var left = isFinite(leftInset) ? Math.max(0, Math.min(leftInset, limit)) : 0;
    var right = isFinite(rightInset) ? Math.max(0, Math.min(rightInset, limit)) : 0;
    var total = left + right;
    if (total > limit && total > 0) {
        var scale = limit / total;
        left *= scale;
        right *= scale;
    }
    for (var i = 0; i < wrappers.length; i++) {
        wrappers[i].style.setProperty('margin-left', left + 'px', 'important');
        wrappers[i].style.setProperty('margin-right', right + 'px', 'important');
    }
}
"""

/// Make the SwiftUI gutter act as a MINIMUM "indent" that ABSORBS an email's own
/// outer horizontal inset, instead of the two STACKING (our 16pt + the email's own
/// 8px cell padding ≈ 24pt, which reads as over-inset now that we no longer shrink
/// emails).
///
/// Mechanism (NO content fiddling, so it cannot clip or perturb the email layout):
/// this script only MEASURES the email's own content inset and posts it to Swift,
/// which then REDUCES the SwiftUI horizontal padding to `max(0, 16 − emailInset)`.
/// Total inset = padding + emailInset = `max(16, emailInset)`:
///   • email with no inset (full-bleed)  → pad 16 → total 16  (unchanged)
///   • email with 8px inset (Scholar)    → pad 8  → total 16  (absorbed)
///   • email indented more than 16        → pad 0  → total = its own inset
/// The 16 constant is never lowered — it stays the floor for every email — so this
/// CANNOT harm other emails: the clamp to `[0, 16]` means we only ever REMOVE our
/// own double-count, never add indent or pull content.
///
/// Inset = the MIN inset among WIDE text leaves (width ≥ 60% of body): the main
/// content column. Narrow elements (an injected "[CAUTION]" banner, a centered
/// date) and structural full-width wrappers (no direct text) are excluded, so a
/// single low-inset outlier can't defeat it (the failure mode of the earlier
/// body-pull approach). The reduction is SYMMETRIC (both sides reduced by the
/// smaller of the two sides' insets) so the gutter is never lopsided — content
/// can't go flush on one side while padded on the other. A negative inset
/// (content overflowing the body, i.e. a desktop email that fitViewportJS will
/// widen) clamps to 0 → no reduction. Exposed for unit tests via `_eatGutterMarginsJS`.
internal var _eatGutterMarginsJS: String { eatGutterMarginsJS }
private var eatGutterMarginsJS: String {
    let gl = DebugModeManager.isLoggingEnabled()
        ? "function gl(s){try{window.webkit.messageHandlers.consoleLog.postMessage('[EatGutter] '+s);}catch(_){}}"
        : "function gl(s){}"
    return """
    (function() {
        \(gl)
        \(_alignBodyLevelDisclosureJS)
        if (!document.body) return;
        try {
            // MUST match AutoSizingHTMLView's default .padding gutter. We only ever
            // REDUCE the SwiftUI padding by the email's own inset (down to 0), never
            // below — so the gutter stays the minimum indent.
            var GUTTER = 16;
            var b = document.body.getBoundingClientRect();
            var bw = b.width;
            if (bw <= 0) return;
            var WIDE = bw * 0.6; // main-column width; excludes banners / centered chips
            var minLeft = Infinity, minRight = Infinity, cp = null;
            var els = document.body.getElementsByTagName('*');
            for (var i = 0; i < els.length; i++) {
                var el = els[i];
                // Direct-text leaf only: structural full-width wrappers (no direct
                // text) are skipped so they can't peg the inset to 0.
                var hasText = false;
                for (var n = el.firstChild; n; n = n.nextSibling) {
                    if (n.nodeType === 3 && n.textContent.replace(/\\u00a0/g, ' ').trim().length) { hasText = true; break; }
                }
                if (!hasText) continue;
                var r = el.getBoundingClientRect();
                if (r.width < WIDE || r.height <= 0) continue; // main column only
                var li = r.left - b.left;   if (li < minLeft) { minLeft = li; cp = el; }
                var ri = b.right - r.right; if (ri < minRight) minRight = ri;
            }
            if (!isFinite(minLeft) || !isFinite(minRight)) { gl('no wide text content — keep 16'); return; }
            // The invite card is app-owned and appended at body level, so it does
            // not inherit the sender's content-column inset the way an in-body
            // quote wrapper does. Apply the measured per-side inset only to that
            // exact app-created wrappers before the height/fit pipeline measures
            // layout. `bw - WIDE` preserves the same 60%-wide column floor even
            // when hostile/off-body geometry reports an extreme positive inset.
            alignBodyLevelDisclosure(
                window.__tmICSDisclosureWrappers || [],
                minLeft,
                minRight,
                bw - WIDE
            );
            // SYMMETRIC reduction: reduce BOTH sides by the SMALLER inset, clamped
            // [0, GUTTER]. Using the min keeps the gutter symmetric so content can
            // never end up flush on one side while padded on the other — the
            // regression on a desktop email whose content overflowed the LEFT
            // (minLeft=-8) but sat 16px from the RIGHT: per-side ate right→0 while
            // left stayed 16, so content hugged the right edge. A negative
            // (overflow) inset → 0 → no reduction (overflowing/desktop emails are
            // handled by fitViewportJS's widen, not by the gutter).
            var x = Math.max(0, Math.min(minLeft, minRight, GUTTER));
            var pad = GUTTER - x;
            gl('emailInset L=' + Math.round(minLeft) + ' R=' + Math.round(minRight)
                + ' → SwiftUI pad ' + pad + ' (both, ' + (cp ? cp.tagName + '.' + (cp.className || '') : '?') + ')');
            window.webkit.messageHandlers.gutterAdjust.postMessage({ l: pad, r: pad });
        } catch (e) { gl('error: ' + (e && e.message ? e.message : e)); }
    })();
    """
}

internal var _monitorHeightJS: String { monitorHeightJS }
private let monitorHeightJS = """
    (function() {
        var lastH = 0;
        // Defense-in-depth scroll pin. The webview is sized to content height
        // and the parent SwiftUI ScrollView owns scrolling, so <body> must
        // never hold a vertical scroll offset. overflow-x:clip on html/body
        // (EmailHTMLWrapper) already prevents them from being scroll
        // containers; this resets body.scrollTop in case a late image-swap
        // reflow lands a stray offset on a WebKit build where `clip` is flaky.
        // ONLY body.scrollTop — NEVER documentElement / scrollingElement,
        // which on iOS WKWebView mirror the native UIScrollView (zoom-pan);
        // touching those would yank a pinch-zoomed user back to the top.
        // <!DOCTYPE html> standards mode makes documentElement the viewport
        // scroller, so body.scrollTop is always a safe inner-scroll reset.
        function pinBodyScroll() {
            try { if (document.body && document.body.scrollTop !== 0) document.body.scrollTop = 0; } catch(_) {}
        }
        function report() {
            // Gate the FIRST height post on fit() completing. Before fit()
            // decides whether to widen, body is laid out at the un-widened
            // device width; posting that height applies a too-tall frame that
            // then snaps smaller the instant fit() widens — a visible flicker
            // (frame 1→881→466 for the Apple survey). fitViewportJS sets
            // __tmFitDone on EVERY exit (widen or not) and then calls this, so
            // the first applied height is already the final one. The fallback
            // timer below force-opens the gate if fit() never runs (e.g. webView
            // bounds<50 at load) so the frame can't stay stuck at its seed.
            if (!window.__tmFitDone) {
                // Body is laid out (width known) but fit() hasn't run yet. fit()
                // is normally driven by didFinish, which waits on external
                // images/subresources — far too late for a big newsletter whose
                // body lays out in ~100ms but whose images push didFinish to
                // ~500ms+, leaving the frame stuck at 1px (invisible) the whole
                // time. Ask Swift to fit NOW, on this first real layout, so the
                // frame is sized + revealed as soon as the width is known. fit()
                // then re-posts the final height through this same function
                // (with __tmFitDone set). Once only — guarded by __tmFitRequested.
                if (document.body.scrollHeight > 1 && !window.__tmFitRequested) {
                    window.__tmFitRequested = true;
                    try { window.webkit.messageHandlers.heightChanged.postMessage({ requestFit: true }); } catch(e) {}
                }
                return;
            }
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
                    window.webkit.messageHandlers.heightChanged.postMessage({
                        h: h,
                        vp: vp,
                        scroll: scroll,
                        rect: rect,
                        userDisclosure: \(_consumeUserDisclosureExpression)
                    });
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
                img.addEventListener('load', function() { setTimeout(function(){ pinBodyScroll(); report(); }, 50); }, { once: true });
                img.addEventListener('error', function() { setTimeout(function(){ pinBodyScroll(); report(); }, 50); }, { once: true });
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
        // (These are no-ops until fit() opens the __tmFitDone gate; the
        // post-fit re-fires below + fit()'s own report() call apply the height.)
        report();
        setTimeout(report, 100);
        setTimeout(report, 500);
        // Liveness fallback: if fit() never runs (webView too small at load,
        // never laid out, etc.), open the gate after a grace period so the
        // frame still gets a height instead of staying at its seed. One-shot,
        // NOT a polling interval.
        setTimeout(function() {
            if (!window.__tmFitDone) { window.__tmFitDone = true; report(); }
            // Failsafe reveal: EmailHTMLWrapper starts the document at opacity:0
            // and fitViewportJS.reveal() normally un-hides it. If fit() never ran
            // (webView never laid out, etc.), un-hide here so content can never
            // be stranded invisible. Idempotent with reveal().
            try { document.documentElement.style.setProperty('opacity', '1', 'important'); } catch(_){}
        }, 700);
    })();
    """

/// Shared, pure gated aspect-ratio correction — evaluated by BOTH the
/// production `fixImageAspectRatioJS` script and the unit tests (zero-drift,
/// same pattern as `walkUpToWrapStartJS`). Reads naturalWidth/naturalHeight +
/// getBoundingClientRect, writes ONLY `height`. Returns true iff it corrected.
///
/// WHY: some senders pin a fixed `height` on a full-width image without a
/// matching `width`, so when our `img{max-width:100%}` caps the width on a
/// phone the height stays fixed and the image stretches vertically. The CSS
/// `img[width]{height:auto}` rule only covers images that carry a `width`
/// attribute; this catches the rest (height-only / inline-styled).
///
/// SAFETY (see `fitViewportJS`, which widens the layout viewport on horizontal
/// overflow): we ONLY ever set `height` — never width — so the document's
/// horizontal extent is unchanged and the widen decision cannot be perturbed.
/// And we ONLY act when the RENDERED ratio diverges from the image's NATURAL
/// ratio, so a logo sized by `height="29"` (rendered at its true ratio, just
/// small) is left untouched and can't balloon to full container width — the
/// exact regression the scoped CSS rule guards against. WebKit's
/// naturalWidth/naturalHeight are EXIF-orientation corrected, so rotated
/// photos compare correctly.
let fixImgAspectFnJS = """
function tmFixImgAspect(img, log) {
    // `log` is an optional debug callback (no-op in production / unit tests),
    // same pattern as walkUpToWrapStart's logFn. It records the decision at
    // every branch so we can see WHY a given image was or wasn't corrected.
    if (!log) log = function() {};
    // >2% off the natural ratio == visibly distorted. The margin absorbs
    // sub-pixel getBoundingClientRect rounding (a proportionally-scaled image
    // diverges well under 1%); genuine distortion is 10%+.
    var TOL = 0.02;
    if (!img) return false;
    var src = (img.currentSrc || img.src || img.getAttribute('data-tmsrc') || '').slice(-48);
    if (img.__tmAspectFixed) { log('skip(already-fixed) ' + src); return false; }
    var nw = img.naturalWidth, nh = img.naturalHeight;
    if (!nw || !nh) { log('skip(unloaded nat=' + nw + 'x' + nh + ') ' + src); return false; }  // not loaded / broken / SVG w/o intrinsic size
    var r = img.getBoundingClientRect();
    if (!r || r.width < 1 || r.height < 1) { log('skip(no-box) ' + src); return false; }  // not laid out / hidden
    var natRatio = nw / nh;
    var renderRatio = r.width / r.height;
    var div = Math.abs(renderRatio - natRatio) / natRatio;
    var info = 'nat=' + nw + 'x' + nh + '(' + natRatio.toFixed(3) + ') render=' + Math.round(r.width) + 'x' + Math.round(r.height) + '(' + renderRatio.toFixed(3) + ') div=' + (div * 100).toFixed(1) + '% attrW=' + (img.getAttribute('width') || '-') + ' attrH=' + (img.getAttribute('height') || '-') + ' ' + src;
    if (div <= TOL) { log('skip(proportional) ' + info); return false; }  // proportional — leave alone
    img.style.setProperty('height', 'auto', 'important');
    img.__tmAspectFixed = true;
    log('FIX height:auto ' + info);
    return true;
}
"""

/// Gated post-load image aspect-ratio correction (injected at documentEnd).
/// Wires the shared `tmFixImgAspect` to every image's load event — covering
/// BOTH inline `tabmail-asset://` images (loaded at first paint) AND remote
/// images whose `src` is swapped in later by `deferredImageLoadJS` (those are
/// `complete` with no src at documentEnd, so monitorHeightJS's image listeners
/// skip them; this attaches its own non-`once` listeners + re-scans after the
/// swap). Exposed for unit tests via `_fixImageAspectRatioJS`.
internal var _fixImageAspectRatioJS: String { fixImageAspectRatioJS }
private var fixImageAspectRatioJS: String {
    // Debug-gated log helper (same shape as fitViewportJS): a no-op function in
    // production so the diagnostic is fully stripped, per CLAUDE.md rule 12.
    // Lands on the `consoleLog` handler, which `print()`s only when logging is
    // enabled. Tag `[ImgAspect]` so it's greppable alongside `[FitViewport]`.
    let logFn = DebugModeManager.isLoggingEnabled()
        ? "function log(s) { try { window.webkit.messageHandlers.consoleLog.postMessage('[ImgAspect] ' + s); } catch(_){} }"
        : "function log(s) {}"
    return """
    (function() {
        \(logFn)
        \(fixImgAspectFnJS)
        function fixAndReport(img) {
            if (tmFixImgAspect(img, log)) {
                // Height changed to the true ratio — nudge the height monitor so
                // the webview frame resizes. Deduped by monitorHeightJS's lastH
                // guard; one-shot per image (flag), and once corrected the ratio
                // matches so it cannot re-fire.
                try { if (window.__tmReportHeight) window.__tmReportHeight(); } catch(_) {}
            }
        }
        window.__tmFixImgAspect = fixAndReport;
        function scan() {
            var imgs = document.getElementsByTagName('img');
            log('scan ' + imgs.length + ' img(s) rs=' + document.readyState);
            for (var i = 0; i < imgs.length; i++) {
                var img = imgs[i];
                if (!img.__tmAspectListener) {
                    img.__tmAspectListener = true;
                    // NOT {once}: a deferred remote img fires `load` only when its
                    // swapped-in src finishes; fixAndReport is flag-guarded so any
                    // extra fire is a no-op.
                    img.addEventListener('load', function() { fixAndReport(this); });
                }
                fixAndReport(img); // correct now if already loaded (inline/cached)
            }
        }
        scan();
        // Re-scan after the deferred-image swap (deferredImageLoadJS swaps on a
        // double-rAF after load, 1500ms failsafe). The per-img load listener
        // already covers swapped images; the re-scans also pick up imgs added to
        // the DOM after first paint by author scripts.
        if (document.readyState === 'complete') { requestAnimationFrame(scan); }
        else { window.addEventListener('load', function() { setTimeout(scan, 50); }, { once: true }); }
        setTimeout(scan, 1600);
    })();
    """
}

/// Post-image-load width recheck (injected at documentEnd, after monitorHeightJS).
///
/// `fitViewportJS` measures horizontal overflow with the DEFERRED remote images
/// hidden (`measureMaxRight`'s phantom-overflow fix), so an email whose true
/// width is IMAGE-DRIVEN under-widens: the FleetOptics delivery template's
/// centered 515px table measured only 307px at vw=288 with its 12 remote images
/// hidden, fit converged at 400 — then the images loaded, the table re-expanded
/// to 515px, and the extra ~115px stayed clipped behind html{overflow-x:clip}
/// forever, because the idempotency guard (window.__tmLayoutVp) blocks any
/// fit re-entry (logmain.log 2026-07-04). Height had re-report paths for
/// exactly this post-load staleness (postWiden timers, img load listeners);
/// width had none.
///
/// This closes that gap EVENT-DRIVEN: arm load/error listeners on every image
/// that is not yet displayable at documentEnd (deferred data-tmsrc/data-tmsrcset,
/// or !complete in-flight — the same keying as measureMaxRight's hide). When the
/// LAST such image settles, re-measure the true rightmost edge; if it overflows
/// the committed layout viewport by more than fitViewportJS's OVERFLOW_SLOP,
/// post ONE {requestWidthRefit:true}. Swift re-runs the fit through the
/// SANCTIONED reset path (viewportResetJS + fitViewportJS in a single JS turn —
/// ADR-IOS-039's rotation/resize path), where the now-loaded images measure at
/// their real size. One-shot (__tmWidthRefitRequested) so a pathological
/// document can never loop reset/fit. Images all loaded BEFORE fit() ran need
/// nothing — fit measured them un-hidden already. Images that never fire
/// load/error keep today's behavior (no refit).
///
/// ── P4: the generic image-failure DIAGNOSTIC rides on the SAME arming loop ──
///
/// `reportImageFailures()` records which images ended in `error` rather than
/// `load`, waits until the armed set settles, and posts one bounded census on the
/// dedicated `imageLoadFailure` channel. As of the 2026-08-13 owner decision,
/// this census is diagnostic-only and cannot raise user-visible UI: a bare JS
/// image `error` does not distinguish a 404/expired URL from a TLS failure. The
/// app therefore shows no image-failure notice.
///
/// ⚠️ **This is OBSERVATIONAL and must stay so.** Nothing here retries, probes,
/// re-requests or HEAD-checks a failed URL, and nothing changes which images load
/// or when. Re-requesting a failed URL would manufacture exactly the tracking hit
/// the deferred-load design exists to bound. It is also NOT the block-with-banner
/// design that was implemented, smoke-tested and REVERTED on 2026-06-17
/// (Memory/037 bullet 30): that one BLOCKED remote images and then explained
/// itself, and broke every message whose layout depends on images loading. This
/// census runs strictly AFTER the fact and changes no load behaviour at all.
///
/// **Why it is a second reader inside this function rather than a new script.**
/// `check()` is UNCHANGED and the failure report is scheduled AFTER it in both
/// listeners, so the width pipeline is armed first and cannot be perturbed by a
/// throw in the new code. The report has its OWN one-shot
/// (`window.__tmImageFailureReported`) and deliberately does NOT inherit
/// `check()`'s guards: it needs neither `__tmFitDone` (a failure is not a layout
/// fact) nor `!__tmWidthRefitRequested` (a message that both loses images AND
/// needs a re-fit must still report).
///
/// **Only images WE deferred are counted.** `EmailHTMLWrapper.wrapHTML` rewrites
/// remote `http(s)` `src`/`srcset` — and only those — to
/// `data-tmsrc`/`data-tmsrcset`, so that attribute IS the "remote" predicate. It
/// is captured per-image at ARM time, because `deferredImageLoadJS`'s `swap()`
/// removes the attribute before it assigns `src`, so by the time an `error` fires
/// the image no longer carries it. A purely local image with no deferral attribute
/// therefore drives the settle (it is armed on `!complete`) but never inflates the
/// count. A mixed live `cid:` src plus deferred remote `srcset` is remote at arm
/// time and uses the accepted first-terminal rule: a cid error that wins that race
/// can count. IOS-UI-004 records the trade-off; do not restate the pure-local claim
/// as applying to that mixed shape.
///
/// **No cause diagnosis, stated so nobody reconnects this to UI.** `onerror` fires for
/// far more than an ATS/TLS refusal: 404s, DNS failures, malformed image bytes,
/// authenticated or expired URLs, and a plain offline device all land here
/// identically, and WebKit hands the page no distinguishing reason. This census
/// may describe only observed errors in diagnostics; it must not make a product claim.
///
/// **Accepted gap: the CENSUS settle point is unreachable for a withheld armed
/// image that receives no other terminal event.**
/// T8's `hiddenByViewMode` (`deferredImageLoadJS`) deliberately leaves
/// `data-tmsrc`/`data-tmsrcset` in place on images inside a hidden `.eml` section.
/// Such an image IS armed — the arm loop skips only images that are `complete` AND
/// carry no deferral attribute. For the ordinary remote-only withheld shape it fires
/// neither `load` nor `error`, so its terminal mark stays null and the census arm's
/// `armedPending()` never reaches 0. This suppresses the report only when a document
/// actually contains at least one such non-settling image; merely carrying an `.eml`
/// attachment is not sufficient. A mixed live-src/deferred-srcset image may settle.
/// The remaining gap is FAIL-CLOSED and registered as `IOS-UI-004`.
///
/// ⚠️ **The reason recorded here for NOT closing it was wrong, and it pointed the
/// next reader the wrong way.** It used to argue that closing the gap "would mean
/// changing what `pendingImgs()` counts, which is the width pipeline's settle
/// predicate", i.e. that touching the count was the change to avoid. The truth is
/// the reverse: T8 had ALREADY changed what that count means for the width
/// pipeline, and by sharing one predicate it disarmed the post-load width re-fit
/// outright on exactly these messages — a silent regression against shipped
/// `v1.7.8`, where `swap()` had no visibility predicate and the count always
/// reached 0. Restoring the re-fit is what the `ignoreWithheld` split does.
///
/// So the width half is FIXED, and only the diagnostic census half remains an
/// accepted observability gap. It has no user-visible consequence. Found by two
/// independent audit legs, 2026-08-13.
///
/// Exposed for unit tests via `_postImageWidthRecheckJS`.
internal var _postImageWidthRecheckJS: String { postImageWidthRecheckJS }
private var postImageWidthRecheckJS: String {
    let logFn = DebugModeManager.isLoggingEnabled()
        ? "function log(s) { try { window.webkit.messageHandlers.consoleLog.postMessage('[WidthRefit] ' + s); } catch(_){} }"
        : "function log(s) {}"
    return """
    (function() {
        \(logFn)
        // `ignoreWithheld` distinguishes the pipeline's TWO settle questions,
        // which are not the same question and were conflated until 2026-08-13.
        //
        //   • WIDTH RE-FIT asks "can any image still change the layout?" A
        //     withheld image (T8, `data-tmwithheld`) answers NO — it is inside a
        //     `display:none` subtree, contributes no box to `measureMaxRight`,
        //     and is never going to load in this document. Waiting on it is
        //     waiting forever, which is precisely what shipped `v1.7.8` did NOT
        //     do: there `swap()` had no visibility predicate, every deferred
        //     image lost `data-tmsrc`, and the count always reached 0.
        //   • DIAGNOSTIC CENSUS asks "has every armed image reached a terminal
        //     state?" A withheld image answers NO, honestly — it never loaded
        //     and never errored, so a census taken now would be incomplete.
        //     That arm keeps IOS-UI-004.
        //
        // ⚠️ Since 2026-08-13 the census answers its question from the per-image
        // terminal marks (`armedPending()`), not from this function, because the
        // two questions differ in POPULATION as well as in predicate: the width
        // pipeline asks about the live DOM, the census about the set it armed.
        // `ignoreWithheld` therefore has a single caller passing `true` today. It
        // is kept as a parameter deliberately — this function's contract is "how
        // many images are still pending, for the question you are asking", and
        // collapsing it to a constant would erase the distinction the parameter
        // exists to name, which is the exact conflation that disarmed the re-fit.
        //
        // Restoring the width re-fit is deliberately NOT the same edit as
        // closing IOS-UI-004: the first restores shipped width behaviour; the
        // second changes only the completeness timing of a diagnostic census.
        //
        // NOTE the one honest difference from `v1.7.8`: there, `check()` waited
        // for the hidden section's images to finish loading; here it does not
        // wait at all. The MEASUREMENT is identical either way — a `display:none`
        // image contributes nothing to the scan — so only the timing moves, and
        // it moves earlier.
        function pendingImgs(ignoreWithheld) {
            var imgs = document.getElementsByTagName('img');
            var n = 0;
            for (var i = 0; i < imgs.length; i++) {
                var im = imgs[i];
                if (ignoreWithheld && im.hasAttribute('data-tmwithheld')) continue;
                if (im.hasAttribute('data-tmsrc') || im.hasAttribute('data-tmsrcset') || !im.complete) n++;
            }
            return n;
        }
        function check() {
            if (window.__tmWidthRefitRequested) return;
            // fit() commits the baseline this compares against; if it hasn't run
            // yet, it will measure the (already loaded) images itself — nothing
            // to recheck. No later event re-fires check in that case, which is
            // correct: fit-after-load sees the true widths un-hidden.
            if (!window.__tmFitDone || !document.body) return;
            // Withheld images excluded — see pendingImgs(). Including them is
            // what disarmed this re-fit entirely on any message with an
            // attached `.eml`.
            if (pendingImgs(true) > 0) return;
            // Committed layout viewport — NEVER bare innerWidth (WebKit bug
            // 170595); same fallback chain as monitorHeightJS.
            var vp = window.__tmLayoutVp || window.__tmDeviceWidth || window.innerWidth;
            // Same clip-aware discipline as fitViewportJS's measureMaxRight
            // (AutoSizingHTMLView, logmain.log 2026-07-07): an element
            // contained by an author ancestor's overflow-x auto/scroll/
            // hidden/clip (strictly below document.body) cannot widen the
            // page even after its own images finish settling, so it must not
            // drive this recheck's re-widen decision either.
            function findClippingAncestor(el) {
                var anc = el.parentElement;
                while (anc && anc !== document.body) {
                    var ov = window.getComputedStyle(anc).overflowX;
                    if (ov === 'auto' || ov === 'scroll' || ov === 'hidden' || ov === 'clip') {
                        return anc;
                    }
                    anc = anc.parentElement;
                }
                return null;
            }
            var mr = 0;
            var all = document.body.getElementsByTagName('*');
            for (var k = 0; k < all.length; k++) {
                var rr = all[k].getBoundingClientRect().right;
                if (rr > mr) {
                    var clipAnc = findClippingAncestor(all[k]);
                    if (clipAnc) {
                        log('skipping would-be culprit ' + all[k].tagName + '.' + (all[k].className || '')
                            + ' w=' + Math.round(rr) + ' — clipped by ancestor ' + clipAnc.tagName + '.' + (clipAnc.className || ''));
                        continue;
                    }
                    mr = rr;
                }
            }
            // Same slop as fitViewportJS's OVERFLOW_SLOP — sub-pixel/ceil noise
            // must not trigger a re-fit of a fitting email.
            if (mr <= vp + 8) { log('images settled, no overflow (maxRight=' + Math.round(mr) + ' vp=' + vp + ')'); return; }
            window.__tmWidthRefitRequested = true;
            log('images settled, overflow: maxRight=' + Math.round(mr) + ' > vp=' + vp + ' — requesting re-fit');
            try { window.webkit.messageHandlers.heightChanged.postMessage({ requestWidthRefit: true }); } catch(_) {}
        }
        // ── P4 image-failure diagnostic (see the doc comment above) ──
        // Purely observational: records which of the images WE deferred ended in
        // `error` and reports the total ONCE, after the LAST armed image settles.
        // Never retries, probes or re-requests anything, and never touches which
        // images load or when.
        //
        // ONE RECORD PER ARMED IMAGE, holding the FIRST terminal state that image
        // reached. Until 2026-08-13 this was two free-running integers —
        // `remoteFailures` counted `error` FIRES, `armedRemote` counted images —
        // and nothing tied an increment to the image it came from. Two counters
        // over one population is two facts that can disagree, and author script
        // could make them disagree in both directions:
        //
        //   • OVERCOUNT. The listeners are deliberately not {once} (see below),
        //     so re-assigning `src` on one broken <img> re-fires `error` as often
        //     as the sender likes. Each fire incremented the counter, so `failed`
        //     could exceed `deferred` outright — an impossible diagnostic claiming
        //     more failures than there were images to fail.
        //   • UNDERCOUNT. The settle question was asked of the LIVE DOM
        //     (`pendingImgs(false)` walks `getElementsByTagName('img')`) while the
        //     armed population was a snapshot taken once. Detaching a still-loading
        //     armed <img> removed it from the predicate's view, the census read 0
        //     pending, published its one-shot report early, and the removed image's
        //     later `error` had nowhere to go.
        //
        // Deriving both numbers from the per-image marks makes `failed <= deferred`
        // structural rather than probable, and makes "has everything settled?" a
        // question about the images we actually armed rather than about whatever
        // is in the DOM at the moment it is asked.
        var armedImgs = [];
        function settle(rec, kind) {
            // First terminal event wins; later ones are dropped. An image cannot
            // un-fail, and it cannot fail twice.
            if (rec.terminal) return;
            rec.terminal = kind;
        }
        function armedPending() {
            var n = 0;
            for (var i = 0; i < armedImgs.length; i++) {
                if (!armedImgs[i].terminal) n++;
            }
            return n;
        }
        function armedRemoteCount() {
            var n = 0;
            for (var i = 0; i < armedImgs.length; i++) {
                if (armedImgs[i].isRemote) n++;
            }
            return n;
        }
        function remoteFailureCount() {
            var n = 0;
            for (var i = 0; i < armedImgs.length; i++) {
                if (armedImgs[i].isRemote && armedImgs[i].terminal === 'error') n++;
            }
            return n;
        }
        function reportImageFailures() {
            // Own one-shot, deliberately NOT check()'s: a message that both
            // loses images and needs a width re-fit must still report.
            if (window.__tmImageFailureReported) return;
            if (!document.body) return;
            // The STRICT settle question, asked of the ARMED SET and not of the
            // live DOM: has every image we armed reached a terminal state? A
            // FAILED image satisfies it — a broken <img> fires `error`, which is
            // as terminal as `load`.
            //
            // ⚠️ This is deliberately NOT `check()`'s question, and the
            // difference is the whole point. The census must not report while an
            // armed image has reached no terminal state — an ordinary remote-only
            // withheld image neither loaded nor errored, so counting it as settled
            // would publish an incomplete census. A mixed live `cid:` src can settle
            // despite its deferred `srcset`; IOS-UI-004 records that exception.
            // The width pipeline has the opposite need (see
            // pendingImgs()), so the two questions are answered separately rather
            // than by one shared call. IOS-UI-004 is preserved BY this arm, not in
            // spite of it: a withheld armed image with no terminal event keeps
            // `armedPending()` above zero. The condition is the non-settling image,
            // not the mere presence of an attached `.eml`. Closing that gap remains
            // a separate decision about P4's diagnostic completeness.
            //
            // ⚠️ This arm asked `pendingImgs(false)` until 2026-08-13. The
            // replacement is strictly MORE conservative about the population it
            // is responsible for — an armed image detached from the document
            // still blocks the report, where the DOM walk stopped seeing it — and
            // for the SETTLE question it drops only images that were never armed,
            // i.e. ones injected after documentEnd, which carry no listener and
            // whose failures this census could never have counted anyway. It does
            // not report earlier for any image we armed, and it never reports on
            // a withheld one.
            //
            // ⚠️ THE TWO SENTENCES ABOVE ARE TOO NARROW, and the missing case is
            // an image that IS armed. `wrapHTML` rewrites `src` and `srcset`
            // INDEPENDENTLY, so `<img src="cid:…" srcset="https://…">` keeps a
            // live cid src AND gains `data-tmsrcset` — armed, and `isRemote`.
            // Which terminal state it records is a RACE between the local cid
            // fetch and the remote srcset candidate swap() assigns. If the cid
            // wins, settle() records 'load' and the remote `error` is dropped,
            // where the old free-running counter did `remoteFailures++` on it
            // regardless of a prior load; and because the record is now settled
            // while `data-tmsrcset` may still be present, the census can also
            // publish EARLIER for this shape than `pendingImgs(false)` allowed.
            // Conservative both ways (a diagnostic count may be lower) and
            // deliberately LEFT ALONE: letting one image be both loaded and
            // failed reopens the two-facts-that-disagree problem this change
            // existed to close.
            if (armedPending() > 0) return;
            window.__tmImageFailureReported = true;
            var failed = remoteFailureCount(), deferred = armedRemoteCount();
            log('images settled, remote failures=' + failed + ' of ' + deferred + ' deferred');
            // The post itself remains available in every build, but Swift treats
            // it as diagnostic-only and emits its line only under the debug gate.
            try {
                window.webkit.messageHandlers.imageLoadFailure.postMessage({
                    failed: failed,
                    deferred: deferred
                });
            } catch(_) {}
        }
        var imgs = document.getElementsByTagName('img');
        for (var i = 0; i < imgs.length; i++) {
            var im = imgs[i];
            // A loaded, non-deferred image is already in fit()'s measurement —
            // only not-yet-displayable images can change the layout later.
            if (im.complete && !im.hasAttribute('data-tmsrc') && !im.hasAttribute('data-tmsrcset')) continue;
            // P4: "did WE defer this one" — i.e. is it a remote http(s) image
            // (the only kind wrapHTML rewrites). Captured HERE, not in the
            // handler, because swap() removes the attribute before assigning
            // src, so it is already gone when an error fires.
            var rec = {
                isRemote: im.hasAttribute('data-tmsrc') || im.hasAttribute('data-tmsrcset'),
                terminal: null
            };
            armedImgs.push(rec);
            // The IIFE is what gives each iteration its own binding: `var rec`
            // in this loop is function-scoped, so without it every listener
            // would mark the LAST image's record.
            (function(rec) {
                // NOT {once}: a deferred img fires load only after
                // deferredImageLoadJS swaps its real src in; check() is
                // flag-guarded so extra fires are cheap no-ops, and settle()
                // keeps only the first terminal state. The 60ms delay lets the
                // post-load reflow settle before measuring.
                //
                // check() is scheduled FIRST in both handlers so the width
                // pipeline is armed before any P4 statement runs and cannot be
                // perturbed by a throw in the newer code.
                im.addEventListener('load', function() {
                    setTimeout(check, 60);
                    settle(rec, 'load');
                    setTimeout(reportImageFailures, 60);
                });
                im.addEventListener('error', function() {
                    setTimeout(check, 60);
                    settle(rec, 'error');
                    setTimeout(reportImageFailures, 60);
                });
            })(rec);
        }
        if (armedImgs.length) {
            log('armed ' + armedImgs.length + ' image listener(s), ' + armedRemoteCount() + ' remote');
        }
    })();
    """
}

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
                var loaded = 0, broken = 0, pending = 0, deferred = 0, zeroSize = 0;
                for (var ii = 0; ii < allImgs.length; ii++) {
                    var img = allImgs[ii];
                    if (img.hasAttribute('data-tmsrc') || img.hasAttribute('data-tmsrcset')) deferred++;
                    else if (img.complete) { if (img.naturalWidth > 0) loaded++; else broken++; }
                    else pending++;
                    if (img.offsetWidth === 0 && img.offsetHeight === 0) zeroSize++;
                }
                window.webkit.messageHandlers.consoleLog.postMessage(
                    '[HTMLDebug] IMAGE AUDIT: total=' + allImgs.length
                    + ' loaded=' + loaded + ' broken=' + broken + ' pending=' + pending
                    + ' deferred=' + deferred + ' zeroSize=' + zeroSize
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
        // Reveal the document (EmailHTMLWrapper starts it at opacity:0). Called
        // at EVERY exit so content is never stranded invisible: synchronously on
        // the no-widen / skip paths (their first paint is already correctly
        // scaled), and via a double-rAF on the widen path so the reveal lands
        // AFTER WebKit's page-scale commit — the un-scaled widen frame is painted
        // while still opacity:0 and never seen. Inline+important beats the
        // stylesheet's opacity:0.
        function reveal() {
            try { document.documentElement.style.setProperty('opacity', '1', 'important'); } catch(_){}
            // Tell Swift the content is now visible so the loading placeholder is
            // removed. Funnels through reveal() so EVERY reveal path (no-overflow,
            // widen, idempotent re-fit, vw<100 skip) emits it. Idempotent Swift-side.
            try { window.webkit.messageHandlers.heightChanged.postMessage({ revealed: true }); } catch(_){}
        }
        // Reveal AFTER a paint cycle. Setting opacity:1 synchronously at
        // layout-time shows the box before WebKit has rasterized the visible
        // content — on a huge/complex doc (Vancouver Sun: 16003px Outlook
        // newsletter, revealed early via requestFit at readyState=interactive)
        // that is a visible "empty box at the right height, content paints in
        // later". A double rAF lands after the next compositor frame, so the
        // visible tiles are painted before we un-hide. (Offscreen tiles still
        // paint lazily on scroll — unavoidable and fine.)
        function revealAfterPaint() {
            requestAnimationFrame(function() { requestAnimationFrame(reveal); });
        }
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
        if (window.__tmLayoutVp) { log('already fitted (layoutVp=' + window.__tmLayoutVp + ') — idempotent no-op'); reveal(); return true; }
        // Mark fit() as having run for THIS document before any early return.
        // monitorHeightJS's report() suppresses height posts until this is set,
        // so the pre-widen (un-widened, scale-1.0) height is never applied —
        // killing the 1→881→466 load flicker. Set here (not at the bottom) so
        // every exit path below — including the vw<100 skip — opens the gate.
        window.__tmFitDone = true;
        // Measure against the Swift-stamped device-pt width (fit() stamps
        // __tmDeviceWidth from webView.bounds.width immediately before this
        // script runs). At the device-width baseline 1 CSS px == 1 pt, so it
        // IS the layout viewport. window.innerWidth is only the fallback for
        // a hypothetical unstamped run — it is unreliable after meta/bounds
        // changes (WebKit bug 170595).
        var vw = window.__tmDeviceWidth || window.innerWidth;
        log('enter: vw=' + vw + ' innerWidth=' + window.innerWidth + ' screenWidth=' + window.screen.width + ' devicePixelRatio=' + window.devicePixelRatio);
        if (vw < 100) { log('skip: viewport too small'); reveal(); return false; }
        // Strip hardcoded widths from non-table block elements wider than
        // viewport. CSS max-width works fine on divs/p/sections, so this is
        // mostly belt-and-suspenders. Tables/cells are EXCLUDED: many email
        // templates set `width="100%"` on outer wrappers intentionally so the
        // table grows with its container. Stripping it to `width:auto` makes
        // the table content-driven, and after viewport widening the table
        // no longer fills the widened parent — leaving visible left/right
        // margins where the auto-centered table sits inside a wider body.
        // `hr` IS included: it's purely decorative, so a fixed pixel width
        // wider than the viewport carries no content to preserve, and
        // `width:auto` just restores its default fill-the-container behavior.
        // Outlook/OWA quoted-content separator `<hr class="_qc_B"
        // style="width:1457.4px">`, logmain.log 2026-07-07: sole overflowing
        // element → widened to the 1200 cap → whole email at 0.24x.
        var toFix = document.body.querySelectorAll('div,p,section,hr');
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
        // Factored into a helper so it can be RE-RUN after a widen: widening the
        // layout viewport can cross one of the email's OWN `@media (max-width:N)`
        // breakpoints (e.g. 288→420 crosses a `max-width:415` query), flipping it
        // into a wider layout that overflows the width we just picked — the
        // "still cut on the right a bit" symptom (Apple-survey: mobile content
        // min-width 420 > its own 415 breakpoint, so any widen reveals the
        // desktop layout). We re-measure post-reflow and widen again until stable.
        function measureMaxRight() {
            // LAYER 2 — neutralize not-yet-displayable images for the overflow
            // measurement (the UPSTREAM fix; the runaway guard after the loop is
            // the downstream backstop). A DEFERRED image (its src stripped to
            // data-tmsrc for first paint, swapped back only AFTER paint) or a
            // still-loading <img> has no reliable intrinsic size and, with
            // width:auto, can balloon far past its container — making the loop
            // widen for a PHANTOM overflow that vanishes the instant the image
            // loads and img{max-width:100%} clamps it (Scholar Inbox header logo:
            // 43px phantom overflow → 0.33x shrink; logmain.log 2026-06-29).
            // Hide such images (display:none) so their — AND their inline <a>
            // wrapper's — bogus extent is excluded from the rightmost-edge scan,
            // then restore immediately (synchronous, before paint; no lasting
            // mutation). SCOPE is deliberate: keyed on data-tmsrc / !complete,
            // NEVER on naturalWidth===0 — a LOADED image (incl. an intrinsic-
            // size-less SVG) keeps its real width and still drives the decision.
            // NB: deferred imgs report complete===true (no src), so the
            // data-tmsrc check is REQUIRED — the old `!complete`-only guard
            // (reverted 2026-06-16) skipped 0 of them. This does NOT regress the
            // height:auto logo-balloon case: that image is LOADED, so it is not
            // hidden here and its (now height-scoped) sizing is unchanged.
            var imgs = document.body.getElementsByTagName('img');
            var hiddenImgs = [];
            for (var hi = 0; hi < imgs.length; hi++) {
                var hm = imgs[hi];
                if (hm.hasAttribute('data-tmsrc') || hm.hasAttribute('data-tmsrcset') || !hm.complete) {
                    // Capture the original inline display VALUE and PRIORITY so the
                    // restore is byte-faithful — e.g. enforceMediaDisplayJS (runs
                    // before fit) may have set `display:block !important` to beat a
                    // stylesheet's `display:none !important`; restoring without the
                    // priority would silently re-hide it.
                    hiddenImgs.push([hm, hm.style.getPropertyValue('display'), hm.style.getPropertyPriority('display')]);
                    hm.style.setProperty('display', 'none', 'important');
                }
            }
            // CLIP-AWARE MEASUREMENT: an element whose horizontal overflow is
            // contained by an AUTHOR ancestor (strictly below document.body)
            // with overflow-x auto/scroll/hidden/clip CANNOT widen the page —
            // its visible extent is the clipping ancestor's own box, and that
            // ancestor already participates in this scan as an element itself.
            // Without this, a notification email's markdown-render pricing
            // table (491px, nowrap cells) sitting inside its own sender-authored
            // DIV.w-full.overflow-auto scroller (286px — the standard
            // markdown-render horizontal-pan pattern) measured as the
            // rightmost edge and widened the whole email to 493px → 0.58x
            // shrink, even though on the web the table just pans inside its
            // own box and never touches the page width (logmain.log
            // 2026-07-07: OVERFLOW CULPRIT: TABLE.w-max min-w-full ...
            // ancestor[0] DIV.w-full overflow-auto w=286,
            // __aliyun_email_body_block markup). Only walk ancestors when a
            // candidate would BECOME the new max — the monotonic-increase
            // gate keeps the added per-candidate cost negligible. The walk
            // stops BEFORE document.body: our own wrapper sets
            // `overflow-x: clip` on html/body (EmailHTMLWrapper), so
            // including body in the walk would make every candidate look
            // contained. Undefined/empty/'visible' overflowX (the JSContext
            // test harnesses that stub getComputedStyle without an overflowX
            // field) is treated as non-containing — it must NOT match any of
            // the four listed values, or the 55 pre-existing tests break.
            function findClippingAncestor(el) {
                var anc = el.parentElement;
                while (anc && anc !== document.body) {
                    var ov = window.getComputedStyle(anc).overflowX;
                    if (ov === 'auto' || ov === 'scroll' || ov === 'hidden' || ov === 'clip') {
                        return anc;
                    }
                    anc = anc.parentElement;
                }
                return null;
            }
            var mr = 0, cp = null;
            var all = document.body.getElementsByTagName('*');
            for (var k = 0; k < all.length; k++) {
                var rr = all[k].getBoundingClientRect().right;
                if (rr > mr) {
                    var clipAnc = findClippingAncestor(all[k]);
                    if (clipAnc) {
                        log('measureMaxRight: skipping would-be culprit ' + all[k].tagName + '.' + (all[k].className || '')
                            + ' w=' + Math.round(rr) + ' — clipped by ancestor ' + clipAnc.tagName + '.' + (clipAnc.className || '')
                            + ' overflow-x=' + window.getComputedStyle(clipAnc).overflowX);
                        continue;
                    }
                    mr = rr; cp = all[k];
                }
            }
            // Culprit's own width, measured while the deferred images are STILL
            // hidden (same discipline as maxRight — a phantom descendant must
            // not inflate it; restoring first would fold the hidden images'
            // boxes back into the number). The widen loop needs it because a
            // CENTERED culprit's rect.right only closes half its overflow per
            // pass, while its own width is the exact viewport that contains it.
            var cw = cp ? cp.getBoundingClientRect().width : 0;
            // Restore each hidden image's original inline display value + priority.
            for (var ri = 0; ri < hiddenImgs.length; ri++) {
                var rEl = hiddenImgs[ri][0], rVal = hiddenImgs[ri][1], rPri = hiddenImgs[ri][2];
                if (rVal) rEl.style.setProperty('display', rVal, rPri);
                else rEl.style.removeProperty('display');
            }
            return { maxRight: mr, culprit: cp, culpritWidth: cw };
        }
        var measured = measureMaxRight();
        var maxRight = measured.maxRight;
        var culprit = measured.culprit;
        var culpritWidth = measured.culpritWidth;
        log('maxRight=' + Math.round(maxRight) + ' vs vw=' + vw);
        if (culprit && maxRight > vw + 10) {
            var culpritInfo = (culprit.tagName + '.' + (culprit.className || '') + ' w=' + Math.round(culprit.getBoundingClientRect().width)
                + ' style=' + (culprit.getAttribute('style') || 'none').substring(0, 120));
            log('OVERFLOW CULPRIT: ' + culpritInfo);
            var txt = (culprit.innerText || '').substring(0, 120).replace(/\\s+/g, ' ');
            log('  culprit text: "' + txt + '"');
            log('  culprit outerHTML[0:300]: ' + (culprit.outerHTML || '').substring(0, 300));
            // DIAGNOSTIC (2026-06-16): when the culprit is an image, dump its
            // intrinsic vs attribute vs computed size. Distinguishes a
            // GENUINELY-wide banner (naturalWidth >= rendered, email really is
            // desktop-width → widen is correct) from one BALLOONED by our
            // `img{height:auto}` wrapper rule stripping its height attr (small
            // natural size, but height:auto + no width lets it fill the
            // container → false overflow). The IMAGE AUDIT line is from a
            // different (earlier) script pass, so it can show complete=false
            // while THIS measurement sees a loaded image — log the state HERE.
            if (culprit.tagName === 'IMG') {
                var ccs = window.getComputedStyle(culprit);
                log('  culprit IMG natural=' + culprit.naturalWidth + 'x' + culprit.naturalHeight
                    + ' complete=' + culprit.complete
                    + ' attrW=' + (culprit.getAttribute('width') || '-') + ' attrH=' + (culprit.getAttribute('height') || '-')
                    + ' offset=' + culprit.offsetWidth + 'x' + culprit.offsetHeight
                    + ' computedW=' + ccs.width + ' computedH=' + ccs.height + ' maxW=' + ccs.maxWidth);
            }
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
        // Overflow must exceed the viewport by more than a few px to count.
        // WebKit reports sub-pixel layout widths (e.g. a column at 288.2 in a
        // 288 viewport), and `Math.ceil` turned 288.2 into 289 > 288 — a FALSE
        // overflow that then floored to STANDARD_MIN (400) and shrank a
        // perfectly-fitting email to 0.72x (observed: a 107KB newsletter that
        // `overflowingDescendants: none` confirmed fits at 288 was widened to
        // 403 on a second fit and visibly shrank). The slop also stops the
        // widen loop from creeping ~1px/pass on width:100% content. Genuine
        // desktop-width emails overflow by 50-130px, far above this slop, so
        // they still widen; a <=8px overflow clips harmlessly under
        // html{overflow-x:hidden} instead of over-shrinking the whole email.
        var OVERFLOW_SLOP = 8;
        if (maxRight <= vw + OVERFLOW_SLOP) {
            log('no overflow (maxRight=' + Math.round(maxRight) + ' within ' + OVERFLOW_SLOP + 'px slop of vw=' + vw + ') — staying at 1.0x');
            // Gate is now open; post the (scale-1.0) height immediately so a
            // no-widen email applies its height without waiting on the timers.
            if (window.__tmReportHeight) window.__tmReportHeight();
            // Reveal AFTER a paint cycle, not synchronously. We reach here as
            // early as the first layout (requestFit), often at
            // readyState=interactive — opacity:1 right now shows the box before
            // WebKit has painted the visible content of a big doc (Vancouver Sun
            // empty-then-appears). revealAfterPaint waits one compositor frame.
            revealAfterPaint();
            return false;
        }
        var meta = document.querySelector('meta[name="viewport"]');
        // Iteratively widen until the layout stops overflowing the width we set.
        // Each widen can cross a responsive @media breakpoint and reveal wider
        // content (fixed-px buttons, no-wrap rows), so a single measure-then-
        // widen undershoots and clips the right edge. Re-measure after a forced
        // synchronous reflow and widen to the new content width.
        //
        // TERMINATION (why this cannot run away — see the prior width/height
        // feedback loops in ADR-IOS-039): the loop is a plain synchronous `for`
        // with three independent stops, ALL of which must be true to continue:
        //   (1) bounded pass count — `pass < MAX_PASSES` (hard cap);
        //   (2) monotonic non-decreasing target — `targetWidth` is only ever
        //       assigned a strictly larger `want`; the moment a pass asks for
        //       `want <= targetWidth + OVERFLOW_SLOP` (no material progress) it
        //       breaks. A width:100% element fills whatever viewport we set, so
        //       its remeasure is within slop of targetWidth → immediate break;
        //       only FIXED-px content (which does not grow with the viewport)
        //       drives another pass, and it converges in one more pass;
        //   (3) absolute ceiling — clamped to 1200, with an explicit break.
        // It never calls fit() (no re-entry), runs entirely between paints (no
        // ResizeObserver/Swift feedback mid-loop), and once it sets
        // __tmLayoutVp the idempotency guard at the top blocks any future
        // fitViewportJS re-entry. So the worst case is "widen to 1200 once."
        var MAX_PASSES = 4;
        var targetWidth = 0;
        var converged = false;
        for (var pass = 0; pass < MAX_PASSES; pass++) {
            // Target the culprit's own width as well as the rightmost edge. A
            // margin:auto / align=center culprit RE-CENTERS on every widen, so
            // its rect.right only closes HALF the remaining overflow per pass
            // (FleetOptics 515px centered table at vw=288: right edge would walk
            // 402→459→487→501 and exhaust the pass budget still clipped — and a
            // not-converged end state can trip the runaway guard into reverting
            // a genuinely fixed-width email to 1.0x). The culprit's width is the
            // exact one-pass viewport for centered content; for left-anchored
            // content (left >= 0) width <= rect.right so the max() is a no-op,
            // and fluid width:100% content measures == the viewport and never
            // enters this loop.
            var want = Math.min(Math.max(Math.ceil(Math.max(maxRight, culpritWidth)), STANDARD_MIN), 1200);
            // Stop once we're not asking for materially more than already set.
            // The slop absorbs sub-pixel/ceil creep on width:100% content, which
            // otherwise re-measures ~1px wider every pass and runs out the whole
            // pass budget instead of converging in one widen.
            if (want <= targetWidth + OVERFLOW_SLOP) {
                if (targetWidth > 0) log('widen stable at ' + targetWidth + 'px after ' + pass + ' pass(es)');
                converged = true;
                break;
            }
            targetWidth = want;
            if (meta) {
                // initial-scale pins the visual page scale to the fit scale
                // (vw/targetWidth) from the FIRST paint. Without it WebKit paints
                // the widened layout once at scale 1.0 — content overflowing /
                // clipped to the frame — and commits the shrink ~one frame later
                // (zoom 1.0→0.56), which reads as a brief blink. Recomputed each
                // pass since targetWidth grows.
                var initScale = (vw / targetWidth).toFixed(3);
                meta.setAttribute('content', 'width=' + targetWidth + ', initial-scale=' + initScale + ', maximum-scale=5, user-scalable=yes');
            }
            // Force a synchronous reflow so the new viewport meta takes effect,
            // then re-measure. If a breakpoint flipped, maxRight now exceeds
            // targetWidth and the next pass widens to cover the revealed content.
            void document.documentElement.offsetHeight;
            var re = measureMaxRight();
            maxRight = re.maxRight;
            culprit = re.culprit;
            culpritWidth = re.culpritWidth;
            log('WIDEN pass ' + pass + ': set ' + targetWidth + 'px → remeasured maxRight=' + Math.round(maxRight)
                + (culprit ? ' culprit=' + culprit.tagName + '.' + (culprit.className || '') : ''));
            if (targetWidth >= 1200) { log('widen hit 1200px cap'); break; }
        }
        // RUNAWAY GUARD — abort the widen when the culprit is FLUID, not wide.
        // A width:auto / max-width:100% element (classically a not-yet-loaded
        // deferred <img> whose src we strip to data-tmsrc for first paint, so
        // `img{max-width:100%}` can't clamp it) GROWS with whatever viewport we
        // set. The loop above then chases it pass after pass without ever
        // containing it, settling at a large targetWidth and rendering the WHOLE
        // email at a tiny sub-0.5x scale — the "desktop size" shrink (Scholar
        // Inbox digest: a 43px logo overflow at vw=288 ran 288→400→499→648→873
        // and committed 0.33x; logmain.log 2026-06-29). The idempotency guard
        // then locks that scale even after the image loads and would fit.
        //
        // Discriminator: genuinely fixed-width content CONVERGES — once the
        // viewport is >= its intrinsic width it fits (maxRight <= targetWidth),
        // so `converged` is set. Fluid content never converges: after widening
        // to `targetWidth` it STILL overflows (maxRight > targetWidth). So:
        // not converged AND still-overflowing AND below the 1200 cap => fluid
        // runaway. Revert to device width and render at 1.0x (large, readable —
        // what Apple Mail does); html{overflow-x:clip} hides the few px of
        // transient overflow, and once the deferred image loads `max-width:100%`
        // snaps it inside the device-width container so nothing stays clipped.
        // The `targetWidth < 1200` gate preserves scale-to-fit for genuinely
        // wider-than-cap FIXED emails (clipping those would lose real content).
        if (!converged && targetWidth < 1200 && maxRight > targetWidth + OVERFLOW_SLOP) {
            log('RUNAWAY widen aborted: maxRight=' + Math.round(maxRight) + ' still > targetWidth=' + targetWidth
                + ' (fluid culprit ' + (culprit ? culprit.tagName + '.' + (culprit.className || '') : '?')
                + ') — reverting to device width, rendering at 1.0x');
            if (meta) meta.setAttribute('content', 'width=device-width, initial-scale=1, maximum-scale=5, user-scalable=yes');
            // Leave __tmLayoutVp unset (0): monitorHeightJS measures at scale 1.0
            // and the idempotency guard stays open so a later legitimate re-fit
            // (rotation / width change) can still run.
            window.__tmLayoutVp = 0;
            // Reflow back to device width before reporting the (now 1.0x) height.
            void document.documentElement.offsetHeight;
            if (window.__tmReportHeight) window.__tmReportHeight();
            revealAfterPaint();
            return false;
        }
        var scaleFactor = (vw / targetWidth).toFixed(2);
        log('WIDENING viewport to ' + targetWidth + 'px → CONTENT WILL RENDER AT ' + scaleFactor + 'x SCALE');
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
        // Gate is open (set at the top); post the FINAL widened height now so the
        // frame snaps straight from its seed to the scaled height (1→466), never
        // through the un-widened height (the 1→881→466 flicker).
        if (window.__tmReportHeight) window.__tmReportHeight();
        // Reveal AFTER the page-scale commit. The meta widen sets the layout
        // width synchronously, but WebKit applies the VISUAL scale ~one frame
        // later (zoom 1.0→0.56); a double rAF lands after that commit, so the
        // content (held at opacity:0 since load) is never painted on screen
        // un-scaled. WebKit ignores initial-scale on a runtime meta change, so
        // this opacity hold is what actually kills the blink, not the meta.
        revealAfterPaint();
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
                    window.webkit.messageHandlers.heightChanged.postMessage({
                        h: h,
                        vp: vp,
                        scroll: scroll,
                        rect: rect,
                        source: 'postWiden-' + stage,
                        userDisclosure: \(_consumeUserDisclosureExpression)
                    });
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
