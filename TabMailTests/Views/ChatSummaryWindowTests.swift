/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import SwiftUI
import Testing
@testable import TabMail

/// ADR-IOS-103 decision 9: which emails an open chat asks summaries for (owner 2026-11-06).
///
/// THE SYSTEM PROPERTY pinned here: the emails on screen come first, newest first, then the
/// nearest neighbours up to the given counts, older before newer at each distance; nothing beyond
/// them, and nothing when nothing is on screen.
@Suite("Chat summary window")
struct ChatSummaryWindowTests {
    /// e0 (oldest) ... e49 (newest).
    private let order = (0..<50).map { "e\($0)" }
    private func ids(_ range: ClosedRange<Int>) -> [String] { range.map { "e\($0)" } }

    @Test("At open: the emails on screen, newest first, then summaryLead older ones, nearest first")
    func openWindow() {
        let visible = Set(ids(45...49))
        let got = ChatSummaryWindow.ids(order: order, visible: visible, older: ChatViewConfig.summaryLead, newer: 0)
        #expect(got == Array(ids(45...49).reversed()) + Array(ids((45 - ChatViewConfig.summaryLead)...44).reversed()))
    }

    @Test("After a scroll: the emails on screen, then summarySpread on each side, nearest first, older first")
    func scrollWindow() {
        let spread = ChatViewConfig.summarySpread
        let visible = Set(ids(24...26))
        let got = ChatSummaryWindow.ids(order: order, visible: visible, older: spread, newer: spread)
        var expected = Array(ids(24...26).reversed())
        for d in 1...spread {
            if 24 - d >= 0 { expected.append("e\(24 - d)") }
            if 26 + d < order.count { expected.append("e\(26 + d)") }
        }
        #expect(got == expected)
        #expect(got.count == 3 + min(spread, 24) + min(spread, 23))
        #expect(!got.contains("e49"), "beyond the spread waits for a scroll")
    }

    @Test("The window stops at the thread's ends")
    func edges() {
        #expect(ChatSummaryWindow.ids(order: order, visible: ["e0"], older: 5, newer: 2) == ["e0", "e1", "e2"])
        #expect(ChatSummaryWindow.ids(order: order, visible: ["e49"], older: 2, newer: 5) == ["e49", "e48", "e47"])
        #expect(ChatSummaryWindow.ids(order: ["only"], visible: ["only"], older: 3, newer: 3) == ["only"])
    }

    @Test("Ids on screen that are not emails (the Unread line, the bottom) and an empty screen ask for nothing more")
    func nothingOnScreen() {
        #expect(ChatSummaryWindow.ids(order: order, visible: [], older: 10, newer: 10).isEmpty)
        #expect(ChatSummaryWindow.ids(order: order, visible: ["chat-bottom", "chat-unread-line"], older: 10, newer: 10).isEmpty)
        #expect(ChatSummaryWindow.ids(order: order, visible: ["chat-bottom", "e49"], older: 1, newer: 0) == ["e49", "e48"])
    }

    @Test("The chat's window: summaryLead above the screen at open, summarySpread each way once the user has scrolled by hand")
    func chatWindow() {
        let visible = Set(ids(24...26))
        #expect(ChatSummaryWindow.ids(order: order, visible: visible, handScrolled: false)
                == ChatSummaryWindow.ids(order: order, visible: visible, older: ChatViewConfig.summaryLead, newer: 0))
        #expect(ChatSummaryWindow.ids(order: order, visible: visible, handScrolled: true)
                == ChatSummaryWindow.ids(order: order, visible: visible,
                                         older: ChatViewConfig.summarySpread, newer: ChatViewConfig.summarySpread))
    }

    @Test("Only a hand scroll widens the window: a drag or its fling, never the chat's own scroll or a resting list")
    func handScrollOnly() {
        #expect(ChatSummaryWindow.userMoved(.interacting))
        #expect(ChatSummaryWindow.userMoved(.decelerating))
        #expect(!ChatSummaryWindow.userMoved(.animating), "the scroll to the opening place and the jump to the bottom")
        #expect(!ChatSummaryWindow.userMoved(.tracking), "a finger resting on the list has not moved it")
        #expect(!ChatSummaryWindow.userMoved(.idle))
    }

    @Test("The numbers are the owner's")
    func ownerNumbers() {
        #expect(ChatViewConfig.summaryLead == 10)
        #expect(ChatViewConfig.summarySpread == 20)
    }
}
