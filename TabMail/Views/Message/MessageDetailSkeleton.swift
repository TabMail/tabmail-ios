/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import SwiftUI

/// Loading placeholder shown while the opened message resolves asynchronously
/// (`MessageDetailViewModel.init` is zero-I/O; a notification tap may even
/// arrive with an unresolved provider id — the resolve ladder runs under this).
///
/// Design (2026-07-04, user-directed): a faithful replica of the FOCUSED
/// `MessageCardView` — same card chrome, fonts, and paddings — filled with
/// generic fake content that is BLURRED out, pulsing with the same opacity
/// breath as the compose editor's AI-editing state (`bodyBlink`: 1 ↔ 0.35,
/// 0.8s easeInOut autoreverse). No shimmer. The pulse is driven by
/// `.phaseAnimator`, NOT `@State` + `.onAppear { withAnimation(...repeatForever...) }`
/// — a `repeatForever` animation started in `onAppear` leaks into this view's
/// removal transition when the real message lands and the ViewModel swaps it
/// out inside `withAnimation`: the outgoing skeleton's removal never
/// completes, stranding a pulsing ghost over the rendered content forever
/// (found on-device 2026-07-07, chat-pill open). `.phaseAnimator` scopes each
/// phase's animation to the view's lifetime and tears down cleanly when the
/// view is removed, so this cannot happen. When the real message lands, the
/// ViewModel assigns it inside `withAnimation` so this dissolves into the
/// actual card.
struct MessageDetailSkeleton: View {
    var body: some View {
        VStack(spacing: 0) {
            fakeCard
                .padding(.vertical, 6)  // cardRow's listRowInsets
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Palette.previewPaneBg)
        .phaseAnimator([false, true]) { content, dimmed in
            content.opacity(dimmed ? 0.35 : 1)
        } animation: { _ in
            .easeInOut(duration: 0.8)
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading message")
    }

    /// Replica of the focused expanded `MessageCardView`: header (sender +
    /// date, To row), subject, divider, AI summary bubble, body paragraphs —
    /// blurred so it reads as content loading in, not as a real message.
    private var fakeCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header — sender + date, then the To row (MessageCardView's
            // collapsedHeaderDetails, text margin 17pt = 3 + 12pt gutter + 2).
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .top) {
                    Text("Sender Name")
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    Spacer()
                    Text("9:41 AM")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
                Text("To: you")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
            .padding(.leading, 17)
            .padding(.trailing)

            // Subject
            Text("Loading this message for you")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 17)
                .padding(.trailing)
                .padding(.top, 6)

            // Separator (aligned with text content)
            Divider()
                .padding(.leading, 17)
                .padding(.trailing)
                .padding(.vertical, 10)

            // AI summary bubble (SummaryBubbleView chrome)
            Text("A short summary of the message will appear here once it loads.")
                .font(.caption)
                .foregroundStyle(Theme.textPrimary)
                .padding(.vertical, 8)
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.accent.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Theme.accent.opacity(0.2), lineWidth: 1)
                )
                .padding(.horizontal, 6)
                .padding(.bottom, 8)

            // Body paragraphs
            Text(Self.fakeBody)
                .font(.body)
                .foregroundStyle(Theme.textPrimary)
                .padding(.leading, 17)
                .padding(.trailing)
                .padding(.bottom, 16)
        }
        .padding(.top, 8)
        .blur(radius: 3.5)  // fake content is illegible; massing stays real
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Theme.cardBackground)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    /// Generic filler (no real names/addresses — public-repo rule); length
    /// chosen so the card massing matches a typical short email.
    private static let fakeBody = """
    Hello,

    Thanks for reaching out about the plan for next week. I had a look at \
    the notes you sent over and I think we are broadly aligned on the main \
    points. There are a couple of details worth going over together before \
    we commit to the schedule.

    Could you let me know when you have a moment to talk? Either way I will \
    send the updated draft along later today.

    Best,
    Sender
    """
}
