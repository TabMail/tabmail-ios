<!-- KNOWN-ISSUES-AMENDMENT-BEGIN -->
> **⚠️ AMENDMENT (2026-08-13) — ONE SITE LEFT THIS ROW'S `TabMail/Services/` CORPUS. The disposition
> below is unchanged (still CLOSED AS A DECISION), and the body is preserved unedited because it is
> regenerated from the hash-pinned archive and byte-compared.**
>
> `beff4dc19` ("Debug-gate the search entry point's echo of the user's query text") gated **exactly
> one** site inside this row's registered `TabMail/Services/` corpus: the opening `print` of
> `SearchIndex.search(query:fromDateMs:toDateMs:limit:folderIds:)`, which interpolated
> `query.prefix(80)` — the text the user typed into the search field — alongside the `ftsQuery`
> derived from it, and fired on every search. This is a **narrow amendment to the closed decision,
> not a sweep of it.** The row's range-not-corpus rule bounds what gets SWEPT; it never asserted that
> a user-content site inside the corpus is correct as written, and the body below already separates
> the sites interpolating plausible USER CONTENT as the stronger subclass — it records `ad9d9047d`
> gating the two `SearchView` prints that carried the account address as *"this same round doing
> exactly that"*. `SearchIndex.swift`'s other 34 ungated prints **stay**, per the decision.
>
> **Post-census, as stated by `beff4dc19`'s own commit body at that commit's HEAD:**
> `TabMail/Services/` **1,309 → 1,308**; `SearchIndex.swift` **35 → 34**; `TabMail/Views/` unchanged
> at **159**; `IOS-LOG-003`'s calendar family unchanged at **77**; the tree-wide `print(` population
> unchanged at **2,180** — nothing was deleted, one site was gated. This discharges the follow-up
> that commit's body records as owed to this row.
>
> ⚠️ **Those figures are `beff4dc19`'s, and were NOT independently re-derived here.** The brace-frame
> census script that produced them is not in the tree, so no positive control could be run against
> this row's own published figures the way the 2026-08-05 scope extension did. Treat them as a lead
> pinned to that commit, not as a bound (`MIS-044`).
>
> 🚫 **DO NOT "correct" the 1,474 / 1,370 figures in the body below to match 1,309 / 1,308.** They
> are neither stale nor the same measurement: they are **revision-pinned** claims about shipped
> `07a4bb703` and candidate `1d1557187`, revisions `beff4dc19` did not touch, while 1,309 → 1,308 is
> a later HEAD over the same corpus. Editing a rev-pinned census so it tracks a newer HEAD falsifies
> it (`MIS-007` instances 27, 45, 59). Independently, **editing the preserved body at all breaks
> `ruby Scripts/compact_known_issues.rb verify` byte-for-byte** — an amendment may only ADD, which is
> why this correction is a wrapped block rather than an edit to the sentence it corrects.
>
> **Everything else in this row is unchanged:** the five closure elements, the negative bound (no
> durable or network channel, no secret-bearing site, no licence to add ungated prints), the
> predicate and its documented `guard` blind spot, and the instruction that any future sweep
> re-derive its own count with the predicate restated beside it.
<!-- KNOWN-ISSUES-AMENDMENT-END -->
# IOS-LOG-001

> Routed from `KNOWN_ISSUES.md` line 988 during the 2026-08-09 hierarchy split. The exact pre-split source is hash-pinned in [`known-issues-pre-hierarchy-2026-08-09.txt`](../../History/KnownIssues/known-issues-pre-hierarchy-2026-08-09.txt) (`SHA-256 513497704ad37e977e2fb86e4623e956e6f1ca99844122948ff74995dfa9a309`).

- Register classification: `closed-decision`
- Original row SHA-256: `fb7e74d46ad6ddb55c98af11ef231155dac1a70fd3d9a2acfac1aef041665604`

## Status

✅ **CLOSED AS A DECISION (2026-08-05)** — `stdout` is discarded on device, nothing is persisted or transmitted, so ADR-004 is not engaged and **nothing degrades while this stays open**; the cell below states all five closure elements and bounds the claim negatively (durable/network channels and secret-bearing sites are explicitly NOT covered). **Its full statement is preserved verbatim below. Original disposition, retained as history:** 🔓 **OPEN by decision — CLOSED as a question (2026-08-04)**; pre-existing and **REDUCED** by v3 (183 → 169 ungated over the same corpus); no data risk, no user-visible defect, no coupling to any other work; **this row is the record that the sweep is deliberately not opened**, not a to-do

## Subsystem and search terms

Diagnostic logging; global `CLAUDE.md` rule 12; ungated `print`; `DebugModeManager.isLoggingEnabled`; `TabMail/Views/`; `stdout` discarded on device; Console.app; sysdiagnose; ADR-004 zero retention; `af98d92c7` range-not-corpus precedent; C3 refusal paths; minimal diffs; scope creep; `Companion/Memory/Current/105`

## Full detail

