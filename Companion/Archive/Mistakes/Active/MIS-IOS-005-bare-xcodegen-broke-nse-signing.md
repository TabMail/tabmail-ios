# MIS-IOS-005 — I ran `xcodegen generate` and silently killed smart push

**Class:** build-ops
**Severity:** high
**First seen:** 2026 · **Recurrences:** 2 · **Status:** Active
**Rule owner:** `tabmail-ios/CLAUDE.md` § Development Rules 3

## The tell

`project.yml` changed, so the project file needs regenerating. `xcodegen generate` is the obvious,
documented, upstream command and it exits cleanly.

## What actually happened

`./Scripts/xcodegen.sh` is a wrapper that sources `DEVELOPMENT_TEAM` from the gitignored signing
config and exports it so XcodeGen expands `${DEVELOPMENT_TEAM}` into `DevelopmentTeam` in
`TargetAttributes` for **every** target — including the notification service extension.

A bare `xcodegen generate` with the variable unset writes the **literal string**
`"${DEVELOPMENT_TEAM}"`. The NSE is then signed with an invalid profile that the device rejects:
`applekeystored deny file-write-xattr` → SpringBoard `can be modified: 0` → the NSE never launches.
**Smart push silently dies while silent/background push keeps working**, so the app looks healthy.

## Why it is not obvious

The failure is asymmetric and delayed: the build succeeds, the app installs, most push still works.
Only the NSE-dependent path is dead, and nothing in the build log says so.

## The rule

Always `./Scripts/xcodegen.sh`, never a bare `xcodegen generate` — including from fastlane lanes and
`ensure_xcodegen`.

## Mechanical check

```bash
rg -n 'DEVELOPMENT_TEAM' TabMail.xcodeproj/project.pbxproj | rg '\$\{' \
  && echo 'BROKEN — literal var, NSE will not launch'
```

`TabMail.xcodeproj/project.pbxproj` and `xcshareddata/xcschemes/*` are gitignored, so this must be
re-run after every clone and after pulling any change that touches `project.yml`.
