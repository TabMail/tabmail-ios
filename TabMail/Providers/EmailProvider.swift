/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// Result of saving a draft to the server.
/// For Gmail: serverId is the draft resource ID, messageId is the underlying Gmail message ID.
/// For IMAP/Exchange: serverId is the UID/message ID (same as messageId), so messageId is nil.
struct DraftSaveResult: Sendable {
    let serverId: String
    let messageId: String?
    init(serverId: String, messageId: String? = nil) {
        self.serverId = serverId
        self.messageId = messageId
    }
}

struct FolderInfo: Sendable {
    let name: String
    let path: String // Server-side identifier (Gmail: label ID, IMAP: mailbox name)
    var role: FolderRole // var so the IMAP dedup pass can demote duplicate-role folders to .custom
    let unreadCount: Int
    let totalCount: Int
    let uidNext: Int? // IMAP only — for delta sync change detection
    let highestModSeq: Int? // IMAP CONDSTORE only — full-sync fetch-skip (Fix B task 4). nil = no CONDSTORE

    init(name: String, path: String, role: FolderRole, unreadCount: Int, totalCount: Int, uidNext: Int? = nil, highestModSeq: Int? = nil) {
        self.name = name
        self.path = path
        self.role = role
        self.unreadCount = unreadCount
        self.totalCount = totalCount
        self.uidNext = uidNext
        self.highestModSeq = highestModSeq
    }
}

struct MessageHeaderInfo: Sendable {
    let messageId: String
    let rfc822MessageId: String? // RFC 2822 Message-ID header (device-independent, for cross-device AI cache probe)
    let inReplyTo: String? // RFC 2822 In-Reply-To header (parent message ID for thread detection)
    let references: [String] // RFC 2822 References header (ancestor chain for thread detection fallback)
    let threadId: String?
    let subject: String
    let from: String
    let fromAddress: String
    let to: String
    let cc: String
    let bcc: String
    let replyTo: String?
    let date: Date
    let snippet: String
    let isRead: Bool
    let isFlagged: Bool
    let hasAttachments: Bool
    let isReplied: Bool
    let isForwarded: Bool
    let actionTag: ActionTag?
    /// User label IDs extracted during message parse (Gmail: label IDs, IMAP: custom keywords).
    /// Excludes tm_* labels (handled by ActionTag) and system labels.
    /// Empty for providers that don't support labels.
    var userLabelIds: [String] = []
}

struct AttachmentInfo: Sendable, Codable {
    let filename: String
    let contentType: String
    let section: String  // MIME section for IMAP fetch, or attachment ID for Gmail
    let size: Int
    let encoding: String?  // Content-Transfer-Encoding (e.g. "base64", "quoted-printable") for IMAP decoding
    /// Section of the enclosing `message/rfc822` part when this attachment lives
    /// inside an attached `.eml`. `nil` for top-level attachments. Enables
    /// `AttachmentListView` to show only top-level chips while
    /// `EmlAttachmentPreview` surfaces the nested ones, and prevents Forward
    /// carry-over from duplicating attachments already inside a carried `.eml`.
    ///
    /// Added after initial ship — optional so Codable decoding of pre-existing
    /// `attachmentsJSON` rows (without this key) defaults to nil (= top-level).
    /// Older records show all attachments flat until next body re-fetch.
    let parentEmlSection: String?

    init(filename: String, contentType: String, section: String, size: Int, encoding: String?, parentEmlSection: String? = nil) {
        self.filename = filename
        self.contentType = contentType
        self.section = section
        self.size = size
        self.encoding = encoding
        self.parentEmlSection = parentEmlSection
    }
}

/// Inline image data resolved from CID (Content-ID) references.
struct InlineImage: Sendable {
    let contentId: String   // e.g. "image001.png@01D12345" (without angle brackets)
    let contentType: String // e.g. "image/png"
    let data: Data
}

struct FullMessageInfo: Sendable {
    let header: MessageHeaderInfo
    let htmlBody: String?
    let textBody: String?
    let attachments: [AttachmentInfo]
    let inlineImages: [InlineImage]
    /// Pre-fetched ICS calendar data (from pipelined batch fetch).
    /// When present, renderBody skips the separate fetchAttachment call.
    let icsData: Data?

    init(header: MessageHeaderInfo, htmlBody: String?, textBody: String?, attachments: [AttachmentInfo] = [], inlineImages: [InlineImage] = [], icsData: Data? = nil) {
        self.header = header
        self.htmlBody = htmlBody
        self.textBody = textBody
        self.attachments = attachments
        self.inlineImages = inlineImages
        self.icsData = icsData
    }
}

