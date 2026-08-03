
## ADR-IOS-059: A Folder Role Is Never Identity — Undo Resolves by a Recorded Tuple and Drops on Any Mismatch

> **Superseded by ADR-IOS-060 (2026-07-13).** The general lesson that mutable attributes are not identity remains valid. The recorded-destination resolver, token ledger, provider receipt identities, alias advancement, full-row restoration, and mismatch adjudication are rejected. Undo no longer resolves a historical row or owns a second recovery protocol; it issues an ordinary inverse command through the global queue.

**Status:** Accepted (2026-07-12) — supersedes the undo-resolution machinery accreted in ADR-IOS-058's audit rounds 23-50.

### Context

Undo had to answer one question — *which durable row does this undo entry restore?* — under two facts:

- **IMAP re-keys rows.** `messageHeader.id` is `accountId:folderPath:messageId`, and on IMAP `messageId` is the UID, which a MOVE changes. Sync deletes the stale row and re-inserts it under a new id. So the composite id is a birth certificate, not an address, and it goes stale the moment our own move syncs.
- **Folder metadata drifts.** Settings can retag any folder's role (`AccountDetailView.assignRole` is a raw `UPDATE folder SET role`), sync re-derives roles, drops folders that vanish remotely, and renames change a folder's path.

The implementation answered it by **scoping a probe by folder role** — "find the row with this rfc822 id, in this account's archive-role folder" — and then spent ~30 commits patching the consequences: the probe was re-scoped four times (each adding one more qualifier), the captured-vs-live role precedence was reversed three times, and a "last-resort" probe was reinstated and then deleted again after it was shown to resurrect deliberately-deleted mail. `AccountManagerActions.swift` grew from 1,239 to 2,269 lines.

Every one of those bugs was real. None of them was the bug. **The bug was using a mutable, per-account, user-editable attribute as part of an identity key.** Role can be reassigned between the gesture and the undo; a key that can be edited by the user is not a key. This is the same error ADR-IOS-042 forbids for sync (window by UID, never by the mutable `date`) and the same one the MOVE-changes-UIDs rule forbids for message identity.

### Decision

**An undo entry records, at gesture time, what it did. At undo time, it resolves only what it recorded. Role is never read at undo time — not for probes, not for scoping, not for guards, not for tie-breaks.**

Concretely, the undo entry carries, per account, the folder the gesture moved that account's messages into (`UndoableAction.destinationPathByAccount`). Gesture sites seed the intended paths synchronously; `AccountManagerActions.move` overwrites them after its GRDB transaction with the paths the write actually used. A token-keyed `UndoService` ledger survives the action being popped until the undo journal receipt completes, so a move finishing in the pop→undo-fold window cannot lose its actual destination. Resolution is then one lookup and one comparison, per member:

```
identityKey := rfc822MessageId            (providers whose ids re-key: IMAP/iCloud)
            := messageId                  (provider whose ids are stable: Gmail)
            := receipt-proven id component (Outlook Graph default REST ids re-key)
            := NONE                       (re-keying provider, no Message-ID header)

row := the single row with (accountId, identityKey) whose folderId == the RECORDED destination folder

  exactly one such row  -> RESTORE it (location + user state from the snapshot),
                           move-back sources from the recorded destination
  anything else         -> DROP the member and report it refused
```

"Anything else" is every case the deleted machinery tried to adjudicate, and it needs no adjudication:

