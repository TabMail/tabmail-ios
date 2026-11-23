# An Outlook calendar listing reads every page Graph returns

**Added 2026-11-12 (#435).**

Microsoft Graph pages a collection: "To read all results, you must continue to call Microsoft
Graph with the @odata.nextLink property returned in each response until the @odata.nextLink
property is no longer returned" (learn.microsoft.com/graph/paging). Until #435,
`ExchangeCalendarProvider.listEvents` sent `$top=maxResults` and read only the first page, and
`listCalendars` read one page of `/me/calendars`. A busy window lost every event past page one,
the assistant's search (`query`, filtered on the device because calendarView has no `$search`)
saw only page one, and a mailbox with more calendars than one page lost the rest.

## The rule now

- `ExchangeCalendarProvider.readPages` reads a collection page by page through `request`, so
  every page carries the same `Prefer: outlook.timezone` and every listed time is in one zone.
- A next link that is not a Graph page link (`GraphAPI.isGraphPageLink`: https,
  graph.microsoft.com, default port, no user info) throws `ExchangeCalendarError.invalidPageLink`
  before any request is sent to it, so the token never leaves Graph.
- A listing that has not ended within `ExchangeCalendarConfig.maxListPages` (40) pages throws
  `ExchangeCalendarError.listingIncomplete`. No part of a listing is returned as the whole.
  Only the assistant's tools and Settings list calendars and events, never the durable calendar
  queue, so the error cannot hold a queued write. The cap is reachable: 40 pages of 250 is 10,000
  rows, which a search with explicit dates years apart on a very busy calendar can pass. That
  calendar is then reported in the tool's result as not read, and a narrower window lists it
  (#1293, 2026-11-23; until then it was skipped: `CalendarToolHelpers` logged and moved on, and
  the assistant read the missing calendar as one with no events).
- `listEvents` asks for `ExchangeCalendarConfig.listPageSize` (250) events a page, the `$top` the
  search tool's `maxResults` already sent, so Graph is known to take it. It filters each page as
  it is read (cancelled, empty, then the `query`), so `maxResults` counts the events returned,
  never the raw rows a page held, and reading stops on the page that reaches `maxResults` (the
  first `maxResults` matches in start order, like Google's `maxResults` and CalDAV's trim).
- `listCalendars` sends no `$top` (never measured on `/me/calendars`) and reads Graph's own pages.

## `$select` names only properties calendarView can select

learn.microsoft.com/graph/api/user-list-calendarview: "The createdDateTime and
lastModifiedDateTime properties of event don't support $select." Both were in
`ExchangeCalendarProvider.eventSelect` (listings, `getEvent`, `fetchForEdit`, splits) and fed
`GCalEvent.created` / `updated`, which nothing reads. They are no longer selected or decoded; an
Outlook event carries no `created` or `updated`.

## Not measured live

A read-only Graph Explorer check on an Outlook.com test account was tried on 2026-11-12. Every `/me` read came back 502 `UnknownError` with Graph Explorer still on "Tenant
Sample" after the account tile was picked, so no Graph request was measured. To measure later:
`GET /me/calendarView?startDateTime=…&endDateTime=…&$top=2&$select=id,createdDateTime,lastModifiedDateTime`
(does a nextLink come back, and are the two dates in the response), the largest `$top`
calendarView takes, and `/me/calendars`' default page size.

## Tests

`ExchangeCalendarPagingTests` (a fake Graph collection served in pages with
`@odata.nextLink`): every event of a window across pages with one `Prefer` header on every page;
the `/events` listing (no window) across pages; a search match on a later page; `maxResults`
counting returned events and reading stopping at the page that reaches it; a page holding more
matches than `maxResults` still returning exactly `maxResults` from one request; cancelled and empty
events on a later page left out; every calendar across pages; a next link off Graph's host refused
(`invalidPageLink`) with no request sent to it; a listing that never ends an error
(`listingIncomplete`) after exactly `maxListPages` requests; the event reads' `$select` free of the
two properties.

## Not changed

`GoogleCalendarProvider.listEvents` also reads one page (`maxResults` is Google's page size and
its `nextPageToken` is not followed); a separate issue, not this one.

## The assistant's read tools name what they could not read (#1293, 2026-11-23)

This holds for every provider, not only Outlook. `CalendarToolHelpers.fetchEventsFromAllCalendars` returns,
beside the events, `unread`: each visible calendar whose `listEvents` threw and each account whose
`listCalendars` threw (`listingIncomplete` and `missingScope` included; the catch is untyped, so no provider
type is named above the provider), sorted. `calendar_read`, `calendar_search` (every page) and
`calendar_event_read` by start time append one line naming them, after their results or in place of their
plain "nothing found" text; `calendar_event_read` by id names an account whose calendars could not be listed
in its scan's error. Nothing is retried. When every calendar is read, every output is exactly what it was.

The text, for the Thunderbird add-on's matching fix (TabMail/tabmail-thunderbird#466) to copy:
- a calendar: `"<calendar name>" (<account address>)`, the name falling back to the calendar id;
- an account: `every calendar of <account address>`;
- the line: `These calendars could not be read, so their events are not listed: <label>; <label>. Tell the user they could not be read; do not say they have no events.`
- the empty texts: `No calendar events found in the requested date range in the calendars that could be read.`,
  `No calendar events found matching '<query>' in the requested date range in the calendars that could be read.`,
  `No entries matched in the calendars that could be read.`, and by id
  `Event not found in the calendars that could be read.` (inside the JSON `error`).

Tests: `CalendarUnreadCalendarTests` (each tool through its entry point, one or more accounts failing).
Not covered by this: `calendar_event_read` by id still skips, without saying so, a calendar whose `getEvent`
fails with an error other than not found, because the scan sends one provider's id to every other provider
and a foreign id often fails that way (Google refuses a CalDAV href, Graph answers 400, CalDAV refuses an
occurrence id), so such a failure cannot be told apart from "not this provider's event".
