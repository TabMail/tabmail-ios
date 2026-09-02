/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB

/// Shared body fetch + render logic used by both ActiveBodyQueue (forward/inbox)
/// and BackfillBodyQueue (backward/all folders).
///
/// Two-phase pipeline per message:
/// 1. **Fetch** (provider-bound): provider.fetchMessage → render body (CID, ICS)
///    Provider owns concurrency — IMAP pool, Gmail/Exchange HTTP limits.
/// 2. **Process** (DB-bound): write MessageBody + FTS + snippet + flags + queue AI/embedding
///
/// Queues pipeline these: while processing result N, fetch N+1 is already in flight.
enum BodyFetchProcessor {

    struct Item: Sendable {
        let headerId: String
        let accountId: String
        let folderPath: String
        let messageId: String
        let isInInbox: Bool
    }

    enum Result: Sendable, Error {
        case success
        case confirmedEmpty
        case retry
        case payloadTooLarge
    }

    /// The ONE durable oversized mark. Both body queues and the single-item fetch path
    /// route here, so neither guard below can be added to one copy and forgotten in
    /// another — which is precisely the defect that made `admissionSQL` a shared symbol.
    ///
    /// **Guard 1, `AND bodyComplete = 0` — a proven body always wins.** The mark is
    /// DISPATCHED, so a user pull-to-refresh can succeed between the overflow and this
    /// statement. Without the guard it lands on a row that now HAS a body, and the stale
    /// flag makes that body unopenable once `BodyAssetMaintenance` evicts the cached
    /// asset — eviction deliberately leaves `bodyComplete = 1` (ADR-IOS-050), so the
    /// detail view's cache-miss fetch is the only recovery and the flag would delete it.
    ///
    /// **Guard 2, the re-minted-key comparison — the observation must be ABOUT this row.**
    /// Inside the `optimisticMoveToFolder` window a row's PRIMARY KEY and its columns name
    /// DIFFERENT messages: the key still carries the SOURCE folder and UID while the
    /// columns already claim the destination. The overflow was observed at the COLUMNS'
    /// address, so it is not evidence about the message the key names. Marking anyway is
    /// durable and rides the re-key (`MessageHeaderRekey.apply` copies the whole row), so
    /// a perfectly fetchable message is excluded from both admission queries, counted as
    /// settled by `MessageHeader.bodySettledRequest`, and refused by every read-side gate
    /// — permanently. This is the predicate `BodyAddressGate.addressIsInFlight` applies in
    /// Swift, expressed against the row's own columns: re-mint the key WHOLE and compare,
    /// never `hasPrefix`, so a `:` in the folder path or the messageId is just data on
    /// both sides. `StuckMessageDiagnostics`'s `pkMismatch` counts the same shape.
    /// It fails safe — the caller keeps its session-scoped deferral, and the row is
    /// re-attempted after `finishMove` re-keys it. (Found by audit.)
    ///
    ///
    /// ⚑ ACCEPTED LIMITATIONS OF THIS FLAG — registered as `IOS-BODY-006`, filed `open` and
    /// **NOT owner-blessed as a SET**. Each is a deliberate design choice with a stated
    /// rationale, and exactly TWO carry an actual owner decision, both dated 2026-09-01 and
    /// both reversals of an earlier stance recorded here: item 2 (let "Sync Complete" fire)
    /// and item 4's fail-fast-on-open (report the failure immediately instead of attempting
    /// a wire fetch). Items 1, 3, 5, 6 and 7 do NOT — and item 7, the one-strike latch on a
    /// non-deterministic signal, is precisely the question `IOS-BODY-006` was filed to put
    /// in front of the owner. Do not "fix" any of them without asking, and do not cite the
    /// set as accepted — a source comment claiming a blessing the register withholds is how
    /// a future reader stops asking. (Found by audit.)
    ///
    /// ⚠️ THIS ENUMERATION USED TO BE DUPLICATED VERBATIM on both queues'
    /// `markOversizedDurably`, under a "edit both copies or neither" instruction. It lives
    /// here now, on the single writer both of them call, because an instruction in a
    /// comment is not load-bearing — `MIS-IOS-009` is this repo's record of exactly that,
    /// and it is at nine recurrences. (Found by audit.)
    /// The SQL is NOT duplicated either: the mark and the UIDVALIDITY clear are single
    /// symbols (`BodyFetchProcessor.markBodyMetadataOversized` / `.clearBodyMetadataOversized`),
    /// so a guard cannot be added to one queue and forgotten in the other. ⚠️ The line that
    /// used to sit here said "Edit both copies or neither" — it survived the hoist that
    /// deleted the second copy, instructing the reader to maintain a duplication that no
    /// longer exists. Exactly the dead-instruction class the paragraph above cites.
    ///
    /// What legitimately stays per-queue is the write CHAIN — one INSTANCE of
    /// `BodyFetchProcessor.DurableWriteChain` per queue, never one shared instance.
    /// An earlier version of this comment gave a WRONG reason for
    /// that — "a shared helper would need an `await` inside `handlePayloadTooLarge`'s
    /// synchronous critical section, or unchecked-`Sendable` state mutated under two
    /// isolations". That is false: a `Mutex<Task<Void, Never>?>` is `Sendable` and
    /// `withLock` is synchronous, so a shared enqueue is expressible. The real reasons are
    /// (a) ISOLATION — the chain is per-INSTANCE state and suites construct their own
    /// `ActiveBodyQueue()` / `BackfillBodyQueue()` against their own temp pools, so one
    /// process-wide chain would make one
    /// suite's `awaitDurableWritesForTesting()` await another suite's in-flight writes; and
    /// (b) the two queues write through different priority tiers (`AppDatabase.syncPool` vs
    /// `.backgroundPool`), so one chain would serialize a foreground mark behind a
    /// background one. (Found by audit.)
    ///   1. The body stays unindexed and unsearchable BY CONTENT until the parser bound
    ///      is raised. The header stays FTS-indexed, so the message is still findable by
    ///      subject and sender. ⚠️ That bound is FIRST-PARTY, not an upstream dependency —
    ///      earlier wording here said "until a raised parser bound ships upstream", which
    ///      is wrong: it is `IMAPFetchMapping.responseBufferLimit`, a constant in this
    ///      repo passed to `IMAPServer(host:port:useTLS:responseBufferLimit:)` by both IMAP
    ///      entry points. Upstream PR #179 already made it a constructor parameter, so the
    ///      SwiftMail fork is a pure mirror and raising the value needs no upstream work.
    ///      (Found by audit.)
    ///   2. Backfill progress counts a flagged row as RESOLVED
    ///      (`SyncEngineBackfill.updateBackfillProgressForAccount`), so "Sync Complete"
    ///      fires on an account that still has an unfetchable body. Owner decision
    ///      2026-09-01, reversing the earlier stance recorded here: withholding
    ///      completion is a truth claim the user cannot act on, and the cost of it —
    ///      a banner that never clears and a progress bar parked one short of 100% —
    ///      is worse product behaviour than rounding an unfetchable message up to
    ///      done. Revisit when the parser bound is raised (see item 1).
    ///   3. ⛔ `SyncEngineFTS.selfHealBackfillFTSMembership` deliberately does NOT
    ///      carry this flag: it re-indexes HEADERS, and this row's header is healthy.
    ///      Excluding it would drop a good message out of subject/sender search.
    ///   4. Opening an affected message reports a load failure immediately without a
    ///      wire attempt (`MessageDetailViewModel.loadBody`) — **owner decision 2026-09-01**,
    ///      reversing an earlier stance that left the open path attempting the fetch; a
    ///      doomed attempt that costs a connection teardown buys the user nothing. The
    ///      body poll that
    ///      view model leaves behind stops itself the same way rather than retrying
    ///      every 2s forever. The user's retry is pull-to-refresh, which still performs
    ///      a genuine fetch — and whose own trailing poll then stops itself too.
    ///      The sentence a RELEASE user reads is `MessageCardView`'s generic "Unable to
    ///      load message. Pull to retry.", not `BodyFetchRefusal`'s specific text —
    ///      that view renders `viewModel.error` only under `DebugModeManager
    ///      .isLoggingEnabled()`. Convenient here, since the shipped string names the one
    ///      path that is exempt at the funnel. (Found by audit.)
    ///   5. The inbox snippet loader refuses the row at its network tier and blacklists
    ///      it for the session (`InboxViewModel.loadSnippetBatch`), so an affected row
    ///      shows no snippet preview. The blacklist is cleared on every reload, which
    ///      costs a repeated DB read and no wire traffic.
    ///   6. Expanding a collapsed thread bubble whose message is flagged
    ///      (`MessageDetailViewModel.loadThreadMessageBody`) now yields nothing at all —
    ///      no body, no error, no wire attempt. That function has always swallowed EVERY
    ///      failure into a debug print, so the user-visible outcome is unchanged from any
    ///      other error it hits; what changed is that the tap no longer buys a lucky
    ///      re-roll on a different fragmentation. The recovery is to open that message as
    ///      the focused message, where pull-to-refresh is exempt at the funnel. Listed
    ///      because it is a consequence of gating at the funnel rather than in the
    ///      callers, and the enumeration must be exhaustive to be worth reading.
    ///      (Found by audit.)
    ///
    ///   7. ⚠️ THE ONE ARCHITECTURALLY CONSEQUENTIAL PROPERTY, stated plainly because the
    ///      rest of this enumeration reads as if the flag named a permanent fact about a
    ///      message. It does not. The parser bound is on unread AGGREGATE bytes measured
    ///      after the decode loop stops, so the trigger is FRAGMENTATION-dependent: an
    ///      ordinary, perfectly fetchable message on a lossy link can roll into this
    ///      state. This is a ONE-STRIKE latch on a non-deterministic signal, unlike the
    ///      codebase's prior art for the same shape (`emptyFetchCount >= 3` before
    ///      `bodyEmptyConfirmed`), and once latched there is NO automatic release — only
    ///      pull-to-refresh, a UIDVALIDITY reset, Smart Reindex, or a future migration
    ///      that raises the bound. A strike counter is deliberately NOT built: that is a
    ///      new column and more mechanism for a case the pull-to-refresh escape hatch
    ///      already recovers in one gesture. Recorded so the trade is visible rather than
    ///      implied. (Found by audit.)
    ///
    /// The read-side predicate shared by items 4, 5 and 6 is `MessageHeader
    /// .isBodyQuarantined`; the four background queries are the SQL half of the same
    /// question (`ActiveBodyQueue.admissionSQL` / `BackfillBodyQueue.admissionSQL`).
    /// Item 6 reaches it through the funnel, `AccountManagerFetch.fetchBody`, not directly.
    ///
    /// Dispatch and ordering guarantees are documented on `enqueueDurableWrite`.
    nonisolated static func markBodyMetadataOversized(_ db: Database, headerId: String) throws {
        try db.execute(
            sql: """
                UPDATE messageHeader SET bodyMetadataOversized = 1
                WHERE id = ? AND bodyComplete = 0
                  AND id = accountId || ':' || folderPath || ':' || messageId
                """,
            arguments: [headerId])
    }

