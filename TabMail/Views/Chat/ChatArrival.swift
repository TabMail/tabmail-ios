/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import SwiftUI

/// A new email arriving in the open chat (ADR-IOS-114 decision 23): it rises from behind the
/// reply field like a new message, and the chat moves up with it, in one animation. Under Reduce
/// Motion the space opens at once (the chat jumps up) and the bubble fades in. The open's own
/// landing is not an arrival: nothing animates until the chat has landed. Nor is the user's own
/// newest email (their sent reply): its bubble was already showing as it sent.
enum ChatArrival {
    enum Style: Equatable {
        case rise
        case fade
    }

    static func style(reduceMotion: Bool) -> Style {
        reduceMotion ? .fade : .rise
    }

    /// Whether a newest email showing now may animate in: the chat has landed, and the newest is not
    /// the user's own (a reply they sent, filed from Sent, is not an arrival).
    static func animates(landed: Bool, newestIsOwn: Bool) -> Bool {
        landed && !newestIsOwn
    }

    /// Whether a change of the newest email is an arrival to animate: the chat has landed and
    /// already showed a newest email, the newest is now another one, and it is not the user's own.
    static func isArrival(landed: Bool, oldNewest: String?, newNewest: String?, newestIsOwn: Bool) -> Bool {
        animates(landed: landed, newestIsOwn: newestIsOwn)
            && oldNewest != nil && newNewest != nil && oldNewest != newNewest
    }

    /// The layout's animation: the rise, or none under Reduce Motion (the space opens at once).
    static func animation(_ style: Style) -> Animation? {
        switch style {
        case .rise: .easeOut(duration: ChatViewLayout.arrivalRiseDuration)
        case .fade: nil
        }
    }

    /// A row's entrance: only the arriving newest email (`isArrivalRow`) rises or fades in; every
    /// other row, the open's own load included, appears as it is. The fade carries its own timing,
    /// so under Reduce Motion it would otherwise fade in the rows of a thread load.
    static func transition(_ style: Style, isArrivalRow: Bool) -> AnyTransition {
        isArrivalRow ? transition(style) : .identity
    }

    /// The bubble's own entrance: from behind the field, or a fade that carries its own timing.
    static func transition(_ style: Style) -> AnyTransition {
        switch style {
        case .rise: .move(edge: .bottom)
        case .fade: .opacity.animation(.easeIn(duration: ChatViewLayout.arrivalFadeDuration))
        }
    }
}
