import AppKit
import CoreGraphics
import Foundation

final class TextInsertionService {
    func insert(_ text: String, config: ClipboardConfig) throws {
        let pasteboard = NSPasteboard.general
        let previousClipboard = config.restorePrevious ? ClipboardSnapshot(pasteboard: pasteboard) : nil

        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            throw FlowTypeError.insertion("The transcript was ready, but macOS would not place it on the clipboard.")
        }

        guard Permissions.canInsertText else {
            throw FlowTypeError.permission("The transcript is on the clipboard, but Accessibility permission is required to press Cmd-V automatically.")
        }

        guard let source = CGEventSource(stateID: .hidSystemState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else {
            throw FlowTypeError.insertion("The transcript is on the clipboard, but FlowType could not create the Cmd-V keyboard events.")
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)

        if let previousClipboard {
            let delay = max(0, config.restoreDelayMilliseconds)
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(delay)) {
                previousClipboard.restore(to: pasteboard)
            }
        }
    }
}

private struct ClipboardSnapshot {
    struct Item {
        let values: [(NSPasteboard.PasteboardType, Data)]
    }

    let items: [Item]

    init(pasteboard: NSPasteboard) {
        items = (pasteboard.pasteboardItems ?? []).map { pasteboardItem in
            Item(values: pasteboardItem.types.compactMap { type in
                pasteboardItem.data(forType: type).map { (type, $0) }
            })
        }
    }

    func restore(to pasteboard: NSPasteboard) {
        let restoredItems: [NSPasteboardItem] = items.map { item in
            let pasteboardItem = NSPasteboardItem()
            for (type, data) in item.values {
                pasteboardItem.setData(data, forType: type)
            }
            return pasteboardItem
        }
        pasteboard.clearContents()
        if !restoredItems.isEmpty {
            pasteboard.writeObjects(restoredItems)
        }
    }
}
