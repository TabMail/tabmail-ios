## "Trial ended" is DERIVED on the client — there is no `/whoami` flag, and adding one is the reinvention that was already rejected

**Date:** 2026-08-18 · **Status:** current · **Ships dormant** until the backend starts granting
signup trials; every surface below behaves exactly as it did before while `trial` is absent.

### The shape the client must read

A new account is granted a free trial server-side, so it reports `has_subscription: true` and is
*active* — no paywall, no purchase sheet, nothing to start. The **running** shape carries all four
markers: `has_subscription: true`, `plan_tier: "Trial"`, `subscription_provider: "signup"`, and
`trial {is_trial: true, trial_end: <epoch SECONDS>}`.

⚠️ **CORRECTED 2026-08-18 — the ended response does NOT carry "the same `trial` object it always
carried".** That sentence stood here for one day and was wrong in two ways, both of which the client
had to be fixed for:

1. **The value can be an explicit JSON `null`.** The backend emits `trial: ent.trial ?? null`, so
   the ended body keeps the **KEY** while the **VALUE** may be null. Swift's synthesized `Decodable`
   maps `"trial": null` and an absent key to the same `nil`, so the fail-closed ended payload
   degraded to `.noTrial` and every ended-trial surface silently vanished. `AccountInfo` therefore
   has a hand-written `init(from:)` recording `trialKeyPresent` from
   `container.contains(.trial)` — true for a present-but-null key, false only when the key is
   absent. Every other no-subscription state omits the key entirely, which is what keeps the whole
   feature dormant. **A new stored property on `AccountInfo` must be added to that initializer.**
2. **`plan_tier` and `subscription_provider` are DROPPED on the ended body**, so an ended trial
   cannot be recognised by tier. Key presence is the signal, and `is_trial` is deliberately **not**
   required there — it is not guaranteed on that body.

🚨 **`trial.trial_end` is typed `string | number` upstream** (historical webhook writers stored ISO
strings). A synthesized decoder throws `typeMismatch` on the string form — and that throw does not
fail one field, it fails the **ENTIRE `/whoami` parse**, blanking the whole account screen over one
legacy row. `TrialInfo.init(from:)` is therefore hand-written and lenient, following the
`DayStats.init(from:)` precedent in the same file: an unreadable `trial_end` becomes `nil` and a
missing `is_trial` becomes `false`. A nil `trial_end` on a no-subscription body with the key present
derives `.ended`, which is the correct fail-closed degrade.

**Presence-of-key plus `has_subscription != true` IS the ended-trial signal.** Two candidate wire
flags — `trial_expired` and `trial_blocked` — were proposed during design and explicitly **cut as
reinvention**. Do not resurrect them, and do not add a client-side mirror of them either: an
implementer who "notices" that the ended state has no flag has rediscovered the decision, not a gap.

🚨 **A legacy Stripe/Apple CARD trial also carries a `trial` object** — `has_subscription: true`,
`plan_tier` `Basic`/`Pro`, provider `stripe`/`apple`, future `trial_end`. It is an ordinary paid
subscriber inside an introductory period and every surface must keep treating it as one. **`.active`
therefore additionally requires `plan_tier == "Trial"`**; without that gate a card trial flipped the
dashboard CTA from "Change Plan" to "Subscribe", changed its banner, and put a trial banner on the
paywall for someone who had already bought a plan.

### Where the derivation lives (one place, injected clock)

`AccountInfo.trialState(now:)` in `TabMail/Models/AccountPlanState.swift` returns
`TrialState.active(daysRemaining:)` / `.ended` / `.noTrial`. Rules worth knowing before touching it:

- **`.active` requires `has_subscription == true` AND `plan_tier == "Trial"` AND `is_trial` AND a
  FUTURE `trial_end`.** The tier is the discriminator against a card trial (above); dropping it is
  the single highest-impact way to break existing subscribers.
- **`.ended` requires `has_subscription != true` (nil included) AND the `trial` KEY present AND no
  future finite `trial_end`.** A subscriber whose old trial converted is just a subscriber; a past
  `trial_end` alone never means "ended", and an ABSENT `trial` key never means it either.
