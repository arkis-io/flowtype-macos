# FlowType Handoff

Last verified: 2026-09-04 (Asia/Bangkok)

## Current state

Post-0.8 hardening is merged to `main` and pushed to `origin/main`. On top of `adb12a0`:

1. `test: compile every source file into the direct test suite` — `scripts/test-direct.sh` now globs `Sources/FlowType/*.swift` (minus the `@main` entry point) with `-warnings-as-errors` and the app's framework list, so `AppCoordinator`, `AppDelegate`, and the window controllers are compiled under test and a new file cannot escape the suite by omission.
2. `feat: surface provider cost before cloud retries` — new `RetryCostNotice.swift`; Retry Last shows the paid providers in its menu title/tooltip (no modal, to preserve the paste target), History asks for confirmation before a paid retry. Local-only setups see no change.
3. `docs: correct the swift test diagnosis and describe the retry cost notice`.
4. `docs: record toolchain finding and hardening branch in handoff`.
5. `refactor: rename main.swift so SwiftPM can build the app` — `Sources/FlowType/main.swift` is now `FlowTypeMain.swift`; SwiftPM treats a file named `main.swift` as top-level script code, where `@main` is illegal.

The Mac owner reinstalled the Command Line Tools on 2026-09-04. `swift package describe` and `swift build` now succeed with `Package.swift` untouched, which confirms the diagnosis below. `swift test` still cannot run on this Mac; see "Toolchain finding".

6. `chore: bump build number to 14`.

The release candidate is the universal DMG rebuilt from `main` at `2054064` (version `0.8.0`, build `14`):

```text
dist/FlowType-0.8.0-macos-universal.dmg  7,153,264 bytes  2026-09-04 11:40
DMG SHA-256:        8c06ef27f85a12592845673e6a40119c6250615b04e260585de6e526849b1d75
Executable SHA-256: 65b83ac751eeb80812d557a18c0677f3922f6c1304890d1ea31f6cc2ab979a40
Architectures:      x86_64 arm64 (app and bundled whisper-cli)
```

The app installed in `/Applications` is still the 2026-09-01 build `13` (`4426d380…`); it has not been replaced with build 14. No GitHub release or tag exists. The repository is private as of this handoff; the owner has approved making it public, and a full-history scan for key patterns and credential-named files found nothing.

FlowType 0.8 is implemented as one source release: improved microphone routing/capture, stronger local transcription safeguards, three-day recording recovery and retranscription, and the brand-aligned transient capsule.

The source release is committed on `main` and pushed to `origin/main`. The verified app is installed and running from `/Applications/FlowType.app`. No DMG containing the final brand pass has been published, no GitHub release has been created, and nothing has been deployed elsewhere.

A local universal app was rebuilt and validated after the brand-aligned capsule redesign:

```text
dist/FlowType.app
Executable SHA-256: 4426d380f7715063fc8a45a805bc5db64ed532e0db4a6a5046fca923dea0b9a3
Architectures: x86_64 arm64
```

The older `dist/FlowType-0.8.0-macos-universal.dmg` predates the brand-aligned capsule and was not repackaged. The installed executable SHA-256 is `4426d380f7715063fc8a45a805bc5db64ed532e0db4a6a5046fca923dea0b9a3`, exactly matching the redesigned `dist/FlowType.app`. The installed bundle passed deep strict signature and plist validation, launched from `/Applications`, remained running after the smoke check, and created `recordings/` plus `.staging/` with `0700` permissions.

The previous installed app is recoverable at:

```text
.build/backups/FlowType-before-history-retry-20260901.app
.build/backups/FlowType-before-morphing-capsule-20260901-1555.app
.build/backups/FlowType-before-brand-aligned-capsule-20260901.app
```

## What changed

### Three-day recording recovery

Finalized dictations are now captured into private staging under:

```text
~/Library/Application Support/FlowType/recordings/.staging/<UUID>/
```

A readable nonempty capture is promoted before conversion/transcription into:

```text
~/Library/Application Support/FlowType/recordings/<UUID>/
  metadata.json
  recording.caf OR recording.wav
```

Metadata schema version 1 records the immutable entry/capture identity and original capture time, duration, status/stage, immutable first and mutable latest error, raw/final transcript, original/latest provider, attempt count/time, and audio availability. It stores no provider keys, environment values, or arbitrary paths.

Entries expire three days after the original capture time. Retry does not extend expiry. Launch reconciliation recovers valid stale staging as interrupted, removes incomplete staging, and changes stale visible processing entries to failed/interrupted. Reads/writes and a one-shot next-expiry timer prune inactive expired entries.

