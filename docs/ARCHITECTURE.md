# FlowType architecture

This document explains how FlowType is structured, why the boundaries exist, and where to make common changes safely.

## Goals

FlowType is a system-wide macOS dictation utility with these priorities:

1. Local-first and usable without an account.
2. Explicit recording state and a five-minute safety ceiling.
3. Cancellation that prevents late transcription results from pasting.
4. User-controlled hotkeys, microphone choice, clipboard behavior, and vocabulary.
5. Small, understandable native code with no required third-party Swift dependency.
6. Honest unsigned open-source distribution rather than pretending to be a notarized commercial app.

## High-level data flow

```text
GlobalEventMonitor
  │ physical hotkey / Escape + original event timestamp
  ▼
GestureStateMachine
  │ start / stop / cancel / show-mode actions
  ▼
AppCoordinator ───────────────► PillWindowController
  │                               recording / processing feedback
  ├─► AudioDeviceService
  ├─► AudioRecorder
  ├─► OutputVolumeDucker
  └─► AudioConverterService
          │ temporary 16 kHz mono WAV
          ▼
     TranscriptionService
          │ raw transcript
          ▼
       CleanupService
          │ cleaned transcript
          ▼
     PersonalDictionary
          │ exact replacements
          ▼
    TextInsertionService
          │ pasteboard + Cmd-V
          ▼
     previously focused app
```

Update checks are deliberately separate from dictation:

```text
AppDelegate
  │ optional, at most once per 24 hours
  ▼
ReleaseUpdateChecker
  │ unauthenticated HTTPS GET
  ▼
GitHub public latest-release API
  │ version, title, notes, github.com release URL
  ▼
non-activating pill + menu item
  │ user chooses Download / Later / Skip
  ▼
default browser opens GitHub release page
```

FlowType never downloads or installs an executable update inside the app.

Local-model installation is a separate, user-initiated path:

```text
Settings → Install Offline Model
  → pinned HTTPS model URL
  → temporary file in Application Support
  → exact byte-count check
  → streaming SHA-256 verification
  → atomic move to models/ggml-small.en.bin
```

The final filename is never replaced before verification. App replacement and model replacement are therefore independent operations.

## Application lifecycle

`main.swift` creates `NSApplication`, attaches `AppDelegate`, and runs the event loop.

`AppDelegate` owns application-level concerns:

- accessory/menu-bar lifecycle;
- Settings window;
- Launch at Login;
- top-level permission actions;
- update checks and update prompts.

`LocalModelManager` owns only model download/storage state. It has no access to the microphone, hotkeys, transcript, clipboard, `.env`, or update installation.

`AppCoordinator` owns one dictation session at a time. Keeping release checks out of the coordinator prevents network/update work from changing microphone or hotkey state.

## Gesture state machine

`GestureStateMachine` converts physical events into explicit actions. In the default hybrid mode:

- key down starts recording immediately;
- a quick release changes the visible state to hands-free without restarting audio;
- a later tap stops and processes;
- holding and releasing behaves as push to talk;
- Escape cancels the current phase;
- the hands-free timer stops after at most 300 seconds.

The event monitor passes the original `CGEvent` timestamp into the state machine. Do not replace that timestamp with delayed main-thread time. Microphone startup can delay the main thread enough to misclassify a quick tap as a hold.

## Session identity and cancellation

Every processing run receives a UUID. Completion code checks that UUID before inserting text. Escape:

1. resets the gesture state;
2. stops or discards recording;
3. restores output volume;
4. cancels the async processing task;
5. invalidates the active UUID;
6. hides the recording pill.

This prevents an old API response or local process completion from pasting text after the user cancelled.

## Audio capture and conversion

`AudioDeviceService` enumerates macOS input devices and resolves the configured preference. `system_default` is the safest setting because it follows AirPods and other changes made in Control Center.

`AudioRecorder` captures native microphone audio. Experimental Apple voice processing is optional. If a device exposes an unsafe multichannel voice-processing stream, recording falls back to ordinary capture.

`AudioSignalQuality` rejects near-digital silence before Whisper runs. This reduces hallucinated phrases such as “You” from effectively empty recordings.

`AudioConverterService` uses macOS `afconvert` to create the mono 16 kHz WAV expected by Whisper and cloud speech endpoints.

## Music lowering

`OutputVolumeDucker` is independent from microphone processing. It:

1. identifies the current output by stable Core Audio UID;
2. persists its exact volume before changing anything;
3. applies the configured relative level;
4. restores the exact prior volume after stop, cancellation, Settings, quit, or next-launch crash recovery.

Unsupported HDMI/USB volume controls are skipped rather than failing dictation. Do not reconnect music lowering to the experimental voice-processing path.

## Transcription and cleanup

`TranscriptionService` selects one of three providers:

- `local` — prefers a configured custom executable, then FlowType's bundled universal `whisper-cli`, then legacy Homebrew paths; audio stays on the Mac;
- `openai` — sends the WAV to the configured OpenAI transcription endpoint;
- `groq` — sends the WAV to Groq.

`CleanupService` is a separate optional OpenAI-compatible chat-completions call. It sees transcript text, not audio. If cleanup fails and `fallbackToRawOnError` is enabled, FlowType inserts the raw transcript.

`PersonalDictionary` has two roles:

- bare lines become recognition/cleanup vocabulary hints;
- `heard phrase => Desired Spelling` rules run as deterministic whole-phrase replacements after cleanup.

## Clipboard insertion

`TextInsertionService` writes the final text to `NSPasteboard` and synthesizes Cmd-V through Accessibility APIs. Clipboard restoration is optional because restoring too quickly can race a slow target app. The default keeps the transcript on the clipboard as a recovery path.

