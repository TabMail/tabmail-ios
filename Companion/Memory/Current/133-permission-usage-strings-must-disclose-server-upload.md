# Permission usage strings must say when the data leaves the device (App Review 5.1.2)

**Date:** 2026-10-06. **Trigger:** App Review rejected 1.9.1 (378) under Guideline 5.1.2 (Data Use and
Sharing): "the app appears to upload the user's Contacts to a server, but the app does not inform the
user and request their consent first." Apple's screenshot showed the Contacts prompt fired from
Settings > Contacts (`ContactContainerPickerView.loadContainers` → `CNContactStoreHelper.requestAccess`)
with the old string "TabMail uses your contacts to suggest recipients when composing emails."

**The rule.** If any code path sends data guarded by an iOS permission (Contacts, Calendars, Photos,
Microphone, …) to TabMail's server or its AI providers, the matching `NS*UsageDescription` in
`TabMail/Resources/Info.plist` must say so, plus how the data is used. The first-launch `AIConsentView`
alone is not enough: the reviewer judges the system prompt, which can fire from a screen (Settings,
Compose) that has nothing to do with AI. Keep `AIConsentView`'s "Data sent" list accurate, too.
The microphone string ("Your recording is sent to TabMail to be transcribed; TabMail doesn't store it.")
is the model to follow.

**What was sent and how it was fixed (PR #204).** `ContactSearchTool` (and add/edit/delete) return the
matching contacts' names, all email addresses, first/last/nickname and contact id to the LLM loop. The
usage string, `AIConsentView`, and the Settings > Contacts header now say: suggestions stay on device;
with AI on, the matching contacts' names and email addresses go to TabMail's server and its AI providers
when the user asks the assistant to find, add or edit a contact; they're not stored or used for training.

**Calendars were checked and are fine:** EventKit (`EKEventStoreHelper`) is used only for adding
invitations (`ICSCalendarImporter`); the AI calendar tools read through the account calendar APIs
(`CalendarProviderDispatch`), not EventKit. If an AI tool ever reads EventKit, update
`NSCalendarsFullAccessUsageDescription` in the same change.

**Reply-to-Apple note.** "We don't collect it, it's transient" answers the App Privacy *label*
definition, not 5.1.2. 5.1.2 asks for disclosure + consent before the upload, whatever the retention.
The owner's reply satisfied the reviewer this time: 1.9.1 (378) was approved and is live without the
string change (2026-10-06). PR #204 is future-proofing and ships with the next release; the next
reviewer may not accept the reply alone.
