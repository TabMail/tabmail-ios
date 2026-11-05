/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// Whether the chat view, and the AI work only it needs, is on.
///
/// The chat view lands on `main` in several changes, and `main` must stay releasable in between, so
/// release builds keep it off (`isAvailableInBuild`) until the last of them turns it on. Until then
/// it can be turned on from the debug menu for testing. While it is off nothing requests summaries
/// for whole threads (they would spend model calls on a feature nobody sees).
///
/// Read `isActive` ONCE at the start of an operation and pass the value along; never re-read it
/// mid-operation.
enum ChatViewConfig {
    /// The release gate: false until the chat view ships.
    static let isAvailableInBuild = false

    private static let debugOverrideKey = "debug_chat_view_enabled"

    /// The debug menu's override. Only counts while debug mode is unlocked, like
    /// `BackendConfig.useDevServers`.
    static var debugOverride: Bool {
        get {
            guard UserDefaults.standard.bool(forKey: "debug_mode_unlocked") else { return false }
            return UserDefaults.standard.bool(forKey: debugOverrideKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: debugOverrideKey)
        }
    }

    static var isActive: Bool { isAvailableInBuild || debugOverride }
}
