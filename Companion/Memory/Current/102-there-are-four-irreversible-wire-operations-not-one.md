## There are FIVE irreversible wire operations, not one — the draft family destroys drafts outright, and CalDAV destroys calendar events (2026-08-04; corrected FOUR→FIVE 2026-08-05)

> ⚠️ **The FILENAME still says `four`, and that is deliberate.** Four files cite this path —
> `PROJECT_MEMORY.md`, `Companion/Memory/History/110-…`, production `TabMail/Providers/IMAPProvider.swift`,
> and `TabMailTests/Sync/DeletedFlagMergeVisibilityTests.swift`. Renaming breaks every one of
> them, so the slug is frozen and the COUNT lives in this heading and in the body. If you are
> reading the filename as the claim, you are reading a stable id, not a fact.

> ⚠ **THE COUNT IS NOW FIVE (corrected 2026-08-05, round-8 Q3).** The original title and every
> "four" below are preserved as written — the correction is additive, not a rewrite. The fifth is
> **`CalDAVProvider.deleteEvent`**, adjudicated in *"### 5 — CalDAV `DELETE`"* below. This file's
> own 2026-08-05 calendar-family adjudication (the SCOPE block immediately following) reached for
> the calendar family and evaluated **two of three** providers — Graph and Google — because its
> census keyed on the `method: "DELETE"` **argument** form and CalDAV uses the *other* spelling,
> `request.httpMethod = "DELETE"`. That is `MIS-007`: a census inherits its search shape.
>
> ✅ **THE COUNT IS NOW SIX, AND THE HANDOFF BELOW IS DISCHARGED (2026-08-07).** Entries (1)–(5) are
> the *deletion* family; **(6) is `CalDAVProvider.splitSeries`' cap `PUT`** — a REPLACEMENT, not a
> `DELETE`. Everything below is preserved as written; the correction is additive. `tabmail-ios/CLAUDE.md`
> now carries the six-member enumeration, states membership by THE PROPERTY, demotes the greps to a
> LOWER BOUND, and lists patterns D/E — so the reader of the MANTRA no longer sees an incomplete set.

> **THE ENUMERATION PREDICATE — re-run this rather than trusting the integer.** The set is
> *"every wire call that destroys or may destroy user-authored content on a server, where TabMail
> has no positive documented per-item recovery path it actually reaches."* It is enumerated by
> **three** searches over `TabMail/ Shared/ TabMailNotificationService/`, all `--multiline` with
> `\s*` at every join (`MIS-007` instances 36–37 — argument labels wrap routinely here):
>
> | # | pattern | hits at `3e63335b2` | disposition |
> |---|---|---|---|
> | A | `method\s*:\s*"DELETE"` | 7 | `AuthedHTTP:54` is the generic helper, not a wire op. `GmailProvider` ×2 = **(4)** (a call + its 401-retry, one op). `ExchangeProvider` ×2 = excluded on Graph soft-delete (below). `ExchangeCalendarProvider`, `GoogleCalendarProvider` = excluded (below). |
> | B | `httpMethod\s*=\s*"DELETE"` | 3 | `PushClient` ×2 excluded — they delete **TabMail's own push registration** on TabMail's backend, not user content, and the next launch re-registers (recoverable by one ordinary gesture). `CalDAVClient:68` = **(5)**, new. |
> | C | `expunge\(` | 4, of which **2 are live calls** | `IMAPProvider:5037` = **(1)**; `IMAPProvider:5517` inside `expungeScopedToTargets`, reached by `deleteDraftStrong` = **(2)** and `saveDraft` = **(3)**. The other two hits are comments. |
>
> **THE NEGATIVE CASE — state what would falsify this, because an absolute without one is
> unfinished (`feedback_absolutes_need_the_negative_case`, `MIS-019`).** This count is wrong the
> moment any of these becomes true, and each is a thing to go check rather than a hypothetical:
> (a) a **fourth spelling** appears — a `URLRequest` whose method is built from a variable or an
> enum, an `HTTPMethod.delete` type, a `URLSession` upload with a computed verb, or a provider that
> tunnels deletion through `POST` (Gmail `batchDelete`, Graph `permanentDelete`) — none of which
> patterns A/B/C would see; (b) a **non-HTTP, non-IMAP** destructive surface is added (a CardDAV or
> JMAP provider, an EWS SOAP `DeleteItem`); (c) one of the four **excluded** calls loses its
> recovery evidence — Graph retiring Recoverable Items retention, Google Calendar retiring the
> 30-day event trash, or TabMail routing a delete through `message: permanentDelete` /
> `event: permanentDelete`; (d) `GoogleCalendarProvider` gains a **range/series** delete
> (`this and following`), which Google documents as *not* trashed. If you are reading this and
> cannot say which of (a)–(d) you checked, you have not re-run the enumeration.

**The absolute this corrects, and where it is written.** The mental model repeated across this
codebase is: *"TabMail never permanently deletes — `.delete` is a move to Trash — and the ONE
irreversible wire operation in the entire system is expunging a source copy after a proven
`COPY`."* Both halves of that sentence do work: the first is why fail-closed is always safe here,
the second is why the `COPYUID` gate is the single most load-bearing guard in the tree.

