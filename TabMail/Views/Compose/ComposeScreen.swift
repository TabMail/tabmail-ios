/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

/// The kind of screen a compose window was opened on, given by that screen as the compose opens
/// (`ComposeView.openedOn`) and never read later from what is on screen. With the chat view
/// setting read at the Send tap, it decides whether a send's Undo is on a chat's "Sending"
/// bubble (`PendingSendService.sendHasBubbleUndo`): only a compose a chat opened for a send it
/// shows closes back onto the chat that shows that bubble. The compose an Undo reopens records
/// the screen of the bubble whose Undo reopened it (`PendingSendService.ReopenSnapshot.openedOn`),
/// none after the toast's. A compose opened anywhere else (the Drafts list, the inbox, an email
/// screen) records none, and its send keeps the toast.
///
/// Only a screen whose compose behaves differently is named; nil stands for every other.
enum ComposeScreen: Hashable, Sendable {
    /// The chat view (`ChatThreadView`), for a compose whose send it shows as its bubble: a reply to
    /// or a forward of one of its emails, from its AI Suggestion, an agent's card or its Forward
    /// (`ChatThreadView.composeScreen`). A compose it opens for a new email, or for an email of
    /// another thread, records none.
    case chat
    /// A new email's chat (`ChatNewThreadView`), for the compose card it opens for its own new
    /// email: the chat shows that send as its bubble, found by the card's draft
    /// (`ChatNewEmailSend`), not by an In-Reply-To.
    case newEmailChat
}
