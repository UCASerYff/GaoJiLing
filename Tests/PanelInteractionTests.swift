import Foundation
import CoreGraphics
import Darwin

private struct PanelTestFailure: Error, CustomStringConvertible {
    let description: String
}

private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw PanelTestFailure(description: message) }
}

/// Synthetic monotonic time and a 50 ms UI polling cadence. Tests describe
/// user-visible outcomes without reading the policy's private timer state.
private struct PanelScenario {
    var policy = PanelAutoCollapse()
    var time: TimeInterval = 100

    mutating func open() { policy.opened(at: time) }
    mutating func close() { policy.closed() }

    mutating func tick(after seconds: TimeInterval = 0, inside: Bool = false,
                       bridge: Bool = false, buttons: UInt = 0) -> Bool {
        time += seconds
        return policy.shouldCollapse(at: time, pointerInside: inside,
                                     pointerInOpeningBridge: bridge, pressedMouseButtons: buttons)
    }

    mutating func remainsOpen(for duration: TimeInterval, inside: Bool = false,
                              bridge: Bool = false, buttons: UInt = 0, reason: String) throws {
        let end = time + duration
        repeat {
            let collapsed = tick(after: min(0.05, max(0, end - time)), inside: inside,
                                 bridge: bridge, buttons: buttons)
            try require(!collapsed, reason)
        } while time < end
    }

    mutating func collapseDelay(within duration: TimeInterval, bridge: Bool = false,
                                 buttons: UInt = 0) -> TimeInterval? {
        let start = time
        let end = start + duration
        repeat {
            if tick(after: min(0.05, max(0, end - time)), bridge: bridge, buttons: buttons) {
                return time - start
            }
        } while time < end
        return nil
    }
}

@main struct PanelInteractionTests {
    static func main() {
        let cases: [(String, () throws -> Void)] = [
            ("An unentered shortcut opening has a finite grace period", shortcutOutside),
            ("Quick entry then exit bypasses the opening grace period", quickEntryThenExit),
            ("50 ms polling closes within 250 ms of leaving at different poll phases", pollingLatency),
            ("Stationary reading stays open and a brief return cancels dismissal", stationaryReadingAndReturn),
            ("Any outside mouse-down closes immediately, even during grace or an owned drag", outsideMouseDown),
            ("Unrelated held mouse buttons cannot keep an unentered panel alive", unrelatedHeldButtons),
            ("An inside-origin drag survives pointer exit and starts a fresh exit delay on release", insideDragAndRelease),
            ("Deferred focus loss closes on release even when the pointer is still inside", deferredFocusLoss),
            ("Lost mouse-up is reconciled from current button state", lostMouseUp),
            ("Multiple inside-origin buttons protect only while an owned button remains down", multipleButtons),
            ("Closed and reopened panels discard pending timers and gestures", closeAndReopen),
            ("Reopening an already open panel resets pending dismissal", reopenWhilePending),
            ("Actual frame edges and transparent rounded corners are outside hit regions", roundedHitRegion),
            ("Opening bridges cover only the narrow strip-height gap on either side", openingBridgeGeometry),
            ("The bridge helps initial entry but cannot prevent dismissal after entry", bridgeAfterEntry)
        ]
        do {
            for (name, test) in cases {
                do { try test() }
                catch { throw PanelTestFailure(description: "\(name): \(error)") }
                print("PASS: \(name)")
            }
            print("PASS: \(cases.count) panel interaction tests (synthetic clock, no user data)")
        } catch {
            fputs("FAIL: \(error)\n", stderr)
            exit(1)
        }
    }

    static func shortcutOutside() throws {
        var panel = PanelScenario()
        panel.open()
        try panel.remainsOpen(for: 0.5, reason: "Opening must leave time to reach the panel")
        try require(panel.collapseDelay(within: 2) != nil, "Never entering must not leave the panel permanently expanded")
    }

