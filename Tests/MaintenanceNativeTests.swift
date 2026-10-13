import Foundation
import Darwin

/// Opt-in live read-only source checks. Logs only availability and validation,
/// never names/paths from the real application list or actual monitor values.
@main struct MaintenanceNativeTests {
    struct Failure: Error { var message: String }
    static func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw Failure(message: message) }
    }
    static func main() throws {
        guard ProcessInfo.processInfo.environment["GJL_REQUIRE_LIVE"] == "1" else {
            print("SKIP: live maintenance source probe requires GJL_REQUIRE_LIVE=1"); return
        }
        var start: UInt64 = 0, uid: UInt32 = 0
        try require(gjl_process_identity(getpid(), &start, &uid) != 0 && start > 0 && uid == geteuid(), "libproc must verify this probe's own PID/start/UID")
        let own = ProcessIdentity(pid: getpid(), startTime: start, uid: uid)
        let collector = MetricsCollector()
        let first = collector.sample()
        try require(first.cpuPercent == nil, "fresh collector requires a CPU delta baseline")
        Thread.sleep(forTimeInterval: 1.1)
        let second = collector.sample()
        try require(second.cpuPercent.map { (0...100).contains($0) } == true, "real CPU delta must be available and whole-machine normalized")
        try require(second.readings?["memory"]?.isFresh() == true && second.memoryTotal > 0, "Mach memory counters must be genuinely available")
        Thread.sleep(forTimeInterval: 3.2)
        let third = collector.sample()
        try require(third.processes.contains { $0.identities?.contains(own) == true }, "native process snapshot must include this exact PID/start/UID")
        try require(Set(third.processes.map(\.id)).count == third.processes.count, "real application grouping keys must be unique")
        try require(third.processes.allSatisfy { (0...100).contains($0.cpuPercent) && $0.memoryBytes.isFinite && $0.memoryBytes >= 0 }, "real process counters must have safe bounds")
        for reading in third.readings?.values ?? [:].values {
            try require(!reading.source.isEmpty, "every numeric metric must identify its source")
            try require(reading.value?.isFinite ?? true, "unavailable native values cannot leak NaN or infinity")
        }
        guard let battery = third.batterySnapshot else { throw Failure(message: "battery availability observation was not produced") }
        try require(battery.present.source.hasPrefix("IOPowerSources"), "battery presence is sourced from public IOPS")
        if let percent = battery.percent.value { try require((0...100).contains(percent), "real battery percentage range") }
        if let temperature = battery.temperature.value { try require((-20...100).contains(temperature), "public temperature is bounded in Celsius") }
        for fan in third.fanDescriptors ?? [] {
            try require(fan.speed.value.map { (0..<30000).contains($0) } ?? true, "only actual bounded fan readings are exposed")
            try require(fan.minimumRPM == nil && fan.maximumRPM == nil, "unverified fan-control ranges are not invented")
        }
        let available = (third.readings ?? [:]).filter { $0.value.isFresh() }.map(\.key).sorted().joined(separator: ", ")
        let unavailable = (third.readings ?? [:]).filter { !$0.value.isFresh() }.map(\.key).sorted().joined(separator: ", ")
        print("PASS: native Mach/libproc identity and normalized counters; fresh metric keys: " + available)
        print("Unavailable/stale metric keys: " + unavailable)
        print("Battery: present=\(battery.present.value.map(String.init) ?? "unknown"), public temperature available=\(battery.temperature.isFresh()); discovered fans=\(third.fanDescriptors?.isEmpty == false ? "yes" : "none or unavailable")")
        print("Live maintenance probe passed; read-only and no private readings/application list logged.")
    }
}
