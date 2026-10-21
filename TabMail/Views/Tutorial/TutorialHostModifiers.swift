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
/// never asks for a tag that is below the fold. Sits beside the list inside
/// its `ScrollViewReader`; rows are identified by `ThreadGroup.id`.
struct TutorialInboxScroller: View {
    let proxy: ScrollViewProxy
    let groups: [ThreadGroup]

    private var targetGroupId: String? {
        let tutorial = TutorialCoordinator.shared
        guard tutorial.isRunning, let target = TutorialCoordinator.tagTarget(for: tutorial.step) else { return nil }
        return groups.first {
            $0.representative.accountId == DemoSeed.demoAccountId && $0.representative.messageId == target
        }?.id
    }

    var body: some View {
        Color.clear
            .allowsHitTesting(false)
            .onChange(of: targetGroupId, initial: true) { _, id in
                guard let id else { return }
                withAnimation { proxy.scrollTo(id, anchor: .center) }
            }
    }
}
