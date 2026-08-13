/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import WebKit

// =====================================================================================
// P1c — the decision logic behind the message-render navigation boundary.
//
// ADR-IOS-076 decisions 2, 3, 6 and 7; PLAN_EMAIL_RENDER_SECURITY.md §10.1 C1 + C2,
// **as amended by the P1a measurements** (`bc7572eb1`).
//
// THE GUARANTEE, STATED EXACTLY: *no unapproved new main-frame document is admitted.*
// It does NOT claim that fragment or history-state mutations are prevented — P1a measured
// that `pushState`/`history.back` produce no delegate callback at all, and that returning
// `.cancel` on a fragment click does not stop the fragment navigation. A same-document
// mutation does not replace the trusted document, which is why the narrower guarantee is
// the right one to make.
//
// Everything here is a PURE function or a value-type state machine, deliberately: the
// `Coordinator` that owns it lives inside a `private struct` and cannot be reached from a
// test, while these types can be driven directly with the exact action shapes P1a
// recorded.
// =====================================================================================

// MARK: - Per-load document identity

/// The synthetic base URL each app-owned `loadHTMLString` is loaded under.
///
/// **Used UNCONDITIONALLY, at every call site, whether or not a scheme handler is
/// registered.** The original C1 spec said "for persisted messages"; P1a case D refuted
/// that: a substitute-data load never consults the scheme handler for the document
/// itself, so a `headerId == nil` configuration (compose quote, `.eml` preview, tooltip)
/// receives the byte-exact nonce URL at `decidePolicyFor` just the same. The converse is
/// what makes this mandatory rather than merely tidy — under `baseURL: nil` the action
/// arrives as `about:blank` with a `null` origin, so the nonce is not weak there, it is
/// **inexpressible**, and two concurrent `nil`-base loads are indistinguishable.
///
/// The nonce lives in the **path**, never in a fragment: a `.linkActivated` action carries
/// the full URL *including* the fragment (measured), so a fragment-borne nonce would leak
/// into every link the user taps.
///
/// The origin is unaffected — `tabmail-asset://asset` either way, scheme + host only — so
/// **absolute** `tabmail-asset://<hash>/<hash>` subresources resolve exactly as before.
/// **Path-relative** refs do move (`…/_tm-document/<nonce>/foo.gif` instead of
/// `…/asset/foo.gif`), but their OUTCOME cannot change: `BodyAssetStore.assetId(fromURL:)`
/// requires the host to be exactly `hashHexLength` characters and the document host is the
/// 5-character literal `asset`, so a path-relative ref is unresolvable under BOTH bases and
/// fails identically with `URLError(.resourceUnavailable)`. Pinned by
/// `relativeRefsAreUnresolvableUnderBothBases`.
internal enum RenderDocumentURL {
    /// First path segment of the synthetic base URL. Chosen so it can never collide with
    /// a real asset host: asset URLs are `tabmail-asset://<16 hex>/<16 hex>`, and this
    /// prefix is a path segment under the fixed `asset` host.
    static let pathPrefix = "_tm-document"

    /// 128 random bits — C1's floor — rendered as 32 lowercase hex characters.
    static let nonceBitCount = 128

    /// A fresh per-load nonce.
    ///
    /// `SystemRandomNumberGenerator` is documented as cryptographically secure on Apple
    /// platforms and, unlike `SecRandomCopyBytes`, has no failure path — which matters
    /// here because a fallback source would be a silently weaker permit, and the repo
    /// forbids fallback routines outright.
    static func nonce() -> String {
        var rng = SystemRandomNumberGenerator()
        let high = UInt64.random(in: UInt64.min...UInt64.max, using: &rng)
        let low = UInt64.random(in: UInt64.min...UInt64.max, using: &rng)
        return hex16(high) + hex16(low)
    }

    /// The synthetic base URL carrying `nonce` in its path.
    static func url(nonce: String) -> URL {
        // Force-unwrapped deliberately: every component is app-authored and the nonce is
        // hex, so this string is a valid URL by construction. A failable path here would
        // be a fallback with no correct behaviour to fall back to.
        URL(string: "\(BodyAssetConfig.urlScheme)://asset/\(pathPrefix)/\(nonce)/")!
    }

