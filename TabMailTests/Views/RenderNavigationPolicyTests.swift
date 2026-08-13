/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import WebKit
@testable import TabMail

// =====================================================================================
// P1c — the message-render navigation boundary, pinned at the decision level.
//
// THE INVARIANT THESE PIN: *no unapproved new main-frame document is admitted.*
// Not "the nonce is compared with ==", not "the permit field is nil afterwards" — the
// property is that the ONLY action which can bring in a new main-frame document is one
// that presents the unguessable per-load URL the app itself supplied.
//
// The end-to-end half lives in `EmailRenderSecurityCanaryTests` §12, where a real
// `<meta http-equiv="refresh">` is fired at the real `Coordinator` inside a real
// `WKWebView`. These tests exist because that harness cannot enumerate action shapes: the
// `Coordinator` is nested inside a `private struct` and is unreachable from a test, while
// the value types below take every shape P1a recorded, including the ones WebKit will not
// produce on demand.
// =====================================================================================

@Suite("P1c navigation permit — no unapproved main-frame document is admitted")
struct NavigationPermitStateTests {

    private func url(_ nonce: String = "0123456789abcdef0123456789abcdef") -> String {
        RenderDocumentURL.url(nonce: nonce).absoluteString
    }

    @Test("A legitimate app load is admitted, and consumes its permit at policy time")
    func legitimateAppLoadIsAdmitted() {
        var state = NavigationPermitState()
        let expected = url()
        state.arm(generation: 7, url: expected)

        let decision = state.evaluate(url: expected, navigationType: .other, isMainFrame: true)
        #expect(decision == .admit(DocumentLoadPermit(generation: 7, url: expected)))
        // Consumed AT POLICY TIME — not at commit. A failure after commit therefore
        // cannot leak it, and a replay of the same action cannot be admitted twice.
        #expect(state.pending == nil)
        #expect(state.evaluate(url: expected, navigationType: .other, isMainFrame: true)
                == .refuse(.noPendingPermit))
    }

    @Test("A .other main-frame action with the WRONG nonce is refused, and does NOT clear the live permit")
    func forgedOtherMainFrameActionIsRefused() {
        // The meta-refresh vector, in its abstract form: shape-identical to an app load
        // (.other + main frame) and only the URL differs.
        var state = NavigationPermitState()
        let expected = url("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
        state.arm(generation: 1, url: expected)

        let forged = "\(BodyAssetConfig.urlScheme)://asset/forged-target.html"
        #expect(state.evaluate(url: forged, navigationType: .other, isMainFrame: true)
                == .refuse(.urlMismatch))
        // An UNRELATED rejection must never clear a live permit, or an old/subframe/user
        // action cancels a legitimate app load that has not been decided yet.
        #expect(state.pending == DocumentLoadPermit(generation: 1, url: expected))
        // …and the real load that follows is still admitted.
        #expect(state.evaluate(url: expected, navigationType: .other, isMainFrame: true)
                == .admit(DocumentLoadPermit(generation: 1, url: expected)))
    }

    @Test("No armed permit refuses every action shape, and never mutates state")
    func withNoPermitEverythingIsRefused() {
        var state = NavigationPermitState()
        let shapes: [(String?, WKNavigationType, Bool)] = [
            (url(), .other, true),
            (url(), .linkActivated, true),
            ("https://example.com/", .other, true),
            ("https://example.com/", .backForward, true),
            (nil, .other, true),
            (url(), .other, false)
        ]
        for (u, type, main) in shapes {
            #expect(state.evaluate(url: u, navigationType: type, isMainFrame: main)
                    == .refuse(.noPendingPermit))
            #expect(state.pending == nil)
        }
    }

    @Test("The nonce URL on a subframe, or with the wrong navigation type, INVALIDATES the permit")
    func nonceURLThatFailsAnotherCheckInvalidates() {
        // C2: "a rejected action clears the permit ONLY IF it presented the expected nonce
        // URL and failed some other check". Both halves of "some other check" here.
        let expected = url("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")

        var subframe = NavigationPermitState()
        subframe.arm(generation: 3, url: expected)
        #expect(subframe.evaluate(url: expected, navigationType: .other, isMainFrame: false)
                == .refuseAndInvalidate(.notMainFrame))
        #expect(subframe.pending == nil)

        for type in [WKNavigationType.linkActivated, .formSubmitted, .backForward, .reload, .formResubmitted] {
            var state = NavigationPermitState()
            state.arm(generation: 3, url: expected)
            #expect(state.evaluate(url: expected, navigationType: type, isMainFrame: true)
                    == .refuseAndInvalidate(.notOtherNavigationType))
            #expect(state.pending == nil)
        }
    }

    @Test("A superseded load leaks no permit: only issuing the next one retires it")
    func supersededPermitIsRetiredByTheNextIssue() {
        // P1a measured that a superseded load receives NO callback at all — not even
        // didFailProvisionalNavigation. So a design that retired a permit on a failure
        // callback would leak permits forever; `arm` is the only retirement path.
        var state = NavigationPermitState()
        let a = url("cccccccccccccccccccccccccccccccc")
        let b = url("dddddddddddddddddddddddddddddddd")
        #expect(a != b)

        state.arm(generation: 10, url: a)
        let superseded = state.arm(generation: 11, url: b)
        #expect(superseded == DocumentLoadPermit(generation: 10, url: a),
                "arming the next load returns the permit it retired, so the caller can say so in the log")
        #expect(state.pending == DocumentLoadPermit(generation: 11, url: b))

        // The superseded load's own action, arriving late, is refused and leaves B armed.
        #expect(state.evaluate(url: a, navigationType: .other, isMainFrame: true) == .refuse(.urlMismatch))
        #expect(state.pending == DocumentLoadPermit(generation: 11, url: b))
        #expect(state.evaluate(url: b, navigationType: .other, isMainFrame: true)
                == .admit(DocumentLoadPermit(generation: 11, url: b)))
        // Exactly ONE document was admitted across two overlapping loads.
        #expect(state.pending == nil)
    }

    @Test("An action with no URL is refused without touching the permit")
    func missingURLIsRefusedWithoutClearing() {
        var state = NavigationPermitState()
        let expected = url()
        state.arm(generation: 2, url: expected)
        #expect(state.evaluate(url: nil, navigationType: .other, isMainFrame: true)
                == .refuse(.missingURL))
        #expect(state.pending == DocumentLoadPermit(generation: 2, url: expected))
    }

    @Test("invalidate() drops the permit and reports what it dropped; a second call is a no-op")
    func invalidateIsIdempotent() {
        var state = NavigationPermitState()
        let expected = url()
        state.arm(generation: 5, url: expected)
        #expect(state.invalidate() == DocumentLoadPermit(generation: 5, url: expected))
        #expect(state.pending == nil)
        #expect(state.invalidate() == nil)
    }

    @Test("Matching is EXACT string equality — never URL normalization")
    func matchingIsExactStringEquality() {
        // C1 is explicit: compare against the URL we supplied, never after URLComponents
        // normalization, because a disagreement between two parsers is the bug the nonce
        // exists to make impossible. Each variant below is the SAME URL to at least one
        // normalizer, and none of them may be admitted.
        let nonce = "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
        let expected = url(nonce)
        let variants = [
            String(expected.dropLast()),                                   // no trailing slash
            expected + "#",                                                // empty fragment
            expected.replacingOccurrences(of: "_tm-document", with: "_tm%2Ddocument"),
            expected.replacingOccurrences(of: "//asset/", with: "//ASSET/"),   // host case
            expected.uppercased(),
            expected + "?",                                                    // empty query
            expected.replacingOccurrences(of: "//asset/", with: "//asset:80/") // default-port form
        ]
        for variant in variants {
            var state = NavigationPermitState()
            state.arm(generation: 1, url: expected)
            #expect(state.evaluate(url: variant, navigationType: .other, isMainFrame: true)
                    == .refuse(.urlMismatch),
                    "a normalization-equivalent variant must NOT be admitted: \(variant)")
            #expect(state.pending != nil, "…and must not clear the permit either")
        }
        // Non-vacuity: the byte-exact URL IS admitted by the same state machine.
        var control = NavigationPermitState()
        control.arm(generation: 1, url: expected)
        #expect(control.evaluate(url: expected, navigationType: .other, isMainFrame: true)
                == .admit(DocumentLoadPermit(generation: 1, url: expected)))
    }
}

