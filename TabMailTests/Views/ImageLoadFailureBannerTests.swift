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

    @Test("Switching messages carries NOTHING across — neither the accusation nor the dismissal")
    func aDocumentChangeClearsBothHalves() {
        // The failure direction: a previous message's count leaking into a message
        // that rendered perfectly would accuse an innocent sender's server.
        var accusing = ImageFailureBannerState(failedCount: 4, dismissed: false)
        accusing.documentChanged()
        #expect(accusing == ImageFailureBannerState())
        #expect(accusing.isVisible == false)

        // The suppression direction, which is the one a plausible future edit gets
        // wrong ("don't nag the user twice"): a dismissal leaking into the NEXT
        // message silently withholds the banner from a message that really did lose
        // images — and an observational notice has no second channel to fall back on.
        var dismissed = ImageFailureBannerState(failedCount: 4, dismissed: true)
        dismissed.documentChanged()
        #expect(dismissed.dismissed == false,
                "a reset that clears the count but keeps the dismissal blinds the next message")

        // Cleared BOTH halves means the next document starts from the initial value,
        // so a real failure on it is visible again.
        var next = dismissed
        next.failedCount = 1
        #expect(next.isVisible)

        // Idempotent: resetting an already-fresh state is a no-op, which is what
        // lets the call site guard on inequality without changing behaviour.
        var fresh = ImageFailureBannerState()
        fresh.documentChanged()
        #expect(fresh == ImageFailureBannerState())
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
