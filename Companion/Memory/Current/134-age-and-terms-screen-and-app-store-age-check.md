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
  checkbox, ineligible view. A failed check discards the date, blocks the device and sends billing
  `POST /account/age-ineligible` (`BillingClient.requestAgeIneligibleDeletion`). OK waits for that
  request's answer and signs out (prod) only once billing has answered (owner 2026-10-09 handshake,
  `AgeAndTermsConsent.deletionHandshake`): 2xx, a definitive 4xx refusal, or a session that is gone
  or revoked (`.unauthorized`) signs out; no answer (connection failure, timeout, 429, 5xx:
  `BackendError.isRetriable`) keeps the person on the refusal and the next OK sends it again.
  `requestAgeIneligibleDeletion` reads `TabMailTokenCoordinator.validToken()` itself, so a token that
  cannot be refreshed for now throws status 0 (retry), never `.unauthorized` (`currentAuthToken`
  would fold it into nil and sign out with nothing sent). A request lost to a connection problem is
  therefore sent again; someone who leaves the app on the refusal, or whose session is revoked,
  falls back to the billing sweep (7 days old and unused for 30), as does a request billing refuses
  without queuing it (any 4xx, including a 401 when billing cannot verify the token).
  Demo has no account: OK exits demo at once. Keep the legal version constant in step with
  the website's `public-config.js` `LEGAL_VERSION_ISO`.
- `TabMail/Services/AppStoreAgeCheck.swift` + `TabMail/Views/AppStoreAgeGateView.swift` — Apple's
  Declared Age Range API. `isEligibleForAgeFeatures` (iOS 26.2+) says whether the region is
  regulated (TX/UT/LA today); only then `requestAgeRange(ageGates:)`. `classify`: upper bound < 18 or
  nil lower bound → `.minor` (blocked); lower ≥ 18 → `.allowed`; declined → `.unconfirmed` (blocked,
  Try Again); `answer(for:)` maps Apple's `Response`, `Status.blocksApp` is RootView's routing
  test. `run` passes Apple's two real calls to `decide(isRegulated:askAge:)`. Region-check error →
  `.notChecked`, which `shown(previous:checked:)` turns into "keep what is on screen"; an age-range
  request error → `.unconfirmed`. Runs at launch and on foreground from `RootView`,
  ahead of demo and email-only modes. Apple documents that the system caches the answer until the
  person's next birthday, so repeat asks do not re-show the system sheet. Apple's sheet does not run
  in the Simulator (Apple DTS), so owner 2026-10-09 accepted simulated answers through `decide` in
  place of a device smoke test (`AppStoreAgeCheckSimulationTests`). Before iOS
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
  anything (nothing to compare). A new major.minor first asks `isEligibleForAgeFeatures`: the version
  is recorded only where the rules apply. Where they do not (including a device with no Apple
  Account), nothing is shown and nothing is recorded, so a device the rules apply to later still gets
  this version's notice (2026-11-17, issue #972: with no Apple Account, Apple's
  `requiredRegulatoryFeatures` still listed the notice, and its acknowledgment extension failed with
  `missingDSID`, drew nothing, and its full-screen host took every tap at every launch). Where the
  rules apply it asks `requiredRegulatoryFeatures` and, if required, shows
  `showSignificantUpdateAcknowledgment` before recording; a failure records nothing and asks again on
  the next foreground. `acknowledge(acknowledged:current:isRegulated:requiresNotice:show:record:)` is
  the seam; `acknowledgeSignificantUpdate` passes Apple's calls.
- Apple's notice can stay up and never return (#972, #1010). `AppStoreAgeCheck.Runner.pass` orders
  RootView's age check and the notice: the age check's in-progress flag clears BEFORE the notice is
  awaited, so a stuck notice never skips later age checks; the notice has its own flag, so no second
  notice starts while one is up (2026-11-18). Test: `AppStoreAgeCheckRunnerTests`.
- Stuck notice across launches (owner 2026-11-18, #1010, option chosen with the fallback approved; no
  timer): `SignificantUpdate.inProgressVersionKey` holds the major.minor handed to Apple. An UNASKED
  notice sets it just before `show` and clears it when it returns or throws. A launch that finds it
  set, for ANY version, first asks `isRegulated` (no UI); where the rules no longer apply the marker
  clears and nothing is shown or recorded (#972 rule). Otherwise it makes no unasked call and returns
  `.offerBanner` for the CURRENT version (also when the rules question throws); RootView shows
  `SignificantUpdateBanner` (SignInAgainBanner shape, above `MailNavigationView` beside
  `DeletionBanner`), whose tap calls Apple through the same path (`userAsked: true`). A tapped notice
  never clears the marker, returned or thrown: a return records the version (banner goes), a throw
  keeps the banner, and every later version also goes through the banner (2026-11-19 review ruling;
  the first version of this fix ignored a marker for another version and cleared it after a tapped
  throw). Review fixes (2026-11-19): a tapped notice that fails at any of Apple's three calls returns
  `.offerBanner` at once; an already-handled version with a kept marker still asks `isRegulated` and clears
  the marker where the rules no longer apply (no notice, no banner); a launch whose age lookup throws
  (`.notChecked`) still runs the step when `SignificantUpdate.hasStalledNotice()` (via `Runner.pass`'s
  `hasStalledNotice`), which with the marker set never calls Apple unasked. Apple documents a throw only "if the feature isn't available"; whether a user dismissal
  returns or throws is undocumented. The banner state is RootView
  `@State` set from the ZStack `.task`, so it appears when onboarding ends without a relaunch. Killing the app mid-notice also yields the banner (accepted). The
  marker is app state, not user data. Tests: `SignificantUpdateStuckNoticeTests`.

Tests: `AgeAndTermsConsentTests`, `AppStoreAgeCheckSimulationTests` (simulated App Store answers),
`AgeIneligibleDeletionTokenTests` (refusal handshake through the real token path),
`SignificantUpdateStorageTests` (first-run record and repeat), `AppStoreAgeCheckRunnerGuardTests` (one age check at a time, notice only after `.allowed`, RootView source fence),
`SignificantUpdateAcknowledgmentTests` (Apple's answers through `acknowledge`: no notice and no record
where the rules do not apply, shown then recorded once they do, failures record nothing),
`SignificantUpdateMarkerStorageTests`, `AppStoreAgeCheckRunnerTapTests`, `SignificantUpdateBannerWiringTests`,
`AgeAndTermsPushGateTests`, `AgeAndTermsDeviceSyncGateTests`.
Not covered by a test (view wiring; owner smoke list): `ConsentGateView.leave` (OK waits for the
deletion request, resends on no answer, shows the connection message, signs out only after an answer),
`RootView.checkAppStoreAge` applying `shown(previous:checked:)`, RootView's `canStartAccountServices` handler
starting Device Sync and push after sign-in or consent, the eligible path clearing the entered
date from the view's state, and Apple's real calls inside `acknowledgeSignificantUpdate` (their
answers are tested through `acknowledge`; showing the real notice needs a regulated-region sandbox
account).
