## A bare `print` is NOT production observability on iOS, and a debug gate in a BRANCH CONDITION is not a log gate (2026-08-04)

Two failure modes of global `CLAUDE.md` **rule 12** ("diagnostic logs must be a no-op in
production"), found together in the v3 tree and fixed together. Both are about the *channel*, not
about whether a particular line is noisy.

### 1. The `UNGATED BY DECISION` exemption cannot be delivered by `print`

`TabMail/Services/Account/AccountManagerQueue.swift` carries three sites — and a header comment
naming them — marked `🚨 UNGATED BY DECISION`, each claiming rule 12's **production-observability
exception**: a completed op whose delete failed (it will re-execute and may duplicate a wire effect),
a partially-completed bundle requeued whole (the proven members will be re-applied), and the F2b L4
**terminal identity drop** whose accepted cost `KNOWN_ISSUES.md` `IOS-QUEUE-003` item 4 records as
*"bounded and VISIBLE"*.

**The claim did not hold.** Nothing in the tree redirects `stdout` to a file — no `freopen`, no
`dup2`, no `setvbuf`/`STDOUT_FILENO` idiom — so on a device `stdout` is discarded: an ungated `print`
reaches an Xcode console that is not attached, and nothing else. The exemption bought **zero**
observability, and at the terminal-drop site that means the "VISIBLE" half of a *recorded, accepted*
cost was not actually being delivered.

> ⚠️ **Re-checking this claim needs care, because the fix made the search self-matching.** The
> corrected comments in `AccountManagerQueue.swift` now contain the words `freopen`/`dup2`
> themselves, so `grep -rn --include='*.swift' -E '\bfreopen\b|\bdup2\b'` returns **four hits, all
> COMMENT lines in that one file**, where before it returned none. The invariant to re-verify is
> *"no CODE redirects stdout"*, not *"the identifier is absent"* — read each hit before counting it.
> (Same quoted-identifier miscount that the warning-census guidance warns about, and that this task
> also hit in `KNOWN_ISSUES.md`, where a surviving `Status: OPEN` string was a superseding notice
> rather than a live disposition.)

**The fix is strictly additive and changes no gating decision.** Each site now also calls
`BackgroundSyncLogger.logError(_:source:)` — ungated at the write, appended to `error.log`, exported
by `DebugLogView`'s *"Error Logs"* share button. The prints and their `UNGATED BY DECISION` marks are
untouched.

> **The generalisation.** *"This log is exempt from gating because production needs to see it"* is a
> claim about a **channel**, not about a line. Before writing it, name the channel and check it
> exists on the device. On iOS, `print`/`NSLog` to a detached console is not one; a file channel
> (`BackgroundSyncLogger`, `NSELogStore`) or a crash breadcrumb is. The correct shape is *gated
> `print` for the console **plus** an ungated durable write*, which is what
> `SyncEngine.fetchOlderMessages`' `SELECT failed` arm already did and what these three now do.

### 2. "this line is its only witness" is false wherever the durable row survives

The same comments justified the exemption with *"this line is its only witness"*. That is true at
**exactly one** of the three sites — the identity refusal, which **DELETES** the `PendingOperation`
row, so after it nothing durable records the intention at all. At the other two the row is still
there (its delete is what failed; or it was requeued whole), so the row itself is durable evidence of
the op that will re-run. What no durable artifact recorded, at all three, is the **failure**.

The wording was corrected in place at both overstated sites and at the file header; the third now
says explicitly that it is the one where the claim is literally true, and why that makes the file
channel matter most there. (`MIS-019` — an absolute needs its negative case; the second site had
simply inherited the first's claim via *"same reasoning as the sibling CRITICAL above"*.)

### 3. A gate in the BRANCH CONDITION controls which branch is taken

`SyncEngine.fetchOlderMessages` had:

```swift
if !newHeaders.isEmpty {
    await indexHeadersForFTS(newHeaders)
    print("[InfiniteScroll] …")                                  // UNGATED — rule 12 violation
} else if found > 0, DebugModeManager.isLoggingEnabled() {       // gate INSIDE the condition
    print("[InfiniteScroll] …")
}
```

The first arm violates rule 12 outright. The second is subtler and is the durable lesson: with the
gate in the `else if` condition, **a debug unlock decides which branch is taken**, so debug and
release builds no longer share one control-flow graph. Today the arm's only effect is the print, so
hoisting the gate into the body is behaviour-preserving — verified before the edit, and that
verification is the point: *restructuring a branch whose condition carries a gate is a behaviour
change unless the arm is provably log-only*. Any non-logging statement added to such an arm later
would silently not run in production, and nothing would fail.

Both `[InfiniteScroll]` prints in that function, plus the `SELECT failed` print in its `catch` arm
(whose ungated `BackgroundSyncLogger.logError` sibling is the real production channel and is
unchanged), are now gated in the body.

**Left alone, and stated so the census is accountable (`MIS-006`):** `InboxViewModel`'s
`print("[InfiniteScroll] Error: \(error)")` is the fourth `[InfiniteScroll]` print in the tree. It is
a different file and a different owner, and touching it would widen the change past its member. For
every **non-connection** error its sibling sets `self.error`, a user-visible surface, so the common
case is not the same silent-channel problem — but the `if !SyncEngine.isConnectionError(error)` guard
suppresses that surface for connection errors, which is exactly when infinite scroll fails. It
remains an ungated diagnostic print and a known, unfixed instance of the same class.
