/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB

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

    /// The metadata FETCH for this message overflowed the IMAP response parser's
    /// buffer (`PayloadTooLargeError`), so its body could not be retrieved.
    ///
    /// ⚠️ This records an OBSERVATION ABOUT ONE WIRE ATTEMPT, not a verdict about the
    /// message. The parser's bound is on unread aggregate bytes measured after the
    /// decode loop stops, so it is FRAGMENTATION-DEPENDENT: the same message can
    /// overflow on a lossy link and parse fine on WiFi. It is therefore NOT a claim
    /// that the body is unfetchable, and it must never be treated as one.
    ///
    /// SET by every path IN THE MAIN APP that observes the overflow, so the flagged
    /// population is "every row that overflowed" rather than "the rows a background queue
    /// happened to reach first". The writers are enumerated ONCE, under `WRITTEN by` at the
    /// bottom of this comment — do not restate them here; two enumerations in one comment is
    /// how the roster went stale the first time.
    ///
    /// ⚠️ The negative case, because "every path" is an absolute:
    /// `NSEIMAPConnection.performFetch`, in the notification-service extension, observes a
    /// `PayloadTooLargeError` and DISCARDS it — its catch logs through `NSELog.step` and
    /// returns nil. Deliberate: the NSE is a separate process on a hard memory and
    /// wall-clock budget, and a pushed message usually has no `messageHeader` row to flag
    /// yet. The cost is one bounded extra NSE fetch if that message is pushed again; the
    /// NSE does not retry in-process, so there is no loop.
    ///
    /// Read by five kinds of consumer. Three of them are code, and they all ask the same
    /// question through `isBodyQuarantined` below; the other two are SQL.
    ///  1. The four body-fetch admission queries
    ///     (`Active`/`BackfillBodyQueue.repopulateFromDatabase` and `.repopulateOnDrain`)
    ///     — a flagged row is not offered to the background queues.
    ///  2. Backfill progress (`SyncEngineBackfill.updateBackfillProgressForAccount`)
    ///     — a flagged row is counted as RESOLVED, not as pending. This is what lets
    ///     `BackfillProgress.isFullyComplete` become true, the sync banner clear, and
    ///     Fast Sync stop keeping the device awake, on an account holding one of these
    ///     messages. Owner decision 2026-09-01: while the parser bound is what it is,
    ///     these bodies are simply not fetchable, and nagging the user forever about
    ///     work that cannot be done is the worse product outcome. Note the scope of that
    ///     premise: not fetchable BY THIS BUILD, on the parser bound this build ships.
    ///     Nothing here claims the body is gone or that a later build cannot get it.
    ///     Four surfaces move with that decision, not three: the Fast Sync "Sync Complete"
    ///     banner, the wake lock, the "N / M indexed" numerator, and
    ///     `DynamicIslandChatButton.isBackfillInProgress` — the chat pill's "agent search
    ///     results may be incomplete" notice, which reads `!isFullyComplete` and therefore
    ///     also clears. For an account holding a quarantined body that notice is literally
    ///     still true, and it is inside the same decision: a notice that can never clear is
    ///     exactly the permanent nag that was overruled.
    ///  3. The user-open path (`MessageDetailViewModel.loadBody`) — a flagged row
    ///     reports "unable to load" immediately, in exactly the state a fetch that just
    ///     failed would leave behind, instead of spending a full connection on an
    ///     attempt this build cannot complete.
    ///  4. That view model's BODY POLL — the 2s retry loop `loadBody` starts on each of
    ///     its three cancelled-read exits, and that `refetchBody` restarts whenever a
    ///     pull-to-refresh produced no body. Those exits return BEFORE consumer 3's
    ///     branch, so without a gate of its own the poll retries a flagged row forever,
    ///     each attempt paying a full TCP + TLS + LOGIN + SELECT (the overflow marks the
    ///     folder connection unhealthy, so no attempt can reuse it). It reports the same
    ///     load-failed state and ends.
    ///  5. The inbox snippet loader's network tier (`InboxViewModel.loadSnippetBatch`) —
    ///     tier 2 calls `provider.fetchMessage` DIRECTLY, bypassing the funnel below, so
    ///     it needs its own gate. A flagged row is blacklisted for the session instead.
    ///     It matters that this one is gated at all: `reloadMessages` clears that
    ///     blacklist and re-queues the visible window, so an ungated row would be retried
    ///     on every single reload. Tier 2 is also a WRITER — see below.
    ///
    /// ⚠️ Consumers 3–5 ask this question through `isBodyQuarantined`, never by reading
    /// the column directly — the `&& !bodyComplete` fail-safe lives inside that property, so
    /// grepping any of those call sites for `bodyComplete` finds nothing.
    ///
    /// ⚠️ Consumers 3–4 are UI-STATE checks, not the network guard. The authoritative
    /// refusal lives at the funnel, `AccountManagerFetch.fetchBody`, beside the address
    /// gate whose comment states the rule. Gating callers alone was not enough:
    /// `MessageDetailViewModel.loadThreadMessageBody` — a collapsed thread bubble the user
    /// expands — reaches the funnel directly and had no check at all. Any FUTURE caller of
    /// `fetchBody` is covered for free; only a path that skips the funnel (consumer 5)
    /// needs its own. Pull-to-refresh is exempt at the funnel via `replaceExistingBody`.
    ///
    /// The row is NOT retired: `bodyComplete` stays 0, the header stays FTS-indexed and
    /// searchable by subject and sender, the FTS membership self-heal still sees it, and
    /// pull-to-refresh (`MessageDetailViewModel.refetchBody`) still performs a genuine
    /// retry. That retry is the user's escape hatch, and it is the reason the ⚠️ above
    /// still holds: this is an observation, not a verdict.
    ///
    /// CLEARED — the full set, because a flag that outlives its truth is worse than no
    /// flag at all:
    ///  • by ANY successful body write, which is positive evidence refuting the
    ///    observation. All five: `BodyFetchProcessor.flushBatch` (the body branch),
    ///    `BodyFetchProcessor.process` (the confirmed-empty branch — a different
    ///    function, not another branch of `flushBatch`), `NSEDataBridge
    ///    .flushNSEBatchToFTS`, `SyncEngine.applySnippetUpdates`, and
    ///    `SyncEngineFTS.oneTimeBodyCompleteRestore` (which heals rows selected BECAUSE
    ///    their FTS body text exists — the same positive evidence).
    ///    ⚠️ The set is defined by CONSEQUENCE, not by name: any statement that sets
    ///    `bodyComplete = 1` must clear this flag in the SAME statement, or it strands the
    ///    row in the one state no gate can see (both the writer's `AND bodyComplete = 0`
    ///    guard and `isBodyQuarantined`'s `&& !bodyComplete` fail-safe are keyed on the row
    ///    being incomplete). The one remaining `bodyComplete = 1` writer that does not
    ///    clear it is `AccountManagerOutbox`'s optimistic-Sent insert, and it cannot strand
    ///    anything: the row it writes is a brand-new `sent-<UUID>` that has never been
    ///    fetched, so the flag is 0 there by construction.
    ///    ⚠️ "The one remaining writer" counts RUNTIME writers. A full census also finds
    ///    two MIGRATIONS that set `bodyComplete = 1` — `v31_addHasBodyInFTS` and
    ///    `v57_repairOptimisticSentBodyComplete` — and neither is an exception: on a fresh
    ///    database both run BEFORE `v88_addBodyMetadataOversized`, so the column does not
    ///    yet exist, and on an existing database both have already run and a registered
    ///    migration is frozen. Named because an absolute with no negative case is the
    ///    shape that walks the next reader past a real one. (Found by audit.)
    ///    ⚠️ A `rg 'bodyMetadataOversized = 0'` census finds only THREE of them:
    ///    `applySnippetUpdates` writes it as a GRDB `updateAll` chain
    ///    (`Column("bodyMetadataOversized").set(to: false)`) and is invisible to every
    ///    SQL-text search. Census this flag by SYMBOL, not by statement text.
    ///    This is load-bearing, not tidiness:
    ///    `BodyAssetMaintenance` evicts the `messageBody` row while deliberately leaving
    ///    `bodyComplete = 1`, and the detail view's cache-miss fetch is the only
    ///    recovery — a stale flag would delete that recovery and brick a message this
    ///    build has already fetched once.
    ///  • on a UIDVALIDITY reset (the address changed, so the observation is void).
    ///    ⚠️ Scope: this is the folder-wide UIDVALIDITY reset path
    ///    (`clearOversizedDeferred` / `clearOversizedDurably`), which releases every
    ///    flagged row in the folder. A single-message UID REMAP is a different event and
    ///    does not run it — but it cannot strand a flag either, because the remap
    ///    re-keys the header row and the flag travels with the row it describes.
    ///  • by Smart Reindex (`SyncEngine.resetCrawlState`), the user's explicit
    ///    try-everything-again gesture.
    ///    ⚠️ DURABLE HALF ONLY. The process-lifetime sets `ActiveBodyQueue
    ///    .oversizedDeferredThisSession` / `isolationPending` survive it, so `admit` still
    ///    refuses the row for the rest of this launch: the count goes back above 0 and the
    ///    sync banner comes back up until the next relaunch, which gives the row one
    ///    genuine retry and then re-quarantines it. Self-healing and strictly better than
    ///    the pre-flag behaviour (the banner never cleared at all), but it is not the
    ///    immediate release the bullet above reads like on its own.
    ///    ⚠️ AND IT IS OUTSIDE THE SERIALIZED WRITE CHAIN. `resetCrawlState` writes through
    ///    `AppDatabase.backgroundPool` directly, so — unlike the UIDVALIDITY reset's clear,
    ///    which shares `enqueueDurableWrite` with all four marks — a mark dispatched
    ///    microseconds before the user taps Smart Reindex can commit AFTER this clear and
    ///    re-quarantine the row. (The five success-write clears need no such ordering: the
    ///    mark's own `AND bodyComplete = 0` makes a mark-after-success a no-op.) Left as a
    ///    fail-closed edge per THE MANTRA — the recovery is one more ordinary gesture, and
    ///    routing `resetCrawlState` through a queue actor's chain would be a larger change
    ///    for a narrower window. (Found by audit.)
    ///  • exactly, in one statement, by the migration that ships a raised parser bound —
    ///    which is the whole re-fetch mechanism for this population. ⚠️ That bound is
    ///    `IMAPFetchMapping.responseBufferLimit`, a FIRST-PARTY constant in this repo, not
    ///    an upstream dependency (upstream PR #179 already made it a constructor
    ///    parameter). Nothing external gates the release; it is a decision here about how
    ///    many bytes a single IMAP response may buffer. (Found by audit.)
    ///
    /// WRITTEN by one symbol only — `BodyFetchProcessor.markBodyMetadataOversized` —
    /// which carries BOTH guards (`AND bodyComplete = 0`, so a row that already has a body
    /// can never acquire the flag; and the re-minted-key comparison, so an overflow
    /// observed inside an `optimisticMoveToFolder` window is not recorded against the
    /// message the row's key names). Four call sites reach it: both queues'
    /// `markOversizedDurably` (through their serialized `enqueueDurableWrite`),
    /// `BodyFetchProcessor.fetch`'s `PayloadTooLargeError` branch, and
    /// `InboxViewModel.loadSnippetBatch`'s tier-2 catch. It is ONE symbol on purpose: the
    /// guards were previously transcribed three times, which is how a guard gets added to
    /// one copy and forgotten in another.
    var bodyMetadataOversized: Bool = false

    /// THE READ-SIDE INVARIANT, in one place: is this row's body quarantined right now?
    ///
    /// Every fetch initiator asks the same question, and they must never disagree — the
    /// four background admission queries ask it in SQL (`bodyMetadataOversized = 0`), and
    /// the three code paths that can start a fetch on their own ask it here:
    /// `MessageDetailViewModel.loadBody` (user open), that view model's body poll (the
    /// retry loop the three cancelled-read exits and `refetchBody` leave behind), and
    /// `InboxViewModel.loadSnippetBatch`'s tier-2 network fetch. Written out three times
    /// as `flag && !bodyComplete`, one of them would eventually be added, moved or
    /// negated alone.
    ///
    /// `!bodyComplete` is a FAIL-SAFE, not the primary defence — see the flag's own
    /// documentation above. The cache deleters remove a `messageBody` row while leaving
    /// `bodyComplete = 1` and rely on the detail view's cache-miss fetch as their only
    /// recovery, so a stale flag must cost a wasted round trip, never a permanently
    /// unopenable message.
    var isBodyQuarantined: Bool { bodyMetadataOversized && !bodyComplete }

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
    }
}