Recording directories use POSIX `0700`; metadata/audio files use `0600`. FlowType initiates no History sync. Account/FileVault protection applies when enabled, but Time Machine, enterprise backup, and other OS/user backup software may still include Application Support. App-level encryption was not added.

### One correlated processing pipeline

`AppCoordinator` now correlates each asynchronous attempt by both attempt UUID and retained-entry UUID. One pipeline owns CAF conversion/canonicalization, current-settings transcription, cleanup, dictionary replacement, transcript persistence, and origin-specific delivery.

- Initial valid audio is durable before later processing begins.
- Successful conversion retains the exact returned canonical WAV and removes the source/intermediate files.
- Conversion failure retains a readable CAF when possible.
- Missing, empty, near-silent, malformed, symlinked, expired, deleted, or explicitly unusable audio is not retryable.
- Local Whisper `*.transcript.txt` output is removed after success, failure, or cancellation; versioned metadata is the only transcript persistence.
- Late output checks both IDs before metadata, UI, clipboard, or paste changes.

Cancellation is intentional rather than blanket cleanup:

- Escape during a new capture or initial attempt deletes that new entry.
- Escape during a retry retains the older audio and any prior transcript.
- Disabling dictation, opening Settings, or quitting deletes unfinished capture, but retains already-finalized processing as interrupted/retryable.
- Staging left by a lifecycle interruption is reconciled on the next launch.

### Retry Last and Recording History

The menu bar now includes:

- **Retry Last Transcription** — selects the newest eligible retained recording, uses current transcription/cleanup/dictionary/environment settings, pastes into the previously focused app, and keeps recovered text on the clipboard.
- **Recording History…** — opens an on-demand newest-first native window. It shows time, duration, status/stage, attempts, provider history, first/latest errors, transcript, expiry, playback progress, Retranscribe, Copy, and confirmed one-entry Delete.

History retry uses current settings and updates the same UUID, but never synthesizes paste because opening History activates FlowType. The completed transcript is exposed through Copy. Retry is single-flight and unavailable while capture/processing is active or when audio is expired/missing/unusable.

### Feedback and pill

- The exact macOS `/System/Library/Sounds/Pop.aiff` sound at volume `0.32` is used for both recording start and stop. Retry plays no recording-boundary tone.
- The feedback surface is now a borderless deep-navy glass capsule inside a larger transparent, nonactivating, click-through, bottom-center, all-spaces `NSPanel` canvas.
- The visible capsule morphs from a 46-point accent orb into a content-sized 132–318-point surface and collapses back into the orb before ordering out. State changes animate both width and content opacity.
- Window-level shadow and explicit border were removed. The capsule owns a continuous-corner, shape-following navy shadow plus restrained cyan/pearl/coral internal illumination, eliminating the previous rectangular halo/double outline.
- A slow internal light reflection traverses the capsule when motion is enabled; Reduce Motion removes it.
- Recording text is split into a primary state and smaller microphone/routing detail. Three flowing cyan/pearl/coral ribbons echo the logo's three tails, respond to live input, and animate processing; compact success/error/update states omit the ribbons.
- Recording uses coral emphasis, processing uses cyan, and success/error keep semantically clear mint/amber medallions while sharing the branded material.
- The live recording symbol has a subtle accent pulse in addition to the audio-driven ribbons.
- Reduce Motion switches to static/fade-only feedback.
- Presentation generations own auto-hide, so a stale delayed hide cannot dismiss newer feedback.
- Animation and level timers are invalidated by hide/teardown.
- The panel is ordered out at idle and appears only for recording, processing, or brief success/error/update feedback.

## Provider and cost boundary

The configured local Whisper path remains $0 per transcription and per retry; audio stays on this Mac. Cloud behavior is unchanged but retry is a new request:

- OpenAI/Groq transcription sends the retained WAV again and can incur another provider charge.
- Cloud cleanup sends transcript text again and can incur another cleanup charge.
- Provider tier, rate limit, and available account spend were not inspected.

## Verification evidence

Passed during this implementation:

- `./scripts/test-direct.sh`
  - Existing routing/model/signal/volume/hotkey/permission/dictionary/update checks passed.
  - New store checks passed for schema/order/duration, immutable original error/provider, mutable latest error/provider, retry count, fixed retention clock, exact expiry boundary, active exclusion, `0700`/`0600`, retry eligibility, stale staging/processing recovery, transcript preservation, isolated delete, cancellation policy, missing/empty/malformed/null/unsupported/mismatched/symlinked metadata, missing/unusable/zero-byte audio, and nonfatal quarantine.
  - External retry transition from idle, repeated processing rejection, completion, and active-recording rejection passed.
