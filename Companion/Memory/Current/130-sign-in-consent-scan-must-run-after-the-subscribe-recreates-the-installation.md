# Sign-in consent scan must run AFTER the subscribe recreates the installation

**Symptom (owner, 2026-09-14):** after testing sign-out and signing back in, the
"Fix Smart Notifications" banner asking to re-consent Gmail and Outlook push did
not appear until hours or days later, so it read as a spontaneous consent loss
or a refresh bug in the push worker. Neither is the case.

**Why re-consent is required at all.** Sign-out releases this device's
installation on the push worker (memory 124), and the worker's D1 registry
erases the device-owned classifier consents together with that installation
(push-worker migration `0018_device_owned_consents`, trigger
`push_erase_installation_consents`). The status probe answers `missing` for
every account afterwards. That is designed privacy behaviour, not a defect, and
it is pinned on the worker side by `test/deviceConsent.d1.spec.ts`.

**The actual defect: an ordering race.** `RootView` and `MailNavigationView`
fire `checkPushConsentStatusForForeground` on the sign-in transition. Those
scans reach the worker before `/subscribe` has claimed a fresh installation,
so every probe answers 409, the first-scan safety (memory 076) treats an
all-throws scan as "unknown" and posts nothing, and nothing re-ran the scan
until the next scene-phase foreground pass. The banner is passive; it only
changes on a scan that posts.

**Fix.** `TabMailAuthService.restorePushRegistrationAfterSignIn` runs the
consent scan after `subscribeAllAccounts` returns, so the banner appears within
seconds of sign-in. Note `subscribeAllAccounts` does NOT call
`registerDeviceWithWorker`: the worker's `/subscribe` claims the installation
itself (`authoritySubscribeAdmission`), which is why the scan may follow it
directly.

**Test.** `PushConsentScanTests.signInRestoreScansAfterTheSubscribe` drives the
restore through a service wired to the fake push transport with a checker that
models the worker (fails until `/subscribe` has landed, then `missing`). It
pins the user-visible invariant: a completed, authenticated restore surfaces the
missing consent by itself. Reversing the two awaits, removing the subscribe, or
removing the scan all redden it.

**Trap for the next reader.** A test that only asserts "the scan ran during
restore" stays green with the awaits reversed. Pin the ORDER through the
worker model, not the presence of the call.
