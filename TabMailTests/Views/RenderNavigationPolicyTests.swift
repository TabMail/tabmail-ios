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
        for flag in ["revealed", "requestFit", "requestWidthRefit", "userDisclosure"] {
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
            ["userDisclosure": "yes"],
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
    // The counts this channel carries are diagnostic-only. Validation retains the
    // same fail-closed shape as the
    // other three: a malformed payload is DROPPED WHOLE, never coerced, never
    // half-applied. There is no "clamp it to something plausible" branch — a count
    // we cannot trust is a diagnostic we do not print.

    @Test("A well-formed image-failure census survives validation unchanged")
    func wellFormedImageFailureCensusIsAccepted() {
        guard let some = RenderBridgeInput.imageFailureReport(["failed": 2, "deferred": 5]) else {
            #expect(Bool(false), "an ordinary census must be accepted"); return
        }
        #expect(some.failed == 2)
        #expect(some.deferred == 5)

        // The overwhelmingly common report: images were deferred, none failed.
        // It must be ACCEPTED rather than rejected — a drop and a true zero are
        // distinguishable to a reader of the bridge log.
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
             "deferred": RenderBridgeInput.maxReportedImageCount + 1],
            // A JS BOOLEAN. Bridges as `__NSCFBoolean`, which IS an `NSNumber`,
            // so `as? NSNumber` admits it and `doubleValue` reports a clean
            // 1 / 0 — finite, non-negative, integral, under the ceiling, and
            // `failed <= deferred`. Every bound this list tests is satisfied;
            // only the TYPE is wrong. Omitted from this census until both audit
            // legs found it independently on 2026-08-13.
            ["failed": true, "deferred": true],
            ["failed": false, "deferred": false],
            ["failed": true, "deferred": 4],
            ["failed": 1, "deferred": true]
        ]
        for body in hostile {
            #expect(RenderBridgeInput.imageFailureReport(body) == nil,
                    "a malformed imageLoadFailure payload must be dropped, not coerced")
        }
    }

    @Test("A JS boolean is not a number — no bridge validator admits one as a quantity")
    func booleansAreNeverAdmittedAsNumericQuantities() {
        // THE INVARIANT: a bridge payload field that must carry a NUMBER rejects a
        // JS boolean. Stated over the whole bridge surface on purpose — this was
        // reported against `imageFailureReport` alone, but the defect is the CAST,
        // and the same cast validates heights and gutter insets, so fixing only the
        // reported instance would leave the class live (A7).
        //
        // Why it is not obvious: `true` crosses WebKit's bridge as `__NSCFBoolean`,
        // an `NSNumber` subclass. `as? NSNumber` succeeds, `doubleValue` is 1.0,
        // and every range/finiteness/integrality check downstream passes. Nothing
        // reads as wrong at any single guard; the type is simply never checked.
        //
        // Deliberately NOT written as "the implementation calls CFBooleanGetTypeID"
        // — that would pin the fix's mechanism and stay green if a later refactor
        // kept the call but changed what it gates.

        // 1. The image census — the reported instance. Diagnostic-only today.
        #expect(RenderBridgeInput.imageFailureReport(["failed": true, "deferred": true]) == nil,
                "a boolean census must not falsify the image-failure diagnostic")

        // 2. Heights — a bare boolean body, and a boolean under each numeric key.
        #expect(RenderBridgeInput.validatedHeightBody(true) == nil,
                "a bare boolean must not be accepted as a height")
        for key in ["h", "vp", "scroll", "rect"] {
            #expect(RenderBridgeInput.validatedHeightBody([key: true]) == nil,
                    "a boolean under numeric key \(key) must drop the whole payload")
        }

        // 3. Gutter insets — a boolean must drop the message, never resolve to 1pt.
        #expect(RenderBridgeInput.gutterPadding(["l": true], leading: 16, trailing: 16) == nil,
                "a boolean leading inset must drop the payload, not clamp to 1pt")
        #expect(RenderBridgeInput.gutterPadding(["r": true], leading: 16, trailing: 16) == nil,
                "a boolean trailing inset must drop the payload, not clamp to 1pt")

        // 4. THE OTHER SIDE, so this cannot be satisfied by rejecting everything:
        //    real numbers still pass, and the keys that are SUPPOSED to be boolean
        //    still accept booleans. A fix that hardened the numeric cast by
        //    banning `Bool` everywhere would break the flag keys, and that break
        //    would be invisible without this half.
        guard let census = RenderBridgeInput.imageFailureReport(["failed": 2, "deferred": 5]) else {
            #expect(Bool(false), "a well-formed census must still be accepted"); return
        }
        #expect(census.failed == 2)
        #expect(census.deferred == 5)
        #expect(RenderBridgeInput.validatedHeightBody(["h": 812]) != nil,
                "a real height must still be accepted")
        #expect(RenderBridgeInput.gutterPadding(["l": 4], leading: 16, trailing: 16) != nil,
                "a real gutter inset must still be accepted")
        for flag in ["revealed", "requestFit", "requestWidthRefit", "userDisclosure"] {
            #expect(RenderBridgeInput.validatedHeightBody([flag: true]) != nil,
                    "flag key \(flag) is SUPPOSED to be boolean and must still be accepted")
        }
    }

    @Test("More failures than deferred images is impossible — and rejected, not clamped")
    func moreFailuresThanDeferredIsRejected() {
        // `failed` counts a SUBSET of the deferred images (the arming loop only
        // increments it for an `img` carrying `data-tmsrc`/`data-tmsrcset`), so
        // failed > deferred cannot arise from the shipped script. Rejecting it
        // rather than clamping keeps the internal-consistency check meaningful:
        // clamping would silently accept a nonsense payload as a real diagnostic.
        #expect(RenderBridgeInput.imageFailureReport(["failed": 6, "deferred": 5]) == nil)
        #expect(RenderBridgeInput.imageFailureReport(["failed": 1, "deferred": 0]) == nil)
        // The adjacent legal case, so the check is not passing for the wrong reason.
        #expect(RenderBridgeInput.imageFailureReport(["failed": 0, "deferred": 0]) != nil)
    }
}

