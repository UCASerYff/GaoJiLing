import AppKit

extension Notification.Name {
    static let monitorResetEdgeHandle = Notification.Name("GaoJiLing.ResetEdgeHandle")
    static let monitorDockEdgeHandle = Notification.Name("GaoJiLing.DockEdgeHandle")
}

enum EdgeHandleScreen {
    static func identifier(of screen: NSScreen) -> String? {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let uuid = CGDisplayCreateUUIDFromDisplayID(CGDirectDisplayID(number.uint32Value)) else { return nil }
        return CFUUIDCreateString(nil, uuid.takeRetainedValue()) as String
    }

    static func resolve(_ identifier: String?) -> NSScreen? {
        if let identifier, let known = NSScreen.screens.first(where: { self.identifier(of: $0) == identifier }) { return known }
        return NSScreen.main ?? NSScreen.screens.first
    }

    static func containing(_ point: NSPoint) -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(point) }
    }
}

@MainActor final class EdgeHandleController {
    static let ratioDefaultsKey = "GaoJiLing.EdgeHandle.verticalRatio"
    static let horizontalRatioDefaultsKey = "GaoJiLing.EdgeHandle.horizontalRatio"
    static let displayDefaultsKey = "GaoJiLing.EdgeHandle.displayUUID"

    /// Anchor is the strip's complete hit frame in global AppKit coordinates.
    var onOpen: ((NSScreen, NSRect, Bool) -> Void)?
    var onDragBegan: (() -> Void)?
    var onEdgeChanged: ((String) -> Void)?

    private let window: EdgeHandlePanel
    private let stripView: EdgeHandleView
    private let defaults: UserDefaults
    private var enabled = true
    private var expanded = false
    private var suspended = false
    private var edge = "right"
    private var hasConfiguredEdge = false
    private var verticalRatio: Double
    private var horizontalRatio: Double?
    private var displayIdentifier: String?
    private var hoverSince: Date?
    private var suppressHoverUntil = Date.distantPast
    private var requiresPointerExit = false
    private var placedScreen: NSScreen?

    var isInteracting: Bool { window.isPressed }
    var frame: NSRect { window.frame }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        verticalRatio = EdgeHandleGeometry.clamp(defaults.object(forKey: Self.ratioDefaultsKey) as? Double ?? 0.5)
        horizontalRatio = (defaults.object(forKey: Self.horizontalRatioDefaultsKey) as? Double).map(EdgeHandleGeometry.clamp)
        displayIdentifier = defaults.string(forKey: Self.displayDefaultsKey)
        window = EdgeHandlePanel(contentRect: NSRect(origin: .zero, size: EdgeHandleGeometry.hitSize),
                                 styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        stripView = EdgeHandleView(frame: NSRect(origin: .zero, size: EdgeHandleGeometry.hitSize))
        window.title = "搞机灵 · 拖动唤起条"
        window.level = .floating
        window.isFloatingPanel = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        window.contentView = stripView
        stripView.toolTip = "悬停或点击展开；按住可自由移动，也可跨屏拖动，仅靠近左右边缘时吸附。"
        stripView.onPress = { [weak self] in self?.open(manual: true) }
        window.onPressBegan = { [weak self] in
            self?.hoverSince = nil
            self?.stripView.dragging = false
        }
        window.onDragBegan = { [weak self] in
            self?.stripView.dragging = true
            self?.hoverSince = nil
            self?.onDragBegan?()
        }
        window.onDrag = { [weak self] pointer, offset in self?.drag(to: pointer, offset: offset) }
        window.onRelease = { [weak self] dragged in self?.release(dragged: dragged) }
    }

    func update(enabled: Bool, edge: String, restorePosition: Bool = false) {
        self.enabled = enabled
        hoverSince = nil
        guard !isInteracting else { return }
        let selectedEdge = edge == "left" ? "left" : "right"
        let changedSide = hasConfiguredEdge && self.edge != selectedEdge && !restorePosition
        self.edge = selectedEdge
        hasConfiguredEdge = true
        // Backup restoration changes defaults before broadcasting settings.
        verticalRatio = EdgeHandleGeometry.clamp(defaults.object(forKey: Self.ratioDefaultsKey) as? Double ?? 0.5)
        horizontalRatio = (defaults.object(forKey: Self.horizontalRatioDefaultsKey) as? Double).map(EdgeHandleGeometry.clamp)
        displayIdentifier = defaults.string(forKey: Self.displayDefaultsKey)
        if changedSide {
            horizontalRatio = selectedEdge == "left" ? 0 : 1
            persist()
        }
        reposition()
    }

