/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import SwiftUI

/// The real inbox supplies visibility and the current authoritative notice.
struct InboxTrialCountdown: View {
    let isInbox: Bool
    let isDemo: Bool
    let notice: TrialCountdownNotice?

    var body: some View {
        if isInbox, !isDemo, let notice {
            TrialCountdownBanner(notice: notice)
        }
    }
}

/// Updates at the next change in the rounded-up day count and at the exact end.
/// A lazy sequence avoids polling or allocating an array for a long legacy grant.
struct TrialCountdownSchedule: TimelineSchedule {
    let end: Date

    func entries(from startDate: Date, mode: TimelineScheduleMode) -> Entries {
        Entries(nextDate: startDate, end: end)
    }

    struct Entries: Sequence, IteratorProtocol {
        var nextDate: Date?
        let end: Date

        mutating func next() -> Date? {
            guard let date = nextDate else { return nil }
            if date >= end {
                nextDate = nil
            } else {
                let daysAfterNextChange = Swift.max(0, ceil(end.timeIntervalSince(date) / AccountPlanConfig.secondsPerDay) - 1)
                nextDate = end.addingTimeInterval(-daysAfterNextChange * AccountPlanConfig.secondsPerDay)
            }
            return date
        }
    }
}

struct TrialCountdownBanner: View {
    let notice: TrialCountdownNotice
    let action: () -> Void = {
        NotificationCenter.default.post(name: .navigateToPlanPicker, object: nil)
    }
    @Environment(\.scenePhase) private var scenePhase
    @State private var clockRevision = 0

    var body: some View {
        TimelineView(TrialCountdownSchedule(end: notice.end)) { context in
            if let copy = notice.presentation(now: context.date) {
                Button(action: action) {
                    HStack(spacing: 8) {
                        Image(systemName: "clock")
                            .foregroundStyle(Palette.accentColor)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(copy.title)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Palette.textColor)
                            Text(copy.detail)
                                .font(.caption2)
                                .foregroundStyle(Palette.textMuted)
                        }
                        .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        Text(copy.actionTitle)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Palette.accentColor)
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Palette.textMuted)
                            .accessibilityHidden(true)
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity)
                    .background(Palette.accentColor.opacity(0.08))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("inbox-trial-countdown")
                .accessibilityHint("Opens plans and subscription settings")
            }
        }
        .id(clockRevision)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { clockRevision &+= 1 }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)) { _ in
            clockRevision &+= 1
        }
    }
}
