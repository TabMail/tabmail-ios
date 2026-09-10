# SwiftMail upstream synchronization and the parked oversized-metadata train

## Status checked 2026-09-09

SwiftMail upstream main is `64a9a861de7558733cae4e51be6fedcdb128dc4f`. Synchronization to this candidate is BLOCKED by reproduced receive-path compatibility regressions; neither fork main nor the app pin was changed.

The three contributions on the old combined fork pin `3a904d8a5257162cc3935ab0090bc94333dc8022` were incorporated upstream on September 7:

- Header/address encoding: #215 → #226.
- MIME parameter encoding/parsing: #216 → #230.
- Validated partial IMAP fetching: #219 → #228.

The replacement branches retained our original commits and added maintainer fixes. SwiftMail's latest published release is 1.11.0, which predates those merges. The app and notification extension share the exact `packages.SwiftMail.revision` in `project.yml`; changing the fork alone does not change the app dependency.

## Separate upstream release dependency

Draft iOS #103 and issue #74 remain parked. Apple swift-nio-imap #849 merged on September 9 as `26a69caf8487bc91da4fd10aaa119776b526e18c`, exposing `IMAPClientHandler.maximumBufferSize`. The latest tag, 0.4.0, does not contain this commit. SwiftMail at the candidate above still calls `IMAPClientHandler(parserOptions:)` without the new argument and retains its existing literal-limit restriction.

Wait for a containing NIO IMAP release, then SwiftMail adoption and effective limit wiring with fragmented-response tests. Do not file a duplicate implementation of #849 or treat partial-body fetching as a solution to the separate non-streaming metadata limit. The #849 description mentions a 1 MiB default, but the inspected source still defaults through `IMAPDefaults.lineLengthLimit`, defined as 8,192; use source and executable evidence when integrating.

Issue #10's header/MIME acceptance criterion is satisfied; its app synchronization and verification criteria remain separate. Issue #9 concerns pipelined-FETCH promise cleanup, not this NIO IMAP release dependency.

## Migration and resume boundary

Do not reserve a migration number or edit migration code while parked. When #103 resumes, choose the next free number from then-current main, update migration tests and the foreign-key-mode census, and account for development databases that ran the old draft before launching it. Earlier instructions prescribing a specific replacement number are superseded. No migration execution, reset, rebase, or release is part of the housekeeping scope.

Reconcile the shipped #105 `bodyMetadataOversized` admission state with the bounded-fetch recovery path. Reassess both metadata-overflow catches and the part-fetch classifier: fragmentation-dependent metadata overflow is not a deterministic unsupported-part response. Fresh integration validation is required before #103 becomes ready.

## Sources

- https://github.com/Cocoanetics/SwiftMail/pull/226
- https://github.com/Cocoanetics/SwiftMail/pull/230
- https://github.com/Cocoanetics/SwiftMail/pull/228
- https://github.com/apple/swift-nio-imap/pull/849
- https://github.com/TabMail/tabmail-ios/pull/103
- https://github.com/TabMail/tabmail-ios/issues/74
- https://github.com/TabMail/tabmail-ios/issues/10

## Candidate validation and hold

The independent dependency review covered all twelve incoming commits. Architecture was clean; correctness, robustness/security, and test coverage were unclean. No clean gate is claimed. SwiftMail build and strict lint passed (zero lint violations); 619 tests in 77 suites passed. Four CLI logging deprecation diagnostics also occur on the exact baseline. No iOS app/NSE build or device test was run because the collision check blocked adoption.

Reproduced against the exact old app pin and candidate, using unchanged app parsing/rendering helpers:

- Parsed raw `.eml` display names now remain RFC 2047 encoded in app output. Message addresses and body remain intact, so this is a display/index-text representation collision, not a wrong-recipient claim.
- Extended filenames with omitted charset or ASCII values labeled Windows-1252/ISO-8859-15 are discarded and become generated names; attachment bytes remain intact.
- MIME continuation parsing repeatedly scans the full header for each numbered segment. An optimized synthetic 72,635-byte header took 8.08 seconds versus 0.031 seconds on the baseline; a 146,363-byte case exceeded 25 seconds. Full MIME parsing was separately shown to reach the expensive path. Device timing was not measured.

