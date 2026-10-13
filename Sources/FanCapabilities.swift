import Foundation

enum FanPolicy: Codable, Equatable, Sendable {
    case systemAutomatic
    case fixed(rpm: Double)
    case curve(points: [FanCurvePoint])
}
struct FanCurvePoint: Codable, Equatable, Sendable { var temperature: Double; var rpm: Double }
struct ControlLease: Codable, Equatable, Sendable {
    var owner: String
    var expiresAt: Date
    var restorationState: String
}

enum FanCapabilities {
    // Exact model identifiers verified against Apple's model list and M4 Air
    // announcement. An unlisted Mac is "unknown", not assumed fanless.
    static let verifiedFanlessModels: Set<String> = ["Mac16,12", "Mac16,13"]
    static func description(model: String, fans: [FanDescriptor]?) -> String {
        if verifiedFanlessModels.contains(model) { return "此机型为无风扇的 M4 MacBook Air；没有可控制风扇。" }
        guard let fans else { return "未能确认风扇；读取失败与无风扇不能等同。" }
        if fans.isEmpty { return "当前只读接口未发现风扇；不提供转速控制。" }
        return "已发现 \(fans.count) 个风扇，只读转速；尚无经机型验证的写入、范围与崩溃恢复引擎。"
    }
    static func accepts(_ policy: FanPolicy) -> Bool {
        // No write implementation and no lease are issued. System control has
        // never been overridden, so this is not a claim of helper restoration.
        if case .systemAutomatic = policy { return true }
        return false
    }
}
