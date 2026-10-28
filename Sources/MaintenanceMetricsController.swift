import AppKit
import Combine
import UserNotifications

@MainActor final class MaintenanceController: ObservableObject {
    @Published private(set) var preferences: MaintenancePreferences
    @Published private(set) var status: String?
    @Published private(set) var ruleReasons: [UUID: String] = [:]
    @Published private(set) var batteryNotices: [BatteryNotice] = []
    @Published private(set) var isChecking = false
    var writable: Bool { file.writable }
    private let file: MaintenanceStateFile
    private let driver: AppExitDriver
    private let clock: () -> Date
    private let uptime: () -> TimeInterval
    private let deliverNotice: (BatteryNotice) -> Void
    private let actionsAllowed: () -> Bool
    private var policy = AppExitPolicy()
    private var batteryPolicy = BatteryNoticePolicy()
    private var lastCheck = Date.distantPast
    private var lastUptime: TimeInterval?
    private var lastDate: Date?
    private var generation = 0
    private var sleeping = false
    private var actionsSuspended = false
    private var observers: [NSObjectProtocol] = []
    private var pending: (attempt: AppExitAttempt, rule: AppExitRule, date: Date)?
    private var lastSaveCheck: [UUID: Date] = [:]

    init(dataDirectory: URL, driver: AppExitDriver? = nil, clock: @escaping () -> Date = { Date() },
         uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }, observeWorkspace: Bool = true,
         deliverNotice: ((BatteryNotice) -> Void)? = nil, actionsAllowed: @escaping () -> Bool = { true }) {
        file = MaintenanceStateFile(dataDirectory: dataDirectory)
        self.driver = driver ?? .live; self.clock = clock; self.uptime = uptime
        self.actionsAllowed = actionsAllowed
        self.deliverNotice = deliverNotice ?? { notice in
            let content = UNMutableNotificationContent(); content.title = notice.title; content.body = notice.detail
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "maintenance-battery-" + notice.id, content: content, trigger: nil))
        }
        preferences = file.preferences; status = file.loadError
        policy.restoreCooldowns(preferences.records)
        guard observeWorkspace else { return }
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.handleSleep(true) }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.handleSleep(false) }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] notice in
            let pid = (notice.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            Task { @MainActor in
                guard let self, let pid, let identity = AppExitRuntime.identity(pid: pid) else { return }
                self.policy.becameFrontmost(identity); self.generation += 1
            }
        })
    }
    func shutdown() {
        actionsSuspended = true; generation += 1
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }; observers.removeAll()
    }
    func setActionsSuspended(_ value: Bool) {
        if actionsSuspended != value { actionsSuspended = value; generation += 1; policy.resetObservation() }
    }
    func handleSleep(_ value: Bool) {
        sleeping = value; generation += 1; policy.resetObservation(); lastUptime = nil; lastDate = nil
    }
    func update(_ change: (inout MaintenancePreferences) -> Void) {
        var next = preferences; change(&next)
        do {
            try file.save(next); preferences = next
            generation += 1; policy.resetObservation()
            status = "维护设置已保存。硬件充电和风扇仍由系统管理。"
        } catch { status = error.localizedDescription; generation += 1 }
    }
    func chooseApplication() {
        guard writable else { return }
        let panel = NSOpenPanel(); panel.title = "选择正常退出规则的应用"
        panel.message = "只添加停用的规则。系统、搞系列、浏览器、编辑器、下载器和安全应用受保护。"
        panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.applicationBundle]
        guard panel.runModal() == .OK, let url = panel.url?.resolvingSymlinksInPath(), let bundle = Bundle(url: url),
              let id = bundle.bundleIdentifier else { return }
        let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String ?? url.deletingPathExtension().lastPathComponent
        if let reason = AppExitProtection.reason(bundle: bundle, path: url.path, name: name) { status = reason; return }
        guard preferences.rules.count < 32 else { status = "最多保存 32 条规则。"; return }
        guard !preferences.rules.contains(where: { $0.path == url.path && $0.bundleID == id }) else { status = "此应用已有规则。"; return }
        update { $0.rules.append(AppExitRule(bundleID: id, path: url.path, name: name)) }
    }
    func requestNotificationAccess() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
            Task { @MainActor in self?.status = granted ? "通知已获准；可启用电池提醒。" : "通知未获准；仍可在此页查看电池提醒。" }
        }
    }
    /// Called by the existing store's sampling subscription. No second metrics
    /// timer, process enumeration loop, or network service is installed.
    func ingest(sample: MetricsSample) {
        let now = clock(), uptime = self.uptime()
        if let lastDate, let lastUptime,
           abs(now.timeIntervalSince(lastDate) - (uptime - lastUptime)) > 3 || now.timeIntervalSince(lastDate) > 30 {
            generation += 1; policy.resetObservation()
        }
        lastDate = now; lastUptime = uptime
        let notices = batteryPolicy.evaluate(sample.batterySnapshot, rule: preferences.batteryRule, now: now)
        if !notices.isEmpty {
            batteryNotices = Array((notices + batteryNotices).prefix(10))
            // Adding a request cannot grant permission or open a prompt.
            for notice in notices { deliverNotice(notice) }
        }
        finishPending(now: now)
        // The app's @Published busy notifications arrive asynchronously. Read
        // the actual operation state synchronously as well, so a queued AX
        // completion cannot race an already-started restore/cleanup/exit.
        guard actionsAllowed() else { generation += 1; policy.resetObservation(); return }
        guard preferences.appExitEnabled, !preferences.appExitPaused, !sleeping, !actionsSuspended, writable,
              pending == nil, !isChecking, now.timeIntervalSince(lastCheck) >= 10 else { return }
        lastCheck = now
        let observations = driver.observations(preferences.rules, sample, now)
        policy.observe(observations, now: now)
        var candidate: (AppExitRule, AppExitObservation)?
        for rule in preferences.rules {
            guard !preferences.protectedBundleIDs.contains(rule.bundleID) else { ruleReasons[rule.id] = "用户保护名单中的应用"; continue }
            guard let observation = observations.first(where: { $0.bundleID == rule.bundleID && $0.path == rule.path }) else {
                ruleReasons[rule.id] = rule.enabled ? "未运行、身份不可确认或受保护" : "规则未启用"; continue
            }
            var provisional = observation; provisional.saveState = .clean; provisional.windowCount = 0
            let decision = policy.evaluate(rule, observation: provisional, now: now, currentUID: geteuid(), enabled: true, paused: false)
            ruleReasons[rule.id] = decision.reason
            if decision.eligible, candidate == nil || (lastSaveCheck[rule.id] ?? .distantPast) < (lastSaveCheck[candidate!.0.id] ?? .distantPast) { candidate = (rule, observation) }
        }
        guard let (rule, observation) = candidate else { return }
        lastSaveCheck[rule.id] = now
        let expectedGeneration = generation
        let inspect = driver.inspect
        isChecking = true
        Task { [weak self] in
            let saved = await Task.detached(priority: .utility) { inspect(observation) }.value
            guard let self else { return }
            defer { self.isChecking = false }
            guard self.generation == expectedGeneration, self.writable, !self.sleeping, !self.actionsSuspended, self.actionsAllowed() else { return }
            guard saved.identity == observation.identity else { self.ruleReasons[rule.id] = "保存状态检查期间进程身份发生变化，已跳过"; return }
            var checked = observation; checked.windowCount = saved.windows; checked.saveState = saved.saved
            let decision = self.policy.evaluate(rule, observation: checked, now: self.clock(), currentUID: geteuid(), enabled: self.preferences.appExitEnabled, paused: self.preferences.appExitPaused)
            self.ruleReasons[rule.id] = decision.reason
            guard decision.eligible, self.actionsAllowed(), self.driver.validate(checked), self.actionsAllowed() else { return }
            // Recheck saved state off the main actor, then repeat every local
            // guard before persisting intent. This narrows the inspection gap;
            // normal quit still lets the target handle later document changes.
            let finalSaved = await Task.detached(priority: .utility) { inspect(observation) }.value
            guard self.generation == expectedGeneration, self.writable, !self.sleeping, !self.actionsSuspended, self.actionsAllowed() else { return }
            guard finalSaved.identity == observation.identity else { self.ruleReasons[rule.id] = "请求前复核期间进程身份发生变化，已跳过"; return }
            checked.windowCount = finalSaved.windows; checked.saveState = finalSaved.saved
            let finalDecision = self.policy.evaluate(rule, observation: checked, now: self.clock(), currentUID: geteuid(), enabled: self.preferences.appExitEnabled, paused: self.preferences.appExitPaused)
            self.ruleReasons[rule.id] = finalDecision.reason
            guard finalDecision.eligible, self.actionsAllowed(), self.driver.validate(checked), self.actionsAllowed() else { return }
            let prepared = AppExitRecord(ruleID: rule.id, date: self.clock(), name: rule.name, outcome: "准备请求", reason: finalDecision.reason)
            // Durable intent before the only side effect. A crash never replays it.
            guard self.appendRecord(prepared) else { return }
            self.policy.recordAttempt(rule, at: prepared.date)
            guard self.generation == expectedGeneration, self.writable, !self.sleeping, !self.actionsSuspended, self.actionsAllowed(), self.driver.validate(checked), self.actionsAllowed() else { return }
            let attempt = self.driver.request(checked)
            if attempt.accepted {
                self.pending = (attempt, rule, prepared.date)
                self.ruleReasons[rule.id] = "正常退出请求已发出，等待应用实际退出；保存提示仍由原应用处理"
            } else {
                _ = self.appendRecord(AppExitRecord(ruleID: rule.id, date: self.clock(), name: rule.name, outcome: "未发送", reason: "应用拒绝或退出请求失败；未强退，进入冷却"))
            }
        }
    }
    private func finishPending(now: Date) {
        guard let value = pending else { return }
        let ended = value.attempt.hasExited()
        if ended || now.timeIntervalSince(value.date) > 30 {
            let reason = ended ? "已观察到原应用退出；不将进程内存视作系统已释放空间" : "应用仍在运行或等待保存；停止重试，未强退"
            _ = appendRecord(AppExitRecord(ruleID: value.rule.id, date: now, name: value.rule.name,
                outcome: ended ? "已退出" : "未退出", reason: reason))
            ruleReasons[value.rule.id] = reason; pending = nil
        }
    }
    private func appendRecord(_ record: AppExitRecord) -> Bool {
        var next = preferences; next.records.append(record); next.records = Array(next.records.suffix(100))
        do { try file.save(next); preferences = next; return true }
        catch { status = "退出记录无法保存，自动退出已停止：\(error.localizedDescription)"; generation += 1; return false }
    }
}
