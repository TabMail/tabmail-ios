#!/bin/sh
# Generate the Xcode project with code signing wired up.
#
# DEVELOPMENT_TEAM is intentionally kept OUT of the public repo. It lives in the
# gitignored Secrets.xcconfig (every dev creates it from Secrets.xcconfig.example).
# project.yml references it as ${DEVELOPMENT_TEAM}; this wrapper sources that one
# value and exports it so XcodeGen writes DevelopmentTeam into TargetAttributes for
# ALL targets — including the Notification Service Extension (TabMailNotificationService).
#
# Why this matters: if the extension's TargetAttributes has no resolved team, its
# .appex is signed without a usable team/profile, the device rejects its signature
# (applekeystored "deny file-write-xattr"), and SpringBoard marks mutable-content
# pushes "can be modified: 0" — so the NSE is never launched and smart push silently
# dies (silent/background pushes still work because they wake the main app).
#
# ALWAYS run this instead of a bare `xcodegen generate`: with the var unset, XcodeGen
# writes the literal string "${DEVELOPMENT_TEAM}" into the project and breaks signing
# for every target. This wrapper always exports the var (empty if absent), so the
# worst case is a clean empty team that Xcode prompts you to fill in.
set -eu

cd "$(dirname "$0")/.."

team=""
if [ -f Secrets.xcconfig ]; then
  team="$(awk -F= '/^[[:space:]]*DEVELOPMENT_TEAM[[:space:]]*=/{gsub(/[[:space:]]/,"",$2); print $2; exit}' Secrets.xcconfig)"
fi

if [ -z "$team" ]; then
  echo "warning: DEVELOPMENT_TEAM not found in Secrets.xcconfig — generating with an empty team." >&2
  echo "         Set DEVELOPMENT_TEAM in Secrets.xcconfig (see Secrets.xcconfig.example)," >&2
  echo "         or pick a team in Xcode > Signing & Capabilities after generating." >&2
fi

export DEVELOPMENT_TEAM="$team"
exec xcodegen generate "$@"
