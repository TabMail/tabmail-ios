# IOS-AI-004

- Register classification: `open`
- New post-freeze record (2026-08-12) added through the amendment surface; no row in the
  hash-pinned archive and therefore no original row hash.

## Status

🔓 **OPEN (2026-08-13), NARROWED — the trigger now exists; the residual is RFC-less rows.** The
2026-08-12 registration below said "there is no *message entered the inbox* trigger anywhere in the
tree." **That is no longer true.** `1eb41702e` added one, at the exact site this record had already
settled on. What survives is smaller and has a different cause: `resolveInboxEntryAITargets`
**requires an rfc822 Message-ID** and refuses — deliberately, fail-closed, with a debug-gated log —
for any member that has none. So a message with no `Message-ID` header that enters an inbox by local
move, is **never opened**, and falls outside `repopulationCandidates`' window still receives no AI
processing. See *What shipped* below.

<details>
<summary>Superseded status text (2026-08-12), preserved</summary>

🔓 **OPEN (2026-08-12) — registered under THE MANTRA, not deferred as a defect.** A message that
enters an inbox by a **local move** is never enqueued for AI processing at move time. There is no
"message entered the inbox" trigger anywhere in the tree. The gap is masked in ordinary use because
opening the message processes it on demand, which is the recovery gesture — so the user normally sees
AI output arrive when they tap the message rather than never.

</details>

⚠️ **The 2026-08-12 MANTRA argument above was made on a recovery gesture that was BLOCKED from the
state that produced the report.** "Tapping the message is the recovery gesture" is true only while
the row is on screen, and the row was hidden until the visibility fix of the *same day*; both device
episodes predate it. Naming a recovery mechanism without enumerating the states it cannot run from is
`MIS-IOS-008`, and this is its second recorded instance.

## Subsystem and search terms

AI processing; `ActiveAIQueue`; `ActiveAIQueue.enqueue`; `enqueueProcessMessage`;
`AccountManager.processOpenedMessage`; `MessageDetailViewModel.loadBody`; priority direct path;
`BodyFetchProcessor`; `SyncScheduler`; `AccountManagerSync`; `AccountManagerAI`; `NSEDataBridge`;
`repopulateFromDatabase`; `repopulationCandidates`; `SyncConfig.maxRecentEmails`; ADR-IOS-008;
decision 3; third event; `onMoved.js`; TB parity; local move; `isInInbox`; action tag; spinner;
`MessageRowView`; move sheet; `IOS-AI-005` sibling

## Full detail

**The gap, stated as a property of the code.** The production AI-enqueue call sites are: boot and
foreground scheduling (`SyncScheduler`), AI re-enable (`AccountManagerSync`), the guarded-write-miss
redrives (`AccountManagerAI`), the notification-extension merge (`NSEDataBridge`), and the body-fetch
path (`BodyFetchProcessor`, gated on `enableAI && item.isInInbox` with the body just written to FTS).
**None of them fires on a local move.** ADR-IOS-008 decision 3 names "message moved to inbox" as its
third enqueue event, and that event is unimplemented on iOS. The Thunderbird reference — which
ADR-IOS-008 makes authoritative — implements it in `onMoved.js`, enqueuing on
`!wasInInbox && nowInInbox` after an internal-sender skip, with a comment noting that inbox scans may
not otherwise process the message.

**How it is masked, and why that is the recovery rather than a workaround.**
`AccountManager.processOpenedMessage` is reached from `MessageDetailViewModel.loadBody` and enqueues
with priority, guarded by `guard let opened, opened.current.isInInbox else { return }`. So opening the
message **after** the move processes it, while an open **before** the move correctly refuses because
`isInInbox` was still false. Under THE MANTRA the test is whether the state converges via a sync pass,
a retry, or **one ordinary user gesture** — and tapping the message is exactly that gesture. This is
therefore a registered fail-closed residual, not a defect requiring a mechanism.

**Anonymized device observations were consistent with this mechanism.** In each retained episode,
the move was durably admitted and the first AI activity for the message was the priority direct path
on re-open, with no move-triggered enqueue between those events. A separate earlier report lacked a
retained trace and is not treated as measurement evidence. No message identity, account, or mailbox
activity from those observations is part of this public record.

## The narrow case that does NOT recover

**As of `1eb41702e` this requires a third conjunct: the row must have no rfc822 Message-ID.** A
message that enters an inbox and is **never opened** — a move-sheet move from the list, or an
agent/notification-driven move — **and** which falls outside `repopulationCandidates`'
`ORDER BY date DESC LIMIT SyncConfig.maxRecentEmails` window on the next foreground pass, **and**
whose `rfc822MessageId` is null or empty so `resolveInboxEntryAITargets` refuses it. In that case no
enqueue ever occurs and the row keeps no action tag.

