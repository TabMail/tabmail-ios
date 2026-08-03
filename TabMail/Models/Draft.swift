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

    /// PORT — v2final `Draft.lastTouchedSeq` (its v78; ours is v79). The monotonic
    /// eviction-recency key. Assigned `MAX(lastTouchedSeq) + 1` INSIDE the save
    /// transaction (`DraftStore.applySave`), so under GRDB's single serialized
    /// writer it is strictly increasing with no wall-clock ties and no clock
    /// rollback. `DraftStore.evictImpl` orders by this (DESC) instead of
    /// `updatedAt`, so a just-saved draft can never be mis-ranked beyond the
    /// keep-limit and evicted.
    ///
    /// It is EVICTION RECENCY, NEVER A CONFLICT VERSION — that is
    /// `pushAttemptVersion`, which the Stage A/B CAS compares. Nothing may CAS,
    /// fence, or admit on `lastTouchedSeq`.
    ///
    /// Contract: distinct and increasing among CURRENTLY-RETAINED rows, which is
    /// all eviction needs. It is NOT a global-across-time identity — a value freed
    /// by deleting the MAX row may be reused, which is harmless because eviction
    /// only ever compares survivors (`MAX+1` always exceeds every survivor).
    ///
    /// The declaration default `0` keeps every memberwise-init caller compiling;
    /// the value a caller's snapshot carries is IGNORED — `applySave` overrides it
    /// in-transaction (migration `v79` seeds pre-existing rows with a distinct rank).
    var lastTouchedSeq: Int = 0

    /// PORT — compose generation from v2final commit 3f2cc4c34.
    var instanceEpoch: String? = nil
    /// PORT — conflict version used by the v2final Stage A/B CAS. SEPARATE from
    /// `lastTouchedSeq` above (eviction recency, never a conflict version).
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

/// PORT — `v2final:TabMail/Models/Draft.swift`'s `enum DraftAttachmentLoadError`
/// (commit `d2f0c96a3`), verbatim.
///
/// Failure modes for `DraftAttachmentStorage.loadAttachments`. Outbox Reliability
/// Rule 5 applied to drafts: the loader FAILS CLOSED — a compose reopen or a
/// server-draft push must never silently proceed with a SUBSET of the attachments
/// the user attached. Any of these cases throws all-or-nothing rather than
/// dropping a file.
enum DraftAttachmentLoadError: Error {
    /// A draft referenced an attachments directory (non-nil `attachmentsDirName`)
    /// but the directory is missing or its contents could not be enumerated.
    /// A referenced-but-absent dir is NOT "no attachments" — fail closed.
    case directoryUnreadable(dirName: String, underlying: Error)
    /// A present attachment data file could not be read. Never drop it.
    case fileUnreadable(name: String, underlying: Error)
    /// A `.meta`-suffixed file has no corresponding data sibling, so it is
    /// AMBIGUOUS with a real attachment literally named `*.meta` (stored as
    /// `<idx>_*.meta`). The current index-prefix format cannot disambiguate this
    /// from a metadata sidecar, so fail closed rather than silently drop the
    /// real attachment. A disambiguating on-disk manifest is the tracked follow-up.
    case ambiguousMetaFilename(name: String)
}

/// Mirrors OutboxMessage's attachment storage pattern for drafts.
/// Attachments stored under `Application Support/TabMail/draft_attachments/{dirName}/`.
enum DraftAttachmentStorage {

