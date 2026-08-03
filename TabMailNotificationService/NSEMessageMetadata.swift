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

    /// The UIDVALIDITY the NSE's OWN live SELECT observed for `folderPath` at
    /// fetch time — IMAP/iCloud only. `nil` for Gmail/Graph (no UIDVALIDITY
    /// concept) and for every row staged before this field existed.
    ///
    /// PORT of `v2final`'s `NSEMessageMetadata.observedUidValidity` (tag
    /// `e28dd4edb`, ADR-IOS-061 item A / R5 F-2).
    ///
    /// Captured directly from the wire (`Mailbox.Selection.uidValidity`), never
    /// from a cached or mirrored value: this is the ONLY signal that binds the
    /// UID-addressed `messageId` on this row to the numbering it was read
    /// under. `processedAt` cannot substitute — an NSE run that SELECTed
    /// pre-reset but whose merge lands after a reset stamped the folder carries
    /// a wall-clock timestamp that looks perfectly fresh, so wall-clock order
    /// can lose a race this comparison cannot.
    ///
    /// ⚑ NIL IS NOT A MISMATCH — IT IS AN UNANSWERED QUESTION. It means the
    /// address is unproven, exactly as `MessageHeader.observedUidValidity`
    /// documents for the durable side. No consumer may delete, skip, or
    /// re-attribute a row on the strength of a nil alone; only a POSITIVE
    /// disagreement with the folder's current epoch is evidence.
    ///
    /// `0` never enters this field. RFC 3501 §2.3.1.1 types UIDVALIDITY as
    /// `nz-number`; SwiftMail's `Mailbox.Selection.uidValidity` is non-optional
    /// only because it DEFAULTS to `UIDValidity(0)`, so a `0` can only mean
    /// "the server did not report one" — recorded as unknown, the same
    /// convention `IMAPProvider.selectMailboxTracked` enforces main-app side.
    ///
    /// `Int?` (not `UInt32?`) mirrors `MessageHeader.observedUidValidity` and
    /// `PendingOperation.observedUidValidity`, this value's established storage
    /// convention. `var` with a default — unlike every other field here —
    /// because a `let` with a default is excluded from the synthesized
    /// memberwise initializer entirely, whereas a `var` participates in it with
    /// that default, letting the two non-IMAP construction sites
    /// (`GmailNSEClient`, `OutlookNSEClient`) compile unchanged.
    var observedUidValidity: Int? = nil
}
