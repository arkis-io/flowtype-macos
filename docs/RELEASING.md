# FlowType release runbook

This runbook is for the repository owner or an authorized release agent. It creates a universal unsigned community DMG, verifies it, stages a GitHub draft release, and explains how update notifications become visible.

Packaging, committing, pushing, changing visibility, and publishing are separate actions. Do not infer permission for one from permission for another.

## Distribution model

FlowType has no paid Apple Developer Program membership. Releases are therefore:

- ad-hoc signed for bundle integrity;
- not Developer ID signed;
- not notarized;
- manually approved through macOS Gatekeeper;
- manually replaced during an update.

The app checks GitHub for a newer public release but never downloads or installs executable code silently.

## One-time repository decisions

Before making the project public, the owner must explicitly:

1. Confirm the existing MIT License and copyright holder are still intended.
2. Approve changing the GitHub repository from private to public.
3. Review the entire Git history for secrets, personal data, model files, recordings, or private assets.
4. Confirm `.env`, `.build/`, and `dist/` remain ignored.

Do not automate repository visibility changes. They expose the full reachable Git history, not only the latest files.

## Release prerequisites

- macOS 13 or later
- Apple's command-line developer tools (`xcrun`, `swiftc`, `codesign`, `lipo`); the release scripts do not use SwiftPM or Xcode
- CMake for compiling the pinned whisper.cpp release engine (`brew install cmake` on the release Mac)
- `hdiutil`, `ditto`, `plutil`, and `shasum` from macOS
- GitHub CLI only for publishing (`gh auth status`)
- clean, reviewed Git state on the intended release commit

The packaged app has no Homebrew or third-party Swift runtime dependency. CMake is build-time-only; friends installing the DMG do not need it.

## 1. Orient and inspect

```bash
git status --short --branch
git remote -v
git log -5 --oneline --decorate
gh repo view --json nameWithOwner,visibility,url,defaultBranchRef
gh release list --limit 10
```

Stop if:

- the worktree contains unrelated changes;
- `main` is not synchronized with the intended release commit;
- the repository identity is not `jdlinventures/flowtype-macos`;
- a release with the proposed tag already exists;
- visibility or publication has not been approved.

## 2. Choose the version

Update both keys in `Support/Info.plist`:

```text
CFBundleShortVersionString   user-facing version, for example 0.7.0
CFBundleVersion              monotonically increasing build, for example 12
```

Release tags must be `v` followed by the same user-facing version, for example `v0.7.0`. The in-app checker parses numeric version components and GitHub's latest-release endpoint ignores drafts and prereleases.

Use:

- patch (`0.7.0` → `0.7.1`) for fixes;
- minor (`0.7.0` → `0.8.0`) for compatible features;
- major (`0.x` → `1.0.0`) when the project intentionally declares a stable public contract.

## 3. Test and package

```bash
./scripts/package-release.sh
```

The script:

1. runs deterministic tests;
2. checks out whisper.cpp `v1.9.1` at its pinned source commit;
3. compiles static arm64 and x86_64 `whisper-cli` slices and rejects Homebrew/developer-machine links;
4. compiles FlowType for arm64 and x86_64 with warnings as errors;
5. embeds and signs the universal Whisper engine before signing the app;
6. verifies the bundle and plist;
7. creates a compressed DMG;
8. creates a SHA-256 checksum file.

Expected artifacts:

```text
dist/FlowType-VERSION-macos-universal.dmg
dist/FlowType-VERSION-macos-universal.dmg.sha256
```

## 4. Inspect the candidate

```bash
plutil -p dist/FlowType.app/Contents/Info.plist
lipo -archs dist/FlowType.app/Contents/MacOS/FlowType
lipo -archs dist/FlowType.app/Contents/Resources/Whisper/bin/whisper-cli
otool -L dist/FlowType.app/Contents/Resources/Whisper/bin/whisper-cli
codesign --verify --deep --strict --verbose=2 dist/FlowType.app
(cd dist && shasum -a 256 -c FlowType-*-macos-universal.dmg.sha256)
```

Expected architectures:

