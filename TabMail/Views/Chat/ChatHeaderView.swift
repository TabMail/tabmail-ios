/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import SwiftUI

/// The chat's header: who the reply goes to, the subject, the thread's labels.
struct ChatHeaderView: View {
    let thread: ChatThread
    let subject: String
    let labels: [UserLabel]
    /// Tapping the names changes who gets the reply.
    var onTapNames: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 4) {
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
                            .font(.subheadline)
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
            Text(subject)
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
            if !labels.isEmpty {
                HStack(spacing: 4) {
                    ForEach(UserLabelDisplaySegment.expand(labels)) { segment in
                        UserLabelChip(name: segment.displayName)
                    }
                }
                .frame(maxWidth: .infinity)
                .clipped()
            }
        }
        .padding(.horizontal)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity)
        .background(.bar)
        .accessibilityElement(children: .contain)
    }
}