// =====================================================================================
// P1d — the bridge-liveness beacon.
//
// THE INVARIANT: *every committed load emits exactly one bridge verdict, and that verdict
// is a statement about the document that committed.*
//
// Pinned at the sequence level, not at the text of the log line. The device evidence
// that forced this (`KH4CLK`, 2026-08-12) is a load that COMMITTED, ran its user scripts,
// never FINISHED, and therefore reported nothing at all — an alarm whose absence was
// indistinguishable from the alarm not existing.
//
// The second half of the invariant is the 2026-08-13 finding: a `WKScriptMessage` carries
// no document identity, so evidence keyed on the ISSUED generation let the OUTGOING
// document's late timers vouch for the INCOMING one. That direction is the expensive one —
// it makes the alarm fail OPEN — so these drive the beacon against a real
// `CommittedDocumentGate` rather than handing it generations directly.
// =====================================================================================

@Suite("P1d bridge-liveness beacon — every committed load emits exactly one verdict")
struct BridgeLivenessBeaconTests {

    /// One load's production sequence: `wrapAndLoad` hands it to WebKit, `didCommit`
    /// promotes it. Spelled out as two events because running them together is the bug
    /// `CommittedDocumentGate` exists to prevent.
    private func issueAndCommit(_ gate: inout CommittedDocumentGate, generation: Int) {
        gate.issue(generation: generation)
        gate.commit(isIssuedLoad: true)
    }