    /// Available while the strip window is hidden or disabled, without moving it.
    func anchor(on screen: NSScreen) -> NSRect? {
        let identifier = EdgeHandleScreen.identifier(of: screen)
        if let displayIdentifier {
            guard identifier == displayIdentifier else { return nil }
        } else {
            guard let fallback = EdgeHandleScreen.resolve(nil),
                  EdgeHandleScreen.identifier(of: fallback) == identifier else { return nil }
        }
        return EdgeHandleGeometry.frame(in: screen.visibleFrame, edge: edge,
                                         verticalRatio: verticalRatio, horizontalRatio: horizontalRatio)
    }

    func commitPanelPosition(_ frame: NSRect, on screen: NSScreen, edge: String) {
        let anchor = FloatingPanelGeometry.anchor(for: frame, in: screen.visibleFrame, edge: edge)
        self.edge = dockedEdge(for: anchor, in: screen.visibleFrame) ?? (edge == "left" ? "left" : "right")
        verticalRatio = EdgeHandleGeometry.ratio(for: anchor, in: screen.visibleFrame)
        horizontalRatio = EdgeHandleGeometry.horizontalRatio(for: anchor, in: screen.visibleFrame)
        displayIdentifier = EdgeHandleScreen.identifier(of: screen)
        placedScreen = screen
        persist()
        reposition()
        onEdgeChanged?(self.edge)
    }

    func setExpanded(_ expanded: Bool) {
        let wasExpanded = self.expanded
        self.expanded = expanded
        hoverSince = nil
        stripView.hovered = false
        if wasExpanded && !expanded { requiresPointerExit = true }
        if expanded { window.orderOut(nil) } else { reposition() }
    }

    func suspend() {
        suspended = true
        window.cancelInteraction()
        hoverSince = nil
        window.orderOut(nil)
    }

    func resume() {
        suspended = false
        suppressHoverUntil = Date().addingTimeInterval(0.8)
        reposition()
    }

    func reset() {
        window.cancelInteraction()
        verticalRatio = 0.5
        horizontalRatio = edge == "left" ? 0 : 1
        displayIdentifier = (EdgeHandleScreen.containing(NSEvent.mouseLocation) ?? NSScreen.main ?? NSScreen.screens.first)
            .flatMap { EdgeHandleScreen.identifier(of: $0) }
        persist()
        hoverSince = nil
        suppressHoverUntil = Date().addingTimeInterval(0.8)
        reposition()
    }

    func dock() {
        window.cancelInteraction()
        horizontalRatio = edge == "left" ? 0 : 1
        persist()
        hoverSince = nil
        suppressHoverUntil = Date().addingTimeInterval(0.8)
        reposition()
    }

    func screensChanged() {
        window.cancelInteraction()
        stripView.dragging = false
        hoverSince = nil
        reposition()
    }

    /// Called by the application's existing pointer timer; no second polling loop.
    func checkPointer(delay: TimeInterval, canOpen: Bool) {
        guard enabled, !expanded, !suspended, window.isVisible else { hoverSince = nil; return }
        let inside = window.frame.contains(NSEvent.mouseLocation)
        stripView.hovered = inside
        if requiresPointerExit {
            if !inside { requiresPointerExit = false }
            hoverSince = nil
            return
        }
        guard inside, canOpen, !window.isPressed, NSEvent.pressedMouseButtons == 0,
              Date() >= suppressHoverUntil else { hoverSince = nil; return }
        if hoverSince == nil { hoverSince = Date() }
        if Date().timeIntervalSince(hoverSince!) >= max(0.2, delay) {
            hoverSince = nil
            open(manual: false)
        }
    }

    private func reposition() {
        guard !window.isPressed else { return }
        guard enabled, !expanded, !suspended, let screen = EdgeHandleScreen.resolve(displayIdentifier) else {
            window.orderOut(nil); return
        }
        placedScreen = screen
        // A disconnected display falls back without overwriting its saved UUID.
        if displayIdentifier == nil {
            displayIdentifier = EdgeHandleScreen.identifier(of: screen)
            persist()
        }
        let frame = EdgeHandleGeometry.frame(in: screen.visibleFrame, edge: edge,
                                             verticalRatio: verticalRatio, horizontalRatio: horizontalRatio)
        stripView.edge = dockedEdge(for: frame, in: screen.visibleFrame) ?? "floating"
        window.setFrame(frame, display: true)
        window.orderFrontRegardless()
    }

    private func drag(to pointer: NSPoint, offset: NSSize) {
        guard let screen = EdgeHandleScreen.containing(pointer) ?? placedScreen ?? NSScreen.main else { return }
        placedScreen = screen
        let frame = EdgeHandleGeometry.draggingFrame(pointer: pointer, grabOffset: offset, in: screen.visibleFrame)
        edge = dockedEdge(for: frame, in: screen.visibleFrame)
            ?? EdgeHandleGeometry.nearestEdge(to: CGPoint(x: frame.midX, y: frame.midY), in: screen.visibleFrame)
        stripView.edge = dockedEdge(for: frame, in: screen.visibleFrame) ?? "floating"
        window.setFrame(frame, display: true)
    }