**The first half is FALSE FOR DRAFTS, and the second half misses two siblings of the very
operation it names.** A brief or review prompt that says *"the single irreversible operation"* walks
its reader past three others. Enumerated below by symbol, each read at `e4dd08e92`.

**SCOPE — this note enumerates the MAIL/DRAFT family, and says so because an unscoped absolute is
how the "one" got written in the first place (`MIS-019`: an absolute without its negative case).**
The four below are the message/draft destructive wire operations. They are **not** the only
destructive wire calls in the tree: `ExchangeCalendarProvider.deleteEvent` issues
`DELETE /events/{id}` and `GoogleCalendarProvider.deleteEvent` issues
`DELETE /calendars/{cal}/events/{id}?sendUpdates=…` (verified by symbol 2026-08-05, not by line —
`MIS-009`). **Neither is counted, and — following this note's own precedent for
`ExchangeProvider.deleteDraft` — the reason is POSITIVE rather than "unobserved". Both pass the
same `Recoverable ⇒ not irreversible` test that keeps the non-UIDPLUS arms of (2) and (3) out of
the set:**

- **Graph.** ⚠️ **RESTATED 2026-08-06 (round-11 R11-J) BY RECOVERY PROPERTY, NOT BY VERB — the
  count is unchanged; only the test is.** The exclusion used to read "a plain `DELETE` on an event
  is the SOFT delete … Graph exposes a **separate** `event: permanentDelete` action … **TabMail
  never calls it**", which states the criterion as *which HTTP verb we spell* and the evidence as an
  unstated search. That is the very shape this file's own "THE SET IS DEFINED BY A PROPERTY" section
  warns about, and it fails silently in exactly the case that section names: `permanentDelete` is a
  **`POST` action** (`POST /me/events/{id}/permanentDelete`), so none of the three verb greps that
  produce this note's integer could ever see it, and a future call to it would be excluded by a test
  that never looked.

  **The property that excludes this call:** after it returns, the item is in a state from which the
  USER can restore it, per item, without our help — Deleted Items / Recoverable Items, 14 days by
  default on Exchange Online. Recovery is a fact about the RESOURCE AFTER the call, and it is what
  membership in this set turns on; the verb is only how we happened to ask.

  **The predicate that keeps the exclusion honest, so it is checkable rather than asserted:** search
  the ACTION NAMES and the destructive MODES, never the verb — `rg -n 'permanentDelete|batchDelete|
  DeleteType|HardDelete|SoftDelete|/purges?/' TabMail/ Shared/ TabMailNotificationService/`. Run at
  `e1e8724bc` it returns **two hits, BOTH PROSE, ZERO call sites**: `IMAPProvider.swift`'s comment
  naming Graph's `message: permanentDelete` as the destroying semantic we do *not* use, and
  `SyncEngine.swift`'s "evict/purge/prune" describing LOCAL database maintenance. ⚠️ Report the hits
  rather than the phrase "returns nothing" — a predicate reported as empty when it is not is how the
  next reader concludes the census was never run. **Zero call sites** — not "we only issue `DELETE`"
  — is the evidence. The exclusion is
  **falsified**, and the call joins the set, the moment ANY of these becomes true regardless of
  spelling: the tree calls `permanentDelete` or any dumpster/`Purges`-targeting action; a deletion
  is tunnelled through a `POST` batch or a computed/enum verb; an EWS `DeleteItem` with
  `DeleteType=HardDelete` appears; or Microsoft retires Recoverable Items retention for the
  populations we serve.

  Identical shape, identical reasoning and identical conclusion to the
  `ExchangeProvider.deleteDraft` adjudication further down this file — which should be read the same
  way, by recovery property rather than by the verb it is spelled with.
- **Google Calendar.** A deleted event goes to the calendar's **Trash and is restorable for 30
  days**. ⚠️ **The negative case, because this one has a real exception:** deleting a recurring
  series with *"this and following"* is NOT trashed and cannot be restored. It does not apply here —
  `GoogleCalendarProvider.deleteEvent` takes a single `eventId` and issues one resource `DELETE`;
  the tree's occurrence paths (`updateOccurrence`, the `/instances` resolution) address a single
  instance resource by its own id. **If a range/series delete is ever added, re-adjudicate: that
  call WOULD be irreversible and would belong in the set.**

⚠️ **THE SENTENCE THAT FOLLOWS IS FALSE AND IS KEPT VERBATIM BECAUSE IT IS THE PREMISE ANYONE
RE-DERIVING THIS ADJUDICATION WOULD LEAN ON (round-13 U8 item 3).** *"Both calendar files are
**byte-identical to `v1.6.38`** (`git diff 07a4bb703..HEAD --` on them is empty), so nothing in the
v3 range changed that surface."* Google was, when this was written. **Exchange was not**, and by
round 13 neither is: measured at `c77d70675`, `git diff --stat 07a4bb703..HEAD --` reports
`GoogleCalendarProvider.swift` **+146/−…**, `ExchangeCalendarProvider.swift` **+182/−…**, and
`CalDAVProvider.swift` **+349/−…** (587 insertions, 90 deletions across the three). A
"byte-identical to shipped" claim is a measurement with a timestamp, not a property — restate it
only with the revision beside it, or it silently becomes an argument for not re-checking the very
surface it describes.

