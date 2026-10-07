import Foundation

/// Owned by the store's serial sampling queue. No shell or privileged helper is used.
final class MetricsCollector: @unchecked Sendable {
    private struct ProcessBaseline {
        var start: UInt64
        var cpu: UInt64
    }
    private struct AppIdentity {
        var name: String
        var path: String?
    }
    private let sensors = Sensors()
    private var previousCores: [GJLCoreTicks] = []
    private var previousNetwork: [UInt64: GJLCounter] = [:]
    private var previousDisks: [UInt64: GJLCounter] = [:]
    private var previousProcesses: [Int32: ProcessBaseline] = [:]
    private var identities: [String: AppIdentity] = [:]
    private var lastUptime: TimeInterval?
    private var lastDate: Date?
    private var lastProcessUptime: TimeInterval?
    private var cachedProcesses: [ProcessMetric] = []
    private var cachedProcessCount = 0

    init() {}

    static let hardwareDescription: String = {
        func read(_ key: String) -> String {
            var buffer = [CChar](repeating: 0, count: 256)
            guard gjl_sysctl_string(key, &buffer, buffer.count) != 0 else { return "" }
            return String(cString: buffer).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let chip = read("machdep.cpu.brand_string")
        let model = read("hw.model")
        let title = [chip, model].filter { !$0.isEmpty }.joined(separator: " · ")
        return "\(title.isEmpty ? "Mac" : title) · \(ProcessInfo.processInfo.processorCount) 核"
    }()

    func sample() -> MetricsSample {
        let now = Date()
        let uptime = ProcessInfo.processInfo.systemUptime
        let elapsed = lastUptime.map { uptime - $0 }
        let wallElapsed = lastDate.map { now.timeIntervalSince($0) }
        let usableInterval = Self.validInterval(elapsed, wallElapsed: wallElapsed)
        var sample = MetricsSample(timestamp: now)
        var raw = GJLSystem()
        gjl_system_snapshot(&raw)
        let count = Int(raw.core_count)
        let cores = withUnsafeBytes(of: &raw.cores) { Array($0.bindMemory(to: GJLCoreTicks.self).prefix(count)) }
        if usableInterval, previousCores.count == count, !cores.isEmpty {
            var active: UInt64 = 0, total: UInt64 = 0
            sample.corePercents = zip(cores, previousCores).map { current, old in
                let delta = Self.cpuDelta(current, old)
                active += delta.active; total += delta.total
                return delta.total > 0 ? Double(delta.active) / Double(delta.total) * 100 : 0
            }
            sample.cpuPercent = total > 0 ? min(100, Double(active) / Double(total) * 100) : nil
        }
        previousCores = cores
        if raw.memory_valid != 0 {
            sample.memoryTotal = Double(raw.memory_total)
            sample.memoryUsed = Double(raw.memory_used)
            sample.memoryCompressed = Double(raw.memory_compressed)
            sample.swapUsed = Double(raw.swap_used)
        }
        sample.memoryPressure = switch raw.pressure_level {
        case 1: "正常"
        case 2: "偏高"
        case 4: "严重"
        default: "未知"
        }
        sample.diskFree = Double(raw.disk_free)
        sample.diskTotal = Double(raw.disk_total)
        sample.uptime = raw.uptime > 0 ? raw.uptime : uptime
        let network = readCounters(gjl_network_counters)
        let disks = readCounters(gjl_disk_counters)
        if usableInterval, let interval = elapsed {
            if network?.isEmpty == true {
                sample.networkDown = 0; sample.networkUp = 0
            } else if let rates = Self.counterRates(current: network, previous: previousNetwork, elapsed: interval) {
                sample.networkDown = rates.received; sample.networkUp = rates.sent
            }
            if let rates = Self.counterRates(current: disks, previous: previousDisks, elapsed: interval) {
                sample.diskRead = rates.received; sample.diskWrite = rates.sent
            }
        }
        previousNetwork = network ?? [:]
        previousDisks = disks ?? [:]
        if !usableInterval {
            previousProcesses.removeAll(keepingCapacity: true)
            lastProcessUptime = nil
        }
        // Heavy process inspection is limited to once every four seconds.
        if lastProcessUptime == nil || uptime - lastProcessUptime! >= 4 {
            sampleProcesses(at: uptime, cores: count > 0 ? count : max(1, ProcessInfo.processInfo.processorCount))
        }
        sample.processes = cachedProcesses
        sample.processCount = cachedProcessCount
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: sample.thermalState = "正常"
        case .fair: sample.thermalState = "偏暖"
        case .serious: sample.thermalState = "严重"
        case .critical: sample.thermalState = "危急"
        @unknown default: sample.thermalState = "未知"
        }
        sensors.apply(to: &sample, uptime: uptime, force: !usableInterval)
        lastUptime = uptime; lastDate = now
        return sample
    }

    /// Discard baselines after suspension, clock discontinuity or a failed/late sample.
    static func validInterval(_ elapsed: TimeInterval?, wallElapsed: TimeInterval?) -> Bool {
        guard let elapsed, let wallElapsed else { return false }
        return elapsed >= 0.05 && elapsed <= 30 && abs(elapsed - wallElapsed) < 3
    }

