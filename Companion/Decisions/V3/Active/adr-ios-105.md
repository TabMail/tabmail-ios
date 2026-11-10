## ADR-IOS-105: The App Sells No Plan to an Account Whose Web Subscription Has Not Ended

**Status:** Active (2026-11-09; owner ruling). iOS side of global DECISIONS.md ADR-037 ("a
subscription is managed only where it was bought"). Issue #557.

**Context:** TabMail sells the same plans on the website (Stripe) and in the app (Apple in-app
purchase). The plan picker offered in-app subscriptions to every account, so an account already
paying on the website could buy a second, overlapping subscription from Apple and pay twice. The
server used to hand such a purchase to an automatic Stripe-to-Apple migration; the owner replaced
that with no crossing at all: a subscription is managed only on the side it was bought, and the
other side opens once it has ended.

**Decision:**
1. **Live web subscription** = `subscription_provider == "stripe"` and `subscription_status` is not
   `canceled` and not `incomplete_expired` (`AccountInfo.hasLiveWebSubscription`,
   `AccountPlanConfig.endedWebSubscriptionStatuses`). It reads only those two `/whoami` fields, never
   `has_subscription`: an unpaid, incomplete or paused subscription grants no access and is still
   live. A missing status counts as live. No new wire field.
2. **The plan picker hides every purchase option** for such an account (billing toggle, plan cards,
   footnotes, the Apple disclosure and Restore Purchases) and shows one plain sentence in their
   place: "Your subscription is managed on tabmail.ai, so it can't be changed in this app. For help,
   contact support." (wording approved 2026-11-09; `PlanPickerView.webManagedNote(for:)`, rendered
   with `Text(verbatim:)` so the domain is never a link). No link and no button: outside the US storefront App Review guidelines
   3.1.1(a) and 3.1.3 forbid calls to action toward other purchase methods, and a statement of where
   a subscription is managed is not one. 3.1.3(b) holds because the plans are still sold in the app
   to everyone else.
3. **Everything else is unchanged:** Apple subscribers keep the Cancel / Manage Subscription path;
   the pending-cancellation and pending-downgrade banners stay; a signup-trial or no-subscription
   account can buy.
4. **The plans stay on sale until `/whoami` has loaded.** Hiding them until then would block every
   buyer whenever the server is slow or unreachable. A purchase that still arrives for an account
   with a live web subscription (this window, or an app version from before this decision) is caught
   server-side: access is kept, an alert is raised, and support cancels and refunds the web
   subscription by hand.

**Dependency:** the server sends `subscription_provider` and `subscription_status` only while the
subscription grants access until its no-access branch sends them too (a separate server change).
Until then the unpaid, incomplete and paused cases reach the app as a plain no-subscription body and
the plans stay on sale for them; past due already arrives, since it keeps access. The app needs no
change when the server change lands.

**Rejected:** a link or button to the website (forbidden outside the US storefront; a
storefront-specific variant was judged not worth its checks); hiding the buttons with no
explanation (looks broken); a new `/whoami` flag (the two existing fields already say it).
