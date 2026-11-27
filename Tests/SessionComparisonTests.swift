import Foundation
import SQLite3

@main struct SessionComparisonTests {
    private static let time = Date(timeIntervalSince1970: 1_760_000_000)

    private static func sample(_ seconds: TimeInterval, cpu: Double? = nil, memory: Double? = nil,
                               processCPU: Double = 8) -> MetricsSample {
        let date = time.addingTimeInterval(seconds)
        return MetricsSample(timestamp: date, cpuPercent: cpu, memoryUsed: memory ?? 0,
                             memoryTotal: memory == nil ? 0 : 1024, processes: [
            ProcessMetric(name: "原生会话进程", cpuPercent: processCPU, memoryBytes: 128, observedAt: date, cpuAvailable: true),
            ProcessMetric(name: "缓存进程", cpuPercent: 99, memoryBytes: 128, observedAt: date.addingTimeInterval(-1), cpuAvailable: true),
            ProcessMetric(name: "无 CPU 基线", cpuPercent: 0, memoryBytes: 64, observedAt: date, cpuAvailable: false),
        ])
    }

    private static func requireFailure(_ operation: () throws -> Void) {
        do { try operation() } catch { return }
        fatalError("Expected the operation to fail")
    }

    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let database = try MonitorDatabase(directory: root.appendingPathComponent("current"))
        let start = time.addingTimeInterval(10)
        let end = time.addingTimeInterval(50)
        let current = MonitorSession(name: "原生有明细", start: start, end: end, peakCPU: 92, peakMemory: 200,
                                     sampleCount: 4, cpuTotal: 282, lastObserved: time.addingTimeInterval(46), interrupted: false)
        var measured = SessionComparisonDetails()
        assert(measured.observe(sample(9, cpu: 100, memory: 600), start: start, processBaseline: time, processFloor: start) == nil)
        measured.observe(sample(12, cpu: 92, memory: 200, processCPU: 80), start: start, processBaseline: time, processFloor: start)
        measured.observe(sample(19, cpu: 55, memory: 100, processCPU: 18), start: start, processBaseline: time.addingTimeInterval(12), processFloor: start)
        measured.observe(sample(26, cpu: 70), start: start, processBaseline: nil, processFloor: start)
        measured.observe(sample(46, cpu: 65, memory: 180, processCPU: 88), start: start,
                         processBaseline: time.addingTimeInterval(19), processFloor: time.addingTimeInterval(41))
        assert(measured.observe(sample(46, cpu: 100), start: start, processBaseline: time, processFloor: start) == nil)
        try database.saveCompleted(current, comparison: measured)

        let legacyStart = time.addingTimeInterval(-100)
        let legacy = MonitorSession(name: "旧任务", start: legacyStart, end: time,
                                    lastObserved: time.addingTimeInterval(-20), interrupted: true)
        try database.save(legacy)
        for seconds in [-110.0, -95, -40, -10, 1] {
            try database.append(sample(seconds, cpu: 42, memory: 50))
        }
        let runs = try database.compareSessions([current.id, legacy.id])
        assert(runs.map(\.session.id) == [current.id, legacy.id])
        let run = runs[0], old = runs[1]
        assert(run.duration == 40 && run.peakCPU == 92 && run.averageCPU == 70.5 && run.peakMemory == 200)
        assert(run.sampleCount == 4 && run.sampleStart == time.addingTimeInterval(12) && run.sampleEnd == current.lastObserved)
        assert(run.trendSource == .session && run.trend.map(\.elapsed) == [9, 16, 36])
        assert(run.processSnapshot?.timestamp == time.addingTimeInterval(19))
        assert(run.processSnapshot?.systemCPU == 55 && run.processSnapshot?.rows.map(\.name) == ["原生会话进程"])
        assert(run.processSnapshot?.rows.first?.cpu == 18)
        assert(old.trendSource == .history && old.trend.map(\.elapsed) == [5, 60] && old.sampleCount == nil)
        assert(old.peakMemory == nil && old.averageCPU == nil && old.peakCPU == nil && old.processSnapshot == nil)
        assert(old.session.interrupted == true && old.duration == 100)
        requireFailure { _ = try database.compareSessions([current.id, current.id]) }
        requireFailure { _ = try database.compareSessions([current.id, UUID()]) }
        print("PASS: task metrics, same-session process baseline, cache/paused exclusion and legacy scope")

