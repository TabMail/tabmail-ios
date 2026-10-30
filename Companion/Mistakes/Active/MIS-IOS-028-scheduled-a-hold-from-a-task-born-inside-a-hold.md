# MIS-IOS-028 — scheduled a later prompt-store call from a Task created inside a hold; the Task inherited the hold's task-local mark and every call was refused as nested

**Recurrences:** 1
**Status:** Active
**First recorded:** 2026-10-30

## The tell

> *"The timer fires two seconds later, long after the edit's hold is released, so its own
> `withPromptStore` just takes the semaphore."* — reasoning about WHEN the call runs, not about which
> task-local values the task carrying it was created with.

## What actually happened

The local-edit history timer (`PromptStore.debouncedRecordHistory`) was routed through
`withPromptStore`. The timer is scheduled from `didCommitBullets`, which runs INSIDE the edit's hold. An
unstructured `Task { }` inherits task-locals, so the timer carried `PromptSemaphore.holding` (the edit's
token) and `PromptSemaphore.hold` refused it at once as a nested call (`.busy`). The refusal was only
debug-logged, so local-edit history silently stopped being recorded. Every negative test stayed green,
because "refused" is what they expect. Only the positive control (an ordinary edit records an entry after
the quiet period) went red. The same hazard applies to the received-message chain in `DeviceSyncService`.

## The rule

A task scheduled from inside a hold, that later takes a hold of its own, is created outside the
task-local mark: `PromptSemaphore.$holding.withValue(nil) { Task { … } }`. Every negative test of a
refusal path ships with a positive control that proves the same path can succeed; a refusal test
without one stays green whether the refusal is correct or universal.

## Census

`debouncedRecordHistory` and `DeviceSyncService.applyReceived` are the tasks that take a hold after being
created in one; `PromptSemaphoreTests.taskUnderClearedMarkIsNotNested` pins the pattern.
