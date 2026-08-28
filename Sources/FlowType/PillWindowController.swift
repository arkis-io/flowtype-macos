import AppKit

@MainActor
final class PillWindowController {
    enum Appearance {
        case held
        case handsFree
        case processing
        case error
        case update

        var color: NSColor {
            switch self {
            case .held: return .systemRed
            case .handsFree: return .systemOrange
            case .processing: return .systemBlue
            case .error: return .systemYellow
            case .update: return .systemGreen
            }
        }
    }

    private let panel: NSPanel
    private let label = NSTextField(labelWithString: "")
    private let indicator = NSView(frame: .zero)

    init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 230, height: 46),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let background = NSVisualEffectView(frame: panel.contentView?.bounds ?? .zero)
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 23
        background.layer?.masksToBounds = true
        background.autoresizingMask = [.width, .height]

        indicator.translatesAutoresizingMaskIntoConstraints = false
        indicator.wantsLayer = true
        indicator.layer?.cornerRadius = 5

        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = .white
        label.lineBreakMode = .byTruncatingTail

        background.addSubview(indicator)
        background.addSubview(label)
        NSLayoutConstraint.activate([
            indicator.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 17),
            indicator.centerYAnchor.constraint(equalTo: background.centerYAnchor),
            indicator.widthAnchor.constraint(equalToConstant: 10),
            indicator.heightAnchor.constraint(equalToConstant: 10),
            label.leadingAnchor.constraint(equalTo: indicator.trailingAnchor, constant: 10),
            label.trailingAnchor.constraint(lessThanOrEqualTo: background.trailingAnchor, constant: -17),
            label.centerYAnchor.constraint(equalTo: background.centerYAnchor)
        ])

        panel.contentView = background
    }

    func show(_ text: String, appearance: Appearance) {
        label.stringValue = text
        indicator.layer?.backgroundColor = appearance.color.cgColor
        positionOnActiveScreen()
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
    }

    private func positionOnActiveScreen() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let visibleFrame = screen?.visibleFrame else { return }
        let panelFrame = panel.frame
        panel.setFrameOrigin(NSPoint(
            x: visibleFrame.midX - panelFrame.width / 2,
            y: visibleFrame.minY + 64
        ))
    }
}
