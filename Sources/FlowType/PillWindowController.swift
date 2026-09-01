import AppKit
import QuartzCore

private enum FlowTypePalette {
    static let navy = NSColor(srgbRed: 0.018, green: 0.035, blue: 0.105, alpha: 1)
    static let cyan = NSColor(srgbRed: 0.22, green: 0.78, blue: 1.0, alpha: 1)
    static let pearl = NSColor(srgbRed: 0.84, green: 0.88, blue: 0.98, alpha: 1)
    static let coral = NSColor(srgbRed: 1.0, green: 0.38, blue: 0.31, alpha: 1)
    static let mint = NSColor(srgbRed: 0.30, green: 0.88, blue: 0.70, alpha: 1)
    static let amber = NSColor(srgbRed: 1.0, green: 0.70, blue: 0.18, alpha: 1)
}

@MainActor
final class PillWindowController {
    enum Appearance {
        case held
        case handsFree
        case processing
        case success
        case error
        case update

        var color: NSColor {
            switch self {
            case .held, .handsFree: return FlowTypePalette.coral
            case .processing, .update: return FlowTypePalette.cyan
            case .success: return FlowTypePalette.mint
            case .error: return FlowTypePalette.amber
            }
        }

        var medallionColors: [NSColor] {
            switch self {
            case .held, .handsFree:
                return [FlowTypePalette.pearl, FlowTypePalette.coral]
            case .processing, .update:
                return [FlowTypePalette.pearl, FlowTypePalette.cyan]
            case .success:
                return [FlowTypePalette.cyan, FlowTypePalette.mint]
            case .error:
                return [FlowTypePalette.coral, FlowTypePalette.amber]
            }
        }

        var symbolName: String {
            switch self {
            case .held: return "mic.fill"
            case .handsFree: return "record.circle.fill"
            case .processing: return "ellipsis"
            case .success: return "checkmark"
            case .error: return "exclamationmark"
            case .update: return "arrow.down"
            }
        }

        var showsLiveLevel: Bool {
            self == .held || self == .handsFree
        }

        var showsWaveform: Bool {
            self == .held || self == .handsFree || self == .processing
        }
    }

    private static let canvasSize = NSSize(width: 350, height: 74)
    private static let bubbleHeight: CGFloat = 46
    private static let collapsedWidth: CGFloat = 46

    private let panel: NSPanel
    private let rootView: NSView
    private let bubble: MorphingCapsuleView
    private let content: PillContentView
    private var processingTimer: Timer?
    private var autoHideWorkItem: DispatchWorkItem?
    private var presentationGeneration = 0
    private var appearance: Appearance = .processing
    private var expandedWidth: CGFloat = 180
    private var reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

    init() {
        content = PillContentView(frame: .zero)
        bubble = MorphingCapsuleView(frame: .zero, contentView: content)
        rootView = NSView(frame: NSRect(origin: .zero, size: Self.canvasSize))
        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.canvasSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.isOpaque = false
        panel.backgroundColor = .clear
        // The visible capsule owns a shape-following shadow. A window-level shadow
        // follows the rectangular canvas and creates the double border seen before.
        panel.hasShadow = false
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.animationBehavior = .none

        rootView.wantsLayer = true
        rootView.layer?.backgroundColor = NSColor.clear.cgColor
        bubble.frame = bubbleFrame(width: Self.collapsedWidth)
        rootView.addSubview(bubble)
        panel.contentView = rootView
        panel.orderOut(nil)

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(accessibilityDisplayOptionsChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil
        )
    }

