
## Zero (BYOK) Plan — IAP Surface (ADR-IOS-040)

- Products `ai.tabmail.byok.monthly`/`.yearly` — tier string "BYOK" everywhere internal; **only display renders "Zero"** via `StoreKitManager.displayPlanName(forTier:)`. Ranks: Unknown=0/BYOK=1/Basic=2/Pro=3 (`tierRank(for:)`/`tierRank(forTier:)`).
- `checkTrialEligibility()` must read a product **with** an intro offer (Zero has none and sorts first). PlanCard trial badge = group-eligible AND `product.subscription?.introductoryOffer != nil`.
- `Configuration.storekit` group levels follow Apple's convention (1 = highest): Pro=1, Basic=2, BYOK=3 (was inverted Basic=1/Pro=2 before 2026-06-10). Local testing only; ASC group order must match (Pro → Basic → Zero). Sandbox-verify upgrade/downgrade direction before release.
- **No scheme sets `storeKitConfiguration`** (verified 2026-06-10): the simulator loads REAL ASC sandbox product metadata (live prices/names) with no local config — plan-picker screenshots 12-15 show actual store prices. Don't pin Configuration.storekit to a scheme; it would swap in placeholder prices. The file is for manual Xcode StoreKit-testing only.
- Dashboard quota card shows **N/A** for `planTier == "BYOK"` (no priority budget); daily-quota chart already hidden via `maxMonthlyCostCents > 0`.

---
