<p align="center">
  <img src="docs/assets/flowtype-logo.png" alt="FlowType logo" width="128">
</p>

<h1 align="center">FlowType</h1>

<p align="center">
  <strong>Talk instead of type. Anywhere on your Mac. Nothing leaves your computer.</strong>
</p>

<p align="center">
  <a href="https://github.com/jdlinventures/flowtype-macos/releases/latest"><img src="https://img.shields.io/github/v/release/jdlinventures/flowtype-macos?label=download&color=2ea44f" alt="Latest release"></a>
  <a href="https://github.com/jdlinventures/flowtype-macos/releases"><img src="https://img.shields.io/github/downloads/jdlinventures/flowtype-macos/total?color=blue" alt="Downloads"></a>
  <img src="https://img.shields.io/badge/macOS-13%2B-black?logo=apple" alt="macOS 13+">
  <img src="https://img.shields.io/badge/Apple%20Silicon%20%2B%20Intel-universal-lightgrey" alt="Universal build">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-yellow" alt="MIT license"></a>
</p>

Press a key, say what you want to write, and the words appear wherever your cursor is: Slack, Notes, Gmail, your code editor, anything. Speech recognition runs **on your Mac** with an open-source model, so it is free to use and your voice is never uploaded.

> [!WARNING]
> **macOS will say "Apple could not verify FlowType is free of malware."** That is expected. FlowType is a free community app with no paid Apple developer certificate, so macOS shows this for every download.
>
> **The fix takes 10 seconds:** open **System Settings → Privacy & Security**, scroll down, and click **Open Anyway** next to the FlowType message. Then open FlowType again.
>
> Do **not** turn off Gatekeeper or run any "disable security" command someone suggests online. You only need to approve this one app.

## Install (5 steps)