@Suite("P1c per-load document URL")
struct RenderDocumentURLTests {

    @Test("The nonce carries at least 128 bits, is lowercase hex, and never repeats")
    func nonceEntropy() {
        #expect(RenderDocumentURL.nonceBitCount >= 128)
        var seen = Set<String>()
        for _ in 0..<256 {
            let n = RenderDocumentURL.nonce()
            #expect(n.count == 32, "128 bits as lowercase hex")
            #expect(n.allSatisfy { $0.isHexDigit && !$0.isUppercase })
            seen.insert(n)
        }
        #expect(seen.count == 256, "every load gets a fresh nonce")
    }

    @Test("The nonce lives in the PATH — origin unchanged, no fragment, no query")
    func nonceLivesInThePath() {
        let n = RenderDocumentURL.nonce()
        let u = RenderDocumentURL.url(nonce: n)
        #expect(u.scheme == BodyAssetConfig.urlScheme)
        #expect(u.host() == "asset", "scheme+host is the origin, and it must not move with the nonce")
        #expect(u.fragment == nil,
                "a .linkActivated action carries the full URL INCLUDING the fragment, so a fragment-borne nonce would leak into every link the user taps")
        #expect(u.query == nil)
        #expect(u.path.contains("/\(RenderDocumentURL.pathPrefix)/\(n)"))
        #expect(u.absoluteString.hasSuffix("/"))
        // The document URL must never be mistakable for an asset URL.
        #expect(BodyAssetStore.assetId(fromURL: u) == nil,
                "the synthetic document URL parses as no asset id at all")
    }

    @Test("Only the nonce PREFIX is ever loggable")
    func onlyThePrefixIsLoggable() {
        let n = "0123456789abcdef0123456789abcdef"
        #expect(RenderDocumentURL.logPrefix(n) == "01234567…")
        #expect(!RenderDocumentURL.logPrefix(n).contains(String(n.suffix(8))))
        #expect(RenderDocumentURL.logPrefix(forDocumentURL: RenderDocumentURL.url(nonce: n).absoluteString)
                == "01234567…")
        #expect(RenderDocumentURL.logPrefix(forDocumentURL: "https://example.com/") == "?")
    }

    @Test("Path-relative asset refs move under the nonce base but their OUTCOME cannot change")
    func relativeRefsAreUnresolvableUnderBothBases() {
        // The plan's HARD STOP: relative refs DO resolve differently under the nonce base.
        // What matters is whether any of them changes OUTCOME, and none can:
        // `assetId(fromURL:)` requires the host to be exactly `hashHexLength` characters,
        // and the document host is the 5-character literal `asset` under BOTH bases.
        let scheme = BodyAssetConfig.urlScheme
        let n = RenderDocumentURL.nonce()
        let underPlainBase = URL(string: "\(scheme)://asset/relative-probe.gif")!
        let underNonceBase = URL(string: "\(scheme)://asset/\(RenderDocumentURL.pathPrefix)/\(n)/relative-probe.gif")!
        #expect(underPlainBase.absoluteString != underNonceBase.absoluteString,
                "the ref really does move — this test is about the outcome, not the string")
        #expect(BodyAssetStore.assetId(fromURL: underPlainBase) == nil)
        #expect(BodyAssetStore.assetId(fromURL: underNonceBase) == nil)

        // NON-VACUITY, the other side: a well-formed ABSOLUTE asset URL — the shape
        // `BodyRenderer` bakes into persisted HTML — parses under both bases, unchanged,
        // because an absolute ref ignores the document path entirely.
        let host = String(repeating: "a", count: BodyAssetStore.hashHexLength)
        let asset = String(repeating: "b", count: BodyAssetStore.hashHexLength)
        let absolute = URL(string: "\(scheme)://\(host)/\(asset)")!
        #expect(BodyAssetStore.assetId(fromURL: absolute) == "\(host)/\(asset)")
    }
}

