/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// Base64-URL encode a UTF-8 string. Gmail's required encoding for
/// `MessagePartBody.data` (URL-safe alphabet, no padding) per the REST API:
/// https://developers.google.com/workspace/gmail/api/reference/rest/v1/users.messages.attachments
///
/// Used by test fixtures that build synthetic Gmail message JSON at test time.
func base64URL(_ s: String) -> String {
    Data(s.utf8).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}
