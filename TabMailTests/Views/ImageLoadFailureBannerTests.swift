/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import SwiftUI
@testable import TabMail

// =====================================================================================
// P4 — the image-failure banner's visibility decision (ADR-IOS-076).
//
// THE INVARIANT THESE PIN: *the banner appears if and only if at least one remote
// image of the document CURRENTLY on screen ended in `error` and the user has not
// dismissed it — and nothing about it survives a document change.*
//
// Both directions matter, and for different reasons. A missing banner costs the user
// an explanation. A SPURIOUS banner is worse: it is a claim about a stranger's mail
// server, shown over a message that rendered perfectly, and the user has no way to
// check it. So every test here carries its negative control.
//
// This is the state half. The census that feeds `failedCount` is pinned on the JS side
// by `EmailRenderPipelineTests`' "P4 image-failure census" block, and the payload
// validation by `RenderBridgeInputTests`.
//
// ⚠️ NOT the 2026-06-17 block-with-banner design (Memory/037 bullet 30), which blocked
// remote images and then explained itself, and was reverted for breaking layout. Nothing
// on this path alters which images load or when; the banner is observational, after the
// fact, and its only affordance is dismissal.
// =====================================================================================

@Suite("P4 image-failure banner — shown iff a remote image failed on THIS document")
struct ImageFailureBannerStateTests {

