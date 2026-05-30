/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// Resolves the "active message" for bottom-bar actions (Reply, Reply All, Forward,
/// Archive, Delete, Move) in MessageDetailView.
///
/// The bottom bar tracks the most-visible card via `CardVisibilityKey` / `onPreferenceChange`,
/// which stores a `MessageHeader` snapshot (`chatContextMessage`). That snapshot is frozen
/// at capture time — if AI populates `cachedReply` after the card was captured, the snapshot
/// is stale and the Reply button shows no suggested-reply bubble.
///
/// Regression: action-tag taps always used the live per-render `MessageHeader` from
/// `MessageCardView`, so they saw fresh state. Toolbar Reply / Reply-All did not.
///
/// Fix: re-resolve by id against the current viewModel arrays so we see the live
/// `@Observable` instance.
enum ActiveMessageResolver {
    /// Return the live message matching `context.id` from the viewModel's arrays.
    /// Falls back to `focused` when there's no context yet (user hasn't scrolled),
    /// and to the stale context only if no live instance is found (shouldn't happen
    /// in practice but preserves previous behavior under edge cases).
    static func resolve(
        context: MessageHeader?,
        focused: MessageHeader?,
        later: [MessageHeader],
        earlier: [MessageHeader]
    ) -> MessageHeader? {
        guard let ctx = context else { return focused }
        if let hit = later.first(where: { $0.id == ctx.id }) { return hit }
        if let focused, focused.id == ctx.id { return focused }
        if let hit = earlier.first(where: { $0.id == ctx.id }) { return hit }
        return ctx
    }
}
