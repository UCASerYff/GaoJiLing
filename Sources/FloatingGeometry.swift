import Foundation
import CoreGraphics

/// The strip's hit frame is the shared, persistent anchor for both window sizes.
enum EdgeHandleGeometry {
    static let hitSize = CGSize(width: 20, height: 104)
    static let visualWidth: CGFloat = 6
    static let visualHeight: CGFloat = 96
    static let verticalInset: CGFloat = 12
    static let snapDistance: CGFloat = 32
    static let dragThreshold: CGFloat = 4

    static func clamp(_ ratio: Double) -> Double {
        ratio.isFinite ? min(max(ratio, 0), 1) : 0.5
    }

    static func frame(in visible: CGRect, edge: String, verticalRatio: Double,
                      horizontalRatio: Double? = nil) -> CGRect {
        let width = min(hitSize.width, max(visible.width, 1))
        let height = min(hitSize.height, max(visible.height - verticalInset * 2, 1))
        let travel = max(visible.height - height - verticalInset * 2, 0)
        let ratio = horizontalRatio.map(clamp) ?? (edge == "left" ? 0 : 1)
        let x = visible.minX + CGFloat(ratio) * max(visible.width - width, 0)
        let y = visible.minY + min(verticalInset, max((visible.height - height) / 2, 0))
            + CGFloat(1 - clamp(verticalRatio)) * travel
        return CGRect(x: x, y: y, width: width, height: height)
    }

    static func ratio(for frame: CGRect, in visible: CGRect) -> Double {
        let travel = max(visible.height - frame.height - verticalInset * 2, 0)
        guard travel > 0 else { return 0.5 }
        return clamp(1 - Double((frame.minY - visible.minY - verticalInset) / travel))
    }

    static func horizontalRatio(for frame: CGRect, in visible: CGRect) -> Double {
        let travel = max(visible.width - frame.width, 0)
        guard travel > 0 else { return 0.5 }
        return clamp(Double((frame.minX - visible.minX) / travel))
    }

    static func nearestEdge(to point: CGPoint, in visible: CGRect) -> String {
        point.x < visible.midX ? "left" : "right"
    }

    static func draggingFrame(pointer: CGPoint, grabOffset: CGSize, in visible: CGRect) -> CGRect {
        var frame = self.frame(in: visible, edge: "left", verticalRatio: 0.5)
        frame.origin.x = min(max(pointer.x - grabOffset.width, visible.minX), max(visible.minX, visible.maxX - frame.width))
        let lowY = visible.minY + min(verticalInset, max((visible.height - frame.height) / 2, 0))
        let highY = max(lowY, visible.maxY - verticalInset - frame.height)
        frame.origin.y = min(max(pointer.y - grabOffset.height, lowY), highY)
        let left = frame.minX - visible.minX
        let right = visible.maxX - frame.maxX
        if min(left, right) <= snapDistance {
            frame.origin.x = left <= right ? visible.minX : max(visible.minX, visible.maxX - frame.width)
        }
        return frame
    }
}

enum FloatingPanelGeometry {
    static let inset: CGFloat = 12
    static let gap: CGFloat = 8
    private static let edgeTolerance: CGFloat = 0.5