    static func quickEntryThenExit() throws {
        var panel = PanelScenario()
        panel.open()
        try require(!panel.tick(after: 0.05, inside: true), "Entering soon after opening must keep the panel visible")
        try require(!panel.tick(after: 0.05), "Leaving starts a brief delay rather than closing immediately")
        let delay = panel.collapseDelay(within: 0.25)
        try require(delay != nil, "After entry, the opening grace must not keep the panel open on exit")
        try require(panel.time < 100.5, "A quick enter/exit must close well before the initial opening grace ends")
    }

    static func pollingLatency() throws {
        // The real pointer can leave immediately after a poll or near the next
        // poll. Both the detection delay and close delay must fit this bound.
        for phase in [0.0, 0.001, 0.025, 0.049] {
            var panel = PanelScenario()
            panel.open()
            _ = panel.tick(after: 0.05, inside: true)
            let actualExit = panel.time + phase
            let delay = panel.collapseDelay(within: 0.3)
            try require(delay != nil, "A pointer exit must close on a bounded polling deadline")
            let elapsed = panel.time - actualExit
            try require(elapsed >= 0.14 && elapsed <= 0.250_001,
                        "With 50 ms polling, leaving must close after a short delay and within 250 ms; got \(elapsed)s")
        }
    }

    static func stationaryReadingAndReturn() throws {
        var panel = PanelScenario()
        panel.open()
        try panel.remainsOpen(for: 300, inside: true, reason: "Reading without pointer motion must remain open")
        _ = panel.tick()
        try require(!panel.tick(after: 0.05), "A short excursion should leave time to return")
        try require(!panel.tick(after: 0.025, inside: true), "Returning must cancel pending dismissal")
        try panel.remainsOpen(for: 2, inside: true, reason: "No old exit timer may dismiss the panel after returning")
        _ = panel.tick()
        try require(!panel.tick(after: 0.05), "A later exit gets its own brief delay")
        try require(panel.collapseDelay(within: 0.25) != nil, "A later sustained exit must close normally")
    }

    static func outsideMouseDown() throws {
        for button in [0, 1, 2, 7] {
            var panel = PanelScenario()
            panel.open()
            try require(panel.policy.mouseDown(button: button, insidePanel: false),
                        "Any outside click must close immediately without waiting for opening grace")
        }
        var dragging = PanelScenario()
        dragging.open()
        try require(!dragging.policy.mouseDown(button: 0, insidePanel: true), "Inside clicks must not close")
        try require(dragging.policy.mouseDown(button: 1, insidePanel: false),
                    "An outside click with another button must close even while an inside-origin button is held")
        var focus = PanelScenario()
        focus.open()
        try require(focus.policy.shouldCollapseOnFocusLoss(pressedMouseButtons: 2),
                    "Focus loss must close immediately when no gesture began inside the panel")
    }

    static func unrelatedHeldButtons() throws {
        var panel = PanelScenario()
        panel.open()
        try require(panel.collapseDelay(within: 2, buttons: 1 | 4) != nil,
                    "Buttons already held outside must not create a protected panel gesture")
        var entered = PanelScenario()
        entered.open()
        _ = entered.tick(inside: true)
        try require(entered.collapseDelay(within: 0.25, buttons: 2) != nil,
                    "A held outside button must not keep an entered panel open after the pointer leaves")
    }

    static func insideDragAndRelease() throws {
        var panel = PanelScenario()
        panel.open()
        try require(!panel.policy.mouseDown(button: 0, insidePanel: true), "Starting a gesture inside must retain the panel")
        try panel.remainsOpen(for: 30, buttons: 1, reason: "An inside-origin drag must stay open after moving outside")
        panel.policy.mouseUp(button: 0)
        try require(!panel.tick(), "Releasing must start a fresh exit delay rather than inherit the drag duration")
        try require(!panel.tick(after: 0.05), "Release must allow a short chance to move back inside")
        try require(panel.collapseDelay(within: 0.25) != nil, "The panel must close after release when the pointer remains outside")
    }

