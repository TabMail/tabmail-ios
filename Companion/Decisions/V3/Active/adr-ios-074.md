## ADR-IOS-074: A Forward's Attachment Carry Has One Snapshot Boundary

**Date:** 2026-08-08

**Status:** Active.

**Context.** A fresh forward starts one concurrent fetch per original attachment and returns to the
editor immediately. Send, explicit Save and agent autosave previously captured the live attachment
array independently. Any producer could therefore persist the prefix that happened to have arrived;
the autosave first-save branch persisted no attachment directory at all. Reopening that deterministic
forward draft did not rerun the carry, so the missing user intention became indistinguishable from an
attachment-less forward. This was IOS-COMPOSE-001 and existed in shipped v1.6.38.

**Decision.**

1. `ComposeAttachmentCarryGate` is the single completion authority for the concurrent batch. Send,
   explicit Save and agent autosave are the exhaustive snapshot-producer census and all consult it.
2. A producer waits until every fetch settles before reading the attachment array. Send is replaced
   by a visible “Preparing attachments…” state while work is outstanding, and compose-agent admission
   is disabled at the same boundary. Alternate action entries keep an async defense-in-depth wait.
3. A failed member marks the settled batch incomplete. All three producers refuse until the aggregate
   failure alert is acknowledged, so a failure that lands during an already-waiting action cannot
   dismiss, send or autosave a partial set. Acknowledgement is the user decision boundary: attach the
   missing file manually and retry, or discard and restart the forward.
4. Agent autosave reads the live post-boundary attachment binding and copy-on-write stages that exact
   set. Both first-save and update branches adopt the staging directory only on an applied generation;
   a losing/throwing generation deletes only its own staging directory, while an applied generation
   deletes only the superseded directory.
5. The boundary does not widen message identity, provider address, body fetch or attachment fetch
   authority. IOS-BODY-001 through IOS-BODY-005 remain accepted/forward-fix-only as registered.

**Rationale.** Completeness cannot be inferred from the current array length because the original
expected set lives in asynchronous work, not in the draft row. One explicit completion authority
lets every durable or outbound snapshot share the same fact while preserving the established
bounded-concurrent fetch behavior.

**Consequences.**

- A user cannot silently send or save an in-flight prefix, and an autosaved forward reopens with its
  completed attachment set.
- Save or autosave can wait for the slowest provider fetch (including its existing timeout ceiling).
  This is visible/retained work, not a dropped intention.
- An acknowledged fetch failure can still lead to a deliberately incomplete draft if the user ignores
  the warning and retries without replacing the file; that outcome is no longer silent.
- Copy-on-write attachment staging now also covers agent autosave, increasing bounded temporary disk
  usage during an in-flight save but preserving the live directory across failures and CAS losses.

**Tests / evidence.** Red checkpoint `4a1f45073` fails all three producer gates, early completion and
autosave first-save adoption. Implementation `ec9682dec` passes 71 focused compose/draft/attachment
tests. `ComposeAttachmentCarryTests` pins wait/ready/failure directions and all-members completion;
the existing draft attachment fail-closed/COW suites remain green.

**Relates:** ADR-IOS-019 (durable Outbox), ADR-IOS-072 (unreadable user content fails closed),
IOS-COMPOSE-001, never-drop-user-intention.
