/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import SwiftUI

/// The chat's header, in the navigation bar's principal slot as in Messages: the avatars level with
/// Back, the names under them. Tapping the names changes who gets the reply.
struct ChatHeaderView: View {
    let thread: ChatThread
    var onTapNames: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: ChatViewLayout.subjectLineSpacing) {
            HStack(spacing: -8) {
                ForEach(Array(thread.replyPeople.prefix(ChatViewLayout.headerNameCount + 1).enumerated()), id: \.offset) { _, person in
                    ChatAvatar(person: person, size: ChatViewLayout.headerAvatarSize)
                        .overlay(Circle().stroke(Palette.previewPaneBg, lineWidth: 2))
                }
            }
            if !thread.replyPeople.isEmpty {
                Button { onTapNames?() } label: {
                    HStack(spacing: 2) {
                        Text(ChatThread.headerTitle(thread.replyPeople))
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                .buttonStyle(.plain)
                .disabled(onTapNames == nil)
                .accessibilityHint("Changes who gets your reply")
            }
        }
        .accessibilityElement(children: .contain)
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
        line
            // Both sides, so the subject stays centred under the names.
            .padding(.horizontal, ChatViewLayout.aiNoticeTapTarget)
            .overlay(alignment: .trailing) {
                AISummariesNoticeButton(landed: landed, reportContent: reportContent)
            }
    }

    private var line: some View {
        HStack(spacing: 4) {
            Text(subject)
                .font(.caption)
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
