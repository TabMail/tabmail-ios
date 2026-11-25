/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import SwiftUI

/// The chat's header, in the navigation bar's principal slot as in Messages: the avatars level with
/// Back, the names under them. Tapping the names changes who gets the reply. A new email's header
/// (`ChatNewThreadView`) starts with nobody: one empty avatar and "Add recipient", the same tap.
struct ChatHeaderView: View {
    let people: [ChatThread.Person]
    /// With nobody yet, the empty avatar's line ("Add recipient"); nil shows nothing then.
    var emptyTitle: String? = nil
    var hint: String = Self.replyHint
    var onTapNames: (() -> Void)? = nil

    static let replyHint = "Changes who gets your reply"
    static let newEmailHint = "Chooses who gets this email"

    init(thread: ChatThread, onTapNames: (() -> Void)? = nil) {
        self.init(people: thread.replyPeople, onTapNames: onTapNames)
    }

    init(people: [ChatThread.Person], emptyTitle: String? = nil, hint: String = Self.replyHint,
         onTapNames: (() -> Void)? = nil) {
        self.people = people
        self.emptyTitle = emptyTitle
        self.hint = hint
        self.onTapNames = onTapNames
    }

    var body: some View {
        VStack(spacing: ChatViewLayout.subjectLineSpacing) {
            HStack(spacing: -8) {
                if people.isEmpty, emptyTitle != nil {
                    emptyAvatar
                }
                ForEach(Array(people.prefix(ChatViewLayout.headerNameCount + 1).enumerated()), id: \.offset) { _, person in
                    ChatAvatar(person: person, size: ChatViewLayout.headerAvatarSize)
                        .overlay(Circle().stroke(Palette.previewPaneBg, lineWidth: 2))
                        .contentShape(.contextMenuPreview, Circle())
                        .copyAddressMenu(AddressCopy.person(person))
                }
            }
            if let title = people.isEmpty ? emptyTitle : ChatThread.headerTitle(people) {
                Button { onTapNames?() } label: {
                    HStack(spacing: 2) {
                        Text(title)
                            .font(.footnote)
                            .fontWeight(.semibold)
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                .buttonStyle(.plain)
                .disabled(onTapNames == nil)
                .accessibilityHint(hint)
                .accessibilityIdentifier(Self.namesId)
            }
        }
        .accessibilityElement(children: .contain)
    }

    /// The names' button, as tests find it.
    static let namesId = "chatHeaderNames"

    /// A new email's avatar before anyone is picked.
    private var emptyAvatar: some View {
        Image(systemName: "person.fill")
            .font(.system(size: ChatViewLayout.headerAvatarSize * ChatViewLayout.emptyAvatarGlyphScale))
            .foregroundStyle(Theme.textSecondary)
            .frame(width: ChatViewLayout.headerAvatarSize, height: ChatViewLayout.headerAvatarSize)
            .background(Circle().fill(Palette.boxBg))
            .accessibilityHidden(true)
    }
}

/// The thin line under the navigation bar: the subject and the thread's labels. No band of its own:
/// it sits in the chat's top bar inset, which the navigation bar's scroll edge covers. The AI
/// summaries glyph sits at its trailing edge, under Forward; its tap target overlaps the bar
/// without making the line taller.
struct ChatSubjectLine: View {
    let subject: String
    let labels: [UserLabel]
    /// The chat has landed: the AI summaries notice may open by itself.
    let landed: Bool
    /// The chat's AI summaries for "Report a concern", newest first.
    let reportContent: () -> String

    var body: some View {
        ChatSubjectText(subject: subject, labels: labels)
            // Both sides, so the subject stays centred under the names.
            .padding(.horizontal, ChatViewLayout.aiNoticeTapTarget)
            .overlay(alignment: .trailing) {
                AISummariesNoticeButton(landed: landed, reportContent: reportContent)
            }
    }
}

/// The text of the line under a chat's header: the subject, then its labels. A thread's line
/// (`ChatSubjectLine`) and a new email's (`ChatNewEmailSubjectLine`, no labels) both draw it.
struct ChatSubjectText: View {
    let subject: String
    var labels: [UserLabel] = []

    var body: some View {
        HStack(spacing: ChatViewLayout.subjectLabelGap) {
            Text(subject)
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
            ForEach(UserLabelDisplaySegment.expand(labels)) { segment in
                UserLabelChip(name: segment.displayName)
            }
        }
        .padding(.horizontal)
        .padding(.bottom, ChatViewLayout.subjectLineBottomGap)
        .frame(maxWidth: .infinity)
        .clipped()
        .accessibilityElement(children: .contain)
    }
}
