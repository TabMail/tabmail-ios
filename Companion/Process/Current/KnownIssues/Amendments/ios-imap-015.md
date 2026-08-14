# IOS-IMAP-015

> **Post-freeze record.** Added 2026-08-12, after the 2026-08-09 hierarchy freeze, through the
> amendment surface in `Scripts/compact_known_issues.rb`. It has no row in
> `known-issues-pre-hierarchy-2026-08-09.txt` and is deliberately not regenerated from that archive.

- Register classification: `open`
- Disposition: 🔓 **OPEN (2026-08-12)** — deferred by the owner: "this could be something we fix, but
  not now". Recorded so the false-green mechanism is not rediscovered from scratch.

## Status

🔓 **OPEN — test-infrastructure only. No production impact, and that bound is structural rather than
observational.** A leaked NIO promise on the pipelined-FETCH path aborts the test process mid-run
while the run still reports the word "passed", so a truncated suite reads GREEN by every habitual
check in this repo.

## Subsystem and search terms

SwiftMail; SwiftNIO; `IMAPConnection+PipelinedFetch`; `makePromise`; `PipelinedFetchPartHandler`;
leaking promise; `debugOnly`; `EventLoopFuture` deinit; false green; truncated test run; exit 65;
`NeverDropExitClosureTests`; test count regression

## Full detail

**Symptom.** During test runs, non-deterministically (measured ~1 run in 3 on
`NeverDropExitClosureTests`):

```
SwiftMail/IMAPConnection+PipelinedFetch.swift:197: Fatal error: leaking promise created at ...
```

**Why the `file:line` is misleading.** That location is where the promise was *created*, not where
the trap lives. `IMAPConnection+PipelinedFetch.swift:197` is
`let promise = channel.eventLoop.makePromise(of: Data.self)` inside the loop that registers one
pipelined FETCH part per request and hands each promise to a `PipelinedFetchPartHandler`. Grepping
that file for "leaking promise" returns nothing, which has misdirected at least one investigation.

The `fatalError` is in **SwiftNIO**, in `EventLoopFuture.deinit`
(`swift-nio/Sources/NIOCore/EventLoopFuture.swift`): if a promise is deallocated with `_value == nil`
it traps, reporting the creation site. So the defect is a pipelined-FETCH part promise that is not
resolved on some path — a part handler that never completes because the response never arrives, the
connection is torn down, or the dispatcher drops it.

**Why production is unaffected, stated structurally.** The trap is wrapped in NIO's `debugOnly`,
which is `assert({ body(); return true }())` — the body runs only when assertions are enabled.
Release builds compile it out entirely, so a leaked promise in production is a leak, not a crash. The
bound is therefore on the *build configuration*, not on the frequency of the leak, and it does not
depend on the leak being rare.

⚠️ **Stated negatively:** this does NOT claim the leak itself cannot happen in production. It claims
only that its *observable consequence there* is not a `fatalError`. An unresolved promise still means
a pipelined FETCH part whose continuation never resumes; whether any caller can await it forever is
NOT established here and was not investigated.

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

**Attribution.** In the pinned SwiftMail fork, not in app code, and not introduced by the
render-security series (those commits touch no IMAP path). Note the fork already resolves promises
defensively at seven other sites for exactly this reason —
`IMAPConnection+Connection.swift:104`, `+Authentication.swift:108`,
`+CommandExecution.swift:148` and `:231`, `+Idle.swift:61`, `SMTPServer.swift:252`,
`SMTPServer+Send.swift:347`, each carrying a comment naming the "leaking promise" fatal error. The
pipelined-FETCH path is missing that treatment, which makes this an omission in a pattern the fork
otherwise applies, not an unknown failure mode.

**Remedy, and where it belongs.** Resolve the part promise on every exit path (failure, teardown,
dispatcher drop), mirroring the seven sites above. ⛔ Per `feedback_swiftmail_pr_upstream`, SwiftMail
changes go **upstream to Cocoanetics**, never to the fork, and the PR is the owner's. Do not open it
from this repo's work. Not reported upstream as of 2026-08-12.

**Related:** the same family of false-green mechanisms as a bare `-only-testing:` name (runs ZERO
tests, exits 0) and a stale test bundle (runs the wrong tests). All three make a run report success
without having executed what the reader believes it executed.