    /// The ONE durable oversized CLEAR for a UIDVALIDITY turnover — the inverse of the
    /// mark above, and one symbol for the same reason: both queues issue it, and this
    /// statement was duplicated VERBATIM on each of them, which is exactly the "a guard
    /// added to one copy and forgotten in the other" hazard that made `admissionSQL` and
    /// `markBodyMetadataOversized` shared symbols in the first place. (Found by audit.)
    ///
    /// A reset means the folder's UIDs no longer address the same messages, so a per-row
    /// observation about "the message at this address" is void and must not outlive it.
    ///
    /// Scoped by the `(accountId, folderPath)` COLUMNS, while the queues' in-memory half
    /// filters header-id STRINGS through `MessageIdentity.headerIdBelongsToFolder`.
    ///
    /// ⚠️ Those two are not the same predicate, and an earlier comment claimed the SQL form
    /// "cannot drift from `MessageIdentity`'s parsing". It can: `optimisticMoveToFolder`
    /// leaves a row whose id was minted under the SOURCE folder while its columns already
    /// name the DESTINATION, so for that row the string filter and the column filter
    /// disagree about which folder it belongs to.
    ///
    /// Kept as-is because the disagreement is benign in BOTH directions, and the columns
    /// are the better half: a UIDVALIDITY reset is a statement about the folder the row is
    /// IN. If this clear releases a mid-move row the in-memory half kept, the row is merely
    /// re-offered to the queues — worst case one wasted fetch. If it keeps one the
    /// in-memory half released, the row stays quarantined until the next reset, a success
    /// write, or Smart Reindex, exactly as any other flagged row does.
    nonisolated static func clearBodyMetadataOversized(
        _ db: Database, accountId: String, folderPath: String
    ) throws {
        try db.execute(
            sql: """
                UPDATE messageHeader SET bodyMetadataOversized = 0
                WHERE accountId = ? AND folderPath = ?
                  AND bodyMetadataOversized = 1
                """,
            arguments: [accountId, folderPath])
    }

    /// The serialized tail of one queue's dispatched durable flag writes.
    ///
    /// ⛔ THE SERIALIZATION IS A CORRECTNESS REQUIREMENT, NOT A CONVENIENCE. A mark and a
    /// clear can be dispatched microseconds apart — a UIDVALIDITY reset landing right after
    /// an oversized batch is exactly the case the synchronous `resetGeneration` guard exists
    /// for. If the two writes could reorder, the clear could execute FIRST and the mark
    /// would then re-flag a row whose address no longer refers to the same message,
    /// reintroducing through async dispatch the stale-quarantine bug the generation guard
    /// prevents in memory. Chaining every write behind its predecessor makes the durable
    /// order match the dispatch order.
    ///
    /// ONE TYPE, TWO INSTANCES — and the instances are the point. This was 63 BYTE-IDENTICAL
    /// lines on `ActiveBodyQueue` and `BackfillBodyQueue`, carrying a "edit both copies or
    /// neither" comment; a hardening applied to one copy (a retry, a backpressure bound, a
    /// new seam) would have silently left the other with the old semantics, so the ordering
    /// this file calls a correctness requirement would hold on one queue and not the other.
    /// The two reasons the CHAINS stay separate are unaffected by sharing the code, because
    /// both are about per-instance state rather than per-instance logic:
    ///   1. test isolation — suites construct their own `ActiveBodyQueue()` /
    ///      `BackfillBodyQueue()` against temp pools, and a shared tail would serialize
    ///      (and cross-contaminate) unrelated instances; and
    ///   2. different write-priority tiers — `AppDatabase.syncPool` vs `.backgroundPool`,
    ///      passed in per call rather than captured here.
    /// ⛔ Do NOT turn this into a singleton or a `static var`. Hold it as a per-instance
    /// `var` on each queue actor, exactly as both do today. (Found by audit.)
    struct DurableWriteChain {
        /// Log prefix identifying the owning queue, e.g. `"[ActiveBody]"`.
        let owner: String
        private var tail: Task<Void, Never>?

