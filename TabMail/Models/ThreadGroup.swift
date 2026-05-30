/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// Thread display info passed to MessageRowView for thread-aware rendering.
struct ThreadDisplayInfo {
    let senderList: String
    let memberCount: Int
    let threadTag: ActionTag?
    let hasUnread: Bool
    /// True when every inbox member of this thread has an actionTag.
    /// When false, the spinner should still show even if threadTag is non-nil
    /// (one member got tagged but others are still processing).
    let allMembersTagged: Bool
    /// True when any member with an actionTag still has no cached reply (AI reply not yet generated).
    /// Used to show shimmer on the thread-level tag badge.
    let anyMemberStillProcessingReply: Bool
    /// Union of user labels across all thread members (deduped by ID, sorted alphabetically).
    let unionLabels: [UserLabel]
}

/// A group of messages sharing the same thread (by normalized subject or provider threadId).
/// Single messages are represented as groups with memberCount == 1.
struct ThreadGroup: Identifiable, Equatable {
    let id: String
    var isThread: Bool { memberCount > 1 }
    var representative: MessageSnapshot
    var memberCount: Int
    var allSenders: [String]
    var threadTag: ActionTag?
    var hasUnread: Bool
    var members: [MessageSnapshot]

    /// Build a ThreadDisplayInfo for passing to MessageRowView.
    var displayInfo: ThreadDisplayInfo? {
        guard isThread else { return nil }
        let inboxMembers = members.filter({ $0.isInInbox })
        let allTagged = inboxMembers.allSatisfy { $0.actionTag != nil }
        let anyStillProcessing = inboxMembers.contains { $0.actionTag != nil && !$0.isReplyProcessed }
        // Union of user labels across all thread members, deduped by ID
        var seenIds: Set<String> = []
        var union: [UserLabel] = []
        for member in members {
            for label in member.userLabels {
                if seenIds.insert(label.id).inserted {
                    union.append(label)
                }
            }
        }
        union.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return ThreadDisplayInfo(
            senderList: allSenders.joined(separator: ", "),
            memberCount: memberCount,
            threadTag: threadTag,
            hasUnread: hasUnread,
            allMembersTagged: allTagged,
            anyMemberStillProcessingReply: anyStillProcessing,
            unionLabels: union
        )
    }
}
