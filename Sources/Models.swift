import Foundation

struct ProcessMetric: Codable, Identifiable, Equatable {
    var id: String { name }
    var name: String
    var cpuPercent: Double
    var memoryBytes: Double
    var pids: [Int32] = []
    var path: String? = nil
}

struct MetricsSample: Codable, Identifiable {
    var id: Date { timestamp }
    var timestamp = Date()
    var cpuPercent: Double? = nil
    var corePercents: [Double] = []
    var memoryUsed: Double = 0
    var memoryTotal: Double = 0
    var memoryCompressed: Double = 0
    var swapUsed: Double = 0
    var memoryPressure: String = "未知"
    var networkDown: Double? = nil
    var networkUp: Double? = nil
    var diskRead: Double? = nil
    var diskWrite: Double? = nil
    var diskFree: Double = 0
    var diskTotal: Double = 0
    var gpuPercent: Double? = nil
    var cpuTemperature: Double? = nil
    var cpuPower: Double? = nil
    var gpuPower: Double? = nil
    var fanRPM: Double? = nil
    var batteryPercent: Double? = nil
    var batteryCharging: Bool = false
    var batteryHealth: Double? = nil
    var batteryCycles: Int? = nil
    var uptime: Double = 0
    var processCount: Int = 0
    var thermalState: String = "正常"
    var processes: [ProcessMetric] = []
    var memoryPercent: Double { memoryTotal > 0 ? memoryUsed / memoryTotal * 100 : 0 }
    static var empty: MetricsSample { MetricsSample() }
}

struct MonitorEvent: Codable, Identifiable {
    var id = UUID()
    var date: Date
    var title: String
    var detail: String
    var severity: String
    var kind: String
}

struct MonitorSession: Codable, Identifiable {
    var id = UUID()
    var name: String
    var start: Date
    var end: Date? = nil
    var peakCPU: Double = 0
    var peakMemory: Double = 0
    var peakTemperature: Double? = nil
    var sampleCount: Int = 0
    var cpuTotal: Double = 0
    var lastObserved: Date? = nil
    var interrupted: Bool? = nil
    var duration: TimeInterval { (end ?? Date()).timeIntervalSince(start) }
    var averageCPU: Double { sampleCount > 0 ? cpuTotal / Double(sampleCount) : 0 }
}

struct AppSettings: Codable, Equatable {
    var edgeEnabled = true
    var edge = "right"
    var edgeDelay = 0.45
    var sampleInterval = 2.0
    var retentionDays = 7
    var launchAtLogin = false
    var notificationsEnabled = false
    var appearance = "system"
    var showSensors = true
    var menuBarCPU = true
    var hotkeyChoice = "g"
}

struct NetworkCheck: Identifiable {
    var id = UUID()
    var title: String
    var detail: String
    var success: Bool?
}

enum Format {
    static func bytes(_ value: Double) -> String {
        if !value.isFinite || value <= 0 { return "0 KB" }
        return ByteCountFormatter.string(fromByteCount: Int64(max(0, min(value, Double(Int64.max - 1024)))), countStyle: .binary)
    }
    static func rate(_ value: Double?) -> String { value.map { bytes($0) + "/s" } ?? "—" }
    static func percent(_ value: Double?) -> String { value.map { String(format: "%.0f%%", $0) } ?? "—" }
    static func duration(_ seconds: Double) -> String {
        let s = max(0, Int(seconds)); if s >= 3600 { return "\(s / 3600)小时\((s % 3600) / 60)分" }
        if s >= 60 { return "\(s / 60)分\(s % 60)秒" }; return "\(s)秒"
    }
}
