/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import WebKit

// =====================================================================================
// P1d — asset ownership binding for the `tabmail-asset://` scheme.
//
// ADR-IOS-076 decision 5; PLAN_EMAIL_RENDER_SECURITY.md §10.1 C3 + C5, §10.2.
//
// THE INVARIANT: **an asset is served only to the document that owns it.**
//
// Everything that DECIDES lives in `BodyAssetServePolicy` — pure functions over values,
// so the ownership, shape and MIME rules can be driven directly from tests without a
// `WKWebView`, a window, or a WebKit run loop. The handler below does I/O and nothing
// else: parse, fetch the row, ask the policy, read the bytes, respond.
// =====================================================================================

/// Why an asset request was not served. Raw values are LOG tokens only.
///
/// ⚠️ These distinctions exist for the log and **must never reach the wire.** Every one
/// of them produces the same single `URLError(.resourceUnavailable)` failure, so a
/// document cannot tell "you do not own that" from "there is no such asset" from "that
/// asset is the wrong MIME type". Because the wire response is deliberately uniform, the
/// log is the ONLY place the distinction exists — which is what makes these diagnostics
/// load-bearing rather than decorative.
enum BodyAssetRefusal: String, Equatable, Sendable {
    /// The request carried no URL at all.
    case missingURL = "missing-url"
    /// The URL is not the canonical `tabmail-asset://<16 hex>/<16 hex>` shape.
    case malformedURL = "malformed-url"
    /// No manifest row with that exact id (or the manifest was unreadable).
    case noManifestRow = "no-manifest-row"
    /// A row exists, but its `headerId` is not this document's owner key.
    case notOwned = "not-owned"
    /// A row exists and is owned, but it is a file ATTACHMENT, not an inline image —
    /// so message HTML cannot read its own message's attachments through `<img>`.
    case wrongKind = "wrong-kind"
    /// The stored content type is not in the allowlist.
    case disallowedMIME = "disallowed-mime"
    /// Row authorized, bytes missing or unreadable on disk.
    case missingFile = "missing-file"
}

/// The pure decision layer behind `BodyAssetSchemeHandler`.
enum BodyAssetServePolicy {

    // MARK: - Canonical URL shape

    /// The canonical asset id for a request URL, or nil if the URL is not exactly the
    /// shape `absoluteURL(forAssetId:)` produces.
    ///
    /// **Why this is not `BodyAssetStore.assetId(fromURL:)`.** That parser answers a
    /// different question — "does this look roughly like an asset URL" — and it accepts
    /// non-hex segments, ignores extra path components, and does not care about
    /// userinfo, port, query or fragment. On the SERVING path the question is instead
    /// "is this byte-for-byte a URL we minted", and anything looser widens the surface
    /// the ownership check then has to defend. This is the ONLY parser on the serving
    /// path, so there is no second parser to disagree with (the same reason the
    /// navigation permit compares URLs as exact strings).
    ///
    /// `assetId(fromURL:)` is retained unchanged for its existing non-serving callers.
    static func canonicalAssetId(from url: URL) -> String? {
        guard url.scheme == BodyAssetConfig.urlScheme else { return nil }
        // A `URLComponents` round trip would re-normalize; read the components off the
        // URL we were handed instead.
        guard url.user == nil, url.password == nil, url.port == nil,
              url.query == nil, url.fragment == nil else { return nil }
        guard let host = url.host(percentEncoded: true), isExpectedHex(host) else { return nil }
        // `pathComponents` percent-DECODES, so a `%2F` inside a segment would be
        // invisible here. Split the raw path instead: an encoded separator then fails
        // the hex test rather than silently becoming a second segment.
        let rawPath = url.path(percentEncoded: true)
        guard rawPath.hasPrefix("/") else { return nil }
        let segments = rawPath.dropFirst().split(separator: "/", omittingEmptySubsequences: false)
        guard segments.count == 1, isExpectedHex(String(segments[0])) else { return nil }
        return "\(host)/\(segments[0])"
    }

