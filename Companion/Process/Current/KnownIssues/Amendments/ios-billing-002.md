# IOS-BILLING-002

> **Post-freeze record.** Added 2026-08-12, after the 2026-08-09 hierarchy freeze, through the
> amendment surface in `Scripts/compact_known_issues.rb`. It has no row in
> `known-issues-pre-hierarchy-2026-08-09.txt` and is deliberately not regenerated from that archive.

- Register classification: `open`
- Disposition: 🔓 **OPEN (2026-08-12)** — deferred by the owner, to revisit when the next build is
  planned. The backend half is already built; only the client surface is missing.

## Status

🔓 **OPEN — the client cannot tell a restored subscription from one permanently lost.**
`POST /account/cancel-deletion` now returns a four-valued `subscription_outcome`, but iOS discards
the entire response body, so a user whose subscription lapsed irrecoverably during the grace period
sees exactly the same silent success as one whose subscription came back.

**Not yet reachable in production.** `subscription_outcome` does not exist in the deployed billing
worker (`git grep -c subscription_outcome origin/main -- src` returns 0 hits); it is introduced by
unpushed commits. This record describes a gap that opens when those deploy, not a live defect.

## Subsystem and search terms

account deletion; grace period; `BillingClient`; `CancelDeletionResponse`; `cancelAccountDeletion`;
`RootView.cancelDeletion`; `DeletionBanner`; `subscription_outcome`; `expired_during_grace`;
Stripe `cancel_at_period_end`; discarded response body; silent success

## Full detail

**What the backend now returns.** `handleCancelDeletion` in
`tabmail-billing-worker/src/handlers/accountDeletion.ts` responds
`{ status: 'restored', subscription_outcome: <outcome> }`, where outcome is one of:

| value | meaning |
|---|---|
| `restored` | the subscription was still live and `cancel_at_period_end` was reversed |
| `expired_during_grace` | **the subscription passed period end during the grace window and is gone permanently** |
| `none` | there was nothing to restore |
| `unknown` | we could not establish which of the above happened |

⚠️ **`status` is `'restored'` in all four cases.** It describes the *account* being restored, not the
*subscription*. Nothing in the response distinguishes the four outcomes except the field iOS drops.

**Why `expired_during_grace` is not recoverable by the user.** A `canceled` Stripe subscription
cannot be reactivated — `cancel_at_period_end: false` only reverses a *scheduled* cancellation while
the subscription is still live. The only route back is `subscriptions.create`, i.e. a fresh purchase,
which the billing worker deliberately never calls. So the user keeps their account and silently
loses their paid subscription, with no signal at the moment they would act on it.

**How often that can happen.** The exposure is the fraction of the 30-day grace window that falls
after the subscription's period end. Averaged over where in the billing cycle the deletion is
requested, the undo still restores the subscription for roughly **50% of the window on a monthly
plan** and **~95.9% on an annual plan**. ⚠️ These two figures were derived by the billing-worker
audit agent and are recorded here as reported; they were **not** independently re-derived, though
they are internally consistent with `1 − (15 / cycle_days)`. Treat them as an order-of-magnitude
statement, not a measurement.

**The client side, verified 2026-08-12.** Two independent reasons the value cannot reach the UI:

1. `BillingClient.CancelDeletionResponse` declares only `status: String?` and `error: String?`. It is
   a plain synthesized `Decodable` with no custom `init(from:)` and no `CodingKeys`, so Swift
   silently ignores the unknown `subscription_outcome` key.
2. `RootView.cancelDeletion()` discards the decoded value outright —
   `_ = try await BillingClient().cancelAccountDeletion()`. It branches only on thrown errors and on
   HTTP 409/404. Even `status` is never read.

`cancelAccountDeletion()` has exactly one caller (`RootView.cancelDeletion`), reached from two
`DeletionBanner` placements in `RootView`. Census run by invocation form over `TabMail/`.

**The one useful consequence of the above:** because the decoder ignores unknown keys and the body is
discarded, **shipped builds cannot crash or misbehave when the new field starts arriving.** The
backend change is safe to deploy ahead of any client work — which is why this is registered rather
than treated as a deploy blocker.

**Remedy, when revisited.** Add `subscription_outcome: String?` to `CancelDeletionResponse`, return
it from `RootView.cancelDeletion()` instead of discarding it, and have `DeletionBanner` present a
distinct result for `expired_during_grace` — the user needs to know they must resubscribe. Decode it
as `String?` and branch with a `default`, **not** as a Swift enum: a raw-value enum makes a future
backend value a decode failure, converting an unrecognised outcome into a failed cancel. `restored`
and `none` warrant no message; `unknown` should say nothing rather than guess.

**Attribution.** Client-side gap in `tabmail-ios`. The backend half landed in
`tabmail-billing-worker` as `6c4170d`, `b83baec`, `ed46e0e` (returns the field), `3217778` (records
the cancelled-subscription roster) and `71e8537` (makes `expired_during_grace` exact rather than
heuristic). None of those are pushed as of 2026-08-12.

**Related:** `IOS-BILLING-001` — the sibling case where a billing-surface failure is log-only and
leaves a control with no visible result. Same shape: the backend knows something the user needs and
the UI never says it.
