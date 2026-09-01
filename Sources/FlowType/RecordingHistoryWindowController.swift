import AppKit
import AVFoundation

@MainActor
final class RecordingHistoryWindowController: NSObject, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    var onRetry: ((UUID) -> Void)?
    var onEntriesChange: (() -> Void)?
    var activeEntryIDs: (() -> Set<UUID>)?
    var isBusy: (() -> Bool)?

    private let store: RecordingHistoryStore
    private var windowController: NSWindowController?
    private var tableView: NSTableView?
    private var entries: [RecordingHistoryEntry] = []
    private var audioPlayer: AVAudioPlayer?
    private var playbackTimer: Timer?

    private let emptyLabel = NSTextField(labelWithString: "No retained recordings yet.")
    private let timeLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let providerLabel = NSTextField(labelWithString: "")
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private let expiryLabel = NSTextField(labelWithString: "")
    private let transcriptView = NSTextView()
    private let playButton = NSButton(title: "Play", target: nil, action: nil)
    private let retryButton = NSButton(title: "Retranscribe", target: nil, action: nil)
    private let copyButton = NSButton(title: "Copy", target: nil, action: nil)
    private let deleteButton = NSButton(title: "Delete…", target: nil, action: nil)
    private let playbackProgress = NSProgressIndicator()
    private let playbackLabel = NSTextField(labelWithString: "0:00 / 0:00")
    private let issueLabel = NSTextField(wrappingLabelWithString: "")

    init(store: RecordingHistoryStore) {
        self.store = store
        super.init()
    }

    var isVisible: Bool {
        windowController?.window?.isVisible == true
    }

    func showHistory() {
        ensureWindow()
        refresh()
        NSApp.activate(ignoringOtherApps: true)
        windowController?.showWindow(nil)
        windowController?.window?.makeKeyAndOrderFront(nil)
    }

    func refresh(preferredEntryID: UUID? = nil) {
        guard windowController != nil else { return }
        let selectedID = preferredEntryID ?? selectedEntry?.id
        do {
            let snapshot = try store.listEntries(activeIDs: activeEntryIDs?() ?? [])
            entries = snapshot.entries
            issueLabel.stringValue = snapshot.loadErrors.first.map { "Some entries were skipped: \($0)" } ?? ""
        } catch {
            entries = []
            issueLabel.stringValue = "History could not be loaded: \(error.localizedDescription)"
        }
        if let selectedID, !entries.contains(where: { $0.id == selectedID }) {
            stopPlayback()
        }
        tableView?.reloadData()
        if let selectedID, let index = entries.firstIndex(where: { $0.id == selectedID }) {
            tableView?.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        } else if !entries.isEmpty {
            tableView?.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        } else {
            tableView?.deselectAll(nil)
        }
        updateDetail()
    }

    func updateBusyState() {
        guard windowController != nil else { return }
        updateDetail()
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        entries.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("RecordingHistoryCell")
        let cell: NSTableCellView
        if let reused = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView {
            cell = reused
        } else {
            cell = NSTableCellView()
            cell.identifier = identifier
            let text = NSTextField(labelWithString: "")
            text.translatesAutoresizingMaskIntoConstraints = false
            text.lineBreakMode = .byTruncatingTail
            text.maximumNumberOfLines = 2
            cell.textField = text
            cell.addSubview(text)
            NSLayoutConstraint.activate([
                text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
                text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
                text.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
        }
        let entry = entries[row]
        let status = entry.status.rawValue.capitalized
        cell.textField?.stringValue = "\(Self.dateFormatter.string(from: entry.createdAt))  ·  \(Self.duration(entry.durationSeconds))\n\(status)"
        cell.textField?.textColor = entry.status == .failed ? .systemOrange : .labelColor
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        stopPlayback()
        updateDetail()
    }

    func windowWillClose(_ notification: Notification) {
        stopPlayback()
    }

    @objc private func togglePlayback() {
        guard let entry = selectedEntry else { return }
        if let audioPlayer {
            if audioPlayer.isPlaying {
                audioPlayer.pause()
                playButton.title = "Resume"
            } else {
                audioPlayer.play()
                playButton.title = "Pause"
                startPlaybackTimer()
            }
            return
        }

        do {
            guard let url = try store.audioURL(for: entry.id) else {
                throw RecordingHistoryStoreError.unavailable("The retained audio file is missing.")
            }
            let player = try AVAudioPlayer(contentsOf: url)
            guard player.prepareToPlay() else {
                throw RecordingHistoryStoreError.unavailable("macOS could not prepare this recording for playback.")
            }
            audioPlayer = player
            playbackProgress.maxValue = max(player.duration, 0.1)
            player.play()
            playButton.title = "Pause"
            startPlaybackTimer()
            updatePlaybackProgress()
        } catch {
            refresh(preferredEntryID: entry.id)
            issueLabel.stringValue = error.localizedDescription
        }
    }

    @objc private func retrySelected() {
        guard let id = selectedEntry?.id else { return }
        stopPlayback()
        onRetry?(id)
        refresh(preferredEntryID: id)
    }

    @objc private func copySelected() {
        guard let transcript = selectedEntry?.finalTranscript, !transcript.isEmpty else { return }
        NSPasteboard.general.clearContents()
        if !NSPasteboard.general.setString(transcript, forType: .string) {
            issueLabel.stringValue = "macOS could not place the transcript on the clipboard."
        }
    }

    @objc private func deleteSelected() {
        guard let entry = selectedEntry else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Delete this recording?"
        alert.informativeText = "Its retained audio and transcript will be permanently removed."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        stopPlayback()
        do {
            try store.delete(id: entry.id, activeIDs: activeEntryIDs?() ?? [])
            onEntriesChange?()
            refresh()
        } catch {
            refresh(preferredEntryID: entry.id)
            issueLabel.stringValue = "Delete failed: \(error.localizedDescription)"
        }
    }

    private var selectedEntry: RecordingHistoryEntry? {
        guard let row = tableView?.selectedRow, entries.indices.contains(row) else { return nil }
        return entries[row]
    }

    private func updateDetail() {
        guard let entry = selectedEntry else {
            emptyLabel.isHidden = false
            timeLabel.stringValue = ""
            statusLabel.stringValue = ""
            providerLabel.stringValue = ""
            errorLabel.stringValue = ""
            expiryLabel.stringValue = ""
            transcriptView.string = ""
            [playButton, retryButton, copyButton, deleteButton].forEach { $0.isEnabled = false }
            return
        }
        emptyLabel.isHidden = true
        timeLabel.stringValue = "Recorded \(Self.fullDateFormatter.string(from: entry.createdAt)) · \(Self.duration(entry.durationSeconds))"
        statusLabel.stringValue = "\(entry.status.rawValue.capitalized) · \(entry.stage.rawValue.capitalized) · \(entry.attemptCount) attempt\(entry.attemptCount == 1 ? "" : "s")"
        let original = entry.originalProvider ?? "Not attempted"
        let latest = entry.latestProvider ?? original
        providerLabel.stringValue = original == latest
            ? "Provider: \(latest)"
            : "Provider: \(original) originally · \(latest) latest"
        let errors = [
            entry.firstError.map { "First error: \($0)" },
            entry.latestError.flatMap { $0 == entry.firstError ? nil : "Latest error: \($0)" }
        ].compactMap { $0 }
        errorLabel.stringValue = errors.joined(separator: "\n")
        expiryLabel.stringValue = "Deletes automatically \(Self.fullDateFormatter.string(from: entry.createdAt.addingTimeInterval(RecordingHistoryStore.retentionInterval)))"
        transcriptView.string = entry.finalTranscript ?? entry.rawTranscript ?? "No transcript yet."

        let active = activeEntryIDs?().contains(entry.id) == true
        let busy = isBusy?() == true
        let eligibility = try? store.retryEligibility(for: entry.id, activeIDs: activeEntryIDs?() ?? [])
        if case .available = eligibility {
            retryButton.isEnabled = !busy
        } else {
            retryButton.isEnabled = false
        }
        playButton.isEnabled = !active && (try? store.audioURL(for: entry.id)) != nil
        copyButton.isEnabled = !(entry.finalTranscript ?? "").isEmpty
        deleteButton.isEnabled = !active
    }

    private func ensureWindow() {
        guard windowController == nil else { return }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 520),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Recording History"
        window.minSize = NSSize(width: 680, height: 430)
        window.center()
        window.delegate = self
        window.isReleasedWhenClosed = false

        let splitView = NSSplitView(frame: window.contentView?.bounds ?? .zero)
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.autoresizingMask = [.width, .height]

        let listContainer = NSView(frame: NSRect(x: 0, y: 0, width: 270, height: 520))
        let table = NSTableView()
        table.headerView = nil
        table.rowHeight = 52
        table.usesAlternatingRowBackgroundColors = true
        table.allowsEmptySelection = true
        table.delegate = self
        table.dataSource = self
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("recordings"))
        column.title = "Recordings"
        column.width = 270
        table.addTableColumn(column)
        let tableScroll = NSScrollView(frame: listContainer.bounds)
        tableScroll.documentView = table
        tableScroll.hasVerticalScroller = true
        tableScroll.autoresizingMask = [.width, .height]
        listContainer.addSubview(tableScroll)
        tableView = table

        let detail = makeDetailView(frame: NSRect(x: 0, y: 0, width: 550, height: 520))
        splitView.addSubview(listContainer)
        splitView.addSubview(detail)
        splitView.setPosition(270, ofDividerAt: 0)
        window.contentView = splitView
        windowController = NSWindowController(window: window)
    }

    private func makeDetailView(frame: NSRect) -> NSView {
        let view = NSView(frame: frame)
        let title = NSTextField(labelWithString: "Recording details")
        title.font = .systemFont(ofSize: 19, weight: .semibold)
        emptyLabel.textColor = .secondaryLabelColor
        statusLabel.textColor = .secondaryLabelColor
        providerLabel.textColor = .secondaryLabelColor
        expiryLabel.textColor = .tertiaryLabelColor
        errorLabel.textColor = .systemOrange
        issueLabel.textColor = .systemOrange
        issueLabel.maximumNumberOfLines = 2

        transcriptView.isEditable = false
        transcriptView.isSelectable = true
        transcriptView.font = .systemFont(ofSize: 14)
        transcriptView.textContainerInset = NSSize(width: 8, height: 8)
        let transcriptScroll = NSScrollView()
        transcriptScroll.documentView = transcriptView
        transcriptScroll.hasVerticalScroller = true
        transcriptScroll.borderType = .bezelBorder

        playbackProgress.style = .bar
        playbackProgress.isIndeterminate = false
        playbackProgress.minValue = 0
        playbackProgress.maxValue = 1

        playButton.target = self
        playButton.action = #selector(togglePlayback)
        retryButton.target = self
        retryButton.action = #selector(retrySelected)
        copyButton.target = self
        copyButton.action = #selector(copySelected)
        deleteButton.target = self
        deleteButton.action = #selector(deleteSelected)

        let playbackRow = NSStackView(views: [playButton, playbackProgress, playbackLabel])
        playbackRow.orientation = .horizontal
        playbackRow.spacing = 8
        playbackProgress.widthAnchor.constraint(greaterThanOrEqualToConstant: 150).isActive = true
        let actionRow = NSStackView(views: [retryButton, copyButton, deleteButton])
        actionRow.orientation = .horizontal
        actionRow.spacing = 8
        actionRow.alignment = .centerY

        let stack = NSStackView(views: [
            title,
            emptyLabel,
            timeLabel,
            statusLabel,
            providerLabel,
            errorLabel,
            expiryLabel,
            transcriptScroll,
            playbackRow,
            actionRow,
            issueLabel
        ])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 9
        transcriptScroll.translatesAutoresizingMaskIntoConstraints = false
        transcriptScroll.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        transcriptScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true
        issueLabel.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        errorLabel.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -16)
        ])
        return view
    }

    private func startPlaybackTimer() {
        playbackTimer?.invalidate()
        playbackTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.updatePlaybackProgress()
                if let player = self.audioPlayer,
                   !player.isPlaying,
                   player.currentTime >= player.duration - 0.05 {
                    self.stopPlayback()
                }
            }
        }
    }

    private func updatePlaybackProgress() {
        guard let player = audioPlayer else {
            playbackProgress.doubleValue = 0
            playbackLabel.stringValue = "0:00 / 0:00"
            return
        }
        playbackProgress.maxValue = max(player.duration, 0.1)
        playbackProgress.doubleValue = player.currentTime
        playbackLabel.stringValue = "\(Self.duration(player.currentTime)) / \(Self.duration(player.duration))"
    }

    private func stopPlayback() {
        playbackTimer?.invalidate()
        playbackTimer = nil
        audioPlayer?.stop()
        audioPlayer = nil
        playButton.title = "Play"
        updatePlaybackProgress()
    }

    private static func duration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()

    private static let fullDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}
