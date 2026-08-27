import Foundation

@MainActor
final class AppCoordinator {
    var onStatusChange: ((String) -> Void)?
    var onEnabledChange: ((Bool) -> Void)?

    private(set) var config: AppConfig
    private let configStore: ConfigStore
    private let eventMonitor: GlobalEventMonitor
    private let audioRecorder = AudioRecorder()
    private let audioFeedback = AudioFeedbackService()
    private let outputVolumeDucker: OutputVolumeDucker
    private let audioConverter = AudioConverterService()
    private let transcriptionService = TranscriptionService()
    private let cleanupService = CleanupService()
    private let insertionService = TextInsertionService()
    private let pill = PillWindowController()

    private var stateMachine = GestureStateMachine()
    private var doubleTapTimer: Timer?
    private var autoStopTimer: Timer?
    private var processingTask: Task<Void, Never>?
    private var currentSessionID: UUID?

    init(configStore: ConfigStore) throws {
        self.configStore = configStore
        outputVolumeDucker = OutputVolumeDucker(recoveryURL: configStore.outputVolumeRecoveryURL)
        config = try configStore.load()
        try SettingsValidator.validate(config)
        eventMonitor = try GlobalEventMonitor(config: config.hotkey, toggleConfig: config.toggleHotkey)

        eventMonitor.onHotkeyDown = { [weak self] eventTime in
            Task { @MainActor in self?.hotkeyDown(at: eventTime) }
        }
        eventMonitor.onHotkeyUp = { [weak self] eventTime in
            Task { @MainActor in self?.hotkeyUp(at: eventTime) }
        }
        eventMonitor.onToggleHotkeyDown = { [weak self] eventTime in
            Task { @MainActor in self?.toggleHotkeyDown(at: eventTime) }
        }
        eventMonitor.onEscape = { [weak self] in
            Task { @MainActor in self?.escapePressed() }
        }
    }

    func start() {
        _ = outputVolumeDucker.restoreIfNeeded()
        installEventMonitor()
        onEnabledChange?(config.enabled)
    }

    func shutdown() {
        cancelCurrentWork()
    }

    func reloadConfiguration() {
        do {
            let loaded = try configStore.load()
            try SettingsValidator.validate(loaded)
            try eventMonitor.update(config: loaded.hotkey, toggleConfig: loaded.toggleHotkey)
            config = loaded
            installEventMonitor()
            if !config.enabled {
                cancelCurrentWork()
            }
            onEnabledChange?(config.enabled)
            onStatusChange?(config.enabled ? "Ready — \(hotkeyDescription)" : "Dictation is off")
        } catch {
            showError(error.localizedDescription)
        }
    }

    func setEnabled(_ enabled: Bool) {
        config.enabled = enabled
        if !enabled {
            cancelCurrentWork()
        }
        do {
            try configStore.save(config)
            onEnabledChange?(enabled)
            onStatusChange?(enabled ? "Ready — \(hotkeyDescription)" : "Dictation is off")
        } catch {
            showError("Could not save the on/off setting: \(error.localizedDescription)")
        }
    }

    func retryEventMonitor() {
        installEventMonitor()
    }

    func setSettingsPresented(_ presented: Bool) {
        if presented {
            cancelCurrentWork()
        }
    }

    var dictionaryURL: URL {
        URL(fileURLWithPath: config.dictionaryPath.expandingTildeInPath)
    }

    private var hotkeyDescription: String {
        if config.gestures.hybridPrimaryHotkey {
            return "tap \(shortcutDescription(config.hotkey)) for hands-free; hold for push to talk"
        }
        return "hold \(shortcutDescription(config.hotkey)); tap \(shortcutDescription(config.toggleHotkey)) for hands-free"
    }

    private func shortcutDescription(_ hotkey: HotkeyConfig) -> String {
        let key: String
        switch hotkey.key.lowercased() {
        case "fn", "function", "globe": key = "Fn"
        case "right_option": key = "Right Option"
        case "right_command": key = "Right Command"
        case "right_control": key = "Right Control"
        case "right_shift": key = "Right Shift"
        default: key = hotkey.key.uppercased()
        }
        return (hotkey.modifiers.map { $0.capitalized } + [key]).joined(separator: "+")
    }

    private func installEventMonitor() {
        do {
            try eventMonitor.install()
            onStatusChange?(config.enabled ? "Ready — \(hotkeyDescription)" : "Dictation is off")
        } catch {
            onStatusChange?("Needs Input Monitoring permission")
        }
    }

    private func hotkeyDown(at eventTime: TimeInterval) {
        guard config.enabled else { return }
        handle(.hotkeyDown(at: eventTime))
    }

    private func hotkeyUp(at eventTime: TimeInterval) {
        guard config.enabled else { return }
        handle(.hotkeyUp(at: eventTime))
    }

    private func toggleHotkeyDown(at eventTime: TimeInterval) {
        guard config.enabled, !config.gestures.hybridPrimaryHotkey else { return }
        handle(.toggleHotkeyDown(at: eventTime))
    }

    private func escapePressed() {
        handle(.escape)
    }

    private func handle(_ event: GestureStateMachine.Event) {
        let actions = stateMachine.handle(event, config: config.gestures)
        execute(actions)
    }