@Suite("P1c external link dispatch — http/https allowlist before UIApplication.shared.open")
struct RenderLinkPolicyTests {

    private let documentURL = RenderDocumentURL.url(nonce: "0123456789abcdef0123456789abcdef").absoluteString

    @Test("An in-document fragment is handled internally and never reaches the system opener")
    func inDocumentFragmentIsNotOpened() {
        // P1a demonstrated on shipped code that a `tabmail-asset://asset/#target` URL
        // reaches UIApplication.shared.open, because every .linkActivated was cancelled
        // and handed to the opener. Both halves are fixed here.
        let url = URL(string: documentURL + "#target")!
        #expect(RenderLinkPolicy.dispatch(for: url, documentURL: documentURL) == .sameDocumentFragment)
    }

    @Test("A fragment on a DIFFERENT document is not treated as same-document")
    func fragmentOnAnotherDocumentIsNotSameDocument() {
        // The branch is anchored to the URL WE supplied, not to "the URL has a #".
        #expect(RenderLinkPolicy.dispatch(for: URL(string: "https://example.com/#target")!,
                                          documentURL: documentURL) == .openExternally)
        let otherDoc = RenderDocumentURL.url(nonce: "ffffffffffffffffffffffffffffffff").absoluteString
        #expect(RenderLinkPolicy.dispatch(for: URL(string: otherDoc + "#target")!,
                                          documentURL: documentURL) == .refuse(.nonWebScheme))
        // With no document loaded there is nothing to be "inside", so it fails closed.
        #expect(RenderLinkPolicy.dispatch(for: URL(string: documentURL + "#target")!,
                                          documentURL: nil) == .refuse(.nonWebScheme))
    }

    @Test("http and https with a host are opened; the scheme test is ASCII-case-insensitive")
    func webSchemesAreOpened() {
        for raw in ["https://example.com/path?q=1",
                    "http://example.com/",
                    "HTTPS://EXAMPLE.COM/",
                    "HtTp://sub.domain.com/x#y"] {
            #expect(RenderLinkPolicy.dispatch(for: URL(string: raw)!, documentURL: documentURL)
                    == .openExternally, "\(raw) must be dispatched to the system opener")
        }
    }

    @Test("Every non-web scheme is refused, including the one P1a proved reaches open() today")
    func nonWebSchemesAreRefused() {
        for raw in ["\(BodyAssetConfig.urlScheme)://asset/#target",
                    "\(BodyAssetConfig.urlScheme)://asset/forged.html",
                    "tel:+15550100",
                    "sms:+15550100",
                    "facetime:someone@example.com",
                    "itms-apps://apps.example.com/app/id1",
                    "file:///etc/passwd",
                    "data:text/html;base64,PGI+aGk8L2I+",
                    "javascript:alert(1)",
                    "ftp://example.com/x",
                    "customapp://open?token=abc"] {
            guard let url = URL(string: raw) else {
                #expect(Bool(false), "fixture is not a URL: \(raw)"); continue
            }
            #expect(RenderLinkPolicy.dispatch(for: url, documentURL: documentURL)
                    == .refuse(.nonWebScheme), "\(raw) must NOT reach UIApplication.shared.open")
        }
    }

    @Test("An http/https URL with no host is refused")
    func webSchemeWithoutHostIsRefused() {
        for raw in ["https:", "http:", "https:relative/path"] {
            guard let url = URL(string: raw) else {
                #expect(Bool(false), "fixture is not a URL: \(raw)"); continue
            }
            #expect(RenderLinkPolicy.dispatch(for: url, documentURL: documentURL)
                    == .refuse(.emptyHost), "\(raw) has no host to open")
        }
    }

    @Test("Only the scheme is loggable, lowercased and bounded")
    func loggableSchemeIsBounded() {
        #expect(RenderLinkPolicy.loggableScheme(URL(string: "HTTPS://example.com/")!) == "https")
        #expect(RenderLinkPolicy.loggableScheme(URL(string: "tel:+15550100")!) == "tel")
        let long = "a" + String(repeating: "b", count: 200)
        #expect(RenderLinkPolicy.loggableScheme(URL(string: "\(long)://x/")!).count <= 24)
    }
}

