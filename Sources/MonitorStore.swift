import AppKit
import Combine
import ServiceManagement
import UserNotifications
import UniformTypeIdentifiers

extension Notification.Name {
    static let monitorSettingsChanged = Notification.Name("GaoJiLing.SettingsChanged")
    static let monitorNavigate = Notification.Name("GaoJiLing.Navigate")
}

@MainActor final class MonitorStore: ObservableObject {
    @Published var latest = MetricsSample.empty
    @Published var history: [MetricsSample] = []
    @Published var events: [MonitorEvent] = []
    @Published var sessions: [MonitorSession] = []
    @Published var activeSession: MonitorSession?
    @Published var settings = AppSettings()
    @Published var statusMessage: String?
    @Published var networkChecks: [NetworkCheck] = []
    @Published var isDiagnosing = false
    @Published var isPaused = false
    @Published var focusedEvent: MonitorEvent?
    @Published var eventHistory: [MetricsSample] = []
    @Published var dataBusy = false
    @Published var dataSummaryText = "正在读取本地数据…"
    @Published var dataSizeText = "—"
    @Published var lastExportURL: URL?
    let hardwareDescription = MetricsCollector.hardwareDescription
    let dataDirectory: URL
    private var database: MonitorDatabase?
    private let collector = MetricsCollector()
    private let queue = DispatchQueue(label: "com.gaoseries.GaoJiLing.sampling", qos: .utility)
    private var timer: Timer?
    private var sampling = false
    private var lastPersisted = Date.distantPast
    private var lastPruned = Date.distantPast
    private let detector = EventDetector()
    private var settingsWritable = true
    private var dataGeneration = 0
    private let edgePreferenceKeys = ["GaoJiLing.EdgeHandle.verticalRatio", "GaoJiLing.EdgeHandle.displayUUID"]

