## A value read only inside a sheet's content closure is not a body dependency (2026-11-22)

**What happened:** the new email chat (`ChatNewThreadView`) reads the user's addresses after the
screen first draws (`loadOwnAddresses`, from `.task`) into `@State ownAddresses`, and passes them to
the Add recipient sheet (`ChatReplyToSheet`), which refuses to add them. The body read
`ownAddresses` only inside the `.sheet(isPresented:) { … }` content closure. A read inside a closure
the body only builds is not a read by the body, so the body did not depend on the value: setting it
did not run the body again, and the sheet kept the closure built in the body run before the read,
holding the empty set. Typing the user's own address in the sheet then added it as a recipient.

**Fix:** capture the value while the body runs, `.sheet(isPresented: $showsAddRecipient) { [ownAddresses] in … }`.
A capture list is evaluated when the closure is created, during `body`, so the body now depends on the
value and runs again when it is set; the sheet modifier then gets a closure holding the loaded set.

**How it was found:** `ChatNewThreadScreenTests.pickedPeople` (a hosted test that types into the
sheet's real text field and presses Done) saw the user's own address added in three runs. A debug-gated
log showed the read had succeeded, which ruled out a failed or slow read and pointed at the value the
sheet was given.

**Rule of thumb:** when a sheet, popover or full-screen cover's content needs `@State` that is filled in
after the screen appears, and nothing else in the body reads that state, capture it in the content
closure's capture list (or read it in the body). Otherwise the content keeps the value from the last
body run. The thread chat's Reply to sheet (`ChatThreadView`) never had this bug: its body reads the
same addresses through `thread`, so the body already depended on them.

**Still open:** the sheet can open, and a contact can be picked, before the read finishes, and a failed
read leaves the set empty (tabmail-ios#1236, P4). A stored account email with spaces around it is not
trimmed before the comparison (tabmail-ios#1245).

**Update 2026-11-28:** the sheet no longer refuses the user's own addresses: a typed or picked own
address is added like anyone's (ADR-IOS-114 decision 11, amendment of 2026-11-28). The captured
`ownAddresses` still matter: the Add recipient sheet's Recent section leaves them out
(`ChatRecentPeople.load`), and a stale empty capture would list the user there. The rule of thumb
above is unchanged.
