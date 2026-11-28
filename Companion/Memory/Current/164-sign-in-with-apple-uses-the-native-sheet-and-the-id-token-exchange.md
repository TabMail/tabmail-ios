# 164 — Sign in with Apple uses Apple's own sheet and the id_token exchange

**Status:** Current (2026-11-28). Applies to every change to TabMail sign-in, the Supabase Apple provider
settings, `Info.plist` URL schemes, or the Apple sign-in entitlement.

## What the app does

- `AppleIDSignIn` (`TabMail/Services/AppleIDSignIn.swift`) shows Apple's own sheet
  (`ASAuthorizationAppleIDProvider`) with the email scope only (no full name).
- Every attempt makes a fresh raw nonce (`makeRawNonce`: 32 random bytes, base64url, 43 characters). The sheet
  request carries its SHA-256 hex (`sha256Hex`), so a retry never reuses a nonce.
- `TabMailAuthService.signInWithApple` sends the sheet's identity token to Supabase
  `POST /auth/v1/token?grant_type=id_token` with provider `apple`, the token, and the RAW nonce. Supabase hashes
  the raw nonce and compares it with the token's `nonce` claim. Google and Microsoft id_token sign-ins send no
  nonce (the body is exactly the provider and the token).
- A closed sheet (`CancellationError`) is silent and sends nothing; a failed sheet or a missing token sends
  nothing either.
- A successful exchange writes the session once (`installNewSession`), with `clearAIChoiceIfNoMailAccount`
  before it and the billing sync after it, as for the other id_token providers. There are now two session-write
  sites (id-token, OTP); see the note in ADR-IOS-038.

## What was removed

- The web sign-in (`/auth/v1/authorize` through `ASWebAuthenticationSession`), its callback page, and the
  `tabmail-ios` URL scheme. `Info.plist` keeps exactly the Google and Microsoft redirect schemes and `mailto`.
- The entitlement `com.apple.developer.applesignin` is `["Default"]`.

## The server condition (release blocker)

The Supabase Apple provider's Client IDs must list the app's bundle id `ai.tabmail.ios`, after the web Service
ID (the web sign-in uses the first entry). Without it every Apple sign-in in the app fails with
"Unacceptable audience in id_token". The Apple rotation workflow in tabmail-release-helpers writes this list
(`APPLE_NATIVE_CLIENT_IDS` in `rotate-apple-secret.yml`). A build with this sign-in must not ship before the
live list includes `ai.tabmail.ios`.

## Same person, same account

Supabase finds the identity by the Apple `sub`, which Apple keeps the same for every app and Service ID of one
team, so someone who first signed in on the web reaches the same TabMail account. Check it on a device before
a release: the `/whoami` user id of a test Apple ID first used on the web stays the same.

## Known limitation

The sheet offers only the device's Apple Account. Someone whose TabMail account is on a different Apple ID
reaches a different account; signing in with the email code reaches theirs.

## Account deletion stops the app's use of the Apple Account (2026-11-28)

Apple asks an app that offers Sign in with Apple to revoke the user's authorization when the account is deleted.
The revoke itself happens in billing (`/auth/token` with a fresh authorization code, then `/auth/revoke` with the
refresh token); the app only supplies the code.

- Which account: `AppleIDSignIn.isAppleAccount` reads `app_metadata.providers` from the app's own access token
  (decoded, not verified; it only decides whether to show the sheet). Both screens read it as the operation's
  first step, because the deletion clears the session.
- Settings deletion: `AppleIDSignIn.scheduleDeletion` runs Apple's sheet (`makeRevokeRequest`: no scopes, no
  nonce) once, inside the coordinator's `scheduleDeletion` step, after every subscription check and the final
  `/whoami` re-read, so the five-minute code is fresh. The code goes only into the `/account/delete` body
  (`apple_authorization_code`); without a code the request has no body, as before.
- A sheet that is closed or fails, or gives no usable code, still sends the deletion without a code
  (`freshAuthorizationCode` never throws and never logs the code).
- The answer's `apple_authorization_revoked` reaches the confirmation through
  `ExecutionResult.scheduled(deletionDate:appleAuthorizationRevoked:)`; the status read-back after a lost answer
  gives nil. For an Apple account, unless the answer is `true`, the confirmation shows Apple's manual path (Settings, your name, Sign in
  with Apple, TabMail, Delete) and links support article 102571 (`showsManualStopLine`). The confirmation is
  `AccountDeletionConfirmation`, shown after the sign-out as a root sheet from `AccountDeletionReceipt`
  (ios#1676, memory 165); the receipt carries `showsAppleManualStop` next to the date, so the manual path shows
  there too, and in the deletion screen's own confirmation when the local sign-out fails.
- Failed age check (`AgeAndTermsConsent.RefusalExit`, held by `ConsentGateView` as its state; the request goes
  through `AgeAndTermsConsent.sendDeletionRequest`): the request at the failed check carries no code. On OK, once
  billing has acknowledged the deletion with a 2xx, an Apple account sees the sheet once and the request is sent
  one more time with the code (billing adopts the existing deletion). A refusal (409, 400) or a gone session signs
  out with no sheet; no answer stays on the refusal with no sheet. The sheet never changes whether the person is
  signed out.
- The code request never replaces the deletion's own answer, and the sign-out decision is kept: when signing out
  fails on the device (Keychain), the next OK signs out again at once, with no request and no second sheet. (A
  first version stored the code request as the deletion's answer, so its 503 could keep a confirmed deletion on the
  refusal, or its 2xx could bring the sheet back.)
- No deadline on Apple's sheet (decided 2026-11-28): `AuthorizationController.performRequest` ends with a
  credential or an error (closing the sheet is `.canceled`), and sign-in awaits the same call with no deadline. A
  timer would cut off a person still entering their password and drop the code Apple then issues.

## Tests

`AppleIDSignInTests` and `AppleIDSignInSessionTests` (TESTS.md, "Sign in with Apple"); the deletion revoke in
`AppleSignInRevokeTests`, `AppleSignInRevokeWireTests` (the real `BillingClient` over `FakeHTTP`, with a synthetic
session under `.processGlobalState`) and `AppleSignInRevokeWiringTests`. Both sign-in suites run under
`.processGlobalState`, because they share the process-wide transport stand-in
(`TabMailAuthService._setSignInTransportForTesting`, which covers the exchange and the billing sync).
