
## ADR-IOS-036: Action Tags Are Local-Only (Supersedes ADR-IOS-004)

**Context:** Since the original cross-instance tag-sync design (ADR-IOS-004), iOS and TB had been writing `tm_*` IMAP keywords, Gmail labels, and Exchange categories so the other instance could adopt the classification without re-running the LLM. Two problems accumulated:

1. **User-visible pollution.** Gmail web/mobile showed `tm_reply` / `tm_archive` / `tm_delete` / `tm_none` in the label sidebar. Outlook desktop/web/mobile showed those same strings as colored category chips on every triaged message plus a master-category-list entry. Other IMAP clients (Apple Mail, plain TB) surfaced the strings as raw keyword flags. Users who paid attention to their label/category UI saw TabMail internals leaking through.
2. **Redundant with Device Sync.** The device-sync WSS relay already exchanges `{summary, action, reply}` between connected peers via `ai_cache_probe` — this fully covers the "both devices online" case without any server-side label writes.

The only gap Device Sync leaves uncovered is the *async* cross-device case: device A classifies a message, device B comes online hours later while device A is offline. Previously device B would pick up the classification via IMAP keyword / Gmail label. Now device B runs the LLM independently — one extra LLM call per miss.

**Decision:**

1. iOS no longer reads or writes `tm_*` IMAP keywords / Gmail labels / Exchange categories. All provider `setActionTag` methods are no-ops. All provider parse paths set `actionTag = nil`; the local `MessageAICache` restore + AI classification pipeline is the only populator of `MessageHeader.actionTag`.
2. `GmailProvider.fetchFolders` no longer provisions `tm_*` labels via REST, does not build a `tagLabelMap`, and does not hide legacy `tm_*` labels. Legacy labels are filtered out of the folder list via `UserLabelStore.shouldExcludeLabel` (which already matched the `tm_` prefix for user-label visibility).
3. `ExchangeProvider` drops `tagCategoryMap`. The category → ActionTag resolution in `parseGraphMessage` is removed.
4. `IMAPProvider.buildMessageHeaderInfo` stops extracting ActionTag from IMAP keywords.
5. `NSEDataBridge` stops mirroring the Gmail `tagLabelMap`. `resolveServerActionTag` returns nil unconditionally — the NSE merge falls through to the AI-computed tag on the staging row.
6. `SyncEngineMaintenance.sweepStaleActionTags` keeps clearing local `actionTag` on non-inbox messages (inbox-scoped UX contract) but no longer issues server-side `setActionTag(nil)` calls.
7. `AccountManagerQueue` `.setTag` / `.removeTag` drain branches become explicit no-ops — legacy queued ops flush cleanly, no provider call.
8. **Inbox-exit cleanup for legacy pollution.** Whenever a message moves OUT of the inbox (archive, delete, user-initiated move), each provider strips any residual `tm_*` labels/keywords/categories inline with the move. This is the natural decay mechanism for pre-ADR pollution: as users triage, their on-server `tm_*` count drops to zero. Implementation per provider:
   - **Gmail:** `fetchFolders` records `legacyTmLabelIds: Set<String>` (any label whose name starts with `tm_`). `move()` includes these IDs in the existing `messages.modify` `removeLabelIds` array when `source == "INBOX"`. Zero extra round-trip.
   - **IMAP:** `idempotentMove` issues a `STORE -FLAGS (tm_reply tm_archive tm_delete tm_none)` on the source UIDs before the MOVE when `source.uppercased() == "INBOX"`. One extra round-trip. Best-effort — a STORE failure logs and continues (the move must not be blocked by cleanup).
   - **Exchange:** `move()` calls `stripLegacyCategories(id:)` before `moveMessage` when `source == inboxFolderId`. That helper does a `$select=categories` GET, filters out `tm_*`, and PATCHes the message if anything changed. Two extra round-trips worst case, skipped entirely if no `tm_*` categories present. Best-effort — a strip failure logs and continues.
9. ADR-IOS-004 is marked **superseded** by this ADR.

**What still works:**

- `MessageHeader.actionTag` continues to drive the UI chip everywhere it does today — inbox row chip, message detail, thread bubbles, tag sort order.
- AIService classification still writes `MessageHeader.actionTag` + `MessageAICache.actionTag` via `AccountManagerAI.processSingleMessage` / `setManualTag`.
- User manual override (long-press menu → pick action) still flows: `setManualTag` writes local state, queues a PendingOperation (which now drains to a no-op — intentional), and updates `MessageAICache` for persistence across delete/re-insert.
- Device Sync probe (`DeviceSyncService.probeAICache`) still serves action/summary/reply between peers on cache miss.
- `ActionTag.imapKeyword` / `fromIMAPKeyword` helpers are retained as **legacy stubs** for tests and any one-off migration reads.

