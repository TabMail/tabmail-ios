## ADR-IOS-080: Body Indexing Is Bounded, Payload-Selective, and Truthfully Terminal

**Date:** 2026-08-31

**Status:** Active.

**Context.** An IMAP message part can be larger than SwiftMail's ordinary response parser limit.
Fetching the complete part therefore fails deterministically with `PayloadTooLargeError`; reducing
the number of messages in a batch cannot split that one literal. Affected rows have complete
headers but bodies that are neither indexed nor confirmed empty, so body queues stop making progress
while Fast Sync continues to count the rows as pending forever.
Increasing the response limit merely moves the failure threshold and raises memory use. Marking the
rows empty or complete would lie about server content that was never fetched.

**Decision.**

1. **IMAP MIME parts are fetched with validated partial `BODY.PEEK` ranges.** The SwiftMail fork
   exposes `fetchPart(section:of:offset:count:)`, encodes
   `BODY.PEEK[section]<offset.count>`, and accepts bytes only from the requested message identity,
   exact section kind and origin. It rejects ignored/malformed ranges, impossible lengths, extra
   body literals and responses larger than the requested count while draining the wire safely.
2. **The app fetches required parts in one-MiB chunks.** Transfer-encoded bytes are concatenated
   before base64 or quoted-printable decoding, because encoded units can straddle a chunk boundary.
   A BODYSTRUCTURE size is a planning hint, not truncation authority: after reaching it, the app
   probes one byte at the advertised endpoint and accepts completion only when the server returns
   an empty range. Where size is unavailable, a short nonempty response is not treated as EOF and
   fetching continues until an empty range. The server-reported size does not trigger a full-size
   allocation before bytes arrive.
3. **Background body indexing downloads only render ingredients.**
   `IMAPFetchMapping.isRequiredBodyPart` selects visible `text/plain` and `text/html`, calendar
   content, and non-attachment CID images. BODYSTRUCTURE metadata is sufficient for normal
   attachments and opaque `.eml` payloads. Flattened descendants of an attached `message/rfc822`
   part are excluded component-wise as attachment payload too. Attachment bytes are fetched on
   demand through the same bounded path. Attached HTML is metadata, not a display body.
4. **The ordinary four-MiB response parser limit and NSE memory limit stay unchanged.** The bounded
   transport is the fix; there is no larger-buffer fallback. The NSE uses the same payload selection
   and chunking, never downloads ordinary attachment payloads, and declines active body rendering
   before fetching when required BODYSTRUCTURE sizes are unknown or exceed its aggregate admission
   budget.
5. **A server that cannot honor partial ranges creates an explicit terminal-unindexed state.**
   `MessageHeader.bodyIndexingFailureReason = "partial_fetch_unsupported"` means the row is neither
   indexed nor empty, but is no longer runnable by automatic body queues. Only deterministic partial
   protocol/assembly failures take this path; transient connection and database failures remain
   retryable. The write is guarded by the row's full provider address plus positive identity proof
   from the failed fetch: its exact SELECT UIDVALIDITY epoch must match the stored row whenever both
   epochs exist; only when epoch evidence is unavailable may a matching fetched RFC 5322 Message-ID
   serve as fallback proof. A move, re-key, or reused UID therefore cannot attach the outcome to
   another message, and a duplicate Message-ID cannot override an explicit epoch contradiction.
6. **Completion reports runnable work and truthful omissions separately.** `pendingBodyCount`
   excludes terminal-unindexed rows; `unindexedBodyCount` reports them. Once the header walk and all
   runnable body work finish, the UI says `Sync complete with N messages not indexed` and displays a
   completed progress bar instead of holding indexing active forever. Smart Reindex clears terminal
   reasons so a later app or server upgrade can try again.

**Rationale.** A finite chunk bound closes the arbitrary-size-literal class without weakening the
parser's memory boundary. Payload selection avoids paying attachment memory and network cost during
background indexing. The terminal state separates three facts that must never be conflated:
indexed content, confirmed-empty content, and content that exists but cannot be indexed with the
server's current protocol behaviour.

**Consequences.**

- Large text/calendar/CID parts can be reconstructed beyond 32 MiB while every response literal
  stays below the ordinary parser limit.
- Background indexing uses more IMAP commands for large required parts, in exchange for bounded
  memory and deterministic progress.
- Normal attachment payloads are absent from background `MessagePart` values and are downloaded
  only when requested through the same chunked path. BODYSTRUCTURE still supplies their filename,
  MIME type, section and size; `.eml` attachments are parsed for preview only after that tap-time
  download.
- A non-compliant server may leave messages unindexed, but the state is visible, terminal, and
  retryable by explicit Smart Reindex rather than silently empty, falsely complete, or infinite.

**Tests / evidence.** SwiftMail wire tests reconstruct a body larger than 32 MiB under a four-MiB
parser buffer and cover ignored/malformed ranges, wrong identity/section/origin, oversized and
duplicate literals, UID ordering, and unsolicited FETCH updates. iOS tests cover encoded-boundary
assembly, understated and unknown BODYSTRUCTURE sizes, payload selection on the provider's wire hot
path, on-demand `.eml` fetching, NSE admission/state transitions, identity-safe terminal writes,
queue convergence, migration/default state, queue exclusion, Smart Reindex recovery, and exact
completion wording.

**Relates:** ADR-IOS-050 (`bodyComplete` is FTS truth), ADR-IOS-072 (content ownership),
ADR-IOS-075 (acknowledge only committed cache state), bounded-memory absolute.
