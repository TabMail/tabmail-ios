## ADR-IOS-085: Chat-Pill Dictation Uses TabMail Voice's Backend Speech-to-Text and Cleanup

**Status:** Active (2026-09-26; amended 2026-09-29: the cleanup runs in the transcription request)

**Context:** The chat pill dictated with Apple's on-device `SFSpeechRecognizer`
(`SpeechRecognizer.swift`): live partial transcripts streamed into the input field while the
user spoke. TabMail Voice (the macOS app, `tabmail-voice`) replaced Apple's recogniser with the
backend's `POST /dictation/transcribe` (OpenRouter speech-to-text, TabMail Voice ADR-DESK-005)
followed by a language-model cleanup that fixes misheard names and terms using what is on screen
(`system_prompt_dictate_cleanup`, ADR-DESK-008). Owner, 2026-09-26: the iOS app should use the
same dictation, "a one-for-one copy" of the Voice app: the mic button is off without an internet
connection, a waveform shows in the input field while dictating, the text is appended to the end
of the input when it comes back, and the contextual cleanup runs.

**Decision:**

1. `Services/Dictation/` holds the flow, copied from TabMail Voice and kept in step with it:
   `AudioRecorder` (16 kHz mono Int16), `WAVEncoder`, `LevelEnvelope` and the waveform numbers
   are copies (only the license header and the logger call differ); `DictationController` is Voice's state machine without the
   push-to-talk arming (the mic button toggles: tap to listen, tap again to transcribe);
   `DictationCleanup` builds the same prompt variables.
2. Transcription goes through `BackendClient.transcribeDictation` (the app's auth token,
   `X-Client-Type: ios`), and the cleanup rides in the same request (amendment 2026-09-29 below):
   the recording carries `cleanup`, the prompt's variables (`DictationCleanup.variables`), and the
   backend answers `cleaned_text` beside the transcript. ~~The cleanup through
   `sendCompletionsDirect` with tools and web search off. The backend already serves the prompt to
   iOS clients, so it needs no change.~~ (2026-09-26 to 2026-09-29.)
3. The "screen" the cleanup reads is the chat pill, captured when the dictation starts: what the
   pill is about (the email's sender, subject and snippet, or the draft's subject and body), the
   latest chat turns, and the input field as a `» ` line with the caret `‸` at its end. Only
   the last `contextMaxScreenChars` = 500 characters, ending at the caret, are sent, and the
   cleanup gets 1.5 s (owner, 2026-09-28, as TabMail Voice's a78baba: the cleanup is a light pass
   and more context slows it; was 20,000 characters and 3 s). Since 2026-09-29 the backend
   enforces the 1.5 s (its `cleanup.timeoutMs`); the app's `cleanupTimeout` is gone.