- **An absent `trial` key resolves to `.noTrial`** — every surface then keeps its pre-trial
  behaviour. This is what makes the whole change dormant against today's backend, and it is now the
  ONLY thing that does: a PRESENT key with no usable end date and no subscription fails closed to
  `.ended`, not to `.noTrial`, because `is_trial` is not guaranteed on that body.
- **`daysRemaining` rounds UP and floors at 1**, so the last partial day reads "1 day left" rather
  than "0". Callers must not re-derive day counts with their own arithmetic.
- **Never gate an ended-trial surface behind `if let trial`.** The object can be null on exactly
  that body. Render from `trialState() == .ended`. `AccountDashboardView.trialBannerCopy` is the
  reference shape: it switches on the state first and only reads `info.trial` in the `.noTrial` arm,
  where it preserves the legacy card trial's "Trial active until <date>" wording verbatim.
- **The case is spelled `.noTrial`, not `.none`** — `Optional.none` shadowing has bitten this
  codebase before (`ActionTag.none`).

### The one persisted signal, and why the AI 402/403 paths must not write it

The sidebar subscribe banner lives in `MailNavigationView` and is driven by `AISubscriptionGate`,
which has no `AccountInfo` in hand. `AISubscriptionGate.apply(_:now:)` is therefore the single seam:
it opens/closes the gate **and** stamps `trialHasEnded` from the same authoritative `/whoami`. The
flag is persisted for the same reason `isActive` is — the banner renders from last-known state on
launch, so an in-memory-only flag would show generic copy and then visibly swap wording.

**The census is over `fetchAccountInfo()` call sites, not over `apply` call sites** — counting the
callers of `apply` can only ever find the sites that already route, which is the shape of census
that misses the very thing it is looking for. `rg -n "fetchAccountInfo\(\)" TabMail` at the time of
writing returns 14 hits: one definition (`BackendClient`), three closure invocations inside
`AccountDeletionSubscriptionCoordinator` plus the injection in `AccountDeletionView` (a
policy-decision read, no gate involvement), and **nine** production reads that hold a body:

| site | routes through `apply`? | why |
|---|---|---|
| `RootView.revalidateAISubscriptionGate` | ✅ | foreground / sign-in, the original seam |
| `AccountDashboardView.fetchAll` | ✅ | the dashboard is rendering trial copy from this body |
| `PlanPickerView` post-purchase | ✅ | the purchase just ended any running trial |
| `PlanPickerView` post-restore | ✅ | restore can re-establish a subscription |
| `SyncScheduler.revalidateAISubscriptionGate` | ⚠️ open branch only | see below |
| `PlanPickerView` `.task` (initial load) | ❌ deliberate | see below |
| `PlanPickerView` `scenePhase == .active` refresh | ❌ deliberate | see below |
| `PlanPickerView` post-manage-subscription refresh | ❌ deliberate | see below |
| `RootView` sign-in consent read | ❌ deliberate | consent gating, not subscription state |

The four ❌ rows are **not** oversights. `apply` closes the gate on a no-subscription body and
`closeGate` stamps `hasCheckedOnce` — so routing a merely *incidental* read would surface the sidebar
subscribe banner earlier than it appears today, for users who have not yet been through the
foreground revalidation that owns that decision. The ✅ rows are the ones where the body is already
being used to render subscription state, so stamping from it changes nothing about *when* the app
decides, only about *which* copy it shows. When adding a new `/whoami` read, ask which of those two
it is; the answer, not the convenience, decides.

`SyncScheduler.revalidateAISubscriptionGate` is the deliberate partial: it is **open-only** (guarded
by `!gate.isActive`, and it only ever acted when `has_subscription == true`), so only the OPEN branch
routes through `apply`. The negative branch still makes no call at all, which is what keeps the
open-only semantics provably intact — and with `has_subscription == true` the derivation can only
ever stamp "trial not ended", so the open branch cannot change the flag in the wrong direction
either.

⚠️ **`openGate` / `closeGate` deliberately leave `trialHasEnded` alone.** The AI 402/403 paths in
`ActiveAIQueue` call them with no whoami body; stamping "not ended" there would flip correct copy
back to the generic invitation on the next background AI failure. Only `apply` writes the flag.

