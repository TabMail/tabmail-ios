## ADR-IOS-084: Gmail Display Date Is the Top `Received:` Timestamp; `providerDate` Keeps the Provider's Order Key

**Status:** Active (2026-09-16)

**Context:** The inbox sorts and groups by `MessageHeader.date`, which every
provider fills from its "server accepted this message" field: IMAP
`INTERNALDATE`, Graph `receivedDateTime`, Gmail `internalDate`. The first two
are what they claim. Gmail's is not: for Google-generated and Google-relayed
mail (DMARC aggregate reports, Google Groups / mailing-list relays, anything
Google itself injects) `internalDate` is the authored `Date:` header, not the
time the mailbox accepted it. Measured on a real mailbox: a list message
carried an `internalDate` eight weeks before the day its top `Received:` stamp
says the mailbox accepted it, and sorted below eight weeks of older inbox mail;
DMARC aggregate reports all carry `23:59:59` of the reporting day. The message id itself
(`id >> 20` ≈ arrival epoch ms) corroborates that Gmail knows the true arrival
and simply does not surface it as `internalDate`.

`internalDate` is nonetheless what Gmail ORDERS BY: `messages.list` pages,
`after:` / `before:` query filters and history windows all reason in it. The
`.date` arm of `SyncEngine.selectStaleHeaders` (ADR-IOS-042) windows a Gmail
page by "min date of the fetched page" and deletes local rows inside that window
which the page did not return. Changing `date` alone to the arrival time would
therefore be a data-loss defect: the list message above, arrival today but
`internalDate` in July, is never in Gmail's newest-N page, so with `date` =
arrival it sits inside the window and is stale-deleted on the next full sync.

**Decision:**

1. **Gmail's display/sort `date` is the timestamp of the FIRST `Received:`
   header in `payload.headers`** (the final hop, i.e. the receiving mailbox —
   RFC 5322 §3.6.7 prepends each hop). `GmailAPI.metadataQuery` requests
   `Received` alongside the other metadata headers, so the app and the NSE get
   it on the same fetch. Parsing is `EmailDateParsing.receivedHeaderDate`:
   everything after the last `;` that sits OUTSIDE a comment (comments nest and
   may contain `;` and quoted-pairs, RFC 5322 §3.2.2), CFWS removed, obsolete
   two/three-digit years normalized per §4.3 (`26` → 2026, `99` → 1999, `126`
   → 2026 — the shared formatter would otherwise accept `26` as 26 AD and sink
   the message), then the existing `RFC5322Parse.parseRFC5322Date` (weekday and
   seconds optional).
2. **Fallback is `internalDate`, and only when no `Received:` exists or its
   tail does not parse** (owner-approved 2026-09-16). Never `Date()`, for the
   reason `IOS-DATE-001` already records: arrival-now makes an old message the
   newest thing in the inbox, a silent corruption.
3. **A second column, `messageHeader.providerDate` (migration `v91`), carries
   the provider's own order key.** Gmail writes `internalDate` into it; IMAP
   and Graph write the same value as `date` (`MessageHeaderInfo.providerDate`
   nil ⇒ `providerOrderDate == date`). Every sync decision that Gmail
   evaluates in `internalDate` reads `providerDate`, never `date`: the `.date`
   stale-window floor and comparison, the candidate window query, the
   `oldestSyncedDate` anchor, `fetchOlderMessages`' `before:` cutoff, and both
   backfill-walk anchors. Copies that preserve a row (orphan reclaim, UID remap)
   preserve `providerDate` with `date`.
4. **The NSE stages `providerDate` too** (`nse_processed_message.providerDate
   REAL`, ensure-column in both processes) so a pushed Gmail row lands with the
   same window key sync would write, rather than an epoch-zero placeholder or a
   Received-derived date that puts it inside the window before any page has
   returned it.
5. **IMAP and Graph are untouched.** Their receipt field IS their order key, so
   there is nothing to split; `providerDate` simply mirrors `date`.

**Rationale:** The owner's requirement is that the inbox sorts by server
arrival. The Thunderbird add-on already shows the same messages in arrival
position because Thunderbird's own database stores the `Received:`-derived date.
Keeping one column and re-deriving Gmail's stale window from `Received` was
rejected: it would make every Gmail window compare a key the provider does not
page by, which is the `MIS-IOS-002` shape (a window in the wrong coordinate)
with the provider swapped. Two columns keep each consumer in the coordinate its
producer actually uses. The migration's `NOT NULL DEFAULT epoch-zero` plus
`UPDATE … SET providerDate = date` is fail-closed: an upgraded database keeps
and deletes exactly the rows it did before, and a nullable column would have
made every `>= floor` comparison skip NULL rows (SQL three-valued logic).

**Consequences:**

- Existing Gmail rows keep their `internalDate` in `date` until the next
  metadata fetch rewrites them (`runSyncMessages` refreshes `existing.date` on
  every page it returns), so the newest window repairs itself on the first sync
  after upgrade; older rows repair as backfill/re-fetch reaches them. No
  one-off rewrite of history is performed.
- Gmail `before:` / `after:` cutoffs are now anchored on `providerDate`, so a
  Received-vs-internalDate divergence can no longer move a cutoff forward
  between pages.
- `Received:` is one more metadata header per message on the Gmail fetch; no
  additional request.
- The display date on Gmail can now differ from Gmail's web UI for
  Google-relayed mail, in the direction the owner asked for (arrival, not
  authored). Drafts and self-sent mail with no `Received:` keep `internalDate`.
- Pinned by `ReceivedHeaderDateTests`, `GmailParseReceivedDateTests`,
  `StaleWindowProviderDateTests` (red on the pre-`providerDate` code),
  `MessageHeaderProviderDateMigrationTests`, the `providerDateCarry` case in
  `NSEMergeFullHeaderTests`, and `GmailReceivedDateBoundaryTests` — the real
  `GmailProvider` against the fake Gmail REST boundary (which now serves
  `internalDate`, honours `metadataHeaders=` and `before:`, and lists by
  `internalDate`, and serves system labels on request), the real
  `runSyncMessages` (new, refresh, orphan-reclaim, RFC-ID remap and both
  stale-window operands), `fetchOlderMessages`, `runBackfill`, `fullSync`'s
  initial anchor and `gmailDeltaSync` (new row and orphan reclaim), the real `GmailNSEClient.fetchSingleMessage`, and the
  NSE staging column upgrade → writers → decoder → merge. `DatabaseIndexTests`
  pins that the provider-order window and anchor reads seek `providerDate`
  from the v91 index and never sort the folder (two-sided against a
  `(folderId)`-only control of the same name).

Related: ADR-IOS-042 (window coordinate), `IOS-DATE-001` (arrival-now is the
worse fallback), `MIS-IOS-002` (date window for IMAP sync).
