/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import SwiftMail
import Testing
@testable import TabMail

/// The inbox error banner and the account re-authentication alert show only fixed
/// plain lines, never text derived from an error; and the inbox banner is cleared
/// only by a completed sync run that itself raised no banner.
///
/// Earlier, the banner put `error.localizedDescription` on screen when debug
/// logging was unlocked, and every inbox sync failure stored that text. A
/// temporary IMAP refusal therefore reached the screen as
/// `Login failed: no([UNAVAILABLE] …)`. The detail now lives only in the
/// debug-gated logs.
@Suite("Inbox error banner — fixed lines only, cleared only by a clean run",
       .serialized, .processGlobalState)
struct InboxErrorBannerTests {

    /// A marker no fixed line contains. Every error below that can carry text
    /// carries it, so a banner derived from the error would contain it.
    private static let marker = "raw-detail-7f3a"

    private struct UnknownError: Error, CustomStringConvertible, LocalizedError {
        var description: String { "UnknownError(\(InboxErrorBannerTests.marker))" }
        var errorDescription: String? { "Unknown failure \(InboxErrorBannerTests.marker)" }
    }

    /// Every error the sync and login paths can hand the banner decision: the typed
    /// provider, auth, OAuth, transport, IMAP-login and timeout errors, plus an
    /// arbitrary unknown error.
    private static var everyError: [any Error] {
        let m = marker
        let loginReasons = [
            "no([UNAVAILABLE] \(m))", "no([INUSE] \(m))", "no([SERVERBUG] \(m))", "no([LIMIT] \(m))",
            "no([AUTHENTICATIONFAILED] \(m))", "no([AUTHORIZATIONFAILED] \(m))", "no([EXPIRED] \(m))",
            "no([CONTACTADMIN] \(m))", "no(\(m) login failed)", "bad(\(m))",
        ]
        var errors: [any Error] = [
            ProviderError.notConnected,
            ProviderError.messageNotFound,
            ProviderError.authenticationFailed,
            ProviderError.networkError(underlying: HTTPError.networkError(statusCode: 503)),
            ProviderError.networkError(underlying: HTTPError.networkError(statusCode: 429)),
            ProviderError.networkError(underlying: HTTPError.networkError(statusCode: 400)),
            ProviderError.networkError(underlying: NSError(domain: "Gmail", code: 403,
                                                           userInfo: [NSLocalizedDescriptionKey: m])),
            ProviderError.invalidURL(m),
            ProviderError.actionIdentityResolutionFailed(m),
            ProviderError.uidValidityChanged(folderPath: m, stored: 1, live: 2),
            ProviderError.syntheticPlaceholderId([m]),
            ProviderError.syntheticFolderPath(m),
            ProviderError.addressPendingMove(m),
            AuthError.refreshFailed(underlying: m),
            AuthError.noRefreshToken,
            AuthError.noToken,
            OAuthError.tokenExchangeFailed(m),
            OAuthError.notConfigured(m),
            OAuthError.consentFailed(m),
            OAuthError.cancelled,
            OAuthError.noAuthCode,
            IMAPTransportSecurityError.tlsFloorNotMet(host: m),
            IMAPError.connectionFailed(m),
            IMAPError.selectFailed(m),
            IMAPError.fetchFailed(m),
            URLError(.notConnectedToInternet),
            URLError(.badServerResponse),
            NSError(domain: "NIOCore.IOError", code: 1),
            NSError(domain: "com.example.unknown", code: 9, userInfo: [NSLocalizedDescriptionKey: m]),
            TimeoutError(duration: 30),
            CancellationError(),
            UnknownError(),
        ]
        for reason in loginReasons {
            errors.append(IMAPError.loginFailed(reason))
            errors.append(ProviderTemporaryRefusal(underlying: IMAPError.loginFailed(reason)))
        }
        return errors
    }

    // MARK: - The invariant

    @Test("for every error, the banner shows a fixed line or nothing, never the error's text")
    func bannerTextIsAlwaysAFixedLine() {
        for error in Self.everyError {
            guard let line = InboxErrorBanner.text(for: error) else { continue }
            #expect(InboxErrorBanner.allLines.contains(line), "not a fixed line for \(error)")
            #expect(!line.contains(Self.marker), "banner carried the error's text for \(error)")
            #expect(line != error.localizedDescription, "banner showed the error for \(error)")
        }
    }

    @Test("for every error, the re-authentication alert shows a fixed line or nothing")
    func reauthAlertIsAlwaysAFixedLine() {
        for error in Self.everyError {
            for isPassword in [true, false] {
                guard let line = AccountReauthAlert.line(for: error, isPassword: isPassword) else { continue }
                #expect(AccountReauthAlert.allLines.contains(line), "not a fixed line for \(error)")
                #expect(!line.contains(Self.marker), "alert carried the error's text for \(error)")
            }
        }
    }

