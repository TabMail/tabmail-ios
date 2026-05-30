/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import SwiftUI

/// Environment key exposing whether the user has an active TabMail session.
/// Child views use `@Environment(\.hasTabMailSession)` to gate AI features.
private struct HasTabMailSessionKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var hasTabMailSession: Bool {
        get { self[HasTabMailSessionKey.self] }
        set { self[HasTabMailSessionKey.self] = newValue }
    }
}
