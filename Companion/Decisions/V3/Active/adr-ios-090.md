## ADR-IOS-090: `web_read` Reads a Page as a User Agent, Without Asking robots.txt

**Status:** Active (2026-10-07)

**Context:** `WebReadTool` (`web_read`) fetched the site's `/robots.txt` before every page and
refused a path it disallowed, a port of the Thunderbird add-on's `web_read.js`. The parser matched
a group only when its `User-agent` was `*` or the exact full user-agent string, not the product
token RFC 9309 §2.2.1 matches (TabMail Voice issue #45), and a later group naming another crawler
cleared the rules already gathered from `*`, so a common file (`*` first, other crawlers after)
lost its general rules. Owner, 2026-10-07: rather than fix the parser, drop the check. robots.txt
is written for crawlers, automatic clients that walk a site; `web_read` fetches one page because
the user asked, as a browser does, and browsers do not consult robots.txt.

**Decision:** `WebReadTool` no longer fetches or parses robots.txt (`checkRobotsTxt`,
`isPathAllowed` and `Config.robotsTimeoutSeconds` deleted, with the `WebReadToolRobotsTests`
suite). It fetches the page alone. The Thunderbird add-on (its ADR-026) and TabMail Voice
(ADR-DESK-030 amendment) drop the check in the same change, keeping the three clients alike
(ADR-IOS-008 parity), and the backend's `web_read` tool description no longer says the tool
respects robots.txt.

**Rationale:** What keeps the tool a good citizen is unchanged: the request names TabMail in its
User-Agent (`TabMail/1.0 (iOS; +https://tabmail.app)`), so a site can see who is asking and block
it; the backend lets the model pass only a URL the user gave or one from an earlier tool result,
never a private address; and each call reads one page, following no links. A broken parser kept in
step across three clients bought little, and its fetch delayed every read by up to 5 s.

**Consequences:**
- A page a site's robots.txt disallows for crawlers is read when the user asks for it.
- One request per read instead of two; no robots.txt timeout before the page.
- `WebReadTool` fetches through `sharedEphemeralSession` with no injectable seam, so the
  "page alone" behaviour has no iOS unit test (no seam was added only for a test); the Thunderbird
  and Voice suites pin it, and the iOS code has no robots path left.
