/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// How a URL appears in a log line (`BackgroundSyncLogger`, `print`): a short, fixed form that names where a
/// request went and leaves out the parts that belong to one reader. A URL's user info, query and fragment
/// can hold per-user data (a sign-in code, a session parameter), so no form here prints them; it only
/// marks that a query or fragment was there. Percent-encoded, so a line never holds a raw newline.
enum LoggableURL {

    /// Scheme, host, port and path: for the app's own server addresses (an API endpoint, a calendar server),
    /// where the path says which call it was.
    static func address(_ url: URL?) -> String {
        guard let url else { return "(none)" }
        return origin(of: url) + url.path(percentEncoded: true) + marks(of: url)
    }

    /// `address` of a URL held as text.
    static func address(_ text: String) -> String {
        guard let url = URL(string: text) else { return unparsable(text) }
        return address(url)
    }

    /// Scheme, host and port only: for a link someone else chose (one in a message, a page or a chat
    /// answer), whose path can be as particular to its reader as its query. Marks a dropped path with `…`
    /// (`/…` after a host; a link with no host, such as `mailto:`, keeps only its scheme).
    static func origin(_ url: URL?) -> String {
        guard let url else { return "(none)" }
        let path = url.path(percentEncoded: true)
        let dropped = path.isEmpty || path == "/" ? "" : (url.host(percentEncoded: true) == nil ? "…" : "/…")
        return origin(of: url) + dropped + marks(of: url)
    }

    /// `origin` of a URL held as text.
    static func origin(_ text: String) -> String {
        guard let url = URL(string: text) else { return unparsable(text) }
        return origin(url)
    }

    private static func origin(of url: URL) -> String {
        let scheme = url.scheme?.lowercased() ?? ""
        guard let host = url.host(percentEncoded: true) else { return scheme.isEmpty ? "" : scheme + ":" }
        let port = url.port.map { ":\($0)" } ?? ""
        return (scheme.isEmpty ? "" : scheme + "://") + host + port
    }

    private static func marks(of url: URL) -> String {
        (url.query(percentEncoded: true) == nil ? "" : "?…") + (url.fragment(percentEncoded: true) == nil ? "" : "#…")
    }

    private static func unparsable(_ text: String) -> String {
        "(not a URL, \(text.utf8.count) bytes)"
    }
}
