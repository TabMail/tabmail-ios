# IOS-IMAP-015

> **Post-freeze record.** Added 2026-08-12, after the 2026-08-09 hierarchy freeze, through the
> amendment surface in `Scripts/compact_known_issues.rb`. It has no row in
> `known-issues-pre-hierarchy-2026-08-09.txt` and is deliberately not regenerated from that archive.

- Register classification: `open`
- Disposition: 🔓 **OPEN (2026-08-12; re-audited 2026-08-15)** — deferred by the owner: "this
  could be something we fix, but not now". The only code remedy belongs upstream in
  Cocoanetics/SwiftMail and has not been authorised as an upstream PR.

## Status

🔓 **OPEN — one narrow upstream cleanup gap, with debug/test impact only.**
`IMAPConnection.pipelinedFetchPartsBody` creates every part promise, then installs its dispatcher
before entering the catch that fails those promises. If that install throws, debug/test builds abort
when the unfulfilled promises deallocate; a truncated test run can still report "passed". The error
itself reaches the app, no release caller awaits the orphaned futures, and the existing body-queue
failure path retries; the production closed-channel case releases that connection as unhealthy.

## Subsystem and search terms

SwiftMail; SwiftNIO; `IMAPConnection+PipelinedFetch`; `makePromise`; `PipelinedFetchPartHandler`;
`PipelinedCommandDispatcher`; dispatcher install; `debugOnly`; `EventLoopFuture` deinit; false green;
truncated test run; exit 65; `NeverDropExitClosureTests`; test count regression

## Full detail

**Symptom.** During test runs, non-deterministically (measured ~1 run in 3 on
`NeverDropExitClosureTests`):

```
SwiftMail/IMAPConnection+PipelinedFetch.swift:197: Fatal error: leaking promise created at ...
```

**Why the diagnostic's `file:line` is misleading.** It identifies the creation expression inside
`IMAPConnection.registerPipelinedFetchRequests`, not the trap. That loop creates one promise per
pipelined FETCH part and hands it to a `PipelinedFetchPartHandler`; the fatal check is elsewhere.

The `fatalError` is in **SwiftNIO**, in `EventLoopFuture.deinit`: with assertions enabled, an
unfulfilled promise traps and reports its creation site. The exact unresolved path is now proved:

1. `IMAPConnection.pipelinedFetchPartsBody` passes its active-channel guard.
2. `registerPipelinedFetchRequests` creates all part promises and handlers.
3. `channel.pipeline.addHandler(dispatcher, position: .before(responseBuffer)).get()` throws. In
   production the channel can close in the guard-to-install window; the focused proof omitted the
   relative handler. The invariant is that any install failure unwinds here.
4. The function unwinds before it schedules the timeout or enters the command-dispatch catch, so
   none of the newly registered handlers is failed.

This is the only throw between promise creation and the first promise-resolving catch.

**Why production cannot hang on these futures, stated structurally.** The install error is thrown out
of `pipelinedFetchPartsBody` before `drainPipelinedFetchFutures` is entered. No consumer ever calls
`.get()` on the unresolved futures from this exit; they deallocate during unwinding, and the caller
receives the install error. Release builds also compile NIO's `debugOnly` deinit trap out, but that is
the weaker bound: even with assertions ignored, there is no awaiting continuation on this path.

Every exit that does reach the drain is already covered: the scheduled batch timeout,
`PipelinedCommandDispatcher.channelInactive`, `errorCaught`, BYE and fatal-response handling fail all
pending handlers, while `dispatchPipelinedFetchCommands` fails every handler before rethrowing. The
app's `IMAPProvider.fetchMessagesBatch` treats the propagated install error as a batch failure,
releases the production closed-channel connection as unhealthy, and the body queue retries its items.
No promise registry, teardown sweep, dispatcher-removal hook, or app-side machinery is needed.

**Why it is registered rather than merely fixed later — the false green.** The `fatalError` kills the
test process partway through, and the run still prints "passed" with zero `✘` markers. Measured
2026-08-12, three consecutive runs of one unchanged commit:

| run | exit | `leaking promise` hits | summary line |
|---|---|---|---|
| 1 | **65** | 2 | `Test run with **13** tests in 1 suite **passed**` |
| 2 | 0 | 0 | `Test run with 21 tests in 1 suite passed` |
| 3 | 0 | 0 | `Test run with 21 tests in 1 suite passed` |

Eight tests never executed in run 1. Every habitual green-check in this repo — `grep -c '✘'`,
"0 failures", "TEST EXECUTE SUCCEEDED" — reads GREEN on that run. Only the exit code and the dropped
test COUNT reveal it.

**How to tell a truncated run from a green one.** Do not trust a remembered baseline; a stale one is
dangerous in the low direction, where it blesses a truncation. Run the suspect suite ALONE, then the
others together, and confirm the combined total equals the sum of the parts. Arithmetic that closes
proves no suite was cut short. This was hit by the coordinator's own verification run during the
render-security series and caught only because exit code and failure count were checked separately.

**Attribution and class census.** The gap was introduced by SwiftMail commit `2d93774` (`#141`,
2026-03-24) and survived the pipelining hardening in `b50c7ad` (`#198`). The owning three files are
unchanged at the later `7aee922`, iOS v1.7.9 pin `f8469b14`, and current 1.11.0 pin `a2d4a94`.
Across the current SwiftMail source, 11 of 12 `makePromise` sites cover installation or dispatch
failure; `pipelinedFetchPartsBody` is the only outlier. The closest safe twin is
`IMAPConnection.startIdleSession`; current safe sites also include `connectBody`, the authentication
paths, `executeCommandBody` and `executeHandlerOnly` (covered by the catches in `runCommandHandler`
and `runStandaloneHandler`), `waitForFutureWithTimeout`, `SMTPServer.executeCommand`,
`SMTPServer.connect`, `executeSubmissionCommand`, and `flushSubmissionBuffer`.

**Remedy, and where it belongs.** In `pipelinedFetchPartsBody`, wrap only the dispatcher install in a
catch that calls `fail(error)` on every registered handler before rethrowing. This is a six-line
upstream candidate mirroring `startIdleSession`; all later exits already have fallbacks. A focused
SwiftMail test proved the invariant conventionally: without the catch, the selected test aborts at
NIO's leaked-promise check; with it, the same test passes. The candidate was then removed from the
disposable proof tree, leaving production source identical to `a2d4a94`.

⛔ SwiftMail changes go **upstream to Cocoanetics**, never to the deviation-free TabMail fork. No
fork-local edit or upstream PR is authorised by this record; the issue remains open until the owner
separately authorises upstream work or accepts the limitation.

**Related:** the same family of false-green mechanisms as a bare `-only-testing:` name (runs ZERO
tests, exits 0) and a stale test bundle (runs the wrong tests). All three make a run report success
without having executed what the reader believes it executed.
