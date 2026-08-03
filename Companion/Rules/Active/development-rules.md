<!-- COMPANION-CURRENT-NOTE-BEGIN -->
> **Current routing note:** Post-compaction amendment; this current rule supersedes the frozen numbered list below.

8. **Sole build-warning exception** — The zero-warning rule has exactly one benign exception: `warning: Metadata extraction skipped. No AppIntents.framework dependency found.` from Xcode's `ExtractAppIntentsMetadata` phase for a target that intentionally does not link AppIntents.framework. Do not suppress or skip the phase to hide it. Every build gate must still count and report each occurrence. Every other warning remains a hard failure; changed diagnostic text or the same diagnostic on a target that links AppIntents.framework is not covered.
<!-- COMPANION-CURRENT-NOTE-END -->
## Development Rules

1. **SwiftUI + GRDB** — All new UI in SwiftUI. Data persistence via GRDB (`AppDatabase.swift` manages migrations and `DatabasePool`).
2. **Swift language** — All code in Swift.
3. **XcodeGen** — Project file generated from `project.yml`. Do not edit `.xcodeproj` directly. **`TabMail.xcodeproj/project.pbxproj` and `xcshareddata/xcschemes/*` are gitignored** — after `git clone` (or pulling changes that touch `project.yml`), run **`./Scripts/xcodegen.sh`** (NOT a bare `xcodegen generate`) before opening Xcode. The wrapper sources `DEVELOPMENT_TEAM` from gitignored `Secrets.xcconfig` and exports it so XcodeGen expands `${DEVELOPMENT_TEAM}` (in `project.yml` `settings.base`) into `DevelopmentTeam` in `TargetAttributes` for **every** target — including the NSE (`TabMailNotificationService`). A bare `xcodegen generate` with the var unset writes a literal `"${DEVELOPMENT_TEAM}"` and breaks signing; an NSE with no resolved team is signed with an invalid profile the device rejects (`applekeystored deny file-write-xattr` → SpringBoard `can be modified: 0` → the NSE never launches, so smart push silently dies while silent/background push still works). Fastlane lanes / `ensure_xcodegen` must call `./Scripts/xcodegen.sh`.
4. **Secrets in Secrets.xcconfig** — OAuth client IDs, API keys, etc. are in `Secrets.xcconfig` (gitignored). Loaded via `project.yml` configFiles → exposed in `Info.plist` → read at runtime.
5. **IMAP/SMTP via SwiftMail fork** — Use the SwiftMail fork (`github.com/TabMail/SwiftMail`, BSD-2-Clause, pinned in `project.yml`) for mail protocol operations. Do not add other IMAP/SMTP libraries.
6. **Modularization** - If a single code becomes longer than 500 lines, consider whether there are modularization opportunities for easy maintenance and upgrade.
7. **Code reuse** - Make sure to check if a similar function exists before you implement a function so that we do NOT have multiple re-implementations of the same function.

---
