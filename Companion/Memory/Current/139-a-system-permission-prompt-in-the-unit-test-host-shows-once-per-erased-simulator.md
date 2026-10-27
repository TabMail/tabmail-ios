# A system permission prompt in the unit-test host shows once per erased simulator

Found 2026-10-26 (guided tutorial, full unit suite before merge; ADR-IOS-038 c4 bullet).

## What happened

The full `TabMailTests` run on a freshly erased simulator failed one test, the tutorial splash
fixture, at its precondition "the test host's scene is active". The identical rerun passed, and a
scene-activation observer saw no deactivation at all.

The simulator's privacy database explained it:
`~/Library/Developer/CoreSimulator/Devices/<UDID>/data/Library/TCC/TCC.db`, table `access`, had
`kTCCServiceAddressBook | ai.tabmail.ios | auth_value 0 | auth_reason 13`, written at the moment the
first run's app was killed. Reason 13 is a prompt that was shown and cancelled. iOS records it as
denied, so no later run on that simulator shows the prompt again.

The prompt came from `DraftOpenReloadTests`, which mounts `ComposeView` in a window. Its `onAppear`
calls `ContactSearchService.requestAccess()`, a fire-and-forget Contacts request. Nothing in a unit
test answers the alert, and the scene stays inactive for the rest of the process. SwiftUI does not
start a newly shown view's `.task` in an inactive scene, so the only test that waited on one failed.
Every other test is indifferent to scene activation, which is why the prompt went unnoticed.

## The rule

The unit-test host answers system permission requests itself: `TestPermissionPrompts`
(TabMailTests/Infrastructure) silently denies notification and Contacts requests for the whole
process, installed from `ProcessGlobalTestState.withLock`. If a test starts reaching another request
(Calendar `requestFullAccessToEvents`, microphone `requestRecordPermission`), add it there. A
stand-in scoped to one test cannot work: the request is queued work that outlives the test.

## How to diagnose the next one

A failure that appears only in the first run after `simctl erase` and never again is a one-time
prompt. Query the simulator's TCC.db for the app's rows (`select service, auth_value, auth_reason,
last_modified from access where client='ai.tabmail.ios'`): a reason-13 row names the service. To
reproduce, erase the simulator again before each run. Notification permission is not in TCC.db.