        init(owner: String) { self.owner = owner }

        /// Dispatches one durable flag write.
        ///
        /// ⚠️ DISPATCHED, NOT AWAITED, AND THAT IS LOAD-BEARING.
        /// `handlePayloadTooLarge` and `clearOversizedDeferred` are both documented as
        /// running synchronously on their actor so no producer can slip an enqueue between
        /// their set mutation and their queue mutation. Awaiting a database write inline
        /// would open exactly that window.
        ///
        /// ⛔ `Task`, never `Task.detached`: a detached task drops the write-priority tier
        /// task-locals the pool relies on.
        ///
        /// ⚠️ `pool` is a PARAMETER, not a property, and that is the eager-resolution rule
        /// made structural. Both queues' `dbPool` is a computed property over
        /// `AppDatabase.shared`; resolving it INSIDE the task would resolve it after
        /// `await previous?.value`, i.e. against whichever database is installed by the time
        /// the write finally runs — not the one whose UIDVALIDITY reset produced it. An
        /// identity resolved before an `await` is not a fact after it, and here the identity
        /// we need is the one from before. In production `AppDatabase.shared` is installed
        /// once at boot and this is a no-op; it is load-bearing for tests, which swap
        /// `AppDatabase.shared` to a temp pool and restore it in `defer`, so a
        /// late-resolving write would land on an unrelated suite's database and clear
        /// `bodyMetadataOversized` out from under its fixture. With the pool passed by
        /// value, a write that outlives its suite targets the retired pool and fails
        /// harmlessly into the `catch` below instead of corrupting a sibling.
        ///
        /// If a write fails the row simply keeps its in-memory disposition for this session
        /// and is reconsidered on the next launch — it degrades to the previous behaviour
        /// rather than to a wrong one, so there is nothing to compensate for.
        mutating func enqueue(
            pool: PrioritizedDatabase,
            label: String,
            _ op: @escaping @Sendable (Database) throws -> Void
        ) {
            let previous = tail
            let owner = self.owner
            tail = Task {
                await previous?.value
                do {
                    try await pool.write { db in try op(db) }
                } catch {
                    if DebugModeManager.isLoggingEnabled() {
                        print("\(owner) Durable oversized write failed (\(label)): \(error)")
                    }
                }
            }
        }

        /// Await every write dispatched so far.
        func drain() async {
            await tail?.value
        }
    }

    /// Record an observed overflow durably, from a path that is NOT one of the body queues:
    /// `BodyFetchProcessor.fetch` (the user-open funnel) and `InboxViewModel.loadSnippetBatch`
    /// tier 2.
    ///
    /// 🚨 Routed through `ActiveBodyQueue`'s serialized durable-write chain rather than
    /// writing directly, and that is a CORRECTNESS requirement, not tidiness. The chain is
    /// also what `AccountManagerUidValidityReset` uses for the reset's CLEAR, so ordering
    /// between a mark and a clear is only defined for writers that share it. A direct write
    /// races: overflow on `acct:INBOX:900` enqueues a mark → INBOX turns over → the reset
    /// purges and clears → the resync inserts a fresh-epoch row that reuses UID 900 → the
    /// stale mark commits last and passes both of `markBodyMetadataOversized`'s guards
    /// (`bodyComplete = 0`, key consistent) against a message that never overflowed. That
    /// row is then excluded from both admission queries, counted settled, and refused at the
    /// funnel — recoverable only by pull-to-refresh, the next reset, or Smart Reindex.
    ///
    /// `ActiveBodyQueue` specifically, not `BackfillBodyQueue`: the reset clears on both, so
    /// either orders correctly, and both of this function's callers are foreground paths.
    /// (Found by audit.)
    static func markOversizedDurably(headerId: String) async {
        await ActiveBodyQueue.shared.markOversizedDurably(headerId)
    }

    /// Fetch phase: provider.fetchMessage + render body. Provider-bound (network I/O).
    /// Returns the rendered MessageBody and extracted plain text, or an error result.
    struct FetchResult: Sendable {
        let item: Item
        let renderedBody: MessageBody
        let plainText: String?
        let hasAttachments: Bool
        /// True when the message carries a `text/calendar` (invite) part whose ICS
        /// bytes this render had to fetch on demand but couldn't get this attempt
        /// (transient). `process` routes this to retry instead of caching an empty
        /// attachment-only body. See `RenderedBody.hasUnresolvedICS`.
        let hasUnresolvedICS: Bool
        /// RFC 2822 Message-ID of the message the server ACTUALLY returned, carried so
        /// `process` can compare it against the row's before writing
        /// (`BodyAddressGate.identityContradicts`). Both producers hold `fullMessage`;
        /// `process` is the sole consumer and therefore the sole enforcement point — a
        /// check spread across producers can be forgotten by the next producer added.
        /// Optional because RFC 5322 makes `Message-ID` a SHOULD, not a MUST.
        let fetchedRfc822MessageId: String?
    }