    /// Drives the real arm/settle sequence and returns every verdict a load produced.
    ///
    /// `bridgeMessageDuring` is the generation that was the COMMITTED document when a
    /// bridge message arrived (`nil` = none ever did); `settlesUnder` is the document
    /// committed by the time the grace periods expire.
    private func verdicts(
        commits: [Int],
        bridgeMessageDuring: Int?,
        settlesUnder: Int
    ) -> [BridgeLivenessVerdict] {
        var gate = CommittedDocumentGate()
        var beacon = BridgeLivenessBeacon()
        var armed: [Int] = []
        for generation in commits {
            issueAndCommit(&gate, generation: generation)
            if let armedGeneration = beacon.arm(in: gate) { armed.append(armedGeneration) }
            if bridgeMessageDuring == generation { beacon.recordBridgeMessage(in: gate) }
        }
        if gate.committedGeneration != settlesUnder {
            issueAndCommit(&gate, generation: settlesUnder)
        }
        return armed.compactMap { beacon.settle(generation: $0, in: gate) }
    }

    @Test("A load that COMMITS but never FINISHES still reports — the KH4CLK blind spot")
    func aCommittedButNeverFinishedLoadStillReports() {
        // The whole sequence for this load is: didCommit, then nothing. `didFinish` is
        // never called — KH4CLK's images never settled — so a verdict armed there would
        // never fire. Armed at commit, it does.
        let out = verdicts(commits: [1], bridgeMessageDuring: 1, settlesUnder: 1)
        #expect(out == [.live],
                "KH4CLK's user scripts provably ran ([ImageLoadDiag id=KH4CLK +1ms] inventory images=5, the line right after its didCommit), so the verdict for a committed-but-unfinished load is LIVE — and there must BE one")
    }

    @Test("Silence is reported, not omitted")
    func silenceIsReported() {
        let out = verdicts(commits: [4], bridgeMessageDuring: nil, settlesUnder: 4)
        #expect(out == [.silent],
                "SILENT is the designated alarm for the catastrophic-quiet failure mode; it must be a sentence, not an absence")
        // A bridge message from an OLDER document proves nothing about this one.
        let stale = verdicts(commits: [3, 4], bridgeMessageDuring: 3, settlesUnder: 4)
        #expect(stale == [.silent])
    }

    @Test("A bridge message from the OUTGOING document must not report the INCOMING one as LIVE")
    func aSupersededDocumentsMessageDoesNotForgeLivenessForTheNextLoad() {
        // THE INVARIANT, and the direction that matters: an alarm may fail closed and may
        // not fail open. `Coordinator.userContentController(_:didReceive:)` records the
        // evidence for EVERY channel and BEFORE any dispatch, so it sits upstream of the
        // one-shot gate and the gate cannot shield it — the attribution has to be right
        // where it is written.
        var gate = CommittedDocumentGate()
        var beacon = BridgeLivenessBeacon()

        // Document A commits and is the document on screen.
        issueAndCommit(&gate, generation: 1)
        #expect(beacon.arm(in: gate) == 1)

        // A rebind calls `wrapAndLoad`, whose FIRST statement bumps `loadGeneration`; the
        // detached `EmailHTMLWrapper.wrapHTML` (100 ms–1 s+ of CPU) and WebKit's
        // provisional load all happen after it. A is still committed for all of it.
        gate.issue(generation: 2)

        // A's ResizeObserver / 60 ms settle timers fire inside that window and post.
        beacon.recordBridgeMessage(in: gate)

        // B commits. Its user scripts never execute — the catastrophic-quiet failure mode
        // this beacon is the designated alarm for.
        gate.commit(isIssuedLoad: true)
        #expect(beacon.arm(in: gate) == 2)

        #expect(beacon.settle(generation: 2, in: gate) == .silent,
                "document B ran zero JavaScript; document A's late message must not report it LIVE")

        // NON-VACUITY, the other side: once B's OWN scripts reach Swift it reads LIVE, so
        // this is not satisfied by a beacon that never says LIVE at all.
        beacon.recordBridgeMessage(in: gate)
        #expect(beacon.settle(generation: 2, in: gate) == .live)
    }

    @Test("Nothing on screen means nothing to vouch for — and no evidence is erased")
    func aMessageWithNoCommittedDocumentIsNotRecorded() {
        // After `invalidateNavigationState` (content-process death, server redirect) there
        // is no document a message could have come from. Recording one would attribute it
        // to whatever loads next; erasing the existing evidence would turn a LIVE document
        // silent. Neither happens.
        var gate = CommittedDocumentGate()
        var beacon = BridgeLivenessBeacon()
        issueAndCommit(&gate, generation: 1)
        beacon.recordBridgeMessage(in: gate)
        #expect(beacon.settle(generation: 1, in: gate) == .live)

        gate.invalidate()
        beacon.recordBridgeMessage(in: gate)

        // The recovery load commits; it has posted nothing of its own.
        issueAndCommit(&gate, generation: 2)
        #expect(beacon.settle(generation: 2, in: gate) == .silent,
                "a message received while nothing was committed must not vouch for the recovery load")
        // And there is no verdict at all while nothing is committed.
        var dead = CommittedDocumentGate()
        dead.issue(generation: 3)
        #expect(beacon.settle(generation: 3, in: dead) == nil)
    }

    @Test("EXACTLY one — a second commit for the same load cannot produce a second verdict")
    func exactlyOneVerdictPerLoad() {
        // This is the structural half of the invariant: it must be impossible to double-
        // report, including via a future edit that re-adds an arm from `didFinish`.
        let out = verdicts(commits: [9, 9, 9], bridgeMessageDuring: 9, settlesUnder: 9)
        #expect(out == [.live], "three arms of one generation, one verdict")

        var gate = CommittedDocumentGate()
        var beacon = BridgeLivenessBeacon()
        #expect(beacon.arm(in: gate) == nil, "nothing is committed, so there is nothing to arm")
        issueAndCommit(&gate, generation: 2)
        #expect(beacon.arm(in: gate) == 2)
        #expect(beacon.arm(in: gate) == nil, "re-arming the same committed document is refused")
        issueAndCommit(&gate, generation: 3)
        #expect(beacon.arm(in: gate) == 3, "a genuinely new document arms again")
    }

    @Test("Two distinct committed loads each get their own verdict")
    func twoLoadsTwoVerdicts() {
        var gate = CommittedDocumentGate()
        var beacon = BridgeLivenessBeacon()
        issueAndCommit(&gate, generation: 1)
        #expect(beacon.arm(in: gate) == 1)
        beacon.recordBridgeMessage(in: gate)
        #expect(beacon.settle(generation: 1, in: gate) == .live)

        issueAndCommit(&gate, generation: 2)
        #expect(beacon.arm(in: gate) == 2)
        #expect(beacon.settle(generation: 2, in: gate) == .silent)
    }

    @Test("A SUPERSEDED load is silent about itself — the one documented exception")
    func aSupersededLoadReportsNothing() {
        // Stated with its exception so the invariant is not overstated (MIS-019 shape):
        // a superseded load's verdict would describe a document that is no longer on
        // screen, and supersession is separately logged (`issued gen=…` / `superseded
        // gen=…`), so its silence is explained rather than mysterious. Pre-existing
        // behaviour; P1d re-sequenced the arm and deliberately did not change this.
        //
        // "Superseded" now means a newer document COMMITTED — replacing what is on
        // screen — rather than a newer load merely having been issued.
        var gate = CommittedDocumentGate()
        var spoke = BridgeLivenessBeacon()
        issueAndCommit(&gate, generation: 5)
        spoke.recordBridgeMessage(in: gate)
        issueAndCommit(&gate, generation: 6)
        // Load 5 had proven itself live, and still reports nothing once 6 replaced it.
        #expect(spoke.settle(generation: 5, in: gate) == nil)
        // …and so does a load that never posted at all: supersession outranks both verdicts.
        let quiet = BridgeLivenessBeacon()
        #expect(quiet.settle(generation: 5, in: gate) == nil)
    }
}

