# MIS-IOS-021 — I unified two look-alike classifiers into one helper, and silently widened the narrower gate

**Class:** data-integrity
**Severity:** high (retires user intentions and deletes local mail rows that the pre-change tree kept)
**First seen:** 2026-09 · **Recurrences:** 1 · **Status:** Active
**Related:** `MIS-IOS-004` (conflated unknown with authoritative stale — this is how the conflation gets in through the back door) · `MIS-IOS-010` (selected on a value that was itself a guard) · `MIS-IOS-012` (a census whose shape hid half the callers) · `Companion/Rules/Active/never-drop-user-intention.md` (exit 2)

## The tell

Two sentences, and they sound like good engineering:

1. *"These two functions ask the same question — 'did the server tell us this message is gone?' —
   and two copies of a classification are two things that can drift. I'll keep one and make the
   other forward to it."*
2. *"The one I'm keeping is the STRICTER one. `isConfirmedGoneError` is documented as the strict
   sibling that gates header deletion, so reusing it cannot possibly loosen anything."*

The second sentence is where it goes wrong: **"stricter" was measured against the wrong neighbour.**

## What actually happened

PR 1 of the two-PR action-queue refactor, branch `agent/ios-queue-no-split`.

Deleting the drain's batch-splitting arm required a new predicate at the provider boundary for
"the server answered the request addressed at THIS member with an authoritative not-found". Rather
than write one, I extracted `AccountManager.isConfirmedGoneError`'s body into
`ProviderMemberAbsence.isAuthoritative` and left `isConfirmedGoneError` forwarding to it.

The tree has THREE classifiers, not two, and they sit at different depths:

- `isMessageNotFoundError` — the gate a not-found must pass before the drain may retire an
  operation at all. Accepts `ProviderError.messageNotFound` and HTTP **404**, plus a substring
  fallback. **Never 410.**
- `isConfirmedGoneError` — runs only INSIDE the arm the first one already admitted, and decides
  whether the retired member's local header may go too. Accepts 404 **and 410**.
- (new) `ProviderMemberAbsence.isAuthoritative` — decides whether a per-member provider answer
  retires that member AND deletes its header.

`isConfirmedGoneError` is strict relative to `isMessageNotFoundError`'s *substring fallback*, which
is what its doc comment is about. It is **wider** on status codes, and its extra `410` had always
been **unreachable** — nothing could reach it without passing the 404-only gate first. Forwarding
made that dead branch live, on the most destructive path in the subsystem: a bare `410` went from
"retry forever" to "retire the operation and delete the local header, with its body and FTS
content". Strictly more destruction than the base tree, arrived at by picking a helper rather than
by deciding anything.

An existing test, `httpError410ForMessageNotFound`, documents the exclusion as deliberate — "keeping
them separate so we don't accidentally over-drop pending ops on 410" — and I had read the file it
lives in. It reads as trivia about two classifiers until you know one of them just became reachable.

Caught by a GPT consult before commit; the fix is one line of predicate plus a queue-level test that
a 410 retires nothing and deletes nothing, with the 404 case as the two-sided control.

## Why it is not obvious

Nothing in the diff of a forwarder shows a widening. The forwarder's body is *identical* to the
function it replaced, the function it replaced kept behaving identically, and the new caller is new
code with no "before" to compare against. The widening exists only in the composition: an acceptance
set that was safe because of where it sat, moved somewhere else.

De-duplication also has the moral momentum of the codebase behind it — a shared predicate really is
how you stop two judgements from drifting. The question that distinguishes the good case from this
one is not *"do these look the same?"* but ***"is either of them currently unreachable, and if so,
what was keeping it that way?"***

## The countermeasure

**Before reusing a classifier at a new call site, establish what its CURRENT callers have already
excluded before it runs — then diff the acceptance sets, not the function bodies.** Concretely:

1. Enumerate every existing caller of the helper and write down the predicate that guards each one.
   A helper called under a guard has an *effective* acceptance set = its own ∩ every guard's.
2. Compare the new site's effective set against the old effective set, per input class (each status
   code, each error case) — not "stricter/looser" as a vibe.
3. If the new set is larger anywhere, that difference is a **behaviour change** and needs its own
   evidence, its own decision and its own test. It is never a side effect of de-duplication.
4. When in doubt, make the new predicate the NARROWER one and let the two differ. Two predicates
   that disagree in the safe direction cost a comment; one that silently widened costs user data.

The comment that now sits on both functions names the asymmetry and says it is deliberate, so the
next reader who notices the duplication finds the reason before the refactor.
