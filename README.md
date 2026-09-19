# VoiceKing

VoiceKing is an experimental, personal-use iPhone voice keyboard. It records through the containing app, transcribes speech with ChatGPT/Codex, optionally cleans up the transcript, and inserts the result into the active text field.

## v0.3.6: Typeless-style no-switch path

The primary interaction now follows the behavior publicly documented by Typeless for iOS:

- **Skip app switching uses Picture in Picture.** Start it from the VoiceKing Home tab, then tuck the PiP window against the left or right edge of the screen.
- **Solid microphone = no-switch path ready.** The keyboard can ask VoiceKing to record without first opening the app.
- **Outline microphone = fallback path.** VoiceKing may need to briefly open the containing app if the service has been suspended.
- **The microphone stays off while idle.** Keyboard heartbeat/state polling no longer arms the microphone. Input starts only after the user taps Speak and stops immediately after Stop.
- The previous app-open / host-app-return code remains only as a personal-sideload fallback. It is no longer the primary architecture.

This is inspired by Typeless's documented user-facing behavior; it is not a claim about Typeless's private implementation.

## Modes

- **Smart Cleanup (default)** — adds punctuation and paragraphs, removes meaningless filler and repetition, and fixes obvious grammar or word-order problems. It must preserve the speaker's meaning, names, numbers, amounts, dates, and technical terms; it must not add information or summarize substantive content.
- **Verbatim** — returns the transcription without a second-pass rewrite. Use it for quotations, interviews, and meeting records where the original wording matters.

The mode is selected at the top of the VoiceKing keyboard and persists between uses. Smart Cleanup first calls the transcription endpoint, then sends the raw transcript through `https://chatgpt.com/backend-api/codex/responses` with a strict cleanup instruction. If cleanup is unavailable, VoiceKing returns the valid raw transcription rather than losing it.

## Architecture

- **VoiceKing app** — ChatGPT OAuth, recognition-language setting, microphone permission, Picture in Picture service, transcription, and smart cleanup.
- **VoiceKingKeyboard extension** — mode selector, microphone/start/stop UI, service status, app wake fallback, result insertion, globe key, and delete key. It intentionally does not include a QWERTY or Pinyin keyboard.
- **Picture in Picture** — keeps the containing app reachable while another app is in front. The PiP status view can be tucked off-screen.
- **Localhost bridge** — the keyboard talks to the app through `127.0.0.1:14557`, avoiding the App Group entitlement unavailable to free Apple developer accounts.

The containing app records on behalf of the keyboard because iOS keyboard extensions cannot access the microphone directly. Recordings have no fixed duration limit and are uploaded through a temporary multipart file instead of being copied fully into memory.

## Usage

1. Open VoiceKing and sign in with ChatGPT.
2. Tap **Start Keyboard Service**.
3. Tap **Enable Skip App Switching / 开启免跳转模式** and leave the Picture in Picture window active. It may be tucked against the screen edge.
4. In Settings → General → Keyboard → Keyboards, add VoiceKing and enable **Allow Full Access**.
5. Open a text field in another app and switch to VoiceKing.
6. A **solid microphone** means the PiP no-switch path is ready. Tap Speak and begin dictating immediately.
7. Tap Stop. VoiceKing closes the microphone before transcription/cleanup continues, then inserts the result.
8. If the keyboard shows an outline microphone because VoiceKing is unavailable, tapping it uses the older wake/open-app fallback.

## Build

The repository's `Build` GitHub Actions workflow selects Xcode 26.3, validates a simulator build, archives an unsigned iPhone build, and uploads `VoiceKing-unsigned.ipa`.

1. Push a commit to `main` or a `codex/**` test branch.
2. Open the completed workflow run and download the `VoiceKing-unsigned` artifact.
3. Extract the ZIP to get `VoiceKing-unsigned.ipa`.
4. Sideload the IPA with the same free Apple ID whenever refreshing VoiceKing. A free signature lasts 7 days.

## Limitations

The ChatGPT/Codex endpoints used by this project are undocumented and can change without notice. PiP/background lifecycle behavior must be validated on a real iPhone. The automatic host-app return fallback uses unsupported behavior and is intended only for personal sideloading, not App Store distribution.

## Status

v0.3.6 Typeless-PiP test — Smart Cleanup and Verbatim modes, Chinese/English speech recognition, PiP-based Skip App Switching, mic-off-until-Speak behavior, solid/outline mic status, and the existing wake/open-app fallback.

## Acknowledgements

The design was informed by:

- Typeless's public iOS interaction documentation
- `A3Boy/codex-voice-input`
- `n0an/VivaDicta`

See `NOTICE.md` and `LICENSE`.
