import Foundation
import CoreGraphics
import Darwin

private struct GeometryTestFailure: Error, CustomStringConvertible {
    let description: String
}

private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw GeometryTestFailure(description: message) }
}

private func equal(_ actual: CGFloat, _ expected: CGFloat, _ message: String) throws {
    try require(abs(actual - expected) < 0.000_001, "\(message); expected \(expected), got \(actual)")
}

private func equal(_ actual: CGRect, _ expected: CGRect, _ message: String) throws {
    try equal(actual.minX, expected.minX, message + " (x)")
    try equal(actual.minY, expected.minY, message + " (y)")
    try equal(actual.width, expected.width, message + " (width)")
    try equal(actual.height, expected.height, message + " (height)")
}

private func fits(_ frame: CGRect, in screen: CGRect, _ message: String) throws {
    try require([frame.minX, frame.minY, frame.width, frame.height].allSatisfy { $0.isFinite }, message + ": finite coordinates")
    try require(frame.width > 0 && frame.height > 0, message + ": positive size")
    try require(frame.minX >= screen.minX - 0.000_001 && frame.maxX <= screen.maxX + 0.000_001
                && frame.minY >= screen.minY - 0.000_001 && frame.maxY <= screen.maxY + 0.000_001,
                message + ": must remain on screen; \(frame) outside \(screen)")
}

@main struct FloatingGeometryTests {
    static let desktop = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    static let panelSize = CGSize(width: 398, height: 600)

    static func main() {
        let cases: [(String, () throws -> Void)] = [
            ("A middle-screen strip drop survives saved-ratio restoration", freeStripRoundTrip),
            ("Strip snapping uses frame distance and stops beyond 32 pt", stripSnapThreshold),
            ("Old left/right preferences restore without a horizontal ratio", legacyDocking),
            ("Panel snapping uses its inset boundary and stops beyond 32 pt", panelSnapThreshold),
            ("Expansion chooses available space and otherwise honors the preferred side", expansionSide),
            ("Dragging, collapsing, and reopening a floating panel preserves its frame", floatingPanelRoundTrip),
            ("Dragging a panel to either edge survives collapse and reopen", dockedPanelRoundTrip),
            ("Negative-coordinate displays and out-of-screen drags remain bounded", screenBoundaries),
            ("Small displays constrain strip and panel sizes without invalid frames", smallScreens),
            ("Invalid persisted ratios restore a finite bounded position", invalidRatios)
        ]
        do {
            for (name, test) in cases {
                do { try test() }
                catch { throw GeometryTestFailure(description: "\(name): \(error)") }
                print("PASS: \(name)")
            }
            print("PASS: \(cases.count) floating geometry tests (synthetic screens, no user data)")
        } catch {
            fputs("FAIL: \(error)\n", stderr)
            exit(1)
        }
    }

    static func freeStripRoundTrip() throws {
        let screen = CGRect(x: -1920, y: -320, width: 1920, height: 1080)
        let pointer = CGPoint(x: -943, y: 177)
        let grab = CGSize(width: 3, height: 71)
        let dropped = EdgeHandleGeometry.draggingFrame(pointer: pointer, grabOffset: grab, in: screen)
        try equal(dropped.minX, pointer.x - grab.width, "A free drop must keep the grabbed horizontal position")
        try equal(dropped.minY, pointer.y - grab.height, "A free drop must keep the grabbed vertical position")
        let horizontal = EdgeHandleGeometry.horizontalRatio(for: dropped, in: screen)
        let vertical = EdgeHandleGeometry.ratio(for: dropped, in: screen)
        for edge in ["left", "right"] {
            let restored = EdgeHandleGeometry.frame(in: screen, edge: edge, verticalRatio: vertical, horizontalRatio: horizontal)
            try equal(restored, dropped, "A saved free position must override the previous docking side")
        }
    }

    static func stripSnapThreshold() throws {
        let size = EdgeHandleGeometry.frame(in: desktop, edge: "left", verticalRatio: 0.5).size
        // Uneven grab offsets ensure the threshold applies to the strip frame,
        // rather than to the pointer's distance from the screen edge.
        for edge in ["left", "right"] {
            let grab = CGSize(width: edge == "left" ? size.width - 1 : 1, height: 37)
            for distance: CGFloat in [31.5, 32, 32.5, 160] {
                let proposedX = edge == "left" ? desktop.minX + distance : desktop.maxX - size.width - distance
                let frame = EdgeHandleGeometry.draggingFrame(
                    pointer: CGPoint(x: proposedX + grab.width, y: 420), grabOffset: grab, in: desktop)
                let expectedX = distance <= 32 ? (edge == "left" ? desktop.minX : desktop.maxX - size.width) : proposedX
                try equal(frame.minX, expectedX, "Only a strip within 32 pt of the \(edge) boundary may snap")
            }
        }
    }

