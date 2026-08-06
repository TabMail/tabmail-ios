## ADR-IOS-068: Durable Message Actions Are Keyed by the Native Provider Id (Supersedes ADR-IOS-026B)

**Date:** 2026-08-02

**Status:** Active. **Supersedes ADR-IOS-026B** (the `stableId` / RFC-822 durable-action-identity
scheme). Withdraws the identity half of the unreleased ADR-IOS-060 (see ADR-IOS-070). Folds in the
principle of the unreleased ADR-IOS-059. Owner constraint D4, frozen 2026-07-30.

**Context — the failure.** A user with **aliases** receives one message more than once, so two local
rows carry the same RFC 822 Message-ID. Every durable action keyed by that RFC becomes ambiguous.
The concrete observed regression was one Gmail message delivered to two aliases in the same account.
Two server resources can share one RFC Message-ID; **RFC is corroborating metadata, never mutation
authority.**

Both existing designs are wrong on that input, in opposite directions, and each leg is independently
sufficient to justify this record.

**Leg 1 — the post-`v1.6.38` line fails CLOSED, and it is a defect CLASS, not one code path.**

- *Swipe / durable queue.* The reference's UID resolver returns `.ambiguous` on a multi-hit, the
  consumer `guard case .exact(let uid) = … else { continue }` **skips the member**, and the batch
  then hits `guard !messages.isEmpty else { return }` — **returning success with nothing done.** The
  op is deleted as a success, the gesture is lost, and the next sync visibly reverts it.
- *Notification actions.* `resolveDurableInboxHeader`'s RFC arm is **account-global, not
  folder-scoped**, and takes `prefix(2)`; two hits ⇒ `.ambiguous` ⇒ the handler returns without
  acting. **Every notification action button on that message silently does nothing, forever.**
- *AI writes.* `AIWriteTarget.capture` returns `nil` when the row is RFC-less and has no UIDVALIDITY
  baseline, so **the whole AI job no-ops** — a second live "permanently un-analysable" path.

A design that removed RFC authority from the queue alone would leave the second and third broken.
This ADR therefore governs **every** durable identity site, not the queue.

**Leg 2 — the shipped `v1.6.38` fails OPEN: one swipe mutates every copy.** `MessageHeader.stableId`
returns the RFC whenever `messageId` is numeric and an RFC is present; `IMAPProvider.resolveUID`
falls through to `searchByMessageId` and returns **the entire `UIDSet` with no cardinality check**;
its consumer stores flags on that whole set. On IMAP, one swipe on a duplicated-RFC message mutates
**every copy** — and has done so since before `v1.6.38`. That defect is recorded as `IOS-IMAP-002`
under *Fixed by D4* in `KNOWN_ISSUES.md`.

**Decision.**

1. **Identity.** A durable action op records **the native provider identifier of the message the
   user gestured on, in the mailbox it was gestured in, and nothing else.**

   | Provider | v3 durable action key |
   |---|---|
   | IMAP / iCloud | **`(UIDVALIDITY, UID)`** |
   | Gmail | `message.id` |
   | Graph / Outlook | `message.id` |

   A UID is a mailbox-local integer the server may reassign, so it is meaningful **only** inside the
   UIDVALIDITY generation it was observed in. The op carries one **source** epoch stamp; anything
   that additionally dereferences a *destination* UID must record and assert a **destination** epoch
   as well.

2. **The RFC 822 Message-ID is never consulted to select or authorize a mutation target on any
   provider.** Prior art, quoted from the shipped register: ***"RFC cardinality is never mutation
   authority."*** ADR-IOS-026B's leap from "we fetch, normalize, dedup and stage by RFC" to "RFC is
   therefore durable **mutation authority**" is the defect; that leap alone is superseded.

3. **C3 — the hard invariant.** *A provider issues a mutating command only against the exact
   provider identifier recorded when the user's gesture was admitted, and only while it has
   positively proven that this identifier still denotes the same message it denoted at admission;
   when that proof is unavailable, ambiguous, or contradicted, the operation is abandoned without
   mutating anything.* **Failing closed is always acceptable. Mutating the wrong message is not.**
   Its discharge checklist is normative: epoch assertion after *every* SELECT of a mailbox whose
   UIDs the op names; existence proof by `UID FETCH` before the first mutation; response-integrity
   checks; mutating UIDSets built **only** from UIDs that passed those checks, so **no SEARCH result
   is ever a mutation target**; no argument-less `EXPUNGE` on any action path, ever; and no
   unasserted gap — between the last epoch assertion and the mutating command the only permitted
   awaits are non-mutating commands on the same uninterrupted selection.

