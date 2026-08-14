# IOS-ATTACH-001 — a legacy draft whose attachment name the new predicate refuses cannot be re-saved or sent

**Class:** `accepted` · **Opened:** 2026-08-12 · **Attribution:** introduced by `c35cfdca2`
(`ADR-IOS-077`), unreleased at the time of writing.
**Registered under THE MANTRA, not deferred and not a defect** — recoverable fail-closed edge, one
ordinary user gesture. **Do NOT build a migration for it.**

## What is wrong

`ADR-IOS-077` replaced a filename *reducer* with a *predicate*,
`AttachmentFilename.isSafeFileComponent`. The predicate's doc comment shipped with a compatibility
guarantee:

> *"Names already on disk — including every name the old reducer transformed — therefore still load
> unchanged, and every one of them is ACCEPTED by this predicate, because the reducer's output
> satisfied exactly these six rules by construction. A draft saved before this round can still be
> reopened and re-saved."*

**The second half is false, and its premise never existed: no shipped build ever ran the reducer.**

| checked | `safeAttachmentFileComponent` | `isSafeFileComponent` | what the stores write |
|---|---|---|---|
| `v1.7.6` | absent | absent | — |
| `v1.7.7` | absent | absent | — |
| `v1.7.8` (newest tag) | absent | absent | `"\(index)_\(att.filename)"`, verbatim and unchecked |

Verified with `git grep <symbol> <tag> -- '*.swift'` (zero hits at all three tags) and by reading
`v1.7.8:TabMail/Models/Draft.swift` `saveAttachments` and `v1.7.8:TabMail/Models/OutboxMessage.swift`
`saveAttachments`. The reducer was introduced by `711afc6b8` (2026-08-12 01:20) and deleted by
`c35cfdca2` (2026-08-12 15:59) — ~15 hours, entirely on this unreleased line, 92 commits past
`v1.7.8`.

So the population on disk in every shipped install is **raw sender-authored MIME `filename`
parameters**, not reducer output.

## The at-risk population is NOT "refused names" — the filesystem was already a gate

"Some raw sender names are refused" is true and far too wide. `v1.7.8` wrote
`"\(index)_\(att.filename)"` unchecked, but `open(2)` still had to accept both the data file and its
`.meta` sidecar. The legacy at-risk set is therefore the intersection
**refused-by-predicate ∩ writable-by-`v1.7.8`**, and that intersection is **three narrow shapes**.
Measured on a real APFS filesystem by writing `0_<name>` and `0_<name>.meta` for each candidate:

**CAN be on disk:**

1. **Any of the 79 refused scalars** — C0/C1 controls, the bidi overrides/embeddings/isolates, ALM,
   LRM/RLM, LS/PS. All 79 wrote successfully as `0_invoice<scalar>.pdf` *and* their sidecars;
   **0 of 79** were refused by the filesystem. This is the hostile shape, and refusing it is the whole
   point of `ADR-IOS-077`.
2. **A name of 231–248 NFD UTF-16 units, at a single-digit attachment index.** The predicate budget is
   230 (`255 − String(Int.max).count(19) − 1 − ".meta".count(5)`), which reserves for the widest index
   that can exist; a real draft at index 0–9 spends only `"N_"`, so its sidecar fits up to 248.
   Measured writable range **231…248 — 18 units wide** at indices 0–9, 247 at 10–99, and so on. This
   is the *legitimate* shape: a long non-Latin filename, per `ADR-IOS-077` consequence 2.
3. **A canonical combining run of exactly 31 non-starters**, leading or interior. The predicate's
   `combiningRunBudgetScalars` is `maxCombiningSequenceScalars(32) − 2`, i.e. it refuses a run > 30,
   while the filesystem accepts a sequence up to 32 (starter + 31). Measured: run 30 writes, run 31
   writes, run 32 fails `NSCocoaErrorDomain` 512 — confirmed with `U+0301`, `U+0323` and `U+064B`, and
   with a precomposed `U+00E9` base contributing its own mark to the NFD run. **One value wide.**

**CANNOT be on disk — `v1.7.8` could not write these, so no field data exists:**

- **unassigned scalars** — `open(2)` raises `EILSEQ`. `isSafeFileComponent`'s own doc records the
  full `U+0000...U+10FFFF` sweep behind rule 4: the set the filesystem refuses is *exactly* the
  scalars whose general category is `unassigned`, 814,730 of them, zero disagreements in either
  direction. Spot-confirmed here with `U+0378`;