    deinit {
        processingTimer?.invalidate()
        autoHideWorkItem?.cancel()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    func show(
        _ text: String,
        appearance: Appearance,
        autoHideAfter: TimeInterval? = nil
    ) {
        presentationGeneration += 1
        let generation = presentationGeneration
        autoHideWorkItem?.cancel()
        autoHideWorkItem = nil
        processingTimer?.invalidate()
        processingTimer = nil
        self.appearance = appearance
        reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        bubble.setBrandMotionEnabled(!reduceMotion)

        let wasVisible = panel.isVisible
        if wasVisible && !reduceMotion {
            content.prepareForStateChange()
        }
        content.configure(text: text, appearance: appearance, reduceMotion: reduceMotion)
        expandedWidth = content.preferredExpandedWidth()

        panel.setFrameOrigin(targetOriginOnActiveScreen())
        panel.alphaValue = 1

        let targetFrame = bubbleFrame(width: expandedWidth)
        if !wasVisible {
            bubble.frame = reduceMotion ? targetFrame : bubbleFrame(width: Self.collapsedWidth)
            bubble.alphaValue = reduceMotion ? 1 : 0
            content.prepareForEntrance(expanded: reduceMotion)
            panel.orderFrontRegardless()

            if !reduceMotion {
                bubble.animateEntranceScale()
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.30
                    context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    bubble.animator().frame = targetFrame
                    bubble.animator().alphaValue = 1
                    content.revealExpanded(animated: true)
                }
            }
        } else if reduceMotion {
            bubble.frame = targetFrame
            bubble.alphaValue = 1
            content.revealExpanded(animated: false)
            panel.orderFrontRegardless()
        } else {
            bubble.alphaValue = 1
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.24
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                bubble.animator().frame = targetFrame
                content.revealExpanded(animated: true)
            }
        }

        startProcessingAnimationIfNeeded()
        if let autoHideAfter {
            let workItem = DispatchWorkItem { [weak self] in
                guard let self, self.presentationGeneration == generation else { return }
                self.hide()
            }
            autoHideWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + autoHideAfter, execute: workItem)
        }
    }

    func updateInputLevel(_ level: Float) {
        guard appearance.showsLiveLevel else { return }
        content.updateInputLevel(level, reduceMotion: reduceMotion)
    }

    func hide() {
        presentationGeneration += 1
        autoHideWorkItem?.cancel()
        autoHideWorkItem = nil
        processingTimer?.invalidate()
        processingTimer = nil
        content.stopAnimations()
        bubble.setBrandMotionEnabled(false)
        guard panel.isVisible else {
            panel.orderOut(nil)
            return
        }

        let generation = presentationGeneration
        if reduceMotion {
            panel.orderOut(nil)
            bubble.frame = bubbleFrame(width: Self.collapsedWidth)
            bubble.alphaValue = 1
            content.prepareForEntrance(expanded: false)
        } else {
            let collapsedFrame = bubbleFrame(width: Self.collapsedWidth)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.20
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                content.collapseToOrb(animated: true)
                bubble.animator().frame = collapsedFrame
                bubble.animator().alphaValue = 0
            } completionHandler: { [weak self] in
                Task { @MainActor in
                    guard let self, self.presentationGeneration == generation else { return }
                    self.panel.orderOut(nil)
                    self.bubble.frame = collapsedFrame
                    self.bubble.alphaValue = 1
                    self.content.prepareForEntrance(expanded: false)
                }
            }
        }
    }

    @objc private func accessibilityDisplayOptionsChanged() {
        reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        processingTimer?.invalidate()
        processingTimer = nil
        content.setReduceMotion(reduceMotion)
        bubble.setBrandMotionEnabled(panel.isVisible && !reduceMotion)
        if panel.isVisible && reduceMotion {
            bubble.layer?.removeAllAnimations()
            bubble.frame = bubbleFrame(width: expandedWidth)
            bubble.alphaValue = 1
            content.revealExpanded(animated: false)
        }
        startProcessingAnimationIfNeeded()
    }

    private func startProcessingAnimationIfNeeded() {
        guard appearance == .processing, !reduceMotion, panel.isVisible else { return }
        processingTimer?.invalidate()
        processingTimer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.content.advanceProcessingFrame() }
        }
    }

    private func bubbleFrame(width: CGFloat) -> NSRect {
        NSRect(
            x: (Self.canvasSize.width - width) / 2,
            y: (Self.canvasSize.height - Self.bubbleHeight) / 2,
            width: width,
            height: Self.bubbleHeight
        )
    }

    private func targetOriginOnActiveScreen() -> NSPoint {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let visibleFrame = screen?.visibleFrame else { return panel.frame.origin }
        return NSPoint(
            x: visibleFrame.midX - panel.frame.width / 2,
            y: visibleFrame.minY + 54
        )
    }
}