    /// The only form of a nonce that may ever be logged. Enough to correlate the lines of
    /// one load in a log; far too little to forge a permit.
    static func logPrefix(_ nonce: String) -> String {
        String(nonce.prefix(8)) + "…"
    }

    /// The nonce embedded in a document URL produced by `url(nonce:)`, for logging only.
    static func logPrefix(forDocumentURL urlString: String) -> String {
        let marker = "/\(pathPrefix)/"
        guard let range = urlString.range(of: marker) else { return "?" }
        let tail = urlString[range.upperBound...]
        let nonce = tail.prefix(while: { $0 != "/" })
        return logPrefix(String(nonce))
    }

    private static func hex16(_ value: UInt64) -> String {
        let digits = String(value, radix: 16)
        return String(repeating: "0", count: 16 - digits.count) + digits
    }
}

// MARK: - The main-frame document permit

/// One armed permit: the load generation that armed it and the exact URL string that was
/// handed to `loadHTMLString`.
internal struct DocumentLoadPermit: Equatable {
    let generation: Int
    let url: String
}

/// Why an action was not admitted. Raw values are log tokens.
internal enum PermitRefusal: String, Equatable {
    /// Nothing is pending — the app is not loading a document right now.
    case noPendingPermit = "no-pending-permit"
    /// The action named a different URL than the one we supplied.
    case urlMismatch = "url-mismatch"
    /// The action carried no URL at all.
    case missingURL = "missing-url"
    /// It DID name our URL but arrived on a subframe (or a new window).
    case notMainFrame = "not-main-frame"
    /// It DID name our URL but was not `.other` — a link/form/back-forward action.
    case notOtherNavigationType = "not-other-navigation-type"
}

internal enum PermitDecision: Equatable {
    /// This action IS the app's own pending load. Admit it and consume the permit.
    case admit(DocumentLoadPermit)
    /// It presented the expected nonce URL and failed some OTHER check, so the permit is
    /// no longer trustworthy: clear it and refuse.
    case refuseAndInvalidate(PermitRefusal)
    /// Unrelated to the pending permit. Refuse WITHOUT touching it — otherwise an old,
    /// subframe or user action would cancel a legitimate app load.
    case refuse(PermitRefusal)
}

/// The permit half of the two-state machine (the other state is the returned
/// `WKNavigation`, which only the `Coordinator` can hold).
///
/// **Supersession, not assertion failure.** P1a measured that a superseded load receives
/// **no callback at all** — not even `didFailProvisionalNavigation`. A design that retired
/// a permit on a failure callback would therefore leak permits forever, so the ONLY way a
/// live permit is retired other than by being consumed or explicitly invalidated is
/// `arm(...)` issuing the next one.
internal struct NavigationPermitState: Equatable {
    private(set) var pending: DocumentLoadPermit?

    init(pending: DocumentLoadPermit? = nil) {
        self.pending = pending
    }

    /// Arm the permit for a new load, returning the permit this one superseded (if any).
    @discardableResult
    mutating func arm(generation: Int, url: String) -> DocumentLoadPermit? {
        let superseded = pending
        pending = DocumentLoadPermit(generation: generation, url: url)
        return superseded
    }

    /// Drop any live permit, returning it. Used by the content-process-termination path
    /// and by the server-redirect path, both of which must not leave a permit armed.
    @discardableResult
    mutating func invalidate() -> DocumentLoadPermit? {
        let dropped = pending
        pending = nil
        return dropped
    }

    /// Classify an action against the pending permit WITHOUT mutating anything.
    ///
    /// The comparison is **exact string equality against the URL we supplied** — never
    /// after `URLComponents` normalization, because a disagreement between two parsers is
    /// precisely the bug a nonce is supposed to make impossible.
    func classify(url: String?, navigationType: WKNavigationType, isMainFrame: Bool) -> PermitDecision {
        guard let pending else { return .refuse(.noPendingPermit) }
        guard let url else { return .refuse(.missingURL) }
        guard url == pending.url else { return .refuse(.urlMismatch) }
        // From here on the action named our per-load nonce, which an untrusted document
        // cannot guess. Anything else wrong with it means the permit is compromised or
        // stale, so it is cleared rather than left armed.
        guard isMainFrame else { return .refuseAndInvalidate(.notMainFrame) }
        guard navigationType == .other else { return .refuseAndInvalidate(.notOtherNavigationType) }
        return .admit(pending)
    }

