/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import CoreGraphics
import Testing
@testable import TabMail

/// Dragging the reply field up (`ChatFieldDrag`): the field swells under the finger, only for a drag
/// that goes more up than sideways, never past its limit, and the let-go opens the panel once the
/// swell or a flick's predicted swell reaches the open distance.
@Suite("Dragging the reply field")
struct ChatFieldDragTests {
    private let open = ChatViewLayout.fieldDragOpenDistance

    @Test("The field swells by the upward distance, up to its limit")
    func swellFollowsTheFinger() {
        #expect(ChatFieldDrag.swell(translation: CGSize(width: 0, height: -30)) == 30)
        #expect(ChatFieldDrag.swell(translation: CGSize(width: 0, height: -10_000)) == ChatViewLayout.fieldDragMaxSwell)
    }

    @Test("A drag down, or one more sideways than up, does not swell the field",
          arguments: [CGSize(width: 0, height: 40), CGSize(width: 80, height: -40), CGSize(width: -80, height: -40), .zero])
    func onlyAnUpwardDragSwells(_ translation: CGSize) {
        #expect(ChatFieldDrag.swell(translation: translation) == 0)
    }

    @Test("Letting go at or past the open distance opens the panel; short of it, it settles back")
    func distanceOpens() {
        let past = CGSize(width: 0, height: -open)
        let short = CGSize(width: 0, height: -(open - 1))
        #expect(ChatFieldDrag.opens(translation: past, predictedEndTranslation: past))
        #expect(!ChatFieldDrag.opens(translation: short, predictedEndTranslation: short))
    }

    @Test("A short upward flick opens; a sideways or downward flick does not")
    func flickOpens() {
        let short = CGSize(width: 0, height: -(open / 2))
        #expect(ChatFieldDrag.opens(translation: short, predictedEndTranslation: CGSize(width: 0, height: -open * 3)))
        #expect(!ChatFieldDrag.opens(translation: short, predictedEndTranslation: CGSize(width: open * 4, height: -open * 3)))
        #expect(!ChatFieldDrag.opens(translation: short, predictedEndTranslation: CGSize(width: 0, height: open * 3)))
    }
}
