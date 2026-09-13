/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import SwiftUI
import Testing
import UIKit
@testable import TabMail

/// Issue #110, the production control: the dashboard's real Sign Out button
/// (`SignOutButton`, driven by `SignOutButtonModel`) is hosted in a `UIWindow`
/// and driven through `SignOutButtonModel.activate(onLocalFailure:)` — the
/// exact entry point the button's action calls — while the rendered hierarchy
/// is inspected across the state transition. A hosted SwiftUI button publishes
/// no accessibility element in this process (verified: the hosting view
/// reports zero elements and zero subviews), so the tap itself cannot be
/// driven from a test; the button's remaining glue is the one-line action
/// closure and `.disabled(model.isSigningOut)`.
///
/// Pinned invariants: no indicator while idle; indicator shown for exactly
/// as long as the sign-out call is pending; a second activation while pending
/// does not start a second sign-out; a false result reaches the failure
/// callback exactly once and releases the control so a retry activation runs
/// the sign-out again.
@Suite("Sign Out button", .serialized)
@MainActor
struct SignOutButtonTests {

    /// A sign-out call the test releases by hand, counting entries so a
    /// second activation while pending is observable.
    final class HeldSignOut: @unchecked Sendable {
        private var continuation: CheckedContinuation<Bool, Never>?
        private(set) var entries = 0

        @MainActor
        func perform() async -> Bool {
            entries += 1
            return await withCheckedContinuation { self.continuation = $0 }
        }

        @MainActor
        func release(returning result: Bool) {
            continuation?.resume(returning: result)
            continuation = nil
        }
    }

    @MainActor
    final class FailureRecorder {
        private(set) var count = 0
        func record() { count += 1 }
    }

    @Test("activating the hosted control shows its indicator while the sign-out is pending, ignores a second activation, then releases it")
    func activationDrivesTheIndicatorAndIgnoresReentry() async throws {
        let held = HeldSignOut()
        let failures = FailureRecorder()
        let model = SignOutButtonModel(perform: held.perform)
        let host = try Self.host(SignOutButton(model: model, onLocalFailure: failures.record))
        defer { host.window.isHidden = true }

        #expect(!model.isSigningOut, "idle: not in flight")
        #expect(!Self.containsProgressIndicator(host.window), "idle: no spinner")

        model.activate(onLocalFailure: failures.record)
        #expect(model.isSigningOut, "activation must mark the control in flight synchronously, before the call is entered")
        let pending = await Self.waitUntil { held.entries == 1 && Self.containsProgressIndicator(host.window) }
        #expect(pending, "pending: the activated control must render its indicator while the call is held")

        // A second activation while pending must not start a second sign-out:
        // it would race the first one's handshake for the same session.
        model.activate(onLocalFailure: failures.record)
        try await Task.sleep(for: .milliseconds(100))
        #expect(held.entries == 1, "an activation while one is pending must be a no-op")

        held.release(returning: true)
        let released = await Self.waitUntil { !model.isSigningOut && !Self.containsProgressIndicator(host.window) }
        #expect(released, "after completion the control is released and the indicator is gone")
        #expect(failures.count == 0, "a successful local completion must not report a failure")
    }

    @Test("a sign-out that cannot complete locally reports the failure once and the control accepts a retry")
    func localFailureIsReportedAndRetryIsAccepted() async throws {
        let held = HeldSignOut()
        let failures = FailureRecorder()
        let model = SignOutButtonModel(perform: held.perform)
        let host = try Self.host(SignOutButton(model: model, onLocalFailure: failures.record))
        defer { host.window.isHidden = true }

        model.activate(onLocalFailure: failures.record)
        _ = await Self.waitUntil { held.entries == 1 }
        held.release(returning: false)
        let reported = await Self.waitUntil { failures.count == 1 }
        #expect(reported, "a false result must reach the failure callback exactly once")
        let released = await Self.waitUntil { !model.isSigningOut && !Self.containsProgressIndicator(host.window) }
        #expect(released, "a failed local completion must release the control for the retry")

        model.activate(onLocalFailure: failures.record)
        let retried = await Self.waitUntil { held.entries == 2 }
        #expect(retried, "the retry activation must run the sign-out again")
        held.release(returning: true)
        _ = await Self.waitUntil { !model.isSigningOut }
        #expect(failures.count == 1, "the successful retry must not report another failure")
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
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        controller.view.layoutIfNeeded()
        return Host(window: window)
    }

    /// Polls on the main actor, letting SwiftUI apply its pending updates
    /// between checks. Bounded so a broken binding fails the assertion rather
    /// than hanging the process.
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
