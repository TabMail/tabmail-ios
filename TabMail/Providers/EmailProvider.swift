/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// PORT — reduced from v2final `DraftSaveOutcome` / `CreatedId` (82c9ce5c9).
/// A created address is provider-native; no display/header identifier may be
/// reinterpreted as mutation authority.
enum DraftCreatedAddress: Sendable, Equatable {
    case gmail(resourceId: String, containedMessageId: String?)
    case outlook(graphId: String)
    case imap(folder: String, uidValidity: Int, uid: Int)
    case demo(localId: String)
}

enum DraftSaveOutcome: Sendable, Equatable {
    case created(DraftCreatedAddress)
    /// The provider may have created a copy, but this attempt produced no
    /// destructive-capable address. Terminal for this attempt; sync reconciles.
    case unaddressable
}

/// PORT — reduced typed delete seam from v2final commit 83205c5a7.
enum DraftDeleteIdentity: Sendable, Equatable {
    case gmail(resourceId: String)
    case gmailContainedMessage(messageId: String)
    case outlook(graphId: String)
    case imap(folder: String, uidValidity: Int, uid: Int)
    case demo(localId: String)
}

enum DraftDeleteAddressKind: String, Codable, Sendable {
    case providerResource
    case gmailContainedMessage
}

/// PORT adaptation of v2final's concrete registered-provider switch. This is
/// deliberately runtime truth, never the persisted Account.provider column.
enum DraftRuntimeIdentityKind: Sendable, Equatable {
    case gmail
    case outlook
    case imap
    case demo
    case unknown
}

struct FolderInfo: Sendable {
    let name: String
    let path: String // Server-side identifier (Gmail: label ID, IMAP: mailbox name)
    var role: FolderRole // var so the IMAP dedup pass can demote duplicate-role folders to .custom
    let unreadCount: Int
    let totalCount: Int
    let uidNext: Int? // IMAP only — for delta sync change detection
    let highestModSeq: Int? // IMAP CONDSTORE only — full-sync fetch-skip (Fix B task 4). nil = no CONDSTORE
    /// IMAP UIDVALIDITY — the folder's UID-numbering epoch (RFC 3501 §2.3.1.1).
    /// Carried on the folder-list path so the full sync can make the epoch
    /// DURABLE (`Folder.lastKnownUidValidity`); the delta path already gets it
    /// from `IMAPFolderStatus`. nil when the server didn't report it (no
    /// UIDPLUS) and for every non-IMAP provider — nil means UNKNOWN, never
    /// "unchanged", so callers must not synthesise a value from it.
    let uidValidity: Int?

