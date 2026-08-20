# Post-login routing waits for an authoritative `/whoami` — the plan-navigation latch and the existing-account predicate

**Status:** Current · **Authored:** 2026-08-19 (issue #56)
**Related:** [[118-trial-ended-is-derived-never-a-new-whoami-flag]] (`apply` is the single
authoritative seam; its `fetchAccountInfo` census is UNCHANGED by this work) ·
[[113-a-swift-string-comparison-does-not-reproduce-sqlite-binary-collation]] (the *ordering* rule —
see below for why the *identity* predicate deliberately diverges from BINARY) · ADR-IOS-044 (no new
`/whoami` polling seams) · `PendingPlanNavigationLatch` · `Account.existing` ·
`AISubscriptionGate.lastAuthoritativeApplyAt` / `noteSignedOut` · `MailNavigationView.consumePendingPlanNavigation`

## The two defects (issue #56, both since initial release)

Signing in with Google on a device where that Gmail account was already fully configured:

1. **Re-offered adding the already-added account.** `TabMailLoginView`'s post-OAuth phase staged
   `PendingAccountAdd.shared.pending` **unconditionally** — no existing-account check on the login
   write path at all (not a race). Separately, `setupOAuthAccount`'s dedupe compared
   `emailAddress` with SQLite's default **BINARY** equality, so an identity provider returning a
   differently-cased address turned a token refresh into a **duplicate account row**.
2. **Routed an ACTIVE subscriber to the paywall.** The `pending_plan_navigation` UserDefaults latch
   (armed by the sidebar subscribe banner and by the AI-consent screen) was consumed by
   `MailNavigationView` with **no entitlement check** — a bare read-and-navigate — and the
   AI-consent writer had a fall-through that left a stale armed latch for active subscribers.

## The design that fixed it — and the invariants to preserve

**Freshness marker.** `AISubscriptionGate.lastAuthoritativeApplyAt: Date?` — in-memory ONLY,
deliberately not persisted. `isActive`/`hasCheckedOnce` hydrate from UserDefaults so returning
users get flash-free UI, but a ROUTING decision must never fire on that hydrated default (it can
describe a previous session or a previous account). **Only `apply(_:now:)` stamps it** — the bare
`openGate`/`closeGate` (AI 402/403 paths) and `refreshAfterLocalPurchase` do NOT (tests pin the
negative cases). `noteSignedOut()` clears it on `.tabMailDidSignOut` so the next sign-in cannot
inherit the previous account's freshness; last-known UI state (`isActive` etc.) deliberately
survives sign-out (118's "GLOBAL, not account-scoped" decision).

**The latch has exactly one owner.** `PendingPlanNavigationLatch` is the only code that touches the
raw `pending_plan_navigation` key. `consume(gateHasAuthoritativeState:gateIsActive:aiOptedOut:)`
returns a **4-case** outcome — `noLatch` / `waitForAuthoritativeGate` (latch PRESERVED) /
`navigateToPlanPicker` / `clearedWithoutNavigation`. `noLatch` is distinct from
`clearedWithoutNavigation` on purpose: the caller restores `initialSelection` only when a latch was
actually consumed, so ordinary foreground revalidations never yank the user's selection.
`recordAfterAIConsent(aiEnabled:gateIsActive:gateIsAuthoritative:)` arms unless the gate is active
AND authoritative (`lastAuthoritativeApplyAt != nil`), and **clears otherwise** — including the
stale-latch case that misrouted subscribers. A hydrated-but-unverified `isActive == true` still
ARMS (see the hardening section: disarming on it would deny a genuinely unentitled user the plan
picker). `clear` writes an **explicit `false`**, never `removeObject`: `UserDefaults(suiteName:)`
test isolation falls through to `.standard` for missing keys.

**Event-driven consumption, no timers.** The old consumer was a `.task` with a 100 ms sleep (a
timing guess). Now `MailNavigationView` consumes via
`.onChange(of: AISubscriptionGate.shared.lastAuthoritativeApplyAt, initial: true)` — the latch
waits exactly until the sanctioned always-on revalidation (`RootView.revalidateAISubscriptionGate`,
fired on scenePhase `.active` and on `.tabMailDidSignIn`) applies a real `/whoami`. **No new
`fetchAccountInfo` call sites were added** — 118's census and ADR-IOS-044 hold; entitlement state
remains server-written only.

**The existing-account predicate.** `Account.existing(forEmail:provider:in:)` is the single
predicate for "is this address already configured for this provider?", shared by the login add-gate
(skip staging `PendingAccountAdd` when it hits) and `setupOAuthAccount`'s dedupe (refresh vs.
insert) — the two decisions MUST agree. It fetches the provider's rows and compares full-Unicode
CASE-FOLDED values (`folding(options: .caseInsensitive)`, NOT `lowercased()` — see the hardening
section for the final-sigma reason and the deterministic duplicate preference) in Swift:

- **This is an IDENTITY-equality predicate, not an ordering — topic 113 does not apply and must not
  be "fixed" onto it.** 113 mandates UTF-8 byte comparison where Swift must reproduce a SQL
  `ORDER BY` arrangement. Here the BINARY-equality behavior *was the bug* (case-differing duplicate
  rows), and Swift treating NFC/NFD forms as equal is *desired*: two normalizations of the same
  address are the same identity, and matching them prevents a duplicate row.
- **calendarOnly rows match on purpose.** A calendar-first row (from `CalendarSetupView`) is still
  "this address is configured". Callers inspect `calendarOnly` on the returned row:
  `setupOAuthAccount`'s upgrade arm clears `calendarOnly`, promotes to primary if no active primary
  exists, and runs full mail activation — breaking the old infinite re-ask loop for calendar-first
  users.
- **Accepted landing for the calendar-only-row-and-NO-mail-rows device:** sign-in suppresses the
  pre-staged `PendingAccountAdd` offer (the issue's "add gate"), but `RootView.routedContent`
  counts MAIL accounts (`navigationStore.accounts` — `Account.sidebarRequest` filters
  `calendarOnly`), so with zero mail rows the app shows the generic `AddAccountGeneralView` once.
  That is correct — the device has no mail account and the app needs one — and ONE manual add of
  that provider reaches `setupOAuthAccount`'s upgrade arm, which permanently fixes the row
  (pre-fix, the same trigger looped forever). Do NOT "fix" this by making the router count
  calendar-only rows: a mail UI with zero mail accounts is worse than one add screen.
- **Never substitute `navigationStore.accounts`** — `Account.sidebarRequest` filters
  `isActive && !calendarOnly`, so calendar-first rows are invisible to it.

## Review-round hardening (both gate reviewers found these on the first candidate)

1. **Sign-in epoch guard.** A `/whoami` fetch started for account A can complete after A signs out
   (and after B signs in): `fetchAccountInfo` captures the bearer before the network await, and
   `apply` used to stamp unconditionally — re-poisoning `lastAuthoritativeApplyAt` and `isActive`
   with the WRONG account's entitlement (routing an active B to the paywall, or clearing an
   unentitled B's latch). Now `AISubscriptionGate.signInGeneration` (bumped by `noteSignedOut`) is
   captured BEFORE every fetch and checked by `applyIfCurrentEpoch(_:fetchedInGeneration:)`, which
   delegates to `apply` — apply remains the single seam. All three fetch→apply pipelines are
   guarded: `RootView.revalidateAISubscriptionGate`, `SyncScheduler.revalidateAISubscriptionGate`
   (open-only, but a stale OPEN cleared latches), and `AccountDashboardView`'s refresh.
2. **The consent writer requires AUTHORITY to disarm.** `recordAfterAIConsent` gained
   `gateIsAuthoritative` (`lastAuthoritativeApplyAt != nil`): a UserDefaults-hydrated
   `isActive == true` left by a previous subscriber must count as UNKNOWN — clearing on it would
   deny a genuinely unentitled user the plan picker forever. Arm unless (active AND authoritative);
   the entitlement-aware consumer clears silently for real actives.
3. **The predicate case-FOLDS and is deterministic under duplicates.**
   `folding(options: .caseInsensitive)` replaces `lowercased()` (lowercasing is context-sensitive —
   final sigma `ς` vs `σ` never compare equal; folding maps every case variant to one form; Swift
   `==` on the folded strings keeps NFC/NFD equivalence). And because the pre-fix BINARY dedupe
   could mint case-variant duplicates that are in the wild, multi-match now prefers the full MAIL
   row over calendarOnly, then the oldest — so token refresh and the upgrade arm can never seize a
   calendarOnly duplicate and mint a SECOND active mail account.
4. **`CalendarSetupView` routed through the predicate** — it still BINARY-matched before inserting
   calendar-only rows, recreating the duplicate class the fix eliminates.
5. **Signed-out `waitForAuthoritativeGate` restores the inbox.** No authoritative `/whoami` can
   arrive without a session (`fetchAccountInfo` throws unauthorized immediately), so waiting would
   suppress `initialSelection` for the whole session, every session (e.g. subscribe-banner tap →
   cancel sign-in). The consumer restores the inbox when `!hasTabMailSession`; the latch stays
   armed for the post-sign-in consume.

## Accepted limitations

Apple/iCloud sign-in keeps only its pre-existing once-only guard (out of issue-56 scope). The view
wiring (`RootView`/`MailNavigationView`) is not unit-tested; the invariants are pinned at the
pure-logic level (`PendingPlanNavigationLatchTests`, `AISubscriptionGateTests`,
`AccountLookupTests`). Three further consciously-accepted edges:

- **Upgrade-arm activation is not transactional with its row write.** `setupOAuthAccount` commits
  `calendarOnly = false` before `activateMailAccount`; a transient `connectAccount` failure leaves
  a full-mail row whose retry takes the plain reconnect arm and skips the one-time extras (initial
  sync kick, push subscribe, NSE mirror). This is the IDENTICAL pre-existing failure class as the
  fresh-insert arm (row committed, tail throws, retry reconnects plainly), self-heals via the
  foreground sync / push-consent rescan / NSE mirror cycles, and loses no data.
- **Signed-IN with an armed latch and a failing `/whoami` (offline launch) waits** — the folder
  list shows instead of the inbox until a fetch succeeds; one tap on any mailbox recovers, and the
  latch (the user's recorded intent) survives. Deliberate: distinguishing "in flight" from "failed"
  would add gate surface for a narrow, one-gesture-recoverable window (THE MANTRA).
- **No retroactive cleanup of duplicate rows the pre-fix bug already minted** — a merge migration
  would have to re-home messages keyed by accountId (high risk, low reach). The predicate's
  deterministic preference makes existing duplicates inert going forward.

## 2026-08-19 — merging `main` exposed the epoch's real boundary: bind to the STATE CHANGE, not to a notification

Merging `origin/main` into this branch combined the latch/epoch machinery above with main's async
`TabMailAuthService.signOut()` (the IOS-PUSH-001 sign-out cleanup handoff). Neither line had the
defect alone; the combination did. A sign-out's cleanup flush drives a token refresh in an
**unstructured** `Task`, which `signOut()`'s `flush.cancel()` cannot reach, so it completes after
`clearSession()` and writes the OUTGOING account's session back into the shared Keychain slot. That
resurrected session then answers a `/whoami` for the account the user just left.

**Search terms:** epoch bump timing; `noteSignedIn`; sign-in generation; `applyIfCurrentEpoch`;
session write vs notification; `.tabMailDidSignIn` too late; `syncStripeCustomer` suspension;
conditional bump; same-user re-auth preserves marker; `lastSignedInUserId`; identity pinned to work.

**The correction that matters beyond this bug.** The first fix bumped the epoch on the
`.tabMailDidSignIn` receiver. That is the wrong boundary and looked right: the notification is
posted by UI callers (`RootView`, `MailNavigationView`, `TabMailSignInPrompt`) only AFTER the
session has been written and after `syncStripeCustomer` — a network round-trip — has returned. A
prior account's in-flight `/whoami` landing inside that gap still carried the un-bumped generation,
passed `applyIfCurrentEpoch`, stamped `lastAuthoritativeApplyAt`, and let the latch consumer route
on the OLD account's entitlement. Two-sided: an unentitled A + active B paywalls B; an active A +
unentitled B silently clears B's latch and denies the picker. The epoch now advances at the three
`KeychainHelper.save(encoded, for: sessionKey)` sites in `TabMailAuthService`, synchronously and
before any suspension; the notification receiver is kept only as an idempotent backstop. **The
general rule this instance teaches: invalidate on the STATE CHANGE itself, never on a downstream
notification that merely announces it.** The same principle produced the sibling fix in
`IOS-PUSH-001` (pin the bearer to the admitted cleanup pass instead of re-deriving it per action
from ambient state) — both are "bind identity to the work, not to whatever is ambient later".

**The bump is CONDITIONAL, and that is not an optimization.** Those three save sites also fire when
the SAME user re-authenticates (web auth, id-token, OTP). An unconditional bump would discard a
known-good authoritative entitlement and widen the "unknown" window for nothing, leaving the
consumer waiting on a `/whoami` it did not need. `noteSignedIn(userId:previousUserId:)` bumps only
when the incoming subject differs from the established one (`lastSignedInUserId`, falling back to
the slot's prior subject so a same-user re-auth after a cold start is still recognised). An unknown
prior identity BUMPS. ⚠️ Note the deliberate asymmetry with the token coordinator's clobber guard,
where an unreadable slot means SAVE: there, withholding could log the user out; here, vouching for
a new account with the old account's entitlement is the worse harm. Same instinct, opposite
directions, because the harms differ — do not harmonize them.

**Why this fix cannot break authentication (census, 2026-08-19).** `signInGeneration` is declared in
`AISubscriptionGate`, bumped only by `noteSignedOut`/`noteSignedIn`, compared only in
`applyIfCurrentEpoch`, and read at exactly three sites — `SyncScheduler`, `AccountDashboardView`,
`RootView` — each capturing it immediately before a `/whoami` fetch. It appears ZERO times in
`TabMailTokenCoordinator`, `TabMailAuthService`, `PushClient`, and `BackendClient`. It therefore
gates only whoami→gate stamping and sits on no auth, token, or network path; an over-eager bump
cannot fail a backend call. Its worst case is that one `/whoami` result is dropped, the gate stays
unknown, and the consumer DEFERS — latch retained, no navigation — until a fresh result lands.
