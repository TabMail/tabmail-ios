/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// Requests to TabMail's own servers (the backend, device sync, sign-in, push, billing, templates) carry
/// the user's TabMail sign-in token, and none of those servers answers with a redirect. Such a request
/// never follows one: the redirect response is handed back to the caller as the answer (a 3xx, which
/// every caller treats as a failed request), so the token reaches only the server the app addressed.
///
/// Every other host keeps URLSession's default handling: Gmail and Microsoft Graph, a CalDAV server
/// (iCloud sends its clients on to another host), and the pages the AI web tool reads.
///
/// The app's sessions get it at creation (`sharedEphemeralSession`, the LLM sessions); the notification
/// service extension's calls on `URLSession.shared` pass it with each request.
final class OwnServerRedirectPolicy: NSObject, URLSessionTaskDelegate, Sendable {

    /// The domain whose subdomains are TabMail's own servers. The bare domain is the public website,
    /// which the app only links to or reads without a token.
    static let ownServerDomain = "tabmail.ai"

    static let shared = OwnServerRedirectPolicy()

    private let isOwnServer: @Sendable (URL) -> Bool

    /// `isOwnServer` decides from a request's first address; a test names its loopback server.
    init(isOwnServer: @escaping @Sendable (URL) -> Bool = { OwnServerRedirectPolicy.isTabMailServer($0) }) {
        self.isOwnServer = isOwnServer
    }

    /// Whether `url` addresses one of TabMail's own servers: its host is a subdomain of `ownServerDomain`.
    static func isTabMailServer(_ url: URL) -> Bool {
        guard let host = url.host()?.lowercased() else { return false }
        return host.hasSuffix("." + ownServerDomain)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        guard let first = task.originalRequest?.url, isOwnServer(first) else {
            completionHandler(request)
            return
        }
        completionHandler(nil)
    }
}
