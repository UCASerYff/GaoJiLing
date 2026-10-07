import Foundation
import SQLite3

private struct TestFailure: Error, CustomStringConvertible {
    let description: String
}

private func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw TestFailure(description: message) }
}

private func expectFailure(_ message: String, _ operation: () throws -> Void) throws {
    do { try operation() }
    catch { return }
    throw TestFailure(description: message)
}

@main struct StoreTests {
    static let origin = Date(timeIntervalSince1970: 1_800_000_000)
    static var passed = 0

    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try run("SQLite sample roundtrip, order, optional values and compaction") { try samples(root) }
        try run("SQLite settings/events/sessions survive reopen and updates") { try records(root) }
        try run("Interrupted task checkpoints retain last observation and legacy compatibility") { try interruptedSession(root) }
        try run("Retention prunes history without deleting task sessions") { try retention(root) }
        try run("Malformed settings payload raises and remains unchanged") { try damagedPreferences(root) }
        try run("Malformed historical payloads raise without replacement") { try damagedRecords(root) }
        try run("Full JSON backup restores all records, settings and auxiliary preferences") { try backupRoundTrip(root) }
        try run("Backup validation rejects corruption, unsupported schemas and invalid records") { try backupValidation(root) }
        try run("Restore SQL failure rolls back every table without losing prior data") { try backupRollback(root) }
        try run("Backup export failure preserves destination and protects database files") { try backupExportFailure(root) }
        try run("Scoped clearing preserves other kinds, settings and cutoff boundaries") { try scopedClearing(root) }
        try run("CPU sustained threshold and 600-second cooldown") { try cpuCooldown() }
        try run("Recovery before threshold resets consecutive duration") { try interruptedCPU() }
        try run("Memory and thermal events have independent duration gates") { try memoryThermal() }
        try run("Disk warning uses both free-space and capacity thresholds") { try diskThreshold() }
        try run("Swap growth requires a minute and more than 512 MiB") { try swapGrowth() }
        try run("Pause reset clears duration but preserves event cooldown") { try detectorReset() }
        try run("Long sampling gaps restart sustained CPU and Swap observations") { try samplingGap() }
        print("PASS: \(passed) storage and detector tests")
    }

    static func run(_ name: String, _ block: () throws -> Void) throws {
        do { try block(); passed += 1; print("PASS: \(name)") }
        catch { fputs("FAIL: \(name): \(error)\n", stderr); throw error }
    }

    static func directory(_ root: URL, _ name: String) -> URL {
        root.appendingPathComponent(name, isDirectory: true)
    }

    static func sample(_ seconds: Double, cpu: Double? = 0) -> MetricsSample {
        var value = MetricsSample()
        value.timestamp = origin.addingTimeInterval(seconds)
        value.cpuPercent = cpu
        value.memoryTotal = 16 * 1_073_741_824
        value.memoryUsed = 7 * 1_073_741_824
        value.diskTotal = 1_000 * 1_073_741_824
        value.diskFree = 200 * 1_073_741_824
        value.memoryPressure = "正常"
        return value
    }

    static func samples(_ root: URL) throws {
        let db = try MonitorDatabase(directory: directory(root, "samples"))
        var first = sample(10, cpu: 42.75)
        first.gpuPercent = nil
        first.networkDown = 4096.5
        first.cpuTemperature = 61.25
        first.corePercents = [12, 24, 36]
        first.processes = (0..<9).map { ProcessMetric(name: "应用 \($0) ' ; \"", cpuPercent: Double($0), memoryBytes: Double($0 * 1_048_576), pids: [Int32($0)], path: "/Applications/Test \($0).app") }
        try db.append(sample(20, cpu: nil))
        try db.append(first)
        try db.append(sample(0, cpu: 10))
        let loaded = try db.history(since: origin.addingTimeInterval(5))
        try expect(loaded.count == 2, "since filter must exclude the older sample")
        try expect(loaded[0].timestamp == first.timestamp && loaded[1].timestamp == origin.addingTimeInterval(20), "history must be chronological")
        try expect(loaded[0].cpuPercent == 42.75 && loaded[0].networkDown == 4096.5 && loaded[0].cpuTemperature == 61.25, "numeric values must retain precision")
        try expect(loaded[0].gpuPercent == nil && loaded[1].cpuPercent == nil, "missing sensor readings must remain nil")
        try expect(loaded[0].corePercents.isEmpty, "long-term history intentionally omits per-core samples")
        try expect(loaded[0].processes == Array(first.processes.reversed().prefix(6)), "history must retain the six largest CPU processes including Unicode and quote characters")
        first.cpuPercent = 99
        try db.append(first)
        let updated = try db.history(since: origin.addingTimeInterval(5))
        try expect(updated.count == 2 && updated[0].cpuPercent == 99, "checkpoint must replace one timestamp without duplicating history")
        let window = try db.history(since: origin.addingTimeInterval(10), until: origin.addingTimeInterval(10))
        try expect(window.count == 1 && window[0].timestamp == first.timestamp, "event-window query must include exact endpoints and exclude later observations")
    }

    static func records(_ root: URL) throws {
        let location = directory(root, "records")
        var custom = AppSettings()
        custom.edge = "left"; custom.edgeDelay = 0.75; custom.sampleInterval = 5
        custom.retentionDays = 30; custom.appearance = "dark"; custom.notificationsEnabled = true
        var session = MonitorSession(name: "本地模型任务 '引用'", start: origin)
        session.peakCPU = 87.5; session.peakMemory = 8_589_934_592
        session.sampleCount = 2; session.cpuTotal = 120
        let first = MonitorEvent(date: origin, title: "开始", detail: "引号 ' \" 与中文", severity: "提醒", kind: "cpu")
        let second = MonitorEvent(date: origin.addingTimeInterval(10), title: "后续", detail: "detail", severity: "关注", kind: "memory")
        do {
            let db = try MonitorDatabase(directory: location)
            try expect(try db.settings() == AppSettings(), "a brand-new database returns default settings")
            try db.save(custom); try db.save(session); try db.save(first); try db.save(second)
            session.end = origin.addingTimeInterval(90); session.peakCPU = 95
            try db.save(session)
        }
        let reopened = try MonitorDatabase(directory: location)
        try expect(try reopened.settings() == custom, "settings must survive database close and reopen")
        let saved = try reopened.sessions()
        try expect(saved.count == 1 && saved[0].id == session.id && saved[0].end == session.end, "session checkpoint and finish must update the same record")
        try expect(saved[0].peakCPU == 95 && saved[0].averageCPU == 60 && saved[0].duration == 90, "task summary values must survive reopen")
        let events = try reopened.events()
        try expect(events.map(\.id) == [second.id, first.id] && events[1].detail == first.detail, "events must retain text and be newest first")
    }

    static func retention(_ root: URL) throws {
        let db = try MonitorDatabase(directory: directory(root, "retention"))
        let old = -2.0 * 86400
        for offset in [-8.0 * 86400, old + 1, old + 2, old + 61, -3599, -3598] { try db.append(sample(offset)) }
        let ancientSession = MonitorSession(name: "应永久保留的任务", start: origin.addingTimeInterval(-90 * 86400), end: origin.addingTimeInterval(-90 * 86400 + 60))
        let oldEvent = MonitorEvent(date: origin.addingTimeInterval(-8 * 86400), title: "旧事件", detail: "", severity: "提醒", kind: "cpu")
        let freshEvent = MonitorEvent(date: origin.addingTimeInterval(-60), title: "新事件", detail: "", severity: "提醒", kind: "cpu")
        try db.save(ancientSession); try db.save(oldEvent); try db.save(freshEvent)
        try db.prune(days: 7, now: origin)
        let loaded = try db.history(since: origin.addingTimeInterval(-100 * 86400))
        try expect(loaded.map { $0.timestamp.timeIntervalSince(origin) } == [old + 1, old + 61, -3599, -3598], "only expired samples and excess older-than-one-day minute points may be removed")
        try expect(try db.events().map(\.id) == [freshEvent.id], "expired events should be removed")
        try expect(try db.sessions().map(\.id) == [ancientSession.id], "retention must never delete saved task sessions")
    }

    static func interruptedSession(_ root: URL) throws {
        let location = directory(root, "interrupted-session")
        var task = MonitorSession(name: "三天前的任务", start: origin.addingTimeInterval(-3 * 86400))
        task.lastObserved = task.start.addingTimeInterval(125)
        task.sampleCount = 12; task.cpuTotal = 600; task.interrupted = true
        do {
            let db = try MonitorDatabase(directory: location)
            try db.save(task)
            try db.append(sample(-3 * 86400 + 10))
            try db.append(sample(-3 * 86400 + 125))
        }
        let db = try MonitorDatabase(directory: location)
        let tasks = try db.sessions()
        try expect(tasks.count == 1 && tasks[0].end == nil && tasks[0].lastObserved == task.lastObserved && tasks[0].interrupted == true, "unfinished task must preserve exact last observation beyond a day")
        try expect(try db.lastSample(since: task.start)?.timestamp == task.lastObserved, "recovery lookup must find the last persisted sample outside the 24-hour UI window")
        try expect(try db.lastSample(since: origin) == nil, "lookup must not borrow samples older than a task start")
        var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(task)) as! [String: Any]
        legacy.removeValue(forKey: "lastObserved"); legacy.removeValue(forKey: "interrupted")
        let decoded = try JSONDecoder().decode(MonitorSession.self, from: JSONSerialization.data(withJSONObject: legacy))
        try expect(decoded.id == task.id && decoded.lastObserved == nil && decoded.interrupted == nil && decoded.sampleCount == 12, "legacy tasks without recovery fields must remain readable")
    }

    static func sql(_ location: URL, _ statement: String) throws {
        var handle: OpaquePointer?
        guard sqlite3_open(location.appendingPathComponent("monitor.sqlite").path, &handle) == SQLITE_OK else { throw TestFailure(description: "test SQL open failed") }
        defer { sqlite3_close(handle) }
        guard sqlite3_exec(handle, statement, nil, nil, nil) == SQLITE_OK else { throw TestFailure(description: "test SQL execution failed: \(String(cString: sqlite3_errmsg(handle)))") }
    }

    static func scalar(_ location: URL, _ query: String) throws -> String {
        var handle: OpaquePointer?
        guard sqlite3_open(location.appendingPathComponent("monitor.sqlite").path, &handle) == SQLITE_OK else { throw TestFailure(description: "test SQL open failed") }
        defer { sqlite3_close(handle) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, query, -1, &statement, nil) == SQLITE_OK else { throw TestFailure(description: "test SQL query failed") }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) else { throw TestFailure(description: "test SQL returned no scalar") }
        return String(cString: text)
    }

    static func damagedPreferences(_ root: URL) throws {
        let location = directory(root, "damaged-preferences")
        let db = try MonitorDatabase(directory: location)
        try db.save(AppSettings())
        try sql(location, "UPDATE preferences SET payload='{broken settings payload' WHERE id=1")
        try expectFailure("malformed settings must not become defaults") { _ = try db.settings() }
        try db.append(sample(0))
        try expect(try scalar(location, "SELECT payload FROM preferences WHERE id=1") == "{broken settings payload", "a failed read and unrelated writes must preserve the original bytes")
        let reopened = try MonitorDatabase(directory: location)
        try expectFailure("reopening a malformed settings database must not replace the payload") { _ = try reopened.settings() }
        try expect(try scalar(location, "SELECT payload FROM preferences WHERE id=1") == "{broken settings payload", "reopen must keep malformed source data")
    }

    static func damagedRecords(_ root: URL) throws {
        let location = directory(root, "damaged-records")
        let db = try MonitorDatabase(directory: location)
        try db.append(sample(0)); try db.append(sample(10))
        try db.save(MonitorEvent(date: origin, title: "test", detail: "", severity: "提醒", kind: "cpu"))
        try db.save(MonitorSession(name: "test", start: origin))
        try sql(location, "UPDATE samples SET payload='{damaged sample' WHERE t=1800000000; UPDATE events SET payload='{damaged event'; UPDATE sessions SET payload='{damaged session';")
        try expectFailure("corrupt samples must raise instead of returning empty history") { _ = try db.history(since: .distantPast) }
        try expectFailure("corrupt events must raise instead of returning an empty list") { _ = try db.events() }
        try expectFailure("corrupt sessions must raise instead of returning an empty list") { _ = try db.sessions() }
        try expect(try scalar(location, "SELECT COUNT(*) FROM samples") == "2", "failed history read must retain healthy and malformed rows")
        try expect(try scalar(location, "SELECT payload FROM sessions LIMIT 1") == "{damaged session", "failed session read must preserve payload bytes")
    }

    static func backupRoundTrip(_ root: URL) throws {
        let location = directory(root, "backup-source")
        let source = try MonitorDatabase(directory: location)
        var setting = AppSettings(); setting.edge = "left"; setting.hotkeyChoice = "m"; setting.appearance = "dark"
        try source.save(setting)
        var value = sample(0.123456789, cpu: 72.125)
        value.cpuTemperature = 45.25; value.gpuPower = nil
        value.processes = [ProcessMetric(name: "应用 \"引号\" 🌟", cpuPercent: 20.125, memoryBytes: 123456, pids: [42, 43], path: "/Applications/中文.app")]
        try source.append(value); try source.append(sample(10.987654321, cpu: nil))
        for index in 0..<305 {
            try source.save(MonitorEvent(date: origin.addingTimeInterval(Double(index)), title: "事件 \(index)", detail: "完整详情；不可只保留300条", severity: "提醒", kind: "cpu"))
            var task = MonitorSession(name: "任务 \(index)", start: origin.addingTimeInterval(Double(index)), end: origin.addingTimeInterval(Double(index + 1)))
            task.peakCPU = 30; task.sampleCount = 2; task.cpuTotal = 40; task.lastObserved = task.end
            try source.save(task)
        }
        let path = root.appendingPathComponent("full-backup.json")
        let preferences = ["edgeHandleY": "0.314159", "edgeHandleDisplay": "main"]
        let summary = try source.exportBackup(to: path, appVersion: "1.01", auxiliaryPreferences: preferences)
        try expect(summary == MonitorDataSummary(sampleCount: 2, eventCount: 305, sessionCount: 305), "backup must not inherit the UI 300-record cap")
        try expect(try source.allEvents().count == 305 && source.allSessions().count == 305, "CSV all-record readers must be unbounded")
        let preview = try MonitorDatabase.inspectBackup(at: path)
        try expect(preview.appVersion == "1.01" && preview.schemaVersion == 1 && preview.summary == summary, "backup metadata and counts survive JSON")
        try expect(preview.auxiliaryPreferences == preferences && preview.settings == setting, "backup includes app settings and caller-provided UI preferences")
        try expect(preview.samples[0].timestamp == value.timestamp && preview.samples[0].processes == value.processes && preview.samples[0].gpuPower == nil, "fractional sample IDs, Unicode and optional readings must remain exact")
        let restoredLocation = directory(root, "backup-restored")
        do {
            let target = try MonitorDatabase(directory: restoredLocation)
            try target.append(sample(999)); try target.save(AppSettings())
            try expect(try target.restoreBackup(preview) == summary, "restore returns imported counts")
        }
        let reopened = try MonitorDatabase(directory: restoredLocation)
        try expect(try reopened.dataSummary() == summary && reopened.settings() == setting, "all tables and settings survive restore and reopen")
        let secondPath = root.appendingPathComponent("restored-backup.json")
        try reopened.exportBackup(to: secondPath, appVersion: "1.01", auxiliaryPreferences: preferences)
        let second = try MonitorDatabase.inspectBackup(at: secondPath)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try expect(try encoder.encode(second.samples) == encoder.encode(preview.samples), "restored sample payloads must not be compacted again")
        try expect(try encoder.encode(second.events) == encoder.encode(preview.events) && encoder.encode(second.sessions) == encoder.encode(preview.sessions), "all event and session payloads must be lossless")
        let empty = try MonitorDatabase(directory: directory(root, "backup-empty"))
        let emptyPath = root.appendingPathComponent("empty-backup.json")
        try empty.exportBackup(to: emptyPath, appVersion: "1.01")
        let emptyPreview = try MonitorDatabase.inspectBackup(at: emptyPath)
        try expect(emptyPreview.settings == nil && emptyPreview.auxiliaryPreferences == nil, "absent preferences remain absent; optional auxiliary field is compatible")
        try reopened.restoreBackup(emptyPreview)
        try expect(try reopened.dataSummary().totalRecords == 0 && reopened.settings() == AppSettings(), "explicit empty backup restores a fresh database including default settings")
    }

    static func backupValidation(_ root: URL) throws {
        let db = try MonitorDatabase(directory: directory(root, "backup-validation"))
        try db.append(sample(0, cpu: 50))
        try db.save(MonitorEvent(date: origin, title: "原事件", detail: "保留", severity: "提醒", kind: "cpu"))
        let path = root.appendingPathComponent("validated-backup.json")
        try db.exportBackup(to: path, appVersion: "1.01")
        let valid = try MonitorDatabase.inspectBackup(at: path)
        let before = try db.dataSummary()
        func reject(_ mutation: (inout MonitorBackup) -> Void, _ message: String) throws {
            var changed = valid; mutation(&changed)
            try expectFailure(message) { _ = try db.restoreBackup(changed) }
            try expect(try db.dataSummary() == before && db.history(since: .distantPast)[0].cpuPercent == 50, "rejected backup must never clear existing tables")
        }
        try reject({ $0.schemaVersion = 99 }, "new schema must be rejected")
        try reject({ $0.format = "different-app" }, "another app archive must be rejected")
        try reject({ $0.samples.append($0.samples[0]) }, "duplicate sample keys must be rejected")
        try reject({ $0.events.append($0.events[0]) }, "duplicate event IDs must be rejected")
        try reject({ $0.samples[0].cpuPercent = -1 }, "out-of-range readings must be rejected")
        try reject({ $0.samples[0].networkDown = .infinity }, "non-finite readings must be rejected")
        try reject({ $0.samples[0].cpuPercent = 49 }, "valid-looking modified content must fail SHA-256")
        try reject({ var settings = AppSettings(); settings.sampleInterval = 0; $0.settings = settings }, "invalid settings must be rejected")
        let truncated = root.appendingPathComponent("truncated.json")
        try Data("{\"format\":\"com.gaoseries.GaoJiLing.backup\"".utf8).write(to: truncated)
        try expectFailure("truncated JSON must fail before restoration") { _ = try MonitorDatabase.inspectBackup(at: truncated) }
        let oversized = root.appendingPathComponent("oversized.json")
        FileManager.default.createFile(atPath: oversized.path, contents: nil)
        let handle = try FileHandle(forWritingTo: oversized)
        try handle.truncate(atOffset: UInt64(MonitorBackup.maximumFileBytes + 1)); try handle.close()
        try expectFailure("oversized file must be rejected before loading into memory") { _ = try MonitorDatabase.inspectBackup(at: oversized) }
    }

    static func backupRollback(_ root: URL) throws {
        let source = try MonitorDatabase(directory: directory(root, "rollback-source"))
        let event = MonitorEvent(date: origin, title: "触发回滚", detail: "", severity: "提醒", kind: "cpu")
        try source.append(sample(20)); try source.save(event)
        try source.save(MonitorSession(name: "新任务", start: origin))
        var incoming = AppSettings(); incoming.appearance = "dark"; try source.save(incoming)
        let path = root.appendingPathComponent("rollback-backup.json")
        try source.exportBackup(to: path, appVersion: "1.01")
        let archive = try MonitorDatabase.inspectBackup(at: path)
        let location = directory(root, "rollback-target")
        let target = try MonitorDatabase(directory: location)
        try target.append(sample(0, cpu: 33)); try target.append(sample(5))
        let originalEvent = MonitorEvent(date: origin, title: "原事件", detail: "不可丢失", severity: "关注", kind: "disk")
        let originalTask = MonitorSession(name: "原任务", start: origin.addingTimeInterval(-30), end: origin)
        var originalSettings = AppSettings(); originalSettings.edge = "left"
        try target.save(originalEvent); try target.save(originalTask); try target.save(originalSettings)
        let oldSummary = try target.dataSummary()
        try sql(location, "CREATE TRIGGER reject_restore BEFORE INSERT ON events WHEN NEW.id='\(event.id.uuidString)' BEGIN SELECT RAISE(ABORT, 'forced restore failure'); END;")
        try expectFailure("mid-transaction insertion failure must throw") { _ = try target.restoreBackup(archive) }
        try expect(try target.dataSummary() == oldSummary, "rollback must restore counts in every table")
        try expect(try target.history(since: .distantPast).map(\.cpuPercent) == [33, 0], "rollback must restore deleted samples after partial new insertion")
        try expect(try target.allEvents().map(\.id) == [originalEvent.id] && target.allSessions().map(\.id) == [originalTask.id] && target.settings() == originalSettings, "rollback must recover original IDs and settings")
        try sql(location, "DROP TRIGGER reject_restore")
        try target.restoreBackup(archive)
        try expect(try target.dataSummary() == archive.summary && target.settings() == incoming, "connection remains usable after rollback")
    }

    static func backupExportFailure(_ root: URL) throws {
        let location = directory(root, "export-failure")
        let db = try MonitorDatabase(directory: location)
        try db.append(sample(0))
        let path = root.appendingPathComponent("existing-backup.json")
        let original = Data("previous backup bytes must survive".utf8)
        try original.write(to: path)
        try sql(location, "UPDATE samples SET payload='{broken source payload'")
        try expectFailure("corrupt source must fail instead of silently skipping rows") { _ = try db.exportBackup(to: path, appVersion: "1.01") }
        try expect(try Data(contentsOf: path) == original, "failed export must preserve preexisting destination bytes")
        try db.append(sample(0))
        for name in ["monitor.sqlite", "monitor.sqlite-wal", "monitor.sqlite-shm", "monitor.sqlite-journal", "MONITOR.SQLITE"] {
            let protected = location.appendingPathComponent(name)
            try expectFailure("every export format must reject database and SQLite sidecars") { try db.validateExportDestination(protected) }
        }
        try expectFailure("data directory itself is protected regardless of URL directory hint") { try db.validateExportDestination(URL(fileURLWithPath: location.path, isDirectory: false)) }
        for (index, name) in ["monitor.sqlite", "monitor.sqlite-wal", "monitor.sqlite-shm"].enumerated() {
            let alias = root.appendingPathComponent("protected-alias-\(index).csv")
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: location.appendingPathComponent(name))
            try expectFailure("CSV-named symbolic link must not bypass destination protection") { try db.validateExportDestination(alias) }
        }
        let directoryAlias = root.appendingPathComponent("data-directory-alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: directoryAlias, withDestinationURL: location)
        try expectFailure("symbolic linked parent must not bypass sidecar protection") { try db.validateExportDestination(directoryAlias.appendingPathComponent("monitor.sqlite-wal")) }
        try db.validateExportDestination(root.appendingPathComponent("normal-export.csv"))
        try db.validateExportDestination(location.appendingPathComponent("user-backup.json"))
        try expectFailure("export must not replace its own SQLite database") { _ = try db.exportBackup(to: location.appendingPathComponent("monitor.sqlite"), appVersion: "1.01") }
        try expect(try db.dataSummary().sampleCount == 1, "protected database must remain usable")
        try db.exportBackup(to: path, appVersion: "1.01")
        try expect(try MonitorDatabase.inspectBackup(at: path).summary.sampleCount == 1, "successful export replaces an old file only after verification")
        let residual = try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix(".gaojiling-backup-") }
        try expect(residual.isEmpty, "export staging files must be cleaned")
    }

    static func scopedClearing(_ root: URL) throws {
        let db = try MonitorDatabase(directory: directory(root, "scoped-clearing"))
        var settings = AppSettings(); settings.appearance = "dark"; try db.save(settings)
        for offset in [-10.0, 0, 10] {
            try db.append(sample(offset))
            try db.save(MonitorEvent(date: origin.addingTimeInterval(offset), title: "事件", detail: "", severity: "提醒", kind: "cpu"))
            try db.save(MonitorSession(name: "任务", start: origin.addingTimeInterval(offset)))
        }
        try expect(try db.clearData(.history, before: origin) == MonitorDataSummary(sampleCount: 1, eventCount: 0, sessionCount: 0), "history cutoff returns only deleted samples")
        try expect(try db.history(since: .distantPast).map(\.timestamp) == [origin, origin.addingTimeInterval(10)], "cutoff equality must be retained")
        try expect(try db.dataSummary() == MonitorDataSummary(sampleCount: 2, eventCount: 3, sessionCount: 3), "clearing history cannot erase events or tasks")
        try expect(try db.clearData(.events).eventCount == 3 && db.allSessions().count == 3, "clearing events preserves task records")
        try expect(try db.clearData(.sessions, before: origin).sessionCount == 1 && db.allSessions().count == 2, "task deletion requires explicit task scope")
        try expect(try db.settings() == settings, "all cleanup scopes preserve settings")
        try expectFailure("invalid cutoff must not interpolate invalid SQL or delete data") { _ = try db.clearData(.history, before: Date(timeIntervalSince1970: .nan)) }
        try expect(try db.dataSummary().sampleCount == 2, "invalid cutoff preserves prior history")
    }

    static func kinds(_ detector: EventDetector, _ sample: MetricsSample) -> Set<String> {
        Set(detector.evaluate(sample).map(\.kind))
    }

    static func cpuCooldown() throws {
        let detector = EventDetector()
        try expect(kinds(detector, sample(0, cpu: 85)).isEmpty, "CPU at threshold begins observation")
        for second in 1..<30 { try expect(kinds(detector, sample(Double(second), cpu: 85)).isEmpty, "CPU must wait all 30 seconds") }
        try expect(kinds(detector, sample(30, cpu: 85)) == ["cpu"], "CPU event must fire at 30 seconds")
        for second in 31..<630 { try expect(kinds(detector, sample(Double(second), cpu: 99)).isEmpty, "CPU event must respect the 600-second cooldown") }
        try expect(kinds(detector, sample(630, cpu: 90)) == ["cpu"], "sustained CPU may fire again after exactly 600 seconds")
    }

    static func interruptedCPU() throws {
        let detector = EventDetector()
        for second in 0..<30 { _ = detector.evaluate(sample(Double(second), cpu: 90)) }
        try expect(kinds(detector, sample(30, cpu: 84.9)).isEmpty, "recovered CPU must not trigger")
        for second in 31..<61 { try expect(kinds(detector, sample(Double(second), cpu: 90)).isEmpty, "recovery resets the consecutive duration") }
        try expect(kinds(detector, sample(61, cpu: 90)) == ["cpu"], "a fresh full 30-second interval should trigger")
        let missing = EventDetector()
        _ = missing.evaluate(sample(0, cpu: 90)); _ = missing.evaluate(sample(20, cpu: nil))
        try expect(kinds(missing, sample(30, cpu: 90)).isEmpty, "an unavailable CPU value must interrupt the duration")
    }

    static func memoryThermal() throws {
        let detector = EventDetector()
        for second in 0...20 {
            var value = sample(Double(second), cpu: 90)
            value.memoryPressure = "紧张"; value.thermalState = "严重"
            let observed = kinds(detector, value)
            try expect(observed == (second == 20 ? ["memory", "thermal"] : []), "memory and thermal warnings each require 20 seconds, independently from CPU")
        }
    }

    static func diskThreshold() throws {
        let detector = EventDetector()
        var value = sample(0)
        value.diskTotal = 100 * 1_073_741_824; value.diskFree = 5 * 1_073_741_824
        try expect(kinds(detector, value).isEmpty, "exactly 5% free is not below the threshold")
        value.timestamp = origin.addingTimeInterval(1); value.diskFree -= 1
        try expect(kinds(detector, value) == ["disk"], "less than 5% on a smaller disk should trigger")
        let largeDisk = EventDetector()
        value = sample(0); value.diskFree = 10 * 1_073_741_824
        try expect(kinds(largeDisk, value).isEmpty, "large disks must use the smaller 10 GiB threshold")
        value.timestamp = origin.addingTimeInterval(1); value.diskFree -= 1
        try expect(kinds(largeDisk, value) == ["disk"], "below 10 GiB should trigger on a large disk")
    }

    static func swapGrowth() throws {
        let exact = EventDetector()
        _ = exact.evaluate(sample(0))
        for second in 1...60 {
            var value = sample(Double(second)); value.swapUsed = 536_870_912
            try expect(kinds(exact, value).isEmpty, "exactly 512 MiB is not more than the growth threshold")
        }
        let above = EventDetector()
        _ = above.evaluate(sample(0))
        for second in 1...60 {
            var value = sample(Double(second)); value.swapUsed = 536_870_913
            try expect(kinds(above, value) == (second == 60 ? ["swap"] : []), "swap must wait one full minute and require growth over 512 MiB")
        }
    }

    static func detectorReset() throws {
        let detector = EventDetector()
        for second in 0...30 { _ = detector.evaluate(sample(Double(second), cpu: 90)) }
        detector.reset()
        for second in 31...80 { try expect(kinds(detector, sample(Double(second), cpu: 90)).isEmpty, "reset must not bypass the previous alert cooldown") }
        let pending = EventDetector()
        for second in 0..<30 { _ = pending.evaluate(sample(Double(second), cpu: 90)) }; pending.reset()
        try expect(kinds(pending, sample(30, cpu: 90)).isEmpty, "reset must discard an unfinished sustained observation")
    }

    static func samplingGap() throws {
        let detector = EventDetector()
        for second in stride(from: 0, through: 15, by: 5) { _ = detector.evaluate(sample(Double(second), cpu: 90)) }
        var wake = sample(3600, cpu: 90); wake.swapUsed = 2_147_483_648
        try expect(kinds(detector, wake).isEmpty, "two high values separated by sleep are not continuous CPU load or one-minute Swap growth")
        for second in 3601..<3630 {
            wake.timestamp = origin.addingTimeInterval(Double(second))
            try expect(kinds(detector, wake).isEmpty, "new sustained observation must restart after waking")
        }
        wake.timestamp = origin.addingTimeInterval(3630)
        try expect(kinds(detector, wake) == ["cpu"], "a fresh 30-second interval after waking should trigger normally")
        let boundary = EventDetector()
        _ = boundary.evaluate(sample(0, cpu: 90)); _ = boundary.evaluate(sample(15, cpu: 90))
        try expect(kinds(boundary, sample(30, cpu: 90)) == ["cpu"], "15-second interval is still accepted")
        let tooLong = EventDetector()
        _ = tooLong.evaluate(sample(0, cpu: 90)); _ = tooLong.evaluate(sample(16, cpu: 90))
        try expect(kinds(tooLong, sample(31, cpu: 90)).isEmpty, "an interval above 15 seconds resets the duration")
    }
}
