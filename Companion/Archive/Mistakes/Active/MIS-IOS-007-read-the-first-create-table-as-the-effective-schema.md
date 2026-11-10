# MIS-IOS-007 — read the first `create(table:)` as the effective schema, when a later migration had already replaced it

**Class:** review-discipline
**Severity:** high (wrong result shipped — the proposed fix would have written a false claim into the code)
**First seen:** 2026-08 · **Recurrences:** 1 · **Status:** Active
**Related:** `MIS-IOS-001` (the write-side twin: editing an already-applied migration) · **Rule owner:** `tabmail-ios/CLAUDE.md` § *Data Integrity Rules — ABSOLUTE* rule 5

## The tell

I need to know whether a column has a foreign key. I `rg` for `create(table: "<name>")`, read the
first hit, see `.references("...", onDelete: .cascade)` — or don't — and I have my answer. It takes
one grep, the evidence is right there in the source, and I move on feeling I *checked* rather than
assumed. **The confidence comes from having read real code.** That is exactly what makes it stick:
I did not guess, I looked — I just looked at the wrong one of several definitions.

## What actually happened

2026-08-03, branch `v3`, while scoping the `AIWriteTarget` fail-open question (task #36) for the
final audit train.

`AIWriteTarget.resolveCurrentHeader` reads `let folder = try Folder.fetchOne(db, key: folderId)` as
an optional, and a **missing** `Folder` row passes arm 5 (`folder?.uidValidityResetPendingAt == nil`)
and takes arm 7's `guard let liveEpoch = folder?.lastKnownUidValidity else { return header }` —
i.e. an AI write is admitted with no epoch proof, fail-**open** on a mutation path.

I ran `rg -n -A6 'create\(table: "messageHeader"\)' TabMail/Services/AppDatabase.swift`, read the
first match (`AppDatabase.swift:521-523`), and reported:

> `messageHeader.folderId` is declared `.notNull().references("folder", onDelete: .cascade)`, so no
> Folder ⇒ no header rows ⇒ arm 1 (`MessageHeader.fetchOne`) already returned `nil`.

I wrote that hypothesis into the audit brief and told the reviewers the likely disposition was **a
doc comment recording the cascade argument, not a code change**.

**It is false.** Migration `v2_dropMessageHeaderFolderFK` (`AppDatabase.swift:603`) recreates the
table with `t.column("folderId", .text).notNull()` and **no** `.references` — the in-file comment on
line 612 says so in words: *"Recreate messageHeader: folderId is plain column (no FK), accountId has
CASCADE FK"*. Only `accountId` cascades. The grep's `-A6` window on the v1 definition physically
could not reach the v2 redefinition 90 lines below.

Consequences, all caught by the reviewer rather than by me:

- The Scope 3 finding is **reachable**, not unreachable: an IMAP folder that vanishes server-side has
  its `Folder` row deleted by `fullSync` while its `messageHeader` rows survive as orphans.
- The disposition I proposed would have **inscribed a false cascade claim into a doc comment** — in a
  codebase where `SyncEngineFullSync` already carries a comment correcting this exact false belief:
  *"this used to say 'CASCADE handles messageHeader deletion automatically'. That is FALSE"*.
- `PROJECT_MEMORY` T1.3 also states it. Two in-tree sources contradicted me and I had read neither,
  because the grep answered first.

## Why it is not obvious

`AppDatabase.swift` contains **many** `create(table:)` calls for the same table — one per migration
that had to rebuild it (SQLite cannot drop a constraint in place, so removing an FK means
recreate-and-copy). The file therefore holds several *contradictory* definitions of the same table,
all syntactically valid, and **the first one is the one that is wrong**, because it is the oldest.
Grep returns them in file order, so the default reading order is the reverse of the correct one.

The habit is reinforced by every other Swift file in the repo, where one symbol has one definition
and the first hit *is* the answer. `AppDatabase.swift` is the one file where a definition is a
historical record rather than a statement of current fact — the schema is the **fold** of all
migrations, not any single one of them.

This is the read-side of `MIS-IOS-001`. That entry warns that a migration is immutable once applied;
this one is the same underlying truth — *the migration list, not the definition, is the schema* —
approached from the direction of someone merely trying to look something up.

## The rule

To learn a table's current shape, read the **last** migration that touches it, never the first — and
confirm against a real database, because `AppDatabase.swift` holds several contradictory definitions
of the same table and grep returns the oldest first.

## Mechanical check

```bash
# every definition of the table, in migration order — the LAST one is the effective schema
rg -n 'create\(table: "messageHeader"\)|renameColumn.*messageHeader|alter\(table: "messageHeader"\)' \
   TabMail/Services/AppDatabase.swift

# ground truth, which outranks any reading of the source
sqlite3 "$(find ~/Library/Developer/CoreSimulator/Devices/*/data/Containers/Data/Application/*/Library/Application\ Support/TabMail -name tabmail.sqlite | head -1)" \
  ".schema messageHeader"
```

If the first command returns more than one hit, **the first hit is not the answer.**
