/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB

/// Persistent draft for compose sessions. Stores draft state (recipients, subject, body)
/// and inline edit history so compose chat can resume on reopen.
///
/// Draft keys:
/// - Reply: `"reply:{replyTo.id}"`
/// - Forward: `"forward:{replyTo.id}"`
/// - New compose: `"new:{uuid}"`
struct Draft: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "draft"

    let id: String              // draftKey
    let accountId: String
    var toJSON: String          // JSON array of recipient emails
    var ccJSON: String
    var bccJSON: String
    var subject: String
    var body: String
    let replyToId: String?      // original message header ID for reply/forward
    let isForward: Bool
    var editHistoryJSON: String? // JSON array of InlineEditTurn
    let createdAt: Double       // epoch seconds
    var updatedAt: Double       // epoch seconds

    // v24: Server draft sync
    var serverDraftId: String?    // Gmail draft ID / Exchange message ID / IMAP UID
    var serverPushStatus: String? // nil (not pushed), "pushed", "dirty"
    var rfc822MessageId: String?  // Stable Message-ID for IMAP dedup
    var attachmentsDirName: String? // Disk directory under draft_attachments/

    /// PORT — compose generation from v2final commit 3f2cc4c34.
    var instanceEpoch: String? = nil
    /// PORT — conflict version used by the v2final Stage A/B CAS.
    var pushAttemptVersion: Int = 0
    /// Mailbox component of the strong IMAP draft address.
    var serverDraftFolderPath: String? = nil

    /// v72: the IMAP UIDVALIDITY epoch `serverDraftId` was MINTED under — the
    /// value the SELECT that carried the draft's APPEND reported, returned by the
    /// provider as `DraftCreatedAddress.imap` and written here in the same
    /// statement as `serverDraftId`.
    ///
    /// A bare UID is an ADDRESS scoped to exactly one `(mailbox, UIDVALIDITY)`
    /// pair. Without the epoch it was minted under, nothing downstream can tell a
    /// still-valid address from one the server has since re-pointed at a different
    /// message, so a bare UID with a nil or stale epoch must never activate a
    /// destructive match. Carrying the epoch is what lets
    /// `IMAPProvider.deleteDraft` take its STRONG arm — verify the live epoch
    /// EQUALS this one, then FETCH and corroborate — instead of degrading to a
    /// Message-ID search that cannot distinguish this draft from a legitimate
    /// same-Message-ID sibling.
    ///
    /// nil for a never-pushed draft, for every non-IMAP provider (Gmail/Graph
    /// resource ids are stable and epoch-free), and for any row written before
    /// v72. nil means UNKNOWN — never "unchanged", never zero.
    ///
    /// Ported from `v2final:TabMail/Models/Draft.swift`'s `serverDraftUidValidity`.
    var serverDraftUidValidity: Int?

    // MARK: - JSON Helpers

    var toArray: [String] {
        (try? JSONDecoder().decode([String].self, from: Data(toJSON.utf8))) ?? []
    }

    var ccArray: [String] {
        (try? JSONDecoder().decode([String].self, from: Data(ccJSON.utf8))) ?? []
    }

    var bccArray: [String] {
        (try? JSONDecoder().decode([String].self, from: Data(bccJSON.utf8))) ?? []
    }

    static func encodeStringArray(_ arr: [String]) -> String {
        (try? String(data: JSONEncoder().encode(arr), encoding: .utf8)) ?? "[]"
    }

    // MARK: - Edit History JSON

    /// Codable wrapper for InlineEditTurn (which isn't Codable itself).
    private struct EditTurnCodable: Codable {
        let userRequest: String
        let bodyAtRequest: String
        let subjectAtRequest: String
        let assistantResponse: String
    }

    var editHistory: [InlineEditTurn] {
        guard let json = editHistoryJSON, let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([EditTurnCodable].self, from: data) else { return [] }
        return decoded.map {
            InlineEditTurn(userRequest: $0.userRequest, bodyAtRequest: $0.bodyAtRequest,
                           subjectAtRequest: $0.subjectAtRequest, assistantResponse: $0.assistantResponse)
        }
    }

    static func encodeEditHistory(_ turns: [InlineEditTurn]) -> String? {
        let codable = turns.map {
            EditTurnCodable(userRequest: $0.userRequest, bodyAtRequest: $0.bodyAtRequest,
                            subjectAtRequest: $0.subjectAtRequest, assistantResponse: $0.assistantResponse)
        }
        guard let data = try? JSONEncoder().encode(codable) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - Draft Key Helpers

    /// Build a draft key for reply/forward/new compose.
    static func draftKey(replyTo: String?, isForward: Bool, newId: String?) -> String {
        if let replyId = replyTo {
            return isForward ? "forward:\(replyId)" : "reply:\(replyId)"
        }
        return "new:\(newId ?? UUID().uuidString)"
    }

    /// Resolve the reply-to MessageHeader from a draft key + replyToId.
    /// Tries PK lookup first, then parses stableId from the draftKey ("reply:{accountId}:{stableId}")
    /// and looks up by rfc822MessageId. Handles stale PKs after IMAP moves.
    static func resolveReplyToHeader(draftKey: String, replyToId: String?, isForward: Bool) -> MessageHeader? {
        // Strategy 1: direct PK lookup
        if let replyId = replyToId,
           let header = try? AppDatabase.dbPool.read({ db in try MessageHeader.fetchOne(db, key: replyId) }) {
            return header
        }
        // Strategy 2: parse stableId from draftKey
        let prefix = isForward ? "forward:" : "reply:"
        guard draftKey.hasPrefix(prefix) else { return nil }
        let rest = String(draftKey.dropFirst(prefix.count))
        guard let colonIdx = rest.firstIndex(of: ":") else { return nil }
        let accountId = String(rest[rest.startIndex..<colonIdx])
        let stableId = String(rest[rest.index(after: colonIdx)...])
        let normalized = EmailFilter.normalizeMessageId(stableId)
        return try? AppDatabase.dbPool.read { db in
            try MessageHeader
                .filter(Column("accountId") == accountId && Column("rfc822MessageId") == normalized)
                .fetchOne(db)
        }
    }

    /// Whether this draft key represents a reply or forward (vs new compose).
    var isReplyOrForward: Bool { replyToId != nil }

    /// Parse a raw "To" header string into individual email addresses.
    /// Handles: "alice@co.com, bob@co.com" and "Alice <alice@co.com>, Bob <bob@co.com>".
    /// Extracts the bare email address from angle-bracket format.
    static func parseRecipients(_ raw: String) -> [String] {
        guard !raw.isEmpty else { return [] }
        // Split on commas that are NOT inside angle brackets or quotes
        var result: [String] = []
        var current = ""
        var inAngleBracket = false
        var inQuote = false
        for char in raw {
            if char == "\"" && !inAngleBracket { inQuote.toggle() }
            if char == "<" && !inQuote { inAngleBracket = true }
            if char == ">" && !inQuote { inAngleBracket = false }
            if char == "," && !inAngleBracket && !inQuote {
                let trimmed = current.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { result.append(extractEmail(from: trimmed)) }
                current = ""
            } else {
                current.append(char)
            }
        }
        let trimmed = current.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { result.append(extractEmail(from: trimmed)) }
        return result
    }

    /// Extract bare email from "Name <email>" format. Returns as-is if no angle brackets.
    private static func extractEmail(from token: String) -> String {
        if let start = token.firstIndex(of: "<"), let end = token.firstIndex(of: ">"), start < end {
            return String(token[token.index(after: start)..<end])
        }
        return token
    }
}