    /// Exactly `BodyAssetStore.hashHexLength` LOWERCASE hex digits — the form
    /// `BodyAssetStore.headerHash` / `assetHash` emit. Uppercase is rejected rather
    /// than folded: our own minting never produces it, so accepting it would only add
    /// a second spelling for the same row id.
    private static func isExpectedHex(_ s: String) -> Bool {
        guard s.utf8.count == BodyAssetStore.hashHexLength else { return false }
        return s.utf8.allSatisfy { c in
            (c >= 0x30 && c <= 0x39) || (c >= 0x61 && c <= 0x66)
        }
    }

    // MARK: - MIME allowlist

    /// The ONE top-level media type this handler will serve.
    ///
    /// The CSP already confines `tabmail-asset:` to `img-src`, so every legitimate use
    /// of this scheme is an `<img>` subresource; the allowlist is the second, wire-level
    /// statement of the same restriction, and it is the one that still holds if the CSP
    /// is edited.
    ///
    /// ⚠️ **STATE WHAT THIS ALLOWLIST IS AND IS NOT.** It admits `image/<subtype>` for
    /// ANY well-formed subtype; it does **not** enumerate subtypes. That is a deliberate
    /// choice against the stricter-looking alternative, and the reason is the owner
    /// directive of 2026-08-12 — *"no behaviour changes, just security"*, under which a
    /// UX regression is a stop-and-report and never an accepted limitation. An
    /// enumerated subtype set carries an **unbounded** regression risk: inline-image
    /// parts arrive with whatever `Content-Type` the sender's mailer wrote
    /// (`IMAPFetchMapping.extractInlineImages` passes `part.contentType` through
    /// unfiltered), Apple's image stack renders a long and version-dependent list, and
    /// legacy spellings such as `image/pjpeg` and `image/x-png` are still emitted in the
    /// wild — so any list I could write would silently break some real message's logo.
    ///
    /// **And it gives up nothing measurable**, which is why the trade is one-sided: every
    /// `image/*` subtype is a non-executable picture format. The one carrying markup is
    /// SVG, and SVG referenced from `<img>` is a non-scripted image document by
    /// specification — no script, no external references — while this document
    /// additionally carries `script-src 'none'`, `object-src 'none'` and
    /// `frame-src 'none'`, and cannot navigate to an asset URL because the P1c permit
    /// admits only the per-load nonce URL. **If any of those facts stops being true,
    /// re-open this decision.** What the gate does buy is the whole point: `text/html`,
    /// `application/javascript`, `text/xml` and every other top-level type are refused,
    /// and a `cid:`-referenced part CAN carry them (the extractor does not filter).
    static let allowedTopLevelType = "image"

    /// Upper bound on the subtype we will echo into a response header.
    static let maxSubtypeLength = 64

