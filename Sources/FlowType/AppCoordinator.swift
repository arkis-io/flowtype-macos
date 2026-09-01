import Foundation

@MainActor
final class AppCoordinator {
    var onStatusChange: ((String) -> Void)?
    var onEnabledChange: ((Bool) -> Void)?
    var onHistoryChange: (() -> Void)?
    var onBusyChange: ((Bool) -> Void)?

    private(set) var config: AppConfig
    let historyStore: RecordingHistoryStore

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
    private var inputLevelTimer: Timer?
    private var processingTask: Task<Void, Never>?
    private var activeCaptureID: UUID?
    private var currentContext: ProcessingContext?
    private var musicLoweringUnavailable = false

    private enum AttemptOrigin: Equatable {
        case newCapture
        case retryLast
        case history
    }

    private enum Delivery: Equatable {
        case paste(keepClipboard: Bool)
        case historyOnly
    }

    private struct ProcessingContext: Equatable {
        let attemptID: UUID
        let entryID: UUID
        let origin: AttemptOrigin
        let delivery: Delivery
    }

    private enum CancellationReason {
        case escape
        case lifecycle
    }

    init(configStore: ConfigStore, historyStore: RecordingHistoryStore) throws {
        self.configStore = configStore
        self.historyStore = historyStore
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

    var isBusy: Bool {
        activeCaptureID != nil || currentContext != nil || audioRecorder.isRecording
    }

    var activeEntryIDs: Set<UUID> {
        Set([activeCaptureID, currentContext?.entryID].compactMap { $0 })
    }

    func start() {
        _ = outputVolumeDucker.restoreIfNeeded()
        installEventMonitor()
        onEnabledChange?(config.enabled)
        onBusyChange?(isBusy)
    }

    func shutdown() {
        cancelCurrentWork(reason: .lifecycle)
    }

    func reloadConfiguration() {
        do {
            let loaded = try configStore.load()
            try SettingsValidator.validate(loaded)
            try eventMonitor.update(config: loaded.hotkey, toggleConfig: loaded.toggleHotkey)
            config = loaded
            installEventMonitor()
            if !config.enabled {
                cancelCurrentWork(reason: .lifecycle)
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
            cancelCurrentWork(reason: .lifecycle)
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
            cancelCurrentWork(reason: .lifecycle)
        }
    }

    func retryLastTranscription() {
        do {
            guard !isBusy, stateMachine.phase == .idle else {
                throw RecordingHistoryStoreError.unavailable("FlowType is already recording or processing audio.")
            }
            guard let entry = try historyStore.newestRetryableEntry(activeIDs: activeEntryIDs) else {
                throw RecordingHistoryStoreError.unavailable("There is no retained recording available to retry.")
            }
            try beginRetry(entryID: entry.id, origin: .retryLast, delivery: .paste(keepClipboard: true))
        } catch {
            showError(error.localizedDescription)
        }
    }

    func retryHistoryEntry(id: UUID) {
        do {
            try beginRetry(entryID: id, origin: .history, delivery: .historyOnly)
        } catch {
            showError(error.localizedDescription)
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
                    let capture = try historyStore.beginCapture()
                    do {
                        try audioRecorder.start(
                            config: config.audio,
                            destinationDirectory: capture.directoryURL
                        )
                    } catch {
                        try? historyStore.discardCapture(id: capture.entryID)
                        throw error
                    }
                    activeCaptureID = capture.entryID
                    notifyBusyAndHistoryChanged()
                    audioFeedback.playStarted(ifEnabled: config.audio.feedbackSoundsEnabled)
                    let musicWasLowered = outputVolumeDucker.begin(
                        enabled: config.audio.lowerOtherAudioEnabled,
                        level: config.audio.duckingLevel
                    )
                    musicLoweringUnavailable = config.audio.lowerOtherAudioEnabled && !musicWasLowered
                    scheduleInputLevelUpdates()
                    scheduleAutoStop()
                    let routingStatus = audioRecorder.activeInputRoutingNote.isEmpty
                        ? "Recording with \(audioRecorder.activeInputDeviceName)"
                        : audioRecorder.activeInputRoutingNote
                    onStatusChange?(
                        musicLoweringUnavailable
                            ? "\(routingStatus) — music could not be lowered"
                            : routingStatus
                    )
                } catch {
                    stateMachine.reset()
                    cancelTimers()
                    showError(error.localizedDescription)
                    return
                }

            case .showHeldMode:
                pill.show(
                    musicLoweringUnavailable ? "Hold · music unchanged" : "Hold · \(activeMicrophoneLabel)",
                    appearance: .held
                )

            case .showHandsFreeMode:
                pill.show(
                    musicLoweringUnavailable
                        ? "Hands-free · music unchanged"
                        : "Hands-free · \(activeMicrophoneLabel)",
                    appearance: .handsFree
                )
                onStatusChange?(
                    musicLoweringUnavailable
                        ? "Hands-free recording — music could not be lowered"
                        : "Hands-free recording"
                )

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
                cancelCurrentWork(reason: .escape)
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
        guard let entryID = activeCaptureID else {
            stateMachine.reset()
            showError("FlowType lost the active recording identifier. Please record again.")
            return
        }

        let context = ProcessingContext(
            attemptID: UUID(),
            entryID: entryID,
            origin: .newCapture,
            delivery: .paste(keepClipboard: false)
        )
        currentContext = context
        notifyBusyAndHistoryChanged()
        let configSnapshot = config
        let environment = configStore.loadEnvironment()
        let dictionary = PersonalDictionary.load(from: configSnapshot.dictionaryPath)
        pill.show("Finishing audio…", appearance: .processing)
        onStatusChange?("Finishing recording")

        processingTask = Task { [weak self] in
            guard let self else { return }
            do {
                let sourceURL = try await audioRecorder.stop()
                let duration = audioRecorder.duration(of: sourceURL)
                _ = outputVolumeDucker.restoreIfNeeded()
                audioFeedback.playStopped(ifEnabled: configSnapshot.audio.feedbackSoundsEnabled)
                try ensureCurrent(context)

                _ = try historyStore.promoteCapture(id: entryID, durationSeconds: duration)
                activeCaptureID = nil
                notifyBusyAndHistoryChanged()
                _ = try historyStore.beginAttempt(
                    id: entryID,
                    provider: configSnapshot.transcription.provider
                )
                guard let durableAudioURL = try historyStore.audioURL(for: entryID) else {
                    throw RecordingHistoryStoreError.unavailable("The finalized recording is missing.")
                }
                try await runPipeline(
                    context: context,
                    audioURL: durableAudioURL,
                    configSnapshot: configSnapshot,
                    environment: environment,
                    dictionary: dictionary
                )
            } catch is CancellationError {
                finishCancelledTask(context)
            } catch {
                _ = outputVolumeDucker.restoreIfNeeded()
                if isCurrent(context) {
                    if (try? historyStore.loadEntry(id: entryID)) != nil {
                        _ = try? historyStore.failAttempt(
                            id: entryID,
                            stage: .capture,
                            message: error.localizedDescription
                        )
                    } else {
                        try? historyStore.discardCapture(id: entryID)
                        activeCaptureID = nil
                    }
                    finishWithError(context, message: error.localizedDescription)
                }
            }
        }
    }

    private func beginRetry(
        entryID: UUID,
        origin: AttemptOrigin,
        delivery: Delivery
    ) throws {
        guard !isBusy, stateMachine.phase == .idle else {
            throw RecordingHistoryStoreError.unavailable("FlowType is already recording or processing audio.")
        }
        let eligibility = try historyStore.retryEligibility(for: entryID, activeIDs: activeEntryIDs)
        guard case .available(let audioURL) = eligibility else {
            if case .unavailable(let reason) = eligibility {
                throw RecordingHistoryStoreError.unavailable(reason)
            }
            throw RecordingHistoryStoreError.unavailable("This recording cannot be retried.")
        }

        _ = stateMachine.handle(.beginExternalProcessing, config: config.gestures)
        guard stateMachine.phase == .processing else {
            throw RecordingHistoryStoreError.unavailable("FlowType could not enter retry mode.")
        }

        let context = ProcessingContext(
            attemptID: UUID(),
            entryID: entryID,
            origin: origin,
            delivery: delivery
        )
        let configSnapshot = config
        let environment = configStore.loadEnvironment()
        let dictionary = PersonalDictionary.load(from: configSnapshot.dictionaryPath)
        do {
            _ = try historyStore.beginAttempt(
                id: entryID,
                provider: configSnapshot.transcription.provider
            )
        } catch {
            stateMachine.reset()
            throw error
        }

        currentContext = context
        notifyBusyAndHistoryChanged()
        pill.show("Retranscribing…", appearance: .processing)
        onStatusChange?("Retranscribing retained audio")
        processingTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await runPipeline(
                    context: context,
                    audioURL: audioURL,
                    configSnapshot: configSnapshot,
                    environment: environment,
                    dictionary: dictionary
                )
            } catch is CancellationError {
                finishCancelledTask(context)
            } catch {
                guard isCurrent(context) else { return }
                let stage = stageFor(error: error)
                _ = try? historyStore.failAttempt(
                    id: entryID,
                    stage: stage,
                    message: error.localizedDescription,
                    unusableAudio: stage == .conversion && isUnusableAudioError(error)
                )
                finishWithError(context, message: error.localizedDescription)
            }
        }
    }

