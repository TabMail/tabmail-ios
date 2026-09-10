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
