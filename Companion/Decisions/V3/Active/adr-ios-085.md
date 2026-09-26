## ADR-IOS-085: Chat-Pill Dictation Uses TabMail Voice's Backend Speech-to-Text and Cleanup

**Status:** Active (2026-09-26)

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
   `DictationCleanup` sends the same prompt and variables.
2. Transcription goes through `BackendClient.transcribeDictation` (the app's auth token,
   `X-Client-Type: ios`); the cleanup through `sendCompletionsDirect` with tools and web search
   off. The prompt lives in the backend's `common/` prompts, so iOS resolves it with no backend
   change.
3. The "screen" the cleanup reads is the chat pill, captured when the dictation starts: what the
   pill is about (the email's sender, subject and snippet, or the draft's subject and body), the
   latest chat turns, and the input field as a `» ` line with the caret `‸` at its end.
4. `DictationController.start` refuses to start offline (`NetworkMonitor`); the pill disables the
   mic button while offline and idle. A recording already in progress can still be stopped.
5. `MicrophoneCapture` activates the audio session per dictation and deactivates it on every exit
   (iOS memory 086); all session and engine work is on one serial queue, which also orders a
   stop after the start it races.
6. `SpeechRecognizer` and the speech-recognition permission string are removed.

**Consequences:**

- Audio leaves the device. The backend stores and logs neither audio nor text (root ADR-004;
  backend ADR-022). The microphone permission string says so. The App Store privacy label may
  need "Audio Data" declared; that is an owner call.
- No live transcript while speaking: the text arrives in one piece after the tap (upload +
  model time, plus up to `cleanupTimeout` = 3 s for the cleanup).
- Dictation needs a TabMail sign-in and an active subscription; it counts toward usage like
  every AI request. Errors (subscription, rate limit, too long, offline) show in the pill for
  `errorDisplayDuration`.
- A failed cleanup never costs the dictation: the transcript is appended as heard. A failed
  transcription loses that recording (as in Voice; no retry queue).
- Recording stops and is sent at `maxRecordingDuration` (5 minutes, under the backend's 10 MiB
  upload limit).
- Collapsing the pill ends the recording and still appends its text; the pill disappearing
  discards it.
- Logs carry lengths, durations and error types only, never the transcript or the audio.
