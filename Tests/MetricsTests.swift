import Foundation

@main struct MetricsTests {
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fputs("FAIL: \(message)\n", stderr); exit(1) }
    }
    static func main() throws {
        require(!MetricsCollector.validInterval(nil, wallElapsed: nil), "initial sample must establish baseline")
        require(!MetricsCollector.validInterval(2, wallElapsed: 120), "wake from sleep must invalidate baseline")
        require(!MetricsCollector.validInterval(60, wallElapsed: 60), "late samples must not produce spikes")
        require(MetricsCollector.validInterval(2, wallElapsed: 2), "normal sample interval")
        let old = GJLCoreTicks(user: UInt32.max - 4, system: 10, idle: 20, nice: 0)
        let current = GJLCoreTicks(user: 5, system: 15, idle: 25, nice: 0)
        let delta = MetricsCollector.cpuDelta(current, old)
        require(delta.active == 15 && delta.total == 20, "CPU 32-bit counter wrap")
        let initial = GJLCounter(identifier: 1, received: 10_000, sent: 2_000)
        let after = GJLCounter(identifier: 1, received: 14_000, sent: 3_000)
        let added = GJLCounter(identifier: 2, received: 9_000_000_000, sent: 9_000_000_000)
        let rates = MetricsCollector.counterRates(current: [1: after, 2: added], previous: [1: initial], elapsed: 2)
        require(rates?.received == 2_000 && rates?.sent == 500, "new interface must not inject its lifetime counters")
        let reset = GJLCounter(identifier: 1, received: 1, sent: 1)
        require(MetricsCollector.counterRates(current: [1: reset], previous: [1: initial], elapsed: 2) == nil, "counter reset must return unavailable")
        require(MetricsCollector.counterRates(current: nil, previous: [1: initial], elapsed: 2) == nil, "failed collection must return unavailable")

        // Independently verify the C shim converts Mach CPU time into nanoseconds.
        func ownCPU() -> UInt64 {
            var pointer: UnsafeMutablePointer<GJLProcess>?
            var total: Int32 = 0
            let count = Int(gjl_process_snapshot(&pointer, &total))
            guard count >= 0, let pointer else { return 0 }
            defer { gjl_free_processes(pointer) }
            return (0..<count).first(where: { pointer[$0].pid == getpid() }).map { pointer[$0].cpu_nanoseconds } ?? 0
        }
        let beforeCPU = ownCPU()
        let spinUntil = ProcessInfo.processInfo.systemUptime + 0.3
        while ProcessInfo.processInfo.systemUptime < spinUntil { }
        let afterCPU = ownCPU()
        if beforeCPU > 0 {
            require(afterCPU > beforeCPU, "CPU counter advances under load")
            let seconds = Double(afterCPU - beforeCPU) / 1e9
            require(seconds > 0.1 && seconds < 2, "rusage timebase conversion (300 ms busy loop)")
            print("CPU timebase: 300 ms workload measured \(String(format: "%.0f", seconds * 1000)) ms CPU")
        }

        let collector = MetricsCollector()
        print("Hardware: \(MetricsCollector.hardwareDescription)")
        for index in 0..<4 {
            let started = ProcessInfo.processInfo.systemUptime
            let sample = collector.sample()
            let duration = (ProcessInfo.processInfo.systemUptime - started) * 1000
            if ProcessInfo.processInfo.environment["GJL_REQUIRE_LIVE"] == "1" {
                require(sample.memoryTotal > 0, "physical memory available")
                require(sample.memoryUsed > 0 && sample.memoryUsed <= sample.memoryTotal, "memory bounds")
                require(sample.diskTotal > 0 && sample.diskFree <= sample.diskTotal, "disk bounds")
                require(sample.processCount > 0 && !sample.processes.isEmpty, "processes accessible")
                if index > 0 { require(sample.cpuPercent != nil, "CPU available after baseline") }
            }
            require(sample.cpuPercent.map { $0 >= 0 && $0 <= 100 } ?? true, "CPU bounds")
            require(sample.processes.allSatisfy { $0.cpuPercent >= 0 && $0.cpuPercent <= 100 && $0.memoryBytes >= 0 }, "process bounds")
            require(Set(sample.processes.map(\.id)).count == sample.processes.count, "unique application identities")
            let top = sample.processes.prefix(3).map { "\($0.name):\(String(format: "%.2f", $0.cpuPercent))%" }.joined(separator: ", ")
            print("sample \(index) \(String(format: "%.1f", duration))ms CPU=\(Format.percent(sample.cpuPercent)) cores=\(sample.corePercents.count) memory=\(Format.bytes(sample.memoryUsed))/\(Format.bytes(sample.memoryTotal)) compressed=\(Format.bytes(sample.memoryCompressed)) swap=\(Format.bytes(sample.swapUsed)) pressure=\(sample.memoryPressure) net=\(Format.rate(sample.networkDown))/\(Format.rate(sample.networkUp)) disk=\(Format.rate(sample.diskRead))/\(Format.rate(sample.diskWrite)) process=\(sample.processCount)/\(sample.processes.count) gpu=\(Format.percent(sample.gpuPercent)) temp=\(sample.cpuTemperature.map { String(format: "%.1f", $0) } ?? "n/a") fan=\(sample.fanRPM.map { String(format: "%.0f", $0) } ?? "n/a") power=\(sample.cpuPower.map { String(format: "%.1f", $0) } ?? "n/a") battery=\(Format.percent(sample.batteryPercent)) health=\(Format.percent(sample.batteryHealth)) cycles=\(sample.batteryCycles.map(String.init) ?? "n/a") top=[\(top)]")
            if index < 3 { Thread.sleep(forTimeInterval: 2) }
        }
        print("PASS: reset/rollover/hotplug invariants and four live snapshots")
    }
}
