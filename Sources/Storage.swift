import Foundation
import SQLite3
import CryptoKit
import Darwin

final class MonitorDatabase {
    private var db: OpaquePointer?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    let directory: URL
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(directory: URL? = nil) throws {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("GaoSeries/GaoJiLing", isDirectory: true)
        try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
        let file = self.directory.appendingPathComponent("monitor.sqlite")
        guard sqlite3_open_v2(file.path, &db, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else { throw error() }
        sqlite3_busy_timeout(db, 1500)
        try execute("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; CREATE TABLE IF NOT EXISTS samples(t REAL PRIMARY KEY, payload TEXT NOT NULL); CREATE TABLE IF NOT EXISTS events(id TEXT PRIMARY KEY,t REAL NOT NULL,payload TEXT NOT NULL); CREATE TABLE IF NOT EXISTS sessions(id TEXT PRIMARY KEY,t REAL NOT NULL,payload TEXT NOT NULL); CREATE TABLE IF NOT EXISTS preferences(id INTEGER PRIMARY KEY CHECK(id=1),payload TEXT NOT NULL);")
    }
    deinit { if let db { sqlite3_close(db) } }
    private func error() -> Error { NSError(domain: "GaoJiLing.Storage", code: Int(sqlite3_errcode(db)), userInfo: [NSLocalizedDescriptionKey: db.map { String(cString: sqlite3_errmsg($0)) } ?? "无法打开历史数据库"]) }
    private func execute(_ sql: String) throws { guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw error() } }
    private func put<T: Encodable>(_ value: T, sql: String, id: String? = nil, time: Date? = nil) throws {
        let payload = String(data: try encoder.encode(value), encoding: .utf8)!
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw error() }
        defer { sqlite3_finalize(statement) }
        var index: Int32 = 1
        if let id { sqlite3_bind_text(statement, index, id, -1, transient); index += 1 }
        if let time { sqlite3_bind_double(statement, index, time.timeIntervalSince1970); index += 1 }
        sqlite3_bind_text(statement, index, payload, -1, transient)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw error() }
    }
    private func read<T: Decodable>(_ type: T.Type, sql: String) throws -> [T] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw error() }
        defer { sqlite3_finalize(statement) }
        var result: [T] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return result }
            guard status == SQLITE_ROW, let string = sqlite3_column_text(statement, 0) else { throw error() }
            let bytes = Data(String(cString: string).utf8)
            result.append(try decoder.decode(T.self, from: bytes))
        }
    }
    func append(_ sample: MetricsSample) throws {
        var compact = sample
        compact.processes = Array(sample.processes.sorted { $0.cpuPercent > $1.cpuPercent }.prefix(6))
        compact.corePercents = []
        try put(compact, sql: "INSERT OR REPLACE INTO samples(t,payload) VALUES(?,?)", time: sample.timestamp)
    }
    func history(since: Date, until: Date = .distantFuture) throws -> [MetricsSample] {
        try read(MetricsSample.self, sql: "SELECT payload FROM samples WHERE t >= \(since.timeIntervalSince1970) AND t <= \(until.timeIntervalSince1970) ORDER BY t")
    }
    func events() throws -> [MonitorEvent] { try read(MonitorEvent.self, sql: "SELECT payload FROM events ORDER BY t DESC LIMIT 300") }
    func sessions() throws -> [MonitorSession] { try read(MonitorSession.self, sql: "SELECT payload FROM sessions ORDER BY t DESC LIMIT 300") }
    func allEvents() throws -> [MonitorEvent] { try read(MonitorEvent.self, sql: "SELECT payload FROM events ORDER BY t DESC, id") }
    func allSessions() throws -> [MonitorSession] { try read(MonitorSession.self, sql: "SELECT payload FROM sessions ORDER BY t DESC, id") }
    func lastSample(since: Date) throws -> MetricsSample? { try read(MetricsSample.self, sql: "SELECT payload FROM samples WHERE t >= \(since.timeIntervalSince1970) ORDER BY t DESC LIMIT 1").first }
    func save(_ event: MonitorEvent) throws { try put(event, sql: "INSERT OR REPLACE INTO events(id,t,payload) VALUES(?,?,?)", id: event.id.uuidString, time: event.date) }
    func save(_ session: MonitorSession) throws { try put(session, sql: "INSERT OR REPLACE INTO sessions(id,t,payload) VALUES(?,?,?)", id: session.id.uuidString, time: session.start) }
    func settings() throws -> AppSettings { try read(AppSettings.self, sql: "SELECT payload FROM preferences WHERE id=1").first ?? AppSettings() }
    func save(_ settings: AppSettings) throws { try put(settings, sql: "INSERT OR REPLACE INTO preferences(id,payload) VALUES(1,?)") }
    func prune(days: Int, now: Date = Date()) throws {
        let cutoff = now.addingTimeInterval(-Double(max(1, min(days, 30))) * 86400).timeIntervalSince1970
        let yesterday = now.addingTimeInterval(-86400).timeIntervalSince1970
        try execute("DELETE FROM samples WHERE t < \(cutoff); DELETE FROM events WHERE t < \(cutoff); DELETE FROM samples WHERE t < \(yesterday) AND t NOT IN (SELECT MIN(t) FROM samples WHERE t < \(yesterday) GROUP BY CAST(t/60 AS INTEGER)); PRAGMA incremental_vacuum;")
    }

    /// A connection is used serially. A read transaction makes all four tables one consistent snapshot,
    /// including when another connection is recording new observations through WAL.
    private func transaction<T>(write: Bool, _ operation: () throws -> T) throws -> T {
        try execute(write ? "BEGIN IMMEDIATE" : "BEGIN DEFERRED")
        do {
            let result = try operation()
            try execute("COMMIT")
            return result
        } catch {
            let original = error
            try? execute("ROLLBACK")
            throw original
        }
    }

    private func count(_ table: String) throws -> Int {
        // Only private, fixed table names are passed here.
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM \(table)", -1, &statement, nil) == SQLITE_OK else { throw error() }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw error() }
        return Int(sqlite3_column_int64(statement, 0))
    }

    func dataSummary() throws -> MonitorDataSummary {
        try transaction(write: false) {
            try MonitorDataSummary(sampleCount: count("samples"), eventCount: count("events"), sessionCount: count("sessions"))
        }
    }

    /// Shared by full backups, CSV and individual task exports. Resolve symlinks and compare
    /// existing file identities as well as names, so alternate-case paths and aliases are protected.
    func validateExportDestination(_ destination: URL) throws {
        guard destination.isFileURL else { throw MonitorBackupError.invalid("导出目标必须是本地文件。") }
        let protectedDirectory = directory.resolvingSymlinksInPath().standardizedFileURL
        let resolved = destination.resolvingSymlinksInPath().standardizedFileURL
        let protectedNames = ["monitor.sqlite", "monitor.sqlite-wal", "monitor.sqlite-shm", "monitor.sqlite-journal"]
        func sameFile(_ first: URL, _ second: URL) -> Bool {
            if first.path == second.path { return true }
            guard let a = try? FileManager.default.attributesOfItem(atPath: first.path),
                  let b = try? FileManager.default.attributesOfItem(atPath: second.path),
                  let deviceA = a[.systemNumber] as? NSNumber, let deviceB = b[.systemNumber] as? NSNumber,
                  let inodeA = a[.systemFileNumber] as? NSNumber, let inodeB = b[.systemFileNumber] as? NSNumber else { return false }
            return deviceA == deviceB && inodeA == inodeB
        }
        let protectedName = sameFile(resolved.deletingLastPathComponent(), protectedDirectory)
            && protectedNames.contains(resolved.lastPathComponent.lowercased())
        guard !sameFile(resolved, protectedDirectory), !protectedName,
              !protectedNames.contains(where: { sameFile(protectedDirectory.appendingPathComponent($0), resolved) }) else {
            throw MonitorBackupError.invalid("不能用导出文件覆盖正在使用的数据库或其日志。")
        }
    }

    /// Export never deletes an existing destination before the replacement has passed validation.
    @discardableResult
    func exportBackup(to destination: URL, appVersion: String, auxiliaryPreferences: [String: String] = [:]) throws -> MonitorDataSummary {
        try validateExportDestination(destination)
        var backup: MonitorBackup = try transaction(write: false) {
            MonitorBackup(appVersion: appVersion, exportedAt: Date(),
                          samples: try read(MetricsSample.self, sql: "SELECT payload FROM samples ORDER BY t"),
                          events: try allEvents(), sessions: try allSessions(),
                          settings: try read(AppSettings.self, sql: "SELECT payload FROM preferences WHERE id=1").first,
                          auxiliaryPreferences: auxiliaryPreferences.isEmpty ? nil : auxiliaryPreferences)
        }
        try backup.seal()
        try backup.validate()
        let data = try MonitorBackup.jsonEncoder(pretty: true).encode(backup)
        guard data.count <= MonitorBackup.maximumFileBytes else { throw MonitorBackupError.tooLarge }
        let folder = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let staged = folder.appendingPathComponent(".gaojiling-backup-\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: staged) }
        try data.write(to: staged, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: staged.path)
        _ = try Self.inspectBackup(at: staged)
        // POSIX rename is atomic on the same filesystem and leaves an old file intact on failure.
        guard Darwin.rename(staged.path, destination.path) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "备份无法写入目标：\(String(cString: strerror(errno)))"])
        }
        return backup.summary
    }

    /// Read once for preview/confirmation, then pass this verified in-memory value to restoreBackup.
    /// No database is opened or changed here. The byte limit is also enforced during reading.
    static func inspectBackup(at source: URL) throws -> MonitorBackup {
        guard source.isFileURL else { throw MonitorBackupError.invalid("备份来源必须是本地文件。") }
        let values = try source.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else { throw MonitorBackupError.invalid("请选择完整资料 JSON 文件。") }
        guard (values.fileSize ?? 0) <= MonitorBackup.maximumFileBytes else { throw MonitorBackupError.tooLarge }
        let handle = try FileHandle(forReadingFrom: source)
        defer { try? handle.close() }
        var data = Data()
        while let part = try handle.read(upToCount: 1_048_576), !part.isEmpty {
            guard part.count <= MonitorBackup.maximumFileBytes - data.count else { throw MonitorBackupError.tooLarge }
            data.append(part)
        }
        let backup: MonitorBackup
        do { backup = try JSONDecoder().decode(MonitorBackup.self, from: data) }
        catch { throw MonitorBackupError.invalid("文件格式无效或内容不完整：\(error.localizedDescription)") }
        try backup.validate()
        return backup
    }

    /// Replaces the database only after validating the whole archive. Auxiliary UI preferences are
    /// returned in MonitorBackup for a caller-owned allowlist; this method never touches UserDefaults.
    @discardableResult
    func restoreBackup(_ backup: MonitorBackup) throws -> MonitorDataSummary {
        try backup.validate()
        return try transaction(write: true) {
            try execute("DELETE FROM samples; DELETE FROM events; DELETE FROM sessions; DELETE FROM preferences;")
            for sample in backup.samples {
                // Preserve the exact archived payload; append() intentionally compacts live observations.
                try put(sample, sql: "INSERT INTO samples(t,payload) VALUES(?,?)", time: sample.timestamp)
            }
            for event in backup.events { try save(event) }
            for session in backup.sessions { try save(session) }
            if let settings = backup.settings { try save(settings) }
            return backup.summary
        }
    }

    /// The caller explicitly selects one kind. History cleanup never deletes task records or settings.
    /// A cutoff removes records strictly older than the cutoff; equality is retained.
    @discardableResult
    func clearData(_ scope: MonitorDataScope, before cutoff: Date? = nil) throws -> MonitorDataSummary {
        if let cutoff { try MonitorBackup.checkDate(cutoff, "清理截止时间") }
        return try transaction(write: true) {
            let table = scope.rawValue
            var statement: OpaquePointer?
            let sql = "DELETE FROM \(table)" + (cutoff == nil ? "" : " WHERE t < ?")
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw error() }
            defer { sqlite3_finalize(statement) }
            if let cutoff { sqlite3_bind_double(statement, 1, cutoff.timeIntervalSince1970) }
            guard sqlite3_step(statement) == SQLITE_DONE else { throw error() }
            let deleted = Int(sqlite3_changes(db))
            return MonitorDataSummary(sampleCount: scope == .history ? deleted : 0,
                                      eventCount: scope == .events ? deleted : 0,
                                      sessionCount: scope == .sessions ? deleted : 0)
        }
    }

}

