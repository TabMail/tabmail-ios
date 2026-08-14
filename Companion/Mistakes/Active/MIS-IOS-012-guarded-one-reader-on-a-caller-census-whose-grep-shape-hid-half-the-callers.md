# MIS-IOS-012 — guarded a reader on a caller census whose grep SHAPE hid half the callers

**Class:** census | review
**Severity:** high (the guard was correct; the incomplete census turned it into a silent, permanent
dropped user intention in an outbound-mail path — found by an external audit round, not by me)
**First seen:** 2026-08 · **Recurrences:** 1 · **Status:** Active
**Related:** `MIS-IOS-003` (enumerated the MECHANISM instead of the PROPERTY), `MIS-IOS-011`
(invoked a rule's name instead of running its test) ·
**Rule owner:** `../CLAUDE.md` § Audit rules A7 ("instance or class?")

## The tell

I had just added a guard that makes a function **throw where it previously returned**, and I
answered "who calls this?" with a single `rg` whose pattern embedded the call's *typography*:

```
rg -n "\.fetchAttachment\(for:|fetchAttachment\(for:" TabMail Shared -g '*.swift'
```

Two hits, both in `AttachmentListView`. I moved on and reasoned about the blast radius as if two
call sites were the whole of it. There are **four**. `ComposeView.carryForwardAttachments` and
`EmlAttachmentPreview` wrap their arguments across lines:

```swift
let data = try await AccountManager.shared.fetchAttachment(
    for: reply, section: att.section, encoding: att.encoding
)
```

`fetchAttachment(` and `for:` are on **different lines**, so a single-line pattern requiring both
adjacent cannot match them. The pattern did not fail — it *succeeded*, with a plausible-looking
answer, which is why nothing prompted me to check.

Watch for: a census whose regex contains any of the call's *formatting* — an argument label, a
receiver name, a paren immediately followed by a label. The moment a codebase wraps long calls
(this one does, constantly), that pattern is measuring line breaks rather than call sites. Also
watch for the specific comfort of a **small, tidy** result set right before a change that alters a
function's failure behaviour: two hits is exactly the number that feels like a complete answer.

## What actually happened

I shipped a fail-closed address guard into `AccountManager.fetchAttachment` (commit `0ba2f1353`) to
close a wrong-attachment write: mid-move, `(folderPath, messageId)` names a different message on
IMAP, and the bytes were being cached under the victim's content key with the victim's identity
stamp.

The guard is right. But `ComposeView.carryForwardAttachments` — a caller my census never saw —
catches every error and only `print`s it, by documented design ("failures are logged and skipped");
its rationale was that the user can attach files manually. With the new guard that catch became
**deterministic** during a move, so a forward silently produced a draft with the original's
attachments missing, no chip, no warning, and nothing that re-runs the carry. The user sends an
incomplete message believing it complete. Codex round 7 found it and blocked the candidate; I had
already declared the commit's caller impact analysed.

Two things make this worse than a missed grep:

1. **I had a second, cheap oracle available and did not use it.** The compiler cannot flag it (the
   function already `throws`), but `rg -n "fetchAttachment" TabMail --glob '*.swift'` — the *bare
   symbol*, no shape at all — returns all four in one call. I chose the precise pattern over the
   broad one, on a question where recall matters and precision does not.
2. **The direction of the change is what made the census load-bearing.** Adding a throw to a
   function is only safe if every catch handles it. A census is not documentation here; it *is* the
   correctness argument.

## The countermeasure

When a change makes an existing function throw (or throw in a new state), enumerate callers by the
**bare symbol name only** — never with argument labels, receiver, or punctuation — and then read
**every** catch. Write down, per caller, what its catch does with the new error: retries, reports,
swallows, or terminalizes. A caller whose catch *swallows* is not "unaffected"; it is the one that
converts a transient refusal into a permanent silent loss.

Generalised: **a census's recall is bounded by the incidental formatting its pattern encodes.** If
the pattern would not match the same call reformatted by an autoformatter, it is not a census.

Repaired in the follow-up commit: `carryForwardAttachments` now aggregates failures and surfaces
them in a `CarryForwardFailureAlert`, which also fixes the pre-existing silent-drop on ordinary
network failures.

---

## Pre-compaction index line (verbatim, 2026-08-13, pass 4)

Routed out of the always-loaded `tabmail-ios/MISTAKES.md` by the `companion-compact` skill, which
was reporting that file 62% over its 12,000 B budget. Kept **byte-for-byte**, inside a fenced block
so its index-relative link is not re-resolved from this directory, because the index line had
accumulated recurrence detail that exists nowhere else in this file.

```text
- **[MIS-IOS-012](Companion/Mistakes/Active/MIS-IOS-012-guarded-one-reader-on-a-caller-census-whose-grep-shape-hid-half-the-callers.md)** — added a fail-closed throw to `AccountManager.fetchAttachment` and enumerated its callers with `rg "\.fetchAttachment\(for:"`, which encodes the call's TYPOGRAPHY: two of the four callers wrap their arguments so `fetchAttachment(` and `for:` sit on different lines and cannot match. The unseen `ComposeView.carryForwardAttachments` catches every error and only `print`s it, so the new deterministic refusal turned a forward into a draft SILENTLY missing the original's attachments — a permanent dropped intention in an outbound path, found by codex round 7 after I had declared caller impact analysed. **Enumerate by the BARE SYMBOL when a change makes a function throw, then read every catch and write down whether it retries, reports, swallows, or terminalizes** — a catch that swallows is not "unaffected", it is the one that converts transient into permanent. A pattern that would not match the same call after an autoformatter touched it is not a census. (×1)
```
