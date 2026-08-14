# MIS-IOS-006 — I reported a test count from a bundle that never rebuilt

**Class:** testing
**Severity:** high
**First seen:** 2026 · **Recurrences:** 5 (**5: the BUILD failed on a peer session's `build.db` lock and
`test-without-building` then ran the PREVIOUS bundle, reporting my red-proof inversion as PASSING —
I had read only the test log**; 4: a brand-new test FILE, never added to the target because
`./Scripts/xcodegen.sh` was not re-run — `** TEST SUCCEEDED **` having executed ZERO of it, with no
count taken at all) · **Status:** Active
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

## Instance 5 (2026-08-11, security-audit fix round) — a RED PROOF reported PASSING, because the build never happened

Verifying an iOS security fix, I inverted the fix to prove the new test was red-first. The test run
reported the inverted code **passing**. I had that backwards: the test was fine and the *build* had
never happened.

```
error: unable to attach DB: … /tmp/tabmail-dd/…/build.db: database is locked
Possibly there are two concurrent builds running in the same filesystem location
```

A peer Claude session was building into the **same shared `derivedDataPath` `/tmp/tabmail-dd`** — which
is the correct path to use (per-job paths once filled 194 GB) and is exactly the contamination the
existing *What actually happened* section already names. `build-for-testing` therefore produced no new
bundle, and `test-without-building` dutifully ran the **previous** one, which still contained the
un-inverted fix. Green.

**What instance 5 adds is a tell about WHICH LOG I READ, and neither existing tell fires on it.**
Instance 1–3's tell is a plausible count; instance 4's is green-plus-relief-with-no-count. Here a
count was taken, it was correct, and it came from a bundle that predated the edit. The tell is:

> *I am reading the verdict out of the TEST log, and I have not looked at the BUILD log at all.*

Compounded by two others in the same command: the failure was two tool calls upstream of where I was
looking, and my compound `xcodebuild … | tail; echo EXIT=$?` reported **`tail`'s** status, so I read
`EXIT=0` off a failed build (root `MIS-023`, and note this shell is zsh — `${PIPESTATUS[0]}` is
`pipestatus` here and does not work either).

**Why "verify by name" does not catch this one.** The by-name check is the countermeasure for
instances 1–4, and it would have passed: the suite name was in the log, because that suite exists in
the stale bundle too. A name proves *selection*, not *freshness*. Only the build log proves freshness.

**The countermeasure, which is now a script rather than a habit** —
`scratchpad/run_until_test.sh` (and its siblings `run_suites.sh`, `run_injection.sh`) do three things
no amount of care does reliably by hand:

1. wait out a peer build — `while pgrep -x xcodebuild >/dev/null; do sleep 20; done` before building
   (**`-x`, never `-f`**: `-f` self-matches the wrapper and deadlocks);
2. **retry** while the log contains `database is locked`, up to a bounded attempt count;
3. **refuse to run any test** unless the build log contains `TEST BUILD SUCCEEDED` — the gate that
   makes a stale-bundle run impossible rather than merely unlikely, and it writes `BUILD FAILED — not
   running tests` into a marker file so the failure is loud in the artifact I actually read.

Never take a verdict — least of all a red-proof verdict — from a test run whose build log you have not
seen say `TEST BUILD SUCCEEDED`. A red proof is the *most* dangerous run to take from a stale bundle,
because the answer it produces ("it passed") is the answer that makes you stop looking.

---

## Pre-compaction index line (verbatim, 2026-08-13, pass 4)

Routed out of the always-loaded `tabmail-ios/MISTAKES.md` by the `companion-compact` skill, which
was reporting that file 62% over its 12,000 B budget. Kept **byte-for-byte**, inside a fenced block
so its index-relative link is not re-resolved from this directory, because the index line had
accumulated recurrence detail that exists nowhere else in this file.

```text
- **[MIS-IOS-006](Companion/Mistakes/Active/MIS-IOS-006-stale-test-bundle-reported-a-wrong-count.md)** — recorded a baseline from a stale `.xctest`; verify new tests ran **by name**, never by total count. A NEW test file is not in the target until `./Scripts/xcodegen.sh` runs, so it reports `** TEST SUCCEEDED **` having executed ZERO of it. A peer build holding `build.db` makes `build-for-testing` fail and `test-without-building` measure the PREVIOUS bundle — so a **red proof reported PASSING**; a name proves *selection*, only the BUILD log proves *freshness*, so gate every run on `TEST BUILD SUCCEEDED`. *Tell: green plus relief, faster than expected, with no count — or reading the verdict from the TEST log having never opened the BUILD log.* (×5)
```
