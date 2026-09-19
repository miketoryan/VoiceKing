# VoiceKing

VoiceKing is a personal-use iPhone voice keyboard. It briefly wakes its containing app to start microphone capture, returns to the original text field, transcribes with ChatGPT, and inserts the result through the keyboard extension.

## Current interaction

The v0.3.9 test flow follows the current Typeless iOS interaction observed in version 2.6.2:

1. Open a text field and switch to the VoiceKing keyboard.
2. Tap the central microphone.
3. VoiceKing briefly appears with a simple launch screen, starts capture in the foreground, and automatically returns to the original app.
4. Speak while the keyboard shows the recording state.
5. Tap the microphone again to finish. The keyboard shows processing and inserts the result when it is ready.

There is no floating overlay or video-based background mode. The wake-and-return route is the only fresh-recording path. If the microphone is still active during the 10-second exit grace period, recording can start immediately without another wake.

## Keyboard design

- Compact VoiceKing header
- Smart Cleanup / Verbatim mode switch
- Chinese / English recognition switch
- Large central voice button with idle, recording, and processing states
- Globe, newline, and delete controls
- Voice-only design; no QWERTY or Pinyin keyboard is bundled

## Modes

- **Smart Cleanup (default)** adds punctuation and paragraphs, removes meaningless filler and repetition, and fixes obvious grammar or word-order problems. It must preserve meaning, names, numbers, amounts, dates, units, model numbers, and technical terms. It must not add information or summarize substantive content.
- **Verbatim** returns the transcription without a second-pass rewrite. It is intended for quotations, interviews, and meeting records.

Smart Cleanup first calls the transcription endpoint, then sends the raw transcript through `https://chatgpt.com/backend-api/codex/responses` with strict cleanup instructions. If cleanup fails, VoiceKing returns the valid raw transcript instead of losing it.

## Architecture

- **VoiceKing app** handles ChatGPT OAuth, microphone permission, recording, transcription, and smart cleanup.
- **VoiceKingKeyboard extension** handles mode/language controls, app wake, service status, result insertion, newline, delete, and keyboard switching.
- **Localhost bridge** connects the keyboard and containing app through `127.0.0.1:14557`, avoiding the App Group entitlement unavailable to free Apple developer accounts.
- **KeyboardKit host resolver** identifies the app that owns the active text field on current iOS releases so VoiceKing can return after foreground capture starts.

The containing app records on behalf of the keyboard because iOS keyboard extensions cannot access the microphone directly. Recordings have no fixed duration limit and are uploaded through a temporary multipart file instead of being copied fully into memory.

## Microphone lifecycle

- The microphone starts only after the user taps the VoiceKing voice button.
- Leaving the input interface starts a 10-second grace period.
- If the keyboard does not return during that period, capture stops. An active recording is finished and transcribed; an idle microphone is closed.
- The background service keeps only a silent audio session alive so the localhost bridge remains reachable. Fresh capture still uses the foreground wake-and-return route.

## Build and sideload

The `Build` GitHub Actions workflow selects Xcode 26.3, validates a simulator build, archives an unsigned iPhone build, and uploads `VoiceKing-unsigned.ipa`.

1. Push a commit to `main` or a `codex/**` test branch.
2. Download the `VoiceKing-unsigned` artifact from the completed workflow.
3. Sideload the IPA with Sideloadly using the same free Apple ID as previous VoiceKing builds.
4. A free Apple signature normally needs refreshing every 7 days.

## Limitations

The ChatGPT/Codex endpoints used by this project are undocumented and may change. Generic automatic return to another iOS app also has no supported public API, so the personal-sideload return helper must be verified on each iOS release. If automatic return is rejected, VoiceKing keeps recording and shows a clear message so the user can return manually.

## Status

v0.3.9 current Typeless-style test: one-tap wake, foreground microphone start, automatic host return, simplified voice keyboard, matching app/extension versions, and all obsolete floating-media experiments removed.

## Acknowledgements

The design was informed by Typeless's public iOS behavior and the MIT-licensed `A3Boy/codex-voice-input` and `n0an/VivaDicta` projects. See `NOTICE.md` and `LICENSE`.