@MainActor
private final class MorphingCapsuleView: NSView {
    private let surfaceView = NSVisualEffectView(frame: .zero)
    private let tintView = NSView(frame: .zero)
    private let brandGlowLayer = CAGradientLayer()
    private let lightSweepLayer = CAGradientLayer()
    private let highlightLayer = CAGradientLayer()
    private let pillContentView: NSView

    init(frame frameRect: NSRect, contentView: NSView) {
        pillContentView = contentView
        super.init(frame: frameRect)

        wantsLayer = true
        layer?.masksToBounds = false
        layer?.shadowColor = FlowTypePalette.navy.cgColor
        layer?.shadowOpacity = 0.46
        layer?.shadowRadius = 13
        layer?.shadowOffset = NSSize(width: 0, height: -3)

        surfaceView.material = .hudWindow
        surfaceView.blendingMode = .behindWindow
        surfaceView.state = .active
        surfaceView.wantsLayer = true
        addSubview(surfaceView)

        tintView.wantsLayer = true
        tintView.layer?.backgroundColor = FlowTypePalette.navy.withAlphaComponent(0.88).cgColor
        tintView.layer?.addSublayer(brandGlowLayer)
        tintView.layer?.addSublayer(lightSweepLayer)
        tintView.layer?.addSublayer(highlightLayer)
        addSubview(tintView)

        brandGlowLayer.colors = [
            FlowTypePalette.cyan.withAlphaComponent(0.16).cgColor,
            FlowTypePalette.pearl.withAlphaComponent(0.025).cgColor,
            FlowTypePalette.coral.withAlphaComponent(0.14).cgColor
        ]
        brandGlowLayer.locations = [0, 0.50, 1]
        brandGlowLayer.startPoint = CGPoint(x: 0, y: 1)
        brandGlowLayer.endPoint = CGPoint(x: 1, y: 0)

        lightSweepLayer.colors = [
            NSColor.clear.cgColor,
            FlowTypePalette.cyan.withAlphaComponent(0.07).cgColor,
            FlowTypePalette.pearl.withAlphaComponent(0.16).cgColor,
            FlowTypePalette.coral.withAlphaComponent(0.07).cgColor,
            NSColor.clear.cgColor
        ]
        lightSweepLayer.locations = [0, 0.30, 0.50, 0.70, 1]
        lightSweepLayer.startPoint = CGPoint(x: 0, y: 0.5)
        lightSweepLayer.endPoint = CGPoint(x: 1, y: 0.5)

        highlightLayer.colors = [
            FlowTypePalette.pearl.withAlphaComponent(0.12).cgColor,
            FlowTypePalette.pearl.withAlphaComponent(0.025).cgColor,
            NSColor.clear.cgColor
        ]
        highlightLayer.locations = [0, 0.46, 1]
        highlightLayer.startPoint = CGPoint(x: 0.5, y: 1)
        highlightLayer.endPoint = CGPoint(x: 0.5, y: 0)

        addSubview(pillContentView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        let radius = bounds.height / 2
        surfaceView.frame = bounds
        tintView.frame = bounds
        pillContentView.frame = bounds
        surfaceView.layer?.cornerRadius = radius
        surfaceView.layer?.cornerCurve = .continuous
        surfaceView.layer?.masksToBounds = true
        tintView.layer?.cornerRadius = radius
        tintView.layer?.cornerCurve = .continuous
        tintView.layer?.masksToBounds = true
        brandGlowLayer.frame = tintView.bounds
        lightSweepLayer.frame = NSRect(x: -120, y: 0, width: 120, height: tintView.bounds.height)
        highlightLayer.frame = tintView.bounds
        layer?.cornerRadius = radius
        layer?.cornerCurve = .continuous
        layer?.shadowPath = CGPath(
            roundedRect: bounds,
            cornerWidth: radius,
            cornerHeight: radius,
            transform: nil
        )
    }

    func animateEntranceScale() {
        guard let layer else { return }
        let animation = CASpringAnimation(keyPath: "transform.scale")
        animation.fromValue = 0.84
        animation.toValue = 1
        animation.mass = 1
        animation.stiffness = 310
        animation.damping = 24
        animation.initialVelocity = 0
        animation.duration = min(animation.settlingDuration, 0.46)
        layer.add(animation, forKey: "capsuleEntranceScale")
    }

    func setBrandMotionEnabled(_ enabled: Bool) {
        lightSweepLayer.removeAnimation(forKey: "brandLightSweep")
        guard enabled else { return }
        let animation = CABasicAnimation(keyPath: "transform.translation.x")
        animation.fromValue = 0
        animation.toValue = 470
        animation.duration = 4.8
        animation.beginTime = CACurrentMediaTime() + 0.35
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        lightSweepLayer.add(animation, forKey: "brandLightSweep")
    }
}

@MainActor
private final class PillContentView: NSView {
    private let orb = NSView(frame: .zero)
    private let orbGradientLayer = CAGradientLayer()
    private let expandedGroup = NSView(frame: .zero)
    private let symbolBackground = NSView(frame: .zero)
    private let symbolGradientLayer = CAGradientLayer()
    private let symbolView = NSImageView(frame: .zero)
    private let ribbons = FlowRibbonsView(frame: .zero)
    private let primaryLabel = NSTextField(labelWithString: "")
    private let secondaryLabel = NSTextField(labelWithString: "")
    private var pillAppearance: PillWindowController.Appearance = .processing
    private var hasSecondaryText = false
    private var reduceMotion = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true

