# IOS-PUSH-001

<!-- KNOWN-ISSUES-AMENDMENT-BEGIN -->
> **Current authority (2026-08-28):** the app/NSE session-resurrection and cross-login-clobber
> residual described in the chronology below is closed by merged iOS PR #95. The permanent
> account-deletion server purge is also shipped. Ordinary sign-out still does not release APNs state
> or add a client/server handshake. See the final update at the end of this amendment.

## 🟡 NARROWED — SAME-SESSION REMOVAL FIXED; SIGN-OUT HANDOFF REMAINS OPEN (2026-08-14)

Worker-owned provider ownership/subscription, dispatch, legacy-device, consent, and IMAP cleanup now persist as compact idempotent debt across offline removal/relaunch while the original TabMail session remains available; stale local identity and credentials are fenced at the authoritative commit.

Before deleting a row, `prepareRemovedAccountCleanup` persists a separate generation containing the minimum names needed after the row is gone: account ID, email/provider, original worker user ID, CalDAV config IDs, captured outbox directory names, and remaining action names. It never persists an OAuth token or message content and has no time-based expiry. Exact-generation cancel handles a failed GRDB commit and also clears any in-memory token; exact-generation merge prevents a prepare/cancel that overlaps network awaits from being lost. A prepared generation is completely inert until `commitPreparedRemovedAccountCleanup` atomically installs its optional one-attempt token snapshot and releases the fence after runtime/credential detachment. A same-ID live census retires a relaunch-after-precommit-crash generation. A different-ID same-email re-add deletes old-ID artifacts and suppresses email-global device actions only when the replacement has a mailbox; CalDAV alone cannot replace the old route. Old provider-specific cleanup remains when the provider changed.

After commit, the durable drain idempotently deletes the per-device account route, rewrites or removes the legacy device record, revokes Gmail/Outlook classifier consent, removes IMAP/iCloud IDLE state, and calls OAuth `/unsubscribe`. Consent runs first because legacy consent authorization may read the ownership proof that `/unsubscribe` revokes. The immediate attempt may use a synchronously captured raw access token once, but relaunch deliberately sends an empty token: the worker still deletes this caller's durable account-ownership proof and provider subscription when it owns the singleton, even if upstream provider teardown cannot authenticate and must expire naturally. A 403 is terminal only for consent/provider cleanup when the worker body carries its stable `user_mismatch` code; those handlers already revoked the authenticated caller's own proof before refusing another user's singleton. Bare edge 403s, 401, 404, and 5xx remain retryable. A missing APNs token terminalizes legacy-device refresh because that install could not have registered the record.

Every remote outcome is bound to the persisted original worker user ID. A different current session may still clean old local artifacts but cannot advance remote debt, preventing a new user from clearing a tombstone while the old user's routes survive. Removal while signed out persists local-artifact cleanup only: without an original worker subject no future session can safely claim email-keyed remote deletion. `RootView` drains unconditionally at launch and on every foreground, including the last-account case; normal `subscribeAllAccounts` also drains before enumerating live rows because its live-row subscription loop cannot name a deleted account.

`NSEDataBridge.removeAccountFromMirrors` now pre-evicts both email→account-ID and IMAP identities before the database transaction, eliminating the commit→mirror-eviction kill window. A failed transaction re-derives both from GRDB; normal launch `mirrorAllState` repairs a precommit process death. At commit, `AccountManager` installs a process-local removed-ID fence, removes provider/work-queue/calendar/coordinator routes, synchronously fences captured OAuth accessors, and deletes credentials before its first await. Removal-only queue invalidation refuses queued/new work; reconnect/reauthentication instead lets an already-captured drain closure attempt and ordinarily requeue its durable operation. OAuth invalidation plus a post-invalidation key deletion prevents a late refresh from recreating credentials, and provider disconnect precedes waiting for cooperatively cancelled sync tasks so a blocked provider read cannot park removal.

`AppDataWiper.wipeAll` still has no production caller, but it now shares the same per-account generations: all are prepared before its database delete, canceled/re-derived on failure, and committed/drained after runtime detachment using each account's captured CalDAV IDs. After commit it always attempts the local FTS, memory, attachment, BYOK, and credential wipes and publishes the row change; FTS/memory failures are visible. Durable account debt or final device unregister gates only authentication/default clearing and the reset success report, leaving a repeatable retry boundary rather than retaining private local data or abandoning worker state.

