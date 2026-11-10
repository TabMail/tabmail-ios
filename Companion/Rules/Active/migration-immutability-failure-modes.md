### Data integrity rule 5: migration immutability failure modes (appending, renaming, duplicate column launch crash, grdb_migrations check)

Routed out of `CLAUDE.md` by the `companion-compact` skill (2026-11-10). A short form stays inline in `CLAUDE.md`; below is the original text, byte-for-byte (sha256 of the block: `8bdba07ce2f31d2c4e1d5921b733a632dc13119d190da0b8c55eae47dab1f07d`).

<!-- preserved-block-begin -->
   - **Appending to an applied migration's body** — the new statements NEVER execute on any DB that already ran it. The column silently does not exist while the code assumes it does.
   - **Renaming it to cover the additions** — GRDB reads the new name as a brand-new migration and re-runs the WHOLE body, which fails on the columns that already exist (`duplicate column name: …`). `AppDatabase` init throws, `shared` stays nil, and `AppDatabase.rawPool`'s force-unwrap **crashes the app at launch before any UI appears**.

   Both were done to one migration on the abandoned post-`v1.6.38` line (2026-07-25) and produced exactly that launch crash. The RULE: once a migration has been run anywhere, freeze its name AND its body; every subsequent schema change gets its own new `vNN`. A fresh install (run vNN then vNN+1) and an existing DB (skip vNN, run vNN+1) must converge on the same schema — state that convergence in a comment when you split.
   **Diff review CANNOT catch this** — the defect lives in the divergence between the diff and already-applied DB state. Verify against reality instead: `sqlite3 "<simulator>/Library/Application Support/TabMail/tabmail.sqlite" "SELECT identifier FROM grdb_migrations ORDER BY rowid DESC LIMIT 5;"` and `PRAGMA table_info(<table>);`.
<!-- preserved-block-end -->
