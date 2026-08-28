# FlowType Handoff

Last verified: 2026-08-28 (Asia/Bangkok)

## Current state

FlowType **0.7.0** (build **12**) is a verified universal release candidate in `dist/`. The currently installed daily-use app remains **0.5.0** (build **10**) at `/Applications/FlowType.app` and was still running as PID 1408 at the final check; this work deliberately did not replace it or churn its working privacy grants.

The GitHub repository is still private, `main` tracks `origin/main`, and there are no published releases. This handoff describes the complete local 0.7.0 implementation snapshot, including the prior 0.6.0 release-engineering work. No repository visibility change, push, tag, draft release, or public release action has been taken.

The universal release candidate contains both architectures:

```text
x86_64 arm64
```

The packaged candidate is `dist/FlowType-0.7.0-macos-universal.dmg` (5,853,268 bytes) with a matching portable `.sha256` file. Its SHA-256 is `f3856aa3e2b5327ebe651f900fb239db3685c622450af7db00d953cd895f8dcf`. Generated `dist/` artifacts remain ignored by Git.

## Verified product behavior

- Right Option is the hybrid shortcut: quick tap starts/stops hands-free recording; hold/release is push to talk.
- Escape cancels recording or in-flight processing without swallowing Escape in the focused app.
- Normal microphone capture is the reliable default. The current input preference is the macOS system default.
- Local transcription now prefers the universal `whisper.cpp` 1.9.1 engine included inside FlowType. It falls back to a custom path or legacy Homebrew path only for backward compatibility.
- General Settings has a first-run Model Manager with Install, progress, Cancel, Retry, Reinstall, and confirmed Remove controls for `ggml-small.en.bin` (487,614,201 bytes).
- The model URL is pinned to an immutable Hugging Face revision. FlowType validates the exact size and SHA-256 `c6138d6d58ecc8322097e0f987c32f1be8bb0a18532a3f88f734d1bbf9c41e5d`, and only then atomically replaces the final file.
- The model stays under Application Support instead of the app. Friends do not need Homebrew, CMake, Terminal, an API key, or an account to use packaged local transcription; app updates preserve the model.
- The result is copied to the clipboard and pasted with Cmd-V. Clipboard restoration is off, so the transcript remains available to paste again.
- Music lowering is enabled at Medium. It independently reduces writable system output volume to 35% of the prior level and restores the exact prior level after stop, Escape, disabling dictation, opening Settings, quit, or next-launch crash recovery.
- Voice processing/AGC is experimental and currently disabled.
- Hands-free recording auto-stops after 300 seconds.
- Automatic release checks are enabled by default and can be disabled in General Settings. The app checks GitHub at most once every 24 hours, shows a non-activating update pill, and offers Download, Later, or Skip. Download only opens the HTTPS GitHub release page; FlowType never installs an executable update silently.

The prior 0.5.0 release-session manual QA used the physical Right Option key and confirmed recording, local transcription, clipboard insertion, and automatic paste. The volume trace showed `1.0 → 0.35 → 1.0`; the recovery file existed only while recording and was removed after restoration. The 0.7.0 candidate has compile/package/model-transcription verification but has not replaced the working installed app, so its new Settings controls still need normal fresh-install visual/manual QA before publication.

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

AppDelegate
  → LocalModelManager
      → pinned HTTPS download → size + streaming SHA-256 → atomic model install
  → ReleaseUpdateChecker
      → public GitHub latest-release API
      → validated github.com release page
      → non-activating pill + user-controlled menu prompt
