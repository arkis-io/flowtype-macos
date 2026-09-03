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
  │                               transient recording / processing feedback
  ├─► AudioDeviceService
  ├─► AudioRecorder
  ├─► OutputVolumeDucker
  ├─► RecordingHistoryStore
  │       │ private staged CAF → versioned three-day entry
  │       ▼
  └─► AudioConverterService
          │ retained 16 kHz mono WAV
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
  → atomic move to models/ggml-medium.en.bin or ggml-small.en.bin
```

The final filename is never replaced before verification. App replacement and model replacement are therefore independent operations.

## Application lifecycle

`main.swift` creates `NSApplication`, attaches `AppDelegate`, and runs the event loop.

`AppDelegate` owns application-level concerns:

- accessory/menu-bar lifecycle;
- Settings window;
- Recording History window, Retry Last action, and retention timer;
- Launch at Login;
- top-level permission actions;
- update checks and update prompts.

`LocalModelManager` owns only model download/storage state. It has no access to the microphone, hotkeys, transcript, clipboard, `.env`, or update installation.

`AppCoordinator` owns one capture or processing attempt at a time. Keeping release checks out of the coordinator prevents network/update work from changing microphone or hotkey state. `RecordingHistoryWindowController` reads lightweight metadata on demand and creates an `AVAudioPlayer` only for the selected recording.

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

Every processing run has both an attempt UUID and a retained-entry UUID. Completion code checks both before changing metadata, UI, clipboard, or paste state. The context also records whether work came from a new capture, Retry Last, or History, and whether delivery is paste or History-only. Escape:

1. resets the gesture state;
2. stops or discards a new recording;
3. restores output volume;
4. cancels the async processing task;
5. invalidates the active UUID;
6. hides the recording pill.

This prevents an old API response or local process completion from pasting text after the user cancelled. Escape deletes a cancelled new capture/initial attempt, but a cancelled retry keeps the older audio and transcript. Disabling dictation, opening Settings, or quitting deletes an unfinished capture and marks already-finalized work interrupted so it can be retried.

## Audio capture and conversion

`AudioDeviceService` enumerates macOS input devices and records their Core Audio transport type. Automatic mode normally follows the system default. When Bluetooth headphones are the output and their Bluetooth microphone is also the default input, the policy chooses the built-in microphone instead. Explicit device selections are always respected.

`AudioRecorder` uses `AVCaptureSession` with an explicit `AVCaptureDeviceInput` and `AVCaptureAudioFileOutput`. This avoids the previous failure mode where retargeting an initialized `AVAudioEngine` audio unit appeared successful but delivered empty or malformed frames. Dictation capture receives a pre-created private staging directory; the Settings microphone test still receives a disposable temporary directory. Stopping is asynchronous so file finalization completes before promotion and conversion.

`AudioSignalQuality` rejects near-digital silence before Whisper runs. This reduces hallucinated phrases such as “You” from effectively empty recordings.

`AudioConverterService` uses macOS `afconvert` to create the mono 16 kHz WAV expected by Whisper and cloud speech endpoints. Optional quiet-speech normalization is capped at 4× and never boosts an already healthy signal.

The recording pill and Settings microphone test poll `AVCaptureAudioChannel.averagePowerLevel`. The meter is diagnostic: the final file is still inspected independently before transcription.

## Music lowering

`OutputVolumeDucker` is independent from microphone processing. It:

1. identifies the current output by stable Core Audio UID;
2. persists its exact volume before changing anything;
3. applies the configured relative level;
4. restores the exact prior volume after stop, cancellation, Settings, quit, or next-launch crash recovery.

Unsupported HDMI/USB volume controls are skipped rather than failing dictation. Keep music lowering independent from capture routing and quiet-speech normalization.

## Transcription and cleanup

`TranscriptionService` selects one of three providers:

- `local` — prefers a configured custom executable, then FlowType's bundled universal `whisper-cli`, then legacy Homebrew paths; audio stays on the Mac;
- `openai` — sends the WAV to the configured OpenAI transcription endpoint;
- `groq` — sends the WAV to Groq.

The bundled local path runs Silero VAD before Whisper. It removes non-speech segments, while `TranscriptQuality` separately rejects output made only of markers such as silence, unintelligible audio, laughter, or background music. Dictionary prompt echoes are also rejected.

`CleanupService` is a separate optional OpenAI-compatible chat-completions call. It sees transcript text, not audio. If cleanup fails and `fallbackToRawOnError` is enabled, FlowType inserts the raw transcript.

`PersonalDictionary` has two roles:

- bare lines become recognition/cleanup vocabulary hints;
- `heard phrase => Desired Spelling` rules run as deterministic whole-phrase replacements after cleanup.

The local Whisper `*.transcript.txt` output is a scoped process artifact and is removed after success, failure, or cancellation. Transcript persistence belongs only to versioned History metadata.

## Recording history and retry

`RecordingHistoryStore` is Foundation-only and uses no database. Each entry is a UUID directory containing `metadata.json` plus at most one retained `recording.caf` or canonical `recording.wav`. Metadata schema version 1 records the original capture time, duration, status/stage, immutable first and mutable latest error, raw/final transcript, original/latest provider, attempts, and audio availability.

Capture begins under `recordings/.staging/`. A readable nonempty finalized file is promoted atomically into the visible UUID directory before conversion/transcription starts. Successful conversion canonicalizes the exact returned audio as `recording.wav` and removes intermediates. A provider failure therefore retains a verified WAV; a conversion failure may retain its readable CAF. Missing, empty, near-silent, malformed, symlinked, expired, or deleted audio is never offered for retry.

Entries expire exactly three days after `createdAt`; retry does not change that clock. App launch, store reads/writes, and a one-shot next-expiry timer prune inactive entries. Launch reconciliation promotes valid stale staging as failed/interrupted, removes incomplete staging, and marks stale visible processing entries interrupted.

Retry Last selects the newest eligible entry, snapshots current provider/model/cleanup/dictionary/environment settings, runs the shared pipeline, pastes to the prior app, and keeps the result on the clipboard. History retry uses the same current settings and updates the same UUID, but deliberately never synthesizes paste because History activates FlowType. History offers selected-file playback, Copy, Retranscribe, and one-entry confirmed Delete.

`RetryCostNotice` is a pure summary of which paid providers a retry would contact again (cloud transcription re-sends the retained audio; enabled cloud cleanup re-sends the transcript). `AppDelegate` shows it in the Retry Last menu title and tooltip rather than a dialog, because a modal would activate FlowType and steal focus from the paste target. The History retry path already activates FlowType, so it asks for confirmation before a paid retry. Local-only configurations produce no notice.

## Clipboard insertion

`TextInsertionService` writes the final text to `NSPasteboard` and synthesizes Cmd-V through Accessibility APIs. Clipboard restoration is optional because restoring too quickly can race a slow target app. The default keeps the transcript on the clipboard as a recovery path, and Retry Last always keeps its recovered transcript on the clipboard. History retry does not call this service.

## Configuration and secrets

`ConfigStore` stores user-controlled files outside the app bundle:

```text
~/Library/Application Support/FlowType/config.json
~/Library/Application Support/FlowType/dictionary.txt
~/Library/Application Support/FlowType/.env
~/Library/Application Support/FlowType/models/
~/Library/Application Support/FlowType/output-volume-recovery.json
~/Library/Application Support/FlowType/recordings/
```

Saved JSON is merged over `AppConfig.defaultConfig` before decoding. New fields therefore inherit defaults for existing users. Provider secrets belong only in `.env`, never in `config.json` or source control.

The recordings tree uses `0700` directories and `0600` metadata/audio files. FlowType stores no provider keys or arbitrary paths in History metadata and initiates no History sync. Account/FileVault protections apply when enabled, but system backup tools may still copy Application Support.

Downloaded speech models are outside the app bundle by design. An app update leaves the 488 MB Small or 1.53 GB Medium model untouched. The bundled engine and 885 KB VAD model are updated with the app; the selected Whisper model changes only through an explicit Model Manager action.

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
| Three-day History | No app-managed network request | Audio, metadata, and transcript under Application Support |
| Local cleanup endpoint | No, when bound locally | Transcript text |
| OpenAI/Groq transcription | Yes | Recorded WAV |
| Cloud cleanup | Yes | Transcript text and vocabulary hints |
| Update check | Yes, to GitHub | Ordinary HTTPS request and app version in User-Agent |
| Telemetry/account system | Not present | Nothing collected by FlowType |

GitHub and selected cloud providers have their own network logs and terms. “No FlowType telemetry” does not mean third-party network services receive no metadata.

## Build and packaging

`scripts/test-direct.sh` compiles every file in `Sources/FlowType/` except the `@main` entry point together with `Tests/ManualTests/main.swift`, with warnings treated as errors and the same framework list as the app build, then runs the resulting binary. A new source file is therefore covered automatically; the suite fails to build if any file fails to compile under test.

It deliberately does not use SwiftPM. Apple's Command Line Tools ship Swift Testing but not XCTest, so the XCTest target in `Package.swift` needs a full Xcode installation. Separately, the original development Mac had a half-updated Command Line Tools install whose `PackageDescription` interface and library disagreed, which made every manifest fail at link time; reinstalling the Command Line Tools is the fix, not editing `Package.swift`.

`scripts/build-app.sh` accepts:

```text
FLOWTYPE_ARCHS=native      current Mac only; default
FLOWTYPE_ARCHS=universal   arm64 + x86_64
FLOWTYPE_ARCHS=arm64       Apple Silicon only
FLOWTYPE_ARCHS=x86_64      Intel only
```

It compiles with warnings treated as errors, copies `Info.plist`, the icon, the generated Whisper engine, the pinned Silero VAD model, and license notices, signs the nested engine, then applies an ad-hoc signature to the app.

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
| `RecordingHistoryStore.swift` | staged capture, metadata, retry eligibility, reconciliation, and retention |
| `RecordingHistoryWindowController.swift` | on-demand History, playback, copy, retry, and delete UI |
| `RetryCostNotice.swift` | which paid providers a retry would contact again |
| `TranscriptQuality.swift` | detection of silence-only or non-speech transcripts |
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
