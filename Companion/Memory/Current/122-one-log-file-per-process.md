## The main app writes ONE persistent log file, and the NSE writes ONE — never a new file per subsystem (issue #83, 2026-08-25)

**The rule.** A new persistent diagnostic channel is a new `AppLogChannel` case and a tag. It is
**not** a new file, a new `fileURL` computed property, a new `read*Log()` / `clear*Log()` pair, or a
new share button. There are exactly two persistent log files in this codebase and adding a third is
the defect this topic exists to prevent:

| process | file | owner |
|---|---|---|
| main app | `tabmail.log` (Application Support / TabMail) | `AppLogStore` |
| notification service extension | `nse.log` (App Group container) | `NSELogStore` |

**What it replaced.** The main app wrote **fifteen** separate files —
`background_sync.log`, `error.log`, `chat_error.log`, `bg_app_refresh.log`, `bg_processing.log`,
`ai_processing.log`, `push.log`, `backfill_ai.log`, `backfill.log`, `inbox.log`, `boot.log`,
`body_render.log`, `stuck_messages.log` (all `BackgroundSyncLogger`), plus `device_sync.log`
(`DeviceSyncLogger`) and `auth_diagnostics.log` (`AuthDiagnostics`) — each with its own retention
policy and its own reader. ⚠️ NOT "each with its own BYTE cap": thirteen were byte-capped, but
`device_sync.log` used a 300-LINE ring and `auth_diagnostics.log` a 50-ENTRY ring, neither of which
bounds a single large message. ⚠️ **NOT "each with its own share button"** — `auth_diagnostics.log` had none; the
correction is stated in full below and this opening paragraph is where earlier drafts kept
re-introducing the claim, because this is the paragraph other files copy from. The count grew by one
every time a subsystem
wanted a channel, because adding a file was the path of least resistance and nothing said not to.

**Why one file is not a cosmetic change.** The failures worth diagnosing cross subsystems: a stalled
backfill that surfaces as an inbox reload storm, a push that lands while a BG refresh holds the
database, an AI queue that starves behind a sync error. With per-subsystem files the reporter had to
export several and re-interleave them **by hand** from their timestamps, and any file they forgot
was silently absent rather than visibly empty. **A single file recovers APPEND ordering, which is
the one thing a per-channel file physically cannot express.** That ordering is pinned by a test
(`AppLogStoreTests`, "Entries from different channels interleave in append order"). ⚠️ APPEND
order, not CALL order: a caller preempted between stamping its timestamp and reaching `ioQueue`
lands after one that stamped later, so the timestamps can read as decreasing. Line order is the
oracle. That test is sequential and therefore does not — and is not claimed to — pin a concurrent
call-order guarantee.

**Entry format and separability.** `[<ISO8601>] [<TAG>] <message>`. `AppLogStore.read()` returns
everything; `read(channel:)` filters back to one subsystem, and `clear(channel:)` drops one
channel's entries while preserving every other — which is what `StuckMessageDiagnostics.run` needs,
since it clears its own channel before each scan and must not take the rest of the file with it.
A physical line with no `[timestamp] [TAG] ` prefix is a **continuation** of the entry above it and
is kept or dropped with that entry; `BackgroundSyncLogger.logChatError` deliberately emits a second
`  User message: …` line, and attributing it to nothing would leak it out of a filtered export.

**⚠️ The gating split is a registered decision and consolidation did NOT change it** (`IOS-LOG-002`).
`AppLogStore.append` does **not** gate — the caller owns that decision, exactly as before:

- **Always-on** (persist in production): `BackgroundSyncLogger.log`, `.logError`, `.logChatError`,
  `DeviceSyncLogger.log`, `AuthDiagnostics.log`. A failure that only reproduces in the field has to
  leave a trace, and `IOS-LOG-002` chose this side of a genuinely two-sided trade.
- **Debug-gated** (`guard DebugModeManager.isLoggingEnabled() else { return }`, global rule 12):
  every other channel. **The guard gates the `print` too**, not just the disk write — a debug-gated
  channel must be a no-op in production on BOTH channels.