    init(
        name: String, path: String, role: FolderRole, unreadCount: Int, totalCount: Int,
        uidNext: Int? = nil, highestModSeq: Int? = nil, uidValidity: Int? = nil
    ) {
        self.name = name
        self.path = path
        self.role = role
        self.unreadCount = unreadCount
        self.totalCount = totalCount
        self.uidNext = uidNext
        self.highestModSeq = highestModSeq
        self.uidValidity = uidValidity
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

    /// T1.2b: the UIDVALIDITY the MOST RECENT SELECT of `folderPath` reported, or
    /// `nil` when that SELECT reported none, when this provider has never SELECTed
    /// the folder, or when the folder concept doesn't apply (every non-IMAP
    /// provider).
    ///
    /// Two things it is NOT, both load-bearing for the caller that persists it:
    /// it never returns `0` (that is "the server did not report a value", never an
    /// epoch), and it never falls back to an epoch an EARLIER SELECT reported once
    /// the current one has stopped reporting one — "unknown now" must read as
    /// unknown, not as "known before" (project rule 4, no fallbacks).
    ///
    /// Deliberately synchronous/non-`async` (`nonisolated` on the IMAP
    /// override) so a sync pass can read "the epoch my fetch was served under"
    /// from inside a GRDB write closure, which cannot `await`.
    ///
    /// REFERENCE (`v2final`, tag `e28dd4edb`): the same member and the same
    /// `nil` default — `v2final:TabMail/Providers/EmailProvider.swift:210` /
    /// `:352`, backed by `IMAPProvider.lastObservedUidValidityBox` (symbol-cited
    /// on purpose: line citations into `IMAPProvider.swift` are abolished in
    /// SWIFT SOURCES, because any edit to that file silently falsifies a number
    /// cited here — ~180 stale ones do still survive in `PLAN_*.md` and
    /// `analysis/v3-recon/*.md`, which this convention does not reach). The
    /// no-stale-fallback rule above is an ADDITION to the reference, required
    /// because v3's consumer writes the value instead of comparing it — see
    /// `IMAPProvider.selectMailboxTracked`.
    func lastObservedUidValidity(folderPath: String) -> UInt32?

    /// Mark the provider's connections as potentially stale. Called on session start
    /// (foreground return, BGAppRefresh, push wakeup). IMAP providers drain and reseed
    /// their connection pool on the next checkout. HTTP providers are a no-op (ephemeral sessions).
    func markDirty() async

    func fetchFolders() async throws -> [FolderInfo]
    func fetchMessages(folder: String, limit: Int, offset: Int) async throws -> [MessageHeaderInfo]

    /// `fetchMessages`, plus the UIDVALIDITY the SELECT that served it reported —
    /// BOUND together, so a consumer that WRITES the epoch can never pick up one
    /// some other SELECT of the same path recorded in between.
    ///
    /// `SyncEngine.runSyncMessages` is the caller, and its consumer direction is a
    /// bootstrap WRITE of `Folder.lastKnownUidValidity`. Reading the shared
    /// `lastObservedUidValidity(folderPath:)` mirror there was fail-DANGEROUS: the
    /// backfill walk, self-heal and deep backfill all record into that mirror
    /// (see `IMAPProvider.selectMailboxTracked`), so one of them landing between
    /// the fetch and the read makes the pass stamp the live server's epoch over a
    /// batch that belongs to the previous one. See
    /// `IMAPProvider.fetchMessagesWithObservedEpoch` for the full rationale.
    func fetchMessagesWithObservedEpoch(
        folder: String, limit: Int, offset: Int
    ) async throws -> (messages: [MessageHeaderInfo], observedEpoch: UInt32?)

    /// T4.S6b: envelope-level sample of SPECIFIC UIDs, plus the UIDVALIDITY the
    /// SELECT that served it reported — BOUND together, same discipline as
    /// `fetchMessagesWithObservedEpoch`.
    ///
    /// The sole consumer is `SyncEngine.verifyAndBootstrapPrePopulatedFolderEpoch`,
    /// which asks one question: *do this folder's OWN stored UIDs still name this
    /// folder's OWN stored messages on the server right now?* It answers by
    /// comparing normalized RFC-822 Message-IDs at specific UIDs, so what it needs
    /// back is `messageId` (the UID, as a string) paired with `rfc822MessageId`.
    ///
    /// A `nil` `observedEpoch` means "the SELECT that served this sample reported no
    /// UIDVALIDITY" — never "an earlier SELECT's value", and never `0` (RFC 3501
    /// §2.3.1.1 types UIDVALIDITY as `nz-number`; SwiftMail's `UIDValidity(0)` is
    /// its own "not reported" default). The consumer treats that as DO NOTHING, so
    /// the binding matters: an unbound epoch could drive a purge of a folder whose
    /// own SELECT never reported one.
    ///
    /// A requested UID that does NOT come back is **no evidence**, never a
    /// disagreement — see the consumer's classification table.
    func sampleHeadersForEpochVerification(
        folder: String, uids: [UInt32]
    ) async throws -> (messages: [MessageHeaderInfo], observedEpoch: UInt32?)

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

    /// Save a draft using only typed provider-native prior authority.
    func saveDraft(
        _ draft: DraftMessage,
        existingIdentity: DraftDeleteIdentity?,
        draftsFolderPath: String
    ) async throws -> DraftSaveOutcome

    /// PORT — narrowed from v2final `resolveDraftResource`. A Gmail Drafts
    /// header carries the contained MESSAGE id, while mutations require the
    /// wrapping RESOURCE id. Exactly one byte-exact wrapper returns its typed
    /// address; zero or multiple wrappers fail closed as `nil`.
    func resolveDraftResource(
        containedMessageId: String,
        draftsFolderPath: String
    ) async throws -> DraftCreatedAddress?

    /// Delete exactly one typed provider-native draft identity.
    func deleteDraft(identity: DraftDeleteIdentity) async throws

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
    func resolveDraftResource(
        containedMessageId: String,
        draftsFolderPath: String
    ) async throws -> DraftCreatedAddress? {
        throw ProviderError.actionIdentityResolutionFailed(
            "resolveDraftResource: provider has no contained-message adapter")
    }

    /// Default `nil` — UIDVALIDITY is an IMAP concept, so every other provider
    /// (and every generic test double) reports "unknown". `nil` is the FAIL-SAFE
    /// answer here: the only consumer is a bootstrap-only persist that writes
    /// nothing when the observation is unknown, so a provider that loses this
    /// override can never erase or invent an epoch (it just stops contributing
    /// one). REFERENCE (`v2final`): identical default at `EmailProvider.swift:352`.
    func lastObservedUidValidity(folderPath: String) -> UInt32? { nil }

    /// Default: the plain fetch, paired with an EXPLICIT `nil` — never a read of
    /// the `lastObservedUidValidity` mirror.
    ///
    /// 🚨 **The direction of this default is the whole point.** Delegating to the
    /// mirror was the first shape written here, and it reproduces exactly the
    /// unbound read this method exists to remove: any conformer that does not
    /// override would silently get the defective path, and silently is the worst
    /// way for a safety seam to fail (the same shape as the nil-defaulted test
    /// seam whose dropped injection put the unit suite on the live internet). A
    /// literal `nil` is BOUND BY CONSTRUCTION — it cannot drift, cannot be
    /// replaced between the fetch and the return, and cannot stamp anything: the
    /// sole consumer, `SyncEngine.runSyncMessages`, persists through
    /// `bootstrapCrawledFolderUidValidity`/`bootstrapFolderUidValidity`, which
    /// write nothing for a nil observation. Losing this override therefore stops
    /// a provider contributing an epoch; it can never make one up.
    ///
    /// UPDATE (T4.S6): `runSyncMessages` now has a SECOND consumer of this value —
    /// the in-transaction epoch comparison that abandons the merge pass and fires
    /// the purge-and-resync reaction. Its direction agrees: the guard requires BOTH
    /// sides known, so a nil observation fails OPEN (ordinary pass, no reaction).
    /// Losing the override therefore still only stops a provider contributing —
    /// it cannot manufacture a turnover, and it cannot manufacture agreement either,
    /// because agreement needs a non-nil value on both sides.
    ///
    /// ⚠ **RETRACTION (round 12, NB1) — the census this comment used to give was
    /// already false when it was written, and the SAME COMMIT falsified it.** It
    /// listed eleven conformers, asserted "exactly two overrides" of
    /// `lastObservedUidValidity`, and concluded that *every* conformer inheriting
    /// this default also answers `nil` from the mirror. `9e0c4797e` added
    /// `MirrorOnlyProvider` (in `SelectSourcedFolderEpochTests.swift`) — a
    /// twelfth conformer, a THIRD override, and the explicit counterexample to
    /// the "every inheritor has a nil mirror" clause, since it inherits this
    /// default while answering a populated mirror. That clause was the
    /// justification for calling the delegating form "invisible"; it is now
    /// simply wrong, and the searches are given below in place of the absolute.
    ///
    /// THE SEARCHES, run 2026-07-31 (re-run them; do not restate their output as
    /// a law):
    /// - `rg -n "(final class|class|struct|actor|extension) +\w+ *:.*EmailProvider"`
    ///   over `TabMail/`, `TabMailTests/`, `TabMailNotificationService/` returned
    ///   TWELVE — production: `IMAPProvider`, `GmailProvider`, `ExchangeProvider`,
    ///   `DemoProvider`; test doubles: `MockEmailProvider`, `PerIDFetchMock`,
    ///   `WorkQueueMockProvider`, `MirrorOnlyProvider`, and the
    ///   `NonProbeProvider` / `ProbingProvider` pairs in `HandleMissedItemsTests`
    ///   and `ConfirmGoneAtThresholdTests`. The search matches the DECLARATION
    ///   line only, so a conformance added in a separate `extension` would not
    ///   appear — it bounds from below, not exactly.
    /// - `rg -n "func lastObservedUidValidity"` over the same roots returned
    ///   THREE overrides: `IMAPProvider`'s, `MockEmailProvider`'s and
    ///   `MirrorOnlyProvider`'s (plus the protocol requirement and the default in
    ///   this file).
    ///
    /// What is true, and all that is needed: this default is BOUND BY
    /// CONSTRUCTION regardless of the census. A conformer that populates a
    /// mirror and does not override gets `nil` here rather than an unbound value
    /// — `MirrorOnlyProvider` is that case made real, and
    /// `SelectSourcedFolderEpochTests.aConformerThatDoesNotOverrideReportsNoEpoch`
    /// asserts it. A future conformer wanting to contribute an epoch must
    /// override this method with a genuinely bound one.
    ///
    /// `IMAPProvider` overrides with the BOUND form — the epoch taken from the
    /// very `Mailbox.Selection` that served the fetch. `MockEmailProvider`
    /// overrides too, because it is the double that MODELS an IMAP-like bound
    /// provider for the epoch suites; `DemoProvider` deliberately does not, and
    /// `SelectSourcedFolderEpochTests.aConformerThatDoesNotOverrideReportsNoEpoch`
    /// pins what that inheritance actually produces so this default can never be
    /// re-pointed at the mirror unnoticed.
    func fetchMessagesWithObservedEpoch(
        folder: String, limit: Int, offset: Int
    ) async throws -> (messages: [MessageHeaderInfo], observedEpoch: UInt32?) {
        let messages = try await fetchMessages(folder: folder, limit: limit, offset: offset)
        return (messages, nil)
    }

    /// Default: no sample, no epoch. **This default is fail-CLOSED here, and only
    /// here** — state the direction rather than the census, because the census moves
    /// (see the retraction above).
    ///
    /// The sole consumer's rule is: a nil `observedEpoch` ⇒ DO NOTHING — no stamp,
    /// no quarantine, no reaction. So a conformer that does not override stops
    /// CONTRIBUTING verification; it can never MANUFACTURE one, in either direction.
    /// It cannot stamp a folder by assertion (the stamp needs a non-nil epoch AND at
    /// least one RFC-822 agreement, and `([], nil)` has neither) and it cannot purge
    /// one (the react leg needs a non-nil epoch too — that asymmetry is the anti-brick
    /// rule, see the consumer).
    ///
    /// For a non-IMAP provider that is also the CORRECT answer, not merely a safe
    /// one: `Folder.lastKnownUidValidity` is nil forever on Gmail/Graph (neither ever
    /// populates `FolderInfo.uidValidity`), `fetchMessagesWithObservedEpoch` is nil
    /// for them by the same default above, and
    /// `AccountManager.newGestureRefusedForUnknownEpoch` excludes them BY PROVIDER
    /// rather than by the column — so there is nothing for a verified bootstrap to
    /// verify and nothing it would unblock.
    ///
    /// `IMAPProvider` overrides in `IMAPProviderEpochSample.swift` (a separate file
    /// on purpose). `MockEmailProvider` overrides too, because it is the double that
    /// MODELS an IMAP-like bound provider for the epoch suites — without that
    /// override every mock-driven test of the verified door would take this
    /// do-nothing leg and pass vacuously.
    func sampleHeadersForEpochVerification(
        folder: String, uids: [UInt32]
    ) async throws -> (messages: [MessageHeaderInfo], observedEpoch: UInt32?) {
        ([], nil)
    }

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
    /// The provider inspected the id it was handed and REFUSED to build a
    /// destructive command from it — the id is not an identity it can verify
    /// (a bare numeric UID, which is a mutable ADDRESS; or a value that does not
    /// canonicalize to an RFC 822 Message-ID). Ported from `v2final`'s case of
    /// the same name.
    ///
    /// DETERMINISTIC and PRE-WIRE: it cannot change on retry. The drain
    /// terminalizes it instead — see `AccountManager.drainPendingQueue`.
    case actionIdentityResolutionFailed(String)
    /// PORT — exact typed reset signal from v2final `ProviderError`.
    /// `stored` is the per-operation admitted epoch; `live` is from the
    /// uninterrupted SELECT that immediately precedes the IMAP mutation.
    case uidValidityChanged(folderPath: String, stored: UInt32, live: UInt32)
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
        case .actionIdentityResolutionFailed(let id): return "'\(id)' is not a verifiable message identity; refusing the operation."
        case .uidValidityChanged(let folderPath, let stored, let live):
            return "UIDVALIDITY changed for \(folderPath): stored=\(stored) live=\(live)"
        case .syntheticPlaceholderId(let ids): return "Synthetic placeholder id(s) leaked into provider fetch: \(ids.prefix(3))"
        case .syntheticFolderPath(let path): return "Synthetic folder path leaked into provider request: \(path)"
        }
    }
}

/// True when `id` matches a TabMail-internal optimistic-placeholder shape.
/// `sent-<UUID>` (`AccountManager.insertOptimisticSentHeader`, in
/// `AccountManagerOutbox.swift`) and `draft-<UUID>`
/// (`AccountManager.queueDraftSave`, in `AccountManagerActions.swift`) are written into
/// `messageHeader.messageId` so the row exists in the user's Sent/Drafts view
/// before the server has assigned a real id. They MUST NOT be forwarded to
/// any provider's HTTP/IMAP fetch — the server has no record of them. Used
/// as a defensive guard at the provider boundary; the upstream queues are
/// supposed to gate these out via `bodyComplete=1`, and reaching this guard
/// means a regression somewhere upstream.
func isSyntheticPlaceholderId(_ id: String) -> Bool {
    id.hasPrefix("sent-") || id.hasPrefix("draft-")
}
