# IOS-ACTION-001

> Routed from `KNOWN_ISSUES.md` line 97 during the 2026-08-09 hierarchy split. The exact pre-split source is hash-pinned in [`known-issues-pre-hierarchy-2026-08-09.txt`](../../History/KnownIssues/known-issues-pre-hierarchy-2026-08-09.txt) (`SHA-256 513497704ad37e977e2fb86e4623e956e6f1ca99844122948ff74995dfa9a309`).

- Register classification: `closed-decision`
- Original row SHA-256: `a93016b4fb69f5c435942f0ec42993a5c3c9ea88c5c610455786f78ef926dc7b`

## Status

✅ **CLOSED AS A DECISION (2026-08-04)** — owner-approved one-time upgrade loss, now IMMUTABLE

## Subsystem and search terms

Action queue; `pendingOperation`; migration `v74`; blanket purge; upgrade; legacy op

## Full detail

Migration `v74_purgeLegacyPendingOperations` runs `DELETE FROM pendingOperation` with no predicate. Any action op queued by a pre-v3 build and not yet drained at upgrade is gone: it removes every legacy row regardless of type, status, decodability or shape, including `.saveDraft` and `.deleteDraft`. Nothing user-authored is touched — `PendingOperation` owns no authored bytes and has no cascade into `Draft`, `Outbox`, `MessageBody` or attachment storage, so draft identity/body/recipients/attachments and Outbox sends remain byte-identical. A dropped `.saveDraft` loses only the automatic server-push intention (the local content stays; the user saves again); a dropped `.deleteDraft` may leave a stale server draft that sync shows again, which is safer than retaining an obsolete destructive address. Startup still runs Outbox reconciliation independently. See ADR-IOS-071.

✅ **CLOSED AS A DECISION (2026-08-04) — an owner-approved one-time upgrade boundary that is now IMMUTABLE and therefore no longer revisable.** Verified at the tip: `migrator.registerTimedMigration("v74_purgeLegacyPendingOperations") { db in try db.execute(sql: "DELETE FROM pendingOperation") }`, carrying the comment *"Owner-approved C6 upgrade boundary"*. **Basis, from this codebase rather than from principle:** the alternative at the time was to decode each legacy row and validate its address space against a keying scheme v3 replaced — precisely the "reconstruct an address the system was already told and discarded" pattern that `MIS-IOS-003` and `CLAUDE.md`'s § *THE ADDRESS PROBLEM* forbid. **And the decision cannot be re-opened:** the migration has run on every device that launched the branch, so Data Integrity Rule 5 freezes its name AND its body; narrowing it now would either silently not execute (append) or re-run the whole body and crash at launch (rename). Any future change must be a new `vNN`. **Accepted cost:** un-drained pre-v3 action ops are gone at the upgrade instant. **Why the cost is bounded — re-verified, not inherited:** `PendingOperation` owns no authored bytes and no FK runs from `Draft`, `Outbox`, `MessageBody` or attachment storage into `pendingOperation`, so draft identity/body/recipients/attachments and Outbox sends are byte-identical across the migration. **Recoverability:** every lost op's target is still visible after the next sync, so the user re-issues the gesture. **A state where the user cannot re-issue it was searched for and none exists** — which is the whole reason the boundary was acceptable to the owner.
