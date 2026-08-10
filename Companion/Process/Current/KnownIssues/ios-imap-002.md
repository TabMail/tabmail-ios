# IOS-IMAP-002

> Routed from the separate “Fixed by D4” compatibility table in `KNOWN_ISSUES.md` line 486. The exact pre-split source is hash-pinned in [`known-issues-pre-hierarchy-2026-08-09.txt`](../../History/KnownIssues/known-issues-pre-hierarchy-2026-08-09.txt) (`SHA-256 513497704ad37e977e2fb86e4623e956e6f1ca99844122948ff74995dfa9a309`).

- Register classification: `fixed-by-d4` (not counted in the main register)
- Original row SHA-256: `afb143cf39c35fc7bf645b57bd6c827d893f09ef03ed300790cc6b3520c1c6f0`

## Historical defect

**A duplicate RFC 822 Message-ID on IMAP made one swipe mutate EVERY copy.** `MessageHeader.stableId` returned the RFC whenever `messageId` was numeric, and `IMAPProvider.resolveUID` fell through to `searchByMessageId` and returned **the entire `UIDSet` with no cardinality check**; its consumer stored flags on that whole set. Reachable with aliases, which are common. **Latent at and before `v1.6.38` — not a post-`v1.6.38` regression.**

## Closed by

ADR-IOS-068 (D4 native-provider-id keying). ~~Under D4 there is no multi-match set to check, because nothing searches.~~ ⚠️ **THAT SENTENCE IS RETRACTED — it was FALSE at `60a8751cb` and the final audit train caught it.** `IMAPProvider.searchByMessageId` still had three live call sites, and one of them — `saveDraft`'s no-`APPENDUID` arm — converted a `SEARCH` result into a **draft mutation address** (`.created(.imap(…))`), which `DraftStore.applyPushCompletion` persisted and `deleteDraftStrong` later mutated with `STORE \Deleted` plus, on a UIDPLUS server, an **irreversible `UID EXPUNGE`**. The exact-verify and cardinality guards the candidate added prove *"exactly one message carries this Message-ID"*, **not** *"this is the message we appended"* — so a same-Message-ID sibling could be expunged instead. That was a **BLOCKING C3** finding and is **fixed separately** (the arm now returns `.unaddressable`; absence of `APPENDUID` yields no address at all). The lesson this register row should carry: **"nothing searches" is a claim about the whole tree and must be re-verified by grep, not inherited from an ADR's intent.** The rest of the row stands, and the original defect remains fixed. Pinned by a red-first invariant test.
