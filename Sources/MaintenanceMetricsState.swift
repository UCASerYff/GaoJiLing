import Foundation
import Darwin

struct MaintenancePreferences: Codable, Sendable {
    var schemaVersion = 1
    var appExitEnabled = false
    var appExitPaused = false
    var rules: [AppExitRule] = []
    var protectedBundleIDs: [String] = []
    var batteryRule = BatteryRule()
    var visibleMetricIDs = ["cpu", "memory", "compressed", "swap", "pressure", "gpu", "temperature", "diskFree", "diskRead", "diskWrite", "networkDown", "networkUp"]
    var records: [AppExitRecord] = []
    var isValid: Bool {
        schemaVersion == 1 && rules.count <= 32 && Set(rules.map(\.id)).count == rules.count && rules.allSatisfy(\.isValid) &&
        protectedBundleIDs.count <= 128 && protectedBundleIDs.allSatisfy { !$0.isEmpty && $0.count <= 256 } &&
        batteryRule.isValid && visibleMetricIDs.count <= 32 && records.count <= 100 &&
        records.allSatisfy { $0.name.count <= 256 && $0.reason.count <= 2048 && $0.date.timeIntervalSince1970.isFinite }
    }
}

/// One private, bounded file. Missing is only ENOENT; bad/future files stay
/// untouched. The original bytes must still match before every atomic save.
final class MaintenanceStateFile {
    private let dataDirectory: URL
    private let directory: URL
    private static let marker = Data("GaoJiLing.Maintenance.v1\n".utf8)
    private var markerPresent = false
    private var saved: Data?
    private(set) var writable = true
    private(set) var loadError: String?
    private(set) var preferences = MaintenancePreferences()
    init(dataDirectory: URL) {
        self.dataDirectory = dataDirectory
        directory = dataDirectory.appendingPathComponent("Maintenance", isDirectory: true)
        do {
            guard let parent = try openDirectory(dataDirectory, create: false) else { return }
            defer { close(parent) }
            let markerBytes = try read(in: parent, name: "Maintenance.initialized", limit: 128)
            guard markerBytes == nil || markerBytes == Self.marker else { throw failure("维护初始化记录损坏或版本不受支持") }
            markerPresent = markerBytes != nil
            guard let fd = try openDirectory(directory, create: false) else {
                guard !markerPresent else { throw failure("原维护资料目录缺失") }
                return
            }
            defer { close(fd) }
            // The directory is created by the first atomic save. If it already
            // exists, a missing state file can be lost data or an interrupted
            // save, not proof that there were never any preferences.
            guard let bytes = try read(in: fd) else { throw failure("维护资料目录存在但记录缺失") }
            let state = try JSONDecoder().decode(MaintenancePreferences.self, from: bytes)
            guard state.isValid else { throw failure("维护设置版本或内容不受支持") }
            preferences = state; saved = bytes
            // Only a fully validated pre-release state can adopt the marker.
            if !markerPresent { try createMarker(in: parent) }
        } catch {
            writable = false
            loadError = "维护设置无法安全读取，原文件已保留；自动退出不会启用。"
        }
    }
    func save(_ state: MaintenancePreferences) throws {
        guard writable, state.isValid else { throw failure("维护设置不可写，原资料已保留") }
        do {
            guard let parent = try openDirectory(dataDirectory, create: true) else { throw failure("无法打开维护资料父目录") }
            defer { close(parent) }
            guard try read(in: parent, name: "Maintenance.initialized", limit: 128) == (markerPresent ? Self.marker : nil) else {
                throw failure("维护初始化记录丢失或被外部修改")
            }
            if saved == nil, let unexpected = try openDirectory(directory, create: false) {
                close(unexpected); throw failure("维护目录在初始化后被外部建立，停止空白写入")
            }
            // Persist the sentinel first: an interruption may require recovery,
            // but can never make a lost directory look like a fresh install.
            if !markerPresent { try createMarker(in: parent) }
            guard let fd = try openDirectory(directory, create: saved == nil) else { throw failure("原维护设置目录缺失") }
            defer { close(fd) }
            guard try read(in: fd) == saved else { throw failure("维护设置已被外部修改；停止写入") }
            let bytes = try JSONEncoder().encode(state)
            guard bytes.count <= 1_048_576 else { throw failure("维护设置超过安全大小") }
            let temporary = "state-\(UUID().uuidString).tmp"
            let output = openat(fd, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard output >= 0 else { throw failure("无法创建维护设置临时文件") }
            defer { close(output); _ = unlinkat(fd, temporary, 0) }
            try bytes.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    let written = Darwin.write(output, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                    if written < 0 && errno == EINTR { continue }
                    guard written > 0 else { throw failure("维护设置写入失败，旧文件未替换") }
                    offset += written
                }
            }
            guard fsync(output) == 0 else { throw failure("维护设置同步失败") }
            guard try read(in: parent, name: "Maintenance.initialized", limit: 128) == Self.marker else { throw failure("维护初始化记录在保存期间改变") }
            guard try read(in: fd) == saved else { throw failure("保存前发现维护设置被外部修改") }
            guard renameat(fd, temporary, fd, "state.json") == 0 else { throw failure("维护设置替换失败") }
            saved = bytes; preferences = state
            guard fsync(fd) == 0 else { throw failure("维护设置已写入，但目录同步失败；自动操作已停用") }
        } catch { writable = false; throw error }
    }
    private func read(in fd: Int32, name: String = "state.json", limit: Int = 1_048_576) throws -> Data? {
        let input = openat(fd, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if input < 0 { if errno == ENOENT { return nil }; throw failure("维护记录不可读取") }
        defer { close(input) }
        var info = stat()
        guard fstat(input, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == geteuid(), info.st_nlink == 1,
              info.st_size >= 0, info.st_size <= limit, info.st_flags & UInt32(SF_DATALESS) == 0 else { throw failure("维护记录属性不受支持") }
        var bytes = Data(); var buffer = [UInt8](repeating: 0, count: 16384)
        while true {
            let count = Darwin.read(input, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw failure("维护记录读取失败") }
            if count == 0 { break }
            bytes.append(contentsOf: buffer.prefix(count))
            guard bytes.count <= limit else { throw failure("维护记录过大") }
        }
        return bytes
    }
    private func createMarker(in parent: Int32) throws {
        let fd = openat(parent, "Maintenance.initialized", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw failure("维护初始化记录已存在或无法创建") }
        defer { close(fd) }
        try Self.marker.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let count = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw failure("维护初始化记录写入失败") }
                offset += count
            }
        }
        guard fsync(fd) == 0, fsync(parent) == 0 else { throw failure("维护初始化记录同步失败") }
        markerPresent = true
    }
    private func openDirectory(_ directory: URL, create: Bool) throws -> Int32? {
        guard directory.isFileURL, directory.path.hasPrefix("/"), !directory.pathComponents.contains("..") else { throw failure("资料目录无效") }
        var fd = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw failure("无法打开资料根目录") }
        do {
            for component in directory.pathComponents.dropFirst() {
                var next = openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
                if next < 0, errno == ENOENT {
                    if !create { close(fd); return nil }
                    guard mkdirat(fd, component, 0o700) == 0 || errno == EEXIST else { throw failure("无法建立资料目录") }
                    next = openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
                }
                guard next >= 0 else { throw failure("资料目录不可读取或含符号链接") }
                close(fd); fd = next
            }
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_uid == geteuid() else { throw failure("维护资料目录归属不正确") }
            return fd
        } catch { close(fd); throw error }
    }
    private func failure(_ message: String) -> Error { NSError(domain: "GaoJiLing.Maintenance", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}