    private func runPipeline(
        context: ProcessingContext,
        audioURL: URL,
        configSnapshot: AppConfig,
        environment: [String: String],
        dictionary: PersonalDictionary
    ) async throws {
        var currentStage = RecordingStage.conversion
        let convertsSourceAudio = audioURL.pathExtension.lowercased() != "wav"
        do {
            try ensureCurrent(context)
            _ = try historyStore.updateStage(id: context.entryID, stage: .conversion)
            let wavURL: URL
            if audioURL.pathExtension.lowercased() == "wav" {
                wavURL = audioURL
            } else {
                let convertedURL = try await audioConverter.convertToWhisperWAV(
                    audioURL,
                    boostQuietSpeech: configSnapshot.audio.boostQuietSpeechEnabled
                )
                try ensureCurrent(context)
                wavURL = try historyStore.canonicalizeAudio(
                    id: context.entryID,
                    convertedURL: convertedURL
                )
            }

            currentStage = .transcription
            try ensureCurrent(context)
            _ = try historyStore.updateStage(id: context.entryID, stage: .transcription)
            pill.show("Transcribing…", appearance: .processing)
            onStatusChange?("Transcribing")
            let rawTranscript = try await transcriptionService.transcribe(
                audioURL: wavURL,
                config: configSnapshot.transcription,
                environment: environment,
                dictionary: dictionary
            )
            try ensureCurrent(context)
            _ = try historyStore.saveRawTranscript(id: context.entryID, text: rawTranscript)

            currentStage = .cleanup
            _ = try historyStore.updateStage(id: context.entryID, stage: .cleanup)
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
            try ensureCurrent(context)

            let finalText = dictionary.applyingReplacements(to: cleaned)
            _ = try historyStore.completeAttempt(
                id: context.entryID,
                rawTranscript: rawTranscript,
                finalTranscript: finalText
            )
            notifyBusyAndHistoryChanged()

            if case .paste(let keepClipboard) = context.delivery {
                currentStage = .insertion
                var clipboardConfig = configSnapshot.clipboard
                if keepClipboard {
                    clipboardConfig.restorePrevious = false
                }
                do {
                    try ensureCurrent(context)
                    try insertionService.insert(finalText, config: clipboardConfig)
                } catch {
                    _ = try? historyStore.recordInsertionFailure(
                        id: context.entryID,
                        message: error.localizedDescription
                    )
                    finishWithError(context, message: error.localizedDescription)
                    return
                }
            }
            finishSuccessfully(context)
        } catch is CancellationError {
            if currentStage == .conversion && convertsSourceAudio {
                historyStore.removePartialConvertedAudio(id: context.entryID)
            }
            throw CancellationError()
        } catch {
            guard isCurrent(context) else { throw CancellationError() }
            if currentStage == .conversion && convertsSourceAudio {
                historyStore.removePartialConvertedAudio(id: context.entryID)
            }
            _ = try? historyStore.failAttempt(
                id: context.entryID,
                stage: currentStage,
                message: error.localizedDescription,
                unusableAudio: currentStage == .conversion && isUnusableAudioError(error)
            )
            finishWithError(context, message: error.localizedDescription)
        }
    }