4. `DictationController.start` refuses to start without AI access (a TabMail session and an
   active subscription, the gate that shows the pill's input bar; TabMail Voice likewise refuses
   when signed out or without consent), when opted out of AI (`AIService.optOutAllAIKey`, set by
   Settings' "Opt Out of AI" and by declining AI consent, as every AI call honours), and offline
   (`NetworkMonitor`). This covers the auto-start paths (auto-dictation
   on expand, and after each agent turn), which would otherwise record with no visible waveform.
   The pill turns the mic button off (`mic.slash`, disabled) while offline or opted out, and
   auto-start then does nothing; a recording already in progress can still be stopped.
5. `MicrophoneCapture` activates the audio session per dictation and deactivates it on every exit
   (iOS memory 086); all session and engine work is on one serial queue, which also orders a
   stop after the start it races.
6. `SpeechRecognizer` and the speech-recognition permission string are removed.
7. Each recording carries its language (added 2026-09-26, after backend ADR-024 made the backend
   pick the speech-to-text model by it: Korean and 11 others go to a model that covers them).
   TabMail Voice sends the keyboard's language (ADR-DESK-019); the pill hides the keyboard while
   dictating, so iOS uses a Settings choice instead (`DictationLanguage`, TabMail Settings →
   Dictation Language, the backend's 30 languages by name). Automatic, the default, is the
   iPhone's first preferred language reduced to its two-letter code; none is sent without one.
   The controller reads it once when the dictation starts, so a change mid-dictation applies from
   the next one. `DictationLanguageTip` on the mic, after the first dictation lands, says where
   to change it (owner, 2026-09-26: a tooltip pointing to a Settings menu). The language is not
   shown while dictating (decision 8; it was first shown as Voice does, a small `KO` circle left
   of the waveform).
8. While dictating, the input field stays where it is with its text dimmed to a faint hint
   (`DictationConfig.dimmedInputOpacity`), and TabMail Voice's waveform is laid over it
   (`DictationPillView`): following the voice while listening, rippling at rest while the words
   are transcribed. Tapping it stops listening. Nothing else is shown: no pill shape, warm-up
   swirl or spinning circle, no language, and no message when a dictation fails; the field just
   comes back (owner, 2026-09-28, after trying the first build on a device: "we don't want this
   to be complicated"). The first build copied Voice's overlay whole: a waveform pill that
   replaced the field, the language badge, and error messages in the pill for 3 s.
   The waveform is drawn in the app's accent colour (owner, 2026-09-28; Voice's blue → purple
   brand gradient looked wrong in the pill). It lies flat while the dictation waits for speech
   (decision 10).
9. While listening, the send button stays send: tapping it finishes the dictation, then sends
   the input once the text is appended. A dictation that brings back nothing just ends; nothing
   is sent, and the pending send never carries over to a later dictation. The mic button (and
   a tap on the waveform) finishes without sending. While the words are transcribed the send
   button is TabMail Voice's thinking spinner (`DictationSpinner`: a faint track with a blue →
   purple arc circling it, Voice's numbers; owner, 2026-09-28: loading feedback, "our own
   spinner, like the TabMail Voice spinner"); a send tapped earlier goes out when the text
   lands. History, all 2026-09-28: first a send button that finished and sent;
   then a stop button that only finished ("stop only"), with the spinner; after trying it on a
   device the owner found stop-then-send clunky and returned to finish-and-send, keeping the
   spinner.
10. A dictation records only once speech is heard (owner, 2026-09-28: someone saying nothing,
   or background noise alone, shouldn't use up the recording time). Until then it waits
   silently, with no time limit: the mic is on, the waveform flat, and only the latest
   `speechPreRollDuration` (2 s) of audio is held, so the first word isn't clipped. Speech is
   told from noise by Apple's on-device sound classifier (`SoundClassifierSpeechDetector`,
   SoundAnalysis `version1`, the speech/whispering/shout classes, confidence ≥ 0.5 over ~1 s
   windows), not by loudness: TabMail Voice's ADR-DESK-005 found no level threshold that keeps
   quiet speech and drops a room's noise. `maxRecordingDuration` counts from speech, the held
   moment included. Stopping before speech was heard asks the classifier about its last window
   (a word said just before the tap) and otherwise ends quietly, sending nothing. TabMail Voice
   has no such wait: a held key already says someone is speaking, while the pill's mic is also
   started automatically (on expand, after each agent turn).

**Consequences:**

- Audio leaves the device. The backend stores and logs neither audio nor text (root ADR-004;
  backend ADR-022); the microphone permission string says so, and the AI consent screen lists
  voice recordings among the data sent. The consent screen's "Zero retention" and "Not used
  for training" claims hold for recordings: OpenRouter applies no per-request zero-retention
  filter to transcription, but the owner confirmed on 2026-09-25 that zero retention is enforced
  across the whole OpenRouter account, and the configured model's one endpoint is on the public
  ZDR list (backend ADR-022). Users who consented before this change see no new notice in the
  app: the change is already announced (owner, 2026-09-27). The App Store privacy label gains no
  "Audio Data" entry (owner, 2026-09-27): Apple counts data as collected only when it is kept
  longer than it takes to serve the request, and the recording is transcribed and dropped, with
  zero retention at every provider. Storing or logging recordings anywhere would change that.
- The language picks a model; each model still detects what is spoken within the languages it
  covers (backend ADR-024), so English said with Korean chosen is still written as English. A
  language outside the backend's list goes to its default model, as with no language. The
  backend's list is copied into `DictationConfig.dictationLanguages`; a new pair there needs the
  same line here to appear in Settings. Deploy order: backend ADR-024 before an iOS build that
  sends `language` (the previous backend forwarded it to AssemblyAI, which lacks Korean and the
  other paired languages). Met: dev and prod were deployed from a backend `main` containing
  ADR-024 on 2026-09-27.
- In demo mode, dictation's transcription and cleanup calls do not count against the demo's
  50-call budget (ADR-IOS-038); the backend's per-token demo rate limit still applies.
  Accepted by the owner (2026-09-27): the calls are small.
- The auto-dictation preference (auto-start on expand, the first-run "Auto-Enable Dictation"
  prompt, restart after each agent turn) is kept as it was; each auto-start now waits for
  speech, then records for backend transcription. A dictation nobody speaks into waits with no
  time limit (owner, 2026-09-28, over a 60 s limit): the microphone stays on and the screen
  awake until someone speaks, the mic or stop is tapped, or the pill closes.
- Speech detection is only as good as the classifier. Measured 2026-09-28 on synthetic
  speech: speech 20 dB quieter than normal inside noise scored ≥ 0.91, white noise ≤ 0.20 and
  mains hum ≤ 0.03. Someone else talking nearby (a TV, a conversation) is speech to it and
  starts the recording; crowd "babble" doesn't. Unverified on a device's real microphone.
- No live transcript while speaking: the text arrives in one piece after the tap (upload +
  model time, plus up to the backend's 1.5 s cleanup deadline). Accepted by the owner
  (2026-09-27).
- Dictation needs a TabMail sign-in and an active subscription; it counts toward usage like
  every AI request. A failure (subscription, rate limit, too long, no speech, microphone denied)
  shows nothing (decision 8); the reason is in the debug log only.
- A failed cleanup never costs the dictation: the transcript is appended as heard. A failed
  transcription loses that recording (as in Voice; no retry queue).
- Recording stops and is sent at `maxRecordingDuration`, 120 seconds from speech (decision 10): the most audio the
  default transcription model takes (AssemblyAI's Sync API, backend ADR-022); the model for the
  other languages (backend ADR-024) takes longer, so 120 s is the stricter limit. Voice's 5 minutes is a bug
  (owner, 2026-09-27), to be fixed there separately; until then the two apps differ here.
- Collapsing the pill ends the recording and still appends its text; the pill disappearing
  discards it.
- Untested by owner decision (2026-09-27, stage-2 review TC2/TC3): the real
  `MicrophoneCapture` session, engine and permission path runs only on a device (the tests use a
  fake capture, as TabMail Voice's do; a seam for it would be production code for tests only), and
  the pill's own wiring (text appended to the input, collapse finishes, leaving cancels, send
  finishes the dictation and then sends, a spinner while transcribing) is pinned by source fences (`ChatPillDictationWiringTests`) rather than hosted-view tests,
  which would need the controller injected into the chat pill view. The same fences pin the
  Settings language menu's row tags and the language tip's rules, one-time display, retirement on
  a choice and donation after a completed dictation: TipKit's datastore is configured by the app
  that hosts the tests and cannot be reset after that, so a tip's lifecycle cannot be run twice
  in one process (no TabMail tip has a behavioural test). What the menu stores, the language on
  the backend request, and the waveform's VoiceOver label are tested behaviourally, as is the
  real classifier: it hears a synthesised sentence and not white noise or mains hum.
- The dictation code logs lengths, durations and error types only, never the transcript or the
  audio. (Until 2026-09-29 the existing `#if DEBUG` short-reply log in `BackendClient`'s
  completions decoding printed a short cleaned dictation in debug builds, as it does any short
  completion; the cleanup no longer goes through that decoding.)

**Amendment 2026-09-29 — the cleanup runs in the transcription request (backend ADR-027).**
Owner, 2026-09-29: the transcription and its cleanup are one backend call on every client ("iOS
should change to a single call as well"), and the backend enforces the cleanup deadline. Each
dictation paid a second gateway pass (JWT, entitlement, quota, throttle) and a second round trip
for the cleanup.

- `transcribeDictation(wav:language:vocabulary:cleanup:)` sends `cleanup` (`app_name` "TabMail",
  `web_host` and `terminal_program` empty, `window_title`, `screen_text`, `dictionary`) and returns
  `DictationTranscription { text, cleanedText }`. A `cleaned_text` that isn't a string is an
  invalid response.
- The controller trims `text` (empty: nothing appended, as before), then appends
  `DictationCleanup.pasted`: the cleaned text, trimmed, or the transcript as heard when
  `cleaned_text` is `""` (the backend's cleanup failed, was refused, or ran past its deadline) or
  missing.
- `DictationCleanup.cleanUp`, the completions request and `DictationConfig.cleanupTimeout` /
  `cleanupPrompt` are removed. `transcriptionRequestTimeout` (45 s) now covers the cleanup too.
- Deploy order: backend ADR-027 first. An older backend ignores `cleanup` and answers no
  `cleaned_text`, so this build then appends the transcript uncleaned; it never fails the
  dictation. Released builds keep working against the new backend, which answers them exactly as
  before.
- Every field is cut to the backend's per-field limit (`DictationConfig.cleanupFieldMaxUTF16`,
  20,000 UTF-16 code units, its `cleanup.maxFieldChars`), between characters: the title keeps its
  start, the screen text its end, at the caret. Over the limit the backend refuses the whole
  request, the transcription included, and the title is the email's subject, which its sender
  chooses: an uncut one could make every dictation in that email's chat fail silently. The cut
  bounds the cleanup model's input only.
- The screen and dictionary now go with the audio even when the transcript comes back empty (the
  backend then runs no cleanup), where before they were sent only with a non-empty transcript.
  They were already sent to the same backend for every dictation that produced text.
- Tests: `BackendClientDictationTests` (the `cleanup` body, `cleaned_text` as sent, `""`, missing
  and non-string), `DictationCleanupTests` (variables, each within the limit, cut between characters, what is pasted), and
  `DictationControllerTests` (the variables go with the upload; `""`, blank and missing
  `cleaned_text` append the transcript; the production factory sends `cleanup`).

**Amendment 2026-09-29 — the recording uploads as FLAC, not WAV (TabMail Voice ADR-DESK-039).**
Owner, 2026-09-29: dictation took two to three seconds from the end of speech to the text, and the
raw WAV upload was one of the measured steps; the fix applies to iOS as well as Voice.

- `FLACEncoder.encode(pcm16Mono:sampleRate:)` replaces `WAVEncoder` (removed): lossless FLAC
  (RFC 9639), one frame per `DictationConfig.flacBlockSize` (4,096) samples, each frame's subframe the
  smallest of constant, verbatim and the fixed predictors of order 0–4 with partitioned Rice
  residuals (`flacMaxPartitionOrder` 6). It is Voice's encoder, choice for choice, so the same
  recording encodes to the same bytes on both; the request sends `format: "flac"`, which the backend
  already accepted. Speech encodes to about half of WAV's size.
- iOS encodes once when the recording finishes, where Voice encodes each frame as the audio
  arrives. On iOS the recorder trims its pre-roll until speech is heard and `append` runs on the
  capture callback under the recorder's lock, so encoding while recording would add work there for
  a few milliseconds' gain. Measured on a Mac (the golden signal, 7 s): 3 ms optimised, 26 ms in a
  debug build, against about 90 ms of upload saved per 7 s. The per-sample loops use unsafe buffers,
  `while` loops and non-copyable helpers because debug builds took 250 ms per 7 s without them.
- The upload's size limit is unchanged: FLAC's worst case (verbatim frames) is PCM plus a few bytes
  per frame, so `noRecordingOutlastsWhatTheModelTranscribes`' PCM bound still holds.
- Tests: `FLACEncoderTests` round-trips speech-like audio, silence, loud noise, a full-scale square
  wave, one sample, a block and a block and one through `FLACTestDecoder` (an independent decoder
  checking every CRC) and through Core Audio's own FLAC decoder, and pins the SHA-256 of the stream
  the reference `flac` decoder accepted, the hash Voice's `test/flac.test.ts` pins.
  `DictationControllerTests` and `BackendClientDictationTests` decode the upload instead of reading
  a WAV header.

**Amendment 2026-09-29 — warm-up at the tap, and a server error tried again (TabMail Voice ADR-DESK-039).**
Owner, 2026-09-29: "also the warmup and retry there as well".

- Warm-up: when a dictation starts listening, `BackendClient.warmUpDictation` sends `GET /whoami`
  (`DictationConfig.warmUpPath`) over `llmSession`, the session the transcription uses, with the
  signed-in session's token. The connection is then open, the token fetched (refreshed if due) and
  the backend's sign-in and entitlement caches warm by the time the recording is sent. It is best
  effort and never waited for; its answer is not read; signed out, nothing is sent. A dictation that
  does not start (offline, no AI access, opted out of AI) sends none. On a new account the request
  can start the signup trial, as any authenticated request can; such a user has already asked to
  dictate with AI.
- Retry: a transcription that failed on the server's side, a 5xx other than a 504 or a connection
  that dropped or could not be made (`DictationController.isServerError`), is sent again, the same recording, after
  500 ms and then 1.5 s (`transcriptionRetryDelays`). Meanwhile the waveform gives way to
  "Server error, retrying…" (`DictationPillView.retryingMessage`, Voice's wording), the one note
  this pill shows, until a retry answers; any other failure still ends silently. Not retried: a
  timeout (the request may still be running on the server), the backend's own 504 (it already
  waited 30 s for the speech model; retrying would hold the field for 1.5 minutes), 4xx refusals (401, 402, 403, 429, 400) and an unreadable answer.
  A dictation cancelled while it waits, or whose server error arrives after a cancel, sends nothing
  more. A retry after an answer lost in transit can count one dictation twice against the quota.
- The release tail stays 300 ms: the owner asked for the warm-up and the retry on iOS.
- Tests: `DictationControllerTests` (each 5xx and a dropped or failed connection retried with the
  same upload and the note shown only while it retries, gone when the text is appended; three
  failures end quietly; each delay waited; refusals, a timeout and a 504 sent once; a cancel during the wait, or before a server error
  arrives, sends nothing more; the warm-up sent once when listening starts and before the upload,
  none for a dictation that does not start, and one that never answers holds nothing up;
  `isServerError` table), `BackendClientDictationAuthTests` (the warm-up goes over the
  transcription's session with the token; signed out, nothing).

**Amendment 2026-09-29 — the recording is peak-normalised before upload (owner).** As TabMail
Voice's ADR-DESK-040: `AudioRecorder.finish` scales the whole recording by one gain so its loudest
sample sits at `DictationConfig.normalizedPeakDecibels` (−3 dBFS), boosting by at most
`maxNormalizationGainDecibels` (30 dB) and never cutting (`AudioRecorder.normalizePeak`). Measured
2026-09-29 (`tabmail-voice/Scripts/stt-compare`, 10 recordings peaking at −22 to −29 dBFS, 3 runs
each, word error rate after the Whisper English normaliser): MAI-Transcribe-2 made 9.5 % errors at
−3 dBFS against 11.0 % as recorded; a Whisper Large V3 host that dropped quiet speech went from 79 %
to 19 %. The FLAC was already encoded after the recording ends, so this adds no stage, only the
scaling pass. `Recording.peakLevel` stays the level as captured; the debug log adds the gain. One loud
click sets the gain, so a recording with a click louder than the speech is boosted less.
- Tests: `DictationAudioRecorderTests` (a quiet recording's loudest sample at −3 dBFS, the FLAC the
  same samples; near-silence boosted by at most 30 dB; a louder tone and digital silence unchanged;
  both signs scaled by one gain), `DictationControllerTests` › the upload's loudest sample at −3 dBFS.

**Amendment 2026-10-02 — the waveform always moves; only the recording waits for speech (owner).**
Owner, after using it: the waveform lying flat until speech is heard "feels like the app is stuck";
"the waveform should always be moving. The suppression of the non-speech at the beginning should
just happen under the hood." Decisions 8 and 10 no longer hold the waveform flat:
`DictationController.updateLevel` feeds `level` from the microphone's first real sound (above
`silenceDecibels`, so a device's start-up digital silence still shows nothing), speech or not, as
TabMail Voice's waveform does; `DictationPillView` draws `Waveform(level:)` with its idle ripple from
the start. What decision 10 decides is unchanged: the recording, its cap and the upload still wait for
the sound classifier to hear speech, and a dictation that never hears any sends nothing.
- The waveform now moves with a room's noise before anyone speaks; `LevelEnvelope` adapts to that
  noise as it does on TabMail Voice, so a steady hum settles rather than holding the bars high.
- Tests: `DictationControllerTests.theWaveformMovesBeforeSpeechIsHeard` (start-up silence then a
  steady room leaves `level` 0, so the silence never sets the floor; a rising room noise moves it with
  no speech heard), and the pill's source fence (no flat state; the pill reads `hasHeardSpeech` only
  for the waveform's colour, below).

**Amendment 2026-10-02 (later) — purple says it is listening, and retrying (owner).** "When it actually
starts to listen, the waveform color could turn from blue to a little bit more purple, our theme
color", for TabMail Voice and iOS alike; and while a server error is tried again, "the circle that
rotates turns a little bit purple". On iOS "listening" is the sound classifier hearing speech
(decision 10): the bars are the app's accent blue while the dictation waits for it and ease
(`waveformColourTransition`, 0.4 s) to `waveformVoicedColour`, the TabMail icon's purple, once
`hasHeardSpeech` (`DictationPillView.waveformColour`). While `isRetrying`, `DictationSpinner`'s track
and arc move `thinkingRetryColourShift` (0.3) along the blue → purple gradient
(`DictationSpinner.colours`); iOS shows its retry note at once, so the shift goes with it. TabMail
Voice's ADR-DESK-006 and ADR-DESK-039 amendments of the same date do the same (its "voice" is a
loudness cue, having no wait for speech).
*(Later, owner 2026-10-02: the purple was replaced, first by a muted crimson ("more red and more
professional … not just pure red"), which was "a little bit too red"; from a page of candidates the
owner chose "the gray to iOS system blue". The bars are now a washed-out grey-blue,
`waveformWaitingColour` #9DB3C9, while the dictation waits for speech, and ease to a vivid iOS system
blue, `waveformVoicedColour` #0A84FF, once it is heard, on iOS and TabMail Voice alike. Nothing else
changes; the spinner keeps its shift toward purple while retrying.)*
- Tests: `DictationControllerTests.theWaveformTakesItsRecordingColourOnSpeechAndTheSpinnerPurpleWhileRetrying`, and the
  pill's and the send slot's source fences (`Waveform(level:colour:)` from `hasHeardSpeech`,
  `DictationSpinner(isRetrying: dictation.isRetrying)`).
