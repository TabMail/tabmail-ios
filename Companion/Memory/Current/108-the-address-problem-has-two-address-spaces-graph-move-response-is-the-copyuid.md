# THE ADDRESS PROBLEM has TWO address spaces — Graph's `/move` response IS the `COPYUID`

**Status:** Current. Landed 2026-08-04 with the `IOS-GRAPH-002` fix.
**Related:** `CLAUDE.md` § THE ADDRESS PROBLEM · ADR-IOS-068 · `KNOWN_ISSUES.md` `IOS-GRAPH-002`,
`IOS-GRAPH-003`, `IOS-QUEUE-008` · `MISTAKES.md` `MIS-IOS-003` (instance 5), `MIS-006` (instance 5),
`MIS-IOS-004` · commit `59423bb7d` (the IMAP half).

---

## The one-sentence version

`59423bb7d` — *"Finish the IMAP move locally using the `COPYUID` already in hand"* — fixed **one
coordinate system**. Microsoft Graph is a **second** address space in which the same sentence was
true verbatim: `POST /messages/{id}/move` answers with the moved message **carrying its new `id`**,
and `ExchangeProvider.moveMessage` bound that response to `_`.

## Why the first census missed it

The census that produced `59423bb7d` enumerated **the mechanism** — every site that touched
`COPYUID` — rather than **the property**: *the server told us the new address and we discarded it*.
`COPYUID` is an IMAP wire keyword, so a `COPYUID` census can only ever find IMAP call sites. Graph's
equivalent is not called `COPYUID`, is not a wire keyword, and is not even an explicit response
field the code had a name for — it is just `id` on the returned resource. Recorded as `MIS-006`
instance 5: *fixed the instance, not the class*.

**The generalised check, which is what to run next time:** enumerate by the PROPERTY
("which provider operations RETURN the mutated resource, and what do we do with the return?"), then
intersect with the provider list. There are three mail providers, so a class fix has three arms and
each one needs a written disposition — **including the arms left alone**.

## The three arms and why they differ

| Arm | Does a move change the address? | Disposition |
|---|---|---|
| **IMAP** | Yes — `(folder, UID, UIDVALIDITY)`; the new UID arrives in `COPYUID` | Fixed by `59423bb7d`. Fails **CLOSED** on top of that: `admittedOrdinaryActionTargets`' IMAP arm refuses a row whose `observedUidValidity` the optimistic move nil'd, so a dead address never reaches the wire even when the re-key is missing |
| **Exchange / Graph** | Yes — the resource `id` is reallocated on the default mutable-id scheme; the new one arrives on the `/move` response body | **Was the defect.** Fixed by `IOS-GRAPH-002`. Fails **OPEN**: the non-IMAP admission arm is `messages.filter { !$0.messageId.isEmpty }` with a `nil` epoch, so it happily admits a dead id |
| **Gmail** | **No** — `messages.modify` adds/removes a label; the resource id is stable across "folder" changes | **Genuinely exempt, not merely unfixed.** A Gmail 404 really does mean gone, so exit 2 is sound there |

**The trap this table exists to prevent:** *a guard that makes a bug benign in one arm is not a
guard the other arm has*. IMAP's fail-closed admission gate made the identical root cause invisible
on IMAP, which is exactly why the Graph half survived a fix that named the root cause correctly.

## The shape of the fix, and the two shapes NOT to reach for

The fix is **stop discarding the address**, not **reclassify the failure**:

- `ExchangeProvider.moveMessage` decodes the response's `id` and returns it.
- `moveProvingDestinations(ids:from:to:) -> MoveOutcome` carries it per member, mirroring
  `IMAPProvider.move(ids:from:to:admittedUidValidity:)`.
- `executeOperation`'s `.move` case grows the sibling `provider as? ExchangeProvider` arm beside the
  existing `as? IMAPProvider` one, so `ExecutedOperation.provenDestinations` is populated.
- `MessageHeaderRekey.finishMove` is **reused**, not duplicated. `ProvenDestinationAddress` became
  provider-neutral for this: `sourceProviderId` / `destinationProviderId` as `String`, and
  `destinationUidValidity` optional.

