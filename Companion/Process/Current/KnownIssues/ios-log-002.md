<!-- KNOWN-ISSUES-AMENDMENT-BEGIN -->
> **⚠️ AMENDMENT (2026-08-25, GitHub #83) — THIS ROW'S CHANNEL 2 MOVED FILES. THE DISPOSITION IS
> UNCHANGED (still CLOSED AS A DECISION), and the body is preserved unedited because it is
> regenerated from the hash-pinned archive and byte-compared.**
>
> Channel 2 below is described as `BackgroundSyncLogger` "appended to a file in the app container,
> and **exported by `DebugLogView`'s share buttons**". Both halves are still true of the CHANNEL and
> now name the wrong artifacts. The main app's **fifteen** persistent log files were consolidated
> into **one** — `tabmail.log`, owned by the new `AppLogStore` — and the Logs section's thirteen
> per-subsystem share buttons became a single "App Logs" button (its "NSE Logs" button is genuinely
> unchanged, and the separate "Stuck Message Report" button keeps its title and its `Stuck Message
> Diagnostics` section — but ⚠️ NOT "untouched": both of its closures are repointed at
> `AppLogStore.read/clear(channel: .stuckDiag)`, so only the NSE button is byte-identical). `error.log` no longer exists as a
> file; the same entries are now `[ERROR]`-tagged lines in the shared file, recoverable with
> `AppLogStore.read(channel: .error)`.
>
> **Nothing this row dispositions has changed, which is why this is an amendment and not a
> re-opening:**
> - **The always-on set is identical.** `BackgroundSyncLogger.log` / `.logError` / `.logChatError`,
>   `DeviceSyncLogger.log` and `AuthDiagnostics.log` still persist in production; every other channel
>   still carries its `guard DebugModeManager.isLoggingEnabled() else { return }`. Consolidation
>   deliberately moved neither side of the trade this row decided, and both directions are now pinned
>   by tests in `AppLogStoreTests` ("Always-on channels persist while debug logging is DISABLED",
>   "Debug-gated channels write NOTHING while debug logging is DISABLED", and its required
>   counterpart "Debug-gated channels DO write once debug logging is enabled").
> - **Class B and Class C are untouched.** No `BackgroundSyncLogger` CALL SITE was added, removed or
>   re-worded, so the interpolations this row defers — the account holder's own address, and
>   user-authored folder names — are the same sites with the same text. ⚠️ **The `412` / `51` / `12`
>   figures below were NOT re-derived here**; they are rev-pinned leads, not bounds (`MIS-044`), and
>   the predicate to re-run is the LINE-oriented one the body states.
> - **Exposure (d) is unchanged in kind, but its PER-ACTION PAYLOAD is BROADER.** ⚠️ An earlier
>   draft called it "marginally narrower … one button rather than thirteen"; that conflated fewer
>   BUTTONS with less EXPOSURE and contradicted this row's own AUTH-widening note below. Sharing is
>   still an explicit user action, but one App Logs share now exports all fifteen main-app channels
>   — including AUTH and CHAT — where sharing PUSH once exported `push.log` alone.
> - **Channel 1 (`NSELog` / unified log) is not touched at all.** The NSE keeps its own separate
>   `nse.log` and its own `os_log` behaviour.
>
> **One thing genuinely CHANGED and is recorded here rather than left to be re-discovered:**
> `AuthDiagnostics` wrote `auth_diagnostics.log`, which **no** Debug-menu surface ever read — its own
> doc comment named a "Settings > Maintenance" row that does not exist in the tree. ⚠️ **It DID have a
> `readLog()`** (`v1.7.14:TabMail/Services/AuthDiagnostics.swift`); an earlier draft of this amendment
> said it "gained a reader it never had," which is false — it gained a UI ROUTE. `v1.7.14`'s Logs
> section had thirteen share buttons plus NSE, with auth absent. ⚠️ An earlier wording of this
> sentence added "and stuck-messages", which is FALSE: `stuck_messages.log` has its own "Stuck
> Message Report" button in the `Stuck Message Diagnostics` section. Counting the whole file,
> `v1.7.14` had FIFTEEN `LogShareButton`s and `auth_diagnostics.log` is the only one of the fifteen
> log files with none. Those entries
> were therefore written and UNREACHABLE, not unreadable. They are now inside the single App Logs export, so this row's Class B
> "`BackgroundSyncLogger` corpus … exported by share buttons" reasoning now reaches the auth channel
> too. That is a WIDENING of what a shared export can contain, it is stated here rather than
> silently absorbed, and it does not change the disposition: the content is the account holder's own
> address on their own device, which is exactly the exposure (d) already accepts.
>
> **⚠️ THE ABOVE RECORDED ONLY HALF OF THAT WIDENING, AND THE MISSING HALF POINTS THE OTHER WAY**
> (added 2026-08-25 after the review of `8b5e517c4`; the author recorded the reader and
> not the destroyer — `feedback_fix_produces_mirror_image_bug`). Auth entries gained a **UI ROUTE**
> — the wording corrected two paragraphs above, restated correctly here so this sentence cannot be
> read on its own as the retracted "reader" claim — and they also gained a **DESTROYER**. At `v1.7.14` `AuthDiagnostics` had **no clear function at all**
> and was absent from `DebugLogView` entirely, so its entries were immune to every clear surface in
> the app. They are now inside `tabmail.log`, which "Clear All Logs" wipes. The support flow "clear
> the logs, reproduce, share" therefore now destroys the auth history that predates the repro —
> precisely the history the channel's own doc comment says must "survive an unexpected logout".
> **Owner decision, 2026-08-25: keep it** (*"Clear all should clear all. never used excluded auth
> logs anyway"*). Excluding auth from Clear All was considered and declined; do not re-add an
> exclusion without re-opening this.
>
> **Also recorded rather than left to be re-discovered: retention ISOLATION was lost.** Each of the
> 13 `BackgroundSyncLogger` files had its own 16 MB budget, `device_sync.log` a 300-line ring and
> `auth_diagnostics.log` a 50-entry ring, and **no channel could evict another**. One shared tail
> (now 32 MB / 16 MB) means `.sync` — always-on, 137 call sites — can evict the `[ERROR]` and
> `[AUTH]` entries this row's (c) rationale calls the primary field-debug artifact. Accepted by the
> owner as "just diagnostics"; per-channel floors were declined. This does not change the
> disposition, but it does narrow what (c) can promise: the channel still exists, its retention is
> no longer independent of unrelated traffic.
>
> **And the fifteen replaced files are now unlinked once at launch**
> (`StartupMigrations.deleteLegacyLogFiles`, flag `didDeleteLegacyLogFiles_v1`). Left in place they
> were unreadable, unclearable, and — via `StorageEstimator.totalSizeMB()` → `isOverBudget()` →
> `SyncEngine.runPruneIfOverBudget` — would have displaced real mail rows. Five of the fifteen are
> written in production, where `DebugMenuView` is behind `debugMode.isUnlocked` and unreachable, so
> no user gesture could ever have removed them.
>
> **One thing this change NARROWS, recorded for symmetry with the widening above.** `logChatError`
> is always-on and `AIChat` passes literal user-typed `userText` into it. Unescaped, a user who typed
> a newline followed by `[x] [AUTH] …` produced a second physical line that parses as a genuine AUTH
> entry — surfacing in `read(channel: .auth)`, truncating the real entry in
> `read(channel: .chatError)`, and surviving `clear(channel: .chatError)`. Confined to
> `chat_error.log` that forgery was harmless; the shared file is what made it cross-channel. The user
> span is now passed through `DebugModeManager.escapedForLogLine` **inside the façade** rather than at
> each call site. ⚠️ **An earlier wording of this sentence ended "so no user-authored text can forge a
> channel." That is an UNQUALIFIED ABSOLUTE and it is FALSE** — both reviewers caught it
> independently. `logChatError` escapes only ITS OWN two spans. The other fourteen façades, and
> `AppLogStore.append` itself, still pass their message through unchanged, so
> `BackgroundSyncLogger.log("head\n[<ts>] [AUTH] forged")` still forges an AUTH entry, still
> truncates the SYNC filtered read at it, and still survives `clear(channel: .sync)`. What is closed
> is the `logChatError` path; the general case is REGISTERED here, not fixed, and this row's own
> class C (user-authored folder names on other channels) is a live instance of it. State it as
> "closed for `logChatError`", never as "no user-authored text can forge a channel".
> This does not disturb classes B and C
> below, which are about the account holder's own address and folder names, not about line forgery.
>
> Architecture, the full channel table, and the rule that a new channel is an `AppLogChannel` case
> rather than a sixteenth file: [`Companion/Memory/Current/122-one-log-file-per-process.md`](../../../Memory/Current/122-one-log-file-per-process.md).
>
> ⚠️ **2026-09-04 — the channel arithmetic in this block is now stale, and "all fifteen main-app
> channels" above is FALSE: it is SIXTEEN.** `AppLogChannel.queue` (tag `QUEUE`, sole writer
> `BackgroundSyncLogger.logQueue`) was added for `IOS-QUEUE-008`, taking the gating split from FIVE
> always-on / TEN debug-gated to FIVE / ELEVEN. The disposition of this row is UNCHANGED — the new
> channel is debug-gated at the write and whole-line escaped, so it is strictly narrower than the
> corpus classes B and C defer. Note the sentence immediately above stays correct: "sixteenth FILE"
> counts the fifteen replaced log files, a closed historical set, not channels — do not renumber it.
> Full amendment: [`Amendments/ios-log-002.md`](Amendments/ios-log-002.md).
<!-- KNOWN-ISSUES-AMENDMENT-END -->
# IOS-LOG-002

> Routed from `KNOWN_ISSUES.md` line 1000 during the 2026-08-09 hierarchy split. The exact pre-split source is hash-pinned in [`known-issues-pre-hierarchy-2026-08-09.txt`](../../History/KnownIssues/known-issues-pre-hierarchy-2026-08-09.txt) (`SHA-256 513497704ad37e977e2fb86e4623e956e6f1ca99844122948ff74995dfa9a309`).

- Register classification: `closed-decision`
- Original row SHA-256: `93cfb32cf135a260bc9ef014d618f56db5702bd2e7a0e9b2747ed6bca3e81a7f`

## Status

✅ **CLOSED AS A DECISION (2026-08-05)** — the **persisted/exported** counterpart to `IOS-LOG-001`'s `stdout`-only scope; the message-content half WAS fixed and is named so this row is not read as covering it

## Subsystem and search terms

Diagnostic logging; **always-on persisted channels**; `NSELog.step`/`NSELog.error`; `os_log(privacy: .public)`; unified log; sysdiagnose; `BackgroundSyncLogger`; `error.log`; `DebugLogView` share buttons; account email address; user-authored folder names; global `CLAUDE.md` rule 12; `Companion/Memory/Current/105`; `c44789559`

## Full detail

**(a) Defect.** Two always-on channels persist diagnostics that interpolate user-derived strings, and neither is covered by `IOS-LOG-001` (whose scope is expressly *"the pre-existing, `stdout`-only, `TabMail/Views/` diagnostic corpus"*). **Channel 1 — `NSELog`:** `step`/`error` both fire `os_log(.error, privacy: .public)`, which iOS PERSISTS in the unified log and hands verbatim to a `sysdiagnose`. **Channel 2 — `BackgroundSyncLogger`:** ungated at the write, appended to a file in the app container, and **exported by `DebugLogView`'s share buttons**, i.e. it leaves the device when the user shares it. **(b) The census, by CHANNEL and then by dataflow rather than by keyword** (`MIS-007` instance 18 — a keyword predicate at a SINK is blind to content arriving through an ALIAS assigned in another file, which is exactly how the title sites were missed the first time). **Class A — message content, ✅ FIXED, not deferred:** `c44789559` shaped the step4 sender/subject and step6a AI-blurb lines; this round shaped the remaining **three**, all of which logged `UNMutableNotificationContent.title`, which `EmailNotificationBuilder.fill` sets to `"New email - <senderName>"` — `deliverOnce`, `serviceExtensionTimeWillExpire` and `deliverPassive`. **Class A is now EXHAUSTIVE for message content:** `fill` also sets `c.subtitle = s.subject` and `c.body = reminderContent ?? summaryBlurb ?? ""`, and **no site logs `.subtitle` or `.body`**. A correspondent's name is a THIRD PARTY's PII — someone who never opted into anything — which is why that half was fixed rather than registered. **Class B — the account holder's OWN address, DEFERRED (this row):** three unified-log sites (`NotificationService.swift`, `NSE process: … email=`, `NSE FAIL: no accountId for`, `NSE imap_reconnect: no accountId for`) plus the `BackgroundSyncLogger` corpus — `rg -o 'BackgroundSyncLogger\.[a-zA-Z]+\(' TabMail/ Shared/ TabMailNotificationService/` = **412** call sites, of which **51** interpolate `emailAddress`/`accountEmail` on the call line (a LINE-oriented proxy; a block-aware count will differ, per `MIS-008` instance 12 — restate the predicate if you re-derive it). **Class C — user-authored folder names, DEFERRED (this row):** `NSEIMAPConnection`'s `NSE IMAP SELECT \(folderPath) failed` plus **12** `logBackfill`/`BackgroundSyncLogger` lines interpolating `folder.name`/`folderName`, same proxy caveat. **(c) Why classes B and C are NOT swept — a genuinely two-sided trade, which is the whole reason this is a decision and not a to-do.** `NSELog`'s own documentation states that firing at `.error` is the established field-visibility trick because the NSE is otherwise invisible in the field. Redacting `accountEmail` from `NSE process:` removes **the only account attribution available BEFORE `accountId` resolves** — and the very next failure line is literally `no accountId for …`, i.e. the state in which nothing else identifies the account. Redacting it from `BackgroundSyncLogger` makes multi-account sync / backfill / push triage impossible on the primary field-debug artifact. Concrete legitimate work would be lost, so this is the chosen side of a two-sided trade, not an unclosed hole. Class A had no such counterweight — a length still tells you a title reached the banner, which is the entire field question — which is why the two halves are dispositioned differently. **(d) Exposure, stated honestly.** The account holder's own address on their own device's logs is a materially weaker exposure than a correspondent's name: the unified log requires an attached Console session or a `sysdiagnose` the user deliberately captures, and `error.log` requires the user to press Share. **ADR-004 zero-retention is not violated** — nothing is transmitted, and the file channel is the user's own container under their own control. **(e) Recoverability / cost of leaving it.** Nothing degrades while this is open, and any individual site is a one-line change with zero coupling. ⚠️ **Stated negatively (`MIS-019`):** this row does **not** license adding NEW user-content interpolations to either channel — a new one inside a range is still a defect and is still swept; it does **not** cover message content (class A is fixed, and the three title sites are named above so this row is not misread as deferring them); it does **not** cover anything that could carry a SECRET, which is the PRIME DIRECTIVE and not this row; and it does **not** license gating `NSELog.step` itself, which is deliberately always-on and load-bearing.