```text
x86_64 arm64
```

Mount the DMG without browsing:

```bash
hdiutil attach -nobrowse "dist/FlowType-VERSION-macos-universal.dmg"
```

Confirm the volume contains:

```text
FlowType.app
Applications
READ ME FIRST.md
LICENSE.txt
THIRD PARTY NOTICES.md
ThirdPartyLicenses/
```

Then eject it using the exact mounted volume shown by `hdiutil`:

```bash
hdiutil detach "/Volumes/FlowType VERSION"
```

Do not use a guessed destructive path or leave a mounted candidate behind.

## 5. Perform fresh-install QA

A package is not proven by compilation alone. On a test Mac or controlled fresh local setup:

1. Copy the app from the DMG into Applications.
2. Complete the unsigned Gatekeeper flow without disabling Gatekeeper.
3. Grant Microphone, Input Monitoring, and Accessibility.
4. Select **Install Offline Model** and wait for the verified-ready status; do not install Homebrew on the test Mac.
5. Test hands-free Right Option.
6. Test held push to talk.
7. Test Escape during recording and processing.
8. Test clipboard retention and automatic paste in TextEdit plus another app.
9. Test music lowering and exact restoration.
10. Replace the app with the same candidate, quit/relaunch, and confirm settings, dictionary, and model remain without another model download.

An Intel slice can be structurally verified on Apple Silicon, but actual Intel runtime behavior requires an Intel Mac. State that gap if it was not tested.

## 6. Commit and push separately

Review the diff, version, documentation, and generated-file exclusions before committing. `dist/` stays ignored; release binaries belong on GitHub Releases, not in Git history.

Commit and push only after explicit authorization. Re-run `git status --short --branch` afterward and confirm the release commit exists on `origin/main` before publishing a release from it.

## 7. Create a draft GitHub Release

Set exact values from the verified candidate:

```bash
VERSION="0.7.0"
TAG="v$VERSION"
DMG="dist/FlowType-$VERSION-macos-universal.dmg"
CHECKSUM="$DMG.sha256"
```

Create a draft from the exact current commit:

```bash
gh release create "$TAG" "$DMG" "$CHECKSUM" \
  --draft \
  --target "$(git rev-parse HEAD)" \
  --title "FlowType $VERSION" \
  --generate-notes
```

Draft creation is an external write and requires explicit approval. A draft does not appear to the in-app latest-release checker.

Review in GitHub:

- tag and target commit;
- title and plain-language release notes;
- DMG and checksum assets;
- supported macOS version and architectures;
- unsigned/Gatekeeper warning;
- local Whisper setup link;
- known limitations.

Publish the draft only after separate approval. Publishing makes the release downloadable and makes the latest-release API return it.

## 8. Verify the public release

After publication:

```bash
gh release view "$TAG" --json tagName,name,isDraft,isPrerelease,url,assets
curl --fail --location \
  -H "Accept: application/vnd.github+json" \
  -H "X-GitHub-Api-Version: 2026-03-10" \
  "https://api.github.com/repos/jdlinventures/flowtype-macos/releases/latest"
```

Confirm:

- `isDraft` is false;
- `isPrerelease` is false for a normal update;
- the API returns the intended tag and `github.com` release URL;
- a prior installed FlowType version detects it through **Check for Updates…**;
- Download Update opens the correct public page;
- Later does not change the installation;
- Skip suppresses the automatic notice for that version;
- no update installs without user action.

## Rollback

If a published build has a serious problem:

1. Do not overwrite an existing release asset with different bytes.
2. Mark the release/practical status clearly in its notes.
3. Prepare a new patch version with a higher build number.
4. Test and publish the patch through the same runbook.
5. Tell affected users to replace the app with the prior known-good release if necessary.

User data normally remains safe because it is outside the app bundle. Never tell users to delete Application Support as a routine rollback step.

## What changes if paid signing is added later

Developer ID signing and notarization would be a new distribution/security project. It would require hardened-runtime review, stable entitlements, signed nested code, notarization, stapling, and permission-upgrade QA. A true self-installing updater could then be reconsidered.
