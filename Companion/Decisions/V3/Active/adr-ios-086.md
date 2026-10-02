## ADR-IOS-086: A Dictation Dictionary: the User's Words, Learned Corrections, and Terms From the Context

**Status:** Active (2026-09-29)

**Context:** Speech-to-text misspells names and uncommon terms ("Xyvora" heard as "Zivora"). The
backend now takes, with each dictation, a list of words to spell as given (`vocabulary`, backend
ADR-025: at most 200, each at most 50 UTF-16 code units and 6 words, no control character or `<` `>`;
one invalid word fails the whole request), passed to the speech model's phrase list, and the
cleanup prompt takes the user's words as `dictionary`. TabMail Voice added a dictionary of the
user's words, typed or learned from their corrections (ADR-DESK-038). Owner, 2026-09-29: ship it to
iOS too, under Settings › Personalization › "Voice dictation dictionary", with no separate consent;
each device keeps its own (no sync); iOS learns from corrections as Voice does. Later the same day:
don't rely on the dictionary alone, but leave half the budget to words picked from the context, "a
dynamic dictionary being constructed on the fly from the captured context": names and uncommon
words of the related email, picked on the device (owner's choices: both apps, 100 + 100 fixed, rules
on the device rather than a model).

**Decision:**

1. `DictationDictionary` keeps the user's words (`{word, learned}`) in UserDefaults on this device,
   with TabMail Voice's rules: a word is trimmed, its spaces (the backend's: Unicode's and
   U+FEFF, found scalar by scalar, since a prepend mark such as U+0600 hides the space after it
   inside one grapheme) collapsed, refused when empty, over
   `dictionaryWordMaxChars` (UTF-16, as the backend counts) or `dictionaryWordMaxWords`, or holding
   a control character or `<` `>`; a word already there in any case is not added twice but takes
   the spelling typed, the user's latest, and a learned one becomes typed. It holds at most `dictionaryMaxEntries` = 100,
   half of the backend's 200, so every word in it is always sent.
2. Each dictation also sends up to `contextTermsMax` = 100 terms picked from what it is about
   (`DictationContextTerms`): the pill's title, the email's sender, subject and snippet (or the
   draft's subject and body), the chat turns and the input, and the email's whole plain-text body,
   read on the device from the search index (`SearchIndex.bodyText`) under the key the content
   stores write it under (`MessageContentStore.capture`, so the read follows the content-key migration). A term is a word with a capital
   letter inside it ("TabMail", "OKR", "iOS"), or at its start where no sentence starts (after `.`
   `!` `?` or at a line's start one does); runs of such words are one term ("Kaelthorne Drake"), a
   run longer than a dictionary word is a heading and counts word by word; everyday words, words
   under `correctionMinWordLength` and addresses (`@`, `://`) are not terms; each term must be a
   valid dictionary word; the most frequent come first, then the earliest; none repeats a
   dictionary word. Only the terms leave the device, not the body.
3. The dictionary is snapshotted when the dictation starts, as its language is (root rule: snapshot
   settings at operation start): the words and the learning switch. The terms are picked in the
   background while the user speaks; the transcription waits at most `contextTermsWait` = 0.2 s for
   them and otherwise goes without.
4. The transcription sends `vocabulary`: the dictionary's words, then the terms (left out when
   there are none). The cleanup gets `dictionary`, the dictionary's words one per line (empty when
   there are none); not the terms, since it reads the screen itself.
5. Learning (on unless switched off): after a dictation lands in the pill's input field,
   `DictationCorrectionWatch` reads that field every `correctionPollInterval` (0.5 s) for
   `correctionWatchDuration` (30 s). An edit that has stayed one interval, or the input as it is
   sent, is compared with the field as the dictation left it by `DictationCorrections`, TabMail
   Voice's `learnedCorrections` ported rule for rule (its approach is OpenWhispr's `correctionLearner`,
   MIT, https://github.com/OpenWhispr/openwhispr, credited in the source; no code copied): only an edit within the dictated text, not a
   rewrite of over `correctionMaxChangedShare` of its words, not a different word
   (`correctionMaxEditShare`), not another form of a lowercase word (only its end changed past
   `correctionMinStemShare` of its start: "report" → "reports", "send" → "sent"; a capitalised name
   or a script without case is exempt), not a short or everyday word, and a change of case only
   inside a word or with a spacing change. The words the last comparison teaches are learned when
   the watch ends (the next dictation, the send, the pill going away, or its duration), so a pause
   in the middle of an edit ("tabmail" on the way to "TabMail") teaches nothing. Every read is
   compared: one that respells something new, or has the dictation back as it was (an undo),
   replaces what an earlier one taught, with what it teaches once it has stayed (or is sent) and with
   nothing before, so a spelling paused on and then changed teaches nothing though the field is
   cleared before the change stays; one that respells nothing (the field cleared, other text, a word
   half retyped) keeps the correction. No Accessibility is
   needed: the field is the app's own.
