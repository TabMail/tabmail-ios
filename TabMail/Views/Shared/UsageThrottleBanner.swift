/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import SwiftUI

/// Subtle, non-dismissible, tappable banner shown at the top of the inbox when
/// the user's background AI processing is being throttled. Deliberately quieter
/// than the red error banner — soft orange tint, small type, a chevron to hint
/// it's tappable, and no dismiss button (the condition clears itself once the
/// quota resets or the user upgrades / adds a key).
///
/// Driven by `UsageThrottleStore.banner`. The tap action is injected by the
/// caller (InboxView) so this view stays navigation-agnostic and previewable.
struct UsageThrottleBanner: View {
    let kind: UsageThrottleBannerKind
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.footnote)
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Palette.textColor)
                    Text(message)
                        .font(.caption2)
                        .foregroundStyle(Palette.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Palette.textMuted)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(Color.orange.opacity(0.12))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens \(kind == .upgradeToPro ? "plans" : "API key settings")")
    }

    private var icon: String {
        switch kind {
        case .upgradeToPro:  return "gauge.with.dots.needle.33percent"
        case .configureKeys: return "key.fill"
        }
    }

    private var title: String {
        switch kind {
        case .upgradeToPro:  return "Monthly AI usage reached"
        case .configureKeys: return "AI processing may slow down"
        }
    }

    private var message: String {
        switch kind {
        case .upgradeToPro:
            return "Background AI processing may slow down. Upgrade to Pro for full-speed processing."
        case .configureKeys:
            return "You're on the shared queue. Set up your own AI provider for full-speed processing."
        }
    }
}
