# Feature: Dictation History, Retry, and Pill Polish

Validate documentation, codebase patterns, external reality, and task sanity
before implementing. Verify exact names of existing utilities, types, models,
configuration keys, and commands against current source.

## Overview

FlowType currently deletes a finalized recording directory whether processing
succeeds or fails. That makes a transient local-engine, provider, network,
cleanup, or insertion failure irreversible even when the captured audio was
good. Retain finalized dictations locally for three days, add Retry Last and an
on-demand History window, use the existing ending Pop for both audio boundaries,
and polish the pill without making it persistent or interactive.

Done means valid audio survives later failures; current-settings Retry Last
pastes and keeps clipboard text; History exposes metadata/playback/retry/copy/
delete but its retry never auto-pastes; unusable audio cannot retry; and the pill
is visible only during recording, processing, or brief status feedback. Search,
export, bulk actions, cloud sync, indefinite retention, themes, accounts, and
pill controls remain out of scope.

## User Story / Problem / Solution

**User story:** As a FlowType user, I want a failed dictation to keep its audio
for a short time and let me transcribe it again, so that a provider or processing
error does not force me to remember and rerecord what I said.

**Problem:** `AppCoordinator.stopAndProcess()` unconditionally removes its
temporary directory, destroying the only recovery input after any later failure.

**Solution:** Add a dependency-free file store under Application Support. Each
dictation gets a UUID directory, constant audio filenames, and atomic versioned
metadata. Capture into private staging, promote before transcription, and reuse
one correlated pipeline for initial attempts and retries. Add native AppKit
History/playback, one Pop tone, and a transient custom waveform pill.

## Metadata

- **Type:** Enhancement with a bug-fix core.
- **Complexity:** High.
- **Systems affected:** capture/conversion/transcription/cleanup/insertion,
  cancellation, local storage, menu/History/playback, pill/sound, tests, and docs.
- **Production dependencies:** None added. Use existing Foundation, AppKit, and
  AVFoundation APIs already linked by `scripts/build-app.sh`.
- **Persistence:** File-per-entry storage, not SQLite/Core Data.
- **Security:** Store under `~/Library/Application Support/FlowType/recordings`,
  set directories to POSIX `0700` and metadata/audio files to `0600`, never put
  secrets in metadata, and do not add app-managed sync. Protection relies on the
  macOS user account and FileVault when enabled; system backup software may still
  include Application Support. App-level encryption is explicitly not part of
  this version.
- **Retention:** `3 * 24 * 60 * 60` seconds from original `createdAt`; retry does
  not extend it.
- **Expected canonical audio size:** at the five-minute ceiling, 16,000 mono
  samples/second * 2 bytes/sample * 300 seconds + an approximately 44-byte WAV
  header = about 9,600,044 bytes (about 9.16 MiB) per successful conversion.
  A retained source CAF after conversion failure has an unverified device-format
  size and must be described as variable rather than assigned a false bound.
- **Current configured cost posture:** `HANDOFF.md:38-40` says the installed
  configuration uses bundled local transcription and no cleanup key, so current
  retries cost $0. Secrets and provider-account tiers were not inspected.
- **Optional paid paths:** OpenAI `whisper-1` is documented at $0.006/minute;
  Groq `whisper-large-v3-turbo` is documented at $0.04/hour with a 10-second
  minimum billed length; current cleanup default `gpt-5-mini` is $0.25 per
  million input tokens and $2.00 per million output tokens. A retry is a new
  transcription request and, when enabled, a new cleanup request.
- **Known tier versus required capability:** OpenAI/Groq tiers are unknown. The
  feature reuses the currently working provider; local retry needs no tier.
- **Premises verified at:** `82a561032a03549714980aa1f4fdb5122b61710f`
  (`feat: prepare FlowType 0.7 release`) plus the dirty working-tree baseline
  inspected on 2026-08-31. The current source differs materially from that
  commit, so the executor must diff and re-read every referenced file before
  editing rather than treating the commit tree alone as current truth.
- **Tracker:** none configured; this plan is the local scope source.

## ASSUMPTIONS AND OPEN QUESTIONS

- **Assumption — retention clock:** expiry is based on the original capture time,
  not the most recent retry. This preserves the approved three-day privacy bound.
- **Assumption — deletion:** History `Delete…` confirms once, then permanently
  removes that entry. Expiry/invalid-staging cleanup does not prompt.
- **Assumption — newest retry target:** `Retry Last Transcription` selects the
  newest nonexpired entry with a present, usable audio file, whether its prior
  status is failed or completed. Entries still capturing/processing, marked
  unusable, missing audio, or being deleted are skipped.
- **Assumption — menu paste target:** a menu-bar retry uses the existing
  `TextInsertionService` behavior after the menu closes. Whether a particular
  target application accepts the synthetic paste remains a physical QA item,
  just as it is for normal dictation.
- **Assumption — playback:** use system-default output through `AVAudioPlayer`;
  do not custom-route or duck playback.