final class EventDetector {
    private var since: [String: Date] = [:]
    private var last: [String: Date] = [:]
    private var swapBaseline: MetricsSample?
    private var previousDate: Date?
    func evaluate(_ sample: MetricsSample) -> [MonitorEvent] {
        if let previousDate, sample.timestamp.timeIntervalSince(previousDate) > 15 { reset() }
        previousDate = sample.timestamp
        var result: [MonitorEvent] = []
        func check(_ key: String, active: Bool, delay: Double, title: String, detail: String, severity: String = "提醒") {
            guard active else { since[key] = nil; return }
            if since[key] == nil { since[key] = sample.timestamp }
            guard sample.timestamp.timeIntervalSince(since[key]!) >= delay,
                  sample.timestamp.timeIntervalSince(last[key] ?? .distantPast) >= 600 else { return }
            last[key] = sample.timestamp
            result.append(MonitorEvent(date: sample.timestamp, title: title, detail: detail, severity: severity, kind: key))
        }
        let top = sample.processes.max { $0.cpuPercent < $1.cpuPercent }
        let processDetail = top.map { "此时 \($0.name) 使用全机 CPU 的 \(Format.percent($0.cpuPercent))。这是同一时段的观测，不代表已确定卡顿原因。" } ?? "可在回看中查看同一时段的指标。"
        check("cpu", active: (sample.cpuPercent ?? 0) >= 85, delay: 30, title: "CPU 持续繁忙", detail: "全机 CPU 连续 30 秒超过 85%。" + processDetail)
        check("memory", active: ["偏高", "紧张", "警告", "严重"].contains(sample.memoryPressure), delay: 20, title: "内存压力升高", detail: "内存压力已持续 20 秒偏高。当前压缩内存 \(Format.bytes(sample.memoryCompressed))，Swap \(Format.bytes(sample.swapUsed))。", severity: "关注")
        check("disk", active: sample.diskTotal > 0 && sample.diskFree < min(10 * 1073741824, sample.diskTotal * 0.05), delay: 0, title: "磁盘空间不足", detail: "启动磁盘剩余 \(Format.bytes(sample.diskFree))。建议检查不再需要的大文件。", severity: "关注")
        check("thermal", active: ["严重", "危急"].contains(sample.thermalState), delay: 20, title: "系统散热压力升高", detail: "系统报告散热状态为“\(sample.thermalState)”，持续超过 20 秒。可检查正在运行的高负载任务。", severity: "关注")
        if let baseline = swapBaseline, sample.timestamp.timeIntervalSince(baseline.timestamp) >= 60 {
            check("swap", active: sample.swapUsed - baseline.swapUsed > 536870912, delay: 0, title: "Swap 快速增长", detail: "过去约一分钟 Swap 增加 \(Format.bytes(sample.swapUsed - baseline.swapUsed))。结合内存压力和应用排行判断是否影响当前工作。")
            swapBaseline = sample
        } else if swapBaseline == nil { swapBaseline = sample }
        return result
    }
    func reset() { since.removeAll(); swapBaseline = nil; previousDate = nil }
}

