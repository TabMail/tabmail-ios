# IOS-BILLING-002

> **Post-freeze record.** Added 2026-08-12, after the 2026-08-09 hierarchy freeze, through the
> amendment surface in `Scripts/compact_known_issues.rb`. It has no row in
> `known-issues-pre-hierarchy-2026-08-09.txt` and is deliberately not regenerated from that archive.

- Register classification: `open`
- Disposition: 🛠 **FIX CANDIDATE (2026-08-15, `814fcd26e`)** — the client implementation and
  invariant-level tests are committed on the issue branch. The record stays open until the primary
  agent's serialized iOS queue validates the exact commit and an exact-diff Claude review is
  obtained; the first review attempt was blocked by Claude Code's weekly quota.

## Status

🛠 **FIX CANDIDATE — the current source contract reaches a shipped client that cannot distinguish a
restored subscription from one permanently lost.** `POST /account/cancel-deletion` returns a
four-valued `subscription_outcome`, but iOS through released `v1.7.9` decodes only `status`/`error`
and discards the entire response body. A user whose subscription lapsed irrecoverably during the
grace period therefore sees the same silent success as one whose subscription came back.

**Reachability boundary, re-verified 2026-08-15.** The earlier claim that the field existed only in
unpushed worker commits is stale: current `tabmail-billing-worker` `origin/main` at `d0b9f12` returns
the field and its focused contract tests pass 19/19. Current iOS `origin/main` at `98dde448b` and the
released `v1.7.9` tag both drop it. This proves the source-contract path and shipped-client gap. It
does **not** prove that the authenticated handler carrying that worker commit is deployed: worker
record `BW-VERIFY-001` says cancellation/deletion have never run against live Stripe, and only
unauthenticated 401 probes exist. Do not cite this record as live-endpoint verification.

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

**The pre-fix client side, re-verified 2026-08-15.** Two independent reasons the value cannot reach
the UI:

1. `BillingClient.CancelDeletionResponse` declares only `status: String?` and `error: String?`. It is
   a plain synthesized `Decodable` with no custom `init(from:)` and no `CodingKeys`, so Swift
   silently ignores the unknown `subscription_outcome` key.
2. `RootView.cancelDeletion()` discards the decoded value outright —
   `_ = try await BillingClient().cancelAccountDeletion()`. It branches only on thrown errors and on
   HTTP 409/404. Even `status` is never read.

`cancelAccountDeletion()` has exactly one caller (`RootView.cancelDeletion`), reached from two
`DeletionBanner` placements in `RootView`. Census run by invocation form over `TabMail/`.

**The one useful consequence of the pre-fix shape:** because the decoder ignores unknown keys and
the body is discarded, **shipped builds cannot crash or misbehave when the new field arrives.** The
worker change is backward-compatible and the iOS fix remains backward-compatible with a deployed
worker that omits the optional field.

## 2026-08-15 fix candidate and proof boundary

Commit `814fcd26e` adds the additive wire key as `String?`, then exposes one named predicate that is
true only for the exact literal `expired_during_grace`. It deliberately does **not** use a raw-value
enum: missing, `null`, `restored`, `none`, `unknown`, and future string values all decode normally
and stay silent. `RootView.cancelDeletion()` consumes the response before dismissing the banner. On
established loss it presents an alert from the stable root view: the account was kept, the
subscription ended during the grace period and could not be restored, and **Choose a Plan** posts
the existing `navigateToPlanPicker` route. No entitlement, subscription, persistence, or provider
state is written, preserving root ADR-023's webhook-sole-writer boundary.

Existing recovery remains intact and was audited before adding the alert: foreground/sign-in
`/whoami` revalidates `AISubscriptionGate`; a closed gate exposes **Start Your Free Trial** in the
sidebar and **Subscribe** in the account dashboard, both reaching `PlanPickerView` in one ordinary
gesture. That fallback made a repair/new billing mechanism unjustified, but it did not explain why
the account succeeded while the paid subscription ended. The alert supplies only that missing
causal result and reuses the existing plan route.

`CancelDeletionResponseDecodableTests` pins exact loss, all three healthy current outcomes,
missing/null keys, and an additive future outcome. The tests explicitly cover the pure predicate
consumed by `RootView`; they do not render SwiftUI or exercise the final alert/navigation hop.
Static parsing and diff hygiene pass. Targeted SwiftLint adds no violation over the pre-existing
file baseline. The primary agent still owns the serialized iOS proof: run the whole suite with the
predicate inverted for red sensitivity, restore exact commit `814fcd26e`, then run the same suite
green plus compile/build validation. Do not promote this record to `resolved` until that evidence
and the exact-diff Claude review exist.

**Attribution correction.** The old unpushed SHAs named here were backup-history references, not
current `origin/main`. The current worker history containing the outcome is pushed: `14a76f8`
introduced the classified no-op result; `42166f1` added the cancelled-subscription roster and exact
loss detection; later commits on current main narrow the roster and record the live-verification
boundary. The client gap and candidate fix are solely in `tabmail-ios`; no worker change or deploy
is part of this issue.

## Accepted residuals and adjacent findings

- A malformed non-string `subscription_outcome` makes synthesized decoding fail and preserves the
  existing Retry surface. The worker's TypeScript union is closed and its 404 retry behavior is
  fail-safe; adding a lossy custom decoder is not justified.
- If the first successful response is lost and a retry receives the existing already-resolved 404,
  the client no longer has the outcome to present. Persisting or re-querying it would require a new
  backend contract.
- The worker reports `restored` as soon as any subscription is restored, before checking whether a
  second rostered subscription lapsed. A multi-subscription partial loss can therefore be
  under-reported. The iOS client must present the returned contract, not infer provider state.
- RootView's other alerts can race this in-memory alert. That rare collision degrades to the shipped
  silent fallback and ordinary plan surfaces; an alert queue is disproportionate to this issue.
- Actual deployment and authenticated live-handler behavior remain unverified per `BW-VERIFY-001`.
- Separate audit findings are not folded into this fix: the account-deletion UI promises automatic
  cancellation while the deletion worker handles Stripe only (Apple IAP requires separate
  disposition), root ADR-020 still says deletion is manual with no endpoint, and the worker's old
  additive-safety comment will become historical after this client ships.

**Related:** `IOS-BILLING-001` — the sibling case where a billing-surface failure is log-only and
leaves a control with no visible result. Same shape: the backend knows something the user needs and
the UI never says it.