    /// `edge` is the side of the panel occupied by the anchor: left opens right.
    static func placement(anchor: CGRect, size: CGSize, in visible: CGRect,
                          preferredEdge: String) -> (frame: CGRect, edge: String) {
        let bounds = usableBounds(in: visible)
        let size = fitted(size, in: bounds)
        let leftDocked = abs(anchor.minX - visible.minX) <= edgeTolerance
        let rightDocked = abs(anchor.maxX - visible.maxX) <= edgeTolerance
        let rightwardX = leftDocked ? bounds.minX : anchor.maxX + gap
        let leftwardX = rightDocked ? bounds.maxX - size.width : anchor.minX - gap - size.width
        func fits(_ x: CGFloat) -> Bool {
            x >= bounds.minX - edgeTolerance && x + size.width <= bounds.maxX + edgeTolerance
        }
        let preferred = preferredEdge == "left" ? "left" : "right"
        let edge: String
        if leftDocked && !rightDocked { edge = "left" }
        else if rightDocked && !leftDocked { edge = "right" }
        else if fits(preferred == "left" ? rightwardX : leftwardX) { edge = preferred }
        else if fits(preferred == "left" ? leftwardX : rightwardX) { edge = preferred == "left" ? "right" : "left" }
        else {
            let rightSpace = bounds.maxX - anchor.maxX - gap
            let leftSpace = anchor.minX - gap - bounds.minX
            edge = rightSpace == leftSpace ? preferred : (rightSpace > leftSpace ? "left" : "right")
        }
        let x = edge == "left" ? rightwardX : leftwardX
        let frame = CGRect(x: clamped(x, low: bounds.minX, high: bounds.maxX - size.width),
                           y: clamped(anchor.midY - size.height / 2, low: bounds.minY, high: bounds.maxY - size.height),
                           width: size.width, height: size.height)
        return (frame, edge)
    }

    static func draggingFrame(pointer: CGPoint, grabOffset: CGSize, size: CGSize,
                              in visible: CGRect) -> CGRect {
        let bounds = usableBounds(in: visible)
        let size = fitted(size, in: bounds)
        var frame = CGRect(x: clamped(pointer.x - grabOffset.width, low: bounds.minX, high: bounds.maxX - size.width),
                           y: clamped(pointer.y - grabOffset.height, low: bounds.minY, high: bounds.maxY - size.height),
                           width: size.width, height: size.height)
        let left = frame.minX - bounds.minX
        let right = bounds.maxX - frame.maxX
        if min(left, right) <= EdgeHandleGeometry.snapDistance {
            frame.origin.x = left <= right ? bounds.minX : bounds.maxX - frame.width
        }
        return frame
    }

    /// Inverse of placement for a fitted panel. A docked panel yields a docked
    /// strip; otherwise the strip sits 8 pt beyond the selected panel side.
    static func anchor(for panel: CGRect, in visible: CGRect, edge: String) -> CGRect {
        let bounds = usableBounds(in: visible)
        var anchor = EdgeHandleGeometry.frame(in: visible, edge: edge, verticalRatio: 0.5)
        let x: CGFloat
        if abs(panel.minX - bounds.minX) <= edgeTolerance { x = visible.minX }
        else if abs(panel.maxX - bounds.maxX) <= edgeTolerance { x = visible.maxX - anchor.width }
        else { x = edge == "left" ? panel.minX - gap - anchor.width : panel.maxX + gap }
        anchor.origin.x = clamped(x, low: visible.minX, high: visible.maxX - anchor.width)
        let lowY = visible.minY + min(EdgeHandleGeometry.verticalInset, max((visible.height - anchor.height) / 2, 0))
        anchor.origin.y = clamped(panel.midY - anchor.height / 2, low: lowY,
                                  high: visible.maxY - EdgeHandleGeometry.verticalInset - anchor.height)
        return anchor
    }

    private static func usableBounds(in visible: CGRect) -> CGRect {
        let xInset = min(inset, max((visible.width - 1) / 2, 0))
        let yInset = min(inset, max((visible.height - 1) / 2, 0))
        return CGRect(x: visible.minX + xInset, y: visible.minY + yInset,
                      width: max(visible.width - 2 * xInset, 1), height: max(visible.height - 2 * yInset, 1))
    }

    private static func fitted(_ size: CGSize, in bounds: CGRect) -> CGSize {
        CGSize(width: min(max(size.width, 1), bounds.width), height: min(max(size.height, 1), bounds.height))
    }

    private static func clamped(_ value: CGFloat, low: CGFloat, high: CGFloat) -> CGFloat {
        min(max(value, low), max(low, high))
    }
}
