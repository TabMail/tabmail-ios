
### A path component is capped in NFD UTF-16 units — not in UTF-8 bytes, and not in `Character`s

**Measured 2026-08-12** while implementing the owner's truncate-overlong-attachment-filenames
decision (`DraftAttachmentStorage.safeAttachmentFileComponent` and its co-edit twin
`AttachmentPreviewStager.displayFilename`). Bisected against a real filesystem — macOS host APFS and
again inside the `iPhone 17 Pro` simulator — rather than read off a document.

> ⚠️ **THE MEASUREMENTS BELOW ARE STILL CURRENT; THE MECHANISM THEY DESCRIBE IS NOT.** Later the same
> day the owner replaced the whole **reduction** — strip filter, unassigned filter, combining-run cap,
> truncation, emptied-stem refill — with a **rejection**: one shared predicate,
> `AttachmentFilename.isSafeFileComponent`, called by `DraftAttachmentStorage.saveAttachments`,
> `OutboxMessage.saveAttachments` and `AttachmentPreviewStager.createAttempt`, which **throws**
> `AttachmentFilenameError.unsupported` instead of transforming the name; display sites render
> `AttachmentFilename.displayLabel`. Both named functions above, and the twin duplication between
> them, are **DELETED**. Every threshold, sweep and counterexample recorded here survived the change —
> they are now the predicate's *acceptance boundary* rather than a reduction's *target*. Read every
> sentence below that says "stripped", "truncated", "reduced" or "capped" as **"refused"**. Five
> confirmed defects across rounds 10–12 all lived in the reduction machinery and none in the
> classification, which is the reason for the change; see the ADR under
> `Companion/Decisions/` and `DECISIONS.md`.
>
> Two consequences that are NOT obvious and were re-derived at cost:
> * **Rejecting at save does not make the loaders safe.** `DraftAttachmentStorage.metaBase` and
>   `afterIndexPrefix` — and their tests — stay. A name can pass all six rules and still defeat
>   `Character`-wise parsing, because the character that grapheme-merges is one the **store** adds:
>   `"\u{0301}foo.pdf"` merges with the `"\(index)_"` prefix, `"invoice\u{0605}"` merges with the
>   `.meta` sidecar's dot. The predicate answers *storability*; the loaders answer *recovering what
>   was stored*.
> * **The user-facing message is REASON-AGNOSTIC** (owner, 2026-08-12). Length is one rule of six —
>   a 48-unit name with an over-long combining run is refused nowhere near the budget — so a
>   length-specific message is simply false for rules 2–5. One message for all six, no per-rule table,
>   no diagnostic breadcrumb, and the rare false rejection of a legitimate long Hangul name is an
>   accepted cost rather than a gap to engineer around.

**The predicate.** A single path component is accepted iff

```
name.decomposedStringWithCanonicalMapping.utf16.count <= 255
```

Over-length writes fail `NSCocoaErrorDomain` 514 wrapping `NSPOSIXErrorDomain` 63
(`"File name too long"`). Both of the obvious guesses are wrong, and wrong in OPPOSITE directions,
so neither is a safe conservative approximation:

| unit you might assume | counterexample | what actually happens |
|---|---|---|
| 255 UTF-8 **bytes** | 86 × `U+6F22` (漢) = **258 bytes** | **stores fine** — the byte count is not the limit |
| 255 **`Character`s** | 128 × `U+00E9` (é) = 128 characters, 128 UTF-16 units | **REFUSED** — APFS decomposes it to 256 units |

Bisected maxima, all consistent with the predicate: ASCII 255 · `U+6F22` 255 · Devanagari `U+0915`
255 · `U+00E9` 127 · `U+00FC` 127 · `e`+`U+0301` 127 · Hangul `U+AC00` 127 · `U+1F600` 127 ·
`U+1E69` (s + two dots, NFD = 3 scalars) 85 · Vietnamese `U+1EC7` 85 · 🇨🇦 (2 regional indicators)
63 · `U+1F468 U+200D U+1F469 U+200D U+1F466` (ZWJ family) 31. Cross-checked over **400 randomised
mixed strings straddling the boundary: 0 disagreements**.