// =====================================================================================
// The committed-document gate — WHICH DOCUMENT a one-shot bridge request belongs to.
//
// THE INVARIANT THESE PIN, and it is two-sided:
//   • a one-shot request that arrives after the next load was ISSUED but before that
//     load COMMITTED is attributed to the OLD document — it spends the old document's
//     slot, not the new one's;
//   • and the new document, once committed, still gets its own request honoured.
//
// One direction alone is worthless here. A gate that refused everything would satisfy
// the first; a gate that honoured everything would satisfy the second; only the pair
// distinguishes "the right document" from "some document".
//
// Why the sequence rather than a field comparison: the defect and the fix differ ONLY in
// when a generation is adopted. `#expect(gate.committedGeneration == …)` would restate
// the mechanism and stay green through the bug, which is exactly the class of test
// (MIS-015) that let the P4 candidate ship with it.
// =====================================================================================

@Suite("Committed-document gate — a one-shot belongs to the document that committed")
struct CommittedDocumentGateTests {

    /// The production sequence for one load: `wrapAndLoad` hands it to WebKit, then
    /// `didCommit` promotes it. Kept as a helper so every test spells the two events out
    /// separately — running them together is the bug.
    private func issueAndCommit(_ gate: inout CommittedDocumentGate, generation: Int) {
        gate.issue(generation: generation)
        gate.commit(isIssuedLoad: true)
    }