    /// Classify and apply the resulting state transition.
    ///
    /// The permit is consumed **at policy time**, immediately before the caller returns
    /// `.allow` — not at commit. Failure after commit therefore cannot leak it.
    mutating func evaluate(url: String?, navigationType: WKNavigationType, isMainFrame: Bool) -> PermitDecision {
        let decision = classify(url: url, navigationType: navigationType, isMainFrame: isMainFrame)
        switch decision {
        case .admit, .refuseAndInvalidate:
            pending = nil
        case .refuse:
            break
        }
        return decision
    }
}

// MARK: - Externally dispatched links

internal enum LinkRefusal: String, Equatable {
    /// Not `http`/`https`. P1a demonstrated on shipped code that a
    /// `tabmail-asset://asset/#target` URL reaches `UIApplication.shared.open`.
    case nonWebScheme = "non-web-scheme"
    /// `http`/`https` with no host — nothing sensible to open.
    case emptyHost = "empty-host"
}

internal enum LinkDispatch: Equatable {
    /// A fragment inside the document we loaded. Handled INTERNALLY: never routed to the
    /// system opener. P1a measured that returning `.cancel` does not prevent the
    /// same-document scroll, so the anchor still works — what stops is the hand-off.
    case sameDocumentFragment
    /// An `http`/`https` URL with a host: hand to `UIApplication.shared.open`.
    case openExternally
    case refuse(LinkRefusal)
}

internal enum RenderLinkPolicy {
    /// Where a `.linkActivated` action goes, given the URL of the document we loaded.
    ///
    /// `mailto:` is handled by the caller before this (unchanged behaviour: TabMail
    /// composes rather than handing off to whichever app iOS considers the default mail
    /// client).
    ///
    /// The scheme test is ASCII-case-insensitive and there is deliberately no re-parse,
    /// percent-decode or `URLComponents` rebuild between the test and the `open` call —
    /// the URL that is checked is the URL that is opened.
    static func dispatch(for url: URL, documentURL: String?) -> LinkDispatch {
        let absolute = url.absoluteString
        // Same-document fragment: everything before the FIRST '#' must equal, byte for
        // byte, the URL we handed to `loadHTMLString`. Compared as strings for the same
        // reason the permit is: no normalization, no second parser.
        if let documentURL, let hash = absolute.firstIndex(of: "#"),
           String(absolute[absolute.startIndex..<hash]) == documentURL {
            return .sameDocumentFragment
        }
        guard let scheme = url.scheme,
              isASCIICaseInsensitiveEqual(scheme, "http") || isASCIICaseInsensitiveEqual(scheme, "https")
        else {
            return .refuse(.nonWebScheme)
        }
        guard let host = url.host(percentEncoded: true), !host.isEmpty else {
            return .refuse(.emptyHost)
        }
        return .openExternally
    }

    /// The scheme, lowercased, for a log line. Schemes are app-safe to log whole — they
    /// are short, drawn from a small vocabulary, and carry no message content.
    static func loggableScheme(_ url: URL) -> String {
        guard let scheme = url.scheme, !scheme.isEmpty else { return "(none)" }
        return String(scheme.prefix(24)).lowercased()
    }

    /// `lhs` compared to a lowercase ASCII literal, ASCII-only.
    ///
    /// Not `lowercased()`: Unicode case folding maps characters outside ASCII into ASCII
    /// (U+0130 folds to `i` + U+0307), and a scheme comparison that accepts those is a
    /// wider allowlist than the one written down.
    private static func isASCIICaseInsensitiveEqual(_ lhs: String, _ lowercaseASCII: String) -> Bool {
        let a = Array(lhs.utf8)
        let b = Array(lowercaseASCII.utf8)
        guard a.count == b.count else { return false }
        for (x, y) in zip(a, b) {
            let folded = (x >= 0x41 && x <= 0x5A) ? x + 0x20 : x
            if folded != y { return false }
        }
        return true
    }
}

// MARK: - Bridge-liveness verdict

/// The verdict a committed load reports about app-injected JavaScript.
internal enum BridgeLivenessVerdict: String, Equatable {
    /// A `WKScriptMessage` arrived for this load — app user scripts provably executed
    /// and provably reached Swift.
    case live = "LIVE"
    /// Nothing arrived. This is the designated alarm for the catastrophic-quiet failure
    /// mode of the whole render-hardening workstream.
    case silent = "SILENT"
}