**Consequence for code — both wrong units are wrong in the UNSAFE direction, so neither is an
acceptable conservative stand-in.** Swept over all 194,528 scalars in `U+0020…U+2FFFF`:
`utf8.count` under-counts the real unit for **73** of them (`U+01D5` Ǖ is 2 UTF-8 bytes and
decomposes to `U+0055 U+0308 U+0304` = 3 UTF-16 units, ratio 2/3 — so a 255-BYTE budget of `U+01D5`
is 382 units and is REFUSED), and `count` (grapheme clusters) under-counts for **142,832** of them.
`utf8.count` additionally over-counts CJK, which is merely wasteful. The live constant is
`DraftAttachmentStorage.maxPathComponentUnits` = 255, and what a reduced filename may actually spend
is `attachmentComponentBudgetUnits` = `255 - String(Int.max).count - 1 - ".meta".count` = **230**,
because what has to fit is the DERIVED name: `saveAttachments` writes `"\(index)_\(component)"` plus
a `"\(that).meta"` sidecar, and the sidecar is the longest of the three. Pinned by
`AttachmentFilenameContainmentTests`, whose measured-cap test re-derives the cap by bisection
wherever the suite runs instead of trusting the constant.

**The failure this closed.** An overlong sender-authored MIME `filename` made
`DraftAttachmentStorage.saveAttachments` and `OutboxMessage.saveAttachments` THROW, so the draft was
never persisted and `queueSend` failed — the message could not be sent until the user removed the
attachment. On the preview path the same name made the atomic write fail, so the user got no preview
at all. Note the boundary is asymmetric between the two files a save writes: for an ASCII stem of
length `L` plus `".pdf"`, the sidecar overflows at `L >= 245` while the data file only overflows at
`L >= 250`, so there is a five-wide band where the bytes land and only the metadata is refused.

**⚠️ SEPARATE OBSERVATION — CLOSED 2026-08-12, and the observation itself was WRONG about the set's
extent.** It was recorded here as "`CharacterSet.controlCharacters` covers category Cf, not just
Cc". **It covers far more than Cf.** Re-measured by sweeping all of `U+0000...U+10FFFF` on Apple
Swift 6.3.3, the set holds **24,970** scalars: Cc **65**, Cf **170**, nonspacing marks **97**
(`U+E0101`, `U+E0120...U+E017F`), and **24,638** scalars the standard library reports **unassigned**
— essentially all of plane 14. Cc ∪ Cf is only 235, so "Cc ∪ Cf" understated it by two orders of
magnitude. The practical consequence is that **`controlCharacters.subtracting(<the Cf scalars>)` is
NOT a way to recover Cc**; an explicit range test is, and the same sweep confirms Cc is exactly
`U+0000...U+001F` plus `U+007F...U+009F` with zero members outside.

The mangling was also worse than recorded. Beyond `U+200D` ZWJ flattening `👨‍👩‍👦report.pdf` into
`👨👩👦report.pdf`, the `U+E0020...U+E007F` TAG characters are Cf too, so a tag-sequence flag emoji
(Scotland `🏴󠁧󠁢󠁳󠁣󠁴󠁿`) was reduced to a plain black flag `🏴` **at the same character count** — a
count-based check could not have seen it. `U+200C` ZWNJ is a letter-shaping distinction in Persian.

**The fix narrows the strip to `DraftAttachmentStorage.strippedFilenameScalars` (and its co-edited
twin in `AttachmentPreviewStager`): Cc, plus an ENUMERATED bidi block `U+202A...U+202E` and
`U+2066...U+2069`.** The bidi half is a real anti-spoofing property and must survive any later
narrowing — measured through CoreText by differencing visible glyph order against the same name
without the scalar, `"report\u{202E}fdp.exe"` lays out to a human as `reportexe.pdf`. On an
all-Latin name `U+202E` RLO is the **only** attributable one; LRE/RLE/PDF/LRO/LRI/RLI/FSI/PDI change
nothing there, but they DO reposition runs once a strong RTL character is present (Trojan-Source,
CVE-2021-42574) and have no legitimate role in a filename.

~~**`U+200E`/`U+200F`/`U+061C` (LRM/RLM/ALM) are deliberately KEPT — and NOT because they are
"weaker".** Measured in the same differential harness, in a mixed-direction name RLM repositions a
run exactly as RLI does. They are kept because they cannot reverse a run of strong LTR characters,
so they cannot manufacture the all-Latin extension swap, and because they are the only means of
fixing the order of a genuine Arabic or Hebrew filename.~~

