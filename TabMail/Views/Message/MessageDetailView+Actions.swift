/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import SwiftUI

// MARK: - Actions, Tag Menus, Compose Helpers

extension MessageDetailView {
    // MARK: - Execute tagged action

    func executeTaggedAction(_ message: MessageHeader) {
        guard let tag = message.actionTag else { return }
        TutorialCoordinator.shared.discovered(.tagTap)
        let result = tag.resolveAction(isMainMessage: message.id == viewModel.message?.id)
        switch result {
        case .reply:
            replyAllMessage = message
        case .archiveAndDismiss:
            // archive() returns false for a no-op (already in the archive
            // folder) — don't dismiss the row/detail then.
            if viewModel.archive() {
                // Fixed archive-role destination — never a rendered inbox.
                dismissMessage(destinationFolderId: nil)
            }
        case .archiveInPlace:
            if viewModel.archiveMessage(message) {
                flashedCardId = message.id
            }
        case .deleteAndDismiss:
            // delete() returns false for a no-op (already in the trash
            // folder) — don't dismiss the row/detail then.
            if viewModel.delete() {
                // Fixed trash-role destination — never a rendered inbox.
                dismissMessage(destinationFolderId: nil)
            }
        case .deleteInPlace:
            if viewModel.deleteMessage(message) {
                flashedCardId = message.id
            }
        case .noop:
            break
        }
    }

    /// Notify the list to dismiss this message with animation, then pop the detail view.
    ///
    /// `destinationFolderId` names the folder the action puts the message INTO, when the
    /// caller knows it. The list receiving this notification hides the row on the premise
    /// that the action took the message out of the folders it renders; that premise is
    /// false for a move whose destination is one of those folders (Archive → Inbox), and
    /// the wrong hide is permanent because there is no un-dismiss path for a row that
    /// simply came back. Callers with a FIXED destination that can never be a rendered
    /// inbox — archive, delete — pass `nil`. **Deliberately not defaulted:** a new dismiss
    /// caller must state which of the two it is rather than silently inheriting `nil`.
    func dismissMessage(destinationFolderId: String?) {
        NotificationCenter.default.post(
            name: .messageDismissedFromDetail,
            object: viewModel.messageId,
            userInfo: destinationFolderId.map { [Self.dismissDestinationFolderIdKey: $0] })
        dismiss()
    }

    /// `userInfo` key carrying `dismissMessage`'s `destinationFolderId`.
    static let dismissDestinationFolderIdKey = "destinationFolderId"

    // MARK: - Agent Tool Compose

    /// Takes a compose card this screen's pill took: a new email opens from the account bound
    /// when its turn started, looked up in the app's accounts as the card is taken; when it is not
    /// there the request ends and nothing opens (`AgentToolRouter.canOpen`).
    func openAgentCompose(_ req: AgentToolRouter.ComposeRequest) {
        guard AgentToolRouter.shared.canOpen(req, accounts: navigationStore.accounts) else { return }
        agentCompose = req
    }

    /// The account a new email the agent asked for is sent from: the one bound when its turn
    /// started (`ComposeRequest.fromAccountId`), never whichever email this screen shows now,
    /// read from the same accounts `openAgentCompose` checked.
    func fromAccount(of req: AgentToolRouter.ComposeRequest) -> Account? {
        navigationStore.accounts.first { $0.id == req.fromAccountId }
    }

    func replyAllComposeView(for msg: MessageHeader) -> some View {
        let allAccounts = (try? AppDatabase.dbPool.read { db in try Account.fetchAll(db) }) ?? []
        let recipients = buildReplyAllRecipients(for: msg, allAccounts: allAccounts)
        return ComposeView(
            replyTo: msg,
            isReplyAll: true,
            prefillTo: recipients.to.isEmpty ? nil : recipients.to,
            prefillCc: recipients.cc.isEmpty ? nil : recipients.cc
        )
    }
}