**MIRROR-IMAGE TRAP 1 — reclassifying the 404 as retryable without re-keying is a LANE WEDGE.**
`buildLanes` keys on `accountId:folderPath:messageId`, so an op that names a dead id would fail
identically forever and starve every later op sharing its lane. The wedge corollary says a starved
op has not been preserved, so that "fix" trades one never-drop violation for another. **The re-key
is what makes retry TERMINATE** — that is the entire reason the fix is the re-key.

**MIRROR-IMAGE TRAP 2 — `Prefer: IdType="ImmutableId"` is not a free win.** It changes id format
**account-wide**, invalidating every value already minted under the mutable scheme:
`MessageHeader.messageId` and every `MessageIdentity.headerId` built from it,
`PendingOperation.messageIds`, `MessageIdentity.aiCacheKey`, `nse_processed_message.id`,
`MessageContentStore` content keys, and Graph `Folder.path` — plus the NSE's **separate**
`Shared/API/GraphAPI` client, which would have to send the identical header or the two halves of the
app would disagree about what a message id is. A one-way per-account migration plus a full re-sync.
And Microsoft still documents the immutable id as changing on a move to an archive mailbox or an
export/re-import, so it narrows the churn without abolishing it. Evaluate on TOP of the re-key,
never instead of it.

## The fail direction: NIL is both the true value and the safe one

`finishMove`'s G2 stamps `observedUidValidity` only when the proven epoch **equals** the folder's;
otherwise `nil`. A provider with **no epoch space at all** reports `nil` and takes the same arm —
and for the same reason. A nil stamp is `.retainedForRetry` (recoverable); a *positive
disagreement* is `.terminalStale`, the only terminal arm. So inventing an epoch for a Graph row
would be a positive disagreement with the folder's own `nil` and would terminally drop the **next**
gesture — the mirror image of the bug being fixed.

## Withheld evidence is not a fallback

When Graph accepts the move but its response names no id, `moveProvingDestinations` returns that
member in `provenIds` with **no entry** in `provenDestinations` — byte-for-byte the shape the IMAP
arm takes when the server returns no `COPYUID`. The row keeps its old address and stays recoverable.
Nothing is substituted, guessed, or defaulted; this is an absence of evidence, which is not a
fallback (repo rule 4).

## A partial batch must return its proven prefix

Each Graph move is its own request, so a two-member batch can land one and fail the next. Throwing
the whole attempt away would discard the destination address the wire had **already** supplied for
the first member — re-creating this exact defect one mid-batch failure later, and not recoverably.
`moveProvingDestinations` therefore returns the proven prefix, which routes through the existing
`retirePartiallyCompletedOp` contract (which already calls `finishMove`). It rethrows only when
nothing at all was proven, so whole-batch failures keep their previous classification, and it
rethrows `CancellationError` unconditionally — a cancelled Task has proved nothing about the members
it never reached.

**Consequence for a later reader of `executeOperation`:** the note that used to say *"no provider
currently returns a strict subset of the requested members"* is now FALSE.
`ExchangeProvider.moveProvingDestinations` is one, and `retirePartiallyCompletedOp` is no longer a
producerless path.

## A1 / RULE R0 finding — the previous release is INAPPLICABLE here, not nonexistent

Recorded because a later reader will otherwise re-propose the banned mechanism:

- **`v2final` `e28dd4edb`** has the identical discard —
  `_ = try await requestPreservingBadRequestBody(...)` — and avoids only the *consequence*, by
  re-resolving the message through `resolveActionMessageIds`, an RFC 822 `internetMessageId`
  `$filter` search. **That mechanism is banned in v3** (ADR-IOS-068 / D4; registered as
  `IOS-IMAP-002`): an RFC Message-ID may never be mutation authority and a SEARCH result may never
  be a mutation target — it returns every copy sharing the Message-ID and mutates all of them.
- **Shipped `07a4bb703`** is `let _ = try await request(path: "/messages/\(id)/move", ...)` — it
  **shares the defect byte-for-byte**, and its `stableId` returns the Graph id for Exchange, so the
  churned id is enqueued there too. A floor, not a ceiling; there was nothing to restore.

So A1 step 3 applies as **INAPPLICABLE** (the release *had* an answer and v3 outlawed it), not
**nonexistent**. Authoring was correct here, and saying *which* is what stops the next reader from
"restoring" a banned search.
