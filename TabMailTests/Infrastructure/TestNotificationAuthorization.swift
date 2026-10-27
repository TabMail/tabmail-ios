/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import ObjectiveC.runtime
import UserNotifications

/// Answers every notification-permission request in the test host with a
/// silent "denied", for the rest of the test process.
///
/// The host app's RootView asks for permission whenever a tutorial run ends
/// (`requestPushPermissionAfterTutorial`), and tutorial tests end runs while
/// it is mounted. On a simulator where permission was never answered, that
/// shows the system alert, and nothing in a unit test answers it. The scene
/// then stays inactive, where SwiftUI does not start a newly shown view's
/// `.task` (the demo setup behind RootView's splash), so a later test that
/// waits on one fails. The request is queued work that outlives the test that
/// ended the run, so a stand-in scoped to one test cannot cover it: this one
/// is installed before the first process-global test body
/// (`ProcessGlobalTestState.withLock`) and never removed.
enum TestNotificationAuthorization {
    private static let installed: Void = {
        typealias Completion = @convention(block) (Bool, NSError?) -> Void
        let silentDenial: @convention(block) (AnyObject, UInt, @escaping Completion) -> Void = { _, _, completion in
            completion(false, nil)
        }
        guard let request = class_getInstanceMethod(
            UNUserNotificationCenter.self,
            NSSelectorFromString("requestAuthorizationWithOptions:completionHandler:")
        ) else {
            preconditionFailure("UNUserNotificationCenter has no requestAuthorizationWithOptions:completionHandler:")
        }
        method_setImplementation(request, imp_implementationWithBlock(silentDenial))
    }()

    static func installIfNeeded() {
        _ = installed
    }
}
