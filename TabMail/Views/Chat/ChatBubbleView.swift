/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import SwiftUI

/// One email of the chat: a gray bubble on the left from someone else, a blue one on the right
/// from the user (N2.2 to N2.5, N2b, O1.3). Text only (Q30); tapping it opens the email card.
struct ChatBubbleView: View {
    let item: ChatThread.Item
    let isGroup: Bool
    let extras: ChatMemberExtras?
    let isHighlighted: Bool
    let onOpen: () -> Void

    var body: some View {
        VStack(alignment: item.isOwn ? .trailing : .leading, spacing: 4) {
            HStack(alignment: .bottom, spacing: 8) {
                if item.isOwn { Spacer(minLength: 0) }
                if showsSender { ChatAvatar(person: item.sender, size: ChatViewLayout.avatarSize) }
                VStack(alignment: item.isOwn ? .trailing : .leading, spacing: 4) {
                    if showsSender {
                        Text(item.sender.name)
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundStyle(ChatAvatar.color(for: item.sender))
                            .lineLimit(1)
                    }
                    bubble
                    if let names = extras?.attachmentNames, !names.isEmpty {
                        ForEach(Array(names.enumerated()), id: \.offset) { _, name in
                            attachmentChip(name)
                        }
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

    private var shownText: String? { item.textMessage }

    private var bubble: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 6) {
                if let text = shownText {
                    Text(text)
                        .font(.body)
                        .foregroundStyle(item.isOwn ? Color.white : Theme.textPrimary)
                        .multilineTextAlignment(.leading)
                } else {
                    // N2b: still being summarized; already tappable.
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
                HStack(spacing: 2) {
                    Spacer(minLength: 0)
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
        .accessibilityAddTraits(.isButton)
    }

    /// Q25: what is on screen, in order.
    private var accessibilityText: String {
        let words = shownText ?? "\(item.header.subject), summarizing"
        return item.isOwn ? "You said: \(words)" : "\(item.sender.name) said: \(words)"
    }

    private func attachmentChip(_ name: String) -> some View {
        Button(action: onOpen) {
            HStack(spacing: 4) {
                Image(systemName: "paperclip")
                Text(name).lineLimit(1).truncationMode(.middle)
            }
            .font(.caption)
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(Palette.boxBg))
            .overlay(Capsule().stroke(Palette.separator, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Attachment \(name)")
    }
}

/// A reply just sent from the chat whose email is not in the chat yet (N7): a blue bubble from the
/// queue write on, with the email's summary once it is made ("Summarizing" until then), and under
/// it "Sending", then "Sent", as under every email of the user's. Its email's own bubble replaces it
/// once the email is in the chat. A send that failed for good reads "Not sent", with the red mark
/// beside the bubble as in Messages; touch and hold offers Retry and Delete, which are the Outbox's
/// own Retry and Discard for the same queued email (owner 2026-11-07).
struct ChatSentReplyBubble: View {
    let progress: ChatSentReplies.Progress?
    let retry: () -> Void
    let delete: () -> Void

    private var notSent: Bool { progress?.status == .notSent }

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

    static let notSentMarkId = "chat.sentReply.notSent"

    @ViewBuilder
    private var failedSendMenu: some View {
        Button(action: retry) { Label("Retry", systemImage: "arrow.clockwise") }
        Button(role: .destructive, action: delete) { Label("Delete", systemImage: "trash") }
    }

    private var bubble: some View {
        VStack(alignment: .trailing, spacing: 4) {
            Group {
                // Each branch says what it shows, so VoiceOver reads what is on screen.
                if let text = progress?.textMessage {
                    Text(text)
                        .font(.body)
                        .foregroundStyle(Color.white)
                        .multilineTextAlignment(.leading)
                        .accessibilityLabel("You said: \(text)")
                } else {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini).tint(Color.white)
                        Text("Summarizing")
                            .font(.caption)
                            .foregroundStyle(Color.white.opacity(0.8))
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("You said: summarizing")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: ChatViewLayout.bubbleCornerRadius)
                    .fill(Theme.accent)
            )
            Text(progress?.caption ?? "Sending")
                .font(.caption2)
                .foregroundStyle(Theme.textSecondary)
        }
    }
}

/// Initials in a circle of the person's color (N2.11).
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
/// today's add-to-calendar screen behind the button (E3).
struct ChatInviteCard: View {
    let invite: ChatInvite

    var body: some View {
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
                            isAllDay: invite.parsed.isAllDay, timeZone: .current))
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                    }
                    Label {
                        Text(CalendarEventFormat.timeZoneLabel(.current))
                    } icon: {
                        Image(systemName: "globe")
                    }
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecondary)
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

/// The "Unread" line where unread starts (O1).
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
