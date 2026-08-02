/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB

enum OutboxStatus: String, Codable, Sendable {
    case queued
    case sending
    case failed
}

struct OutboxMessage: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable {
    static let databaseTableName = "outboxMessage"

    var id: String
    var accountId: String
    var toJSON: String
    var ccJSON: String
    var bccJSON: String
    var subject: String
    var body: String
    var isHTML: Bool
    var inReplyTo: String?
    var referencesJSON: String?
    /// Gmail native conversation id (reply/forward). Persisted so a drain after
    /// app relaunch re-sends with the same thread binding. Gmail REST send only;
    /// nil for IMAP/Exchange and new compositions. See ADR-IOS-043. (v60)
    var threadId: String?
    /// Relative directory name under outbox_attachments/ (same as id)
    var attachmentsDirName: String?
    var status: String
    var errorMessage: String?
    var retryCount: Int
    var createdAt: Date
    /// MessageHeader.id of the original message — used to update isReplied/isForwarded after send
    var originalMessageHeaderId: String?
    /// Whether this is a forward (vs reply)
    var isForward: Bool
    /// Timestamp set immediately after provider.send() succeeds, BEFORE the DB delete.
    /// Allows reconcileOutbox to distinguish "crashed mid-send" from "crashed after
    /// send succeeded" — the latter is deleted (not re-queued) to prevent double-sends.
    var sentAt: Date?
    /// RFC822 Message-ID generated before send — used to dedup IMAP Sent append on retry.
    /// Set before SMTP send so both SMTP and IMAP APPEND use the same Message-ID.
    var sentMessageId: String?
    /// Whether the sent message has been appended to the server's Sent folder.
    /// For IMAP: explicitly appended via IMAP APPEND. For Gmail/Exchange: auto-saved by API.
    /// Outbox message is only deleted when BOTH sentAt != nil AND appendedToSent == true.
    var appendedToSent: Bool = false
    /// Server draft ID captured from local Draft table before deletion.
    /// Used to delete the server draft after send confirmation in drainOutbox.
    var serverDraftId: String?
    /// The DRAFT's own RFC 822 Message-ID, captured at queue-send time from
    /// `Draft.rfc822MessageId` and paired with `serverDraftId` from the same
    /// caller snapshot. (v71)
    ///
    /// ⚠️ NOT `sentMessageId`. Those are two different messages: `sentMessageId`
    /// belongs to the message SMTP delivered and IMAP appended to Sent, and the
    /// copy sitting in Drafts never carries it — keying the post-send cleanup by
    /// it searches Drafts and finds nothing.
    ///
    /// Exists because `IMAPProvider.saveDraft` returns a bare numeric UID as
    /// `serverDraftId`, and a UID is a mutable ADDRESS that `IMAPProvider
    /// .deleteDraft` refuses to build a destructive command from. This column is
    /// what lets the post-send backstops (`finalizeOutboxMessage`, and
    /// `reconcileOutbox` after a crash — neither of which has a live `Draft` row
    /// to read) hand `queueDraftDelete` an identity that can actually resolve.
    var draftRfc822MessageId: String?
    /// The UIDVALIDITY epoch `serverDraftId` was minted under, snapshotted at
    /// queue-send time from `Draft.serverDraftUidValidity` in the same caller
    /// snapshot as `serverDraftId` and `draftRfc822MessageId`. (v72)
    ///
    /// The rfc822 column above gives the backstops an IDENTITY; this one gives
    /// them the epoch that identity's ADDRESS belongs to, and they are not
    /// interchangeable. Two legitimately distinct drafts can share a Message-ID
    /// (a copy, another client's save), so with the identity alone a delete
    /// issued after its own target has gone — another client removed it, or the
    /// primary delete already did — finds exactly one remaining exact match, the
    /// SIBLING, and destroys it. That is a wrong-message delete. With the epoch
    /// the same delete resolves through `IMAPProvider.deleteDraft`'s STRONG arm:
    /// live UIDVALIDITY must equal this value, then the recorded UID is FETCHed
    /// and corroborated, and a target that is already gone is a clean no-op.
    ///
    /// nil for non-IMAP providers, for a draft that was never pushed, and for
    /// any row written before v72 — all of which keep that row on the unchanged
    /// Message-ID-search arm.
    ///
    /// Ported from `v2final:TabMail/Models/OutboxMessage.swift`'s
    /// `draftServerUidValidity` (its migration `v85`).
    var draftServerUidValidity: Int?
    /// Immutable compose generation that owns this send.
    var instanceEpoch: String?
    /// Gmail contained MESSAGE id, distinct from the draft RESOURCE id.
    var serverDraftGmailMessageId: String?
    /// Mailbox component of the strong IMAP cleanup address.
    var draftServerFolderPath: String?
    /// Wall-clock deadline before drain is allowed to claim this row. Set by
    /// queueSend to now + outboxUndoHoldSeconds + outboxClaimBufferSeconds.
    /// NULL for legacy pre-v49 rows (treated as "no hold" by the drain gate).
    var holdUntil: Date?
    /// Draft row id associated with this send. Used at atomic-claim time to
    /// fire DraftStore.delete — deferred from compose-time so Undo-Send can
    /// reopen compose with the draft contents intact.
    var draftId: String?

    // MARK: - Computed accessors

    var to: [String] {
        get { decodeStringArray(toJSON) }
        set { toJSON = encodeStringArray(newValue) }
    }

