## ADR-IOS-089: Device Sync State Belongs to One TabMail Account; a Different Account Starts From Defaults

**Status:** Active (2026-10-05)

**Context:** Device Sync (root ADR-021) syncs prompts, the KB, reply templates, disabled reminders
and the action-compaction thresholds through a per-account relay. iOS sign-out cleared none of
that state and left the relay socket open. Two consequences when a different account then signed
in on the same device: the new account saw the previous account's prompts, and because the device
still held real per-field timestamps it broadcast that state to the new account's other devices on
connect, where last-write-wins could overwrite their own. The open socket also stayed authenticated
to the previous account's room, because `connect()` reuses a live socket. The Thunderbird add-on
clears these keys on sign-out (`supabaseAuth.js` `userStorageKeys`). Owner, 2026-10-05, asked
whether this was a bug and chose "clear on account change" over clearing on every sign-out.

**Decision:**

1. `DeviceSyncService.ownerUserIdKey` records the TabMail user id whose synced state the device
   holds. `DeviceSyncService.claimLocalState(for:)` runs at every session install (the three
   `installNewSession` sites in `TabMailAuthService`, right after `noteSignedIn`) and in
   `connect()`.
2. Same account: nothing changes. No recorded owner (an install from before this ADR): the current
   state is adopted as that account's.
3. Different account: Device Sync disconnects; `PromptStore.resetForNewAccount()` writes the
   defaults to the real prompt and template keys and clears history and the 3-way-merge peer base;
   `DisabledRemindersStore.removeAllForNewAccount()` clears both reminder maps; the compaction
   thresholds, every per-field sync timestamp, the sync backups and the auto-sync flag are removed.
   With no timestamps the device is a new device to the relay: it probes the new account's peers
   and receives their state instead of broadcasting the defaults over it.
4. `TabMailAuthService.completeSession` disconnects Device Sync on every successful session end,
   the single chokepoint for sign-out, account deletion and the account-gone path.

**Trade-offs:** Signing out and back in as the same account keeps everything, including edits
made while signed out. Signing in as a different account discards the previous account's local
copy; it survives on that account's other devices and returns from them when it signs back in,
but a device that was its only copy loses it. The owner accepted that in choosing this option over
keeping per-account copies, which would add new persistence for a rare case. Adoption has one
consequence: an install that updates to this build while signed out, and then signs in as a
different account, adopts the previous account's state once, because nothing records whose it was.
Resetting on a missing owner instead would wipe every same-account update. AI caches and other
per-message state are out of scope.
