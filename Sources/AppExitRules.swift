import Foundation

enum AppExitTrigger: String, Codable, CaseIterable, Identifiable, Sendable {
    case background = "后台时长"
    case idle = "用户空闲且后台"
    case noWindows = "无窗口且后台"
    case memory = "内存超阈值且后台"
    var id: String { rawValue }
}
struct AppExitRule: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var bundleID: String
    var path: String
    var name: String
    var enabled = false
    var trigger: AppExitTrigger = .background
    var minutes = 30.0
    var memoryBytes: UInt64 = 1_073_741_824
    var cooldownSeconds = 1800.0
    var isValid: Bool {
        !bundleID.isEmpty && bundleID.count <= 256 && path.hasPrefix("/") && path.hasSuffix(".app") &&
        !path.split(separator: "/").contains("..") && name.count <= 256 &&
        minutes.isFinite && (1...1440).contains(minutes) && cooldownSeconds.isFinite &&
        (60...86400).contains(cooldownSeconds) && (16_777_216...137_438_953_472).contains(memoryBytes)
    }
}
enum AppExitSaveState: String, Sendable { case clean, edited, unknown }
struct AppExitObservation: Sendable {
    var identity: ProcessIdentity
    var bundleID: String
    var path: String
    var name: String
    var observedAt: Date
    var isFrontmost: Bool
    var memoryBytes: UInt64?
    var windowCount: Int?
    var saveState: AppExitSaveState
    var idleSeconds: Double?
}
struct AppExitDecision: Equatable, Sendable { var eligible: Bool; var reason: String }
struct AppExitRecord: Codable, Identifiable, Sendable {
    var id = UUID()
    var ruleID: UUID
    var date: Date
    var name: String
    var outcome: String
    var reason: String
}

enum AppExitProtection {
    static func reason(bundle: Bundle, path: String, name: String) -> String? {
        let info = bundle.infoDictionary ?? [:]
        let urls = info["CFBundleURLTypes"] as? [[String: Any]] ?? []
        let schemes = urls.flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
        let documentTypes = info["CFBundleDocumentTypes"] as? [[String: Any]] ?? []
        return reason(bundleID: bundle.bundleIdentifier ?? "", path: path, name: name,
            category: info["LSApplicationCategoryType"] as? String, urlSchemes: schemes,
            documentBased: documentTypes.contains { $0["NSDocumentClass"] is String })
    }
    static func reason(bundleID: String, path: String, name: String = "", category: String? = nil,
                       urlSchemes: [String] = [], documentBased: Bool = false) -> String? {
        let id = bundleID.lowercased(), lowerPath = path.lowercased()
        if id == "com.apple" || id.hasPrefix("com.apple.") || id == "com.gaoseries" || id.hasPrefix("com.gaoseries.") ||
            lowerPath.hasPrefix("/system/") || lowerPath.hasPrefix("/usr/") || lowerPath.hasPrefix("/library/") {
            return "系统或搞系列应用始终受保护"
        }
        let protected = ["chrome", "chromium", "firefox", "safari", "brave", "opera", "vivaldi", "arc", "edge", "browser",
                         "code", "cursor", "zed", "jetbrains", "sublime", "textmate", "bbedit", "editor", "office", "word", "excel",
                         "powerpoint", "adobe", "affinity", "obsidian", "notion", "download", "transmission", "torrent", "folx", "aria2",
                         "1password", "bitwarden", "keepass", "security", "antivirus", "littlesnitch", "lulu", "clash", "surge", "vpn",
                         "terminal", "iterm", "warp", "docker", "parallels", "vmware", "sync", "dropbox", "onedrive", "backup"]
        let context = id + " " + name.lowercased()
        if protected.contains(where: context.contains) { return "浏览器、编辑器、下载器或系统安全/后台任务应用保守排除" }
        if urlSchemes.contains(where: { ["http", "https"].contains($0.lowercased()) }) {
            return "声明可处理网页的应用可能包含浏览或下载任务，保守排除"
        }
        if documentBased { return "文稿应用可能保存工作内容，保守排除" }
        if ["public.app-category.developer-tools", "public.app-category.productivity", "public.app-category.finance", "public.app-category.graphics-design", "public.app-category.video"].contains(category ?? "") {
            return "此应用类别可能保存工作或运行长期任务，保守排除"
        }
        return nil
    }
}