struct MonitorDataSummary: Equatable {
    var sampleCount: Int
    var eventCount: Int
    var sessionCount: Int
    var totalRecords: Int { sampleCount + eventCount + sessionCount }
}

enum MonitorDataScope: String, CaseIterable {
    case history = "samples"
    case events
    case sessions
}

enum MonitorBackupError: LocalizedError {
    case invalid(String)
    case unsupportedSchema(Int)
    case tooLarge
    case integrity
    var errorDescription: String? {
        switch self {
        case .invalid(let message): return "完整资料校验失败：\(message)"
        case .unsupportedSchema(let version): return "此备份使用资料格式 V\(version)，当前应用尚不支持。"
        case .tooLarge: return "无法处理超过 256 MB 的备份文件；原数据保持不变。"
        case .integrity: return "备份 SHA-256 校验不符，文件可能损坏或已被修改。"
        }
    }
}

/// Dates use JSONEncoder's native Date representation: seconds since 2001-01-01 UTC.
/// This preserves the Double timestamp exactly, rather than rounding sample IDs to whole seconds.
/// SHA-256 detects accidental modifications; it is an integrity checksum, not a trusted signature.
struct MonitorBackup: Codable {
    static let maximumFileBytes = 256 * 1_048_576
    var format = "com.gaoseries.GaoJiLing.backup"
    var schemaVersion = 1
    var dateEncoding = "secondsSince2001-01-01T00:00:00Z"
    var appVersion: String
    var exportedAt: Date
    var samples: [MetricsSample]
    var events: [MonitorEvent]
    var sessions: [MonitorSession]
    var settings: AppSettings?
    var auxiliaryPreferences: [String: String]?
    var sha256 = ""

