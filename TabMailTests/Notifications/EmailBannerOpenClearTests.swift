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

    @Test("Starting again installs no second observer")
    func startIsIdempotent() {
        let (clear, counter, first) = makeStarted()
        let second = NotificationCenter()
        withExtendedLifetime(clear) {
            clear.start(notificationCenter: second)
            second.post(name: UIApplication.didBecomeActiveNotification, object: nil)
            #expect(counter.count == 0)
            first.post(name: UIApplication.didBecomeActiveNotification, object: nil)
            #expect(counter.count == 1)
        }
    }
}

/// The app's own wiring, which a unit test cannot drive: the launch installs the
/// shared instance, the shared instance removes the email banners, and that removal
/// removes only what `emailBannerIdentifiers` picks. Each check reads the source with
/// every run of whitespace made one space.
@Suite("Email banner removal wiring")
struct EmailBannerOpenClearWiringTests {

    private static let projectRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private static func source(_ path: String) throws -> String {
        let raw = try String(contentsOf: projectRoot.appendingPathComponent(path), encoding: .utf8)
        return raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// The text of `text` from `start` up to the next `end` after it.
    private static func body(of text: String, from start: String, to end: String) throws -> Substring {
        let open = try #require(text.range(of: start), "\(start)")
        let close = try #require(text[open.upperBound...].range(of: end), "\(end) after \(start)")
        return text[open.upperBound..<close.lowerBound]
    }

    private static func count(_ needle: String, in text: some StringProtocol) -> Int {
        text.components(separatedBy: needle).count - 1
    }

    @Test("The launch installs the shared instance, once")
    func launchInstallsSharedInstance() throws {
        let appDelegate = try Self.source("TabMail/App/AppDelegate.swift")
        let launch = try Self.body(
            of: appDelegate,
            from: "didFinishLaunchingWithOptions launchOptions:",
            to: " func ")
        #expect(Self.count("EmailBannerOpenClear.shared.start()", in: launch) == 1)
        #expect(Self.count("EmailBannerOpenClear", in: appDelegate) == 1)
    }

    @Test("The shared instance removes the email banners")
    func sharedInstanceRemovesEmailBanners() throws {
        let text = try Self.source("TabMail/Services/Notifications/EmailBannerOpenClear.swift")
        #expect(text.contains("static let shared = EmailBannerOpenClear(remove: removeEmailBanners)"))
        #expect(text.contains(
            "private static func removeEmailBanners() { Task { await NotificationCleanupService.removeEmailBanners() } }"))
    }

    @Test("The removal removes only the identifiers emailBannerIdentifiers picks")
    func removalRemovesOnlyEmailBanners() throws {
        let text = try Self.source("Shared/Notifications/NotificationCleanupService.swift")
        let removal = try Self.body(of: text, from: "static func removeEmailBanners() async {", to: " static func ")
        #expect(removal.contains("let toRemove = emailBannerIdentifiers(delivered.map(snapshot(from:)))"))
        #expect(Self.count("removeDeliveredNotifications(withIdentifiers: toRemove)", in: removal) == 1)
        #expect(Self.count("removeDeliveredNotifications", in: removal) == 1)
        #expect(Self.count("removeAllDeliveredNotifications", in: removal) == 0)
    }

    /// The classifier reads `hash`; `ProactiveNotifyService` must write that key on
    /// every reminder and nudge it posts, or opening the app would remove them.
    @Test("Every reminder and nudge ProactiveNotifyService posts carries the hash key")
    func remindersCarryTheHashKey() throws {
        let text = try Self.source("TabMail/Services/AI/ProactiveNotifyService.swift")
        #expect(Self.count("content.userInfo = [\"hash\": reminder.hash,", in: text) == 1)
        #expect(Self.count("content.userInfo = [\"hash\": r.hash,", in: text) == 1)
        #expect(Self.count("info[\"hash\"] = r.hash", in: text) == 1)
        #expect(Self.count("UNNotificationRequest(identifier:", in: text) == 3)
    }

    /// Each email category is registered with the system, so its action buttons show.
    @Test("Every email category is registered at launch")
    func everyEmailCategoryIsRegistered() throws {
        let appDelegate = try Self.source("TabMail/App/AppDelegate.swift")
        for category in EmailNotificationBuilder.categoryIdentifiers {
            #expect(Self.count("identifier: \"\(category)\",", in: appDelegate) == 1, "\(category)")
        }
    }
}
