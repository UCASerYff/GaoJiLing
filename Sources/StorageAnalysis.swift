import Foundation
import AppKit
import Darwin

struct StorageEntry: Identifiable, Sendable {
    let id: String
    let name: String
    let category: String
    let path: String
    let bytes: Int64
    let fileCount: Int
    let risk: String
    let reason: String
}

struct StorageAnalysisResult: Sendable {
    let entries: [StorageEntry]
    let largestFiles: [StorageEntry]
    let notes: [String]
    let complete: Bool
    let date: Date
    /// Confirmed allocated blocks, not logical file sizes or promised removable bytes.
    /// When complete is false this is only the portion that could be inspected.
    let totalBytes: Int64
    let root: String?
}

struct DiskCapacity: Sendable {
    let totalBytes: Int64
    let availableBytes: Int64
    static func snapshot(for directory: URL) -> DiskCapacity? {
        try? StorageFilesystem.withMaterializationDisabled {
            let descriptor = try StorageFilesystem.openDirectory(directory)
            defer { close(descriptor) }
            var value = statfs()
            guard fstatfs(descriptor, &value) == 0,
                  let total = StorageAnalysisPolicy.product(UInt64(value.f_blocks), UInt64(value.f_bsize)),
                  let available = StorageAnalysisPolicy.product(UInt64(value.f_bavail), UInt64(value.f_bsize)),
                  total > 0, available <= total else { throw StorageAnalysisFailure("无法读取磁盘容量。") }
            return DiskCapacity(totalBytes: total, availableBytes: available)
        }
    }
}

/// Synchronous, metadata-only work; callers run it on a utility queue. Each call
/// owns its traversal state. There is no delete, move, materialize, or file-read API.
final class StorageAnalyzer: @unchecked Sendable {
    private let home: URL
    private let maximumEntries: Int
    private let timeBudget: TimeInterval
    private let ownerLookup: @Sendable (String) -> Bool?
    init(home: URL = FileManager.default.homeDirectoryForCurrentUser, maximumEntries: Int = 250_000, timeBudget: TimeInterval = 20,
         ownerLookup: @escaping @Sendable (String) -> Bool? = { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil }) {
        self.home = home
        self.maximumEntries = max(0, maximumEntries)
        self.timeBudget = timeBudget.isFinite ? max(0, timeBudget) : 20
        self.ownerLookup = ownerLookup
    }