**Rationale:**

- **No server-side mutation from a privacy-first email client.** Every user expects an email client to *read* their mailbox, not leave persistent tag/label breadcrumbs visible to other clients and other recipients who share the account.
- **Device Sync is the right layer.** It's a first-class real-time channel between TabMail instances, not a piggyback on IMAP keywords. It doesn't leak TabMail internals into the user's mail provider.
- **One extra LLM call per async-cross-device miss is acceptable.** A classification is ~cents of token cost. Orders of magnitude less than the "we're polluting your Gmail label list" trust cost.
- **Verified no shortcut on TB side.** `nsImapMailFolder.cpp`'s `HandleCustomFlags` overwrites local `keywords` with server state on every folder resync when the server advertises user-flag support (Gmail, every modern IMAP) — so "write `keywords` locally via Experiment, skip IMAP STORE" does NOT work. TB's equivalent work requires a custom painter driven from IDB. (See the parallel work in the tabmail-thunderbird add-on.)

**Consequences:**

- **Async cross-device pickup is lost.** Device A tags, goes offline. Device B online hours later → re-runs LLM. For users who keep both clients open simultaneously, no change. For "phone morning, desktop evening" users, up to 2× LLM cost on overlapping inboxes + possible action-pick divergence (3-call vote is non-deterministic).
- **Existing on-server `tm_*` keywords/labels/categories decay naturally** via inbox-exit cleanup (see point 8). We don't do a wholesale scrub (too risky — irreversible server writes on every message). Instead, cleanup is piggybacked on normal user triage: every archive/delete/move strips the message's `tm_*` residue on the way out. Over time, as users work through their inbox, on-server pollution trends to zero. Label *definitions* still exist in Gmail sidebar / Outlook "All Categories" list until the user manually deletes them (or until Gmail auto-hides unused labels, which varies).
- **NSE `gmailTagLabelMaps` UserDefaults key becomes orphaned.** Old mirror data sits in the app group container; no one reads it. Cleanup is a non-goal (zero-cost to leave).
- **Tests that verified server-side ActionTag resolution (`NSEMergeFullHeaderTests` server-tag-wins cases) are inverted** to pin the new local-only behavior: legacy `tm_*` labels in `providerLabels` are ignored; AI's `msg.actionTag` wins.

**Migration path:**

- On-server data: no proactive scrub. The chip reads from `MessageHeader.actionTag` (not from server labels), so the visual behavior is unchanged for end users; only the label-list pollution gradually fades as messages turn over.
- Local data: no migration. `MessageAICache` and `MessageHeader.actionTag` already contained the canonical local state; we just stop feeding them from provider labels.
- TB parallel work: the tabmail-thunderbird add-on removes TB's tag writes and adds an IDB-driven custom painter for the chip (TB has no single GRDB column for actionTag, so the painter is more involved than iOS).

**Related:** ADR-IOS-004 (superseded), ADR-IOS-010 (Device Sync), ADR-IOS-018 (PendingOperation queue — `.setTag` drain is now a no-op).

**Amendment (2026-07-10) — leaving the inbox clears the tag in the SAME optimistic write.** `optimisticMoveToFolder` used to enqueue a `.removeTag` PendingOperation on archive/inbox-exit whose drain case is a no-op `break` (correct — tags are local-only), while the local `actionTag` column was never cleared anywhere at move time: the stale chip stayed visible in Archive/Trash list rows (`MessageRowView.effectiveTag` and `TriageRowView` render `actionTag` UNGATED on `isInInbox`; only the detail view gates) until `sweepStaleActionTags` after the next full sync (≤ ~15 min). Now the inbox-leaving move's `updateAll` also sets `actionTag = nil, tagSortOrder = 99` (the sweep's own sentinel), the dead `.removeTag` enqueue is deleted (the drain case stays as a legacy-row flush), the gesture/tool overlay mutations register `actionTag: .some(nil)` for inbox-leaving moves so the mid-drain window doesn't flash the chip, and undo restores the tag automatically (full-row save of the pre-move snapshot). Tests: `AccountManagerActionsTagClearTests` (real archive/move/undo paths).
