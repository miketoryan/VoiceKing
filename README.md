# VoiceKing

VoiceKing is an experimental, personal-use iPhone voice keyboard. It records through the containing app, transcribes with ChatGPT/Codex, optionally cleans up the transcript, and inserts the result into the active text field.

## Modes

- **Smart Cleanup (default)** — adds punctuation and paragraphs, removes meaningless filler and repetition, and fixes obvious grammar or word-order problems. It must preserve the speaker's meaning, names, numbers, amounts, dates, and technical terms; it must not add information or summarize substantive content.
- **Verbatim** — returns the transcription without a second-pass rewrite. Use it for quotations, interviews, and meeting records where the original wording matters.

The selected mode is stored by the keyboard. Smart Cleanup first calls the transcription endpoint, then sends the raw transcript through `https://chatgpt.com/backend-api/codex/responses` with a strict cleanup instruction. If cleanup is unavailable, VoiceKing returns the valid raw transcription rather than losing it.

## Architecture

- **VoiceKing app** — ChatGPT OAuth, microphone permission, background audio session, transcription, and smart cleanup.
- **VoiceKingKeyboard extension** — mode selector, microphone/start/stop UI, app wake-up, and text insertion.
- **Localhost bridge** — the keyboard talks to the app through `127.0.0.1:14557`, avoiding the App Group entitlement unavailable to free Apple developer accounts.

The containing app records on behalf of the keyboard because iOS keyboard extensions cannot access the microphone directly. Recordings have no fixed duration limit and are uploaded through a temporary multipart file instead of being copied fully into memory.

While visible, the keyboard sends a heartbeat every 2 seconds. When the keyboard is dismissed, switched, or terminated, VoiceKing closes the microphone after about 10 seconds. If iOS has suspended the service by the next recording, tapping the keyboard microphone opens VoiceKing with its private URL scheme, starts the service, asks the app to return to the previous foreground app, and starts recording when the keyboard reconnects. The automatic return uses a private iOS selector and is intended only for personal sideloading, not App Store distribution.

## Build

The repository's `Build` GitHub Actions workflow selects Xcode 26.3, validates a simulator build, archives an unsigned iPhone build, and uploads `VoiceKing-unsigned.ipa`. This route is intended for an older Mac that cannot run Xcode 26.

1. Push a commit to `main` or a `codex/**` test branch.
2. Open the completed workflow run and download the `VoiceKing-unsigned` artifact.
3. Extract the ZIP to get `VoiceKing-unsigned.ipa`.
4. In AltServer on the Mac, hold Option while opening its menu and choose **Sideload .ipa…**.
5. Sign with the same free Apple ID whenever refreshing VoiceKing. A free signature lasts 7 days.

For a local build, install Xcode 26+ and XcodeGen, run `xcodegen generate`, and select a signing team for both targets. VoiceKing intentionally has no App Group entitlement.

## Usage

1. Open VoiceKing, sign in with ChatGPT, and tap **Start Keyboard Service** once.
2. In Settings → General → Keyboard → Keyboards, add VoiceKing and enable **Allow Full Access**.
3. Switch to VoiceKing from the globe key in any text field.
4. Choose **智能整理** or **原文模式**. 智能整理 is selected by default.
5. Tap the microphone to start; tap again to finish and insert the result.
6. After leaving the keyboard, the microphone closes in about 10 seconds. If the service is sleeping next time, tapping the microphone performs the wake-and-return flow automatically.

## Limitations

The ChatGPT/Codex endpoints used by this project are undocumented and can change without notice. The automatic app return is also an unsupported personal-sideload workaround and must be verified on each iOS release.

## Status

v0.2 — VoiceKing naming, dual transcription modes, strict smart cleanup, and keyboard-triggered service recovery.

## Acknowledgements

The design was informed by the MIT-licensed projects:

- `A3Boy/codex-voice-input`
- `n0an/VivaDicta`

See `NOTICE.md` and `LICENSE`.