    private func execute(_ actions: [GestureStateMachine.Action]) {
        for action in actions {
            switch action {
            case .startRecording:
                do {
                    try audioRecorder.start(config: config.audio)
                    audioFeedback.playStarted(ifEnabled: config.audio.feedbackSoundsEnabled)
                    _ = outputVolumeDucker.begin(
                        enabled: config.audio.lowerOtherAudioEnabled,
                        level: config.audio.duckingLevel
                    )
                    scheduleAutoStop()
                    onStatusChange?("Recording")
                } catch {
                    stateMachine.reset()
                    cancelTimers()
                    showError(error.localizedDescription)
                    return
                }

            case .showHeldMode:
                pill.show("Hold · \(activeMicrophoneLabel)", appearance: .held)

            case .showHandsFreeMode:
                pill.show("Hands-free · \(activeMicrophoneLabel)", appearance: .handsFree)
                onStatusChange?("Hands-free recording")

            case .scheduleDoubleTapExpiry(let interval):
                doubleTapTimer?.invalidate()
                doubleTapTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
                    Task { @MainActor in
                        self?.handle(.doubleTapWindowExpired(at: ProcessInfo.processInfo.systemUptime))
                    }
                }

            case .cancelDoubleTapExpiry:
                doubleTapTimer?.invalidate()
                doubleTapTimer = nil

            case .stopAndProcess:
                stopAndProcess()

            case .cancel:
                cancelCurrentWork()
                onStatusChange?(config.enabled ? "Cancelled — \(hotkeyDescription)" : "Dictation is off")

            case .hide:
                pill.hide()
            }
        }
    }

    private func scheduleAutoStop() {
        autoStopTimer?.invalidate()
        let seconds = max(1, config.gestures.maxRecordingSeconds)
        autoStopTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(seconds), repeats: false) { [weak self] _ in
            Task { @MainActor in self?.handle(.autoStop) }
        }
    }

    private var activeMicrophoneLabel: String {
        String(audioRecorder.activeInputDeviceName.prefix(24))
    }

    private func stopAndProcess() {
        cancelTimers()

        let sourceURL: URL
        do {
            sourceURL = try audioRecorder.stop()
            _ = outputVolumeDucker.restoreIfNeeded()
            audioFeedback.playStopped(ifEnabled: config.audio.feedbackSoundsEnabled)
        } catch {
            _ = outputVolumeDucker.restoreIfNeeded()
            stateMachine.reset()
            showError(error.localizedDescription)
            return
        }

        let sessionID = UUID()
        currentSessionID = sessionID
        let configSnapshot = config
        let environment = configStore.loadEnvironment()
        let dictionary = PersonalDictionary.load(from: configSnapshot.dictionaryPath)
        pill.show("Transcribing…", appearance: .processing)
        onStatusChange?("Transcribing")

        processingTask = Task { [weak self] in
            guard let self else { return }
            let directory = sourceURL.deletingLastPathComponent()
            defer { try? FileManager.default.removeItem(at: directory) }

            do {
                let wavURL = try await audioConverter.convertToWhisperWAV(sourceURL)
                let rawTranscript = try await transcriptionService.transcribe(
                    audioURL: wavURL,
                    config: configSnapshot.transcription,
                    environment: environment,
                    dictionary: dictionary
                )
                try Task.checkCancellation()

                if configSnapshot.cleanup.enabled {
                    pill.show("Cleaning up…", appearance: .processing)
                    onStatusChange?("Cleaning transcript")
                }
                let cleaned = try await cleanupService.clean(
                    transcript: rawTranscript,
                    config: configSnapshot.cleanup,
                    environment: environment,
                    dictionary: dictionary
                )
                try Task.checkCancellation()

                let finalText = dictionary.applyingReplacements(to: cleaned)
                guard currentSessionID == sessionID else { throw CancellationError() }
                try insertionService.insert(finalText, config: configSnapshot.clipboard)
                finishProcessing(sessionID: sessionID)
            } catch is CancellationError {
                finishCancelledProcessing(sessionID: sessionID)
            } catch {
                finishProcessing(sessionID: sessionID, errorMessage: error.localizedDescription)
            }
        }
    }

    private func finishProcessing(sessionID: UUID, errorMessage: String? = nil) {
        guard currentSessionID == sessionID else { return }
        currentSessionID = nil
        processingTask = nil
        _ = stateMachine.handle(.processingFinished, config: config.gestures)

        if let errorMessage {
            showError(errorMessage)
        } else {
            pill.hide()
            onStatusChange?(config.enabled ? "Ready — \(hotkeyDescription)" : "Dictation is off")
        }
    }

    private func finishCancelledProcessing(sessionID: UUID) {
        guard currentSessionID == sessionID else { return }
        currentSessionID = nil
        processingTask = nil
        stateMachine.reset()
        pill.hide()
    }

    private func cancelCurrentWork() {
        cancelTimers()
        let wasRecording = audioRecorder.isRecording
        audioRecorder.cancel()
        _ = outputVolumeDucker.restoreIfNeeded()
        if wasRecording {
            audioFeedback.playStopped(ifEnabled: config.audio.feedbackSoundsEnabled)
        }
        processingTask?.cancel()
        processingTask = nil
        currentSessionID = nil
        stateMachine.reset()
        pill.hide()
    }

    private func cancelTimers() {
        doubleTapTimer?.invalidate()
        doubleTapTimer = nil
        autoStopTimer?.invalidate()
        autoStopTimer = nil
    }

    private func showError(_ message: String) {
        let compactMessage = message.replacingOccurrences(of: "\n", with: " ")
        pill.show(String(compactMessage.prefix(90)), appearance: .error)
        onStatusChange?(String(compactMessage.prefix(240)))
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            guard let self, self.stateMachine.phase == .idle else { return }
            self.pill.hide()
        }
    }
}