/// Narrow capability: probe whether a message with the given RFC 2822 Message-ID
/// currently exists in a folder on the server. Used by the backfill body queue
/// to disambiguate an IMAP UID miss (potentially a UIDVALIDITY remap) from a
/// genuinely deleted message BEFORE removing the local header row.
///
/// Only providers that need such disambiguation conform. IMAPProvider conforms
/// in production. REST providers (Gmail/Exchange) already get a clean 404
/// signal from `fetchMessagesBatch` and don't need this probe.
protocol MessageExistenceProbe: Sendable {
    func messageExistsInFolder(rfc822MessageId: String, folderPath: String) async throws -> Bool

    /// Resolve the CURRENT server UID(s) for an RFC 2822 Message-ID in a folder.
    /// Empty array = confirmed not present (same signal as `messageExistsInFolder`
    /// returning false). Used by the backfill body queue to re-key a UID-remapped
    /// header in place (old UID dead, message alive under a new UID) instead of
    /// retrying the dead UID forever — deep-history remaps are never realigned by
    /// full-sync, whose stale/remap window only covers recent messages.
    func currentUIDs(rfc822MessageId: String, folderPath: String) async throws -> [String]
}

/// How a provider's windowed `fetchMessages(limit:)` orders its results, which
/// determines the safe dimension for stale-detection's "overlap window".
/// - `.uid`: IMAP returns the highest UIDs (archive-time order, DECORRELATED from
///   message date). The stale window MUST be UID-based — a date-based window
///   over-deletes when an old-dated message is archived into a fresh high UID.
/// - `.date`: Gmail/Exchange return the most recent by date → date-based window.
enum StaleWindowMode: Sendable { case uid, date }

protocol EmailProvider: Sendable {
    func connect() async throws
    func disconnect() async throws

    /// Fetch-ordering dimension for stale-detection windowing. Defaults to `.date`
    /// (HTTP providers); IMAP overrides to `.uid`. See `StaleWindowMode`.
    var staleWindowMode: StaleWindowMode { get }

    /// Mark the provider's connections as potentially stale. Called on session start
    /// (foreground return, BGAppRefresh, push wakeup). IMAP providers drain and reseed
    /// their connection pool on the next checkout. HTTP providers are a no-op (ephemeral sessions).
    func markDirty() async

    func fetchFolders() async throws -> [FolderInfo]
    func fetchMessages(folder: String, limit: Int, offset: Int) async throws -> [MessageHeaderInfo]
    func fetchMessage(id: String, folder: String) async throws -> FullMessageInfo
    func search(query: String, folder: String, after: Date?, before: Date?, from: String?, to: String?) async throws -> [MessageHeaderInfo]

    func markRead(ids: [String], folder: String) async throws
    func markUnread(ids: [String], folder: String) async throws
    func markFlagged(ids: [String], flagged: Bool, folder: String) async throws
    func move(ids: [String], from: String, to: String) async throws

    func send(draft: DraftMessage) async throws

    /// Append a copy of the sent message to the server's Sent folder.
    /// For IMAP: explicit APPEND. For Gmail/Exchange: no-op (API auto-saves).
    /// - Parameters:
    ///   - draft: The sent message content.
    ///   - sentFolderPath: Server-side Sent folder path.
    ///   - messageId: The RFC822 Message-ID used during SMTP send (for dedup).
    /// - Returns: `true` if the message was appended (or confirmed already present).
    func appendToSentFolder(draft: DraftMessage, sentFolderPath: String, messageId: String) async throws -> Bool

    /// Save a draft to the server's Drafts folder. Creates or updates.
    /// - Parameters:
    ///   - draft: The draft message content.
    ///   - existingDraftId: Server-side draft ID for update (nil for create).
    ///   - draftsFolderPath: Server-side Drafts folder path (for IMAP).
    /// - Returns: DraftSaveResult with serverId (for update/delete) and optional messageId
    ///   (Gmail only — the underlying message ID, different from the draft resource ID).
    func saveDraft(_ draft: DraftMessage, existingDraftId: String?, draftsFolderPath: String) async throws -> DraftSaveResult

    /// Delete a draft from the server's Drafts folder.
    /// Best-effort — failure is logged but does not throw (orphaned drafts are harmless).
    func deleteDraft(draftId: String, draftsFolderPath: String) async throws

    // Incremental sync (optional — Gmail uses history.list, IMAP returns nil)
    func fetchHistory(since historyId: String) async throws -> HistoryResponse?
    func fetchMessageHeaders(ids: [String]) async throws -> [MessageHeaderInfo]

