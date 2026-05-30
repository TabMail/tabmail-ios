/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// Provider-agnostic attachment reference. Maps 1:1 to main app's `AttachmentInfo`.
struct AttachmentRef: Sendable, Codable {
    let filename: String
    let contentType: String
    /// Provider-specific locator: IMAP MIME section number / Gmail attachment ID / Graph attachment ID.
    let section: String
    let size: Int
    /// Content-Transfer-Encoding for IMAP decoding (e.g. "base64", "quoted-printable"). Nil for REST.
    let encoding: String?
}

/// Inline image data resolved from CID references. Only produced when an attachment
/// fetcher is supplied to `BodyRenderer.render` (main app supplies; NSE does not).
struct InlineImageRef: Sendable {
    let contentId: String   // e.g. "image001.png@01D12345" (no angle brackets)
    let contentType: String // e.g. "image/png"
    let data: Data
}