1. **Download** the `.dmg` from the [latest release](https://github.com/jdlinventures/flowtype-macos/releases/latest).
2. **Open the DMG** and drag **FlowType** onto the **Applications** folder.
3. **Open FlowType** from Applications. When macOS blocks it, use the **Open Anyway** fix in the yellow box above.
4. **Allow three permissions** when asked: **Microphone** (to hear you), **Input Monitoring** (to notice your shortcut key), **Accessibility** (to paste the text for you). FlowType walks you through each one.
5. **Pick a speech model** in the Settings window and click **Install**. *Medium English* (1.5 GB) is the most accurate; *Small English* (0.5 GB) downloads faster. This is a one-time download.

That's it. FlowType lives in your menu bar as a small waveform icon. Stuck? The [friend-proof install guide](docs/INSTALL_FOR_FRIENDS.md) covers every error message we know about.

## How to use it

| You do this | FlowType does this |
| --- | --- |
| **Hold Right Option** and talk, then let go | Types what you said |
| **Tap Right Option** once, talk, tap again | Same thing, hands-free (for longer dictations) |
| Press **Esc** while recording | Cancels, nothing is typed |
| Menu bar → **Retry Last Transcription** | Runs the last recording again (handy if it came out wrong) |
| Menu bar → **Recording History…** | See, replay, copy, or delete the last three days of recordings |

A small pill appears at the bottom of the screen while you talk and disappears when it's done. You can change the shortcut key, the microphone, and everything else in **Settings**.

## How it works (the short version)

```text
you talk  →  FlowType records  →  Whisper turns speech into text  →  text is pasted at your cursor
                                   (runs on your Mac, free)
```

- **The speech-to-text model is [Whisper](https://github.com/openai/whisper)**, an open-source model released by OpenAI. FlowType runs it locally using [whisper.cpp](https://github.com/ggml-org/whisper.cpp), a fast C++ version, on either the *medium.en* or *small.en* English model you choose at setup.
- **A tiny second model, [Silero VAD](https://github.com/snakers4/silero-vad)**, checks whether you actually spoke, so silence or background noise doesn't turn into made-up words.
- **Optional cleanup**: if you want, an AI model can tidy the text (remove "um", fix punctuation). This is off unless you add your own API key, because it sends the text to a cloud service.
- **Optional cloud transcription**: you can point FlowType at OpenAI or Groq instead of the local model. Same deal: your key, your bill, your choice. By default nothing is sent anywhere.

## How it was built

FlowType is a native macOS app written in **Swift** with Apple's AppKit, and it has **zero third-party Swift dependencies**. The only bundled outside code is whisper.cpp, compiled from a pinned source commit so every release is reproducible. There is no account system, no analytics, no telemetry, and no database; your recordings and settings are plain files in your own Library folder that you can inspect or delete any time.

It is a personal project shared as-is under the MIT license. Bug reports and pull requests are welcome in [Issues](https://github.com/jdlinventures/flowtype-macos/issues).

## Privacy in four lines

- Your voice is processed on your Mac. It is never uploaded unless **you** turn on a cloud provider.
- Recordings are kept for **three days** so you can retry a bad transcription, then deleted automatically.
- FlowType has no account, no tracking, and no analytics of any kind.
- The only network request it makes on its own is a once-a-day check of this GitHub page for a new version, and it never installs anything without you.

---

<details>
<summary><h2>Full reference (for the curious and for developers)</h2></summary>

## Everything it can do

- Use one hybrid shortcut: tap once for hands-free recording or hold for push to talk.
- Optionally turn hybrid behavior off and assign a separate hands-free shortcut.
- Legacy two-shortcut mode also supports double-tapping push to talk to keep the same recording hands-free.
- Play the same short Pop sound at recording start and stop so both boundaries are clear.
- Follow the current macOS input automatically, or choose a specific connected microphone. When AirPods are handling output and are also the default input, Automatic mode uses the Mac microphone to avoid Bluetooth's low-quality two-way audio mode.
- Test the selected microphone for three seconds in Settings and watch a live input meter both there and in the recording pill.
- Lower music and other output independently while recording, then restore the exact previous volume after stop, cancellation, quit, or crash recovery.
- Optionally apply bounded post-capture gain to quiet speech without changing healthy recordings.
- Hands-free and held recordings stop automatically after five minutes.
- `Esc` cancels a recording or an in-flight local/API transcription. FlowType observes Escape with a listen-only event tap, so Escape still reaches the frontmost app.
- Local transcription through the universal `whisper.cpp` engine included in FlowType, or hosted transcription through OpenAI or Groq.
- A first-run Model Manager offers recommended Medium English or faster Small English, then installs, verifies, retries, cancels, reinstalls, or removes it without Homebrew or Terminal.
- Local transcription uses a bundled Silero voice-activity model to discard silence and background-only markers before paste.
- Optional cleanup through an OpenAI-compatible language-model endpoint.
- A personal dictionary provides recognition hints and deterministic spelling replacements.
- The transcript remains on the clipboard by default. A config flag can restore the previous clipboard after pasting.
- Retain finalized recordings locally for three days, with **Retry Last Transcription** and an on-demand History window for playback, retry, copy, and individual deletion.
- A non-activating, click-through waveform pill appears only while recording, processing, or showing brief success/error/update feedback; it never remains on screen at idle.
- A native Settings window edits shortcut behavior, microphone routing/testing, quiet-speech boost, audio feedback, music lowering, the five-minute safety limit, clipboard behavior, providers, model choice, and personal dictionary.
- Menu-bar controls for settings, on/off, configuration files, permissions, launch at login, and quit.
- Optional daily GitHub release checks. FlowType shows a non-activating notice and lets the user choose Download, Later, or Skip; it never installs an update silently.

## Start here

- **Installing for yourself or a friend:** [Detailed installation and troubleshooting guide](docs/INSTALL_FOR_FRIENDS.md)
- **Handing installation to a coding agent:** use the agent checklist in that same guide; it identifies the steps that still require the Mac owner's clicks.
- **Understanding the code:** [Architecture and data-flow guide](docs/ARCHITECTURE.md)
- **Publishing a new version:** [Release runbook](docs/RELEASING.md)

FlowType is currently distributed as an unsigned community build. There is no Apple Developer Program membership behind the project. That keeps the project free, but macOS will show an unidentified-developer warning and may ask for privacy permissions again after an upgrade. The documentation never recommends disabling Gatekeeper globally.

## Mental model

FlowType separates the work into stages so each can be changed without rewriting the app:

```text
keyboard event
    ↓
gesture state machine (quick tap / held / hands-free / cancel)
    ↓
    selected/default microphone → private staged capture → retained 16 kHz mono WAV
    ↓
local Silero VAD + whisper.cpp OR OpenAI/Groq transcription
    ↓
optional LLM cleanup → exact dictionary replacements
    ↓
clipboard → simulated Cmd-V at the current cursor
```

The state machine is important. It gives late API responses and `Esc` cancellation an explicit session identity, so a cancelled dictation cannot unexpectedly paste several seconds later.

Finalized audio and versioned metadata live under Application Support for three days. A retry runs that same processing pipeline with the settings that are current when Retry is selected. **Retry Last Transcription** pastes into the previously focused app and keeps the text on the clipboard; retrying from History updates that History entry and exposes Copy without auto-pasting into the History window.

## Install

### Option A: packaged release

Download the DMG and matching `.sha256` file from the [latest FlowType release](https://github.com/jdlinventures/flowtype-macos/releases/latest). Verify the checksum, open the DMG, and drag FlowType onto the Applications shortcut.

Because the app is not notarized, first launch requires the one-time **Open Anyway** flow under **System Settings → Privacy & Security**. Then choose Medium English (recommended, 1.53 GB) or Small English (faster, 488 MB) and select **Install** in FlowType Settings. FlowType verifies the model and keeps it for future app updates. Follow [INSTALL_FOR_FRIENDS.md](docs/INSTALL_FOR_FRIENDS.md) for the exact safe steps, permission setup, and a real dictation test.

### Option B: build from source

macOS 13 or later is required. Apple Silicon and Intel builds are supported. Building from source requires Apple's command-line developer tools and CMake; these are release-development tools and are not required by people installing the DMG.

```bash
./scripts/test-direct.sh
./scripts/build-app.sh
```

The finished app is `dist/FlowType.app`. Move it to `/Applications` before enabling Launch at Login, then open it:

```bash
open /Applications/FlowType.app
```

The Settings window opens on the first launch. After that, open it by clicking FlowType in Applications again or choosing **Settings…** from the waveform icon in the menu bar. FlowType is a background utility, so closing Settings leaves dictation running.

The build is ad-hoc signed for local use. It is not notarized. Do not disable Gatekeeper system-wide; approve only the FlowType build you obtained from this repository.

### Install the offline model

The packaged app already contains its own universal `whisper-cli`; no Homebrew, CMake, or Terminal setup is needed. In FlowType Settings:

1. Choose **Recommended — Medium English** for accuracy or **Fast — Small English** for a smaller download.
2. Select the Install button and leave FlowType open while the download completes.
3. Wait for **installed and verified** before dictating.

Both downloads are pinned to an immutable model revision. FlowType verifies the exact byte size and SHA-256 digest before moving either model into place. A cancelled, truncated, or corrupted download cannot replace a working model.

Models are stored under `~/Library/Application Support/FlowType/models/`, outside the app bundle. Replacing FlowType during an update therefore preserves them and keeps later app downloads small. Advanced users can still select another compatible GGML model or custom `whisper-cli` under **Transcription**.

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

New installs recommend the bundled `whisper.cpp` 1.9.1 engine with `ggml-medium.en.bin` for better accuracy. Medium is 1,533,774,781 bytes; Small English remains available at 487,614,201 bytes for faster transcription and a smaller download. Both run entirely on this Mac and cost **$0 per dictation**; recorded audio does not leave the device.

Retrying with the local provider also costs $0. A retry with OpenAI or Groq sends the retained recording again and creates another billable transcription request. If cloud cleanup is enabled, it creates another cleanup request too.

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

- **Automatic — System Default** re-evaluates the route before every recording. If Bluetooth headphones are the current output and their Bluetooth microphone is also the default input, FlowType uses the built-in Mac microphone by default. This preserves clearer headphone playback and gives speech recognition a stronger signal.
- Choose a named device to use that exact microphone without changing the Mac's global input setting. FlowType warns when an explicitly selected Bluetooth microphone may reduce playback and recognition quality.
- If an explicitly selected device is disconnected, FlowType stops with a clear error instead of silently recording from the wrong microphone.
- **Test for 3 seconds** proves that the selected route is delivering frames and shows the live level before a real dictation.

- **Start/stop sounds** play the same macOS Pop sound when the microphone starts and stops. Retries do not play recording-boundary sounds.
- **Boost quiet speech** applies at most 4× gain after capture. Healthy speech is left unchanged, and near-silent audio is rejected rather than amplified into a hallucination.
- **Lower other audio** is independent from microphone processing. FlowType remembers the current output device and its exact volume, then applies a relative level while listening: Light keeps 65%, Medium keeps 35%, and Strong keeps 15%. It uses macOS's virtual main-volume control so Bluetooth devices map to their real master or stereo-channel volume, and it verifies the written value before reporting success.

FlowType restores the previous output volume after normal stop, `Esc`, disabling dictation, opening Settings, or quitting. Before lowering anything it writes a small recovery record under Application Support; the next launch restores that volume if the prior process crashed. Outputs without a writable macOS volume control, such as some HDMI and USB devices, are skipped without interrupting dictation. If the output device changes mid-recording, FlowType restores the original device by its stable Core Audio UID when that device is available.

The floating recording pill shows the microphone FlowType actually opened and a live input meter. AirPods only appear when connected and exposed as an input device; use **Refresh** after audio hardware changes.

### Transcription provider

Local, fully offline transcription is the default:

```json
{
  "transcription": {
    "provider": "local",
    "localExecutable": "bundled",
    "localModelPath": "~/Library/Application Support/FlowType/models/ggml-medium.en.bin",
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

### Update checks

Allow the app to check GitHub's public latest-release endpoint at most once every 24 hours:

```json
{
  "updates": {
    "checkAutomatically": true
  }
}
```

Turn the setting off to make update checks manual-only. The menu-bar **Check for Updates…** action remains available. An update notice never downloads or installs executable code; Download Update opens the validated HTTPS GitHub release page.

## Product research that informed the scope

- [Wispr Flow](https://docs.wisprflow.ai/articles/2772472373-what-is-flow) validates the hold/release and double-press hands-free gesture, but its current transcription requires an internet connection. FlowType keeps the gesture while making local transcription the default.
- [Superwhisper](https://superwhisper.com/docs/security/sensitive-data) separates voice recognition from optional language-model post-processing and lets each stage be local or cloud. FlowType uses the same clean boundary.
- [VoiceInk](https://tryvoiceink.com/docs/introduction) shows the value of global push-to-talk, personal vocabulary, deterministic replacements, and recovery actions in a local-first tool.
- [MacWhisper](https://docs.macwhisper.com/article/16-global) validates the smaller global overlay plus automatic clipboard workflow.

FlowType intentionally does not copy their account systems, indefinite archives, search/export systems, per-app modes, screen-context reading, or command modes. Its update check is deliberately a small GitHub release notification rather than an executable self-updater.

## Privacy and data lifecycle

- There is no telemetry or account layer.
- Finalized dictations are stored for three days under `~/Library/Application Support/FlowType/recordings/`; expiry is based on the original capture time and a retry does not extend it.
- Recording directories use owner-only `0700` permissions and metadata/audio files use `0600`. Protection relies on the macOS user account and FileVault when enabled; OS, enterprise, or user backup tools may still include Application Support.
- FlowType does not initiate cloud sync for History. Cancelling a new capture deletes it; interrupting finalized processing preserves usable audio for retry.
- Local transcription never sends audio off-device.
- Dictionary and configuration files remain in the user's Application Support directory. Vocabulary terms are included in recognition/cleanup prompts, so those terms are sent to the selected provider when a cloud stage is enabled.
- During active music lowering, a small local recovery file stores the output device identifier and prior volume. It is deleted after successful restoration.
- LLM cleanup sends transcript text only when a cloud cleanup endpoint is enabled.
- OpenAI/Groq transcription sends the audio to the selected provider; their API data terms apply.
- Retrying with OpenAI or Groq sends the retained audio to that provider again, and cloud cleanup sends the transcript again. FlowType names the providers in the **Retry Last Transcription** menu title and asks for confirmation before a paid retry from History; local-only setups see no notice. History metadata never stores API keys or `.env` values.
- If automatic update checks are enabled, FlowType makes an unauthenticated HTTPS request to GitHub's public latest-release endpoint at most once every 24 hours. It sends no FlowType account, transcript, audio, dictionary, or device identifier. GitHub still receives ordinary network metadata such as the request IP address.

## Development and verification

Run the project-owned direct test suite. It compiles every app source file with warnings treated as errors and runs the deterministic state-machine, store, dictionary, and settings tests:

```bash
./scripts/test-direct.sh
```

List microphones or perform a three-second capture-path diagnostic without launching the app:

```bash
./scripts/test-audio-capture.sh list
./scripts/test-audio-capture.sh system_default
```

Build and validate the app bundle:

```bash
./scripts/build-app.sh
plutil -lint dist/FlowType.app/Contents/Info.plist
codesign --verify --deep --strict --verbose=2 dist/FlowType.app
```

`scripts/build-whisper.sh` pins whisper.cpp `v1.9.1` to an exact source commit, builds static Apple silicon and Intel slices, joins them into one executable, and rejects developer-machine/Homebrew library links. `build-app.sh` includes that generated engine and the third-party license notices in the app.

Build a universal Intel + Apple Silicon DMG and its SHA-256 checksum:

```bash
./scripts/package-release.sh
```

This packages `FlowType.app`, an Applications shortcut, the friend-install guide, and all license notices. The model itself is intentionally not in the DMG. Packaging does not publish, commit, push, change repository visibility, or weaken macOS security.

A standard `Package.swift` and XCTest suite are also included for development in Xcode. Two toolchain facts matter for `swift test`:

- Apple's Command Line Tools do not ship XCTest, so the XCTest target compiles only with a full Xcode installation.
- On the original development Mac the Command Line Tools were half-updated: `PackageDescription.swiftmodule` (the interface the compiler reads) was newer than `libPackageDescription.dylib` (the library the linker binds), so every manifest failed to link regardless of its contents. `swift package describe` reproduces it. The fix is to reinstall the Command Line Tools (`sudo rm -rf /Library/Developer/CommandLineTools && xcode-select --install`) or install Xcode; no `Package.swift` change helps.

The direct test script uses Apple's compiler and frameworks without SwiftPM and remains the authoritative test path. Release builds additionally use CMake to compile the pinned bundled engine.

## Current boundaries

- Transcription starts after release; there is no partial streaming transcript yet.
- The engine and small VAD model are included, but the selected 488 MB or 1.53 GB speech model is a user-initiated first-run download. The first local dictation cannot work until it finishes.
- Settings covers normal configuration; the cleanup prompt and fine-grained timing values remain advanced `config.json` options.
- The community build is ad-hoc signed rather than Developer ID signed or notarized. Gatekeeper approval and occasional privacy-permission refreshes are an unavoidable distribution limitation.
- Update checks notify and open the selected GitHub release page; the user replaces the app manually. There is intentionally no silent executable self-updater.
- Recording History is deliberately a three-day recovery list with no search, export, bulk actions, account sync, or indefinite retention.
- Device-level verification still requires a real microphone, macOS privacy grants, a focused third-party text field, and either a local model or provider key.

## License

FlowType is released under the permissive [MIT License](LICENSE). You may use, copy, modify, merge, publish, distribute, sublicense, or sell copies subject to the license notice and warranty disclaimer. Bundled local-transcription components and their exact versions are documented in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

</details>