🚨 **OVERRULED THE SAME DAY (2026-08-12, commit `592bd9922`) — the marks ARE stripped now, by owner
decision ("strip them everywhere"), and the paragraph above is preserved struck-through because HOW
it was wrong is the durable part.** Its premise is still true: a mark cannot reverse a run of strong
LTR characters. Its conclusion does not follow, because **a mark does not have to reverse anything
INSIDE a run — it reorders the RUNS.** Re-measured with the same CoreText glyph-position readback:

```
"\u{200F}pdf\u{200F}.exe"     logical ext = .exe   VISIBLE = exe.pdf        <-- SPOOF
"\u{061C}pdf\u{061C}.exe"     logical ext = .exe   VISIBLE = exe.pdf        <-- SPOOF
"\u{200E}pdf\u{200E}.exe"     logical ext = .exe   VISIBLE = pdf.exe        (LRM: no reorder here)
"report\u{200F}fdp.exe"       logical ext = .exe   VISIBLE = reportfdp.exe  (no spoof)
"report\u{202E}fdp.exe"       logical ext = .exe   VISIBLE = reportexe.pdf  (known RLO spoof)
```

⚠️ **WHY THE MEASUREMENT MISSED IT, WHICH IS THE TRANSFERABLE PART — and it is a recurrence of
`MIS-030` (a fixture that never held the precondition), not of `MIS-014`.** The harness was real,
the differencing was real, and the conclusion was still safe-looking because **every fixture it ever
fed the harness began with strong-LTR text (`report…`)**, which anchors the paragraph direction and
makes the swap structurally impossible. The spoof needs a **leading** mark. `bidiControlsAndCcAreStripped`
had exactly that anchored shape and was therefore green while the bug was live, for two rounds. A
"we measured it" claim inherits whatever its fixture's shape can exhibit; ask what the fixture
FORBIDS before trusting a negative result. LRM is stripped with the other two even though it did not
reorder this fixture, because "this mark reorders and that one does not, in this paragraph context"
is not a distinction a filename can carry.

The legitimate use the marks had — fixing the order of a mixed Arabic or Hebrew filename — does not
need them: measured, `דוח.pdf` lays out as `pdf.חוד` with no explicit mark present, i.e. a name's own
strong-RTL letters order correctly on their own.

**Two more scalars joined the strip in the same commit, for two DIFFERENT reasons, and neither was
introduced by the narrowing.**

- **`U+2028` (Zl) and `U+2029` (Zp) — RENDERING.** Measured with `CTTypesetterSuggestLineBreak` at
  100,000pt so the break is mandatory rather than width-driven: `"invoice.pdf\u{2028}.exe"` breaks
  after `invoice.pdf`, so a `.lineLimit(1)` label shows a PDF. Sweeping for the property found
  exactly seven mandatory-break scalars — `U+000A`, `U+000B`, `U+000C`, `U+000D`, `U+0085`, `U+2028`,
  `U+2029` — and the first five were already stripped, but only incidentally, because they are Cc.
- **Every `unassigned` scalar — THE FILESYSTEM.** Swept over all of `U+0000...U+10FFFF` as a real
  path component on APFS: the set the filesystem REFUSES is **exactly** the scalars whose general
  category is `unassigned` — **814,730** of them, **zero disagreements in either direction** —
  with `open(2)` itself raising `EILSEQ` (errno 92), surfacing as `NSCocoaErrorDomain` 512 /
  `NSPOSIXErrorDomain` 92. `"invoice\u{0378}.pdf"` reduced unchanged, satisfied the containment
  probe, and then made `saveAttachments` THROW — the draft never persisted and `queueSend` failed,
  i.e. **the same user-visible failure the length truncation was written to remove, reached by a
  different input.** ⚠️ **The narrowing WIDENED this hole rather than opening it**: bare
  `CharacterSet.controlCharacters` covered 24,638 of these (essentially all of plane 14), the
  narrowed `strippedFilenameScalars` covers **0**, and the other **790,092** were never covered by
  either. The predicate is the scalar's own `properties.generalCategory` rather than a range list,
  because a range list goes stale at every Unicode revision. **Verified post-fix against the
  filesystem, not against the documentation:** reduce `"invoice<scalar>.pdf"` for every scalar and
  write the widest name any caller derives (`"<Int.max>_<reduced>.meta"`) — 1,112,064 scalars,
  **0 write failures**.

