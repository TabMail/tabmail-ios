# Calendar oracle generator

Generates the expected occurrences of repeating events that `TabMailTests/Providers/CalendarOracle/`
checks TabMail's own recurrence code against (ADR-IOS-110). Two independent engines expand the same
calendar text: **libical** (C, through its plain C API) and **ical.js** as Thunderbird ships it.
Their answers are committed as fixtures under `TabMailTests/Fixtures/CalendarOracle/`. Neither
engine is linked into the app or run in CI; this runs by hand on a developer Mac.

## Run

```sh
brew install libical          # the version in oracle-lock.json
./Scripts/cal-oracle/generate.sh
./Scripts/xcodegen.sh         # new fixture files are missing from an older generated project
```

`generate.sh` checks the libical and Node versions against `oracle-lock.json`, compiles
`libical-expand.c` and downloads the hash-pinned ical.js into `$TMPDIR/tabmail-cal-oracle/`, runs
`generate.mjs`, and prints `git diff --stat` of the fixtures. Regenerating unchanged inputs on the
same Node build and system zone data gives byte-identical files (no timestamps are written; the
manifest records the Node version and both zone data versions, so a Node update or a macOS zone
data update changes it). Review any fixture diff like code.

## Files

| File | Role |
|---|---|
| `generate.sh` | The one command: preflight, build, fetch, generate. |
| `oracle-lock.json` | libical version, ical.js URL, revision and SHA-256, Node major, generator version. |
| `cases.json` | The corpus inputs, hand-written: id, family, why, references, the VEVENT lines and zones, window, frame, `expect`, whether to emit rule days, and for RFC 5545's own examples the answer the RFC prints. Never an expected output. |
| `resolutions.json` | Written decisions for every case where the engines disagree. |
| `generate.mjs` | Builds each case's calendar text (with the VTIMEZONE libical builds for each zone, its TZID set to the bare IANA name), runs both engines, checks the zone witness and the RFC's printed answer, compares, and writes the family files and the manifest. |
| `libical-expand.c` | `vtimezone <zone>` prints libical's VTIMEZONE; `expand` prints the master's occurrences (`icalcomponent_foreach_recurrence`: its RRULE, RDATE and EXDATE), each changed occurrence, and the rule-only days (`icalrecur_iterator`). libical leaves RECURRENCE-ID merging to the caller, so `generate.mjs` merges them for the libical column. |

Rule-only days (`ruleDays` in a fixture) are generated for the rule-day and split-count suites of a
later slice; no test reads them yet.

## Checks the generator makes

- **Zone witness.** For every zoned occurrence, libical's UTC offset must equal Node's own zone
  data (`Intl`, `process.versions.tz`), and Node must place each ical.js wall time at the instant
  ical.js gives (unless the wall time does not exist, which is an expansion question). A mismatch
  stops the run: pick another date or zone.
- **RFC answer.** Cases with an `rfc` block must expect exactly the days and wall time RFC 5545
  §3.8.5.3 prints.
- **Windows.** A floating or all-day occurrence edge must be at least 26 hours from a window edge,
  so a device in any zone lists the same set.
- **Disagreements.** Equal lists need no decision. Different lists (or rule days) need an entry in
  `resolutions.json`, or the run fails and prints the difference. A decision whose case now agrees
  fails the run too (a stale decision).

## Decisions (`resolutions.json`)

Keyed by case id. Every decision has `why` and `references` (an RFC 5545 section, an ADR of this
repo, an upstream changelog entry or issue, or Google Calendar's behaviour, the reference for what
the user sees), and one of:

- `follows`: `libical` or `icaljs`, the engine whose occurrences the test expects;
- `except`: `{ "yyyy-MM-dd": "<engine>" }`, days (the day the occurrence's slot falls on in the
  series' frame) taken from the other engine;
- `lengthFrom`: the engine whose occurrence length (end less start) is kept on each day, when the
  followed engine places the start right and the end wrong;
- `ruleDays`: the engine whose rule-only days are kept, when those differ;
- `follows: "excluded"` with `issue`: both answers are kept and nothing is asserted.

The manifest lists every disagreement with its decision.

## Dates

Fixture dates are fixed and run from 1896 to 2019 (every event's DTSTAMP is 2020-01-01). This uses
the testing rules' exception for dates far in the past (2020 and earlier): the engines do not run at
test time, so their answers cannot be relative to today. The earliest dates are the century leap
pair, a yearly 29 February series across 1896-1904 (1900 is not a leap year) and 1996-2004 (2000
is). Zoned cases use 1996-2019, settled time-zone history; the Swift suite checks Foundation's zone
data against each fixture offset and reports a difference as zone-data drift, not as an expansion
bug. libical's listing (`icaltime_as_timet`) is defined only from 1902-01-01 and lists nothing for a
window that starts earlier, so such a case needs a written decision that follows ical.js, with
libical's rule-only days as its check.

## Bumping an engine

Change `oracle-lock.json` in its own commit, re-run, then resolve or update the disagreements the
new version changes.