- `./scripts/test-audio-capture.sh list` passed and listed current macOS inputs.
- `./scripts/test-audio-capture.sh system_default` passed using `MacBook Pro Microphone`: maximum level `0.493`, duration `3.093` seconds, `77,589` capture bytes.
- `FLOWTYPE_ARCHS=universal ./scripts/build-app.sh` passed with warnings treated as errors and produced `x86_64 arm64` slices.
- Before the final brand pass, `./scripts/package-release.sh` passed direct tests, rebuilt the pinned universal whisper.cpp engine, validated signing/plist, created the DMG, and checksum-verified it. That older DMG is not the current release artifact.
- Deep strict ad-hoc signature validation and plist lint passed for `dist/FlowType.app`.
- An isolated native preview rendered the branded recording, processing, success, error, intermediate-orb, and collapse states against real desktop content. The final surfaces had one continuous navy silhouette, logo-derived three-ribbon motion, readable pearl text, and no window border or rectangular panel shadow.
- The redesigned app was installed with a recoverable backup, relaunched, and its running `/Applications` executable hash was matched exactly to `dist/FlowType.app`.
- `swift test` remains unavailable. The earlier claim that the manifest's `swiftLanguageModes: [.v5]` was rejected is incorrect; see "Toolchain finding". The project-owned direct suite and the warnings-as-errors app compiler passed.
- Final source diff hygiene (`git diff --check`) passed.

The CMake whisper build emitted only its upstream deprecation warning about compatibility below CMake 3.10; the build completed successfully.

## Toolchain finding (2026-09-04)

Reproduced with a scratch copy of the package and three manifest variants (`swiftLanguageModes`, `swiftLanguageVersions`, and no language-mode line with tools-version 5.9). All three fail identically at **link** time:

```text
Undefined symbols for architecture arm64:
  PackageDescription.Package.__allocating_init(name:defaultLocalization:platforms:...swiftLanguageVersions:...)
```

Cause: `/Library/Developer/CommandLineTools/usr/lib/swift/pm/ManifestAPI/PackageDescription.swiftmodule` is dated Jul 12 while `libPackageDescription.dylib` beside it is dated Jun 9. The compiler checks the manifest against the newer interface; the linker binds against the older library, which lacks the symbol. No `Package.swift` edit can fix this. `pkgutil --pkg-info=com.apple.pkg.CLTools_Executables` reports 26.6.0; there is no Xcode.app on the machine, and the Command Line Tools ship `Testing.framework` but no XCTest.

Repair (needs the Mac owner; not run by an agent):

```bash
sudo rm -rf /Library/Developer/CommandLineTools && xcode-select --install
```

Done 2026-09-04; `swift package describe` and `swift build` succeed. The remaining blocker for `swift test` is framework availability, verified in a scratch copy:

- XCTest: `no such module 'XCTest'` — the Command Line Tools do not ship it.
- Swift Testing: `Testing.framework` exists under `/Library/Developer/CommandLineTools/Library/Developer/Frameworks`, but SwiftPM reports `no such module 'Testing'` (also with `--enable-swift-testing`), and a direct `swiftc -F` compile fails with `plugin for module 'TestingMacros' not found`. Migrating the tests to Swift Testing therefore does not help on a Command Line Tools-only Mac.

Decision: stay Command Line Tools-only. `scripts/test-direct.sh` is the authoritative suite; it compiles every source file. `swift test` works only after installing Xcode, at which point the existing XCTest files run unchanged.

## Verification evidence for the hardening branch

- `./scripts/test-direct.sh` passed after each commit, including the eight new `RetryCostNotice` checks (local-only no notice, local cleanup endpoint no notice, cloud transcription/cleanup provider naming, audio/transcript wording, de-duplicated provider, pipeline order, message prefix).
- `./scripts/build-app.sh` (native arm64) passed with warnings treated as errors after the `AppDelegate` change; it rebuilt whisper.cpp and fetched the Silero model into the worktree's ignored `.build/`.
- `nm` on the direct test binary confirms `AppCoordinator` symbols are now compiled under test.
- `git diff --check` passed before each commit.
- `./scripts/package-release.sh` passed from `main` at `3376d83`: 121 direct checks, fresh universal whisper.cpp, warnings-as-errors universal app build, deep strict signature, plist lint, DMG creation, checksum round-trip. The shipped executable contains `RetryCostNotice` symbols.
- The first packaging attempt failed because `.build/vendor/whisper-build-*` held CMake caches generated when the project lived at `apps/transcribe/`; those two directories were deleted and regenerated. The whisper.cpp source checkout and Silero model were kept.
- After the rename: `./scripts/test-direct.sh`, `./scripts/build-app.sh` (arm64), and `swift build` all pass; `git diff --check` clean.
- Not verified: the Retry Last menu title and the History confirmation dialog have not been exercised in the running app.