Both directions are pinned by tests, and the pair is deliberately two-sided: "gated channels write
NOTHING while disabled" alone would also pass for a writer that had been accidentally hard-disabled,
so "gated channels DO write once enabled" is its required counterpart. The unlocked half is only
reachable because `DebugModeManager.loggingEnabledOverrideForTesting` exists — in the test host the
real gate is always false (no unlock flag, no session), and its seam default is `nil`, meaning
"derive it exactly as production does" (`MIS-IOS-017`).

**Retention: what actually changed, stated in the direction that does NOT flatter the change.**
The cap is **32 MB, trimmed back to 16 MB** (raised from 16/8 by owner decision, 2026-08-25). The
trim advances past the first partial line so no PARTIAL PHYSICAL LINE is retained — a line, not
a logical entry: a cut inside `logChatError`'s two-line entry leaves its continuation orphaned.

⚠️ **An earlier version of this paragraph said `device_sync` and `auth_diagnostics` "retain far
more" and stopped there. That is true of TOTAL BYTES and FALSE of the per-channel floor, and it was
wrong in the direction that hid a regression** — caught by the cross-model review of `8b5e517c4`,
not by the author. The honest statement is two-sided:

- **Lost: retention ISOLATION.** Before, each of the 13 `BackgroundSyncLogger` files had its **own**
  16 MB budget, `device_sync.log` an unconditional 300-line ring and `auth_diagnostics.log` an
  unconditional 50-entry ring. **No channel could evict another.** Now all fifteen share one tail,
  so `.sync` — always-on, 137 call sites — can evict the `[ERROR]` and `[AUTH]` entries that a field
  report actually needs. The thirteen formerly byte-capped channels (ten debug-gated plus the
  always-on `.sync`, `.error` and `.chatError`) therefore have a **narrower guarantee** than before,
  and the two ring-retained files have **no floor at all** rather than a larger one. ⚠️ "13 debug
  channels" was wrong: the gating split is FIVE always-on to TEN debug-gated, which does not line up
  with the thirteen-byte-capped grouping.
- **Gained: a much larger shared budget**, which for any single channel in ordinary use is more
  headroom than its old per-file cap gave it.

