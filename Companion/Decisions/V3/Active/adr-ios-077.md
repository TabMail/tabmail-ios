## ADR-IOS-077: Hostile Attachment Filenames Are Rejected, Not Reduced

**Date:** 2026-08-12

**Status:** Active. Implemented in `c35cfdca2` (net −476 lines).

**Context.** A network-sourced attachment filename becomes a real path component on disk (the stored
data file, its `.meta` sidecar, and the temp file staged for QuickLook preview). It is sender-authored
and therefore untrusted. From v1.6.x until this ADR the app *reduced* such a name to a safe one:
strip a 79-scalar set (C0/C1 controls, bidi overrides/embeddings/isolates, ALM, LRM/RLM, LS/PS), drop
scalars whose general category is `unassigned`, cap any canonical combining sequence, truncate to a
budget expressed in NFD UTF-16 units, and refill the stem when truncation emptied it. The
reduction had a required-co-edit twin in the view layer so display and staging agreed.

Three audit rounds found five confirmed defects, and **every one of them was in the reduction, none
in the classification of what is unsafe**:

| round | defect | mechanism at fault |
|---|---|---|
| 10 | `unassigned` scalars were kept and the filesystem refused them | strip filter |
| 10 | truncation could empty the stem | truncate + refill |
| 12 | a canonical combining sequence over the limit is refused while far under the length budget — the length cap never engages first | reduction budget |
| 12 | a trailing `Prepend` scalar grapheme-merged with the sidecar's `.`, so the `.meta` sidecar was classified as data and **sent as an extra attachment** | loader, `Character`-wise |
| 12 | a leading combining mark merged with the index prefix's `_`, so the prefix was retained or the name was cut at a later `_` | loader, `Character`-wise |

**Decision.** A filename that is not safe to use verbatim as one path component is **rejected**. One
shared predicate, `AttachmentFilename.isSafeFileComponent`, answers a single question and transforms
nothing. On the outgoing path `DraftAttachmentStorage.saveAttachments`, `OutboxMessage.saveAttachments`
and `AttachmentPreviewStager.createAttempt` throw `AttachmentFilenameError.unsupported` **before
`createDirectory`**, so a refused set writes nothing; compose and forward fail visibly rather than
silently renaming the user's file. On the incoming path both download routes refuse **before the
fetch**, and the row shows `"Unsupported file name"` in place of the hostile name.

The predicate's final rule is an **outcome** test rather than an enumeration of escape spellings:
append the candidate to a probe directory and require the parent to be unchanged. That subsumes `.`,
`..`, empty and any residual traversal in one check.

The reducer and its co-edit twin are deleted. **Removing the twin is part of the win** — a
character-identical duplicate maintained across two files was a standing tax on every round.

**Rationale.** A name that must be *transformed* to be safe carries a large, delicate correctness
surface: each transformation must compose with every other, and the composition is where all five
defects lived. A name that is only *tested* carries almost none. This is the repo's own MANTRA
applied — a rejected attachment is recoverable (the message still exists on the server and the user
can reach the file by other means), and the mantra's instruction for a recoverable edge is to fail
closed and **not build the mechanism**. The mechanism had been built and rebuilt five times.

**Consequences — the parts that must not be re-derived.**

1. **"Long" is not the only refusal reason.** A 48-NFD-unit name with a 32-scalar combining run is
   refused nowhere near the length budget. The user-facing message is therefore generic and
   reason-agnostic — one message for all six rules, no per-rule table, no diagnostic breadcrumb.
   Owner decision, 2026-08-12.
2. **The rejected population is not purely malicious, and that is accepted.** The cap counts NFD
   UTF-16 units, so the threshold is script-dependent: Hangul decomposes to 2–3 units per syllable,
   so a Korean filename is refused at roughly 85 visible characters. Accepted by the owner on the
   grounds that a false rejection is visible and recoverable where a silent rename was neither, and
   that such reports are unlikely to reach us. Deliberately **not** compensated with a debug
   affordance, a "show original name" escape hatch, or telemetry.
3. **Rejecting at save does NOT make the loaders safe.** `AttachmentFilename.metaBase` and
   `AttachmentFilename.afterIndexPrefix` are retained and remain load-bearing. A name can pass the
   predicate and still defeat `Character`-wise parsing downstream:
   - `"\u{0301}foo.pdf"` — one leading combining mark; short, assigned, unstripped, run length 1, so
     **SAFE**. Stored as `0_\u{0301}foo.pdf`, the `_` and the mark are one `Character`.
   - `"invoice\u{0605}"` — one trailing `Prepend` scalar, also **SAFE**; its sidecar grapheme-merges
     the `.`, which is what defeated `hasSuffix(".meta")` *and its fail-closed guard together*.

   The predicate answers *is this storable*; the loaders answer *what was actually stored*. Different
   questions, and neither answers the other. This is the trap any future simplification pass will
   walk into.
4. **The type-spoof guarantee is unchanged and remains bounded, not closed.** Stripping never
   achieved it and rejection does not either: visible strong-RTL letters reorder runs, and the
   legitimate Hebrew name `דוח.pdf` lays out exactly like a crafted `"\u{05D0}pdf\u{05D0}.exe"`, so
   no predicate can separate them. Directional isolates (`U+2066`/`U+2069`) at each *display* site
   are the only real mitigation and remain a tracked follow-up — they must never be applied inside
   the predicate's callers on the staging path, whose output names a real file on disk.
