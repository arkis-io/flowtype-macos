import AppKit
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var coordinator: AppCoordinator?
    private var configStore: ConfigStore?
    private var settingsWindowController: SettingsWindowController?
    private var enabledMenuItem: NSMenuItem?
    private var statusMenuItem: NSMenuItem?
    private var launchAtLoginMenuItem: NSMenuItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        do {
            let configStore = try ConfigStore()
            let coordinator = try AppCoordinator(configStore: configStore)
            self.configStore = configStore
            self.coordinator = coordinator
            let settingsWindowController = SettingsWindowController(configStore: configStore)
            settingsWindowController.onSave = { [weak coordinator] in
                coordinator?.reloadConfiguration()
            }
            settingsWindowController.onVisibilityChange = { [weak coordinator] isVisible in
                coordinator?.setSettingsPresented(isVisible)
            }
            settingsWindowController.onRequestMonitorRetry = { [weak coordinator] in
                coordinator?.retryEventMonitor()
            }
            self.settingsWindowController = settingsWindowController
            configureStatusItem()

            coordinator.onStatusChange = { [weak self] status in
                self?.statusMenuItem?.title = "Status: \(status)"
            }
            coordinator.onEnabledChange = { [weak self] enabled in
                self?.enabledMenuItem?.state = enabled ? .on : .off
                self?.updateStatusIcon(isActive: enabled)
            }
            coordinator.start()

            let onboardingKey = "FlowTypeHasShownSettingsWindowV1"
            let needsPermissions = !Permissions.canRecordAudio
                || !Permissions.canMonitorInput
                || !Permissions.canInsertText
            if !UserDefaults.standard.bool(forKey: onboardingKey) || needsPermissions {
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
        coordinator?.shutdown()
    }

    private func configureStatusItem() {
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        self.statusItem = statusItem
        updateStatusIcon(isActive: true)

        let menu = NSMenu()

        menu.addItem(menuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ","))
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

    private func presentError(title: String, message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }
}