@Suite("P1c bridge input validation — every bridge channel")
struct RenderBridgeInputTests {

    @Test("A well-formed height payload survives validation unchanged")
    func wellFormedHeightsAreAccepted() {
        #expect(RenderBridgeInput.validatedHeightBody(NSNumber(value: 812)) != nil)
        #expect(RenderBridgeInput.validatedHeightBody(NSNumber(value: 0)) != nil)
        let dict: [String: Any] = ["h": 4349, "vp": 390, "scroll": 4349, "rect": 4349, "source": "RO"]
        guard let validated = RenderBridgeInput.validatedHeightBody(dict) as? [String: Any] else {
            #expect(Bool(false), "a normal ResizeObserver payload must be accepted"); return
        }
        #expect((validated["h"] as? NSNumber)?.doubleValue == 4349)
        #expect(validated["source"] as? String == "RO")
        for flag in ["revealed", "requestFit", "requestWidthRefit"] {
            #expect(RenderBridgeInput.validatedHeightBody([flag: true]) != nil)
        }
    }

    @Test("Non-finite, negative and non-numeric heights are dropped — fail closed")
    func hostileHeightsAreRejected() {
        let hostile: [Any] = [
            NSNumber(value: Double.nan),
            NSNumber(value: Double.infinity),
            NSNumber(value: -1),
            ["h": Double.nan],
            ["h": Double.infinity],
            ["h": -5],
            ["h": "tall"],
            ["vp": Double.nan],
            ["scroll": -1],
            ["rect": Double.infinity],
            ["revealed": "yes"],
            ["requestFit": "1"],
            ["requestWidthRefit": ["nested": true]],
            ["source": 5],
            "a bare string",
            [1, 2, 3]
        ]
        for body in hostile {
            #expect(RenderBridgeInput.validatedHeightBody(body) == nil,
                    "a malformed heightChanged payload must be dropped, not coerced")
        }
    }

    @Test("There is deliberately NO upper height bound — a long newsletter is not truncated")
    func thereIsNoArbitraryHeightCeiling() {
        // ADR-IOS-076 decision 7: an arbitrary height ceiling was specified during the vet
        // and then REJECTED. Pinned so a future "clamp it to something sane" does not
        // silently truncate a legitimately long message.
        #expect(RenderBridgeInput.validatedHeightBody(["h": 250_000, "vp": 390]) != nil)
        #expect(RenderBridgeInput.validatedHeightBody(NSNumber(value: 1_000_000)) != nil)
    }

    @Test("A source tag is bounded and control characters are escaped before it reaches a log line")
    func sourceTagIsBoundedAndEscaped() {
        let forged = "RO\n[MeasureHeight id=AAAAAA] h=1 forged line"
        guard let validated = RenderBridgeInput.validatedHeightBody(["h": 10, "source": forged]) as? [String: Any],
              let source = validated["source"] as? String else {
            #expect(Bool(false), "the payload is well-formed apart from the tag"); return
        }
        #expect(!source.contains("\n"), "print is a LINE-oriented sink; a raw newline forges a second diagnostic")
        #expect(source.contains("\\u000a"))

        let long = String(repeating: "x", count: 5000)
        guard let bounded = RenderBridgeInput.validatedHeightBody(["h": 10, "source": long]) as? [String: Any],
              let boundedSource = bounded["source"] as? String else {
            #expect(Bool(false), "a long tag is bounded, not rejected"); return
        }
        #expect(boundedSource.count == RenderBridgeInput.maxSourceLength)
    }

    @Test("Gutter padding is clamped to [0, 16] in Swift, whatever the page posts")
    func gutterIsClampedInSwift() {
        let cases: [(Any, CGFloat, CGFloat)] = [
            (["l": 8, "r": 8], 8, 8),
            (["l": 0, "r": 16], 0, 16),
            (["l": 1_000_000_000, "r": 99], 16, 16),
            (["l": -5, "r": -1_000], 0, 0),
            (["l": 16.4, "r": 15.6], 16, 15.6)
        ]
        for (body, expectedLeading, expectedTrailing) in cases {
            guard let padding = RenderBridgeInput.gutterPadding(body, leading: 16, trailing: 16) else {
                #expect(Bool(false), "well-formed gutter payload rejected"); continue
            }
            #expect(padding.leading == expectedLeading)
            #expect(padding.trailing == expectedTrailing)
        }
        // A missing side keeps the CURRENT value — the shipped behaviour.
        guard let onlyLeading = RenderBridgeInput.gutterPadding(["l": 4], leading: 16, trailing: 11) else {
            #expect(Bool(false), "a one-sided payload is legal"); return
        }
        #expect(onlyLeading.leading == 4)
        #expect(onlyLeading.trailing == 11)
    }

    @Test("A malformed gutter payload is dropped whole — never applied by halves")
    func malformedGutterIsDropped() {
        let hostile: [Any] = [
            ["l": "8"],
            ["r": Double.nan],
            ["l": 8, "r": Double.infinity],
            ["l": ["nested": 1]],
            "not a dictionary",
            NSNumber(value: 8)
        ]
        for body in hostile {
            #expect(RenderBridgeInput.gutterPadding(body, leading: 16, trailing: 16) == nil,
                    "half-applying a gutter payload would leave a lopsided, sender-aimed layout")
        }
    }

    @Test("Console lines are string-typed, escaped and bounded")
    func consoleLinesAreBoundedAndEscaped() {
        #expect(RenderBridgeInput.consoleLine("[HTMLDebug] ordinary line") == "[HTMLDebug] ordinary line")
        #expect(RenderBridgeInput.consoleLine("a\nb") == "a\\u000ab")
        #expect(RenderBridgeInput.consoleLine("a\u{2028}b") == "a\\u2028b")
        #expect(RenderBridgeInput.consoleLine(NSNumber(value: 1)) == nil)
        #expect(RenderBridgeInput.consoleLine(["x": 1]) == nil)

        let overflowing = String(repeating: "z", count: RenderBridgeInput.maxConsoleLineLength + 37)
        guard let bounded = RenderBridgeInput.consoleLine(overflowing) else {
            #expect(Bool(false), "an over-long line is bounded, not dropped"); return
        }
        #expect(bounded.hasPrefix(String(repeating: "z", count: RenderBridgeInput.maxConsoleLineLength)))
        #expect(bounded.hasSuffix("…[+37 chars truncated]"))
    }

    // ── P4: the `imageLoadFailure` channel.
    //
    // The counts this channel carries reach a sentence shown to the user about the
    // sender's own server, so the validation is the same fail-closed shape as the
    // other three: a malformed payload is DROPPED WHOLE, never coerced, never
    // half-applied. There is no "clamp it to something plausible" branch — a count
    // we cannot trust is a banner we do not raise.

    @Test("A well-formed image-failure census survives validation unchanged")
    func wellFormedImageFailureCensusIsAccepted() {
        guard let some = RenderBridgeInput.imageFailureReport(["failed": 2, "deferred": 5]) else {
            #expect(Bool(false), "an ordinary census must be accepted"); return
        }
        #expect(some.failed == 2)
        #expect(some.deferred == 5)

        // The overwhelmingly common report: images were deferred, none failed.
        // It must be ACCEPTED (and then raise no banner) rather than rejected —
        // a drop here and a zero here are indistinguishable to the user but not
        // to a reader of the bridge log.
        guard let none = RenderBridgeInput.imageFailureReport(["failed": 0, "deferred": 5]) else {
            #expect(Bool(false), "zero failures is a legitimate census, not a malformed one"); return
        }
        #expect(none.failed == 0)

        // Both boundaries: everything failed, and the ceiling itself.
        #expect(RenderBridgeInput.imageFailureReport(["failed": 5, "deferred": 5]) != nil)
        let ceiling = RenderBridgeInput.maxReportedImageCount
        #expect(RenderBridgeInput.imageFailureReport(["failed": ceiling, "deferred": ceiling]) != nil)
    }

    @Test("A census that could not have happened is dropped — fail closed")
    func hostileImageFailureCensusIsRejected() {
        let hostile: [Any] = [
            // Not a dictionary at all.
            NSNumber(value: 3),
            "3 failed",
            [1, 2],
            // Either half missing — a one-sided census has no meaning, and
            // defaulting the absent side would make the count sender-aimable.
            ["failed": 1],
            ["deferred": 4],
            [:] as [String: Any],
            // Wrong type.
            ["failed": "1", "deferred": 4],
            ["failed": 1, "deferred": "4"],
            ["failed": ["nested": 1], "deferred": 4],
            // Outside the representable range.
            ["failed": -1, "deferred": 4],
            ["failed": 1, "deferred": -4],
            ["failed": Double.nan, "deferred": 4],
            ["failed": 1, "deferred": Double.infinity],
            // Fractional — a COUNT is an integer; a fraction means the page is
            // not the script we shipped.
            ["failed": 1.5, "deferred": 4],
            ["failed": 1, "deferred": 4.25],
            // Past the ceiling.
            ["failed": 1, "deferred": RenderBridgeInput.maxReportedImageCount + 1],
            ["failed": RenderBridgeInput.maxReportedImageCount + 1,
             "deferred": RenderBridgeInput.maxReportedImageCount + 1]
        ]
        for body in hostile {
            #expect(RenderBridgeInput.imageFailureReport(body) == nil,
                    "a malformed imageLoadFailure payload must be dropped, not coerced")
        }
    }

    @Test("More failures than deferred images is impossible — and rejected, not clamped")
    func moreFailuresThanDeferredIsRejected() {
        // `failed` counts a SUBSET of the deferred images (the arming loop only
        // increments it for an `img` carrying `data-tmsrc`/`data-tmsrcset`), so
        // failed > deferred cannot arise from the shipped script. Rejecting it
        // rather than clamping keeps the internal-consistency check meaningful:
        // clamping would silently accept a nonsense payload as a real failure and
        // raise the banner on it.
        #expect(RenderBridgeInput.imageFailureReport(["failed": 6, "deferred": 5]) == nil)
        #expect(RenderBridgeInput.imageFailureReport(["failed": 1, "deferred": 0]) == nil)
        // The adjacent legal case, so the check is not passing for the wrong reason.
        #expect(RenderBridgeInput.imageFailureReport(["failed": 0, "deferred": 0]) != nil)
    }
}