    func scanEnvironments(exclusions: [URL] = [], cancelled: @Sendable () -> Bool = { false }) throws -> StorageAnalysisResult {
        try StorageFilesystem.withMaterializationDisabled {
            let state = ScanState(maximumEntries: maximumEntries, seconds: timeBudget, exclusions: exclusions)
            var entries: [StorageEntry] = []
            for location in environmentLocations {
                if state.shouldStop(cancelled) { break }
                let url = location.url
                if state.isExcluded(url) { state.note(.excluded); continue }
                do {
                    let descriptor = try StorageFilesystem.openDirectory(url)
                    defer { close(descriptor) }
                    var info = stat()
                    guard fstat(descriptor, &info) == 0 else { throw StorageFilesystem.posix() }
                    if let amount = state.walkDirectory(descriptor, url: url, info: info,
                        device: info.st_dev, category: location.category, depth: 0, cancelled: cancelled) {
                        entries.append(entry(url, category: location.category, amount: amount,
                            risk: location.risk, reason: location.reason))
                        state.totalBytes = state.add(state.totalBytes, amount.bytes)
                    }
                } catch {
                    if let error = error as? StorageAnalysisFailure, error.code == ENOENT { continue }
                    state.note(StorageFilesystem.issue(error))
                }
            }
            // A bundle-like cache name with no identified installed app is only
            // a suspected remnant; it is never offered to the cleanup engine.
            if !state.shouldStop(cancelled) {
                let caches = home.appendingPathComponent("Library/Caches")
                if state.isExcluded(caches) { state.note(.excluded) }
                else {
                    do {
                        let parent = try StorageFilesystem.openDirectory(caches)
                        defer { close(parent) }
                        var rootInfo = stat()
                        guard fstat(parent, &rootInfo) == 0 else { throw StorageFilesystem.posix() }
                        state.enumerate(parent, cancelled: cancelled) { name in
                            let url = caches.appendingPathComponent(name)
                            // Name-only rejection precedes owner lookup and all
                            // metadata/open calls on system or Gao-series caches.
                            guard !StorageAnalysisPolicy.isManagedCache(name) else {
                                _ = state.consume(cancelled); state.note(.managed); return
                            }
                            if state.isExcluded(url) { _ = state.consume(cancelled); state.note(.excluded); return }
                            guard StorageAnalysisPolicy.isBundleLike(name), ownerLookup(name) == false else {
                                _ = state.consume(cancelled)
                                return
                            }
                            // Only directories are candidates; no file is opened.
                            var info = stat()
                            guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
                                _ = state.consume(cancelled); state.note(.unreadable); return
                            }
                            guard info.st_mode & S_IFMT == S_IFDIR else { _ = state.consume(cancelled); return }
                            if let amount = state.walkChild(parent: parent, name: name, url: url,
                                device: rootInfo.st_dev, category: "疑似残留缓存", depth: 1, cancelled: cancelled) {
                                entries.append(entry(url, category: "疑似残留缓存", amount: amount,
                                    risk: "归属待确认", reason: "未识别到此目录名称对应的已安装应用；也可能是命名差异或独立组件，不能据此认定可删除。"))
                                state.totalBytes = state.add(state.totalBytes, amount.bytes)
                            }
                        }
                    } catch {
                        if (error as? StorageAnalysisFailure)?.code != ENOENT { state.note(StorageFilesystem.issue(error)) }
                    }
                }
            }
            return state.result(entries: entries.sorted(by: Self.larger), root: nil)
        }
    }

    func analyze(directory: URL, exclusions: [URL] = [], cancelled: @Sendable () -> Bool = { false }) throws -> StorageAnalysisResult {
        try StorageFilesystem.withMaterializationDisabled {
            let url = directory
            let state = ScanState(maximumEntries: maximumEntries, seconds: timeBudget, exclusions: exclusions)
            guard !state.isExcluded(url) else { throw StorageAnalysisFailure("所选目录位于排除范围内，未进行分析。") }
            let descriptor = try StorageFilesystem.openDirectory(url)
            defer { close(descriptor) }
            var info = stat()
            guard fstat(descriptor, &info) == 0 else { throw StorageFilesystem.posix() }
            var entries: [StorageEntry] = []
            if state.consume(cancelled) {
                state.visited.insert(FileIdentity(info))
                guard let rootBytes = state.allocatedBytes(info) else { throw StorageAnalysisFailure("目录分配大小无效，已停止分析。") }
                state.totalBytes = rootBytes
                state.enumerate(descriptor, cancelled: cancelled) { name in
                    let child = url.appendingPathComponent(name)
                    let amount = state.walkChild(parent: descriptor, name: name, url: child,
                        device: info.st_dev, category: "所选目录", depth: 1, cancelled: cancelled)
                    if let amount {
                        state.totalBytes = state.add(state.totalBytes, amount.bytes)
                        if amount.directory {
                            entries.append(entry(child, category: "子目录", amount: amount, risk: "仅分析",
                                reason: "包含本目录下已确认的本地分配块，不代表可清理空间。"))
                            entries.sort(by: Self.larger)
                            if entries.count > 20 { entries.removeLast() }
                        }
                    }
                }
                var after = stat()
                if fstat(descriptor, &after) != 0 || !StorageAnalysisPolicy.unchanged(info, after) { state.note(.changed) }
            }
            return state.result(entries: entries, root: url.path)
        }
    }

    private func entry(_ url: URL, category: String, amount: Amount, risk: String, reason: String) -> StorageEntry {
        StorageEntry(id: url.path, name: url.lastPathComponent, category: category, path: url.path,
                     bytes: amount.bytes, fileCount: amount.fileCount, risk: risk,
                     reason: reason + (amount.complete ? "" : " 扫描不完整，此数值仅包含已确认部分。"))
    }
    private static func larger(_ left: StorageEntry, _ right: StorageEntry) -> Bool {
        left.bytes == right.bytes ? left.path < right.path : left.bytes > right.bytes
    }

    private struct Location {
        let url: URL
        let category: String
        let risk: String
        let reason: String
    }
    private var environmentLocations: [Location] {
        let cache = "可重新生成或下载的缓存也可能正在使用；此处只统计，不提供删除判断。"
        let environment = "包含已安装工具、环境或运行数据；需由对应软件管理，不能整体当作垃圾。"
        let model = "模型下载与模型数据，重新下载可能耗时或付费；不视为垃圾。"
        var locations: [Location] = []
        func add(_ category: String, _ paths: [String], risk: String = "需确认", reason: String) {
            locations += paths.map { Location(url: home.appendingPathComponent($0), category: category, risk: risk, reason: reason) }
        }
        add("Xcode", ["Library/Developer/Xcode/DerivedData"], reason: "构建中间文件及项目依赖，可能含离线所需内容；仅作空间分析。")
        add("Xcode", ["Library/Developer/Xcode/Archives", "Library/Developer/Xcode/iOS DeviceSupport", "Library/Developer/CoreSimulator"], risk: "保留资料", reason: environment)
        add("Node.js", [".npm", "Library/pnpm/store", ".local/share/pnpm/store", "Library/Caches/pnpm", ".pnpm-store", "Library/Caches/Yarn", ".cache/yarn"], reason: cache)
        add("Python", ["Library/Caches/pip", ".cache/pip", "Library/Caches/pypoetry", ".cache/pypoetry", "Library/Caches/uv", ".cache/uv"], reason: cache)
        add("Python", [".virtualenvs", ".venvs", ".venv", ".conda/envs", "miniconda3/envs", "anaconda3/envs"], risk: "已安装环境", reason: environment)
        add("Gradle / Maven", [".gradle/caches", ".m2/repository"], reason: cache)
        add("Android", ["Library/Android/sdk", ".android/avd"], risk: "已安装环境", reason: environment)
        add("Homebrew", ["Library/Caches/Homebrew"], reason: cache)
        for path in ["/opt/homebrew/Cellar", "/opt/homebrew/Caskroom", "/usr/local/Cellar", "/usr/local/Caskroom"] {
            locations.append(Location(url: URL(fileURLWithPath: path), category: "Homebrew", risk: "已安装工具", reason: environment))
        }
        // Container roots can enter system privacy mediation even during an
        // openat metadata walk. Automatic scans deliberately do not enter them.
        add("Docker", [".docker/buildx/cache"], risk: "运行数据", reason: "可能包含构建状态；这里只统计本地占用，不进入 Docker 沙盒虚拟机目录，不能当作纯缓存。")
        add("Ollama", [".ollama/models"], risk: "模型数据", reason: model)
        add("Hugging Face", [".cache/huggingface"], risk: "模型数据", reason: model)
        add("LM Studio", [".cache/lm-studio/models", ".lmstudio/models"], risk: "模型数据", reason: model)
        add("编辑器", ["Library/Caches/JetBrains", "Library/Caches/Zed", "Library/Caches/dev.zed.Zed"], reason: cache)
        for editor in ["Code", "Cursor"] {
            add("编辑器", ["Cache", "CachedData", "Code Cache", "GPUCache", "CachedExtensionVSIXs"].map { "Library/Application Support/\(editor)/\($0)" }, reason: cache)
        }
        return locations
    }
}