    /// Batch fetch text bodies (HTML + text/plain) for FTS indexing.
    /// Returns results keyed by message ID with htmlBody/textBody.
    /// Each provider uses its own optimal concurrency and batching strategy internally.
    /// IMAP: parallel pool connections with per-batch chunking.
    /// Gmail/Exchange: concurrent HTTP streams.
    /// - Parameters:
    ///   - ids: Message IDs to fetch bodies for. IMAP: numeric UID strings. Gmail/Exchange: provider message IDs.
    ///   - folder: Folder path (required for IMAP SELECT, ignored by Gmail/Exchange).
    func fetchTextBodies(ids: [String], folder: String) async throws -> [TextBodyFetchResult]

    /// Batch fetch full messages for body processing (MessageBody + FTS + rendering).
    /// IMAP: single connection, one SELECT, bulk BODYSTRUCTURE, per-message body parts.
    /// Gmail/Exchange: concurrent HTTP fetches (default sequential fallback).
    /// Returns successfully fetched messages keyed by message ID.
    /// Throws on connection-level errors. Individual message failures are omitted from result.
    func fetchMessagesBatch(ids: [String], folder: String) async throws -> [String: FullMessageInfo]
}

extension EmailProvider {
    /// Default no-op for HTTP-based providers (Gmail, Exchange) — ephemeral sessions have no stale connections.
    func markDirty() async {}

    /// HTTP providers (Gmail, Exchange) return most-recent-by-date → date window.
    /// IMAP overrides to `.uid`.
    var staleWindowMode: StaleWindowMode { .date }

    /// Default sequential implementation. IMAP overrides with batched single-connection fetch.
    ///
    /// Semantics contract: **an ID missing from the returned dictionary means the
    /// server has confirmed that message is permanently gone — HTTP 404/410
    /// ONLY.** It does NOT mean "we had some trouble fetching it." Any other
    /// failure — transient auth refresh (401), rate limit (429), server error
    /// (5xx), network timeout, parse failure — re-throws so the caller fails
    /// the entire batch and retries later.
    ///
    /// Note the deliberate narrowness: we do NOT swallow `ProviderError.messageNotFound`
    /// here. In this codebase Gmail/Exchange providers throw `.messageNotFound`
    /// for PARSE failures (malformed JSON, unreadable base64), NOT for 404s —
    /// which take the `.networkError(HTTPError(404))` path through `request()`.
    /// Treating parse failures as "confirmed gone" would delete local headers
    /// after 5 unparseable responses, which is a data-loss bug. Parse failures
    /// re-throw and retry, letting a transient server glitch resolve itself.
    ///
    /// `isConfirmedGoneError` (which DOES match `.messageNotFound`) remains
    /// correct for the PendingOperation drain path because action methods
    /// (move, markRead, setTag) never exercise the parse-failure code paths.
    func fetchMessagesBatch(ids: [String], folder: String) async throws -> [String: FullMessageInfo] {
        // Defensive guard: synthetic placeholder ids ("sent-<UUID>" / "draft-<UUID>")
        // must never be forwarded to a remote provider. If we see any, throw — do
        // NOT silently drop them, because that would feed the caller's "missing
        // from result" path and after threshold the local row + cached body get
        // CASCADE-deleted. Throwing keeps the items queued (and they fall out
        // naturally after maxQueueRetries). Hitting this guard means an upstream
        // queue regressed — see `isSyntheticPlaceholderId` doc.
        let synthetic = ids.filter(isSyntheticPlaceholderId)
        if !synthetic.isEmpty {
            print("[Provider] ERROR: synthetic placeholder ids leaked into fetchMessagesBatch — upstream queue regression. folder=\(folder) ids=\(synthetic.prefix(5))")
            throw ProviderError.syntheticPlaceholderId(synthetic)
        }
        var results: [String: FullMessageInfo] = [:]
        for id in ids {
            do {
                let msg = try await fetchMessage(id: id, folder: folder)
                results[id] = msg
            } catch {
                if isHttpGoneStatus(error) {
                    print("[Provider] fetchMessagesBatch: \(id) confirmed gone (HTTP 404/410) — omitting from result")
                    continue
                }
                print("[Provider] fetchMessagesBatch: transient/parse error for \(id): \(error) — failing batch")
                throw error
            }
        }
        return results
    }
}