- **The row moved on** (another client re-filed or deleted it, a later gesture superseded it): its `folderId` is not the recorded destination, so it is not ours any more. Drop. This single comparison replaces the SUPERSEDED guard, the UNKNOWN-LOCATION guards, the opposite-role probe, and the sent/drafts exclusion lists — and it cannot resurrect deliberately-deleted mail, because a row in Trash is by definition not at our recorded destination.
- **The row is gone** (hard-deleted): zero candidates. Drop. We never fabricate a row we cannot identify; the old upsert-under-old-id path did exactly that and produced phantom duplicates.
- **The member has no identity** (IMAP message with no `Message-ID` header — a SHOULD, not a MUST, in RFC 5322): no key exists, so nothing can honestly be resolved. Drop.
- **Ambiguity** (the same rfc822 id in several folders — a self-sent message's Inbox and Sent copies): only the row *at the recorded destination* is ours. The Sent sibling is excluded because its folder is not the destination, not because we reasoned about its role.

A re-keyed row is found because the identity key survives a re-key; that is the entire point of keying on it. The undo restores it **in place, under its new id**, and re-posts `.messagesUndone` with the id it actually lives under.

**Audit amendment (2026-07-12, round 52).** Five details are part of this decision, not optional fallbacks:

1. **Choose the key from the provider first.** Gmail resolves by its stable `messageId`, even when the snapshot also has an RFC Message-ID. Outlook resolves only through the exact provider-id component proved by Graph MOVE receipts; it never falls back to RFC identity. RFC-first resolution can select a different same-RFC copy sitting at the destination. IMAP/iCloud use RFC Message-ID because their UIDs re-key and provide no replacement UID receipt.
2. **The committed destination receipt outlives stack membership.** A value-type action is popped before the original move's asynchronous post-commit stamp can run. Phase 1 reads the token ledger immediately before resolution; successful execution-time stamps override gesture-time provisional paths. The ledger entry is removed only after `IntentionJournal.awaitCompletion` for the undo record (or when an unpopped action is evicted/dismissed).
3. **A re-key is carried forward by the exact restored row.** `undoDestructiveAction` returns `[snapshotId: restored MessageHeader]` from the same unique-row transaction. `executeFold` refreshes by each row's actual current id, then indexes it under the old fold id for later co-bundled field/move intentions. The read-error fallback uses that exact returned row too. It never performs a broad RFC fallback, and refused members produce no alias.
4. **Resolution is bijective, not merely unique on the database side.** Exactly one destination row may match one snapshot, and exactly one snapshot in the undo group may carry that immutable key. If two snapshots share one provider identity, every such member is refused even when only one destination row survives; otherwise both snapshots can claim the same row and restore it twice with order-dependent user state.
5. **Every historical alias observes the latest restored state.** Successive IMAP moves can make several old fold ids name one current row. `executeFold` therefore tracks old-id → actual-id separately from the latest restored header per actual id. If refresh fails after multiple undos in one component, all aliases resolve to the row's final serially-restored state, never an intermediate Archive/Trash snapshot that can incorrectly gate a later field or move intention.

**Audit amendment (2026-07-13, round 53).** Microsoft Graph's default REST message id changes on MOVE. Each exact receipt advances the token ledger's provider-id component before the matching GRDB re-key, and the undo resolver snapshots that ledger from inside its serialized write. A cycle or collision between previously distinct components marks that token/account's alias history explicitly invalid; the resolver refuses every member in that account. An empty alias map is not a corruption marker and must never trigger fallback to the captured old id after contradictory receipt evidence.

### Consequences

**Deleted:** `resolveRoleScopedRekeyedRow`, `resolveRelocatedRow`, `scopedRole`, `capturedDestructiveRole`, `effectiveRole`, `UndoableAction.destinationRole` (and its payload field), `supersedingRoles`, `destinationFallback`, the SUPERSEDED / UNKNOWN-LOCATION / UNKNOWN-LOCATION-rekeyed / REKEY+SUPERSEDE guards, the per-member exclusion sets, the representative-account path borrowing, the upsert-under-old-id restore, and the bespoke unread delta arithmetic (the undo now recomputes each touched folder's count from truth inside the same transaction, so there is no delta to get wrong and no exclusion set to keep in sync).

**Behaviour we deliberately gave up** — each is now a drop, and each was previously a guess:

1. A message another client re-filed to a custom folder is no longer dragged back. It is not where we put it; the last actor to touch it was not us.
2. A hard-deleted row is no longer re-fabricated from the snapshot.
3. A folder renamed between gesture and undo makes the recorded destination stop matching (`Folder.id` is path-derived), so those members drop. Refusing is honest; guessing is what produced the bugs.

In all three the user sees the undo decline to act rather than silently do the wrong thing, and the refused ids drive a corrective reload so the UI never shows a row that does not exist.

**Follow-up (not done here):** `Folder.id = "\(accountId):\(path)"` makes a folder's identity path-derived, which is the same class of error one level down — a rename is indistinguishable from a different folder. Giving `Folder` a server-derived stable id would let a rename survive an undo. Recorded as a known limitation; not required by this ADR.

### The rule this generalises

> **Identity keys must be immutable. If an attribute can be edited, re-derived, or reassigned — a role, a path, a date, a UID — it is a display attribute, not a key. Never scope a lookup by one.**

If a future change finds itself adding *one more qualifier* to an undo lookup to make a case pass, that is this ADR's failure mode. Stop and re-read it.

---
