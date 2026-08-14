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

> ⚠️ **CORRECTION (2026-08-04) — the sentence above is WRONG about the escape hatch, and wrong in the
> direction that made the site look safer than it is.** *"its sibling sets `self.error`, a
> user-visible surface"* does not hold in a production build. `InboxViewModel.error` is written at two
> sites and RENDERED at exactly one — `InboxView`'s error banner — and that banner is itself gated:
> `if let error = viewModel.error, DebugModeManager.isLoggingEnabled()`. **With logging locked, the
> banner never renders, so `self.error` is not a user-visible surface at all** and the "common case"
> carve-out evaporates: the non-connection case is the SAME silent-channel problem as the connection
> case, not a milder one. The decision to leave the print alone is unchanged (still a different file,
> still outside the member), but it must not be justified by a surface that does not exist on a user's
> device.
>
> **How the error was made, because it is this file's own lesson turned back on itself.** §1 above
> says: *"before claiming an exemption, NAME THE CHANNEL AND CHECK IT EXISTS ON THE DEVICE"* — and
> then the paragraph below it named a channel (`self.error` → the UI) and did not check it, in the
> same edit. Reading the WRITER of a value proves it is set; only reading its READER proves anyone
> sees it (`MIS-024`: a sentence handing responsibility to a named mechanism owes a grep of that
> mechanism's call sites — here, of its render site).

### 4. ✅ RESOLVED (2026-08-04) — the banner the correction above found is now a production surface

The gate identified by the correction in §3 is **fixed**. `InboxView`'s error banner no longer spells
the debug flag into its branch condition; a small `InboxErrorBanner.text(for:loggingEnabled:)` owns the
whole presentation decision, and **the flag is an ARGUMENT to it rather than a term in a condition** —
presence depends on `error` alone, the flag selects only the wording. The dismiss button, layout,
colours and placement are untouched.

**The shape was restored, not authored.** `MessageCardView.bodyContent` already solved the identical
problem correctly and is **byte-identical in shipped `07a4bb703`, in `v2final` `e28dd4edb` and at
HEAD**: the branch is ungated so the user always learns something failed, and only the DETAIL is
debug-gated, because `error.localizedDescription` — what both `InboxViewModel` write sites store — is
developer text, not user copy. The production string reuses that sibling's existing register rather
than inventing a new one, and both `InboxView` list paths carry `.refreshable`, so the pull-to-refresh
hint names a gesture that genuinely exists.

**A1 verdict, stated because the answer is counter-intuitive: NONEXISTENT, not a regression.** Shipped
`07a4bb703` carries the identical gated line at the identical position, as does `v2final`. So the
production banner has *never* existed on a user's device and this is authored work — while the *shape*
of the fix is restored from a sibling inside the same shipped tag. Both halves are true at once, and
collapsing them either way gets the provenance wrong. (`A1` corollary 3 — the shipped release is a
floor, not a ceiling: restore the property it genuinely had, do not inherit its weaknesses.)

**The census this closed, and its predicate.** Block-aware over `TabMail/Views/`: **95 code references**
to `DebugModeManager` (99 raw string hits − 4 doc-comment mentions), cross-checked two-way with `comm`
against an independent `rg` list, with the 4-line disagreement run down rather than averaged. **Exactly
one** site had a debug flag in a branch condition suppressing a user-visible surface — this one.
`MailNavigationView`'s Debug-menu link under `isUnlocked` also changes what the user sees and is
*correct*, because the debug menu is defined by debug mode. Full predicate, the three hand-closed shape
blind spots (`} else if` arms, `guard … else { return "" }`, and **a gate hoisted into a local boolean**,
which hides the condition from any walker keyed on the flag), and the register row are in
`KNOWN_ISSUES.md`.

> ⚠️ **RETRACTION (2026-08-05) — `af98d92c7`'s claim A over-claims, and this file is where the
> correction lives because a commit body cannot be amended.** That commit's section A states: *"OF THE
> 15, ZERO ARE DEFECTS ON THE MERITS … **All 15 arms are log-only**"*. The second clause is FALSE.
> `InboxView`'s error banner is one of the 15, and its arm renders a **UI banner**, not a log — which
> is precisely the defect §3's correction had already identified and that `3573574ed` fixed **five**
> commits later (`af98d92c7` → `be3db4785` → `ea20e3952` → `438f632cf` → `6713a21cb` → `3573574ed`;
> reproduce with `git log --format='%h %s' 3573574ed~6..3573574ed`). The **conclusion** of claim A
> survives (the census was clean of the class it was
> opened to adjudicate, and `ThreadUtils.swift`'s site is correct as written); what fails is the
> universal *"all 15 arms are log-only"*, asserted while the same commit's own section C described a
> banner that was not.
>
> **How the error was made:** the commit enumerated 15 sites, classified them, and wrote the summary
> sentence from the classification's *majority* rather than from its exceptions — the same shape as
> `MIS-019` (an absolute stated without checking its negative case), and one the same commit was in
> the middle of retracting elsewhere. **A census summary must be written from the rows that disagree
> with it, not the rows that agree.** Found by the final-train Claude audit half, 2026-08-05.

> ⚠️ **What this does NOT close, and it is the half the §3 correction cared most about.** Both
> `InboxViewModel.error` write sites are still wrapped in `if !SyncEngine.isConnectionError(error)`. At
> the `performSync` catch that is covered — `AccountManagerState.shared.lastSyncFailed = true` is set
> **unconditionally** in the same catch and drives the sync-status subtitle. At the **infinite-scroll**
> catch there is no such fallback, so a **connection** failure during pagination is *still* silent, which
> is precisely the case §3 named (*"exactly when infinite scroll fails"*). Registered as
> `IOS-SCROLL-003`; the fix belongs in `InboxViewModel`, not in the view. **So the sentence "`self.error`
> is a user-visible surface" is now TRUE — but only for non-connection errors.** State it with that
> qualifier or it becomes the same over-broad claim the correction above was written to retract.

---

## The residual record of `f947acb4c` was wrong, and residual records are where this keeps happening (2026-08-12)

`f947acb4c` gated and escaped the attachment diagnostics. Its closing paragraph reads:

> Not changed: the many other ungated `print`s elsewhere in `ComposeView` (roughly fifteen, outside
> `carryForwardAttachments`). They are the same Rule 12 class and should be swept, but doing it here
> would have buried this fix.

**That names `ComposeView` and nothing else, and it was false when it was written.** A mechanical
scan one round later found six more sites in the same subsystem, on the same message-render path,
every one of them both ungated AND unescaped — the exact pair of defects that commit existed to
close. All six executed in RELEASE builds:

| symbol | value | fixed in |
|---|---|---|
| `IMAPProvider.buildFullMessageInfo` (×2) | `part.contentType`, `part.filename` | `fa90c60bc` |
| `GmailProvider.extractBodyAndEmlMarkers` (×2) | `part.filename` | `fa90c60bc` |
| `GmailProvider.extractNestedFromFileUploadedEmls` | `part.filename` | `fa90c60bc` |
| `GmailProvider.extractInlineImages` | `item.contentId` | `fa90c60bc` |

**The corrected record, phrased so it cannot be read as a complete set.** Sites in the same class
that are known to remain — *this list is not asserted to be exhaustive, and the enforcement is the
test, not this paragraph*:

- `IMAPFetchMapping.renderBodyWithEmbeddedHeaders` (2 prints). Now `#if DEBUG`-gated, so release
  builds do not emit them, but `part.filename` there is still **UNESCAPED**: `Shared/` compiles into
  the NSE target too, where `DebugModeManager` — and therefore `escapedForLogLine` — does not exist.
  Closing that half means moving the escaper into `Shared/`.
- `IMAPProvider.fetchFolders` and `IMAPProvider.dedupRoles` — server-controlled FOLDER names,
  ungated. Same rule-12 class, off the render path.
- `IMAPProvider`'s date-parse-failure print — `info.subject`, sender-authored, ungated. Deliberately
  NOT covered by the scan: `Draft.subject` is the user's own text under the same accessor spelling,
  so scanning `.subject` would demand escaping the user's composition.
- `ComposeView` outside `carryForwardAttachments`, as the original paragraph said.
- `GoogleCalendarProvider` — a comment in `executeCalendarOperation` records "9 ungated `print`s and
  0 `DebugModeManager` references" in that file. ⚠️ Quoted as the state that comment DESCRIBED, not
  as a current count: the very next line of that file is `if DebugModeManager.isLoggingEnabled() {`,
  so the "0 references" half was already false the moment the comment shipped. Re-derive before
  citing either number.

**Why this is recorded here rather than only in a commit message.** It cannot be recorded in the
commit message: `f947acb4c`'s body is what is wrong, and a commit message cannot be amended once it
is in history. That is the structural reason a durable claim does not belong in one — the same
lesson as the `UNGATED BY DECISION` claim in §1 above, reached from the other end.

**The generalisation, and it is the load-bearing part.** A *residual record* — the "here is what I
deliberately did NOT fix" paragraph — is an absolute in humility's clothing. Its grammar is
confession, it exists to pre-empt "your fix was too narrow", and a reader's reaction to it is relief
rather than suspicion. It is written last, when the work is done and verified, so it gets the least
evidence and the most trust. Two independent reviewers read this commit; both flagged the test above
that paragraph and neither flagged the paragraph.

`f947acb4c` *did* enumerate a class — that is where "the audit's four plus the ones in the same
functions" came from. It enumerated by **function neighbourhood** (which sites sit next to the ones
I am editing) instead of by **property** (which sites interpolate a sender-authored value into a log
sink). The first noun cannot reach another file; the second can. A census inherits the shape of the
thing you searched for.

**Countermeasure, because a better prose list is not one:** `RenderPathLogSinkTests`
(`TabMailTests/Views/EmailRenderPipelineTests.swift`) re-derives the set on every run and fails with
the offending `file:line accessor` triples. It is scoped as a regression guard, not a proof, and its
doc comment enumerates seven evasion shapes it cannot see. Recorded as `MIS-019` instance 18.