6. Settings › Personalization › Voice Dictation Dictionary (`DictationDictionaryView`): add a word
   (with the reason when refused), the list with a "Learned" tag and swipe to delete, and "Learn
   from My Corrections".

**Consequences:**

- No separate consent (owner, 2026-09-29). The AI consent already covers the email and screen text
  sent with a dictation; the terms are picked from that same context and are fewer. The dictionary
  stays on the device; the backend stores neither the words nor the terms (root ADR-004, backend
  ADR-025).
- The dictionary is per device, not synced: a word added on the iPhone is not in TabMail Voice.
- The picking is heuristic: a capitalised ordinary word mid-sentence ("Monday", "Paris") is sent
  too, which is harmless, since a phrase list only biases the model toward a spelling; a name at a
  sentence's start alone is missed unless it also appears elsewhere.
- A body not yet indexed just sends the other terms; a body read slower than 0.2 s sends no email
  terms at all (they are picked together), only the dictionary words.
- A lowercase term heard right at its start but wrong at its end ("kubctl" for "kubectl") is not
  learned; the user adds it by hand.
- 200 terms of up to 6 words could exceed AssemblyAI's 1,000-word `keyterms_prompt` total; the
  backend's current model (MAI-Transcribe-2) has no such limit (backend ADR-025 records it for a
  fallback to AssemblyAI).
- The pill's wiring (the email id, the send, the pill going away) and the Settings row are pinned by
  source fences (`ChatPillDictationWiringTests`), as the rest of the pill's dictation wiring is
  (ADR-IOS-085).

**Amendment 2026-10-02 — 150 dictionary words (100 typed at most) and 50 context terms; a full
dictionary keeps learning, dropping the learned word used least recently.** Owner, for TabMail Voice
and then "the iOS app should also have the same" (TabMail Voice's ADR-DESK-038 amendment of the same
date): at the cap, auto-learned words keep updating, the learned word *used* least recently giving
way, by a count of each word's last use rather than a time; 50 of the 200 words sent kept for the
context's terms and 150 for the dictionary, the typed words taking precedence up to 100 (refused past
that, the user asked to remove one), the learned words in the rest, all 150 when none is typed; a
learned word dropped with no notice; Settings listing the typed words, then the learned ones, each
alphabetically. Before, the dictionary and the context had 100 each, and a full dictionary refused
every new word, so learning stopped for good, silently, once 100 words were in.
- Measured first, in TabMail Voice's `Scripts/stt-compare/vocabulary_limit.py` (OpenRouter,
  MAI-Transcribe 2, a spoken made-up name as the canary): 200 terms are taken and 201 refused; 200 real
  English words or 200 Korean names still spell the canary right. Only lists of made-up,
  similar-sounding names lost it early, which no budget fixes; the budget stays the backend's 200.
- `DictationConfig.dictionaryMaxEntries` 150 + `contextTermsMax` 50 = 200; `dictionaryMaxTypedWords`
  100. `DictationDictionary.add` refuses (`full`) a new word, or a learned word typed again, at the
  typed cap; a typed word typed again takes the spelling typed.
- `Entry.lastUsed`, a count (larger is more recent): a word's last use is its adding, its typing or
  learning again, or a dictation whose transcript or cleaned-up text holds it
  (`DictationDictionary.use`, called by `DictationController` once a non-empty transcript of the
  current dictation comes back). A word counts whatever its case, inside a longer word too (a script
  without spaces has no word edge). An entry stored before `lastUsed`, or with an invalid one, reads
  as never used.
- A new word at `dictionaryMaxEntries`, learned or typed (below the typed cap), takes the place of
  the learned word of the smallest `lastUsed` (the earliest of a tie), never one learned in the same
  correction nor one the same correction respells again (`learn` marks those used before adding any).
  A typed word is never dropped.
- `DictationDictionaryView.shown`: the typed words, then the learned ones, each by
  `localizedCompare`; swipe to delete removes the rows as shown. The learning note says learned words
  fill the room the typed ones leave, up to 150, the one used least recently making way.

**Consequences (amendment):**
- A learned word can drop out with no notice but the debug log's, which doesn't name it.
- The dictionary is rewritten in UserDefaults after a dictation that holds one of its words.
- Fewer context terms (50, was 100): the most frequent are kept.
