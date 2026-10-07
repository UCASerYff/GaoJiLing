import Foundation

enum MonitorCSV {
    // Quote every field and neutralize spreadsheet formulas in user-supplied text.
    static func field(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let safe = ["=", "+", "-", "@"].contains(String(trimmed.prefix(1))) ? "'" + value : value
        return "\"" + safe.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
    private static func file(_ rows: [[String]]) -> Data {
        Data(("\u{FEFF}" + rows.map { $0.map(field).joined(separator: ",") }.joined(separator: "\r\n") + "\r\n").utf8)
    }
    private static func number(_ value: Double?) -> String { value.map { String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), $0) } ?? "" }
    private static func date(_ value: Date) -> String { ISO8601DateFormatter().string(from: value) }
    static func history(_ samples: [MetricsSample]) -> Data {
        file([["时间", "CPU百分比", "内存字节", "总内存字节", "内存压力", "压缩内存字节", "Swap字节", "下载字节每秒", "上传字节每秒", "磁盘读字节每秒", "磁盘写字节每秒", "磁盘剩余字节", "GPU百分比", "温度摄氏度", "电池百分比"]] + samples.map {
            [date($0.timestamp), number($0.cpuPercent), number($0.memoryUsed), number($0.memoryTotal), $0.memoryPressure, number($0.memoryCompressed), number($0.swapUsed), number($0.networkDown), number($0.networkUp), number($0.diskRead), number($0.diskWrite), number($0.diskFree), number($0.gpuPercent), number($0.cpuTemperature), number($0.batteryPercent)]
        })
    }
    static func events(_ values: [MonitorEvent]) -> Data {
        file([["时间", "标题", "详细信息", "级别", "类型"]] + values.map { [date($0.date), $0.title, $0.detail, $0.severity, $0.kind] })
    }
    static func sessions(_ values: [MonitorSession]) -> Data {
        file([["任务名称", "开始时间", "结束时间", "时长秒", "平均CPU百分比", "峰值CPU百分比", "峰值内存字节", "峰值温度摄氏度", "采样数量", "是否中断"]] + values.map {
            [$0.name, date($0.start), $0.end.map(date) ?? "", number($0.duration), number($0.averageCPU), number($0.peakCPU), number($0.peakMemory), number($0.peakTemperature), String($0.sampleCount), $0.interrupted == true ? "是" : "否"]
        })
    }
}
