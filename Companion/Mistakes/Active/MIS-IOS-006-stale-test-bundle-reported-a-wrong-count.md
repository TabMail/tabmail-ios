# MIS-IOS-006 — I reported a test count from a bundle that never rebuilt

**Class:** testing
**Severity:** high
**First seen:** 2026 · **Recurrences:** 4 (**4: a brand-new test FILE, never added to the target because
`./Scripts/xcodegen.sh` was not re-run — `** TEST SUCCEEDED **` having executed ZERO of it, with no
count taken at all**) · **Status:** Active
**Related:** root `MIS-013` (see `../MISTAKES.md`)

## The tell

The suite ran, the count looks plausible, and it is close to the number I expected. I am about to
record it as the verification baseline without confirming that my new tests are in it **by name**.

## What actually happened

A stale `.xctest` bundle produces a **wrong test count** that still reads as a clean run. Two
distinct causes: a project that was never regenerated (`./Scripts/xcodegen.sh` not run, so new files
are not in the target), and concurrent builds sharing one `derivedDataPath` where one job's artifacts
are read by another.

A compounding trap on the same surface: a `fatalError` truncates a run that still **reads clean** —
which is why array access after a count assertion must be guarded (`guard array.count == N else
{ return }`), since Swift Testing does not catch `fatalError` and one crash can hide thousands of
results.

## Why it is not obvious

Test counts drift legitimately all the time, so a number that moved is unremarkable and a number that
did not move is reassuring. Neither observation distinguishes "ran" from "was not built".

## The rule

Verify new tests ran **by name**, not by total count; regenerate the project and clean before any
baseline measurement.

## Mechanical check

```bash
./Scripts/xcodegen.sh && xcodebuild clean build-for-testing ...
rg -c 'Test Case .*<NewTestName>.* (passed|failed)' <log> || echo 'NEW TEST NEVER RAN'
```

Use the one shared `derivedDataPath` (`/tmp/tabmail-dd`) — per-job paths once filled 194 GB — but
remember that disjoint file **paths** do not mean disjoint **verification**: concurrent agents
sharing one derivedData contaminate each other's builds.

## Instance 4 (2026-08-07, pre-ship round) — `** TEST SUCCEEDED **` with zero tests run, and no count was ever taken

The fix agent added a **brand-new test file** and got a green build having executed **nothing**. A new
file is invisible to the target until `./Scripts/xcodegen.sh` regenerates the project, so the file
compiled nowhere, ran nowhere, and the build reported success — correctly, because nothing about the
build had failed.

**The cause is already named in *What actually happened* above** ("a project that was never
regenerated … so new files are not in the target"). That is exactly why this is a recurrence and not a
new entry: the countermeasure was written down, it is correct, and it was not reached for.

**What instance 4 adds is a different TELL, and the existing one cannot fire on it.** This entry's tell
is *"the count looks plausible and it is close to the number I expected"* — it assumes a count was
taken. Here no count was taken at all. The actual tell was:

> *green plus relief, arriving faster than expected, with no count.*

That is the version worth carrying, because it fires **earlier** than the count-shaped one and in the
case the count-shaped one is blind to. A run that finishes sooner than the work you gave it should is
the signal; the absence of a number is not reassuring, it is the finding.

**Same symptom, three distinct causes, now catalogued in one place** — root `MIS-013` (a bare
`-only-testing:` selector, and a bare `()` on a parameterized `@Test(arguments:)`), this entry's
instances 1–3 (a stale `.xctest`, a shared `derivedDataPath` contaminated by a concurrent build), and
instance 4 (target membership). All three produce a green run that executed less than you think, and
**none of them is detectable from the exit status or the `** TEST SUCCEEDED **` marker.** Only the
by-name check is:

```bash
./Scripts/xcodegen.sh && xcodebuild clean build-for-testing …
rg -c '<NewSuiteName>' <log> || echo 'NEW TEST NEVER RAN'
```

Run it after adding **any** new test file, before quoting any result from that run.
