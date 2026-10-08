import Foundation

@main struct MemoryMaintenanceTests {
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fputs("FAIL: \(message)\n", stderr); exit(1) }
    }

    static func main() {
        // All readings are synthetic; no system cleanup, authorization, or user files.
        var raw = GJLMemoryMaintenance()
        raw.total = 16_000
        raw.used = 8_000
        raw.free_bytes = 2_000
        raw.file_cache = 4_000
        raw.purgeable = 1_000
        raw.compressed = 500
        raw.swap = 750
        raw.memory_valid = 1
        raw.swap_valid = 1
        raw.pressure_level = 1
        let date = Date(timeIntervalSince1970: 1_000)
        let before = MemoryMaintenancePolicy.snapshot(raw, date: date)!
        require(before.used == 8_000 && before.total == 16_000 && before.free == 2_000, "native byte units remain unchanged")
        require(before.fileCache == 4_000 && before.purgeable == 1_000 && before.compressed == 500 && before.swap == 750, "individual categories are not conflated")
        require(before.date == date && before.pressure == "正常", "timestamp and pressure preserved")
        for (level, expected) in [(Int32(0), "未知"), (1, "正常"), (2, "偏高"), (4, "严重"), (3, "未知")] {
            raw.pressure_level = level
            require(MemoryMaintenancePolicy.snapshot(raw, date: date)?.pressure == expected, "pressure errors must not become normal")
        }
        raw.memory_valid = 0
        require(MemoryMaintenancePolicy.snapshot(raw, date: date) == nil, "VM failure is unavailable")
        raw.memory_valid = 1
        raw.swap_valid = 0
        require(MemoryMaintenancePolicy.snapshot(raw, date: date) == nil, "Swap failure must not fabricate zero")
        raw.swap_valid = 1
        raw.free_bytes = raw.total + 1
        require(MemoryMaintenancePolicy.snapshot(raw, date: date) == nil, "invalid bounds rejected")
        raw.free_bytes = 0
        raw.used = 0
        raw.swap = 0
        require(MemoryMaintenancePolicy.snapshot(raw, date: date) != nil, "valid zeros are readings, not failures")
        raw.total = 0
        require(MemoryMaintenancePolicy.snapshot(raw, date: date) == nil, "zero physical total rejected")
        print("PASS: snapshot failure, units, bounds and pressure policy")

        let missing = MemoryMaintenancePolicy.missingSnapshot()
        require(!missing.succeeded && missing.before == nil && missing.after == nil && missing.releasedOwnBytes == nil, "missing preflight never claims work")
        let ownZero = MemoryMaintenancePolicy.ownReport(before: before, after: before, released: 0)
        require(ownZero.succeeded && ownZero.releasedOwnBytes == 0 && ownZero.message.contains("没有可归还"), "zero allocator relief is honest success")
        let own = MemoryMaintenancePolicy.ownReport(before: before, after: nil, released: 8_192)
        require(own.succeeded && own.releasedOwnBytes == 8_192 && own.after == nil && own.message.contains("状态暂时不可用"), "actual allocator result remains valid despite later sampling failure")
        let success = MemoryMaintenancePolicy.systemReport(before: before, after: before, outcome: .completed(exitCode: 0, errorText: ""))
        require(success.succeeded && success.releasedOwnBytes == nil && success.message.contains("不代表本次释放量"), "purge success never invents a released byte count")
        let cancel = MemoryMaintenancePolicy.systemReport(before: before, after: before, outcome: .completed(exitCode: 1, errorText: "execution error: User canceled. (-128)\n"))
        require(!cancel.succeeded && cancel.releasedOwnBytes == nil && cancel.message.contains("已取消管理员授权"), "authorization cancellation distinguished")
        let failure = MemoryMaintenancePolicy.systemReport(before: before, after: nil, outcome: .completed(exitCode: 1, errorText: "A private diagnostic (-1743)"))
        require(!failure.succeeded && failure.message.contains("-1743") && !failure.message.contains("private"), "only numeric error is exposed")
        let timeout = MemoryMaintenancePolicy.systemReport(before: before, after: before, outcome: .timedOut)
        require(!timeout.succeeded && timeout.message.contains("可能仍在进行"), "timeout does not claim root command cancellation")
        for outcome in [MemoryCommandOutcome.unavailable, .launchFailed] {
            require(!MemoryMaintenancePolicy.systemReport(before: before, after: nil, outcome: outcome).succeeded, "missing tools and launch failure are failures")
        }
        require(MemoryMaintenancePolicy.appleScriptErrorCode("User canceled. (-128)\n") == -128, "localized error numeric suffix")
        require(MemoryMaintenancePolicy.appleScriptErrorCode("(-128) elsewhere") == nil, "only trailing error code counts")
        require(MemoryMaintenancePolicy.systemCacheScript == "do shell script \"/usr/sbin/purge\" with administrator privileges", "authorized command has fixed scope")
        print("PASS: own/system results, cancellation, timeout and fixed command policy")

        var output = MemoryBoundedOutput()
        output.append(Data(repeating: 65, count: 20_000))
        output.append(Data("\nUser canceled. (-128)\n".utf8))
        require(output.data.count == MemoryBoundedOutput.limit, "diagnostics remain bounded")
        require(MemoryMaintenancePolicy.appleScriptErrorCode(output.text) == -128, "bounded capture retains final diagnostic")
        require(gjl_application_running(nil, 0) == -1, "unknown bundle path cannot establish app absence")
        require(gjl_application_running("relative.app", 1) == -1, "relative bundle path fails closed")
        print("PASS: bounded diagnostics and application guard invalid inputs")
        print("Memory maintenance policy tests passed without running purge or requesting authorization.")
    }
}
