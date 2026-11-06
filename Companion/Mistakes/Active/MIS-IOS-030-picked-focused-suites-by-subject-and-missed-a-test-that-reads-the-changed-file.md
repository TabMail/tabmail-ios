# MIS-IOS-030 — picked a PR's focused suites by subject, and missed a test that reads the changed file's source

**Recurrences:** 1
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

## The rule

Before choosing a PR's focused suites, run `rg -l '<changed file name>' TabMailTests` for every
production file the PR edits, and add every suite that names one. Many iOS tests read source text at
run time (`String(contentsOf:)` on a `TabMail/…` path); they break on a move that changes no behaviour.
Write such a check with whitespace collapsed (`split(whereSeparator: \.isWhitespace).joined(separator: " ")`),
as `ChatReplyFieldTests` and `ChatSwipeTests` do, so a move does not break it.

## Census

`PillDictationModeTests` still matches two other passages with literal newlines (the send gate and the
permission re-read); they pass today and break the same way if their code moves.
