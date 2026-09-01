/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB

enum BodyIndexingFailureReason: String, Sendable {
    case partialFetchUnsupported = "partial_fetch_unsupported"
}

/// TabMail action tags. Raw values are plain action names ("delete", "archive", etc.).
/// Action tags are local-only (ADR-IOS-036) — `MessageHeader.actionTag`,
/// `MessageAICache.actionTag`, and Device Sync probe state. We no longer
/// write `tm_*` IMAP keywords / Gmail labels / Graph categories.
///
/// `imapKeyword` / `fromIMAPKeyword` are retained as **legacy helpers** for
/// test fixtures and any one-off migration reads; production code does not
/// call them.
enum ActionTag: String, Codable, CaseIterable, Sendable {
    case reply   = "reply"
    case none    = "none"
    case archive = "archive"
    case delete  = "delete"

    /// Decode with backward-compat: DB may have persisted old "tm_" prefixed values.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        let plain = raw.hasPrefix("tm_") ? String(raw.dropFirst(3)) : raw
        guard let tag = ActionTag(rawValue: plain) else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Cannot initialize ActionTag from invalid String value \(raw)"
            ))
        }
        self = tag
    }

    /// Legacy: the IMAP keyword / Gmail label name historically used for
    /// cross-instance tag sync. Retained so tests + migration reads compile.
    var imapKeyword: String { "tm_\(rawValue)" }

    /// Legacy: parse an ActionTag out of an IMAP keyword / Gmail label name.
    /// Retained so tests + migration reads compile.
    static func fromIMAPKeyword(_ keyword: String) -> ActionTag? {
        let plain = keyword.hasPrefix("tm_") ? String(keyword.dropFirst(3)) : keyword
        return ActionTag(rawValue: plain)
    }

    /// Triage sort priority (lower = higher priority, matches TB addon)
    var sortOrder: Int {
        switch self {
        case .reply:   return 0
        case .none:    return 1
        case .archive: return 2
        case .delete:  return 3
        }
    }

    var displayName: String {
        switch self {
        case .reply:   return "Reply"
        case .none:    return "None"
        case .archive: return "Archive"
        case .delete:  return "Delete"
        }
    }

    /// Determines the action to take when a tag is tapped in the message detail view.
    /// `isMainMessage` is true when the tapped message is the detail view's primary message
    /// (vs. a thread bubble message).
    enum TagActionResult: Equatable {
        case reply
        case archiveAndDismiss
        case archiveInPlace
        case deleteAndDismiss
        case deleteInPlace
        case noop
    }

    func resolveAction(isMainMessage: Bool) -> TagActionResult {
        switch self {
        case .reply:
            return .reply
        case .archive:
            return isMainMessage ? .archiveAndDismiss : .archiveInPlace
        case .delete:
            return isMainMessage ? .deleteAndDismiss : .deleteInPlace
        case .none:
            return .noop
        }
    }

    /// Single letter for compact tag indicator (nil = no letter, just colored box)
    var letter: String? {
        switch self {
        case .reply:   return "R"
        case .archive: return "A"
        case .delete:  return "D"
        case .none:    return nil
        }
    }
}

struct MessageHeader: Codable, Equatable, FetchableRecord, PersistableRecord, Identifiable, Sendable {
    static let databaseTableName = "messageHeader"