**The shipped set is now 79 scalars** (was 74): Cc `U+0000…U+001F` + `U+007F…U+009F`, `U+061C`,
`U+200E…U+200F`, `U+2028…U+2029`, `U+202A…U+202E`, `U+2066…U+2069` — measured on the shipped
expression itself, with all 79 must-strip scalars present and all 14 must-keep scalars absent.

**One further correction to the LENGTH contract, same commit.** The doc promised that length
truncation "never yields `Attachment`". False in both directions, because **one extended grapheme
cluster can be wider than the whole budget**: `"a" + 300 × U+0301 + ".pdf"` is five `Character`s
costing 305 units, of which the stem is a single 301-unit cluster, so grapheme-boundary truncation
kept no part of it and returned `".pdf"` — whose `pathExtension` Foundation reports as **EMPTY**, so
the preserved type was lost to QuickLook and the outbox MIME path — while the no-extension variant
returned `"Attachment"`. The stem now becomes `"Attachment"` and the extension survives
(`"Attachment.pdf"`), and the contract states that instead of the absolute.

Stripping the format characters was never load-bearing for CONTAINMENT: `U+002F` is in none of these
sets (the scalar-wise `split` handles it), `U+0000` is Cc and still goes, and `.`/`..` are refused by
the outcome probe, which is unchanged and remains the last word.

⚠️ **`AttachmentFilenameContainmentTests` was BLESSING this**, despite a comment saying it
"deliberately does not bless" it. Its multi-byte truncation test recomputed its baseline with the
**same `CharacterSet.controlCharacters` predicate the reducer used**, so the baseline tracked the
defect exactly: green on the flattening, and red on the fix. A baseline derived from the defect's own
predicate is a blessing test whatever the comment claims. Re-baselined onto the RAW stem.

## 🚨 THE ROOT MECHANISM — one named constant, TWO different sets (measured 2026-08-12)

Both the filename defect above and the `MessageIdentity` guard's behaviour follow from a single
Foundation property, isolated by probe rather than inferred:

> **SOME set operations on a BUILT-IN `CharacterSet` materialise it to a different set — and WHICH
> ONES IS NOT PREDICTABLE FROM THE EXPRESSION.** For `controlCharacters` the materialised value is
> exactly Cc ∪ Cf (65 + 170 = 235); used DIRECTLY via `.contains` the same constant is 24,970.

⚠️ **This entry said "ANY set operation" until it was falsified the same day, by the peer
`ios-security-audit` session, and the corrected rule is WORSE for the reader than the wrong one.**
Three counterexamples, all re-measured independently here:

```
controlCharacters                                = 24970   bare
  .subtracting(CharacterSet())                   =   235   COLLAPSES  <-- identity
  .union(CharacterSet())                         = 24970   PRESERVES  <-- identity
  .union(controlCharacters)      (union w/ SELF) =   235   COLLAPSES
  .intersection(controlCharacters)               =   235   COLLAPSES
  .inverted.inverted                             = 24970   PRESERVES
  var c = …; c.formUnion(CharacterSet())         = 24970   PRESERVES
  whitespacesAndNewlines.union(controlCharacters)=   254   (235 + 26 - 7 shared)
  controlCharacters.union(<constructed a-z>)     =   261   = 235 + 26
  <constructed>.union(<constructed>)             =    27   exact; constructed sets never collapse
```

`subtracting(CharacterSet())` and `union(CharacterSet())` are **the same identity operation and give
different answers.** So the discriminator is not "an operator was applied", not the operand, and not
ordering — it is **whether the implementation took a fast path, which the source text does not
reveal.** Under the wrong headline an author could at least reason from the expression; under the
true rule two spellings of one identity disagree and nothing in the code says which you got.

⚠️ **"Materialises to Cc ∪ Cf" is specific to `controlCharacters` and is NOT the general behaviour —
`illegalCharacters` moves the OPPOSITE way.** Swept across 20 built-in sets, bare vs
`.subtracting(CharacterSet())`: exactly **two** are unstable, in opposite directions.