/// Structural HTTP 404/410 check. Intentionally stricter than
/// `AccountManager.isConfirmedGoneError` — does NOT match
/// `ProviderError.messageNotFound` because Gmail/Exchange overload it for
/// parse failures (see `fetchMessagesBatch` doc above).
private func isHttpGoneStatus(_ error: Error) -> Bool {
    guard case ProviderError.networkError(let underlying) = error else { return false }
    if case HTTPError.networkError(let statusCode) = underlying {
        return statusCode == 404 || statusCode == 410
    }
    let nsCode = (underlying as NSError).code
    return nsCode == 404 || nsCode == 410
}

/// Result of a Gmail history.list call — tells us exactly what changed since last sync
struct HistoryResponse: Sendable {
    let newHistoryId: String
    let messagesAdded: [HistoryMessageRef]
    let messagesDeleted: [HistoryMessageRef]
    let labelsAdded: [HistoryLabelChange]
    let labelsRemoved: [HistoryLabelChange]
}

struct HistoryMessageRef: Sendable {
    let messageId: String
    let labelIds: [String]
}

struct HistoryLabelChange: Sendable {
    let messageId: String
    let labelIds: [String]
}

/// Lightweight body-only fetch result for FTS indexing.
/// Skips header parsing, attachment metadata, and inline image resolution.
struct TextBodyFetchResult: Sendable {
    let id: String
    let htmlBody: String?
    let textBody: String?
    let error: Error?
}

/// Combined header + body fetch result for unified backfill.
/// Gmail/Exchange fetch headers and body in a single API call (format=full / $select=...,body).
struct BackfillResult: Sendable {
    let id: String
    let header: MessageHeaderInfo?
    let htmlBody: String?
    let textBody: String?
    let error: Error?
}

enum ProviderError: LocalizedError {
    case notConnected
    case messageNotFound
    case authenticationFailed
    case networkError(underlying: Error)
    case invalidURL(String)
    /// IMAP SEARCH by Message-ID header returned no results. The message likely exists
    /// but the server couldn't match it (substring vs exact match, timing, etc.).
    /// Distinct from `messageNotFound` — drain queue should retry, not drop.
    case uidResolutionFailed(String)
    /// One or more ids handed to `fetchMessagesBatch` are TabMail-internal synthetic
    /// placeholder ids (`sent-<UUID>` / `draft-<UUID>`) that should never reach a
    /// remote provider. Means an upstream queue picked up a row it shouldn't have.
    /// We throw — never silently drop — because the caller's "missing from result"
    /// path increments a miss counter and after threshold deletes the local row,
    /// which would CASCADE delete the locally-cached body and lose user data.
    case syntheticPlaceholderId([String])
    /// A TabMail-internal synthetic folder path (e.g. Gmail's `__GMAIL_ALL_MAIL__`)
    /// leaked into a provider API request. Synthetic paths exist only in TabMail's
    /// folder model and must be translated (or omitted) before reaching the wire —
    /// the server rejects them anyway (Gmail: HTTP 400 "Invalid label"). Thrown at
    /// the request boundary so the bug surfaces at its source, not as an opaque
    /// network error.
    case syntheticFolderPath(String)

    var errorDescription: String? {
        switch self {
        case .notConnected: return "Not connected to mail server."
        case .messageNotFound: return "Message not found."
        case .authenticationFailed: return "Authentication failed. Please check your credentials."
        case .networkError(let error): return "Network error: \(error.localizedDescription)"
        case .invalidURL(let url): return "Invalid URL: \(url)"
        case .uidResolutionFailed(let id): return "Could not resolve Message-ID '\(id)' to UID."
        case .syntheticPlaceholderId(let ids): return "Synthetic placeholder id(s) leaked into provider fetch: \(ids.prefix(3))"
        case .syntheticFolderPath(let path): return "Synthetic folder path leaked into provider request: \(path)"
        }
    }
}

/// True when `id` matches a TabMail-internal optimistic-placeholder shape.
/// `sent-<UUID>` (AccountManagerOutbox.insertOptimisticSentHeader) and
/// `draft-<UUID>` (AccountManagerActions.queueDraftSave) are written into
/// `messageHeader.messageId` so the row exists in the user's Sent/Drafts view
/// before the server has assigned a real id. They MUST NOT be forwarded to
/// any provider's HTTP/IMAP fetch — the server has no record of them. Used
/// as a defensive guard at the provider boundary; the upstream queues are
/// supposed to gate these out via `bodyComplete=1`, and reaching this guard
/// means a regression somewhere upstream.
func isSyntheticPlaceholderId(_ id: String) -> Bool {
    id.hasPrefix("sent-") || id.hasPrefix("draft-")
}
