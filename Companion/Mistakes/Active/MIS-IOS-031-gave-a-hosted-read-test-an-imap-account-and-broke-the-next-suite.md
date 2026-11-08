# MIS-IOS-031 — gave a test that commits a real read an IMAP account, and broke the next suite

**Recurrences:** 1
**Status:** Active
**First recorded:** 2026-11-06

## The tell

> *"It passes alone and the lifecycle suite passes alone, so the failure in the combined run is host
> load."* A suite that was green for hours fails only when run together with a suite you just added,
> and the new suite commits a real read or move through `AccountManager.shared` on an account whose
> provider is `.imap`.

## What actually happened

`ChatCardIdentityTests` (the chat card's identity witness) opened `MessageDetailViewModel` and let
`markReadOnOpenIfNeeded` commit a read on its control case, on an IMAP fixture account copied from
`SearchLocalResultIdentityTests`. Run with `ChatThreadViewLifecycleTests`, the lifecycle suite's
Unread-line and search opens never scrolled away from the bottom within their 12-second wait, twice.
Each suite passed alone, and the unchanged train tip passed the lifecycle suite under the same host
load. With the fixture account on Gmail, as the lifecycle suite's own fixture is, both suites pass
together. Seen: the pair failed twice with IMAP and passed with Gmail. Not traced: the suspected
mechanism is the read's queued operation draining through the IMAP provider, which tries to connect
and holds `AccountManager.shared`'s shared work past the test's end, into the next suite's open.

Weakened the same day: with the fixture already on Gmail, the same lifecycle test failed once more in
a seven-suite run at host load average about 490 on 10 cores, then passed on a re-run of the same
tree (51 of 51). Load alone can therefore produce this failure, and the IMAP fixture is a suspect, not
a proven cause. The lifecycle test's wait for the open's own scroll is a fixed budget, which an
extremely loaded host can exceed.

## Why it is not obvious

`.processGlobalState` serializes the suites, so they look isolated; the test drains the write queue
before it ends, so it looks clean; and the host load average was 200 to 300 at the time, which made
"flaky under load" the easy answer. If the likely mechanism holds, the drain starts after the test's
own barrier and no test owns it.

## The rule

A test that lets a read, move or tag reach `AccountManager.shared`'s queue uses a Gmail fixture
account unless it needs IMAP numbering (a cheap precaution, not a proven fix), and a suite that fails
only beside a new suite is that new suite's fault until a control run (the old tip, same load) says
otherwise. Record the host load beside every such failure, and re-run the same tree once before
changing code: a single failure at a load average many times the core count proves nothing.

## Mechanical check

No mechanical check catches the interaction itself; it shows only when the two suites run together.
This lists the candidates, tests on an IMAP fixture that commit through the shared manager. At
2026-11-06 it lists eight that pass in the train's runs, several of which need IMAP numbering; a hit
is a place to look when a later suite fails beside it, not a defect.

```bash
rg -l 'provider: \.imap' TabMailTests | xargs rg -l 'markReadOnOpenIfNeeded|registerGestureIntent|archiveMessages|deleteMessages'
```
