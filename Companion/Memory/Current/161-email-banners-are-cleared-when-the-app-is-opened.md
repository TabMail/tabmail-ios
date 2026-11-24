# 161. Email banners are cleared when the app is opened; the inbox observer reads nothing at launch

**Rule (2026-11-24, #1385).** The first `UIApplication.didBecomeActiveNotification` of a process (a cold
launch in the foreground, or the first time the user brings up a process iOS launched in the background)
removes every delivered EMAIL banner (`EmailBannerOpenClear`, installed from
`AppDelegate.application(_:didFinishLaunchingWithOptions:)`, calling
`NotificationCleanupService.removeEmailBanners`). A background launch (silent push, background refresh, a
notification's action button) never activates the app and removes nothing. Later activations of the same
process remove nothing. Reminders and every other notification stay; the badge is not touched.

**Which notifications are email banners** (`NotificationCleanupService.isEmailBanner`, unit-tested on
`DeliveredNotificationSnapshot`):

- kept: anything whose `userInfo` has `ProactiveNotifyService`'s `hash` key (its `due_` / `overdue_`
  reminders and its nudges, even a nudge built with `EmailNotificationBuilder.fill`);
- email: a category `EmailNotificationBuilder.fill` sets (`EmailNotificationBuilder.categoryIdentifiers`:
  `EMAIL`, `EMAIL_TAG_ARCHIVE`, `EMAIL_TAG_DELETE`);
- email: a new-mail push the notification extension delivered bare, with no fill: `userInfo["provider"]` in
  `EmailNotificationBuilder.newMailPushProviders` (`gmail`, `outlook`, `imap_new_mail`; not
  `consent_error` or `imap_reconnect`);
- everything else is kept.

**Why by content, not by identifier.** The push worker sets no `apns-collapse-id`, so a banner the
notification extension delivers keeps the push's system-assigned identifier (the extension cannot change a
request's identifier and posts no local notifications). Only the banners the main app posts itself (the
reply banner in `AccountManagerAI`, `ProactiveNotifyService` nudges) use
`EmailNotificationBuilder.identifier` (`email-<accountId>-<messageId>`). So clearing by that identifier
(`InboxNotificationObserver`, `NSEDataBridge.clearNotification` on read) misses extension-delivered banners;
that gap is a separate issue and not part of this rule.

**The observer starts empty.** `InboxNotificationObserver` no longer seeds its rowid map with a whole-inbox
read inside the launch write (the removed `seed(_:)`, `SELECT rowid, accountId, messageId FROM messageHeader
WHERE isInInbox = 1`, which held the writer for one index entry plus one table row per inbox message on
every database open). `AppDatabase.makeInboxNotificationObserver` only registers it
(`pool.add(transactionObserver:)`). It learns a row from any insert or update after registration, so an
email that arrives or is touched after launch and then leaves the inbox still has its banner cleared.
Memory 078's "Startup populate via `WHERE isInInbox = 1` once during `AppDatabase.init`" describes the
earlier design.

**Accepted edge.** A banner shown before a background launch, for an email that leaves the inbox while the
app stays in the background, stays until the app is opened or the 24-hour `NotificationCleanupService`
sweep removes it. Nothing is lost.

**Tests.** `NotificationCleanupServiceTests` (the predicate: email banners removed, reminders, nudges,
`consent_error`, `imap_reconnect` and unknown notifications kept), `EmailBannerOpenClearTests` (first
activation removes once, a background launch removes nothing, a later activation removes nothing),
`InboxNotificationObserverTests` (post-launch arrive-then-leave clears; a row present before registration
and never touched is not tracked).
