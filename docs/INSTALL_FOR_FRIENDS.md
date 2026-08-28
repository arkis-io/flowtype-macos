# Install FlowType on another Mac

This guide is for a friend installing FlowType, or for a coding agent helping that friend. The packaged path needs no Homebrew, CMake, source checkout, API key, account, or Terminal command for speech recognition. The remaining manual steps are macOS's unsigned-app approval and three privacy grants, which FlowType cannot legitimately bypass.

## What the person is installing

FlowType is a menu-bar dictation app for macOS 13 or later. Its default speech-to-text path is local:

```text
microphone
  → temporary recording
  → local whisper.cpp model
  → optional text cleanup
  → clipboard
  → Cmd-V into the focused app
```

The app has no FlowType account or subscription. Local Whisper transcription costs nothing per use. OpenAI, Groq, and cloud cleanup are optional and cost money only if the Mac owner deliberately configures their own API key.

FlowType source and releases use the MIT License. The license notice is included in the repository, the DMG, and the app bundle.

## Important unsigned-app limitation

FlowType is an unsigned community release in the practical Apple sense: its bundle has an ad-hoc integrity signature, but it has no paid Developer ID certificate and is not notarized by Apple.

That means:

- macOS will warn that the developer cannot be verified;
- the owner must approve this specific app under Privacy & Security;
- Microphone, Input Monitoring, and Accessibility must be granted manually;
- a later app replacement may require refreshing those privacy permissions.

Never disable Gatekeeper globally. Never use a blanket command to remove quarantine from every download. Approve only the FlowType build obtained from this repository's release page.

## Fast path: install the packaged release

### 1. Check the Mac

Open Terminal and run:

```bash
sw_vers -productVersion
uname -m
```

FlowType requires macOS 13 or newer. The universal release supports both outputs commonly shown by the second command:

- `arm64` — Apple Silicon
- `x86_64` — Intel

### 2. Download FlowType

