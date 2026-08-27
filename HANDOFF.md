# FlowType Handoff

Last verified: 2026-08-27 (Asia/Bangkok)

## Current state

FlowType is complete for the current personal-use scope. Version **0.5.0** (build **10**) is installed at `/Applications/FlowType.app`, running, and reporting `Ready`. The private repository is `jdlinventures/flowtype-macos`; `main` tracks `origin/main`.

Implementation baseline before this handoff-only commit: `e83218fb677ba61c64f53895c7e988814b8ff604` (`Add crash-safe music lowering`).

The installed app and freshly built `dist/FlowType.app` executable both had SHA-256:

```text
a3c46d6e58bcf6447e15877f6c339786a0faf42654cb45be4941aba64a821123
```

## Verified product behavior

- Right Option is the hybrid shortcut: quick tap starts/stops hands-free recording; hold/release is push to talk.
- Escape cancels recording or in-flight processing without swallowing Escape in the focused app.
- Normal microphone capture is the reliable default. The current input preference is the macOS system default.
- Local transcription uses `whisper.cpp` 1.9.1 and `ggml-small.en.bin` (487,614,201 bytes).
- The result is copied to the clipboard and pasted with Cmd-V. Clipboard restoration is off, so the transcript remains available to paste again.
- Music lowering is enabled at Medium. It independently reduces writable system output volume to 35% of the prior level and restores the exact prior level after stop, Escape, disabling dictation, opening Settings, quit, or next-launch crash recovery.
- Voice processing/AGC is experimental and currently disabled.
- Hands-free recording auto-stops after 300 seconds.

The release-session manual QA used the physical Right Option key and confirmed recording, local transcription, clipboard insertion, and automatic paste. The volume trace showed `1.0 → 0.35 → 1.0`; the recovery file existed only while recording and was removed after restoration.

## Architecture orientation

The app is native Swift/AppKit with no third-party Swift dependencies.

```text
main.swift
  → AppDelegate: app/menu/settings lifecycle
  → AppCoordinator: owns the dictation session
      → GlobalEventMonitor + GestureStateMachine
      → AudioRecorder → AudioConverterService
      → TranscriptionService (local, OpenAI, or Groq)
      → CleanupService → PersonalDictionary
      → TextInsertionService (pasteboard + Cmd-V)
      → OutputVolumeDucker (independent music lowering + recovery)
```

Important boundaries:

- `GlobalEventMonitor` passes the original `CGEvent` timestamp into `GestureStateMachine`. Do not replace it with delayed main-thread time; microphone startup can otherwise misclassify a quick tap as a hold.
- `AudioRecorder` rejects unsafe multichannel voice-processing streams and falls back to normal capture. `AudioSignalQuality` stops near-digital silence before Whisper can hallucinate text.
- `OutputVolumeDucker` is deliberately separate from microphone processing. It writes `output-volume-recovery.json` before lowering anything and restores by stable Core Audio device UID.
- `ConfigStore` merges saved configuration over `AppConfig.defaultConfig`, so newly added fields remain backward compatible with older user config files.

## Validation evidence

Fresh checks run before this handoff:

```bash
./scripts/test-direct.sh
./scripts/build-app.sh
codesign --verify --deep --strict --verbose=2 dist/FlowType.app
plutil -lint dist/FlowType.app/Contents/Info.plist
codesign --verify --deep --strict --verbose=2 /Applications/FlowType.app
```

Results:

- 41 direct tests passed.
- Release app build succeeded.
- Candidate and installed app signatures were valid.
- Candidate `Info.plist` passed validation.
- Installed and candidate executable hashes matched.
- Final MacBook Pro Speakers volume was `1.0`.
- `output-volume-recovery.json` was absent, confirming no unfinished ducking session.

Use `./scripts/test-direct.sh` as the verified test path in this environment.

## Local paths and data

User-controlled files are outside Git:

```text
~/Library/Application Support/FlowType/config.json
~/Library/Application Support/FlowType/dictionary.txt
~/Library/Application Support/FlowType/.env
~/Library/Application Support/FlowType/models/ggml-small.en.bin
```

Temporary recordings are created under the macOS temporary directory and removed after success, failure, or cancellation. `.env`, `.build/`, and `dist/` are ignored by Git.

## macOS permission caveat

Development builds are ad-hoc signed. Replacing the installed app can leave a stale Input Monitoring binding even when FlowType's preflight UI reports `allowed`. The observed symptom is that physical Right Option events appear in a separate event trace while FlowType stays `Ready`.

After installing a newly rebuilt development app:

1. Open System Settings → Privacy & Security → Input Monitoring.
2. Toggle FlowType off and back on.
3. Quit and reopen FlowType.
4. Confirm the physical Right Option key starts recording before diagnosing hotkey code.
5. Re-check Microphone and Accessibility if recording or paste still fails.

A publicly distributed build should use a stable Apple Developer ID signature and notarization so routine upgrades do not churn these grants.

## Known limitations

- Experimental voice processing remains off because the tested macOS path exposed 7/9-channel near-silent audio. Do not reconnect music lowering to this path.
- Output devices without writable Core Audio master volume, including some HDMI/USB devices, safely skip music lowering.
- Local `small.en` prioritizes speed and privacy over maximum accuracy. A medium model is supported by configuration but uses more memory and time.
- There is no automatic updater, transcript history, account system, or telemetry.
- The app is ad-hoc signed and not notarized; it is ready for personal use, not public distribution.

## Rollback

The immediately previous installed app is recoverable from:

```text
~/.Trash/FlowType-0.4.4-before-0.5.0.app
```

Earlier development backups also remain in Trash. Do not delete them without explicit approval.

## Next recommended work

No work is required for current daily use. Start any future change with a fresh orientation pass: read this handoff and `README.md`, inspect Git and installed-app state, then reproduce the current physical Right Option workflow before editing.

If the product moves beyond personal use, the next coherent project is release engineering: Apple Developer ID signing, notarization, a stable installer/update path, and permission-upgrade QA. Treat that as a separate architecture and distribution decision.
