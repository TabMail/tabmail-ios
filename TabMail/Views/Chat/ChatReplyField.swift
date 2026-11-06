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
    /// The reply goes only to these people (R2); nil for Reply All.
    var onlyTo: [ChatThread.Person]? = nil

    var placeholder: String { isNoReply ? "Ask anything" : "Reply or ask anything" }

    /// What Send does with the field's text.
    enum Route: Equatable {
        /// The ready AI Reply, unchanged: straight to the compose card, no agent (N2.6).
        case readyReply
        /// The user's own words: the agent (N4.4, A1).
        case agent
    }

    /// With recipients changed the ready AI Reply was written for everyone, so Send has the agent
    /// write it again for the people chosen (R2.4, Q33).
    static func route(text: String, readyText: String?, recipientsChanged: Bool = false) -> Route {
        guard let readyText, !recipientsChanged else { return .agent }
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
    /// With recipients chosen (R2) the nudge names them: a reply goes only to them.
    static func agentMessage(
        emailNumericId: Int, text: String, isNoReply: Bool, onlyTo: [ChatThread.Person]? = nil
    ) -> String {
        var nudge = isNoReply
            ? "typed in its reply field; the sender is a no-reply address, so do not write a reply to it"
            : "typed in its reply field; if what I want is unclear, I am replying to it"
        if let onlyTo, !onlyTo.isEmpty {
            let people = onlyTo.map { "\($0.name) <\($0.address)>" }.joined(separator: ", ")
            nudge += "; a reply goes only to \(people)"
        }
        return "Regarding [Email](\(emailNumericId)) (\(nudge)): \(text)"
    }

    /// The line above the field while the agent works (A2.1): the agent's own labels, except that
    /// writing a reply reads "Writing your email" (N5.1).
    static func statusLine(_ label: String) -> String {
        label == ToolRegistry.activityLabels["email_reply"] ? "Writing your email" : label
    }
}

/// Whose words are in the reply field (N2.7, N4.3): the ready AI Reply fills the field only while
/// it is the app's, and only over an empty field or the AI Reply the app itself put there, so a
/// late reply never lands on words the user typed or said, in the field or in the open chat sheet.
/// Every event that can hand the field to the user, or back, is decided here, in one place.
struct ChatFieldFill: Equatable {
    /// The user has the field: they changed it while collapsed, or a send or an answer emptied it.
    private(set) var isUsers = false
    /// The AI Reply the app last put in the field: only it, or nothing, may be replaced.
    private(set) var filled: String?
    /// The field's words when the user last sent, from the field or from the open sheet; nil once
    /// a completion emptied it. An answer or a sent reply completes that send, so it empties only
    /// those words: words the user typed after it, in the open sheet, are newer and stay.
    private(set) var atSend: String?

    /// The field's words once the ready AI Reply `ready` is offered, or nil to leave them as they
    /// are: while the field is the app's, collapsed, with nothing sent and no dictation running,
    /// over an empty field or the AI Reply the app put there. Offered again when the sheet closes
    /// and when a dictation ends, so a reply that arrived meanwhile is not lost.
    mutating func offer(_ ready: String?, input: String, expanded: Bool, sent: Bool, dictating: Bool) -> String? {
        guard !isUsers, !expanded, !sent, !dictating, input.isEmpty || input == filled else { return nil }
        filled = ready
        return ready ?? ""
    }

    /// The field's words changed. Collapsed, words other than the AI Reply the app put there are
    /// the user's; words left in the sheet are kept by `offer`, which never replaces them.
    mutating func edited(_ input: String, expanded: Bool) {
        guard !expanded, input != (filled ?? "") else { return }
        isUsers = true
    }

    /// A new newest email: an empty field is the app's again, and its ready AI Reply fills it.
    mutating func newEmail(input: String) {
        guard input.isEmpty else { return }
        isUsers = false
    }

    /// The user sent with `input` in the field.
    mutating func sent(input: String) {
        atSend = input
    }

    /// Whether the completion of the last send (the agent answered, or the reply went out) may
    /// empty the field holding `input`: it still holds the words sent, nothing, or the AI Reply the
    /// app put there. Anything else the user wrote after the send.
    func clears(_ input: String) -> Bool {
        guard let atSend else { return true }
        return input == atSend || input.isEmpty || input == filled
    }

    /// The reply went out, or the agent answered in the sheet: the field empties and stays empty.
    mutating func cleared() {
        isUsers = true
        atSend = nil
    }
}

/// Who the chat's next reply goes to (R1, R2): Reply All, or only the people chosen in Reply to.
struct ChatReplyTarget: Equatable {
    /// Nil: Reply All, the newest email's people (R1.3).
    let only: [ChatThread.Person]?

    static let replyAll = ChatReplyTarget(only: nil)

    /// Done in Reply to: everyone on the newest email ticked and nobody added is Reply All.
    static func chosen(_ ticked: [ChatThread.Person], replyPeople: [ChatThread.Person]) -> ChatReplyTarget {
        Set(ticked.map(\.address)) == Set(replyPeople.map(\.address)) ? .replyAll : ChatReplyTarget(only: ticked)
    }

    /// The "Replying only to" chips: up to `nameCount` names, then how many more (R2.3).
    static func chips(_ people: [ChatThread.Person], nameCount: Int = ChatViewLayout.headerNameCount) -> (names: [String], more: Int) {
        (people.prefix(nameCount).map(\.name), max(0, people.count - nameCount))
    }
}

/// A compose card the agent opens in the chat. `fromField`: it was asked for in the collapsed reply
/// field, not in the open chat sheet.
enum ChatAgentCompose {
    /// The words the chat shows as the Sent bubble once the card sends (N7): only a reply asked for
    /// in the field shows the field's words.
    static func sentWords(mode: AgentToolRouter.ComposeRequest.Mode, fromField: Bool, fieldWords: String?) -> String? {
        mode == .reply && fromField ? fieldWords : nil
    }

    /// Who a reply goes to (R1): asked for in the field with people chosen in Reply to, only them;
    /// otherwise the agent's own recipients.
    static func replyRecipients(
        fromField: Bool, target: ChatReplyTarget, to: [String], cc: [String]
    ) -> (to: [String], cc: [String]) {
        guard fromField, let only = target.only else { return (to, cc) }
        return (only.map(\.address), [])
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

    /// A compose card opened from the chat ended. Only a sent one counts: a sent reply keeps the
    /// user's words as its Sent bubble until its email's text message arrives, and the caller empties
    /// the field. A cancelled or failed card changes nothing. Returns whether it was sent.
    @discardableResult
    func composeEnded(_ outcome: ComposeOutcome, replyTo: MessageHeader?, words: String?) -> Bool {
        guard case .sent = outcome else { return false }
        if let replyTo, let repliedTo = replyTo.rfc822MessageId, let words {
            add(accountId: replyTo.accountId, repliedTo: repliedTo, text: words)
        }
        return true
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
