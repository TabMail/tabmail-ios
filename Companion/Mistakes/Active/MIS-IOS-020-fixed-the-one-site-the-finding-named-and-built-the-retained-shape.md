# MIS-IOS-020 — I fixed the one site the finding named, and then built the retained shape the reviewer's own deletion-first answer had already priced out

**Class:** design-process
**Severity:** medium (wasted rounds)
**First seen:** 2026-09 · **Recurrences:** 1 · **Status:** Active
**Related:** root `MIS-006` (fixed the instance, not the class) · root `MIS-007` (census inherited its search shape) · `MIS-IOS-019` (the same PR's earlier log defect) · **Rule owner:** the monorepo root's `debug-gate-diagnostic-logs.md` routed rule, § addendum 2026-09-05 (root path deliberately not spelled out — see this tree's Mistakes `README.md`)

## The tell

Two, and they arrive together:

1. *"The finding says the defect is at `SyncEngine.runSyncMessages`. I fixed
   `SyncEngine.runSyncMessages`. Thoroughly — three tests, two mutation proofs. Done."* It feels
   like unusually disciplined, well-scoped work, because it is — at one site.
2. *"The reviewer offered deletion OR a carrier. Deleting the instrument would throw away the
   observability the last round was asked to add, so obviously I build the carrier."* The retained
   shape feels like the responsible choice; deletion feels like giving up on the deliverable.

## What actually happened

PR #113, `agent/ios-queue-sync-move-instrumentation`.

- Round 4 (`R4-RS-1`) named ONE symbol: the `[MoveTrace] fullSync upsert` line was rendered inside
  `dbPool.write`, and `AppLogStore.append` enqueues file I/O no `ROLLBACK` retracts. `ef81ee3e5`
  fixed exactly that symbol — correctly, with three new tests and mutation proofs.
- Round 5's correctness AND robustness angles independently reported the identical mechanism at
  **eleven more sites**: six `deltaMoveTraceLog` calls in `gmailDeltaSync`'s write, five `queueLog`
  calls in the drain's claim closure and `reconcilePendingOperations`' `retryWrite`, and
  `undoMove`'s `phase=queuedInverse`. Nothing had changed about them since round 4; they were simply
  never censused, because the round-4 finding was phrased at a symbol.
- Both round-5 reports carried an explicit **"Deletion-first answer"** paragraph saying deletion
  resolves it and crosses none of the three red lines. Round 6 built the carrier anyway (branch
  `agent/ios-queue-sync-move-instrumentation-r6-carrier`). The owner chose deletion on 2026-09-05
  00:30 — *"this is a debug instrument; on rare occasions it's okay to miss that line"* — and that
  branch was superseded unmerged.

Cost: two extra review rounds and one discarded implementation branch, for a change whose accepted
form deletes eleven lines and one façade.

## Why it is not obvious

A finding written "at symbol X" reads as a bounded work item, and fixing it *well* — red-first,
mutation-proved — produces every signal of a job finished. Nothing in that loop asks "what else
shares this mechanism". And the carrier is not a bad design; it is the shape the PREVIOUS round's
fix used and was praised for. Reaching for it again looks like consistency, which is exactly what
makes it invisible that the previous round's line had a reason to survive (it is the one that
attributes a reappearance) and these did not.

## The rule

Before fixing a finding phrased at one symbol, census every site sharing its MECHANISM and fix the
class; and when a reviewer states a deletion-first answer, price deletion first and put the retained
shape to the owner instead of building it.

## Mechanical check

```bash
# From the iOS checkout root: every debug-log emission lexically inside an open
# database write. The `TOTAL` is the census; a finding at one of these lines is a
# finding about all of them.
python3 - <<'PY'
import re,glob
emit=re.compile(r'BackgroundSyncLogger\.log(Queue|Inbox)\(|queueLog\(|deltaMoveTraceLog\(')
opener=re.compile(r'(\.write\s*\{|retryWrite\(|\.write\s*\(|\.inTransaction\s*\{|\.inSavepoint\s*\{|\.barrierWriteWithoutTransaction\s*\{)')
hits=[]
for f in sorted(glob.glob('TabMail/**/*.swift',recursive=True)):
    depth=0; stack=[]
    for i,line in enumerate(open(f).read().split('\n'),1):
        code=re.sub(r'//.*','',line); code=re.sub(r'"(\\.|[^"\\])*"','""',code)
        if opener.search(code): stack.append((i,depth))
        if emit.search(line) and stack: hits.append((f,i,stack[-1][0],line.strip()[:100]))
        depth+=code.count('{')-code.count('}')
        while stack and depth<=stack[-1][1]: stack.pop()
for h in hits: print(f"{h[0]}:{h[1]} (write opened at {h[2]}): {h[3]}")
print("TOTAL",len(hits))
PY
```

There is no mechanical check for the second half — reaching for the retained shape when deletion was
offered is caught only by a reader who reads the reviewer's own "deletion-first answer" paragraph
before writing the brief.
