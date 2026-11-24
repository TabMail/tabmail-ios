/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import UIKit

/// Removes every delivered email banner when the user opens the app
/// (`NotificationCleanupService.removeEmailBanners`; reminders and other
/// notifications stay, the badge is not touched).
///
/// "Opens" is the first `UIApplication.didBecomeActiveNotification` of the
/// process: a cold launch in the foreground, or the first time the user brings
/// up a process iOS launched in the background. A background launch (a silent
/// push, a background refresh, a notification's action button) never activates
/// the app, so it removes nothing: it often comes right after a new-mail banner
/// the user has not seen yet. Later activations of the same process remove
/// nothing either; while the process lives, `InboxNotificationObserver` clears
/// a banner when its email leaves the inbox.
///
/// This replaces the observer's launch seed, which read every inbox row inside
/// the launch write only so it could clear such banners. Accepted edge: a banner
/// shown before a background launch, for an email that leaves the inbox while
/// the app stays in the background, stays until the app is opened or the
/// 24-hour `NotificationCleanupService` sweep removes it.
@MainActor
final class EmailBannerOpenClear {

    static let shared = EmailBannerOpenClear(remove: {
        Task { await NotificationCleanupService.removeEmailBanners() }
    })

    private let remove: @MainActor () -> Void
    private var hasRemoved = false
    private var activeObserver: NSObjectProtocol?

    /// `remove` runs once, at the first activation. Tests inject a recorder.
    init(remove: @escaping @MainActor () -> Void) {
        self.remove = remove
    }

    /// Install from `application(_:didFinishLaunchingWithOptions:)`, which runs
    /// before the app can become active. Idempotent.
    ///
    /// `queue: nil` delivers on the posting thread; UIKit posts
    /// `didBecomeActiveNotification` on the main thread.
    func start(notificationCenter: NotificationCenter = .default) {
        guard activeObserver == nil else { return }
        activeObserver = notificationCenter.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil, queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.appDidBecomeActive()
            }
        }
    }

    /// The first activation of the process removes the banners; later ones do nothing.
    func appDidBecomeActive() {
        guard !hasRemoved else { return }
        hasRemoved = true
        remove()
    }
}