The coordinator independently reran the name/filename assertions (baseline passes, candidate fails; payload/address/subject controls pass) and the 1,024-segment optimized workload (candidate approximately 0.48 seconds versus baseline 0.007 seconds). Retrying successful parsing does not repair either metadata loss or excessive work. Holding the dependency advance preserves the current consumer behavior and the draft's existing partial-fetch API without introducing a fork deviation.

Further acceptance-test gaps were reported for the actual installed reconnect callback and SMTP refusal-reason collection. These are coverage gaps, not reproduced runtime failures. Keep current pins pending a decision on focused upstream fixes and any required app display adaptation; do not advance the fork based solely on the passing library suite.

## Fixes prepared 2026-09-09 (owner decision: upstream PR for the library bugs, app-side decode for the display-name change)

Root causes, from the B→C source diff rather than the report's symptoms:

- **R1 (quadratic continuation parsing) and C2 (lost filenames) are both regressions introduced by upstream #230**, the maintainer's parameter-boundary hardening. Neither exists at the pinned baseline `a2d4a94f`, which had no RFC 2231 continuation support at all and decoded `filename*` with no charset check. #230's new `extendedContinuation` looked each numbered section up with `extractHeaderParam`, which re-tokenizes the whole header per call (N sections → ~2N full scans). Its new `decodeExtendedBytes` whitelisted `utf-8`/`us-ascii`/`iso-8859-1` and returned nil for every other label including the blank one that RFC 2231 §4 explicitly permits. The tests added with #230 cover only UTF-8-labelled happy paths and the injection cases, so the maintainer's suite stays green.
- **C1 (encoded display names) is a deliberate contract change in upstream #226**, not a bug: parsed addresses stay in header wire form. The app must decode at its own boundary.

What was done:

- **SwiftMail fix**, branch `fix/rfc2231-extended-parameters` on the fork, based on upstream `64a9a86`, one commit: the header is tokenized once into `EMLParser.parameters(of:)` and both the lookup and the continuation collector read from that list; RFC 2231 §3 section rules (decimal from 0, no leading zeroes, no gaps, first duplicate wins) are applied; a blank charset decodes as UTF-8 and any other label resolves through Foundation's `String.Encoding(ianaCharsetName:)`, the lookup the encoded-word decoder already uses; unknown labels still yield nil and fall through to the literal spelling. The RFC 2231 helpers moved to `EMLParser+RFC2231.swift` for the lint file-length limit. 624 tests pass; strict lint clean; the blank-charset, platform-charset and 4,096-section linear-work tests are red on unmodified upstream (the last after 34 s in a debug build). Upstream PR target: `Cocoanetics/SwiftMail`, head `TabMail:fix/rfc2231-extended-parameters`.
- **App-side C1 fix** in `EmlParsing.parse`: `RFC5322Parse.decodeRFC2047` is applied to subject, from, to and cc before they reach `EmlMarker`. The decoder is a no-op on text without an encoded-word, so it is correct against both the current pin (which decodes in the library) and the candidate (which does not). Consumer test `parseDecodesEncodedDisplayNames` in `EmlParsingTests`.
- **Red/green for C1 against the fixed candidate** was reproduced with the housekeeping consumer-probe harness (`LOCAL_SWIFTMAIL_HOUSEKEEPING_20260909/compile-probe.py`, compiled against the fixed SwiftMail build): with the pre-fix `EmlParsing`, `htmlContainsDecodedNames` is false and From/To/Cc carry `=?UTF-8?B?…?=`; with the fixed `EmlParsing`, all names decode and addresses are retained. In the same run every `filename*` charset variant (`UTF-8`, `us-ascii`, `iso-8859-1`, `windows-1252`, `iso-8859-15`, blank) projects `invoice.pdf`, closing C2. Evidence: `LOCAL_SWIFTMAIL_HOUSEKEEPING_20260909/fix-evidence/` (local, excluded from git).

Still required before the pin advances: upstream merge of the fix (or a fork-local deviation carrying it, which the sync skill then replays on every resync), then the fork-sync skill's reset/re-pin, then the iOS validations listed in the housekeeping report (app + NSE build via `Scripts/xcodegen.sh`, the consumer suites, real-provider EHLO acceptance for #229). `IOS-IMAP-016`'s "when revisited" items 1–3 appear to be delivered by #226/#230; verify against the final pinned source before closing that record.