    static func legacyDocking() throws {
        for screen in [desktop, CGRect(x: -1600, y: 80, width: 1600, height: 900)] {
            for ratio in [0.0, 0.25, 0.5, 0.75, 1.0] {
                let left = EdgeHandleGeometry.frame(in: screen, edge: "left", verticalRatio: ratio)
                let right = EdgeHandleGeometry.frame(in: screen, edge: "right", verticalRatio: ratio)
                try equal(left.minX, screen.minX, "Missing horizontal data must retain old left docking")
                try equal(right.maxX, screen.maxX, "Missing horizontal data must retain old right docking")
                try equal(left.minY, right.minY, "Changing docking side must not change old vertical position")
                try equal(CGFloat(EdgeHandleGeometry.ratio(for: left, in: screen)), CGFloat(ratio), "Old vertical positions must round trip")
                try fits(left, in: screen, "Restored left strip")
                try fits(right, in: screen, "Restored right strip")
            }
        }
    }

    static func panelSnapThreshold() throws {
        let grab = CGSize(width: 83, height: 540)
        for edge in ["left", "right"] {
            for distance: CGFloat in [31.5, 32, 32.5, 200] {
                let dockX = edge == "left" ? desktop.minX + 12 : desktop.maxX - 12 - panelSize.width
                let proposedX = dockX + (edge == "left" ? distance : -distance)
                let frame = FloatingPanelGeometry.draggingFrame(pointer: CGPoint(x: proposedX + grab.width, y: 700),
                    grabOffset: grab, size: panelSize, in: desktop)
                try equal(frame.minX, distance <= 32 ? dockX : proposedX,
                          "Only a panel within 32 pt of the \(edge) inset boundary may snap")
                try equal(frame.minY, 700 - grab.height, "Horizontal snapping must not move the panel vertically")
            }
        }
    }

    static func expansionSide() throws {
        let anchors = [
            (CGRect(x: 150, y: 430, width: 20, height: 104), "right", "left"),
            (CGRect(x: 1750, y: 430, width: 20, height: 104), "left", "right"),
            (CGRect(x: 950, y: 430, width: 20, height: 104), "left", "left"),
            (CGRect(x: 950, y: 430, width: 20, height: 104), "right", "right")
        ]
        for (anchor, preference, expected) in anchors {
            let placed = FloatingPanelGeometry.placement(anchor: anchor, size: panelSize, in: desktop, preferredEdge: preference)
            try require(placed.edge == expected, "Expansion must choose space before honoring a side preference")
            try fits(placed.frame, in: desktop, "Expanded panel")
            if expected == "left" {
                try equal(placed.frame.minX, anchor.maxX + 8, "Floating left anchor should open to its right with a narrow gap")
            } else {
                try equal(placed.frame.maxX, anchor.minX - 8, "Floating right anchor should open to its left with a narrow gap")
            }
        }
    }

    static func floatingPanelRoundTrip() throws {
        for screen in [desktop, CGRect(x: -2100, y: -170, width: 1920, height: 1080)] {
            let grab = CGSize(width: 173, height: 561)
            let target = CGPoint(x: screen.minX + 700, y: screen.minY + 210)
            let dragged = FloatingPanelGeometry.draggingFrame(pointer: CGPoint(x: target.x + grab.width, y: target.y + grab.height),
                grabOffset: grab, size: panelSize, in: screen)
            try equal(dragged.origin.x, target.x, "Dragging a panel through its CPU area must preserve horizontal grab offset")
            try equal(dragged.origin.y, target.y, "Dragging a panel through its CPU area must preserve vertical grab offset")
            for edge in ["left", "right"] {
                let anchor = FloatingPanelGeometry.anchor(for: dragged, in: screen, edge: edge)
                let restoredAnchor = EdgeHandleGeometry.frame(in: screen, edge: edge,
                    verticalRatio: EdgeHandleGeometry.ratio(for: anchor, in: screen),
                    horizontalRatio: EdgeHandleGeometry.horizontalRatio(for: anchor, in: screen))
                let reopened = FloatingPanelGeometry.placement(anchor: restoredAnchor, size: panelSize, in: screen, preferredEdge: edge)
                try equal(reopened.frame, dragged, "Collapse, save, and reopen must preserve a freely dragged panel")
            }
        }
    }

