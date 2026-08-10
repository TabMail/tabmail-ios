# IOS-BILLING-001

> Routed from `KNOWN_ISSUES.md` line 1449 during the 2026-08-09 hierarchy split. The exact pre-split source is hash-pinned in [`known-issues-pre-hierarchy-2026-08-09.txt`](../../History/KnownIssues/known-issues-pre-hierarchy-2026-08-09.txt) (`SHA-256 513497704ad37e977e2fb86e4623e956e6f1ca99844122948ff74995dfa9a309`).

- Register classification: `accepted`
- Original row SHA-256: `12e736a607a3fd3eaecbddbce497152da89350b0783e9ba924aa8d377490d467`

## Status

📋 **ACCEPTED LIMITATION (2026-08-09)** — failure to present Apple's subscription-management sheet is log-only on both account surfaces, leaving the button with no visible result

## Subsystem and search terms

StoreKit; subscription management; `AppStore.showManageSubscriptions`; `PlanPickerView`; `AccountDashboardView`; silent failure

## Full detail

`PlanPickerView` and `AccountDashboardView` both catch `AppStore.showManageSubscriptions(in:)` errors, print them, and expose no alert or inline status. The user remains on the same screen and can retry, use the App Store's subscription settings directly, or manage the subscription later; purchase and restore failures have separate visible states and are not part of this row. This is a missing error surface, not a billing-state mutation or charge error.