    @Test("A late request from the OUTGOING document does not consume the INCOMING document's slot")
    func aLateRequestFromTheOldDocumentIsAttributedToIt() {
        // The measured window: `wrapAndLoad`'s FIRST statement bumps `loadGeneration`,
        // and only then does the detached `wrapHTML` (100 ms–1 s+ of CPU), the main-actor
        // hop and WebKit's provisional load happen. Document A is committed and posting
        // throughout, and `WKScriptMessage` carries no document identity.
        var gate = CommittedDocumentGate()
        issueAndCommit(&gate, generation: 1)                      // document A on screen
        #expect(gate.evaluate(.widthRefit) == .honour,
                "A's own request must be honoured — the gate is not merely a suppressor")

        // Document B is ISSUED. Note what does NOT happen: nothing commits, because the
        // wrap has not finished and WebKit has not replaced anything. A is still the
        // document on screen.
        gate.issue(generation: 2)

        // A's timers fire again inside that window. This is A's second request, so it is
        // refused as A's DUPLICATE — the fact that a newer generation exists is not
        // allowed to make it look like B's first.
        #expect(gate.evaluate(.widthRefit) == .refuse(.duplicate))

        // B commits and posts its own, genuine request.
        gate.commit(isIssuedLoad: true)
        #expect(gate.evaluate(.widthRefit) == .honour,
                "keyed on the ISSUED generation, A's late message spent B's slot and B rendered with the uncorrected horizontal overflow 758fac32f restored — recoverable only by rotating the device")
    }

    @Test("Every one-shot channel gets the same attribution, not just the one that hurt most")
    func everyOneShotIsAttributedToTheCommittedDocument() {
        // Enumerated from `CaseIterable` rather than listed, so a fourth channel added to
        // the gate is covered here the day it appears instead of the day someone
        // remembers to widen a hand-written list.
        for oneShot in RenderOneShot.allCases {
            var gate = CommittedDocumentGate()
            issueAndCommit(&gate, generation: 10)
            #expect(gate.evaluate(oneShot) == .honour, "\(oneShot.rawValue): document A's own request")
            gate.issue(generation: 11)
            #expect(gate.evaluate(oneShot) == .refuse(.duplicate), "\(oneShot.rawValue): A's late repeat")
            gate.commit(isIssuedLoad: true)
            #expect(gate.evaluate(oneShot) == .honour, "\(oneShot.rawValue): B's own request")
        }
    }

    @Test("The channels are independent — spending one does not spend the others")
    func theChannelsDoNotShareASlot() {
        // A message that both loses images AND needs a width re-fit must do both, which
        // is the same reason the JS census keeps its own `__tmImageFailureReported`
        // rather than inheriting `check()`'s guards.
        var gate = CommittedDocumentGate()
        issueAndCommit(&gate, generation: 3)
        #expect(gate.evaluate(.imageFailureReport) == .honour)
        #expect(gate.evaluate(.widthRefit) == .honour)
        #expect(gate.evaluate(.fit) == .honour)
        #expect(gate.evaluate(.imageFailureReport) == .refuse(.duplicate))
    }

    @Test("Nothing is honoured before a document commits, or after one is invalidated")
    func nothingIsHonouredWithoutACommittedDocument() {
        // Fail-closed, both at the start and after the content process died or a
        // redirect made the document not the one we admitted. Refusing costs at most a
        // timing detail — `didFinish` calls `fit()` directly regardless — while
        // honouring would attribute a dead document's message to whatever loads next.
        var gate = CommittedDocumentGate()
        #expect(gate.evaluate(.fit) == .refuse(.noCommittedDocument))

        // Issued but not yet committed: the provisional load has not replaced anything,
        // so there is still no document that could have posted this.
        gate.issue(generation: 1)
        #expect(gate.evaluate(.fit) == .refuse(.noCommittedDocument))

        gate.commit(isIssuedLoad: true)
        #expect(gate.evaluate(.fit) == .honour)

        gate.invalidate()
        #expect(gate.evaluate(.fit) == .refuse(.noCommittedDocument))
        #expect(gate.evaluate(.widthRefit) == .refuse(.noCommittedDocument))

        // And recovery works: the termination path invalidates and then loads again.
        issueAndCommit(&gate, generation: 2)
        #expect(gate.evaluate(.fit) == .honour, "the recovery load must not inherit the refusal")
    }

    @Test("A repeated didCommit for one navigation is idempotent; a load that never commits never promotes itself")
    func commitIsIdempotentAndNonCommittingLoadsNeverPromote() {
        var gate = CommittedDocumentGate()
        issueAndCommit(&gate, generation: 1)
        #expect(gate.evaluate(.fit) == .honour)
        // A second commit callback for the same navigation must not hand the document a
        // fresh slot — that would be a second one-shot publication for one document.
        gate.commit(isIssuedLoad: true)
        #expect(gate.evaluate(.fit) == .refuse(.duplicate))

        // A load that is issued and then fails provisionally (WebKit gives a superseded
        // load no callback at all) must leave the committed document exactly as it was.
        gate.issue(generation: 2)
        #expect(gate.evaluate(.widthRefit) == .honour, "still document 1's slot")
        #expect(gate.evaluate(.widthRefit) == .refuse(.duplicate),
                "and it was document 1 that spent it, so document 1 cannot spend it twice")
    }

    @Test("A SUPERSEDED commit callback does not consume the newer load's one-shot")
    func aSupersededCommitDoesNotConsumeTheNewerLoadsOneShot() {
        // THE INVARIANT: a `didCommit` that belongs to a load a newer `issue` has already
        // superseded must not adopt the newer generation. `Coordinator.webView(_:didCommit:)`
        // computed `isTracked(navigation)` for its log line and then committed
        // unconditionally, so document A's late commit callback labelled A with B's
        // identity — A spent B's `widthRefit` slot and B's own request was refused as a
        // duplicate, which is the user-visible defect this workstream exists to prevent
        // (`fitViewportJS`'s `__tmLayoutVp` guard blocks every other re-fit path, so B
        // renders with uncorrected horizontal overflow until the device is rotated).
        //
        // ADR-IOS-076 decision 4 already required this callback to be idempotent AND
        // identity-matched; the generation adoption was the one part that was neither.
        var gate = CommittedDocumentGate()
        issueAndCommit(&gate, generation: 1)                   // document A on screen

        // Load B is issued. `trackedNavigation` is now B's, so A's commit callback —
        // delivered late — is no longer the issued load.
        gate.issue(generation: 2)
        #expect(gate.commit(isIssuedLoad: false) == 1,
                "A's late commit reports the document that is actually on screen, not B")

        // A's own one-shot is still A's, and spending it must not touch B's.
        #expect(gate.evaluate(.widthRefit) == .honour, "still document A's slot")
        #expect(gate.evaluate(.widthRefit) == .refuse(.duplicate))

        // B commits for real and gets its OWN slot.
        #expect(gate.commit(isIssuedLoad: true) == 2)
        #expect(gate.evaluate(.widthRefit) == .honour,
                "B's genuine width re-fit request must be honoured — it was refused as a duplicate while A's superseded commit was allowed to adopt B's generation")
    }

    @Test("Every one-shot channel survives a superseded commit, and a refused commit changes nothing")
    func aSupersededCommitIsInertOnEveryChannel() {
        // The class, not the instance (A7): `widthRefit` is the arm with the visible cost,
        // but all three are attributed the same way.
        for oneShot in RenderOneShot.allCases {
            var gate = CommittedDocumentGate()
            issueAndCommit(&gate, generation: 4)
            #expect(gate.evaluate(oneShot) == .honour, "\(oneShot.rawValue): A's own request")
            gate.issue(generation: 5)
            gate.commit(isIssuedLoad: false)
            #expect(gate.evaluate(oneShot) == .refuse(.duplicate),
                    "\(oneShot.rawValue): a superseded commit must not hand A a fresh slot either")
            gate.commit(isIssuedLoad: true)
            #expect(gate.evaluate(oneShot) == .honour, "\(oneShot.rawValue): B's own request")
        }

        // A refused commit before anything has committed leaves the gate closed rather
        // than promoting the issued load — the fail-closed direction, and the negative
        // case that stops `isIssuedLoad: false` being read as "commit anyway".
        var fresh = CommittedDocumentGate()
        fresh.issue(generation: 1)
        #expect(fresh.commit(isIssuedLoad: false) == nil)
        #expect(fresh.evaluate(.fit) == .refuse(.noCommittedDocument))
    }

    @Test("Bridge diagnostics name the COMMITTED document while a newer load is only issued")
    func bridgeDiagnosticsUseTheCommittedGeneration() {
        var gate = CommittedDocumentGate()
        issueAndCommit(&gate, generation: 1)
        gate.issue(generation: 2)

        #expect(RenderBridgeDiagnostics.prefix(webViewId: "ABC123", gate: gate)
            == "[RenderBridge id=ABC123 committedGen=1]",
            "the outgoing document still owns bridge messages until generation 2 commits")

        gate.commit(isIssuedLoad: true)
        #expect(RenderBridgeDiagnostics.prefix(webViewId: "ABC123", gate: gate)
            == "[RenderBridge id=ABC123 committedGen=2]")
    }

    @Test("The nil-navigation fallback adopts only when there is no newer tracked identity")
    func nilNavigationFallbackPinsBothDirections() {
        #expect(NavigationCommitCorrelation.shouldAdoptIssuedGeneration(
            callbackMatchesTrackedNavigation: false,
            hasTrackedNavigation: false),
            "loadHTMLString returning nil leaves no identity to match; refusing would strand the real document")
        #expect(!NavigationCommitCorrelation.shouldAdoptIssuedGeneration(
            callbackMatchesTrackedNavigation: false,
            hasTrackedNavigation: true),
            "an unrelated callback must not adopt a newer tracked load's generation")
        #expect(NavigationCommitCorrelation.shouldAdoptIssuedGeneration(
            callbackMatchesTrackedNavigation: true,
            hasTrackedNavigation: true),
            "the ordinary identity-matched path must still adopt")
    }
}
