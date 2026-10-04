## ADR-IOS-087: Long Dictations, Cut Into Chunks Sent While the User Speaks

**Status:** Active (2026-10-03)

**Context:** A chat-pill dictation stopped at 120 s of speech (ADR-IOS-085 decision 10): the most
audio the backend's transcription model takes in one request (backend ADR-022). TabMail Voice had the
same limit and lifts it by cutting a long dictation into chunks (tabmail-voice issue #1,
ADR-DESK-049). Owner, 2026-10-03: cut at pauses, and only once a chunk holds 10 s or more of speech;
with no pause, cut at about 2 minutes anyway, the next chunk overlapping it by 15 s of speech, the two
texts merged on their repeated words, "and if no repeated words are found just join them. It's better
than losing things"; each chunk is a whole request with its own cleanup, sent in parallel and in the
background while the user goes on; an ellipsis where two chunks meet is taken out; a chunk failing
while the user dictates is tried again until the release, which gets the last tries; "if it
continuously fails completely, paste nothing … paste only the up to successful part"; and "this should
also cover the iOS app, not just the voice app".

Measured 2026-10-03 against the speech model itself, with real recordings looped to length: 60–120 s
clips transcribe in about 1 s and 150 s in about 4 s, the word count growing with the length
throughout (no clip cut short). The model's provider refused about one try in three as rate limited;
the backend answers any provider failure 502, which the apps retry.

**Decision:**