**(a) Defect.** **169 ungated diagnostic `print` sites across 28 of the 127 files in `TabMail/Views/`** at HEAD `ad9d9047d` — predicate and per-rev table immediately above — of which a manually classified **41** (broad mechanical proxy: 44) interpolate plausible USER CONTENT: `account.emailAddress`, `draft.subject`, reminder/task KB statements, AIProbe keys. They are compiled into Release builds and they execute there. **(b) Reachability.** A `print` on iOS writes to `stdout`, and on a device `stdout` is **discarded** unless a debugger or Console is attached — nothing in this tree redirects it (`Companion/Memory/Current/105` §1; ⚠️ re-verify that claim by READING the `freopen`/`dup2` hits, which are that topic's own explanatory comments and not code, per its own self-matching warning). So the whole exposure is: an attached Xcode / Console.app session on a connected device, or a `sysdiagnose` the user deliberately captures and hands to someone. **The app persists none of it** — no file, no server, no crash payload — so **ADR-004 zero-retention is NOT violated**: nothing leaves the device and nothing is written on it. **(c) Attribution — PRE-EXISTING, and this line IMPROVED it.** Same predicate, whole corpus: shipped `07a4bb703` = **183** ungated, `v2final` `e28dd4edb` = 173, HEAD = **169**. Not refactor-attributable and not candidate-attributable to any commit in this range; the range's own *added* diagnostics were censused separately and separately adjudicated (see `af98d92c7`, TRUE COUNT 3). **(d) Recovery.** No data risk, no user-visible defect, no migration, no schema, no protocol, no ordering constraint. The logs are ephemeral by construction (b), and any individual site can be gated later by a one-line change with zero coupling to anything else. **Nothing degrades while this stays open** — that is the property that makes deferring it free rather than merely cheap, and it is why this is a decision rather than a deferral. **(e) Accepted cost.** A 169-site sweep across 28 files at the close of the refactor is a large, entirely mechanical, wholly unreviewed diff that would need its own audit round — against the minimal-diffs rule and against the owner's explicit instruction not to let scope creep restart the cycle. The in-tree precedent already settled the scope: `af98d92c7` scoped this obligation to the **RANGE** (*"Ungated diagnostic logs added in `da57fde6f^..6391de9a5` — TRUE COUNT 3"*), and those 3 were adjudicated **correct as ungated** because they sit on **C3 refusal paths**, where a refusal that leaves no production trace is a genuine observability gap rather than noise. That precedent is the reason this row is a closed decision: a **new** ungated diagnostic inside a range is still a defect and is still swept — `ad9d9047d` gating the two `SearchView` prints that interpolated the account address is this same round doing exactly that — while the pre-existing corpus is not. ⚠️ **Stated negatively, because the absolute would otherwise be far too wide (`MIS-019`).** This row does **not** license adding ungated prints; does **not** cover any log that reaches a durable or network channel (`BackgroundSyncLogger`, `NSELogStore`, a crash breadcrumb, a worker `logger.*`); and does **not** cover a site whose text could carry a SECRET rather than user content — a secret in a log is the PRIME DIRECTIVE, not this row. It covers exactly the pre-existing, `stdout`-only, `TabMail/Views/` diagnostic corpus enumerated above. **If it is ever swept**, do it as its own commit against a **re-derived** count with the predicate restated beside it, and expect the number to have moved.

📌 **SCOPE EXTENDED 2026-08-05 (audit round 7) — the SAME decision, on the SAME five closure elements above, also covers the pre-existing ungated corpus in `TabMail/Services/`.** This row's measured corpus was `TabMail/Views/` only, which left every pre-existing ungated `print` in `TabMail/Services/` outside any registered decision — an unregistered residual rather than a deliberate one. It is registered here instead of being swept. **Measured with THIS row's own predicate, unchanged** (comment-stripped, string-literals-skipped, word-bounded `(^|[^A-Za-z0-9_.])print\(`; GATED iff an ENCLOSING brace-frame header contains `DebugModeManager.isLoggingEnabled`, or an `#if DEBUG` is open, or an enclosing frame references a same-file hoisted `let X = DebugModeManager.isLoggingEnabled()`): **shipped `07a4bb703` = 1,474 ungated across 169 Swift files; candidate `1d1557187` = 1,370 ungated across 176 files.** The range **REDUCED** the Services corpus by 104, the same direction `TabMail/Views/` moved (183 → 169), so this corpus is **pre-existing and improved**, not candidate-attributable. **The instrument was validated before use:** the same script reproduces this row's own published `TabMail/Views/` figures exactly — 183 ungated at `07a4bb703`, 96 gated / 169 ungated at `ad9d9047d`, corpus total 265, 127 files — which is the positive control that the Services numbers are measured by the same rule. ⚠️ **Known, symmetric blind spot, stated so the integers are not mistaken for a hand count:** the predicate scores a top-of-function `guard DebugModeManager.isLoggingEnabled() else { return }` as UNGATED, because a `guard` is not an enclosing brace-frame header (`BackgroundSyncLogger` is the largest such site). That is one of the three shape blind spots this census already documents, it is present at BOTH revisions, and the numbers are therefore comparable to each other rather than to a manual audit. **The one candidate-introduced Services site was NOT deferred under this row and has been gated:** `UndoService.applyRekeys`' `[UndoStack] REKEY member …`, added by `f7c3354c5` (`applyRekeys` does not exist at `07a4bb703`) and firing on the ORDINARY DRAIN SUCCESS path via `AccountManagerQueue.publishRekeys`. That is this row's own range-not-corpus rule doing exactly what it says — *a **new** ungated diagnostic inside a range is still a defect and is still swept* — and the C3-refusal-path carve-out that justified `af98d92c7`'s three does not reach a site that witnesses a SUCCESS. **Accepted cost and recovery are unchanged from (d) and (e) above:** `stdout` is discarded on device, nothing is persisted or transmitted, ADR-004 is not engaged, nothing degrades while this stays open, and a 1,370-site mechanical sweep across 126 files at the close of the refactor is exactly the unreviewed diff element (e) refuses.