    init(startSampling: Bool = true, directory: URL? = nil) {
        dataDirectory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("GaoSeries/GaoJiLing", isDirectory: true)
        do {
            let db = try MonitorDatabase(directory: dataDirectory)
            database = db
            do { settings = try db.settings() } catch { settingsWritable = false; statusMessage = "设置读取失败，原数据已保留：\(error.localizedDescription)" }
            history = try db.history(since: Date().addingTimeInterval(-86400))
            events = try db.events()
            sessions = try db.sessions()
            // An interrupted recording ends at its last saved observation, never at a fabricated restart time.
            for index in sessions.indices where sessions[index].end == nil {
                let lastObserved = try sessions[index].lastObserved ?? db.lastSample(since: sessions[index].start)?.timestamp ?? sessions[index].start
                sessions[index].end = max(sessions[index].start, lastObserved)
                sessions[index].interrupted = true
                try db.save(sessions[index])
            }
        } catch { statusMessage = "历史数据暂时无法读取，原文件已保留：\(error.localizedDescription)"; database = nil }
        settings.sampleInterval = min(10, max(1, settings.sampleInterval))
        settings.launchAtLogin = SMAppService.mainApp.status == .enabled
        if startSampling { restartTimer(); sampleNow() }
        refreshDataSummary()
    }
    private func restartTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: settings.sampleInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sampleNow() }
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
    }
    private func sampleNow() {
        guard !isPaused, !sampling else { return }
        sampling = true
        let collector = self.collector
        let generation = dataGeneration
        queue.async { [weak self] in
            let value = collector.sample()
            Task { @MainActor in
                guard let self else { return }
                guard self.dataGeneration == generation else { self.sampling = false; return }
                self.receive(value)
            }
        }
    }
    private func receive(_ sample: MetricsSample) {
        sampling = false
        guard !isPaused else { return }
        latest = sample
        history.append(sample)
        let cutoff = sample.timestamp.addingTimeInterval(-86400)
        if history.count > 12000 { history = history.enumerated().filter { $0.offset % 2 == 0 || $0.element.timestamp > sample.timestamp.addingTimeInterval(-600) }.map(\.element) }
        history.removeAll { $0.timestamp < cutoff }
        if var session = activeSession, sample.timestamp >= session.start {
            session.peakCPU = max(session.peakCPU, sample.cpuPercent ?? 0)
            session.peakMemory = max(session.peakMemory, sample.memoryUsed)
            if let temperature = sample.cpuTemperature { session.peakTemperature = max(session.peakTemperature ?? temperature, temperature) }
            if let cpu = sample.cpuPercent { session.cpuTotal += cpu; session.sampleCount += 1 }
            session.lastObserved = sample.timestamp
            activeSession = session
        }
        for event in detector.evaluate(sample) {
            events.insert(event, at: 0)
            do { try database?.save(event) } catch { report(error) }
            if settings.notificationsEnabled { notify(event) }
        }
        events = Array(events.prefix(300))
        if sample.timestamp.timeIntervalSince(lastPersisted) >= 10 {
            lastPersisted = sample.timestamp
            do { try database?.append(sample); if let activeSession { try database?.save(activeSession) } } catch { report(error) }
        }
        if sample.timestamp.timeIntervalSince(lastPruned) > 3600 {
            lastPruned = sample.timestamp
            do { try database?.prune(days: settings.retentionDays) } catch { report(error) }
        }
    }
    private func report(_ error: Error) { statusMessage = "保存失败：\(error.localizedDescription)。请检查可用空间。" }
    func checkpoint() { guard !dataBusy else { return }; do { if latest.memoryTotal > 0 { try database?.append(latest) }; if let activeSession { try database?.save(activeSession) } } catch { report(error) } }
    func shutdown() { timer?.invalidate(); if activeSession != nil { endSession() }; checkpoint() }
    func prepareForSleep() { detector.reset(); checkpoint() }
    func saveSettings() {
        guard !dataBusy else { return }
        guard database != nil else { statusMessage = "数据存储不可用，设置未保存。请检查数据目录后重新打开应用。"; return }
        guard settingsWritable else { statusMessage = "原设置读取异常，暂不覆盖。请先备份数据并检查数据库。"; return }
        settings.edgeDelay = min(1.5, max(0.2, settings.edgeDelay))
        settings.sampleInterval = min(10, max(1, settings.sampleInterval))
        settings.retentionDays = min(30, max(1, settings.retentionDays))
        do { try database?.save(settings) } catch { report(error); return }
        restartTimer()
        NotificationCenter.default.post(name: .monitorSettingsChanged, object: nil)
    }
    func togglePause() { guard !dataBusy else { return }; isPaused.toggle(); detector.reset(); if !isPaused { sampleNow() } }
    func startSession(name: String) {
        guard activeSession == nil, !dataBusy else { return }
        guard database != nil else { statusMessage = "数据存储不可用，无法开始持久保存的任务记录。请检查数据目录后重新打开应用。"; return }
        activeSession = MonitorSession(name: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "任务 \(Date().formatted(date: .omitted, time: .shortened))" : String(name.prefix(80)), start: Date())
        checkpoint()
    }
    func endSession() {
        guard !dataBusy, var session = activeSession else { return }
        session.end = Date(); activeSession = nil
        sessions.insert(session, at: 0)
        do { try database?.save(session) } catch { report(error) }
    }
    func focusEvent(_ event: MonitorEvent) {
        let start = event.date.addingTimeInterval(-86400), end = event.date.addingTimeInterval(300)
        do {
            let saved = try database?.history(since: start, until: end) ?? []
            var merged = Dictionary(saved.map { ($0.timestamp, $0) }, uniquingKeysWith: { _, new in new })
            for sample in history where sample.timestamp >= start && sample.timestamp <= end { merged[sample.timestamp] = sample }
            eventHistory = merged.values.sorted { $0.timestamp < $1.timestamp }
            focusedEvent = event
        } catch { statusMessage = "无法读取该事件的历史：\(error.localizedDescription)" }
    }
    func openActivityMonitor() { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app")) }
    func revealDataFolder() { NSWorkspace.shared.open(dataDirectory) }
    func setLoginEnabled(_ enabled: Bool) {
        do { if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            settings.launchAtLogin = SMAppService.mainApp.status == .enabled
            if enabled && !settings.launchAtLogin { statusMessage = "请到系统设置 → 通用 → 登录项确认允许搞机灵。" }
            saveSettings()
        } catch { settings.launchAtLogin = SMAppService.mainApp.status == .enabled; statusMessage = "登录项设置失败：\(error.localizedDescription)" }
    }
    func requestNotifications() {
        guard settings.notificationsEnabled else { saveSettings(); return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [weak self] granted, error in
            Task { @MainActor in
                self?.settings.notificationsEnabled = granted
                if !granted { self?.statusMessage = "通知未开启，可在系统设置中允许搞机灵发送通知。" }
                if let error { self?.statusMessage = error.localizedDescription }
                self?.saveSettings()
            }
        }
    }
    private func notify(_ event: MonitorEvent) {
        let content = UNMutableNotificationContent(); content.title = event.title; content.body = event.detail
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: event.id.uuidString, content: content, trigger: nil))
    }
    func runNetworkDiagnostics(host: String) {
        guard !isDiagnosing else { return }
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, host.count <= 253, host.range(of: "^[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?$", options: .regularExpression) != nil else { statusMessage = "请输入域名，例如 www.apple.com；不需要 https:// 或路径。"; return }
        isDiagnosing = true
        networkChecks = [NetworkCheck(title: "检查中", detail: "正在检查 DNS、默认网关和 HTTPS：\(host)", success: nil)]
        Task {
            let result = await NetworkDiagnostics.run(host: host)
            networkChecks = result; isDiagnosing = false
        }
    }
    func exportHistory(minutes: Int = 1440, eventDate: Date? = nil) {
        let anchor = eventDate ?? Date()
        exportTable("history", days: 0,
                    since: anchor.addingTimeInterval(-Double(minutes) * 60),
                    until: eventDate == nil ? anchor : anchor.addingTimeInterval(300))
    }
    func exportSession(_ session: MonitorSession) {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        do { saveExport(try encoder.encode(session), name: "搞机灵-任务记录.json", type: .json) } catch { report(error) }
    }
    private func saveExport(_ data: Data, name: String, type: UTType) {
        let panel = NSSavePanel(); panel.nameFieldStringValue = name; panel.allowedContentTypes = [type]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            guard let database else { storageUnavailable(); return }
            try database.validateExportDestination(url)
            try data.write(to: url, options: .atomic); lastExportURL = url; statusMessage = "已导出：\(url.lastPathComponent)"
        } catch { report(error) }
    }
}