1. **The same rules as TabMail Voice, ported rule for rule.** `DictationChunker` (Voice's `Chunker`)
   reads each 20 ms frame's loudness against the recording's own levels: the room is its 10th
   percentile, the voice the 90th percentile of frames at least 3 dB above the room, and a frame
   below 0.3 of the way from one to the other is quiet; a quiet run under 300 ms (between syllables
   and words) counts as speech, and louder frames no longer than `chunkPauseBlip` (40 ms) inside a
   quiet run count as quiet. Later note (2026-10-03): the owner's real 32 s test dictation on
   TabMail Voice, with several 1–2 s pauses after 10 s+ of speech, was never cut under the first,
   all-frames-quiet rule; its pauses were 80–90% quiet, the room's noise poking 0–4 dB over the line
   a frame or two at a time. The tolerance is a plosive's burst, shorter than any vowel, so a cut
   still lands only in a pause (owner: "really high precision, even if some recall could be
   lower"); with it that recording is cut at 13.5 s and 27.4 s, both inside its pauses
   (ADR-DESK-049).
   - **A pause:** once a chunk holds `chunkMinimumSpeech` (10 s) of speech, it is cut in the middle of
     the next `chunkPauseDuration` (1 s) of quiet. Nothing overlaps. The levels are relative, so
     speech much softer than what came before, with few frames at the room's level, can read as
     quiet: a pause cut can land in it and split a word or two, with no overlap to recover them
     (reproduced with synthetic audio in TabMail Voice's review, 2026-10-03). Every chunk is still
     sent.
   - **No pause:** a chunk reaching `chunkMaxDuration` (105 s) is cut at the quietest
     `chunkForcedCutWindow` (300 ms) of its last `chunkForcedCutSearch` (5 s); the next starts
     `chunkOverlapSpeech` (15 s) of speech earlier, at most `chunkMaxOverlap` (30 s), and is marked
     `overlapped`. Every upload stays within 120 s.
   - A recording never cut is one upload, exactly as before.
2. **`DictationChunkJoin`** (Voice's `joinChunkTexts`) joins the chunks' texts in order: an ellipsis
   where two meet is removed (one inside a chunk stays); a pause seam is a space, or none between
   scripts written without spaces; an overlapped seam is joined at the longest run of at least
   `chunkOverlapMinimumRun` (3) words, compared in lower case with letters and digits only, within
   `chunkOverlapSearchWords` (80) of the seam, the run kept once: its first word as the earlier
   chunk wrote it, the rest as the later one did (later note, 2026-10-03: the owner's TabMail Voice
   smoke test pasted "you can Test the" at every overlap seam, a chunk's text starting with a
   capital as any text does; "capitalization mid breaks"); with no such run the two are joined
   whole. Each side is cut at a word's place in its own text, so line breaks stay. A chunk overlaps
   only the one just before it: after an empty one (a long silence) it is joined whole, or
   matching it against an earlier chunk's words would cut out the speech between them (found in
   review, 2026-10-03; the controller hands the join every part, empty ones included).
3. **The recorder cuts as it records.** `AudioRecorder` feeds the chunker from `keepFromNow` (speech
   heard), the held pre-roll first, so the chunker's sample indices are the kept recording's. Each cut
   waits with its samples in `takeChunks`, and `onChunk` (on the audio thread) wakes the controller.
   `finish` returns the last chunk (`Recording.lastChunk`), its samples normalised on their own as
   `Recording.pcm`; each chunk is peak-normalised on its own (`normalizePeak`). The cap is
   `maxRecordingDuration` = 10 minutes (was 120 s).
4. **`DictationChunkUploads`** sends each chunk at once (FLAC-encoded off the main actor) with what
   every upload of the dictation sends, prepared once with the first chunk: the language, the
   dictionary's words and the context's terms, and the cleanup's variables (each chunk gets its own
   cleanup, backend ADR-027). **Every chunk is sent**, one the chunker heard no speech in too: the
   model decides, as for one recording, with no loudness gate (owner, 2026-10-03, "send every
   chunk"). Loudness is read against the recording's own levels, so speech much softer than what
   came before (the user leaning back) once read as silence and its chunks went unsent and lost
   (found in TabMail Voice's review, 2026-10-03). Before, a chunk with no speech was not sent, and
   the last only when nothing else was.
5. **Retries.** While the user dictates, a chunk failing with a server error, a dropped connection,
   the backend's own timeout (504) or the speech model's rate limit outlasting the backend's own 30 s
   of retries (429 `transcription_rate_limited`, backend ADR-022; `backendWaited`) is tried again
   after each of `chunkRetryDelays` (1, 2, 5, 10 s, the last repeating), showing nothing. The release cuts any such wait short; from then on a chunk
   gets `transcriptionRetryDelays` more tries (about a minute of waits, ADR-IOS-085 amendment
   2026-10-03; each try that the backend holds for its whole 30 s window, a 504 or that 429, adds its
   30 s, so a chunk failing that way every time keeps the pill transcribing for up to about 5.5
   minutes, 9 tries × 30 s plus the waits, until the user closes the pill; found in review,
   2026-10-03) on
   the same failures, a 504 and that 429 included, under the pill's retry state (`isRetrying`, then
   `showsRetryNote`): the last chunk is sent at the release, so its backend timeout comes after it
   (owner: "we should not lose the end"). Anything else (signed out, over quota or the account's own
   rate limit, a refused request) gives up at once.
6. **What is pasted.** The chunks' texts in order up to the first chunk that gave up; the chunks
   after it are cancelled. The first chunk giving up pastes nothing, as one recording's failure does.
   iOS says nothing about a missing end: dictation failures are silent (ADR-IOS-085 decision 8);
   the reason is in the debug log. (TabMail Voice shows a note.)
   **The polish** (owner, 2026-10-03: "one final cleanup pass after the full dictation, even in the
   chunked case… a little bit wasteful, but nice to have"; "a final polished pass if time permits…
   not longer than 5 seconds"; "this should not change any of the backend mechanisms"): a text of
   two chunks or more (their cleanups, joined) goes once more through the same cleanup prompt,
   `DictationConfig.cleanupPrompt`, which the app calls itself at `POST /completions/chat`
   (`BackendClient.sendCompletionsDirect`, as before the cleanup moved into the transcription
   request), with the dictation's cleanup variables and the joined text as its `dictation`. Its reply
   is pasted if it comes within `chunkPolishTimeout` (5 s) of the chunks being in; one that fails,
   comes back empty or runs out of time (cancelled) leaves the joined text to be pasted, as a failed
   cleanup leaves the transcript. One chunk left before a chunk that gave up already had its whole
   cleanup and is not polished; a single recording never is. As TabMail Voice's.
7. **Cancel** (or the pill going away) cancels every chunk request and wait; nothing is pasted, and
   no request is made after it (a chunk checks for the cancel after its upload is prepared and after
   each retry wait, as TabMail Voice does).
8. **Consent and privacy:** unchanged. The audio was already sent to the AI backend at the tap; it
   now leaves in parts while the user speaks, and nothing more is kept (zero retention, ADR-004).
   iOS's AI consent covers voice recordings (ADR-IOS-085), so no new notice is shown on iOS; TabMail
   Voice shows its existing users a one-time What's New tip under the pill (ADR-DESK-049).

**Consequences:**

- A dictation can run 10 minutes; its text is ready about as soon as a short one's, since the
  earlier chunks were transcribed while the user spoke.
- A cancelled long dictation has already sent its earlier chunks (as Voice).
- A forced, overlapped seam with no shared run of words may repeat a few words; none are lost (owner).
- A rate-limit burst after the release loses the end of the dictation only if it outlasts the last
  tries, about a minute of waits plus up to 30 s per try the backend holds (owner, 2026-10-03: "we
  definitely need more retries"; they were 2 s).
- The cleanup sees one chunk at a time, so a sentence cut at a forced cut is cleaned in two halves;
  the polish reads the whole text if it can within 5 s, at the cost of one more completions request
  per long dictation and up to 5 s more at the spinner. A dictation of several minutes may run out of
  time and keep its chunks' cleanups.
- A long silence costs one request per 105 s, and the model may hear a stray word in it (as in
  one recording's silence).
- `DictationController` is past 500 lines (620); the chunk logic lives in `DictationChunkUploads`,
  `DictationChunker` and `DictationChunkJoin`.
- Tests: `DictationChunkerTests` (including `aPauseWithBlipsOfTheRoomInItIsCutAtOnlyWhileTheyAreShort`:
  40 ms room blips in a pause are cut at, 80 ms ones are not) and `DictationChunkJoinTests` (ported from Voice),
  `DictationLongDictationTests` (order and cleanup, overlap join, retries while recording, last tries
  with the retry state, prefix delivery, first chunk lost, cancel, a quiet last chunk sent too, a
  seeded fuzz over random failures; and, from review: the words around a long silence, a soft
  stretch after loud speech sent and pasted, a steady sound sent in every chunk, the speech
  model's 429 retried while recording and after the release, a refused chunk or the account's own
  429 given up at once, each chunk's
  language and words, each
  chunk peak-normalised on its own, no request after a cancel during a retry wait or the upload's
  preparation; the polish pasted with the prompt's variables, each fallback, a cancel during it, a
  polish answering after a cancel leaving the next dictation alone, and no polish for one chunk),
  `DictationAudioRecorderTests.chunksAreCutAtThePauseCountingTheAudioHeldBeforeSpeech`, and `DictationControllerTests.noUploadOutlastsWhatTheModelTranscribes` /
  `theAppsControllerSendsALongDictationInChunksTheModelTranscribes`. Five mutants (failed chunks
  skipped, the release not ending waits, 504 not retried while recording, a silent chunk not sent,
  cancel not stopping requests) each fail at least one of them.