## Manual checks still required

The verified build is installed and running. These physical/product checks remain open:

1. Grant/refresh permissions if macOS requests them after the replacement.
2. In a real text field, make a successful new dictation and confirm Pop at both boundaries, orb-to-capsule entrance, responsive three-ribbon motion, restrained internal light sweep, content/width state morphs, collapse exit, transient success, paste, clipboard recovery, History row, duration, playback, and no idle pill.
3. Force a reversible provider/model failure and confirm retained audio plus enabled Retry Last.
4. Restore valid current settings and confirm Retry Last pastes and keeps the clipboard.
5. Retry from History and confirm no automatic paste, then Copy.
6. Confirm playback pause/resume/progress and stop-on-switch/close/delete.
7. Exercise Escape during capture, initial processing, and retry; relaunch after lifecycle interruption.
8. Confirm one-entry Delete, expiry while running, stale-hide safety, live Reduce Motion response, and pill nonactivation/click-through behavior.
9. Run the app on an Intel Mac for actual Intel runtime proof; only structural universal verification exists here.

## Changed feature files

Created:

- `Sources/FlowType/RecordingHistoryStore.swift`
- `Sources/FlowType/RecordingHistoryWindowController.swift`
- `Sources/FlowType/TranscriptQuality.swift`
- `Tests/AudioCaptureProbe/main.swift`
- `Tests/OutputVolumeProbe/main.swift`
- `ThirdPartyLicenses/silero-vad-LICENSE.txt`
- `scripts/fetch-vad-model.sh`
- `scripts/test-audio-capture.sh`

Modified for this feature:

- `Sources/FlowType/ConfigStore.swift`
- `Sources/FlowType/Models.swift`
- `Sources/FlowType/AudioDeviceService.swift`
- `Sources/FlowType/AudioRecorder.swift`
- `Sources/FlowType/AudioSignalQuality.swift`
- `Sources/FlowType/GestureStateMachine.swift`
- `Sources/FlowType/AppCoordinator.swift`
- `Sources/FlowType/TranscriptionService.swift`
- `Sources/FlowType/AppDelegate.swift`
- `Sources/FlowType/AudioFeedbackService.swift`
- `Sources/FlowType/LocalModelManager.swift`
- `Sources/FlowType/OutputVolumeDucker.swift`
- `Sources/FlowType/PersonalDictionary.swift`
- `Sources/FlowType/PillWindowController.swift`
- `Sources/FlowType/SettingsWindowController.swift`
- `Support/Info.plist`
- `THIRD_PARTY_NOTICES.md`
- `Tests/ManualTests/main.swift`
- `scripts/build-app.sh`
- `scripts/test-direct.sh`
- `README.md`
- `docs/ARCHITECTURE.md`
- `docs/INSTALL_FOR_FRIENDS.md`
- `HANDOFF.md`

At handoff completion, all source-release changes above are committed and pushed together. Ignored local build outputs, installed-app backups, and visual preview captures remain outside Git.

## Important boundaries

- The app version is now `0.8.0` build `14`. No new package dependency, database, account, cloud sync, search, export, bulk History UI, interactive pill control, tracker mutation, deployment, or publication was added.
- The three-day list is recovery, not an indefinite transcript archive.
- The current DMG predates the brand-aligned capsule. The installed app and `dist/FlowType.app` are current, but a distributable DMG must be rebuilt before any release.
- Building and isolated previewing do not prove the global shortcut, target-app paste, audible tone, perceived animation quality during a real capture, History focus behavior, or Intel runtime.
- Ad-hoc builds are not notarized and may require macOS privacy grants again after replacement.

## Next action

1. Install the build-14 `dist/FlowType.app` over `/Applications/FlowType.app` with a backup, as in the earlier release steps, and run the manual matrix on it.
2. Make the repository public, then tag `v0.8.0` at `2054064` and create a draft GitHub Release with the DMG and `.sha256` per `docs/RELEASING.md` step 7; publish only after review.
3. Add to the manual matrix: with a cloud transcription or cleanup provider selected, confirm the Retry Last menu title shows the provider, its tooltip shows the full sentence, and Retranscribe in History shows the confirmation dialog; with local-only settings confirm neither appears.

Run the remaining physical manual matrix above against the installed app. Before any public release, rebuild and re-verify the universal DMG so it includes the final brand pass; publication remains a separate approval boundary.