**Remaining open bound.** Cleanup APIs authenticate with the current TabMail session. Offline removal followed by ordinary sign-out can clear `tabmail_session` before debt drains; a later different user is correctly refused by the user-ID binding, but cannot finish the old user's work. The same user signing in again recovers debt that captured that user's ID. Removal while already signed out cannot safely schedule remote deletion and therefore leaves existing worker state to natural expiry. Permanent TabMail account deletion is sharper: after the grace-period hard delete the bound user can never authenticate again, while the account-deletion lifecycle does not purge push-worker state. Closing those cross-session cases needs an explicit sign-out handoff and/or a worker-side user-purge capability; #16 remains open rather than moving the unresolved half to a sibling issue.

Focused tests failure-inject offline retry, prove the raw OAuth token is attempted once and relaunch invokes worker unsubscribe with an empty token, bind retry to the original user, keep signed-out removal local-only, distinguish the worker's body-coded shared-owner 403 from an edge 403, pin exact-generation merge under a suspended network call, keep prepared generations inert, protect same-email/provider/CalDAV replacement, verify mirror pre-eviction/DB re-derivation, prove a claimed MOVE survives reconnect admission, and prove stale runtime/OAuth/queue state cannot restart after removal. The focused simulator gate passed 45/45 tests on 2026-08-14.

## 🟡 FURTHER NARROWED — SIGN-OUT HANDOFF LANDED; THE REMAINING BOUND IS SMALLER, NOT CLOSED (2026-08-18)

Nothing above is retracted. This section only narrows the "Remaining open bound" paragraph; #16 stays open.

Ordinary user-initiated sign-out now spends the session before destroying it. `TabMailAuthService.signOut()` is the seam: it asks `PushNotificationService.hasRemovedAccountCleanupDebt(forCurrentUser:)` whether any retained record is bound to the subject about to be cleared and still owes a worker-owned action, and only then runs the existing `retryPendingRemovedAccountCleanups()` under `withTimeout(seconds: PushConfig.signOutCleanupFlushTimeoutSeconds)`. Sign-out itself is unconditional: whatever the flush does, `clearSession()` runs and `.tabMailDidSignOut` is posted. No new durable state, no new mechanism, no migration — the drain invoked is byte-for-byte the one already running at launch and on every foreground, so nothing becomes deletable that was not deletable before. The gate is sharper than `hasPendingRemovedAccountCleanups()` on purpose: records bound to a different subject, and signed-out removals whose only action is `.localArtifacts`, do not make sign-out do work it cannot discharge, so the overwhelmingly common no-debt sign-out is unchanged — one UserDefaults read, no database access, no network.

**Closed: the retained-debt discharge (no removal drain concurrently active).** "Remove the account, then sign out" was a genuine race rather than a rare edge. `AccountManagerSetup.removeAccount` ends with a detached `Task` whose drain reads the worker subject only *after* an awaited account census, so a Sign Out tap landing in that window cleared `tabmail_session` first and the per-pass `workerUserId` guard then skipped every remote action forever. What the handoff closes is the **retained-debt discharge**: whenever no removal drain is concurrently active, the seam's bounded flush runs the drain itself while the session is still valid and discharges the debt the offline removal left behind — and it equally covers the post-outage case where the removal-time attempt failed on a network that has since recovered. The interleaving where the removal's detached drain is *already active* when sign-out fires is **not** won this way: the flush coalesces with it rather than waiting, so it is registered below as a residual sub-case, not a deterministically-closed race.

**Narrowed, NOT closed: still offline at sign-out.** If the device cannot reach the worker during the bounded flush, the flush fails exactly as the removal-time attempt did, the debt stays durable and idempotent, and only the same user signing in again can discharge it. This is the accepted residual, and it is why the counterweight matters: some server-side records for a removed mailbox lapse on their own and some do not, so an undischarged record can leave server-side state associated with a mailbox the user already removed.