    @Test("A fresh document shows nothing — silence is the default, not the exception")
    func aFreshDocumentShowsNoBanner() {
        let fresh = ImageFailureBannerState()
        #expect(fresh.failedCount == 0)
        #expect(fresh.dismissed == false)
        #expect(fresh.isVisible == false,
                "the banner must not exist before the page has told us anything — every message would carry it")
    }

    @Test("A message whose images all load shows no banner")
    func everythingLoadingShowsNoBanner() {
        // The census still ARRIVES for this message — `postImageWidthRecheckJS`
        // reports once whenever anything was armed — it just reports zero. The
        // decision must key on the count, not on whether a report came in.
        var state = ImageFailureBannerState()
        state.failedCount = 0
        #expect(state.isVisible == false)
    }

    @Test("A message with no remote images at all shows no banner")
    func aMessageWithNoRemoteImagesShowsNoBanner() {
        // A plain-text or cid:-only message never posts a census, so the state
        // stays at its initial value for the life of the document.
        #expect(ImageFailureBannerState().isVisible == false)
    }

    @Test("One failed remote image is enough")
    func oneFailureRaisesTheBanner() {
        var state = ImageFailureBannerState()
        state.failedCount = 1
        #expect(state.isVisible, "the threshold is ONE — a single blank box is the case the banner exists to explain")

        // And it does not become more visible with more failures; the count is
        // deliberately not surfaced to the user (see `ImageLoadFailureBanner`).
        state.failedCount = 12
        #expect(state.isVisible)
    }

    @Test("Dismissal hides it for the rest of the document, and a later report cannot resurrect it")
    func dismissalSticksForTheDocument() {
        var state = ImageFailureBannerState(failedCount: 3, dismissed: false)
        #expect(state.isVisible)
        state.dismissed = true
        #expect(state.isVisible == false)

        // The one-shot on the JS side means a second census for the same document
        // should not arrive at all — but if a future edit relaxes that, a dismissed
        // banner must stay dismissed rather than popping back up under the user.
        state.failedCount = 9
        #expect(state.isVisible == false,
                "dismissal is a property of the DOCUMENT, not of a particular count")
    }

    /// A document identity with every field defaulted, so each test varies exactly
    /// the one field it is about and the others cannot silently differ.
    private static func identity(
        html: String = "<p>hello</p>", reloadToken: Int = 0, key: String? = nil
    ) -> RenderedDocumentIdentity {
        RenderedDocumentIdentity(
            html: html, reloadToken: reloadToken,
            bodyContentKey: key.map { ContentKey(rawValue: $0) })
    }

    /// A state with BOTH halves set, so "cleared" and "carried" are distinguishable
    /// outcomes. A default-valued state makes them identical, which is how the
    /// predecessor of these tests managed to assert nothing.
    private static let accusingAndDismissed = ImageFailureBannerState(failedCount: 4, dismissed: true)

    @Test("Every input that selects the CONTENT is part of the document's identity")
    func everyContentInputParticipatesInTheIdentity() {
        // Membership asserted directly, one field at a time, because the wiring
        // reads this type's `==` and nothing else. Dropping a field here is exactly
        // the shape of the defect being fixed: the reset then does not fire for a
        // change that really did put a different document on screen.
        let base = Self.identity()
        #expect(base == Self.identity(), "same content ⇒ same document")

        #expect(base != Self.identity(html: "<p>different</p>"),
                "the body bytes are the document")
        #expect(base != Self.identity(reloadToken: 1),
                "a body refetch replaces the document even when the bytes match — updateUIView reloads on html || reloadToken")
        #expect(base != Self.identity(key: "acct:INBOX:7"),
                "a row re-keyed onto a different message rebinds this view; @State survives the .id(…) remount")
        #expect(Self.identity(key: "acct:INBOX:7") != Self.identity(key: "acct:INBOX:8"),
                "two different bodies are two different documents")
    }

    @Test("A change to ANY content input carries NOTHING across — neither the accusation nor the dismissal")
    func aContentIdentityChangeClearsBothHalves() {
        // MIS-IOS-016 — the setup has to be observably non-default, or "cleared" and
        // "unchanged" are the same value and every assertion below is satisfied by
        // an implementation that does nothing.
        let dirty = Self.accusingAndDismissed
        #expect(dirty != ImageFailureBannerState(),
                "the fixture must differ from the reset value or this test proves nothing")
        #expect(dirty.dismissed && dirty.failedCount > 0,
                "both halves must be set, so a reset that clears only one is visible")

        let base = Self.identity()
        for changed in [Self.identity(html: "<p>next</p>"),
                        Self.identity(reloadToken: 1),
                        Self.identity(key: "acct:INBOX:7")] {
            let next = ImageFailureBannerState.carried(dirty, describing: base, into: changed)
            // The failure direction: a previous message's count leaking into a
            // message that rendered perfectly accuses an innocent sender's server.
            #expect(next.failedCount == 0)
            #expect(next.isVisible == false)
            // The suppression direction, which is the one a plausible future edit
            // gets wrong ("don't nag the user twice"): a dismissal leaking into the
            // NEXT message silently withholds the banner from a message that really
            // did lose images — and an observational notice has no second channel.
            #expect(next.dismissed == false,
                    "a reset that clears the count but keeps the dismissal blinds the next message")
        }

        // Cleared BOTH halves means the next document starts from the initial value,
        // so a real failure on it is visible again.
        var next = ImageFailureBannerState.carried(dirty, describing: base, into: Self.identity(html: "<p>next</p>"))
        next.failedCount = 1
        #expect(next.isVisible)
    }

    @Test("A reload that does NOT change the content keeps the banner — a dark-mode flip must not resurrect a dismissal")
    func anUnchangedIdentityCarriesBothHalves() {
        // The reachable negative control, and the reason the identity is scoped to
        // CONTENT rather than to "the web view reloaded": `updateUIView` reloads the
        // document on a light↔dark flip so `fixDarkModeColorsJS` re-runs for the new
        // appearance. That is a real reload of the SAME message. Scoping the reset to
        // reloads would re-raise a notice the user just dismissed, on the message
        // they are still reading, every time the appearance changed.
        let dirty = Self.accusingAndDismissed
        // MIS-IOS-016 again, in the other direction: if the fixture were the default
        // value, "carried" would be indistinguishable from "reset".
        #expect(dirty != ImageFailureBannerState())

        let same = Self.identity()
        let carried = ImageFailureBannerState.carried(dirty, describing: same, into: Self.identity())
        #expect(carried == dirty, "an unchanged content identity changes nothing about the banner")
        #expect(carried.dismissed, "the dismissal is the half a reload-scoped reset would lose")

        // And the visible half survives too: a user who has NOT dismissed still sees
        // the banner after an appearance change.
        let undismissed = ImageFailureBannerState(failedCount: 2, dismissed: false)
        #expect(undismissed.isVisible)
        #expect(ImageFailureBannerState.carried(undismissed, describing: same, into: Self.identity()).isVisible)
    }

    @Test("Carrying a fresh state across a document change is a no-op — the call site's equality guard changes nothing")
    func carryingAFreshStateIsANoOp() {
        // `AutoSizingHTMLView` assigns only when the result differs, to avoid
        // invalidating the view on every content change. That guard is only safe
        // because the result for an already-fresh state IS the fresh state.
        let fresh = ImageFailureBannerState()
        #expect(ImageFailureBannerState.carried(
            fresh, describing: Self.identity(), into: Self.identity(html: "<p>next</p>")) == fresh)
    }

    @Test("The user-visible sentence stays hedged, name-free and count-free")
    func theCopyDoesNotOverclaim() {
        // `onerror` fires for far more than an ATS/TLS refusal — a 404, a DNS
        // failure, malformed image bytes and a plain offline device are all
        // indistinguishable to the page. The copy is the only place that accepted
        // imprecision is visible to the user, so it is pinned here: anyone
        // strengthening it has to change this test and read why it exists.
        let message = ImageLoadFailureBanner.message
        let lowercased = message.lowercased()
        #expect(message.contains("may not"),
                "the hedge is load-bearing — we do not know the cause, only that the load ended in error")
        #expect(!lowercased.contains("blocked"),
                "nothing is blocked; saying so would describe the REVERTED 2026-06-17 design, not this one")
        #expect(!lowercased.contains("load anyway") && !lowercased.contains("tap to"),
                "there is no load-anyway affordance to advertise — no per-image runtime ATS opt-out exists on iOS")
        #expect(message.rangeOfCharacter(from: .decimalDigits) == nil,
                "no count: the census is a lower bound on a page we do not fully observe")
    }
}