    static func cpuDelta(_ current: GJLCoreTicks, _ previous: GJLCoreTicks) -> (active: UInt64, total: UInt64) {
        // Kernel counters are UInt32; wrapping subtraction handles their rollover.
        let user = UInt64(current.user &- previous.user)
        let system = UInt64(current.system &- previous.system)
        let nice = UInt64(current.nice &- previous.nice)
        let idle = UInt64(current.idle &- previous.idle)
        let active = user + system + nice
        return (active, active + idle)
    }

    private func readCounters(_ read: (UnsafeMutablePointer<GJLCounter>?, Int32) -> Int32) -> [UInt64: GJLCounter]? {
        var values = [GJLCounter](repeating: GJLCounter(), count: 128)
        let count = Int(read(&values, Int32(values.count)))
        guard count >= 0 else { return nil }
        var result: [UInt64: GJLCounter] = [:]
        for value in values.prefix(count) { result[value.identifier] = value }
        return result
    }

    static func counterRates(current: [UInt64: GJLCounter]?, previous: [UInt64: GJLCounter], elapsed: TimeInterval) -> (received: Double, sent: Double)? {
        guard let current, elapsed >= 0.05, elapsed <= 30 else { return nil }
        // Missing devices have no rate; a confirmed offline network is handled by the caller.
        if current.isEmpty { return nil }
        var received = 0.0, sent = 0.0, matched = 0
        for (identifier, counter) in current {
            guard let old = previous[identifier], counter.received >= old.received, counter.sent >= old.sent else { continue }
            received += Double(counter.received - old.received)
            sent += Double(counter.sent - old.sent)
            matched += 1
        }
        guard matched > 0 else { return nil }
        return (received / elapsed, sent / elapsed)
    }

    private func sampleProcesses(at uptime: TimeInterval, cores: Int) {
        var pointer: UnsafeMutablePointer<GJLProcess>?
        var total: Int32 = 0
        let count = Int(gjl_process_snapshot(&pointer, &total))
        guard count >= 0, let pointer else {
            cachedProcesses = []; cachedProcessCount = 0
            previousProcesses.removeAll(keepingCapacity: true); lastProcessUptime = nil
            return
        }
        defer { gjl_free_processes(pointer) }
        var baselines: [Int32: ProcessBaseline] = [:]
        var groups: [String: ProcessMetric] = [:]
        let interval = lastProcessUptime.map { uptime - $0 }
        for index in 0..<count {
            var record = pointer[index]
            let path = withUnsafePointer(to: &record.path) { p in p.withMemoryRebound(to: CChar.self, capacity: 4096) { String(cString: $0) } }
            let rawName = withUnsafePointer(to: &record.name) { p in p.withMemoryRebound(to: CChar.self, capacity: 256) { String(cString: $0) } }
            let identity = appIdentity(path: path, fallback: rawName)
            var cpu = 0.0
            if let interval, interval >= 0.05, interval <= 30, let old = previousProcesses[record.pid], old.start == record.start_time, record.cpu_nanoseconds >= old.cpu {
                cpu = min(100, Double(record.cpu_nanoseconds - old.cpu) / 1e9 / interval / Double(cores) * 100)
            }
            baselines[record.pid] = ProcessBaseline(start: record.start_time, cpu: record.cpu_nanoseconds)
            // The model's ID is the display name, so aggregate equal names to keep IDs unique.
            var group = groups[identity.name] ?? ProcessMetric(name: identity.name, cpuPercent: 0, memoryBytes: 0, path: identity.path)
            group.cpuPercent = min(100, group.cpuPercent + cpu)
            group.memoryBytes += Double(record.memory_bytes)
            group.pids.append(record.pid)
            groups[identity.name] = group
        }
        previousProcesses = baselines
        cachedProcesses = groups.values.sorted { a, b in a.cpuPercent == b.cpuPercent ? a.memoryBytes > b.memoryBytes : a.cpuPercent > b.cpuPercent }
        cachedProcessCount = Int(total)
        lastProcessUptime = uptime
        // Bound metadata cache in very long sessions with many transient executables.
        if identities.count > 4096 { identities.removeAll(keepingCapacity: true) }
    }

    private func appIdentity(path: String, fallback: String) -> AppIdentity {
        let key = path.isEmpty ? "name:\(fallback)" : path
        if let existing = identities[key] { return existing }
        var identity: AppIdentity
        if let range = path.range(of: ".app/", options: .caseInsensitive) {
            let appPath = String(path[..<range.lowerBound]) + ".app"
            let bundle = Bundle(path: appPath)
            let title = (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
                ?? URL(fileURLWithPath: appPath).deletingPathExtension().lastPathComponent
            identity = AppIdentity(name: title, path: appPath)
        } else {
            identity = AppIdentity(name: fallback.isEmpty ? URL(fileURLWithPath: path).lastPathComponent : fallback, path: path.isEmpty ? nil : path)
        }
        identities[key] = identity
        return identity
    }
}