    var summary: MonitorDataSummary {
        MonitorDataSummary(sampleCount: samples.count, eventCount: events.count, sessionCount: sessions.count)
    }

    fileprivate static func jsonEncoder(pretty: Bool = false) -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = pretty ? [.sortedKeys, .withoutEscapingSlashes, .prettyPrinted] : [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    private func contentDigest() throws -> String {
        var content = self
        content.sha256 = ""
        return SHA256.hash(data: try Self.jsonEncoder().encode(content)).map { String(format: "%02x", $0) }.joined()
    }

    fileprivate mutating func seal() throws { sha256 = try contentDigest() }

    fileprivate static func checkDate(_ date: Date, _ field: String) throws {
        let seconds = date.timeIntervalSince1970
        guard seconds.isFinite, (-2_208_988_800...32_503_680_000).contains(seconds) else {
            throw MonitorBackupError.invalid("\(field)不在支持的日期范围（1900–3000 年）。")
        }
    }

    fileprivate func validate() throws {
        guard format == "com.gaoseries.GaoJiLing.backup" else { throw MonitorBackupError.invalid("这不是搞机灵的完整资料。") }
        guard schemaVersion == 1 else { throw MonitorBackupError.unsupportedSchema(schemaVersion) }
        guard dateEncoding == "secondsSince2001-01-01T00:00:00Z" else { throw MonitorBackupError.invalid("日期编码不受支持。") }
        guard appVersion.range(of: "^[0-9]{1,6}\\.[0-9]{2}$", options: .regularExpression) != nil else { throw MonitorBackupError.invalid("应用版本号无效。") }
        try Self.checkDate(exportedAt, "导出时间")
        guard samples.count <= 500_000, events.count <= 100_000, sessions.count <= 100_000 else {
            throw MonitorBackupError.invalid("记录数量超出完整资料的支持范围。")
        }
        func text(_ value: String, _ limit: Int, _ field: String, allowEmpty: Bool = true) throws {
            guard value.utf8.count <= limit, (allowEmpty || !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty), !value.contains("\0") else { throw MonitorBackupError.invalid("\(field)为空、过长或包含无效字符。") }
        }
        func number(_ value: Double, _ field: String, range: ClosedRange<Double> = 0...Double.greatestFiniteMagnitude) throws {
            guard value.isFinite, range.contains(value) else { throw MonitorBackupError.invalid("\(field)不是有效数值。") }
        }
        func optional(_ value: Double?, _ field: String, range: ClosedRange<Double> = 0...Double.greatestFiniteMagnitude) throws {
            if let value { try number(value, field, range: range) }
        }
        if let settings {
            guard ["left", "right"].contains(settings.edge), ["system", "light", "dark"].contains(settings.appearance), ["g", "m"].contains(settings.hotkeyChoice), (1...30).contains(settings.retentionDays) else { throw MonitorBackupError.invalid("设置选项无效。") }
            try number(settings.edgeDelay, "边缘延迟", range: 0.2...1.5)
            try number(settings.sampleInterval, "采样间隔", range: 1...10)
        }
        if let auxiliaryPreferences {
            guard auxiliaryPreferences.count <= 64 else { throw MonitorBackupError.invalid("附加偏好设置数量异常。") }
            for (key, value) in auxiliaryPreferences { try text(key, 256, "附加偏好名称", allowEmpty: false); try text(value, 16_384, "附加偏好值") }
        }
        var sampleIDs = Set<Double>()
        for sample in samples {
            try Self.checkDate(sample.timestamp, "采样时间")
            guard sampleIDs.insert(sample.timestamp.timeIntervalSince1970).inserted else { throw MonitorBackupError.invalid("存在重复的采样时间。") }
            try optional(sample.cpuPercent, "CPU 百分比", range: 0...100)
            try optional(sample.gpuPercent, "GPU 百分比", range: 0...100)
            try optional(sample.batteryPercent, "电量", range: 0...100)
            try optional(sample.batteryHealth, "电池健康", range: 0...100)
            try optional(sample.cpuTemperature, "CPU 温度", range: -100...300)
            try optional(sample.cpuPower, "CPU 功率"); try optional(sample.gpuPower, "GPU 功率")
            try optional(sample.fanRPM, "风扇转速")
            for value in [sample.memoryUsed, sample.memoryTotal, sample.memoryCompressed, sample.swapUsed, sample.diskFree, sample.diskTotal, sample.uptime] { try number(value, "系统计量") }
            for value in [sample.networkDown, sample.networkUp, sample.diskRead, sample.diskWrite] { try optional(value, "传输速率") }
            guard sample.processCount >= 0, sample.processCount <= 1_000_000, (sample.batteryCycles ?? 0) >= 0, sample.corePercents.count <= 1024, sample.processes.count <= 4096,
                  sample.memoryUsed <= sample.memoryTotal, sample.diskFree <= sample.diskTotal else { throw MonitorBackupError.invalid("系统计量的数量或容量不一致。") }
            try text(sample.memoryPressure, 64, "内存压力"); try text(sample.thermalState, 64, "散热状态")
            for value in sample.corePercents { try number(value, "每核 CPU", range: 0...100) }
            var processNames = Set<String>()
            for process in sample.processes {
                try text(process.name, 4096, "应用名称", allowEmpty: false)
                guard processNames.insert(process.name).inserted, process.pids.count <= 32_768, process.pids.allSatisfy({ $0 >= 0 }) else { throw MonitorBackupError.invalid("应用排行包含重复名称或无效进程编号。") }
                if let path = process.path { try text(path, 16_384, "应用路径") }
                try number(process.cpuPercent, "应用 CPU", range: 0...100); try number(process.memoryBytes, "应用内存")
            }
        }
        var eventIDs = Set<UUID>()
        for event in events {
            guard eventIDs.insert(event.id).inserted else { throw MonitorBackupError.invalid("存在重复的事件编号。") }
            try Self.checkDate(event.date, "事件时间")
            try text(event.title, 4096, "事件标题", allowEmpty: false); try text(event.detail, 65_536, "事件详情")
            try text(event.severity, 64, "事件级别", allowEmpty: false); try text(event.kind, 128, "事件类型", allowEmpty: false)
        }
        var sessionIDs = Set<UUID>()
        for session in sessions {
            guard sessionIDs.insert(session.id).inserted else { throw MonitorBackupError.invalid("存在重复的任务编号。") }
            try text(session.name, 4096, "任务名称", allowEmpty: false)
            try Self.checkDate(session.start, "任务开始时间")
            if let end = session.end { try Self.checkDate(end, "任务结束时间"); guard end >= session.start else { throw MonitorBackupError.invalid("任务结束时间早于开始时间。") } }
            if let observed = session.lastObserved { try Self.checkDate(observed, "任务观测时间"); guard observed >= session.start else { throw MonitorBackupError.invalid("任务观测时间早于开始时间。") } }
            try number(session.peakCPU, "任务 CPU 峰值", range: 0...100)
            try number(session.peakMemory, "任务内存峰值")
            try optional(session.peakTemperature, "任务温度峰值", range: -100...300)
            try number(session.cpuTotal, "任务 CPU 累计")
            guard session.sampleCount >= 0, session.cpuTotal <= Double(session.sampleCount) * 100 + 0.0001 else { throw MonitorBackupError.invalid("任务采样计数与累计数值不一致。") }
        }
        guard sha256.count == 64, sha256 == (try contentDigest()) else { throw MonitorBackupError.integrity }
    }
}
