# FlowType

FlowType is a private, system-wide AI dictation app for macOS. Tap its global hotkey for hands-free dictation or hold the same key for push to talk; the finished text is pasted at the cursor in the app you were already using.

It is a native Swift/AppKit menu-bar app with no account system, analytics, telemetry, database, or third-party Swift dependencies.

## What works

- Use one hybrid shortcut: tap once for hands-free recording or hold for push to talk.
- Optionally turn hybrid behavior off and assign a separate hands-free shortcut.
- Legacy two-shortcut mode also supports double-tapping push to talk to keep the same recording hands-free.
- Play distinct start and stop sounds so recording state is audible as well as visible.
- Follow the current macOS input automatically, or choose a specific connected microphone such as AirPods.
- Optionally use Apple's experimental voice processing for automatic gain, voice clarity, and music ducking, with safe fallback to normal capture.
- Hands-free and held recordings stop automatically after five minutes.
- `Esc` cancels a recording or an in-flight local/API transcription. FlowType observes Escape with a listen-only event tap, so Escape still reaches the frontmost app.
- Local transcription through `whisper.cpp`, or hosted transcription through OpenAI or Groq.
- Optional cleanup through an OpenAI-compatible language-model endpoint.
- A personal dictionary provides recognition hints and deterministic spelling replacements.
- The transcript remains on the clipboard by default. A config flag can restore the previous clipboard after pasting.
- A non-activating floating pill shows held, hands-free, processing, and error states without stealing keyboard focus.
- A native Settings window edits shortcut behavior, audio feedback, voice processing, the five-minute safety limit, clipboard behavior, providers, model paths, and personal dictionary.
- Menu-bar controls for settings, on/off, configuration files, permissions, launch at login, and quit.

## Mental model

FlowType separates the work into stages so each can be changed without rewriting the app:

```text
keyboard event
    ↓
gesture state machine (quick tap / held / hands-free / cancel)
    ↓
selected/default microphone → native recording → temporary 16 kHz mono WAV
    ↓
local whisper.cpp OR OpenAI/Groq transcription
    ↓
optional LLM cleanup → exact dictionary replacements
    ↓
clipboard → simulated Cmd-V at the current cursor
```

The state machine is important. It gives late API responses and `Esc` cancellation an explicit session identity, so a cancelled dictation cannot unexpectedly paste several seconds later.

## Install

### 1. Build the app

macOS 13 or later is required. Apple Silicon and Intel builds are supported; the build script targets the Mac it runs on.

```bash
./scripts/test-direct.sh
./scripts/build-app.sh
```

The finished app is `dist/FlowType.app`. Move it to `/Applications` before enabling Launch at Login, then open it:

```bash
open /Applications/FlowType.app
```

The Settings window opens on the first launch. After that, open it by clicking FlowType in Applications again or choosing **Settings…** from the waveform icon in the menu bar. FlowType is a background utility, so closing Settings leaves dictation running.

The build is ad-hoc signed for local use. It is not notarized for public distribution. A public release should use a Developer ID certificate, hardened runtime, and Apple notarization.

### 2. Install whisper.cpp and a model

The default configuration uses local transcription. Homebrew's current formula installs the official `whisper-cli` binary:

```bash
brew install whisper-cpp
```

Download the English `small` model (about 466 MB):

```bash
mkdir -p "$HOME/Library/Application Support/FlowType/models"
curl --fail --location \
  --output "$HOME/Library/Application Support/FlowType/models/ggml-small.en.bin" \
  "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.en.bin"
```

For higher accuracy at the cost of more memory and latency, download `ggml-medium.en.bin` from the same official model repository and update `transcription.localModelPath` in `config.json`.

The app checks the configured executable path first, then the standard Apple Silicon and Intel Homebrew locations.

## Required macOS permissions

FlowType needs three permissions. Open **System Settings → Privacy & Security**:

1. **Microphone** — allows recording only while a dictation is active.
2. **Input Monitoring** — allows the background app to observe the global hotkey and Escape.
3. **Accessibility** — allows FlowType to synthesize `Cmd-V` in the frontmost app.

Use the guided permission button in FlowType Settings. It requests Microphone first, then opens the exact Input Monitoring and Accessibility panes one at a time. When macOS makes FlowType quit after a permission change, the relaunched app resumes at the next missing step. The button reads **Permissions Ready** only after all three checks pass.

Development rebuilds change an ad-hoc signature. If a previously granted permission stops working after a rebuild, remove the old FlowType entry from the privacy list, reopen the newly built app, and grant it again.

### Avoid the macOS Fn shortcut conflict

macOS can assign double-press `Fn` to Apple's own Dictation feature. If both tools respond, either disable/change that shortcut under **System Settings → Keyboard → Dictation**, or configure FlowType to use a different hotkey.

