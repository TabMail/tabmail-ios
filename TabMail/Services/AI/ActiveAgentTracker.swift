/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

extension Notification.Name {
    /// Posted when an agent session finishes (removed from working set).
    /// userInfo contains "sessionKey": String.
    static let agentSessionDidFinish = Notification.Name("AgentSessionDidFinish")
    /// Posted when the user taps an agent toast to navigate to a message with chat open.
    /// userInfo contains "messageId": String.
    static let openMessageWithChat = Notification.Name("OpenMessageWithChat")
}

/// Tracks which chat sessions currently have an agent working.
/// Used by UI components across views to show working indicators (pill shimmer,
/// message row glow, compose icon pulse) even when the user navigates away from
/// the view that launched the agent.
@MainActor @Observable
final class ActiveAgentTracker {
    static let shared = ActiveAgentTracker()

    /// Session keys with active agent work. E.g. "inbox", "msg:acct:stableId", "compose:draftId".
    private(set) var workingSessions: Set<String> = []

    /// Last response text per session key (for toast when agent finishes while user is on a different view).
    @ObservationIgnored
    private var _pendingResponses: [String: String] = [:]

    var anyWorking: Bool { !workingSessions.isEmpty }

    func setWorking(_ sessionKey: String) {
        workingSessions.insert(sessionKey)
    }

    func clearWorking(_ sessionKey: String) {
        workingSessions.remove(sessionKey)
        // Post notification so InboxView can show toast from pending response.
        // Pending response is NOT cleared here — the notification handler consumes it.
        // If no handler consumes it (e.g., InboxView not mounted), the entry stays
        // until consumed on next navigation. Bounded by session count (typically 0-3).
        NotificationCenter.default.post(
            name: .agentSessionDidFinish,
            object: nil,
            userInfo: ["sessionKey": sessionKey]
        )
    }

    func setPendingResponse(_ sessionKey: String, text: String) {
        _pendingResponses[sessionKey] = text
    }

    func consumePendingResponse(_ sessionKey: String) -> String? {
        _pendingResponses.removeValue(forKey: sessionKey)
    }

    /// Check if a message-detail session is working for a given stableId.
    func isMessageWorking(accountId: String, stableId: String) -> Bool {
        workingSessions.contains("msg:\(accountId):\(stableId)")
    }

    /// Whether any compose session is working (for compose button glow).
    var anyComposeWorking: Bool {
        workingSessions.contains { $0.hasPrefix("compose:") }
    }

    /// The draftId of the currently working compose session, if any.
    var workingComposeDraftId: String? {
        workingSessions.first { $0.hasPrefix("compose:") }.map { String($0.dropFirst("compose:".count)) }
    }

    /// Whether any non-inbox session is working (message-detail or compose).
    var anyBackgroundWorking: Bool {
        workingSessions.contains { $0 != "inbox" }
    }

    /// Extract the message stableId from a "msg:accountId:stableId" session key, if applicable.
    static func messageStableId(from sessionKey: String) -> (accountId: String, stableId: String)? {
        guard sessionKey.hasPrefix("msg:") else { return nil }
        let rest = String(sessionKey.dropFirst(4))
        guard let colonIdx = rest.firstIndex(of: ":") else { return nil }
        let accountId = String(rest[rest.startIndex..<colonIdx])
        let stableId = String(rest[rest.index(after: colonIdx)...])
        return (accountId, stableId)
    }
}
