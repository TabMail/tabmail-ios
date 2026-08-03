
## ADR-IOS-066 — Content is addressed by the message it belongs to, never by the slot it occupies

**2026-07-27. Accepted. Landed `486bafd`. Found by the per-unit audit train (unit U4).**

### Context
`headerId` is `accountId:folderPath:UID` — a **mutable address**. When a UIDVALIDITY reset makes a
mailbox reuse a UID, that address silently comes to mean a different message. Two subsystems keyed
user content by it with no identity check at all, and both were reachable in production:

- The FTS **header** index was `INSERT OR IGNORE` + skip-if-present, so a purge racing a parked
  index write reinserted the old-epoch record and the resync could never overwrite it. **Search
  returned the new message carrying the old message's subject and sender, permanently.**
- The attachment cache was keyed by `(headerId, section)` with no verification, so a pre-reset
  attachment was served for whatever message later occupied that UID — **the old message's bytes
  under the new message's filename.**

Neither was visible to a fully green 8,600-test suite.

### Decision
Content identity binds to **the message, not the address**, and for anything the user is looking at
it binds to **the message being displayed** — not to whatever currently occupies that address in the
database. The UI deliberately keeps showing a message after an RFC mismatch, so binding to the
current occupant serves the replacement's content under the original's metadata.

One shared seam (`DisplayedAttachmentIdentity`) resolves it; every consumer routes through it —
top-level attachments, nested `.eml`, and calendar ICS. **No consumer re-derives identity locally.**

### Consequences, including the ones that cost us
Five fix rounds were needed, and four of them shipped a regression that had to be removed. Each was
the **mirror image** of the defect being fixed, and the pattern is the lesson:

| intended | produced |
|---|---|
| stop a stale row shadowing a message | **destroyed** every pre-upgrade FTS body — a rule meant for READS applied to a destructive WRITE |
| stop deleting a blob another writer published | **pinned** blobs forever — an ownership lease with no reaper |
| let rfc-less messages fail closed | made their attachments **permanently unopenable** |

Standing rules that came out of it:
1. **"Identity unknown" justifies a re-fetch, never a delete.** Only a POSITIVE mismatch may clear
   content (`.preserveAndAdopt` keeps a legacy row's body and adopts identity lazily).
2. **The token is captured when the fetch begins**, never re-read at write time — otherwise the
   write blesses its own stale bytes and the read-side check agrees with it.
3. **The check must be atomic with the action it guards.** "A check before an await is not a check"
   caused three separate defects here.
4. **Kind matters.** Inline images are `cid:` content-addressed and self-healing, so they stay
   legacy-tolerant; attachments are keyed by a mutable address, so a legacy token is a strict miss.
5. Orphan reclamation is **by age**, reusing `sweepMinAgeSeconds` — the mechanism the shipped
   release already had. Restoring it beat inventing a fourth one (rule 2c).

**Accepted residual:** in a folder that has ever had a UIDVALIDITY reset, rfc-less attachments stay
unopenable. `MessageHeader` carries no epoch and a retained view holds a stale snapshot, so a
resolve-time epoch read would match both occupants and serve the wrong bytes. The sound fix is to
persist the observation epoch on the header row; that needs its own migration.

**Relates:** ADR-IOS-061 (epoch boundary), ADR-IOS-042 (UID is an address, not an identity).

---
