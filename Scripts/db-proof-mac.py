#!/usr/bin/env python3
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.
"""Measure a database proof's old and new statements with the Mac's own sqlite3.

Usage:
  python3 -I Scripts/db-proof-mac.py <unit-directory> [--repeats N] [--sqlite3 PATH]
  python3 -I Scripts/db-proof-mac.py --self-test

<unit-directory> is the directory a DBProof.compare run wrote (TabMailTests, helper
DBProofHarness.swift): it holds manifest.json and the prepared database files, one per
mode, statistics state and side. For every entry this runs the old and the new
statements with `sqlite3` and `.stats on`, each run a new sqlite3 process (so a cold
page cache), one warm-up each and then old and new interleaved. A write entry runs on
an APFS clone of its file per run, inside BEGIN ... COMMIT. It writes report-mac.txt
next to the manifest and prints it.

Counters (summed over the statements of a run): pages read = "Page cache misses",
pages written = "Page cache writes", VM steps, full-scan steps, sorts, automatic-index
inserts. Time is the sum of the shell's "Run Time: real". Noise is the spread
(p90 - p10) of the repeated old runs.
"""

import argparse
import json
import math
import os
import subprocess
import sys
import tempfile
import uuid

COUNTERS = {
    "Page cache misses": "pages read",
    "Page cache writes": "pages written",
    "Virtual Machine Steps": "VM steps",
    "Fullscan Steps": "full-scan steps",
    "Sort Operations": "sorts",
    "Autoindex Inserts": "autoindex inserts",
}
STATISTICS_LABELS = {"none": "no sqlite_stat1", "analyzed": "after the app's ANALYZE"}
DEFAULT_SQLITE3 = "sqlite3"


def remove_database_files(path):
    for suffix in ("", "-wal", "-shm"):
        if os.path.exists(path + suffix):
            os.remove(path + suffix)


def run_once(sqlite3, path, kind, statements):
    """One run in a new sqlite3 process; returns the summed counters and the time."""
    target = path
    scratch = None
    if kind == "write":
        scratch = os.path.join(os.path.dirname(path), "run-%s.sqlite" % uuid.uuid4().hex)
        subprocess.run(["cp", "-c", path, scratch], check=True)
        target = scratch
    body = [s.strip().rstrip(";") + ";" for s in statements]
    if kind == "write":
        body = ["BEGIN;"] + body + ["COMMIT;"]
    # The app's connection settings first, before the counters start.
    script = ["PRAGMA synchronous = NORMAL;", "PRAGMA wal_autocheckpoint = 0;",
              ".mode off", ".stats on", ".timer on"] + body
    try:
        completed = subprocess.run([sqlite3, "-bail", target], input="\n".join(script) + "\n",
                                   capture_output=True, text=True, check=False)
    finally:
        if scratch:
            remove_database_files(scratch)
    if completed.returncode != 0:
        raise RuntimeError("sqlite3 failed on %s: %s" % (path, completed.stderr.strip()))
    cost = {name: 0 for name in COUNTERS.values()}
    cost["ms"] = 0.0
    for line in completed.stdout.splitlines():
        if line.startswith("Run Time: real "):
            cost["ms"] += float(line.split()[3]) * 1000.0
            continue
        key, separator, value = line.partition(":")
        name = COUNTERS.get(key.strip())
        if name and separator and value.split():
            cost[name] += int(value.split()[0])
    return cost


def percentile(values, p):
    ordered = sorted(values)
    if not ordered:
        return 0.0
    rank = int(math.ceil(p * len(ordered))) - 1
    return ordered[min(max(rank, 0), len(ordered) - 1)]


def time_verdict(old_ms, new_ms):
    old_median, new_median = percentile(old_ms, 0.5), percentile(new_ms, 0.5)
    spread = percentile(old_ms, 0.9) - percentile(old_ms, 0.1)
    if new_median > old_median + spread:
        return "SLOWER"
    if new_median < old_median - spread:
        return "faster"
    return "within noise"


