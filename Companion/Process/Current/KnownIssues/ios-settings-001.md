# IOS-SETTINGS-001

> Routed from `KNOWN_ISSUES.md` line 1096 during the 2026-08-09 hierarchy split. The exact pre-split source is hash-pinned in [`known-issues-pre-hierarchy-2026-08-09.txt`](../../History/KnownIssues/known-issues-pre-hierarchy-2026-08-09.txt) (`SHA-256 513497704ad37e977e2fb86e4623e956e6f1ca99844122948ff74995dfa9a309`).

- Register classification: `closed-decision`
- Original row SHA-256: `8a463d6e7af2138600103c35a34f44c1af669e763827f550c5e5af921ed63131`

## Status

✅ **CLOSED AS A DECISION (2026-08-05, round-10 F7)** — "Delete All Email Index Data" permanently deletes Agent Chat history (`DELETE FROM chatTurn`, `DELETE FROM chatHistory` in `SettingsView.localIndexWipeStatements`, plus `MemoryIndex.shared.deleteAll()`). Those turns are user-authored and exist on **no server**, so the confirmation alert's *"then re-downloaded from your servers"* was never true of them and the alert named neither their deletion nor their preservation — the user could not give informed consent. **The deletion is KEPT and the alert now discloses it**, because `chatHistory` IS the memory store this same gesture wipes via `MemoryIndex.deleteAll()`, and excising the two SQL lines would leave the two halves of one feature inconsistent; chat turns also carry raw `[Email](N)` references into the `messageHeader` rows the same transaction destroys. **RECOVERABILITY, with the non-recovering case named:** nothing recovers a deleted chat turn — that is precisely why the fix is disclosure rather than mechanism. The user chooses it explicitly, from a destructive-role button, behind a confirmation that now says so

## Subsystem and search terms

settings; `SettingsView.localIndexWipeStatements`; `nukeDatabase`; Agent Chat; `chatTurn`; `chatHistory`; `MemoryIndex.deleteAll`; consent copy; ADR-IOS-023

## Full detail

If the two SQL lines are ever removed, `MemoryIndex.deleteAll()` must be revisited in the same change, and the alert copy corrected back.