        orb.wantsLayer = true
        orb.layer?.cornerRadius = 7
        orb.layer?.shadowRadius = 9
        orb.layer?.shadowOpacity = 0.7
        orb.layer?.shadowOffset = .zero
        orb.layer?.masksToBounds = false
        orbGradientLayer.colors = [FlowTypePalette.cyan.cgColor, FlowTypePalette.coral.cgColor]
        orbGradientLayer.startPoint = CGPoint(x: 0, y: 1)
        orbGradientLayer.endPoint = CGPoint(x: 1, y: 0)
        orbGradientLayer.cornerRadius = 7
        orb.layer?.addSublayer(orbGradientLayer)
        addSubview(orb)

        expandedGroup.wantsLayer = true
        addSubview(expandedGroup)

        symbolBackground.wantsLayer = true
        symbolBackground.layer?.cornerRadius = 11
        symbolBackground.layer?.cornerCurve = .continuous
        symbolBackground.layer?.shadowRadius = 7
        symbolBackground.layer?.shadowOffset = .zero
        symbolGradientLayer.startPoint = CGPoint(x: 0, y: 1)
        symbolGradientLayer.endPoint = CGPoint(x: 1, y: 0)
        symbolGradientLayer.cornerRadius = 11
        symbolBackground.layer?.addSublayer(symbolGradientLayer)
        expandedGroup.addSubview(symbolBackground)

        symbolView.imageScaling = .scaleProportionallyDown
        symbolView.contentTintColor = .white
        symbolBackground.addSubview(symbolView)

        expandedGroup.addSubview(ribbons)

        primaryLabel.font = .systemFont(ofSize: 12.5, weight: .semibold)
        primaryLabel.textColor = FlowTypePalette.pearl
        primaryLabel.lineBreakMode = .byTruncatingTail
        primaryLabel.maximumNumberOfLines = 1
        expandedGroup.addSubview(primaryLabel)

        secondaryLabel.font = .systemFont(ofSize: 9.5, weight: .medium)
        secondaryLabel.textColor = FlowTypePalette.pearl.withAlphaComponent(0.62)
        secondaryLabel.lineBreakMode = .byTruncatingTail
        secondaryLabel.maximumNumberOfLines = 1
        expandedGroup.addSubview(secondaryLabel)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        expandedGroup.frame = bounds
        orb.frame = NSRect(x: bounds.midX - 7, y: bounds.midY - 7, width: 14, height: 14)
        orbGradientLayer.frame = orb.bounds

