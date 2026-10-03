## ADR-IOS-087: Long Dictations, Cut Into Chunks Sent While the User Speaks

**Status:** Active (2026-10-03)

**Context:** A chat-pill dictation stopped at 120 s of speech (ADR-IOS-085 decision 10): the most
audio the backend's transcription model takes in one request (backend ADR-022). TabMail Voice had the
same limit and lifts it by cutting a long dictation into chunks (tabmail-voice issue #1,
ADR-DESK-048). Owner, 2026-10-03: cut at pauses, and only once a chunk holds 10 s or more of speech;
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
   and words) counts as speech.
   - **A pause:** once a chunk holds `chunkMinimumSpeech` (10 s) of speech, it is cut in the middle of
     the next `chunkPauseDuration` (1 s) of quiet. Nothing overlaps.
   - **No pause:** a chunk reaching `chunkMaxDuration` (105 s) is cut at the quietest
     `chunkForcedCutWindow` (300 ms) of its last `chunkForcedCutSearch` (5 s); the next starts
     `chunkOverlapSpeech` (15 s) of speech earlier, at most `chunkMaxOverlap` (30 s), and is marked
     `overlapped`. Every upload stays within 120 s.
   - A recording never cut is one upload, exactly as before.
2. **`DictationChunkJoin`** (Voice's `joinChunkTexts`) joins the chunks' texts in order: an ellipsis
   where two meet is removed (one inside a chunk stays); a pause seam is a space, or none between
   scripts written without spaces; an overlapped seam is joined at the longest run of at least
   `chunkOverlapMinimumRun` (3) words, compared in lower case with letters and digits only, within
   `chunkOverlapSearchWords` (80) of the seam, the run kept once; with no such run the two are joined
   whole. Each side is cut at a word's place in its own text, so line breaks stay.
3. **The recorder cuts as it records.** `AudioRecorder` feeds the chunker from `keepFromNow` (speech
   heard), the held pre-roll first, so the chunker's sample indices are the kept recording's. Each cut
   waits with its samples in `takeChunks`, and `onChunk` (on the audio thread) wakes the controller.
   `finish` returns the last chunk (`Recording.lastChunk`), its samples normalised on their own as
   `Recording.pcm`; each chunk is peak-normalised on its own (`normalizePeak`). The cap is
   `maxRecordingDuration` = 10 minutes (was 120 s).
4. **`DictationChunkUploads`** sends each chunk at once (FLAC-encoded off the main actor) with what
   every upload of the dictation sends, prepared once with the first chunk: the language, the
   dictionary's words and the context's terms, and the cleanup's variables (each chunk gets its own
   cleanup, backend ADR-027). A chunk with no speech in it (a long silence) is not sent; the last
   is sent unless it holds no speech and another chunk was sent.
5. **Retries.** While the user dictates, a chunk failing with a server error, a dropped connection or
   the backend's own timeout (504) is tried again after each of `chunkRetryDelays` (1, 2, 5, 10 s,
   the last repeating), showing nothing. The release cuts any such wait short; from then on a chunk
   gets `transcriptionRetryDelays` more tries (about a minute, ADR-IOS-085 amendment 2026-10-03) on
   the same failures, a 504 included, under the pill's retry state (`isRetrying`, then
   `showsRetryNote`): the last chunk is sent at the release, so its backend timeout comes after it
   (owner: "we should not lose the end"). Anything else (signed out, over quota, a refused request)
   gives up at once.
6. **What is pasted.** The chunks' texts in order up to the first chunk that gave up; the chunks
   after it are cancelled. The first chunk giving up pastes nothing, as one recording's failure does.
   iOS says nothing about a missing end: dictation failures are silent (ADR-IOS-085 decision 8);
   the reason is in the debug log. (TabMail Voice shows a note.)
7. **Cancel** (or the pill going away) cancels every chunk request and wait; nothing is pasted.
8. **Consent and privacy:** unchanged. The audio was already sent to the AI backend at the tap; it
   now leaves in parts while the user speaks, and nothing more is kept (zero retention, ADR-004).
   iOS's AI consent covers voice recordings (ADR-IOS-085), so no new notice is shown on iOS; TabMail
   Voice shows its existing users a one-time What's New notice (ADR-DESK-048).

**Consequences:**

- A dictation can run 10 minutes; its text is ready about as soon as a short one's, since the
  earlier chunks were transcribed while the user spoke.
- A cancelled long dictation has already sent its earlier chunks (as Voice).
- A forced, overlapped seam with no shared run of words may repeat a few words; none are lost (owner).
- A rate-limit burst after the release loses the end of the dictation only if it outlasts the last
  tries, about a minute (owner, 2026-10-03: "we definitely need more retries"; they were 2 s).
- Synthetic constant sound (one steady tone) has no frame above the room level and counts as no
  speech: its chunks are not sent, only the last. Speech always varies; the tests use speech-like
  audio.
- `DictationController` is past 500 lines (622); the chunk logic lives in `DictationChunkUploads`,
  `DictationChunker` and `DictationChunkJoin`.
- Tests: `DictationChunkerTests` and `DictationChunkJoinTests` (ported from Voice),
  `DictationLongDictationTests` (order and cleanup, overlap join, retries while recording, last tries
  with the retry state, prefix delivery, first chunk lost, cancel, silent last chunk, a seeded fuzz
  over random failures), and `DictationControllerTests.noUploadOutlastsWhatTheModelTranscribes` /
  `theAppsControllerSendsALongDictationInChunksTheModelTranscribes`. Five mutants (failed chunks
  skipped, the release not ending waits, 504 not retried while recording, a silent last chunk sent,
  cancel not stopping requests) each fail at least one of them.