- **combining runs of 32 or more** (above);
- **path separators and every containment failure** — `photos/img.png` never wrote.

Shape 3 was missed by the first enumeration of this intersection, which measured runs 30, 32, 33 and
40 and skipped the one value the 2-scalar reservation creates. Recorded because it is the same class
of error the reservation exists to prevent: a boundary is not proven by testing either side of it.

## Real effect, stated at the width it holds

- **Loading and display are unaffected.** Neither loader recomputes a data filename in order to find
  it: `DraftAttachmentStorage.loadAttachments` and `OutboxMessage.loadAttachments` both
  `contentsOfDirectory` the slot and strip the `<index>_` prefix off whatever they find. The row
  renders `AttachmentFilename.unsupportedLabel` in place of a refused name.
- **Every WRITE path throws `AttachmentFilenameError.unsupported`:** `ComposeView.saveDraftAndDismiss`
  and `ComposeView.send`'s copy-on-write staging (both via
  `DraftAttachmentStorage.saveAttachments`), `DynamicIslandChatButton.autoSaveDraft`, and
  `AccountManager.queueSend` → `AccountManagerOutbox.persistQueuedSend` →
  `OutboxMessage.saveAttachments`. Compose shows the generic, reason-agnostic
  `"This attachment's file name isn't supported."` and does **not** dismiss (Outbox Reliability Rules
  1 and 5 — the intention is never dropped and nothing is sent with a wrong or missing attachment).
- **Recovery is one ordinary gesture: remove the attachment.** The draft then saves and the message
  sends. The original message and its attachment are untouched on the server.

## The narrowing that must travel with this entry

**An outbox row already QUEUED before the upgrade is unaffected and still sends.** The drain path is
`OutboxMessage.toDraftMessage()` → `loadAttachments()`, which reads the files that are already in the
slot; it never calls `saveAttachments` again. So a send in flight at upgrade time completes normally.
Only a *new* queue attempt — i.e. a draft the user edits and re-sends — hits the throw.

This narrowing was contributed by the second reviewer in round 14 and the first leg missed it. Stating
the blast radius one step wider than it is would have argued for a migration this entry exists to
refuse.

## Why it is registered rather than fixed

The owner has ratified **forward-only**: no backfill and no migration for a security fix, and data the
new rule refuses is allowed to fail (owner, 2026-08-12 — *"we can also opt to NOT backfill any of our
security fixes. As long as it goes 'onwards' its fine."*). The verdict is the owner's; the reasoning
below is agent-side and merely agrees with it — THE MANTRA's test is recoverability, and it is met:
the edge fails closed, nothing is destroyed, and one ordinary gesture reaches a correct state.

**Do not add a migration, a rename-on-load, or a grandfathering path.** Re-introducing a
transformation is precisely what `ADR-IOS-077` deleted after five confirmed defects in three audit
rounds, and a transformation reachable only from legacy rows would be the least-exercised code in the
tree — the worst possible place to put the machinery whose defect rate motivated the ADR.

## Reachability

A user who installed `v1.7.6`–`v1.7.8` (or earlier), saved a draft carrying an attachment whose
sender-authored filename falls in one of the three measured shapes above, upgrades, then edits and
re-saves or re-sends that draft. Shape 1 (a control or bidi scalar) is the hostile case. Shapes 2 and
3 are the *legitimate* cases and they are narrow — 18 length units and one run value.

## When revisited

If field reports show this is common rather than rare, the answer is **still not a reducer**. The
cheapest honest options, in order:

(a) let the compose UI offer *remove this attachment* directly from the error, turning one gesture
into one tap;

(b) reconsider the two budgets, whose conservatism is now **measured** rather than assumed. The
NFD-unit budget is over-restrictive by **18 units** against what `v1.7.8` could actually store,
because it reserves `String(Int.max).count` while real indices are one or two digits; the combining-run
budget is over-restrictive by **1** for the same kind of reason. **Do not change either constant on
that basis alone** — the `Int.max` reservation is deliberately the only bound that cannot be wrong,
and shrinking it trades a provable bound for a probable one. The numbers are recorded as the *size of
the conservatism*, not as a defect in it.

Neither option transforms a name.

## Related

- `ADR-IOS-077` consequence 5 — the same correction, in the decision record.
- `AttachmentFilename.isSafeFileComponent` — the predicate; its doc carries the corrected statement.
- `IOS-COMPOSE-002` — the other open cost on the same filename value, outbound side.
