/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import SwiftUI
import Testing
import UIKit
@testable import TabMail

/// ADR-IOS-121 (#1583): what the upgrade screens say about the time. The notice says
/// "up to N minutes" (`DatabaseUpgrade.noticeMinutes`, or the fallback when a database
/// cannot be read); the running screen says the minutes left, "Less than a minute
/// remaining" or "Almost done" (`DatabaseUpgradeProgress.Remaining`).
///
/// #1589: the screens can always be read whole. At the largest text sizes the notice
/// is taller than the screen; it keeps its full height and scrolls instead of cutting
/// its text off.
@MainActor
@Suite("What the upgrade screens say, and that they can always be read whole")
struct DatabaseUpgradeViewTests {

    @Test("The notice: up to N minutes, one minute in the singular, and the fallback is 10 minutes")
    func theNoticeTime() {
        let fallback = DatabaseUpgradeView.noticeTime(minutes: SyncConfig.databaseUpgradeNoticeFallbackMinutes)
        let one = DatabaseUpgradeView.noticeTime(minutes: 1)
        let ten = DatabaseUpgradeView.noticeTime(minutes: 10)

        #expect(fallback == "It can take up to 10 minutes. Keep TabMail open while it runs.", "\(fallback)")
        #expect(one == "It can take up to 1 minute. Keep TabMail open while it runs.", "\(one)")
        #expect(ten == fallback, "\(ten)")
    }

    @Test("The running screen: about N minutes remaining (one minute in the singular), less than a minute, almost done")
    func theRemainingTime() {
        let two = DatabaseUpgradeView.remainingText(.minutes(2))
        let one = DatabaseUpgradeView.remainingText(.minutes(1))
        let underAMinute = DatabaseUpgradeView.remainingText(.lessThanAMinute)
        let almostDone = DatabaseUpgradeView.remainingText(.almostDone)

        #expect(two == "About 2 minutes remaining", "\(two)")
        #expect(one == "About 1 minute remaining", "\(one)")
        #expect(underAMinute == "Less than a minute remaining", "\(underAMinute)")
        #expect(almostDone == "Almost done", "\(almostDone)")
    }

    @Test("At the largest accessibility text size the notice keeps its full height and scrolls, so none of its text is cut off; at the default size it fits on the screen")
    func theNoticeCanAlwaysBeReadWhole() async throws {
        let upgrade = await Self.openNotice()
        let presented = upgrade.isPresented && upgrade.screen == .notice

        let largest = try await Self.layOut(upgrade, textSize: .accessibility5)
        let normal = try await Self.layOut(upgrade, textSize: .large)

        #expect(presented, "precondition: the notice is open")
        #expect(largest.content > largest.visible, "the largest text size: the notice keeps its full height, taller than the screen, and scrolls: \(largest)")
        #expect(normal.content <= normal.visible + Self.layoutTolerance, "the default text size: the notice fits on the screen: \(normal)")
    }

    /// An iPhone-sized screen, in points.
    private static let screen = CGRect(x: 0, y: 0, width: 393, height: 852)
    /// Rounding between the content's height and the screen's, in points.
    private static let layoutTolerance: CGFloat = 1
    /// How long the hosted view may take to lay out its scroll view.
    private static let layoutDeadline: Duration = .seconds(3)
    private static let layoutPoll: Duration = .milliseconds(20)

    /// The notice for one tiny database still to upgrade: room and power, no warnings.
    private static func openNotice() async -> DatabaseUpgrade {
        let path = FileManager.default.temporaryDirectory.path
        let states = [
            DatabaseUpgrade.DatabaseState(
                path: path,
                state: DatabaseVacuum.SpaceState(autoVacuum: DatabaseVacuum.noneMode, pageCount: 1, freePages: 0, pageSize: 4_096)),
        ]
        let upgrade = DatabaseUpgrade(
            scheduler: SyncScheduler(foreground: true, stageTwo: { _ in }),
            upgradeDatabases: { _ in [] },
            readStates: { states },
            readBattery: { (-1, .unknown) })
        await upgrade.openNotice()
        return upgrade
    }

    /// The screen hosted in a window of `screen`'s size at `textSize`: the height of its
    /// scroll view's content and the height the scroll view shows.
    private static func layOut(
        _ upgrade: DatabaseUpgrade, textSize: DynamicTypeSize
    ) async throws -> (content: CGFloat, visible: CGFloat) {
        let host = UIHostingController(rootView: DatabaseUpgradeView(upgrade: upgrade).environment(\.dynamicTypeSize, textSize))
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = try #require(scenes.first, "the test host has a window scene")
        let window = UIWindow(windowScene: scene)
        window.frame = screen
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true }

        let deadline = ContinuousClock.now + layoutDeadline
        var laidOut: UIScrollView?
        while laidOut == nil, ContinuousClock.now < deadline {
            host.view.layoutIfNeeded()
            if let scroll = scrollView(in: host.view), scroll.contentSize.height > 0 {
                laidOut = scroll
            } else {
                try await Task.sleep(for: layoutPoll)
            }
        }
        let scroll = try #require(laidOut, "the screen's content is in a scroll view")
        let insets = scroll.adjustedContentInset
        return (scroll.contentSize.height, scroll.bounds.height - insets.top - insets.bottom)
    }

    private static func scrollView(in view: UIView) -> UIScrollView? {
        if let scroll = view as? UIScrollView { return scroll }
        for subview in view.subviews {
            if let scroll = scrollView(in: subview) { return scroll }
        }
        return nil
    }
}
