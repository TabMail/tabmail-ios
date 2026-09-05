# MIS-IOS-019 — I added persistent log writers OUTSIDE the facade its registry test was built to see, by reusing an existing channel's tag

**Class:** design-process (reuse / census — the "check if a similar function exists" rule, applied to a logging facade)
**Severity:** high (three copies of a gating policy shipped to a PR; an always-on channel and debug-gated writers shared one tag; the registry test that exists to catch a sixteenth channel could not see any of the three writers; every new gated body had 0 hits in a 9,437-test suite; unescaped persisted lines could forge another channel's entry)
**First seen:** 2026-09 · **Recurrences:** 1 · **Status:** Active
**Related:** root `MIS-045` (the same PR entered no gate) · `IOS-LOG-002` (the always-on / debug-gated split) · topic 122 (`Companion/Memory/Current/122-one-log-file-per-process.md`, "a new persistent diagnostic channel is a new `AppLogChannel` case and a tag") · `MIS-IOS-016` / root `MIS-014` (tests that never exercise the code they are about) · **Rule owner:** root `CLAUDE.md` § Behavioral Rules ("Before implementing a new function, ALWAYS check if a similar function exists") and § General Development Rules 12 (debug-gated diagnostics)

## The tell

I am about to write `AppLogStore.append(…, channel: .<existing>)` from a file that is not
`BackgroundSyncLogger`, `DeviceSyncLogger` or `AuthDiagnostics` — and the reason I am reaching for
an EXISTING channel is that I want my lines to **interleave** with that channel's lines in the
exported log. The comfort is "same tag, same stream, so the drain and the sync read as one story."

The second half of the tell: the helper I am typing has the shape
`guard DebugModeManager.isLoggingEnabled() else { return }; print(line); AppLogStore.append(line, …)`.
That is the body of every debug-gated facade in `BackgroundSyncLogger`. If I am typing it, a facade
already exists and I have not looked.

## What actually happened

2026-09-04, `tabmail-ios` PR #113 (`4f9bd4bbc`). Instrumentation for `IOS-QUEUE-008` (drain lane
order + sync-side move decisions) needed the drain's `queueLog`, seven `[MoveTrace] deltaSync`
prints and one full-sync inserted-id line to reach the exported `tabmail.log`. I made each of the
three sites its own gated guard/print/append onto `.sync`, because `.sync` is what
`BackgroundSyncLogger.log` writes and I wanted append-order interleaving with it.

What that ignored, all of it already written down in the tree:

- `AppLogStore` is ONE file and `read()` preserves append order across ALL tags. Interleaving never
  required a shared tag; a new channel interleaves for free.
- `.sync` is ALWAYS-ON (`IOS-LOG-002`); the new writers were debug-gated. One tag now meant two
  lifetime policies, and `AppLogStoreTests.everyChannelIsClassifiedExactlyOnce` — the test built to
  make a sixteenth channel visible — could not see any of the three, because they were not
  channels and not facades.
- `AppLogStoreTests.gatedWritersGateTheirPrintToo` scans `BackgroundSyncLogger.swift` only, so three
  copies of the gate lived outside its oracle and could drift independently.
- `AppLogStore`'s header says sender/server-authored spans must pass `escapedForLogLine`; the new
  writers persisted raw `folderPath`, provider errors and header ids, so a `\n[x] [AUTH] …` in any
  of them forged another channel's entry. Console-only prints could not do that; persistence
  could, and the facade precedent (`logChatError`) shows where the escape belongs.
- Because the real gate is always false in the test host and nothing flipped
  `DebugModeManager.loggingEnabledOverrideForTesting`, the full suite executed **zero** of the new
  log bodies. The registry entry would have given locked/unlocked/print-gate coverage for free.

The architecture and robustness-security angles of the (retroactive) review gate each found this
in their first pass. The correction (`b3b4b13c2`) is exactly the shape the tree prescribed:
`AppLogChannel.queue`, one facade `BackgroundSyncLogger.logQueue` owning guard + echo + escape +
append, one row in `debugGatedWriters`, and the three sites reduced to one-line forwarders.

## Why it is not obvious

Interleaving is a real requirement, and "same tag" is the obvious way to get it if you think of the
store as one file per tag — which is what the FIFTEEN files it replaced used to be. The tree's own
history primes the wrong model. And the inline helper compiles, gates correctly, and prints in the
console exactly as intended, so nothing about running it locally says "this is a fourth copy of a
policy that has a registry". The failure is invisible until a test tries to enumerate channels.

## The rule

Never write `AppLogStore.append(` outside the three facade types; a new persistent diagnostic
stream is a new `AppLogChannel` case, a new tag, one facade that owns the gate/echo/escape/append,
and one row in `AppLogStoreTests.debugGatedWriters` (or `alwaysOnWriters`, by owner decision only).

## Mechanical check

```bash
# Must print nothing. Any hit is a writer the channel registry tests cannot see.
rg -n "AppLogStore\.append\(" TabMail/ | rg -v "BackgroundSyncLogger|DeviceSyncLogger|AuthDiagnostics"
# And every debug-gated body needs a test that OPENS the gate — a new
# `guard DebugModeManager.isLoggingEnabled()` in the diff with no test touching
# `loggingEnabledOverrideForTesting` means the suite measures the guard, not the body.
```
