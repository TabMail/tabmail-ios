/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import CoreGraphics
import Foundation
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

    @Test("A slow drag past the open distance opens even when its predicted end falls short")
    func swellAloneOpens() {
        // The finger is 70 up; the predicted end (a slow let-go easing back) is only 40 up.
        #expect(ChatFieldDrag.opens(translation: CGSize(width: 0, height: -70),
                                    predictedEndTranslation: CGSize(width: 0, height: -40)))
    }

    @Test("A flick whose predicted swell is exactly the open distance opens; one point short does not")
    func flickBoundary() {
        let short = CGSize(width: 0, height: -(open / 2))
        #expect(ChatFieldDrag.opens(translation: short, predictedEndTranslation: CGSize(width: 0, height: -open)))
        #expect(!ChatFieldDrag.opens(translation: short, predictedEndTranslation: CGSize(width: 0, height: -(open - 1))))
    }

    @Test("The drag's progress is the whole drag, sideways included, with the swell it makes")
    func progress() {
        #expect(ChatFieldDrag.progress(translation: CGSize(width: 0, height: -30)) == .init(isDragging: true, swell: 30))
        #expect(ChatFieldDrag.progress(translation: CGSize(width: 80, height: -10)) == .init(isDragging: true, swell: 0))
        #expect(ChatFieldDrag.Progress() == .init(isDragging: false, swell: 0), "at rest")
    }

    @Test("With the tip showing, the first drag still opens: the tip is inline beside the field, never a popover")
    func firstDragWithTheTipOpens() throws {
        let chat = try String(contentsOfFile: Self.root + "/TabMail/Views/Chat/ChatThreadView.swift", encoding: .utf8)
        // A popover tip takes the first touch (UIKit passthrough contract); an inline TipView in an
        // overlay above the field leaves the field's touches to the field and its drag.
        #expect(!chat.contains(".popoverTip("), "no popover tip on the field")
        #expect(chat.contains("TipView(ChatFieldDragTip(), arrowEdge: .bottom)"))
        #expect(chat.contains(".frame(height: 0)\n                    .overlay(alignment: .bottom) {\n                        TipView(ChatFieldDragTip(), arrowEdge: .bottom)"),
                "the tip hangs above the field from a zero-height anchor, pushing no layout")
        // The same drag that would open without the tip opens with it.
        let drag = CGSize(width: 0, height: -open)
        #expect(ChatFieldDrag.opens(translation: drag, predictedEndTranslation: drag))
    }

    /// The project root: this file is TabMailTests/Views/ChatFieldDragTests.swift.
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path
}