    static func dockedPanelRoundTrip() throws {
        for edge in ["left", "right"] {
            let pointer = CGPoint(x: edge == "left" ? -400 : 2400, y: 760)
            let dragged = FloatingPanelGeometry.draggingFrame(pointer: pointer, grabOffset: CGSize(width: 200, height: 540),
                size: panelSize, in: desktop)
            let anchor = FloatingPanelGeometry.anchor(for: dragged, in: desktop, edge: edge)
            if edge == "left" { try equal(anchor.minX, desktop.minX, "A left-docked panel must collapse to the screen edge") }
            else { try equal(anchor.maxX, desktop.maxX, "A right-docked panel must collapse to the screen edge") }
            let reopened = FloatingPanelGeometry.placement(anchor: anchor, size: panelSize, in: desktop, preferredEdge: edge)
            try equal(reopened.frame, dragged, "A docked panel must reopen where it was dragged")
        }
    }

    static func screenBoundaries() throws {
        let screen = CGRect(x: -1728, y: -900, width: 1728, height: 900)
        let extremes = [CGPoint(x: -9999, y: -9999), CGPoint(x: 9999, y: 9999),
                        CGPoint(x: -9999, y: 9999), CGPoint(x: 9999, y: -9999)]
        for pointer in extremes {
            let strip = EdgeHandleGeometry.draggingFrame(pointer: pointer, grabOffset: CGSize(width: 10, height: 50), in: screen)
            try fits(strip, in: screen, "Strip after crossing a screen boundary")
            let panel = FloatingPanelGeometry.draggingFrame(pointer: pointer, grabOffset: CGSize(width: 100, height: 500), size: panelSize, in: screen)
            try fits(panel, in: screen.insetBy(dx: 12, dy: 12), "Panel after crossing a screen boundary")
            for edge in ["left", "right"] {
                let anchor = FloatingPanelGeometry.anchor(for: panel, in: screen, edge: edge)
                try fits(anchor, in: screen, "Collapsed anchor on a negative-coordinate display")
                let expanded = FloatingPanelGeometry.placement(anchor: anchor, size: panelSize, in: screen, preferredEdge: edge)
                try fits(expanded.frame, in: screen, "Reopened panel on a negative-coordinate display")
            }
        }
    }

    static func smallScreens() throws {
        for screen in [CGRect(x: -80, y: -40, width: 320, height: 240), CGRect(x: 40, y: 90, width: 8, height: 16)] {
            let strip = EdgeHandleGeometry.frame(in: screen, edge: "right", verticalRatio: 1, horizontalRatio: 0.7)
            try fits(strip, in: screen, "Strip on a small display")
            let panel = FloatingPanelGeometry.draggingFrame(pointer: CGPoint(x: screen.midX, y: screen.midY),
                grabOffset: CGSize(width: 200, height: 500), size: panelSize, in: screen)
            try fits(panel, in: screen, "Oversized panel on a small display")
            let placed = FloatingPanelGeometry.placement(anchor: strip, size: panelSize, in: screen, preferredEdge: "right")
            try fits(placed.frame, in: screen, "Expansion on a small display")
            let anchor = FloatingPanelGeometry.anchor(for: panel, in: screen, edge: "right")
            try fits(anchor, in: screen, "Collapsed anchor on a small display")
        }
    }

    static func invalidRatios() throws {
        for vertical in [Double.nan, .infinity, -.infinity, -20, 20] {
            for horizontal in [Double.nan, .infinity, -.infinity, -20, 20] {
                let frame = EdgeHandleGeometry.frame(in: desktop, edge: "left", verticalRatio: vertical, horizontalRatio: horizontal)
                try fits(frame, in: desktop, "Frame restored from malformed ratios")
                let x = EdgeHandleGeometry.horizontalRatio(for: frame, in: desktop)
                let y = EdgeHandleGeometry.ratio(for: frame, in: desktop)
                try require(x.isFinite && y.isFinite && (0...1).contains(x) && (0...1).contains(y),
                            "Re-saving malformed position data must produce finite normalized ratios")
            }
        }
    }
}