/// Sequences the one diagnostic in the render path that survives a total loss of page
/// JavaScript.
///
/// **Why it is a type and not two lines in the `Coordinator`.** The `Coordinator` lives
/// inside a `private struct` and cannot be reached from a test, while this can be driven
/// directly — which matters because the invariant is about the SEQUENCE (arm, settle,
/// exactly once), not about the text of the line.
///
/// ⚠️ **THE BLIND SPOT THIS CLOSES, measured on device 2026-08-12.** The verdict used to
/// be armed from `didFinish`. In a device smoke test at `e81fd75da` — **42 loads that
/// logged `didCommit tracked=true`, 41 that logged a `bridge=` verdict, and no id logging
/// two** — exactly one committed load, `KH4CLK`, logged neither `LIVE` nor `SILENT`,
/// because its images never settled and so `didFinish` never fired. Its user scripts had
/// demonstrably run: `[ImageLoadDiag id=KH4CLK +1ms] inventory images=5` arrived one
/// millisecond after `[NavPermit id=KH4CLK] didCommit tracked=true`, which is a page
/// script reaching Swift. A page that hangs mid-load therefore produced **no line at
/// all**, which made the alarm's ABSENCE indistinguishable from the alarm not existing —
/// `MIS-019`'s shape, a check whose negative case is unobservable. Arming at `didCommit`
/// makes the verdict a property of COMMITTING, which every rendered document does, rather
/// than of FINISHING, which a live page may never do.
///
/// (The source log is a local, gitignored `logmain.log` that keeps growing, so those
/// counts are a snapshot of one session and are **not** reproducible from the repo. The
/// reproducible statement of the same fact is `BridgeLivenessBeaconTests` below.)
///
/// **What "exactly one" means, stated with its exception so it is not overstated:** every
/// committed load emits exactly one verdict *unless a newer load supersedes it first*,
/// and supersession is itself logged (`issued gen=…` / `superseded gen=…`), so its
/// silence is explained rather than mysterious. That exception is the pre-existing,
/// deliberate behaviour — a superseded load's verdict describes a document that is no
/// longer on screen — and P1d does not change it.
internal struct BridgeLivenessBeacon: Equatable {
    /// The most recent generation that has been armed. A generation is armed AT MOST
    /// ONCE, so a second `didCommit` for the same load — or a future edit that re-adds
    /// an arm from `didFinish` — cannot produce a second verdict.
    private(set) var armedGeneration: Int?

    init(armedGeneration: Int? = nil) {
        self.armedGeneration = armedGeneration
    }

    /// Arm the verdict timer for a committed load. Returns `true` when the caller should
    /// actually schedule one, `false` when this generation is already armed.
    mutating func arm(generation: Int) -> Bool {
        guard armedGeneration != generation else { return false }
        armedGeneration = generation
        return true
    }

    /// The verdict for `generation` when its grace period expires, or `nil` when a newer
    /// load has superseded it.
    ///
    /// Pure: the caller supplies the state, so a test drives every branch without a
    /// timer.
    static func settle(
        generation: Int,
        currentGeneration: Int,
        lastBridgeMessageGeneration: Int?
    ) -> BridgeLivenessVerdict? {
        guard currentGeneration == generation else { return nil }
        return lastBridgeMessageGeneration == generation ? .live : .silent
    }
}

// MARK: - Bridge input validation

/// Swift-side validation for the three `WKScriptMessageHandler` channels
/// (`heightChanged`, `consoleLog`, `gutterAdjust`).
///
/// **Why in Swift, when the page-side JS already clamps.** The handlers are registered in
/// the page world, so every clamp that lives in our injected JS is *advisory* — anything
/// running in that world can post whatever it likes and simply not call our clamps.
/// `connect-src 'none'` does not close this: `webkit.messageHandlers` is not a fetch
/// surface. P1b's `allowsContentJavaScript = false` removes today's reachable attacker,
/// but the validation belongs on the trusted side regardless, and the failure modes
/// (a `NaN` frame height, a 10⁹-point gutter) are cheap to make impossible.
///
/// Every rejection **fails closed**: the message is dropped and, when logging is enabled,
/// says so. Nothing substitutes a default a sender could aim.
internal enum RenderBridgeInput {
    /// Matches the `GUTTER` constant in `eatGutterMarginsJS` and the SwiftUI default
    /// padding. The JS already clamps to `[0, GUTTER]`; this is the authoritative copy.
    static let gutterRange: ClosedRange<CGFloat> = 0...16

