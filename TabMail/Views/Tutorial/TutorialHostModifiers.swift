/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import SwiftUI

/// Part 3's source email: reports the open to the tutorial and shows the
/// "There's your answer" card above it. One modifier entry, because the
/// message view's modifier chain is type-checker-budget-sensitive.
struct TutorialMessageHost: ViewModifier {
    let message: MessageHeader?
    let dismiss: DismissAction

    private var isTutorialSource: Bool {
        message?.accountId == DemoSeed.demoAccountId
            && message?.messageId == DemoSeed.TutorialFixture.jordanFlights
    }

    func body(content: Content) -> some View {
        content
            .safeAreaInset(edge: .top) {
                if TutorialCoordinator.shared.isRunning && isTutorialSource {
                    TutorialCoachView(host: .message, onAction: { action in
                        // "Next" continues in the inbox's chat.
                        if action == .showMoreToAsk { dismiss() }
                    })
                    .padding(.vertical, 8)
                }
            }
            .task(id: message?.id) {
                guard let message else { return }
                TutorialCoordinator.shared.messageOpened(accountId: message.accountId, messageId: message.messageId)
            }
    }
}

/// The inbox list: scrolls the row a tag step points at into view, so a card
/// never asks for a tag that is below the fold. Applied to the list inside its
/// `ScrollViewReader`; rows are identified by `ThreadGroup.id`.
///
/// The scroll is re-issued whenever the list's geometry changes while a step
/// targets a row: a scroll asked for as the inbox first appears is dropped,
/// because the list is still laying out and the coach card above it is still
/// settling its height (measured on device 2026-10-25: the offset stayed 0).
struct TutorialInboxScroll: ViewModifier {
    let proxy: ScrollViewProxy
    let groups: [ThreadGroup]

    /// What the scroll depends on: the target row and the list's laid-out size.
    private struct Layout: Equatable {
        var containerHeight: CGFloat = 0
        var contentHeight: CGFloat = 0
    }

    @State private var layout = Layout()

    private var targetGroupId: String? {
        let tutorial = TutorialCoordinator.shared
        guard tutorial.isRunning, let target = TutorialCoordinator.tagTarget(for: tutorial.step) else { return nil }
        return groups.first {
            $0.representative.accountId == DemoSeed.demoAccountId && $0.representative.messageId == target
        }?.id
    }

    func body(content: Content) -> some View {
        content
            .onScrollGeometryChange(for: Layout.self) {
                Layout(containerHeight: $0.containerSize.height, contentHeight: $0.contentSize.height)
            } action: { _, new in
                layout = new
            }
            .onChange(of: targetGroupId, initial: true) { _, id in
                BackgroundSyncLogger.logDebug("[TutScroll] target=\(id ?? "nil") groups=\(groups.count) step=\(String(describing: TutorialCoordinator.shared.step))")
                guard let id else { return }
                withAnimation { proxy.scrollTo(id, anchor: .center) }
            }
            .onChange(of: layout) { _, new in
                guard let id = targetGroupId, new.contentHeight > 0 else { return }
                BackgroundSyncLogger.logDebug("[TutScroll] relayout container=\(Int(new.containerHeight)) content=\(Int(new.contentHeight)): rescroll")
                proxy.scrollTo(id, anchor: .center)
            }
    }
}

/// A sheet's Done, ringed while the tutorial runs: the tutorial's sheets
/// (See rule, See template) close with it.
struct TutorialSheetDoneButton: View {
    let action: () -> Void

    var body: some View {
        Button("Done", action: action)
            .overlay {
                if TutorialCoordinator.shared.isRunning {
                    TutorialPulseRing(shape: Capsule(), lineWidth: 2, outset: 6)
                }
            }
    }
}

/// A row's only swipe action during the tutorial: it shows the locked notice
/// instead of acting on the sample mail the steps need.
struct TutorialLockedSwipeButton: View {
    var body: some View {
        Button {
            _ = TutorialCoordinator.shared.admits(.other)
        } label: {
            Label("Off", systemImage: "lock")
        }
        .tint(Palette.untagged)
    }
}

/// "Other actions are off during the tutorial", shown for a moment after a
/// refused mail action. Styled and placed like the inbox's notice capsules,
/// without their close mark (it goes away by itself).
struct TutorialLockedToast: View {
    var body: some View {
        if let notice = TutorialCoordinator.shared.lockedNotice {
            HStack(spacing: 8) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(
                Capsule()
                    .fill(Color(hex: 0x323232))
                    .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
            )
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .allowsHitTesting(false)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("tutorial-locked-toast")
        }
    }
}

/// The hint on the control a step asks for: an accent ring with a second ring
/// rippling out from it, over and over, so the hint moves and catches the eye
/// (owner 2026-10-25: pulsing, not a static or glowing ring).
struct TutorialPulseRing<S: Shape>: View {
    let shape: S
    var lineWidth: CGFloat = 3
    /// How far the ring sits outside the control.
    var outset: CGFloat = 4
    /// How far the ripple travels past the ring before it fades out.
    var rippleTravel: CGFloat = 10

    var body: some View {
        ZStack {
            shape
                .stroke(Theme.accent, lineWidth: lineWidth)
                .padding(-outset)
            shape
                .stroke(Theme.accent, lineWidth: lineWidth)
                .phaseAnimator([false, true]) { ripple, out in
                    ripple
                        .padding(-(outset + (out ? rippleTravel : 0)))
                        .opacity(out ? 0 : 0.9)
                } animation: { out in
                    // Out over the beat, then straight back to the ring.
                    out ? .easeOut(duration: 1.1) : nil
                }
        }
        .allowsHitTesting(false)
    }
}

/// Navigation the tutorial turns off (owner 2026-10-25): the control stays in
/// place, disabled and dimmed, until the tutorial ends.
struct TutorialLockedNavigation: ViewModifier {
    static let lockedOpacity = 0.35

    func body(content: Content) -> some View {
        let locked = TutorialCoordinator.shared.isRunning
        content
            .disabled(locked)
            .opacity(locked ? Self.lockedOpacity : 1)
    }
}

extension View {
    func tutorialLockedNavigation() -> some View {
        modifier(TutorialLockedNavigation())
    }
}
