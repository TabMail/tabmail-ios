/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import SwiftUI

/// One email of the chat: a gray bubble on the left from someone else, a blue one on the right
/// from the user. Text only; tapping it opens the email card.
struct ChatBubbleView: View {
    let item: ChatThread.Item
    let isGroup: Bool
    let extras: ChatMemberExtras?
    let isHighlighted: Bool
    /// VoiceOver's actions for this email's swipe and the chat's, on the bubble itself.
    var actions: [ChatSwipeButton] = []
    let onOpen: () -> Void

    var body: some View {
        VStack(alignment: item.isOwn ? .trailing : .leading, spacing: 4) {
            HStack(alignment: .bottom, spacing: 8) {
                if item.isOwn { Spacer(minLength: 0) }
                if showsSender {
                    ChatAvatar(person: item.sender, size: ChatViewLayout.avatarSize)
                        .contentShape(.contextMenuPreview, Circle())
                        .copyAddressMenu(AddressCopy.person(item.sender))
                }
                VStack(alignment: item.isOwn ? .trailing : .leading, spacing: 4) {
                    if showsSender || item.repliedOnlyTo != nil {
                        nameLine
                    }
                    bubble
                    if let names = extras?.attachmentNames, !names.isEmpty {
                        let chips = Self.attachmentChips(names)
                        ForEach(Array(chips.names.enumerated()), id: \.offset) { _, name in
                            attachmentChip(name)
                        }
                        if chips.more > 0 { moreChip(chips.more) }
                    }
                    if let invite = extras?.invite {
                        ChatInviteCard(invite: invite)
                    }
                    if item.isOwn {
                        Text("Sent")
                            .font(.caption2)
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                .containerRelativeFrame(.horizontal, alignment: item.isOwn ? .trailing : .leading) { width, _ in
                    width * ChatViewLayout.bubbleMaxWidthFraction
                }
                if !item.isOwn { Spacer(minLength: 0) }
            }
        }
        .padding(.horizontal)
    }

    private var showsSender: Bool { isGroup && !item.isOwn }

    /// The sender's name line above the bubble.
    private var nameLine: some View { ChatSenderLine(item: item) }

    /// The full list: "You" for the user.
    static func listNames(_ only: ChatThread.OnlyTo) -> [String] {
        (only.includesYou ? ["You"] : []) + only.people.map(\.name)
    }

    private var bubble: some View {
        Button(action: onOpen) {
            // As wide as the wider of the words and the Details pin (`ChatBubbleStack`).
            ChatBubbleStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 6) {
                    if let text = item.textMessage {
                        Text(text)
                            .font(.body)
                            .foregroundStyle(item.isOwn ? Color.white : Theme.textPrimary)
                            .multilineTextAlignment(.leading)
                    } else {
                        // Still being summarized; already tappable.
                        Text(item.header.subject.isEmpty ? "(No subject)" : item.header.subject)
                            .font(.body)
                            .foregroundStyle(item.isOwn ? Color.white : Theme.textPrimary)
                            .lineLimit(2)
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.mini)
                                .tint(item.isOwn ? Color.white : Theme.textSecondary)
                            Text("Summarizing")
                                .font(.caption)
                                .foregroundStyle(item.isOwn ? Color.white.opacity(0.8) : Theme.textSecondary)
                        }
                    }
                }
                HStack(spacing: 2) {
                    Text("Details")
                    Image(systemName: "chevron.right")
                }
                .font(.caption2)
                .foregroundStyle(item.isOwn ? Color.white.opacity(0.75) : Theme.textSecondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: ChatViewLayout.bubbleCornerRadius)
                    .fill(item.isOwn ? Theme.accent : Palette.chatIncomingBubble)
            )
            .overlay(
                RoundedRectangle(cornerRadius: ChatViewLayout.bubbleCornerRadius)
                    .stroke(Theme.accent, lineWidth: isHighlighted ? 3 : 0)
                    .shadow(color: Theme.accent.opacity(isHighlighted ? 0.6 : 0), radius: 8)
            )
            .animation(.easeInOut(duration: 0.3), value: isHighlighted)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityHint("Opens the email")
        .accessibilityIdentifier(isHighlighted ? Self.highlightedBubbleId : Self.bubbleId)
        .accessibilityAddTraits(.isButton)
        .accessibilityActions {
            ForEach(actions) { action in
                Button(action.title, action: action.action)
            }
            // The avatar's "Copy Address": VoiceOver does not reach the avatar.
            if showsSender, let copy = AddressCopy.accessibilityAction(AddressCopy.person(item.sender)) {
                Button(copy.title) { AddressCopy.copy(copy.item) }
            }
        }
    }

    /// The bubble's identifier, and the one it has while it glows (an email opened from search or
    /// a notification), so a test can tell which bubble glows. VoiceOver does not read either.
    static let bubbleId = "chat.bubble"
    static let highlightedBubbleId = "chat.bubble.highlighted"

    /// VoiceOver: what is on screen, in order.
    private var accessibilityText: String {
        Self.accessibilityText(item: item, words: item.textMessage ?? "\(item.header.subject), summarizing")
    }

    /// "Priya Vasanth replied only to you, said: …"; "You replied only to Priya Vasanth, saying: …";
    /// "Sarah Chen said: …" for an email to everyone.
    static func accessibilityText(item: ChatThread.Item, words: String) -> String {
        let who = item.isOwn ? "You" : item.sender.name
        guard let only = item.repliedOnlyTo else { return "\(who) said: \(words)" }
        let names = only.names.joined(separator: ", ")
        return "\(who) replied only to \(names), \(item.isOwn ? "saying" : "said"): \(words)"
    }

    /// The chips a bubble shows: up to `chipCount` attachment names, then how many more, as the
    /// header shows its names (`ChatThread.headerTitle`).
    static func attachmentChips(_ names: [String], chipCount: Int = ChatViewLayout.attachmentChipCount) -> (names: [String], more: Int) {
        (Array(names.prefix(chipCount)), max(0, names.count - chipCount))
    }

    /// "+N": opens the email's card, which lists every attachment.
    private func moreChip(_ more: Int) -> some View {
        Button(action: onOpen) {
            chipLabel {
                Text("+\(more)")
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(more) more attachments")
    }

    private func chipLabel<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .font(.caption)
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(Palette.boxBg))
            .overlay(Capsule().stroke(Palette.separator, lineWidth: 0.5))
    }

    private func attachmentChip(_ name: String) -> some View {
        Button(action: onOpen) {
            chipLabel {
                HStack(spacing: 4) {
                    Image(systemName: "paperclip")
                    Text(name).lineLimit(1).truncationMode(.middle)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Attachment \(name)")
    }
}

/// The ready AI Suggestion: a ghost of the user's next message, where it lands once sent
/// (the newest outgoing place, under the last email). A dashed accent outline on a faded accent
/// fill, dark-blue text (`Palette.chatSuggestion*`), and "AI Suggestion · Tap to use" under it, so it reads plainly as not sent. A tap
/// on the bubble or its caption opens the compose card with the suggestion written out; nothing is sent from here.
/// Under the caption, the other reply that came with it, when there is one (`alternative`).
struct ChatSuggestionBubble: View {
    /// The suggestion's text version (`MessageHeader.replyTextMessage`).
    let text: String
    /// The tutorial's move is this tap: a pulse ring marks it.
    var pulses = false
    /// The "or reply:" link under the caption, with its own tap; nil, none.
    var alternative: ChatAlternativeLink? = nil
    let onTap: () -> Void

    var body: some View {
        VStack(alignment: .trailing, spacing: ChatSuggestionConfig.alternativeGap) {
            ghost
            if let alternative { alternative }
        }
        .containerRelativeFrame(.horizontal, alignment: .trailing) { width, _ in
            width * ChatViewLayout.bubbleMaxWidthFraction
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.horizontal)
    }

    private var ghost: some View {
        // One button, bubble and caption, so the caption's "Tap to use" is a tap target too.
        Button(action: onTap) {
            VStack(alignment: .trailing, spacing: 4) {
                Text(text)
                    .font(.body)
                    .foregroundStyle(Palette.chatSuggestionText)
                    .multilineTextAlignment(.leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(
                        RoundedRectangle(cornerRadius: ChatViewLayout.bubbleCornerRadius)
                            .fill(Palette.chatSuggestionFill)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: ChatViewLayout.bubbleCornerRadius)
                            .stroke(Palette.chatSuggestionStroke, style: StrokeStyle(
                                lineWidth: ChatViewLayout.suggestionStrokeWidth, dash: ChatViewLayout.suggestionDash))
                    )
                    .overlay {
                        if pulses {
                            TutorialPulseRing(shape: RoundedRectangle(cornerRadius: ChatViewLayout.bubbleCornerRadius))
                        }
                    }
                Text(ChatSuggestionConfig.statusLine)
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(ChatSuggestionConfig.label): \(text)")
        .accessibilityHint("Opens the email, ready to review and send")
        .accessibilityAddTraits(.isButton)
        // The combined element ignores the Button inside it, so its activation is its own:
        // without this, VoiceOver's double tap opened nothing.
        .accessibilityAction { onTap() }
        .accessibilityIdentifier(Self.bubbleId)
    }

    /// The ghost, as tests find it.
    static let bubbleId = "chat.aiSuggestion"
}

/// The other reply that came with the AI Suggestion (`ChatReplyField.alternative`), as a light line
/// under the ghost's caption: a gray "or", then the reply in blue, and a chevron (ADR-IOS-114
/// decision 10; owner 2026-11-26, mock E3). A tap puts the reply in the field, ready to edit or
/// send (`put`); it never sends, and the ghost keeps its own tap. It shows only while the field is
/// empty, so a tap never replaces the user's own words. It reads them here, in its own view, so a
/// keystroke redraws this line and not the chat. The chat gives none while a dictation is under
/// way (`ChatReplyField.dictationChanged`).
struct ChatAlternativeLink: View {
    let reply: String
    /// The chat's words key (`ChatFieldWords.key(for:)`): whose field it fills.
    let wordsKey: String
    let put: () -> Void

    var body: some View {
        if ChatFieldWords.shared.fill(for: wordsKey).words.isEmpty {
            Button(action: put) {
                Text("\(lead) \(Text(reply).fontWeight(.medium)) \(ChatSuggestionConfig.alternativeChevron)")
                    .font(.footnote)
                    .foregroundStyle(Theme.accent)
                    .multilineTextAlignment(.trailing)
                    .lineLimit(ChatSuggestionConfig.alternativeLineLimit)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(ChatSuggestionConfig.alternativeLabel(reply))
            .accessibilityHint("Puts it in the field")
            .accessibilityIdentifier(Self.linkId)
        }
    }

    /// The gray "or"; the rest of the line takes the link's blue.
    private var lead: Text {
        Text(ChatSuggestionConfig.alternativeLead).foregroundStyle(Theme.textSecondary)
    }

    /// The line, as tests find it.
    static let linkId = "chat.aiSuggestionAlternative"
}

/// The user's own message from the closed field (`ChatFieldMessage`): their words, verbatim, in
/// their own blue bubble where the reply lands once sent. While the field's Send runs, the line
/// under it, where "Sent" goes on a sent email, says what is happening ("Writing your email",
/// `status`). It pulses softly while the email that says them is written, after a short wait
/// (`pulseOpacity`); still once it is written and while its compose card is up. Nothing to tap.
struct ChatFieldMessageBubble: View {
    let text: String
    var pulses = false
    /// The line under the bubble; nil for none (held behind its card).
    var status: String?
    /// When the bubble went up: the pulse's wait runs from here.
    @State private var shownAt = Date.now

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            // Paused, the timeline draws once and the bubble is at full opacity.
            TimelineView(.animation(minimumInterval: ChatSuggestionConfig.dotFrameInterval, paused: !pulses)) { context in
                Text(text)
                    .font(.body)
                    .foregroundStyle(Color.white)
                    .multilineTextAlignment(.leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(
                        RoundedRectangle(cornerRadius: ChatViewLayout.bubbleCornerRadius)
                            .fill(Theme.accent)
                    )
                    .opacity(pulses ? Self.pulseOpacity(sinceShown: context.date.timeIntervalSince(shownAt)) : 1)
            }
            if let status {
                Text(status)
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(pulses ? "You said: \(text), writing your email" : "You said: \(text)")
        .accessibilityIdentifier(pulses ? Self.writingId : Self.bubbleId)
        .containerRelativeFrame(.horizontal, alignment: .trailing) { width, _ in
            width * ChatViewLayout.bubbleMaxWidthFraction
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.horizontal)
    }

    /// The bubble's opacity `elapsed` seconds after it went up: full through
    /// `ChatSuggestionConfig.fieldMessagePulseDelay`, then from full, smoothly, down to
    /// `fieldMessageDimOpacity` at half of each `fieldMessagePulsePeriod` and back up.
    static func pulseOpacity(sinceShown elapsed: Double) -> Double {
        let pulsing = elapsed - ChatSuggestionConfig.fieldMessagePulseDelay
        guard pulsing > 0 else { return 1 }
        let depth = (1 - cos(2 * Double.pi * pulsing / ChatSuggestionConfig.fieldMessagePulsePeriod)) / 2
        return 1 - (1 - ChatSuggestionConfig.fieldMessageDimOpacity) * depth
    }

    /// The bubble, as tests find it: while its email is written, and once it is.
    static let writingId = "chat.fieldMessage.writing"
    static let bubbleId = "chat.fieldMessage"
}

/// The AI Suggestion while it is written: the ghost's dashed bubble holding three pulsing dots,
/// with "AI Suggestion · Writing" under it, in the ghost's place (the last chat row, above the
/// field). It grows into `ChatSuggestionBubble` when the suggestion is stored. Nothing to tap.
struct ChatSuggestionWorkingBubble: View {
    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            TimelineView(.animation(minimumInterval: ChatSuggestionConfig.dotFrameInterval)) { context in
                let time = context.date.timeIntervalSinceReferenceDate
                HStack(spacing: ChatSuggestionConfig.dotSpacing) {
                    ForEach(0..<3, id: \.self) { index in
                        Circle()
                            .fill(Palette.chatSuggestionStroke)
                            .frame(width: ChatSuggestionConfig.dotSize, height: ChatSuggestionConfig.dotSize)
                            .opacity(Self.dotOpacity(at: time - Double(index) * ChatSuggestionConfig.dotStagger))
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: ChatViewLayout.bubbleCornerRadius)
                    .fill(Palette.chatSuggestionFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: ChatViewLayout.bubbleCornerRadius)
                    .stroke(Palette.chatSuggestionStroke, style: StrokeStyle(
                        lineWidth: ChatViewLayout.suggestionStrokeWidth, dash: ChatViewLayout.suggestionDash))
            )
            Text(ChatSuggestionConfig.writingLine)
                .font(.caption2)
                .foregroundStyle(Theme.textSecondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(ChatSuggestionConfig.writingLine)
        .accessibilityIdentifier(Self.bubbleId)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.horizontal)
    }

    /// A dot's opacity at `time`: dim, full at half the period, dim again.
    static func dotOpacity(at time: Double) -> Double {
        let period = ChatSuggestionConfig.dotPulsePeriod
        let phase = (time.truncatingRemainder(dividingBy: period) + period).truncatingRemainder(dividingBy: period) / period
        let rise = 1 - abs(phase * 2 - 1)
        return ChatSuggestionConfig.dotDimOpacity + (1 - ChatSuggestionConfig.dotDimOpacity) * rise
    }

    /// The working bubble, as tests find it.
    static let bubbleId = "chat.aiSuggestion.writing"
}

/// A reply in the outbox that has not gone out yet (`ChatUnsentReply`): a blue bubble with the
/// email's summary once it is made ("Summarizing" until then), and under it "Sending", as under
/// every email of the user's. A send that failed for good reads "Not sent", with the red mark beside
/// the bubble as in Messages; touch and hold offers Retry and Delete, which are the Outbox's own
/// Retry and Discard for the same row.
struct ChatUnsentReplyBubble: View {
    let reply: ChatUnsentReply
    let retry: () -> Void
    let delete: () -> Void
    /// Undo send while the row's undo window lasts (`ChatUndoSendStatus`).
    let undo: () -> Void

    private var notSent: Bool { reply.failed }

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            bubble
            if notSent {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(Theme.destructive)
                    .accessibilityLabel("Not sent")
                    .accessibilityIdentifier(Self.notSentMarkId)
                    .accessibilityAction(named: "Retry", retry)
                    .accessibilityAction(named: "Delete", delete)
            }
        }
        .contextMenu { if notSent { failedSendMenu } }
        .containerRelativeFrame(.horizontal, alignment: .trailing) { width, _ in
            width * ChatViewLayout.bubbleMaxWidthFraction
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.horizontal)
    }

    static let notSentMarkId = "chat.unsentReply.notSent"

    @ViewBuilder
    private var failedSendMenu: some View {
        Button(action: retry) { Label("Retry", systemImage: "arrow.clockwise") }
        Button(role: .destructive, action: delete) { Label("Delete", systemImage: "trash") }
    }

    private var bubble: some View {
        ChatUndoSendTimeline(reply: reply) { look, secondsLeft in
            VStack(alignment: .trailing, spacing: 4) {
                ChatUndoSendFill(look: look) { textColor in
                    Group {
                        // Each branch says what it shows, so VoiceOver reads what is on screen.
                        if let text = reply.textMessage {
                            Text(text)
                                .font(.body)
                                .foregroundStyle(textColor)
                                .multilineTextAlignment(.leading)
                                .accessibilityLabel("You said: \(text)")
                        } else {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.mini).tint(textColor)
                                Text("Summarizing")
                                    .font(.caption)
                                    .foregroundStyle(textColor.opacity(0.8))
                            }
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("You said: summarizing")
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                }
                ChatUndoSendStatus(reply: reply, secondsLeft: secondsLeft, undo: undo)
            }
        }
    }
}

/// Initials in a circle of the person's color.
struct ChatAvatar: View {
    let person: ChatThread.Person
    let size: CGFloat

    static func color(for person: ChatThread.Person) -> Color {
        Palette.chatPersonColors[person.colorIndex(count: Palette.chatPersonColors.count)]
    }

    var body: some View {
        Text(person.initials)
            .font(.system(size: size * 0.4, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Circle().fill(Self.color(for: person)))
            .accessibilityHidden(true)
    }
}

/// The invite's details from its calendar file, laid out like the agent's event card, with
/// today's add-to-calendar screen behind the button.
struct ChatInviteCard: View {
    let invite: ChatInvite

    var body: some View {
        // One read of the device's zone. The invite's times are shown in it, so the card names no
        // zone, as the agent's card does for times in the device's zone.
        let deviceZone = TimeZone.current
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "calendar")
                    .font(.caption)
                    .foregroundStyle(Theme.accent.opacity(0.7))
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 2) {
                    Text(invite.parsed.title.isEmpty ? "Invitation" : invite.parsed.title)
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(2)
                    if let start = invite.parsed.startDate {
                        Text(CalendarEventFormat.time(
                            start: start, end: invite.parsed.endDate ?? start,
                            isAllDay: invite.parsed.isAllDay, timeZone: deviceZone))
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                    }
                    if !people.isEmpty {
                        Label {
                            Text(people).lineLimit(2)
                        } icon: {
                            Image(systemName: "person.2")
                        }
                        .font(.caption2)
                        .foregroundStyle(Theme.textSecondary)
                    }
                }
            }
            Button {
                ICSCalendarImporter.presentCalendarImport(icsText: invite.icsText)
            } label: {
                Text("Add to Calendar")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(Theme.accent)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12).fill(Palette.boxBg))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.separator, lineWidth: 0.5))
    }

    private var people: String {
        var names: [String] = []
        if let organizer = invite.parsed.organizer {
            names.append(organizer.name.isEmpty ? organizer.email : organizer.name)
        }
        for attendee in invite.parsed.attendees {
            let name = attendee.name.isEmpty ? attendee.email : attendee.name
            if !names.contains(name) { names.append(name) }
        }
        return names.joined(separator: ", ")
    }
}