    var id: String
    var folderId: String
    var accountId: String
    var folderPath: String
    // Read by InboxNotificationObserver — schema changes here require lockstep
    // updates to seed() and the post-commit SELECT.
    var isInInbox: Bool
    var messageId: String
    /// UIDVALIDITY observed by the exact IMAP SELECT/FETCH that supplied this
    /// row's current mailbox-local UID. Nil means the address is unproven (or
    /// the provider has stable ids). Never synthesize this from Folder state.
    ///
    /// ⚑ NO REFERENCE — INVENTED. `v2final` has no persisted header/snapshot
    /// observation epoch; commit 486bafd4b explicitly deferred this transport.
    var observedUidValidity: Int? = nil
    var rfc822MessageId: String? // RFC 2822 Message-ID header (device-independent, for cross-device AI cache probe)
    var inReplyTo: String? // RFC 2822 In-Reply-To header (parent message ID for thread chain walking)
    var referencesJSON: String? // RFC 2822 References header as JSON array of normalized message IDs
    var threadId: String?
    var computedThreadId: String = ""
    var subject: String
    var from: String
    var fromAddress: String
    var to: String
    var cc: String = ""
    var bcc: String = ""
    var replyTo: String?
    var date: Date
    var snippet: String
    var isRead: Bool
    var isFlagged: Bool
    var hasAttachments: Bool
    var isReplied: Bool = false
    var isForwarded: Bool = false
    var actionTag: ActionTag?
    var tagSortOrder: Int = 99  // Mirrors actionTag?.sortOrder ?? 99 for triage sorting

    /// When `actionTag` was last assigned a non-nil value. Nil whenever
    /// `actionTag` is nil. Drives `sweepStaleActionTags`'s TTL reclaim
    /// (`SyncConfig.actionTagTTLSeconds`, migration v81) — the sweep only
    /// enumerates non-inbox folders, so an inbox tag is never swept
    /// regardless of age; only an out-of-inbox tag older than the TTL is
    /// reclaimed. A NULL stamp on a non-nil tag (pre-migration legacy row,
    /// or a writer that failed to stamp) is treated as immediately
    /// eligible — fail-safe toward MORE reclaiming, never less.
    var actionTagSetAt: Date? = nil

    // AI-generated summary fields
    var summaryBlurb: String?
    var summaryTodos: String?
    var reminderDate: String?
    var reminderTime: String?
    var reminderContent: String?

    // AI-generated reply cache (matches TB's reply: IDB prefix)
    var cachedReply: String?

    /// Whether this header's FTS indexing is complete (GRDB + FTS two-phase write).
    /// Set after indexHeadersForFTS succeeds. Body queue requires headerComplete=1
    /// before fetching body — prevents the race where body fetch runs before FTS
    /// indexing, causing permanent AI processing failure.
    /// New inserts default to false. Migration v38 sets true for existing rows.
    var headerComplete: Bool = false

    /// Whether this message's body text has been indexed in FTS.
    /// Set by applySnippetUpdates after FTS write. Used by AI/body queue
    /// repopulate to avoid expensive per-message FTS probes.
    var bodyComplete: Bool = false

    /// Server confirmed this message has no body content (fetched twice, both empty).
    /// Once true, the message is permanently excluded from body fetch queues.
    /// Reset by Smart Reindex to give previously-empty messages a fresh chance.
    var bodyEmptyConfirmed: Bool = false

    /// Stable terminal reason explaining why this body could not be indexed.
    ///
    /// Unlike `bodyEmptyConfirmed`, this does NOT claim the server returned no
    /// content, and unlike `bodyComplete`, it does NOT claim the body reached FTS.
    /// A non-nil value retires the row from automatic body queues while keeping
    /// the missing index entry truthful and visible in sync progress. Smart
    /// Reindex clears it so a server/app upgrade gets another attempt.
    var bodyIndexingFailureReason: String?

    /// How many times a body fetch returned empty (no text, no attachments).
    /// Used to guard against false empties from partial IMAP responses.
    /// bodyEmptyConfirmed is only set when emptyFetchCount >= 3.
    var emptyFetchCount: Int = 0

    /// How many times an IMAP batch fetch did NOT return this UID (absent from the
    /// batch result, as opposed to returning an empty body). After a configurable
    /// threshold the header is treated as confirmed-gone from the server and deleted.
    /// Reset on any successful fetch.
    var missFetchCount: Int = 0

