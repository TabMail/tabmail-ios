#!/usr/bin/env bash
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.
#
# Regenerates the calendar oracle fixtures (ADR-IOS-110). Run by hand on a developer Mac,
# never in the app or in CI:
#
#   ./Scripts/cal-oracle/generate.sh
#
# Needs Homebrew libical (the version in oracle-lock.json), Node (the major in the lock) and a
# C compiler. It builds libical-expand and fetches the hash-pinned ical.js into
# $TMPDIR/tabmail-cal-oracle/; nothing lands in the repo except the fixtures.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
lock="$here/oracle-lock.json"
fixtures="$repo/TabMailTests/Fixtures/CalendarOracle"
work="${TMPDIR:-/tmp}/tabmail-cal-oracle"

lock_value() {
  node -e 'const l = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")); console.log(process.argv[2].split(".").reduce((v, k) => v[k], l))' "$lock" "$1"
}

refuse() {
  echo "generate.sh: $*" >&2
  exit 1
}

command -v cc >/dev/null || refuse "no C compiler (cc)"
command -v node >/dev/null || refuse "no node"
command -v brew >/dev/null || refuse "no Homebrew (libical comes from its bottle)"

node_major="$(node -p 'process.versions.node.split(".")[0]')"
[[ "$node_major" == "$(lock_value node.major)" ]] || refuse "Node $node_major, the lock wants $(lock_value node.major)"

# Homebrew's libical needs its keg-only ICU on the pkg-config path.
PKG_CONFIG_PATH="$(brew --prefix "$(lock_value libical.icuFormula)")/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
export PKG_CONFIG_PATH
libical_version="$(pkg-config --modversion libical)" || refuse "libical not found (brew install libical)"
[[ "$libical_version" == "$(lock_value libical.version)" ]] || refuse "libical $libical_version, the lock wants $(lock_value libical.version)"

mkdir -p "$work"
# shellcheck disable=SC2046 # pkg-config prints separate flags
cc -Wall -Wextra -Werror -O1 -o "$work/libical-expand" "$here/libical-expand.c" $(pkg-config --cflags --libs libical)

icaljs="$work/Ical.sys.mjs"
want="$(lock_value icaljs.sha256)"
if [[ ! -f "$icaljs" ]] || [[ "$(shasum -a 256 "$icaljs" | cut -d' ' -f1)" != "$want" ]]; then
  curl -sSfL -o "$icaljs" "$(lock_value icaljs.url)"
fi
got="$(shasum -a 256 "$icaljs" | cut -d' ' -f1)"
[[ "$got" == "$want" ]] || refuse "ical.js SHA-256 $got, the lock wants $want"

# libical reads the system zoneinfo; its version goes into the fixtures.
CAL_ORACLE_SYSTEM_TZDATA="$(cat /usr/share/zoneinfo/+VERSION)"
export CAL_ORACLE_SYSTEM_TZDATA

node "$here/generate.mjs" "$work" "$fixtures"
git -C "$repo" diff --stat -- "$fixtures"
