# Age and terms screen, App Store age check, and the push/sync consent gate

**Since:** 2026-10-08 (owner, COPPA audit). Root decision: monorepo root `DECISIONS.md`
ADR-034.

## Where it lives

- `TabMail/Services/AgeAndTermsConsent.swift` — constants (`minAgeYears`, `birthYearsShown`,
  `ineligibleBlockDays`, `legalVersion`), the `hasCompletedConsentGate` key
  (`completedKey`), `isComplete()`, `agreementMetadata(at:)` (the `user_metadata` flags; no birth
  date), `ageInYears` / `evaluate` (the website's `consent.js` rule exactly: a birthday not yet
  reached this year does not count, 29 Feb counts on 1 Mar in common years), `check` (the
  screen's call: `evaluate`, and an `.ineligible` result blocks the device), and the 30-day
  failed-check block (`blockDevice` / `isDeviceBlocked`, stores ONLY the expiry in
  `ageCheckIneligibleUntil`, removed once lapsed).
- **Plain Gregorian years and English month names** (`AgeAndTermsConsent.calendar`,
  `birthYears(today:)`, `monthNames`), like the website; never `Calendar.current`, which follows
  the phone's calendar setting (review 2026-10-08: a phone set to another calendar showed other
  year numbers and got wrong answers). Owner 2026-10-08: English only, keep it simple; no locale
  or other-calendar handling.
- `TabMail/Views/ConsentGateView.swift` — neutral Month/Day/Year menus with no default, terms
  checkbox, ineligible view. A failed check discards the date, blocks the device, calls billing
  `POST /account/age-ineligible` once (`BillingClient.requestAgeIneligibleDeletion`), then
  `onIneligible` signs out (prod) or exits demo. Keep the legal version constant in step with
  the website's `public-config.js` `LEGAL_VERSION_ISO`.
- `TabMail/Services/AppStoreAgeCheck.swift` + `TabMail/Views/AppStoreAgeGateView.swift` — Apple's
  Declared Age Range API. `isEligibleForAgeFeatures` (iOS 26.2+) says whether the region is
  regulated (TX/UT/LA today); only then `requestAgeRange(ageGates:)`. `classify`: upper bound < 18 or
  nil lower bound → `.minor` (blocked); lower ≥ 18 → `.allowed`; declined → `.unconfirmed` (blocked,
  Try Again); `status(for:)` maps Apple's `Response`, `Status.blocksApp` is RootView's routing
  test. Region-check error → `.notChecked`; an age-range request error → `.unconfirmed`. Runs at launch and on foreground from `RootView`,
  ahead of demo and email-only modes. Apple documents that the system caches the answer until the
  person's next birthday, so repeat asks do not re-show the system sheet (still confirm in a sandbox
  account in a regulated region, including background then foreground with no block). Before iOS
  26.2 nothing is asked (`isEligibleForAgeFeatures` needs 26.2). The block covers the screens only
  (owner 2026-10-09).
  Entitlement `com.apple.developer.declared-age-range`; the App
  ID needs the Declared Age Range capability in the developer portal or automatic signing strips it.
- `RootView` starts Device Sync and push restore on `.onChange(of: canStartAccountServices)`
  (session AND consent), not on sign-in. `DeviceSyncService.connect()` and
  `PushNotificationService.registerDeviceWithWorker` / `subscribeAccount` /
  `registerDeviceAccountRecord` refuse until `AgeAndTermsConsent.isComplete()`; removal paths stay
  open. The push and device-sync workers enforce the same rule server-side (`consent_required`).
  DEBUG seam: `PushNotificationService._setAgeAndTermsConsentForTesting` (test initializers default
  it to true, so existing push tests are unaffected). `AgeAndTermsPushGateTests` sets it to `nil`
  and drives the real `completedKey` flag, so the production predicate is what it tests.
- Every reader of the flag uses `AgeAndTermsConsent.completedKey` (RootView `@AppStorage`,
  `ScreenshotMode`, `ActiveAIQueue`); a renamed literal would leave push and sync shut silently.

## Traps

- SwiftUI has no `text-wrap: balance`. The owner dislikes a single word alone on the last line, so
  rephrase or split into paragraphs and render (light + dark) before shipping copy on these screens.
- App Store 18+ rating does NOT exempt the app from Declared Age Range in regulated regions.
- Significant updates (Utah/Louisiana; owner 2026-10-09: every major.minor bump counts):
  `AppStoreAgeCheck.SignificantUpdate` decides, `acknowledgeSignificantUpdate` (iOS 26.4+, run after
  an `.allowed` check) acts. It stores only the last handled major.minor under
  `AppStoreAgeCheck.significantUpdateVersion`. The first run records the version without showing
  anything (nothing to compare); a new major.minor asks Apple's `requiredRegulatoryFeatures` and, if
  required, shows `showSignificantUpdateAcknowledgment` before recording; a failure records nothing
  and asks again on the next foreground.

Tests: `AgeAndTermsConsentTests`, `SignificantUpdateStorageTests` (first-run record and repeat),
`AgeAndTermsPushGateTests`, `AgeAndTermsDeviceSyncGateTests`.
Not covered by a test (view wiring; owner smoke list): RootView's `canStartAccountServices` handler
starting Device Sync and push after sign-in or consent, the eligible path clearing the entered
date from the view's state, and the Apple-facing arm of `acknowledgeSignificantUpdate` (asking
`requiredRegulatoryFeatures` and showing the notice needs a regulated-region sandbox account).
