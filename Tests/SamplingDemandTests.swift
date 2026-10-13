import Foundation

@main struct SamplingDemandTests {
    struct Failure: Error { let message: String }
    static func require(_ actual: TimeInterval, _ expected: TimeInterval, _ message: String) throws {
        guard actual == expected else { throw Failure(message: "\(message): expected \(expected), received \(actual)") }
    }
    struct Demand {
        var visible = false
        var panel = false
        var recording = false
        var history = true
        var rules = false
        func interval(_ preferred: TimeInterval = 2) -> TimeInterval {
            SamplingDemand.interval(preferred: preferred, visibleMetrics: visible, panelVisible: panel,
                recording: recording, historyRequired: history, maintenanceRulesEnabled: rules)
        }
    }
    static func main() throws {
        var demand = Demand()
        try require(demand.interval(), 5, "background recording of ordinary history uses reduced frequency")
        demand.visible = true
        try require(demand.interval(), 2, "visible metrics return to the requested refresh rate")
        demand.visible = false; demand.panel = true
        try require(demand.interval(), 2, "floating panel remains responsive with the main window closed")
        demand.panel = false
        try require(demand.interval(), 5, "closing both metric surfaces relaxes the schedule")
        demand.history = false
        try require(demand.interval(), 10, "without a history consumer the background uses the lowest frequency")
        print("PASS: foreground, floating panel and background/history demand transitions")

        demand.recording = true
        try require(demand.interval(), 2, "a recording keeps requested fidelity even when all UI is hidden")
        demand.recording = false; demand.rules = true
        try require(demand.interval(), 2, "active maintenance rules remain supported in the background")
        demand.rules = false
        try require(demand.interval(), 10, "removing the final active rule returns to background demand")
        demand.history = true; demand.recording = true; demand.rules = true
        try require(demand.interval(), 2, "overlapping recording and rule consumers do not create another polling rate")
        demand.recording = false
        try require(demand.interval(), 2, "ending a recording does not throttle still-active maintenance")
        demand.rules = false
        try require(demand.interval(), 5, "ending the last foreground-quality consumer restores history cadence")
        print("PASS: independent recording/rule consumers and their release order")

        try require(demand.interval(8), 8, "background history never speeds up a slower user preference")
        demand.panel = true
        try require(demand.interval(8), 8, "opening the panel respects a deliberately slower preference")
        demand.visible = true; demand.recording = true; demand.rules = true
        try require(demand.interval(10), 10, "all active consumers still share the configured maximum interval")
        demand = Demand(history: false)
        try require(demand.interval(8), 10, "no consumer uses the background cap even for a slower preference")
        print("PASS: configured slow sampling is preserved")

        demand.visible = true
        for invalid in [Double.nan, .infinity, -.infinity] {
            try require(demand.interval(invalid), 2, "non-finite saved preferences fall back to a safe finite interval")
        }
        try require(demand.interval(0), 1, "zero cannot become a busy-loop timer")
        try require(demand.interval(-Double.greatestFiniteMagnitude), 1, "negative overflow-scale input is clamped")
        try require(demand.interval(Double.leastNonzeroMagnitude), 1, "subnormal input cannot create an excessive sampling frequency")
        try require(demand.interval(Double.greatestFiniteMagnitude), 10, "large finite input cannot indefinitely stall live samples")
        demand.visible = false; demand.history = true
        try require(demand.interval(.nan), 5, "invalid preference fallback still honors background history demand")
        print("PASS: invalid preferences never produce zero, negative, non-finite or unbounded timer intervals")
        print("SamplingDemand tests passed. Pause/startSampling gates belong to MonitorStore and are not represented as a zero interval.")
    }
}