## Configuration

Use the native Settings window for everyday changes. On first launch FlowType also creates these human-readable files:

```text
~/Library/Application Support/FlowType/config.json
~/Library/Application Support/FlowType/dictionary.txt
~/Library/Application Support/FlowType/.env
```

Advanced users can still open and reload these files from the menu-bar menu. Missing JSON fields inherit the app defaults, so a small partial configuration is valid. Settings validates changes before saving and reloads them into the running app immediately.

### Current model and cost

The default setup uses `whisper.cpp` with `ggml-small.en.bin`. That model runs entirely on this Mac and costs **$0 per dictation**; recorded audio does not leave the device. The model file is stored locally and is roughly 466 MB.

OpenAI and Groq are optional alternatives. If you select either cloud transcription provider and add its key to `.env`, audio is sent to that provider and usage is billed to the account that owns the key. FlowType itself has no subscription or account system.

AI cleanup is a separate step. Without an API key, the default safe fallback inserts the raw local Whisper transcript, so the current local-only setup still costs $0. Adding a cloud cleanup key can incur usage charges for each completed transcript. The Transcription tab shows the active path and whether a required key is configured without revealing the key itself.

### Dictation shortcuts

The default **hybrid shortcut** uses one key for both styles:

- Press Right Option and release it quickly to start hands-free recording. Tap it again to stop, transcribe, and paste.
- Hold Right Option while speaking and release it to stop, transcribe, and paste.

Recording begins on key-down in both cases, so switching to hands-free does not lose the first words. The quick-tap threshold defaults to 240 milliseconds. While hybrid mode is enabled, `toggleHotkey` is retained in the settings file as a reversible fallback but is ignored by the app.

The default configuration is:

```json
{
  "gestures": {
    "hybridPrimaryHotkey": true
  },
  "hotkey": {
    "key": "right_option",
    "modifiers": []
  },
  "toggleHotkey": {
    "key": "fn",
    "modifiers": []
  }
}
```

Turn hybrid mode off in Settings if you prefer the older two-shortcut behavior. In that mode, `hotkey` controls push to talk and `toggleHotkey` controls tap-to-start/tap-to-stop hands-free recording; the two shortcuts must be different.

Example `Control + Option + Space` hotkey:

```json
{
  "hotkey": {
    "key": "space",
    "modifiers": ["control", "option"]
  }
}
```

Supported modifiers are `command`, `control`, `option`, `shift`, and `fn`. Supported keys include letters, numbers, punctuation, `space`, `return`, `tab`, `delete`, and the arrow keys. Standalone `right_option`, `right_command`, `right_control`, and `right_shift` distinguish the physical key on the right side of the keyboard. Escape is reserved for cancellation. In legacy two-shortcut mode, the two recording shortcuts must be different.

FlowType observes shortcuts with a listen-only event monitor, so the key event still reaches the frontmost app. A standalone letter may therefore type that letter; a side-specific modifier or a modified shortcut is usually the safer choice.

### Microphone selection, recording sounds, and voice clarity

The General tab lists the input devices currently exposed by macOS and includes the local audio controls:

- **Automatic — System Default** is the safe default. FlowType checks the macOS default again at the start of every recording, so connecting AirPods and selecting them in Control Center is enough.
- Choose a named device to make FlowType prefer that microphone without changing the Mac's global input setting.
- If a preferred device is disconnected, FlowType labels it unavailable in Settings and safely falls back to the current system default for that recording.

- **Start/stop sounds** play short macOS sounds when the microphone starts and stops.
- **Voice clarity** optionally enables Apple's voice processing and automatic gain control, which raises quieter speech and reduces non-speech interference. Normal microphone capture is the reliable default.
- **Lower other audio** controls how strongly macOS ducks music and audio from other apps while FlowType is listening. Medium is the default.

Voice processing is available on macOS 13 and later. Configurable ducking is available on macOS 14 and later. If the selected microphone or virtual audio device rejects voice processing or exposes an unsafe multichannel stream, FlowType automatically retries with ordinary recording rather than risking a silent dictation. FlowType does not alter the Mac's master volume, so there is no volume value to restore after recording.

The floating recording pill shows the microphone FlowType actually opened. AirPods only appear when they are connected and macOS exposes them as an input device; use **Refresh** in Settings after connecting or disconnecting audio hardware.

### Transcription provider

Local, fully offline transcription is the default:

```json
{
  "transcription": {
    "provider": "local",
    "localExecutable": "/opt/homebrew/bin/whisper-cli",
    "localModelPath": "~/Library/Application Support/FlowType/models/ggml-small.en.bin",
    "language": "en"
  }
}
```

OpenAI transcription:

```json
{
  "transcription": {
    "provider": "openai",
    "openAIModel": "whisper-1"
  }
}
```

