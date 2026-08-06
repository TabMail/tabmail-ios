## There are FOUR irreversible wire operations, not one — the draft family destroys drafts outright (2026-08-04)

> ⚠ **THE COUNT IS NOW FIVE (corrected 2026-08-05, round-8 Q3).** The original title and every
> "four" below are preserved as written — the correction is additive, not a rewrite. The fifth is
> **`CalDAVProvider.deleteEvent`**, adjudicated in *"### 5 — CalDAV `DELETE`"* below. This file's
> own 2026-08-05 calendar-family adjudication (the SCOPE block immediately following) reached for
> the calendar family and evaluated **two of three** providers — Graph and Google — because its
> census keyed on the `method: "DELETE"` **argument** form and CalDAV uses the *other* spelling,
> `request.httpMethod = "DELETE"`. That is `MIS-007`: a census inherits its search shape.
>
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

- **Graph.** A plain `DELETE` on an event is the SOFT delete — the item lands in Deleted Items /
  Recoverable Items. Graph exposes a **separate** `event: permanentDelete` action, documented as
  placing the event in the *Purges* folder of the mailbox dumpster where Outlook cannot reach it.
  **TabMail never calls it.** Identical shape, identical reasoning and identical conclusion to the
  `ExchangeProvider.deleteDraft` adjudication further down this file.
- **Google Calendar.** A deleted event goes to the calendar's **Trash and is restorable for 30
  days**. ⚠️ **The negative case, because this one has a real exception:** deleting a recurring
  series with *"this and following"* is NOT trashed and cannot be restored. It does not apply here —
  `GoogleCalendarProvider.deleteEvent` takes a single `eventId` and issues one resource `DELETE`;
  the tree's occurrence paths (`updateOccurrence`, the `/instances` resolution) address a single
  instance resource by its own id. **If a range/series delete is ever added, re-adjudicate: that
  call WOULD be irreversible and would belong in the set.**

Both calendar files are **byte-identical to `v1.6.38`** (`git diff 07a4bb703..HEAD --` on them is
empty), so nothing in the v3 range changed that surface. Do not read this note as a census of every
destructive call in the tree; it is the mail/draft family, plus this adjudication of the calendar
pair. Recorded 2026-08-05, round 3 angle 2.

⚠ **"the calendar pair" WAS THE ERROR — the family has THREE members.** The paragraph above says
*"reached for the calendar family"*, but `CalDAVProvider.deleteEvent` was never evaluated, because
the census that produced it keyed on the `method: "DELETE"` argument form and CalDAV spells it
`request.httpMethod = "DELETE"`. `rg -ci 'caldav'` over this file returned **zero** before
2026-08-05. It is counted now, as **(5)** below. The lesson is the one this file already teaches
about `ExchangeProvider.deleteDraft`: **exclusion needs positive evidence**, and "I did not see it"
is not evidence — but neither is "I searched", if the search could not have seen it.

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

   **NOT a range regression.** `git diff 07a4bb703..HEAD --` over `TabMail/Providers/CalDAV/`,
   `AccountManagerCalendarQueue.swift`, `GoogleCalendarProvider.swift` and
   `ExchangeCalendarProvider.swift` is **empty**. This is a pre-existing surface that the previous
   enumeration could not see, not something v3 introduced.

   **Consequence for design, which is the only reason this matters:** a fail-closed argument for a
   *calendar* path may not lean on "nothing is ever destroyed". For CalDAV specifically, a wrong or
   duplicated `deleteEvent` is unrecoverable, so it sits under C3 alongside the `COPYUID` gate — do
   not widen what authorizes it, and prefer refusing a delete whose target identity is unproven.

   Sources: [RFC 4918 §9.6 `DELETE`](https://datatracker.ietf.org/doc/html/rfc4918#section-9.6),
   [RFC 4791 (CalDAV)](https://datatracker.ietf.org/doc/html/rfc4791),
   [Apple — Restore your calendars and events on iCloud.com](https://support.apple.com/guide/icloud/restore-your-calendars-and-events-mm7478c562f3/icloud),
   [Nextcloud calendar trashbin regression #30096](https://github.com/nextcloud/server/issues/30096).

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