// =====================================================================================
// P1d — the bridge-liveness beacon.
//
// THE INVARIANT: *every committed load emits exactly one bridge verdict.*
//
// Pinned at the sequence level, not at the text of the log line. The device evidence
// that forced this (`KH4CLK`, 2026-08-12) is a load that COMMITTED, ran its user scripts,
// never FINISHED, and therefore reported nothing at all — an alarm whose absence was
// indistinguishable from the alarm not existing.
// =====================================================================================

@Suite("P1d bridge-liveness beacon — every committed load emits exactly one verdict")
struct BridgeLivenessBeaconTests {

    /// Drives the real arm/settle sequence and returns every verdict a load produced.
    private func verdicts(
        commits: [Int],
        currentGeneration: Int,
        lastBridgeMessageGeneration: Int?
    ) -> [BridgeLivenessVerdict] {
        var beacon = BridgeLivenessBeacon()
        var out: [BridgeLivenessVerdict] = []
        for generation in commits where beacon.arm(generation: generation) {
            if let v = BridgeLivenessBeacon.settle(
                generation: generation,
                currentGeneration: currentGeneration,
                lastBridgeMessageGeneration: lastBridgeMessageGeneration
            ) { out.append(v) }
        }
        return out
    }

    @Test("A load that COMMITS but never FINISHES still reports — the KH4CLK blind spot")
    func aCommittedButNeverFinishedLoadStillReports() {
        // The whole sequence for this load is: didCommit, then nothing. `didFinish` is
        // never called — KH4CLK's images never settled — so a verdict armed there would
        // never fire. Armed at commit, it does.
        let out = verdicts(commits: [1], currentGeneration: 1, lastBridgeMessageGeneration: 1)
        #expect(out == [.live],
                "KH4CLK's user scripts provably ran ([ImageLoadDiag id=KH4CLK +1ms] inventory images=5, the line right after its didCommit), so the verdict for a committed-but-unfinished load is LIVE — and there must BE one")
    }

    @Test("Silence is reported, not omitted")
    func silenceIsReported() {
        let out = verdicts(commits: [4], currentGeneration: 4, lastBridgeMessageGeneration: nil)
        #expect(out == [.silent],
                "SILENT is the designated alarm for the catastrophic-quiet failure mode; it must be a sentence, not an absence")
        // A bridge message from an OLDER load proves nothing about this one.
        let stale = verdicts(commits: [4], currentGeneration: 4, lastBridgeMessageGeneration: 3)
        #expect(stale == [.silent])
    }

    @Test("EXACTLY one — a second commit for the same load cannot produce a second verdict")
    func exactlyOneVerdictPerLoad() {
        // This is the structural half of the invariant: it must be impossible to double-
        // report, including via a future edit that re-adds an arm from `didFinish`.
        let out = verdicts(commits: [9, 9, 9], currentGeneration: 9, lastBridgeMessageGeneration: 9)
        #expect(out == [.live], "three arms of one generation, one verdict")

        var beacon = BridgeLivenessBeacon()
        #expect(beacon.arm(generation: 2) == true)
        #expect(beacon.arm(generation: 2) == false, "re-arming the same generation is refused")
        #expect(beacon.arm(generation: 3) == true, "a genuinely new load arms again")
    }

    @Test("Two distinct committed loads each get their own verdict")
    func twoLoadsTwoVerdicts() {
        var beacon = BridgeLivenessBeacon()
        #expect(beacon.arm(generation: 1) == true)
        #expect(BridgeLivenessBeacon.settle(generation: 1, currentGeneration: 1,
                                            lastBridgeMessageGeneration: 1) == .live)
        #expect(beacon.arm(generation: 2) == true)
        #expect(BridgeLivenessBeacon.settle(generation: 2, currentGeneration: 2,
                                            lastBridgeMessageGeneration: nil) == .silent)
    }

    @Test("A SUPERSEDED load is silent about itself — the one documented exception")
    func aSupersededLoadReportsNothing() {
        // Stated with its exception so the invariant is not overstated (MIS-019 shape):
        // a superseded load's verdict would describe a document that is no longer on
        // screen, and supersession is separately logged (`issued gen=…` / `superseded
        // gen=…`), so its silence is explained rather than mysterious. Pre-existing
        // behaviour; P1d re-sequenced the arm and deliberately did not change this.
        #expect(BridgeLivenessBeacon.settle(generation: 5, currentGeneration: 6,
                                            lastBridgeMessageGeneration: 5) == nil)
        #expect(BridgeLivenessBeacon.settle(generation: 5, currentGeneration: 6,
                                            lastBridgeMessageGeneration: nil) == nil)
    }
}
