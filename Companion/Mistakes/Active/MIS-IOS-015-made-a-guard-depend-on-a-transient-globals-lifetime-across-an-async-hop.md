# MIS-IOS-015 — made a guard depend on a transient global's lifetime, across an async hop, and read the ordering off a log that could not distinguish it

**Recurrences:** 1
**Status:** Active
**First recorded:** 2026-08-12

## The tell

> *"The overlay is registered before the enqueue and released after the write, so it is definitely
> still live when my handler runs."* — a lifetime asserted from where the retain/release **calls**
> sit in the source, for a handler that does not run in that call's turn.

Adjacent, weaker tell: *the log shows the two events in the order I need, so the order is settled.*
A log line proves when a `print` executed, not when a **state mutation** happened, and it never
proves an ordering is **guaranteed** rather than **observed once**.

## What actually happened

Fixing the Archive → Inbox invisible-row defect (owner report 2026-08-11), the first version of the
guard asked `AccountManager.snapshotOverlayMutation(forCurrentHeaderId:)` for the move's destination
folder inside `InboxView`'s `.messageDismissedFromDetail` receiver:

```swift
func actionKeepsMessageInDisplayedList(_ messageId: String) -> Bool {
    guard let destinationFolderId = manager
        .snapshotOverlayMutation(forCurrentHeaderId: messageId)?.mutation.folderId
    else { return false }          // ← no overlay ⇒ dismiss, i.e. the bug
    return displaysFolder(destinationFolderId)
}
```

The doc comment I wrote for it asserted the overlay "is live for the whole window in which the
dismissal notification is delivered." That publisher carries `.receive(on: DispatchQueue.main)`, so
the handler runs in a **later** main-queue turn than the `post`. `MessageDetailViewModel.move`
retains the overlay, registers the mutation, and releases it when the durable admission returns —
also on the main actor. Nothing orders the Combine hop against that release. If the release wins,
the guard reads `nil`, falls back to `false`, and the fix silently does nothing — restoring exactly
the defect it was written to fix, on a path with no test able to see it.

I then tried to settle it from `logmain_inbox_move_bug.log` and found the failure mode of that
evidence too: `overlay.release … remove=true` sits at line 1641 and the first `dismissed=1` body
evaluation at 1654, but that evaluation is a **render**, coalesced and asynchronous. The insert
that caused it could have run on either side of the release. The log is consistent with both
orderings, which is the point — **it could not have told me I was wrong.**

The fix that replaced it removes the dependency instead of proving it: `MessageDetailView.handleMove`
already knows the destination path and the message's account, so `dismissMessage` now carries
`destinationFolderId` in the notification and the receiver decides from the payload it was handed.
No transient global, no ordering question. (Non-defaulted parameter, so the archive/delete callers
must state `nil` explicitly rather than inherit it.)

## Why it is worth an entry despite never shipping

It was caught in the same session, before any build — but only because I re-derived the notification
delivery path while writing the test, not because anything flagged it. It would have compiled,
passed a plausible unit test written against the same wrong assumption (register the overlay in the
test, then call the predicate — green, and green for the wrong reason), and reproduced the original
bug intermittently on device. The near-miss is the finding.

## The rule

**A guard must not depend on how long some other subsystem's in-memory state happens to live.** When
the deciding information is already known at the site that triggers the decision, pass it — a payload
is a fact, a global's lifetime is a race. If passing it is genuinely impossible, then the lifetime is
a real invariant and needs a real test that fails when the ordering flips; a log that recorded the
convenient order once is not that test.

Corollary on evidence: before quoting a log to settle an ordering, ask **what the other ordering
would have looked like in this log.** If the answer is "the same", the log is not evidence.

---

## Pre-compaction index line (verbatim, 2026-08-13, pass 4)

Routed out of the always-loaded `tabmail-ios/MISTAKES.md` by the `companion-compact` skill, which
was reporting that file 62% over its 12,000 B budget. Kept **byte-for-byte**, inside a fenced block
so its index-relative link is not re-resolved from this directory, because the index line had
accumulated recurrence detail that exists nowhere else in this file.

```text
- **[MIS-IOS-015](Companion/Mistakes/Active/MIS-IOS-015-made-a-guard-depend-on-a-transient-globals-lifetime-across-an-async-hop.md)** — wrote a fail-open guard that read the move destination out of `AccountManager`'s **optimistic overlay** from inside `InboxView`'s `.messageDismissedFromDetail` receiver, a publisher carrying `.receive(on: DispatchQueue.main)` — so the handler runs a turn LATER than the `post`, nothing orders it against `overlay.release`, and losing the race returns `nil` → `false` → the exact dismissal the guard existed to prevent. **I asserted the lifetime from where the retain/release CALLS sit in the source**, then tried to settle it from `logmain_inbox_move_bug.log`, where `overlay.release` (1641) precedes the first `dismissed=1` **render** (1654) — but a body evaluation is coalesced, so the log is consistent with BOTH orderings and could never have told me I was wrong. Replaced by passing the destination folder id in the notification `userInfo` from `MessageDetailView.handleMove`, which already knows it (non-defaulted parameter, so archive/delete state `nil`). Caught pre-build, pre-commit, by re-deriving delivery while writing the test — nothing flagged it, and a test written against the same assumption would have been green for the wrong reason. ***Tell: "registered before the enqueue, released after the write, so it is definitely still live when my handler runs" — and its evidence-side twin, quoting a log to settle an ordering without asking what the OTHER ordering would have looked like in that same log.*** (×1)
```
