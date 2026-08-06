/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// Extracted thread grouping algorithm from InboxViewModel for testability.
/// Groups messages by computedThreadId — a unified thread identifier assigned at insert time.
/// Gmail/Exchange: copied from native threadId. IMAP: computed via chain-walking inReplyTo/References.
enum ThreadGroupBuilder {
    /// Strict less-than comparator for ThreadGroup ordering in `displayGroups`.
    /// Normal mode: date descending, stable tie-break by id ascending.
    /// Triage mode: threadTag.sortOrder ascending (reply/0 → none/1 → archive/2 → delete/3 → untagged/99),
    /// then date descending, then id ascending.
    /// Used by `buildDisplayGroups` and by `InboxViewModel.rebuildDisplayGroups`
    /// (both insert-position search and full re-sort) so all paths agree.
    static func areInIncreasingOrder(_ a: ThreadGroup, _ b: ThreadGroup, mode: InboxMode) -> Bool {
        if mode == .triage {
            let aSort = a.threadTag?.sortOrder ?? 99
            let bSort = b.threadTag?.sortOrder ?? 99
            if aSort != bSort { return aSort < bSort }
        }
        if a.representative.date != b.representative.date {
            return a.representative.date > b.representative.date
        }
        return a.id < b.id
    }

    /// Build display groups from a list of message snapshots.
    /// Groups by computedThreadId (non-empty values only).
    /// Returns groups sorted by `areInIncreasingOrder(_:_:mode:)` — date-desc in normal mode,
    /// tagSortOrder-asc + date-desc in triage mode.
    static func buildDisplayGroups(from messages: [MessageSnapshot], mode: InboxMode = .normal) -> [ThreadGroup] {
        // Group by computedThreadId
        var groups: [String: [MessageSnapshot]] = [:]
        var groupOrder: [String] = []

        for snapshot in messages {
            let key = snapshot.computedThreadId.isEmpty ? snapshot.id : snapshot.computedThreadId
            if groups[key] == nil { groupOrder.append(key) }
            groups[key, default: []].append(snapshot)
        }

        var result = groupOrder.compactMap { key -> ThreadGroup? in
            guard var members = groups[key], !members.isEmpty else { return nil }
            // Sort members by date descending (most recent first), with the shared
            // `id` tie-break so `representative` and `allSenders` are a function of
            // the data and not of `Array.sort`'s (deliberately unspecified)
            // stability. `.normal` is passed DELIBERATELY, not by omission: a
            // thread's internal order is newest-first in BOTH list modes — triage's
            // `tagSortOrder` ranks the GROUP against other groups
            // (`areInIncreasingOrder` below, via `threadTag`), never one member
            // against its siblings. Only the tie-break is shared here.
            members.sort { InboxOrdering.areInIncreasingOrder($0, $1, mode: .normal) }
            let representative = members[0]

            // Collect unique senders (preserving order of most-recent-first)
            var seenSenders: Set<String> = []
            var allSenders: [String] = []
            for member in members {
                if seenSenders.insert(member.from).inserted {
                    allSenders.append(member.from)
                }
            }

            // Thread tag: highest priority (lowest sortOrder) among all members
            let threadTag = members.compactMap(\.actionTag).min(by: { $0.sortOrder < $1.sortOrder })

            let hasUnread = members.contains { !$0.isRead }

            return ThreadGroup(
                id: key,
                representative: representative,
                memberCount: members.count,
                allSenders: allSenders,
                threadTag: threadTag,
                hasUnread: hasUnread,
                members: members
            )
        }

        // Sort groups with mode-aware comparator.
        // Normal: most recent date first.
        // Triage: tagSortOrder ascending first (reply at top), then date descending.
        result.sort { areInIncreasingOrder($0, $1, mode: mode) }

        return result
    }
}