- **Assumption — scheduling:** prune at launch/reads/writes and via one-shot next-
  expiry timer; when not running, prune on next launch.
- **Assumption — legacy metadata:** schema version 1 is the first shipped
  version. A missing, null, nonnumeric, or unsupported `schemaVersion`, malformed
  JSON, UUID-directory mismatch, or symlinked entry is quarantined from the
  visible list and reported through a nonfatal load error; it is not guessed at.
- **Assumption — crash recovery:** a stale `.staging/<UUID>` directory with a
  readable nonempty CAF/WAV and valid version-1 metadata is promoted as a failed
  `interrupted` entry. Empty, malformed, symlinked, or audio-less staging is
  removed as incomplete capture. Stale visible `processing` entries are changed
  to failed/interrupted at launch.
- **Assumption — storage pressure:** no extra quota because dictation frequency
  and failed-CAF sizes are unknown; measure during QA instead of inventing a cap.
- **Open verification — physical interaction:** Computer Use cannot prove the
  real global Right Option gesture, target-app paste, audible Pop tone, live mic
  waveform, or perceived animation quality. Those require human QA on the Mac.
- **Open verification — Intel runtime:** the universal binary can be structurally
  validated on Apple silicon, but actual Intel behavior needs an Intel Mac.

## Reference Docs to Load First

None. This repository has no `reference/` directory or project rules routing
feature work to reference documents. Load root `HANDOFF.md`, `README.md`, and
`docs/ARCHITECTURE.md` instead because they describe current behavior and the
canonical validation contract.

## CONTEXT REFERENCES

### Files to read before implementing

- `HANDOFF.md:1-166` — current behavior, validation, permissions, and stale
  storage/history claims.
- `Sources/FlowType/AppCoordinator.swift:3-99,152-227,242-373` — service
  ownership, lifecycle cancellation, pipeline, task correlation, and pill timers.
- `Sources/FlowType/AudioRecorder.swift:8-205,208-325` — temporary capture
  ownership, async finalization, conversion, silence proof, boost, and filenames.
- `Sources/FlowType/TranscriptionService.swift:12-149,181-219` — exact providers,
  endpoints, multipart fields, local output artifact, and transcript guards.
- `Sources/FlowType/CleanupService.swift:1-92` and
  `Sources/FlowType/TextInsertionService.swift:1-67` — cleanup fallback and
  clipboard/Cmd-V delivery to reuse.
- `Sources/FlowType/GestureStateMachine.swift:3-103` — exhaustive state branches.
- `Sources/FlowType/AppDelegate.swift:5-194` — lifecycle, service wiring, menu,
  selectors, and separate update pill.
- `Sources/FlowType/SettingsWindowController.swift:6-149` — reusable programmatic
  AppKit window lifecycle for History.
- `Sources/FlowType/PillWindowController.swift:3-117` and
  `Sources/FlowType/AudioFeedbackService.swift:3-25` — overlay invariants and the
  verified Tink/Pop behavior.
- `Sources/FlowType/ConfigStore.swift:3-79,119-149` — Application Support URLs,
  atomic writes/rollback, and private-file permission pattern.
- `Sources/FlowType/LocalModelManager.swift:93-128` — verified staging promotion.
- `Tests/ManualTests/main.swift:1-514` and `scripts/test-direct.sh:1-30` — direct
  `expect` harness and its explicit source list.
- `scripts/test-audio-capture.sh:1-26`, `scripts/build-app.sh:1-52`, and
  `scripts/package-release.sh:1-54` — real capture, warnings-as-errors/all-source
  build, and final package gates.
- `README.md:9-50,128-132,335-351,390-399` — user behavior, cost, privacy,
  intentional scope, and limitations.
- `docs/ARCHITECTURE.md:1-181,207-255` — data flow/storage/cloud/scripts/file map.
- `docs/INSTALL_FOR_FRIENDS.md:1-18,125-181,217-240` — install-facing behavior,
  privacy, troubleshooting, and QA.

### New files to create

- `Sources/FlowType/RecordingHistoryStore.swift` — versioned entry models,
  constant-path resolution, secure staging/finalization, atomic metadata,
  retention, crash reconciliation, eligibility, deletion, and list ordering.
- `Sources/FlowType/RecordingHistoryWindowController.swift` — native AppKit
  list/detail History UI, playback, retry/copy/delete controls, and busy updates.

### Documentation links

