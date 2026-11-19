/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

extension TabMailAuthService {
    /// Runs before a TabMail session is written at sign-in. Not implemented yet: the tests in
    /// `OneAISettingForTheDeviceTests` describe what it must do.
    nonisolated static func clearAIChoiceIfNoMailAccount(
        countMailAccounts: @escaping @Sendable () async throws -> Int = { 0 }
    ) async {}

    /// The decision, given the number of mail accounts (nil: it could not be read). Not
    /// implemented yet.
    nonisolated static func clearAIChoice(mailAccountCount: Int?, in store: UserDefaults) {}
}