4. **The IMAP leg's spec, lifted from the shipped `IOS-DRAFT-008` (already D4-shaped).** Strong
   `(UIDVALIDITY, UID)` operations verify the live epoch before mutation. The source epoch is
   **captured with the source row**, not reconstructed later: `MessageHeader.observedUidValidity`
   (migration `v77`) and its `MessageSnapshot` copy carry the UIDVALIDITY under which that exact UID
   was fetched or authoritatively adopted, and it is stamped onto
   `PendingOperation.observedUidValidity` (migration `v69`) at admission. Unproven ingress records
   nil; zero is unknown and also becomes nil. **Never substitute the current
   `Folder.lastKnownUidValidity` for a missing row/snapshot epoch** — that blesses an old-epoch UID
   after the mailbox has advanced.

5. **Two checkpoints, and the drop rule.** *Checkpoint A* runs inside the queue's claim/delete
   transaction, scoped to the op's exact `accountId + folderPath`, before any provider I/O: every
   member must be a positive native UID, the op epoch nonzero, the stored Folder epoch nonzero and
   equal, and no reset pending. *Checkpoint B* passes the admitted epoch explicitly through the
   concrete IMAP action APIs and compares it after the wrapper SELECT and every inner source
   re-SELECT. A failure at either **deletes the whole op** — never a passing subset — and if that
   delete write fails, the original op is requeued unchanged. Checkpoint A is **type-scoped to the
   11 action types**: `executeSingleOp` receives every op type and draft ops' `messageIds` are not
   header ids at all, so an unscoped checkpoint would misclassify them.

   ⚠️ **COUNT CORRECTED 2026-08-05 — this clause said "13 action types", and a bare integer with no
   member list is exactly what let it drift.** The set is `AccountManagerQueue.swift`'s
   `nonDraftTypes`, and at `1d1557187` it has **eleven** members, enumerated here so the next reader
   checks membership rather than arithmetic:

   `.archive`, `.delete`, `.move`, `.markRead`, `.markUnread`, `.markFlagged`, `.markUnflagged`,
   `.markReplied`, `.markForwarded`, `.addUserLabel`, `.removeUserLabel`.

   **`.setTag` and `.removeTag` are excluded DELIBERATELY, and re-adding them would be a defect.**
   They were removed from the set by `b78a9303d`, which left an in-tree comment saying so. Action
   tags are **local-only** (ADR-IOS-036): their `executeOperation` arm is a bare `break` with no
   provider write at all, so they touch no wire address and stamp **no `observedUidValidity`**.
   Checkpoint A's unstamped arm would therefore begin REFUSING them — a self-inflicted intention drop
   on a path that has no wire hazard to protect against. The exclusion is correct; only the number
   was stale.

   📌 **`065a827ca`'s COMMIT BODY carries the same stale 13** (*"Enforce transactional Checkpoint A
   across all 13 non-draft operation types"*). A commit message cannot be amended on this
   no-rewrite branch, so the correction is recorded here instead — do not treat that sentence as
   evidence that two types are missing from the set.

6. **A folder role is never identity** (the surviving principle of the unreleased ADR-IOS-059).
   Undo resolves by the **recorded tuple** — account, mailbox, native id, epoch — and **drops on any
   mismatch.** A role such as "Archive" or "the inbox" is a label on a mailbox, not a name for a
   message, and may never be substituted for a recorded address.

7. **Two keying schemes, on purpose.** Durable **actions** key by provider id, because that is what
   distinguishes two copies of one message. **Content** — FTS rows, body assets, the AI cross-device
   cache probe — keys by RFC, because two copies of one message *are* the same content. This is not
   an inconsistency and must not be "unified" by a later tidy-up; see ADR-IOS-072 for the content
   side.

**What RFC is still used for — normative exempt list. Do NOT sweep these.** An unlisted RFC site is
by construction a removal candidate, so an **omission from this list is itself a bug**.

