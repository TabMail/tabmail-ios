/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import SwiftUI
import Testing
import UIKit
@testable import TabMail

/// Issue #110, the production binding: the dashboard's real Sign Out control
/// (`SignOutButton`, driven by `SignOutButtonModel`) must render its progress
/// indicator for exactly as long as the sign-out call is pending. The control
/// is hosted in a `UIWindow` and the rendered UIKit hierarchy is inspected
/// across the state transition, so this fails if the button stops feeding its
/// in-flight state to the label, if the label is swapped back for a static
/// one, or if the model releases the state before the call returns.
@Suite("Sign Out button", .serialized)
@MainActor
struct SignOutButtonTests {

    /// A sign-out call the test releases by hand.
    final class HeldSignOut: @unchecked Sendable {
        private var continuation: CheckedContinuation<Bool, Never>?
        private(set) var entered = false

        @MainActor
        func perform() async -> Bool {
            entered = true
            return await withCheckedContinuation { self.continuation = $0 }
        }

        @MainActor
        func release(returning result: Bool) {
            continuation?.resume(returning: result)
            continuation = nil
        }
    }

    @Test("the hosted control shows its indicator while the sign-out is pending, and not before or after")
    func indicatorTracksThePendingSignOut() async throws {
        let held = HeldSignOut()
        let model = SignOutButtonModel(perform: held.perform)
        let host = try Self.host(SignOutButton(model: model, onLocalFailure: {}))
        defer { host.window.isHidden = true }

        #expect(!Self.containsProgressIndicator(host.window),
                "idle: the real control must not show a spinner")

        let signOut = Task { await model.signOut() }
        let appeared = await Self.waitUntil { held.entered && Self.containsProgressIndicator(host.window) }
        #expect(appeared, "pending: the control must render its indicator while the sign-out call is held")
        #expect(model.isSigningOut)

        held.release(returning: true)
        let result = await signOut.value
        #expect(result)
        let disappeared = await Self.waitUntil { !Self.containsProgressIndicator(host.window) }
        #expect(disappeared, "after completion the indicator must be gone again")
        #expect(!model.isSigningOut)
    }

    @Test("a sign-out that cannot complete locally reports the failure and releases the control")
    func localFailureIsReportedAndTheControlIsReleased() async throws {
        let held = HeldSignOut()
        let model = SignOutButtonModel(perform: held.perform)
        let signOut = Task { await model.signOut() }
        _ = await Self.waitUntil { held.entered }
        #expect(model.isSigningOut)

        held.release(returning: false)
        let result = await signOut.value
        #expect(!result, "the model must hand the local-failure result back so the dashboard can show its retry message")
        #expect(!model.isSigningOut, "a failed local completion must release the control for the retry tap")
    }

    // MARK: - Hosting

    private struct Host {
        let window: UIWindow
    }

    private static func host<V: View>(_ view: V) throws -> Host {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first else {
            throw HostingFailure("no UIWindowScene is available to host SignOutButton")
        }
        let controller = UIHostingController(rootView: view)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 120)
        window.rootViewController = controller
        window.isHidden = false
        window.layoutIfNeeded()
        controller.view.layoutIfNeeded()
        return Host(window: window)
    }

    /// Polls the rendered hierarchy on the main actor, letting SwiftUI apply
    /// its pending updates between checks. Bounded so a broken binding fails
    /// the assertion rather than hanging the process.
    private static func waitUntil(seconds: TimeInterval = 2, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    private static func containsProgressIndicator(_ view: UIView) -> Bool {
        view.layoutIfNeeded()
        if view is UIActivityIndicatorView { return true }
        if view.accessibilityIdentifier == "signOut.progress" { return true }
        return view.subviews.contains(where: containsProgressIndicator)
    }

    private struct HostingFailure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}