```

Important boundaries:

- `GlobalEventMonitor` passes the original `CGEvent` timestamp into `GestureStateMachine`. Do not replace it with delayed main-thread time; microphone startup can otherwise misclassify a quick tap as a hold.
- `AudioRecorder` rejects unsafe multichannel voice-processing streams and falls back to normal capture. `AudioSignalQuality` stops near-digital silence before Whisper can hallucinate text.
- `OutputVolumeDucker` is deliberately separate from microphone processing. It writes `output-volume-recovery.json` before lowering anything and restores by stable Core Audio device UID.
- `ConfigStore` merges saved configuration over `AppConfig.defaultConfig`, so newly added fields remain backward compatible with older user config files.
- `LocalModelManager` writes only inside `~/Library/Application Support/FlowType/models/`. A download remains a staging file until verification succeeds, so a corrupt/cancelled replacement cannot damage the current model.
- `TranscriptionService` checks an explicit custom executable first, then the bundled engine, then legacy Homebrew paths. New configs use `localExecutable: "bundled"`.
- Update checking is intentionally outside `AppCoordinator`; it cannot mutate an active microphone/dictation session. `UpdateChecker.swift` contains the testable network/version logic, while `AppDelegate` owns the user-facing choice.

## Validation evidence

Fresh checks run before this handoff:

```bash
./scripts/test-direct.sh
FLOWTYPE_ARCHS=universal ./scripts/build-app.sh
./scripts/package-release.sh
codesign --verify --deep --strict --verbose=2 dist/FlowType.app
plutil -lint dist/FlowType.app/Contents/Info.plist
(cd dist && shasum -a 256 -c FlowType-0.7.0-macos-universal.dmg.sha256)
```

Results:

- 56 direct checks passed. New coverage pins the model metadata, accepts the correct checksum, rejects a corrupt checksum, proves a bad staging file cannot replace a working model, and proves a verified file can replace it atomically.
- Native and universal app builds succeeded with warnings treated as errors.
- The pinned whisper.cpp build produced a 6.6 MB static universal `whisper-cli`. `otool -L` showed only `/System/Library` frameworks and `/usr/lib` libraries—no Homebrew, `/usr/local`, or `@rpath` dependency.
- The candidate app's ad-hoc signature was valid.
- Candidate `Info.plist` passed validation.
- The DMG checksum passed.
- A read-only mounted DMG contained `FlowType.app`, the Applications shortcut, `READ ME FIRST.md`, `LICENSE.txt`, `THIRD PARTY NOTICES.md`, and four upstream license texts. The same notices are inside the app bundle.
- The mounted app contained valid `x86_64` and `arm64` slices and passed deep strict code-signature verification.
- No `ggml-*.bin` model was present in the mounted app. The packaged engine successfully loaded the existing verified Application Support model and transcribed the bundled JFK sample to: “And so, my fellow Americans, ask not what your country can do for you. Ask what you can do for your country.”
- The mounted volume was ejected after verification.
- The release candidate was not installed, so the already-working 0.5.0 hotkey/microphone/paste setup was not disturbed.

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

The project owner does not plan to purchase Apple Developer Program membership. Community releases therefore remain ad-hoc signed and not notarized. Friend installations must use the documented per-app Open Anyway flow; routine replacements may still require refreshing Input Monitoring or Accessibility.

## Known limitations

- Experimental voice processing remains off because the tested macOS path exposed 7/9-channel near-silent audio. Do not reconnect music lowering to this path.
- Output devices without writable Core Audio master volume, including some HDMI/USB devices, safely skip music lowering.
- Local `small.en` prioritizes speed and privacy over maximum accuracy. A medium model is supported by configuration but uses more memory and time.
- A new packaged install needs one user-initiated ~488 MB network download before local transcription works. After verification, local transcription is offline and costs $0 per dictation.
- There is no executable self-updater, transcript history, account system, or FlowType telemetry. Update checking is notification-only and contacts GitHub when enabled.
- The app is ad-hoc signed and not notarized. Gatekeeper friction cannot legitimately be removed without Developer ID membership.
- The latest-release check returns unavailable while the repository is private or has no published release. This is handled silently for automatic checks and explained for manual checks.
- Universal structure is verified on Apple Silicon; actual Intel runtime behavior remains untested without an Intel Mac.
- The repository has an MIT License with `Copyright (c) 2026 jdlinventures`. FlowType, whisper.cpp, OpenAI Whisper, miniaudio, and stb_vorbis notices are copied into the app bundle and DMG.

## Rollback

The immediately previous installed app is recoverable from:

```text
~/.Trash/FlowType-0.4.4-before-0.5.0.app
```

Earlier development backups also remain in Trash. Do not delete them without explicit approval.

## Next recommended work

Current daily use needs no installed-app change. The next release steps are intentionally separate:

1. Review the local 0.7.0 implementation commit and its validation evidence.
2. Audit reachable Git history for secrets/private material.
3. Explicitly approve pushing `main` to `origin/main`.
4. Explicitly approve changing repository visibility to public.
5. Create and inspect a GitHub draft release using `docs/RELEASING.md`.
6. Explicitly approve publishing the release.
7. Test the public latest-release endpoint and upgrade flow from an older installed build.
8. Have the friend follow `docs/INSTALL_FOR_FRIENDS.md` and report real hotkey/paste evidence.
