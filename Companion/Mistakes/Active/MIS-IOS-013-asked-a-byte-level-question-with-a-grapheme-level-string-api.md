# MIS-IOS-013 — asked a question about the bytes another system will parse, and answered it with a `Character`-level `String` API

**Class:** data-integrity
**Severity:** high (wrong result shipped — one instance put the store's own metadata bytes into an
outgoing email as an attachment)
**First seen:** 2026-08 · **Recurrences:** 5 · **Status:** Active
**Related:** `MIS-IOS-012` (a census whose SHAPE hid half its subjects — same root: the tool's
notion of a unit was not the domain's), root `MIS-030` (scale is not shape) ·
**Rule owner:** `../CLAUDE.md` § Data Integrity Rules

## The tell

I am writing a line about a **filename** and it reads as completely ordinary Swift:

```swift
if name.hasSuffix(".meta") { … }
let filename = full.contains("_") ? String(full.drop(while: { $0 != "_" }).dropFirst()) : full
let last = path.split(separator: "/").last
```

Nothing about it looks like a decision. It looks like string handling — the kind you write without
slowing down, because the alternative spelling would be *more* code for *no* reason. The fixtures I
reach for are `"invoice.pdf"`, `"0_report.docx"`, `"a/b/c.txt"`, and they all pass. The tell is one
question: **who parses this string next?** If the answer is a filesystem, a MIME header, a wire
protocol, or my own on-disk naming scheme, then the unit that matters is the **scalar**, and I have
just asked about it with an API that groups scalars into units for *human reading*.

The specific comfort to watch for: `hasSuffix` / `contains` / `split` / `drop(while:)` / `hasPrefix`
feel like they operate on characters in the C sense. They do not. They operate on extended grapheme
clusters, and a hostile — or merely foreign — scalar chooses what a cluster is.

## What actually happened

Four instances, six sites, all on the same attachment-filename path, over two weeks.

1. **`split(separator: "/")` in `AttachmentPreviewStager.displayFilename`** (fixed `05200112d`).
   `U+002F` followed by a combining mark is ONE `Character`, and it is not `Character("/")`, so the
   separator survived the "reduce to one path component" step. A crafted filename could name a
   sibling file in the staging directory.

2. **The same bug, re-introduced 15 seconds later** in `DraftAttachmentStorage
   .safeAttachmentFileComponent` (`711afc6b8`) — written from the same instinct in the same sitting.
   `7ce64e44b` had to fix **both**, which is the first evidence that this is a class and not a typo.

3. **(round 12) `hasSuffix(".meta")` in BOTH `DraftAttachmentStorage.loadAttachments` and
   `OutboxMessage.loadAttachments`** — fixed `2ecdd6370`. Measured: **27** assigned scalars have
   grapheme-break property `Prepend`; each merges with the following `.` into one `Character`, so
   `"0_invoice\u{0605}.meta".hasSuffix(".meta")` is **false**. The sidecar was therefore classified
   as a data file: `loadAttachments` returned 2 attachments for 1 saved file. On the outbox side that
   is the SEND path, and the measurement was concrete — the outgoing message carried a 15-byte
   attachment whose content was `application/pdf`, i.e. the sidecar's own MIME-type text. All 27
   scalars survive the filename reducer, so a sender-authored MIME `filename` parameter reaches this
   code intact.

   The compounding detail: the `ambiguousMetaFilename` **fail-closed guard** in the same function
   asked the identical question with the identical API, so it declined to fire on exactly the inputs
   it existed to catch. The classifier and its backstop failed together, on the same input, four
   lines apart.

4. **(round 12) `contains("_")` + `drop(while: { $0 != "_" })` in the same two functions** — fixed
   `f5e225419`. **2,619** assigned scalars merge with the store's own `_`, producing one of two wrong
   answers: the `"0_"` index prefix comes back as the user's filename, or `drop(while:)` runs past
   the merged first `_` to the **second** one and truncates the front of the name
   (`"\u{0301}foo_bar.pdf"` → `"bar.pdf"`).

The two round-12 classes are disjoint (intersection: 0 scalars), so neither fix would have found the
other by accident.

5. **(round 13) The MEASURING HARNESS had it too, one layer up — `visibleOrder` in
   `AttachmentFilenameContainmentTests` assumed ONE GLYPH PER UTF-16 UNIT.** It reads a string's
   visible order back out of CoreText by sorting `CTRunGetPositions` left to right and mapping each
   glyph through `CTRunGetStringIndices` to the unit it came from. A **ligature** is one glyph
   standing for two units, so the unit it does not report is silently missing from the
   reconstruction. Measured 2026-08-12: `visibleOrder("Unsupported file name")` returned
   `"Unsupported fle name"` — Helvetica's `fi` ligature — and the assertion reported a string that
   lays out perfectly in order as REORDERED. Fixed by disabling ligatures
   (`kCTLigatureAttributeName = 0`), which narrows the instrument to the bidi ordering it exists to
   measure, plus a new instrument test `layoutOrderHarnessIsFaithful` covering `fi`, `ff`, `fl`,
   `ffl`.

   **Why this instance matters more than its size:** it is the same root — the tool's notion of a
   unit is not the domain's — but the tool was the **oracle**, not the product. The harness had been
   in the tree since the bidi work and was wrong for every ligature-bearing input the whole time;
   nothing caught it because no fixture had ever contained an `fi`/`fl`/`ff` pair, exactly as
   "every fixture anyone naturally writes for a filename is ASCII" below predicts. It surfaced only
   because the round-13 rejection design introduced a user-facing label that happens to contain one.
   Had the failure gone the other way — a ligature masking a real reorder — the suite would have
   been GREEN and wrong, which is the same shape as the tests that blessed the never-drop bugs.
   **The generalisation: a harness that reconstructs one representation from another is subject to
   this class exactly like production code is, and it needs its own non-vacuity test.**

## Why it is not obvious

Swift's default `String` iteration is the **right** default — for text a human reads. It is the wrong
one for a name some other system will parse, and nothing in the API signals which world you are in;
`hasSuffix` has the same spelling for both. Every fixture anyone naturally writes for a filename is
ASCII, where the grapheme view and the scalar view coincide *exactly*, so a test matrix can look
complete, be green, and prove nothing about the property under test.

And the failure is silent in the safe-looking direction. `hasSuffix` returns **false**; nothing
throws, nothing logs, the loader simply returns one extra attachment. A defect that produces "no
match" rather than a crash cannot be found by exercising the happy path, only by asking what the
predicate is really quantifying over.

Finally, the duplication is structural rather than accidental: the draft store and the outbox store
are deliberate twins (`OutboxMessage.saveAttachments` already calls into
`DraftAttachmentStorage.safeAttachmentFileComponent`), so every one of these bugs is born as a pair.
Fixing one and calling it done leaves the SEND path — the worse of the two — broken.

## The rule

When a string's **bytes** are what some other system will parse — a path component, a MIME
parameter, a header, a wire field — do the comparison over `unicodeScalars`, and put the decision in
ONE named function that both the classifier and its fail-closed guard call.

## Mechanical check

```bash
# Grapheme-level String APIs used in files that build or parse names for the filesystem or the wire.
# Every hit needs an answer to "who parses this next?" — a human reader is the only exempt answer.
rg -n 'hasSuffix\(|hasPrefix\(|\.contains\("|split\(separator:|drop\(while:|dropLast\(|dropFirst\(' \
  TabMail/Models/Draft.swift \
  TabMail/Models/OutboxMessage.swift \
  TabMail/Views/Message/AttachmentListView.swift

# Companion check: the twins must stay byte-identical in the parts that make the decision.
python3 <scratchpad>/check_twins.py
```

---

## Pre-compaction index line (verbatim, 2026-08-13, pass 4)

Routed out of the always-loaded `tabmail-ios/MISTAKES.md` by the `companion-compact` skill, which
was reporting that file 62% over its 12,000 B budget. Kept **byte-for-byte**, inside a fenced block
so its index-relative link is not re-resolved from this directory, because the index line had
accumulated recurrence detail that exists nowhere else in this file.

```text
- **[MIS-IOS-013](Companion/Mistakes/Active/MIS-IOS-013-asked-a-byte-level-question-with-a-grapheme-level-string-api.md)** — asked what a filesystem / MIME parameter / wire field will parse, and answered with a `Character`-wise `String` API: `hasSuffix` `hasPrefix` `contains` `split(separator:)` `drop(while:)` `dropLast` are extended-**grapheme**-cluster-wise, so a `Prepend` or combining **scalar** chooses what a cluster is. 4 instances / 6 sites on the attachment-filename path, always born as PAIRS (draft store and outbox store are deliberate twins): `split(separator: "/")` (`05200112d`, twin `711afc6b8`, both `7ce64e44b`); `hasSuffix(".meta")` false for `0_x\u{0605}.meta` → sidecar loaded as a data file and the SEND path emailed the sidecar's own bytes, **and the `ambiguousMetaFilename` fail-closed guard 4 lines away asked the identical question so it declined to fire on exactly its own input** (`2ecdd6370`); `contains("_")`/`drop(while:)` returned the store's `0_` prefix or cut the name at the SECOND `_` (`f5e225419`). ASCII fixtures cannot see it — the two views coincide there — and it fails silently in the safe-looking direction. 🚨 **Instance 5 was in the ORACLE, not the product: the `visibleOrder` CoreText harness assumed ONE GLYPH PER UTF-16 UNIT, so an `fi` LIGATURE made it report an in-order string as REORDERED** (`kCTLigatureAttributeName = 0` + instrument test `layoutOrderHarnessIsFaithful`); wrong since it was written, exposed only by a new label containing `fi` — the other direction would have been GREEN and wrong. **A harness that reconstructs one representation from another needs its own non-vacuity test.** **Compare over `unicodeScalars`, in ONE named function that both the classifier and its guard call.** (×5)
```
