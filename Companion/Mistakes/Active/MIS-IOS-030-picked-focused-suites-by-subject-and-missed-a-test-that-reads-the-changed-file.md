# MIS-IOS-030 — picked a PR's focused suites by subject, and missed a test that reads the changed file's source

**Recurrences:** 4
**Status:** Active
**First recorded:** 2026-11-05

## The tell

> *"This PR is about the chat's reply field, so the focused run is the chat and pill suites."* — a
> focused-suite list chosen from what the change is ABOUT, with no search of `TabMailTests/` for the
> paths of the files it edits.

## What actually happened

A chat view PR moved the inbox pill's mic button into its own property in
`DynamicIslandChatButton.swift`, one nesting level out. `PillDictationModeTests` reads that file's
source and matched the mic tap's newest-gesture-wins lines with literal newlines and a fixed
indentation, so it failed although the behaviour was unchanged. The PR's focused suites were chosen
from the chat feature and did not include the dictation suite, so the failure was found three PRs later,
when a later PR added that suite to its run, and the fix had to go back into the earlier PR and
restack every PR after it.

## Recurrence 2 (2026-11-05, the chat view train gate)

The file search was done, and it found `DictationControllerTests.swift`, but the run named the
file's main suite, `DictationControllerTests`. `xcodebuild -only-testing:` addresses a Swift Testing
suite by its TYPE name, not by its file, and the same file also declares `ChatPillDictationWiringTests`.
That suite never ran, so three of its source checks were stale on the candidate and the reviewer
found them. A first census script then missed a suite with no `@Suite` attribute
(`PillDictationModeTests`, a bare `struct` holding `@Test`s).

The tell this time: *"the file is in the list, so its tests ran."* A file is not a suite.

## Recurrence 3 (2026-11-06, the chat view train, whole-chat actions across accounts)

The focused list named `UndoableActionTests` and `UndoServiceTests` from their FILE names. Neither
file declares a type of that name for its tests (`UndoServiceTests.swift` declares twelve suites such
as `UndoStackLogicTests` and `UndoableActionPropertiesTests`; `UndoableActionTests.swift` declares
`UndoableActionLabelTests`), so `-only-testing:` matched nothing and the run reported 8 suites for a
list of 10, without an error. Caught by comparing the reported suite count with the list; the 13 real
suites were then run and passed.

The tell this time: *"the suite is named after its file."* Read the declared types; a run that
reports fewer suites than the list named is a miss, not a pass.

## Recurrence 4 (2026-11-06, the chat view train gate)

A coverage fix added a source check to the reply-field PR, third from the bottom of a six-PR stack,
and its focused run passed there. The check looked for `clearCount: fieldClearCount)`, closing
parenthesis included; the next PR adds an `onlyTo:` argument after it, so the check failed from that
PR on and was found only by the train-tip gate, after the stack had been rebased onto it.

The tell this time: *"the new test passes in the PR I added it to."* In a stack, a test added to an
earlier PR also has to pass at the tip, and a source check should match the smallest token that
carries its meaning.

## The rule

Before choosing a PR's focused suites, run `rg -l '<changed file name>' TabMailTests` for every
production file the PR edits, and add every suite that names one. Then list every suite TYPE each matched file
declares (every type after a `@Suite`, and every top-level `struct`/`class` holding `@Test`s), and
pass each one to `-only-testing:`; naming one suite of a file runs only that suite, and a name no type carries runs nothing, silently. Check that the reported suite count equals the list's. A test added to an earlier PR of a stack is also run at the stack's tip before the round closes. Many iOS tests read source text at
run time (`String(contentsOf:)` on a `TabMail/…` path); they break on a move that changes no behaviour.
Write such a check with whitespace collapsed (`split(whereSeparator: \.isWhitespace).joined(separator: " ")`),
as `ChatReplyFieldTests` and `ChatSwipeTests` do, so a move does not break it.

## Census

`PillDictationModeTests` still matches two other passages with literal newlines (the send gate and the
permission re-read); they pass today and break the same way if their code moves.