**Residual sub-case, same-user concurrent drain — completed-or-retained, never dropped.** `retryPendingRemovedAccountCleanups()` coalesces: if a drain is already active (`removedAccountCleanupDrainActive == true`, set before it suspends on the account census), a second call sets `removedAccountCleanupDrainRequested` and returns at once. So when `AccountManagerSetup.removeAccount`'s detached drain is mid-flight at sign-out, the seam's flush call coalesces with it instead of waiting for it — `withTimeout` completes immediately and `clearSession()` proceeds without the bounded wait ever blocking on the active drain. The debt is **completed-or-retained, not dropped** — not "retained in full". Any worker call the still-running drain had already dispatched under the valid session (its auth token read *before* `clearSession()`) may complete after it, and that action is then genuinely done, correctly, on the old subject's authority; every action the drain only reaches *after* `clearSession()` gets `noAuthToken` and is retained. Nothing is dropped either way, because the coalesced flush persists nothing and the drain retires no action it could not authenticate. The retained remainder is **recovered on the same user's next sign-in** — the identical durable-retain-then-recover path as the still-offline residual above. This is why the concurrent case is a residual rather than a closed race: the guarantee is completed-or-retained-then-recovered, not deterministically discharged in-session.

**Unchanged accepted limitation: removal while signed out.** `PendingRemovedAccountPushCleanup.init` still records `actions = [.localArtifacts]` when there is no worker subject. Claiming that debt later by email would weaken the ownership binding that protects a shared-address co-owner, so it stays local-only by design rather than by omission.

**Out of scope here: the post-grace-period purge.** After a permanent TabMail account deletion the bound user can never authenticate again, so no iOS-side handoff can reach it. That half is server-side (a user-keyed purge capability). It was claimed at the time to be already in flight there — see the 2026-08-20 correction below, which found that claim unsupported. Either way it is not in this change.

**Residual worth naming: session resurrection.** `TabMailTokenCoordinator.performRefresh` writes a refreshed session back to the Keychain, so a refresh in flight when `clearSession()` runs can recreate the session. This predates the handoff and remains unfixed here — a sign-out generation guard in the token coordinator is a separate change. The handoff narrows rather than widens the window: the flush task is cancelled *before* `clearSession()`, not after, so a timed-out cleanup request cannot keep driving a token refresh past the moment the session is deleted.

**Scope deliberately bounded to one call site.** Only the account-dashboard "Sign Out of TabMail" button routes through the seam (the button is disabled while the flush is in flight). `AccountDeletionView.scopedTabMailCleanup` and `RootView`'s "Account No Longer Available" path sign out against a subject the server has already invalidated, where these calls would only 401; `AppDataWiper.wipeAll` already flushes first and then deliberately *blocks* on undischarged debt, and must keep doing so.

Six focused tests extend `RemovedAccountPushCleanupTests`: the flush completes debt while the session is valid; a hung flush neither blocks sign-out past the bound nor drops the debt, and the drain latch is proved re-entrant afterwards rather than assumed; a no-debt sign-out makes no cleanup call at all; another subject's sign-out advances nothing and retires nothing; a failing flush still clears the session and posts `.tabMailDidSignOut` while leaving every remote action durable; and a removal drain that is already active when sign-out lands pins the **same-user** coalescing residual. That last test asserts both halves: the transient blocked-window state (sign-out clears the session while the concurrently-blocked drain's debt is not dropped) **and** the settled outcome (once the block is released with the mock succeeding, the same-user drain resumes to completion under the identity it was admitted with and the record is retired — the debt is discharged **by completion**, not stranded). The drain's mock ignores auth, so the settled half pins that the coalescing did not corrupt or drop the debt, not that production discharges every action after `clearSession()`.
## 🟡 CROSS-USER DIMENSION — IDENTITY IS NOW PINNED TO THE PASS; THE STRANDING BOUND WIDENS (2026-08-19)

Nothing above is retracted except the one over-claim corrected at the end of this section. #16 stays open.

**Search terms for this dimension:** pinned bearer; pinned identity; `PushCleanupIdentity.pinnedAuthToken`; task-local bearer; cross-user token bleed; `user_mismatch` false discharge; per-action token acquisition; `currentAuthToken`; `performPinnedRemovedAccountCleanupActions`; drain subject change; B signs in mid-drain; cross-user worker state mutation; session slot clobber; `shouldPersistRefreshedSession`; NSE second writer; `NSETokenManager`; cross-process Keychain TOCTOU.