    /// Fetch + render a single message. Provider gates concurrency.
    /// Call from a Task — the provider's pool/throttle serializes as needed.
    static func fetch(
        item: Item,
        provider: any EmailProvider
    ) async -> Swift.Result<FetchResult, Result> {
        // PRE-FETCH REFUSAL — before the network round trip, not after it.
        //
        // A refused row deliberately keeps `bodyComplete = 0`, so the queues' `repopulateOnDrain`
        // re-admits it every cycle. Without this check each of those cycles issued a full
        // `provider.fetchMessage` that was then guaranteed to be refused — an unbounded fetch loop
        // for as long as a move stays undrained, at the queue's cycle rate. Refusing here makes a
        // retry cycle cost one indexed point read instead of an IMAP round trip. (Found by audit.)
        //
        // This does NOT replace the write-time refusal: it runs before the fetch, so it cannot see
        // a move that lands while the fetch is in flight.
        if let refusal = await addressRefusal(for: item, fetchedRfc822MessageId: nil) {
            BackgroundSyncLogger.log(
                "[BodyFetch] REFUSED before fetch for \(item.headerId.prefix(30)) folder=\(item.folderPath) uid=\(item.messageId) — \(refusal.logDescription); left bodyComplete=0 for retry")
            return .failure(.retry)
        }
        let t0 = CFAbsoluteTimeGetCurrent()
        do {
            let fullMessage = try await provider.fetchMessage(id: item.messageId, folder: item.folderPath)
            let fetchMs = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
            if fetchMs > 500 {
                print("[BodyFetch] Single fetch slow: \(item.messageId) took \(fetchMs)ms")
            }

            // Diagnostic: log raw provider output when the fetch comes back without
            // any text body. This lets us distinguish a server-side empty (provider
            // returned nothing) from a parser drop (renderer/EmailFilter ate real
            // content) before BodyFetchProcessor.process flips bodyEmptyConfirmed.
            let rawHtmlLen = fullMessage.htmlBody?.count ?? 0
            let rawTextLen = fullMessage.textBody?.count ?? 0
            if rawHtmlLen == 0 && rawTextLen == 0 {
                print("[BodyFetch] RAW empty \(item.messageId) folder=\(item.folderPath) attachments=\(fullMessage.attachments.count) inline=\(fullMessage.inlineImages.count) ics=\(fullMessage.icsData != nil) tookMs=\(fetchMs)")
            }

            // PRE-RENDER REFUSAL — see `addressRefusal`. Rendering persists inline images to disk
            // under this row's content key, so it must not run for a message we are going to refuse.
            if let refusal = await addressRefusal(
                for: item, fetchedRfc822MessageId: fullMessage.header.rfc822MessageId) {
                BackgroundSyncLogger.log(
                    "[BodyFetch] REFUSED before render for \(item.headerId.prefix(30)) folder=\(item.folderPath) uid=\(item.messageId) — \(refusal.logDescription); left bodyComplete=0 for retry")
                return .failure(.retry)
            }

            let fetchAttachment = buildAttachmentFetcher(
                accountId: item.accountId, messageId: item.messageId, folderPath: item.folderPath
            )
            let (renderedBody, plainText, hasUnresolvedICS) = await renderBody(
                headerId: item.headerId,
                fullMessage: fullMessage,
                fetchAttachment: fetchAttachment
            )

            // Diagnostic: parser dropped raw content. If we got bytes from the
            // provider but extractPlainText returned nil/empty, the renderer or
            // EmailFilter is eating real content (e.g., unusual MIME shape, charset
            // decode failure, all-tags HTML). Log a sample so we can reproduce.
            if (rawHtmlLen > 0 || rawTextLen > 0) && (plainText?.isEmpty ?? true) && DebugModeManager.isLoggingEnabled() {
                let renderedLen = renderedBody.htmlContent?.count ?? 0
                let htmlSample = String((fullMessage.htmlBody ?? "").prefix(200))
                let textSample = String((fullMessage.textBody ?? "").prefix(200))
                print("[BodyFetch] PARSER DROPPED \(item.messageId) folder=\(item.folderPath) rawHtmlLen=\(rawHtmlLen) rawTextLen=\(rawTextLen) renderedHtmlLen=\(renderedLen) htmlSample=\(htmlSample.debugDescription) textSample=\(textSample.debugDescription)")
            }

            return .success(FetchResult(
                item: item,
                renderedBody: renderedBody,
                plainText: plainText,
                hasAttachments: !fullMessage.attachments.isEmpty,
                hasUnresolvedICS: hasUnresolvedICS,
                fetchedRfc822MessageId: fullMessage.header.rfc822MessageId
            ))
        } catch {
            let desc = "\(error)"
            if desc.contains("PayloadTooLargeError") {
                // Data-integrity rule 1 ("NEVER mark unfetched content as fetched"):
                // a PayloadTooLargeError is NOT an empty body — the message overflowed
                // the fixed per-binary NIO buffer, so it is honestly INCOMPLETE, not
                // empty. The body demonstrably EXISTS; it is merely bigger than this
                // request could carry, which is the opposite of the one permitted
                // exception (a verified permanent "content confirmed gone").
                //
                // So we must NOT write `bodyEmptyConfirmed = 1` here. That flag is read
                // as "the server confirmed this message has no content", and every body
                // queue / FTS self-heal / embedding repopulate query gates on
                // `bodyEmptyConfirmed = 0`. Setting it retires the row from all of them
                // permanently, leaving the message searchable-but-unopenable — the
                // silent user-message drop the rule exists to prevent.
                //
                // The row instead stays `bodyComplete = 0` / `bodyEmptyConfirmed = 0`
                // (truthfully retryable), and `emptyFetchCount` is deliberately NOT
                // incremented — an oversized body must not consume a strike from the
                // empty-confirmation budget that `process` spends on genuinely empty
                // fetches.
                //
                // Reachable only from the single-item user-open path (`fetchAndProcess`
                // ← `AccountManagerFetch.fetchBody`). The batched queues never
                // reach here — they use `fetchMessagesBatch` + `renderFetched` and own
                // their separate oversize handling.
                //
                // ⚠️ Termination is NOT free on this path, and a comment here used to
                // claim it was ("that path performs no retry loop … so leaving the row
                // retryable cannot spin"). It does loop: `loadBody` ends with
                // `if messageBody == nil { startBodyPoll() }`, and that poll re-fetches
                // every 2 seconds indefinitely — each attempt paying a full
                // TCP + TLS + LOGIN + SELECT, because the overflow marks the folder
                // connection unhealthy so no attempt can reuse it.
                //
                // So this observation is RECORDED, exactly as the body queues record
                // theirs (`Active`/`BackfillBodyQueue.markOversizedDurably`). One
                // statement, the same `AND bodyComplete = 0` guard, the same meaning —
                // and it is what lets the poll's own quarantine gate stop the loop on its
                // next tick. Without it the flag's population would be "whatever the
                // background queues happened to reach first", and the one path that
                // detects the overflow soonest would throw the information away.
                //
                // Still NOT `bodyEmptyConfirmed`, and still no `emptyFetchCount` strike:
                // the row stays truthfully retryable, and pull-to-refresh remains a
                // genuine wire attempt (`MessageDetailViewModel.refetchBody` does not
                // consult the flag).
                //
                // PORT of `v2final`'s `BodyFetchProcessor.fetch` (commit `737aea64f`),
                // which deleted this same write from this same branch.
                if DebugModeManager.isLoggingEnabled() {
                    print("[BodyFetch] Body too large for \(item.messageId) — exceeds buffer (left honestly-incomplete, not marked empty)")
                }
                await markOversizedDurably(headerId: item.headerId)
                return .failure(.payloadTooLarge)
            } else {
                print("[BodyFetch] Fetch failed for \(item.messageId): \(error)")
                return .failure(.retry)
            }
        }
    }

    /// Data returned from process for batched FTS writes.
    ///
    /// 🚨 **TWO IDS ON PURPOSE.** `flushBatch` uses this record for two unrelated
    /// jobs: it writes the body into FTS (keyed by CONTENT) and then flips
    /// `messageHeader.bodyComplete` for the confirmed subset (keyed by the
    /// HEADER). One field served both only while the two were the same string.
    /// Once the content key moves, a content key in the `WHERE id = ?` of that
    /// flip matches nothing — `bodyComplete` never flips and the body is
    /// re-fetched forever.
    struct ProcessedItem: Sendable {
        /// FTS row key. Feeds `SearchIndex.updateBodies` and the confirmed-set
        /// membership test against its return value.
        let contentKey: ContentKey
        /// `messageHeader.id`. Feeds `UPDATE messageHeader … WHERE id = ?` and the
        /// downstream AI queue. **Never** an FTS lookup.
        let headerId: String
        let accountId: String
        let isInInbox: Bool
        let body: String
        let snippet: String
    }