| Surface | Why it keeps RFC |
|---|---|
| **`MessageExistenceProbe` / `currentUIDs` / `messageExistsInFolder`** ★★★ | Two consumers: the queue **and, destructively, the backfill body queue**. `confirmGoneAtThreshold` opens `guard let prober = provider as? any MessageExistenceProbe else { return .gone }`, and `.gone` deletes the user's local header. **Removing the conformance does not disable a check — it converts every IMAP backfill miss at threshold into "delete the user's local header and body"**, and destroys the UID-remap re-key that project memory records as the 2026-06-09 FTS body-loss root cause. **KEEP THE CONFORMANCE.** |
| Sent-folder duplicate-APPEND guard (`appendToSentFolder` → `searchByMessageId`) | The only thing preventing a duplicate Sent copy when an append is retried after a partial finalize. Double-send prevention is non-negotiable. |
| Pre-generated `sentMessageId` on the Outbox claim path | It is both the wire Message-ID and that dedup key. |
| Draft RFC ≠ sent RFC in Outbox server-draft cleanup | Conflating them orphans the server draft. |
| ~~IMAP draft UID **discovery**~~ **RETIRED — this row was itself a D4 violation.** | It read: *"RFC is the search key used to learn the UID after a non-UIDPLUS APPEND; the UID remains the identity."* That is exactly the forbidden relationship, dressed as discovery: the learned UID became a **mutation address** that `DraftStore` persisted and `deleteDraftStrong` later `STORE \Deleted`-ed and, on UIDPLUS, **irreversibly UID-EXPUNGEd**. Exact-match and cardinality guards prove one message carries the Message-ID — never that it is the message we appended. Removed in "Refuse a draft address derived from a Message-ID SEARCH"; absence of `APPENDUID` now yields `.unaddressable`. **Do not restore this row.** |
| AI cross-device cache probe (`MessageIdentity.aiCacheKey`) | ADR-IOS-026B / ADR-IOS-010; shared with the Thunderbird addon. A provider id is device-local. |
| Threading / `References` / `In-Reply-To` | RFC 5322 threading is *defined* on Message-ID. |
| The two-key sync filter (`PendingOperation.containsAnyKey`) | Explicitly preserved by D4's scope boundary. Do not tidy. |
| **Refuse-only equality witnesses** — a CATEGORY, not a site | Roughly twenty production sites (round-5 Angle-1 census `F2`, at `01550cdc6`). Not enumerated row by row; see the carve-out immediately below for the test that identifies one. |

**⚠️ THE ABSOLUTE ABOVE HAS A NEGATIVE CASE, AND LEAVING IT UNSTATED WAS ITSELF THE `MIS-019` SHAPE
(added 2026-08-05).** Every row in this table enumerates an RFC use that confers **authority** — a
probe whose answer decides a delete, an APPEND dedup key, a wire id, a cache key, RFC 5322 threading,
the two-key sync filter. Those are the sites where an RFC match makes something *happen*. They are
**not** the whole population of RFC uses in production, and *"an unlisted RFC site is by construction
a removal candidate"* is true **only of that authority class**.

**The distinguishing test, applied one site at a time:** *does the RFC match AUTHORIZE an action, or
only REFUSE one?* A **refuse-only witness** has two signatures: its sole output is a veto, and the
ABSENCE of either id produces **no** verdict at all (never a refusal, never a licence). Removing one
does not remove an RFC dependency — it removes a **refusal**, which fails in the dangerous direction.
That is the same defect class as widening the `COPYUID`-gated expunge's evidence, and it is why these
sites are neither listed here nor sweepable.

Exemplars (3 of ~20 — the category is the normative part, not the list):

- **`SyncEngineEpochVerify.classifyEpochVerificationSample`** — NEW IN THE v3 RANGE, which is exactly
  why the unqualified absolute was dangerous. A server-returned `rfc822MessageId` that disagrees with
  the stored one marks that sample a mismatch and blocks the UIDVALIDITY re-stamp; a sampled UID the
  server did not return, or returned without an rfc822, is *"NOT RETURNED ⇒ no evidence. Never a
  mismatch, never an agreement."*
- **`ExpectedMessageIdentity.matches` / `.partition`** (`AccountManagerActions`) — the C3 content
  witness on the re-resolve path. A header with no captured identity is KEPT (`guard let expected =
  expectedIdentities[header.id] else { return true }`), so a match grants nothing the caller was not
  already doing; only a positive disagreement refuses, and only for that one id.
- **`NSEStagingDB.stagedIdentityPositivelyDiffers`** — named for the property. It returns `false`
  unless BOTH sides are present and differ, so a staged AI result is served unless the RFC ids
  *positively* disagree (`IOS-NSE-006`).