**The mechanism that was wrong.** `drainPendingRemovedAccountCleanupsOnce` reads the worker subject exactly ONCE, at pass admission, and then performs several awaited network actions. Every production `PushClient` operation independently re-derived its bearer through `currentAuthToken()` → `TabMailTokenCoordinator.validToken()` → an **ambient** read of the `tabmail_session` Keychain slot. So a sign-in landing mid-pass switched the identity the REMAINDER of user A's cleanup was sent under, without the drain noticing. Two IOS-PUSH-001 violations follow: the worker's `user_mismatch` refusal is treated as terminal by `isTerminalRemovedAccountOwnershipRefusal` and the action is REMOVED — **A's debt recorded as discharged without ever being discharged**, a dropped user intention — or, on a 2xx, **B-scoped worker state is mutated on A's behalf**. `refreshDeviceRegistrationForRemovedAccountCleanup` was the sharpest case: it re-read the session itself and re-registered the device under whoever now owned the slot.

**The fix: identity follows the WORK, not ambient state.** The pass now resolves ONE bearer at admission, verifies the slot still holds the admitted subject, and binds it for the whole pass via the `PushCleanupIdentity.pinnedAuthToken` task-local; `PushClient.currentAuthToken` prefers that pin over the ambient session. `refreshDeviceRegistrationForRemovedAccountCleanup` takes the admitted subject as a parameter instead of re-reading the Keychain. If no bearer can be obtained for the admitted subject, or the slot changed owner before the pin was bound, the pass performs **no remote action at all** and retains the debt — never a discharge of something it could not send. Task-locals propagate into actor methods called from the binding scope (an actor hop stays in the same task) but are NOT inherited by `Task.detached`; the action loop contains no detached task, and a test asserts the pinned value actually ARRIVES at the client rather than assuming propagation, because a task-local that silently fails to propagate is a fail-dangerous seam.

**Why this makes the existing terminal-discharge correct again — do not "re-fix" it.** `isTerminalRemovedAccountOwnershipRefusal` treats a body-coded `403 user_mismatch` as terminal. That was only sound while the bearer could not change mid-pass. Once the bearer is pinned, a `user_mismatch` again genuinely proves the ADMITTED subject lacks ownership of the shared-address singleton — which is exactly what makes it terminal. A `user_mismatch` arising from OUR OWN bearer switch is not evidence the debt is settled, and can no longer occur.

**The NEW residual: a cross-user stranding, not only a same-user one.** The residual recorded above is the SAME-USER case — "the debt stays durable and idempotent, and only the same user signing in again can discharge it". Pinning adds a CROSS-USER dimension: when a different user (B) signs in while A's debt is outstanding, A's remaining actions are now RETAINED rather than sent under B, so **B's sign-in can strand A's debt too, not only A's absence**. The counterweight recorded above is unchanged and still applies: some server-side records for a removed mailbox lapse on their own and some do not, so an undischarged record can leave server-side state associated with a mailbox the user already removed.

**This is the deliberate trade, stated plainly.** A stranded cleanup — retained, idempotent, retried, and discharged whenever its own user next signs in — is strictly better than a false discharge or a cross-user worker-state mutation. A false discharge is unrecoverable (the debt record is gone and nothing will ever retry it); a stranding is recoverable by an ordinary user gesture. **No TTL and no purge is introduced here, and none should be invented** — see the out-of-scope note on the worker-side user-keyed purge above, which remains the right home for that half.

**Correction to the 2026-08-18 section's test narrative (it over-claimed).** That section says the released same-user drain "resumes to completion **under the identity it was admitted with**". That was the documented INTENT, and it was true of the test's mock — but it was NOT true of production at the time it was written: production re-acquired a bearer per action, so the identity it completed under was whatever owned the session slot at that moment. The claim is accurate as of this section, because pinning now makes production honor it. Recorded rather than silently edited: a document asserting a guarantee the code does not implement is the exact defect class this register exists to catch, and this one survived a full review round unchallenged.