    /// Non-vacuity: the decision can say yes, and says no where it must.
    @Test("an unknown error raises the generic line; refresh refusals, offline and temporary refusals raise none")
    func bannerDecisionCases() {
        #expect(InboxErrorBanner.text(for: UnknownError()) == InboxErrorBanner.genericMessage)
        #expect(InboxErrorBanner.text(for: IMAPError.loginFailed("no([AUTHENTICATIONFAILED] x)"))
                == InboxErrorBanner.genericMessage)
        #expect(InboxErrorBanner.text(for: AuthError.refreshFailed(underlying: "x")) == nil)
        #expect(InboxErrorBanner.text(for: URLError(.notConnectedToInternet)) == nil)
        #expect(InboxErrorBanner.text(for: CancellationError()) == nil)
        #expect(InboxErrorBanner.text(
            for: ProviderTemporaryRefusal(underlying: IMAPError.loginFailed("no([UNAVAILABLE] x)"))) == nil)
    }

    // MARK: - Clearing: only a completed run that raised nothing clears it

    /// Runs `body` with the shared banner state saved and restored.
    @MainActor
    private func withCleanState(_ body: (AccountManagerState) throws -> Void) rethrows {
        let state = AccountManagerState.shared
        let savedBanner = state.syncErrorBanner
        let savedCompleted = state.lastSyncCompletedAt
        state.syncErrorBanner = nil
        defer {
            state.syncErrorBanner = savedBanner
            state.lastSyncCompletedAt = savedCompleted
        }
        try body(state)
    }

    private static func failing() -> AccountManager.SyncResult {
        AccountManager.SyncResult(hadChanges: false, failed: true,
                                  bannerText: InboxErrorBanner.text(for: UnknownError()))
    }

    private static func succeeding() -> AccountManager.SyncResult {
        AccountManager.SyncResult(hadChanges: true, failed: false)
    }

    @Test("one account failing every run beside one succeeding: the banner stays up for ten runs, then clears once it recovers")
    @MainActor
    func bannerStaysSteadyWhileOneAccountKeepsFailing() {
        withCleanState { state in
            for run in 1...10 {
                let results = [Self.failing(), Self.succeeding()]
                // A mixed run still completes (the foreground poll's aggregate is
                // "not every account failed"; the background poll always stamps).
                state.finishSyncRun(bannerText: AccountManager.SyncResult.runBannerText(results),
                                    completed: true)
                #expect(state.syncErrorBanner == InboxErrorBanner.genericMessage, "banner gone after run \(run)")
            }
            let recovered = [Self.succeeding(), Self.succeeding()]
            state.finishSyncRun(bannerText: AccountManager.SyncResult.runBannerText(recovered), completed: true)
            #expect(state.syncErrorBanner == nil)
        }
    }

    @Test("a completed background or scheduler run clears the banner and advances the timestamp")
    @MainActor
    func backgroundCompletionClearsBanner() {
        withCleanState { state in
            state.finishSyncRun(bannerText: InboxErrorBanner.genericMessage, completed: false)
            #expect(state.syncErrorBanner == InboxErrorBanner.genericMessage)
            let before = state.lastSyncCompletedAt
            state.finishSyncRun(bannerText: AccountManager.SyncResult.runBannerText([Self.succeeding()]),
                                completed: true)
            #expect(state.syncErrorBanner == nil)
            #expect(state.lastSyncCompletedAt != nil)
            #expect(state.lastSyncCompletedAt != before)
        }
    }

    @Test("a run that does not complete never clears the banner")
    @MainActor
    func incompleteRunDoesNotClear() {
        withCleanState { state in
            state.finishSyncRun(bannerText: InboxErrorBanner.genericMessage, completed: false)
            state.finishSyncRun(bannerText: nil, completed: false)
            #expect(state.syncErrorBanner == InboxErrorBanner.genericMessage)
        }
    }

    // MARK: - isAuthError is typed only

    @Test("isAuthError matches only the typed case, never refusal text")
    func isAuthErrorIsTypedOnly() {
        let manager = AccountManager.shared
        #expect(manager.isAuthError(ProviderError.authenticationFailed))
        #expect(!manager.isAuthError(IMAPError.loginFailed("no([UNAVAILABLE] login failed, try later)")))
        #expect(!manager.isAuthError(IMAPError.loginFailed("no([UNAVAILABLE] LOGIN failed)")))
        #expect(!manager.isAuthError(IMAPError.loginFailed("no([AUTHENTICATIONFAILED] x)")))
        #expect(!manager.isAuthError(UnknownError()))
    }
}