⚠️ **A move that never reaches the queue drain is outside this trigger entirely** — the capture hangs
off the drain's destination-folder loop, so any inbox entry that does not arrive as a drained
`PendingOperation` move (a server-side move observed by sync, an NSE-delivered message landing
directly) is covered by its own enqueue site, not by this one. That is the pre-existing division of
labour, not a gap this fix introduced; it is recorded here so a future reader does not mistake the
trigger for universal.

This is what keeps the record OPEN rather than closed, and it is deliberately **not** in THE MANTRA's
blocking set: AI output is **derived, recomputable content**, not authored user data and not a queued
user intention, so nothing is dropped in the never-drop sense, no operation starves, there is no
wrong-message mutation, and nothing bricks. Owner ruling of 2026-08-12 applies directly — a non-minimal
fix belongs in the register for a later session.

## What shipped (2026-08-13, `1eb41702e`) — and the one thing it does not cover

Two functions in `AccountManagerQueue`, split across the drain boundary on purpose:

- **`recordMembersThatEnteredInbox`** captures, per drained move op, the members whose row is now in
  `destinationPath` with `isInInbox` true. It keys them through
  `MessageHeaderRekey.currentHeaderId(afterHandoffFrom:)`, so it follows the `COPYUID` handoff when
  there was one and leaves the id unchanged when there was not.
- **`enqueueAIForMembersThatEnteredInbox`** runs **after** the post-drain sync returns, which is the
  point at which the durable id and the FTS key agree by construction — a stronger condition than
  "the sync succeeded", and why it sits outside that `do/catch`. It resolves through
  **`resolveInboxEntryAITargets`**, then calls `ActiveAIQueue.shared.enqueue` per member.

Every prescription this record made was honoured: post-re-key id ✅, not `publishMoveFinish` ✅,
post-drain destination-folder loop ✅, per-item enqueue mirroring `BodyFetchProcessor.flushBatch` ✅.

🚨 **The residual, and it is a deliberate refusal rather than an oversight.**
`resolveInboxEntryAITargets` inverts `DurableIdentityLookup.find`'s priority: rfc822 identity is
**required**, not a fallback, because it is the only key that survives *both* re-key paths (the
drain's `COPYUID` and the sync's UID remap). A member with no rfc822 Message-ID is therefore skipped
with an observable log line. That is correct — the alternative was resolving a stale source UID
against the destination folder, which **did** land on an unrelated message and is pinned by
`MoveIntoInboxAIEnqueueTests.aiTargetIsNeverAUidCollisionVictim`.

**But it means the non-recovering case below survives for RFC-less rows specifically**, and that
subset is the same population `IOS-AI-003` found expensive for the same reason. Do not close this
record until either RFC-less rows get a re-identification path across a remap, or the register
records why they never need one.

## The site was settled BEFORE it was built — kept because the reasoning still governs any change

- **Use the POST-re-key id.** `ActiveAIQueue.executeJob` resolves the body as
  `SearchIndex.bodyText(contentKey: ContentKey(rawValue: job.headerId))`, and the move re-keys the FTS
  entry. An enqueue capturing the **pre**-re-key id finds no body and drops the job. THE ADDRESS
  PROBLEM applies in full: a move changes the address, and the row's primary key still names the
  source until the drain re-keys it.
- **`publishMoveFinish` is the WRONG hook.** It is the `COPYUID` drain path, so for providers that
  never change ids (Gmail) its applied set is empty and the hook would never fire.
- **The provider-agnostic site is the post-drain destination-folder loop** in `AccountManagerQueue`,
  where the destination `folder.role` is in scope.
- Mirror `onMoved.js`'s architecture rather than inventing one — ADR-IOS-008 parity is mandatory.

## The owner re-test — now a CONFIRMATION test, not a justification test

Same single gesture, but its meaning has inverted. Move a message into the inbox **from the inbox
list's move sheet** — not from a detail view — and **do not open it**. Before `1eb41702e` this was the
case with no recovery gesture; now it is the case the fix is supposed to handle, so AI output should
appear without the message ever being opened. If it does not, the fix did not take and this record
reopens at its original width.

⚠️ **This test has not been run.** `1eb41702e` has been verified by reading and by
`MoveIntoInboxAIEnqueueTests`; no device pass has confirmed the user-visible outcome.

## Related

- `IOS-AI-005` — a *separate* defect that can discard an AI result which WAS computed.
- `IOS-MOVE-002` — its 2026-08-12 amendment; the visibility fix that restored the tap gesture.
- ADR-IOS-008 — TB parity, authoritative for any implementation.
