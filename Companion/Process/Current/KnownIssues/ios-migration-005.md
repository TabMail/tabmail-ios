# IOS-MIGRATION-005

> Routed from `KNOWN_ISSUES.md` line 1321 during the 2026-08-09 hierarchy split. The exact pre-split source is hash-pinned in [`known-issues-pre-hierarchy-2026-08-09.txt`](../../History/KnownIssues/known-issues-pre-hierarchy-2026-08-09.txt) (`SHA-256 513497704ad37e977e2fb86e4623e956e6f1ca99844122948ff74995dfa9a309`).

- Register classification: `closed-decision`
- Original row SHA-256: `fc221684f543da883f691beaf3827903814558923c8c95a457be591206d3ad64`

## Status

✅ **CLOSED AS A DECISION (2026-08-06)** — `pendingRender` is a **dead table that is knowingly RETAINED, together with both of its remaining `DELETE` statements**. Neither the "drop it in a new migration" lever nor the "delete the dead call sites" lever is taken, and the reasons are different for each

## Subsystem and search terms

Dead table; `pendingRender`; `v32_createPendingRender`; durable body staging; `DROP TABLE`; launch-path migration; `v84`; `AccountManagerUidValidityReset`; UIDVALIDITY purge enumeration; ADR-IOS-061; `SettingsView` clear-local-data; `MessageHeaderRekey`; Code Quality rule 5; sibling of `IOS-MIGRATION-002` / `IOS-MIGRATION-004`

## Full detail

**What the table is.** `v32_createPendingRender` creates a 9-column table (`id` PK = headerId, `accountId`, `messageId`, `folderPath`, `htmlBody`, `textBody`, `attachmentsJSON`, `inlineImagesJSON`, `createdAt`) for *"durable body staging"* — persisting a fetched body between fetch and render so it survives an app kill. **That feature was never built.** `MessageHeaderRekey`'s doc comment already calls it *"a DEAD TABLE"*; this row is the decision that comment was missing.

**LEVER 1 — drop it in `v84`. REFUSED, and the reason is the launch path, not the table.** A `DROP TABLE` can only be reached through a registered migration, which runs on the blocking launch chain. That chain was cut from the owner's measured **27,601 ms** to a projected **3,241 ms** across three changes (`IOS-MIGRATION-002`, `IOS-PERF-005`) specifically by taking work OFF it. Spending a new migration to drop a table that is **provably empty in every database** reclaims **zero bytes** and buys nothing — it is the same trade `IOS-MIGRATION-002` and `IOS-MIGRATION-004` already refused from the other direction, and the *cheapest* possible instance of it.

**LEVER 2 — delete the two dead `DELETE FROM pendingRender` call sites (Code Quality rule 5). REFUSED, and this is the part that is NOT obvious.** Both are members of **safety enumerations**, not ordinary call sites: `AccountManagerUidValidityReset` deletes it as item **(iv)** of a documented purge list `(i)…(iv)` that is ADR-IOS-061's purge-completeness closure, and `SettingsView` deletes it inside the clear-local-data statement list. **Keeping a no-op `DELETE` is fail-safe in BOTH directions; removing it is safe only for as long as the table stays dead.** Durable body staging is a real feature this codebase could re-adopt — it is literally what the table was created for — and on the day someone adds the first `INSERT`, both enumerations would silently under-cover: a UIDVALIDITY reset would leave staged bodies keyed to a dead epoch, and "clear local data" would not clear them. **No v3 test pins either enumeration** (the purge-completeness test that asserted `pendingRender` is cleared lives on the `v2final` sibling line and is not on this branch), so nothing would catch it. The cost of the refusal is two `DELETE FROM` statements against a table with no rows.

**Why this is a decision and not an unfinished task.** Both levers were refused on derived evidence and no code changed; that is the correct outcome, not an incomplete one. **The non-recovering case, named per `MIS-IOS-008`: none** — nothing was built and nothing was removed, so there is no mechanism that can fail. The accepted cost is a 9-column always-empty table in every user database plus two statements that never delete anything.

⚠️ **Stated negatively, so this does not become a general licence (`MIS-019`):** this does **not** say dead tables should be kept. It says **this** one should, on three conjunct facts — it is provably empty everywhere, so dropping it reclaims nothing; its only drop vehicle is a launch-path migration on a chain that was just optimised; and its two surviving references are members of safety enumerations rather than ordinary reads. **A dead table that actually holds rows, or one whose references are ordinary call sites, is a different case and must be argued separately** — nothing here covers it.

**Expiry condition, stated so the next reader can check it instead of quoting the 9.** This row goes stale the moment anything **INSERTs** into `pendingRender`: the rows stop being hypothetical, both `DELETE`s stop being no-ops, and the table stops being dead. Re-derive the census the way this one was taken — case-insensitively, by table name AND by Swift model type — rather than restating the integer (`MIS-007`).