```
controlCharacters    24970 ->    235   -24735   COLLAPSES
illegalCharacters   796458 -> 820957   +24499   EXPANDS
nonBaseCharacters     2543 ->   2543        0   stable
whitespaces · newlines · whitespacesAndNewlines · alphanumerics · letters ·
lower/upper/capitalizedLetters · decimalDigits · punctuationCharacters ·
symbols · urlPath/Query/Host/Fragment/User/PasswordAllowed          all delta 0
```

So the class is **exactly `controlCharacters` and `illegalCharacters`** — bounded, not open-ended.
Anything shaped `x.subtracting(.illegalCharacters)` yields a set **24,499 scalars broader** than
`.illegalCharacters.contains` predicts, which for a *rejection* predicate is the dangerous direction.

### The bare set is INCOHERENT in plane 14 — it splits the variation-selector block

The bare constant cannot be described as any category union at all:

```
plane-14 Mn LOST by the operator : 97  -> U+E0101, U+E0120–U+E017F
plane-14 KEPT by the operator    : 97  -> U+E0001, U+E0020–U+E007F  (tag chars; these are Cf)
plane-14 Mn in Unicode           : 240 -> U+E0100–U+E01EF
plane-14 Mn NOT in bare control  : 143 -> U+E0100, U+E0102–U+E011F, U+E0180–U+E01EF
```

**Bare `controlCharacters` contains `U+E0101` but NOT `U+E0100` and NOT `U+E0102`–`U+E011F`.** No
Unicode property partitions the variation-selector supplement that way. Verified here:
`U+E0100`, `U+E0102`, `U+E0180` are all OUT of the bare set.

🚨 **Consequence for TESTS, and this round came within one scalar of it.** "The pre-fix code stripped
variation selectors" is TRUE for `U+E0101` and `U+E0120`–`U+E017F` and **FALSE** for `U+E0100`,
`U+E0102`–`U+E011F`, `U+E0180`–`U+E01EF`. A red proof that reached for a *generic* variation-selector
exemplar had a **143-in-240 chance of picking one the bare set never contained** — the strip would
not have fired, the bug would have looked absent, and a test written to match that observation would
have blessed it ([[feedback_tests_that_bless_the_bug]]).

`AttachmentFilenameContainmentTests` is safe, and the reason it is safe is the transferable lesson:
its exemplars are `U+E0101` and the `U+E0020`–`U+E007F` tag characters (verified IN the bare set),
and they are there because they came from the **observed defect** — the actual mangled filename in
the bug report — not from someone choosing a representative of a category. **An exemplar drawn from
an observed failure is grounded; an exemplar drawn from a category name inherits whatever artefact
the category has.**

⚠️ **The intuition inverts, which is why this is a trap rather than a curiosity.** 235 is exactly
Cc ∪ Cf — the set the documentation leads every author to expect. The operators do not corrupt the
set; they collapse it *to the documented one*. **The bare constant is the anomaly.** An author who
writes `.union(...)` accidentally gets the sane set; an author who writes plain `.contains` gets the
surprising one. Consequences, both verified in this tree:

- `DraftAttachmentStorage.safeAttachmentFileComponent`'s pre-fix body used bare
  `CharacterSet.controlCharacters.contains($0)` ⇒ 24,970 scalars ⇒ it ate `U+E0101` and the
  `U+E0020`–`U+E007F` tag characters and flattened a ZWJ family emoji. That is the defect above.
- The RFC message-id guard in `MessageIdentity` writes
  `CharacterSet.whitespacesAndNewlines.union(.controlCharacters)` ⇒ 254 scalars ⇒ it never reaches
  plane 14 at all. Same constant, opposite exposure, operator is the entire difference.

**Constructed sets are exact.** The committed `strippedFilenameScalars` is four chained `.union(...)`
calls over `CharacterSet(charactersIn:)` ranges and measures **74** — the full set-theoretic result,
all 13 must-strip scalars present, all 10 must-keep scalars absent. Only built-in operands collapse.

⚠️ **A verification-method warning attached to that number.** The first behavioural probe of the
narrowed reducer tested a hand-written *mirror* of the predicate rather than the shipped
`CharacterSet` expression, and reported it as verification of the fix. A mirror can diverge from its
original at exactly the point under investigation — here, whether chained `union` preserves the
ranges. The 74 above comes from re-measuring the **shipped expression itself**. When the property
under test is "does this library type behave as written", a reimplementation proves nothing about the
artifact ([[feedback_verify_the_instrument_not_just_the_claim]] in the session memory).
