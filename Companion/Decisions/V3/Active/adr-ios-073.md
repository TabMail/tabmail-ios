## ADR-IOS-073: Atomic UID MOVE Is a Distinct, No-Fallback Route

**Date:** 2026-08-08

**Status:** Active.

**Context.** SwiftMail's public move API may implement MOVE as COPY plus source-flag mutation and
expunge when the server does not support RFC 6851. That compatibility behavior is useful to a
general client, but it cannot sit behind TabMail's atomic route: a timeout or partial server failure
after an irreversible step makes an automatic retry capable of duplicating or deleting mail. At the
same time, servers that advertise `MOVE` can perform one atomic UID command and avoid the app's
owned COPY/STORE/UID-EXPUNGE sequence. `UIDPLUS` affects the availability of `COPYUID` evidence;
it is not a prerequisite for `UID MOVE`.

**Decision.**

1. The SwiftMail fork exposes `moveAtomically(messages:to:)`. It requires the advertised `MOVE`
   capability, emits exactly one `UID MOVE`, and has no COPY/STORE/EXPUNGE fallback. Tagged NO/BAD,
   timeout and cancellation are returned to the app; tagged OK with absent or malformed `COPYUID`
   is successful completion without destination evidence.
2. TabMail snapshots `supportsMove` after connection establishment and chooses one route. `MOVE`
   takes the atomic-only API; no `MOVE` takes the pre-existing owned sequence. Once an atomic command
   is attempted, an error never falls through to the owned route because RFC 6851 permits partial
   completion and the app cannot prove the safe subset to replay.
3. IMAP source mailbox selection, admitted UIDVALIDITY, cancellation and legacy deleted-flag cleanup
   are reasserted immediately before the irreversible command. No path emits bare mailbox-wide
   `EXPUNGE`.
4. `COPYUID` is optional destination-address evidence. Only one-to-one, cardinality-aligned source
   and destination UID sets may re-key local rows. A positive destination UIDVALIDITY disagreement
   refuses the re-key. Missing or malformed evidence is success without a destination address, never
   permission to guess or replay.
5. Local finish classifies each old header as applied, unsafe-for-undo, or removed. Exact optimistic
   rows alone may re-key; a wrong/non-optimistic survivor is left untouched but loses stale undo
   authority. Applied rekeys update Undo, FTS and body assets; removed rows delete their mirrors;
   every unsafe/unaddressed member is pruned from Undo.
6. A retry after ambiguous atomic completion converges for a conforming server because completed
   source UIDs are absent and are not reused within the admitted epoch. The registered residual is a
   non-conforming or standards-permitted partial failure that leaves a member in both mailboxes; the
   client does not invent recovery evidence for that case.

**Rationale.** Atomicity is a wire property, not a name for a convenience API. Separating the API
makes a hidden fallback structurally impossible. Separating provider success from destination-address
evidence also preserves the never-drop rule without turning missing `COPYUID` into guessed identity.

**Consequences.**

- Servers with `MOVE` avoid the app-induced COPY-before-delete duplicate window; servers without it
  retain the audited owned sequence.
- A server that advertises but permanently rejects MOVE can park the lane until its configuration is
  corrected. Falling back after the rejected command would be less safe than the visible refusal.
- Atomic success without safe `COPYUID` can leave an optimistic row unaddressed and recoverable by
  ordinary sync; stale undo authority is removed immediately.
- `supportsMove`, the atomic-only entry point, and both handlers' tagged-OK malformed-COPYUID behavior
  are fork-local deviations that must survive every upstream sync.
- The repository owner is the actor for any upstream SwiftMail PR. This task records the deviation
  but does not open an upstream PR.

**Tests / evidence.** SwiftMail commits `8da5d45a` and `4a409fe8`; app commits `dd51c74ff` and
`4f1a756fb`. Fork: 417 tests and strict SwiftLint green. App: atomic wire, provider route, local
finish, undo/mirror and queue tests; post-fix full suite 8,794 total, 8,793 passed, zero failures and
one registered expected failure. Self-audit commits `495554bff` and `4bdc5b330` are the two
consecutive clean rounds.

**Relates:** ADR-IOS-068 (native provider address), ADR-IOS-069 (address-space reset exit),
ADR-IOS-072 (content ownership), RFC 6851, IOS-IMAP-001/003/006, IOS-QUEUE-004.