    /// Console lines are diagnostics, not data. Bounded so one message cannot flood the
    /// device log, and escaped because `print` is a LINE-oriented sink.
    static let maxConsoleLineLength = 2048

    /// `source` is a short app-authored tag (`RO`, `postWiden-1`, …) that is interpolated
    /// into a log line; bounded for the same reason.
    static let maxSourceLength = 64

    /// Numeric keys of a `heightChanged` dictionary payload. Each must be a finite,
    /// non-negative number if present.
    ///
    /// There is deliberately **no upper bound**: an arbitrary height ceiling was specified
    /// during the vet and then REJECTED, because it truncates a legitimately long
    /// newsletter and buys little (ADR-IOS-076 decision 7). Finite and non-negative is the
    /// whole contract.
    private static let numericKeys = ["h", "vp", "scroll", "rect"]

    /// Boolean command keys. Present-but-not-a-`Bool` is a malformed payload, not a
    /// falsey one.
    private static let flagKeys = ["revealed", "requestFit", "requestWidthRefit"]

    /// Validate a `heightChanged` payload, returning the body to process or `nil` to drop
    /// it. A dictionary payload is returned with its `source` tag bounded and escaped, so
    /// the downstream log interpolation cannot be forged.
    static func validatedHeightBody(_ body: Any) -> Any? {
        if let number = body as? NSNumber {
            return isAcceptableMeasurement(number) ? number : nil
        }
        guard let dict = body as? [String: Any] else { return nil }
        for key in flagKeys {
            guard let raw = dict[key] else { continue }
            guard raw is Bool else { return nil }
        }
        for key in numericKeys {
            guard let raw = dict[key] else { continue }
            guard let number = raw as? NSNumber, isAcceptableMeasurement(number) else { return nil }
        }
        guard let rawSource = dict["source"] else { return dict }
        guard let source = rawSource as? String else { return nil }
        var sanitized = dict
        sanitized["source"] = DebugModeManager.escapedForLogLine(String(source.prefix(maxSourceLength)))
        return sanitized
    }

    /// The clamped `[leading, trailing]` padding for a `gutterAdjust` payload, or `nil` if
    /// the payload is malformed.
    ///
    /// A missing side keeps the caller's current value (the shipped behaviour); a side
    /// that is PRESENT but not a finite number rejects the whole message rather than
    /// applying half of it.
    static func gutterPadding(_ body: Any, leading: CGFloat, trailing: CGFloat) -> (leading: CGFloat, trailing: CGFloat)? {
        guard let dict = body as? [String: Any] else { return nil }
        var resolvedLeading = leading
        var resolvedTrailing = trailing
        if let raw = dict["l"] {
            guard let number = raw as? NSNumber, number.doubleValue.isFinite else { return nil }
            resolvedLeading = clampToGutter(CGFloat(truncating: number))
        }
        if let raw = dict["r"] {
            guard let number = raw as? NSNumber, number.doubleValue.isFinite else { return nil }
            resolvedTrailing = clampToGutter(CGFloat(truncating: number))
        }
        return (resolvedLeading, resolvedTrailing)
    }

    /// A bounded, control-character-escaped console line, or `nil` if the payload is not a
    /// string.
    static func consoleLine(_ body: Any) -> String? {
        guard let raw = body as? String else { return nil }
        let overflow = raw.count - maxConsoleLineLength
        let bounded = overflow > 0 ? String(raw.prefix(maxConsoleLineLength)) : raw
        let escaped = DebugModeManager.escapedForLogLine(bounded)
        return overflow > 0 ? escaped + "…[+\(overflow) chars truncated]" : escaped
    }

    private static func clampToGutter(_ value: CGFloat) -> CGFloat {
        min(max(value, gutterRange.lowerBound), gutterRange.upperBound)
    }

    private static func isAcceptableMeasurement(_ number: NSNumber) -> Bool {
        let value = number.doubleValue
        return value.isFinite && value >= 0
    }
}
