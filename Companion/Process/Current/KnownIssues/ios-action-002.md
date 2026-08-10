# IOS-ACTION-002

> Routed from `KNOWN_ISSUES.md` line 98 during the 2026-08-09 hierarchy split. The exact pre-split source is hash-pinned in [`known-issues-pre-hierarchy-2026-08-09.txt`](../../History/KnownIssues/known-issues-pre-hierarchy-2026-08-09.txt) (`SHA-256 513497704ad37e977e2fb86e4623e956e6f1ca99844122948ff74995dfa9a309`).

- Register classification: `closed-decision`
- Original row SHA-256: `076645bdb682bf3e3a36b92c7462b50404452be10970189a57c73235b4e956c1`

## Status

✅ **CLOSED AS A DECISION (2026-08-04)** — not a deferral at all; this is the STATEMENT of ADR-IOS-069's fourth never-drop exit

## Subsystem and search terms

UIDVALIDITY; provider id reset; queued op; drop; rebind; quarantine; C2; C4; C5

## Full detail

On a UIDVALIDITY change or a provider stable-id reset, every queued op that named an address in the affected space is **dropped** — not rebound, not re-resolved, not re-searched, not quarantined. The user repeats the gesture; sync reconciles the visible state. **This row exists precisely because the behaviour is a deliberate carve-out of "never drop user intention", not an accident:** the invariant still holds in full on the ordinary path (offline, retry, app kill, provider error, transient read failure) and only the id-reset boundary is carved out. It never extends past queue state — Outbox sends, drafts, bodies, attachments and FTS content are never dropped under it, and double-send prevention is unchanged. Owner: *"much better than a fragile and complicated codebase."* See ADR-IOS-069.

✅ **CLOSED AS A DECISION (2026-08-04) — this row is not a deferral; it is the STATEMENT of exit 4, and it kept reading as an outstanding task only because a decision was living in a deferral register.** `tabmail-ios/CLAUDE.md` § *Core Philosophy* now carries it normatively (*"Exit 4 does not widen clause 2 … Exit 4 is the only exit that is a failure, it is deliberately narrow, and nothing else may use it"*), and it is enforced at three points in code: checkpoint A's positive-mismatch delete arm, `opIsProvenInvalidatedByReset` inside `uidValidityResetStampFreshEpoch`, and `admittedOrdinaryActionTargets`' epoch equality. **The decision, restated so it cannot be mistaken for a bug:** a **proven** id reset drops every queued op that named an address in that space, because v3 compares an op against its DURABLE `PendingOperation.observedUidValidity` — once the epoch provably moves, every retry of that op fails identically and forever, so executing it would mean executing under numbering it never observed (C3). An **unknown** epoch is an absence of evidence and stays retryable forever; the two are disjoint and exit 4 must never be widened to cover the second. **Accepted cost:** the user's queued gesture is dropped and they repeat it. **Recoverability:** sync reconciles the visible state. The state where that fails would be one in which the message is no longer addressable after the reset — but the reset reaction purges and resyncs the folder, so post-reaction every surviving message carries a fresh, stamped address. **None found.** The drop never extends past queue state: Outbox sends, drafts, bodies, attachments and FTS content are untouched, and double-send prevention is unchanged. **Editorial note:** the substance belongs in `DECISIONS.md` under ADR-IOS-069 with a one-line searchable pointer here; that routing is a separate task, and this pass wrote only `KNOWN_ISSUES.md`.