    private func release(dragged: Bool) {
        stripView.dragging = false
        hoverSince = nil
        if dragged, let screen = placedScreen {
            verticalRatio = EdgeHandleGeometry.ratio(for: window.frame, in: screen.visibleFrame)
            horizontalRatio = EdgeHandleGeometry.horizontalRatio(for: window.frame, in: screen.visibleFrame)
            displayIdentifier = EdgeHandleScreen.identifier(of: screen)
            persist()
            // Reopen only after the pointer leaves and re-enters, not on mouse-up.
            suppressHoverUntil = Date().addingTimeInterval(1.0)
            requiresPointerExit = true
            reposition()
            onEdgeChanged?(edge)
        } else {
            open(manual: true)
        }
    }

    private func open(manual: Bool) {
        guard enabled, !expanded, !suspended, !window.isPressed,
              let screen = placedScreen ?? EdgeHandleScreen.resolve(displayIdentifier) else { return }
        onOpen?(screen, window.frame, manual)
    }

    private func persist() {
        defaults.set(verticalRatio, forKey: Self.ratioDefaultsKey)
        if let horizontalRatio { defaults.set(horizontalRatio, forKey: Self.horizontalRatioDefaultsKey) }
        else { defaults.removeObject(forKey: Self.horizontalRatioDefaultsKey) }
        defaults.set(displayIdentifier, forKey: Self.displayDefaultsKey)
    }

    private func dockedEdge(for frame: CGRect, in visible: CGRect) -> String? {
        if abs(frame.minX - visible.minX) <= 0.5 { return "left" }
        if abs(frame.maxX - visible.maxX) <= 0.5 { return "right" }
        return nil
    }
}

/// Mouse events are handled before NSView hit testing, so dragging also works
/// while another app is active and never needs Accessibility permissions.
private final class EdgeHandlePanel: NSPanel {
    var onPressBegan: (() -> Void)?
    var onDragBegan: (() -> Void)?
    var onDrag: ((NSPoint, NSSize) -> Void)?
    var onRelease: ((Bool) -> Void)?
    private(set) var isPressed = false
    private var pressedAt: NSPoint?
    private var grabOffset = NSSize.zero
    private var dragged = false

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func cancelInteraction() { isPressed = false; pressedAt = nil; dragged = false }

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            let pointer = NSEvent.mouseLocation
            guard frame.contains(pointer) else { super.sendEvent(event); return }
            isPressed = true; dragged = false; pressedAt = pointer
            grabOffset = NSSize(width: pointer.x - frame.minX, height: pointer.y - frame.minY)
            onPressBegan?()
        case .leftMouseDragged where isPressed:
            let pointer = NSEvent.mouseLocation
            if !dragged, let pressedAt,
               hypot(pointer.x - pressedAt.x, pointer.y - pressedAt.y) >= EdgeHandleGeometry.dragThreshold {
                dragged = true; onDragBegan?()
            }
            if dragged { onDrag?(pointer, grabOffset) }
        case .leftMouseUp where isPressed:
            let wasDragged = dragged
            cancelInteraction()
            onRelease?(wasDragged)
        default:
            super.sendEvent(event)
        }
    }
}

private final class EdgeHandleView: NSView {
    var edge = "right" { didSet { if oldValue != edge { needsDisplay = true } } }
    var hovered = false { didSet { if oldValue != hovered { needsDisplay = true } } }
    var dragging = false { didSet { if oldValue != dragging { needsDisplay = true } } }
    var onPress: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("搞机灵唤起条")
        setAccessibilityHelp("悬停或点击展开；按住可自由移动，仅靠近左右边缘时吸附。")
    }
    required init?(coder: NSCoder) { nil }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func accessibilityPerformPress() -> Bool { onPress?(); return true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let width = hovered || dragging ? 7.0 : EdgeHandleGeometry.visualWidth
        let height = min(EdgeHandleGeometry.visualHeight, bounds.height - 8)
        let x = edge == "left" ? 1 : edge == "right" ? bounds.width - width - 1 : (bounds.width - width) / 2
        let capsule = NSBezierPath(roundedRect: NSRect(x: x, y: (bounds.height - height) / 2, width: width, height: height),
                                  xRadius: width / 2, yRadius: width / 2)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.20)
        shadow.shadowBlurRadius = 3
        shadow.shadowOffset = NSSize(width: edge == "left" ? 1 : edge == "right" ? -1 : 0, height: 0)
        shadow.set()
        let alpha: CGFloat = hovered || dragging ? 1 : 0.84
        let top = NSColor(calibratedRed: 0.33, green: 0.65, blue: 0.58, alpha: alpha)
        let bottom = NSColor(calibratedRed: 0.14, green: 0.43, blue: 0.40, alpha: alpha)
        NSGradient(starting: bottom, ending: top)?.draw(in: capsule, angle: 90)
        NSColor.white.withAlphaComponent(0.42).setStroke()
        capsule.lineWidth = 0.6
        capsule.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }
}