private struct FileIdentity: Hashable {
    let device: dev_t
    let inode: ino_t
    init(_ value: stat) { device = value.st_dev; inode = value.st_ino }
}
private struct Amount {
    var bytes: Int64
    var fileCount: Int
    let directory: Bool
    var complete: Bool
}
private enum ScanIssue: String, CaseIterable {
    case excluded = "排除范围"
    case managed = "系统或搞系列管理的缓存（未查询归属或访问内容）"
    case symlink = "符号链接（未跟随）"
    case placeholder = "云端占位或尚未下载内容（未下载）"
    case mount = "其他挂载卷（未跨卷）"
    case unreadable = "权限不足或元数据无法读取"
    case special = "特殊文件"
    case changed = "扫描期间发生变化"
    case depth = "目录层级超过 64 层"
    case overflow = "分配大小超出可表示范围"
}
private final class ScanState {
    let maximumEntries: Int
    let deadline: TimeInterval
    let exclusions: [[String]]
    var visited = Set<FileIdentity>()
    var totalBytes: Int64 = 0
    var largestFiles: [StorageEntry] = []
    var issues: [ScanIssue: Int] = [:]
    var duplicates = 0
    var entriesSeen = 0
    var stopReason: String?
    var complete: Bool { issues.isEmpty && stopReason == nil }
    init(maximumEntries: Int, seconds: TimeInterval, exclusions: [URL]) {
        self.maximumEntries = maximumEntries
        deadline = ProcessInfo.processInfo.systemUptime + seconds
        self.exclusions = exclusions.filter(\.isFileURL).flatMap { [$0.pathComponents, $0.resolvingSymlinksInPath().pathComponents] }
    }
    func isExcluded(_ url: URL) -> Bool {
        let parts = url.pathComponents
        return exclusions.contains { parts.count >= $0.count && Array(parts.prefix($0.count)) == $0 }
    }
    func note(_ issue: ScanIssue) { issues[issue, default: 0] += 1 }
    func shouldStop(_ cancelled: @Sendable () -> Bool) -> Bool {
        if stopReason != nil { return true }
        if cancelled() { stopReason = "扫描已取消；仅展示已确认部分。" }
        else if entriesSeen >= maximumEntries { stopReason = "达到 \(maximumEntries) 个条目的扫描预算；仅展示已确认部分。" }
        else if ProcessInfo.processInfo.systemUptime >= deadline { stopReason = "达到时间预算；仅展示已确认部分。" }
        return stopReason != nil
    }
    func consume(_ cancelled: @Sendable () -> Bool) -> Bool {
        guard !shouldStop(cancelled) else { return false }
        entriesSeen += 1
        return true
    }
    func add(_ a: Int64, _ b: Int64) -> Int64 {
        let result = a.addingReportingOverflow(b)
        if result.overflow { note(.overflow); return Int64.max }
        return result.partialValue
    }
    func allocatedBytes(_ value: stat) -> Int64? {
        guard value.st_blocks >= 0, let bytes = StorageAnalysisPolicy.product(UInt64(value.st_blocks), 512) else {
            note(.overflow); return nil
        }
        return bytes
    }
    func enumerate(_ descriptor: Int32, cancelled: @Sendable () -> Bool, visit: (String) -> Void) {
        let copy = dup(descriptor)
        guard copy >= 0 else { note(.unreadable); return }
        guard let stream = fdopendir(copy) else { close(copy); note(.unreadable); return }
        defer { closedir(stream) }
        while !shouldStop(cancelled) {
            errno = 0
            guard let item = readdir(stream) else {
                if errno != 0 { note(errno == EDEADLK ? .placeholder : .unreadable) }
                return
            }
            let name = withUnsafePointer(to: &item.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(validatingUTF8: $0) }
            }
            guard let name else { _ = consume(cancelled); note(.unreadable); continue }
            if name == "." || name == ".." { continue }
            visit(name)
        }
    }
    func walkChild(parent: Int32, name: String, url: URL, device: dev_t, category: String, depth: Int,
                   cancelled: @Sendable () -> Bool) -> Amount? {
        guard consume(cancelled) else { return nil }
        if isExcluded(url) { note(.excluded); return nil }
        var info = stat()
        guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
            note(errno == EDEADLK ? .placeholder : .unreadable); return nil
        }
        let kind = info.st_mode & S_IFMT
        if kind == S_IFLNK { note(.symlink); return nil }
        if StorageAnalysisPolicy.isPlaceholder(flags: info.st_flags, name: name) { note(.placeholder); return nil }
        if info.st_dev != device { note(.mount); return nil }
        guard kind == S_IFDIR || kind == S_IFREG else { note(.special); return nil }
        if visited.contains(FileIdentity(info)) { duplicates += 1; return nil }
        if kind == S_IFDIR {
            guard depth < 64 else { note(.depth); return nil }
            let descriptor = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard descriptor >= 0 else { note(errno == EDEADLK ? .placeholder : .unreadable); return nil }
            defer { close(descriptor) }
            var opened = stat()
            guard fstat(descriptor, &opened) == 0, StorageAnalysisPolicy.unchanged(info, opened) else { note(.changed); return nil }
            return walkDirectory(descriptor, url: url, info: opened, device: device, category: category,
                                 depth: depth, alreadyCounted: true, cancelled: cancelled)
        }
        // Never open the file or ask a provider to download its contents.
        visited.insert(FileIdentity(info))
        guard let bytes = allocatedBytes(info) else { return nil }
        let entry = StorageEntry(id: url.path, name: name, category: category, path: url.path,
            bytes: bytes, fileCount: 1, risk: "仅分析", reason: "按本地分配块统计，未读取文件内容；不代表可清理。")
        largestFiles.append(entry)
        largestFiles.sort { $0.bytes == $1.bytes ? $0.path < $1.path : $0.bytes > $1.bytes }
        if largestFiles.count > 20 { largestFiles.removeLast() }
        return Amount(bytes: bytes, fileCount: 1, directory: false, complete: true)
    }
    func walkDirectory(_ descriptor: Int32, url: URL, info: stat, device: dev_t, category: String,
                       depth: Int, alreadyCounted: Bool = false, cancelled: @Sendable () -> Bool) -> Amount? {
        if !alreadyCounted && !consume(cancelled) { return nil }
        if visited.contains(FileIdentity(info)) { duplicates += 1; return nil }
        visited.insert(FileIdentity(info))
        let issuesBefore = issues.values.reduce(0, +)
        guard let ownBytes = allocatedBytes(info) else { return nil }
        var amount = Amount(bytes: ownBytes, fileCount: 0, directory: true, complete: true)
        enumerate(descriptor, cancelled: cancelled) { name in
            if let child = walkChild(parent: descriptor, name: name, url: url.appendingPathComponent(name),
                device: device, category: category, depth: depth + 1, cancelled: cancelled) {
                amount.bytes = add(amount.bytes, child.bytes)
                amount.fileCount += child.fileCount
            }
        }
        var after = stat()
        if fstat(descriptor, &after) != 0 || !StorageAnalysisPolicy.unchanged(info, after) { note(.changed) }
        amount.complete = stopReason == nil && issues.values.reduce(0, +) == issuesBefore
        return amount
    }
    func result(entries: [StorageEntry], root: String?) -> StorageAnalysisResult {
        var notes = ["只读取目录和文件元数据，不打开文件内容，不删除文件，也不请求云端下载。",
                     "空间按 st_blocks × 512 估算；APFS 克隆、快照或共享存储可能重复占用统计，数值不等于可释放空间。",
                     "时间预算和停止请求在系统调用之间检查；若系统权限检查或存储响应尚未返回，不能立即中断该调用。"]
        if root == nil {
            notes.append("仅检查常见默认目录；自定义环境、项目内虚拟环境和其他模型路径需另选目录分析。")
            notes.append("默认分析不进入 Library/Containers 应用沙盒，包括 Docker 虚拟机数据；这些占用未计入，请在对应软件中查看和管理。")
        }
        for issue in ScanIssue.allCases where issues[issue, default: 0] > 0 {
            notes.append("已跳过或未完整确认：\(issue.rawValue)，\(issues[issue, default: 0]) 项。")
        }
        if duplicates > 0 { notes.append("\(duplicates) 个重复 inode 已去重；硬链接占用计入首次访问的目录。") }
        if let stopReason { notes.append(stopReason) }
        if !complete { notes.append("结果不完整：总量与排名仅代表已确认部分，未访问项目不按零占用处理。") }
        return StorageAnalysisResult(entries: entries, largestFiles: largestFiles, notes: notes,
            complete: complete, date: Date(), totalBytes: totalBytes, root: root)
    }
}

