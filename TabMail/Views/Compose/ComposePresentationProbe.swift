/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import SwiftUI
import UIKit

/// How the compose card's AI Suggestion bubble comes in.
enum ComposeSuggestionRevealConfig {
    /// The bubble's insertion animation, run once the card has finished coming on screen.
    static let insertionDuration: Double = 0.3
}

/// Tells the compose card when it has finished coming on screen: UIKit's `viewDidAppear` on this
/// child controller. In UIKit's usual appearance sequence a presented card's hosting controller
/// forwards it to its children once the presentation transition has completed (for a card already
/// on screen, as soon as it mounts). That ordering is observed behaviour, not documented API; the
/// hosted test that drives begin/endAppearanceTransition by hand pins it. The card holds
/// the suggestion bubble's insertion until then, so the bubble never animates in while the card
/// is still sliding in. Only that insertion waits: the card's content, fields and draft load do not.
struct ComposePresentationProbe: UIViewControllerRepresentable {
    /// What the debug log records when the signal fires.
    struct AppearState {
        let ancestorBeingPresented: Bool
        let hasTransitionCoordinator: Bool
    }

    let onAppeared: (AppearState) -> Void

    func makeUIViewController(context: Context) -> Controller {
        let controller = Controller()
        controller.onAppeared = onAppeared
        return controller
    }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.onAppeared = onAppeared
    }

    final class Controller: UIViewController {
        var onAppeared: ((AppearState) -> Void)?

        override func loadView() {
            view = UIView()
            view.isUserInteractionEnabled = false
            view.isAccessibilityElement = false
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            // For the debug log: whether any controller above is still mid-presentation.
            var ancestor = parent
            var beingPresented = false
            while let current = ancestor {
                if current.isBeingPresented { beingPresented = true }
                ancestor = current.parent
            }
            onAppeared?(AppearState(ancestorBeingPresented: beingPresented,
                                    hasTransitionCoordinator: transitionCoordinator != nil))
        }
    }
}
