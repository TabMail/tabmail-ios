# IOS-BUILD-001

> Routed from `KNOWN_ISSUES.md` line 113 during the 2026-08-09 hierarchy split. The exact pre-split source is hash-pinned in [`known-issues-pre-hierarchy-2026-08-09.txt`](../../History/KnownIssues/known-issues-pre-hierarchy-2026-08-09.txt) (`SHA-256 513497704ad37e977e2fb86e4623e956e6f1ca99844122948ff74995dfa9a309`).

- Register classification: `history`
- Original row SHA-256: `8db8ebbf30dccadc7678a9332437010a4cacba801aaaacaffbd2194a7ce44b38`

## Status

🧭 **HISTORY FACT — permanent, will never be "fixed"** (2026-08-05). Not a product issue; a navigation warning for anyone bisecting or building this range

## Subsystem and search terms

bisect; `git bisect`; non-buildable commit; release range; `ec3236f1d`; `ac74baba5`; `2826483de`; `675354e6f`; `SyncEngineMaintenance.swift`; dropped brace; `git apply --cached`; `MIS-028`

## Full detail

🚨 **ANY BISECT OR BUILD OF THE RELEASE RANGE MUST START AT `675354e6f` OR LATER.** The three consecutive commits `ec3236f1d` → `ac74baba5` → `2826483de` **do not compile as committed** — they are non-buildable intermediates, and a bisect that lands on one of them will report a build failure that has nothing to do with the behaviour being bisected. `675354e6f` ("Restore the extension brace `ec3236f1d` dropped — HEAD did not compile") repairs it, and HEAD builds green.

**Evidence, re-derived rather than inherited.** Parsing the committed blob directly: `git show <sha>:TabMail/Services/Sync/SyncEngineMaintenance.swift > x.swift && xcrun swiftc -parse x.swift` fails at all three shas with `error: static properties may only be declared on a type` at `:559:24` and `error: static methods may only be declared on a type` at `:603:24`; the same command at `675354e6f` and at every commit after it exits 0.

**SCOPE — exactly one file, bounded by census, not assumed.** Every `.swift` file touched anywhere in `ec3236f1d^..2826483de` was parsed at `2826483de`: `AppDatabase.swift`, `SyncEngine.swift`, `DatabaseIndexTests.swift` and `SyncMaintenanceTests.swift` all parse; only `SyncEngineMaintenance.swift` fails. ⚠️ **Stated negatively:** this is a per-file *parse* census, so it bounds the syntactic breakage only — it is not a claim that the three commits would link, pass tests, or be semantically correct if the brace were restored.

**CAUSE — see `MIS-028`.** The commits were assembled by staging per-item hunks with `git apply --cached --unidiff-zero`. A **pure-deletion hunk** moving `extension SyncEngine`'s closing brace past three new declarations was silently not applied, so those declarations landed at file scope. A hunk that only removes lines leaves no added text to notice missing afterwards, and a brace is invisible in a `--stat`.

**WHY THE H1 MEASUREMENT EVIDENCE IS UNAFFECTED.** `git apply --cached` is documented as applying "the patch to just the index, without touching the working tree", so the defect was confined to the index; the working tree retained the correct brace throughout, and the H1 timing measurements were gathered from a build of that working tree. That is the same divergence between the index and the worktree which caused the defect in the first place — here it happens to be the reason the measurements survive.

**NOT REWRITTEN, DELIBERATELY.** History rewriting was forbidden for this range, so the commits stay as they are and this row exists instead. Do not amend, rebase or squash them to "clean this up".
