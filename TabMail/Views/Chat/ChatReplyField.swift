/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Observation

/// The chat's reply field (N2.6 to N7, A1 to A4, E1, E1b): the pill on the newest email becomes
/// [mic] [field] [Send]. The field holds the ready AI Reply's text message when there is one; Send
/// with it unchanged opens the compose card with the full AI Reply, and anything else the user says
/// or types goes to the agent on the newest email, as today's Chat pill on that email (section 3c).
struct ChatReplyField: Equatable {
    /// The ready AI Reply's text message; nil when there is none.
    let readyText: String?
    /// The newest email is from a no-reply address (E1).
    let isNoReply: Bool
    /// Changes when the field must empty: the reply went out (N7), or the agent answered in the
    /// sheet (A3).
    let clearCount: Int

    var placeholder: String { isNoReply ? "Ask anything" : "Reply or ask anything" }

    /// What Send does with the field's text.
    enum Route: Equatable {
        /// The ready AI Reply, unchanged: straight to the compose card, no agent (N2.6).
        case readyReply
        /// The user's own words: the agent (N4.4, A1).
        case agent
    }

    static func route(text: String, readyText: String?) -> Route {
        guard let readyText else { return .agent }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
            == readyText.trimmingCharacters(in: .whitespacesAndNewlines) ? .readyReply : .agent
    }

    /// Dictation in the collapsed field over the untouched ready AI Reply replaces it rather than
    /// adding to it (N4.3). Edited words, no ready reply, or the open chat sheet keep the text.
    static func dictationReplaces(input: String, readyText: String?, expanded: Bool) -> Bool {
        guard !expanded, let readyText else { return false }
        return input == readyText
    }

    /// The field's text once dictation brings `words`: they replace it when `replacing`, else they
    /// are added to what is there.
    static func dictated(_ words: String, onto input: String, replacing: Bool) -> String {
        DictationController.appending(words, to: replacing ? "" : input)
    }

    /// The ready AI Reply of the thread's newest email, as the field shows it: its text message,
    /// while the full reply is stored. Nothing for the user's own email or a no-reply sender.
    static func readyText(newest: MessageHeader, isOwn: Bool) -> String? {
        guard !isOwn, !EmailFilter.isNoReply(newest.fromAddress),
              let reply = newest.cachedReply, !reply.isEmpty,
              let text = newest.replyTextMessage, !text.isEmpty else { return nil }
        return text
    }

    /// The agent's message for words typed or said in the field: today's Chat pill message on the
    /// newest email (`Regarding [Email](N): …`), with a nudge that the words came from this
    /// email's reply field, so an unclear request is a reply to it (section 3c). For a no-reply
    /// sender the nudge says it takes no replies (E1.2).
    static func agentMessage(emailNumericId: Int, text: String, isNoReply: Bool) -> String {
        let nudge = isNoReply
            ? "typed in its reply field; the sender is a no-reply address, so do not write a reply to it"
            : "typed in its reply field; if what I want is unclear, I am replying to it"
        return "Regarding [Email](\(emailNumericId)) (\(nudge)): \(text)"
    }

    /// The line above the field while the agent works (A2.1): the agent's own labels, except that
    /// writing a reply reads "Writing your email" (N5.1).
    static func statusLine(_ label: String) -> String {
        label == ToolRegistry.activityLabels["email_reply"] ? "Writing your email" : label
    }
}

/// Replies sent from the chat whose email has no text message yet (N7). The bubble shows what the
/// user said, or the ready AI Reply's text message, until the email's own text message arrives.
/// In memory only: after a relaunch the sent email shows "Summarizing" until its summary lands.
@MainActor @Observable
final class ChatSentReplies {
    static let shared = ChatSentReplies()

    struct Entry: Identifiable, Equatable {
        let id = UUID()
        let accountId: String
        /// The Message-ID of the email the reply answers (the reply's In-Reply-To).
        let repliedTo: String
        let text: String
        let sentAt: Date
    }

    private(set) var entries: [Entry] = []

    func add(accountId: String, repliedTo: String, text: String, sentAt: Date = Date()) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        prune(now: sentAt)
        entries.append(Entry(accountId: accountId, repliedTo: repliedTo, text: text, sentAt: sentAt))
    }

    /// The entries for a chat whose emails have these Message-IDs.
    func entries(accountId: String, messageIds: Set<String>) -> [Entry] {
        entries.filter { $0.accountId == accountId && messageIds.contains($0.repliedTo) }
    }

    /// The entry that is this email's: the user's reply to `repliedTo`, dated from about when it
    /// was sent.
    static func entry(for header: MessageHeader, in entries: [Entry]) -> Entry? {
        guard let inReplyTo = header.inReplyTo else { return nil }
        return entries.first { entry in
            let earliest = entry.sentAt.addingTimeInterval(-ChatViewLayout.sentReplyDateSlack)
            return entry.accountId == header.accountId && entry.repliedTo == inReplyTo && header.date >= earliest
        }
    }

    /// Drops the entries whose email now has its own text message, and old ones.
    func settle(_ items: [ChatThread.Item], now: Date = Date()) {
        let done = Set(items.compactMap { item in
            item.textMessage != nil ? Self.entry(for: item.header, in: entries)?.id : nil
        })
        if !done.isEmpty { entries.removeAll { done.contains($0.id) } }
        prune(now: now)
    }

    private func prune(now: Date) {
        entries.removeAll { now.timeIntervalSince($0.sentAt) > ChatViewLayout.sentReplyLifetime }
    }

    #if DEBUG
    func removeAllForTesting() { entries = [] }
    #endif
}
