import Foundation
import Darwin

private struct PanelTestFailure: Error, CustomStringConvertible {
    let description: String
}

private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw PanelTestFailure(description: message) }
}

/// A synthetic monotonic clock drives realistic pointer/gesture sequences.
/// Tests observe whether a panel should stay visible, not private timer state.
private struct PanelScenario {
    var policy = PanelAutoCollapse()
    var time: TimeInterval = 100

    mutating func open() { policy.opened(at: time) }
    mutating func close() { policy.closed() }

    mutating func tick(after seconds: TimeInterval = 0, inside: Bool = false, pressed: Bool = false) -> Bool {
        time += seconds
        return policy.shouldCollapse(at: time, pointerInside: inside, mousePressed: pressed)
    }

    mutating func remainsVisible(for duration: TimeInterval, inside: Bool, pressed: Bool = false, reason: String) throws {
        let end = time + duration
        repeat {
            let collapsed = tick(after: min(0.1, max(0, end - time)), inside: inside, pressed: pressed)
            try require(!collapsed, reason)
        } while time < end
    }

    mutating func eventuallyCollapses(within duration: TimeInterval) -> Bool {
        let end = time + duration
        repeat {
            if tick(after: min(0.1, max(0, end - time))) { return true }
        } while time < end
        return false
    }
}

@main struct PanelInteractionTests {
    static func main() {
        let cases: [(String, () throws -> Void)] = [
            ("Shortcut opening outside the panel closes after a finite grace period", shortcutOutside),
            ("A stationary pointer keeps the panel open for uninterrupted reading", stationaryReading),
            ("A brief pointer exit is cancelled by returning to the panel", returnBeforeCollapse),
            ("Held mouse gestures stay open and release starts a fresh delay", mouseGesture),
            ("Closed panels ignore old timers and reopening gets a fresh grace period", closeAndReopen),
            ("Reopening an already visible panel discards a pending exit", reopenWhilePending)
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
        try panel.remainsVisible(for: 0.5, inside: false, reason: "Opening must give the user a chance to move into the panel")
        try require(panel.eventuallyCollapses(within: 5), "A shortcut-opened panel must not remain indefinitely when the pointer never enters")
    }

    static func stationaryReading() throws {
        var panel = PanelScenario()
        panel.open()
        try panel.remainsVisible(for: 300, inside: true, reason: "Reading without pointer motion must not dismiss the panel")
        _ = panel.tick(inside: false)
        try require(panel.eventuallyCollapses(within: 2), "Leaving after reading should still dismiss normally")
    }

    static func returnBeforeCollapse() throws {
        var panel = PanelScenario()
        panel.open()
        try panel.remainsVisible(for: 3, inside: true, reason: "The panel must remain open while being read")
        try require(!panel.tick(), "Moving outside should not dismiss immediately")
        try require(!panel.tick(after: 0.2), "A short excursion must leave time to return")
        try require(!panel.tick(after: 0.05, inside: true), "Returning to the panel must cancel pending dismissal")
        try panel.remainsVisible(for: 3, inside: true, reason: "The previous exit must not cause a delayed dismissal after returning")
        try require(!panel.tick(), "A later exit needs its own delay")
        try require(!panel.tick(after: 0.2), "The later exit must not inherit elapsed time from the earlier exit")
        try require(panel.eventuallyCollapses(within: 2), "Remaining outside after the later exit should eventually dismiss")
    }

    static func mouseGesture() throws {
        var panel = PanelScenario()
        panel.open()
        try panel.remainsVisible(for: 3, inside: true, reason: "Initial reading should stay visible")
        _ = panel.tick()
        try require(!panel.tick(after: 0.2), "The initial short exit must not dismiss")
        try panel.remainsVisible(for: 30, inside: false, pressed: true, reason: "A held mouse button or drag outside the panel must prevent dismissal")
        try require(!panel.tick(pressed: false), "Releasing after a long drag must begin a new delay, not dismiss immediately")
        try require(!panel.tick(after: 0.2), "The user must retain a short grace period after releasing the mouse")
        try panel.remainsVisible(for: 10, inside: false, pressed: true, reason: "Resuming a gesture must cancel a pending post-release dismissal")
        try require(!panel.tick(pressed: false), "A second release must also restart the delay")
        try require(panel.eventuallyCollapses(within: 2), "Once the gesture has ended and the pointer remains outside, the panel should close")
    }

    static func closeAndReopen() throws {
        var panel = PanelScenario()
        try panel.remainsVisible(for: 10, inside: false, reason: "A panel that has never opened must never request dismissal")
        panel.open()
        try panel.remainsVisible(for: 3, inside: true, reason: "The first opening should remain visible while reading")
        _ = panel.tick()
        _ = panel.tick(after: 0.2)
        panel.close()
        try panel.remainsVisible(for: 30, inside: false, reason: "Closing must invalidate pending auto-collapse decisions")
        panel.close() // Closing an already closed panel is harmless.
        panel.open()
        try panel.remainsVisible(for: 0.5, inside: false, reason: "A reopened panel must receive a new opening grace period")
        try require(panel.eventuallyCollapses(within: 5), "A reopened panel must still auto-collapse if nobody enters")
    }

    static func reopenWhilePending() throws {
        var panel = PanelScenario()
        panel.open()
        try panel.remainsVisible(for: 3, inside: true, reason: "Initial reading should stay visible")
        _ = panel.tick()
        _ = panel.tick(after: 0.2)
        panel.open()
        try panel.remainsVisible(for: 0.5, inside: false, reason: "Opening again must discard a pending exit timer even without a separate close call")
        try require(panel.eventuallyCollapses(within: 5), "Repeated openings must not disable eventual auto-collapse")
    }
}
