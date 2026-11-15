/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import GRDB
import SwiftUI

/// Opens a message from any open path (a folder, search, a notification, a reminder, an email
/// reference): a draft in the draft editor, as from Drafts (the chat leaves drafts out);
/// anything else as a chat when the chat view is on, else in today's detail. The chat view
/// setting is snapshotted once per open, so a Settings change applies to the next open.
struct MessageOpenView: View {
    let messageId: String
    var expectedRfc822MessageId: String?
    var opensWithSkeletonDwell = false
    /// Opened from search or a notification: the chat scrolls to this email and its bubble
    /// glows briefly.
    var highlightsMessage = false
    @State private var opensInChat = ChatViewConfig.opensInChat

    /// Where an open goes.
    enum Route: Equatable {
        /// A message in a Drafts folder: the draft editor (`DraftComposePresenter`).
        case draftEditor(MessageHeader)
        case chat
        case detail
    }

    /// The open's route: a Drafts-folder message goes to the draft editor whatever the chat view
    /// setting; anything else, a message not found included, to the chat or today's detail. One
    /// read transaction, so the header and its folder agree. A search result carries the
    /// Message-ID it found (`expectedRfc822MessageId`): a header that no longer has it is not the
    /// draft searched for, so it goes to the chat or the detail, which refuse a replaced message.
    nonisolated static func route(
        messageId: String, expectedRfc822MessageId: String? = nil, opensInChat: Bool, pool: PrioritizedDatabase
    ) -> Route {
        let expected = ExpectedMessageIdentity(capturedRfc822MessageId: expectedRfc822MessageId)
        let draft: MessageHeader? = try? pool.read { db in
            guard let header = try MessageHeader.fetchOne(db, key: messageId),
                  expected?.matches(header) ?? true,
                  try Folder.fetchOne(db, key: header.folderId)?.role == .drafts else { return nil }
            return header
        }
        if let draft { return .draftEditor(draft) }
        return opensInChat ? .chat : .detail
    }

    var body: some View {
        switch Self.route(messageId: messageId, expectedRfc822MessageId: expectedRfc822MessageId,
                          opensInChat: opensInChat, pool: AppDatabase.dbPool) {
        case .draftEditor(let header):
            DraftComposePresenter(source: .header(header))
        case .chat:
            ChatThreadView(
                messageId: messageId,
                expectedRfc822MessageId: expectedRfc822MessageId,
                highlightsOpenedMessage: highlightsMessage)
        case .detail:
            MessageDetailView(
                messageId: messageId,
                opensWithSkeletonDwell: opensWithSkeletonDwell,
                expectedRfc822MessageId: expectedRfc822MessageId)
        }
    }
}
