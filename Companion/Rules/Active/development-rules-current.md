# Development Rules — current text (routed out of `CLAUDE.md`)

**Status:** Active/current. Routed out of `CLAUDE.md` (working tree, 2026-08-05 companion-compact
pass), source lines 28–40, byte-for-byte — nothing below is reworded, merged, or truncated. This
is the CURRENT text; the `0bcc851` pre-compaction snapshot of the same section is the pinned
fragment `Companion/Rules/Active/development-rules.md` and the two differ. `CLAUDE.md` keeps a
keyword index row pointing here; where the index and this file differ, **this file wins**.

---

## Development Rules

1. **SwiftUI + GRDB** — All new UI in SwiftUI. Data persistence via GRDB (`AppDatabase.swift` manages migrations and `DatabasePool`).
2. **Swift language** — All code in Swift.
3. **XcodeGen** — Project file generated from `project.yml`. Do not edit `.xcodeproj` directly. **`TabMail.xcodeproj/project.pbxproj` and `xcshareddata/xcschemes/*` are gitignored** — after `git clone` (or pulling changes that touch `project.yml`), run **`./Scripts/xcodegen.sh`** (NOT a bare `xcodegen generate`) before opening Xcode. The wrapper sources `DEVELOPMENT_TEAM` from gitignored `Secrets.xcconfig` and exports it so XcodeGen expands `${DEVELOPMENT_TEAM}` (in `project.yml` `settings.base`) into `DevelopmentTeam` in `TargetAttributes` for **every** target — including the NSE (`TabMailNotificationService`). A bare `xcodegen generate` with the var unset writes a literal `"${DEVELOPMENT_TEAM}"` and breaks signing; an NSE with no resolved team is signed with an invalid profile the device rejects (`applekeystored deny file-write-xattr` → SpringBoard `can be modified: 0` → the NSE never launches, so smart push silently dies while silent/background push still works). Fastlane lanes / `ensure_xcodegen` must call `./Scripts/xcodegen.sh`.
4. **Secrets in Secrets.xcconfig** — OAuth client IDs, API keys, etc. are in `Secrets.xcconfig` (gitignored). Loaded via `project.yml` configFiles → exposed in `Info.plist` → read at runtime.
5. **IMAP/SMTP via SwiftMail fork** — Use the SwiftMail fork (`github.com/TabMail/SwiftMail`, BSD-2-Clause, pinned in `project.yml`) for mail protocol operations. Do not add other IMAP/SMTP libraries.
6. **Modularization** - If a single code becomes longer than 500 lines, consider whether there are modularization opportunities for easy maintenance and upgrade.
7. **Code reuse** - Make sure to check if a similar function exists before you implement a function so that we do NOT have multiple re-implementations of the same function.
8. **Sole build-warning exception** — The zero-warning rule has exactly one benign exception: `warning: Metadata extraction skipped. No AppIntents.framework dependency found.` from Xcode's `ExtractAppIntentsMetadata` phase for a target that intentionally does not link AppIntents.framework. Do not suppress or skip the phase to hide it. Every build gate must still count and report each occurrence. Every other warning remains a hard failure; changed diagnostic text or the same diagnostic on a target that links AppIntents.framework is not covered.

   > **Scope, stated negatively because this exemption is the ONLY one and widening it silently permits real warnings.** It does **not** cover: a different diagnostic from the same phase; the same text with any wording change; the same text on a target that *does* link AppIntents.framework; any other target's metadata warnings; or "warnings that look benign". It is not a licence to pass a build gate with an uncounted warning — an unreported occurrence is a failed gate even though the warning itself is allowed. This is the exception the global `CLAUDE.md` Code Quality rule 6 points at; that rule delegates the definition here, so this text is the definition.