    /// Process phase: write MessageBody to GRDB, return data for batched FTS write.
    /// FTS writes are deferred to the caller for batching (avoids per-item FTS overhead).
    ///
    /// MessageBody is only written when content exists (text or attachments).
    /// Empty fetches require three consecutive attempts before confirming — a single
    /// empty IMAP response can be a partial result (connection drop, BGTask
    /// cancellation, server delay) and must not permanently mark a message as empty.
    static func process(
        fetchResult: FetchResult,
        enableAI: Bool,
        replaceExistingBody: Bool = false
    ) async -> (Result, ProcessedItem?) {
        let item = fetchResult.item
        let dbPool = AppDatabase.dbPool
        let bodyToInsert = fetchResult.renderedBody

        // ── ADDRESS-CORROBORATION GATE (BodyAddressGate) ────────────────────────────
        // THE single enforcement point for every body write. All four callers converge
        // here: `fetch` → `process` (interactive single fetch) and `renderFetched` →
        // `process` (both body queues' batch fetch). Enforcing at the sole CONSUMER
        // rather than at each producer is deliberate — a producer added later cannot
        // forget a check it never has to make.
        //
        // Disposition is ALWAYS `.retry`, never `.confirmedEmpty`: the row keeps
        // `bodyComplete = 0` so it is re-attempted once the address is corroborated again
        // (Data Integrity Rule 1 — never mark unfetched content as fetched; Rule 2 —
        // retries must not mask failures).
        //
        // ⚠️ **What clears the refusal is the row being RE-KEYED, not the epoch being
        // re-stamped.** This comment said "or an ordinary folder sync re-stamps the epoch"
        // until an audit round checked it against the predicate: `addressIsInFlight`
        // compares the stored primary key against one re-minted from
        // `(accountId, folderPath, messageId)`, and the epoch appears in neither side —
        // so stamping it on the still-mismatched old-key row changes this answer by
        // exactly nothing. The clearing events are `finishMove` re-keying on COPYUID
        // proof, or a sync that RE-INSERTS the row at its destination address (which is
        // what `BodyAddressGate`'s own banner says, and it was right while this was not).
        // THE AUTHORITATIVE REFUSAL. Both render paths run this same probe pre-render, but that
        // pass cannot see a move that lands DURING the fetch — this one re-reads the row after the
        // bytes are in hand, so it is the one the invariant rests on. (The pre-render pass exists
        // to stop `renderBody` persisting inline images under this row's content key; it is an
        // optimisation, never the guard.)
        if let refusal = await addressRefusal(for: item, fetchedRfc822MessageId: fetchResult.fetchedRfc822MessageId) {
            BackgroundSyncLogger.log(
                "[BodyFetch] REFUSED body write for \(item.headerId.prefix(30)) folder=\(item.folderPath) uid=\(item.messageId) — \(refusal.logDescription); left bodyComplete=0 for retry")
            return (.retry, nil)
        }

        // Branch on content — only write MessageBody when we have actual content.
        if let plainText = fetchResult.plainText, !plainText.isEmpty {
            // Has text content — write body and return data for FTS batching.
            do {
                try await dbPool.write { db in
                    try persistDisplayableBody(
                        bodyToInsert,
                        item: item,
                        replaceExistingBody: replaceExistingBody,
                        db: db)
                }
            } catch {
                // ADR-IOS-046: suspension aborts are expected + retryable (bodyComplete
                // stays 0 → re-fetched next wake); only log genuine failures. Never
                // mint an FTS candidate for bytes that did not reach the body cache.
                if !error.isDatabaseSuspensionAbort {
                    print("[BodyFetch] MessageBody insert failed for \(item.headerId.prefix(30)): \(error)")
                }
                return (.retry, nil)
            }
            let snippet = EmailFilter.snippetFromPlainText(plainText)
            let processed = ProcessedItem(
                contentKey: ContentKey(rawValue: item.headerId),
                headerId: item.headerId,
                accountId: item.accountId,
                isInInbox: item.isInInbox,
                body: plainText,
                snippet: snippet
            )
            return (.success, processed)

        } else if fetchResult.hasAttachments && !fetchResult.hasUnresolvedICS {
            // No text but has attachments — write body (attachment metadata) and route
            // through flushBatch so FTS gets a placeholder entry and bodyComplete is
            // only set after FTS membership is confirmed (writtenToFts gate).
            // Setting bodyComplete=1 without an FTS row leaves the message permanently
            // stuck in the AI queue (drops with notInFtsIndex).
            //
            // `!hasUnresolvedICS` guard: a calendar invite's text/calendar part is
            // itself an attachment, so `hasAttachments` is true for invites. If its
            // ICS bytes failed to resolve this attempt, falling in here would persist
            // an attachment-only body with empty HTML — the detail view then shows
            // "This message has no content." permanently. Instead let it fall to the
            // retry path below (bounded by emptyFetchCount) so a later fetch renders
            // the invite. (Invites that ALSO carry a text/HTML body have non-empty
            // plainText and were already handled by the first branch.)
            do {
                try await dbPool.write { db in
                    try persistDisplayableBody(
                        bodyToInsert,
                        item: item,
                        replaceExistingBody: replaceExistingBody,
                        db: db)
                }
            } catch {
                if !error.isDatabaseSuspensionAbort {
                    print("[BodyFetch] Attachment-only MessageBody insert failed for \(item.headerId.prefix(30)): \(error)")
                }
                return (.retry, nil)
            }
            let placeholder = "[attachment]"
            let processed = ProcessedItem(
                contentKey: ContentKey(rawValue: item.headerId),
                headerId: item.headerId,
                accountId: item.accountId,
                isInInbox: item.isInInbox,
                body: placeholder,
                snippet: placeholder
            )
            return (.success, processed)

        } else {
            // No usable text/HTML body. Two cases land here:
            //  (a) a genuinely empty message (no text, no attachments), or
            //  (b) a calendar invite whose ICS bytes we couldn't resolve this attempt
            //      (`hasUnresolvedICS`) — see the guard on the branch above.
            // BOTH are treated as retryable: guard against false empties (partial IMAP
            // response, BGTask cancellation, transient ICS attachment-fetch failure) by
            // incrementing emptyFetchCount and only confirming empty after 2+ misses.
            // bodyComplete stays 0 so the background queue re-enqueues for retry. We
            // must NEVER persist an empty/attachment-only body for an unresolved invite.
            if fetchResult.hasUnresolvedICS && DebugModeManager.isLoggingEnabled() {
                print("[BodyFetch] Unresolved ICS for \(item.headerId.prefix(30)) — retrying, will not cache empty body")
            }
            let currentCount = (try? await dbPool.read { db in
                try Int.fetchOne(db, sql: "SELECT emptyFetchCount FROM messageHeader WHERE id = ?", arguments: [item.headerId])
            }) ?? 0

            if currentCount >= 2 {
                // Third+ empty fetch — confirmed empty. Write empty body for UI and set flags.
                do {
                    try await dbPool.write { db in
                        if replaceExistingBody {
                            try bodyToInsert.save(db)
                        } else {
                            try bodyToInsert.insert(db, onConflict: .ignore)
                        }
                        try db.execute(
                            sql: """
                                UPDATE messageHeader
                                SET bodyEmptyConfirmed = 1,
                                    bodyComplete = 1,
                                    bodyMetadataOversized = 0,
                                    emptyFetchCount = emptyFetchCount + 1,
                                    summaryBlurb = 'This message has no content.',
                                    actionTag = ?,
                                    tagSortOrder = ?,
                                    embeddingComplete = 1
                                WHERE id = ?
                            """,
                            arguments: [ActionTag.delete.rawValue, ActionTag.delete.sortOrder, item.headerId]
                        )
                    }
                } catch {
                    if !error.isDatabaseSuspensionAbort {
                        print("[BodyFetch] Confirmed-empty flag write failed for \(item.headerId.prefix(30)): \(error)")
                    }
                    // Confirmation is an acknowledgement of the combined body+flag
                    // transaction. A suspension abort leaves the message retryable.
                    return (.retry, nil)
                }
                return (.confirmedEmpty, nil)
            } else {
                // First empty fetch — increment counter but leave bodyComplete = 0
                // so the background queue re-enqueues for retry on next cycle.
                // Don't write empty body or set bodyEmptyConfirmed.
                print("[BodyFetch] First empty fetch for \(item.headerId.prefix(30)) — will confirm on next attempt")
                do {
                    try await dbPool.write { db in
                        try db.execute(
                            sql: "UPDATE messageHeader SET emptyFetchCount = emptyFetchCount + 1 WHERE id = ?",
                            arguments: [item.headerId]
                        )
                    }
                } catch {
                    if !error.isDatabaseSuspensionAbort {
                        print("[BodyFetch] emptyFetchCount increment failed for \(item.headerId.prefix(30)): \(error)")
                    }
                }
                return (.retry, nil)
            }
        }
    }

