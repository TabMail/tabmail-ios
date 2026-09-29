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
   off. The backend already serves the prompt to iOS clients, so it needs no change.
3. The "screen" the cleanup reads is the chat pill, captured when the dictation starts: what the
   pill is about (the email's sender, subject and snippet, or the draft's subject and body), the
   latest chat turns, and the input field as a `» ` line with the caret `‸` at its end. Only
   the last `contextMaxScreenChars` = 500 characters, ending at the caret, are sent, and the
   cleanup gets `cleanupTimeout` = 1.5 s (owner, 2026-09-28, as TabMail Voice's a78baba: the
   cleanup is a light pass and more context slows it; was 20,000 characters and 3 s).
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
  model time, plus up to `cleanupTimeout` = 1.5 s for the cleanup). Accepted by the owner
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
  audio. (The existing `#if DEBUG` short-reply log in `BackendClient`'s completions decoding
  prints a short cleaned dictation in debug builds, as it does any short completion.)
