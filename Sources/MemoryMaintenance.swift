import Foundation
import Darwin

struct MemorySnapshot: Sendable, Equatable {
    let used: Double
    let total: Double
    /// HOST_VM_INFO64 free_count includes speculative pages.
    let free: Double
    /// File-backed pages, including mappings; not a guaranteed reclaimable amount.
    let fileCache: Double
    let purgeable: Double
    /// Physical compressor storage, in the same units as the monitor.
    let compressed: Double
    let swap: Double
    let pressure: String
    let date: Date
}

struct MemoryReleaseReport: Sendable {
    let before: MemorySnapshot?
    let after: MemorySnapshot?
    /// Only libmalloc's return value for this process. System purge has no byte result.
    let releasedOwnBytes: UInt64?
    let succeeded: Bool
    let message: String
}

/// User-initiated maintenance only. No data files, preferences, keychain, or processes
/// belonging to other apps are changed. The caller serializes actions in its UI.
enum MemoryMaintenance {
    static func snapshot() -> MemorySnapshot? {
        var raw = GJLMemoryMaintenance()
        guard gjl_memory_maintenance_snapshot(&raw) != 0 else { return nil }
        return MemoryMaintenancePolicy.snapshot(raw, date: Date())
    }

    static func releaseOwnMemory() async -> MemoryReleaseReport {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                guard let before = snapshot() else {
                    continuation.resume(returning: MemoryMaintenancePolicy.missingSnapshot())
                    return
                }
                let released = autoreleasepool { gjl_memory_maintenance_relief() }
                continuation.resume(returning: MemoryMaintenancePolicy.ownReport(
                    before: before, after: snapshot(), released: released))
            }
        }
    }

    static func reclaimSystemFileCache() async -> MemoryReleaseReport {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                guard let before = snapshot() else {
                    continuation.resume(returning: MemoryMaintenancePolicy.missingSnapshot())
                    return
                }
                let outcome = runSystemCacheCommand()
                continuation.resume(returning: MemoryMaintenancePolicy.systemReport(
                    before: before, after: snapshot(), outcome: outcome))
            }
        }
    }

    // NSAppleScript is documented as main-thread-only. A fixed Apple-supplied
    // osascript process keeps synchronous authorization off this app's UI thread.
    // AppleScript's `with timeout` does not cancel `do shell script`; the bounded
    // wait below only ends our wait and requests termination of this osascript.
    // The privileged purge may already have started and must not be force-killed.
    private static func runSystemCacheCommand() -> MemoryCommandOutcome {
        guard FileManager.default.isExecutableFile(atPath: "/usr/sbin/purge"),
              FileManager.default.isExecutableFile(atPath: "/usr/bin/osascript") else { return .unavailable }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", MemoryMaintenancePolicy.systemCacheScript]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let errors = Pipe()
        process.standardError = errors
        let descriptor = errors.fileHandleForReading.fileDescriptor
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) != -1 else {
            return .launchFailed
        }
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do { try process.run() } catch { return .launchFailed }
        errors.fileHandleForWriting.closeFile()
        defer {
            errors.fileHandleForReading.closeFile()
            process.terminationHandler = nil
        }
        var diagnostics = MemoryBoundedOutput()
        func drainErrors() {
            var buffer = [UInt8](repeating: 0, count: 512)
            // Bounded work and storage even if a system command unexpectedly logs.
            for _ in 0..<16 {
                let count = Darwin.read(descriptor, &buffer, buffer.count)
                guard count > 0 else { break }
                diagnostics.append(Data(buffer.prefix(count)))
            }
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 120
        while true {
            drainErrors()
            if finished.wait(timeout: .now() + 0.1) == .success {
                drainErrors()
                return .completed(exitCode: process.terminationStatus, errorText: diagnostics.text)
            }
            if ProcessInfo.processInfo.systemUptime >= deadline {
                if process.isRunning { process.terminate() }
                // Do not wait indefinitely, escalate to SIGKILL, or signal purge.
                _ = finished.wait(timeout: .now() + 1)
                return .timedOut
            }
        }
    }
}

/// Pure policy remains testable without authorizing or invoking a system command.
enum MemoryCommandOutcome: Sendable {
    case completed(exitCode: Int32, errorText: String)
    case timedOut
    case unavailable
    case launchFailed
}

