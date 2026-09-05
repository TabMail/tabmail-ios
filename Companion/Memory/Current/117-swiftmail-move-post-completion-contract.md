<!-- COMPANION-CURRENT-NOTE-BEGIN -->
> **Current routing note (2026-09-04, GitHub #115): the first and third bullets below are HALF
> wrong and are corrected here; the body is preserved unedited.** Only
> `.moveFailedAfterPartialCompletion(copyUID:reason:)` is non-retryable — it carries positive
> `COPYUID` evidence, and TabMail still retires on it and reconciles both folders.
> `.moveFailedAfterPossiblePartialCompletion` is raised for ANY tagged NO/BAD with no retained
> `COPYUID`, including a refusal answered before any mutation (a transport loss between the pre-move
> `SELECT` and the `UID MOVE` makes `IMAPConnection.executeCommandBody` re-open a raw channel with no
> LOGIN/SELECT, and the server answers `NO No mailbox selected`). Treating it as non-retryable dropped
> the user's move (`3f6a0a5a8`; `MIS-IOS-004` recurrence). #115 deletes that arm: the error is a
> typed, retryable failure (`IOS-IMAP-013`), the op stays queued, and the next drain reissues
> `UID MOVE` — safe because RFC 3501 §6.4.8 ignores absent UIDs and §2.3.1.1 forbids UID reuse within
> an epoch; the residual duplicate on a server that violates RFC 6851 §3.3 is accepted under
> `IOS-IMAP-006` / `IOS-QUEUE-007`.
>
> **2026-09-05 (#115 round 3) — where the refusal now goes, because "deletes that arm" was only half
> the answer.** With the arm merely deleted, `moveFailedAfterPossiblePartialCompletion` fell into the
> atomic route's PRE-EXISTING generic catch, and that catch does two things neither #115 nor this
> note intended. (1) It runs `mailboxConfirmedAbsent` — an exact-name `LIST` — and retires the WHOLE
> operation as `IMAPActionMailboxAbsent` when the name is not returned. A LIST omission is not
> evidence of absence: RFC 4314 §4 makes `l` (LIST visibility) independent of `i` (insert/COPY, which
> is what a MOVE target needs), and RFC 9051 §6.3.9 lets a server silently ignore a valid pattern
> under a tagged OK — so the zero-mutation refusal could still empty the queue. (2) When LIST DOES
> list the destination, the raw `IMAPError` escapes the provider, matches no typed arm in
> `AccountManager.executeSingleOp`, and reaches the drain's generic catch, which inserts the account
> into `DrainContext.failedAccounts` — account-wide suppression reserved for facts about the
> CONNECTION. A server that keeps refusing MOVE (`ADR-IOS-073` accepts that one may) then starved
> every disjoint lane on the account, every drain.
>
> **The routing, current:** one typed arm in `IMAPProvider.move`'s atomic route, BEFORE the generic
> catch, rethrows the error as the private `IMAPAtomicMoveRefused` — a `ProviderEvidenceUnavailable`
> alongside `IMAPLivenessProbeInconclusive` / `IMAPDestinationEpochRefusal` /
> `IMAPEpochEvidenceMissing`, carrying the server's reason text as a diagnostic payload. It therefore
> never reaches the LIST probe, and it lands in the drain's LANE-LOCAL arm (requeue,
> `retryCount += 1`, `evidenceRefused`, `.haltLane`, account untouched). `AccountManager.isMessageNotFoundError`
> exempts the whole PROTOCOL structurally (`if error is ProviderEvidenceUnavailable { return false }`)
> rather than one SwiftMail case, and `AccountManagerQueue.swift` no longer imports SwiftMail.
> `mailboxConfirmedAbsent`, the generic catch, `IMAPActionMailboxAbsent`, the action-SELECT LIST probe
> and the COPY-route destination probe are pre-existing and unchanged; the same LIST-omission argument
> applies to them and is recorded for the owner. Registered in
> `Companion/Process/Current/KnownIssues/Amendments/ios-imap-013.md`.
>
> **2026-09-05 (#115 round 3b) — THE RENDERED-REASON CONTRACT, because the provider now PARSES that
> payload.** `MoveHandler.handleTaggedErrorResponse` builds the payload of BOTH move failure cases as
> `let reason = String(describing: response.state)`. `response.state` is
> `NIOIMAPCore.TaggedResponse.State`, an enum whose `ok` / `no` / `bad` cases each carry a
> `ResponseText`; `ResponseText` conforms to `CustomDebugStringConvertible` and its
> `debugDescription` re-encodes the WIRE form, writing `"[" <code> "] "` before the human text
> whenever `code != nil`. So the reason string TabMail receives is
> `no([TRYCREATE] UID MOVE destination does not exist)` — enum-case wrapper, then the RFC 3501 §7.1
> `resp-text` verbatim. VERIFIED EMPIRICALLY against `FakeIMAPServer` before the parser was written,
> not inferred from the types.
>
> `IMAPProvider.leadingResponseCode(inRenderedReason:)` is anchored on exactly that shape: it strips
> one optional `no(` / `bad(` / `ok(` wrapper with its matching trailing `)`, and reads the
> bracketed atom ONLY when it is the first thing in the remainder. Everything else returns nil. That
> is deliberate — a response code is a protocol statement only in the LEADING position, so
> `no(Move refused, see [TRYCREATE] semantics)` must not, and does not, parse.
>
> ⚠ **THIS DEPENDS ON A `String(describing:)` RENDERING, WHICH IS NOT AN API CONTRACT.** An upstream
> change to `TaggedResponse.State`'s case names, or a `CustomStringConvertible` conformance added to
> `ResponseText` that differs from its `debugDescription`, would silently change the payload and the
> extractor would return nil — failing CLOSED (every refusal parks its lane again, the round-3
> disposition) rather than open, which is why this is acceptable rather than a defect waiting to
> happen. The better home is a STRUCTURAL carrier in the pinned SwiftMail fork — the `ResponseText`'s
> `code` surfaced on the `IMAPError` case itself instead of flattened into a string — and that is a
> FOLLOW-UP, not done here. It is pinned meanwhile by
> `IMAPMoveWireContractTests.leadingResponseCodeIsReadStructurally` and by the end-to-end
> `NeverDropExitClosureTests` cases, so an upstream rendering change fails a test rather than
> changing behaviour silently. Registered in
> `Companion/Process/Current/KnownIssues/Amendments/ios-imap-013.md`.
<!-- COMPANION-CURRENT-NOTE-END -->
# SwiftMail MOVE post-completion contract — PR #208

- `IMAPError.moveFailedAfterPossiblePartialCompletion` and
  `.moveFailedAfterPartialCompletion(copyUID:reason:)` are **non-retryable**: mailbox state may
  already have changed before tagged NO/BAD.
- The verified form's `CopyUID` is attempt-correlated destination evidence and should be preserved.
- TabMail retires the original source identifiers for both forms and reconciles both source and
  destination folders. Reissuing UID MOVE can duplicate mail or address a later source-UID occupant.
- `IMAPError.moveFallbackFailedAfterCopy` is not reachable from TabMail's atomic route because it
  always calls `move(..., fallback: .disabled)`; do not conflate it with the two cases above if that
  routing changes.
- Collision proof for the 2026-08-13 fork sync: pinned integration tree `7aee922` is byte-identical
  to merged PR #208 at `e77744c`. Upstream `f8469b1` adds ordered repeated selective-header fields
  while retaining the legacy last-value-wins dictionary; TabMail does not consume the new property.
- Sync completed 2026-08-13: `TabMail/SwiftMail` `main`, local `origin/main`, and `upstream/main` all
  resolve to `f8469b14f7620ef7b1105eccbfa19271448819d5`; `project.yml` pins that exact revision.
  SwiftMail verification: build passed, 479 tests / 62 suites passed, strict lint 0 violations / 293
  files. iOS app + embedded NSE build passed with the two sanctioned AppIntents warnings, followed by
  120 re-pinned integration tests / 7 suites.
- Duplicate linked worktrees `tabmail-ios-SwiftMailFocused` and
  `tabmail-ios-SwiftMailReleaseTests` were clean and removed. Their branch refs remain; safety branch
  `tabmail/pre-sync-20260813` retains integration commit `7aee922`.
