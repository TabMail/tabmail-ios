/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// Values written into a query string or an `application/x-www-form-urlencoded`
/// body so that the server reads back exactly what was sent. Only RFC 3986
/// unreserved characters stay bare: `.urlQueryAllowed` leaves `&` and `=`,
/// which split a field, and `+`, which a form reader turns into a space.
///
/// The one definition of that set for the app and the notification service
/// extension: Graph ids and search text, Gmail search, the Gmail drafts.list
/// and history.list page tokens, Google Calendar search and the OAuth token form
/// bodies encode through it. Gmail messages.list page tokens and label ids are
/// still interpolated as they come.
enum StrictPercentEncoding {
    static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    /// `value` as one query or form component, or nil if it cannot be encoded.
    static func component(_ value: String) -> String? {
        value.addingPercentEncoding(withAllowedCharacters: unreserved)
    }

    /// A form body holding each field once, in the given order, or nil if a
    /// name or value cannot be encoded.
    static func formBody(_ fields: [(name: String, value: String)]) -> Data? {
        var pairs: [String] = []
        for field in fields {
            guard let name = component(field.name), let value = component(field.value) else { return nil }
            pairs.append("\(name)=\(value)")
        }
        return Data(pairs.joined(separator: "&").utf8)
    }
}