// MARK: - Draft Attachment Disk Storage

/// Mirrors OutboxMessage's attachment storage pattern for drafts.
/// Attachments stored under `Application Support/TabMail/draft_attachments/{dirName}/`.
enum DraftAttachmentStorage {

    static var baseDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("draft_attachments", isDirectory: true)
    }

    static func dirURL(for dirName: String) -> URL {
        baseDir.appendingPathComponent(dirName, isDirectory: true)
    }

    /// Save attachments to disk. Throws if any write fails.
    static func saveAttachments(_ attachments: [DraftAttachment], dirName: String) throws {
        guard !attachments.isEmpty else { return }
        let dir = dirURL(for: dirName)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (index, att) in attachments.enumerated() {
            let dataName = "\(index)_\(att.filename)"
            try att.data.write(to: dir.appendingPathComponent(dataName))
            // Write metadata sidecar — uses indexed name to avoid collision when
            // multiple attachments share the same filename (e.g., two "document.pdf").
            let meta = "\(att.mimeType)\n\(att.isAlternative)"
            try meta.write(to: dir.appendingPathComponent("\(dataName).meta"), atomically: true, encoding: .utf8)
        }
    }

    /// Load attachments from disk. Returns empty array if dir doesn't exist.
    static func loadAttachments(dirName: String) -> [DraftAttachment] {
        let dir = dirURL(for: dirName)
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return [] }
        let dataFiles = files.filter { !$0.lastPathComponent.hasSuffix(".meta") }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        return dataFiles.compactMap { fileURL in
            guard let data = try? Data(contentsOf: fileURL) else { return nil }
            let fullName = fileURL.lastPathComponent
            // Strip index prefix: "0_filename.pdf" → "filename.pdf"
            let filename = fullName.contains("_") ? String(fullName.drop(while: { $0 != "_" }).dropFirst()) : fullName
            // Meta sidecar uses full indexed name (matching save)
            let metaURL = dir.appendingPathComponent("\(fullName).meta")
            let meta = (try? String(contentsOf: metaURL, encoding: .utf8))?.split(separator: "\n")
            let mimeType = meta?.first.map(String.init) ?? "application/octet-stream"
            let isAlternative = meta?.dropFirst().first == "true"
            return DraftAttachment(filename: filename, mimeType: mimeType, data: data, isAlternative: isAlternative)
        }
    }

    /// Delete attachments directory for a draft.
    static func deleteAttachments(dirName: String) {
        let dir = dirURL(for: dirName)
        try? FileManager.default.removeItem(at: dir)
    }
}