**Also corrected: the "session resurrection" residual is now narrowed, not merely named.** That section notes that `TabMailTokenCoordinator.performRefresh` writes a refreshed session back and so can recreate a session cleared by `clearSession()`. An auth-safe compare-and-swap now guards that write: it persists only when the slot is empty, unreadable, or still owned by the SAME subject, and withholds only when the slot holds a VALID session for a DIFFERENT subject. The polarity is deliberate — an ambiguous read SAVES, because withholding a legitimate save would strand a stale token and log the user out, which is worse than the clobber. Resurrection into an EMPTY slot is therefore still possible by design; the sign-in epoch bump (`AISubscriptionGate.noteSignedIn`, now invoked at the session write rather than at the `.tabMailDidSignIn` notification) closes its user-visible consequence.

**Remaining, honestly stated: a cross-process TOCTOU we shrink but do not eliminate.** The notification-service extension writes the IDENTICAL Keychain item (service `ai.tabmail.ios`, access group `group.ai.tabmail`, account `tabmail_session`) from a SEPARATE PROCESS via `NSETokenManager.performRefresh` → `SharedKeychain.setSession`. `@MainActor` cannot serialize another process. The same auth-safe predicate now runs on the NSE side too, which shrinks the window to the gap between that process's read and its write — it does not close it. A genuine fix needs a Keychain-level compare-and-swap, which `SecItemUpdate` does not offer. The NSE predicate is not unit-tested: `NSETokenManager.swift` is not a member of the `TabMailTests` target (only `NSEStagingDB`, `NSEMessageMetadata`, `NSEConfig`, `NSELog`, `SharedNSEData` are), and adding it would pull `SharedKeychain` and its Security-framework dependency into the test target for a mirrored three-line predicate. Recorded as a known coverage gap rather than closed.

## 🔴 THE COUNTERWEIGHT WAS FALSE; THE RESIDUAL IS SHARPER THAN RECORDED; #16 CLOSED AND THE SERVER-SIDE HALF REFILED (2026-08-20)

