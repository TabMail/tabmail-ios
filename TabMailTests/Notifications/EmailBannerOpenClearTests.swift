/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import UIKit
@testable import TabMail

/// Email banners are removed when the user opens the app: the first activation of
/// the process. A background launch (no activation) removes nothing, and later
/// activations of the same process remove nothing. Each test drives the app
/// lifecycle notifications on its own `NotificationCenter`.
@MainActor
@Suite("Email banners removed when the app is opened")
struct EmailBannerOpenClearTests {

    private final class RemoveCounter {
        var count = 0
    }

    private func makeStarted() -> (clear: EmailBannerOpenClear, counter: RemoveCounter, center: NotificationCenter) {
        let counter = RemoveCounter()
        let clear = EmailBannerOpenClear(remove: { counter.count += 1 })
        let center = NotificationCenter()
        clear.start(notificationCenter: center)
        return (clear, counter, center)
    }

    @Test("A cold launch in the foreground removes the email banners")
    func coldForegroundLaunch_removes() {
        let (clear, counter, center) = makeStarted()
        withExtendedLifetime(clear) {
            center.post(name: UIApplication.didBecomeActiveNotification, object: nil)
            #expect(counter.count == 1)
        }
    }

    @Test("A background launch removes nothing")
    func backgroundLaunch_removesNothing() {
        let (clear, counter, center) = makeStarted()
        withExtendedLifetime(clear) {
            // A silent push, a background refresh or a notification action: the app
            // runs and goes back to the background without ever becoming active.
            center.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
            #expect(counter.count == 0)
        }
    }

    @Test("The first open of a background-launched process removes them; later activations do not")
    func firstOpenAfterBackgroundLaunch_removesOnce() {
        let (clear, counter, center) = makeStarted()
        withExtendedLifetime(clear) {
            center.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
            #expect(counter.count == 0)
            center.post(name: UIApplication.willEnterForegroundNotification, object: nil)
            #expect(counter.count == 0)
            center.post(name: UIApplication.didBecomeActiveNotification, object: nil)
            #expect(counter.count == 1)
            center.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
            center.post(name: UIApplication.willEnterForegroundNotification, object: nil)
            center.post(name: UIApplication.didBecomeActiveNotification, object: nil)
            #expect(counter.count == 1)
        }
    }

    @Test("Starting twice still removes once")
    func startIsIdempotent() {
        let (clear, counter, center) = makeStarted()
        withExtendedLifetime(clear) {
            clear.start(notificationCenter: center)
            center.post(name: UIApplication.didBecomeActiveNotification, object: nil)
            #expect(counter.count == 1)
        }
    }
}