The ADJUDICATION below still holds — it rests on what the calls DO and on the providers'
documented recovery, not on the files being unchanged — but it must be re-derived against HEAD
rather than inherited. Do not read this note as a census of every
destructive call in the tree; it is the mail/draft family, plus this adjudication of the calendar
pair. Recorded 2026-08-05, round 3 angle 2.

⚠ **"the calendar pair" WAS THE ERROR — the family has THREE members.** The paragraph above says
*"reached for the calendar family"*, but `CalDAVProvider.deleteEvent` was never evaluated, because
the census that produced it keyed on the `method: "DELETE"` argument form and CalDAV spells it
`request.httpMethod = "DELETE"`. `rg -ci 'caldav'` over this file returned **zero** before
2026-08-05. It is counted now, as **(5)** below. The lesson is the one this file already teaches
about `ExchangeProvider.deleteDraft`: **exclusion needs positive evidence**, and "I did not see it"
is not evidence — but neither is "I searched", if the search could not have seen it.

⚠️ **THE REPLACEMENT-AXIS CENSUS COUNTS A PATTERN LINE, NOT THE WIRE OPERATIONS BEHIND IT
(round-13 U9).** Pattern D (`httpMethod\s*=\s*"PUT"`) yields exactly one CalDAV hit,
`CalDAVClient.swift`'s request builder, and this file adjudicates exactly one thing behind it —
`splitSeries`' cap `PUT`. **That single line is reached by seven distinct operations.** Two of them,
`CalDAVProvider.updateEvent` and `CalDAVProvider.updateOccurrence`, replace a WebDAV representation
wholesale with no restore — the identical shape that was used to admit the cap `PUT` — and are named
neither as included nor as excluded. A census whose unit is a grep hit rather than a caller reports
"one site, adjudicated" when seven operations share it; the count is a property of the SEARCH, not
of the surface (`MIS-007`).

Separately, the falsification clause excludes Graph `PATCH` on the ground that it *"merges named
fields"*. That condition is **already false in this tree**: both `ExchangeCalendarProvider` and
`GoogleCalendarProvider` GET the event and send the full merged payload, and both say so in their
own comments. The exclusion therefore rests on a premise the code contradicts.

**What is wrong is the CENSUS-COMPLETENESS claim, and only that.** The substantive lost-update risk
these operations carry is owned and closed by `KNOWN_ISSUES.md` `IOS-CAL-002` — **do not re-file the
lost-update class here.** Recorded 2026-08-06, round 13.

