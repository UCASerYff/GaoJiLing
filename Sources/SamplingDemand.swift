import Foundation

enum SamplingDemand {
    static func interval(preferred: TimeInterval, visibleMetrics: Bool, panelVisible: Bool,
                         recording: Bool, historyRequired: Bool, maintenanceRulesEnabled: Bool) -> TimeInterval {
        let base = preferred.isFinite ? min(10, max(1, preferred)) : 2
        if visibleMetrics || panelVisible || recording || maintenanceRulesEnabled { return base }
        // Background history still receives real samples. This is not an invented continuous trace.
        return max(base, historyRequired ? 5 : 10)
    }
}
