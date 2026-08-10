# IOS-BUILD-002

> Routed from `KNOWN_ISSUES.md` line 1376 during the 2026-08-09 hierarchy split. The exact pre-split source is hash-pinned in [`known-issues-pre-hierarchy-2026-08-09.txt`](../../History/KnownIssues/known-issues-pre-hierarchy-2026-08-09.txt) (`SHA-256 513497704ad37e977e2fb86e4623e956e6f1ca99844122948ff74995dfa9a309`).

- Register classification: `closed-decision`
- Original row SHA-256: `3fb8bb28655d37d65327a3b4c9e043d26a0bbac28aafb65cbc09d4115c0dfab3`

## Status

✅ **CLOSED AS A DECISION (reconfirmed 2026-08-09 for released `v1.7.5`)** — the **SwiftMail dependency is not pinned reproducibly**: `project.yml` pins it by `branch: main`, and `Package.resolved` — the file that would pin the exact revision — is gitignored. **PRE-EXISTING, not introduced by the v3 range**, and **accepted** because the fork is the owner's own repository

## Subsystem and search terms

Build reproducibility; SPM; `project.yml` `packages:`; `branch: main`; `Package.resolved`; `.gitignore:6` `TabMail.xcodeproj/`; XcodeGen; `github.com/TabMail/SwiftMail.git`; supply chain; dependency pinning; `Scripts/xcodegen.sh`

## Full detail

**What is unpinned, verified rather than taken on trust.** `project.yml:36-38` declares `SwiftMail: url: https://github.com/TabMail/SwiftMail.git` / `branch: main` — a MOVING reference. SPM records the concrete revision in `TabMail.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`, and `git check-ignore -v` on that exact path answers **`.gitignore:6:TabMail.xcodeproj/`** — the whole XcodeGen-generated project directory is ignored, so the resolved file is never committed. Consequence: **two clones at the same TabMail commit can build against different SwiftMail revisions**, and nothing in the repository records which one a given build used.

**PRE-EXISTING — THE PIN ITSELF IS BYTE-IDENTICAL TO THE SHIPPED RELEASE.** The claim is about the PIN, so the evidence is scoped to the pin: at both `07a4bb703` and `7c143daa5`, `project.yml` lines 36-38 read exactly `SwiftMail:` / `url: https://github.com/TabMail/SwiftMail.git` / `branch: main`, and the enclosing `packages:` block hashes identically on both sides — `sha1(git show <rev>:project.yml | sed -n '35,48p')` = `975b41c88b33ef77f91b120f34f21a80babff4d6` at each. The branch-pin was therefore **not introduced by the v3 range**.

**Context, not doubt: the FILE did change in the range, and should have.** Blobs `e87c0426cfd30e679deeadbf06cd8de2c883682a` → `1430b669750cc679801a85c6cf23587a1398cf8c`; `git diff 07a4bb703 7c143daa5 -- project.yml` is **29 insertions, 0 deletions**, in two `-U0` hunks (`@@ -121,0 +122,20 @@` and `@@ -123,0 +144,9 @@`) **entirely inside the `TabMailTests` target** — the five `NSEStagingDB`-related source paths and `SWIFT_ACTIVE_COMPILATION_CONDITIONS` `$(inherited) TABMAIL_TESTS` (the `IOS-NSE-005` work). ⚠️ **This row previously recorded that as a failed byte-identity check.** It was not: the round-16 brief asked for WHOLE-FILE identity while the claim only ever needed PIN identity, so the mismatch was manufactured by the predicate, not by the code — `MIS-008`, a diff result is a claim about the QUERY before it is a claim about the tree. The pin did not change.

**The hazard, demonstrated on this machine rather than argued.** Three SwiftMail checkouts exist locally for the same branch-pinned dependency and they are **not** at the same revision: the shared `/tmp/tabmail-dd` derived-data checkout is at **`078a09b83dda6d10d1a772bbcb0fed573b11c3cf`** (2026-07-31, *"Expose MOVE capability detection on IMAPServer and IMAPNamedConnection"*) — the revision `Package.resolved` currently names — while both `DerivedData/` and `DerivedData/round53-receipt/` checkouts sit at **`202dc2d83d5a42ecfa5b41b13f57a6bd105b07d4`** (2026-06-23), **five weeks behind**. A build run against the wrong one compiles a different IMAP implementation than the one the audit read.

**Why it is ACCEPTED rather than fixed.** The fork is the **owner's own repository**, not a third party's: nobody else can push to `main`, so the supply-chain threat model that normally motivates revision pinning (an upstream maintainer force-pushing or a compromised account) does not apply in the usual form. The cost of fixing it is real — un-ignoring one path inside a wholly generated directory, which is exactly the invariant `.gitignore:6` exists to state (*"The whole .xcodeproj is regenerated, so none of it is tracked"*), or moving the pin to a tag/revision in `project.yml` and taking on manual bumps.

**Recoverability, with the non-recovering case named (`MIS-IOS-008`).** An unexpected SwiftMail revision is recoverable: re-resolve, or pin `project.yml` to a revision, and rebuild. **The non-recovering case is diagnostic, not operational** — a field bug reproduced against an unknown SwiftMail revision cannot be bisected, because the repository does not record which revision the build used. That is a debugging cost, not data loss, no dropped intention and no wrong-message mutation, which is why it fails closed and is registered rather than mechanised (THE MANTRA).

**v1.7.5 RELEASE OBSERVATION (2026-08-09).** The accepted hazard has now materialized as a release fact rather than only a hypothetical: `project.yml` still names `branch: main`; the ignored local `Package.resolved` used for the release currently names SwiftMail `4a409fe8a45a29ea54492d7146b60543acaeb7fe`; and remote `TabMail/SwiftMail` `main` resolved to that same commit when this census ran. The signed `v1.7.5` tag does **not** record that revision, so a future reader cannot derive it from the release commit after `main` advances. This remains CLOSED AS A DECISION by the owner's explicit preference for the simple owned-branch workflow, but the diagnostic cost is now concrete.

**What would re-open this row:** the SwiftMail fork gaining a second person with push access to `main`; the local resolver disagreeing with remote `main` during a release; or an IMAP defect that cannot be bisected because the shipped SwiftMail revision is unknown. Then the minimal remedy is to pin `project.yml` by `revision:` or by a signed tag — **not** to un-ignore a file inside the generated `.xcodeproj`.

⚠️ **Deliberately NOT re-opened by this row, and listed so a future reader does not re-litigate them:** SwiftMail's `move` COPY+STORE+bare-EXPUNGE fallback (**zero** TabMail production call sites; `IMAPProvider.swift` documents it as an owner-decided trade), `server.expunge(messages:)` failing closed without UIDPLUS, and `CopyUID.init(nio:)` / `CopyUID.expand` throwing on cardinality mismatch, inverted range and the 1,000,000-UID cap. All three are closed.