    /// Whether a NORMALIZED media type may be served.
    ///
    /// The subtype must be a non-empty RFC 6838 *restricted-name* — that is what keeps a
    /// stored, attacker-influenced value from being echoed into a header as anything
    /// other than a media-type token (no comma, no space, no separator, no control).
    static func isAllowedMIMEType(_ normalized: String) -> Bool {
        let parts = normalized.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0] == allowedTopLevelType else { return false }
        let subtype = parts[1].utf8
        guard !subtype.isEmpty, subtype.count <= maxSubtypeLength else { return false }
        guard let first = subtype.first, isASCIIAlphanumeric(first) else { return false }
        return subtype.allSatisfy { byte in
            // restricted-name-chars = ALPHA / DIGIT / "!" / "#" / "$" / "&" / "-" /
            //                         "^" / "_" / "." / "+"   (already lowercased)
            isASCIIAlphanumeric(byte) || [0x21, 0x23, 0x24, 0x26, 0x2D, 0x5E, 0x5F, 0x2E, 0x2B].contains(byte)
        }
    }

    private static func isASCIIAlphanumeric(_ byte: UInt8) -> Bool {
        (byte >= 0x61 && byte <= 0x7A) || (byte >= 0x30 && byte <= 0x39)
    }

    /// Exact normalization: split at the first `;`, trim ASCII whitespace, lowercase.
    ///
    /// Lowercasing is ASCII-only for the same reason `RenderLinkPolicy` folds schemes
    /// by hand — Unicode case folding maps non-ASCII scalars INTO ASCII (U+212A KELVIN
    /// SIGN folds to `k`), so a Unicode-aware fold is a wider allowlist than the one
    /// written down.
    static func normalizedMIMEType(_ raw: String) -> String {
        let base = raw.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        let trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(String.UnicodeScalarView(trimmed.unicodeScalars.map { scalar in
            (scalar.value >= 0x41 && scalar.value <= 0x5A)
                ? Unicode.Scalar(scalar.value + 0x20)!
                : scalar
        }))
    }

    /// A bounded, character-allowlisted rendering of a stored content type, for logs.
    ///
    /// The stored value comes from a sender's MIME headers, and `print` is a
    /// LINE-oriented sink: an interior CR/LF would forge a plausible extra diagnostic
    /// line. Restricting to the characters a media type is actually built from is
    /// stronger than escaping, and needs no app-target escaper (this file also compiles
    /// into the notification-service extension).
    static func loggableMIMEType(_ raw: String) -> String {
        let capped = String(raw.prefix(64))
        let mapped = capped.unicodeScalars.map { scalar -> Character in
            switch scalar.value {
            case 0x61...0x7A, 0x41...0x5A, 0x30...0x39: return Character(scalar)
            case 0x2F, 0x2B, 0x2E, 0x2D, 0x5F: return Character(scalar)  // / + . - _
            default: return "?"
            }
        }
        return mapped.isEmpty ? "(empty)" : String(mapped)
    }

    // MARK: - The decision

    /// What to do with a request, given the manifest row it resolved to.
    enum Authorization: Equatable {
        /// Serve the bytes under this exact, normalized content type. The stored value
        /// is NOT echoed: it is attacker-influenced and may carry parameters, and the
        /// only thing that has been authorized is the normalized token.
        case serve(contentType: String)
        case refuse(BodyAssetRefusal)
    }

    /// The ownership predicate: exact row id (already established by the caller having
    /// fetched `row` under `assetId`), `headerId` equal to the rendering document's
    /// owner key, `kind == .inlineImage`, and an allowlisted content type.
    ///
    /// Order matters only for the LOG: the reasons are reported most-specific-first so a
    /// smoke test says *why*, while the wire response is identical for all of them.
    static func authorize(row: BodyAssetStore.AssetManifestRow?, ownerKey: ContentKey) -> Authorization {
        guard let row else { return .refuse(.noManifestRow) }
        guard row.owner == ownerKey else { return .refuse(.notOwned) }
        guard row.kind == .inlineImage else { return .refuse(.wrongKind) }
        let normalized = normalizedMIMEType(row.contentType)
        guard isAllowedMIMEType(normalized) else { return .refuse(.disallowedMIME) }
        return .serve(contentType: normalized)
    }
}

/// `WKURLSchemeHandler` for the `tabmail-asset://` scheme. Serves bytes from
/// `BodyAssetStore` in-process so WKWebView's sandboxed WebContent process can
/// render `<img src>` refs without requiring `file://` access to the App Group
/// container (which doesn't work on device).
///
/// **P1d: the handler is BOUND to the `MessageBody.id` of the document it serves.**
/// The owner key is a `ContentKey` — the body's authoritative key — and never a key
/// rebuilt from `MessageHeader.id`, which is a plain `String` that 35 call sites pass
/// unwrapped (see `MessageBody`'s own doc comment). A handler is installed ONCE on a
/// `WKWebViewConfiguration` and `updateUIView` cannot replace it, so the web view is
/// recreated when the body `ContentKey` changes — see `HTMLWebView`'s `.id(…)`.
///
/// Lives in `Shared/` so both targets can use it. NSE doesn't render HTML so it
/// never instantiates the handler — but the type compiles into the NSE bundle
/// at near-zero cost (one class definition, no static state).
///
/// **Does NOT bump LRU.** LRU bumps fire only on user tap
/// (`MessageDetailViewModel.loadBody()` and the attachment tap-time fetcher).
/// Rendering an already-cached message's images via the scheme handler is not
/// considered "tapping" the message — only the explicit message open is.
///
/// Returns `Cache-Control: no-store` so WKWebView always invokes the handler
/// (rather than caching responses) — matters for fresh re-renders after a
/// cap-change or eviction. The handler itself is fast (single SQLite read +
/// `Data(contentsOf:)`).
final class BodyAssetSchemeHandler: NSObject, WKURLSchemeHandler {

