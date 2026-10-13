import Foundation
import Darwin

@main struct MaintenanceTests {
    struct Failure: Error { var message: String }
    static func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw Failure(message: message) }
    }
    static func main() throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let fresh = MetricReading(value: 25.0, unit: "%", timestamp: now, source: "injected native source")
        let missing = MetricReading<Double>(value: nil, unit: "%", timestamp: now.addingTimeInterval(5), source: "failed new read", availabilityReason: "permission denied")
        let retained = missing.retaining(fresh)
        try require(retained.value == 25 && retained.timestamp == now && retained.source == fresh.source && retained.isStale, "failed readings preserve old value, timestamp and source")
        try require(!retained.isFresh(at: now.addingTimeInterval(5)) && !fresh.isFresh(at: now.addingTimeInterval(16)), "old and failed readings are never fresh")
        try require(missing.retaining(nil).value == nil, "missing sensor never becomes zero")
        var injected = GJLSensors()
        injected.battery_present = 1; injected.battery_percent = 35; injected.battery_ac_power = 0; injected.battery_charging = 0
        injected.battery_health = .nan; injected.battery_cycles = -1; injected.battery_temperature = .nan
        injected.battery_minutes_empty = .nan; injected.battery_minutes_full = .nan
        injected.fan_count = -1; injected.fan_rpm = .nan; injected.gpu_percent = .nan; injected.cpu_temperature = .nan
        injected.cpu_power = .nan; injected.gpu_power = .nan
        var sensorReads = 0
        let sensors = Sensors(read: { raw in raw = injected; sensorReads += 1 })
        var sensorSample = MetricsSample(timestamp: now)
        sensors.apply(to: &sensorSample, uptime: 100)
        try require(sensorSample.batterySnapshot?.percent.value == 35 && sensorSample.cpuTemperature == nil, "native optional mapping preserves availability")
        sensorSample.timestamp = now.addingTimeInterval(2)
        sensors.apply(to: &sensorSample, uptime: 102)
        try require(sensorReads == 1 && sensorSample.batterySnapshot?.percent.timestamp == now, "cached sensor does not acquire a fake current timestamp")
        injected.battery_present = -1; injected.battery_percent = .nan; injected.battery_ac_power = -1; injected.battery_charging = -1
        sensorSample.timestamp = now.addingTimeInterval(7)
        sensors.apply(to: &sensorSample, uptime: 107)
        try require(sensorSample.batterySnapshot?.percent.value == 35 && sensorSample.batterySnapshot?.percent.isStale == true && sensorSample.batterySnapshot?.percent.timestamp == now, "failed native reading retains old value explicitly stale")
        try require(sensorSample.batterySnapshot?.present.isStale == true && sensorSample.batteryPercent == nil, "unknown presence is not absence and legacy scalar stays unavailable")
        injected.battery_present = 0; sensorSample.timestamp = now.addingTimeInterval(14)
        sensors.apply(to: &sensorSample, uptime: 114)
        try require(sensorSample.batterySnapshot?.present.value == false && sensorSample.batterySnapshot?.percent.value == nil, "confirmed battery absence clears retained battery readings")
        let legacy = Data(#"{"name":"Same","cpuPercent":2,"memoryBytes":4096,"pids":[1],"path":"/fixture/a.app"}"#.utf8)
        let decoded = try JSONDecoder().decode(ProcessMetric.self, from: legacy)
        try require(decoded.groupID == nil && decoded.identities == nil && decoded.path == "/fixture/a.app", "V1.09 process data remains decodable")
        var sampleJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(MetricsSample())) as! [String: Any]
        for key in ["readings", "batterySnapshot", "fanDescriptors"] { sampleJSON.removeValue(forKey: key) }
        let oldSample = try JSONDecoder().decode(MetricsSample.self, from: JSONSerialization.data(withJSONObject: sampleJSON))
        try require(oldSample.readings == nil && oldSample.batterySnapshot == nil && oldSample.fanDescriptors == nil, "old metrics history needs no fabricated sensor migration")
        let identity = ProcessIdentity(pid: 120, startTime: 400, uid: 501)
        let first = MetricsCollector.groupKey(path: "/fixture/first.app", bundleID: "org.example.utility", process: identity)
        let second = MetricsCollector.groupKey(path: "/fixture/second.app", bundleID: "org.example.utility", process: identity)
        try require(first != second, "same bundle or display name at different real paths must not merge")
        try require(first != MetricsCollector.groupKey(path: "/fixture/first.app", bundleID: "org.example.utility", process: ProcessIdentity(pid: 121, startTime: 500, uid: 502)), "different users do not merge")
        try require(MetricsCollector.groupKey(path: nil, bundleID: nil, process: identity) != MetricsCollector.groupKey(path: nil, bundleID: nil, process: ProcessIdentity(pid: 120, startTime: 401, uid: 501)), "unknown executable identity cannot collapse reused PIDs")
        print("PASS: stale/source provenance, missing sensors, historical Codable and process aggregation")

        var rule = AppExitRule(bundleID: "org.example.utility", path: "/fixture/Utility.app", name: "Utility")
        rule.enabled = true; rule.minutes = 1; rule.cooldownSeconds = 600
        func observation(_ time: Date) -> AppExitObservation {
            AppExitObservation(identity: identity, bundleID: rule.bundleID, path: rule.path, name: rule.name, observedAt: time,
                               isFrontmost: false, memoryBytes: 2_147_483_648, windowCount: 0, saveState: .clean, idleSeconds: 100)
        }
        var policy = AppExitPolicy()
        for offset in stride(from: 0.0, through: 70, by: 10) { let t = now.addingTimeInterval(offset); policy.observe([observation(t)], now: t) }
        let ready = now.addingTimeInterval(70)
        func decision(_ value: AppExitObservation, enabled: Bool = true, paused: Bool = false) -> AppExitDecision {
            policy.evaluate(rule, observation: value, now: ready, currentUID: 501, enabled: enabled, paused: paused)
        }
        try require(decision(observation(ready)).eligible, "confirmed clean background app becomes eligible after continuous observation")
        try require(!decision(observation(ready), enabled: false).eligible && !decision(observation(ready), paused: true).eligible, "disabled/paused never requests exit")
        var unsafe = observation(ready); unsafe.saveState = .unknown
        try require(!decision(unsafe).eligible, "unknown save state always skipped, including zero windows")
        unsafe.saveState = .edited
        try require(!decision(unsafe).eligible, "edited state skipped")
        unsafe = observation(ready); unsafe.isFrontmost = true
        try require(!decision(unsafe).eligible, "foreground protected")
        unsafe = observation(ready); unsafe.identity.startTime += 1
        try require(!decision(unsafe).eligible, "PID reuse cannot inherit background interval")
        unsafe = observation(ready); unsafe.identity.uid += 1
        try require(!decision(unsafe).eligible, "different UID protected")
        unsafe = observation(ready.addingTimeInterval(-15))
        try require(!decision(unsafe).eligible, "stale observation cannot authorize exit")
        for trigger in AppExitTrigger.allCases {
            var changed = rule; changed.trigger = trigger
            try require(policy.evaluate(changed, observation: observation(ready), now: ready, currentUID: 501, enabled: true, paused: false).eligible, "each supported trigger is eligible only after background/save checks")
            var unavailable = observation(ready)
            switch trigger {
            case .background: unavailable.isFrontmost = true
            case .idle: unavailable.idleSeconds = nil
            case .noWindows: unavailable.windowCount = nil
            case .memory: unavailable.memoryBytes = nil
            }
            try require(!policy.evaluate(changed, observation: unavailable, now: ready, currentUID: 501, enabled: true, paused: false).eligible, "missing trigger evidence cannot become zero/eligible")
        }
        policy.recordAttempt(rule, at: ready)
        try require(!decision(observation(ready)).eligible, "sent, refused or duplicate requests share cooldown")
        var restored = AppExitPolicy()
        restored.restoreCooldowns([AppExitRecord(ruleID: rule.id, date: ready, name: rule.name, outcome: "准备请求", reason: "fixture")])
        for offset in stride(from: 0.0, through: 70, by: 10) { let t = now.addingTimeInterval(offset); restored.observe([observation(t)], now: t) }
        try require(!restored.evaluate(rule, observation: observation(ready), now: ready, currentUID: 501, enabled: true, paused: false).eligible, "durable intent restores cooldown without replaying side effects")
        policy = AppExitPolicy()
        for offset in stride(from: 0.0, through: 70, by: 10) { let t = now.addingTimeInterval(offset); policy.observe([observation(t)], now: t) }
        policy.becameFrontmost(identity)
        try require(!decision(observation(ready)).eligible, "brief foreground activation resets the interval between polling ticks")
        let wake = ready.addingTimeInterval(1000)
        policy.observe([observation(wake)], now: wake)
        try require(!policy.evaluate(rule, observation: observation(wake), now: wake, currentUID: 501, enabled: true, paused: false).eligible, "sleep gap cannot immediately trigger a quit on wake")
        for id in ["com.apple.finder", "com.gaoseries.GaoJiLing", "org.mozilla.firefox", "com.microsoft.VSCode", "org.example.downloader", "com.1password.app"] {
            try require(AppExitProtection.reason(bundleID: id, path: "/fixture/Protected.app") != nil, "protected application category: \(id)")
        }
        try require(AppExitProtection.reason(bundleID: "org.example.unknown", path: "/fixture/Protected.app", urlSchemes: ["HTTPS"]) != nil, "web handler metadata protects unnamed browsers without relying on display-name matching")
        try require(AppExitProtection.reason(bundleID: "org.example.unknown", path: "/fixture/Protected.app", documentBased: true) != nil, "NSDocument application metadata preserves conservative editing protection")
        print("PASS: AppOFF default-off, frontmost/save-state/UID/PID protection, cooldown and sleep state machine; no applications quit")

        func number(_ value: Double?) -> MetricReading<Double> { MetricReading(value: value, unit: "%", timestamp: now, source: "fixture") }
        func flag(_ value: Bool?) -> MetricReading<Bool> { MetricReading(value: value, unit: "", timestamp: now, source: "fixture") }
        var battery = BatterySnapshot(timestamp: now, present: flag(true), percent: number(15), externalPower: flag(false), charging: flag(false),
            healthPercent: number(nil), healthCondition: MetricReading(value: nil, unit: "", timestamp: now, source: "fixture"),
            cycles: MetricReading(value: nil, unit: "次", timestamp: now, source: "fixture"), temperature: number(nil), minutesToEmpty: number(nil), minutesToFull: number(nil))
        var batteryPolicy = BatteryNoticePolicy(); var batteryRule = BatteryRule()
        try require(batteryPolicy.evaluate(battery, rule: batteryRule, now: now).isEmpty, "battery notices default off")
        batteryRule.enabled = true
        try require(batteryPolicy.evaluate(battery, rule: batteryRule, now: now).map(\.id) == ["low"], "actual available value triggers one notice")
        try require(batteryPolicy.evaluate(battery, rule: batteryRule, now: now).isEmpty, "threshold does not notify repeatedly")
        try require(batteryPolicy.evaluate(nil, rule: batteryRule, now: now).isEmpty, "transient read failure cannot emit a notice")
        try require(batteryPolicy.evaluate(battery, rule: batteryRule, now: now).isEmpty, "transient read failure must not reset notification hysteresis")
        battery.percent = number(25)
        _ = batteryPolicy.evaluate(battery, rule: batteryRule, now: now)
        battery.percent = number(15); battery.percent.isStale = true
        try require(batteryPolicy.evaluate(battery, rule: batteryRule, now: now).isEmpty, "stale battery value cannot trigger notification")
        try require(BatteryCapability.current.allSatisfy { $0.capability != .verifiedControl }, "readings do not imply hardware control")
        try require(FanCapabilities.description(model: "Mac16,12", fans: nil).contains("无风扇"), "only officially verified model is marked fanless")
        try require(FanCapabilities.description(model: "UnknownModel", fans: nil).contains("未能确认"), "unknown hardware is not guessed fanless")
        try require(!FanCapabilities.accepts(.fixed(rpm: 3000)) && !FanCapabilities.accepts(.curve(points: [])), "unverified fixed/curve writes rejected")
        print("PASS: battery notification hysteresis/missing values and honest fan/control capabilities")

        let fm = FileManager.default
        let base = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("gaojiling-maintenance-tests-" + UUID().uuidString)
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }
        let data = base.appendingPathComponent("normal")
        let file = MaintenanceStateFile(dataDirectory: data)
        var state = file.preferences; state.rules = [rule]
        try require(!state.appExitEnabled, "fresh preferences never globally enable AppOFF")
        try file.save(state)
        let reloaded = MaintenanceStateFile(dataDirectory: data)
        try require(reloaded.writable && reloaded.preferences.rules == [rule], "new private state round-trips")
        let marker = try Data(contentsOf: data.appendingPathComponent("Maintenance.initialized"))
        try require(marker == Data("GaoJiLing.Maintenance.v1\n".utf8), "independent initialization sentinel has stable exact bytes")
        let path = data.appendingPathComponent("Maintenance/state.json")
        var st = stat(); try require(lstat(path.path, &st) == 0 && st.st_mode & 0o777 == 0o600, "private state permissions")
        let external = Data("externally changed, preserve me".utf8)
        try external.write(to: path)
        do { try file.save(state); throw Failure(message: "external edits must block save") } catch is Failure { throw Failure(message: "external edits must block save") } catch { }
        let externalAfter = try Data(contentsOf: path)
        try require(externalAfter == external && !file.writable, "external change preserves exact original bytes")
        let corrupt = MaintenanceStateFile(dataDirectory: data)
        try require(!corrupt.writable && !corrupt.preferences.appExitEnabled, "corrupt file disables all automatic actions")
        let futureRoot = base.appendingPathComponent("future")
        let futurePath = futureRoot.appendingPathComponent("Maintenance/state.json")
        try fm.createDirectory(at: futurePath.deletingLastPathComponent(), withIntermediateDirectories: true)
        var futureState = MaintenancePreferences(); futureState.schemaVersion = 99; futureState.appExitEnabled = true
        let futureBytes = try JSONEncoder().encode(futureState); try futureBytes.write(to: futurePath)
        let future = MaintenanceStateFile(dataDirectory: futureRoot)
        try require(!future.writable && !future.preferences.appExitEnabled, "future schema preserved instead of migrated to empty")
        let futureAfter = try Data(contentsOf: futurePath); try require(futureAfter == futureBytes, "future bytes unchanged")
        let linkedRoot = base.appendingPathComponent("linked")
        try fm.createDirectory(at: linkedRoot, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: linkedRoot.appendingPathComponent("Maintenance"), withDestinationURL: futurePath.deletingLastPathComponent())
        try require(!MaintenanceStateFile(dataDirectory: linkedRoot).writable, "symlink state directories rejected")
        let forbiddenRoot = base.appendingPathComponent("restricted")
        let forbiddenFile = MaintenanceStateFile(dataDirectory: forbiddenRoot); try forbiddenFile.save(state)
        let forbidden = forbiddenRoot.appendingPathComponent("Maintenance")
        try require(chmod(forbidden.path, 0) == 0, "restrict fixture permissions")
        defer { _ = chmod(forbidden.path, 0o700) }
        let denied = MaintenanceStateFile(dataDirectory: forbiddenRoot)
        try require(chmod(forbidden.path, 0o700) == 0, "restore fixture permissions")
        try require(!denied.writable, "permission failure is never mistaken for missing state")
        let missingRoot = base.appendingPathComponent("missing-record")
        try fm.createDirectory(at: missingRoot.appendingPathComponent("Maintenance"), withIntermediateDirectories: true)
        let missingFile = MaintenanceStateFile(dataDirectory: missingRoot)
        try require(!missingFile.writable && !missingFile.preferences.appExitEnabled, "existing directory with missing record is lost data, never a fresh empty store")
        try require(!fm.fileExists(atPath: missingRoot.appendingPathComponent("Maintenance/state.json").path), "missing-record protection never creates an empty replacement")
        let lostRoot = base.appendingPathComponent("lost-directory")
        let lost = MaintenanceStateFile(dataDirectory: lostRoot); try lost.save(state)
        try fm.removeItem(at: lostRoot.appendingPathComponent("Maintenance"))
        try require(!MaintenanceStateFile(dataDirectory: lostRoot).writable, "independent sentinel detects loss of the entire maintenance directory")
        do { try lost.save(state); throw Failure(message: "deleted directory must block existing writer") } catch is Failure { throw Failure(message: "deleted directory must block existing writer") } catch { }
        try require(!fm.fileExists(atPath: lostRoot.appendingPathComponent("Maintenance").path), "lost directory is not recreated as empty")
        let draftRoot = base.appendingPathComponent("valid-draft")
        let draftPath = draftRoot.appendingPathComponent("Maintenance/state.json")
        try fm.createDirectory(at: draftPath.deletingLastPathComponent(), withIntermediateDirectories: true)
        let draftBytes = try JSONEncoder().encode(state); try draftBytes.write(to: draftPath)
        let draft = MaintenanceStateFile(dataDirectory: draftRoot)
        let draftAfter = try Data(contentsOf: draftPath)
        try require(draft.writable && draftAfter == draftBytes && fm.fileExists(atPath: draftRoot.appendingPathComponent("Maintenance.initialized").path), "valid pre-release state can adopt marker without rewriting its data")
        try fm.removeItem(at: draftRoot.appendingPathComponent("Maintenance.initialized"))
        do { try draft.save(state); throw Failure(message: "external marker deletion must block live writer") } catch is Failure { throw Failure(message: "external marker deletion must block live writer") } catch { }
        try require(!draft.writable, "live external marker deletion is never silently repaired")
        print("PASS: private state, external edits, corrupt/future schema, symlinks and unreadable data protection")
        print("Maintenance tests passed with injected snapshots and private temporary fixtures only.")
    }
}