Open the [latest FlowType release](https://github.com/jdlinventures/flowtype-macos/releases/latest) and download both files:

```text
FlowType-VERSION-macos-universal.dmg
FlowType-VERSION-macos-universal.dmg.sha256
```

If the link shows no published release, use the source-build fallback later in this guide. The release checker cannot work while the repository is private.

### 3. Verify the download

In Terminal, switch to Downloads and verify the checksum file:

```bash
cd "$HOME/Downloads"
shasum -a 256 -c FlowType-*-macos-universal.dmg.sha256
```

The expected result ends in `OK`. Stop if it reports `FAILED`, if the checksum file is missing, or if the DMG came from somewhere other than the project release page.

### 4. Copy the app into Applications

1. Double-click the DMG.
2. Drag **FlowType** onto the **Applications** shortcut.
3. Eject the FlowType disk image.
4. Open `/Applications/FlowType.app`.

If macOS blocks the first launch:

1. Leave the warning visible or click **Done**.
2. Open **System Settings → Privacy & Security**.
3. Scroll to Security and find the FlowType message.
4. Click **Open Anyway**.
5. Confirm **Open** for FlowType.

This creates an exception for this app. It does not turn off Mac security globally.

## One-click local model setup

The app already contains a self-contained `whisper.cpp` engine for Apple silicon and Intel. FlowType deliberately keeps only the large model outside the app. This makes the DMG and future updates small while preserving the model when the app is replaced.

In the Settings window that opens on first launch:

1. Find **Offline transcription** at the top of General.
2. Select **Install Offline Model**.
3. Leave FlowType open while the ~488 MB download completes.
4. Wait until the status says **installed and verified**.

That is the entire local speech-recognition setup. The download button also acts as the owner's consent to fetch the model from the official whisper.cpp model repository.

### What FlowType protects during the download

- The source URL is pinned to a specific repository revision rather than a moving `main` link.
- The expected file is exactly 487,614,201 bytes.
- Its expected SHA-256 is `c6138d6d58ecc8322097e0f987c32f1be8bb0a18532a3f88f734d1bbf9c41e5d`.
- Verification streams the file in chunks rather than loading ~488 MB into memory.
- The final model path is replaced only after both checks pass.
- Cancel, Retry, Reinstall, and Remove are available in the same Settings section.
- A failed or cancelled download cannot replace a previously working model.

The verified model is stored here:

```text
~/Library/Application Support/FlowType/models/ggml-small.en.bin
```

Do not delete the Application Support folder during an app upgrade. The model, settings, personal dictionary, and optional API keys all live there and survive replacing `FlowType.app`.

## Grant the three macOS permissions

Open FlowType Settings and select **Continue Permission Setup**. FlowType walks through one missing permission at a time:

1. **Microphone** — records only while dictation is active.
2. **Input Monitoring** — observes the global shortcut and Escape.
3. **Accessibility** — performs Cmd-V into the focused app.

macOS may terminate or relaunch FlowType after a privacy change. Reopen FlowType and continue to the next permission. The setup button reads **Permissions Ready** only when all three checks pass.

These approvals belong to the Mac owner. An installation agent can open the correct settings page, but should pause while the owner reviews and grants each permission.

## First real test

Do not consider the installation complete based only on a successful build.

1. Open TextEdit and create a plain text document.
2. Click into the document so the cursor is visible.
3. Quickly tap **Right Option**.
4. Confirm the floating pill says hands-free recording is active.
5. Say: “FlowType is working on this Mac.”
6. Tap **Right Option** again.
7. Wait for transcription and automatic paste.
8. Press Cmd-V once more to confirm the transcript stayed on the clipboard.
9. Hold **Right Option**, speak a second sentence, and release it to test push to talk.
10. Start once more and press Escape to confirm cancellation pastes nothing.

If music lowering is enabled, play audio quietly during one test and confirm the original volume returns after recording ends.

## Configure FlowType

Open Settings from the waveform icon in the menu bar.

- **General** controls the hotkeys, microphone, sounds, music lowering, clipboard behavior, and update checks.
- **Transcription** selects local, OpenAI, or Groq transcription and optional cleanup.
- **Dictionary** adds vocabulary hints and exact spelling replacements.

The default hybrid Right Option behavior is:

- quick tap: start or stop hands-free recording;
- hold and release: push to talk;
- Escape: cancel the active recording or transcription.

User files are stored here and survive app replacement:

```text
~/Library/Application Support/FlowType/config.json
~/Library/Application Support/FlowType/dictionary.txt
~/Library/Application Support/FlowType/.env
~/Library/Application Support/FlowType/models/
```

Never upload or commit `.env`. It may contain paid provider credentials.

## How updates work

When **Check GitHub for new releases automatically** is enabled, FlowType asks GitHub for the latest public release at most once every 24 hours.

- It does not upload audio, transcripts, dictionary terms, settings, or an account identifier.
- A small non-activating pill announces an available version.
- The menu bar offers **Download Update**, **Later**, and **Skip This Version**.
- Download opens the GitHub release page; FlowType never installs executable code silently.

To upgrade:

1. Download and checksum-verify the new DMG.
2. Quit FlowType from its menu-bar menu.
3. Open the DMG and drag FlowType to Applications.
4. Choose **Replace** when Finder asks.
5. Reopen FlowType and perform the short TextEdit test.
6. If the hotkey or paste stops working, refresh Input Monitoring and Accessibility for the replaced app.

Do not delete the Application Support folder during an upgrade. It contains the owner's settings, dictionary, keys, and local model.

## Troubleshooting

### Clicking FlowType appears to do nothing

FlowType is a menu-bar utility and has no Dock icon. Look for the waveform icon near the clock. Clicking FlowType in Applications should reopen Settings.

### Right Option does nothing

1. Check that **Dictation Enabled** is on.
2. Open **System Settings → Privacy & Security → Input Monitoring**.
3. Turn FlowType off and on, or remove the stale entry and add the current `/Applications/FlowType.app`.
4. Quit and reopen FlowType.
5. Test the physical key in TextEdit before changing any hotkey code.

### Recording starts but no text appears

- Confirm Microphone permission.
- Open General Settings and confirm **Offline engine: included** and **Model: installed and verified**.
- If model setup failed, select **Retry Download**. FlowType will not install an unverified file.
- Open FlowType's Transcription tab and verify the provider is **Local**.
- If the status says the audio was too quiet, check the active microphone shown in the recording pill.

### The transcript reaches the clipboard but is not pasted

Refresh FlowType under **System Settings → Privacy & Security → Accessibility**, then relaunch it. Cmd-V simulation depends on this permission.

### AirPods are connected but another microphone is used

Select the AirPods input in Control Center and leave FlowType on **Automatic — System Default**, or select the named AirPods device in Settings and click Refresh.

### macOS says the app is damaged

Stop. Re-download the DMG from the project release page and verify its checksum. Do not work around a damaged or checksum-mismatched download by disabling security protections.

## Source-build fallback

Use this if no packaged release exists or the friend wants to audit and compile the source. The repository must first be public, or the friend must have been granted private access.

```bash
git clone https://github.com/jdlinventures/flowtype-macos.git
cd flowtype-macos
brew install cmake
./scripts/test-direct.sh
./scripts/build-app.sh
```

After the tests pass:

```bash
ditto "dist/FlowType.app" "/Applications/FlowType.app"
open "/Applications/FlowType.app"
```

The source build contains the same bundled universal Whisper engine. Open FlowType, select **Install Offline Model**, grant permissions, and run the TextEdit test described above. CMake is required only for compiling that engine; it is not a runtime requirement.

## Checklist for a helping coding agent

An agent should report evidence for each item instead of saying only “installed”:

- [ ] macOS is 13 or newer.
- [ ] CPU architecture is supported by the selected release.
- [ ] DMG checksum passed, or source tests passed.
- [ ] `/Applications/FlowType.app` exists.
- [ ] The installed executable architecture was inspected with `file` or `lipo -archs`.
- [ ] The app's ad-hoc signature passes `codesign --verify --deep --strict`.
- [ ] The installed app contains a universal `Contents/Resources/Whisper/bin/whisper-cli` with no Homebrew library dependency.
- [ ] FlowType reports the local model as installed and verified.
- [ ] The owner personally reviewed all three privacy grants.
- [ ] Hands-free, push-to-talk, Escape cancellation, clipboard retention, and automatic paste were tested in a real field.
- [ ] No `.env` value was printed, uploaded, committed, or copied into chat.

The agent must not:

- disable Gatekeeper;
- delete `~/Library/Application Support/FlowType`;
- add paid API keys without authorization;
- change repository visibility, publish a release, commit, or push unless explicitly asked;
- claim global hotkeys work until a physical-key test succeeds.