    private static func persistDisplayableBody(
        _ body: MessageBody,
        item: Item,
        replaceExistingBody: Bool,
        db: Database
    ) throws {
        guard replaceExistingBody else {
            try body.insert(db, onConflict: .ignore)
            return
        }

        try body.save(db)
        // Keep the old body visible until the complete replacement is durable.
        // The existing FTS tail reconfirms bodyComplete after indexing succeeds.
        try db.execute(
            sql: """
                UPDATE messageHeader
                SET summaryBlurb = CASE
                        WHEN bodyEmptyConfirmed = 1 AND summaryBlurb = 'This message has no content.'
                            THEN NULL
                        ELSE summaryBlurb
                    END,
                    actionTag = CASE
                        WHEN bodyEmptyConfirmed = 1 AND actionTag = ? THEN NULL
                        ELSE actionTag
                    END,
                    tagSortOrder = CASE
                        WHEN bodyEmptyConfirmed = 1 AND actionTag = ? THEN 99
                        ELSE tagSortOrder
                    END,
                    bodyComplete = 0,
                    bodyEmptyConfirmed = 0,
                    emptyFetchCount = 0,
                    embeddingComplete = 0
                WHERE id = ?
            """,
            arguments: [
                ActionTag.delete.rawValue,
                ActionTag.delete.rawValue,
                item.headerId,
            ]
        )
    }

    /// Flush a batch of processed items to FTS + GRDB flags in one go.
    /// Batching FTS writes avoids per-item FTS5 index maintenance overhead.
    ///
    /// `aiWindowExempt` (ADR-IOS-078 pathway regating): this function is
    /// DUAL-ORIGIN. The gated (default) bucket has TWO production callers, both
    /// sync-origin and window-gated at `ActiveAIQueue.enqueue`, which is the
    /// install-flood bound: `ActiveBodyQueue`'s background flush, and
    /// `InboxViewModel`'s snippet-loader Tier-2 network fetch (list-scroll
    /// driven — exactly the unbounded shape the flood bound exists for).
    /// (`BackfillBodyQueue` passes `enableAI: false` and never reaches AI at
    /// all.) The user-open priority fetch
    /// (`fetchAndProcess` ← `AccountManagerFetch.fetchBody`) passes `true`: a
    /// manual open is window-exempt on the arm where the body had to be fetched
    /// from the server first (round-1 review finding — the first cut exempted
    /// only `processOpenedMessage`'s already-cached arm).
    ///
    /// SCOPE — this exempts the open that performs its OWN fetch; it is NOT
    /// "exempt in every body state". When `ActiveBodyQueue` already owns the
    /// fetch (`MessageDetailViewModel.loadBody` sees `isQueuedOrInFlight` and
    /// polls), the body lands via the DEFAULT gated flush above and
    /// `startBodyPoll`'s `adoptReadyBody` displays it without re-triggering AI.
    /// That residual is the coordinator-deferred body-arrival auto-trigger,
    /// Retry-recoverable — see ADR-IOS-078 and the IOS-AI-004 amendment.
    static func flushBatch(_ items: [ProcessedItem], enableAI: Bool, aiWindowExempt: Bool = false) async {
        guard !items.isEmpty else { return }
        let t0 = CFAbsoluteTimeGetCurrent()
        let dbPool = AppDatabase.dbPool

        // 1. Batch FTS write — returns which headerIds were actually written.
        // Items not yet in FTS index are skipped (bodyComplete stays 0 for retry).
        let tFts = CFAbsoluteTimeGetCurrent()
        let ftsBuffer = items.map { (contentKey: $0.contentKey, body: $0.body) }
        let writtenToFts: Set<ContentKey>
        do {
            writtenToFts = try await SearchIndex.shared.updateBodies(ftsBuffer)
        } catch {
            // ADR-IOS-046: a suspension abort is expected + benign here — bodyComplete
            // stays 0, the next wake's repopulate retries. Only log real failures.
            if !error.isDatabaseSuspensionAbort {
                print("[BodyFetch] Batch FTS write failed (\(items.count) items): \(error)")
            }
            // Items already have MessageBody in GRDB. bodyComplete stays 0.
            // Next repopulate will retry.
            return
        }
        let ftsMs = Int((CFAbsoluteTimeGetCurrent() - tFts) * 1000)

        let skippedCount = items.count - writtenToFts.count
        if skippedCount > 0 {
            let skippedItems = items.filter { !writtenToFts.contains($0.contentKey) }
            let accountIds = Set(skippedItems.map(\.accountId)).sorted().joined(separator: ",")
            print("[BodyFetch] flushBatch: \(skippedCount)/\(items.count) items not in FTS yet — bodyComplete deferred (accounts=[\(accountIds)])")
        }

        // 2. Batch GRDB flag update (snippets + bodyComplete) — ONLY for items written to FTS.
        // Items skipped by FTS keep bodyComplete=0 so body fetch queue retries them.
        let tDb = CFAbsoluteTimeGetCurrent()
        // ⚠ Membership is tested on the CONTENT key (that is what `updateBodies`
        // returns); the flip below binds the HEADER id. Do not collapse the two.
        let confirmedItems = items.filter { writtenToFts.contains($0.contentKey) }
        do {
            try await dbPool.write { db in
                for item in confirmedItems {
                    // Reset missFetchCount=0 on success: a prior run may have accumulated
                    // misses against this header (e.g. IMAP flap). Now that we have real
                    // content, the miss chain is broken — start counting fresh next time.
                    // `bodyMetadataOversized = 0`: a body we just fetched is positive
                    // proof that refutes the recorded overflow observation. Cleared
                    // HERE, at the success write, not at each reader — the flag is
                    // read by the body-queue admission queries, by backfill progress
                    // and by the detail view, and a stale one makes an evicted body
                    // unopenable and lets Smart Reindex un-complete a healthy row.
                    // Rides the existing UPDATE exactly as `missFetchCount = 0` does.
                    try db.execute(
                        sql: """
                            UPDATE messageHeader
                            SET snippet = ?, bodyComplete = 1, missFetchCount = 0,
                                bodyMetadataOversized = 0
                            WHERE id = ?
                            """,
                        arguments: [item.snippet, item.headerId]
                    )
                }
            }
        } catch {
            if !error.isDatabaseSuspensionAbort {
                print("[BodyFetch] flushBatch snippet/bodyComplete write failed (\(confirmedItems.count) items): \(error)")
            }
        }
        let dbMs = Int((CFAbsoluteTimeGetCurrent() - tDb) * 1000)

        // 3. Enqueue downstream processing — only for items actually written to FTS.
        for item in confirmedItems {
            if enableAI && item.isInInbox {
                await ActiveAIQueue.shared.enqueue(
                    headerId: item.headerId, accountId: item.accountId,
                    windowExempt: aiWindowExempt)
            }
            if enableAI {
                await ActiveEmbeddingQueue.shared.enqueue(headerId: item.headerId)
            } else {
                await BackfillEmbeddingQueue.shared.enqueue(headerId: item.headerId)
            }
        }

        let totalMs = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
        print("[BodyFetch] flushBatch: \(items.count) items (\(writtenToFts.count) written) in \(totalMs)ms (fts=\(ftsMs)ms, db=\(dbMs)ms)")
    }

