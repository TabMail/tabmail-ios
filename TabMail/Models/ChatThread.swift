/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// A thread as the chat view shows it: every email as a bubble, oldest first, and the people the
/// next reply goes to. Pure: built from headers the caller already read.
struct ChatThread: Equatable {

    struct Person: Hashable {
        /// Lowercased address.
        let address: String
        let name: String

        /// Up to two letters for the avatar: the first letters of the first two words of the name,
        /// or of the address when there is no name.
        var initials: String {
            let words = name.split(whereSeparator: { $0.isWhitespace || $0 == "." || $0 == "," })
            let letters = words.prefix(2).compactMap { $0.first }
            let text = letters.isEmpty ? String(address.prefix(1)) : String(letters)
            return text.uppercased()
        }

        /// A stable pick among `count` colors, the same on every launch (Swift's `hashValue` is
        /// randomized per process, so it is not used).
        func colorIndex(count: Int) -> Int {
            guard count > 0 else { return 0 }
            return address.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0x7fffffff } % count
        }
    }

    struct Item: Identifiable, Equatable {
        var id: String { header.id }
        let header: MessageHeader
        /// Written by the user: a blue bubble on the right.
        let isOwn: Bool
        let sender: Person
        /// The bubble's text message; nil while it is being summarized (N2b). An email with
        /// nothing to summarize is done without one (`MessageHeader.noContentSummary`): its bubble
        /// says so, never "Summarizing".
        var textMessage: String? {
            if let text = header.summaryTextMessage, !text.isEmpty { return text }
            return header.summaryBlurb == MessageHeader.noContentSummary ? MessageHeader.noContentSummary : nil
        }
        /// The email did not go to everyone in the chat: who it went to (R3). Nil for an email to
        /// everyone.
        let repliedOnlyTo: OnlyTo?
        /// A time stamp goes above this bubble.
        let showsTimeStamp: Bool
        /// The "Unread" line goes above this bubble (O1).
        let showsUnreadLine: Bool
    }

    /// The people an email went to when it did not go to everyone in the chat (R3).
    struct OnlyTo: Equatable {
        /// The user was one of them.
        let includesYou: Bool
        /// Everyone else it went to, in its To then Cc order.
        let people: [Person]

        /// "you" first, then the names.
        var names: [String] { (includesYou ? ["you"] : []) + people.map(\.name) }

        /// The gray label: up to `nameCount` names, then "+N" (R3.4).
        func label(nameCount: Int = ChatViewLayout.headerNameCount) -> String {
            let shown = names.prefix(nameCount).joined(separator: ", ")
            let rest = names.count - min(names.count, nameCount)
            return rest > 0 ? "\(shown) +\(rest)" : shown
        }
    }

    let items: [Item]
    /// Who the next reply goes to: the newest email's Reply All set (N2.1).
    let replyPeople: [Person]
    /// More than one other person: bubbles carry the sender's avatar and name (N2.11).
    let isGroup: Bool

    var newest: MessageHeader? { items.last?.header }

    /// - Parameters:
    ///   - members: the opened email and the rest of its thread, in any order.
    ///   - replyAddresses: an email's Reply All recipients (`buildReplyAllRecipients`), To then
    ///     Cc; asked for the newest email.
    ///   - ownAddresses: the user's addresses, lowercased.
    ///   - draftFolderIds / sentFolderIds: folders whose emails are drafts (left out, Q22) or the
    ///     user's own.
    ///   - unreadAtOpen: emails that were unread when the chat opened (the Unread line).
    ///   - preferredId: the copy to keep when one email sits in two folders (the opened one).
    init(
        members: [MessageHeader],
        replyAddresses: (MessageHeader) -> [String],
        ownAddresses: Set<String>,
        draftFolderIds: Set<String>,
        sentFolderIds: Set<String>,
        unreadAtOpen: Set<String>,
        preferredId: String?,
        timeStampGap: TimeInterval = ChatViewLayout.timeStampGap
    ) {
        let kept = Self.oneCopyEach(
            members.filter { !draftFolderIds.contains($0.folderId) }, preferredId: preferredId)
            .sorted { ($0.date, $0.id) < ($1.date, $1.id) }
        let names = Self.names(in: kept)
        /// Everyone on the emails so far (R3).
        var chatPeople = Set<String>()

        var items: [Item] = []
        var unreadLineShown = false
        for header in kept {
            let address = header.fromAddress.lowercased()
            let isOwn = ownAddresses.contains(address) || sentFolderIds.contains(header.folderId)
            let previous = items.last?.header.date
            let showsUnread = !unreadLineShown && unreadAtOpen.contains(header.id)
            if showsUnread { unreadLineShown = true }
            items.append(Item(
                header: header,
                isOwn: isOwn,
                sender: Person(address: address, name: Self.name(for: address, header: header, names: names)),
                repliedOnlyTo: Self.onlyTo(header, chatPeople: chatPeople, ownAddresses: ownAddresses, names: names),
                showsTimeStamp: previous.map { header.date.timeIntervalSince($0) >= timeStampGap } ?? true,
                showsUnreadLine: showsUnread))
            chatPeople.formUnion(Self.audience(of: header, ownAddresses: ownAddresses))
        }
        self.items = items

        var seen = Set<String>()
        self.replyPeople = (items.last.map { replyAddresses($0.header) } ?? [])
            .map { $0.lowercased() }
            .filter { !ownAddresses.contains($0) && seen.insert($0).inserted }
            .map { Person(address: $0, name: names[$0] ?? Self.fallbackName($0)) }

        var others = Set(replyPeople.map(\.address))
        for item in items where !item.isOwn { others.insert(item.sender.address) }
        self.isGroup = others.count > 1
    }

    /// Stands for the user in an audience, whichever of their addresses an email used.
    private static let you = "\u{0}you"

    /// Everyone on an email: its sender and its To and Cc, lowercased, the user as one person.
    static func audience(of header: MessageHeader, ownAddresses: Set<String>) -> Set<String> {
        var people = Set(recipients(of: header).map(\.address))
        people.insert(header.fromAddress.lowercased())
        return Set(people.map { ownAddresses.contains($0) ? you : $0 })
    }

    /// An email's To then Cc recipients, lowercased, each once.
    private static func recipients(of header: MessageHeader) -> [(address: String, name: String?)] {
        var seen = Set<String>()
        return [header.to, header.cc].flatMap { RecipientEntry($0).recipients }
            .map { (address: $0.address.lowercased(), name: $0.name) }
            .filter { seen.insert($0.address).inserted }
    }

    /// Who an email went to, when it left out someone already in the chat: on an earlier email
    /// (R3.2, R3.3). Someone new on an email joins the chat's people, so adding a person alone is
    /// not "only", and an email is never "only" for people who joined after it.
    private static func onlyTo(
        _ header: MessageHeader, chatPeople: Set<String>, ownAddresses: Set<String>, names: [String: String]
    ) -> OnlyTo? {
        guard !chatPeople.subtracting(audience(of: header, ownAddresses: ownAddresses)).isEmpty else { return nil }
        let sender = header.fromAddress.lowercased()
        let others = recipients(of: header).filter { $0.address != sender }
        let includesYou = others.contains { ownAddresses.contains($0.address) }
        let people = others.filter { !ownAddresses.contains($0.address) }
            .map { Person(address: $0.address, name: names[$0.address] ?? Self.fallbackName($0.address)) }
        guard includesYou || !people.isEmpty else { return nil }
        return OnlyTo(includesYou: includesYou, people: people)
    }


    /// What makes two headers copies of one email (`copyKey`): its RFC Message-ID; without one, a
    /// provider id that names the message itself (Gmail, Exchange), in its account; else the row.
    /// An IMAP UID only numbers a message inside one folder, so two headers with the same UID and no
    /// Message-ID are two emails, never copies (`MessageHeader.stableId` falls back to the bare UID).
    static func copyKey(_ header: MessageHeader) -> String {
        if let rfc822 = header.rfc822MessageId, !rfc822.isEmpty { return "rfc:\(rfc822)" }
        if UInt32(header.messageId) == nil { return "id:\(header.accountId):\(header.messageId)" }
        return "row:\(header.id)"
    }

    /// One header per email: copies of one message in two folders share a `copyKey`. Keeps the
    /// opened copy, else one with a text message, else the first.
    static func oneCopyEach(_ headers: [MessageHeader], preferredId: String?) -> [MessageHeader] {
        var order: [String] = []
        var chosen: [String: MessageHeader] = [:]
        for header in headers {
            let key = Self.copyKey(header)
            guard let current = chosen[key] else {
                order.append(key)
                chosen[key] = header
                continue
            }
            if current.id == preferredId { continue }
            if header.id == preferredId || (current.summaryTextMessage == nil && header.summaryTextMessage != nil) {
                chosen[key] = header
            }
        }
        return order.compactMap { chosen[$0] }
    }

    /// Display names by lowercased address, from every sender and recipient in the thread.
    static func names(in headers: [MessageHeader]) -> [String: String] {
        var names: [String: String] = [:]
        for header in headers {
            for field in [header.to, header.cc] {
                for recipient in RecipientEntry(field).recipients {
                    if let name = recipient.name, !name.isEmpty {
                        names[recipient.address.lowercased()] = name
                    }
                }
            }
        }
        // Senders last: a From name is what the person calls themselves.
        for header in headers where !header.from.isEmpty && header.from.lowercased() != header.fromAddress.lowercased() {
            names[header.fromAddress.lowercased()] = header.from
        }
        return names
    }

    private static func name(for address: String, header: MessageHeader, names: [String: String]) -> String {
        names[address] ?? (header.from.isEmpty ? fallbackName(address) : header.from)
    }

    /// An address with no name: its part before the @.
    static func fallbackName(_ address: String) -> String {
        address.split(separator: "@").first.map(String.init) ?? address
    }

    /// The header line: up to `nameCount` names, then "+N" (Q34).
    static func headerTitle(_ people: [Person], nameCount: Int = ChatViewLayout.headerNameCount) -> String {
        let shown = people.prefix(nameCount).map(\.name).joined(separator: ", ")
        let rest = people.count - min(people.count, nameCount)
        return rest > 0 ? "\(shown) +\(rest)" : shown
    }
}