private struct StorageAnalysisFailure: LocalizedError {
    let message: String
    let code: Int32?
    init(_ message: String, code: Int32? = nil) { self.message = message; self.code = code }
    var errorDescription: String? { message }
}
private enum StorageFilesystem {
    // Apple TN3150: even stat() may materialize intermediate dataless directories.
    // Thread-scoped opt-out also closes the race between a flags check and openat.
    static func withMaterializationDisabled<T>(_ body: () throws -> T) throws -> T {
        let original = getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD)
        guard original >= 0, setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES,
            IOPOL_SCOPE_THREAD, IOPOL_MATERIALIZE_DATALESS_FILES_OFF) == 0 else {
            throw StorageAnalysisFailure("无法启用禁止云端下载的扫描策略，已停止分析。")
        }
        defer { _ = setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, original) }
        return try body()
    }
    static func openDirectory(_ url: URL) throws -> Int32 {
        guard url.isFileURL, url.path.hasPrefix("/"), !url.pathComponents.contains("."), !url.pathComponents.contains("..") else { throw StorageAnalysisFailure("请选择本地目录。") }
        var descriptor = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { throw posix() }
        do {
            for name in url.pathComponents.dropFirst() {
                var info = stat()
                guard fstatat(descriptor, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw posix() }
                guard info.st_mode & S_IFMT != S_IFLNK else { throw StorageAnalysisFailure("路径包含符号链接，未跟随。", code: ELOOP) }
                guard !StorageAnalysisPolicy.isPlaceholder(flags: info.st_flags, name: name) else {
                    throw StorageAnalysisFailure("路径包含云端占位目录，未下载。", code: EDEADLK)
                }
                let next = openat(descriptor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
                guard next >= 0 else { throw posix() }
                var opened = stat()
                guard fstat(next, &opened) == 0, StorageAnalysisPolicy.unchanged(info, opened) else {
                    close(next); throw StorageAnalysisFailure("路径在访问时变化，已停止分析。")
                }
                close(descriptor); descriptor = next
            }
            return descriptor
        } catch { close(descriptor); throw error }
    }
    static func posix() -> StorageAnalysisFailure {
        let value = errno
        return StorageAnalysisFailure("目录无法安全读取：\(String(cString: strerror(value)))。", code: value)
    }
    static func issue(_ error: Error) -> ScanIssue {
        switch (error as? StorageAnalysisFailure)?.code {
        case ELOOP: return .symlink
        case EDEADLK: return .placeholder
        default: return .unreadable
        }
    }
}

enum StorageAnalysisPolicy {
    static func isManagedCache(_ name: String) -> Bool {
        let identifier = name.lowercased()
        return ["com.apple", "com.gaoseries"].contains { identifier == $0 || identifier.hasPrefix($0 + ".") }
    }
    static func isBundleLike(_ name: String) -> Bool {
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count >= 2 && parts.allSatisfy { !$0.isEmpty && $0.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
        } }
    }
    static func isPlaceholder(flags: UInt32, name: String) -> Bool {
        flags & UInt32(SF_DATALESS) != 0 || (name.hasPrefix(".") && name.hasSuffix(".icloud"))
    }
    static func product(_ count: UInt64, _ unit: UInt64) -> Int64? {
        let value = count.multipliedReportingOverflow(by: unit)
        guard !value.overflow, value.partialValue <= UInt64(Int64.max) else { return nil }
        return Int64(value.partialValue)
    }
    static func unchanged(_ before: stat, _ after: stat) -> Bool {
        before.st_dev == after.st_dev && before.st_ino == after.st_ino && before.st_mode == after.st_mode &&
            before.st_size == after.st_size && before.st_blocks == after.st_blocks &&
            before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec && before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec &&
            before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec && before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec
    }
}
