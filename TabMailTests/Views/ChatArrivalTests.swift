/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
@testable import TabMail

/// A new email's arrival in the open chat (`ChatArrival`): only a change of the newest email after
/// the landing animates; it rises, or under Reduce Motion the space opens at once and it fades in.
@Suite("A new email arriving in the chat")
struct ChatArrivalTests {
    @Test("A new newest email after the landing is an arrival")
    func arrival() {
        #expect(ChatArrival.isArrival(landed: true, oldNewest: "a", newNewest: "b"))
    }

    @Test("The open's own load, the same newest, or an emptied chat is not an arrival")
    func notArrivals() {
        #expect(!ChatArrival.isArrival(landed: false, oldNewest: "a", newNewest: "b"), "before the landing")
        #expect(!ChatArrival.isArrival(landed: true, oldNewest: nil, newNewest: "b"), "the first rows")
        #expect(!ChatArrival.isArrival(landed: true, oldNewest: "a", newNewest: "a"))
        #expect(!ChatArrival.isArrival(landed: true, oldNewest: "a", newNewest: nil))
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