        let file = root.appendingPathComponent("archive.json")
        try database.exportBackup(to: file, appVersion: "1.16", auxiliaryPreferences: ["GaoJiLing.Windows.SessionCompare.fixture": "opaque"])
        let backup = try MonitorDatabase.inspectBackup(at: file)
        assert(backup.schemaVersion == 1)
        assert(backup.auxiliaryPreferences?[SessionComparisonDetails.backupPrefix + current.id.uuidString] != nil)
        let restored = try MonitorDatabase(directory: root.appendingPathComponent("restored"))
        try restored.restoreBackup(backup)
        let restoredRun = try restored.compareSessions([legacy.id, current.id])[1]
        assert(restoredRun.processSnapshot == run.processSnapshot && restoredRun.trend == run.trend)
        try restored.clearData(.history)
        let remaining = try restored.compareSessions([legacy.id, current.id])
        assert(remaining[0].trend.isEmpty && remaining[1].trend == run.trend)
        try restored.clearData(.sessions, before: legacy.start.addingTimeInterval(1))
        requireFailure { _ = try restored.compareSessions([legacy.id, current.id]) }
        try restored.clearData(.sessions)
        let clearedFile = root.appendingPathComponent("cleared.json")
        try restored.exportBackup(to: clearedFile, appVersion: "1.16")
        let cleared = try MonitorDatabase.inspectBackup(at: clearedFile)
        assert(cleared.sessions.isEmpty && cleared.auxiliaryPreferences == nil)
        print("PASS: V1 integrity round trip, history and task cleanup")

        var long = SessionComparisonDetails()
        for seconds in stride(from: 0.0, to: 7 * 86_400.0, by: 60.0) {
            long.observe(sample(seconds, cpu: 17, memory: 64), start: time, processBaseline: nil, processFloor: time)
        }
        assert(long.sampleCount == 7 * 1440 && long.points.count <= SessionComparisonDetails.pointLimit)
        assert(long.isValid(duration: 7 * 86_400, start: time))
        for index in 0..<SessionComparisonDetails.taskLimit {
            let start = time.addingTimeInterval(Double(1000 + index * 10))
            let session = MonitorSession(name: "有界样本", start: start, end: start.addingTimeInterval(3), interrupted: false)
            try database.saveCompleted(session, comparison: SessionComparisonDetails())
        }
        let afterRetention = try database.compareSessions([legacy.id, current.id])
        assert(afterRetention[1].trendSource == .history && afterRetention[1].processSnapshot == nil)
        let count = try database.dataSummary().sessionCount
        assert(count == SessionComparisonDetails.taskLimit + 2)
        print("PASS: adaptive sample and task-detail capacity without dropping summaries")

        let active = MonitorSession(name: "写入失败", start: time)
        try database.save(active)
        var sql: OpaquePointer?
        let sqlPath = database.directory.appendingPathComponent("monitor.sqlite").path
        guard sqlite3_open(sqlPath, &sql) == SQLITE_OK else { fatalError("Cannot open isolated fixture") }
        defer { sqlite3_close(sql) }
        guard sqlite3_exec(sql, "CREATE TRIGGER reject_detail BEFORE INSERT ON session_comparison BEGIN SELECT RAISE(ABORT, 'fixture'); END;", nil, nil, nil) == SQLITE_OK else {
            fatalError("Cannot add isolated transaction fixture trigger")
        }
        var doomed = active
        doomed.end = time.addingTimeInterval(3)
        requireFailure { try database.saveCompleted(doomed, comparison: SessionComparisonDetails()) }
        let saved = try database.allSessions().first { $0.id == active.id }
        assert(saved != nil && saved?.end == nil)
        print("PASS: failed detail write preserves the active summary atomically")
    }
}
