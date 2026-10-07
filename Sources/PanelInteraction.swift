import Foundation
import CoreGraphics

/// Opening grace only applies before the pointer first reaches the panel.
/// A gesture protects the panel only when its mouse-down started inside it.
struct PanelAutoCollapse {
    static let openingGrace: TimeInterval = 1.2
    static let exitDelay: TimeInterval = 0.15
    private var openedAt: TimeInterval?
    private var outsideSince: TimeInterval?
    private var hasEnteredPanel = false
    private var gestureButtons: UInt = 0
    private var pendingFocusLoss = false

    mutating func opened(at time: TimeInterval) {
        openedAt = time
        outsideSince = nil
        hasEnteredPanel = false
        gestureButtons = 0
        pendingFocusLoss = false
    }

    mutating func closed() {
        openedAt = nil
        outsideSince = nil
        hasEnteredPanel = false
        gestureButtons = 0
        pendingFocusLoss = false
    }

    /// Returns true for an outside mouse-down, including during opening grace.
    mutating func mouseDown(button: Int, insidePanel: Bool) -> Bool {
        guard openedAt != nil else { return false }
        guard insidePanel else { return true }
        hasEnteredPanel = true
        outsideSince = nil
        if let mask = buttonMask(button) { gestureButtons |= mask }
        return false
    }

    mutating func mouseUp(button: Int) {
        if let mask = buttonMask(button) { gestureButtons &= ~mask }
    }

    mutating func shouldCollapseOnFocusLoss(pressedMouseButtons: UInt) -> Bool {
        guard openedAt != nil else { return false }
        gestureButtons &= pressedMouseButtons
        pendingFocusLoss = true
        return gestureButtons == 0
    }

    mutating func shouldCollapse(at time: TimeInterval, pointerInside: Bool,
                                 pointerInOpeningBridge: Bool = false, pressedMouseButtons: UInt = 0) -> Bool {
        guard let openedAt else { return false }
        // Reconcile lost mouse-up events without treating unrelated buttons as
        // a panel gesture. An outside click is handled immediately by mouseDown.
        gestureButtons &= pressedMouseButtons
        if pendingFocusLoss && gestureButtons == 0 { return true }
        if pointerInside {
            hasEnteredPanel = true
            outsideSince = nil
            return false
        }
        if gestureButtons != 0 || (!hasEnteredPanel && pointerInOpeningBridge) {
            outsideSince = nil
            return false
        }
        if !hasEnteredPanel && time - openedAt < Self.openingGrace { return false }
        guard let outsideSince else {
            self.outsideSince = time
            return false
        }
        return time - outsideSince >= Self.exitDelay
    }

    private func buttonMask(_ button: Int) -> UInt? {
        guard (0..<UInt.bitWidth).contains(button) else { return nil }
        return UInt(1) << button
    }
}

enum PanelHitRegion {
    static let cornerRadius: CGFloat = 20

    /// Match the visible rounded panel, without an invisible exterior halo.
    static func contains(_ point: CGPoint, in frame: CGRect) -> Bool {
        guard frame.contains(point) else { return false }
        let radius = min(cornerRadius, frame.width / 2, frame.height / 2)
        let centre = CGPoint(x: min(max(point.x, frame.minX + radius), frame.maxX - radius),
                             y: min(max(point.y, frame.minY + radius), frame.maxY - radius))
        return hypot(point.x - centre.x, point.y - centre.y) <= radius
    }

    /// Only the strip-height gap is a transfer path, and only until first entry.
    static func openingBridge(panel: CGRect, strip: CGRect) -> CGRect {
        let bottom = max(panel.minY, strip.minY)
        let top = min(panel.maxY, strip.maxY)
        guard top > bottom else { return .zero }
        if strip.midX > panel.midX {
            return CGRect(x: panel.maxX, y: bottom, width: max(0, strip.maxX - panel.maxX), height: top - bottom)
        }
        return CGRect(x: strip.minX, y: bottom, width: max(0, panel.minX - strip.minX), height: top - bottom)
    }
}