// MARK: - Backfill-progress predicates

extension MessageHeader {

    /// Rows that still owe a body fetch for `accountId` — the numerator of
    /// "work remaining" that `BackfillProgress.pendingBodyCount` publishes and
    /// `isFullyComplete` gates on.
    ///
    /// ⚠️ **This exists as a shared symbol so the test tree can assert the REAL
    /// predicate.** It used to be an inline `filter(…)` chain inside
    /// `SyncEngineBackfill.updateBackfillProgressForAccount`, and every test of it was
    /// a hand-copied replica — which cannot go red when production changes, and would
    /// have blessed a regression here (`feedback_tests_that_bless_the_bug`). Being a
    /// query-interface chain it is also invisible to every SQL-text grep
    /// (`feedback_census_inherits_its_search_shape`), so a name is the only way a
    /// future census finds it.
    ///
    /// `bodyMetadataOversized = 0` is part of the predicate: a message whose metadata
    /// FETCH overflows the IMAP response parser cannot be fetched by this build, and
    /// counting it as outstanding leaves the sync banner up forever. See the flag's own
    /// documentation for the owner decision behind that.
    static func pendingBodyRequest(accountId: String) -> QueryInterfaceRequest<MessageHeader> {
        MessageHeader.filter(
            Column("accountId") == accountId &&
            Column("headerComplete") == true &&
            Column("bodyComplete") == false &&
            Column("bodyEmptyConfirmed") == false &&
            Column("bodyMetadataOversized") == false
        )
    }

    /// Rows whose body question is SETTLED for `accountId` — fetched, confirmed empty,
    /// or unfetchable by this build. The complement of `pendingBodyRequest` among
    /// header-complete rows, and the numerator behind the "N / M indexed" readouts.
    ///
    /// ⚠️ Keep the two in lockstep. If a disposition counts as settled here but still
    /// counts as pending there, the progress bar parks below 100% beside a green
    /// completion check — the same nag in a different widget.
    static func bodySettledRequest(accountId: String) -> QueryInterfaceRequest<MessageHeader> {
        MessageHeader.filter(
            Column("accountId") == accountId &&
            (Column("bodyComplete") == true
                || Column("bodyEmptyConfirmed") == true
                || Column("bodyMetadataOversized") == true)
        )
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
