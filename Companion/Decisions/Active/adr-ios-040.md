<!-- COMPANION-CURRENT-NOTE-BEGIN -->
> **Current routing note:** amended 2026-11-03, after this fragment was pinned. Where the text below
> and the pinned body differ, this text wins.
>
> Point 4's closing sentence, "Zero NEVER has a trial (D8).", no longer holds. Zero now gets the
> same App Store free-trial introductory offer as Basic and Pro (owner, 2026-11-03). Subscribing to
> any plan, Zero included, ends the server-granted signup trial, and the subscription starts with
> Apple's free trial. Apple decides eligibility itself (one introductory offer per subscription
> group).
>
> No client logic changes with this. Since issue #55 (2026-08-19) the plan cards advertise no
> introductory offer at all, and Apple's purchase sheet shows the trial, the price and the first
> charge date. The plan picker's trial banner now reads "Subscribing resets your free trial."
> When the signup trial has more days left than the subscription's free trial
> (`AccountPlanConfig.subscriptionTrialDays`, matching the App Store offer), it reads
> "Subscribing ends this trial and starts a new 7-day free trial." instead (owner, 2026-11-03).
<!-- COMPANION-CURRENT-NOTE-END -->

## ADR-IOS-040: Zero (BYOK) Plan in the IAP Plan Picker — Three-Tier, Display-Only Naming

**Date:** 2026-06-10
**Status:** Accepted
**Context:** the BYOK pricing pages work Phase 3; global ADR-025 (explicit-zero
priority budget → slow queue). The BYOK plan (Apple products
`ai.tabmail.byok.monthly`/`.yearly`) ships as the cheapest, first-listed tier:
no priority AI budget, AI via the user's own keys or the throttled queue.

**Decisions:**
1. **Ranks renumber to Unknown=0 / BYOK=1 / Basic=2 / Pro=3** —
   `StoreKitManager.tierRank(for:)` (product ID) and `tierRank(forTier:)`
   (backend tier string), matching billing-worker/apple-webhook ranks. All
   upgrade/downgrade direction logic (PlanCard buttonLabel, entitlement
   best-plan pick) is rank-driven; no binary `isPro` branching remains.
2. **Display-only naming (D6):** user-facing label is "Zero";
   `StoreKitManager.displayPlanName(forTier:)` maps "BYOK"→"Zero" at render
   time ONLY. `planName(for:)` keeps returning backend-facing "BYOK" because it
   must equal `AccountInfo.planTier`. Internal ids stay byok/BYOK everywhere
   (product IDs, KV plan_name, planQuotas). Site precedent: the site's pricing display
   (pricing.js), the site's tier display (dashboard.js).
3. **Plan picker sorts by explicit tier order** (Zero → Basic → Pro), not by
   price — "BYOK happens to be cheapest" is not a contract.
4. **Trial gating is per-product intro offer, not group eligibility alone:**
   `checkTrialEligibility()` reads eligibility from the first product that HAS
   an introductory offer (Zero has none and sorts first — `products.first`
   would report ineligible and hide the Basic/Pro "2 weeks free" badge).
   PlanCard shows trial badge/label only when group-eligible AND the product
   carries an intro offer (suppresses it on Zero). Zero NEVER has a trial (D8).
5. **Cost disclosure (D7):** the plan picker footnotes carry the same note as
   the site FAQ — provider API bills can be significant; TabMail's own AI
   infra (Basic/Pro) is generally 10–100× cheaper for the same usage.
6. **Quota shows N/A for Zero** (dashboard): a percentage of a zero budget is
   meaningless; sublabel explains no-priority-budget. Daily-quota chart already
   hides via `maxMonthlyCostCents > 0`.
7. **Configuration.storekit group levels fixed to Apple's convention** (level
   1 = highest service tier): Pro=1, Basic=2, BYOK=3. The file previously had
   Basic=1 < Pro=2 (inverted). Local-testing only; ASC group order must be set
   to match (Pro highest → Basic → Zero lowest). Verify upgrade/downgrade
   direction during the sandbox IAP smoke before release.
8. **No `storeKitConfiguration` on any scheme** — verified 2026-06-10: the
   simulator loads REAL App Store product metadata (live ASC prices/names)
   without any local StoreKit configuration, which is exactly what the
   plan-picker screenshots (12-15) should show. Pinning the local
   Configuration.storekit would risk screenshots rendering placeholder
   prices. The file remains for optional manual StoreKit-testing in Xcode
   (e.g. sandbox-verifying group-level upgrade/downgrade direction).

**Related:** global DECISIONS.md ADR-025; the BYOK pricing pages work§7.

---
