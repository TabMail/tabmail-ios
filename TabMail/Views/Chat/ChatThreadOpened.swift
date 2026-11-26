/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Observation

/// A thread read before it shows, so its first frame is the whole thread (ADR-IOS-114 decision 24).
///
/// A new email's chat becomes its sent email's thread once the Sent copy is in. A thread built from
/// the copy's id alone reads it after it shows: for its first frames it drew a spinner, then faded
/// the email in on the other person's side, and moved it to the user's side once it had read the
/// user's own addresses. Between the new email and the thread, that was a blink. So the chat reads
/// the thread first, with the reads the thread makes anyway: its view model resolves the email
/// (`MessageDetailViewModel.loadBody`, which goes on with the body and the thread's other emails as
/// for any open), and its context (`ChatThreadContext.load`) tells the user's own emails apart. The
/// thread then starts with both (`ChatThreadView(opened:)`).
@MainActor
struct ChatThreadOpened {
    let viewModel: MessageDetailViewModel
    let context: ChatThreadContext

    /// Reads the thread of the email `messageId`: until the email is resolved, never its body, which
    /// may come from the server, then its context. Cancelled, it stops the load it started.
    static func read(messageId: String) async -> ChatThreadOpened {
        let viewModel = MessageDetailViewModel(messageId: messageId)
        let load = Task { await viewModel.loadBody() }
        return await withTaskCancellationHandler {
            for await resolved in Observations({ @MainActor in viewModel.message != nil || viewModel.messageNotFound })
            where resolved { break }
            let members = viewModel.message.map { [$0] } ?? []
            let context = members.isEmpty
                ? ChatThreadContext()
                : await ChatThreadContext.load(members: members, pool: AppDatabase.dbPool)
            return ChatThreadOpened(viewModel: viewModel, context: context)
        } onCancel: {
            load.cancel()
        }
    }
}
