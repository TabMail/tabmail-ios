# MIS-IOS-010 — designed a bulk write whose WHERE clause selected exactly the rows a guard was protecting

**Class:** data-integrity | design-process
**Severity:** critical (would have shipped wrong-message mutation — C3)
**First seen:** 2026-08 · **Recurrences:** 1 · **Status:** Active
**Related:** `MIS-IOS-004` (unknown vs authoritative), `MIS-026` (deliberately-held direction),
`MIS-021` (a bound is a claim about code) · **Rule owner:** `CLAUDE.md` § Data Integrity Rules

## The tell

I read `WHERE observedUidValidity IS NULL` as *"the rows we haven't gotten to yet."* It felt like the
safe, conservative half of the predicate — the term that made the write **bootstrap-only** instead of
unconditional. I wrote a whole section of the plan explaining that this clause was a guard, and I was
right that it was a guard; I just had the direction backwards. It was protecting rows **from** me, and
I had turned it into my selector.

The confident phrasing to watch for in my own writing: *"this term is simultaneously the
bootstrap-only rule and the exclusion of every armed row."* One clause doing two safety jobs at once
is a claim, not an observation — and I never grepped who **writes** the NULL.

## What actually happened

`PLAN_FOLDER_EPOCH_BOOTSTRAP.md` rev F (2026-08-07) proposed, inside the success branch of
`SyncEngineEpochVerify.verifyAndBootstrapPrePopulatedFolderEpoch`:

```
UPDATE messageHeader SET observedUidValidity = :epoch
 WHERE folderId = :folderId AND observedUidValidity IS NULL
```

justified by a folder-granular RFC-822 sample proof, on the argument that RFC 3501/9051 forbid UID
reuse within an epoch so the question is folder-granular by construction.

Two independent codex vets, given **different** briefs, converged on the same defect:

- `AccountManagerActions.optimisticMoveToFolder` sets `folderId`/`folderPath` to the **destination**
  while leaving `messageId` as the **source** UID, and writes `observedUidValidity = nil`
  **deliberately** — the row's UID is not an address in that folder until
  `MessageHeaderRekey.finishMove` installs the proven destination address from `COPYUID`.
- So `folderId = :folderId AND observedUidValidity IS NULL` selects **exactly** those remnants. The
  UPDATE converts the sentinel into a false proof; `admittedOrdinaryActionTargets` then admits,
  Checkpoint A claims (both epochs agree), and the provider issues the command against whatever
  message owns that UID in the destination. **C3 on a fully compliant server**, from an ordinary move
  that had not drained before the upgrade.

A second, independent refutation killed the sample argument itself: a mailbox recreated under a new
epoch and refilled with one insertion plus one later omission leaves the four lowest and four highest
sampled UIDs aligned while a bounded interior interval is shifted — so the proposed low+high
strengthening passes and the interior rows are stamped wrong.

Cost: one full plan revision (rev F → rev G) and two vet runs. Nothing was implemented, so no code
shipped — the plan-vet gate is what caught it, which is the gate working as designed.

## Why it is not obvious

`IS NULL` **is** genuinely a bootstrap-only guard in the sibling writes, and the plan cited them
correctly: `bootstrapVerifiedFolderUidValidity` uses `lastKnownUidValidity == nil` for exactly that
purpose, and it is sound there. The clause is load-bearing in both places — but on `Folder` the NULL
means *not yet learned*, while on `MessageHeader` it means *deliberately invalidated*. Same spelling,
same table family, opposite semantics, and only one of them has a second writer that means something
by it.

The generalising argument was also *correct where it applied*: per-row proof really is redundant under
a stable epoch. The error was carrying that conclusion across to the population where the epoch is not
the question at all — a remnant's UID is wrong regardless of whether the numbering rolled.

## The rule

Before writing a bulk UPDATE, grep every **writer** of every column in its WHERE clause and state what
each writer means by the value you are selecting on; a value written deliberately by another code path
is a guard, and selecting on it makes you its second writer.

## Mechanical check

```bash
# For each column named in a proposed bulk UPDATE's WHERE clause, enumerate its writers.
# Any hit outside the module doing the UPDATE is a semantics claim you must resolve.
rg -n "Column\(\"<col>\"\)\.set\(|\.<col> = " --type swift TabMail/ Shared/ TabMailNotificationService/
```

Ask of every hit: *does this writer mean "not yet known", or does it mean "known to be invalid"?*
If any writer means the second, the bulk UPDATE is unsound as written.