**This is an accepted trade, not an oversight** (owner, 2026-08-25: *"increase max to 32, and then
okay if other logs drown things. it's just diagnostics. don't overcomplicate it"*). Per-channel
floors and reserved quotas were considered and **declined**. Do not re-introduce them without
re-opening that decision, and do not restate the retention change as a pure widening.

**`AuthDiagnostics` gained a UI ROUTE it never had — NOT a reader.** ⚠️ An earlier draft of this
topic, of the `IOS-LOG-002` amendment, and of the commit body all said "gained a reader it never
had." **That is false and it survived two reviews before being caught**: `v1.7.14`'s
`AuthDiagnostics` has a `readLog()` (`git show v1.7.14:TabMail/Services/AuthDiagnostics.swift`, and
`DeviceSyncLogger` had one too). What it lacked was any surface that CALLED it — the Logs section
carried thirteen `LogShareButton`s plus NSE, and **auth was not among them**, so "fifteen files each
with its own share button" is wrong as well. ⚠️ **It is `fourteen` of fifteen, not thirteen, and the
first correction of this sentence got THAT wrong too.** `stuck_messages.log` does have a button —
`LogShareButton(title: "Stuck Message Report", … readLog: BackgroundSyncLogger.readStuckDiagLog)`
at `v1.7.14` — it just lives in the `Stuck Message Diagnostics` section rather than in `Logs`, and
it is still there today. ⚠️ **NOT "untouched":** that symbol has ZERO occurrences in the tree now.
The button keeps its title and its section, but this change REPOINTS both closures at
`AppLogStore.read(channel: .stuckDiag)` / `clear(channel: .stuckDiag)`. Same button, rewritten line. **`auth_diagnostics.log` is the only one of the fifteen with
no share button anywhere.** The transferable error is the one this file already names twice: a
census was scoped to one SECTION and its answer was stated about the whole MENU
(`feedback_census_inherits_its_search_shape`). The predicate that settles it is
`grep -c 'LogShareButton(' TabMail/Views/Settings/DebugLogView.swift` over the WHOLE file — fifteen
at `v1.7.14`, three now — never a reading of the `Logs` section alone. Its own
doc comment named a "Settings > Maintenance > Auth Diagnostics" row that does not exist in the tree,
which is what made the reader unreachable rather than absent. Those entries are now part of the
single App Logs export, so the consolidation *fixed* a reachability gap rather than merely tidying
one. **The generalisable error: "no UI reads it" was restated as "it has no reader," and nobody
checked the type until a second model did.**

**🚨 Consolidating orphans the OLD files, and orphaned log bytes buy their size in PRUNED MAIL.**
This is the non-obvious consequence and the reason `StartupMigrations.deleteLegacyLogFiles` exists.
The fifteen replaced files survive an upgrade: nothing writes them, nothing reads them, and "Clear
All Logs" no longer knows they exist. That is not merely untidy — `StorageEstimator.totalSizeMB()`
measures Application Support **recursively**, `isOverBudget()` compares it to the user's configured
`globalStorageBudgetMB`, and `SyncEngine.runPruneIfOverBudget` responds by deleting `MessageBody`
and header rows. ⚠️ **State that CONDITIONALLY or it is false** — an earlier draft of this topic, and
of the commit body, asserted it flatly. `StorageEstimator.defaultBudgetMB` is `Int.max` and
`isOverBudget()` short-circuits on `budgetMB != Int.max`, so the pruning consequence exists only for
users who have SET a budget. That is still a real population rather than a theoretical one — the
budget is an ordinary `SettingsView` row, not a debug surface — and for them dead diagnostics
displace real mail. **Five of the fifteen are written in
production** (`background_sync`, `error`, `chat_error`, `device_sync`, `auth_diagnostics` — the
always-on set), where the Debug menu that could once clear them sits behind `debugMode.isUnlocked`
and is unreachable. Hence a **one-shot unlink at launch**, keyed on `didDeleteLegacyLogFiles_v1`,
naming the fifteen files **explicitly** and never enumerating the directory — a widened pattern
would eat `tabmail.log` itself. It is deliberately **not** in `resetFlagKeys`, because that list
arms the "Updating…" splash via `allResetsComplete` and unlinking fifteen small files is not
splash-worthy.

**The generalisation worth carrying: consolidation is not complete until the predecessors are
gone.** Merging N artifacts into one leaves N orphans that no surface can reach, and "nothing reads
them" is not the same as "they cost nothing" — here the cost was routed through a storage budget
nobody was thinking about. Ask what still measures, sums, or enumerates the container.

**What this topic does NOT cover, stated negatively (`MIS-019`).** It does not touch the `stdout`
`print` corpus — `IOS-LOG-001` (Views + Services) and `IOS-LOG-003` (calendar family) still own that.
⚠️ **It DID add two `print` sites, and an earlier draft of this topic — and of the commit body —
claimed the opposite.** `StartupMigrations` went from 11 to 13, both new ones in the legacy-log
cleanup, and `TabMail/Services/` is inside `IOS-LOG-001`'s corpus (scope extended 2026-08-05), whose
own range-not-corpus rule says a NEW ungated diagnostic inside a range is still a defect and is still
swept. Both are therefore wrapped in `if DebugModeManager.isLoggingEnabled()` per global rule 12. No
`BackgroundSyncLogger` call site was added, removed or re-worded. It does
not license adding new user-content interpolations to any channel; `IOS-LOG-002`'s negative bound
still binds, and a value that could carry a SECRET is the PRIME DIRECTIVE, not this topic. It does
not change the NSE, whose single file, synchronous-append rationale and in-place-truncate `clear`
are unchanged — `NSELogStore` writes inline precisely because the NSE process can be hard-killed at
any instant, and `AppLogStore`'s async `ioQueue` is correct only for the main app.

**⚠️ One serial queue for one file is load-bearing, not tidiness.** `DeviceSyncLogger` used to own a
second queue and `AuthDiagnostics` wrote **synchronously on the caller's thread** — including from
`TabMailApp.init` on MainActor. Sharing a file without sharing a serial queue would interleave
partial writes; all three now go through `AppLogStore.ioQueue`.


### Four hazards the SHARED file creates that fifteen separate files did not

Each was found by cross-model review of the first implementation, and each is a consequence of the
same structural change: fifteen private, independently-written artifacts became one shared,
line-oriented, in-place-appended artifact. **This is the transferable list — a future consolidation
of anything line-oriented should expect all four.**

1. **A torn write now corrupts the NEXT writer's entry, not just its own.** At `v1.7.14`
   `AuthDiagnostics` and `DeviceSyncLogger` rewrote their whole file with
   `write(to:atomically:true)` — an atomic replace can never leave a partial line — and every other
   channel appended to a file only IT wrote. Now all fifteen append in place to one file, so a
   process death mid-`write` leaves a partial line onto which the next entry is concatenated: two
   entries become one physical line, `entryTag` reads it as the FIRST one's channel, the second is
   unfilterable, and `clear(channel:)` on the first channel deletes the survivor with it.
   `AppLogStore.appendRaw` therefore opens `forUpdating` (`O_RDWR`, not `O_WRONLY`) and repairs a
   missing terminal newline before appending. ⚠️ **Two honest qualifications an earlier draft
   omitted.** The repair stops the NEXT entry from merging onto the torn one; it does **not**
   reconstruct the torn entry's lost suffix — that evidence is gone, and at `v1.7.14` the two atomic
   writers could lose a whole entry but never hold a torn one. And "one 1-byte read is the whole
   cost" understates it: requiring `O_RDWR` means a `tabmail.log` that is writable but NOT readable
   (mode `0200`) now fails to open at all and every append is silently dropped, where the old
   `O_WRONLY` append succeeded. Not reachable for a file the sandboxed app creates and owns, but it
   is a real narrowing and it is the cost of the repair, not a free improvement.
2. **One bad byte could destroy the WHOLE artifact, and make it unclearable.** If a torn write
   splits a multibyte UTF-8 scalar, `String(contentsOf:encoding:)` throws — which made `read()`
   report `(no log)` for the entire file and turned `clear(channel:)` into a silent no-op. A single
   byte thus destroyed every channel's history AND removed the means to recover. `decodedFileText`
   now decodes lossily (`String(decoding:as:)`, U+FFFD for the invalid sequence). ⚠️ **`nil` is NOT
   reserved for the genuinely-missing file, and three places said it was** — `decodedFileText`'s own
   doc, `read()`'s doc, and an earlier draft of this paragraph. It is returned for ANY
   `Data(contentsOf:)` failure: missing, unreadable (mode `000`), or a directory at the path. So an
   existing-but-unopenable log still reports `(no log)` and still makes `clear(channel:)` a silent
   no-op — the same "unreadable ⇒ unclearable" pair, surviving for a different cause. Not reachable
   inside the app's own sandbox, where it owns and can open its own Application Support files, which
   is why this is a documentation-accuracy point first and a robustness note second.
3. **User-authored text can forge ANOTHER channel's entry.** `logChatError` is always-on and
   `AIChat` passes literal user-typed `userText`. A typed newline followed by `[x] [AUTH] …` yields
   a second physical line that parses as a real AUTH entry: it surfaces in `read(channel: .auth)`,
   truncates the real entry in `read(channel: .chatError)`, and survives
   `clear(channel: .chatError)`. Confined to `chat_error.log` this was harmless; the shared file is
   what makes it cross-channel. The user span is now escaped **inside the façade** (cap first with
   `prefix(100)`, escape second, so the cap can never slice an escape sequence), which is the one
   deviation from the otherwise call-site-owned escaping rule.
4. **A one-shot deletion of the predecessors must never be able to recurse.** `removeItem(at:)` is
   documented recursive, and guarding it with an `isRegularFile` query does not help — the query and
   the removal are two syscalls with a window between them, so a directory appearing at a legacy
   name in that window is deleted with its contents, at launch, before any UI exists to report it.
   The cleanup uses `unlink(2)`: one syscall, no check/use window, refuses a directory outright, and
   removes a symlink's LINK rather than reaching through to its target. Darwin returns `EPERM` for
   BOTH a directory and an immutable file, so the ambiguity is resolved by an `lstat(2)` call that
   only CLASSIFIES (no removal follows it), and an unresolvable answer counts as a **failure**,
   never a clean skip — erasing it would arm the one-shot flag and strand that name's bytes
   forever. That last point is the general one: **`try?` on a metadata query, feeding a one-shot
   completion flag, converts "I could not tell" into "nothing to do, done forever."**

   ⚠️ **`URL.resourceValues(forKeys: [.isDirectoryKey])` does NOT follow symlinks.** A review round
   asserted the opposite — that the original `.isDirectoryKey` spelling would resolve a
   symlink-to-directory as a directory and silently convert a failed `unlink` into the deliberate
   permanent skip. It does not. Measured directly against Foundation on a symlink pointing at a
   directory: `.isDirectoryKey` is `false`, `.isSymbolicLinkKey` is `true`, `lstat` reports
   not-a-directory and only `stat` (which does follow) reports one. Corroborated a second way, by
   inverting the line in the simulator and re-running `StartupMigrationsTests`, which stays green
   precisely because both spellings agree. The `lstat` spelling shipped anyway — it states the
   no-follow requirement in the call itself instead of relying on an undocumented Foundation
   behaviour — but it is a **behaviour-preserving simplification, not a defect fix**, and the
   symlink test therefore cannot be red-proofed against it. The transferable lesson is about
   reviews, not about files: **a reviewer's MECHANISM can be sound while its CLASSIFICATION is
   wrong.** "`resourceValues` resolves the URL" is true in general and false for this specific key;
   the finding read as correct because the mechanism was plausible. Verify the classification
   against the actual API before recording a fix as a fix, or the changelog inherits a defect that
   never existed.

### Accepted costs, registered rather than fixed

- **`clear(channel:)` went from O(1) to O(whole file).** At `v1.7.14`
  `BackgroundSyncLogger.clearStuckDiagLog()` was one `"".write(to:atomically:)`. It is now a full
  read → filter → atomic rewrite of a file capped at 32 MB, and `StuckMessageDiagnostics.run()`
  calls it at the top of every scan from a nonisolated `async` context, blocking a cooperative-pool
  thread. Transient peak memory is roughly 4× the file. Reachable only with debug logging unlocked
  (`DebugMenuView` is behind `debugMode.isUnlocked`; `StuckMessageDiagnostics.run` guards on
  `isLoggingEnabled()`), so no production user reaches it — but the five always-on channels can
  genuinely grow the file to the cap, so the size input is real.
- **Ordering is carried by LINE ORDER, not by the timestamp.** `append` stamps with
  `iso8601String()` — `withInternetDateTime`, **second** precision — and captures it on the caller's
  thread before `ioQueue.async`. Two threads can therefore enqueue in the opposite order to their
  capture. ⚠️ An earlier draft said this is unobservable because both render the same second. That
  is FALSE: a capture at `…:00.999` preempted past a capture at `…:01.001` that enqueues first puts
  a VISIBLY DECREASING pair of timestamps on disk. The
  serial queue still writes in submission order, so the file reads correctly; but do not describe
  the timestamps as the ordering oracle. Sub-second interleaving is read from line order.
- ~~**`read()` is not serialized against writers after its drain barrier.**~~ **RETRACTED — closed
  in this same change, and this bullet is kept only so the retraction is searchable.** An earlier
  draft shipped a `flushPendingWrites()` barrier and decoded OUTSIDE `ioQueue`. A barrier only
  proves the writes queued BEFORE it have landed; an append queued after it ran concurrently with
  the decode, so a share could observe a half-written entry or a split UTF-8 scalar. Both readers
  now decode INSIDE `ioQueue.sync` and `flushPendingWrites` no longer exists — it has zero
  occurrences in Swift. **The general form: a drain barrier is not mutual exclusion.** It orders
  the past and says nothing about the future, so it is the wrong tool whenever the reader must not
  overlap a concurrent writer.
- **The trim is physical-line-safe, not entry-safe.** It advances past the first newline in the
  retained tail, which is correct for the fourteen single-line channels. A cut inside the first line
  of `logChatError`'s deliberate two-line entry leaves the `User message:` continuation as a leading
  orphan: filtered reads drop it (both `filter` and `clear(channel:)` treat a leading orphan the same
  way, which is what makes "unreadable but unclearable" impossible), while the unfiltered export
  shows it without its channel. ⚠️ **This paragraph has now been wrong TWICE, in OPPOSITE
  directions, and both retractions are kept because the pair is the lesson.** Draft one said "no
  writer can produce an entry larger than the cap" — false: `logChatError` bounded its user span
  with `prefix(100)`, which counts extended grapheme CLUSTERS, so one pasted grapheme carrying an
  unbounded run of combining marks passed that cap intact (`MIS-IOS-013` — **a SIZE question asked
  with a grapheme-level `String` API, and the answer believed**). Draft two then said "a single
  entry larger than the cap is not trimmed, it ERASES the file" — true of the code at the time, and
  false of the code this topic now describes. Both holes are closed at the STORE: `append` bounds
  every channel at `maxEntryScalars` (unicode scalars, which one grapheme cannot defeat), and
  `trimTail` refuses to write an empty file. **Current behaviour: such a trim is ABANDONED — the
  log is left untrimmed and above its cap, neither erased nor trimmed** — which is deliberate,
  because keeping an oversized file beats deleting a non-empty one, and the next bounded append
  puts a newline inside the tail so the following trim succeeds. Do not restate the erase claim; it
  describes a superseded draft.
- **A permanently undeletable legacy file re-runs the fifteen-name scan every launch, forever.** The
  flag arms only on a clean pass, which is what makes a TRANSIENT obstruction self-heal; it is not a
  strict-progress guarantee. Arming after a partial pass would be strictly worse. The cost is
  fifteen `unlink` calls, fourteen returning `ENOENT` immediately.
- **The trim is entry-lossy at an aligned boundary, and that is PRE-EXISTING, not new.** When
  `offset = size - keepBytes` happens to land immediately after a newline, the retained tail already
  begins at a line boundary — and the unconditional "advance past the first newline" discards that
  first PHYSICAL LINE anyway. Note the unit: a physical line, not an entry. For the fourteen
  single-line channels the two coincide, but if the retained tail opens on `logChatError`'s
  deliberate two-line entry, what is dropped is its tagged HEAD, leaving the `User message:`
  continuation as a leading orphan — the same orphan class the bullet above describes. `v1.7.14`'s
  `BackgroundSyncLogger.trimTail` is byte-identical on this point, so consolidation neither
  introduced nor widened it. **Deliberately not fixed:** the unconditional form can never leave half
  a line behind, and losing one extra line from a 16 MiB retained tail of diagnostics is exactly the
  redundant work this repo prefers over conditional cleverness. No remedy is prescribed here on
  purpose — an earlier draft stated one and stated its predicate BACKWARDS.
- **The cleanup trusts the CONTAINER DIRECTORY, only its final path components.** `unlink` resolves
  symlinks in the PARENT path, so if `Application Support/TabMail` were itself a symlink, the
  fifteen unlinks would follow it; the `lstat` classification guards the final component only.
  **Deliberately not fixed.** Pinning the directory with `O_DIRECTORY | O_NOFOLLOW` + `unlinkat` is
  the mechanical fix, but the premise is unreachable in the iOS sandbox: nothing in the app creates
  that symlink, and anyone who could plant it already has arbitrary write access to the container.
  `v1.7.14` extended the identical trust — all fifteen loggers resolved the same parent path on every
  write — so this is the app's standing container assumption, not something consolidation introduced.
  Worth stating because the finding LOOKS like a directory-traversal defect and will be re-raised.


### Three more guarantees the shared file gives up, none of them obvious

Recorded because each was missed by at least one reviewer and none is visible from the diff alone.

- **Filesystem failure isolation is gone.** At `v1.7.14`, making `push.log` unreadable broke PUSH and
  nothing else. One unreadable `tabmail.log` now hides and disables **all fifteen** channels at once.
  Consolidation converts fifteen independent single points of failure into one shared one — the
  ordinary cost of consolidation, worth stating rather than discovering.
- **`DeviceSyncLogger` lost its queue independence.** It owned a second serial queue; it now shares
  `AppLogStore.ioQueue` with fourteen other channels including the 137-site always-on `.sync`. A
  device-sync entry enqueued behind a flood of large entries can be lost to termination in a way it
  could not before. This is the same trade already recorded for `AuthDiagnostics`' synchronous write,
  reached by a different route, and the commit body originally recorded only the Auth half.
- **`logBoot` entries gained a timestamp they never had.** At `v1.7.14` the façade wrote
  `line + "\n"` with no timestamp at all — `BootProfiler.mark` supplies its own
  `[BootProfile +Nms (ΔNms)]`. Boot lines are now `[ISO8601] [BOOT] [BootProfile …]`. Additive and
  unavoidable given the shared envelope, nothing parses the old format, but it is the ONE writer
  whose on-disk text changed beyond the mandated tag insertion, so "no call site was re-worded" —
  true about call sites — does not cover it.

Also worth knowing, though a cost rather than a lost guarantee: **`read()` runs on MainActor from the
share button.** `LogShareButton`'s action calls its injected `readLog()` — now `AppLogStore.read`,
which decodes INSIDE `ioQueue.sync` — and then writes a temp file, roughly 2× the file,
synchronously, before the share sheet appears. (An earlier draft called the now-deleted
`flushPendingWrites()`; the main-actor cost is unchanged by that swap, and is now additionally a
wait on any queued write or trim.) `v1.7.14`'s largest BYTE-CAPPED button was a 16 MB
`background_sync.log` — not an overall maximum, since `device_sync.log`'s 300-LINE ring bounded no
line's length and could exceed it; the cap
is now 32 MB. Debug-only, and the counterpart to the `clear(channel:)` entry above.

## Routed files this change falsified, and why they were not edited in place

Consolidation makes references in eight routed files factually wrong — eight files this change
does **not** otherwise touch. Two further routed files name the same dead artifacts deliberately,
because they are what registers this change: this topic, and
`Companion/Process/Current/KnownIssues/ios-log-002.md`. Both carry their corrections inline in this
same commit, so neither is listed below and neither is a counterexample to the closure claim at the
end. The eight are listed here, with their corrections, **rather than patched at each site**, and
the reason is mechanical: five of the eight are hash-pinned bodies in
`Companion/Memory/manifest.tsv` / `Companion/Decisions/manifest.tsv`. The only sanctioned edit to
such a body is a prepended `COMPANION-CURRENT-NOTE` wrapper, which `exact_body` in
`Scripts/compact_companion_docs.rb` strips before hashing — ⚠️ the wrapper is the SAFE operation,
and amending one of these bodies *without* it is the one `MIS-IOS-009` records, repeatedly aborting
the verifier on its first check. This repo's routing
protocol makes the **`rg` result set** the reachable surface, not the individual file, so a search
for any dead artifact below returns the stale sentence and this correction together. That is the
whole requirement, and it costs one edit instead of eight.

The dead artifacts, spelled out so they match a literal search: `background_sync.log`, `error.log`,
`chat_error.log`, `bg_app_refresh.log`, `bg_processing.log`, `ai_processing.log`, `push.log`,
`backfill_ai.log`, `backfill.log`, `inbox.log`, `boot.log`, `body_render.log`, `stuck_messages.log`,
`device_sync.log`, `auth_diagnostics.log`, `BackgroundSyncLogger.trimTail`, and the share buttons
"Error Logs", "Backfill Logs" and "Boot Profile Logs".

Every per-file destination below is now `tabmail.log`, read with `AppLogStore.read(channel:)` and
exported by the single **"App Logs"** button. **The `BackgroundSyncLogger.log*` façades all survive**
— `logError`, `logBackfill`, `logInbox` and `logBoot` are unchanged as call sites; only their
destination and their reader moved. Citations are by quoted phrase, not line number
(`feedback_line_citations_go_stale`).

- **`Companion/Memory/Current/105-a-print-is-not-production-observability-on-ios.md`** — "appended to
  `error.log`, exported by `DebugLogView`'s *"Error Logs"* share button". Both halves are now wrong:
  the destination is `tabmail.log` under the `[ERROR]` tag, exported by "App Logs". The point the
  sentence is making — that `logError` is ungated at the write — is **unaffected and still true**.
- **`Companion/Process/Current/KnownIssues/ios-scroll-003.md`** — the same phrase, "(`error.log`,
  exported by `DebugLogView`'s "Error Logs")", with the same correction. Its argument, that this is
  a developer channel rather than a user-visible surface, is unaffected.
- **`Companion/Memory/Current/027-backfill-diagnostics-backfill-log-channel-2026-07-02.md`** — its
  title and its "`BackgroundSyncLogger.logBackfill` → `backfill.log` (debug-gated, exported as
  "Backfill Logs" in the Debug menu)". The façade and the debug gate are both unchanged; the
  destination is the `[BACKFILL]` tag in `tabmail.log`, exported by "App Logs". This file also
  names the dead EXPORT filename `backfill_ai_logs.txt`, and is the only routed file citing a dead
  export name. (Deliberately not restated here: how many exports the app has NOW. This
  section's job is to make DEAD names reachable; a live count is a new falsifiable claim that
  serves no part of that job and would need re-verifying on every UI change.)
