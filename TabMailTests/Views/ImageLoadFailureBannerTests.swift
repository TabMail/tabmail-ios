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
// THE INVARIANT THESE PIN: *given a banner state and the identities of the document
// it describes and the document now on screen, the banner is visible iff at least one
// remote image of the CURRENT document ended in `error` and the user has not dismissed
// it — and every input that can change rendered content while this enclosing state
// survives discards both halves.* Preview attachment selection is a fresh UUID-keyed
// sheet/remount, so `previewFilename` is deliberately outside this value-level identity.
//
// ⚠️ The scope sentence above is narrower than the one this header carried until
// 2026-08-13 ("nothing about it survives a document change"), and the difference is
// the reason `aDocumentChangeClearsBothHalves` was worthless. `documentChanged()` was
// `self = ImageFailureBannerState()` and the test asserted `x.documentChanged();
// x == ImageFailureBannerState()` — the implementation's own statement read back. It
// could not fail for any implementation of "assign the initial value", and, more to
// the point, it said nothing about WHEN the reset ran, which was the entire defect:
// the call site fired on `html` alone, so a body refetch returning identical bytes
// and a row re-keyed onto a different message both kept the old count and dismissal.
// A vacuous test is not merely uninformative — it made this file LOOK like it covered
// the wiring. The reset now takes the two document identities as ARGUMENTS, which is
// what moves that decision into something assertable.
//
// ⚠️ STILL NOT COVERED HERE, stated so nobody reads more into a green run than it
// carries: that `AutoSizingHTMLView` actually invokes `carried` at the right moments.
// `.onChange(of: documentIdentity)` needs a SwiftUI render pass to observe, and the
// suite has no host for one. What these tests pin is the DECISION — membership of
// `RenderedDocumentIdentity`, and what `carried` does with it. The wiring was verified
// by inverting it (dropping each field from the identity in turn and watching the
// matching test below go red).
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

    @Test("Every content selector whose enclosing state survives is part of the document identity")
    func everySurvivingContentInputParticipatesInTheIdentity() {
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

    /// A gate holding one committed document — the state every census actually
    /// arrives in, since `evaluate` refuses outright when nothing is committed.
    private func committedGate(generation: Int = 1) -> CommittedDocumentGate {
        var gate = CommittedDocumentGate()
        gate.issue(generation: generation)
        gate.commit(isIssuedLoad: true)
        return gate
    }

    /// The count a census publishes, or 0 when it publishes nothing.
    private func publishedCount(_ census: ImageFailureBannerState.Census) -> Int {
        switch census {
        case .publish(let count): return count
        case .suppressedOffline, .refused: return 0
        }
    }

    @Test("An offline device publishes no failures — the banner must not blame a server the device never reached")
    func anOfflineCensusIsSuppressed() {
        // On a device with no network EVERY remote image errors, so an unfiltered
        // census reads as "the sender's image server may not support a secure
        // connection" about a server the device never tried to reach. `onerror`
        // gives the page no reason code, but the app has `NWPathMonitor` — this is
        // the one cause we can rule out rather than hedge around.
        let reported = 5

        // MIS-IOS-016 — the fixture has to be a census that WOULD raise a banner,
        // or "suppressed" and "there was nothing to suppress" are the same result
        // and every assertion below passes against a function that does nothing.
        #expect(ImageFailureBannerState(failedCount: reported).isVisible,
                "the fixture must raise a banner when online, or suppression is unobservable")

        var offlineGate = committedGate()
        #expect(ImageFailureBannerState.census(
            reported: reported, isConnected: false, in: &offlineGate) == .suppressedOffline)
        let offline = ImageFailureBannerState(failedCount: publishedCount(.suppressedOffline))
        #expect(offline.isVisible == false, "no banner while offline")

        // The negative control, and it is the half that matters most: online, the
        // census is published untouched. A suppression that swallowed the online
        // case too would delete the feature outright while leaving the assertion
        // above green.
        var onlineGate = committedGate()
        let published = ImageFailureBannerState.census(
            reported: reported, isConnected: true, in: &onlineGate)
        #expect(published == .publish(reported))
        #expect(ImageFailureBannerState(failedCount: publishedCount(published)).isVisible,
                "a real failure on a connected device must still raise the banner")

        // And suppression cannot manufacture a banner in either direction.
        var emptyOnline = committedGate()
        var emptyOffline = committedGate()
        #expect(ImageFailureBannerState.census(
            reported: 0, isConnected: true, in: &emptyOnline) == .publish(0))
        #expect(ImageFailureBannerState.census(
            reported: 0, isConnected: false, in: &emptyOffline) == .suppressedOffline)
    }

    @Test("An offline census clears a visible result from an earlier rendering of the same content")
    func anOfflineReloadClearsAStaleVisibleBanner() {
        // Reachable production precondition: a connected rendering published a
        // failure, then a colour-scheme flip or content-process recovery reloads
        // the SAME content while the device is offline. Document identity carries
        // the state across that reload, so suppression must actively retract the
        // old count rather than merely decline to publish a new one.
        let stale = ImageFailureBannerState(failedCount: 4, dismissed: false)
        #expect(stale.isVisible, "the fixture must start with an observable stale accusation")

        let replacement = ImageFailureBannerState.replacementFailedCount(after: .suppressedOffline)
        #expect(replacement == 0,
                "offline suppression must retract the earlier result for this still-visible content")

        // Negative controls: a connected publication replaces the count, while a
        // gate refusal has no authority to erase a valid result.
        #expect(ImageFailureBannerState.replacementFailedCount(after: .publish(2)) == 2)
        #expect(ImageFailureBannerState.replacementFailedCount(after: .refused(.duplicate)) == nil)
    }

    @Test("Offline suppression leaves the Swift one-shot unspent as a fail-safe")
    func offlineSuppressionLeavesTheSwiftOneShotUnspentAsAFailSafe() {
        // The page sets `__tmImageFailureReported` before its sole post, so this
        // same-document second call is NOT a production recovery route. The Swift
        // gate still should not manufacture a spent slot for a report it refused to
        // publish: that keeps the authority honest if delivery is ever retried or the
        // page-side one-shot changes later.
        var gate = committedGate()

        #expect(ImageFailureBannerState.census(
            reported: 4, isConnected: false, in: &gate) == .suppressedOffline)

        // Directly probe the Swift authority after connectivity returns. This is a
        // fail-safe property of the gate, not a claim that today's page posts twice.
        #expect(ImageFailureBannerState.census(
            reported: 4, isConnected: true, in: &gate) == .publish(4),
                "a suppressed report must not create an authoritative publication record")

        // Non-vacuity, both sides. The slot IS a one-shot — otherwise the assertion
        // above would hold against a gate that never refuses anything...
        #expect(ImageFailureBannerState.census(
            reported: 4, isConnected: true, in: &gate) == .refused(.duplicate),
                "the second published census for one document must still be refused")

        // ...and offline suppression is not simply "the gate refuses everything":
        // with nothing committed, the online path refuses rather than publishing.
        var uncommitted = CommittedDocumentGate()
        #expect(ImageFailureBannerState.census(
            reported: 4, isConnected: true, in: &uncommitted) == .refused(.noCommittedDocument))
    }

    @Test("Offline is read before the one-shot, so an offline census cannot be refused as a duplicate")
    func offlineIsResolvedBeforeTheGate() {
        // Order, stated as a property rather than as a statement sequence. Whatever
        // the gate's state, an offline census reports suppression — it never reports
        // a gate verdict, because it never reaches the gate.
        var gate = committedGate()
        #expect(ImageFailureBannerState.census(
            reported: 3, isConnected: true, in: &gate) == .publish(3))
        #expect(ImageFailureBannerState.census(
            reported: 3, isConnected: true, in: &gate) == .refused(.duplicate),
                "precondition: this document's slot is now spent")

        #expect(ImageFailureBannerState.census(
            reported: 3, isConnected: false, in: &gate) == .suppressedOffline,
                "offline is answered without consulting the gate at all")

        // And with no document committed — the other refusal — offline still wins.
        var uncommitted = CommittedDocumentGate()
        #expect(ImageFailureBannerState.census(
            reported: 3, isConnected: false, in: &uncommitted) == .suppressedOffline)
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
