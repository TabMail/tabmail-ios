/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// A `Sendable` display+action projection of an NSE-staged message, carried in the
/// `.messagesStaged` notification so the inbox can render just-pushed mail
/// **in-memory** — without waiting for the merge's (resume-time-slow) durable
/// header write. See `PLAN_INBOX_INSTANT_INSERT.md` / ADR-IOS-049. No body: the
/// list only needs header fields; body render keeps lagging to the merge.
struct StagedInboxRow: Sendable, Equatable {
    let accountId: String
    let folderPath: String
    let messageId: String
    let rfc822MessageId: String?
    let threadId: String?
    let inReplyTo: String?
    let references: [String]
    let subject: String
    let senderName: String
    let senderAddress: String
    let to: String
    let snippet: String
    let date: Date
    let isRead: Bool
    let isFlagged: Bool
    let hasAttachments: Bool
    let isReplied: Bool
    let isForwarded: Bool
    let actionTag: String?
    let summaryBlurb: String?
    /// The UIDVALIDITY the NSE's OWN live SELECT observed when it staged this
    /// row — the epoch under which `messageId` (a mailbox-local UID on IMAP) is
    /// a meaningful address. `nil` for Gmail/Graph (stable ids, no epoch), for
    /// rows staged before `nse_processed_message.observedUidValidity` existed,
    /// and for anything the projection could not prove.
    ///
    /// **A PROVEN VALUE OR NIL — never the `0` sentinel.** RFC 3501 §2.3.1.1
    /// types UIDVALIDITY as `nz-number`, so `0` can only mean "not reported";
    /// `NSEDataBridge.StagedMessage.toInboxRow()` normalizes through
    /// `SyncEngine.knownUidValidity` so a `0` arrives here as `nil` rather than
    /// as a false trust claim. Carried onto `MessageHeader.observedUidValidity`
    /// by `toMessageHeader()` so a gesture on a just-pushed row is adjudicated
    /// by `AccountManager.admittedOrdinaryActionTargets` on the evidence the
    /// NSE actually had — admitted when it equals the folder's live epoch,
    /// refused (terminally) when it positively disagrees.
    ///
    /// `var` with a default rather than `let`: a `let` with a default is
    /// EXCLUDED from the synthesized memberwise initializer entirely, whereas a
    /// `var` with one participates with that default — so every pre-existing
    /// `StagedInboxRow(...)` construction site compiles unchanged. Same
    /// rationale as `NSEDataBridge.StagedMessage.observedUidValidity`.
    var observedUidValidity: Int? = nil

    /// Matches the eventual GRDB `MessageHeader.id` for this message.
    var headerId: String {
        MessageIdentity.headerId(accountId: accountId, folderPath: folderPath, messageId: messageId)
    }

    var folderId: String {
        MessageIdentity.folderId(accountId: accountId, folderPath: folderPath)
    }

    /// A GRDB-shaped `MessageHeader` for a staged row not yet written to GRDB, so
    /// the inbox can render it and actions (`lookupMessage`) can resolve it.
    /// Flagged `headerComplete` + `isInInbox` — it IS inbox-visible pending mail.
    func toMessageHeader() -> MessageHeader {
        var h = MessageHeader(
            messageId: messageId,
            subject: subject,
            from: senderName,
            fromAddress: senderAddress,
            to: to,
            date: date,
            snippet: snippet,
            folderId: folderId,
            accountId: accountId,
            folderPath: folderPath,
            isInInbox: true
        )
        h.rfc822MessageId = rfc822MessageId
        h.threadId = threadId
        h.inReplyTo = inReplyTo
        h.referencesJSON = MessageHeader.encodeReferences(references)
        h.isRead = isRead
        h.isFlagged = isFlagged
        h.hasAttachments = hasAttachments
        h.isReplied = isReplied
        h.isForwarded = isForwarded
        h.actionTag = actionTag.flatMap { ActionTag(rawValue: $0) }
        h.tagSortOrder = h.actionTag?.sortOrder ?? 99
        h.summaryBlurb = summaryBlurb
        // The epoch is TRUST (ADR-IOS-061: UID = address, RFC = identity, epoch
        // = trust). Dropping it here made a positively-proven address enter the
        // action path as "unknown", so the gesture the user was just shown was
        // refused by the very guard the epoch exists to satisfy. Carrying it is
        // fail-SAFE: `admittedOrdinaryActionTargets` admits only on EQUALITY
        // with the folder's live epoch, so a moved epoch can only ever cause a
        // refusal, never a wrong admission (`IOS-NSE-001`).
        h.observedUidValidity = observedUidValidity
        h.headerComplete = true
        return h
    }
}