    /// Render a pre-fetched FullMessageInfo into a FetchResult.
    /// Used by batch fetch path — the provider fetch already happened in bulk.
    /// Handles CID resolution, ICS calendar parsing, plain text extraction.
    /// One read for the `process` gate, on a path that is already DB-bound.
    ///
    /// Reads the row's CURRENT epoch rather than trusting anything carried on `Item`: the
    /// window this closes is precisely one in which the row changes underneath an
    /// in-flight fetch, so a snapshot taken at enqueue time would classify stale state.
    /// (That admission-vs-execution skew is a recorded trap —
    /// `feedback_admission_execution_classification_skew`.)
    /// The gate's probe. Runs at TWO points, deliberately:
    ///   - **pre-render**, with `fetchedRfc822MessageId: nil` — so a refused message never reaches
    ///     `renderBody`, which would otherwise persist its inline images to disk under this row's
    ///     content key via `BodyAssetStore.makeInlineImageWriter` before anything could refuse the
    ///     write. Those files outlive the refusal, and a later legitimate fetch that references a
    ///     colliding CID but fails to re-fetch that one attachment would render the STRANGER's
    ///     image inside this message — a wrong-content display that no sync undoes. Preventing the
    ///     write is cheaper than reasoning about the collision. (Found by audit.)
    ///   - **at write time**, with the real fetched Message-ID — the AUTHORITATIVE refusal. The
    ///     pre-render call is an optimisation and cannot be relied on: it runs before the row is
    ///     re-read at write time, so it cannot see a move that lands during the fetch.
    ///
    /// A `nil` fetched id disarms only the identity half (absence of evidence, by design), so the
    /// pre-render pass still enforces both address halves.
    private static func addressRefusal(
        for item: Item, fetchedRfc822MessageId: String?
    ) async -> BodyAddressGate.Refusal? {
        struct Probe {
            let id: String
            let folderPath: String
            let messageId: String
            let storedRfc: String?
            let provider: AccountProvider
        }
        let probe: Probe?
        do {
            // `dbPool.pool` (RAW), not `dbPool.read`: `PrioritizedDatabase.read` awaits
            // `NSEDataBridge.mergeIfStagingPending()` first, which would put a potentially
            // multi-second NSE merge in front of EVERY body write — a hot path that runs once per
            // fetched message. The gate wants the DURABLE row state anyway: the fields it reads
            // (`folderPath`, `messageId`, `rfc822MessageId`) are written by the move path, and the
            // NSE never moves messages, so a pending merge cannot change this answer. A row that
            // exists only in staging reads as missing here ⇒ `.verificationUnavailable` ⇒ `.retry`,
            // which is the fail-closed direction and clears once the merge commits. (Found by audit.)
            probe = try await AppDatabase.dbPool.pool.read { db -> Probe? in
                guard let header = try MessageHeader.fetchOne(db, key: item.headerId),
                      let account = try Account.fetchOne(db, key: item.accountId)
                else { return nil }
                // `header.folderPath`, NOT `item.folderPath`: the Item is a snapshot taken
                // at enqueue time, and the window this closes is precisely one in which the
                // row moves underneath an in-flight fetch.
                return Probe(
                    id: header.id,
                    folderPath: header.folderPath,
                    messageId: header.messageId,
                    storedRfc: header.rfc822MessageId,
                    provider: account.provider)
            }
        } catch {
            // Suspension aborts and transient read failures land here. An unknown answer
            // is retryable, never authoritative — refuse rather than write blind.
            return .verificationUnavailable
        }
        // Header or account gone mid-fetch: nothing left to corroborate against, and the
        // body would be orphaned anyway. Refuse; the queue's scans no longer select a
        // deleted header, so this does not spin.
        guard let probe else { return .verificationUnavailable }
        // PROVENANCE. These bytes were fetched against `item.folderPath` / `item.messageId`.
        // The key test below compares the row's key to the row's CURRENT folder, which is blind
        // to a row that moved and moved BACK while this fetch was in flight: an undo annihilating
        // an unattempted move restores the source `folderPath`, so the key agrees again — yet the
        // bytes in hand were fetched from the destination address and belong to a stranger.
        // Comparing what we fetched against what the row now is closes that independently.
        // Scoped to the same hazard as the rest of the gate: where a stale address MISSES rather
        // than resolving, bytes fetched under the old address are still this message's bytes
        // (Gmail/Graph fetch by opaque id, not by folder+UID), so refusing would only cost a
        // needless retry on every label move that overlaps a body fetch — a common pair.
        if BodyAddressGate.addressCanResolveToAnotherMessage(
            provider: probe.provider, accountId: item.accountId),
           probe.folderPath != item.folderPath || probe.messageId != item.messageId {
            return .fetchProvenanceMismatch
        }
        return BodyAddressGate.refusal(
            id: probe.id,
            accountId: item.accountId,
            folderPath: probe.folderPath,
            messageId: probe.messageId,
            provider: probe.provider,
            storedRfc822MessageId: probe.storedRfc,
            fetchedRfc822MessageId: fetchedRfc822MessageId)
    }