struct MemoryBoundedOutput {
    private(set) var data = Data()
    static let limit = 4_096
    mutating func append(_ chunk: Data) {
        if chunk.count >= Self.limit {
            data = Data(chunk.suffix(Self.limit))
        } else {
            let excess = data.count + chunk.count - Self.limit
            if excess > 0 { data.removeFirst(excess) }
            data.append(chunk)
        }
    }
    var text: String { String(decoding: data, as: UTF8.self) }
}

enum MemoryMaintenancePolicy {
    // No paths, commands, names, passwords, or other user input are interpolated.
    static let systemCacheScript = "do shell script \"/usr/sbin/purge\" with administrator privileges"

    static func snapshot(_ raw: GJLMemoryMaintenance, date: Date) -> MemorySnapshot? {
        guard raw.memory_valid != 0, raw.swap_valid != 0, raw.total > 0,
              raw.used <= raw.total, raw.free_bytes <= raw.total,
              raw.file_cache <= raw.total, raw.purgeable <= raw.total,
              raw.compressed <= raw.total else { return nil }
        let pressure: String
        switch raw.pressure_level {
        case 1: pressure = "正常"
        case 2: pressure = "偏高"
        case 4: pressure = "严重"
        default: pressure = "未知"
        }
        return MemorySnapshot(used: Double(raw.used), total: Double(raw.total),
                              free: Double(raw.free_bytes), fileCache: Double(raw.file_cache),
                              purgeable: Double(raw.purgeable), compressed: Double(raw.compressed),
                              swap: Double(raw.swap), pressure: pressure, date: date)
    }

    static func missingSnapshot() -> MemoryReleaseReport {
        MemoryReleaseReport(before: nil, after: nil, releasedOwnBytes: nil, succeeded: false,
                            message: "无法读取当前内存状态，本次未执行回收。请稍后重试。")
    }

    static func ownReport(before: MemorySnapshot, after: MemorySnapshot?, released: UInt64) -> MemoryReleaseReport {
        let message = released == 0
            ? "检查完成，搞机灵当前没有可归还的闲置分配。"
            : "已归还搞机灵自身的闲置内存，字节数由系统分配器返回。"
        return MemoryReleaseReport(before: before, after: after, releasedOwnBytes: released,
                                   succeeded: true, message: message + missingAfter(after))
    }

    static func systemReport(before: MemorySnapshot, after: MemorySnapshot?, outcome: MemoryCommandOutcome) -> MemoryReleaseReport {
        let succeeded: Bool
        let message: String
        switch outcome {
        case .completed(let exitCode, let errorText):
            succeeded = exitCode == 0
            if succeeded {
                message = "系统文件缓存回收已完成。前后读数也会受其他应用活动影响，不代表本次释放量；应用占用与 Swap 不会因此被清空。"
            } else if appleScriptErrorCode(errorText) == -128 {
                message = "已取消管理员授权，本次未执行系统文件缓存回收。"
            } else {
                let code = appleScriptErrorCode(errorText).map(String.init) ?? String(exitCode)
                message = "系统文件缓存回收未能完成（错误 \(code)）。可检查管理员授权后重试。"
            }
        case .timedOut:
            succeeded = false
            message = "等待已超时，已请求终止本次授权程序。系统缓存回收可能仍在进行，请勿立即重复操作。"
        case .unavailable:
            succeeded = false
            message = "此 macOS 环境缺少系统缓存回收工具，无法执行。"
        case .launchFailed:
            succeeded = false
            message = "无法启动系统授权程序，本次未执行系统文件缓存回收。"
        }
        return MemoryReleaseReport(before: before, after: after, releasedOwnBytes: nil,
                                   succeeded: succeeded, message: message + missingAfter(after))
    }

    static func appleScriptErrorCode(_ text: String) -> Int? {
        // osascript writes localized messages, but the final error code is stable.
        guard let range = text.range(of: #"\(-?\d+\)\s*$"#, options: .regularExpression) else { return nil }
        let code = text[range].trimmingCharacters(in: .whitespacesAndNewlines)
        return Int(code.dropFirst().dropLast())
    }

    private static func missingAfter(_ after: MemorySnapshot?) -> String {
        after == nil ? " 回收后状态暂时不可用。" : ""
    }
}
