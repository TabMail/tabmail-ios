/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// Value-type snapshot of a MessageHeader for safe SwiftUI rendering.
/// With GRDB, MessageHeader is already a value type, but snapshots are still
/// useful for the inbox list: they hold only the fields the list row needs
/// and support in-place mutation (optimistic UI) without touching the database.
struct MessageSnapshot: Identifiable, Hashable, Sendable {
    let id: String
    let accountId: String
    let messageId: String
    let threadId: String?
    let computedThreadId: String
    let rfc822MessageId: String?
    let inReplyTo: String?
    let references: [String]
    let subject: String
    let from: String
    let fromAddress: String
    let to: String
    let date: Date
    var snippet: String
    var isRead: Bool
    var isFlagged: Bool
    let hasAttachments: Bool
    let isReplied: Bool
    let isForwarded: Bool
    var actionTag: ActionTag?
    // var (not let): reloadMessages' Pass-1 carries over a staged row's
    // tagSortOrder alongside its actionTag when a fresh (phase-1/sync) row
    // arrives with actionTag == nil — see ADR-IOS-049 AI-field carry-over.
    var tagSortOrder: Int
    var summaryBlurb: String?
    var isInInbox: Bool
    var hasReplyReady: Bool
    var isReplyProcessed: Bool // cachedReply != nil (includes empty sentinel for filtered messages)
    var userLabels: [UserLabel]

    init(from header: MessageHeader, userLabels: [UserLabel] = []) {
        self.id = header.id
        self.accountId = header.accountId
        self.messageId = header.messageId
        self.threadId = header.threadId
        self.computedThreadId = header.computedThreadId
        self.rfc822MessageId = header.rfc822MessageId
        self.inReplyTo = header.inReplyTo
        self.references = header.references
        self.subject = header.subject
        self.from = header.from
        self.fromAddress = header.fromAddress
        self.to = header.to
        self.date = header.date
        self.snippet = header.snippet
        self.isRead = header.isRead
        self.isFlagged = header.isFlagged
        self.hasAttachments = header.hasAttachments
        self.isReplied = header.isReplied
        self.isForwarded = header.isForwarded
        self.actionTag = header.actionTag
        self.tagSortOrder = header.tagSortOrder
        self.summaryBlurb = header.summaryBlurb
        self.isInInbox = header.isInInbox
        self.hasReplyReady = header.cachedReply != nil && !header.cachedReply!.isEmpty
        self.isReplyProcessed = header.cachedReply != nil
        self.userLabels = userLabels
    }

    /// Stable identifier that survives IMAP MOVE (uses rfc822MessageId when available).
    /// Mirrors MessageHeader.stableId logic.
    var stableId: String {
        if UInt32(messageId) != nil, let rfc822 = rfc822MessageId, !rfc822.isEmpty {
            return rfc822
        }
        return messageId
    }
}