    static func deferredFocusLoss() throws {
        for receivesMouseUp in [true, false] {
            var panel = PanelScenario()
            panel.open()
            _ = panel.policy.mouseDown(button: 0, insidePanel: true)
            try require(!panel.policy.shouldCollapseOnFocusLoss(pressedMouseButtons: 1),
                        "Focus loss must defer dismissal while an inside-origin gesture is held")
            try panel.remainsOpen(for: 2, inside: true, buttons: 1,
                                  reason: "The active gesture must survive deferred focus loss")
            try panel.remainsOpen(for: 2, buttons: 1,
                                  reason: "Dragging outside must not prematurely complete deferred focus loss")
            if receivesMouseUp { panel.policy.mouseUp(button: 0) }
            try require(panel.tick(inside: true),
                        "Release must complete deferred focus loss immediately, even inside and even when mouse-up was lost")
        }
    }

    static func lostMouseUp() throws {
        var polled = PanelScenario()
        polled.open()
        _ = polled.policy.mouseDown(button: 0, insidePanel: true)
        try polled.remainsOpen(for: 2, buttons: 1, reason: "An owned gesture stays protected while still physically pressed")
        // No mouseUp notification arrives, but the OS button mask is now clear.
        try require(polled.collapseDelay(within: 0.25) != nil, "A missed mouse-up notification must not make the panel permanent")
        var focus = PanelScenario()
        focus.open()
        _ = focus.policy.mouseDown(button: 2, insidePanel: true)
        try require(!focus.policy.shouldCollapseOnFocusLoss(pressedMouseButtons: 4), "A still-held owned button protects focus loss")
        try require(focus.policy.shouldCollapseOnFocusLoss(pressedMouseButtons: 0), "Focus-loss reconciliation must release a gesture after a lost mouse-up")
    }

    static func multipleButtons() throws {
        var panel = PanelScenario()
        panel.open()
        _ = panel.policy.mouseDown(button: 0, insidePanel: true)
        _ = panel.policy.mouseDown(button: 2, insidePanel: true)
        try panel.remainsOpen(for: 2, buttons: 1 | 4, reason: "Both inside-origin buttons may protect a gesture")
        panel.policy.mouseUp(button: 0)
        try require(!panel.policy.shouldCollapseOnFocusLoss(pressedMouseButtons: 4), "Releasing one button must retain another owned gesture")
        try panel.remainsOpen(for: 2, buttons: 4, reason: "The remaining inside-origin button must retain protection")
        panel.policy.mouseUp(button: 2)
        // A physically pressed button with no inside mouse-down cannot inherit
        // ownership from the two released buttons.
        try require(panel.tick(inside: true, buttons: 2),
                    "After the last owned button is released, an unrelated held button must not postpone deferred focus loss")
    }

    static func closeAndReopen() throws {
        var panel = PanelScenario()
        try require(!panel.policy.mouseDown(button: 0, insidePanel: false), "A closed panel must not react to outside clicks")
        try require(!panel.policy.shouldCollapseOnFocusLoss(pressedMouseButtons: 0), "A closed panel must ignore focus-loss dismissal")
        panel.open()
        _ = panel.policy.mouseDown(button: 0, insidePanel: true)
        try require(!panel.policy.shouldCollapseOnFocusLoss(pressedMouseButtons: 1),
                    "The original gesture must defer focus-loss dismissal")
        try panel.remainsOpen(for: 1, buttons: 1, reason: "The original gesture must be protected")
        panel.close()
        try panel.remainsOpen(for: 10, reason: "A closed panel must not emit stale collapse decisions")
        panel.close()
        panel.open()
        try panel.remainsOpen(for: 0.5, buttons: 1, reason: "Reopening must reset the entered flag and receive a new opening grace")
        try require(panel.collapseDelay(within: 2, buttons: 1) != nil, "Reopening must discard the previous opening's gesture ownership")
    }

    static func reopenWhilePending() throws {
        var panel = PanelScenario()
        panel.open()
        _ = panel.tick(inside: true)
        _ = panel.tick(after: 0.05)
        _ = panel.tick(after: 0.05)
        panel.open()
        try panel.remainsOpen(for: 0.5, reason: "Opening again must discard an old exit timer and reset entry state")
        try require(panel.collapseDelay(within: 2) != nil, "Reopening must not disable eventual auto-collapse")

        var focus = PanelScenario()
        focus.open()
        _ = focus.policy.mouseDown(button: 0, insidePanel: true)
        _ = focus.policy.shouldCollapseOnFocusLoss(pressedMouseButtons: 1)
        focus.open()
        try focus.remainsOpen(for: 2, inside: true,
                              reason: "Reopening without a close must discard a previous gesture's deferred focus loss")
    }

