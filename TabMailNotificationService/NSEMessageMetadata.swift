/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// Canonical metadata payload the NSE produces for a pushed message.
///
/// **Parity contract with main-app sync.** The NSE fetches the same fields
/// main-app IMAP/Gmail/Graph sync fetches; those fields MUST propagate all
/// the way to the staging DB so `NSEDataBridge.mergeNSEStagingData` can
/// insert a `MessageHeader` that is byte-identical to what sync would
/// produce for the same message. Dropping fields on the floor and letting
/// sync "fix it later" violates `CLAUDE.md` Data Integrity Rule #1 (no
/// placeholder/sentinel values) and creates a window — from NSE push
/// delivery to the next sync tick — where the inbox row is missing
/// recipients, read state, and thread linkage. On providers where the
/// merge-side lookup misses the NSE-inserted row (historic IMAP bug,
/// 2026-04-19) that window becomes permanent.
///
/// Recipient-string format MUST match what the corresponding main-app sync
/// path writes to GRDB (`SyncEngineFullSync.swift:530` branch):
///   • Gmail   → raw RFC 2822 header value (`"Name" <a@b>, "N" <c@d>`).
///   • Outlook → email-only comma list (`a@b, c@d`) — `GraphAPI` only exposes
///     parsed addresses, not raw headers.
///   • IMAP    → SwiftMail `info.to` joined with `", "` (already raw per
///     RFC 5322 ENVELOPE).
struct NSEMessageMetadata: Sendable {
    let messageId: String
    let threadId: String?
    let rfc822MessageId: String?
    let senderName: String
    let senderEmail: String

    // Recipients (raw strings — see type-level doc for per-provider format).
    let to: String
    let cc: String
    let bcc: String
    let replyTo: String?

    // Threading — lets the merge populate `MessageReference` and the
    // subject-based thread-ID fallback in `ThreadUtils` without waiting
    // for sync.
    let inReplyTo: String?
    let references: [String]

    let subject: String
    let snippet: String
    let dateString: String
    let date: Date?

    // Server-side flags — NSE fetches these; storing false until sync runs
    // is a sentinel that misrepresents server state.
    let isRead: Bool
    let isFlagged: Bool
    let hasAttachments: Bool

    // Replied / forwarded state — IMAP populates from the `\Answered` standard
    // flag and the `$Forwarded` keyword (matches
    // `IMAPProvider.buildMessageHeaderInfo`). Gmail/Graph REST surfaces
    // don't expose these per-message, so those clients always stage false
    // (same as main-app sync's behavior — see GmailProvider /
    // ExchangeProvider's `isReplied: false, isForwarded: false`).
    let isReplied: Bool
    let isForwarded: Bool

    // Provider-native label identifiers, UNFILTERED:
    //   • Gmail   → `labelIds` from the message resource (INBOX, UNREAD,
    //     STARRED, Label_123, etc. — system + user labels mixed).
    //   • Outlook → `categories` (string names, e.g. "tm_reply").
    //   • IMAP    → custom IMAP keywords (non-system-flag `\Tags`).
    // The merge filters per-provider (`NSEDataBridge.filterUserLabels`) to
    // derive `MessageUserLabel` junction rows. Staging the raw list lets us
    // avoid encoding provider-specific filter logic in the NSE target.
    let providerLabels: [String]

    /// Provider-canonical folder path (the same value the main-app sync
    /// layer will store in `MessageHeader.folderPath` for this message).
    /// Gmail: `"INBOX"`. Outlook/Graph: `parentFolderId`. IMAP: `"INBOX"`.
    /// NSE writes this into `nse_processed_message.folderId` so the
    /// merge-side `MessageHeader.id` matches what sync later constructs —
    /// without it, sync produces a duplicate row that lacks NSE's AI fields.
    let folderPath: String
}
