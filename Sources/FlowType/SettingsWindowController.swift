import AppKit
import AVFoundation
import Foundation
import UniformTypeIdentifiers

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    var onSave: (() -> Void)?
    var onVisibilityChange: ((Bool) -> Void)?
    var onRequestMonitorRetry: (() -> Void)?

    private let configStore: ConfigStore
    private let modelManager: LocalModelManager
    private var draft = AppConfig.defaultConfig
    private var activeTranscriptionProvider = "local"

    private let offlineEngineStatusLabel = SettingsWindowController.wrappingLabel("")
    private let offlineModelStatusLabel = SettingsWindowController.wrappingLabel("")
    private let offlineModelProgress = NSProgressIndicator()
    private let offlineModelPopup = NSPopUpButton()
    private let offlineModelButton = NSButton(title: "Install Offline Model", target: nil, action: nil)
    private let removeOfflineModelButton = NSButton(title: "Remove Model", target: nil, action: nil)

    private let enabledCheckbox = NSButton(checkboxWithTitle: "Dictation enabled", target: nil, action: nil)
    private let hotkeyPopup = NSPopUpButton()
    private let commandCheckbox = NSButton(checkboxWithTitle: "Command", target: nil, action: nil)
    private let controlCheckbox = NSButton(checkboxWithTitle: "Control", target: nil, action: nil)
    private let optionCheckbox = NSButton(checkboxWithTitle: "Option", target: nil, action: nil)
    private let shiftCheckbox = NSButton(checkboxWithTitle: "Shift", target: nil, action: nil)
    private let toggleHotkeyPopup = NSPopUpButton()
    private let toggleCommandCheckbox = NSButton(checkboxWithTitle: "Command", target: nil, action: nil)
    private let toggleControlCheckbox = NSButton(checkboxWithTitle: "Control", target: nil, action: nil)
    private let toggleOptionCheckbox = NSButton(checkboxWithTitle: "Option", target: nil, action: nil)
    private let toggleShiftCheckbox = NSButton(checkboxWithTitle: "Shift", target: nil, action: nil)
    private let hybridHotkeyCheckbox = NSButton(
        checkboxWithTitle: "Tap the push-to-talk key to start or stop hands-free recording",
        target: nil,
        action: nil
    )
    private let autoStopPopup = NSPopUpButton()
    private let restoreClipboardCheckbox = NSButton(
        checkboxWithTitle: "Restore the clipboard after pasting",
        target: nil,
        action: nil
    )
    private let automaticUpdateCheckbox = NSButton(
        checkboxWithTitle: "Check GitHub for new releases automatically",
        target: nil,
        action: nil
    )
    private let hotkeySummaryLabel = SettingsWindowController.wrappingLabel("")
    private let toggleHotkeySummaryLabel = SettingsWindowController.wrappingLabel("")
    private let permissionStatusLabel = SettingsWindowController.wrappingLabel("")
    private let permissionSetupButton = NSButton(title: "Continue Permission Setup", target: nil, action: nil)
    private let openPermissionSettingsButton = NSButton(title: "Open Permission Settings", target: nil, action: nil)
    private let feedbackSoundsCheckbox = NSButton(
        checkboxWithTitle: "Play a sound when recording starts and stops",
        target: nil,
        action: nil
    )
    private let microphonePopup = NSPopUpButton()
    private let microphoneStatusLabel = SettingsWindowController.wrappingLabel("")
    private let boostQuietSpeechCheckbox = NSButton(
        checkboxWithTitle: "Boost quiet speech after recording",
        target: nil,
        action: nil
    )
    private let preferBuiltInMicCheckbox = NSButton(
        checkboxWithTitle: "Use the Mac microphone when Bluetooth headphones are playing audio",
        target: nil,
        action: nil
    )
    private let microphoneTestButton = NSButton(title: "Test for 3 seconds", target: nil, action: nil)
    private let microphoneLevel = NSLevelIndicator()
    private let lowerOtherAudioCheckbox = NSButton(
        checkboxWithTitle: "Lower music and other audio while recording",
        target: nil,
        action: nil
    )
    private let duckingPopup = NSPopUpButton()

    private let transcriptionProviderPopup = NSPopUpButton()
    private let languageField = NSTextField(string: "")
    private let transcriptionModelField = NSTextField(string: "")
    private let executableField = NSTextField(string: "")
    private let modelPathField = NSTextField(string: "")
    private let localEngineRows = NSStackView()
    private let transcriptionStatusLabel = SettingsWindowController.wrappingLabel("")

    private let cleanupEnabledCheckbox = NSButton(
        checkboxWithTitle: "Clean punctuation and remove filler words",
        target: nil,
        action: nil
    )
    private let cleanupProviderPopup = NSPopUpButton()
    private let cleanupModelField = NSTextField(string: "")
    private let cleanupBaseURLField = NSTextField(string: "")
    private let fallbackCheckbox = NSButton(
        checkboxWithTitle: "Use the raw transcript if cleanup fails",
        target: nil,
        action: nil
    )
    private let cleanupStatusLabel = SettingsWindowController.wrappingLabel("")

    private let dictionaryTextView = NSTextView()
    private let saveStatusLabel = NSTextField(labelWithString: "")
    private var microphoneTestRecorder: AudioRecorder?
    private var microphoneTestTimer: Timer?
    private var microphoneTestMaximumLevel: Float = 0

    private static let permissionSetupAwaitingKey = "FlowTypePermissionSetupAwaiting"

    init(configStore: ConfigStore, modelManager: LocalModelManager) {
        self.configStore = configStore
        self.modelManager = modelManager

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 670),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "FlowType Settings"
        window.minSize = NSSize(width: 680, height: 580)
        window.isReleasedWhenClosed = false
        window.center()

        super.init(window: window)
        window.delegate = self
        configureControls()
        buildInterface(in: window)
        modelManager.onStateChange = { [weak self] state in
            self?.updateOfflineModelControls(state)
        }
        updateOfflineModelControls(modelManager.state)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func showSettings() {
        reloadFromDisk()
        modelManager.refresh()
        onVisibilityChange?(true)
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func startPermissionSetup() {
        showSettings()
        DispatchQueue.main.async { [weak self] in
            self?.requestPermissions()
        }
    }

    func refreshPermissionStatus() {
        let microphone: String
        let microphoneAllowed: Bool
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            microphone = "Microphone: allowed"
            microphoneAllowed = true
        case .denied, .restricted:
            microphone = "Microphone: needs permission"
            microphoneAllowed = false
        case .notDetermined:
            microphone = "Microphone: not requested yet"
            microphoneAllowed = false
        @unknown default:
            microphone = "Microphone: unknown"
            microphoneAllowed = false
        }

        let inputAllowed = Permissions.canMonitorInput
        let accessibilityAllowed = Permissions.canInsertText
        let input = inputAllowed ? "Input Monitoring: allowed" : "Input Monitoring: needs permission"
        let accessibility = accessibilityAllowed ? "Accessibility: allowed" : "Accessibility: needs permission"
        if microphoneAllowed, inputAllowed, accessibilityAllowed {
            permissionStatusLabel.stringValue = "Ready — \(microphone)  ·  \(input)  ·  \(accessibility)"
            permissionStatusLabel.textColor = .systemGreen
        } else {
            permissionStatusLabel.stringValue = "Setup required before dictation works — \(microphone)  ·  \(input)  ·  \(accessibility)"
            permissionStatusLabel.textColor = .systemRed
        }


        let step = PermissionSetupStep.next(
            microphoneAllowed: microphoneAllowed,
            inputMonitoringAllowed: inputAllowed,
            accessibilityAllowed: accessibilityAllowed
        )
        permissionSetupButton.title = step.buttonTitle
        permissionSetupButton.isEnabled = step != .ready
        openPermissionSettingsButton.title = step.settingsButtonTitle
        openPermissionSettingsButton.isHidden = step == .ready
    }

    func windowWillClose(_ notification: Notification) {
        cancelMicrophoneTest()
        onVisibilityChange?(false)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        refreshPermissionStatus()
        resumePermissionSetupIfAdvanced()
    }

    private func configureControls() {
        offlineModelProgress.style = .bar
        offlineModelProgress.minValue = 0
        offlineModelProgress.maxValue = 1
        offlineModelProgress.isIndeterminate = false
        offlineModelProgress.isHidden = true
        for specification in LocalModelSpecification.supported {
            offlineModelPopup.addItem(
                withTitle: "\(specification.displayName) (\(specification.downloadSizeLabel))"
            )
            offlineModelPopup.lastItem?.representedObject = specification.identifier
        }
        offlineModelPopup.target = self
        offlineModelPopup.action = #selector(offlineModelChanged)
        offlineModelButton.target = self
        offlineModelButton.action = #selector(offlineModelButtonPressed)
        removeOfflineModelButton.target = self
        removeOfflineModelButton.action = #selector(removeOfflineModelPressed)

        for popup in [hotkeyPopup, toggleHotkeyPopup] {
            for (title, key) in Self.hotkeyChoices {
                popup.addItem(withTitle: title)
                popup.lastItem?.representedObject = key
            }
            popup.target = self
            popup.action = #selector(hotkeyChanged)
        }

        for checkbox in [
            commandCheckbox, controlCheckbox, optionCheckbox, shiftCheckbox,
            toggleCommandCheckbox, toggleControlCheckbox, toggleOptionCheckbox, toggleShiftCheckbox
        ] {
            checkbox.target = self
            checkbox.action = #selector(hotkeyChanged)
        }

        hybridHotkeyCheckbox.target = self
        hybridHotkeyCheckbox.action = #selector(hotkeyChanged)

        feedbackSoundsCheckbox.target = self
        feedbackSoundsCheckbox.action = #selector(audioControlsChanged)
        microphonePopup.target = self
        microphonePopup.action = #selector(audioControlsChanged)
        boostQuietSpeechCheckbox.target = self
        boostQuietSpeechCheckbox.action = #selector(audioControlsChanged)
        preferBuiltInMicCheckbox.target = self
        preferBuiltInMicCheckbox.action = #selector(audioControlsChanged)
        microphoneTestButton.target = self
        microphoneTestButton.action = #selector(startMicrophoneTest)
        microphoneLevel.levelIndicatorStyle = .continuousCapacity
        microphoneLevel.minValue = 0
        microphoneLevel.maxValue = 1
        microphoneLevel.doubleValue = 0
        microphoneLevel.isEditable = false
        microphoneLevel.translatesAutoresizingMaskIntoConstraints = false
        microphoneLevel.widthAnchor.constraint(equalToConstant: 120).isActive = true
        lowerOtherAudioCheckbox.target = self
        lowerOtherAudioCheckbox.action = #selector(audioControlsChanged)
        for (title, value) in [
            ("Light — keep 65%", "min"),
            ("Medium — keep 35%", "mid"),
            ("Strong — keep 15%", "max")
        ] {
            duckingPopup.addItem(withTitle: title)
            duckingPopup.lastItem?.representedObject = value
        }
        duckingPopup.target = self
        duckingPopup.action = #selector(audioControlsChanged)

        for minutes in 1...5 {
            autoStopPopup.addItem(withTitle: minutes == 1 ? "1 minute" : "\(minutes) minutes")
            autoStopPopup.lastItem?.representedObject = NSNumber(value: minutes * 60)
        }

        configureProviderPopup(transcriptionProviderPopup)
        transcriptionProviderPopup.target = self
        transcriptionProviderPopup.action = #selector(transcriptionProviderChanged)
        configureProviderPopup(cleanupProviderPopup)
        cleanupProviderPopup.target = self
        cleanupProviderPopup.action = #selector(cleanupControlsChanged)

        cleanupEnabledCheckbox.target = self
        cleanupEnabledCheckbox.action = #selector(cleanupControlsChanged)

        dictionaryTextView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        dictionaryTextView.isRichText = false
        dictionaryTextView.isAutomaticQuoteSubstitutionEnabled = false
        dictionaryTextView.isAutomaticDashSubstitutionEnabled = false
        dictionaryTextView.isAutomaticTextReplacementEnabled = false
        dictionaryTextView.textContainerInset = NSSize(width: 10, height: 10)

        saveStatusLabel.textColor = .secondaryLabelColor
        saveStatusLabel.lineBreakMode = .byTruncatingTail
        saveStatusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    private func buildInterface(in window: NSWindow) {
        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = content

        let title = NSTextField(labelWithString: "FlowType")
        title.font = .systemFont(ofSize: 26, weight: .semibold)
        let subtitle = Self.wrappingLabel(
            "Choose how dictation starts, where speech is transcribed, and which words FlowType should recognize."
        )
        subtitle.textColor = .secondaryLabelColor

        let header = NSStackView(views: [title, subtitle])
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = 5
        header.translatesAutoresizingMaskIntoConstraints = false

        let tabs = NSTabView()
        tabs.translatesAutoresizingMaskIntoConstraints = false
        tabs.addTabViewItem(tabItem(label: "General", view: buildGeneralTab()))
        tabs.addTabViewItem(tabItem(label: "Transcription", view: buildTranscriptionTab()))
        tabs.addTabViewItem(tabItem(label: "Dictionary", view: buildDictionaryTab()))

        let reloadButton = NSButton(title: "Reload", target: self, action: #selector(reloadPressed))
        let saveButton = NSButton(title: "Save Settings", target: self, action: #selector(savePressed))
        saveButton.keyEquivalent = "\r"
        saveButton.bezelStyle = .rounded

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let footer = NSStackView(views: [saveStatusLabel, spacer, reloadButton, saveButton])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 10
        footer.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(header)
        content.addSubview(tabs)
        content.addSubview(footer)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            header.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 28),
            header.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -28),

            tabs.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 18),
            tabs.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            tabs.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            tabs.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -14),

            footer.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 28),
            footer.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -28),
            footer.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            footer.heightAnchor.constraint(greaterThanOrEqualToConstant: 30)
        ])
    }

    private func buildGeneralTab() -> NSView {
        let offlineModelButtons = NSStackView(views: [offlineModelButton, removeOfflineModelButton])
        offlineModelButtons.orientation = .horizontal
        offlineModelButtons.spacing = 8

        let modifiers = NSStackView(views: [commandCheckbox, controlCheckbox, optionCheckbox, shiftCheckbox])
        modifiers.orientation = .horizontal
        modifiers.spacing = 10

        let hotkeyControls = NSStackView(views: [hotkeyPopup, modifiers])
        hotkeyControls.orientation = .vertical
        hotkeyControls.alignment = .leading
        hotkeyControls.spacing = 8

        let toggleModifiers = NSStackView(views: [
            toggleCommandCheckbox, toggleControlCheckbox, toggleOptionCheckbox, toggleShiftCheckbox
        ])
        toggleModifiers.orientation = .horizontal
        toggleModifiers.spacing = 10

        let toggleHotkeyControls = NSStackView(views: [toggleHotkeyPopup, toggleModifiers])
        toggleHotkeyControls.orientation = .vertical
        toggleHotkeyControls.alignment = .leading
        toggleHotkeyControls.spacing = 8

        permissionSetupButton.target = self
        permissionSetupButton.action = #selector(requestPermissions)
        openPermissionSettingsButton.target = self
        openPermissionSettingsButton.action = #selector(openPrivacySettings)
        let permissionButtons = NSStackView(views: [permissionSetupButton, openPermissionSettingsButton])
        permissionButtons.orientation = .horizontal
        permissionButtons.spacing = 8

        let refreshMicrophonesButton = NSButton(
            title: "Refresh",
            target: self,
            action: #selector(refreshMicrophones)
        )
        let microphoneControls = NSStackView(views: [microphonePopup, refreshMicrophonesButton])
        microphoneControls.orientation = .horizontal
        microphoneControls.alignment = .centerY
        microphoneControls.spacing = 8

        let microphoneTestControls = NSStackView(views: [microphoneTestButton, microphoneLevel])
        microphoneTestControls.orientation = .horizontal
        microphoneTestControls.alignment = .centerY
        microphoneTestControls.spacing = 10

        return scrollingTab(views: [
            sectionTitle("Offline transcription"),
            offlineEngineStatusLabel,
            row(label: "Offline quality", control: offlineModelPopup),
            offlineModelStatusLabel,
            offlineModelProgress,
            offlineModelButtons,
            Self.helpLabel(
                "Medium English is the recommended accuracy setting. Small English is faster on older Macs. Models download once, survive app updates, work offline, and have no usage fees."
            ),
            divider(),
            sectionTitle("Dictation shortcuts"),
            enabledCheckbox,
            row(label: "Push to talk", control: hotkeyControls),
            hotkeySummaryLabel,
            hybridHotkeyCheckbox,
            row(label: "Hands-free toggle", control: toggleHotkeyControls),
            toggleHotkeySummaryLabel,
            Self.helpLabel("In hybrid mode the second shortcut is ignored. Escape always cancels the active recording or transcription."),
            divider(),
            sectionTitle("Recording feedback and voice clarity"),
            row(label: "Microphone", control: microphoneControls),
            microphoneStatusLabel,
            row(label: "Input check", control: microphoneTestControls),
            feedbackSoundsCheckbox,
            boostQuietSpeechCheckbox,
            preferBuiltInMicCheckbox,
            lowerOtherAudioCheckbox,
            row(label: "Lowering strength", control: duckingPopup),
            Self.helpLabel(
                "Music lowering is independent from the microphone and restores the exact previous output volume after stop, Escape, or quit. Unsupported HDMI or USB outputs are skipped safely."
            ),
            divider(),
            sectionTitle("Safety and clipboard"),
            row(label: "Automatic stop", control: autoStopPopup),
            Self.helpLabel("Hands-free recording always stops at five minutes or sooner."),
            restoreClipboardCheckbox,
            Self.helpLabel(
                "Off leaves the finished transcript on your clipboard. On restores whatever was copied before dictation."
            ),
            automaticUpdateCheckbox,
            Self.helpLabel(
                "Checks at most once every 24 hours. FlowType only notifies you; downloads and installation always require your choice."
            ),
            divider(),
            sectionTitle("macOS permissions"),
            permissionStatusLabel,
            permissionButtons,
            Self.helpLabel(
                "Input Monitoring reads the shortcuts. Accessibility performs Cmd-V. Microphone records only while dictating."
            )
        ])
    }

    private func buildTranscriptionTab() -> NSView {
        let chooseExecutable = NSButton(title: "Choose…", target: self, action: #selector(chooseExecutable))
        let executableControls = pathControls(field: executableField, button: chooseExecutable)
        let chooseModel = NSButton(title: "Choose…", target: self, action: #selector(chooseModel))
        let modelControls = pathControls(field: modelPathField, button: chooseModel)

        localEngineRows.orientation = .vertical
        localEngineRows.alignment = .leading
        localEngineRows.spacing = 10
        localEngineRows.addArrangedSubview(row(label: "whisper.cpp app", control: executableControls))
        localEngineRows.addArrangedSubview(row(label: "Whisper model", control: modelControls))

        let openEnvironmentButton = NSButton(
            title: "Open API Key File (.env)",
            target: self,
            action: #selector(openEnvironment)
        )

        return scrollingTab(views: [
            sectionTitle("Speech recognition"),
            row(label: "Transcription provider", control: transcriptionProviderPopup),
            row(label: "Language code", control: languageField),
            row(label: "Cloud model", control: transcriptionModelField),
            localEngineRows,
            transcriptionStatusLabel,
            divider(),
            sectionTitle("Optional AI cleanup"),
            cleanupEnabledCheckbox,
            row(label: "Cleanup provider", control: cleanupProviderPopup),
            row(label: "Cleanup model", control: cleanupModelField),
            row(label: "OpenAI-compatible URL", control: cleanupBaseURLField),
            fallbackCheckbox,
            cleanupStatusLabel,
            openEnvironmentButton,
            Self.helpLabel(
                "API keys stay in the protected .env file and are never displayed here. Local Whisper does not need a key."
            )
        ])
    }

    private func buildDictionaryTab() -> NSView {
        let container = NSView()
        let explanation = Self.wrappingLabel(
            "Add one preferred spelling per line to guide recognition. Use “heard words => Preferred Spelling” for exact replacements. Lines beginning with # are notes."
        )
        explanation.textColor = .secondaryLabelColor
        explanation.translatesAutoresizingMaskIntoConstraints = false

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.borderType = .bezelBorder
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.documentView = dictionaryTextView

        container.addSubview(explanation)
        container.addSubview(scroll)
        NSLayoutConstraint.activate([
            explanation.topAnchor.constraint(equalTo: container.topAnchor, constant: 22),
            explanation.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 22),
            explanation.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -22),
            scroll.topAnchor.constraint(equalTo: explanation.bottomAnchor, constant: 14),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 22),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -22),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -22)
        ])
        return container
    }

    private func scrollingTab(views: [NSView]) -> NSView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false

        let document = SettingsDocumentView()
        document.translatesAutoresizingMaskIntoConstraints = false
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        scroll.documentView = document

        let followViewportWidth = document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor)
        followViewportWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            followViewportWidth,
            document.widthAnchor.constraint(greaterThanOrEqualToConstant: 620),
            stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 22),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 22),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -22),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -22)
        ])
        for case let separator as NSBox in views where separator.boxType == .separator {
            separator.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        return scroll
    }

    private func row(label: String, control: NSView) -> NSView {
        let title = NSTextField(labelWithString: label)
        title.textColor = .secondaryLabelColor
        title.alignment = .right
        title.translatesAutoresizingMaskIntoConstraints = false
        title.widthAnchor.constraint(equalToConstant: 160).isActive = true

        let row = NSStackView(views: [title, control])
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 12
        row.setHuggingPriority(.defaultLow, for: .horizontal)
        control.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return row
    }

    private func pathControls(field: NSTextField, button: NSButton) -> NSView {
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(greaterThanOrEqualToConstant: 360).isActive = true
        let stack = NSStackView(views: [field, button])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        return stack
    }

    private func divider() -> NSView {
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return separator
    }

    private func sectionTitle(_ value: String) -> NSTextField {
        let field = NSTextField(labelWithString: value)
        field.font = .systemFont(ofSize: 15, weight: .semibold)
        return field
    }

    private func tabItem(label: String, view: NSView) -> NSTabViewItem {
        let item = NSTabViewItem(identifier: label)
        item.label = label
        item.view = view
        return item
    }

    private func configureProviderPopup(_ popup: NSPopUpButton) {
        for (title, value) in [("Local", "local"), ("OpenAI", "openai"), ("Groq", "groq")] {
            popup.addItem(withTitle: title)
            popup.lastItem?.representedObject = value
        }
    }

    @objc private func hotkeyChanged() {
        updateHotkeyControls()
    }

    @objc private func audioControlsChanged() {
        if microphoneTestRecorder != nil {
            cancelMicrophoneTest()
        }
        updateAudioControls()
    }

    @objc private func refreshMicrophones() {
        populateMicrophonePopup()
        updateAudioControls()
    }

    @objc private func offlineModelChanged() {
        guard let identifier = selectedValue(in: offlineModelPopup),
              let specification = LocalModelSpecification.supported.first(where: {
                  $0.identifier == identifier
              }) else { return }
        modelManager.select(specification)
        let path = "~/Library/Application Support/FlowType/models/\(specification.filename)"
        draft.transcription.localModelPath = path
        modelPathField.stringValue = path
        updateOfflineModelControls(modelManager.state)
    }

    @objc private func transcriptionProviderChanged() {
        stashTranscriptionModel(for: activeTranscriptionProvider)
        activeTranscriptionProvider = selectedValue(in: transcriptionProviderPopup) ?? "local"
        loadTranscriptionModel(for: activeTranscriptionProvider)
        updateTranscriptionControls()
    }

    @objc private func offlineModelButtonPressed() {
        switch modelManager.state {
        case .downloading:
            modelManager.cancelDownload()
        case .verifying:
            break
        case .notInstalled, .ready, .failed:
            modelManager.install()
        }
    }

    @objc private func removeOfflineModelPressed() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Remove the offline model?"
        alert.informativeText = "Local transcription will stop working until you install \(modelManager.specification.displayName) again. FlowType itself and your other settings will remain installed."
        alert.addButton(withTitle: "Remove Model")
        alert.addButton(withTitle: "Keep Model")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        do {
            try modelManager.removeInstalledModel()
            updateProviderStatus()
        } catch {
            offlineModelStatusLabel.stringValue = "Could not remove the model: \(error.localizedDescription)"
            offlineModelStatusLabel.textColor = .systemRed
        }
    }

    @objc private func cleanupControlsChanged() {
        updateCleanupControls()
    }

    @objc private func startMicrophoneTest() {
        if microphoneTestRecorder != nil {
            cancelMicrophoneTest()
            microphoneStatusLabel.stringValue = "Microphone test stopped."
            microphoneStatusLabel.textColor = .secondaryLabelColor
            return
        }

        var audioConfig = draft.audio
        audioConfig.inputDeviceUID = selectedValue(in: microphonePopup) ?? AudioDeviceService.systemDefaultUID
        audioConfig.inputDeviceName = audioConfig.inputDeviceUID == AudioDeviceService.systemDefaultUID
            ? ""
            : AudioDeviceService.inputDevice(withUID: audioConfig.inputDeviceUID)?.name
                ?? draft.audio.inputDeviceName
        audioConfig.preferBuiltInMicWithBluetoothOutput = preferBuiltInMicCheckbox.state == .on

        let recorder = AudioRecorder()
        do {
            try recorder.start(config: audioConfig)
            microphoneTestRecorder = recorder
            microphoneTestMaximumLevel = 0
            microphoneLevel.doubleValue = 0
            microphoneTestButton.title = "Stop test"
            microphoneStatusLabel.stringValue = "Listening through \(recorder.activeInputDeviceName)… speak normally."
            microphoneStatusLabel.textColor = .labelColor
            microphoneTestTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, let recorder = self.microphoneTestRecorder else { return }
                    let level = recorder.normalizedInputLevel
                    self.microphoneTestMaximumLevel = max(self.microphoneTestMaximumLevel, level)
                    self.microphoneLevel.doubleValue = Double(level)
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self, weak recorder] in
                guard let self, self.microphoneTestRecorder === recorder else { return }
                self.finishMicrophoneTest()
            }
        } catch {
            microphoneStatusLabel.stringValue = error.localizedDescription
            microphoneStatusLabel.textColor = .systemRed
            microphoneLevel.doubleValue = 0
        }
    }

    @objc private func reloadPressed() {
        reloadFromDisk()
    }

    @objc private func savePressed() {
        do {
            try captureDraftFromControls()
            try configStore.save(draft, dictionaryContents: dictionaryTextView.string)
            saveStatusLabel.stringValue = "Saved and applied"
            saveStatusLabel.textColor = .systemGreen
            onSave?()
            updateProviderStatus()
        } catch {
            saveStatusLabel.stringValue = error.localizedDescription
            saveStatusLabel.textColor = .systemRed
            NSSound.beep()
        }
    }

    @objc private func requestPermissions() {
        let step = currentPermissionSetupStep
        switch step {
        case .microphone:
            Permissions.requestMicrophone { [weak self] granted in
                Task { @MainActor in
                    guard let self else { return }
                    self.refreshPermissionStatus()
                    if granted {
                        self.requestPermissions()
                    } else {
                        self.openPrivacyPane(for: .microphone)
                    }
                }
            }

        case .inputMonitoring:
            if Permissions.requestInputMonitoring() {
                refreshPermissionStatus()
                requestPermissions()
            } else {
                openPrivacyPane(for: .inputMonitoring)
            }

        case .accessibility:
            if Permissions.requestAccessibility() {
                refreshPermissionStatus()
                requestPermissions()
            } else {
                openPrivacyPane(for: .accessibility)
            }

        case .ready:
            clearPermissionSetupResumeState()
            refreshPermissionStatus()
            onRequestMonitorRetry?()
        }
    }

    @objc private func openPrivacySettings() {
        openPrivacyPane(for: currentPermissionSetupStep)
    }

    private func openPrivacyPane(for step: PermissionSetupStep) {
        guard let anchor = step.settingsAnchor,
              let url = URL(
                string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)"
              ) else { return }
        UserDefaults.standard.set(step.rawValue, forKey: Self.permissionSetupAwaitingKey)
        NSWorkspace.shared.open(url)
        refreshPermissionStatus()
    }

    private var currentPermissionSetupStep: PermissionSetupStep {
        PermissionSetupStep.next(
            microphoneAllowed: Permissions.canRecordAudio,
            inputMonitoringAllowed: Permissions.canMonitorInput,
            accessibilityAllowed: Permissions.canInsertText
        )
    }

    private func resumePermissionSetupIfAdvanced() {
        guard let rawStep = UserDefaults.standard.string(forKey: Self.permissionSetupAwaitingKey),
              let awaitedStep = PermissionSetupStep(rawValue: rawStep) else { return }

        let currentStep = currentPermissionSetupStep
        guard currentStep != awaitedStep else { return }
        clearPermissionSetupResumeState()

        if currentStep == .ready {
            onRequestMonitorRetry?()
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.requestPermissions()
            }
        }
    }

    private func clearPermissionSetupResumeState() {
        UserDefaults.standard.removeObject(forKey: Self.permissionSetupAwaitingKey)
    }

    @objc private func openEnvironment() {
        NSWorkspace.shared.open(configStore.environmentURL)
    }

    @objc private func chooseExecutable() {
        chooseFile(currentPath: executableField.stringValue, allowedExtensions: nil) { [weak self] path in
            self?.executableField.stringValue = path
            self?.updateProviderStatus()
        }
    }

    @objc private func chooseModel() {
        chooseFile(currentPath: modelPathField.stringValue, allowedExtensions: ["bin"]) { [weak self] path in
            self?.modelPathField.stringValue = path
            self?.updateProviderStatus()
        }
    }

    private func chooseFile(
        currentPath: String,
        allowedExtensions: [String]?,
        completion: @escaping (String) -> Void
    ) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        if let allowedExtensions {
            panel.allowedContentTypes = allowedExtensions.compactMap { UTType(filenameExtension: $0) }
        }
        let expanded = currentPath.expandingTildeInPath
        if !expanded.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: expanded).deletingLastPathComponent()
        }
        panel.beginSheetModal(for: window!) { response in
            guard response == .OK, let url = panel.url else { return }
            completion(url.path)
        }
    }

    private func reloadFromDisk() {
        do {
            draft = try configStore.load()
            populateControls()
            saveStatusLabel.stringValue = "Settings are loaded from this Mac"
            saveStatusLabel.textColor = .secondaryLabelColor
        } catch {
            saveStatusLabel.stringValue = error.localizedDescription
            saveStatusLabel.textColor = .systemRed
        }
    }

    private func populateControls() {
        enabledCheckbox.state = draft.enabled ? .on : .off
        populateShortcut(
            draft.hotkey,
            popup: hotkeyPopup,
            checkboxes: [commandCheckbox, controlCheckbox, optionCheckbox, shiftCheckbox]
        )
        populateShortcut(
            draft.toggleHotkey,
            popup: toggleHotkeyPopup,
            checkboxes: [toggleCommandCheckbox, toggleControlCheckbox, toggleOptionCheckbox, toggleShiftCheckbox]
        )
        hybridHotkeyCheckbox.state = draft.gestures.hybridPrimaryHotkey ? .on : .off
        select(number: draft.gestures.maxRecordingSeconds, in: autoStopPopup)
        restoreClipboardCheckbox.state = draft.clipboard.restorePrevious ? .on : .off
        automaticUpdateCheckbox.state = draft.updates.checkAutomatically ? .on : .off
        feedbackSoundsCheckbox.state = draft.audio.feedbackSoundsEnabled ? .on : .off
        boostQuietSpeechCheckbox.state = draft.audio.boostQuietSpeechEnabled ? .on : .off
        preferBuiltInMicCheckbox.state = draft.audio.preferBuiltInMicWithBluetoothOutput ? .on : .off
        lowerOtherAudioCheckbox.state = draft.audio.lowerOtherAudioEnabled ? .on : .off
        let savedDuckingLevel = draft.audio.duckingLevel.lowercased()
        select(value: savedDuckingLevel == "default" ? "mid" : savedDuckingLevel, in: duckingPopup)
        populateMicrophonePopup()

        activeTranscriptionProvider = draft.transcription.provider.lowercased()
        select(value: activeTranscriptionProvider, in: transcriptionProviderPopup)
        languageField.stringValue = draft.transcription.language
        executableField.stringValue = draft.transcription.localExecutable
        modelPathField.stringValue = draft.transcription.localModelPath
        let localSpecification = LocalModelSpecification.matching(
            path: draft.transcription.localModelPath
        ) ?? .mediumEnglish
        modelManager.select(localSpecification)
        select(value: localSpecification.identifier, in: offlineModelPopup)
        loadTranscriptionModel(for: activeTranscriptionProvider)

        cleanupEnabledCheckbox.state = draft.cleanup.enabled ? .on : .off
        select(value: draft.cleanup.provider.lowercased(), in: cleanupProviderPopup)
        cleanupModelField.stringValue = draft.cleanup.model
        cleanupBaseURLField.stringValue = draft.cleanup.baseURL
        fallbackCheckbox.state = draft.cleanup.fallbackToRawOnError ? .on : .off

        dictionaryTextView.string = configStore.loadDictionary(for: draft)
        updateHotkeyControls()
        updateAudioControls()
        updateTranscriptionControls()
        updateCleanupControls()
        refreshPermissionStatus()
    }

    private func captureDraftFromControls() throws {
        draft.enabled = enabledCheckbox.state == .on
        draft.hotkey = shortcut(
            from: hotkeyPopup,
            checkboxes: [commandCheckbox, controlCheckbox, optionCheckbox, shiftCheckbox]
        )
        draft.toggleHotkey = shortcut(
            from: toggleHotkeyPopup,
            checkboxes: [toggleCommandCheckbox, toggleControlCheckbox, toggleOptionCheckbox, toggleShiftCheckbox]
        )
        draft.gestures.hybridPrimaryHotkey = hybridHotkeyCheckbox.state == .on
        draft.gestures.maxRecordingSeconds = selectedNumber(in: autoStopPopup) ?? 300
        draft.clipboard.restorePrevious = restoreClipboardCheckbox.state == .on
        draft.updates.checkAutomatically = automaticUpdateCheckbox.state == .on
        draft.audio.feedbackSoundsEnabled = feedbackSoundsCheckbox.state == .on
        draft.audio.voiceProcessingEnabled = false
        draft.audio.boostQuietSpeechEnabled = boostQuietSpeechCheckbox.state == .on
        draft.audio.preferBuiltInMicWithBluetoothOutput = preferBuiltInMicCheckbox.state == .on
        draft.audio.lowerOtherAudioEnabled = lowerOtherAudioCheckbox.state == .on
        draft.audio.duckingLevel = selectedValue(in: duckingPopup) ?? "mid"
        draft.audio.inputDeviceUID = selectedValue(in: microphonePopup) ?? AudioDeviceService.systemDefaultUID
        draft.audio.inputDeviceName = draft.audio.inputDeviceUID == AudioDeviceService.systemDefaultUID
            ? ""
            : AudioDeviceService.inputDevice(withUID: draft.audio.inputDeviceUID)?.name
                ?? draft.audio.inputDeviceName

        stashTranscriptionModel(for: activeTranscriptionProvider)
        draft.transcription.provider = selectedValue(in: transcriptionProviderPopup) ?? "local"
        draft.transcription.language = languageField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.transcription.localExecutable = executableField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.transcription.localModelPath = modelPathField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)

        draft.cleanup.enabled = cleanupEnabledCheckbox.state == .on
        draft.cleanup.provider = selectedValue(in: cleanupProviderPopup) ?? "openai"
        draft.cleanup.model = cleanupModelField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.cleanup.baseURL = cleanupBaseURLField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.cleanup.fallbackToRawOnError = fallbackCheckbox.state == .on

        try SettingsValidator.validate(draft)
    }

    private func updateHotkeyControls() {
        updateShortcutControls(
            popup: hotkeyPopup,
            checkboxes: [commandCheckbox, controlCheckbox, optionCheckbox, shiftCheckbox],
            summary: hotkeySummaryLabel,
            mode: .pushToTalk
        )
        updateShortcutControls(
            popup: toggleHotkeyPopup,
            checkboxes: [toggleCommandCheckbox, toggleControlCheckbox, toggleOptionCheckbox, toggleShiftCheckbox],
            summary: toggleHotkeySummaryLabel,
            mode: .handsFreeToggle
        )

        let usesHybridKey = hybridHotkeyCheckbox.state == .on
        toggleHotkeyPopup.isEnabled = !usesHybridKey
        for checkbox in [
            toggleCommandCheckbox, toggleControlCheckbox, toggleOptionCheckbox, toggleShiftCheckbox
        ] {
            checkbox.isEnabled = !usesHybridKey && !Self.standaloneHotkeyKeys.contains(
                selectedValue(in: toggleHotkeyPopup) ?? "fn"
            )
        }
        toggleHotkeySummaryLabel.textColor = usesHybridKey ? .tertiaryLabelColor : .secondaryLabelColor
        if usesHybridKey {
            toggleHotkeySummaryLabel.stringValue = "Not needed — a quick tap of the push-to-talk key controls hands-free mode."
        }
    }

    private func updateAudioControls() {
        duckingPopup.isEnabled = lowerOtherAudioCheckbox.state == .on
        updateMicrophoneStatus()
    }

    private func updateOfflineModelControls(_ state: LocalModelState) {
        let bundledEngineURL = Bundle.main.resourceURL?
            .appendingPathComponent("Whisper/bin/whisper-cli")
        if let bundledEngineURL,
           FileManager.default.isExecutableFile(atPath: bundledEngineURL.path) {
            offlineEngineStatusLabel.stringValue = "Offline engine: included for Apple silicon and Intel Macs"
            offlineEngineStatusLabel.textColor = .systemGreen
        } else {
            offlineEngineStatusLabel.stringValue = "Offline engine: missing from this app build"
            offlineEngineStatusLabel.textColor = .systemRed
        }

        offlineModelProgress.isHidden = true
        offlineModelProgress.isIndeterminate = false
        removeOfflineModelButton.isHidden = !modelManager.isInstalled
        offlineModelButton.isEnabled = true
        offlineModelPopup.isEnabled = true
        let selectedModelName = modelManager.specification.displayName

        switch state {
        case .notInstalled:
            offlineModelStatusLabel.stringValue = "\(selectedModelName): not installed"
            offlineModelStatusLabel.textColor = .systemOrange
            offlineModelButton.title = "Install \(selectedModelName.replacingOccurrences(of: "Recommended — ", with: "").replacingOccurrences(of: "Fast — ", with: ""))"
        case .downloading(let fraction):
            let percent = Int((fraction * 100).rounded())
            offlineModelStatusLabel.stringValue = "Downloading \(selectedModelName)… \(percent)%"
            offlineModelStatusLabel.textColor = .labelColor
            offlineModelProgress.doubleValue = fraction
            offlineModelProgress.isHidden = false
            offlineModelButton.title = "Cancel Download"
            removeOfflineModelButton.isHidden = true
            offlineModelPopup.isEnabled = false
        case .verifying:
            offlineModelStatusLabel.stringValue = "Verifying \(selectedModelName) before installation…"
            offlineModelStatusLabel.textColor = .labelColor
            offlineModelProgress.isIndeterminate = true
            offlineModelProgress.isHidden = false
            offlineModelProgress.startAnimation(nil)
            offlineModelButton.title = "Verifying…"
            offlineModelButton.isEnabled = false
            removeOfflineModelButton.isHidden = true
            offlineModelPopup.isEnabled = false
        case .ready:
            offlineModelStatusLabel.stringValue = "\(selectedModelName): installed and verified — ready for private, $0 local transcription"
            offlineModelStatusLabel.textColor = .systemGreen
            offlineModelButton.title = "Reinstall \(selectedModelName.replacingOccurrences(of: "Recommended — ", with: "").replacingOccurrences(of: "Fast — ", with: ""))"
        case .failed(let message):
            offlineModelStatusLabel.stringValue = "Model setup failed: \(message)"
            offlineModelStatusLabel.textColor = .systemRed
            offlineModelButton.title = "Retry Download"
        }
        if case .verifying = state {} else {
            offlineModelProgress.stopAnimation(nil)
        }
        if case .downloading = state {
            // Avoid re-reading config and .env on every progress tick.
        } else {
            updateProviderStatus()
        }
    }

    private func populateMicrophonePopup() {
        let selectedUID = draft.audio.inputDeviceUID
        let devices = AudioDeviceService.inputDevices()
        let defaultName = AudioDeviceService.defaultInputDevice()?.name ?? "Unavailable"

        microphonePopup.removeAllItems()
        microphonePopup.addItem(withTitle: "Automatic — System Default (\(defaultName))")
        microphonePopup.lastItem?.representedObject = AudioDeviceService.systemDefaultUID

        for device in devices {
            microphonePopup.addItem(withTitle: device.name)
            microphonePopup.lastItem?.representedObject = device.uid
        }

        if selectedUID != AudioDeviceService.systemDefaultUID,
           !devices.contains(where: { $0.uid == selectedUID }) {
            let savedName = draft.audio.inputDeviceName.isEmpty ? "Saved microphone" : draft.audio.inputDeviceName
            microphonePopup.addItem(withTitle: "Unavailable — \(savedName)")
            microphonePopup.lastItem?.representedObject = selectedUID
        }

        select(value: selectedUID, in: microphonePopup)
        if selectedValue(in: microphonePopup) == nil {
            select(value: AudioDeviceService.systemDefaultUID, in: microphonePopup)
        }
        updateMicrophoneStatus()
    }

    private func updateMicrophoneStatus() {
        let selectedUID = selectedValue(in: microphonePopup) ?? AudioDeviceService.systemDefaultUID
        var audioConfig = draft.audio
        audioConfig.inputDeviceUID = selectedUID
        audioConfig.inputDeviceName = selectedUID == AudioDeviceService.systemDefaultUID
            ? ""
            : AudioDeviceService.inputDevice(withUID: selectedUID)?.name ?? draft.audio.inputDeviceName
        audioConfig.preferBuiltInMicWithBluetoothOutput = preferBuiltInMicCheckbox.state == .on

        do {
            let plan = try AudioDeviceService.capturePlan(for: audioConfig)
            if plan.reason == .avoidedBluetoothHeadsetMic {
                let outputName = AudioDeviceService.defaultOutputDevice()?.name ?? "Bluetooth headphones"
                microphoneStatusLabel.stringValue =
                    "\(outputName) is playing audio, so FlowType will record with \(plan.input.name) for clearer speech."
                microphoneStatusLabel.textColor = .systemGreen
            } else if plan.input.isBluetooth {
                microphoneStatusLabel.stringValue =
                    "\(plan.input.name) is selected. Bluetooth microphone mode can reduce music quality and transcription accuracy."
                microphoneStatusLabel.textColor = .systemOrange
            } else if selectedUID == AudioDeviceService.systemDefaultUID {
                microphoneStatusLabel.stringValue =
                    "Automatic currently resolves to \(plan.input.name) and is checked again before every recording."
                microphoneStatusLabel.textColor = .secondaryLabelColor
            } else {
                microphoneStatusLabel.stringValue =
                    "FlowType will record directly from \(plan.input.name) without changing the Mac's global microphone."
                microphoneStatusLabel.textColor = .systemGreen
            }
        } catch {
            microphoneStatusLabel.stringValue = error.localizedDescription
            microphoneStatusLabel.textColor = .systemRed
        }
    }

    private func finishMicrophoneTest() {
        microphoneTestTimer?.invalidate()
        microphoneTestTimer = nil
        microphoneTestButton.isEnabled = false
        guard let recorder = microphoneTestRecorder else { return }
        let maximumLevel = microphoneTestMaximumLevel

        Task { @MainActor [weak self, weak recorder] in
            guard let self, let recorder else { return }
            do {
                let sourceURL = try await recorder.stop()
                try? FileManager.default.removeItem(at: sourceURL.deletingLastPathComponent())
                guard self.microphoneTestRecorder === recorder else { return }
                self.microphoneTestRecorder = nil
                self.microphoneTestButton.title = "Test for 3 seconds"
                self.microphoneTestButton.isEnabled = true
                if maximumLevel >= 0.08 {
                    self.microphoneStatusLabel.stringValue =
                        "Microphone test passed — \(recorder.activeInputDeviceName) delivered a healthy signal."
                    self.microphoneStatusLabel.textColor = .systemGreen
                } else {
                    self.microphoneStatusLabel.stringValue =
                        "The microphone opened, but the signal stayed very low. Move closer, check the input level, or choose another microphone."
                    self.microphoneStatusLabel.textColor = .systemOrange
                }
            } catch is CancellationError {
                // A close, setting change, or second button press intentionally stopped the test.
            } catch {
                guard self.microphoneTestRecorder === recorder else { return }
                self.microphoneTestRecorder = nil
                self.microphoneTestButton.title = "Test for 3 seconds"
                self.microphoneTestButton.isEnabled = true
                self.microphoneStatusLabel.stringValue = error.localizedDescription
                self.microphoneStatusLabel.textColor = .systemRed
            }
        }
    }

    private func cancelMicrophoneTest() {
        microphoneTestTimer?.invalidate()
        microphoneTestTimer = nil
        microphoneTestRecorder?.cancel()
        microphoneTestRecorder = nil
        microphoneTestMaximumLevel = 0
        microphoneLevel.doubleValue = 0
        microphoneTestButton.title = "Test for 3 seconds"
        microphoneTestButton.isEnabled = true
    }

    private enum ShortcutMode {
        case pushToTalk
        case handsFreeToggle
    }

    private func updateShortcutControls(
        popup: NSPopUpButton,
        checkboxes: [NSButton],
        summary: NSTextField,
        mode: ShortcutMode
    ) {
        let key = selectedValue(in: popup) ?? "fn"
        let isStandalone = Self.standaloneHotkeyKeys.contains(key)
        for checkbox in checkboxes {
            checkbox.isEnabled = !isStandalone
            if isStandalone { checkbox.state = .off }
        }

        let modifierNames = ["Command", "Control", "Option", "Shift"]
        let modifiers = zip(checkboxes, modifierNames).compactMap { checkbox, name in
            checkbox.state == .on ? name : nil
        }
        let joined = (modifiers + [popup.titleOfSelectedItem ?? key]).joined(separator: " + ")
        switch mode {
        case .pushToTalk:
            if hybridHotkeyCheckbox.state == .on {
                summary.stringValue = "Tap \(joined) to start or stop hands-free recording. Hold it while speaking for push to talk."
            } else {
                summary.stringValue = "Hold \(joined) while speaking, then release to transcribe and paste. Double-tap also enters hands-free mode."
            }
        case .handsFreeToggle:
            summary.stringValue = "Tap \(joined) once to start hands-free recording; tap it again to stop, transcribe, and paste."
        }
    }

    private func populateShortcut(_ hotkey: HotkeyConfig, popup: NSPopUpButton, checkboxes: [NSButton]) {
        select(value: normalizedHotkeyKey(hotkey.key), in: popup)
        let modifiers = Set(hotkey.modifiers.map(normalizedModifier))
        let names = ["command", "control", "option", "shift"]
        for (checkbox, name) in zip(checkboxes, names) {
            checkbox.state = modifiers.contains(name) ? .on : .off
        }
    }

    private func shortcut(from popup: NSPopUpButton, checkboxes: [NSButton]) -> HotkeyConfig {
        let key = selectedValue(in: popup) ?? "fn"
        guard !Self.standaloneHotkeyKeys.contains(key) else {
            return HotkeyConfig(key: key, modifiers: [])
        }
        let names = ["command", "control", "option", "shift"]
        let modifiers = zip(checkboxes, names).compactMap { checkbox, name in
            checkbox.state == .on ? name : nil
        }
        return HotkeyConfig(key: key, modifiers: modifiers)
    }

    private func updateTranscriptionControls() {
        let provider = selectedValue(in: transcriptionProviderPopup) ?? "local"
        let isLocal = provider == "local"
        localEngineRows.isHidden = !isLocal
        transcriptionModelField.isEnabled = !isLocal
        updateProviderStatus()
    }

    private func updateCleanupControls() {
        let enabled = cleanupEnabledCheckbox.state == .on
        cleanupProviderPopup.isEnabled = enabled
        cleanupModelField.isEnabled = enabled
        cleanupBaseURLField.isEnabled = enabled
        fallbackCheckbox.isEnabled = enabled
        updateProviderStatus()
    }

    private func updateProviderStatus() {
        let environment = configStore.loadEnvironment()
        let transcriptionProvider = selectedValue(in: transcriptionProviderPopup) ?? "local"
        switch transcriptionProvider {
        case "local":
            let path = modelPathField.stringValue.expandingTildeInPath
            let modelDescription = fileDescription(atPath: path)
            let modelExists = FileManager.default.fileExists(atPath: path)
            transcriptionStatusLabel.stringValue =
                "Local whisper.cpp · $0 per dictation · audio stays on this Mac. \(modelDescription)"
            transcriptionStatusLabel.textColor = modelExists ? .systemGreen : .systemOrange
        case "openai":
            let configured = hasKey("OPENAI_API_KEY", in: environment)
            transcriptionStatusLabel.stringValue = configured
                ? "OpenAI API key configured · usage is billed by OpenAI · audio is sent to OpenAI."
                : "OpenAI API key is missing. Add OPENAI_API_KEY to .env before using this provider."
            transcriptionStatusLabel.textColor = configured ? .systemOrange : .systemRed
        default:
            let configured = hasKey("GROQ_API_KEY", in: environment)
            transcriptionStatusLabel.stringValue = configured
                ? "Groq API key configured · usage is billed by Groq · audio is sent to Groq."
                : "Groq API key is missing. Add GROQ_API_KEY to .env before using this provider."
            transcriptionStatusLabel.textColor = configured ? .systemOrange : .systemRed
        }

        guard cleanupEnabledCheckbox.state == .on else {
            cleanupStatusLabel.stringValue = "AI cleanup is off. FlowType will use the raw Whisper transcript."
            cleanupStatusLabel.textColor = .secondaryLabelColor
            return
        }

        let cleanupProvider = selectedValue(in: cleanupProviderPopup) ?? "openai"
        let keyConfigured: Bool
        switch cleanupProvider {
        case "groq":
            keyConfigured = hasKey("LLM_API_KEY", in: environment) || hasKey("GROQ_API_KEY", in: environment)
        case "openai":
            keyConfigured = hasKey("LLM_API_KEY", in: environment) || hasKey("OPENAI_API_KEY", in: environment)
        default:
            keyConfigured = true
        }

        if cleanupProvider == "local" {
            cleanupStatusLabel.stringValue = "Local cleanup expects an OpenAI-compatible server at the URL above."
            cleanupStatusLabel.textColor = .systemGreen
        } else if keyConfigured {
            cleanupStatusLabel.stringValue = "Cleanup key configured · each cleanup request may incur provider usage charges."
            cleanupStatusLabel.textColor = .systemOrange
        } else if fallbackCheckbox.state == .on {
            cleanupStatusLabel.stringValue = "No cleanup key configured. FlowType currently falls back to the raw transcript at no cost."
            cleanupStatusLabel.textColor = .secondaryLabelColor
        } else {
            cleanupStatusLabel.stringValue = "No cleanup key configured. Dictation will fail unless you add a key or enable fallback."
            cleanupStatusLabel.textColor = .systemRed
        }
    }

    private func loadTranscriptionModel(for provider: String) {
        switch provider {
        case "openai": transcriptionModelField.stringValue = draft.transcription.openAIModel
        case "groq": transcriptionModelField.stringValue = draft.transcription.groqModel
        default: transcriptionModelField.stringValue = "Not used for local transcription"
        }
    }

    private func stashTranscriptionModel(for provider: String) {
        let value = transcriptionModelField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, provider != "local" else { return }
        if provider == "openai" {
            draft.transcription.openAIModel = value
        } else if provider == "groq" {
            draft.transcription.groqModel = value
        }
    }

    private func fileDescription(atPath path: String) -> String {
        guard FileManager.default.fileExists(atPath: path),
              let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attributes[.size] as? NSNumber else {
            return "The selected model file was not found."
        }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return "Model: \(URL(fileURLWithPath: path).lastPathComponent) (\(formatter.string(fromByteCount: size.int64Value)))."
    }

    private func hasKey(_ key: String, in environment: [String: String]) -> Bool {
        guard let value = environment[key] else { return false }
        return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func selectedValue(in popup: NSPopUpButton) -> String? {
        popup.selectedItem?.representedObject as? String
    }

    private func selectedNumber(in popup: NSPopUpButton) -> Int? {
        (popup.selectedItem?.representedObject as? NSNumber)?.intValue
    }

    private func select(value: String, in popup: NSPopUpButton) {
        if let index = popup.itemArray.firstIndex(where: { ($0.representedObject as? String) == value }) {
            popup.selectItem(at: index)
        }
    }

    private func select(number: Int, in popup: NSPopUpButton) {
        if let index = popup.itemArray.firstIndex(where: {
            ($0.representedObject as? NSNumber)?.intValue == number
        }) {
            popup.selectItem(at: index)
        }
    }

    private func normalizedHotkeyKey(_ value: String) -> String {
        let key = value.lowercased()
        return ["function", "globe"].contains(key) ? "fn" : key
    }

    private func normalizedModifier(_ value: String) -> String {
        switch value.lowercased() {
        case "cmd": return "command"
        case "ctrl": return "control"
        case "alt": return "option"
        default: return value.lowercased()
        }
    }

    private static func wrappingLabel(_ value: String) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: value)
        field.maximumNumberOfLines = 0
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    private static func helpLabel(_ value: String) -> NSTextField {
        let field = wrappingLabel(value)
        field.textColor = .secondaryLabelColor
        field.font = .systemFont(ofSize: 12)
        return field
    }

    private static let hotkeyChoices: [(String, String)] = {
        var choices: [(String, String)] = [
            ("Fn / Globe", "fn"),
            ("Right Option", "right_option"),
            ("Right Command", "right_command"),
            ("Right Control", "right_control"),
            ("Right Shift", "right_shift"),
            ("Space", "space"), ("Return", "return"), ("Tab", "tab"), ("Delete", "delete")
        ]
        choices.append(contentsOf: Array("abcdefghijklmnopqrstuvwxyz").map { (String($0).uppercased(), String($0)) })
        choices.append(contentsOf: Array("0123456789").map { (String($0), String($0)) })
        choices.append(contentsOf: [("Left Arrow", "left"), ("Right Arrow", "right"), ("Up Arrow", "up"), ("Down Arrow", "down")])
        choices.append(contentsOf: [("-", "-"), ("=", "="), ("[", "["), ("]", "]"), (";", ";"), ("'", "'"), (",", ","), (".", "."), ("/", "/"), ("`", "`")])
        return choices
    }()

    private static let standaloneHotkeyKeys: Set<String> = [
        "fn", "right_option", "right_command", "right_control", "right_shift"
    ]
}

private final class SettingsDocumentView: NSView {
    override var isFlipped: Bool { true }
}