extension MonitorStore {
    private var savedEdgePreferences: [String: String] {
        var result: [String: String] = [:]
        for key in edgePreferenceKeys {
            if let value = UserDefaults.standard.object(forKey: key) { result[key] = String(describing: value) }
        }
        return result
    }
    func refreshDataSummary() {
        guard let database else { dataSummaryText = "本地存储不可用"; return }
        do {
            let summary = try database.dataSummary()
            dataSummaryText = "\(summary.sampleCount) 条采样 · \(summary.eventCount) 个事件 · \(summary.sessionCount) 项任务"
            var size: Int64 = 0
            for name in ["monitor.sqlite", "monitor.sqlite-wal", "monitor.sqlite-shm"] {
                let url = database.directory.appendingPathComponent(name)
                size += (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            }
            dataSizeText = Format.bytes(Double(size))
        } catch { dataSummaryText = "读取失败：\(error.localizedDescription)" }
    }
    func revealLastExport() {
        if let lastExportURL { NSWorkspace.shared.activateFileViewerSelecting([lastExportURL]) }
    }
    func exportTable(_ kind: String, days: Int, since requestedStart: Date? = nil, until requestedEnd: Date? = nil) {
        guard !dataBusy else { return }
        guard let database else { storageUnavailable(); return }
        checkpoint()
        let title = kind == "events" ? "异常事件" : kind == "sessions" ? "任务汇总" : "监控记录"
        let panel = NSSavePanel(); panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "搞机灵-\(title)-\(Date().formatted(.iso8601.year().month().day().dateSeparator(.dash))).csv"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do { try database.validateExportDestination(destination) } catch { statusMessage = error.localizedDescription; return }
        dataBusy = true; statusMessage = "正在导出\(title)…"
        let directory = database.directory
        Task {
            do {
                let count = try await Task.detached(priority: .utility) {
                    let db = try MonitorDatabase(directory: directory)
                    let since = requestedStart ?? (days == 0 ? Date.distantPast : Date().addingTimeInterval(-Double(days) * 86400))
                    let data: Data; let count: Int
                    if kind == "events" {
                        let values = try db.allEvents().filter { $0.date >= since }
                        data = MonitorCSV.events(values); count = values.count
                    } else if kind == "sessions" {
                        let values = try db.allSessions().filter { $0.end != nil && $0.start >= since }
                        data = MonitorCSV.sessions(values); count = values.count
                    } else {
                        let values = try db.history(since: since, until: requestedEnd ?? .distantFuture)
                        data = MonitorCSV.history(values); count = values.count
                    }
                    try data.write(to: destination, options: .atomic)
                    return count
                }.value
                lastExportURL = destination; statusMessage = "已导出 \(count) 条\(title)：\(destination.lastPathComponent)"
            } catch { statusMessage = "导出失败：\(error.localizedDescription)" }
            dataBusy = false; refreshDataSummary()
        }
    }
    func exportFullBackup() {
        guard !dataBusy else { return }
        guard let database else { storageUnavailable(); return }
        checkpoint()
        let panel = NSSavePanel(); panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "搞机灵-完整备份-\(backupStamp()).json"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        dataBusy = true; statusMessage = "正在备份全部历史、任务和设置，并校验文件…"
        let directory = database.directory, prefs = savedEdgePreferences
        Task {
            do {
                let result = try await Task.detached(priority: .utility) {
                    try MonitorDatabase(directory: directory).exportBackup(to: destination, appVersion: GLPalette.version, auxiliaryPreferences: prefs)
                }.value
                lastExportURL = destination
                statusMessage = "完整备份已保存并通过校验：\(result.sampleCount) 条采样、\(result.eventCount) 个事件、\(result.sessionCount) 项任务。"
            } catch { statusMessage = "备份失败：\(error.localizedDescription)" }
            dataBusy = false; refreshDataSummary()
        }
    }
    func restoreFullBackup() {
        guard !dataBusy else { return }
        guard let database else { storageUnavailable(); return }
        guard activeSession == nil else { statusMessage = "请先结束当前任务记录，再恢复备份。"; return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        panel.message = "选择搞机灵导出的完整备份 JSON 文件"
        guard panel.runModal() == .OK, let source = panel.url else { return }
        dataBusy = true; statusMessage = "正在核验备份…"
        let directory = database.directory
        Task {
            var samplingWasPaused: Bool?
            var recoveryFile: URL?
            var restoreCommitted = false
            do {
                let backup = try await Task.detached(priority: .utility) { try MonitorDatabase.inspectBackup(at: source) }.value
                let alert = NSAlert(); alert.alertStyle = .warning; alert.messageText = "恢复这份完整备份？"
                alert.informativeText = "将恢复 \(backup.samples.count) 条采样、\(backup.events.count) 个事件、\(backup.sessions.count) 项任务和应用设置，替换当前记录。恢复前会自动保存一份当前数据的安全备份。登录项与通知权限保留本机当前状态。"
                alert.addButton(withTitle: "备份当前数据并恢复"); alert.addButton(withTitle: "取消")
                guard alert.runModal() == .alertFirstButtonReturn else { dataBusy = false; statusMessage = "已取消恢复，当前数据未改变。"; return }
                samplingWasPaused = isPaused; isPaused = true; dataGeneration += 1; detector.reset()
                if latest.memoryTotal > 0 { try database.append(latest) }
                let recoveryDirectory = directory.appendingPathComponent("Recovery", isDirectory: true)
                try FileManager.default.createDirectory(at: recoveryDirectory, withIntermediateDirectories: true)
                let recovery = recoveryDirectory.appendingPathComponent("恢复前安全备份-\(backupStamp())-\(UUID().uuidString.prefix(6)).json")
                recoveryFile = recovery
                let prefs = savedEdgePreferences
                statusMessage = "正在保存安全备份并恢复…"
                _ = try await Task.detached(priority: .utility) {
                    let db = try MonitorDatabase(directory: directory)
                    _ = try db.exportBackup(to: recovery, appVersion: GLPalette.version, auxiliaryPreferences: prefs)
                    return try db.restoreBackup(backup)
                }.value
                restoreCommitted = true
                let currentNotifications = settings.notificationsEnabled
                settings = try database.settings()
                settings.sampleInterval = min(10, max(1, settings.sampleInterval))
                settings.edgeDelay = min(1.5, max(0.2, settings.edgeDelay))
                settings.retentionDays = min(30, max(1, settings.retentionDays))
                settings.launchAtLogin = SMAppService.mainApp.status == .enabled
                settings.notificationsEnabled = settings.notificationsEnabled && currentNotifications
                try database.save(settings); settingsWritable = true
                history = try database.history(since: Date().addingTimeInterval(-86400))
                events = try database.events(); sessions = try database.allSessions()
                for index in sessions.indices where sessions[index].end == nil {
                    let end = try sessions[index].lastObserved ?? database.lastSample(since: sessions[index].start)?.timestamp ?? sessions[index].start
                    sessions[index].end = max(sessions[index].start, end); sessions[index].interrupted = true
                    try database.save(sessions[index])
                }
                sessions = Array(sessions.prefix(300))
                for key in edgePreferenceKeys { UserDefaults.standard.removeObject(forKey: key) }
                if let value = backup.auxiliaryPreferences?[edgePreferenceKeys[0]], let ratio = Double(value), ratio.isFinite, (0...1).contains(ratio) {
                    UserDefaults.standard.set(ratio, forKey: edgePreferenceKeys[0])
                }
                if let value = backup.auxiliaryPreferences?[edgePreferenceKeys[1]], UUID(uuidString: value) != nil {
                    UserDefaults.standard.set(value, forKey: edgePreferenceKeys[1])
                }
                focusedEvent = nil; eventHistory = []; latest = .empty; lastPersisted = .distantPast; lastPruned = Date()
                restartTimer(); NotificationCenter.default.post(name: .monitorSettingsChanged, object: nil)
                lastExportURL = recovery; statusMessage = "恢复完成。恢复前的数据已保存在数据目录的 Recovery 文件夹。"
            } catch {
                if restoreCommitted {
                    // Never resume persistence from stale memory after the replacement has committed.
                    self.database = nil; isPaused = true
                    latest = .empty; history = []; events = []; sessions = []; focusedEvent = nil; eventHistory = []
                }
                if let recoveryFile, FileManager.default.fileExists(atPath: recoveryFile.path) {
                    lastExportURL = recoveryFile
                    let prefix = restoreCommitted ? "数据已恢复，但重新加载失败；采样已暂停，请退出并重新打开应用。" : "恢复未完成："
                    statusMessage = "\(prefix)\(error.localizedDescription)。恢复前数据已保存为 \(recoveryFile.lastPathComponent)。"
                } else { statusMessage = "恢复未完成：\(error.localizedDescription)。原数据未改变。" }
            }
            dataBusy = false
            if let samplingWasPaused, self.database != nil { isPaused = samplingWasPaused; if !isPaused { sampleNow() } }
            refreshDataSummary()
        }
    }
    func clearSavedData(_ scope: MonitorDataScope) {
        guard !dataBusy else { return }
        guard let database else { storageUnavailable(); return }
        guard activeSession == nil else { statusMessage = "请先结束当前任务记录，再清理数据。"; return }
        let title: String
        switch scope { case .history: title = "历史采样"; case .events: title = "异常事件"; case .sessions: title = "已完成任务" }
        let alert = NSAlert(); alert.alertStyle = .warning; alert.messageText = "清空全部\(title)？"
        alert.informativeText = "只删除\(title)，其他记录和设置保持不变。此操作无法撤销，请先导出完整备份。"
        alert.addButton(withTitle: "取消"); alert.addButton(withTitle: "清空\(title)")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        do {
            _ = try database.clearData(scope)
            switch scope {
            case .history: history = []; eventHistory = []; focusedEvent = nil; latest = .empty; lastPersisted = .distantPast; dataGeneration += 1
            case .events: events = []; focusedEvent = nil; eventHistory = []
            case .sessions: sessions = []
            }
            statusMessage = "已清空\(title)。"; refreshDataSummary()
        } catch { statusMessage = "清理失败：\(error.localizedDescription)" }
    }
    private func backupStamp() -> String {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return formatter.string(from: Date())
    }
    private func storageUnavailable() {
        statusMessage = "数据存储暂不可用，不能安全导出或恢复。原文件已保留，请通过“打开数据文件夹”备份原文件并检查后重新打开应用。"
    }
    func openNotices() {
        if let url = Bundle.main.url(forResource: "THIRD-PARTY-NOTICES", withExtension: "txt") { NSWorkspace.shared.open(url) }
    }
    func openGuide() {
        if let url = Bundle.main.url(forResource: "使用说明", withExtension: "txt") { NSWorkspace.shared.open(url) }
    }
}
