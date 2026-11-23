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
    /// The address epoch a search result carries: the witness for a row with no usable
    /// Message-ID (`ExpectedMessageIdentity`'s epoch arm).
    var expectedObservedUidValidity: Int? = nil
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
    /// Message-ID it found (`expectedRfc822MessageId`), or, for a row without one, the address
    /// epoch it found (`expectedObservedUidValidity`): a header that no longer matches is not the
    /// draft searched for, so it goes to the chat or the detail, which refuse a replaced message.
    nonisolated static func route(
        messageId: String, expectedRfc822MessageId: String? = nil, expectedObservedUidValidity: Int? = nil,
        opensInChat: Bool, pool: PrioritizedDatabase
    ) -> Route {
        let expected = ExpectedMessageIdentity(
            capturedRfc822MessageId: expectedRfc822MessageId,
            capturedObservedUidValidity: expectedObservedUidValidity)
        let draft: MessageHeader? = try? pool.read { db in
            guard let header = try MessageHeader.fetchOne(db, key: messageId),
                  expected?.matches(header) ?? true,
                  try Folder.fetchOne(db, key: header.folderId)?.role == .drafts else { return nil }
            return header
        }
        if let draft { return .draftEditor(draft) }
        return opensInChat ? .chat : .detail
    }

    /// This open's route, the one its body shows: its address with every witness it carries, and
    /// the Chat View choice it took when it was made.
    func route(pool: PrioritizedDatabase) -> Route {
        Self.route(messageId: messageId, expectedRfc822MessageId: expectedRfc822MessageId,
                   expectedObservedUidValidity: expectedObservedUidValidity,
                   opensInChat: opensInChat, pool: pool)
    }

    var body: some View {
        switch route(pool: AppDatabase.dbPool) {
        case .draftEditor(let header):
            DraftComposePresenter(source: .header(header), presentedAsCover: false)
        case .chat:
            chat
        case .detail:
            detail
        }
    }

    /// The chat this open shows, carrying the open's witnesses to its view model.
    var chat: ChatThreadView {
        ChatThreadView(
            messageId: messageId,
            expectedRfc822MessageId: expectedRfc822MessageId,
            expectedObservedUidValidity: expectedObservedUidValidity,
            highlightsOpenedMessage: highlightsMessage)
    }

    /// Today's detail this open shows, carrying the open's witnesses to its view model.
    var detail: MessageDetailView {
        MessageDetailView(
            messageId: messageId,
            opensWithSkeletonDwell: opensWithSkeletonDwell,
            expectedRfc822MessageId: expectedRfc822MessageId,
            expectedObservedUidValidity: expectedObservedUidValidity)
    }
}
