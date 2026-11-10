# MIS-IOS-024 — I widened a bound without asking what the bound was protecting

**Class:** design-process
**Severity:** medium (three review rounds; a main-actor multi-second stall would have shipped)
**First seen:** 2026-09 · **Recurrences:** 2 (2: #511, a re-scan loop over an organizer's HTML) · **Status:** Active
**Related:** `MIS-005` (root; the per-group cap was the bug's mirror image, instance 28) · `Companion/Memory/Current/125-html-links-in-converted-text.md` (#162 section) · **Rule owner:** root `CLAUDE.md` § Code Quality 6 (warnings) has no analogue; this entry is the rule

## The tell

A constant is "arbitrary" — nobody can say why it is 4,000 rather than 20,000 — and the bug is
plainly that it is too small. I benchmark the happy path at the larger value, it is fast, and I
raise the number. It feels like the smallest possible diff.

What I never ask is what the bound was *bounding*. A limit that no one can justify usually once
bounded an algorithm that has since been replaced; the replacement's worst case has never been
measured at the wider limit because the limit hid it.

The second form: after the reviewer shows the worst case, I reach for a smaller bound inside the
same construct (a per-group cap, a consuming alternative). Each patch fixes the hostile input and
breaks a valid one. Two such patches in a row means the construct is wrong, not the parameters.

## What actually happened

PR #163 (issue #162). `EmailFilter.snippetLinkScanChars` was 4,000 scalars; the newsletter's
preview leaked because the window cut a link. Widened to 32,000 with a happy-path benchmark.

- Round 2 reviewer: the regex behind `unwrapMarkdownLinks` is quadratic on unclosed-opener runs;
  `[](` × 10,000 measured 3.5 s and `\[` × 16,000 measured 6.8 s at the new window, on the
  main actor, for every call site including the inbox loader.
- My fix: a per-group length cap in the regex. Round 3 reviewer: a complete link longer than the
  cap now stays raw Markdown — the exact symptom the PR fixes (MIS-005).
- My fix: a failure-consuming alternative. Round 4 reviewer: `[a](x[b c](y)` skips the valid
  `[b c](y)`.
- Replaced the regex with a linear precomputed-closure scanner; fuzzed equal to the regex on
  600,000 strings; round 4 clean on the construct, rounds 5–6 on tests only.

## Recurrence 2: #511, a loop that re-scanned for each candidate (2026-11)

No bound was widened this time; the second form of the same tell. To pass over copies of an online
meeting's join link in the organizer's notes, `GraphOnlineMeetingBody.joinSection` looped over every
copy and, for each, re-scanned the notes from their start for a line of underscores. That is O(k·n)
in the copies k and the body n, on HTML any meeting organizer writes, run on every Outlook calendar
read. The tier-1 reviewer found it by reading. The fix replaced the algorithm, as this entry's rule
says: a copy has a line before it exactly when it starts after the first line is complete, so one
search from that point is linear and returns the same anchor. `manyLinkCopies` is the bounded-time
test with a hostile fixture. The tell to watch: a loop whose body scans from a FIXED start (not from
where the loop stands) over content someone else writes.

## Why it is not obvious

The bound *was* arbitrary in the sense that its value had no derivation. But its existence was
not: it was the only thing keeping a quadratic scanner's worst case below a frame. The happy-path
benchmark answered "is a normal email fast at 32K" and could not answer "what is the worst input
at 32K", and hostile Markdown is exactly what a text/plain body from an unknown sender can be.

## The rule

Before widening a limit, write down the complexity of the code the limit feeds in terms of that
limit and benchmark the adversarial input, not the typical one; if the answer is worse than
linear, replace the algorithm rather than tuning caps inside it.

## Mechanical check

```bash
# Every scan-window constant must have a bounded-time test naming a hostile fixture.
cd tabmail-ios && for c in $(rg -o 'static let (\w+)(Chars|Scalars|Window)\b' -r '$1$2' Shared TabMail | sort -u); do
  rg -q "$c" TabMailTests && rg -lq 'elapsed|ContinuousClock|Date\(\)\.timeIntervalSince' $(rg -l "$c" TabMailTests) || echo "NO bounded-time test for $c"
done
```

---

## Pre-compaction index line (verbatim, 2026-11-09)

Routed out of `tabmail-ios/MISTAKES.md` by the `companion-compact` skill (13026 B against
its 12,000 B budget). The index keeps a shortened line; this is the line it replaced,
**byte-for-byte**, source line 50 at `6597c3a7`.

<!-- BEGIN VERBATIM INDEX LINE MIS-IOS-024 2026-11-09 -->

```text
- **MIS-IOS-024** — **widened a scan window (`snippetLinkScanChars` 4,000 → 32,000) on a happy-path benchmark without asking what the bound was protecting**: the regex behind `unwrapMarkdownLinks` was quadratic on unclosed `[](` / `\[` runs (3.5–6.8 s on the main actor at the new window); two cap-inside-the-regex patches each broke a valid link (MIS-005 ×28) before the construct was replaced by a linear scanner (#162, PR #163). Benchmark the ADVERSARIAL input in terms of the limit; worse than linear ⇒ replace the algorithm, never tune caps. (×1)
```

<!-- END VERBATIM INDEX LINE MIS-IOS-024 2026-11-09 -->
