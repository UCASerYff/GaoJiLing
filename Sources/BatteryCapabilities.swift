import Foundation

enum BatteryControlCapability: String, Codable, Sendable {
    case unsupported = "不支持"
    case readOnly = "只读"
    case authorizationRequired = "需授权"
    case verifiedControl = "已验证可控"
}

struct BatteryCapability: Identifiable, Sendable {
    var id: String
    var title: String
    var capability: BatteryControlCapability
    var detail: String
    var evidenceURL: String
    static var systemChargeLimitAvailable: Bool {
        #if arch(arm64)
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return v.majorVersion > 26 || (v.majorVersion == 26 && v.minorVersion >= 4)
        #else
        return false
        #endif
    }
    static let current: [Self] = [
        Self(id: "read", title: "电源与电量", capability: .readOnly,
             detail: "公开 IOPowerSources；缺项保持不可用。健康百分比与循环来自已适配的只读 IORegistry 字段。",
             evidenceURL: "https://developer.apple.com/documentation/iokit/1523856-iopscopypowersourceslist"),
        Self(id: "limits", title: "充电上限与低电量阈值", capability: .unsupported,
             detail: "Apple Silicon 配合 macOS 26.4 或更新系统，可由本人在系统电池设置选择 80–100% 充电上限。本应用未取得公开写入或设定读回接口，不代替系统设置，也不把低电量提醒当作硬件下限。",
             evidenceURL: "https://support.apple.com/en-us/102338"),
        Self(id: "heat", title: "高温暂停充电", capability: .unsupported,
             detail: "仅对实际可读的电池温度发提醒；热状态不是摄氏温度，不会冒充温度或暂停充电。",
             evidenceURL: "https://aodo365.com/battery1.html"),
        Self(id: "sleep", title: "睡眠充电策略", capability: .unsupported,
             detail: "未安装充电控制 helper，不承诺睡眠、关机或异常退出时执行充电策略。",
             evidenceURL: "https://aodo365.com/battery1.html"),
        Self(id: "discharge", title: "主动放电", capability: .unsupported,
             detail: "官网说明放电到限定电量；当前可读官方资料未明确完整机型矩阵。本机未验证合法写入引擎，不执行主动放电。",
             evidenceURL: "https://aodo365.com/battery1.html")
    ]
}

struct BatteryChargingRequest: Codable, Equatable, Sendable {
    var upperPercent: Double?
    var lowerPercent: Double?
    var temperatureLimit: Double?
    var sleepStrategy: String?
    var activeDischarge: Bool?
}

struct BatteryRule: Codable, Equatable, Sendable {
    var enabled = false
    var lowPercent = 20.0
    var highPercent = 80.0
    var highTemperature = 45.0
    /// A stored request is never treated as hardware acknowledgement.
    var requestedStrategy: BatteryChargingRequest? = nil
    var isValid: Bool {
        lowPercent.isFinite && highPercent.isFinite && highTemperature.isFinite &&
        (5...50).contains(lowPercent) && (50...100).contains(highPercent) && lowPercent < highPercent &&
        (30...70).contains(highTemperature) && requestedStrategy == nil
    }
}

struct BatteryNotice: Identifiable, Sendable {
    var id: String
    var title: String
    var detail: String
}

struct BatteryNoticePolicy {
    private var active = Set<String>()
    mutating func evaluate(_ snapshot: BatterySnapshot?, rule: BatteryRule, now: Date) -> [BatteryNotice] {
        guard rule.enabled, rule.isValid else { active.removeAll(); return [] }
        // A transient failure cannot rearm a threshold and repeat a notice as
        // soon as the exact same battery state becomes readable again.
        guard let snapshot, snapshot.present.isFresh(at: now) else { return [] }
        guard snapshot.present.value == true else { active.removeAll(); return [] }
        var conditions: [BatteryNotice] = []
        if snapshot.percent.isFresh(at: now), let percent = snapshot.percent.value {
            if percent <= rule.lowPercent { conditions.append(BatteryNotice(id: "low", title: "电池电量较低", detail: "当前电量 \(Int(percent))%，可连接电源。")) }
            if percent >= rule.highPercent, snapshot.charging.isFresh(at: now), snapshot.charging.value == true {
                conditions.append(BatteryNotice(id: "high", title: "达到电量提醒阈值", detail: "当前电量 \(Int(percent))%。这是一条提醒，未停止硬件充电。"))
            }
        }
        if snapshot.temperature.isFresh(at: now), let value = snapshot.temperature.value, value >= rule.highTemperature {
            conditions.append(BatteryNotice(id: "heat", title: "电池温度提醒", detail: "系统报告电池温度 \(String(format: "%.1f", value)) °C；未更改充电或热保护。"))
        }
        let newlyActive = conditions.filter { !active.contains($0.id) }
        // Hysteresis avoids repeated alerts near the threshold.
        if let p = snapshot.percent.value, snapshot.percent.isFresh(at: now) {
            if p > rule.lowPercent + 3 { active.remove("low") }
            if p < rule.highPercent - 3 { active.remove("high") }
        }
        if let t = snapshot.temperature.value, snapshot.temperature.isFresh(at: now), t < rule.highTemperature - 2 { active.remove("heat") }
        active.formUnion(conditions.map(\.id))
        return newlyActive
    }
}
