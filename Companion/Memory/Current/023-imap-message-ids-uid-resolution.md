<!-- COMPANION-CURRENT-NOTE-BEGIN -->
> **⚠️ CURRENT ROUTING NOTE (2026-08-05) — the `markRead`/`markUnread` bullet below is STALE and its
> mechanism NO LONGER EXISTS. Read this before that bullet; the body is preserved unedited because
> its bytes are hash-pinned in `Companion/Memory/manifest.tsv` and reconstruct `PROJECT_MEMORY.md`.**
>
> The bullet beginning *"**Self-send appears as two `MessageHeader` rows (INBOX + Sent) with the same
> `rfc822MessageId`.**"* asserts **in the present tense** that *"`markRead`/`markUnread` use
> `expandWithSiblingsByRfc822` … to flip BOTH rows in one transaction, decrement BOTH folders'
> `unreadCount`, and queue ONE `PendingOperation` per folder"*, and that *"Sync is the safety net if
> rfc822 is missing."* **Every clause of that is now false.**
>
> `AccountManager.expandWithSiblingsByRfc822` was **REMOVED** by `065a827ca` ("Bind ordinary IMAP
> actions to UID epochs") as a deliberate **D4 SUBTRACT** — the plan records it as *"⚑ NO REFERENCE —
> INVENTED: remove `expandWithSiblingsByRfc822` from ordinary IMAP"*. It had **3 production + 8 test**
> hits at shipped `07a4bb703` (`git grep -c 'expandWithSiblingsByRfc822' 07a4bb703 -- '*.swift'`);
> at `1d1557187` there is **no declaration anywhere in the tree** (`rg -n 'func
> expandWithSiblingsByRfc822' TabMail/ Shared/ TabMailNotificationService/ TabMailTests/` → exit 1).
>
> **What the code does now.** `markRead`/`markUnread` group **only the rows the user actually
> gestured on**, by `accountId|folderPath`, and admit each group through
> `AccountManager.admittedOrdinaryActionTargets`, which requires a live, equal `observedUidValidity`
> and keys the `PendingOperation` by `admission.providerIds` — the provider's **native** address.
> Shipped, by contrast, expanded to `stableId`s (the RFC) and queued the fan-out.
>
> **THE BEHAVIOUR DELTA, registered because it was previously unregistered:** on plain IMAP, marking
> the INBOX copy of a self-sent message read **no longer flips the same-RFC Sent copy in the same
> gesture**. Registered as `IOS-IMAP-011` in `KNOWN_ISSUES.md`.
>
> ⚠️ **Do NOT repeat the phrasing that "sync reconciles" it.** We no longer issue the sibling
> `STORE`, so there is no server-side flag change for a later sync to observe. This is a **deliberate
> feature removal on D4 grounds**, not a defect and not a dropped intention: the user's gesture
> targeted the row they acted on and it executed. Two same-RFC rows in different folders are
> **different messages**, and expanding a mutation across them by RFC is precisely what D4 bans
> (ADR-IOS-068 clause 2; the fan-out defect it closed is `IOS-IMAP-002`).
>
> **Reintroducing RFC-keyed expansion on any mutation path is BANNED** — it re-opens exactly the hole
> `IOS-IMAP-002` closed and is a D4 violation. Equally, do not read the current non-expanding
> behaviour as a regression to be "restored".
<!-- COMPANION-CURRENT-NOTE-END -->

### IMAP Message IDs & UID Resolution
- `info.messageId` from SwiftMail is often `nil` (many messages lack Message-ID header)
- Fallback chain: `info.messageId ?? UID ?? sequenceNumber` — stored in `MessageHeader.messageId`
- `resolveUID()` helper in IMAPProvider: numeric IDs → construct `UIDSet(UID(...))` directly; non-numeric → search by `Message-ID` header
- All IMAP operations use `resolveUID()` — never raw `server.search(criteria: [.header("Message-ID", id)])`
- **CRITICAL: IMAP MOVE changes UIDs.** When a message is moved between folders via IMAP, it gets a NEW UID in the destination folder. The old UID is invalid. For any undo/move-back operation on IMAP accounts, ALWAYS use `rfc822MessageId` (RFC 2822 Message-ID header) — NEVER the numeric UID. This ensures `resolveUID` does a header search in the destination folder and finds the correct UID. Gmail uses stable IDs (no fix needed).
- **Stale detection UID remap check**: Before deleting a "stale" local message (not in remote set), fullSync checks if any NEW remote message in the same folder has matching `rfc822MessageId`. If found, it's a UID remap (not stale) — local row is migrated in-place to preserve body/AI cache.
- **Self-send appears as two `MessageHeader` rows (INBOX + Sent) with the same `rfc822MessageId`.** Gmail (and other shared-storage IMAP servers) represents this as one underlying message; iOS materializes it as two rows keyed by `folderId`. `markRead`/`markUnread` use `expandWithSiblingsByRfc822` (in `AccountManagerActions.swift`) to flip BOTH rows in one transaction, decrement BOTH folders' `unreadCount`, and queue ONE `PendingOperation` per folder. For Gmail the second op is a no-op server-side; for plain IMAP it correctly issues a `STORE \Seen` against the sibling folder's UID. Sync is the safety net if rfc822 is missing.
- **`MessageHeader.id` vs `stableId` — CRITICAL distinction**:
  - `MessageHeader.id` (GRDB PK) = `"{accountId}:{folderPath}:{messageId}"`. For IMAP, `messageId` = UID which **changes on MOVE**. For Gmail/Exchange, `messageId` is a stable provider ID.
  - `MessageHeader.stableId` (computed) = `rfc822MessageId` for IMAP (survives folder moves), `messageId` for Gmail/Exchange (already stable). Falls back to raw UID if no rfc822MessageId.
  - **Rule**: Any key that must survive folder moves (PendingOperation messageIds, chat session keys, draft keys) MUST use `stableId`, NEVER `message.id`. Using `message.id` causes orphaned records when IMAP messages move folders.
  - **Pattern**: `"{accountId}:{stableId}"` for unique-per-account keys (chat sessions use `"msg:{accountId}:{stableId}"`, drafts use `"reply:{accountId}:{stableId}"`).
  - See `MessageHeader.swift:108` for the stableId implementation.
- **Body architecture (CORRECTED 2026-06-23 — the old "backfill is FTS-only / MessageBody only on open" note was STALE and wrong)**:
  1. **FTS** (`fts.db`) = persistent plain-text store for search. Written by `BodyFetchProcessor.flushBatch`.
  2. **MessageBody (`tabmail.sqlite`, HTML)** = the on-disk body cache. **Written at DOWNLOAD time, not just on open.** `BodyFetchProcessor.process` (`bodyToInsert.insert`, `BodyFetchProcessor.swift:150/182/218`) persists it, and that processor is shared by **all** body-fetch paths: `ActiveBodyQueue` (inbox, enqueued right after each sync via `SyncEngine*.enqueueBatch(newHeaders)`), `BackfillBodyQueue` (all other folders), `AccountManagerFetch.fetchBody` (on open), AND — since 2026-06-23 — the inbox **snippet loader** (`InboxViewModel.loadSnippetBatch` Tier 2: it already downloads the whole body for the snippet, so it now routes it through `BodyFetchProcessor` to cache it instead of discarding — this fixed the "first open re-downloads + renders slowly" report; `enableAI = isInInbox` mirrors the Active/Backfill split).
  3. **Eviction is OVER-BUDGET ONLY** — `SyncEngine.runPruneIfOverBudget` deletes bodies (then headers, oldest-first, keeping `floorPerFolder`) only when `StorageEstimator.isOverBudget()` (2 GB default). There is NO aggressive TTL eviction (`evictStaleBodies` no longer exists). So a fetched body stays cached until the budget is hit.
  4. **The "open re-downloads" you may still see is a RACE** (open before the background body fetch reached that message) or a body pruned when over budget — NOT a missing-cache bug. `loadBody` checks `MessageBody.fetchOne` first and skips the network if present.
  5. **Memory** = zero bodies in memory except the one currently displayed.
- Snippets derived from body text during FTS indexing / body processing. Failed fetches get sentinel `" "` to prevent retry.
- **NEVER fetch bodies inline during sync or backfill header insertion** — body FTS indexing runs as bounded background pass after header backfill completes.
- **Calendar invite ICS resolution is on-demand for Gmail/Exchange + IMAP-batch (race fixed 2026-05-26)**: A `text/calendar` part is classified as an *attachment*, and its ICS bytes are resolved via a SEPARATE network round-trip (`attachmentFetcher`) for Gmail/Exchange (their `FullMessageInfo.icsData` is always `nil`) and for IMAP *batch* fetch when the pipelined part-fetch drops the calendar section. The IMAP *single* user-open fetch (`fetchMessageOnConnection`) reliably prefetches all parts via `fetchAllMessageParts`, which is why **reloading an invite fixes the display**. Previously `BodyRenderer.render` swallowed that on-demand fetch failure with `try?` → empty HTML → `BodyFetchProcessor.process` hit the `else if hasAttachments` branch (true, the invite IS an attachment) → persisted an empty body + `bodyComplete=1` → MessageCardView showed "This message has no content." permanently. Fix: `RenderedBody.hasUnresolvedICS` is set when this render *owned* ICS resolution (fetcher present, no prefetch) but got no usable bytes (`do/catch`, not `try?`); `process` excludes that case from the attachment-only write (`hasAttachments && !hasUnresolvedICS`) and routes it to the retry path bounded by the 3-strike `emptyFetchCount`. NSE passes no fetcher → never flagged (it defers ICS to the main app by design). Tests: `BodyRendererTests` `unresolvedICSWhenFetchThrows` / `resolvedICSOnDemand` / `noFlagWithoutFetcher`.