    static func roundedHitRegion() throws {
        let frame = CGRect(x: 100, y: 200, width: 398, height: 720)
        let outside = [CGPoint(x: frame.minX - 1, y: frame.midY), CGPoint(x: frame.maxX + 1, y: frame.midY),
                       CGPoint(x: frame.midX, y: frame.minY - 1), CGPoint(x: frame.midX, y: frame.maxY + 1)]
        for point in outside { try require(!PanelHitRegion.contains(point, in: frame), "A point 1 pt beyond any visible side must be outside") }
        let inside = [CGPoint(x: frame.minX + 1, y: frame.midY), CGPoint(x: frame.maxX - 1, y: frame.midY),
                      CGPoint(x: frame.midX, y: frame.minY + 1), CGPoint(x: frame.midX, y: frame.maxY - 1),
                      CGPoint(x: frame.midX, y: frame.midY)]
        for point in inside { try require(PanelHitRegion.contains(point, in: frame), "Visible pixels just inside a straight side must remain interactive") }
        for x in [frame.minX + 1, frame.maxX - 1] {
            for y in [frame.minY + 1, frame.maxY - 1] {
                try require(!PanelHitRegion.contains(CGPoint(x: x, y: y), in: frame), "Transparent rounded corners must not keep the panel expanded")
            }
        }
        for x in [frame.minX + 10, frame.maxX - 10] {
            for y in [frame.minY + 10, frame.maxY - 10] {
                try require(PanelHitRegion.contains(CGPoint(x: x, y: y), in: frame), "Visible pixels inside the rounded corner must be interactive")
            }
        }
    }

    static func openingBridgeGeometry() throws {
        let panel = CGRect(x: 100, y: 200, width: 398, height: 720)
        let strips = [CGRect(x: panel.maxX + 12, y: 500, width: 8, height: 48),
                      CGRect(x: panel.minX - 20, y: 500, width: 8, height: 48)]
        for strip in strips {
            let bridge = PanelHitRegion.openingBridge(panel: panel, strip: strip)
            let gapX = strip.midX > panel.midX ? panel.maxX + 6 : panel.minX - 6
            try require(bridge.contains(CGPoint(x: gapX, y: strip.midY)), "The actual gap between strip and panel must permit initial entry from either side")
            try require(!bridge.contains(CGPoint(x: gapX, y: strip.minY - 1)), "The bridge must not extend below the strip")
            try require(!bridge.contains(CGPoint(x: gapX, y: strip.maxY + 1)), "The bridge must not extend above the strip")
            try require(!bridge.contains(CGPoint(x: panel.midX, y: strip.midY)), "The bridge must not swallow the panel interior")
            let beyondStrip = strip.midX > panel.midX ? strip.maxX + 1 : strip.minX - 1
            try require(!bridge.contains(CGPoint(x: beyondStrip, y: strip.midY)), "The bridge must not create an invisible exterior halo")
        }
        let disconnected = PanelHitRegion.openingBridge(panel: panel,
            strip: CGRect(x: panel.maxX + 12, y: panel.maxY + 10, width: 8, height: 48))
        try require(disconnected.isEmpty, "A strip with no vertical overlap must not create an opening bridge")
    }

    static func bridgeAfterEntry() throws {
        var panel = PanelScenario()
        panel.open()
        try panel.remainsOpen(for: 3, bridge: true, reason: "Before first entry, the narrow bridge should allow transfer into the panel")
        try require(!panel.tick(after: 0.05, inside: true), "Entering from the bridge must keep the panel open")
        try require(panel.collapseDelay(within: 0.25, bridge: true) != nil,
                    "Once entered, returning to the bridge must count as leaving and close within the normal short delay")
    }
}
