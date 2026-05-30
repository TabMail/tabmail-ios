/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import SwiftUI

/// Compact triage row: sender, date, subject — tinted with tag color.
/// No preview, no attachment icon — only reply/forward indicators.
struct TriageRowView: View {
    let message: MessageSnapshot
    let isSelected: Bool
    var fadeTop: Bool = false
    var fadeBottom: Bool = false
    var prevTag: ActionTag?
    var nextTag: ActionTag?
    var onStripeAction: (() -> Void)?
    var onRetag: ((ActionTag) -> Void)?
    @AppStorage(AIService.optOutAllAIKey, store: AIService.optOutStore) private var optOutAllAI = false
    @State private var tagTapTick = 0
    private var anyAISourceEnabled: Bool {
        (!optOutAllAI || DeviceSyncService.shared.isAutoEnabled) && AISubscriptionGate.shared.isActive
    }

    var body: some View {
        HStack(spacing: 0) {
            // Tag color stripe on far left
            if let tag = message.actionTag {
                tagStripe(tag: tag)
            } else if message.isInInbox && anyAISourceEnabled {
                Theme.textSecondary.opacity(0.2)
                    .frame(width: 4)
            } else {
                Color.clear
                    .frame(width: 4)
            }

            HStack(alignment: .center, spacing: 10) {
                // Left indicators: fixed slots — unread dot, reply, forward
                VStack(spacing: 3) {
                    Circle()
                        .fill(message.isRead ? Color.clear : Theme.unreadDot)
                        .frame(width: 8, height: 8)
                    Image(systemName: "arrowshape.turn.up.left.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.textSecondary)
                        .opacity(message.isReplied ? 1 : 0)
                    Image(systemName: "arrowshape.turn.up.right.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.textSecondary)
                        .opacity(message.isForwarded ? 1 : 0)
                }
                .frame(width: 12)

                VStack(alignment: .leading, spacing: 2) {
                    // Top row: sender + date
                    HStack {
                        Text(message.from)
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .foregroundStyle(Theme.textUnread)
                            .lineLimit(1)
                        Spacer()
                        Text(message.date.formattedForInbox())
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                        if message.isFlagged {
                            Image(systemName: "flag.fill")
                                .font(.caption)
                                .foregroundStyle(Theme.flagged)
                        }
                    }

                    // Subject + tag action button
                    HStack(alignment: .bottom) {
                        Text(message.subject)
                            .font(.subheadline)
                            .fontWeight(.regular)
                            .foregroundStyle(Theme.textUnread)
                            .lineLimit(1)
                        if let tag = message.actionTag {
                            Spacer(minLength: 4)
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
                                .onTapGesture {
                                    tagTapTick &+= 1
                                    onStripeAction?()
                                }
                                .contextMenu { retagMenu }
                        } else if message.isInInbox && anyAISourceEnabled {
                            Spacer(minLength: 4)
                            ProgressView()
                                .controlSize(.mini)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                        }
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
    }

    // MARK: - Tag stripe with boundary cross-fade

    @ViewBuilder
    private func tagStripe(tag: ActionTag) -> some View {
        let barColor = Theme.tagColor(tag)

        if !fadeTop && !fadeBottom {
            barColor.frame(width: 4)
        } else {
            ZStack {
                // Own color — T/2 to transparent at list edges, T/4 to half at inter-group
                LinearGradient(stops: {
                    var stops: [Gradient.Stop] = []
                    if fadeTop {
                        let len: Double = prevTag != nil ? 0.0625 : 0.125
                        let edge: Double = prevTag != nil ? 0.5 : 0
                        stops.append(.init(color: barColor.opacity(edge), location: 0))
                        stops.append(.init(color: barColor, location: len))
                    } else {
                        stops.append(.init(color: barColor, location: 0))
                    }
                    if fadeBottom {
                        let len: Double = nextTag != nil ? 0.0625 : 0.125
                        let edge: Double = nextTag != nil ? 0.5 : 0
                        stops.append(.init(color: barColor, location: 1 - len))
                        stops.append(.init(color: barColor.opacity(edge), location: 1))
                    } else {
                        stops.append(.init(color: barColor, location: 1))
                    }
                    return stops
                }(), startPoint: .top, endPoint: .bottom)

                // Previous tag bleeding in at half intensity over T/4
                if fadeTop, let pt = prevTag {
                    LinearGradient(stops: [
                        .init(color: Theme.tagColor(pt).opacity(0.5), location: 0),
                        .init(color: Theme.tagColor(pt).opacity(0), location: 0.0625),
                    ], startPoint: .top, endPoint: .bottom)
                }

                // Next tag bleeding in at half intensity over T/4
                if fadeBottom, let nt = nextTag {
                    LinearGradient(stops: [
                        .init(color: Theme.tagColor(nt).opacity(0), location: 0.9375),
                        .init(color: Theme.tagColor(nt).opacity(0.5), location: 1),
                    ], startPoint: .top, endPoint: .bottom)
                }
            }
            .frame(width: 4)
        }
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
        message.actionTag != nil && !message.isReplyProcessed && AISubscriptionGate.shared.isActive
    }

}