        let symbolSize: CGFloat = 22
        let leftPadding: CGFloat = 12
        symbolBackground.frame = NSRect(
            x: leftPadding,
            y: bounds.midY - symbolSize / 2,
            width: symbolSize,
            height: symbolSize
        )
        symbolGradientLayer.frame = symbolBackground.bounds
        symbolView.frame = NSRect(x: 5, y: 5, width: 12, height: 12)

        var nextX = symbolBackground.frame.maxX + 8
        if pillAppearance.showsWaveform {
            ribbons.isHidden = false
            ribbons.frame = NSRect(x: nextX, y: bounds.midY - 11, width: 34, height: 22)
            nextX = ribbons.frame.maxX + 10
        } else {
            ribbons.isHidden = true
        }

        let availableTextWidth = max(0, bounds.width - nextX - 16)
        if hasSecondaryText {
            primaryLabel.frame = NSRect(x: nextX, y: bounds.midY, width: availableTextWidth, height: 15)
            secondaryLabel.frame = NSRect(x: nextX, y: bounds.midY - 13, width: availableTextWidth, height: 12)
        } else {
            primaryLabel.frame = NSRect(x: nextX, y: bounds.midY - 8, width: availableTextWidth, height: 17)
            secondaryLabel.frame = .zero
        }
    }

    func configure(
        text: String,
        appearance: PillWindowController.Appearance,
        reduceMotion: Bool
    ) {
        pillAppearance = appearance
        self.reduceMotion = reduceMotion
        let parts = split(text: text)
        primaryLabel.stringValue = parts.primary
        secondaryLabel.stringValue = parts.secondary ?? ""
        secondaryLabel.isHidden = parts.secondary == nil
        hasSecondaryText = parts.secondary != nil

        symbolView.image = NSImage(
            systemSymbolName: appearance.symbolName,
            accessibilityDescription: text
        )
        symbolGradientLayer.colors = appearance.medallionColors.map { $0.cgColor }
        symbolBackground.layer?.shadowColor = appearance.color.cgColor
        orb.layer?.shadowColor = appearance.color.cgColor
        ribbons.configure(live: appearance.showsLiveLevel)
        configureLivePulse(enabled: appearance.showsLiveLevel && !reduceMotion)
        setAccessibilityElement(true)
        setAccessibilityLabel(text)
        needsLayout = true
    }

    func preferredExpandedWidth() -> CGFloat {
        let primaryWidth = primaryLabel.intrinsicContentSize.width
        let secondaryWidth = hasSecondaryText ? secondaryLabel.intrinsicContentSize.width : 0
        let textWidth = ceil(max(primaryWidth, secondaryWidth))
        let ribbonWidth: CGFloat = pillAppearance.showsWaveform ? 44 : 0
        let chromeWidth: CGFloat = 12 + 22 + 8 + ribbonWidth + 10 + 16
        return min(max(chromeWidth + textWidth, 132), 318)
    }

    func prepareForEntrance(expanded: Bool) {
        expandedGroup.alphaValue = expanded ? 1 : 0
        orb.alphaValue = expanded ? 0 : 1
    }

    func prepareForStateChange() {
        expandedGroup.alphaValue = 0
        orb.alphaValue = 0
    }

    func revealExpanded(animated: Bool) {
        if animated {
            expandedGroup.animator().alphaValue = 1
            orb.animator().alphaValue = 0
        } else {
            expandedGroup.alphaValue = 1
            orb.alphaValue = 0
        }
    }

    func collapseToOrb(animated: Bool) {
        if animated {
            expandedGroup.animator().alphaValue = 0
            orb.animator().alphaValue = 1
        } else {
            expandedGroup.alphaValue = 0
            orb.alphaValue = 1
        }
    }

    func updateInputLevel(_ level: Float, reduceMotion: Bool) {
        ribbons.update(level: level, reduceMotion: reduceMotion)
    }

    func advanceProcessingFrame() {
        ribbons.advanceProcessingFrame()
    }

