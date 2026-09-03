# IOS-PUSH-001

> **Post-freeze amendment to a BASE-register record.** Added 2026-09-03 through the amendment
> surface in `Scripts/compact_known_issues.rb`. The base record's own bytes are hash-pinned and are
> **not** edited by this file: `Companion/Process/Current/KnownIssues/ios-push-001.md` is unchanged,
> nothing in it is deleted or rewritten, and its chronology remains the audit record. This file only
> **adds** the current disposition of one section of it.

- Register classification: `accepted` (unchanged — see the base-register override row in
  `KNOWN_ISSUES.md`; this amendment changes no classification)
- Amends: `Companion/Process/Current/KnownIssues/ios-push-001.md` § "🟢 FINAL UPDATE …", subsection
  **3. Ordinary sign-out policy remains intentionally small**

## Status

⚠️ **SUPERSEDED IN PART (2026-09-03) — §3 no longer describes the code.** Everything else in the
base record stands, including all three stranding paths and the server-side purge split.

## Subsystem and search terms

ordinary sign-out; sign-out handshake; device release; `unregisterDeviceForSignOut`;
`releasePushRegistrationAndEndAuthSession`; `signOutHandshakeTimeoutSeconds`; GoTrue
`logout?scope=local`; token release; APNs registration release; `restorePushRegistrationAfterSignIn`;
`subscribeAllAccounts`; sign-out identity guard; mid-flush sign-in; push-worker issue #42;
memory topic 124; do not revive

## What §3 says, and what is now true

§3 of the base record reads, verbatim:

> Ordinary sign-out does not unregister the APNs token, release device ownership, call a server
> purge, or perform a new client/server handshake. […] The original iOS issue remains closed. Future
> work belongs to the surviving server issue trackers; do not revive the superseded local
> sign-out/token-release branch from this historical record.

That was the correct disposition when it was written (2026-08-28) and is kept as history. It was
**reversed by owner ruling on 2026-09-03** while closing push-worker issue #42, and the reversal is
implemented: ordinary user-initiated sign-out now performs exactly the client/server handshake §3
forbade reviving.

**Current behaviour — the authoritative statement is memory topic 124**
([`Companion/Memory/Current/124-ordinary-sign-out-releases-the-device-push-registration-and-ends-the-auth-session.md`](../../../../Memory/Current/124-ordinary-sign-out-releases-the-device-push-registration-and-ends-the-auth-session.md)),
which this amendment points at rather than restates. In outline: `TabMailAuthService.signOut()` runs
a best-effort, time-bounded release handshake while its bearer is still valid — the worker's
`DELETE /register-device` for this install, then GoTrue `POST /auth/v1/logout?scope=local`, both legs,
in that order — pinned by a single comparison to the subject that was signed in when sign-out began,
and clears the local session on every path regardless of the outcome. Nothing is retried, persisted
or migrated.

**What §3 still gets right, and must not be re-derived as contradicted:**

- Sign-out **does not depend on remote success**. The handshake cannot fail sign-out and cannot
  extend it past its bound.
- Local credential finality is still enforced by the generation store, not by the handshake.
- There is still **no server purge call** on this path, and no account-incarnation protocol,
  payment check or re-consent flow.
- The base record's **three stranding paths for removed-account cleanup debt are untouched**. The
  handshake releases *this device's registration*; it does not discharge another user's debt, and a
  sign-in landing mid-flush makes it refuse rather than act under the new subject — which is the
  same rule the pinned-identity drain follows, and preserves rather than widens the cross-user
  stranding recorded on 2026-08-19.
- The **server-side user-keyed purge** tracked in the 2026-08-20 §3 remains the backstop for the
  cases no iOS-side handshake can reach, above all permanent account deletion, where the bound user
  can never authenticate again.

**What is now wrong in §3, stated plainly so a census cannot miss it:** the sentence "Ordinary
sign-out does not unregister the APNs token, release device ownership, call a server purge, or
perform a new client/server handshake" is false in three of its four clauses. Sign-out **does**
release device ownership on the worker and **does** perform a client/server handshake; it also ends
the auth session server-side, which §3 does not contemplate at all. Only "call a server purge"
survives. The closing instruction — *"do not revive the superseded local sign-out/token-release
branch"* — is **retired by the owner ruling above**; it must not be quoted to block or reverse this
work.

⚠️ **One clause of the base record's own reasoning is also retired.** The 2026-09-03 candidate
initially coupled the auth leg to the worker's status code ("logout only after a successful
release"), on the theory that a registration the worker still holds needs its session kept alive.
Round-1 review retired the coupling because it protected nothing while leaving this device with a
live server-side session after every worker outage. ⚠️ **Round 1 also justified that in the present
tense by naming a server-side staleness sweep that is NOT DEPLOYED yet — do not restate it as an
existing backstop.** On the currently deployed worker the only server-side nets that retire a
registration whose session ended before the release landed are the next-owner eviction (the next
account to claim the same APNs token displaces the older registration) and APNs feedback once the app
is uninstalled; the general staleness sweep lands with the push worker's half of issue #42 and, once
deployed, becomes the standing backstop. The retirement stands either way — the coupling's cost is
certain and its benefit was never established. **Both legs now run unconditionally, worker first.** Do not
reinstate the coupling; the only thing that suppresses the logout is the bound itself
(`guard !Task.isCancelled` between the legs).

## Reachability and recovery

Ordinary sign-out is a deliberate user gesture from the account dashboard, so this path is reached
whenever a signed-in user signs out — it is the common path, not an edge. Every failure mode is
recoverable by an ordinary user gesture or by server-side expiry:

- A failed or timed-out release leaves the registration in place on the worker. On the currently
  deployed worker the only server-side nets that retire it are the next-owner eviction — the next
  account to claim the same APNs token displaces the older registration — and APNs feedback once the
  app is uninstalled; a general server-side staleness sweep lands with the push worker's half of
  issue #42 and becomes the standing backstop only once deployed. No local state claims the install
  is still registered: the cache clears run in a `defer`, so a release whose
  outcome is unknown never leaves a "registered" cache that would make the next sign-in skip
  registration.
- A failed or timed-out logout leaves this device's auth session to its natural expiry, exactly as
  before this change.
- A refusal on the identity guard (a sign-in landed mid-flush) leaves the outgoing user's device
  registration in place; the next foreground pass or the next sign-out for that subject releases it.
  Acting instead would have deleted the *incoming* user's device route.
- A sign-out followed by a sign-in in the same process re-registers immediately via
  `TabMailAuthService.restorePushRegistrationAfterSignIn()`, wired to RootView's `.tabMailDidSignIn`
  receiver; without it the install would have no registration until the next scene-phase transition.

No new durable state, no migration, no retry queue, and no persistence is introduced by any of the
above.