- **`Companion/Memory/Current/029-bodycomplete-fts-indexed-truth-display-cache-has-no-flag-adr-ios-050-202.md`**
  — two hits. "`backfill.log` showed pending…" is **historical narration of a 2026-07 investigation
  and was true when written**; leave it read as history. "Asset evictions now log to `backfill.log`"
  is present-tense and now means the `[BACKFILL]` tag in `tabmail.log`.
- **`Companion/Decisions/Active/adr-ios-050.md`** — the same two shapes. Its **Context** paragraph
  ("`backfill.log` showed the body-pending population climbing") is historical; its consequence 3
  ("logs victims + MB reclaimed + duration to `backfill.log`") is present-tense and now the
  `[BACKFILL]` tag in `tabmail.log`. The consequence itself — that eviction is observable — holds.
- **`Companion/Memory/Current/033-optimistic-ui-rollback.md`** — `inbox.log`, now the `[INBOX]` tag
  in `tabmail.log`.
- **`Companion/Memory/Current/072-persistent-nse-log-file-watchdog-partial-result-delivery-2026-07-09.md`**
  and
  **`Companion/Memory/Current/099-persistent-nse-log-file-watchdog-partial-delivery-audit-rounds.md`**
  — both carry the same sentence twice over. `BackgroundSyncLogger.trimTail` is a **dead symbol**
  (zero Swift occurrences); the function moved to `AppLogStore.trimTail`, and the point being made
  about it — that an atomic external replace would orphan a cached `FileHandle` onto a deleted
  inode, which is why `NSELogStore` truncates in place instead — is **still exactly true of
  `AppLogStore.trimTail`**, so only the name is stale. Both also say the "NSE Logs" button "mirrors
  the "Boot Profile Logs" pattern"; that button is gone, and "NSE Logs" now sits beside "App Logs"
  as one of the two buttons the **Logs section** now has. `DebugLogView` declares three
  `LogShareButton`s in all — the third, "Stuck Message Report", sits in its own section and was
  never one of the thirteen, so a whole-file count and a Logs-section count differ by one here.

⚠️ **This list is closed under the nineteen artifacts named above — the fifteen log files, `BackgroundSyncLogger.trimTail`, and the three share-button titles — and nothing else.** It is wrong the moment a
further routed file cites a per-subsystem log file, or a future change moves `tabmail.log` itself.
It does **not** cover `Companion/Memory/History/` or `Companion/Process/History/`, which are
snapshots and are supposed to read as of their date.
