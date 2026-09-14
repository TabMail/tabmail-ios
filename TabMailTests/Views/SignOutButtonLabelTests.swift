/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import SwiftUI
import Testing
import UIKit
@testable import TabMail

/// Issue #110: the Sign Out control must show a progress indicator while
/// sign-out is in flight, and must NOT show one while idle. The label is
/// hosted for real in a `UIWindow` and the rendered UIKit hierarchy is
/// inspected, so this is a rendering assertion rather than a check of the
/// Boolean that drives it. Two-sided on purpose: a label that always showed
/// the indicator, or never did, fails one of the two cases.
@Suite("Sign Out button label", .serialized)
@MainActor
struct SignOutButtonLabelTests {

    @Test("shows a progress indicator only while signing out")
    func progressIndicatorTracksSigningOut() throws {
        #expect(try Self.hasProgressIndicator(isSigningOut: false) == false,
                "an idle Sign Out button must not show a spinner")
        #expect(try Self.hasProgressIndicator(isSigningOut: true) == true,
                "while sign-out is in flight the control must render its progress indicator")
    }

    // MARK: - Hosting

    private struct Host {
        let window: UIWindow
        let controller: UIHostingController<SignOutButtonLabel>
    }

    private static func host(isSigningOut: Bool) throws -> Host {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first else {
            throw HostingFailure("no UIWindowScene is available to host SignOutButtonLabel")
        }
        let controller = UIHostingController(rootView: SignOutButtonLabel(isSigningOut: isSigningOut))
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 120)
        window.rootViewController = controller
        window.isHidden = false
        window.layoutIfNeeded()
        controller.view.layoutIfNeeded()
        return Host(window: window, controller: controller)
    }

    private static func hasProgressIndicator(isSigningOut: Bool) throws -> Bool {
        let host = try host(isSigningOut: isSigningOut)
        defer { host.window.isHidden = true }
        return containsProgressIndicator(host.window)
    }

    /// SwiftUI backs an indeterminate `ProgressView` on iOS with a
    /// `UIActivityIndicatorView`; the accessibility identifier is checked as
    /// well so the assertion survives a backing-class change in either
    /// direction, and the identifier alone survives if the class changes.
    private static func containsProgressIndicator(_ view: UIView) -> Bool {
        if view is UIActivityIndicatorView { return true }
        if view.accessibilityIdentifier == "signOut.progress" { return true }
        return view.subviews.contains(where: containsProgressIndicator)
    }

    private struct HostingFailure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}