    var cc: [String] {
        get { decodeStringArray(ccJSON) }
        set { ccJSON = encodeStringArray(newValue) }
    }

    var bcc: [String] {
        get { decodeStringArray(bccJSON) }
        set { bccJSON = encodeStringArray(newValue) }
    }

    var references: [String] {
        get { decodeStringArray(referencesJSON ?? "[]") }
        set { referencesJSON = encodeStringArray(newValue) }
    }

    var outboxStatus: OutboxStatus {
        OutboxStatus(rawValue: status) ?? .queued
    }

    // MARK: - Init

    init(
        accountId: String,
        draft: DraftMessage,
        originalMessageHeaderId: String? = nil,
        isForward: Bool = false
    ) {
        self.id = UUID().uuidString
        self.accountId = accountId
        self.toJSON = encodeStringArray(draft.to)
        self.ccJSON = encodeStringArray(draft.cc)
        self.bccJSON = encodeStringArray(draft.bcc)
        self.subject = draft.subject
        self.body = draft.body
        self.isHTML = draft.isHTML
        self.inReplyTo = draft.inReplyTo
        self.referencesJSON = encodeStringArray(draft.references)
        self.threadId = draft.threadId
        self.attachmentsDirName = draft.attachments.isEmpty ? nil : self.id
        self.status = OutboxStatus.queued.rawValue
        self.errorMessage = nil
        self.retryCount = 0
        self.createdAt = Date()
        self.originalMessageHeaderId = originalMessageHeaderId
        self.isForward = isForward
        self.instanceEpoch = nil
        self.serverDraftGmailMessageId = nil
        self.draftServerFolderPath = nil
    }

    // MARK: - Attachment Disk Storage

    /// Base directory for all outbox attachments.
    static var attachmentsBaseDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TabMail", isDirectory: true)
            .appendingPathComponent("outbox_attachments", isDirectory: true)
    }

    /// Directory for this message's attachments.
    var attachmentsDir: URL? {
        guard let dirName = attachmentsDirName else { return nil }
        return Self.attachmentsBaseDir.appendingPathComponent(dirName, isDirectory: true)
    }

    /// Save attachments from a DraftMessage to disk.
    /// Returns the directory name (same as message id) or nil if no attachments.
    static func saveAttachments(_ attachments: [DraftAttachment], dirName: String) throws {
        guard !attachments.isEmpty else { return }
        let dir = attachmentsBaseDir.appendingPathComponent(dirName, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        for (index, attachment) in attachments.enumerated() {
            // Use index prefix to preserve ordering and avoid filename collisions
            let filename = "\(index)_\(attachment.filename)"
            let fileURL = dir.appendingPathComponent(filename)
            try attachment.data.write(to: fileURL)

            // Save metadata (mimeType + flags) as a sidecar
            let metaURL = dir.appendingPathComponent("\(filename).meta")
            var meta = attachment.mimeType
            if attachment.isAlternative { meta += "\nisAlternative" }
            try meta.write(to: metaURL, atomically: true, encoding: .utf8)
        }
    }

    /// Load attachments from disk back into DraftAttachment array.
    /// Throws if any attachment file cannot be read — sending an email with missing
    /// attachments is silent data corruption and must be prevented.
    func loadAttachments() throws -> [DraftAttachment] {
        guard let dir = attachmentsDir else { return [] }
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)

        // Find attachment files (not .meta sidecars), sorted by index prefix
        let attachmentFiles = files
            .filter { !$0.lastPathComponent.hasSuffix(".meta") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        return try attachmentFiles.map { fileURL in
            let data = try Data(contentsOf: fileURL)
            let metaURL = fileURL.appendingPathExtension("meta")
            let metaContent = (try? String(contentsOf: metaURL, encoding: .utf8)) ?? "application/octet-stream"
            let metaLines = metaContent.components(separatedBy: "\n")
            let mimeType = metaLines[0]
            let isAlternative = metaLines.contains("isAlternative")
            // Strip the index prefix to recover original filename
            let filename = fileURL.lastPathComponent
            let originalName = filename.contains("_") ? String(filename.drop(while: { $0 != "_" }).dropFirst()) : filename
            return DraftAttachment(filename: originalName, mimeType: mimeType, data: data, isAlternative: isAlternative)
        }
    }

    /// Delete attachment directory from disk.
    func deleteAttachments() {
        guard let dir = attachmentsDir else { return }
        try? FileManager.default.removeItem(at: dir)
    }

    /// Reconstruct a DraftMessage from this outbox entry.
    /// Throws if attachment files cannot be loaded — prevents sending with missing attachments.
    func toDraftMessage() throws -> DraftMessage {
        DraftMessage(
            to: to,
            cc: cc,
            bcc: bcc,
            subject: subject,
            body: body,
            isHTML: isHTML,
            inReplyTo: inReplyTo,
            references: references,
            attachments: try loadAttachments(),
            threadId: threadId
        )
    }
}

// MARK: - JSON Helpers

func encodeStringArray(_ array: [String]) -> String {
    (try? String(data: JSONEncoder().encode(array), encoding: .utf8)) ?? "[]"
}

func decodeStringArray(_ json: String) -> [String] {
    guard let data = json.data(using: .utf8) else { return [] }
    return (try? JSONDecoder().decode([String].self, from: data)) ?? []
}
