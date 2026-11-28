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

## Tests

`AppleIDSignInTests` and `AppleIDSignInSessionTests` (TESTS.md, "Sign in with Apple"). Both suites run under
`.processGlobalState`, because they share the process-wide transport stand-in
(`TabMailAuthService._setSignInTransportForTesting`, which covers the exchange and the billing sync).
