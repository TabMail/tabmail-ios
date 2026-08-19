## "Trial ended" is DERIVED on the client — there is no `/whoami` flag, and adding one is the reinvention that was already rejected

**Date:** 2026-08-18 · **Status:** current · **Ships dormant** until the backend starts granting
signup trials; every surface below behaves exactly as it did before while `trial` is absent.

### The shape the client must read

A new account is granted a free trial server-side, so it reports `has_subscription: true` and is
*active* — no paywall, no purchase sheet, nothing to start. When that trial runs out the response
becomes `has_subscription: false` **plus the same `trial` object it always carried**
(`{is_trial, trial_end}`), with `trial_end` now in the past.

**That pair IS the ended-trial signal.** Two candidate wire flags — `trial_expired` and
`trial_blocked` — were proposed during design and explicitly **cut as reinvention**. Do not
resurrect them, and do not add a client-side mirror of them either: an implementer who "notices"
that the ended state has no flag has rediscovered the decision, not a gap.

### Where the derivation lives (one place, injected clock)

`AccountInfo.trialState(now:)` in `TabMail/Models/AccountPlanState.swift` returns
`TrialState.active(daysRemaining:)` / `.ended` / `.noTrial`. Rules worth knowing before touching it:

- **`.ended` requires `has_subscription != true`.** A subscriber whose old trial converted is just a
  subscriber; a past `trial_end` alone never means "ended".
- **Missing `trial_end`, or `is_trial == false`, resolves to `.noTrial`** — every surface then keeps
  its pre-trial behaviour. This is what makes the whole change dormant against today's backend.
- **`daysRemaining` rounds UP and floors at 1**, so the last partial day reads "1 day left" rather
  than "0". Callers must not re-derive day counts with their own arithmetic.
- **The case is spelled `.noTrial`, not `.none`** — `Optional.none` shadowing has bitten this
  codebase before (`ActionTag.none`).

### The one persisted signal, and why the AI 402/403 paths must not write it

The sidebar subscribe banner lives in `MailNavigationView` and is driven by `AISubscriptionGate`,
which has no `AccountInfo` in hand. `AISubscriptionGate.apply(_:now:)` is therefore the single seam:
it opens/closes the gate **and** stamps `trialHasEnded` from the same authoritative `/whoami`
(`RootView.revalidateAISubscriptionGate` is its only production caller). The flag is persisted for
the same reason `isActive` is — the banner renders from last-known state on launch, so an
in-memory-only flag would show generic copy and then visibly swap wording.

⚠️ **`openGate` / `closeGate` deliberately leave `trialHasEnded` alone.** The AI 402/403 paths in
`ActiveAIQueue` call them with no whoami body; stamping "not ended" there would flip correct copy
back to the generic invitation on the next background AI failure. Only `apply` writes the flag.

### Zero-priority-budget plans are now a SET, not a string equality

`Trial` is the second zero-priority-budget tier after `BYOK` (global ADR-025), so it reports the same
`queue_mode: "slow"` a Zero user without their own key does. On the client that means
`AccountDashboardView.isZeroPlan` is no longer `planTier == "BYOK"`: it goes through
`ZeroBudgetPlan.forTier(_:)`, and **each member owns its own caption** — the BYOK caption talks
about the user's own API keys, which a trial user does not have. Copying the Zero caption onto the
trial is the specific mistake this enum exists to prevent.

`StoreKitManager.displayPlanName(forTier:)` is display-only, as it has always been: it maps
`BYOK → "Zero"` and `Trial → "Free Trial"`, and internal tier strings stay `BYOK`/`Trial`
everywhere (KV, planQuotas, product IDs). `Trial` is not purchasable and has rank 0, so it can never
outrank a product in the plan picker's upgrade/downgrade direction logic.

### What is deliberately left alone

- `StoreKitManager.checkTrialEligibility()` and `PlanCard.showsTrialBadge` stay. They gate on
  `product.subscription?.introductoryOffer != nil`, so removing the App Store Connect introductory
  offers extinguishes the "2 weeks free" badge and the "Start Free Trial" CTA with no app release.
  They are scheduled for a later cleanup, not this one.
- Apple's forfeiture boilerplate ("Any unused portion of a free trial period, if offered…") stays —
  it is required, and it happens to describe the server trial's forfeit-on-purchase behaviour too.
- `UsageThrottleStore.banner` returns `nil` for a trial on purpose: a trial rides the shared queue
  for its whole duration, so a throttle nudge would be permanent noise. The dashboard and plan
  picker carry that story instead.
