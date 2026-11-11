## ADR-IOS-109: A CalDAV Event With Guests Is Written With Its Organizer, Taken From the Resource or From the Server

**Status:** Active (2026-11-11). Replaces the override-only organizer rule in
`occurrenceOverrideResource` (an override that had attendees and no organizer took the series'
organizer, and nothing else did). Amends ADR-IOS-108 (a resource that holds only changed
occurrences "adds no organizer" becomes "adds only an organizer the resource already names").

**Context:** RFC 5545 §3.8.4.3 requires an ORGANIZER on a VEVENT that has attendees. TabMail's
CalDAV writes never wrote one, except an override copying the series' organizer when the series
had one: a create with guests, a first guest added to a stored event, a changed occurrence of a
series with no organizer, and both halves of a split were all written without it.
- **Measured:** iCloud refuses a changed occurrence of a series with no organizer that has
  attendees with a 403, which the calendar queue retires as permanent ("(2) the event has an
  ATTENDEE but no ORGANIZER").
- **Not measured:** whether iCloud also refuses a create, a whole series or a split's parts in
  that shape. The tests model the refusal for every VEVENT (`FakeCalDAVStore`'s
  `refusesAttendeesWithoutOrganizer`), which is what RFC 5545 requires.
- **From the RFCs:** on a server that accepts the shape, the event is stored with guests and nobody
  is invited, because RFC 6638 §3.1 schedules only a resource whose ORGANIZER is one of the calendar
  owner's addresses.

**Decision:**
1. **One step on every PUT.** `CalDAVProvider.putEvent(url:body:precondition:)` is the only
   caller of `client.put`; all six writes go through it: the create, the whole-event edit, the
   one-occurrence edit, the one-occurrence delete's `EXDATE` PUT (`deleteOccurrence`) and both PUTs
   of a split. It runs `withOrganizer` on the final body: the pure
   `CalDAVProvider.organized(_:own:)` (`CalDAVOrganizer.swift`). A source fence
   (`CalDAVOrganizerStepTests.onePutCallSite`) keeps `client.put(` at one call site. The split
   prepares both bodies before its first PUT, so a lookup that fails there writes nothing. When the
   server advertises no address, nothing is cached and `putEvent` looks it up again before each
   PUT, so a lookup can also fail between the split's two PUTs: the new part is written and the
   series is not capped yet, and the retry reaches the cap through ADR-IOS-106's create-only 412
   and `successorIsOurs`.
2. **What the step does,** reading each VEVENT's own properties only (an EMAIL alarm's attendee is
   the alarm's): when some VEVENT has an attendee and no organizer, every VEVENT of the resource
   that has no organizer gets the same one, the guest-less series too, because RFC 6638 §3.1 wants
   the organizer set in all the components; a VEVENT that has an organizer keeps its own; when no
   VEVENT has an attendee without an organizer, the body is returned byte for byte. The step is
   idempotent: a body that already has its organizer passes through `putEvent`'s run unchanged and
   makes no request. A body that still has none (nothing advertised) asks again.
3. **Which address, in order:**
   1. The resource's own organizer, copied byte for byte (every physical line of a folded one): the
      series VEVENT's, else the first changed occurrence's in document order. Every VEVENT that had
      none then names the same organizer (RFC 6638 §3.2.4.2).
   2. Otherwise, and only for a resource with a series VEVENT (every create has one): an address the
      server advertises in the principal's `calendar-user-address-set` (RFC 6638 §2.4.1). The
      sign-in address when it is advertised, written as the server spells it; else the first
      advertised `mailto:`. An href that is not a `mailto:` with an address, or that carries a
      control character or a line break, is skipped.
   3. Nothing advertised: no ORGANIZER is written and the server decides (today's behaviour). The
      sign-in is never written unchecked: on iCloud it can be an Apple ID at another provider or a
      bare login name, and a wrong organizer misattributes the meeting and can send the guests'
      answers elsewhere, which is worse than none.
4. **Never the account's address on an invitations-only resource.** A resource that holds only
   changed occurrences is an invitation to single occurrences of someone else's series. Writing the account's address there would forge the meeting's identity, the alternative
   ADR-IOS-052 rejected. It only gets an organizer another of its VEVENTs names.
5. **The lookup** (`advertisedAddresses`) runs only when the step needs the account's address:
   some VEVENT needs an organizer, no VEVENT names one, and the resource has a series VEVENT. It
   reuses `CalDAVDiscovery.discover` for the principal, then PROPFINDs the principal (Depth 0) for
   `calendar-user-address-set` (`CalDAVDiscovery.calendarUserAddresses`), reading every href
   (`MultistatusParser.Response.propertyHrefs`). An address found is cached for the provider's
   lifetime, in memory only: no column, nothing persisted (ADR-004 untouched), not a setting (the
   snapshot rule does not apply). A new provider, built on reconnect and on Update Password, asks
   again. "None advertised" and errors are never cached: an answer that only reads as none (a
   transient refusal, an error page served as a success) then costs one write, and the next write
   that needs the address asks again.
6. **Lookup errors keep the queue's meaning.** A 404, 403 or other 4xx, a missing principal or
   property, or an answer that can't be read means "none advertised" and the write goes ahead
   without an organizer. A lookup 404 never surfaces as `CalDAVError.notFound`, which the queue
   reads as "the event is gone" and retires. A 401 is rethrown (the auth arm handles it); a
   transport error, a 5xx, a 408, 409, 423, 425 or 429 is rethrown and the edit stays queued with
   nothing written (never-drop clause 2). The "come back later" codes are one predicate,
   `CalendarHTTPStatus.isComeBackLater`, shared with the calendar queue's retirement rule
   (`AccountManager.isCalendarBadRequestError`), so the two cannot drift apart.

**Alternatives rejected:**
- *Write the sign-in address unchecked* (no request): wrong whenever the sign-in is not a scheduling
  address the server knows (Apple ID at another provider, bare iCloud login, a generic server's
  login name).
- *Write the sign-in when it looks like an email:* still unchecked against the server.
- *Refuse the write before the PUT when no address is known:* turns a server-decided outcome into
  a certain failure; servers that accept the shape would stop storing guests.
- *Read the address set at account setup and persist it:* a new column and a migration for a value
  that one PROPFIND per provider lifetime gives, and it would go stale when the user's addresses change.

**Consequences:**
- Guests are invited on CalDAV for the first time: on iCloud, guest writes that 403'd now land, and
  an RFC 6638 server sends the invitations, consistent with `sendUpdates: "all"` and with Google and
  Outlook.
- Late invitations: any later write of a stored event that has guests and no organizer (almost
  always one TabMail wrote before this ADR, on a server that accepted it), such as a title edit,
  a one-occurrence edit, a split or the delete of one occurrence, adds the organizer. For a delete,
  the remaining guests then get their first invitation, to the rest of the series, when one
  occurrence is deleted. RFC 6638 §3.2.3.1 makes that PUT a
  scheduling "Create", so the server invites those guests then, possibly long after they were
  added. Those guests were added to be invited, and on iCloud such a resource can't be written back
  without an organizer.
- Not measured on iCloud: whether it accepts and schedules a resource whose series VEVENT was given
  the organizer only because one of its changed occurrences has guests (the all-components rule
  above). RFC 6638 §3.1 requires that shape; the tests model it.
- On a server that advertises no address, guests are still stored and not invited, as before.
- The first write that needs the address costs up to three PROPFINDs (principal, home set, address
  set; the `.well-known` try adds one on a non-iCloud server), once per provider when an address is
  found. On a server that advertises none, nothing is cached, so every PUT that needs the address
  asks again: a split asks up to four times.
- The irreversible wire operations are unchanged: the split's cap PUT and the one-occurrence
  delete's `EXDATE` PUT may gain ORGANIZER lines, and their membership predicate is unaffected. The
  delete's check (`CalDAVOccurrences.requireDeletedAlone`) compares what each VEVENT is, not its
  content, so the added lines cannot trip it, and a lookup that fails throws before the PUT.
- `MultistatusParser` keeps every href of a property in order (`propertyHrefs`); `properties` is
  unchanged (the last href, as before) for its existing readers.

**Tests:** `CalDAVOrganizerTests` (against `FakeCalDAVStore` in its iCloud-like mode that refuses
attendees without an organizer, and `FakeCalDAVPrincipal`; the invariant on the stored resource after
the real queue drains, on every write path, for each address case, the lookup's failures, the cache,
an href with a line break, and a replay after a lost response; the one exception is test 16, a
resource that holds only changed occurrences, written through the provider's one-occurrence edit
because the queue's series read can't read such a resource, until #720 is fixed), `CalDAVOrganizerStepTests` (the pure
step byte for byte, the chooser, and the one-`client.put` fence) and
`MultistatusParserTests.parsePropertyWithSeveralHrefs`. Closes #711.
