# IOS-DRAFT-018

> Routed from `KNOWN_ISSUES.md` line 1126 during the 2026-08-09 hierarchy split. The exact pre-split source is hash-pinned in [`known-issues-pre-hierarchy-2026-08-09.txt`](../../History/KnownIssues/known-issues-pre-hierarchy-2026-08-09.txt) (`SHA-256 513497704ad37e977e2fb86e4623e956e6f1ca99844122948ff74995dfa9a309`).

- Register classification: `closed-decision`
- Original row SHA-256: `97bc3b6b4c1e53bbda77167b0276160e8905211c10cc91b942ee53d6b750665d`

## Status

✅ **CLOSED AS A DECISION (2026-08-06, round-12 T4)** — `DraftStore`'s `runtimeKind == .unknown` guard throws `actionIdentityResolutionFailed`, which the drain **terminalizes**; the code is defensible but the comments around it stated the opposite, and are corrected rather than the disposition being changed

## Subsystem and search terms

Drafts; `DraftStore`; `runtimeKind`; `.unknown`; `AccountManager.draftRuntimeIdentityKind`; `ProviderError.actionIdentityResolutionFailed`; `PendingOperation`; `AccountManagerQueue`; terminalizes; not retryable; `ProviderEvidenceUnavailable`; mirror-image; `IOS-QUEUE-003` item 4; `MailNavigationView`; fail-closed sentinel

## Full detail

**What was wrong — in the DOCUMENTATION, not the mechanism.** Three sites described this path incorrectly: `PendingOperation` annotated `actionIdentityResolutionFailed` as *(retryable)*, which it is not; `AccountManagerQueue` stated as an absolute that *`IMAPProvider.move` therefore no longer raises this error at all*, which is false of BOTH overloads; and the same block said *the op class that raises this error* where two op classes reach the arm. A reader who trusted any of the three would design the wrong fix.

**What now holds.** The annotations state the truth: the drain **deletes** the op row on `actionIdentityResolutionFailed`; both `move` overloads still raise it (the epoch-less one as its entire body, the epoch-bearing one via `nativeUIDSet`) and it is **Checkpoint A** — requiring `idsAreCanonicalUIDs` AND a positive admitted epoch — that structurally prevents an IMAP op from reaching either; and `IOS-QUEUE-003` item 4 is cited as the owning adjudication.

**Counterfactual discharged, and it is why the disposition did NOT change.** The obvious repair is to swap the throw for `ProviderEvidenceUnavailable` so the op requeues. That produces the **mirror image** (`MIS-005`): a runtime kind that is `.unknown` is `.unknown` on every retry, so the op would starve forever — the wedge corollary, which is in the non-recoverable set, traded for a loss bounded to the op row alone (the local `Draft` row survives and the next open re-derives).

**⚠ DEFERRED sub-item, stated rather than dropped.** The brief also proposed making `.unknown` structurally impossible. `AccountManager.draftRuntimeIdentityKind(for:)` switches over `GmailProvider`/`ExchangeProvider`/`IMAPProvider`/`DemoProvider` with `default: .unknown`, and those four ARE the complete production `EmailProvider` conformer set (all others are test-only). Removing the sentinel is therefore not a small diff — `MailNavigationView`'s `runtimeKind != .unknown` guard and the `.deleteDraft` switch both rely on it as a fail-closed value — and it is deferred to a later round with that reasoning recorded here rather than re-derived.
