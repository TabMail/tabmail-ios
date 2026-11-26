## ADR-IOS-118: The Label Menu Lists Recently Applied Labels Above Every Label A to Z

**Status:** Active (2026-11-24, #1386).

**Context:** The label menu ranked labels by how many inbox messages carried each
(`UserLabelStore.labelsSortedForMenu`). Every opening of the menu read every inbox header of the
account and the label rows of each, then grouped and counted them, so its cost grew with the inbox.
A count is also a poor guide to which label the user wants next: the labels a user reaches for are
the ones they applied recently.

**Decision:**
1. The menu lists up to three labels the user applied most recently in this app, newest first
   (`UserLabelStore.Config.menuRecentCount`), then a separator, then every label of the account
   A to Z; the recent ones appear in the A-to-Z list again. With no recent label the menu is the
   A-to-Z list alone, with no separator. While the user searches, only the matching A-to-Z rows
   show. The order is fixed when the sheet opens; a label applied in the sheet moves up at the next
   opening. A label created in the sheet is inserted where it falls A to Z.
2. The time lives in its own table, `userLabelLastUsed` (`v115_addUserLabelLastUsed`):
   `userLabelId` (primary key, references `userLabel.id` with `ON DELETE CASCADE`) and `lastUsedAt`.
   It starts empty, with nothing backfilled from mail. Only the menu's apply writes it
   (`UserLabelMenuModel.applyLabel` → `UserLabelStore.recordUse`), in the transaction that writes
   the label's join row and queues its operation, after every refusal, so a label has a time
   exactly when an apply of it was admitted. Removing a label, a label applied on another device,
   and labels that sync brings in leave it alone. No counts, no decay.
3. `UserLabelStore.menu` reads the account's labels, the last-used table, and this message's own
   join rows, and no other message. The last-used read names no account: the table has one row per
   label the user has applied in this app, and only labels in the account's list are kept, so a
   system label, an excluded keyword or another account's label never reaches the top.

**Proof of need (why a new table):** no existing field records when a label was applied.
`messageUserLabel` holds only the (message, label) pair, `userLabel` only the label, and the queued
`pendingOperation` row is deleted once it has run. A column on `userLabel` was rejected: label sync
rewrites those rows (the catalog upsert in `SyncEngineFullSync` and the sync arms' inserts), and a
rebuild of `userLabel` (as `v82` did) would have to carry it. A table of its own, keyed by the
label id, keeps the time apart from what sync writes; a sync upsert updates the label row in place
and keeps the time, and deleting the label deletes the time through the cascade. No index beyond
the primary key: the table is as small as the set of labels applied here, and the primary key also
serves the cascade's lookup when a label is deleted. The time is not email content (ADR-004) and
stays on the device; it is not synced.

**Query plans** (`EXPLAIN QUERY PLAN` on the app schema with the new table):
- last-used read: `SCAN userLabelLastUsed`, `USE TEMP B-TREE FOR ORDER BY` (rows: labels applied
  here);
- this message's checkmarks: `SEARCH messageUserLabel USING COVERING INDEX
  sqlite_autoindex_messageUserLabel_1 (messageId=?)`;
- the account's labels (`allLabels`, unchanged): `SCAN userLabel`, `USE TEMP B-TREE FOR ORDER BY`
  (rows: the labels on the device);
- the cascade's child lookup: `SEARCH userLabelLastUsed USING INDEX
  sqlite_autoindex_userLabelLastUsed_1 (userLabelId=?)`;
- removed, the old count: `SEARCH mh USING INDEX messageHeader_folderId_providerDate (folderId=?)`
  over every inbox header, `SEARCH mul USING COVERING INDEX sqlite_autoindex_messageUserLabel_1
  (messageId=?)` for each, then `USE TEMP B-TREE FOR GROUP BY` and `FOR count(DISTINCT)`.

**Consequences:** opening the menu no longer costs more as the inbox grows. Users who upgrade see
the A-to-Z list alone until they apply a label in the menu. A label's time goes with the label
(deleted on the server and swept by sync, or its account removed). A later migration that rebuilds
`userLabel` cascades the times away unless it carries them across.