    static func renderFetched(
        item: Item,
        fullMessage: FullMessageInfo
    ) async -> Swift.Result<FetchResult, Result> {
        // PRE-RENDER REFUSAL — see `addressRefusal`. Rendering persists inline images to disk
        // under this row's content key, so it must not run for a message we are going to refuse.
        if let refusal = await addressRefusal(for: item, fetchedRfc822MessageId: fullMessage.header.rfc822MessageId) {
            BackgroundSyncLogger.log(
                "[BodyFetch] REFUSED before render for \(item.headerId.prefix(30)) folder=\(item.folderPath) uid=\(item.messageId) — \(refusal.logDescription); left bodyComplete=0 for retry")
            return .failure(.retry)
        }
        let t0 = CFAbsoluteTimeGetCurrent()

        let fetchAttachment = buildAttachmentFetcher(
            accountId: item.accountId, messageId: item.messageId, folderPath: item.folderPath
        )
        let (renderedBody, plainText, hasUnresolvedICS) = await renderBody(
            headerId: item.headerId,
            fullMessage: fullMessage,
            fetchAttachment: fetchAttachment
        )

        let renderMs = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
        if renderMs > 200 {
            print("[BodyFetch] renderFetched: \(item.messageId) slow render: \(renderMs)ms")
        }

        return .success(FetchResult(
            item: item,
            renderedBody: renderedBody,
            plainText: plainText,
            hasAttachments: !fullMessage.attachments.isEmpty,
            hasUnresolvedICS: hasUnresolvedICS,
            fetchedRfc822MessageId: fullMessage.header.rfc822MessageId
        ))
    }

    /// Combined fetch + process for single-item callers (user-open path).
    /// Flushes FTS immediately (no batching needed for single items).
    ///
    /// `aiWindowExempt`: see `flushBatch`. The sole production caller is
    /// `AccountManagerFetch.fetchBody` — every path into it is a user-driven
    /// detail-view open — which passes `true` so the open's AI enqueue is
    /// window-exempt (ADR-IOS-078 pathway regating).
    static func fetchAndProcess(
        item: Item,
        provider: any EmailProvider,
        enableAI: Bool,
        aiWindowExempt: Bool = false,
        replaceExistingBody: Bool = false
    ) async -> Result {
        let fetchResult = await fetch(item: item, provider: provider)
        switch fetchResult {
        case .success(let result):
            let (outcome, processed) = await process(
                fetchResult: result,
                enableAI: enableAI,
                replaceExistingBody: replaceExistingBody)
            if let processed {
                await flushBatch([processed], enableAI: enableAI, aiWindowExempt: aiWindowExempt)
            }
            return outcome
        case .failure(let result):
            return result
        }
    }

    // MARK: - Body Rendering

    /// Render a FullMessageInfo into a MessageBody.
    /// Delegates to the shared `BodyRenderer` — single source of truth for CID
    /// resolution, ICS handling, and plain-text extraction. Main app supplies an
    /// `ICSBuilder`-backed icsRenderer and the provider-specific attachment fetcher.
    static func renderBody(
        headerId: String,
        fullMessage: FullMessageInfo,
        fetchAttachment: (@Sendable (String, String?) async throws -> Data)? = nil
    ) async -> (body: MessageBody, plainText: String?, hasUnresolvedICS: Bool) {
        // Convert main-app FullMessageInfo → shared RawBodyIngredients.
        let sharedAttachments = fullMessage.attachments.map {
            AttachmentRef(
                filename: $0.filename, contentType: $0.contentType,
                section: $0.section, size: $0.size, encoding: $0.encoding
            )
        }
        let sharedInlineImages = fullMessage.inlineImages.map {
            InlineImageRef(contentId: $0.contentId, contentType: $0.contentType, data: $0.data)
        }
        let ingredients = RawBodyIngredients(
            rawHTML: fullMessage.htmlBody, rawText: fullMessage.textBody,
            attachments: sharedAttachments, inlineImages: sharedInlineImages,
            icsData: fullMessage.icsData
        )

        // Main-app ICS renderer: parse + build invite HTML via ICSBuilder.
        let icsRenderer: BodyRenderer.ICSRenderer = { icsText in
            guard let invite = ICSBuilder.parseIncoming(icsText) else { return nil }
            return ICSBuilder.buildIncomingInviteBody(invite)
        }

        // ⚠ STAGE E1: `renderBody` receives a `messageHeader.id` and uses it as the
        // CONTENT key for both the asset store and the `MessageBody` row it builds.
        // `BodyFetchProcessor.Item` (which is where `headerId` comes from) carries no
        // `rfc822MessageId` and no provider space, so this cannot mint through
        // `ContentKey.forHeader` yet — plumbing those two fields onto `Item` is a
        // prerequisite for E1. Byte-identical today.
        let contentKey = ContentKey(rawValue: headerId)

        // Single source of the writer — same factory the NSE clients use.
        // Both targets call `BodyAssetStore.makeInlineImageWriter(forContentKey:)`,
        // so persisted assets land at the same paths and the rendered HTML
        // references identical `tabmail-asset://` URLs across targets.
        let inlineImageWriter = BodyAssetStore.makeInlineImageWriter(forContentKey: contentKey)
        let rendered = await BodyRenderer.render(
            ingredients: ingredients,
            attachmentFetcher: fetchAttachment,
            icsRenderer: icsRenderer,
            inlineImageWriter: inlineImageWriter
        )

        // `rendered.htmlContent` is already display-ready (BodyRenderer is the single
        // conversion authority — plain-text bodies were converted to HTML there), so
        // create() just stores it: no re-conversion, no double-escape. The canonical
        // plain text for snippet/FTS is `rendered.textContent`, returned to the caller
        // (NOT re-derived from htmlContent, which would round-trip plain→HTML→plain).
        var body = MessageBody.create(contentKey: contentKey, htmlBody: rendered.htmlContent)
        // Diagnostic (debug-gated, no-op in prod): flag if a double-escaped body ever
        // reaches storage. Captured on the `.bodyRender` channel of the single
        // tabmail.log (`AppLogStore.read(channel: .bodyRender)`), exported by
        // DebugMenu › Logs › "App Logs".
        BackgroundSyncLogger.diagnoseStoredBody(source: "BodyFetch", headerId: headerId, htmlContent: body.htmlContent)
        if !fullMessage.attachments.isEmpty {
            body.attachmentsJSON = String(data: (try? JSONEncoder().encode(fullMessage.attachments)) ?? Data(), encoding: .utf8)
        }
        body.icsText = rendered.icsText
        return (body, rendered.textContent, rendered.hasUnresolvedICS)
    }

    // MARK: - Helpers

    private static func buildAttachmentFetcher(
        accountId: String, messageId: String, folderPath: String
    ) -> @Sendable (String, String?) async throws -> Data {
        return { section, encoding in
            let queue = await AccountManager.shared.workQueues[accountId]
            guard let queue else { throw ProviderError.notConnected }
            let provider = queue.provider

            return try await queue.execute(priority: .bodyFetch) {
                if let imap = provider as? IMAPProvider {
                    return try await imap.fetchAttachment(messageId: messageId, folder: folderPath, section: section, encoding: encoding)
                } else if let gmail = provider as? GmailProvider {
                    return try await gmail.fetchAttachment(messageId: messageId, attachmentId: section)
                } else if let exchange = provider as? ExchangeProvider {
                    return try await exchange.fetchAttachment(messageId: messageId, attachmentId: section)
                }
                throw ProviderError.notConnected
            }
        }
    }
}
