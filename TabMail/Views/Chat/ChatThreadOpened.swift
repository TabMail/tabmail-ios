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
///
/// Its header (`ChatThreadHeader`) is shown by the hosting screen's own toolbar item, the one item
/// it keeps for its whole life, first with the new email's header, then with the thread's: an item
/// the thread brought itself would come into the navigation bar some commits after the thread's
/// content, and for those commits the bar had no header at all.
@MainActor
struct ChatThreadOpened {
    let viewModel: MessageDetailViewModel
    let context: ChatThreadContext
    let header: ChatThreadHeader

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
            let thread = ChatThreadView.thread(
                members: ChatThreadView.members(of: viewModel), context: context, unreadAtOpen: [],
                preferredId: viewModel.message?.id)
            return ChatThreadOpened(viewModel: viewModel, context: context,
                                    header: ChatThreadHeader(people: thread.replyPeople))
        } onCancel: {
            load.cancel()
        }
    }
}

/// The header of a thread another screen hosts (`ChatThreadOpened`): who a reply goes to, kept by
/// the thread (`ChatThreadView`), and the names' tap, which the thread answers by opening who its
/// reply goes to.
@MainActor @Observable
final class ChatThreadHeader {
    var people: [ChatThread.Person]
    /// The names were tapped; the thread clears it as it opens who the reply goes to.
    var asksReplyTo = false

    init(people: [ChatThread.Person]) {
        self.people = people
    }
}
