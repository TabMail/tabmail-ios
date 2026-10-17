## ADR-IOS-091: Drafts Written by Other Mail Apps Are Adopted on Open

**Status:** Active (2026-10-17, GitHub #217)

**Context:** `e0d3d30e` (v1.7.0) bound every draft mutation to an exact provider-native address
and SUBTRACTED "unverified server-origin reopen": the pre-v1.7 open matched local rows by Message-ID
and subject, deleted the server copy at Send by Message-ID search, opened an empty editor when the
body fetch failed, and left the other app's copy behind as a duplicate on save. Removing it made
every draft started in Gmail web, Apple Mail or Outlook unopenable ("Draft unavailable"). Owner,
2026-10-17: take over the draft whichever client wrote it; if two apps edit it at the same time,
the last save wins — no lock, no warning, "simple is king".

**Decision:** When `ServerDraftComposeLoader` finds no local owner for a Drafts header, it adopts
the server copy (`ExternalDraftAdoption`): body and top-level attachments are fetched, then one
write transaction re-verifies the header and its exact address, refuses if any `Draft` row already
owns that address, and inserts an ordinary `Draft` row (`adopted:<uuid>`, status `"pushed"`)
carrying the address the existing save/send/delete paths use (IMAP folder + UIDVALIDITY + UID,
Gmail draft resource id, Graph id). The normal resolver then opens it. The reply parent comes from
`In-Reply-To` (exactly one header in the account, stamp-provable at reopen) or the draft is
unthreaded; adopted drafts get no TabMail quote.

**Rationale:** Adoption reuses the v1.7 machinery instead of re-opening its hazards: the row is
the same shape a locally authored draft has after its first push, so save replaces and Send deletes
exactly the adopted copy, and nothing ever selects a mutation target by Message-ID (ADR-IOS-068 D4).
The v2final Outlook open lease is not ported (owner ruling). An unproven IMAP epoch, a placeholder
id, a changed header, an unconfirmed-empty body or a failed attachment fetch still fail closed.

**Consequences:**
- Drafts from any client open and edit; the first save replaces the other app's copy.
- Concurrent edits in two apps: last save wins. A later in-place edit elsewhere (Gmail/Graph keep
  their ids) is not shown on reopen — `IOS-DRAFT-020`, open for the owner.
- An evicted but pushed local draft is re-adopted from its server copy when reopened.
- Inline images in another app's HTML draft become plain-text body only (the compose is plain
  text); top-level attachments are carried.
