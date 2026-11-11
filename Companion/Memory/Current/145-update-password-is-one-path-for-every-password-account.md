## Update Password is one path for every password account (2026-11-11)

Account detail's sign-in button routes by `AccountProvider.signInMethod` (`.password`: IMAP, iCloud,
CalDAV; `.oauth`: Gmail, Outlook), never by a provider switch in the view. Before this, only `.imap`
got the password prompt; iCloud and calendar-only accounts fell into the OAuth action, whose switch
had an empty `.imap, .icloud, .caldav` arm, so the button did nothing.

- **One entry point each.** `AccountManager.updatePassword(_:for:)` serves every password kind;
  `AccountManager.reauthenticateOAuth(for:)` dispatches Gmail and Outlook. Each throws
  `ReauthenticationError.signInMethodMismatch` for the other kind; neither returns silently.
  `updateIMAPPassword` is gone.
- **Snapshot.** The view keeps the account as it was when the prompt opened
  (`passwordPromptAccount`). `updatePassword`'s first step reads the stored row and its
  `caldavConfig` once (`passwordUpdatePlan`); a row that is gone, or no longer `signsInLike` the
  prompt's account (id, provider, calendar-only, address, IMAP user, host, port), stops the update
  before any server is asked: `ReauthenticationError.accountChanged`, alert line
  `AccountReauthAlert.accountChangedLine`. A runtime removal during the checks ends the same way.
  There is no separate removal-fence check at plan time: removal commits the row delete before
  `disconnectAccount(_:deletingCredentials:)` sets the fence, so the stored-row check already stops
  a removed account (an early fence check was deleted as redundant; its mutant could not be killed).
- **What is checked and saved, by kind** (model properties, no provider switch in the account layer):
  - Mail and calendar on one password (`mailAndCalendarShareOnePassword`, iCloud): the mail probe
    and the calendar (CalDAV discovery with the new password) must both accept; then both are
    saved. Any failure saves nothing.
  - Mail with a calendar whose stored password equals the stored mail password, or already equals
    the new password (compared in memory, never logged): the mail must accept; the calendar follows only if it accepts too. A calendar
    refusal (`isCalDAVAuthError`) leaves the calendar as it was and updates the mail alone; any
    other calendar failure fails the whole update so a retry can still update both. A calendar with
    a different password is never asked.
  - Calendar only (`calendarOnly`): the calendar step alone.
- **Save order and repair.** Calendar Keychain entry first, then mail, so a failed mail save leaves a
  state the next attempt finishes: the calendar then holds the new password and the mail the old one,
  nothing is made live, the mark stays. A retry with the same password counts "the calendar already
  has the new password" as following the mail (iCloud re-checks both anyway), so it saves both, makes
  both providers live and clears the mark (`failedMailSaveIsRepairedByRetry`, iCloud and plain IMAP). Then the providers are made live: `calendarProviders` gets a provider on the
  accepted client; the mail probe goes through `installAcceptedPasswordProbeAsLive`, unchanged.
- **Sign-in mark.** The checks never mark the account: the mail probe has no account reporter, CalDAV
  has none. A refused password is thrown as `ProviderError.authenticationFailed`, which
  `AccountReauthAlert.passwordUpdateLine` turns into the password line.
- **Prompt copy.** `PasswordPrompt.message(for:)` names `AccountProvider.passwordName` ("app-specific
  password" for iCloud).
- **Test seam.** `makeCalDAVClient` uses `setCalDAVSessionOverrideForTesting`'s session (DEBUG only,
  fenced by `TLSOverrideDebugFenceTests`), so `AccountPasswordUpdateTests` drives the calendar check
  against a `FakeHTTP` CalDAV server that accepts one password.
  `KeychainHelper.failNextSaveForTesting(key:)` (DEBUG only, same fence) fails one save to one key.
- **Not changed.** The calendar picker's "add the calendar account again" text for password accounts
  (`CalendarPickerView`) still points at the setup screen.
