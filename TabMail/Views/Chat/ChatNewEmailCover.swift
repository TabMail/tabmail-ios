/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import SwiftUI

/// A new email a screen presents as a full-screen cover: asked for by the email screen's compose
/// button, a contact pill or a `mailto:` link (in an email or from outside the app). Where it opens
/// is decided once, as the request arrives (`ChatNewThreadRoute.newEmail`): today's compose, filled
/// with what the request brought, or the new email's chat. The cover shows only what was captured
/// then, never a later read.
struct ChatNewEmailCover: Identifiable {
    enum Content {
        /// Today's compose: the request's To, Cc, Bcc, subject and body, from `account` (nil:
        /// compose picks its own).
        case compose(MailtoRequest?, account: Account?)
        /// The new email's chat, in its own navigation stack; its Back closes the cover.
        case chat(ChatNewThreadModel)
    }

    let id = UUID()
    let content: Content

    /// The cover for a new email asked for now. `chatAccount` is the account the chat starts from
    /// (`Account.primary`); `composeAccount` is what that screen's compose was given before the chat
    /// view, unchanged.
    @MainActor
    static func make(
        request: MailtoRequest?,
        opensInChat: Bool,
        signedIn: Bool,
        chatAccount: @autoclosure () -> Account?,
        composeAccount: @autoclosure () -> Account?
    ) -> ChatNewEmailCover {
        switch ChatNewThreadRoute.newEmail(opensInChat: opensInChat, signedIn: signedIn) {
        case .newThread:
            ChatNewEmailCover(content: .chat(ChatNewThreadModel(account: chatAccount(), request: request)))
        case .compose:
            ChatNewEmailCover(content: .compose(request, account: composeAccount()))
        }
    }
}

/// Whether the list has a sheet or cover of its own up (Search, a reply, compose, a move or label
/// sheet, a new email). On iPad the detail column beside the list is then behind it, so the screen
/// there takes no new-email request. The list writes it (`listPresentationWriter`); only the detail
/// column reads it (`listPresentationBesideDetail`), so an email opened inside the list's Search
/// sheet, which carries the list's environment, still takes one. Not observed: it is read only as
/// a request arrives, so it never redraws a screen.
@MainActor
final class ListPresentationState {
    var isUp = false
}

private struct ListPresentationWriterKey: EnvironmentKey {
    static let defaultValue: ListPresentationState? = nil
}

private struct ListPresentationBesideDetailKey: EnvironmentKey {
    static let defaultValue: ListPresentationState? = nil
}

extension EnvironmentValues {
    /// The list's presentation state, given to the list column, which keeps it current.
    var listPresentationWriter: ListPresentationState? {
        get { self[ListPresentationWriterKey.self] }
        set { self[ListPresentationWriterKey.self] = newValue }
    }

    /// The same state, given to the detail column only, whose screens read it.
    var listPresentationBesideDetail: ListPresentationState? {
        get { self[ListPresentationBesideDetailKey.self] }
        set { self[ListPresentationBesideDetailKey.self] = newValue }
    }
}

/// What a `ChatNewEmailCover` shows.
struct ChatNewEmailCoverView: View {
    let cover: ChatNewEmailCover

    var body: some View {
        switch cover.content {
        case .compose(let request, let account):
            ComposeView(
                account: account,
                prefillTo: request?.to,
                prefillCc: request.flatMap { $0.cc.isEmpty ? nil : $0.cc },
                prefillBcc: request.flatMap { $0.bcc.isEmpty ? nil : $0.bcc },
                prefillSubject: request?.subject,
                prefillBody: request?.body
            )
        case .chat(let model):
            NavigationStack { ChatNewThreadView(model: model) }
        }
    }
}