## Configuration and secrets

`ConfigStore` stores user-controlled files outside the app bundle:

```text
~/Library/Application Support/FlowType/config.json
~/Library/Application Support/FlowType/dictionary.txt
~/Library/Application Support/FlowType/.env
~/Library/Application Support/FlowType/models/
~/Library/Application Support/FlowType/output-volume-recovery.json
```

Saved JSON is merged over `AppConfig.defaultConfig` before decoding. New fields therefore inherit defaults for existing users. Provider secrets belong only in `.env`, never in `config.json` or source control.

Temporary recordings use the macOS temporary directory and are removed after success, failure, or cancellation.

The downloaded model is outside the app bundle by design. A ~10 MB app update leaves the ~488 MB model untouched. The bundled engine is executable code and is updated with the app; the model is data and is updated only through an explicit Model Manager action.

## Update design

`ReleaseUpdateChecker` reads the endpoint from `FlowTypeReleaseAPIURL` in `Info.plist`. It:

- requests GitHub's latest non-draft, non-prerelease release;
- uses GitHub's public REST API without a token;
- validates the response and accepts only an HTTPS `github.com` release page;
- parses numeric tags such as `v0.7.0`;
- compares numeric version components rather than strings;
- treats a 404 as an unavailable public feed;
- checks automatically only when enabled and 24 hours have passed.

`AppDelegate` stores the last-check date and skipped version in `UserDefaults`. Automatic discovery shows a non-activating pill and changes the menu item. A modal choice appears only after the user invokes the update menu or manually checks.

Why not Sparkle? FlowType has no Developer ID certificate. Sparkle is excellent for signed/notarized distribution, but its own documentation warns that some ad-hoc-signing configurations can prevent macOS from loading the framework. A notification-only checker is smaller, easier to audit, and honest about the required manual replacement.

## Privacy boundaries

| Feature | Leaves the Mac? | Contents |
| --- | --- | --- |
| Local Whisper | No | Audio stays local |
| Local cleanup endpoint | No, when bound locally | Transcript text |
| OpenAI/Groq transcription | Yes | Recorded WAV |
| Cloud cleanup | Yes | Transcript text and vocabulary hints |
| Update check | Yes, to GitHub | Ordinary HTTPS request and app version in User-Agent |
| Telemetry/account system | Not present | Nothing collected by FlowType |

GitHub and selected cloud providers have their own network logs and terms. “No FlowType telemetry” does not mean third-party network services receive no metadata.

## Build and packaging

`scripts/test-direct.sh` compiles and runs deterministic tests without relying on the local SwiftPM installation.

`scripts/build-app.sh` accepts:

```text
FLOWTYPE_ARCHS=native      current Mac only; default
FLOWTYPE_ARCHS=universal   arm64 + x86_64
FLOWTYPE_ARCHS=arm64       Apple Silicon only
FLOWTYPE_ARCHS=x86_64      Intel only
```

It compiles with warnings treated as errors, copies `Info.plist`, the icon, the generated Whisper engine, and license notices, signs the nested engine, then applies an ad-hoc signature to the app.

`scripts/build-whisper.sh` uses CMake to build whisper.cpp `v1.9.1` from the exact commit recorded in the script. It disables shared libraries and host-specific CPU tuning, builds Apple silicon and Intel slices, merges them, and rejects `@rpath`, Homebrew, or `/usr/local` dependencies. CMake is required only on the release-development Mac.

`scripts/package-release.sh` runs tests, builds universal by default, validates the app, and creates:

```text
dist/FlowType-VERSION-macos-universal.dmg
dist/FlowType-VERSION-macos-universal.dmg.sha256
```

The DMG includes FlowType, an Applications shortcut, the friend-install guide, and FlowType/third-party notices. It intentionally excludes the model. Packaging does not publish or change GitHub state.

The root MIT `LICENSE` is copied into both the app bundle and DMG. `THIRD_PARTY_NOTICES.md` and the upstream whisper.cpp/OpenAI Whisper MIT texts are included beside it so binary distributions retain all notices.

## Source map

| File | Responsibility |
| --- | --- |
| `AppDelegate.swift` | app/menu/settings/update lifecycle |
| `AppCoordinator.swift` | active dictation session orchestration |
| `GlobalEventMonitor.swift` | listen-only global keyboard events |
| `GestureStateMachine.swift` | deterministic shortcut modes and cancellation |
| `AudioRecorder.swift` | microphone capture and WAV preparation |
| `AudioDeviceService.swift` | microphone discovery/preference |
| `OutputVolumeDucker.swift` | music lowering and crash recovery |
| `TranscriptionService.swift` | local/OpenAI/Groq speech recognition |
| `LocalModelManager.swift` | pinned model download, progress, verification, atomic install, and removal |
| `CleanupService.swift` | optional transcript cleanup |
| `PersonalDictionary.swift` | hints and exact replacements |
| `TextInsertionService.swift` | clipboard and Cmd-V |
| `SettingsWindowController.swift` | native settings interface |
| `UpdateChecker.swift` | public GitHub release query/version logic |

## Change-safety rules

- Keep Escape passive so it still reaches the focused app.
- Keep session-ID checks around async completions.
- Keep output-volume recovery persistent and independent.
- Never log or surface `.env` values.
- Preserve old JSON configs by adding defaults before reading new fields.
- Test physical global shortcuts and cross-app paste before claiming end-to-end success.
- Treat Developer ID signing, notarization, or an executable self-updater as a new distribution/security decision.
