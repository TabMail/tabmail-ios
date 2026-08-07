# MIS-IOS-001 — I edited a migration that had already run, and bricked launch

**Class:** data-integrity
**Severity:** critical (brick)
**First seen:** 2026-07-25 · **Recurrences:** 2 · **Status:** Active
**Related:** [MIS-IOS-002](MIS-IOS-002-date-window-for-imap-sync.md) · **Rule owner:** `tabmail-ios/CLAUDE.md` § Data Integrity 5

## The tell

The migration is **uncommitted**. It is my own work, from this branch, not yet in anyone's history.
Editing it feels obviously safe — I am just finishing what I started.

## What actually happened

Both halves of the trap were sprung on one migration on the abandoned post-`v1.6.38` line:

1. **Appending to an applied migration's body** — GRDB records applied state by migration **name**,
   per database. The new statements never execute on any DB that already ran it. The column silently
   does not exist while the code assumes it does.
2. **Renaming it to cover the additions** — GRDB reads the new name as a brand-new migration and
   re-runs the **whole** body, which fails on columns that already exist
   (`duplicate column name: …`). `AppDatabase` init throws, `shared` stays nil, and
   `AppDatabase.rawPool`'s force-unwrap **crashes the app at launch before any UI appears**.

## Why it is not obvious

"Uncommitted" and "unapplied" are different facts, and only the first one is visible in git. The
migration has already run on **every dev simulator and device that launched the branch** — including
yours. The divergence lives between the diff and already-applied DB state, which is precisely the
place a diff review cannot look.

## The rule

Once a migration has run **anywhere**, freeze its name **and** its body; every subsequent schema
change gets its own new `vNN`.

## Mechanical check

```bash
# Diff review CANNOT catch this. Verify against reality:
sqlite3 "<simulator>/Library/Application Support/TabMail/tabmail.sqlite" \
  "SELECT identifier FROM grdb_migrations ORDER BY rowid DESC LIMIT 5;"
sqlite3 "<...>/tabmail.sqlite" "PRAGMA table_info(<table>);"
```

When you split, state the convergence in a comment: a fresh install (runs `vNN` then `vNN+1`) and an
existing DB (skips `vNN`, runs `vNN+1`) must reach the same schema.
