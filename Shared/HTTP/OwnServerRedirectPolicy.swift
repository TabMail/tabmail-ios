/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// TabMail's own servers (the backend, device sync, sign-in, push, billing, templates, forms) never
/// answer with a redirect, and most requests to them carry the user's TabMail sign-in token. A redirect
/// that one of them answers is never followed: the 3xx response is handed back to the caller as the
/// answer, so what the request carries goes to no other address. The decision is made per answer, by the
/// address that answered, wherever the request started; an answer with no address is not followed either.
///
/// Redirects answered by every other host keep URLSession's default handling: Gmail and Microsoft Graph,
/// a CalDAV server (iCloud sends its clients on to another host), and the pages the AI web tool reads.
///
/// `sharedEphemeralSession` holds it for all of its requests; the AI requests (`BackendClient`) and the
/// calls on `URLSession.shared` pass it with each request.
final class OwnServerRedirectPolicy: NSObject, URLSessionTaskDelegate, Sendable {

    /// The domain whose subdomains are TabMail's own servers. The bare domain is the public website,
    /// which the app only links to or reads without a token.
    static let ownServerDomain = "tabmail.ai"

    static let shared = OwnServerRedirectPolicy()

    private let isOwnServer: @Sendable (URL) -> Bool

    /// `isOwnServer` decides from the address that answered with the redirect; a test names its
    /// loopback server.
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
        guard let answeredBy = response.url, !isOwnServer(answeredBy) else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}
