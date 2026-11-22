/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

/// The kind of screen a compose window was opened on, given by that screen as the compose opens
/// (`ComposeView.openedOn`) and never read later from what is on screen. With the chat view
/// setting read at the Send tap, it decides whether a reply's Undo is on the chat's "Sending"
/// bubble (`PendingSendService.sendHasBubbleUndo`): only a compose the chat opened closes back onto
/// the chat that shows that bubble. A compose opened anywhere else (the Drafts list, the inbox, an
/// email screen, the compose an Undo reopens) records none, and its send keeps the toast.
///
/// Only a screen whose compose behaves differently is named; nil stands for every other.
enum ComposeScreen: Hashable, Sendable {
    /// The chat view (`ChatThreadView`): its AI Suggestion, the agent's compose cards it opens (a
    /// reply asked for in its reply field included), and its Forward.
    case chat
}