```dotenv
OPENAI_API_KEY=your_key_here
```

Groq transcription:

```json
{
  "transcription": {
    "provider": "groq",
    "groqModel": "whisper-large-v3-turbo"
  }
}
```

```dotenv
GROQ_API_KEY=your_key_here
```

Audio is sent off-device only when `transcription.provider` is `openai` or `groq`.

### LLM cleanup

Cleanup is a separate stage from speech recognition. It removes filler, repairs punctuation, and preserves names, numbers, technical terms, intent, and apparent casing style.

`LLM_API_KEY`, `LLM_BASE_URL`, and `LLM_MODEL` in `.env` override the cleanup values in `config.json`. If `LLM_API_KEY` is absent, cleanup reuses `OPENAI_API_KEY` or `GROQ_API_KEY` according to `cleanup.provider`.

If cleanup fails and `fallbackToRawOnError` is `true`, FlowType still inserts the raw transcript instead of losing the dictation.

For completely offline operation, either disable cleanup:

```json
{
  "cleanup": {
    "enabled": false
  }
}
```

or point the cleanup stage at a locally running OpenAI-compatible Chat Completions endpoint:

```json
{
  "cleanup": {
    "enabled": true,
    "provider": "local",
    "baseURL": "http://127.0.0.1:11434/v1",
    "model": "your-local-model"
  }
}
```

The local cleanup provider does not require an API key.

### Personal dictionary

Bare lines are vocabulary hints sent to Whisper and the cleanup model:

```text
Arkis
whisper.cpp
Solomon de Leon
```

Use `=>` for an exact, case-insensitive whole-phrase replacement after cleanup:

```text
whisper flow => Wispr Flow
super whisper => Superwhisper
```

The replacement step is deterministic. It will replace `WHISPER FLOW`, but it will not alter a larger word such as `flowing`.

### Clipboard behavior

Keep the final transcript on the clipboard, which is the default and safest recovery path:

```json
{
  "clipboard": {
    "restorePrevious": false
  }
}
```

Restore the prior clipboard after waiting for the frontmost app to consume `Cmd-V`:

```json
{
  "clipboard": {
    "restorePrevious": true,
    "restoreDelayMilliseconds": 500
  }
}
```

Clipboard restoration is inherently timing-sensitive in unusually slow apps. Increase the delay if an app sometimes pastes the prior clipboard value.

## Product research that informed the scope

- [Wispr Flow](https://docs.wisprflow.ai/articles/2772472373-what-is-flow) validates the hold/release and double-press hands-free gesture, but its current transcription requires an internet connection. FlowType keeps the gesture while making local transcription the default.
- [Superwhisper](https://superwhisper.com/docs/security/sensitive-data) separates voice recognition from optional language-model post-processing and lets each stage be local or cloud. FlowType uses the same clean boundary.
- [VoiceInk](https://tryvoiceink.com/docs/introduction) shows the value of global push-to-talk, personal vocabulary, deterministic replacements, and recovery actions in a local-first tool.
- [MacWhisper](https://docs.macwhisper.com/article/16-global) validates the smaller global overlay plus automatic clipboard workflow.

This first version intentionally does not copy their account systems, transcript history, per-app modes, screen-context reading, command modes, or update infrastructure.

## Privacy and data lifecycle

- There is no telemetry or account layer.
- Temporary audio lives in the macOS temporary directory and is deleted after success, failure, or cancellation.
- Local transcription never sends audio off-device.
- Dictionary and configuration files remain in the user's Application Support directory. Vocabulary terms are included in recognition/cleanup prompts, so those terms are sent to the selected provider when a cloud stage is enabled.
- LLM cleanup sends transcript text only when a cloud cleanup endpoint is enabled.
- OpenAI/Groq transcription sends the audio to the selected provider; their API data terms apply.

## Development and verification

Run the deterministic state-machine and dictionary tests:

```bash
./scripts/test-direct.sh
```

Build and validate the app bundle:

```bash
./scripts/build-app.sh
plutil -lint dist/FlowType.app/Contents/Info.plist
codesign --verify --deep --strict --verbose=2 dist/FlowType.app
```

A standard `Package.swift` and XCTest suite are also included for development in a full, internally consistent Xcode installation. The direct scripts use only Apple's compiler and frameworks and are the authoritative no-dependency build path.

## Current boundaries

- Transcription starts after release; there is no partial streaming transcript yet.
- `whisper-cli` and the selected model are installed separately rather than inflating the app bundle by hundreds of megabytes.
- Settings covers normal configuration; the cleanup prompt and fine-grained timing values remain advanced `config.json` options.
- The local build is signed for personal use, not notarized for redistribution.
- Device-level verification still requires a real microphone, macOS privacy grants, a focused third-party text field, and either a local model or provider key.