- [Apple AVAudioPlayer](https://developer.apple.com/documentation/avfaudio/avaudioplayer)
  — existing-framework file playback, play/pause state, and duration.
- [Apple AVAudioPlayer currentTime](https://developer.apple.com/documentation/avfaudio/avaudioplayer/currenttime)
  — exact playback position used for a small progress label/control.
- [Apple Reduce Motion](https://developer.apple.com/documentation/appkit/nsworkspace/accessibilitydisplayshouldreducemotion)
  — exact `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion` property
  and change-notification guidance.
- [Apple NSAnimationContext](https://developer.apple.com/documentation/appkit/nsanimationcontext)
  — built-in AppKit animation grouping without a production dependency.
- [OpenAI whisper-1](https://developers.openai.com/api/docs/models/whisper-1)
  — current transcription endpoint support and $0.006/minute price.
- [OpenAI Audio API FAQ](https://help.openai.com/en/articles/7031512-audio-api-faq)
  — legacy `whisper-1` upload maximum of 25 MiB.
- [OpenAI gpt-5-mini](https://developers.openai.com/api/docs/models/gpt-5-mini)
  — current cleanup-model price and `v1/chat/completions` support.
- [Groq Speech to Text](https://console.groq.com/docs/speech-to-text)
  — exact transcription endpoint, model, WAV support, size tiers, 10-second
  billing minimum, and $0.04/hour price.
- [Wispr Flow bar](https://roadmap.wisprflow.ai/changelog/pointup2-new-flow-bar-flow-pro)
  — approved reference for a restrained compact activation bar.
- [Superwhisper recording window](https://superwhisper.com/docs/get-started/interface-rec-window)
  — approved reference for waveform and explicit recording/processing clarity.
- [VoiceInk transcription history](https://tryvoiceink.com/docs/transcription-history)
  — approved precedent for local history, three-day retention, playback, copy,
  status, and metadata.
- [VoiceInk shortcuts](https://tryvoiceink.com/docs/shortcuts)
  — approved precedent for current-settings Retry Last and Open History actions.

### Patterns to follow

- `ConfigStore.save(_:)` at `Sources/FlowType/ConfigStore.swift:44-48` encodes
  with sorted pretty JSON and uses atomic writes. The history store should use
  the same atomic-write idea, then explicitly enforce file mode `0600`.
- `ConfigStore.save(_:dictionaryContents:)` at
  `Sources/FlowType/ConfigStore.swift:55-78` preserves earlier bytes and rolls
  back on a multi-file failure. History promotion must likewise avoid exposing
  half-written metadata as a valid entry.
- `Sources/FlowType/LocalModelManager.swift:93-128` verifies staging before
  replace/move; do not expose an in-progress artifact merely because it exists.
- `AppCoordinator` uses a UUID at `Sources/FlowType/AppCoordinator.swift:245-246`
  and compares it before insertion at lines 295-297. Replace this with a richer
  context, but preserve identity-based late-result rejection.
- `AudioRecorder.finishRecording` at `Sources/FlowType/AudioRecorder.swift:160-190`
  is the sole capture-finalization callback. Ownership of deleting versus
  retaining its directory must remain explicit here and in the coordinator.
- `AudioConverterService` at `Sources/FlowType/AudioRecorder.swift:215-260`
  already proves frames and signal quality. Reuse that proof; do not add a
  second inconsistent silence threshold in History.
- `SettingsWindowController` at
  `Sources/FlowType/SettingsWindowController.swift:113-149` creates one reusable,
  programmatic native window, reloads state before showing, and activates the
  app. History should mirror that lifecycle.
- `PillWindowController` at `Sources/FlowType/PillWindowController.swift:29-41`
  establishes the product-critical nonactivating, click-through overlay. Preserve
  these panel flags through visual refactoring.
- `Tests/ManualTests/main.swift` uses small direct `expect` checks and cleans
  per-test temporary directories with `defer`. Extend that style rather than
  introducing XCTest or a package dependency.
- `scripts/build-app.sh:41` compiles every `Sources/FlowType/*.swift`, so new app
  sources are build-covered automatically; `scripts/test-direct.sh:14-25` is an
  explicit list and must be updated for store tests.

### External reality verified

- `AVAudioPlayer` supports file-backed asynchronous playback, `play()`,
  `pause()`, `isPlaying`, `currentTime`, and `duration`; it is sufficient for the
  MVP and avoids an `AVAudioEngine` playback subsystem.
- `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion` is available well
  before the project's macOS 13 deployment target. Apple recommends avoiding
  large or 3D motion when it is enabled and exposes a display-options change
  notification.
- The local macOS SDK contains both the Reduce Motion property and
  `NSAnimationContext.runAnimationGroup`; identifiers were checked against the
  installed SDK, not reconstructed from memory.
- Current source sends OpenAI audio to
  `https://api.openai.com/v1/audio/transcriptions` and Groq audio to
  `https://api.groq.com/openai/v1/audio/transcriptions` as multipart WAV with
  `model`, `language`, `response_format`, optional `prompt`, and `file` fields.
- OpenAI documents `whisper-1` at $0.006/minute and a 25 MiB legacy upload limit.
  The maximum canonical five-minute WAV calculated above is below that limit.
- Groq documents `whisper-large-v3-turbo` at $0.04/hour, a 10-second minimum
  billed duration, 25 MB free-tier and 100 MB developer-tier direct upload
  limits, and WAV support. The maximum canonical WAV is below both size limits.
- Provider-account ownership, available spend, and rate-limit tier are
  unavailable. Retry UI must present provider errors rather than claiming a
  request is free, guaranteed, or exempt from rate limits.
- Wispr Flow, Superwhisper, and VoiceInk are visual/workflow references only.
  Their code, assets, private interfaces, and account/cloud behavior are not
  dependencies and must not be copied.

## STEP-BY-STEP TASKS

### Task 1 — CREATE the versioned local recording-history store

- **IMPLEMENT:** Create a Foundation-only schema-v1 store with UUID, `createdAt`,
  duration, status/stage, immutable first and mutable latest error, raw/final
  text, original/latest provider, attempts, last attempt, and audio availability.
  Statuses are `captured|processing|completed|failed`; stages are
  `capture|conversion|transcription|cleanup|insertion|interrupted`.
- **IMPLEMENT:** Use UUID directories and constants `metadata.json`,
  `recording.caf`, `recording.wav`; implement staging/promotion, atomic updates,
  newest-first list, eligibility/audio resolution, canonicalization, attempt
  updates, delete, launch reconciliation, prune, and next-expiry lookup.
- **GOTCHA:** Treat absent/empty root, missing/zero/malformed/null metadata,
  missing/unsupported schema, UUID mismatch, missing/zero audio, symlinks, stale
  staging, and stale processing separately. Retry never extends `createdAt`;
  active work is prune-excluded until completion.
- **PATTERN:** Mirror atomic JSON and permission handling from
  `Sources/FlowType/ConfigStore.swift:44-79,119-149`, and staging-before-exposure
  from the model manager.
- **VALIDATE:** Add direct tests and the store to `scripts/test-direct.sh`, then
  run `./scripts/test-direct.sh`; cover every state above, round trip/order,
  immutable first error, retry update, expiry boundary/exclusion, permissions,
  crash recovery, eligibility, and isolated delete.

### Task 2 — UPDATE ConfigStore with a private recordings root

- **IMPLEMENT:** Add `recordingsURL`, create it under Application Support, apply
  `0700` to the recordings tree and `0600` after metadata/audio create or move.
  Keep three-day retention fixed rather than adding config schema.
- **GOTCHA:** Existing Application Support directories may already have broader
  permissions. Tighten only `recordings`; do not inspect FileVault or add
  Keychain encryption.
- **PATTERN:** `Sources/FlowType/ConfigStore.swift:10-27` owns Application Support
  URLs and `Sources/FlowType/ConfigStore.swift:137-149` sets a private file mode.
- **VALIDATE:** Run `./scripts/test-direct.sh` and
  `FLOWTYPE_BUNDLE_WHISPER=0 ./scripts/build-app.sh`.

### Task 3 — UPDATE AudioRecorder to accept explicit capture-directory ownership

- **IMPLEMENT:** Let `start` accept an optional precreated destination. Dictation
  passes staging; Settings omits it. Track owned-temp versus loaned-durable
  directories, delete either on start/capture cancel, retain durable on success,
  and calculate duration from source frames/sample rate outside the store.
- **GOTCHA:** Preserve callback-before/after-continuation `finalizedResult` and
  exactly-once resume. Settings test audio must never enter History.
- **PATTERN:** Preserve the capture-session and callback flow at
  `Sources/FlowType/AudioRecorder.swift:32-190`; change only directory ownership
  semantics and duration exposure.
- **VALIDATE:** Run `./scripts/test-audio-capture.sh system_default` and
  `FLOWTYPE_BUNDLE_WHISPER=0 ./scripts/build-app.sh`.

### Task 4 — ADD an explicit external-processing transition

- **IMPLEMENT:** Add `beginExternalProcessing`: idle -> processing with no action;
  holding/waiting/hands-free/processing ignore it. Keep Escape cancellation and
  `processingFinished` -> idle.
- **GOTCHA:** Transition and confirm before creating the retry Task; reset if
  setup throws so menu state and machine state cannot drift.
- **PATTERN:** Extend the exhaustive switch in
  `Sources/FlowType/GestureStateMachine.swift:37-103` and its existing table-like
  tests in `Tests/ManualTests/main.swift`.
- **VALIDATE:** Run `./scripts/test-direct.sh` with idle, all ignored nonidle,
  Escape, and completion assertions.

### Task 5 — REFACTOR AppCoordinator around one correlated processing pipeline

- **IMPLEMENT:** Inject the store and replace bare session ID with context:
  attempt UUID, entry UUID, `newCapture|retryLast|history`, `paste|historyOnly`,
  and cancellation policy. Stage before capture; after stop, persist duration
  and promote before conversion.
- **IMPLEMENT:** Use one pipeline for CAF resolution/conversion, stage updates,
  current config/environment/dictionary transcription, cleanup/replacements,
  transcript persistence, and context delivery. Canonicalize the exact returned
  WAV (including boosted output), chmod it, remove intermediates, retain readable
  CAF on conversion failure, delete any non-returned partial WAV, and callback
  busy/history changes.
- **IMPLEMENT:** Check attempt + entry UUID before any metadata/UI/state/
  clipboard/paste mutation; this correlates async output to its request.
- **GOTCHA:** Remove the unconditional directory `defer` at
  `Sources/FlowType/AppCoordinator.swift:255-260`. Converter-proven missing/
  silent audio becomes unusable; process failure with readable CAF and provider
  failure with valid WAV remain retryable.
- **PATTERN:** Preserve current config snapshotting and processing UI at
  `Sources/FlowType/AppCoordinator.swift:247-298`, plus identity guard at line
  296, while separating persistence, processing, and delivery responsibilities.
- **VALIDATE:** Run `./scripts/test-direct.sh` for pure policy helpers and
  `FLOWTYPE_BUNDLE_WHISPER=0 ./scripts/build-app.sh`; use Task 14 for integration.

### Task 6 — ADD initial-attempt and retry cancellation policies

- **IMPLEMENT:** Escape deletes active capture/initial-processing entry but
  retains a retry source and prior transcript. Disable/Settings/shutdown delete
  unfinished capture but preserve finalized audio as interrupted/retryable.
  Reconcile valid staging and stale processing on launch.
- **GOTCHA:** Apply policy exactly once despite cancellation at any await point;
  late work cannot affect newer UUIDs. Restore output/play stop once for capture;
  retry never ducks output or plays recording feedback.
- **PATTERN:** Split current `cancelCurrentWork()` call sites at
  `Sources/FlowType/AppCoordinator.swift:55-98,331-344` by explicit reason.
- **VALIDATE:** Run `./scripts/test-direct.sh` for every policy branch and a stale
  attempt UUID.

### Task 7 — UPDATE TranscriptionService to clean local output artifacts

- **IMPLEMENT:** Delete local `recording.transcript.txt` after success, failure,
  or cancellation; metadata is the only transcript persistence.
- **GOTCHA:** Resolve the output before process start and delete only that file,
  never canonical audio or metadata.
- **PATTERN:** Keep exact arguments and normalization behavior at
  `Sources/FlowType/TranscriptionService.swift:69-105`; add only scoped artifact
  ownership.
- **VALIDATE:** Run `FLOWTYPE_BUNDLE_WHISPER=0 ./scripts/build-app.sh`; Task 14
  must observe no `*.transcript.txt` artifact.

### Task 8 — ADD public coordinator retry entry points

- **IMPLEMENT:** Add Retry Last and History retry entry points. Require idle and
  disk eligibility; snapshot current provider/model/cleanup/dictionary/env,
  increment attempt, enter external processing, then run the shared pipeline.
  Retry Last pastes; History retry only updates and exposes Copy.
- **GOTCHA:** Return clear busy/expired/missing/unusable/malformed/deleted errors.
  Preserve original/latest provider separately. Cleanup raw fallback completes;
  insertion failure retains completed text with insertion error.
- **PATTERN:** Reuse the service sequence at
  `Sources/FlowType/AppCoordinator.swift:247-298`; do not duplicate a second
  provider switch or dictionary implementation.
- **VALIDATE:** Run `FLOWTYPE_BUNDLE_WHISPER=0 ./scripts/build-app.sh`; Task 14
  proves Retry Last paste and History no-paste.

### Task 9 — CREATE the on-demand Recording History window

- **IMPLEMENT:** Create reusable native newest-first list/detail History, loaded
  only on command. Show time/duration/status, first/latest error, attempts,
  original/latest provider, transcript/expiry, and empty state. Add one selected-
  entry `AVAudioPlayer` with play/pause/progress plus Retranscribe/Copy/Delete.
  Refresh by UUID; stop playback on switch/delete/close/expiry/missing audio.
- **GOTCHA:** History activates FlowType, so never insertion-paste from this
  origin. Do not load audio bytes into list models. Confirm delete once; failure
  keeps row visible. Disable retry/destruction for active work.
- **PATTERN:** Mirror reusable window setup/show lifecycle from
  `Sources/FlowType/SettingsWindowController.swift:113-149`; use AVAudioPlayer's
  verified `isPlaying`, `currentTime`, `duration`, `play()`, and `pause()`.
- **VALIDATE:** Run `FLOWTYPE_BUNDLE_WHISPER=0 ./scripts/build-app.sh`, then the
  Task 14 History matrix.

### Task 10 — UPDATE AppDelegate menu wiring and retention lifecycle

- **IMPLEMENT:** AppDelegate creates/reconciles/prunes one store, injects it,
  owns one History controller, adds both menu actions, updates enablement/window
  from callbacks, and schedules/invalidate the next-expiry timer. History stays
  viewable while busy; active retry/delete is disabled. Keep `updatePill`
  separate and the dictation pill absent at idle.
- **GOTCHA:** History/store failure must disable only recovery UI, not app launch.
  Avoid closure cycles.
- **PATTERN:** Follow selector/menu construction at
  `Sources/FlowType/AppDelegate.swift:103-153` and lifecycle ownership at lines
  25-101.
- **VALIDATE:** Run `FLOWTYPE_BUNDLE_WHISPER=0 ./scripts/build-app.sh`, launch the
  built app, and observe enablement after capture, busy, delete, and expiry.

### Task 11 — UPDATE feedback so Pop is both activation and ending tone

- **IMPLEMENT:** Use one `/System/Library/Sounds/Pop.aiff` instance at `0.32` for
  both public boundaries with stop-before-play.
- **GOTCHA:** Preserve the `feedbackSoundsEnabled` guard at coordinator call
  sites. Retry is not a new recording and must not play activation/ending tones.
- **PATTERN:** Refactor only `Sources/FlowType/AudioFeedbackService.swift:3-25`
  and preserve its `@MainActor` ownership.
- **VALIDATE:** Run `FLOWTYPE_BUNDLE_WHISPER=0 ./scripts/build-app.sh`; physically
  confirm Pop once at start/stop and none on retry.

### Task 12 — REFACTOR the pill into a polished transient waveform/status bar

- **IMPLEMENT:** Preserve nonactivating/click-through/bottom-center/all-spaces
  behavior. Draw five rounded bars, smooth existing 0.08-second levels, and add
  held/hands-free/processing/success/error/update states with text/symbol plus
  color. Use a generation token for every delayed hide, stop timers on hide/
  deinit, and use opacity plus <=6-point motion via `NSAnimationContext`.
- **IMPLEMENT:** Observe Reduce Motion; use static state plus opacity when on.
- **GOTCHA:** Order completely out at idle. Centralize token-aware auto-hide so
  old coordinator/update timers cannot hide a new presentation.
- **PATTERN:** Preserve panel flags and screen placement from
  `Sources/FlowType/PillWindowController.swift:29-41,89-117`; use the approved
  Wispr compactness and Superwhisper state clarity as direction, not pixel-copy.
- **VALIDATE:** Run `FLOWTYPE_BUNDLE_WHISPER=0 ./scripts/build-app.sh`, then prove
  idle absence, nonactivation, motion/timing, stale-hide safety, and Reduce Motion.

### Task 13 — UPDATE user and architecture documentation

- **IMPLEMENT:** Update README behavior/privacy/cost/limitations, Architecture
  staging/schema/correlation/states/retention/UI/cancellation, and friend-facing
  menu/recovery/privacy/cost/QA. Remove obsolete no-history/always-delete claims.
- **GOTCHA:** Say FlowType does not initiate cloud sync; do not promise that
  Time Machine, enterprise backup, or other OS software excludes Application
  Support. Say local provider keeps audio on-device; cloud provider retry sends
  the recording again.
- **GOTCHA:** Do not update version numbers, release notes, package metadata, or
  claim a release/deployment. Those require separate release work.
- **PATTERN:** Keep the current plain-English user flow and explicit local/cloud
  cost boundary in `README.md:128-132,335-351`.
- **VALIDATE:** Run `git diff --check -- README.md docs/ARCHITECTURE.md docs/INSTALL_FOR_FRIENDS.md`
  and reconcile every hit from
  `rg -n "temporary|deleted|history|retry|start and stop sounds|distinct start" README.md docs/ARCHITECTURE.md docs/INSTALL_FOR_FRIENDS.md` against shipped behavior.

### Task 14 — UPDATE HANDOFF and run the full staged verification matrix

- **IMPLEMENT:** After observed checks, update HANDOFF with shipped behavior,
  security/cancellation/delivery/cost/UI decisions, changed files, exact results,
  skips, and physical/Intel gaps. Run deterministic -> device list -> real capture
  -> universal build -> package, plus the disposable-entry manual matrix. Package
  creation is not deployment/release.
- **GOTCHA:** The current working tree already contains extensive uncommitted 0.8
  work. Do not reset, restore, stage, commit, or overwrite unrelated changes.
  Review the final diff against the baseline recorded in this plan.
- **GOTCHA:** `scripts/package-release.sh` may rebuild ignored artifacts and can
  require locally available Whisper/VAD assets. If it cannot run, report the
  exact blocker rather than substituting a weaker command and calling it passed.
- **PATTERN:** Preserve the evidence-oriented structure and command list in
  `HANDOFF.md:67-96,148-166` while replacing stale storage/history claims.
- **VALIDATE:** Run every command below, record exact results, run diff hygiene,
  and reconcile final status with the pre-existing dirty baseline.

## TESTING STRATEGY

### Deterministic logic tests

Extend the current direct Swift harness rather than adding XCTest or a package.
Tests must fail with a nonzero exit if behavior is absent. Include:

- schema-v1 round trip/order; immutable original versus latest error/provider;
- exact expiry boundary, no retry extension, active exclusion, then prune;
- isolated delete and `0700` directory/`0600` file permissions;
- absent root, empty root, missing metadata, zero-byte metadata, malformed JSON,
  JSON `null`, missing/unsupported schema, UUID mismatch, symlink, missing audio,
  and zero-byte audio each produce the specified result;
- valid/invalid stale staging, stale processing, and transcript preservation;
- available versus unusable/missing eligibility;
- external processing from idle and every ignored nonidle branch;
- initial Escape delete, retry Escape retain, lifecycle interrupt retain,
  capture lifecycle cancellation delete, and stale UUID no-op policies.

### Build/integration coverage

- Direct tests must explicitly compile the Foundation-only store; app build must
  compile all sources with Swift 5, warnings-as-errors, AppKit, and AVFoundation.
- `scripts/test-audio-capture.sh system_default` proves actual capture and
  conversion still work after changing directory ownership.
- Universal build proves both slices compile/link; packaging proves assembly and
  ad-hoc validation, not Intel runtime or publication.

### Manual end-to-end matrix

1. With local transcription, make a successful new dictation in a real text
   field; confirm two Pop tones, responsive waveform, processing state, brief
   success, paste, clipboard recovery, completed History row, duration, playback,
   and no idle pill afterward.
2. Force a recoverable transcription failure using a reversible bad local model
   path or missing test API key; confirm retained audio, original error, enabled
   Retry Last, no lost recording, and no leftover local transcript artifact.
3. Restore valid current settings and choose Retry Last while a real text field
   is frontmost; confirm current provider is used, text pastes, clipboard is
   populated, and the same row becomes completed without changing `createdAt`.
4. Force another failed entry, open History, retry it, and confirm History remains
   the focused app, no text is auto-pasted, the row updates, and Copy works.
5. Exercise playback/switch/close/delete, including failed delete visibility.
6. Create a near-silent/zero-frame fixture through the probe or a
   deterministic fixture; confirm the row explains no usable audio and both retry
   controls are disabled for it.
7. Press Escape during capture; confirm no History row. Press Escape during
   initial processing; confirm its new row is removed. Press Escape during a
   retry; confirm the older entry/audio remains.
8. Disable dictation/open Settings/quit during finalized processing; relaunch and
   confirm the entry is interrupted and retryable. Repeat with active capture and
   confirm incomplete capture is absent.
9. Seed an expired disposable entry and relaunch; confirm automatic deletion.
   Seed a future-near expiry while running and confirm the one-shot timer removes
   it without reopening History.
10. Rapidly overlap status/new-recording presentations; prove stale-hide safety.
11. Toggle Reduce Motion live; prove static clarity and preference response.
12. Prove the pill never becomes key, captures clicks, persists idle, or replaces
    the menu-bar launcher.

## VALIDATION COMMANDS

Run from the repository root in this order:

```bash
./scripts/test-direct.sh
./scripts/test-audio-capture.sh list
./scripts/test-audio-capture.sh system_default
FLOWTYPE_ARCHS=universal ./scripts/build-app.sh
./scripts/package-release.sh
git diff --check
git status --short
```

Coverage notes:

- `./scripts/test-direct.sh` is authoritative for deterministic pure Swift in
  this repository because local SwiftPM behavior is known to differ. It covers
  the new store only after its explicit source list is updated.
- `./scripts/test-audio-capture.sh list` proves device discovery but not capture.
- `./scripts/test-audio-capture.sh system_default` proves one real capture and
  conversion route but not global-hotkey/UI/history behavior.
- `FLOWTYPE_ARCHS=universal ./scripts/build-app.sh` covers every source file via
  the verified glob and treats warnings as errors. It proves structural slices,
  not Intel runtime.
- `./scripts/package-release.sh` is the project's final package gate. It does not
  deploy or publish anything.
- `git diff --check` proves whitespace/patch hygiene, not runtime behavior.
- The manual matrix remains required for tone, animation quality, nonactivation,
  global hotkey, paste target, playback, and the user-visible retry distinction.

## ACCEPTANCE CRITERIA

- [ ] A valid finalized recording is durable before conversion/transcription
  begins and survives conversion, transcription, cleanup, and insertion failure.
- [ ] Each entry uses a UUID directory with one version-1 `metadata.json` and at
  most one retained CAF or canonical WAV after an attempt becomes quiescent.
- [ ] Recording directories are `0700`; metadata/audio files are `0600`; no API
  keys, environment values, or arbitrary paths are written to metadata.
- [ ] FlowType initiates no history sync and documentation accurately notes that
  OS/user backup tools may still include Application Support.
- [ ] Entries expire from original capture time after three days; retry never
  extends expiry; launch and in-process next-expiry pruning are proven.
- [ ] Intentional new-capture cancellation removes audio/history, while lifecycle
  interruption after finalization preserves a failed/interrupted retryable entry.
- [ ] Escape during initial processing removes that new entry; Escape during a
  retry preserves the prior entry, audio, and any prior transcript.
- [ ] Retry Last selects the newest eligible retained entry, uses current
  transcription/cleanup/dictionary settings, auto-pastes through the existing
  insertion path, and updates the same History UUID.
- [ ] History retry uses current settings, updates the same UUID, exposes Copy,
  and never synthesizes paste while History is active.
- [ ] Retry Last and History retry are single-flight and disabled/rejected during
  capture or processing with an accurate reason.
- [ ] Missing, zero-frame, zero-byte, near-silent, expired, malformed, symlinked,
  and deleted entries cannot be retried and do not crash the app.
- [ ] Original error is retained after retries; latest stage/error/provider,
  attempt count, raw transcript, and final transcript update atomically.
- [ ] History opens only on request, sorts newest first, and shows time, duration,
  status, original error, playback, retranscribe, copy, and delete controls.
- [ ] Playback starts/pauses/resumes selected CAF/WAV audio and stops on selection
  change, deletion, close, expiry, or missing file.
- [ ] Delete requires one confirmation, permanently removes only that entry, and
  keeps the row visible with an error if filesystem deletion fails.
- [ ] Local whisper leaves no `*.transcript.txt` alongside retained audio.
- [ ] The exact existing Pop system sound plays once for recording start and once
  for recording stop when feedback is enabled; retry produces no recording tone.
- [ ] The pill remains nonactivating, click-through, bottom-center, and completely
  absent at idle; it appears only for active recording/processing or brief
  success/error/update feedback.
- [ ] Five-bar recording motion responds to input, processing is visually clear,
  text/symbol supplements color, and Reduce Motion produces a static/fade-only
  alternative.
- [ ] A stale delayed hide cannot dismiss a newer presentation, and no repeating
  animation/level timer survives `hide()` or controller teardown.
- [ ] Current local transcription and cleanup fallback remain $0 per retry;
  documentation warns that configured cloud transcription/cleanup retries create
  new billable requests.
- [ ] No new dependency, database, account, cloud sync, search, export, bulk UI,
  interactive pill, release version bump, deployment, or tracker write is added.
- [ ] Direct tests, audio list/capture probes, universal build, package gate, and
  diff hygiene pass, or every skipped/blocked gate is reported with exact risk.
- [ ] Physical QA proves the real shortcut, same start/stop tone, target-app paste,
  History no-paste behavior, playback, transient pill, and Reduce Motion.
- [ ] `README.md`, `docs/ARCHITECTURE.md`, `docs/INSTALL_FOR_FRIENDS.md`, and root
  `HANDOFF.md` match observed shipped behavior without claiming deployment.

## TRACKER

Untracked project. No project-root `AGENTS.md`/`CLAUDE.md` tracker configuration
or tracker section exists, and root `HANDOFF.md` names no tracker. No lookup was
performed, no issue was inferred, and no external issue creation/update is part
of this plan.

## HANDOFF UPDATE

The final implementation task must update root `HANDOFF.md`. Record what actually
shipped, the per-entry storage/data flow, three-day retention and permissions,
current-settings retry behavior, the paste versus History-only delivery split,
cancellation/crash recovery, provider cost boundary, pill/tone behavior, exact
validation evidence, manual checks, failures/skips, known limitations, and the
next action. Remove the stale claims that recordings are deleted after every
failure and transcript history does not exist. Do not edit HANDOFF during this
planning workflow and do not claim commit, push, install, release, or deployment
without separate evidence.

## DECISION LOG (plain English - for the human)

1. **Three-day local files.** The user chose three days. UUID folders beat a
   database for a small reversible single-user list; revisit only for search,
   long retention, or measured volume pressure.

2. **Durable staging.** Capture inside Application Support instead of copying
   from `/tmp` after stop, which leaves a crash-loss window. Keep Settings tests
   temporary and verify every ownership/cancel branch.

3. **Standard macOS protection.** The user approved `0700`/`0600`, account/
   FileVault protection, no app sync, and timed deletion over app encryption.
   Document that OS backup software may still include the files.

4. **Current-settings retry, origin-specific delivery.** User-approved Retry Last
   pastes and keeps clipboard text; History retry updates and offers Copy because
   History activates FlowType. Preserve original/latest provider and error.

5. **Honest retry eligibility.** Valid-audio provider failures remain retryable;
   missing/empty/near-silent audio does not. The existing converter remains the
   single signal-quality authority.

6. **Cancellation versus interruption.** User-rejected new audio is deleted;
   lifecycle/crash interruption after finalization and retry cancellation retain
   recovery data. This protects intent without making every interruption loss.

7. **Existing-framework playback.** `AVAudioPlayer` covers CAF/WAV and MVP
   controls without a new engine/dependency; custom routing and playback ducking
   are deliberately deferred.

8. **Transient native feedback.** The user rejected a persistent pill and chose
   Pop for both boundaries. AppKit five-bar motion, generation-safe hides, and a
   Reduce Motion fallback add polish without interactivity or a dependency.

9. **Verification is not release.** Build/package checks are allowed evidence;
   versioning, commit, push, install, publish, and deploy remain separate. Preserve
   and reconcile the dirty worktree rather than resetting it.
