## ADR-IOS-074: A Forward's Attachment Carry Has One Snapshot Boundary

**Date:** 2026-08-08

**Status:** Active.

**Context.** A fresh forward starts one concurrent fetch per original attachment and returns to the
editor immediately. The Photos picker also resolves selected items asynchronously. Send, explicit
Save and agent autosave previously captured the live attachment array independently. Any producer
could therefore persist the prefix that happened to have arrived; the autosave first-save branch
persisted no attachment directory at all. Photos, Files and Camera conversion failures were also
silently ignored, even though the user had explicitly selected those items. Reopening a deterministic
forward draft did not rerun the carry, so missing intention became indistinguishable from an
attachment-less forward. The related audit also found that agent edits and Save/Send/Close/Discard
could overtake one another across suspensions. The forward-carry defect was IOS-COMPOSE-001 and
existed in shipped v1.6.38; the broader ingress and disposition census closed the same defect class.

**Decision.**

1. `ComposeAttachmentCarryGate` is the single completion authority for asynchronous attachment
   preparation: original-forward fetches and Photos-picker loads join it before their first
   suspension. Files and Camera are synchronous, but any conversion/read failure marks the same
   unacknowledged-failure state. Send, explicit Save and agent autosave remain the exhaustive
   attachment snapshot-producer census and all consult it.
2. A producer waits until every outstanding preparation settles before reading the attachment array. Send is replaced
   by a visible “Preparing attachments…” state while work is outstanding, and compose-agent admission
   is disabled at the same boundary. Alternate action entries keep an async defense-in-depth wait.
3. A failed member marks the settled batch incomplete. All three producers refuse until one complete,
   source-aware failure census is acknowledged, so a failure that lands during an already-waiting
   action cannot dismiss, send or autosave a partial set. Forward failures retain their discard,
   reopen and retry guidance; a selected Photos/Files/Camera item instead tells the user to reselect
   or attach it another way. Acknowledgement is the user decision boundary.
4. Agent autosave reads the live post-boundary attachment binding and copy-on-write stages that exact
   set. Both first-save and update branches adopt the staging directory only on an applied generation;
   a losing/throwing generation deletes only its own staging directory, while an applied generation
   deletes only the superseded directory.
5. `ComposeAgentSendFence` is the shared exclusive-disposition boundary between a running inline-agent
   edit and Save, Send, Close or Discard. Save and Send claim it before attachment settlement; Send
   also sets `isSending` before that suspension, while Save sets `isSavingDraft`. Close and Discard
   refuse either admitted operation and claim the same fence before their own suspending work. Failed
   or completed non-send dispositions release admission; an outbox-admitted Send retains ownership
   through dismissal.
6. The boundary does not widen message identity, provider address, body fetch or attachment fetch
   authority. IOS-BODY-001 through IOS-BODY-005 remain accepted/forward-fix-only as registered.

**Rationale.** Completeness cannot be inferred from the current array length because the original
expected set lives in asynchronous work, not in the draft row. One explicit completion authority
lets every durable or outbound snapshot share the same fact while preserving the established
bounded-concurrent fetch behavior.

**Consequences.**

- A user cannot silently send or save an in-flight prefix, and an autosaved forward reopens with its
  completed attachment set.
- A selected Photos, Files or Camera item cannot disappear without an on-screen failure; an admitted
  terminal action cannot race a running agent edit or another Save/Send disposition.
- Save or autosave can wait for the slowest provider fetch (including its existing timeout ceiling).
  This is visible/retained work, not a dropped intention.
- An acknowledged fetch failure can still lead to a deliberately incomplete draft if the user ignores
  the warning and retries without replacing the file; that outcome is no longer silent.
- Copy-on-write attachment staging now also covers agent autosave, increasing bounded temporary disk
  usage during an in-flight save but preserving the live directory across failures and CAS losses.

**Tests / evidence.** Red checkpoint `4a1f45073` fails all three producer gates, early completion and
autosave first-save adoption; `cb338d1d8`, `b325c368d` and `a41298e8b` pin the related ingress and
disposition defects. Implementations `ec9682dec` and `f7bc2315c` pass the focused compose, generation
and write-tier gates (34 tests in the final focused receipt at
`Test-TabMail-2026.08.08_11-03-10--0700.xcresult`). `ComposeAttachmentCarryTests` pins
wait/ready/failure directions, all-members completion, Photos admission, synchronous failure
surfacing and disposition ordering; the existing draft attachment fail-closed/COW suites remain green.

**Relates:** ADR-IOS-019 (durable Outbox), ADR-IOS-072 (unreadable user content fails closed),
IOS-COMPOSE-001, never-drop-user-intention.