**Rationale.**

- **On the IMAP leg this is a forward design, not a revert. State this plainly whenever the change
  is described.** On Gmail and Graph, and on the notification lookup path, D4 restores what
  `v1.6.38` already did. On the IMAP action queue the shipped release is **the less safe of the two
  designs**: the reference fails closed where the base fails open. D4 is the first design correct on
  that leg, because **it never produces a multi-match set at all** — there is no cardinality to
  check, because the action queue's own path never searches.

  ⚠️ **This bullet previously ended "because nothing searches", full stop. That was false and is
  retracted.** `searchByMessageId` retains two live call sites, and a third — `saveDraft`'s
  no-`APPENDUID` arm — was live when this sentence was written and did convert a SEARCH hit into a
  draft mutation address (`IOS-IMAP-002`'s retraction; fixed separately). **The property D4 actually
  guarantees is narrower and is the one that matters: no SEARCH result is ever a mutation target.**
  State it that way, never as "nothing searches" — the blanket phrasing is what let the draft arm sit
  inside a frozen ADR that forbids it. The two survivors are both non-mutation reads:
  `appendToSentFolder` uses cardinality only, as an existence probe, and never converts a hit into an
  address; `currentUIDs` / `messageExistsInFolder` feed the backfill body queue's re-key, which is a
  **local** header address for a body fetch, not a wire mutation target — its multi-hit resolution is
  registered as an open lead (`IOS-BACKFILL-002`).
- UID keying is viable now only because C2/C4/C5 (ADR-IOS-069) removed the durability-across-reset
  requirement that forced RFC keying in the first place. It **deletes** code rather than adding it.
- Graph ids are stable for a message *in place*, but Graph **reallocates the id on move**. That is
  expected and resolves to a stale no-op — it is not a reassignment of one id to a *different*
  message, which is the hazard this ADR guards. Do not write "never reassigned".

**Consequences.**

- `MessageHeader.stableId` is no longer durable-action authority. `uidResolutionRetryCount` becomes
  dead: the column stays, the logic goes.
- A duplicated-RFC message is now actionable on every provider, and a swipe on one copy mutates only
  that copy.
- The move path owns its sequence rather than delegating: `IMAPProvider.move` no longer calls
  `server.move`, and issues COPY → STORE `\Deleted` → (UIDPLUS only) scoped `UID EXPUNGE` itself,
  asserting the admitted epoch at **five** boundaries (`3843940cb`). A non-UIDPLUS server fails
  closed at copy-plus-soft-delete with **no expunge of any kind**.
- Provider error classification stops depending on a discarded HTTP body: `HTTPRequestResult
  .errorBody`, `HTTPError.networkErrorWithBody` and `AuthedHTTP.requestPreservingBadRequestBody`
  (`cd2062bea`) are the substrate the Gmail/Graph structural-400 classifiers read, so a
  structurally-invalid-id 400 can be retired as a stale no-op instead of retried forever.
- Notification taps are scoped to their account and their exact composite address, and a thrown
  durable read is no longer treated as absence (`7c26989b9`). A nil-`accountId` tap previously
  matched **any** account sharing the UID and durably marked that message read.

**Tests / evidence.** `3843940cb` (IMAP move wire contract, 8 tests extending the `FakeIMAPServer`
wrong-message wire oracle rather than a bespoke hook, both non-vacuity partners strict);
`7c26989b9` (11 two-sided notification tests; one test that BLESSED the nil-account hazard deleted,
five repaired); `cd2062bea` (12 + 22 HTTP tests). Every one of those commits landed inside a
combined clean build plus full suite at 8,080 passed / 0 failures / 0 production warnings.

**Relates:** ADR-IOS-026B (superseded), ADR-IOS-042 (the same "window in the fetch's own ordering
dimension" principle applied to sync), ADR-IOS-003 / ADR-IOS-018 (the queue charter this keys),
ADR-IOS-069 (what happens when the id resets), ADR-IOS-070 (the withdrawal record), ADR-IOS-071 (no
backward compatibility), ADR-IOS-072 (the content side of the two keying schemes), `KNOWN_ISSUES.md`
(`IOS-IMAP-002` under *Fixed by D4*), `PLAN_IOS_REFACTOR_V3/PLAN_V3_S3_design.md` §3.1–§3.6.

---

