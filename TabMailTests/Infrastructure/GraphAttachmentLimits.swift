/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

/// Microsoft Graph's two edges for adding a file to an Outlook message, stated
/// here from the documentation and never from `ExchangeDraftConfig`, so a fake
/// that refuses at these edges cannot agree with the app by construction (#433).
///
/// - message-post-attachments: "This operation limits the size of the attachment
///   you can add to under 3 MB."
/// - outlook-large-attachments: "If the file size is between 3 MB and 150 MB,
///   create an upload session", and `ErrorAttachmentSizeShouldNotBeLessThanMinimumSize`
///   "is returned when attempting to create an upload session to attach a file
///   smaller than 3 MB".
///
/// Neither page gives the byte count. Both edges are read as the same binary
/// megabyte: the session's minimum is the hard edge (a documented error code),
/// and these attachment limits are quoted in binary megabytes (150 MB as
/// 157,286,400 bytes). A fake refusing at both edges fails any app threshold
/// that routes a size to the route refusing it.
enum GraphAttachmentLimits {
    /// A single POST refuses a file of this many bytes or more.
    static let singlePostMaxExclusive = 3 * 1_048_576
    /// `createUploadSession` refuses a file smaller than this.
    static let uploadSessionMinimum = 3 * 1_048_576
    /// Sizes on both sides of either reading of "3 MB" (3,000,000 and 3,145,728 bytes).
    static let edgeSizes = [2_999_999, 3_000_000, 3_100_000, 3_145_727, 3_145_728, 3_145_729]
}
