/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import SwiftUI

/// Compact card for an individual message within an expanded thread group.
/// Layout mirrors MessageRowView but with smaller fonts:
/// Line 1: sender + date
/// Line 2: subject
/// Line 3: snippet + action tag (bottom-right)
struct ThreadChildCardView: View {
    let message: MessageSnapshot
    var onTagAction: (() -> Void)?
    var onRetag: ((ActionTag) -> Void)?

    var body: some View {
        HStack(spacing: 0) {
            // Left tag color bar (full height) — inbox only (ADR-IOS-036):
            // the tag is retained across folders, but a thread child card can
            // render an out-of-inbox member (e.g. a Sent/Archived reply in an
            // otherwise-inbox thread), so display must gate on isInInbox or a
            // retained tag would leak a stale chip onto a non-inbox row.
            if let tag = message.actionTag, message.isInInbox {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Theme.tagColor(tag))
                    .frame(width: 3)
                    .padding(.vertical, 2)
            } else {
                Color.clear.frame(width: 3)
            }

            HStack(alignment: .top, spacing: 6) {
                // Left indicators: unread, reply/forward (merged), attachment
                VStack(spacing: 2) {
                    Circle()
                        .fill(message.isRead ? Color.clear : Theme.unreadDot)
                        .frame(width: 6, height: 6)
                    MessageIndicators.replyForwardIcon(isReplied: message.isReplied, isForwarded: message.isForwarded, size: 7)
                    Image(systemName: "paperclip")
                        .font(.system(size: 7))
                        .foregroundStyle(Theme.textSecondary)
                        .opacity(message.hasAttachments ? 1 : 0)
                }
                .frame(width: 10)
                .padding(.top, 3)

                VStack(alignment: .leading, spacing: 2) {
                    // Line 1: sender + date
                    HStack {
                        Text(message.from)
                            .font(.caption)
                            .fontWeight(message.isRead ? .regular : .semibold)
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                        Spacer()
                        Text(message.date.formattedForInbox())
                            .font(.caption2)
                            .foregroundStyle(Theme.textSecondary)
                    }

                    // Line 2: subject
                    Text(message.subject)
                        .font(.caption)
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)

                    // Line 3: snippet + tag (bottom-right)
                    HStack(alignment: .bottom) {
                        Text(message.snippet.isEmpty ? " " : message.snippet)
                            .font(.caption)
                            .fontWeight(.light)
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(1)
                        if let tag = message.actionTag, message.isInInbox {
                            Spacer(minLength: 4)
                            Menu {
                                retagMenu
                            } label: {
                                Text(tag.displayName)
                                    .font(.caption2)
                                    .fontWeight(.semibold)
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(Theme.tagColor(tag))
                                    .clipShape(RoundedRectangle(cornerRadius: 3))
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 4)
                                    .contentShape(Rectangle())
                            } primaryAction: {
                                onTagAction?()
                            }
                        }
                    }

                    // User label chips
                    if !message.userLabels.isEmpty {
                        let segments = UserLabelDisplaySegment.expand(message.userLabels)
                        HStack(spacing: 4) {
                            ForEach(segments) { segment in
                                UserLabelChip(name: segment.displayName)
                            }
                        }
                        .clipped()
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
        }
        // No card background — parent listRowBackground provides grouped styling
    }

    @ViewBuilder
    private var retagMenu: some View {
        if let onRetag {
            Button { onRetag(.reply) } label: {
                Label("Tag as Reply", systemImage: "arrowshape.turn.up.left")
            }
            Button { onRetag(ActionTag.none) } label: {
                Label("Tag as None", systemImage: "tag.slash")
            }
            Button { onRetag(.archive) } label: {
                Label("Tag as Archive", systemImage: "archivebox")
            }
            Button { onRetag(.delete) } label: {
                Label("Tag as Delete", systemImage: "trash")
            }
        }
    }

}
