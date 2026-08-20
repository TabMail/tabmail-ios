# MIS-IOS-014 — wrote a red-first proof that could not run red: the inverted build TRAPPED instead of failing

**Class:** testing
**Severity:** medium (the evidence the gate depends on could not be produced; a run that hides every
other result looks identical to a run that never started)
**First seen:** 2026-08 · **Recurrences:** 1 · **Status:** Active
**Related:** `MIS-IOS-006` (a test run that reported a number it had not measured) ·
**Rule owner:** `../CLAUDE.md` § Testing Rules 9

## The tell

I have just written a test that **measures** something — bisected a filesystem limit, read a budget
back out of the implementation, counted a set — and I am now building fixtures out of that
measurement:

```swift
let budget = bisectWhatThePredicateAccepts()
try expectSavesAndReloads(filename: String(repeating: "a", count: budget - 4) + ".pdf", …)
let inBudget = base + String(repeating: mark, count: runBudget - 1)
```

It reads as the *most* rigorous thing in the file — nothing is hardcoded, every constant is measured
in situ, the test re-derives its own boundaries on whatever machine it runs on. That is the feeling
to distrust. **A derived length is a fixture that depends on the code under test, and the red run is
exactly the run where that code returns something degenerate.** I am about to invert the
implementation to prove the assertions can fail, and the assertions will never be reached.

The specific comfort: "this can't be negative, the budget is 230". It is 230 *when the code is
right*. The whole point of the next run is that the code is not.

## What actually happened

Round 13 (replace filename REDUCTION with REJECTION), 2026-08-12. The rewritten containment suite
bisects two real limits against the filesystem and two matching budgets out of
`AttachmentFilename.isSafeFileComponent`, then builds fixtures from them —
`String(repeating: "a", count: budget - 4)` in the length test and
`base + String(repeating: mark, count: predicateRunBudget - 1)` in the combining-run test.

The red-first protocol required the predicate inverted in both directions. **RED-A** (forced `true`)
worked: 16 tests failed with 486 issues, exactly the reject side of the suite. **RED-B** (forced
`false`) made both bisections return **0**, so both fixtures asked for a string of negative length:

```
Swift/StringLegacy.swift:31: Fatal error: Negative count not allowed
```

`String(repeating:count:)` traps. Swift Testing cannot catch a `fatalError`, so the test host died —
and `xcodebuild` relaunched it and it died again, five times over, each attempt writing another
~1,500 lines of relaunch noise into a 1.5 MB log. 101 genuine `✘` issues had already been recorded
before the first crash, which is why the run *looked* like it was working. It had to be killed
manually (`TEST EXIT=143`). The suite could not produce the evidence it exists to produce.

Fixed by asserting the budget is plausible and returning early if it is not, at both sites, with the
measurement recorded at the guard rather than in a commit message.

## Why it is not obvious

Repo Testing Rule 9 already says to guard before array access after a count assertion, and this is
the same failure mode — a trap takes the whole process, so one degenerate fixture hides thousands of
unrelated results. But rule 9 names `array[0]`, and nothing here indexes anything. The trap arrives
through `count:`, in a call that has no bracket in it, in the one file where the author has been
congratulating himself for not hardcoding constants.

It is also invisible in every run that matters day to day. The suite is green, and green is the state
where the measurement is correct and the fixture is fine. The defect exists **only** in the inverted
build — the run nobody does twice, whose output nobody reads carefully because "of course it fails,
that is the point".

## The rule

Any fixture whose SIZE is derived from a measurement must assert the measurement is plausible and
`guard … else { return }` before constructing anything from it — because the red run is precisely
where the measurement is degenerate.

## Mechanical check

```bash
# Fixture sizes derived by arithmetic from a measured value: every hit needs a guard above it.
rg -n 'repeating:.*count: *[A-Za-z_][A-Za-z0-9_]* *[-+/]' TabMailTests/
rg -n 'prefix\(|dropLast\(|dropFirst\(' TabMailTests/ | rg ' *[-+] *[0-9]'

# And the run-level check: a red proof that crashed is not a red proof.
grep -c 'Fatal error' <scratchpad>/test-<tag>.log     # must be 0
grep -c 'Test run with' <scratchpad>/test-<tag>.log   # must be 1 — more than one means relaunches
```

---

## Pre-compaction index line (verbatim, 2026-08-13, pass 4)

Routed out of the always-loaded `tabmail-ios/MISTAKES.md` by the `companion-compact` skill, which
was reporting that file 62% over its 12,000 B budget. Kept **byte-for-byte**, inside a fenced block
so its index-relative link is not re-resolved from this directory, because the index line had
accumulated recurrence detail that exists nowhere else in this file.

```text
- **[MIS-IOS-014](Companion/Mistakes/Active/MIS-IOS-014-wrote-a-red-first-proof-that-could-not-run-red.md)** — wrote a red-first proof that **could not run red**: fixtures SIZED from an in-situ measurement (`count: budget - 4`) asked for a NEGATIVE length once the inverted code bisected to 0, and `String(repeating:count:)` **TRAPS** — uncatchable, host died, `xcodebuild` relaunched 5x and buried 101 real `✘`. Rule-9 class with **no bracket in the line**, and invisible in every GREEN run. *Tell: "nothing is hardcoded, every constant is measured in situ" — a derived length depends on the code under test.* **`guard` the measurement before building anything sized from it; `Fatal error` in the log or >1 `Test run with` line = not evidence.** (×1)
```

---

## Pre-compaction index line (verbatim, 2026-08-20, pass 5)

Routed out of the always-loaded `tabmail-ios/MISTAKES.md` by the `companion-compact` skill, which
was reporting that file 19% over its 12,000 B budget. Kept **byte-for-byte**, inside a fenced
block so its index-relative link is not re-resolved from this directory, because the index
line had accumulated recurrence detail that exists nowhere else in this file.

```text
- **[MIS-IOS-014](Companion/Mistakes/Active/MIS-IOS-014-wrote-a-red-first-proof-that-could-not-run-red.md)** — wrote a red-first proof that **could not run red**: fixtures SIZED from an in-situ measurement (`count: budget - 4`) asked for a NEGATIVE length once the inverted code bisected to 0, and `String(repeating:count:)` **TRAPS** — the host died, `xcodebuild` relaunched 5× and buried 101 real `✘`. Invisible in every GREEN run. *Tell: "nothing is hardcoded, every constant is measured in situ" — a derived length depends on the code under test.* **`guard` the measurement first; `Fatal error` in the log or >1 `Test run with` line = not evidence.** (×1)
```
