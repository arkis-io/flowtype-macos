import AppKit
import Foundation
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var coordinator: AppCoordinator?
    private var configStore: ConfigStore?
    private var historyStore: RecordingHistoryStore?
    private var settingsWindowController: SettingsWindowController?
    private var historyWindowController: RecordingHistoryWindowController?
    private var localModelManager: LocalModelManager?
    private var enabledMenuItem: NSMenuItem?
    private var statusMenuItem: NSMenuItem?
    private var launchAtLoginMenuItem: NSMenuItem?
    private var updatesMenuItem: NSMenuItem?
    private var retryLastMenuItem: NSMenuItem?
    private var historyMenuItem: NSMenuItem?
    private var updateChecker: ReleaseUpdateChecker?
    private var updateCheckTask: Task<Void, Never>?
    private var automaticUpdateCheckWorkItem: DispatchWorkItem?
    private var availableRelease: FlowTypeRelease?
    private var retentionTimer: Timer?
    private let updatePill = PillWindowController()

    private static let lastUpdateCheckKey = "FlowTypeLastGitHubReleaseCheck"
    private static let skippedUpdateVersionKey = "FlowTypeSkippedReleaseVersion"

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        do {
            let configStore = try ConfigStore()
            let historyStore = try RecordingHistoryStore(rootURL: configStore.recordingsURL)
            _ = try historyStore.reconcileInterruptedWork()
            let coordinator = try AppCoordinator(
                configStore: configStore,
                historyStore: historyStore
            )
            let savedConfig = try configStore.load()
            let selectedModel = LocalModelSpecification.matching(
                path: savedConfig.transcription.localModelPath
            ) ?? .mediumEnglish
            let modelManager = LocalModelManager(
                applicationSupportURL: configStore.applicationSupportURL,
                specification: selectedModel
            )
            self.configStore = configStore
            self.historyStore = historyStore
            self.coordinator = coordinator
            self.localModelManager = modelManager
            let settingsWindowController = SettingsWindowController(
                configStore: configStore,
                modelManager: modelManager
            )
            settingsWindowController.onSave = { [weak self, weak coordinator] in
                coordinator?.reloadConfiguration()
                self?.updateConfigurationDidChange()
            }
            settingsWindowController.onVisibilityChange = { [weak coordinator] isVisible in
                coordinator?.setSettingsPresented(isVisible)
            }
            settingsWindowController.onRequestMonitorRetry = { [weak coordinator] in
                coordinator?.retryEventMonitor()
            }
            self.settingsWindowController = settingsWindowController
            let historyWindowController = RecordingHistoryWindowController(store: historyStore)
            historyWindowController.onRetry = { [weak self, weak coordinator] id in
                guard let coordinator else { return }
                if let notice = RetryCostNotice.summary(for: coordinator.config),
                   self?.confirmPaidRetry(notice) != true {
                    return
                }
                coordinator.retryHistoryEntry(id: id)
            }
            historyWindowController.onEntriesChange = { [weak self] in
                self?.updateRecoveryUI()
                self?.scheduleNextRetentionPrune()
            }
            historyWindowController.activeEntryIDs = { [weak coordinator] in
                coordinator?.activeEntryIDs ?? []
            }
            historyWindowController.isBusy = { [weak coordinator] in
                coordinator?.isBusy ?? false
            }
            self.historyWindowController = historyWindowController
            configureStatusItem()

            coordinator.onStatusChange = { [weak self] status in
                self?.statusMenuItem?.title = "Status: \(status)"
            }
            coordinator.onEnabledChange = { [weak self] enabled in
                self?.enabledMenuItem?.state = enabled ? .on : .off
                self?.updateStatusIcon(isActive: enabled)
            }
            coordinator.onHistoryChange = { [weak self] in
                self?.historyWindowController?.refresh()
                self?.updateRecoveryUI()
                self?.scheduleNextRetentionPrune()
            }
            coordinator.onBusyChange = { [weak self] _ in
                self?.historyWindowController?.updateBusyState()
                self?.updateRecoveryUI()
            }
            coordinator.start()
            updateRecoveryUI()
            scheduleNextRetentionPrune()
            configureUpdateChecker()
            scheduleAutomaticUpdateCheck()

            let onboardingKey = "FlowTypeHasShownSettingsWindowV1"
            let needsPermissions = !Permissions.canRecordAudio
                || !Permissions.canMonitorInput
                || !Permissions.canInsertText
            let config = try? configStore.load()
            let needsLocalModel = config?.transcription.provider.lowercased() == "local"
                && !FileManager.default.fileExists(
                    atPath: config?.transcription.localModelPath.expandingTildeInPath ?? ""
                )
            if !UserDefaults.standard.bool(forKey: onboardingKey) || needsPermissions || needsLocalModel {
                UserDefaults.standard.set(true, forKey: onboardingKey)
                DispatchQueue.main.async { [weak self] in self?.showSettings() }
            }
        } catch {
            configureStatusItem()
            statusMenuItem?.title = "Status: setup failed"
            presentError(title: "FlowType could not start", message: error.localizedDescription)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        automaticUpdateCheckWorkItem?.cancel()
        updateCheckTask?.cancel()
        retentionTimer?.invalidate()
        updatePill.hide()
        localModelManager?.cancelDownload()
        coordinator?.shutdown()
    }

    private func configureStatusItem() {
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        self.statusItem = statusItem
        updateStatusIcon(isActive: true)

        let menu = NSMenu()

        menu.addItem(menuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ","))
        let history = menuItem(title: "Recording History…", action: #selector(openHistory))
        menu.addItem(history)
        historyMenuItem = history
        let retryLast = menuItem(
            title: "Retry Last Transcription",
            action: #selector(retryLastTranscription)
        )
        retryLast.isEnabled = false
        menu.addItem(retryLast)
        retryLastMenuItem = retryLast
        menu.addItem(.separator())

        let enabled = NSMenuItem(title: "Dictation Enabled", action: #selector(toggleEnabled(_:)), keyEquivalent: "")
        enabled.target = self
        enabled.state = .on
        menu.addItem(enabled)
        enabledMenuItem = enabled

        let status = NSMenuItem(title: "Status: Starting…", action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        statusMenuItem = status

        let updates = menuItem(title: "Check for Updates…", action: #selector(checkForUpdates))
        menu.addItem(updates)
        updatesMenuItem = updates

        menu.addItem(.separator())
        menu.addItem(menuItem(title: "Open config.json", action: #selector(openConfig)))
        menu.addItem(menuItem(title: "Open dictionary.txt", action: #selector(openDictionary)))
        menu.addItem(menuItem(title: "Open .env", action: #selector(openEnvironment)))
        menu.addItem(menuItem(title: "Reload Configuration", action: #selector(reloadConfiguration)))

        menu.addItem(.separator())
        menu.addItem(menuItem(title: "Request Microphone Permission", action: #selector(requestMicrophonePermission)))
        menu.addItem(menuItem(title: "Continue Permission Setup…", action: #selector(requestInputPermissions)))

        let loginItem = menuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin(_:)))
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(loginItem)
        launchAtLoginMenuItem = loginItem

        menu.addItem(.separator())
        menu.addItem(menuItem(title: "Quit FlowType", action: #selector(quit), keyEquivalent: "q"))

        statusItem.menu = menu
    }

    private func menuItem(title: String, action: Selector, keyEquivalent: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = self
        return item
    }

    private func updateStatusIcon(isActive: Bool) {
        let symbol = isActive ? "waveform.circle.fill" : "waveform.circle"
        statusItem?.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "FlowType")
    }

    @objc private func toggleEnabled(_ sender: NSMenuItem) {
        coordinator?.setEnabled(sender.state != .on)
    }

    @objc private func openSettings() {
        showSettings()
    }

    @objc private func openHistory() {
        historyWindowController?.showHistory()
    }

    @objc private func retryLastTranscription() {
        coordinator?.retryLastTranscription()
    }

    @objc private func openConfig() {
        guard let url = configStore?.configURL else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func openDictionary() {
        guard let url = coordinator?.dictionaryURL else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func openEnvironment() {
        guard let url = configStore?.environmentURL else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func reloadConfiguration() {
        coordinator?.reloadConfiguration()
        updateConfigurationDidChange()
    }

    @objc private func checkForUpdates() {
        if let availableRelease {
            presentUpdate(release: availableRelease)
        } else {
            beginUpdateCheck(isManual: true)
        }
    }

    @objc private func requestMicrophonePermission() {
        Permissions.requestMicrophone { [weak self] granted in
            Task { @MainActor in
                if granted {
                    self?.statusMenuItem?.title = "Status: Microphone access granted"
                } else {
                    self?.presentError(
                        title: "Microphone permission is still off",
                        message: "Open System Settings → Privacy & Security → Microphone and enable FlowType."
                    )
                }
            }
        }
    }

    @objc private func requestInputPermissions() {
        settingsWindowController?.startPermissionSetup()
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
            sender.state = SMAppService.mainApp.status == .enabled ? .on : .off
            if SMAppService.mainApp.status == .requiresApproval {
                presentError(
                    title: "Launch at Login needs approval",
                    message: "Open System Settings → General → Login Items and allow FlowType under Allow in the Background."
                )
            }
        } catch {
            presentError(
                title: "Could not change Launch at Login",
                message: error.localizedDescription + " Make sure you are running the packaged FlowType.app from Applications."
            )
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func showSettings() {
        settingsWindowController?.showSettings()
    }

    private func configureUpdateChecker() {
        guard let endpointValue = Bundle.main.object(forInfoDictionaryKey: "FlowTypeReleaseAPIURL") as? String,
              let endpoint = URL(string: endpointValue),
              endpoint.scheme == "https",
              endpoint.host == "api.github.com" else {
            updatesMenuItem?.isEnabled = false
            updatesMenuItem?.title = "Updates are not configured"
            return
        }
        updateChecker = ReleaseUpdateChecker(endpoint: endpoint)
    }

    private func scheduleAutomaticUpdateCheck() {
        automaticUpdateCheckWorkItem?.cancel()
        automaticUpdateCheckWorkItem = nil
        guard automaticUpdateChecksEnabled else { return }
        let lastCheck = UserDefaults.standard.object(forKey: Self.lastUpdateCheckKey) as? Date
        guard ReleaseUpdateChecker.shouldCheckAutomatically(lastCheck: lastCheck) else { return }

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.automaticUpdateCheckWorkItem = nil
            guard self.automaticUpdateChecksEnabled else { return }
            self.beginUpdateCheck(isManual: false)
        }
        automaticUpdateCheckWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: workItem)
    }

    private var automaticUpdateChecksEnabled: Bool {
        guard let configStore, let config = try? configStore.load() else { return false }
        return config.updates.checkAutomatically
    }

    private var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    private func updateConfigurationDidChange() {
        updateRecoveryUI()
        if automaticUpdateChecksEnabled {
            scheduleAutomaticUpdateCheck()
        } else {
            automaticUpdateCheckWorkItem?.cancel()
            automaticUpdateCheckWorkItem = nil
            updateCheckTask?.cancel()
        }
    }

    private func beginUpdateCheck(isManual: Bool) {
        guard updateCheckTask == nil else { return }
        guard let updateChecker else {
            if isManual {
                presentError(
                    title: "Update checking is unavailable",
                    message: "This build does not contain a valid GitHub release endpoint."
                )
            }
            return
        }

        if isManual {
            updatesMenuItem?.title = "Checking for Updates…"
            updatesMenuItem?.isEnabled = false
        }
        UserDefaults.standard.set(Date(), forKey: Self.lastUpdateCheckKey)
        let installedVersion = currentVersion

        updateCheckTask = Task { @MainActor [weak self] in
            defer { self?.updateCheckTask = nil }
            do {
                let outcome = try await updateChecker.check(currentVersion: installedVersion)
                guard !Task.isCancelled else { return }
                self?.finishUpdateCheck(outcome, isManual: isManual)
            } catch is CancellationError {
                self?.resetUpdatesMenuItem()
            } catch {
                self?.resetUpdatesMenuItem()
                if isManual {
                    self?.presentError(title: "Could not check for updates", message: error.localizedDescription)
                }
            }
        }
    }

    private func finishUpdateCheck(_ outcome: ReleaseCheckOutcome, isManual: Bool) {
        switch outcome {
        case .updateAvailable(let release):
            availableRelease = release
            let skippedVersion = UserDefaults.standard.string(forKey: Self.skippedUpdateVersionKey)
            if isManual {
                presentUpdate(release: release)
            } else if skippedVersion != release.version {
                updatesMenuItem?.title = "Update Available: FlowType \(release.version)…"
                updatesMenuItem?.isEnabled = true
                updatePill.show(
                    "FlowType \(release.version) available — use the menu bar",
                    appearance: .update,
                    autoHideAfter: 8
                )
            } else {
                resetUpdatesMenuItem()
            }
        case .upToDate:
            availableRelease = nil
            resetUpdatesMenuItem()
            if isManual {
                presentMessage(
                    title: "FlowType is up to date",
                    message: "You are running the latest published version (\(currentVersion))."
                )
            }
        case .feedUnavailable:
            availableRelease = nil
            resetUpdatesMenuItem()
            if isManual {
                presentMessage(
                    title: "No public release feed yet",
                    message: "The GitHub repository may still be private, or no release has been published. This will start working after the project and its first release are public."
                )
            }
        }
    }

    private func presentUpdate(release: FlowTypeRelease) {
        updatePill.hide()
        NSApp.activate(ignoringOtherApps: true)

        let notes = release.notes.isEmpty
            ? "A new version of FlowType is available on GitHub."
            : String(release.notes.prefix(2_000))
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "FlowType \(release.version) is available"
        alert.informativeText = notes + "\n\nUpdates are never installed automatically. Downloading opens the GitHub release page."
        alert.addButton(withTitle: "Download Update")
        alert.addButton(withTitle: "Later")
        alert.addButton(withTitle: "Skip This Version")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            NSWorkspace.shared.open(release.webpageURL)
        case .alertThirdButtonReturn:
            UserDefaults.standard.set(release.version, forKey: Self.skippedUpdateVersionKey)
            resetUpdatesMenuItem()
        default:
            updatesMenuItem?.title = "Update Available: FlowType \(release.version)…"
            updatesMenuItem?.isEnabled = true
        }
    }

    private func resetUpdatesMenuItem() {
        updatesMenuItem?.title = "Check for Updates…"
        updatesMenuItem?.isEnabled = updateChecker != nil
    }

    private func updateRecoveryUI() {
        guard let historyStore, let coordinator else {
            retryLastMenuItem?.isEnabled = false
            historyMenuItem?.isEnabled = false
            return
        }
        historyMenuItem?.isEnabled = true
        retryLastMenuItem?.isEnabled = !coordinator.isBusy
            && (try? historyStore.newestRetryableEntry(activeIDs: coordinator.activeEntryIDs)) != nil

        // Retry Last pastes into the previously focused app, so it must not show a
        // modal that would activate FlowType. Surface the cost boundary in the menu instead.
        if let notice = RetryCostNotice.summary(for: coordinator.config) {
            retryLastMenuItem?.title = "Retry Last Transcription (uses \(notice.providers.joined(separator: " + ")))"
            retryLastMenuItem?.toolTip = notice.message
        } else {
            retryLastMenuItem?.title = "Retry Last Transcription"
            retryLastMenuItem?.toolTip = nil
        }
    }

    private func confirmPaidRetry(_ notice: RetryCostNotice.Summary) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Retranscribe with \(notice.providers.joined(separator: " and "))?"
        alert.informativeText = notice.message
        alert.addButton(withTitle: "Retranscribe")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func scheduleNextRetentionPrune() {
        retentionTimer?.invalidate()
        retentionTimer = nil
        guard let historyStore, let coordinator else { return }
        guard let expiry = try? historyStore.nextExpiryDate(activeIDs: coordinator.activeEntryIDs) else { return }
        let interval = max(0.25, expiry.timeIntervalSinceNow)
        retentionTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, let historyStore = self.historyStore else { return }
                _ = try? historyStore.prune(activeIDs: self.coordinator?.activeEntryIDs ?? [])
                self.historyWindowController?.refresh()
                self.updateRecoveryUI()
                self.scheduleNextRetentionPrune()
            }
        }
    }

    private func presentMessage(title: String, message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }

    private func presentError(title: String, message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }
}
