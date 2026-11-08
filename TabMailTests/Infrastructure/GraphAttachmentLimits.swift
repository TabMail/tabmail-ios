/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

/// Microsoft Graph's two edges for adding a file to an Outlook message, stated
/// here from the documentation and a live check, never from `ExchangeDraftConfig`,
/// so a fake that refuses at these edges cannot agree with the app by
/// construction (#433).
///
/// - message-post-attachments: "This operation limits the size of the attachment
///   you can add to under 3 MB."
/// - outlook-large-attachments: "If the file size is between 3 MB and 150 MB,
///   create an upload session", and `ErrorAttachmentSizeShouldNotBeLessThanMinimumSize`
///   "is returned when attempting to create an upload session to attach a file
///   smaller than 3 MB".
///
/// Neither page gives the byte count. On a test Outlook.com mailbox on 2026-11-08,
/// a single POST of exactly 3,100,000 bytes and a `createUploadSession` for
/// 3,100,000 bytes were both accepted (HTTP 201). So the two edges are read
/// differently, and a file of 3,000,000 to 3,145,727 bytes is accepted on both:
/// - the single POST refuses from the binary reading, 3,145,728 bytes (these
///   attachment limits are quoted in binary megabytes, 150 MB as 157,286,400
///   bytes). Not measured above 3,100,000; it is reported to accept larger files,
///   so this refusal is stricter than Graph may be and can only cause a false red;
/// - the session refuses below the decimal reading, 3,000,000 bytes, the only
///   reading that both the documented error and the measured 3,100,000 allow.
///   Not measured below 3,000,000.
/// A fake refusing at both edges fails any app threshold that routes a size to
/// the route refusing it.
enum GraphAttachmentLimits {
    /// A single POST refuses a file of this many bytes or more.
    static let singlePostMaxExclusive = 3 * 1_048_576
    /// `createUploadSession` refuses a file smaller than this.
    static let uploadSessionMinimum = 3_000_000
    /// Sizes on both sides of either reading of "3 MB" (3,000,000 and 3,145,728 bytes).
    static let edgeSizes = [2_999_999, 3_000_000, 3_100_000, 3_145_727, 3_145_728, 3_145_729]
}
