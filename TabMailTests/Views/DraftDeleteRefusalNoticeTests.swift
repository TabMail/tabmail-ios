/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
@testable import TabMail

/// A refused Drafts deletion is EXPLAINED, and explained exactly once per gesture
/// (#147). Pins the decision in `DraftDeleteRefusalNotice.text`, the pure hop
/// between `InboxViewModel.delete` / `deleteThread` reporting a refusal and the
/// view showing a notice.
///
/// Same reach caveat as `InboxErrorBannerTests`: no test here constructs
/// `InboxView`, so the wiring from the four un-hide sites to this function is
/// covered by inspection, not assertion.
struct DraftDeleteRefusalNoticeTests {

    @Test("a refused single-row deletion in the Drafts list produces the notice")
    func singleRefusalIsExplained() {
        #expect(DraftDeleteRefusalNotice.text(refusedCount: 1, isDraftsContext: true)
            == DraftDeleteRefusalNotice.message)
    }

    @Test("a thread gesture with several refused members produces ONE notice, identical to the single-row one — no per-member duplicates")
    func threadRefusalCollapsesToOneNotice() {
        let single = DraftDeleteRefusalNotice.text(refusedCount: 1, isDraftsContext: true)
        let many = DraftDeleteRefusalNotice.text(refusedCount: 5, isDraftsContext: true)
        #expect(many != nil)
        #expect(many == single)
    }

    @Test("a successful deletion (nothing refused) produces no notice")
    func successProducesNoNotice() {
        #expect(DraftDeleteRefusalNotice.text(refusedCount: 0, isDraftsContext: true) == nil)
    }

    @Test("a refused deletion outside the Drafts list keeps its existing silent un-hide")
    func nonDraftsRefusalIsSilent() {
        #expect(DraftDeleteRefusalNotice.text(refusedCount: 1, isDraftsContext: false) == nil)
        #expect(DraftDeleteRefusalNotice.text(refusedCount: 3, isDraftsContext: false) == nil)
    }

    @Test("the copy names no identifiers and says the draft is still available")
    func copyIsPlainLanguage() {
        let text = DraftDeleteRefusalNotice.message
        #expect(text.contains("still in Drafts"))
        #expect(!text.contains(":"))
        #expect(!text.contains("UID"))
    }
}
