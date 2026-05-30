/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import SwiftUI

/// Unified "AI is working" shimmer animation.
///
/// **Design Rule:** Every indicator that AI processing is in-flight MUST use this
/// modifier. It produces a soft radial glow that sweeps across the view in a
/// continuous loop — no hard-edged stripe, just a natural light reflection.
///
/// Uses `TimelineView` with `paused:` to keep the view always in the tree
/// (avoids identity loss from if/else branching) while only consuming frames
/// when active.
private struct AIWorkingShimmerModifier: ViewModifier {
    let active: Bool
    let cornerRadius: CGFloat
    let inset: CGFloat

    func body(content: Content) -> some View {
        content
            .overlay {
                TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !active)) { timeline in
                    let seconds = timeline.date.timeIntervalSinceReferenceDate
                    let phase = seconds.remainder(dividingBy: 2.0) / 2.0 // –0.5…+0.5
                    let normalized = phase + 0.5 // 0…1
                    // Sweep center from –20% to 120% so the glow fully enters/exits
                    let center = normalized * 1.4 - 0.2

                    GeometryReader { geo in
                        let radius = geo.size.width * 0.7
                        Rectangle()
                            .fill(
                                RadialGradient(
                                    stops: [
                                        .init(color: .white.opacity(0.65), location: 0),
                                        .init(color: .white.opacity(0.3), location: 0.35),
                                        .init(color: .white.opacity(0.08), location: 0.6),
                                        .init(color: .clear, location: 1.0),
                                    ],
                                    center: UnitPoint(x: center, y: 0.45),
                                    startRadius: 0,
                                    endRadius: radius
                                )
                            )
                    }
                    .padding(inset)
                    .clipShape(RoundedRectangle(cornerRadius: max(cornerRadius - inset, 0)))
                    .clipped()
                }
                .blendMode(.plusLighter)
                .opacity(active ? 1 : 0)
                .allowsHitTesting(false)
            }
    }
}

/// Pulsing tinted row background for message rows with an active background agent.
/// Returns a View suitable for use as `.listRowBackground()` so it fills the entire
/// row area including insets (no margins). Smooth rounded corners match row shape.
struct AgentWorkingRowBackground: View {
    let active: Bool

    var body: some View {
        if active {
            TimelineView(.animation(minimumInterval: 1.0 / 20, paused: false)) { timeline in
                let seconds = timeline.date.timeIntervalSinceReferenceDate
                let phase = seconds.remainder(dividingBy: 2.0) / 2.0
                let breath = (sin(phase * .pi * 2) + 1) / 2 // 0…1
                let opacity = 0.06 + breath * 0.12 // 0.06…0.18

                RoundedRectangle(cornerRadius: 12)
                    .fill(Theme.accent.opacity(opacity))
            }
        } else {
            Color.clear
        }
    }
}

/// ViewModifier that applies the glow — kept for API compatibility with `.agentWorkingGlow()`.
/// For List rows, prefer `AgentWorkingRowBackground` via `.listRowBackground()` instead.
private struct AgentWorkingGlowModifier: ViewModifier {
    let active: Bool

    func body(content: Content) -> some View {
        content
            .overlay {
                if active {
                    TimelineView(.animation(minimumInterval: 1.0 / 20, paused: false)) { timeline in
                        let seconds = timeline.date.timeIntervalSinceReferenceDate
                        let phase = seconds.remainder(dividingBy: 2.0) / 2.0
                        let breath = (sin(phase * .pi * 2) + 1) / 2
                        let opacity = 0.06 + breath * 0.12

                        RoundedRectangle(cornerRadius: 12)
                            .fill(Theme.accent.opacity(opacity))
                    }
                    .allowsHitTesting(false)
                }
            }
    }
}

extension View {
    /// Apply the standard AI-working shimmer overlay.
    ///
    /// - Parameters:
    ///   - active: Whether the shimmer is currently animating.
    ///   - cornerRadius: Clip radius matching the host view's shape (default 4 for tag badges).
    ///   - inset: Shrink the glow area by this amount on each edge (for icons with internal margin).
    func aiWorkingShimmer(active: Bool, cornerRadius: CGFloat = 4, inset: CGFloat = 0) -> some View {
        modifier(AIWorkingShimmerModifier(active: active, cornerRadius: cornerRadius, inset: inset))
    }

    /// Apply a subtle breathing brightness indicating a background agent is working on this item.
    func agentWorkingGlow(active: Bool) -> some View {
        modifier(AgentWorkingGlowModifier(active: active))
    }
}
