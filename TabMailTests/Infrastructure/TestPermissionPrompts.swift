/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Contacts
import Foundation
import ObjectiveC.runtime
import UserNotifications

/// Answers every notification and Contacts permission request in the test
/// host with a silent "denied", for the rest of the test process.
///
/// On a simulator where a permission was never answered, a request shows the
/// system alert, and nothing in a unit test answers it. The scene then stays
/// inactive, where SwiftUI does not start a newly shown view's `.task` (the
/// demo setup behind RootView's splash), so a later test that waits on one
/// fails. Two requests reach the host:
/// - notifications: RootView asks whenever a tutorial run ends
///   (`requestPushPermissionAfterTutorial`), and tutorial tests end runs
///   while it is mounted;
/// - Contacts: ComposeView asks on appear (`ContactSearchService`), and view
///   tests mount it.
/// Each request is queued work that outlives the test that caused it, so a
/// stand-in scoped to one test cannot cover it: this one is installed before
/// the first process-global test body (`ProcessGlobalTestState.withLock`) and
/// never removed.
enum TestPermissionPrompts {
    private static let installed: Void = {
        typealias Completion = @convention(block) (Bool, NSError?) -> Void
        let silentDenial: @convention(block) (AnyObject, Int, @escaping Completion) -> Void = { _, _, completion in
            completion(false, nil)
        }
        replace(UNUserNotificationCenter.self, "requestAuthorizationWithOptions:completionHandler:", with: silentDenial)
        replace(CNContactStore.self, "requestAccessForEntityType:completionHandler:", with: silentDenial)
    }()

    private static func replace(_ type: AnyClass, _ selector: String, with block: Any) {
        guard let method = class_getInstanceMethod(type, NSSelectorFromString(selector)) else {
            preconditionFailure("\(type) has no \(selector)")
        }
        method_setImplementation(method, imp_implementationWithBlock(block))
    }

    static func installIfNeeded() {
        _ = installed
    }
}