    private func ensureCurrent(_ context: ProcessingContext) throws {
        try Task.checkCancellation()
        guard isCurrent(context) else { throw CancellationError() }
    }

    private func isCurrent(_ context: ProcessingContext) -> Bool {
        currentContext?.attemptID == context.attemptID
            && currentContext?.entryID == context.entryID
    }

    private func finishSuccessfully(_ context: ProcessingContext) {
        guard isCurrent(context) else { return }
        currentContext = nil
        processingTask = nil
        _ = stateMachine.handle(.processingFinished, config: config.gestures)
        notifyBusyAndHistoryChanged()
        let message = context.origin == .history ? "Transcript ready in History" : "Transcript ready"
        pill.show(message, appearance: .success, autoHideAfter: 1.8)
        onStatusChange?(config.enabled ? "Ready — \(hotkeyDescription)" : "Dictation is off")
    }

    private func finishWithError(_ context: ProcessingContext, message: String) {
        guard isCurrent(context) else { return }
        currentContext = nil
        processingTask = nil
        _ = stateMachine.handle(.processingFinished, config: config.gestures)
        notifyBusyAndHistoryChanged()
        showError(message)
    }

    private func finishCancelledTask(_ context: ProcessingContext) {
        guard isCurrent(context) else { return }
        currentContext = nil
        processingTask = nil
        stateMachine.reset()
        notifyBusyAndHistoryChanged()
        pill.hide()
    }