    /// Whether a notification with completed AI classification was delivered for this message.
    /// Set by NSE (via staging DB merge) or main app (after posting a local notification).
    /// Prevents double-notifying. Deterministic notification ID (email-{accountId}-{messageId})
    /// handles upgrade from passive to active if AI classifies as reply.
    var notified: Bool = false

    /// Embedding vector has been generated and stored for this message.
    /// Set after SearchIndex.storeEmbedding succeeds. Used by Active/BackfillEmbeddingQueue
    /// repopulate to avoid cross-DB FTS queries.
    var embeddingComplete: Bool = false

    /// Decoded References header — array of normalized message IDs from the thread ancestor chain.
    var references: [String] {
        guard let json = referencesJSON,
              let data = json.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [String] else {
            return []
        }
        return array
    }

    /// Encode references array to JSON for storage.
    static func encodeReferences(_ refs: [String]) -> String? {
        guard !refs.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: refs),
              let json = String(data: data, encoding: .utf8) else {
            return nil
        }
        return json
    }

    /// Returns the most stable identifier for use in PendingOperation queues.
    /// For IMAP messages (numeric UIDs), prefers rfc822MessageId which survives
    /// UIDVALIDITY changes and UID remaps after MOVE. For Gmail/Exchange (non-numeric
    /// stable IDs), returns messageId.
    var stableId: String {
        if UInt32(messageId) != nil, let rfc822 = rfc822MessageId, !rfc822.isEmpty {
            return rfc822
        }
        return messageId
    }

    /// Set `actionTag` (and its two derived companions, `tagSortOrder` and
    /// `actionTagSetAt`) atomically. Use this instead of assigning `actionTag`
    /// directly wherever a model-save path applies a NEW tag value or clears
    /// one: a non-nil `tag` stamps `actionTagSetAt = date` (defaults to now —
    /// the moment this write happens); nil clears both `tagSortOrder` (→ 99)
    /// and `actionTagSetAt` (→ nil) together, preserving the invariant
    /// `actionTag != nil ⇒ actionTagSetAt != nil`. Callers CARRYING a stamp
    /// forward from another row/generation (identity merges, AI-cache
    /// restores, provider-DTO round-trips) should pass that source's
    /// `actionTagSetAt` as `date` instead of accepting the `Date()` default.
    mutating func setActionTag(_ tag: ActionTag?, at date: Date = Date()) {
        actionTag = tag
        actionTagSetAt = tag == nil ? nil : date
        tagSortOrder = tag?.sortOrder ?? 99
    }

    // MARK: - GRDB Associations

    /// Has-many association to the messageReference junction table for indexed reverse reference lookups.
    static let messageReferences = hasMany(MessageReference.self, using: MessageReference.messageHeaderForeignKey)

    init(
        messageId: String,
        subject: String,
        from: String,
        fromAddress: String,
        to: String,
        date: Date,
        snippet: String,
        folderId: String,
        accountId: String,
        folderPath: String,
        isInInbox: Bool
    ) {
        self.id = MessageIdentity.headerId(accountId: accountId, folderPath: folderPath, messageId: messageId)
        self.folderId = folderId
        self.accountId = accountId
        self.folderPath = folderPath
        self.isInInbox = isInInbox
        self.messageId = messageId
        self.subject = subject
        self.from = from
        self.fromAddress = fromAddress
        self.to = to
        self.date = date
        self.snippet = snippet
        self.isRead = false
        self.isFlagged = false
        self.hasAttachments = false
        self.isReplied = false
        self.isForwarded = false
        self.bodyIndexingFailureReason = nil
    }
}

/// Junction table row for the messageReference table — maps a messageHeader to an rfc822 ID it references.
struct MessageReference: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "messageReference"

    var messageHeaderId: String
    var referencedRfc822Id: String

    /// Foreign key back to messageHeader.
    static let messageHeaderForeignKey = ForeignKey(["messageHeaderId"])
}
