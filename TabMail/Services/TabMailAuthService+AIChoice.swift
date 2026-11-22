/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB

extension TabMailAuthService {
    /// Runs on the line before a TabMail session is written at sign-in. On a device with no
    /// mail account, it clears the device's AI setting (the AI choice, then Opt Out of AI): an
    /// answer stored then was given while trying the demo, so the AI screen asks again after
    /// the first account is added, and AI stays off until it is answered. With a mail account
    /// on the device the answer is kept. Updating the app and refreshing a session do not run it.
    nonisolated static func clearAIChoiceIfNoMailAccount(
        countMailAccounts: @escaping @Sendable () async throws -> Int = { try await mailAccountCount() }
    ) async {
        let count: Int?
        do {
            count = try await countMailAccounts()
        } catch {
            if DebugModeManager.isLoggingEnabled() {
                BackgroundSyncLogger.logDebug("[TabMailAuth] Mail accounts could not be counted at sign-in: \(error)")
            }
            count = nil
        }
        clearAIChoice(mailAccountCount: count, in: AIService.optOutStore)
    }

    /// The decision, given the number of mail accounts (nil: it could not be read, which
    /// clears too: at worst the AI screen is shown once more).
    nonisolated static func clearAIChoice(mailAccountCount: Int?, in store: UserDefaults) {
        if let mailAccountCount, mailAccountCount > 0 { return }
        AIConsentPolicy.clearChoice(in: store)
        if DebugModeManager.isLoggingEnabled() {
            BackgroundSyncLogger.logDebug("[TabMailAuth] No mail account at sign-in: AI choice cleared")
        }
    }

    /// The person's mail accounts: the sidebar's own definition (active, not calendar-only, not
    /// the demo's account, so a demo row left by an unfinished cleanup does not count).
    nonisolated private static func mailAccountCount() async throws -> Int {
        guard await AppStartup.shared.ensureDatabaseReady() else { throw DatabaseUnavailable() }
        return try await AppDatabase.dbPool.read { db in
            try Account.sidebarRequest(demoActive: false).fetchCount(db)
        }
    }
}

/// The app database could not be opened when the mail accounts were counted at sign-in.
private struct DatabaseUnavailable: Error {}
