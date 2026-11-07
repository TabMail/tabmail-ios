/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import SwiftUI

/// Which emails of an open chat get their summary asked for, and in what order (owner
/// 2026-11-06). A thread can be any length, so the chat never asks for all of it: only the emails
/// on screen and a few around them. The rest wait until a scroll brings them near.
enum ChatSummaryWindow {
    /// The ids to ask for, first to last: the emails on screen, newest first, then up to `older`
    /// emails above the oldest on-screen one and `newer` below the newest, nearest first (at each
    /// distance the older one first). `order` is the chat's emails, oldest first; `visible` the ids
    /// on screen. Nothing on screen asks for nothing.
    static func ids(order: [String], visible: Set<String>, older: Int, newer: Int) -> [String] {
        guard let first = order.firstIndex(where: visible.contains),
              let last = order.lastIndex(where: visible.contains) else { return [] }
        var ids = Array(order[first...last].reversed())
        for distance in 1...max(1, max(older, newer)) {
            if distance <= older, first - distance >= 0 { ids.append(order[first - distance]) }
            if distance <= newer, last + distance < order.count { ids.append(order[last + distance]) }
        }
        return ids
    }

    /// The chat's window: the screen and `ChatViewConfig.summaryWindow` above it until the user
    /// has scrolled by hand, then `ChatViewConfig.summaryWindow` on each side.
    static func ids(order: [String], visible: Set<String>, handScrolled: Bool) -> [String] {
        ids(order: order, visible: visible,
            older: ChatViewConfig.summaryWindow,
            newer: handScrolled ? ChatViewConfig.summaryWindow : 0)
    }

    /// Whether the user moved the chat by hand: a finger drag or the fling after it. Only then does
    /// a stop ask `ChatViewConfig.summaryWindow` both ways; the chat's own scroll to its opening
    /// place (the Unread line, a searched email) and the jump to the bottom keep the open window.
    static func userMoved(_ phase: ScrollPhase) -> Bool {
        phase == .interacting || phase == .decelerating
    }
}