**Accepted design: `trialHasEnded` is GLOBAL, not account-scoped.** It follows the most recently
signed-in account, exactly like the `isActive` / `hasCheckedOnce` flags it sits beside — the same
pre-existing gate-persistence pattern, in the same `UserDefaults.standard`. A stale ended-copy after
an account switch self-corrects on the next authoritative `/whoami`, and the banner is copy
selection only: it never gates access. Do not "fix" this into per-account persistence without a
reason that outweighs diverging from the two flags next to it.

⚠️ **A test helper that restores this gate must restore `trialHasEnded` BEFORE `isActive`.** The flag
is only writable through `apply`, which opens or closes the gate as a side effect — so putting
`isActive` back first lets the restoring fixture reopen the gate afterwards and persist a
last-known-active the user never had, leaking into every suite that follows.

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

### Account deletion — a signup trial has nothing to cancel

A running signup trial reports `has_subscription: true` with `subscription_provider: "signup"`, and
`AccountDeletionSubscriptionPolicy.nextStep` dispatches on that provider. Its `default:` arm is
`.unsupportedActiveProvider`, so before the `case "signup": return .scheduleDeletion` arm existed
**an active trial user was blocked from deleting their account at all**. There is no purchase behind
a signup trial: nothing renews, nothing charges, and there is no provider subscription to cancel
first, so deletion is scheduled directly and the remaining days are simply forfeited.

⚠️ **That file has exactly TWO provider comparisons** — `nextStep` (the dispatch above) and
`stripeDeletionEligibilityWasConfirmed`, which proves a **Stripe** cancellation landed and therefore
still admits only `"stripe"`. Widening the second would let another provider's state satisfy a
Stripe-specific proof; `"signup"` never reaches it because it never takes the `.cancelStripe`
branch. Census both when adding a provider.

### What is deliberately left alone

> ⚠️ **UPDATE 2026-08-19 (issue #55):** the first bullet below is now history — the "later cleanup"
> it defers to has happened. The App Store Connect introductory offers were removed on 2026-08-19,
> and `checkTrialEligibility()`, `StoreKitManager.isEligibleForTrial`, `PlanCardIntroOffer`
> (`suppressesIntroOffer` / `showsTrialBadge`), the PlanCard `hasIntroOffer` plumbing, the
> "2 weeks free" badge and the "Start Free Trial" CTA were all **deleted**. The rank-driven
> purchase-button logic survives as `PlanCardCTA.buttonLabel` (no-subscription → "Subscribe").
> The suppression cohort the bullet protects no longer needs protecting: with no ASC offer,
> there is nothing Apple could grant on top of a running signup trial. Everything else in this
> file — the derivation, the gate seam, the banner rules — is untouched and current.

- `StoreKitManager.checkTrialEligibility()` and `PlanCard.showsTrialBadge` stay. They gate on
  `product.subscription?.introductoryOffer != nil`, so removing the App Store Connect introductory
  offers extinguishes the "2 weeks free" badge and the "Start Free Trial" CTA with no app release.
  They are scheduled for a later cleanup, not this one.
  ⚠️ **But NOT for a user already on a running signup trial.** While the ASC offers still exist, that
  cohort would see "2 weeks free" and a "Start Free Trial" button on the same page as a banner
  saying their trial is running — and Apple would genuinely grant its offer on top. So
  `PlanCardIntroOffer.suppressesIntroOffer(for:now:)` (true only for `.active`) hides the badge, its
  "free for 2 weeks" line, and the CTA, which becomes "Subscribe". Suppression is scoped to that one
  cohort: `checkTrialEligibility`, `hasIntroOffer` and the rest of `showsTrialBadge` are untouched
  for everyone else. For the same reason the plan-picker banner says only *"Subscribing now ends the
  trial"* — an earlier draft claimed billing starts immediately, which is FALSE while an
  introductory offer can still apply to the purchase.
- Apple's forfeiture boilerplate ("Any unused portion of a free trial period, if offered…") stays —
  it is required, and it happens to describe the server trial's forfeit-on-purchase behaviour too.
- `UsageThrottleStore.banner` returns `nil` for a trial on purpose: a trial rides the shared queue
  for its whole duration, so a throttle nudge would be permanent noise. The dashboard and plan
  picker carry that story instead.
