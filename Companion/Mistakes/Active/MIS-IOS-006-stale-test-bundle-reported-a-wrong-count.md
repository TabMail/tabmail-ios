# MIS-IOS-006 — I reported a test count from a bundle that never rebuilt

**Class:** testing
**Severity:** high
**First seen:** 2026 · **Recurrences:** 3 · **Status:** Active
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
