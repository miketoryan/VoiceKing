# VoiceKing

VoiceKing is a personal-use iPhone voice keyboard. When its background service is alive, it starts capture without leaving the current text field. If background activation fails, it briefly wakes its containing app, returns automatically, transcribes with ChatGPT, and inserts the result through the keyboard extension.

## Current interaction

The v0.5.8 flow follows the current Typeless iOS interaction observed in version 2.6.2:

1. Open a text field and switch to the VoiceKing keyboard.
2. Tap the central microphone.
3. The keyboard always asks the running VoiceKing service to start capture first. A cold microphone enables a bounded foreground fallback, but must not trigger an immediate app switch. Only after background start actually fails may VoiceKing briefly appear, start capture in the foreground, and return to the original app.
4. Speak while the keyboard shows the recording state.
5. Tap the microphone again to finish. The keyboard shows processing and inserts the result automatically when it is ready; there is no insertion confirmation.

There is no floating overlay or video-based background mode. Background resume is attempted first; wake-and-return is an automatic recovery path only when the background service cannot start a valid capture.

## Keyboard design

- Compact VoiceKing header
- Smart Cleanup / Verbatim mode switch
- Automatic spoken-language detection, including mixed Chinese and English
- Large central voice button with idle, recording, and processing states
- Globe, newline, and delete controls
- Voice-only design; no QWERTY or Pinyin keyboard is bundled

## Modes

- **Smart Cleanup (default)** adds punctuation and paragraphs, removes meaningless filler and repetition, and fixes obvious grammar or word-order problems. It must preserve meaning, names, numbers, amounts, dates, units, model numbers, and technical terms. It must not add information or summarize substantive content.
- **Verbatim** returns the transcription without a second-pass rewrite. It is intended for quotations, interviews, and meeting records.

Smart Cleanup first calls the transcription endpoint, then sends the raw transcript through `https://chatgpt.com/backend-api/codex/responses` with strict cleanup instructions. If cleanup fails, VoiceKing returns the valid raw transcript instead of losing it.

## Architecture

- **VoiceKing app** handles ChatGPT OAuth, microphone permission, recording, transcription, and smart cleanup.
- **VoiceKingKeyboard extension** handles mode control, background-first recording requests, app recovery, service status, automatic result insertion, newline, delete, and keyboard switching.
- **Localhost bridge** connects the keyboard and containing app through `127.0.0.1:14557`, avoiding the App Group entitlement unavailable to free Apple developer accounts.
- **KeyboardKit host resolver** identifies the app that owns the active text field on current iOS releases so VoiceKing can return after foreground capture starts.

The containing app records on behalf of the keyboard because iOS keyboard extensions cannot access the microphone directly. Recordings have no fixed duration limit and are uploaded through a temporary multipart file instead of being copied fully into memory.

## Microphone lifecycle

- The microphone starts only after the user taps the VoiceKing voice button.
- Tapping stop ends file writing immediately. While the VoiceKing keyboard remains visible, the microphone engine stays ready for the next dictation.
- Leaving the input interface starts a 10-second grace period.
- If the keyboard does not return during that period, capture stops. An active recording is finished and transcribed; an idle microphone is closed.
- VoiceKing does not play silent audio in the background. It resumes capture directly only while iOS still allows the app to respond; otherwise the keyboard automatically falls back to foreground wake-and-return.

## Build and sideload

The `Build` GitHub Actions workflow selects Xcode 26.3, validates a simulator build, archives an unsigned iPhone build, and uploads `VoiceKing-unsigned.ipa`.

1. Push a commit to `main` or a `codex/**` test branch.
2. Download the `VoiceKing-unsigned` artifact from the completed workflow.
3. Sideload the IPA with AltStore/AltServer using the same free Apple ID as previous VoiceKing builds.
4. A free Apple signature normally needs refreshing every 7 days.

## Limitations

The ChatGPT/Codex endpoints used by this project are undocumented and may change. Generic automatic return to another iOS app also has no supported public API, so the personal-sideload return helper must be verified on each iOS release. If automatic return is rejected, VoiceKing keeps recording and shows a clear message so the user can return manually.

## Status

v0.5.8: restores background-first microphone startup and serializes foreground handoff attempts. Tapping the microphone no longer treats a cold microphone as an immediate reason to leave the keyboard; the app handoff remains a bounded recovery path. SwiftUI openURL is tried first and the modern responder-chain fallback is only attempted if the keyboard is still visible after 600 ms. v0.5.6/v0.5.7 request validation, active-app gating, PCM confirmation, and handoff security remain intact.

v0.5.7: improves warm-background activation by replacing the deprecated responder-chain `openURL:` call with the modern completion-handler form, while treating actual keyboard disappearance or matching bridge state as the success signal. Duplicate handoff URLs are idempotent. Local bridge results are capability-protected by the recording request ID, malformed HTTP lengths and duplicate OAuth parameters are rejected safely, and a microphone shutdown error no longer deletes valid captured speech.

v0.5.6: waits until the app is genuinely active before restarting AVAudioSession, clears stale service-ready state before every restart, and returns to the host only after the current request has written real PCM frames.

v0.5.5: restores the foreground handoff path without restoring silent background audio or Picture in Picture. A cold microphone wakes VoiceKing immediately, a warm engine may still record directly, real PCM validation remains required, and the microphone still closes about 10 seconds after leaving the keyboard.

## Acknowledgements

The design was informed by Typeless's public iOS behavior and the MIT-licensed `A3Boy/codex-voice-input` and `n0an/VivaDicta` projects. See `NOTICE.md` and `LICENSE`.