    func setReduceMotion(_ enabled: Bool) {
        reduceMotion = enabled
        ribbons.setReduceMotion(enabled)
        configureLivePulse(enabled: pillAppearance.showsLiveLevel && !enabled)
    }

    func stopAnimations() {
        ribbons.stop()
        symbolBackground.layer?.removeAnimation(forKey: "livePulse")
    }

    private func configureLivePulse(enabled: Bool) {
        symbolBackground.layer?.removeAnimation(forKey: "livePulse")
        symbolBackground.layer?.shadowOpacity = enabled ? 0.36 : 0.18
        guard enabled, let layer = symbolBackground.layer else { return }
        let animation = CABasicAnimation(keyPath: "shadowOpacity")
        animation.fromValue = 0.18
        animation.toValue = 0.56
        animation.duration = 0.90
        animation.autoreverses = true
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(animation, forKey: "livePulse")
    }

    private func split(text: String) -> (primary: String, secondary: String?) {
        for separator in [" · ", " — "] {
            guard let range = text.range(of: separator) else { continue }
            let primary = String(text[..<range.lowerBound])
            let secondary = String(text[range.upperBound...])
            return (primary, secondary.isEmpty ? nil : secondary)
        }
        return (text, nil)
    }
}

@MainActor
private final class FlowRibbonsView: NSView {
    private let ribbonColors = [
        FlowTypePalette.cyan,
        FlowTypePalette.pearl,
        FlowTypePalette.coral
    ]
    private var smoothedLevel: CGFloat = 0.18
    private var phase: CGFloat = 0
    private var isLive = false
    private var reduceMotion = false

    override var isFlipped: Bool { true }

    func configure(live: Bool) {
        isLive = live
        phase = live ? 0.35 : 1.1
        smoothedLevel = live ? 0.18 : 0.42
        needsDisplay = true
    }

    func update(level: Float, reduceMotion: Bool) {
        self.reduceMotion = reduceMotion
        let target = CGFloat(min(max(level, 0), 1))
        smoothedLevel = reduceMotion ? max(0.22, target) : smoothedLevel * 0.58 + target * 0.42
        if !reduceMotion {
            phase += 0.34
        }
        needsDisplay = true
    }

    func setReduceMotion(_ enabled: Bool) {
        reduceMotion = enabled
        needsDisplay = true
    }

    func advanceProcessingFrame() {
        guard !reduceMotion, !isLive else { return }
        phase += 0.42
        needsDisplay = true
    }

    func stop() {
        phase = 0
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let leftX: CGFloat = 1.5
        let rightX = bounds.width - 1.5
        let centerY = bounds.midY
        let activity = reduceMotion ? 0.34 : max(0.18, smoothedLevel)

        for index in 0..<3 {
            let indexOffset = CGFloat(index - 1)
            let color = ribbonColors[index]
            let emphasis: CGFloat
            if isLive {
                emphasis = index == 2 ? 1 : (index == 1 ? 0.82 : 0.70)
            } else {
                emphasis = index == 0 ? 1 : (index == 1 ? 0.82 : 0.64)
            }

            let startY = centerY + indexOffset * 2.2
            let endY = centerY + indexOffset * 5.1
            let oscillation = sin(phase + CGFloat(index) * 1.15)
            let amplitude = (0.8 + activity * (index == 1 ? 3.6 : 2.8)) * oscillation
            let path = NSBezierPath()
            path.move(to: NSPoint(x: leftX, y: startY))
            path.curve(
                to: NSPoint(x: rightX, y: endY),
                controlPoint1: NSPoint(x: bounds.width * 0.32, y: startY + amplitude),
                controlPoint2: NSPoint(x: bounds.width * 0.66, y: endY - amplitude)
            )
            path.lineWidth = index == 1 ? 1.8 : 1.55
            path.lineCapStyle = .round
            path.lineJoinStyle = .round

            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = color.withAlphaComponent(0.42 * emphasis)
            shadow.shadowBlurRadius = 3.2
            shadow.shadowOffset = .zero
            shadow.set()
            color.withAlphaComponent(0.94 * emphasis).setStroke()
            path.stroke()
            NSGraphicsContext.restoreGraphicsState()
        }
    }
}
