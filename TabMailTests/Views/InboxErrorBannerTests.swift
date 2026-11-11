/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import SwiftMail
import Testing
@testable import TabMail

/// The inbox error banner and the account re-authentication alert show only fixed
/// plain lines, never text derived from an error. When the banner is raised and
/// cleared is pinned through the real run entry points in
/// `SyncRunBannerEntryPointTests`.
///
/// Earlier, the banner put `error.localizedDescription` on screen when debug
/// logging was unlocked, and every inbox sync failure stored that text. A
/// temporary IMAP refusal therefore reached the screen as
/// `Login failed: no([UNAVAILABLE] …)`. The detail now lives only in the
/// debug-gated logs.
@Suite("Inbox error banner and re-auth alert — fixed lines only",
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

    private static let host = "imap.example.com"

    @Test("for every error, the re-authentication alert shows a fixed line or nothing")
    func reauthAlertIsAlwaysAFixedLine() {
        let allowed: Set<String> = [AccountReauthAlert.passwordLine, AccountReauthAlert.setupLine,
                                    AccountReauthAlert.oauthLine, AccountReauthAlert.tlsLine(host: Self.host)]
        for error in Self.everyError {
            let lines = [AccountReauthAlert.passwordUpdateLine(for: error, host: Self.host),
                         AccountReauthAlert.oauthLine(for: error)].compactMap { $0 }
            for line in lines {
                #expect(allowed.contains(line), "not a fixed line for \(error)")
                #expect(!line.contains(Self.marker), "alert carried the error's text for \(error)")
            }
        }
    }

    @Test("the password-update alert picks its line by what failed")
    func reauthAlertLineByPhase() {
        // The server refused the new password (as `updateIMAPPassword` reports it).
        #expect(AccountReauthAlert.passwordUpdateLine(for: ProviderError.authenticationFailed, host: Self.host)
                == AccountReauthAlert.passwordLine)
        // The server cannot meet the TLS minimum: main's sentence, for the account's host.
        let tls = AccountReauthAlert.passwordUpdateLine(
            for: IMAPTransportSecurityError.tlsFloorNotMet(host: Self.host), host: Self.host)
        #expect(tls == IMAPTransportSecurityError.tlsFloorNotMet(host: Self.host).description)
        #expect(tls != AccountReauthAlert.passwordLine)
        // The password was accepted, then saving or the sync failed; or the server
        // refused for now.
        for error: any Error in [UnknownError(), NSError(domain: "com.example.keychain", code: -25299),
                                 ProviderTemporaryRefusal(underlying: UnknownError())] {
            #expect(AccountReauthAlert.passwordUpdateLine(for: error, host: Self.host)
                    == AccountReauthAlert.setupLine, "\(error)")
        }
        // Offline keeps the alert closed, as before.
        #expect(AccountReauthAlert.passwordUpdateLine(for: URLError(.notConnectedToInternet), host: Self.host) == nil)
        #expect(Set([AccountReauthAlert.passwordLine, AccountReauthAlert.setupLine, tls ?? ""]).count == 3)
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