    private func cancelCurrentWork(reason: CancellationReason) {
        cancelTimers()
        let captureID = activeCaptureID
        let context = currentContext
        let wasRecording = audioRecorder.isRecording
        let retainFinalizingCapture = reason == .lifecycle && context?.origin == .newCapture
        audioRecorder.cancel(retainRecording: retainFinalizingCapture)
        _ = outputVolumeDucker.restoreIfNeeded()
        if wasRecording {
            audioFeedback.playStopped(ifEnabled: config.audio.feedbackSoundsEnabled)
        }
        processingTask?.cancel()
        processingTask = nil

        if let context {
            let workKind: RecordingWorkKind = context.origin == .newCapture ? .initialProcessing : .retry
            let cause: RecordingCancellationCause = reason == .escape ? .escape : .lifecycle
            switch RecordingCancellationPolicy.disposition(for: workKind, cause: cause) {
            case .delete:
                try? historyStore.discardCapture(id: context.entryID)
            case .retainInterrupted:
                if context.origin == .newCapture {
                    if (try? historyStore.loadEntry(id: context.entryID)) != nil {
                        _ = try? historyStore.markInterrupted(id: context.entryID)
                    }
                } else {
                    _ = try? historyStore.markInterrupted(
                        id: context.entryID,
                        message: reason == .escape
                            ? "The retry was cancelled. The retained audio is still available."
                            : "The retry was interrupted. The retained audio is still available."
                    )
                }
            }
        } else if let captureID {
            try? historyStore.discardCapture(id: captureID)
        }

        activeCaptureID = nil
        currentContext = nil
        stateMachine.reset()
        pill.hide()
        notifyBusyAndHistoryChanged()
    }

    private func cancelTimers() {
        doubleTapTimer?.invalidate()
        doubleTapTimer = nil
        autoStopTimer?.invalidate()
        autoStopTimer = nil
        inputLevelTimer?.invalidate()
        inputLevelTimer = nil
    }

    private func scheduleInputLevelUpdates() {
        inputLevelTimer?.invalidate()
        inputLevelTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.audioRecorder.isRecording else { return }
                self.pill.updateInputLevel(self.audioRecorder.normalizedInputLevel)
            }
        }
    }

    private func notifyBusyAndHistoryChanged() {
        onBusyChange?(isBusy)
        onHistoryChange?()
    }

    private func stageFor(error: Error) -> RecordingStage {
        guard let flowError = error as? FlowTypeError else { return .transcription }
        switch flowError {
        case .recording, .conversion: return .conversion
        case .transcription, .configuration: return .transcription
        case .cleanup: return .cleanup
        case .insertion, .permission: return .insertion
        }
    }

    private func isUnusableAudioError(_ error: Error) -> Bool {
        guard let flowError = error as? FlowTypeError,
              case .recording(let message) = flowError else { return false }
        let normalized = message.lowercased()
        return normalized.contains("no microphone audio")
            || normalized.contains("no audio frames")
            || normalized.contains("nearly silent")
    }

    private func showError(_ message: String) {
        let compactMessage = message.replacingOccurrences(of: "\n", with: " ")
        pill.show(String(compactMessage.prefix(90)), appearance: .error, autoHideAfter: 4)
        onStatusChange?(String(compactMessage.prefix(240)))
    }
}
