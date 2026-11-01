# MIS-IOS-029 — called a surviving mutant "equivalent" after tracing only the immediate call, deleted the code, and removed a guard a queued operation needs

**Recurrences:** 1
**Status:** Active
**First recorded:** 2026-10-31

## The tell

> *"Both orders of demo entry and exit give the same outcome, so the pass-through is redundant: delete
> it."* — a survivor explained away by tracing two states of a flag at the moment of the call, with no
> operation waiting in line between the decision and the use.

## What actually happened

A mutation run on `PromptStore.writeAfterRead` (target taken from `capture.demo` versus the live mode)
survived. The reasoning "commitEdit already takes its target from the capture, so the access's own target
is redundant" was checked only for a write made right after entry or exit of the demo. The reviewer's
case was a real capture whose write queues behind a holder while the demo starts and then ends: the access
took the live mode at the call, found the demo started, and was refused as changed when it ran after the
demo ended, although nothing had moved. The "redundant" argument was removed in a commit and came back as
a round-5 finding with a reproduction.

## The rule

A surviving mutant is a missing test until a test fails on it. "Equivalent" needs an argument over every
state an operation can wait through (it can suspend, queue, and run after the state it started under has
changed), not over the state at the call. Write the test for the queued case first; delete the code only
once that test passes both with and without it.

## Census

`PromptStore.writeAfterRead` (target from `capture.demo`, pinned by
`PromptStoreInvariantTests.queuedRealAIResultSurvivesDemoStartAndEnd`) and every caller of `edit` /
`withPromptStore`, whose `demo:` parameter has no default (`DemoFlagReadSitesTests` lists the sites that
read the live flag).