Sources: [Graph `event: delete`](https://learn.microsoft.com/en-us/graph/api/event-delete?view=graph-rest-1.0),
[Graph `event: permanentDelete`](https://learn.microsoft.com/en-us/graph/api/event-permanentdelete?view=graph-rest-1.0),
[Google Calendar — delete an event](https://support.google.com/calendar/answer/37113?hl=en&co=GENIE.Platform%3DDesktop).

### The four, by symbol — ⚠ **now five**; (5) was added 2026-08-05 and is at the end of this list

1. **The `COPYUID`-gated move source expunge** — `IMAPProvider.move`'s purge leg,
   `try await server.expunge(messages: purgeAuthorizedUIDs)`. This is the one the absolute names.
   It removes a **duplicate** the COPY already proved landed, never a message. Its evidence is
   `COPYUID` and **must never be widened**; that prohibition is unchanged by this entry.
2. **`IMAPProvider.deleteDraftStrong`** — after validating epoch + UID and re-FETCHing the target,
   it issues `STORE \Deleted` then `expungeScopedToTargets(targetSet, …)`. On a UIDPLUS server that
   is `UID EXPUNGE`: **the draft is destroyed, not moved to Trash.**
3. **`IMAPProvider.saveDraft`'s old-copy replacement** — before APPENDing the new revision, when the
   prior identity validates (same folder, epoch match, UID present on FETCH), it issues the same
   `STORE \Deleted` + `expungeScopedToTargets` pair against the OLD draft UID. Same destruction, on
   the ordinary save path rather than an explicit delete gesture.
4. **`GmailProvider.deleteDraft`'s resource arm** — `DELETE {baseURL}/drafts/{draftId}`. Google
   documents `users.drafts.delete` as *"Immediately and permanently deletes the specified draft.
   Does not simply trash it."* There is no Trash copy and no undo.
5. **`CalDAVProvider.deleteEvent`** — `client.delete(url: eventURL)`, i.e.
   `CalDAVClient.delete`'s `request.httpMethod = "DELETE"`, an unconditional WebDAV `DELETE` on the
   event's own `.ics` resource. **Added 2026-08-05 (round-8 Q3); previously unadjudicated.** It
   destroys a user-authored calendar event — title, attendees, location, notes — outright.

   **Why it is COUNTED while Graph and Google calendar are excluded.** The exclusion standard those
   two rest on is *documented, per-item, server-side recovery that TabMail's own call actually
   reaches*: Graph's plain `DELETE` is the soft delete into Recoverable Items, Google Calendar's is
   a 30-day event Trash. **CalDAV has no such standard.** WebDAV (RFC 4918 §9.6) defines `DELETE`
   as removing the resource and defines **no** trash, undelete, versioning, or restore; CalDAV
   (RFC 4791) adds none. Whether a *particular* server keeps something is a per-implementation
   extension TabMail neither selects nor observes — some do (Nextcloud keeps a calendar trashbin,
   visibly enough that re-adding a deleted UID fails with *"Deleted calendar object with uid
   already exists"*), most do not. **That is precisely the "unobserved" standard this file already
   rejected** when it re-raised `ExchangeProvider.deleteDraft`: absence of evidence is not evidence
   of recovery. The asymmetry is deliberate — for Graph and Google we can name the documented
   recovery path; for CalDAV we cannot name one for any server TabMail supports.

   ⚠ **The near-miss counterexample, stated because it looks like one and is not.** iCloud is the
   primary CalDAV target (`ICloudConfig.swift`), and Apple does offer *Restore your calendars and
   events* on iCloud.com from periodic archives. **It does not qualify.** It is a **whole-calendar
   snapshot rollback**, not a per-item trash: restoring replaces the calendar's current contents
   with the archived version, so recovering the one deleted event **discards every change made
   since the snapshot** and re-issues invitations. Recovering one user intention by destroying
   later ones is not recovery — the same test that keeps a mailbox-wide `EXPUNGE` unacceptable as a
   substitute for `UID EXPUNGE`. There is also no per-account guarantee the archive exists, and the
   app never surfaces the path.

   **Reachability — it is live, and undiscriminated.**
   `AccountManagerCalendarQueue.swift:460` calls `provider.deleteEvent(calendarId:eventId:sendUpdates:)`
   **through the protocol with no provider branch**, so a CalDAV account takes the same drain path
   as Graph and Google. `CalDAVProvider.deleteEvent` itself has no ETag precondition (`If-Match` is
   set on `put`, never on `delete`), no confirmation re-read, and no epoch/identity gate — it
   resolves a URL from the event id and issues the `DELETE`.

   **NOT a range regression — the CONCLUSION survives, the EVIDENCE as originally written does
   not.** ⚠️ **CORRECTED 2026-08-05 (round-10 F5b).** This paragraph said: *"`git diff
   07a4bb703..HEAD --` over `TabMail/Providers/CalDAV/`, `AccountManagerCalendarQueue.swift`,
   `GoogleCalendarProvider.swift` and `ExchangeCalendarProvider.swift` is **empty**."* **It is not
   empty, and it was already not empty when written.** Re-run with an EXPLICIT revision range —
   `git diff --numstat 07a4bb703..3974e4280 -- TabMail/Providers/CalDAV/` — it reports
   **`CalDAVClient.swift` 39 insertions / 4 deletions** and **`CalDAVProvider.swift` 58 insertions /
   12 deletions**; the other three paths ARE unchanged over that range. The CalDAV delta is the
   round-9 remediation that introduced `CalDAVPutPrecondition` and rewrote `revertMasterCap`.

   **The conclusion is unaffected**, and that is the point of correcting it rather than deleting it:
   none of those 97 changed lines touches `deleteEvent` or `CalDAVClient.delete`, so `deleteEvent` IS
   pre-existing and IS a surface the earlier enumeration could not see. The defect was the
   INSTRUMENT, twice over: (a) it cited **`..HEAD`**, a moving target, so the command's answer
   changes under a durable document that quotes it — never write `..HEAD` in a durable document,
   always pin both ends (`feedback_line_citations_go_stale`); and (b) it read a directory-level diff
   as a proxy for a symbol-level question, so a real change to a SIBLING symbol in the same directory
   was reported as "empty". Ask the question you mean: *did `deleteEvent` or `CalDAVClient.delete`
   change in this range?* — `git log -L` on the symbol, or `git diff <base>..<rev> -- <file>` read
   for the hunk that contains it.

   **Consequence for design, which is the only reason this matters:** a fail-closed argument for a
   *calendar* path may not lean on "nothing is ever destroyed". For CalDAV specifically, a wrong or
   duplicated `deleteEvent` is unrecoverable, so it sits under C3 alongside the `COPYUID` gate — do
   not widen what authorizes it, and prefer refusing a delete whose target identity is unproven.

   Sources: [RFC 4918 §9.6 `DELETE`](https://datatracker.ietf.org/doc/html/rfc4918#section-9.6),
   [RFC 4791 (CalDAV)](https://datatracker.ietf.org/doc/html/rfc4791),
   [Apple — Restore your calendars and events on iCloud.com](https://support.apple.com/guide/icloud/restore-your-calendars-and-events-mm7478c562f3/icloud),
   [Nextcloud calendar trashbin regression #30096](https://github.com/nextcloud/server/issues/30096).

### ⚠️ MEMBERSHIP IS DEFINED BY A PROPERTY, NOT BY A VERB — and the three greps are a LOWER BOUND, not the enumeration (added 2026-08-05, round-10 F4)

**Everything above this heading stands and nothing in it is retracted.** What is corrected is the
*shape of the question*. The three `--multiline` searches recorded at the top of this file
(`method\s*:\s*"DELETE"`, `httpMethod\s*=\s*"DELETE"`, `expunge\(`) are all searches for a
**verb**. The set they are supposed to enumerate is defined by a **property**:

> **THE PROPERTY.** A wire call belongs to this set when, **at the moment it succeeds**, some
> user-authored content that existed on the server no longer exists there, and TabMail cannot name a
> documented per-item recovery path that its own call actually reaches.

Read that predicate and then read the three greps: **a verb-shaped search cannot see a destructive
call that is not spelled with a destructive verb.** The property is about the *effect on the stored
representation*, and an HTTP `PUT` replaces a representation — the previous bytes are gone. So the
enumeration was structurally blind to an entire axis, and the blindness is not a counting error that
a more careful re-run of the same three patterns would catch. `MIS-007` again, one level up: the
first correction fixed the SPELLING of a verb (`method:` vs `httpMethod =`) while leaving the
*category* — "destructive means DELETE" — unexamined.

**THE REPLACEMENT AXIS — run these too, and treat them exactly as the DELETE patterns are treated:
as a lower bound on the property, never as its definition.**

| # | pattern | hits at `3974e4280` | disposition |
|---|---|---|---|
| D | `httpMethod\s*=\s*"PUT"` | 2 | `CalDAVClient.swift:82` — the CalDAV `PUT`; adjudicated below. `TabMailAuthService.swift:273` — TabMail's own backend, not user content on a mail/calendar server; excluded. |
| E | `method\s*:\s*"PUT"` | 2 | `AuthedHTTP.swift:50` is the generic helper, not a wire op. `GmailProvider.swift:655` — `PUT /drafts/{existingId}`; adjudicated below. |

**⚠️ NEVER WRITE A BARE INTEGER FOR THIS SET WITHOUT THE REVISION IT WAS DERIVED AT.** Every count in
this file — 5, 7, 3, 4, 2, 2 — is a measurement of one tree at one commit, and this file has already
carried a stale one past the code it described (`MIS-007`, 43 recorded instances). Write *"five at
`3e63335b2`"*, not *"five"*. If you are restating a number from this file into a brief, a review
prompt, or `CLAUDE.md`, carry the revision with it or do not carry the number.

#### Adjudication — `CalDAVProvider.splitSeries` **IS IN THE SET** (the cap `PUT`)

`splitSeries` step 3 issues `client.put(url: eventURL, body: cappedICS, …)` against the **existing
master event resource**. That PUT replaces the master's representation with one whose `RRULE` carries
an `UNTIL=` cap: **every occurrence after the split point ceases to exist on the server**, and the
pre-cap representation is gone. WebDAV defines no versioning, no undelete, and no restore for it
(RFC 4918) — the same absence that puts `CalDAVProvider.deleteEvent` in the set as (5). It satisfies
THE PROPERTY exactly, and no `DELETE`-shaped or `expunge`-shaped search could ever have found it.

It is **not** a sixth numbered member of the list above, and the distinction is worth stating because
it is the reusable part: entries (1)–(5) are *deletion* operations, and `splitSeries` is a
*replacement* operation. Both destroy; only one is spelled like it. The list above is the **deletion
family**; this section is the **replacement family**, and the two together are the property's current
membership at `3974e4280`.

**Consequence for design, which is the whole reason this matters.** `splitSeries` is a
**multi-step** irreversible operation — cap the master, then create the successor — and its rollback
is a best-effort compensating `PUT`, not a transaction. Round 10 (F1, F2) closed the two ways that
compensation went wrong: the rollback now carries `.ifMatch(capETag)` using the tag the cap PUT's own
2xx returned, so it overwrites **our own** write and refuses a concurrent editor's; and a 412 from
the create-only successor PUT is discriminated by probing the deterministic successor URL for our own
UID, so a lost ACK retires the op instead of un-capping a master that already has a live successor
(which would duplicate every post-split occurrence) or wedging the account's calendar lane forever on
an error `AccountManagerCalendarQueue.isCalendarBadRequestError` does not classify. **Do not widen
the successor PUT past `.ifNoneMatchAny`, and do not make the rollback unconditional again.**

#### Adjudication — `GmailProvider.saveDraft`'s update arm is **NOT** in the set

`PUT /drafts/{existingId}` replaces a Gmail draft's content, so it destroys the previous revision of
user-authored bytes. It is nevertheless **excluded, on positive evidence rather than on absence** —
the same standard this file applies to `ExchangeProvider.deleteDraft` and the two non-CalDAV calendar
providers: the content it replaces is a draft revision the local `draft` row still holds, and the
call is the *mechanism by which the user's own newest text reaches the server*. Refusing it does not
preserve a user intention; it drops one. ⚠️ **The negative case:** this exclusion is about a draft
overwriting ITSELF with a newer authored revision. If a code path ever PUTs a draft resource with
content it did not derive from that draft's own current local state — a merge, a template, a
regeneration keyed on a stale snapshot — that call destroys authored bytes with no local copy behind
them and belongs in the set. The Stage A/B CAS in `DraftStore.applySave` is what currently makes that
impossible; if it is removed, re-adjudicate this line.

#### What would falsify THIS section

(a) A third destructive-by-replacement spelling appears — `PATCH` that replaces rather than merges
(Graph's `PATCH /events/{id}` in `ExchangeCalendarProvider.splitSeries` merges named fields and is
excluded on that basis, but a full-resource `PATCH` would not be), a `POST` that overwrites, or a
`URLRequest` whose method is computed. (b) A CalDAV or CardDAV `PUT` is added on a path whose prior
representation has no local copy. (c) `splitSeries` gains a third wire step, which would widen the
window its compensating rollback has to cover. (d) The property itself is restated more narrowly by
someone reading "irreversible" as "spelled DELETE" — which is the error this section exists to stop.

### The negative cases — because an absolute without one is unfinished

- **(2) and (3) are irreversible only where the server advertises UIDPLUS.** `expungeScopedToTargets`
  issues `UID EXPUNGE` on UIDPLUS and **nothing at all** otherwise — it explicitly refuses to
  degrade to a mailbox-wide `EXPUNGE`, so on a non-UIDPLUS server the draft is left
  `\Deleted`-but-present and is recoverable. The fail-closed arm is deliberate and documented at
  the function; do not "fix" it into a bare expunge.
- **All four are UID- or resource-scoped. None is mailbox-wide.** That distinction is the whole
  point of `expungeScopedToTargets` and is separate from reversibility.
- **`GmailProvider.deleteDraft`'s OTHER arm is reversible** — the `.gmailContainedMessage` branch
  calls `trashContainedDraftMessage`, i.e. a trash, not a delete. The irreversible claim is about
  the `.gmail(resourceId)` arm only.
- **`ExchangeProvider.deleteDraft` is NOT counted above.** It issues
  `DELETE {baseURL}/messages/{id}`; whether Graph hard-deletes or moves the item to Deleted Items is
  a server-side semantic TabMail neither chooses nor observes, so it is neither confirmed as a fifth
  irreversible op nor covered by "never permanently deletes". Verified at the wire call only.

  📌 **RE-RAISED AS A FIFTH (2026-08-05) AND STILL NOT COUNTED — now on evidence rather than on the
  absence of it.** An audit angle enumerated **five** irreversible wire operations in scope, the
  fifth being this one, and asked that the fifth be recorded. Recording it: the call is
  `performHTTPRequestWithRetry(url: baseURL + "/messages/\(encodedDraftId)", method: "DELETE", …)`
  in `ExchangeProvider.deleteDraft`, gated on `case .outlook(let draftId)` of `DraftDeleteIdentity`
  and treating a `404` as success ("Exchange may auto-delete drafts after send"). **It stays out of
  the set, and the reason is now positive rather than "unobserved":** Microsoft Graph exposes a
  **separate** `message: permanentDelete` action, documented as permanently deleting the message and
  placing it in the *purges* folder of the mailbox dumpster — TabMail never calls it. A plain
  `DELETE` on a mailbox item is the soft delete: the item lands in Deleted Items / Recoverable
  Items' *Deletions* subfolder and is retained for the mailbox's deleted-item retention period
  (14 days by default on Exchange Online). **Recoverable ⇒ not irreversible**, which is the same
  test that keeps the non-UIDPLUS arms of (2) and (3) out of the set. The count stays **four**.
  ⚠ If someone later routes a draft delete through `permanentDelete`, that call — not the plain
  `DELETE` — becomes the fifth, and this note must be updated with it.
  Sources: [message: delete](https://learn.microsoft.com/en-us/graph/api/message-delete?view=graph-rest-1.0),
  [message: permanentDelete](https://learn.microsoft.com/en-us/graph/api/message-permanentdelete?view=graph-rest-1.0).
- **Ordinary mail is unaffected.** `.delete` on a message is still a move to Trash; nothing here
  widens any message-deletion path. The falsification is scoped to **drafts**.

### The true half, which is load-bearing and stays

Verified by grep at `e4dd08e92`, and worth keeping quotable:

- **v3 has ZERO bare `server.expunge()` call sites.** `rg -n '\.expunge\(\)' TabMail/` returns one
  hit and it is a *comment* in `expungeScopedToTargets` recording that an earlier revision did this
  and why the reasoning was wrong. Every live expunge names its targets.
- **Shipped `07a4bb703` had FOUR bare `server.expunge()` call sites**, all in
  `TabMail/Providers/IMAPProvider.swift` (a fifth `expunge(` site at that tag is the UID-scoped
  `server.expunge(messages: srcUIDs)` — five expunge sites, four of them bare). The shipped release
  also reached SwiftMail's `server.move`, whose non-UIDPLUS fallback falls through to a bare
  mailbox-wide `expunge()`; v3 no longer calls `server.move` at all. ⚠️ **A swarm report circulated
  the count as "five bare sites" — it is four bare of five total. Cite the number you counted.**
- **The `COPYUID` gate's evidence must never be widened.** A source copy left `\Deleted`-but-present
  is an accepted, recoverable cost; expunging without proof is a wrong-message deletion (C3).
  `aUidPlusMoveStillPurgesOnlyTheNamedUID` in `DeletedFlagMergeVisibilityTests` is the standing
  control.

### How to write it from now on

Not *"the single irreversible wire operation"*. Instead: *"the only irreversible operation on a
**message** is the `COPYUID`-gated source expunge, which removes a proven duplicate. **Drafts are
different**: `deleteDraftStrong`, `saveDraft`'s old-copy replacement and Gmail's `drafts.delete`
destroy a draft outright."* State drafts explicitly, every time — that is the negative case the
absolute was hiding.

**Handoff note:** `tabmail-ios/CLAUDE.md`'s THE MANTRA section still carries the uncorrected
absolute (*"TabMail never permanently deletes"* / *"The one irreversible wire operation in the
entire system…"*). That file was dirty in the owner's working tree when this entry was written and
was deliberately not edited. It needs the same correction.

✅ **HANDOFF DISCHARGED (2026-08-05).** `tabmail-ios/CLAUDE.md`'s THE MANTRA section now carries the
correction inline — a *"Stated negatively, because this absolute was wrong for two years and walked
reviewers past two live hazards"* block enumerating all four, scoping (2) and (3) to UIDPLUS, noting
Gmail's `.gmailContainedMessage` arm trashes rather than destroys, declining to count
`ExchangeProvider.deleteDraft`, and linking back to this file. The remaining stale copy of the
absolute was `IMAPProvider.deleteDraftStrong`'s inline comment (*"one of the two irreversible wire
operations"*); it was corrected to **four** on 2026-08-05 and now points here as the authority.

⚠️ **A SECOND HANDOFF IS OPEN (2026-08-05, round-10 F4).** `tabmail-ios/CLAUDE.md`'s THE MANTRA block
now enumerates **five** operations and lists **three** census patterns — all of them
`DELETE`/`expunge`-shaped. It therefore inherits exactly the blindness the *"MEMBERSHIP IS DEFINED BY
A PROPERTY"* section above corrects: it states the set by verb, and it carries the bare integer
"five" with the rev only in the routed detail. **That file was dirty in the owner's working tree when
this entry was written and was deliberately NOT edited** — the same reason the first handoff was
deferred. It needs: membership stated by THE PROPERTY, the three greps demoted to a lower-bound
cross-check, patterns D and E added, `CalDAVProvider.splitSeries` adjudicated in, and the integer
never restated without its revision. Until that edit lands, **this file is the authority** and
`CLAUDE.md`'s MANTRA already says so (*"Detail and evidence: …102-…"*).

⚠️ **THE SECOND HANDOFF IS STILL OPEN, RE-VERIFIED 2026-08-07 (round-18 D4) — and round 18 produced
the evidence that it is not merely tidy-up.** The round-18 audit re-reported *"the enumeration lists
five deletion-family operations but omits `CalDAVProvider.splitSeries`"* as a **new** finding. It is
not new: the *"Adjudication — `CalDAVProvider.splitSeries` **IS IN THE SET**"* section above has said
so since round 10. What the re-report actually measures is **reachability**: an auditor reading
`tabmail-ios/CLAUDE.md`'s MANTRA block sees five DELETE/expunge-shaped members and three
DELETE/expunge-shaped census patterns, finds no replacement axis, and correctly concludes the set is
incomplete — because *from that file* it is. The routed detail is authoritative and was already
right; it is simply not what the reader reads. **A correction that lives only in the routed file is
not discharged, it is filed.** That is the transferable point, and it is why this handoff gets a
dated re-verification rather than a second copy of the adjudication.

**Re-derived at `92e99fad1` + this round's working tree, per the never-a-bare-integer rule above.**
Bounded to `TabMail/ Shared/ TabMailNotificationService/`:

| # | pattern | hits at `3974e4280` | hits at `92e99fad1` | delta |
|---|---|---|---|---|
| A | `method\s*:\s*"DELETE"` | — | 7 | (`AuthedHTTP` helper; Gmail drafts ×2 incl. retry; Exchange calendar; Google calendar; Exchange draft ×2 incl. retry) |
| B | `httpMethod\s*=\s*"DELETE"` | — | 3 | (`PushClient` ×2 — TabMail's own backend, excluded; `CalDAVClient:103`) |
| C | `expunge\(` | — | 4 | (2 calls in `IMAPProvider`, 2 comment lines) |
| D | `httpMethod\s*=\s*"PUT"` | 2 | **2** | unchanged — `CalDAVClient.swift:82` (in the set, via `splitSeries`' cap), `TabMailAuthService.swift:273` (own backend, excluded) |
| E | `method\s*:\s*"PUT"` | 2 | **2** | unchanged — `AuthedHTTP.swift:50` (generic helper), `GmailProvider.swift:655` (adjudicated OUT above) |

So **the adjudications above hold unchanged at this revision**; nothing was added to the replacement
axis and nothing left it. `CalDAVProvider.splitSeries` step 3 still issues
`client.put(url: eventURL, body: cappedICS, precondition: etag.map(.ifMatch) ?? .unconditional)`
against the existing master resource, and the compensating `revertMasterCap` is still best-effort
rather than transactional.

**THE EXACT ONE-LINE EDIT `tabmail-ios/CLAUDE.md` NEEDS — written out so the owner does not have to
re-derive it.** In THE MANTRA's *"Stated negatively"* block, after the sentence enumerating the five
and before the *"⚠ Do not restate this integer without re-running its predicate"* warning, insert:

> **(6) is not a DELETE at all: `CalDAVProvider.splitSeries`' cap `PUT` replaces the master `.ics`
> with an `UNTIL=`-capped `RRULE`, destroying every occurrence after the split point, under a
> best-effort compensating rollback rather than a transaction. Membership in this set is defined by
> a PROPERTY — content that existed on the server no longer does, with no documented per-item
> recovery the call reaches — not by the verb `DELETE`; the three greps are a LOWER BOUND, and
> patterns D (`httpMethod\s*=\s*"PUT"`) and E (`method\s*:\s*"PUT"`) belong beside them.**

**This entry does NOT edit `tabmail-ios/CLAUDE.md`.** That file is a protected owner artifact and was
dirty in the owner's working tree again in round 18; editing it was explicitly out of scope. The
handoff therefore remains OPEN, and this file remains the authority until the owner lands the edit
above.

---

## ✅ DISCHARGED 2026-08-07 — the `tabmail-ios/CLAUDE.md` edit LANDED

**The handoff above is closed.** The owner's working tree was clean, so the edit specified verbatim in
*"THE EXACT ONE-LINE EDIT `tabmail-ios/CLAUDE.md` NEEDS"* was applied to THE MANTRA block:

- `There are **five**:` → `There are **six**:`
- the `(6) … cap `PUT`` sentence inserted before the restate-the-integer warning;
- membership restated **by the PROPERTY**, with the greps demoted to an explicit **LOWER BOUND**;
- patterns **D** (`httpMethod\s*=\s*"PUT"`) and **E** (`method\s*:\s*"PUT"`) added beside A/B/C;
- *"a fifth spelling"* → *"a further spelling"*, so the trip-wire carries no integer of its own;
- the closing pointer now reads *"its count is now six"*.

**All five predicates were re-run before the edit** (never restate the integer): **A=7, B=3, C=4,
D=2, E=2** over `TabMail/ Shared/ TabMailNotificationService/` — identical to the `92e99fad1` column
of the table above, so every adjudication holds unchanged. `CalDAVProvider.splitSeries` step 3 still
issues the cap `PUT` against the existing master resource with a best-effort `revertMasterCap`.

**The transferable point this entry made — *"a correction that lives only in the routed file is not
discharged, it is filed"* — is now demonstrated in both directions:** it took an audit re-reporting
the same finding as NEW, twice, before the index surface was actually corrected. The re-report was
not noise; it was the measurement that the routed fix had never become reachable.

---

## Re-derived for atomic UID MOVE at `ec9682dec` (2026-08-08)

The property predicate and all five lower-bound searches were re-run over `TabMail/`, `Shared/` and
`TabMailNotificationService/` at the production candidate `ec9682dec`:

| pattern | hits | disposition |
|---|---:|---|
| A — `method\s*:\s*"DELETE"` | 7 | unchanged adjudications |
| B — `httpMethod\s*=\s*"DELETE"` | 3 | unchanged adjudications |
| C — `expunge\s*\(` | 5 | 2 live UID-scoped calls and 3 comments; the +1 from the prior census is comment-only |
| D — `httpMethod\s*=\s*"PUT"` | 2 | unchanged adjudications |
| E — `method\s*:\s*"PUT"` | 2 | unchanged adjudications |

A direct transport census adds exactly one app call to `server.moveAtomically`. It is **outside the
set on positive evidence**: successful RFC 6851 `UID MOVE` retains each affected message in the
destination mailbox, and the fork entry point has no COPY/STORE/EXPUNGE fallback. It changes the
message's location, not whether its authored content exists on the server. The no-`MOVE` owned route
and its two live UID-scoped expunge calls remain unchanged.

Therefore the six-member property set is unchanged at `ec9682dec`; only reachability narrows. On a
`MOVE` server the app no longer reaches its own `STORE \\Deleted` / scoped-expunge tail. The soft-
deleted residue and explicit source-expunge surfaces remain reachable only on the no-`MOVE` route,
as narrowed in `IOS-IMAP-001` and `IOS-IMAP-006`.

**Negative case.** Re-adjudicate atomic MOVE if the fork ever gains a fallback, if a call can report
success without retaining each member in at least one mailbox, or if a future provider implements a
"move" as destructive replacement without a reached per-item recovery path. The symbol name is not
the exclusion; retained server-side content is.