Nothing above is retracted except the one counterweight sentence corrected in §1, which was **false**, and the "already in flight" claim corrected in §3, which was **unsupported**. GitHub [#16](https://github.com/TabMail/tabmail-ios/issues/16) is **CLOSED** by owner decision on this date; the residual is not withdrawn but **refiled where the state actually lives** (§3).

**Search terms for this correction:** counterweight was false; server-side record has no automatic expiry; TTL attached to the wrong key; ADR-004 zero-retention posture; stranded server-side record; user-keyed purge did not exist; server-side half refiled on the private infrastructure trackers; three stranding paths; different user signs in strands A's debt.

### 1. The counterweight sentence is factually wrong — that record does not expire on its own

The 2026-08-18 and 2026-08-19 sections above both say, verbatim: *"consent KV expires in 7 days and provider subscriptions self-heal"*. **The first half is false.** The server-side record that sentence leaned on has **no automatic expiry** — it persists until something explicitly deletes it. The "7 days" is real but belongs to a *different*, unrelated key, so the counterweight attached a TTL to the wrong record.

**The second half survives, and is the only half that does.** The provider *subscription* genuinely does lapse on its own once the provider's watch expires (~7 d Gmail, ~3 d Outlook), so the mailbox stops being watched even when nothing explicitly cleans it up.

> The storage layout, key names, bindings, schedules and the code that writes them are **deliberately not restated here.** They are private-infrastructure detail and this record only needs the iOS-visible consequence; the specifics live with the server-side issue referenced in §3.

### 2. The consequence, stated plainly

A stranded record therefore keeps **server-side state for a mailbox the user has already removed from the device**, with no automatic expiry.

That makes it **the sharpest retention instance in this record's residual**, and it sits *alongside* the other server-side records that also do not lapse on their own rather than replacing them. The nature and extent of that state is tracked with the server-side issue referenced in §3 and is not enumerated in this public record.

⚠️ **Be precise about which rule this offends — do not over-claim it as an ADR-004 breach.** Root `DECISIONS.md` ADR-004 forbids storing *email content, email metadata and mailbox data*, and explicitly permits the server to store *auth metadata*, so this is **not** a violation of ADR-004's letter. What it offends is the zero-retention **posture** ADR-004 exists to express: server-side state retained indefinitely for a mailbox the user removed is exactly the at-rest user state the policy is meant to prevent — and neighbouring server code was written assuming it does not exist, so the posture is stated in one place and quietly not held in another.

**Why the error matters more than its size.** The false half was doing counterweight WORK: it is what made *"the debt stays durable and only the same user signing in again can discharge it"* read as tolerable, and it survived two amendment rounds and a full review round unchallenged. A reassuring sentence is not audited the way a claim of harm is. **A residual is only as narrow as its narrowest TRUE bound** — same defect class as the 2026-08-19 over-claim correction above, and the second instance in this record.

### 3. The server-side capability did NOT already exist — and is now tracked

The 2026-08-18 section says the user-keyed purge *"is in flight in the push-worker and billing-worker trees"*. **That was unsupported.** Verified at this date, no such capability existed on either side, and there were no branches or issues for it anywhere. Nothing was in flight. The claim should never have been written without checking the trees it named — that is the transferable lesson here, and it is the reason this section exists.

**It is tracked now**, on the private infrastructure trackers, split by genuine ownership rather than by which tree noticed it:

- The service that **owns the state** — it is the only one that can enumerate and delete the affected records, so the purge capability has to live there.
- The service that **owns the deletion lifecycle** — it is the only one that knows when a grace period has expired, which is the only moment the permanent-deletion case can be acted on.

The split is the load-bearing part: **neither side can close the case alone**, which is exactly why this half was never an iOS change and why #16's remaining scope does not belong on `tabmail-ios`. The specific services, storage and schedules are private-infrastructure detail and are deliberately not named in this public record.

### 4. There are THREE stranding paths, not two

Read together, the sections above enumerate three ways the debt strands. The third is easy to miss because 2026-08-19 states it as a *consequence* of the pinning fix rather than as a list item:

1. **Offline at sign-out** (2026-08-18) — the bounded flush fails exactly as the removal-time attempt did; the debt stays durable and idempotent, and only the same user signing in again discharges it.
2. **Permanent TabMail account deletion** (2026-08-14) — after the grace-period hard delete the bound user can never authenticate again, so **no iOS-side handoff can ever reach it**.
3. **A different user signs in** (2026-08-19) — once identity is pinned to the pass, A's remaining actions are RETAINED rather than sent under B's bearer. That is the correct outcome (retained beats a false discharge or a cross-user worker-state mutation), but it means **B's sign-in strands A's debt**, so A's absence is no longer the only cause. Recorded here as a numbered path so a future census of this record cannot miss it.

A fourth case is **deliberately not one of these and must not be counted as one**: removal while already signed out records `actions = [.localArtifacts]` and stays local-only **by design**, because claiming that debt later by email would weaken the ownership binding that protects a shared-address co-owner. That is an accepted design limitation, not a failure of the flush.

All three paths are now backstopped **only** by the server-side purge tracked in §3. With the counterweight disproved, *"it expires anyway"* is available for the provider subscription and for nothing else.

## 🟢 FINAL UPDATE — LOCAL CREDENTIAL FINALITY AND PERMANENT-DELETION PURGE SHIPPED (2026-08-28)

The sections above remain the chronological audit record. This section is the current authority for
the two residuals they left open.

### 1. The app/NSE Keychain race is closed without a sign-out handshake

iOS PR #95 merged at `96d21167add5f3ded0e8488c07127bc97dfd1599`. The app and Notification
Service Extension now share one session-specific Keychain store with immutable generation records
and one active pointer. A refresh captures its generation before network work and can update only
that exact existing generation. It cannot add a deleted generation, recreate the pointer, reactivate
an inactive login, or overwrite the next login. A current in-flight invocation may still finish
with the bearer it already obtained; only its authority for later work is revoked.

Deletion and migration use typed Keychain outcomes rather than treating failure as absence. Sign-out
success is emitted only after verified pointer deactivation. Strong cleanup verifies the whole
session namespace empty. Historical no-access-group sessions migrate by exact persistent reference
only after the new pointer and generation bytes are verified, so an activation failure preserves the
sole source for retry and does not force authentication or provider consent again. A durable App
Group cleanup-pending bit is resolved before the database fresh-install heuristic and blocks app/NSE
session use plus provider launch until verified cleanup succeeds.

The tests compile the real app coordinator and NSE token manager, hold their actual refresh
responses across sign-out/account switch, and exercise the production launch decision across two
launches. Seeded schedules reuse the existing module `SplitMix64`; there is no second state model or
same-user generation latch. The final candidate passed 194 relevant tests/199 runs, 9,279 full-suite
tests with 9,369 passing parameter runs plus one expected issue, both simulator builds, and two
consecutive fresh-context Codex-clean reviews on identical bytes.

This closes the older claims that resurrection into an empty flat slot remains possible, that the
NSE cross-process TOCTOU is unresolved, and that `NSETokenManager` lacks executable coverage. It
does not add a server call, APNs-token release, account-incarnation protocol, payment check, or
re-consent flow.

### 2. Permanent TabMail deletion now has a server-owned purge

The server now stores each classification credential per TabMail user and exposes a narrow purge to
the permanent account-deletion lifecycle. Permanent deletion requires successful cleanup, and a
bounded later sweep catches registrations created by a still-valid token after the first purge.
Dev and production migrations were applied and independently verified; the old singleton credential
copies were deleted and verified absent. Runtime never falls back to the legacy credential store.

This resolves the permanent-deletion half that was moved out of iOS #16. It does not claim every
eventually consistent server inventory problem disappeared; the broader strong-resource-inventory
and provider/droplet lifecycle limits remain in their own private infrastructure trackers.

### 3. Ordinary sign-out policy remains intentionally small

Ordinary sign-out does not unregister the APNs token, release device ownership, call a server purge,
or perform a new client/server handshake. A later authoritative device claim already evicts a
displaced owner. The existing bounded flush for already-persisted removed-account cleanup debt may
spend the outgoing session before local teardown, but it is not a general token-release protocol and
sign-out does not depend on remote success. Local credential finality is enforced by the generation
store regardless of whether that bounded cleanup succeeds.

The original iOS issue remains closed. Future work belongs to the surviving server issue trackers;
do not revive the superseded local sign-out/token-release branch from this historical record.

<!-- KNOWN-ISSUES-AMENDMENT-END -->
> Routed from `KNOWN_ISSUES.md` line 1445 during the 2026-08-09 hierarchy split. The exact pre-split source is hash-pinned in [`known-issues-pre-hierarchy-2026-08-09.txt`](../../History/KnownIssues/known-issues-pre-hierarchy-2026-08-09.txt) (`SHA-256 513497704ad37e977e2fb86e4623e956e6f1ca99844122948ff74995dfa9a309`).

- Register classification: `open`
- Original row SHA-256: `6f947e0a6d96e4f03abe0764e2e076a6b33d1a7ac7b868ca526b96535da8639d`

## Status

🔓 **OPEN (2026-08-09)** — account removal and the latent factory-reset path treat remote push unsubscribe, consent revocation, and device unregister as best-effort with no durable retry; a stale push can still produce an old-account warning after local removal

## Subsystem and search terms

push; unsubscribe; consent revocation; device unregister; account removal; `PushNotificationService`; `NSEDataBridge.mirrorAccountMap`; App Group defaults; stale notification; privacy

## Full detail

**MECHANISM.** `unsubscribeAccount` catches and logs every failure; `revokePushConsentForAccount` uses `try?`; `unregisterDevice` catches and returns. `AccountManager.removeAccount` then deletes local credentials/rows without recording remote-cleanup debt. A later push for the removed email cannot resolve the now-removed account through `NSEState.findAccountId`, and `NotificationService` deliberately delivers the passive fallback title `Connection to <email> lost` / `Open TabMail to reconnect`. Thus remote cleanup failure is not merely an invisible backend record: it can remain user-visible after removal and disclose which account used to be configured on the device. The currently uncalled `AppDataWiper.wipeAll` is worse if ever wired: it clears only standard `UserDefaults`, not the App-Group account map, and never remirrors an empty map.

**RECOVERY / BOUND.** Retrying account removal is not possible after the row has gone; re-adding then removing, disabling notification permission, backend subscription expiry/cleanup, or uninstalling the app ends delivery. Mail remains server-authoritative and no wrong message is mutated. A future fix should remain small: make remote cleanup return an outcome, clear the shared account/IMAP mirrors synchronously, and retain only a compact retry tombstone if worker cleanup truly must survive offline removal.