/// Pure state machine, driven by verified observations. A new PID/start/UID or
/// sleep discontinuity starts a fresh background interval; never catches up.
struct AppExitPolicy {
    private var backgroundSince: [ProcessIdentity: Date] = [:]
    private var lastAttempt: [UUID: Date] = [:]
    private var lastObservation: Date?
    mutating func resetObservation() { backgroundSince.removeAll(); lastObservation = nil }
    mutating func becameFrontmost(_ identity: ProcessIdentity) { backgroundSince.removeValue(forKey: identity) }
    mutating func recordAttempt(_ rule: AppExitRule, at date: Date) { lastAttempt[rule.id] = date }
    mutating func restoreCooldowns(_ records: [AppExitRecord]) {
        for value in records { lastAttempt[value.ruleID] = max(lastAttempt[value.ruleID] ?? .distantPast, value.date) }
    }
    mutating func observe(_ observations: [AppExitObservation], now: Date) {
        if let lastObservation, now.timeIntervalSince(lastObservation) > 30 || now < lastObservation { resetObservation() }
        lastObservation = now
        let present = Set(observations.map(\.identity))
        backgroundSince = backgroundSince.filter { present.contains($0.key) }
        for value in observations {
            if value.isFrontmost { backgroundSince.removeValue(forKey: value.identity) }
            else if backgroundSince[value.identity] == nil { backgroundSince[value.identity] = now }
        }
    }
    func evaluate(_ rule: AppExitRule, observation: AppExitObservation, now: Date, currentUID: UInt32,
                  enabled: Bool, paused: Bool) -> AppExitDecision {
        func skip(_ reason: String) -> AppExitDecision { AppExitDecision(eligible: false, reason: reason) }
        guard enabled, rule.enabled else { return skip("规则未主动启用") }
        guard !paused else { return skip("用户暂停或睡眠保护") }
        guard rule.isValid else { return skip("规则无效") }
        guard observation.bundleID == rule.bundleID, observation.path == rule.path, observation.identity.uid == currentUID,
              observation.identity.pid > 1, observation.identity.startTime > 0 else { return skip("应用身份不匹配") }
        guard now.timeIntervalSince(observation.observedAt) >= 0, now.timeIntervalSince(observation.observedAt) <= 12 else { return skip("应用观测已过期") }
        if let reason = AppExitProtection.reason(bundleID: rule.bundleID, path: rule.path, name: rule.name) { return skip(reason) }
        guard !observation.isFrontmost else { return skip("前台应用受保护") }
        guard observation.saveState == .clean else { return skip(observation.saveState == .edited ? "存在未保存内容，已跳过" : "无法确认保存状态，已跳过") }
        if let attempt = lastAttempt[rule.id], now.timeIntervalSince(attempt) < rule.cooldownSeconds { return skip("处于冷却期，不重复请求退出") }
        guard let start = backgroundSince[observation.identity], now.timeIntervalSince(start) >= rule.minutes * 60 else {
            return skip("等待完整的后台观察时长；不会累计休眠时间")
        }
        switch rule.trigger {
        case .background: break
        case .idle:
            guard let idle = observation.idleSeconds, idle.isFinite, idle >= rule.minutes * 60 else { return skip("用户空闲时间不足或不可用") }
        case .noWindows:
            guard observation.windowCount == 0 else { return skip("仍有窗口或窗口状态未知") }
        case .memory:
            guard let bytes = observation.memoryBytes, bytes >= rule.memoryBytes else { return skip("应用内存未超阈值或不可用") }
        }
        return AppExitDecision(eligible: true, reason: "\(rule.trigger.rawValue)满足规则，保存状态可确认；仅请求正常退出")
    }
}
