<!-- KNOWN-ISSUES-AMENDMENT-BEGIN -->
> **Current amendment (2026-09-06): bounded ordinary message-action retries.** The historical
> no-cap/no-drop statements below no longer describe all ordinary message-action failures.
> `AccountOperationExecutor` retires an ordinary message action after ten counted no-progress
> provider failures using the existing `PendingOperation.retryCount`. The unchanged
> `!SyncEngine.isConnectionError` classifier includes final HTTP 429/5xx and authentication
> refusals; opaque `AuthError.refreshFailed`, cancellation, local storage failures, unavailable
> evidence and empty/ambiguous reports remain uncharged. Progress never charges or triggers the
> cap, and draft producers, Outbox, calendar and AI retries retain their separate policies.
>
> The accepted cost is loss of automatic retry after the limit; a user may have to repeat the
> gesture. Existing historical counts are used without reset. An always-on App Logs error follows
> the durable retirement commit, before deferred-successor removal and follower admission. A failed
> terminal write keeps local ownership and stops the drain until recovery, without another wire
> attempt. This does not add a reauthentication banner or change the historical signal decision.
> See the fifth runtime exit in
> [the normative rule](../../../Rules/Active/never-drop-user-intention.md).
<!-- KNOWN-ISSUES-AMENDMENT-END -->
<!-- KNOWN-ISSUES-AMENDMENT-BEGIN -->
> **Current amendment (2026-11-10, tabmail-ios #534): the mail-side signal gap is FIXED.** The
> visibility gap this row registered (a revoked Google or Microsoft grant halting mail actions,
> sends and sync with no prompt, `MIS-IOS-008`) no longer holds. Every Gmail API and Microsoft Graph
> request, mail and calendar alike, gets its token from the accessor `AccountManager.makeOAuthAccessor`
> builds, and that accessor now raises `markAuthFailed(accountId)` when the token refresh fails with
> `OAuthError.tokenExchangeFailed` carrying one of the three codes
> `AccountManager.isGrantLevelOAuthFailure` accepts (`invalid_grant`, `invalid_client`,
> `unauthorized_client`). That is the narrow shape the row demanded: `temporarily_unavailable`,
> `server_error`, the `"unknown"` fallback, `invalid_scope`, an offline device, a timeout and an
> undecodable body raise nothing. The signal is skipped when the account was removed or the user
> has already installed a new sign-in (the stored generation moved), so the accessor itself does not
> re-raise the prompt on a late refusal of the old grant after re-authentication. The calendar drain's
> own raise (`isCalendarOAuthReauthRequired`) has no generation guard, so a calendar op whose refresh
> with the old grant was in flight during re-authentication can still re-raise it; the warning then
> stays until the next successful `connectAccount` (at the latest, the next cold launch). The user sees the existing warning
> (`RootView` opens Settings after a launch connect, the `SettingsView` row icon, the
> `AccountDetailView` banner), and it clears as before when `connectAccount` succeeds after
> re-authentication.
>
> The error is rethrown unchanged, so no disposition changed. Ordinary message actions on Gmail and
> Graph receive it wrapped as `AuthError.refreshFailed` by `AccountAuthSource`, which the fifth
> runtime exit does not charge, so they stay queued however long the grant is refused and drain
> after sign-in. Outbox sends keep ADR-IOS-019's existing three-strike policy: the row is never
> dropped, becomes `failed` (visible, with Retry) after three refused drains, and goes out after
> sign-in on the next drain or on Retry. Not covered: the notification service extension (a
> separate process with its own token path and no banner), and `AccountManager.freshAccessToken`
> (push subscription), which calls the refresh coordinator directly. IMAP and iCloud accounts sign
> in with a password and have no grant; their connect-time refusal was already signalled through
> `AccountManager.isAuthError`. The body's statement that `isAuthError` is the ONLY writer of
> `authFailedAccounts` was already untrue before this change (the calendar drain and
> `SyncEngineBackfillWalk` also write it), and the accessor is now a further writer. Tests:
> `RevokedMailGrantSignalTests`.
<!-- KNOWN-ISSUES-AMENDMENT-END -->
<!-- KNOWN-ISSUES-AMENDMENT-BEGIN -->
> **Current amendment (2026-11-27, tabmail-ios #659): the warning also covers refusals only the user,
> or their admin, can resolve.** Microsoft `interaction_required` (another sign-in step, such as
> multi-factor or a Conditional Access step) and `consent_required` (consent from the user or, where
> the organisation reserves it, an admin), and Google `admin_policy_enforced` (a Workspace admin
> restricted a requested service), raised no warning: the mail queue, outbox and sync stopped
> silently. The warning now reads its own code set, `AccountManager.isSignInAgainOAuthFailure`: the
> three grant-level codes plus those three, same exact match and normalisation, of the top-level
> `error` field of the token endpoint's answer whatever its HTTP status. Microsoft lists
> `consent_required` in the token endpoint's error table, which its refresh documentation points to;
> Google documents `admin_policy_enforced` for the sign-in step, so on a refresh it is matched only if
> it comes. Like the other codes, the mark also keeps the
> account's other failures in a sync poll out of the inbox refresh banner's count while it is up
> (`InboxErrorBanner.countsAsFailure`); a pull still shows its own error.
>
> The token accessor in `makeOAuthAccessor` is now the ONLY place a token-endpoint refusal raises the
> warning. The calendar drain's `isCalendarOAuthReauthRequired` no longer reads
> `OAuthError.tokenExchangeFailed` at all (it keeps the two post-refresh 401s and
> `ProviderError.authenticationFailed`): every Google and Microsoft calendar request takes its token
> from the same accessor, so the drain's raise only repeated it without the generation check. The
> late-refusal residual in the #534 amendment above is therefore CLOSED for token-endpoint refusals:
> the accessor's check and the insert run in one turn of the `AccountManager` actor
> (`markAuthFailed(_:refusedSignIn:store:)`), the actor that also installs a new sign-in
> (`installOAuthCredentials`) and clears the warning (`connectAccount`), so a token-endpoint refusal
> of a replaced sign-in, or of a removed account, raises nothing, whichever queue it reaches. Still
> open, each its own issue: the old sign-in's refresh can also end without a refusal (it succeeds
> after the sign-in was replaced, the coordinator was invalidated, or the sign-in reads as inactive),
> and `OAuthRefreshCoordinator.refresh` then throws `ProviderError.authenticationFailed`, which the
> calendar drain (`isCalendarOAuthReauthRequired`) and `SyncEngineBackfillWalk` still turn into the
> warning with no sign-in check (#1611); a late grant-level refusal still retires a calendar change as a sign-in failure
> whose notice asks to sign in again (#1598); the warning clears only when the reconnect after a new
> sign-in succeeds (#1599); a calendar-only account has no surface that shows the warning (#1600); a
> refusal of a new sign-in installed while the refresh was on its way to `OAuthRefreshCoordinator`
> raises no warning until the next token request (#1604).
>
> What retires a calendar operation is unchanged: `isCalendarAuthError` still reads
> `isGrantLevelOAuthFailure` alone, so a calendar change refused with one of the three new codes stays
> queued (transient arm) and goes through once a sign-in gets a token again. Signing in again is how
> the user takes the step or gives the consent; an admin restriction or an admin-only consent must
> first be lifted or given by the admin, and until then a new sign-in can be refused the same way, so
> the warning stays up and the change stays queued. Tests: `RevokedMailGrantSignalTests`
> (`revokedSignInWarnsAndKeepsTheWork` over `refusedMailSignIns`, a refused grant and a code that needs
> the user for each provider, through the real mail queue and outbox;
> `indeterminateFailureRaisesNoWarning`, including an unknown code containing a known one;
> `refusedGrantRaisesTheWarning`, `refusalOfAReplacedSignInRaisesNoWarning` and
> `refusalAfterRemovalRaisesNoWarning` over `warns`; `refusalWarnsOnlyForTheInstalledSignIn`;
> `refusalCheckAndInsertShareOneActorTurn`, the source check that the accessor's refusal branch makes
> no check before the hop to the actor;
> `calendarChangeWaitsForTheUser` over the three codes through the real calendar queue;
> `calendarRefusalOfAReplacedSignInRaisesNoWarning` over `warns` through the real calendar queue),
> `CalendarBadRequestClassificationTests` (roster, the drain's signal no longer reading token-endpoint
> codes, and `reauthSignalCoversWhatTheTerminalArmDoesNot`).
<!-- KNOWN-ISSUES-AMENDMENT-END -->
# IOS-QUEUE-009

> Routed from `KNOWN_ISSUES.md` line 1208 during the 2026-08-09 hierarchy split. The exact pre-split source is hash-pinned in [`known-issues-pre-hierarchy-2026-08-09.txt`](../../History/KnownIssues/known-issues-pre-hierarchy-2026-08-09.txt) (`SHA-256 dfa31256dfc43d25d741408ed6e33e2e58ae9984d7cc825a2d59c6c1ae1b6535`).

- Register classification: `closed-decision`
- Original row SHA-256: `d5254feb44f817c5e59cd86030b305ff6ea54431c6f15c22d12dfca7269884b9`

## Status

✅ **CLOSED AS A DECISION (2026-08-06, round-15 FIX-5)** — the re-authentication signal round 14 added is **calendar-lane only**. The identical revoked Google/Exchange grant reaching the **mail** action queue, outbox or sync raises no user-visible signal at all, so that account's mail lane halts on every drain while the user is never told to sign in again. Registered, not fixed: no intention is dropped, and recovery is one ordinary gesture

## Subsystem and search terms

OAuth; revoked grant; `invalid_grant`; re-authentication; mail lane vs calendar lane; `AccountManagerQueue.executeSingleOp`; `DrainContext.failedAccounts`; `.haltLane`; `AccountManager.isAuthError`; `authFailedAccounts`; `AccountManager.connectAccount`; `OAuthError.tokenExchangeFailed`; `OAuthService.refreshGoogleToken`; `AccountManagerCalendarQueue.isGrantLevelOAuthFailure`; `isCalendarOAuthReauthRequired`; `markAuthFailed`; `AccountDetailView.reauthButton`; `IOS-CAL-003` sibling; `MIS-007` census shape; never-drop clause 2

## Full detail

**How the gap was made.** R14-F4 fixed a real calendar wedge and censused its blast radius with `rg -c authFailedAccounts` over `AccountManagerCalendarQueue.swift` — one file. A census inherits the shape of its instrument (`MIS-007`), and the instrument here was a FILE, so the answer covers a lane rather than the failure.

**What the mail side actually does.** `OAuthService.refreshGoogleToken` throws `OAuthError.tokenExchangeFailed(response.error ?? "unknown")`. `OAuthError` is declared `enum OAuthError: Error` with **no** `LocalizedError` and **no** `CustomStringConvertible`, so `"\(error)"` renders as `tokenExchangeFailed("invalid_grant")` — which matches none of `AccountManager.isAuthError`'s four predicates (`ProviderError.authenticationFailed`, `AUTHENTICATIONFAILED`, `LOGIN failed`/`login failed`, `Application-specific password required`). `isAuthError` is also the ONLY writer of `authFailedAccounts`, and it is reached only from `connectAccount`. So the op falls to `AccountManagerQueue.executeSingleOp`'s generic transient arm, which requeues with `status = queued` and `retryCount += 1`, inserts the account into `DrainContext.failedAccounts` and returns `.haltLane`; the next drain re-reaches the same op first and repeats. The banner in `AccountDetailView` is driven by `authFailedAccounts`, so it never appears.

**Why this is registered and not fixed — the counterfactual, which is the whole argument.** The obvious fix is to claim `OAuthError.tokenExchangeFailed` on the mail side the way the calendar lane now does. Blanket-claiming the CASE is the mirror-image defect: the same case carries `temporarily_unavailable`, `server_error` and the `"unknown"` fallback (a token-endpoint body with no `error` key at all), i.e. never-drop clause 2's *"we could not determine the answer"*. Raising a re-authentication prompt on those tells a user their account is broken during a Google 5xx, and there is no dismiss for a banner whose condition never clears by itself. **The narrow shape any future fix MUST follow is already written down**: `AccountManagerCalendarQueue.isGrantLevelOAuthFailure` trims whitespace, lowercases, and matches exactly `invalid_grant`, `invalid_client`, `unauthorized_client` — three values parsed positively from the token endpoint's own body, never a bare failure — and `isCalendarOAuthReauthRequired` keeps the SIGNAL (about the account) separate from the DISPOSITION (about the op), which is why `ProviderError.authenticationFailed` is signalled there and deliberately still retryable. Port that pair, or nothing.

**Why it is not in the non-recoverable set.** Nothing is dropped: the ops stay durable and queued, the mail lane has no retry cap, and the moment the grant is restored the same drain executes them. Nothing is mutated: the lane halts before any wire operation. The state is *blocked*, never *damaged* — the same distinction `IOS-MIGRATION-003` turns on.

**Recovery is one ordinary gesture, and it is unconditional.** `AccountDetailView` renders `reauthButton` inside a plain `Section("Authentication")` with no `hasAuthError` guard — the gated copy is only the banner's. Both halves are byte-identical to `07a4bb703` (A1: shipped is the floor and it is silent here too, so this is not a regression in the range).

**THE NON-RECOVERING CASE, NAMED (`MIS-IOS-008`).** A user who never opens Settings → Account detail is never prompted, because the only thing that would prompt them is the signal this row is about. Their queued actions do not execute and do not fail visibly; they simply do not stick, and the user must diagnose that unaided. That is a **visibility** gap, not a data-loss gap, and it is deliberately not promoted: the alternative costs a false re-authentication prompt on every transient token failure, which is a worse and more frequent harm. **What would re-open this row:** the mail lane acquiring a retry cap (the ops would then start being retired instead of starving), or evidence that revoked grants are common enough that the diagnosis burden outweighs the false-alarm cost.
