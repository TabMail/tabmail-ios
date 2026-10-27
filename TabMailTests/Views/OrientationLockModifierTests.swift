/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import ObjectiveC.runtime
import Synchronization
import SwiftUI
import Testing
import UIKit
@testable import TabMail

/// `lockOrientation` asks UIKit to rotate, and UIKit may report a refusal on
/// a background queue. The refusal is only logged: it must never take the
/// app down (the tutorial's welcome and finish pages and the onboarding
/// consent screens all lock to portrait).
@MainActor
@Suite("A refused orientation request is harmless", .serialized, .processGlobalState)
struct OrientationLockModifierTests {
    private final class Calls: Sendable {
        let count = Mutex(0)
    }

    private typealias ErrorHandler = @convention(block) (NSError) -> Void

    /// Holds UIKit's error handler for the hop to a background queue.
    private final class HandlerBox: @unchecked Sendable {
        let handler: ErrorHandler?
        init(_ handler: ErrorHandler?) { self.handler = handler }
    }

    /// Stands in for `UIWindowScene.requestGeometryUpdate(_:errorHandler:)`:
    /// refuses every request, reporting it on a background queue.
    private static func refusingImplementation(_ calls: Calls) -> IMP {
        let block: @convention(block) (AnyObject, AnyObject, ErrorHandler?) -> Void = { _, _, handler in
            calls.count.withLock { $0 += 1 }
            let box = HandlerBox(handler)
            DispatchQueue.global().async {
                box.handler?(NSError(domain: "OrientationLockModifierTests", code: 1))
            }
        }
        return imp_implementationWithBlock(block)
    }

    @Test("A refusal reported on a background queue leaves the locked view on screen")
    func refusalOffTheMainQueue() async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let method = try #require(class_getInstanceMethod(
            UIWindowScene.self, #selector(UIWindowScene.requestGeometryUpdate(_:errorHandler:))))
        let calls = Calls()
        let replacement = Self.refusingImplementation(calls)
        let original = method_setImplementation(method, replacement)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = UIHostingController(rootView: Color.clear.lockOrientation(.portrait))
        defer {
            window.isHidden = true
            window.rootViewController = nil
            method_setImplementation(method, original)
            imp_removeBlock(replacement)
            AppDelegate.orientationLock = .all
        }
        window.isHidden = false
        window.makeKeyAndVisible()
        window.layoutIfNeeded()

        var requested = false
        for _ in 0..<200 where !requested {
            requested = calls.count.withLock { $0 } > 0
            if !requested { try await Task.sleep(for: .milliseconds(25)) }
        }
        try #require(requested, "the locked view asked UIKit to rotate")
        // Give the refusal time to arrive; before the fix it trapped here.
        try await Task.sleep(for: .milliseconds(500))
        #expect(window.rootViewController != nil)
        #expect(AppDelegate.orientationLock == .portrait, "the lock stays in place after a refused rotation")
    }
}