5. **THERE IS NO MIGRATION GUARANTEE, because there was never a reducer to migrate FROM.** Corrected
   2026-08-12, one round after this ADR landed. `isSafeFileComponent`'s doc comment claimed that every
   name already on disk — *"including every name the old reducer transformed"* — is accepted by the
   predicate *"because the reducer's output satisfied exactly these six rules by construction"*, so any
   pre-existing draft could be reopened **and re-saved**. The *loading* half is true and unaffected;
   the *acceptance* and *re-save* halves are false. **No shipped build ever
   ran the reducer:** `v1.7.6`, `v1.7.7` and `v1.7.8` (newest tag) contain neither
   `safeAttachmentFileComponent` nor `isSafeFileComponent`, and `v1.7.8`'s two stores write
   `"\(index)_\(att.filename)"` verbatim and unchecked. The reducer was introduced by `711afc6b8` and
   deleted by `c35cfdca2` ~15 hours later, entirely on this unreleased line. So the field population is
   **raw sender-authored names**.

   **The at-risk set is narrower than "refused names", because the filesystem was already a gate.**
   `v1.7.8` wrote unchecked, but `open(2)` still had to accept the data file *and* its `.meta` sidecar,
   so what can exist in the field is `refused-by-predicate ∩ writable-by-v1.7.8` — measured on APFS as
   exactly **three shapes**: (1) **any of the 79 refused scalars** (all 79 wrote, 0 filesystem
   refusals — the hostile shape); (2) **a name of 231–248 NFD UTF-16 units at a single-digit index**,
   18 units wide, because the 230 budget reserves `String(Int.max).count` while a real index spends two
   characters (the legitimate shape, consequence 2's long non-Latin name); (3) **a canonical combining
   run of exactly 31**, one value wide, because `combiningRunBudgetScalars` is `32 − 2` while the
   filesystem accepts a 32-scalar sequence. **Unassigned scalars, runs ≥ 32, separators and every
   containment failure CANNOT be on disk** — `v1.7.8` could not write them, so no field data exists.

   The real effect, narrowed rather than overstated: such a draft still **loads and displays** (both
   loaders enumerate the slot and strip the `<index>_` prefix — neither recomputes a name), but every
   **write** path throws `AttachmentFilenameError.unsupported` — `ComposeView.saveDraftAndDismiss`,
   `ComposeView.send`'s COW staging, `DynamicIslandChatButton.autoSaveDraft`, and `queueSend` →
   `persistQueuedSend` → `OutboxMessage.saveAttachments` — so compose refuses to dismiss and shows the
   generic message. **Removing the attachment is the recovery**, and it is one ordinary gesture. An
   outbox row **already queued before the upgrade is unaffected**: the drain runs `toDraftMessage` →
   `loadAttachments`, which sends the existing files without re-saving them.

   Registered as `IOS-ATTACH-001`. The no-backfill choice is the **owner's verdict**, not an agent
   application of THE MANTRA: security fixes are forward-only and data the new rule refuses is allowed
   to fail (owner, 2026-08-12 — *"we can also opt to NOT backfill any of our security fixes. As long as
   it goes 'onwards' its fine."*); the MANTRA reasoning is ours and merely agrees. **So: do not add a
   migration, a rename-on-load, or a grandfathering path.** Re-introducing a transformation is exactly
   what this ADR deleted, and one reachable only from legacy rows would be the least tested code in the
   tree.

   **The transferable part:** the false claim was a *compatibility* argument written in the same round
   that deleted the thing it claimed compatibility with. It was checkable in one command
   (`git grep <symbol> <tag>`) and nobody ran it, because the sentence described this branch's history,
   which was fresh in mind, rather than the field's. That is audit rule **A1 — search the previous
   release first** (`CLAUDE.md`), applied to a compatibility claim rather than to a design.

**Retained measurements.** The deleted reduction carried sweep results that are still true and
expensive to re-derive; they move onto the predicate rather than out with the code:

- The combining-sequence test is **canonical combining class ≠ 0 on the NFD form**, *not* general
  category `Mn`/`Mc`/`Me` — swept and wrong in **both** directions (`U+0E31` Mn, `U+0903` Mc,
  `U+20DD` Me and `U+FE0F` are unlimited; every `ccc != 0` scalar failed at the same length).
- The limit counts on `decomposedStringWithCanonicalMapping`: `U+00E1` + 31 marks is refused because
  it decomposes to `a` + 32.
- The length and run caps are **independent**; the length cap never engages first.
- `CharacterSet` algebra is not set algebra on built-in sets. The refused-scalar set is built
  entirely from `CharacterSet(charactersIn:)` and is exact.

**Out of scope, recorded here so it is not mistaken for closed.** `GmailProvider`'s hand-rolled MIME
part builder interpolates `attachment.filename` and `attachment.mimeType` raw into `Content-Type` and
`Content-Disposition`. This predicate incidentally closes the CR/LF half **for the filename only**;
the embedded-quote half, RFC 2047/2231 encoding, and `mimeType` — which this ADR does not constrain
at all — remain open and are owned by the outbound-security workstream.