    static var baseDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("draft_attachments", isDirectory: true)
    }

    /// `root` is a test seam: when nil (production) the global `baseDir` is used;
    /// tests inject a temporary directory so they can create/mutate real files.
    static func dirURL(for dirName: String, root: URL? = nil) -> URL {
        (root ?? baseDir).appendingPathComponent(dirName, isDirectory: true)
    }

    /// Save attachments to disk. Throws if any write fails.
    static func saveAttachments(_ attachments: [DraftAttachment], dirName: String, root: URL? = nil) throws {
        guard !attachments.isEmpty else { return }
        let dir = dirURL(for: dirName, root: root)
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

    /// PORT — `v2final`'s `DraftAttachmentStorage.loadAttachments(dirName:root:)`
    /// (commit `d2f0c96a3`), verbatim.
    ///
    /// Load attachments from disk, FAIL-CLOSED. Returns `[]` ONLY for a nil
    /// `dirName` (the sole clean attachment-less case). Otherwise it throws rather
    /// than return a partial set: a missing/unenumerable directory, an unreadable
    /// data file, or a `.meta`-ambiguous filename all THROW. A missing/unreadable
    /// metadata sidecar is NOT a data-loss case (the bytes are intact) — it keeps
    /// the existing MIME fallback.
    static func loadAttachments(dirName: String?, root: URL? = nil) throws -> [DraftAttachment] {
        // nil dirName is the ONLY clean attachment-less case.
        guard let dirName else { return [] }
        let dir = dirURL(for: dirName, root: root)
        // A referenced-but-absent directory (or an enumeration failure) is NOT
        // "no attachments" — fail closed instead of returning [].
        let files: [URL]
        do {
            files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        } catch {
            throw DraftAttachmentLoadError.directoryUnreadable(dirName: dirName, underlying: error)
        }

        // Classify. A ".meta" file is a metadata SIDECAR iff its base (name minus
        // ".meta") is a present file: `0_x.pdf.meta` is the sidecar of data
        // `0_x.pdf`, and `0_settings.meta.meta` is the sidecar of a real attachment
        // literally named `settings.meta` (stored as data `0_settings.meta`). A
        // ".meta" file whose base is ABSENT is itself a DATA file.
        let allNames = Set(files.map { $0.lastPathComponent })
        func isSidecar(_ name: String) -> Bool {
            name.hasSuffix(".meta") && allNames.contains(String(name.dropLast(".meta".count)))
        }
        let dataFiles = files.filter { !isSidecar($0.lastPathComponent) }
        // Fail closed on a DATA file whose name ends in ".meta" but whose OWN
        // sidecar ("<name>.meta") is absent: it is indistinguishable from a
        // lost-data orphan (the real data file gone, only its ".meta" sidecar
        // left), so throw rather than load metadata bytes as the attachment.
        for url in dataFiles where url.lastPathComponent.hasSuffix(".meta") {
            guard allNames.contains(url.lastPathComponent + ".meta") else {
                throw DraftAttachmentLoadError.ambiguousMetaFilename(name: url.lastPathComponent)
            }
        }

        let sorted = dataFiles.sorted { $0.lastPathComponent < $1.lastPathComponent }
        return try sorted.map { fileURL in
            let data: Data
            do {
                data = try Data(contentsOf: fileURL)
            } catch {
                // A present-but-unreadable data file must NEVER be dropped.
                throw DraftAttachmentLoadError.fileUnreadable(name: fileURL.lastPathComponent, underlying: error)
            }
            let fullName = fileURL.lastPathComponent
            // Strip index prefix: "0_filename.pdf" → "filename.pdf"
            let filename = fullName.contains("_") ? String(fullName.drop(while: { $0 != "_" }).dropFirst()) : fullName
            // Meta sidecar uses full indexed name (matching save). A missing/
            // unreadable sidecar is not data loss (bytes are intact) — keep the
            // MIME fallback rather than throwing.
            let metaURL = dir.appendingPathComponent("\(fullName).meta")
            let meta = (try? String(contentsOf: metaURL, encoding: .utf8))?.split(separator: "\n")
            let mimeType = meta?.first.map(String.init) ?? "application/octet-stream"
            let isAlternative = meta?.dropFirst().first == "true"
            return DraftAttachment(filename: filename, mimeType: mimeType, data: data, isAlternative: isAlternative)
        }
    }

    /// Delete attachments directory for a draft.
    static func deleteAttachments(dirName: String, root: URL? = nil) {
        let dir = dirURL(for: dirName, root: root)
        try? FileManager.default.removeItem(at: dir)
    }
}