def row(label, old, new, verdict):
    return label.ljust(20) + old.rjust(12) + new.rjust(12) + "  " + verdict


def measure_entry(sqlite3, entry, repeats):
    """Returns (old runs, new runs), or None when a side is a Swift body only."""
    sides = (entry["old"], entry["new"])
    if any(side.get("swiftOnly") or not side.get("sql") for side in sides):
        return None
    for side in sides:  # warm-up
        run_once(sqlite3, side["file"], entry["kind"], side["sql"])
    old_runs, new_runs = [], []
    for _ in range(repeats):
        old_runs.append(run_once(sqlite3, sides[0]["file"], entry["kind"], sides[0]["sql"]))
        new_runs.append(run_once(sqlite3, sides[1]["file"], entry["kind"], sides[1]["sql"]))
    return old_runs, new_runs


def block(entry, measured):
    label = STATISTICS_LABELS.get(entry["statistics"], entry["statistics"])
    lines = ["== %s (%s), %s" % (entry["mode"], entry["kind"], label)]
    if measured is None:
        lines.append("simulator only: a side is a Swift body with no SQL")
        return lines + [""]
    old_runs, new_runs = measured
    old_ms = [r["ms"] for r in old_runs]
    new_ms = [r["ms"] for r in new_runs]
    lines.append(row("", "old", "new", "verdict"))
    lines.append(row("median ms", "%.3f" % percentile(old_ms, 0.5), "%.3f" % percentile(new_ms, 0.5),
                     time_verdict(old_ms, new_ms)))
    lines.append(row("p90 ms", "%.3f" % percentile(old_ms, 0.9), "%.3f" % percentile(new_ms, 0.9), ""))
    lines.append(row("old spread ms", "%.3f" % (percentile(old_ms, 0.9) - percentile(old_ms, 0.1)), "", ""))
    for name in COUNTERS.values():
        old_values = sorted(r[name] for r in old_runs)
        new_values = sorted(r[name] for r in new_runs)
        old_median = old_values[len(old_values) // 2]
        new_median = new_values[len(new_values) // 2]
        verdict = "MORE" if new_median > old_median else ("fewer" if new_median < old_median else "same")
        if old_values[0] != old_values[-1] or new_values[0] != new_values[-1]:
            verdict += " (varied between runs)"
        lines.append(row(name, str(old_median), str(new_median), verdict))
    return lines + [""]


def sqlite_version(sqlite3):
    return subprocess.run([sqlite3, "--version"], capture_output=True, text=True,
                          check=True).stdout.split()[0]


def run_unit(unit_directory, repeats=None, sqlite3=DEFAULT_SQLITE3):
    with open(os.path.join(unit_directory, "manifest.json"), encoding="utf-8") as handle:
        manifest = json.load(handle)
    repeats = repeats or manifest["repeats"]
    lines = [
        "Database proof: %s" % manifest["unit"],
        "Side: Mac (host sqlite3 %s, synchronous NORMAL, autocheckpoint off)" % sqlite_version(sqlite3),
        "Runs: %d timed per variant after one warm-up, old and new interleaved, each a new sqlite3 process."
        % repeats,
        "Noise: the spread (p90 - p10) of the repeated old runs. Pages and rows visited compare exactly.",
        "",
    ]
    for entry in manifest["entries"]:
        lines.extend(block(entry, measure_entry(sqlite3, entry, repeats)))
    text = "\n".join(lines)
    with open(os.path.join(unit_directory, "report-mac.txt"), "w", encoding="utf-8") as handle:
        handle.write(text)
    return text


def self_test(sqlite3=DEFAULT_SQLITE3):
    """Builds a small database with sqlite3 and checks the counters tell a scan from a
    seek and a wide write from a narrow one, and that a write leaves its file alone."""
    with tempfile.TemporaryDirectory(prefix="dbproof-mac-") as directory:
        base = os.path.join(directory, "base.sqlite")
        rows = 5000
        setup = "\n".join([
            "CREATE TABLE t(id INTEGER PRIMARY KEY, a TEXT, b INTEGER);",
            "WITH RECURSIVE s(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM s WHERE n < %d)" % rows,
            "INSERT INTO t SELECT n, printf('text %d', n), n % 7 FROM s;",
            "CREATE INDEX t_b ON t(b);",
            "PRAGMA journal_mode = WAL;",
        ])
        subprocess.run([sqlite3, base], input=setup + "\n", capture_output=True, text=True, check=True)
        unit = os.path.join(directory, "self-test")
        os.makedirs(unit)
        manifest = {"unit": "self-test", "repeats": 2, "entries": [
            {"mode": "scan vs seek", "kind": "read", "statistics": "none",
             "old": {"file": base, "sql": ["SELECT id FROM t WHERE a LIKE '%99%'"], "swiftOnly": False},
             "new": {"file": base, "sql": ["SELECT id FROM t WHERE id = 42"], "swiftOnly": False}},
            {"mode": "wide vs narrow write", "kind": "write", "statistics": "none",
             "old": {"file": base, "sql": ["UPDATE t SET b = b + 1"], "swiftOnly": False},
             "new": {"file": base, "sql": ["UPDATE t SET b = b + 1 WHERE id = -1"], "swiftOnly": False}},
            {"mode": "swift only", "kind": "read", "statistics": "none",
             "old": {"file": base, "sql": [], "swiftOnly": True},
             "new": {"file": base, "sql": [], "swiftOnly": True}},
        ]}
        with open(os.path.join(unit, "manifest.json"), "w", encoding="utf-8") as handle:
            json.dump(manifest, handle)

        def total():
            return subprocess.run([sqlite3, base, "SELECT sum(b) FROM t;"], capture_output=True,
                                  text=True, check=True).stdout.strip()

        before = total()
        scan_old, seek_new = measure_entry(sqlite3, manifest["entries"][0], 2)
        wide_old, narrow_new = measure_entry(sqlite3, manifest["entries"][1], 2)
        report = run_unit(unit, sqlite3=sqlite3)
        failures = []

        def check(condition, message):
            if not condition:
                failures.append(message)

        check(scan_old[0]["full-scan steps"] >= rows - 1, "a scan visits every row: %r" % scan_old[0])
        check(seek_new[0]["full-scan steps"] == 0, "a seek has no full-scan steps: %r" % seek_new[0])
        check(seek_new[0]["pages read"] > 0, "the page counter counts: %r" % seek_new[0])
        check(scan_old[0]["pages read"] > seek_new[0]["pages read"], "a scan reads more pages")
        check(scan_old[0]["pages read"] == scan_old[1]["pages read"], "every run is as cold")
        check(wide_old[0]["pages written"] > narrow_new[0]["pages written"], "a wide write writes more pages")
        check(total() == before, "a write runs on a clone and leaves the file alone")
        check(not [n for n in os.listdir(directory) if n.startswith("run-")], "no clone is left behind")
        check(measure_entry(sqlite3, manifest["entries"][2], 2) is None, "a Swift-only entry is skipped")
        for heading in ("== scan vs seek (read), no sqlite_stat1", "== wide vs narrow write (write)",
                        "simulator only", "pages read", "full-scan steps", "median ms"):
            check(heading in report, "report has %r" % heading)
        check(os.path.exists(os.path.join(unit, "report-mac.txt")), "report-mac.txt is written")
        if failures:
            print("self-test FAILED:\n  " + "\n  ".join(failures))
            return 1
        print("self-test OK")
        return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("unit_directory", nargs="?")
    parser.add_argument("--repeats", type=int)
    parser.add_argument("--sqlite3", default=DEFAULT_SQLITE3)
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        return self_test(args.sqlite3)
    if not args.unit_directory:
        parser.error("a unit directory (holding manifest.json) is required")
    print(run_unit(args.unit_directory, args.repeats, args.sqlite3))
    return 0


if __name__ == "__main__":
    sys.exit(main())
