/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import SwiftUI
import UIKit

/// Locks the app to a specific interface orientation (or set of
/// orientations) while the modified view is on screen. Used by the
/// onboarding consent screens — `ConsentGateView`, `AIConsentView`,
/// `PushConsentView`, `AddAccountGmailOutlookView`,
/// `AddAccountICloudView`, `AddAccountGeneralView` — which are
/// designed portrait-only and look broken if the user rotates
/// mid-flow.
///
/// Mechanism (iOS 16+):
/// 1. `onAppear` writes the desired mask to `AppDelegate.orientationLock`.
///    `application(_:supportedInterfaceOrientationsFor:)` returns this
///    value, so the system honours the lock for the whole app while
///    the view is mounted.
/// 2. We then call `requestGeometryUpdate(.iOS(...))` on the active
///    window scene to actively rotate the device if it's already in a
///    disallowed orientation. Without this, the lock only takes effect
///    on the next user rotation.
/// 3. `onDisappear` restores `.all` so the rest of the app rotates
///    normally again.
private struct OrientationLockModifier: ViewModifier {
    let mask: UIInterfaceOrientationMask

    func body(content: Content) -> some View {
        content
            .onAppear {
                AppDelegate.orientationLock = mask
                requestGeometryUpdate(mask: mask)
            }
            .onDisappear {
                AppDelegate.orientationLock = .all
            }
    }

    private func requestGeometryUpdate(mask: UIInterfaceOrientationMask) {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive })
            ?? UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first
        else { return }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { error in
            // Failures are non-fatal — system may reject the update if
            // another scene is requesting a conflicting orientation.
            print("[OrientationLock] requestGeometryUpdate failed: \(error)")
        }
    }
}

extension View {
    /// Locks the app to the given interface orientation while this view
    /// is on screen; restores `.all` on disappear. See
    /// `OrientationLockModifier` for the iOS 16+ mechanism.
    func lockOrientation(_ mask: UIInterfaceOrientationMask) -> some View {
        modifier(OrientationLockModifier(mask: mask))
    }
}