/// The "Unread" line where unread starts.
struct ChatUnreadLine: View {
    var body: some View {
        HStack(spacing: 8) {
            Rectangle().fill(Theme.accent.opacity(0.4)).frame(height: 1)
            Text("Unread")
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(Theme.accent)
            Rectangle().fill(Theme.accent.opacity(0.4)).frame(height: 1)
        }
        .padding(.horizontal)
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

/// The sender's name above a bubble (`ChatBubbleView`).
struct ChatSenderLine: View {
    let item: ChatThread.Item

    @State private var showsOnlyList: Bool
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// `showsOnlyList`: the full "replied only to" list starts open.
    init(item: ChatThread.Item, showsOnlyList: Bool = false) {
        self.item = item
        _showsOnlyList = State(initialValue: showsOnlyList)
    }

    /// The label's tap: opens the full "replied only to" list.
    func openRecipientList() {
        showsOnlyList = true
    }

    /// The sender's name (group chats), or "You" on the user's own email, with a gray
    /// "(replied only to …)" when the email did not go to everyone. One line; tap the
    /// label for the full list. At accessibility text sizes the name is one line of its own,
    /// truncating, and the label wraps below it, so neither runs off the screen.
    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: item.isOwn ? .trailing : .leading, spacing: 4) {
                    senderName
                        .lineLimit(1)
                    if let only = item.repliedOnlyTo {
                        onlyToLabel(only)
                            .lineLimit(nil)
                            .multilineTextAlignment(item.isOwn ? .trailing : .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } else {
                // On one baseline: the name is a step larger than the label after it.
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    senderName
                        .fixedSize()
                    if let only = item.repliedOnlyTo {
                        onlyToLabel(only)
                    }
                }
                .lineLimit(1)
            }
        }
        .accessibilityHidden(true)
    }

    /// The sender's name, a step larger than the "(replied only to …)" label after it.
    static let nameFont = Font.footnote

    private var senderName: some View {
        Text(item.isOwn ? "You" : item.sender.name)
            .font(Self.nameFont)
            .fontWeight(.medium)
            .foregroundStyle(item.isOwn ? Theme.textSecondary : ChatAvatar.color(for: item.sender))
    }

    private func onlyToLabel(_ only: ChatThread.OnlyTo) -> some View {
        Button { openRecipientList() } label: {
            Text("(replied only to \(only.label()))")
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showsOnlyList) {
            ChatPeopleList(
                title: "\(item.isOwn ? "You" : item.sender.name) replied only to",
                names: ChatBubbleView.listNames(only))
        }
    }
}
