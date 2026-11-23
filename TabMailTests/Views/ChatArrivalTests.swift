/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import SwiftUI
import Testing
@testable import TabMail

/// A new email's arrival in the open chat (`ChatArrival`): only a change of the newest email after
/// the landing animates; it rises, or under Reduce Motion the space opens at once and it fades in.
@Suite("A new email arriving in the chat")
struct ChatArrivalTests {
    @Test("A new newest email after the landing is an arrival")
    func arrival() {
        #expect(ChatArrival.isArrival(landed: true, oldNewest: "a", newNewest: "b", newestIsOwn: false))
    }

    @Test("The user's own newest email (a sent reply filed from Sent) is not an arrival and does not rise")
    func ownReplyIsNotAnArrival() {
        #expect(!ChatArrival.isArrival(landed: true, oldNewest: "a", newNewest: "b", newestIsOwn: true))
        #expect(!ChatArrival.animates(landed: true, newestIsOwn: true))
        #expect(ChatArrival.animates(landed: true, newestIsOwn: false))
        #expect(!ChatArrival.animates(landed: false, newestIsOwn: false), "the open's own load")
    }

    @Test("Only the arriving row has an entrance; the load's rows, under Reduce Motion too, appear as they are")
    func onlyTheArrivalRowEnters() {
        // `.identity` cannot be compared, so the type's description stands in for it.
        let none = String(describing: AnyTransition.identity)
        for style in [ChatArrival.Style.rise, .fade] {
            #expect(String(describing: ChatArrival.transition(style, isArrivalRow: false)) == none, "\(style)")
            #expect(String(describing: ChatArrival.transition(style, isArrivalRow: true)) != none, "\(style)")
        }
    }

    @Test("The open's own load, the same newest, or an emptied chat is not an arrival")
    func notArrivals() {
        #expect(!ChatArrival.isArrival(landed: false, oldNewest: "a", newNewest: "b", newestIsOwn: false), "before the landing")
        #expect(!ChatArrival.isArrival(landed: true, oldNewest: nil, newNewest: "b", newestIsOwn: false), "the first rows")
        #expect(!ChatArrival.isArrival(landed: true, oldNewest: "a", newNewest: "a", newestIsOwn: false))
        #expect(!ChatArrival.isArrival(landed: true, oldNewest: "a", newNewest: nil, newestIsOwn: false))
    }

    @Test("It rises; under Reduce Motion the layout jumps (no animation) and the bubble fades in")
    func reduceMotion() {
        #expect(ChatArrival.style(reduceMotion: false) == .rise)
        #expect(ChatArrival.style(reduceMotion: true) == .fade)
        #expect(ChatArrival.animation(.rise) != nil)
        #expect(ChatArrival.animation(.fade) == nil, "the space opens at once")
        #expect(ChatViewLayout.arrivalRiseDuration == 0.42 && ChatViewLayout.arrivalFadeDuration == 0.2)
    }
}