    /// The rendered document's `MessageBody.id`. Immutable for this handler's whole
    /// lifetime: a MUTABLE owner key was considered and REJECTED, because in-flight
    /// `WKURLSchemeTask`s would straddle the mutation. The structural fix is view
    /// recreation, not a settable key.
    private let ownerKey: ContentKey

    /// Debug-gated log sink, injected because `DebugModeManager` lives in the app
    /// target and this file also compiles into the notification-service extension.
    /// The CALLER owns the gate, so this stays a no-op in production without a
    /// `#if DEBUG` that a release smoke test would strip.
    private let log: (@Sendable (String) -> Void)?

    init(ownerKey: ContentKey, log: (@Sendable (String) -> Void)? = nil) {
        self.ownerKey = ownerKey
        self.log = log
        super.init()
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else {
            fail(urlSchemeTask, assetId: nil, refusal: .missingURL)
            return
        }
        guard let assetId = BodyAssetServePolicy.canonicalAssetId(from: url) else {
            fail(urlSchemeTask, assetId: nil, refusal: .malformedURL)
            return
        }
        let row = BodyAssetStore.assetManifestRow(assetId: assetId)
        let contentType: String
        switch BodyAssetServePolicy.authorize(row: row, ownerKey: ownerKey) {
        case .refuse(let refusal):
            // The MIME decision is reported with the type it rejected — the owner
            // requirement is that every MIME decision says which type it saw, and a
            // refusal with no type is undiagnosable from the log alone.
            let detail: String
            if refusal == .disallowedMIME, let row {
                detail = " type=\(BodyAssetServePolicy.loggableMIMEType(row.contentType))"
            } else {
                detail = ""
            }
            fail(urlSchemeTask, assetId: assetId, refusal: refusal, detail: detail)
            return
        case .serve(let allowed):
            contentType = allowed
        }
        guard let data = BodyAssetStore.read(assetId: assetId) else {
            fail(urlSchemeTask, assetId: assetId, refusal: .missingFile)
            return
        }
        guard let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Type": contentType,
                "Content-Length": "\(data.count)",
                "Cache-Control": "no-store",
                // The handler echoes bytes whose type was decided from an
                // attacker-influenced MIME header. `nosniff` stops WebKit from
                // re-deciding that type from the bytes themselves — defense in
                // depth behind the allowlist, NOT content validation.
                "X-Content-Type-Options": "nosniff",
            ]
        ) else {
            // Unreachable in practice (every field above is app-authored), but it is
            // a failure like any other and gets the same uniform wire result.
            fail(urlSchemeTask, assetId: assetId, refusal: .missingFile)
            return
        }
        log?("[AssetServe] \(logContext(assetId)) allowed type=\(contentType) bytes=\(data.count)")
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        // No-op: the start handler completes synchronously, so there's nothing to stop.
    }

    /// THE uniform failure. Every refusal reason funnels through here so malformed,
    /// unowned, wrong-kind, disallowed-MIME and missing-file are indistinguishable on
    /// the wire.
    ///
    /// Fails the task rather than serving an empty 200: a failed request still fires
    /// the DOM `error` event, so the view's load/error listeners settle, whereas an
    /// empty success looks like a completed transaction and hides authorization
    /// failures.
    private func fail(_ task: WKURLSchemeTask, assetId: String?, refusal: BodyAssetRefusal, detail: String = "") {
        log?("[AssetServe] \(logContext(assetId)) refused reason=\(refusal.rawValue)\(detail)")
        task.didFailWithError(URLError(.resourceUnavailable))
    }

    /// Truncated ids only. The asset id is hex and the owner key is
    /// `"<accountId>:<folderPath>:<tail>"` — enough of each to correlate a smoke-test
    /// log, not enough to reconstruct a mailbox path.
    private func logContext(_ assetId: String?) -> String {
        let asset = assetId.map { String($0.prefix(8)) + "…" } ?? "(unparsed)"
        let owner = String(ownerKey.rawValue.prefix(12)) + "…"
        return "asset=\(asset) owner=\(owner)"
    }
}
