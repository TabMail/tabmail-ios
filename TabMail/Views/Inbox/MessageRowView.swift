/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import SwiftUI

struct MessageRowView: View {
    let message: MessageSnapshot
    var threadInfo: ThreadDisplayInfo?
    var onTagAction: (() -> Void)?
    var onRetag: ((ActionTag) -> Void)?
    /// Thread chevron: isThread=true shows tinted circle, false shows plain chevron.
    var isThread: Bool = false
    var isExpanded: Bool = false
    var onThreadToggle: (() -> Void)?
    /// For user-authored folders (Drafts, Sent) the row shows the recipient
    /// instead of the sender — the sender is always the user, so showing it
    /// adds no information.
    var showsRecipientInsteadOfSender: Bool = false
    @AppStorage(AIService.optOutAllAIKey, store: AIService.optOutStore) private var optOutAllAI = false
    @State private var tagTapTick = 0
    @State private var tagMenuOpenTick = 0
    /// Whether at least one AI source is enabled (LLM or Device Sync).
    /// When in demo with AI declined, treat all AI
    /// surfaces as off regardless of pre-baked content.
    private var anyAISourceEnabled: Bool {
        let demoStore = DemoModeStore.shared
        if demoStore.isActive && !demoStore.aiEnabled { return false }
        return (!optOutAllAI || DeviceSyncService.shared.isAutoEnabled) && AISubscriptionGate.shared.isActive
    }

    /// Effective sender (or recipient) display:
    /// - Thread view: senderList from threadInfo (aggregated sender names).
    /// - Drafts/Sent folders: recipient list (`To: …`) prefixed with "To:".
    /// - Everywhere else: the message's `from` field.
    private var senderDisplay: String {
        if let list = threadInfo?.senderList { return list }
        if showsRecipientInsteadOfSender {
            let to = message.to.trimmingCharacters(in: .whitespaces)
            if to.isEmpty { return "(No recipient)" }
            return "To: \(to)"
        }
        return message.from
    }

    /// Effective tag: thread aggregate tag overrides individual message tag.
    /// Hide action chip when demo + AI off.
    private var effectiveTag: ActionTag? {
        let demoStore = DemoModeStore.shared
        if demoStore.isActive && !demoStore.aiEnabled { return nil }
        if let threadInfo { return threadInfo.threadTag }
        return message.actionTag
    }

    /// Effective unread: thread-level unread overrides individual.
    private var isUnread: Bool {
        if let threadInfo { return threadInfo.hasUnread }
        return !message.isRead
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Left indicators: unread, reply/forward (merged), attachment
            VStack(spacing: 3) {
                Circle()
                    .fill(isUnread ? Theme.unreadDot : Color.clear)
                    .frame(width: 9, height: 9)
                MessageIndicators.replyForwardIcon(isReplied: message.isReplied, isForwarded: message.isForwarded, size: 11)
                Image(systemName: "paperclip")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
                    .opacity(message.hasAttachments ? 1 : 0)
            }
            .frame(width: 14)
            .padding(.top, 4)

            VStack(alignment: .leading, spacing: 4) {
                // Top row: sender + date + flag + chevron
                // Long-press on non-tag areas opens label management
                HStack {
                    Text(senderDisplay)
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundStyle(Theme.textUnread)
                        .lineLimit(1)
                    if let count = threadInfo?.memberCount, count > 1 {
                        Text("\(count)")
                            .font(.caption2)
                            .fontWeight(.semibold)
                            .foregroundStyle(Theme.textSecondary)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Theme.textSecondary.opacity(0.15))
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                    }
                    Spacer()
                    Text(message.date.formattedForInbox())
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                    if message.isFlagged {
                        Image(systemName: "flag.fill")
                            .font(.caption)
                            .foregroundStyle(Theme.flagged)
                    }
                    // Thread chevron indicator (inline with date)
                    if isThread, let onToggle = onThreadToggle {
                        Button {
                            onToggle()
                        } label: {
                            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                                .font(.caption)
                                .fontWeight(.semibold)
                                .foregroundStyle(.white)
                                .frame(width: 22, height: 22)
                                .background(Theme.accent)
                                .clipShape(Circle())
                        }
                        .buttonStyle(.plain)
                    } else {
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .fontWeight(.medium)
                            .foregroundStyle(Theme.textSecondary.opacity(0.5))
                    }
                }

                // Subject
                Text(message.subject)
                    .font(.subheadline)
                    .fontWeight(.regular)
                    .foregroundStyle(Theme.textUnread)
                    .lineLimit(1)
    
                // Preview + tag
                HStack(alignment: .bottom) {
                    // Reserve 2 lines of height even when snippet is empty,
                    // so row height is consistent and scroll length stays stable.
                    Text(message.snippet.isEmpty ? " \n " : message.snippet)
                        .font(.subheadline)
                        .fontWeight(.light)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(2)
                            if let tag = effectiveTag, message.isInInbox {
                        Spacer(minLength: 4)
                        HStack(spacing: 4) {
                            // Menu pattern (same as MessageCardView.actionTagBadge):
                            // Tap → execute tag action, Long-press → retag menu
                            Menu {
                                retagMenu
                            } label: {
                                Text(tag.displayName)
                                    .font(.caption2)
                                    .fontWeight(.semibold)
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .actionTagButtonStyle(color: Theme.tagColor(tag))
                                    .aiWorkingShimmer(active: showShimmer)
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 4)
                                    .contentShape(Rectangle())
                                    .sensoryFeedback(.impact(weight: .light), trigger: tagTapTick)
                                    .sensoryFeedback(.impact(weight: .medium), trigger: tagMenuOpenTick)
                            } primaryAction: {
                                tagTapTick &+= 1
                                onTagAction?()
                            }
                            .simultaneousGesture(
                                LongPressGesture(minimumDuration: 0.35)
                                    .onEnded { _ in tagMenuOpenTick &+= 1 }
                            )
                            .popoverTip(InboxTagTeachingTip(), arrowEdge: .top)
                            // Thread: show spinner next to tag while other members still processing
                            if threadMembersStillProcessing {
                                ProgressView()
                                    .controlSize(.mini)
                            }
                        }
                    } else if message.isInInbox && anyAISourceEnabled {
                        Spacer(minLength: 4)
                        ProgressView()
                            .controlSize(.mini)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                    }
                }

                // User label chips — for collapsed threads, show union of all members' labels.
                // For single messages/expanded threads, show this message's labels.
                let effectiveLabels = threadInfo?.unionLabels ?? message.userLabels
                if !effectiveLabels.isEmpty {
                    let segments = UserLabelDisplaySegment.expand(effectiveLabels)
                    HStack(spacing: 4) {
                        ForEach(segments) { segment in
                            UserLabelChip(name: segment.displayName)
                        }
                    }
                    .clipped()
                    .padding(.top, 2)
                    .popoverTip(UserLabelRowManageTip(), arrowEdge: .bottom)
                }
            }
        }
        .padding(.vertical, 4)
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

    private var showShimmer: Bool {
        guard effectiveTag != nil, AISubscriptionGate.shared.isActive else { return false }
        // For threads: shimmer if ANY member with a tag is still awaiting reply processing
        if let threadInfo {
            return threadInfo.anyMemberStillProcessingReply
        }
        return !message.isReplyProcessed
    }

    /// For thread rows: true when the thread has a tag but not all inbox members are tagged yet.
    private var threadMembersStillProcessing: Bool {
        guard let threadInfo else { return false }
        return !threadInfo.allMembersTagged && anyAISourceEnabled
    }

}
