import Foundation
import CryptoKit
import Darwin

struct DuplicateDirectoryIdentity: Codable, Equatable, Sendable {
    let device: Int32
    let inode: UInt64
    let uid: UInt32
    init(device: Int32, inode: UInt64, uid: UInt32) { self.device = device; self.inode = inode; self.uid = uid }
    init(_ value: stat) { device = value.st_dev; inode = UInt64(value.st_ino); uid = value.st_uid }
}

struct DuplicateFileIdentity: Codable, Equatable, Sendable {
    let device: Int32
    let inode: UInt64
    let uid: UInt32
    let mode: UInt32
    let linkCount: UInt64
    let byteCount: UInt64
    let allocatedBytes: UInt64
    let mtimeSeconds: Int64
    let mtimeNanoseconds: Int64
    let ctimeSeconds: Int64
    let ctimeNanoseconds: Int64
    init(_ value: stat) {
        device = value.st_dev; inode = UInt64(value.st_ino); uid = value.st_uid
        mode = UInt32(value.st_mode); linkCount = UInt64(value.st_nlink)
        byteCount = UInt64(max(0, value.st_size))
        let allocation = UInt64(max(0, value.st_blocks)).multipliedReportingOverflow(by: 512)
        allocatedBytes = allocation.overflow ? UInt64.max : allocation.partialValue
        mtimeSeconds = Int64(value.st_mtimespec.tv_sec); mtimeNanoseconds = Int64(value.st_mtimespec.tv_nsec)
        ctimeSeconds = Int64(value.st_ctimespec.tv_sec); ctimeNanoseconds = Int64(value.st_ctimespec.tv_nsec)
    }
    var physicalID: String { "\(device):\(inode)" }
}

struct DuplicateFile: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let path: String
    let name: String
    let identity: DuplicateFileIdentity
    let sha256: String
    let protectionReason: String?
    var isSelected: Bool = false
}
struct DuplicateGroup: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let sha256: String
    let byteCount: UInt64
    let files: [DuplicateFile]
    let suggestedKeeperID: String
}
enum DuplicateScanPhase: String, Codable, Sendable { case enumerating, sampling, hashing, verifying, finished }
struct DuplicateScanProgress: Codable, Equatable, Sendable {
    var phase: DuplicateScanPhase = .enumerating
    var visitedEntries = 0
    var uniqueFiles = 0
    var sizeCandidates = 0
    var sampledFiles = 0
    var hashedFiles = 0
    var verifiedFiles = 0
    var contentBytesRead: UInt64 = 0
    var allocatedBytes: UInt64 = 0
    var logicalBytes: UInt64 = 0
    var skippedEntries = 0
    var elapsed: TimeInterval = 0
    var currentPath: String?
}
struct DuplicateScanResult: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let scope: String
    let scopeIdentity: DuplicateDirectoryIdentity
    let startedAt: Date
    let date: Date
    let groups: [DuplicateGroup]
    let progress: DuplicateScanProgress
    let complete: Bool
    let cancelled: Bool
    let stopReason: String?
    let notes: [String]
}
struct DuplicateAnalysisFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Descriptors remain open through the caller's transaction preflight. Pinned
/// descriptors and repeated checks reduce races, but cannot exclude a malicious
/// process with the same user's privileges between a check and a system call.
final class DuplicatePinnedFile {
    let parentDescriptor: Int32
    let descriptor: Int32
    let name: String
    let path: String
    let identity: DuplicateFileIdentity
    fileprivate let parentIdentity: DuplicateDirectoryIdentity
    fileprivate let flags: UInt32
    fileprivate init(parent: Int32, file: Int32, path: String, info: stat, parentInfo: stat) {
        parentDescriptor = parent; descriptor = file; self.path = path
        name = (path as NSString).lastPathComponent; identity = DuplicateFileIdentity(info)
        parentIdentity = DuplicateDirectoryIdentity(parentInfo); flags = info.st_flags
    }
    deinit { close(descriptor); close(parentDescriptor) }
}

enum DuplicateFileSafety {
    static func failure(_ message: String) -> DuplicateAnalysisFailure { DuplicateAnalysisFailure(message: message) }
    static func withMaterializationDisabled<T>(_ body: () throws -> T) throws -> T {
        let original = getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD)
        guard original >= 0 else { throw failure("无法读取云占位访问策略，内容分析已停止。") }
        defer { _ = setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, original) }
        guard setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, IOPOL_MATERIALIZE_DATALESS_FILES_OFF) == 0,
              getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD) == IOPOL_MATERIALIZE_DATALESS_FILES_OFF else {
            throw failure("无法禁止云占位下载，内容分析已停止。")
        }
        let result = Result { try body() }
        guard setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, original) == 0,
              getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD) == original else {
            throw failure("无法恢复云占位访问策略；本轮内容分析不作为完整结果。")
        }
        return try result.get()
    }
    static func pathParts(_ path: String) throws -> [String] {
        guard path.hasPrefix("/"), !path.contains("\0"), path.utf8.count <= 4_096 else { throw failure("必须选择长度不超过 4096 字节的本机绝对路径。") }
        let values = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !values.dropFirst().contains(where: { $0 == "." || $0 == ".." || $0.isEmpty }) else {
            throw failure("路径含相对跳转或非规范组件。")
        }
        return Array(values.dropFirst())
    }
    static func validDirectoryURL(_ url: URL) -> Bool {
        url.isFileURL && url.host.map({ $0.isEmpty || $0 == "localhost" }) != false &&
        url.user == nil && url.password == nil && url.port == nil && url.query == nil && url.fragment == nil
    }
    static func within(_ path: String, scope: String) -> Bool { path != scope && path.hasPrefix(scope + "/") }
    /// The same path policy is rechecked by recovery immediately before moving.
    /// A positive result is protection, never permission to delete something.
    static func movableReason(path: String, scope: String) -> String? {
        guard (try? pathParts(path)) != nil, (try? pathParts(scope)) != nil, within(path, scope: scope) else { return "不在本人确认的目录范围内" }
        return protectedReason(path) ?? documentProtectionReason(path)
    }
    static func documentProtectionReason(_ path: String) -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if ["Documents", "Downloads", "Desktop"].contains(where: { path == home + "/" + $0 || path.hasPrefix(home + "/" + $0 + "/") }) {
            return "个人文稿、下载或桌面资料（仅分析，不提供移动）"
        }
        let ext = (path as NSString).pathExtension.lowercased()
        if ["txt", "md", "rtf", "rtfd", "doc", "docx", "odt", "pages", "pdf", "xls", "xlsx", "ods", "numbers", "csv", "tsv", "ppt", "pptx", "odp", "key", "tex", "bib", "ris", "enw", "nbib", "psd", "ai", "sketch", "fig", "xcodeproj", "xcworkspace"].contains(ext) {
            return "个人文档或工程资料（仅分析，不提供移动）"
        }
        return nil
    }
    static func protectedReason(_ path: String) -> String? {
        let components = path.split(separator: "/").map(String.init)
        let lowered = components.map { $0.lowercased() }
        let systemRoots = ["/System", "/Library", "/Applications", "/usr", "/bin", "/sbin", "/dev", "/private/var", "/opt"]
        if systemRoots.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) { return "系统或已安装程序目录" }
        if lowered.contains(where: { $0 == "gaoseries" || $0 == "搞app" || $0.hasPrefix("com.gaoseries.") }) { return "搞系列程序或资料" }
        if lowered.contains("library") || lowered.contains(".trash") || lowered.contains(".git") || lowered.contains(".svn") { return "应用资料、恢复资料或版本库" }
        let packages = ["app", "bundle", "framework", "photoslibrary", "photolibrary", "musiclibrary", "pvm", "vmwarevm", "vmbundle", "sparsebundle", "sparseimage", "band"]
        if lowered.contains(where: { packages.contains(($0 as NSString).pathExtension) }) { return "应用包、资料库或虚拟机" }
        let ext = ((lowered.last ?? "") as NSString).pathExtension
        if ["sqlite", "sqlite3", "db", "db3", "keychain", "keychain-db", "wal", "shm"].contains(ext) ||
            lowered.last.map({ $0.hasSuffix("-wal") || $0.hasSuffix("-shm") }) == true { return "业务数据库或凭据" }
        return nil
    }
    static func directory(_ path: String, read: Bool = false) throws -> Int32 {
        let pieces = try pathParts(path)
        var current = open("/", O_SEARCH | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard current >= 0 else { throw failure("无法固定目录根。") }
        do {
            for (index, piece) in pieces.enumerated() {
                var before = stat()
                guard fstatat(current, piece, &before, AT_SYMLINK_NOFOLLOW) == 0,
                      before.st_mode & S_IFMT == S_IFDIR, before.st_flags & UInt32(SF_DATALESS) == 0 else {
                    throw failure("目录路径含链接、云占位或不可读取对象。")
                }
                let flags = read && index == pieces.count - 1 ? O_RDONLY | O_DIRECTORY : O_SEARCH | O_DIRECTORY
                let next = openat(current, piece, flags | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw failure("目录权限不足，无法安全打开。") }
                var after = stat()
                guard fstat(next, &after) == 0, DuplicateDirectoryIdentity(before) == DuplicateDirectoryIdentity(after),
                      after.st_flags & UInt32(SF_DATALESS) == 0 else { close(next); throw failure("目录打开时身份变化。") }
                close(current); current = next
            }
            return current
        } catch { close(current); throw error }
    }
    static func info(_ descriptor: Int32) throws -> stat {
        var value = stat()
        guard fstat(descriptor, &value) == 0 else { throw failure("无法核验文件身份。") }
        return value
    }
    static func sameFile(_ a: DuplicateFileIdentity, _ b: DuplicateFileIdentity, allowRenamedTimes: Bool = false) -> Bool {
        a.device == b.device && a.inode == b.inode && a.uid == b.uid && a.mode == b.mode && a.linkCount == b.linkCount &&
        a.byteCount == b.byteCount && a.allocatedBytes == b.allocatedBytes && a.mtimeSeconds == b.mtimeSeconds && a.mtimeNanoseconds == b.mtimeNanoseconds &&
        (allowRenamedTimes || (a.ctimeSeconds == b.ctimeSeconds && a.ctimeNanoseconds == b.ctimeNanoseconds))
    }
    static func openPinned(path: String, expected: DuplicateFileIdentity? = nil, allowRenamedTimes: Bool = false) throws -> DuplicatePinnedFile {
        _ = try pathParts(path)
        let parentPath = (path as NSString).deletingLastPathComponent
        let parent = try directory(parentPath)
        var file: Int32 = -1
        do {
            let parentInfo = try info(parent)
            let name = (path as NSString).lastPathComponent
            var before = stat()
            guard fstatat(parent, name, &before, AT_SYMLINK_NOFOLLOW) == 0,
                  before.st_mode & S_IFMT == S_IFREG, before.st_uid == getuid(), before.st_size >= 0,
                  before.st_mode & S_IRUSR != 0, before.st_flags & UInt32(SF_DATALESS) == 0 else {
                throw failure("文件不是本用户可读取的普通本地文件，或是链接、云占位内容。")
            }
            if let expected, !sameFile(expected, DuplicateFileIdentity(before), allowRenamedTimes: allowRenamedTimes) { throw failure("文件身份或内容元数据已变化。") }
            file = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard file >= 0 else { throw failure("文件内容不可读取。") }
            let opened = try info(file)
            guard sameFile(DuplicateFileIdentity(before), DuplicateFileIdentity(opened)), before.st_flags == opened.st_flags else { throw failure("文件打开时发生变化。") }
            return DuplicatePinnedFile(parent: parent, file: file, path: path, info: opened, parentInfo: parentInfo)
        } catch { if file >= 0 { close(file) }; close(parent); throw error }
    }
    static func validatePinned(_ file: DuplicatePinnedFile) throws {
        let opened = try info(file.descriptor)
        let parent = try info(file.parentDescriptor)
        var named = stat()
        guard DuplicateDirectoryIdentity(parent) == file.parentIdentity,
              fstatat(file.parentDescriptor, file.name, &named, AT_SYMLINK_NOFOLLOW) == 0,
              sameFile(file.identity, DuplicateFileIdentity(opened)), sameFile(file.identity, DuplicateFileIdentity(named)),
              opened.st_flags == file.flags, named.st_flags == file.flags, opened.st_flags & UInt32(SF_DATALESS) == 0 else { throw failure("文件或父目录在复核时发生变化。") }
        let current = try directory((file.path as NSString).deletingLastPathComponent)
        defer { close(current) }
        guard DuplicateDirectoryIdentity(try info(current)) == file.parentIdentity else { throw failure("文件父目录路径已被替换。") }
    }
    static func fullDigest(_ file: DuplicatePinnedFile, cancelled: @Sendable () -> Bool = { false }) throws -> String {
        try withMaterializationDisabled {
            guard !cancelled() else { throw failure("已取消内容复核。") }
            try validatePinned(file)
            var digest = SHA256(), offset: UInt64 = 0
            var buffer = [UInt8](repeating: 0, count: 1_048_576)
            while offset < file.identity.byteCount {
                if cancelled() { throw failure("已取消内容复核。") }
                let requested = Int(min(UInt64(buffer.count), file.identity.byteCount - offset))
                let count = pread(file.descriptor, &buffer, requested, off_t(offset))
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw failure("文件内容读取不完整。") }
                digest.update(data: Data(buffer.prefix(count))); offset += UInt64(count)
            }
            guard !cancelled() else { throw failure("已取消内容复核。") }
            try validatePinned(file)
            return digest.finalize().map { String(format: "%02x", $0) }.joined()
        }
    }
    static func withVerifiedPair<T>(file: DuplicateFile, keeper: DuplicateFile, scope: String,
                                    scopeIdentity: DuplicateDirectoryIdentity, cancelled: @Sendable () -> Bool = { false },
                                    body: (DuplicatePinnedFile, DuplicatePinnedFile) throws -> T) throws -> T {
        try withMaterializationDisabled {
            guard !cancelled() else { throw failure("已取消内容复核，原文件未移动。") }
            guard movableReason(path: file.path, scope: scope) == nil, file.protectionReason == nil,
                  file.identity.linkCount == 1, file.identity.physicalID != keeper.identity.physicalID,
                  within(keeper.path, scope: scope), file.identity.byteCount == keeper.identity.byteCount,
                  file.sha256 == keeper.sha256 else { throw failure("候选范围、保护规则或保留项不符合要求。") }
            let root = try directory(scope); defer { close(root) }
            guard DuplicateDirectoryIdentity(try info(root)) == scopeIdentity else { throw failure("本人确认的目录已被替换。") }
            let candidate = try openPinned(path: file.path, expected: file.identity)
            let retained = try openPinned(path: keeper.path, expected: keeper.identity)
            guard candidate.identity.device == scopeIdentity.device, retained.identity.device == scopeIdentity.device else { throw failure("不跨卷处理重复文件。") }
            var digest = SHA256(), offset: UInt64 = 0
            var a = [UInt8](repeating: 0, count: 1_048_576), b = a
            while offset < candidate.identity.byteCount {
                if cancelled() { throw failure("已取消内容复核，原文件未移动。") }
                let requested = Int(min(UInt64(a.count), candidate.identity.byteCount - offset))
                let countA = pread(candidate.descriptor, &a, requested, off_t(offset))
                if countA < 0 && errno == EINTR { continue }
                let countB = pread(retained.descriptor, &b, requested, off_t(offset))
                if countB < 0 && errno == EINTR { continue }
                guard countA == requested, countB == requested, a.prefix(requested).elementsEqual(b.prefix(requested)) else { throw failure("候选与保留项的实际内容不再完全相同。") }
                digest.update(data: Data(a.prefix(requested))); offset += UInt64(requested)
            }
            let actual = digest.finalize().map { String(format: "%02x", $0) }.joined()
            guard actual == file.sha256 else { throw failure("文件摘要已变化，原文件未移动。") }
            try validatePinned(candidate); try validatePinned(retained)
            let currentRoot = try directory(scope); defer { close(currentRoot) }
            guard DuplicateDirectoryIdentity(try info(currentRoot)) == scopeIdentity else { throw failure("确认范围在提交前发生变化。") }
            guard !cancelled() else { throw failure("已取消内容复核，原文件未移动。") }
            return try body(candidate, retained)
        }
    }
}

/// Explicit content analysis only. No Trash, write, move or permanent-delete API.
/// Budgets and cancellation are cooperative between filesystem system calls.
final class DuplicateAnalyzer: @unchecked Sendable {
    private let maximumEntries: Int, maximumFiles: Int, maximumDepth: Int, segmentBytes: Int
    private let timeBudget: TimeInterval, maximumContentBytes: UInt64
    init(maximumEntries: Int = 100_000, maximumFiles: Int = 20_000, maximumDepth: Int = 64,
         timeBudget: TimeInterval = 60, maximumContentBytes: UInt64 = 4 * 1_024 * 1_024 * 1_024, segmentBytes: Int = 65_536) {
        self.maximumEntries = min(100_000, max(0, maximumEntries)); self.maximumFiles = min(20_000, max(0, maximumFiles))
        self.maximumDepth = min(64, max(0, maximumDepth)); self.segmentBytes = min(262_144, max(1_024, segmentBytes))
        self.timeBudget = timeBudget.isFinite ? max(0, min(600, timeBudget)) : 60
        self.maximumContentBytes = min(64 * 1_024 * 1_024 * 1_024, maximumContentBytes)
    }
    func scan(directory url: URL, expectedIdentity: DuplicateDirectoryIdentity? = nil,
              progress: @escaping @Sendable (DuplicateScanProgress) -> Void = { _ in },
              cancelled: @Sendable () -> Bool = { false }) throws -> DuplicateScanResult {
        guard DuplicateFileSafety.validDirectoryURL(url), (try? DuplicateFileSafety.pathParts(url.path)) != nil else { throw DuplicateFileSafety.failure("必须选择本机目录。") }
        if let reason = DuplicateFileSafety.protectedReason(url.path) { throw DuplicateFileSafety.failure("此目录受保护：\(reason)。") }
        return try DuplicateFileSafety.withMaterializationDisabled {
            let root = try DuplicateFileSafety.directory(url.path, read: true); defer { close(root) }
            let original = try DuplicateFileSafety.info(root), rootIdentity = DuplicateDirectoryIdentity(original)
            guard original.st_uid == getuid(), original.st_mode & S_IFMT == S_IFDIR,
                  original.st_mode & S_IRUSR != 0, original.st_mode & S_IXUSR != 0 else { throw DuplicateFileSafety.failure("只分析本用户拥有且可读取的明确目录。") }
            if let expectedIdentity, expectedIdentity != rootIdentity { throw DuplicateFileSafety.failure("已确认目录的身份发生变化。") }
            let state = DuplicateScanState(scope: url.path, root: rootIdentity, maximumEntries: maximumEntries,
                maximumFiles: maximumFiles, maximumDepth: maximumDepth, seconds: timeBudget,
                maximumContentBytes: maximumContentBytes, segmentBytes: segmentBytes, progress: progress)
            state.walk(root, path: url.path, depth: 0, cancelled: cancelled)
            let groups = state.finalizeGroups(state.compare(cancelled: cancelled), cancelled: cancelled)
            do {
                let current = try DuplicateFileSafety.directory(url.path); defer { close(current) }
                guard DuplicateDirectoryIdentity(try DuplicateFileSafety.info(current)) == rootIdentity,
                      DuplicateScanState.directoryUnchanged(original, try DuplicateFileSafety.info(root)) else { throw DuplicateFileSafety.failure("范围目录在分析期间发生变化") }
            } catch { state.note("范围目录在分析期间发生变化，结果不完整") }
            return state.result(groups: groups)
        }
    }
}

private struct DuplicateObservedFile {
    let path: String
    let identity: DuplicateFileIdentity
    let protectionReason: String?
}
private final class DuplicateScanState {
    let scope: String, root: DuplicateDirectoryIdentity, maximumEntries: Int, maximumFiles: Int, maximumDepth: Int
    let maximumContentBytes: UInt64, segmentBytes: Int, seconds: TimeInterval
    let startedAt = Date(), clock = ProcessInfo.processInfo.systemUptime
    let handler: @Sendable (DuplicateScanProgress) -> Void
    var progress = DuplicateScanProgress(), files: [DuplicateObservedFile] = [], visited = Set<String>()
    var directories: [(String, stat)] = []
    var notes: [String: Int] = [:], stopped: String?, cancelled = false, incomplete = false
    init(scope: String, root: DuplicateDirectoryIdentity, maximumEntries: Int, maximumFiles: Int, maximumDepth: Int,
         seconds: TimeInterval, maximumContentBytes: UInt64, segmentBytes: Int, progress: @escaping @Sendable (DuplicateScanProgress) -> Void) {
        self.scope = scope; self.root = root; self.maximumEntries = maximumEntries; self.maximumFiles = maximumFiles
        self.maximumDepth = maximumDepth; self.seconds = seconds; self.maximumContentBytes = maximumContentBytes
        self.segmentBytes = segmentBytes; handler = progress
    }
    func emit(_ phase: DuplicateScanPhase? = nil, path: String? = nil) {
        if let phase { progress.phase = phase }; progress.currentPath = path
        progress.elapsed = ProcessInfo.processInfo.systemUptime - clock; handler(progress)
    }
    func note(_ value: String, incomplete: Bool = true) {
        notes[value, default: 0] += 1; progress.skippedEntries += 1
        if incomplete { self.incomplete = true }
    }
    func add(_ a: UInt64, _ b: UInt64) -> UInt64 {
        let result = a.addingReportingOverflow(b)
        if result.overflow { note("文件大小汇总超出表示范围"); return UInt64.max }
        return result.partialValue
    }
    func stop(_ reason: String) { if stopped == nil { stopped = reason } }
    func check(_ cancel: @Sendable () -> Bool) -> Bool {
        if cancel() { cancelled = true; stop("用户取消；仅保留已确认的部分结果") }
        if ProcessInfo.processInfo.systemUptime - clock >= seconds { stop("达到内容分析时间预算；结果不完整") }
        return stopped != nil
    }
    static func directoryUnchanged(_ a: stat, _ b: stat) -> Bool {
        DuplicateDirectoryIdentity(a) == DuplicateDirectoryIdentity(b) && a.st_mode == b.st_mode && a.st_flags == b.st_flags &&
        a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec &&
        a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec
    }
    func walk(_ descriptor: Int32, path: String, depth: Int, cancelled: @Sendable () -> Bool) {
        guard !check(cancelled) else { return }
        let before: stat
        do { before = try DuplicateFileSafety.info(descriptor) } catch { note("目录无法读取"); return }
        if depth > maximumDepth { note("目录深度超过上限"); return }
        guard directories.count < 20_000 else { stop("达到目录快照预算；结果不完整"); return }
        directories.append((path, before))
        let readable = openat(descriptor, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard readable >= 0, let iterator = fdopendir(readable) else { if readable >= 0 { close(readable) }; note("目录枚举权限不足"); return }
        defer { closedir(iterator) }
        while !check(cancelled) {
            errno = 0
            guard let entry = readdir(iterator) else { if errno != 0 { note("目录枚举不完整") }; break }
            let name = withUnsafePointer(to: &entry.pointee.d_name) { $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) } }
            if name == "." || name == ".." { continue }
            guard progress.visitedEntries < maximumEntries else { stop("达到目录条目预算；结果不完整"); break }
            progress.visitedEntries += 1
            let childPath = path + "/" + name
            emit(.enumerating, path: childPath)
            guard childPath.utf8.count <= 4_096 else { note("路径超过 4096 字节（未读取内容）"); continue }
            if let _ = DuplicateFileSafety.protectedReason(childPath) { note("受保护的程序、业务资料或版本库（未读取内容）"); continue }
            var info = stat()
            guard fstatat(descriptor, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { note("权限不足或无法读取元数据"); continue }
            guard info.st_flags & UInt32(SF_DATALESS) == 0 else { note("云占位内容（未下载）"); continue }
            guard info.st_dev == root.device else { note("其他卷（未跨卷）"); continue }
            guard info.st_uid == getuid() else { note("非本用户拥有的项目"); continue }
            let kind = info.st_mode & S_IFMT
            if kind == S_IFDIR {
                guard info.st_mode & S_IRUSR != 0, info.st_mode & S_IXUSR != 0 else { note("目录权限不足"); continue }
                let child = openat(descriptor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard child >= 0 else { note("目录无法安全打开"); continue }
                do {
                    let opened = try DuplicateFileSafety.info(child)
                    if Self.directoryUnchanged(info, opened) { walk(child, path: childPath, depth: depth + 1, cancelled: cancelled) }
                    else { note("目录打开时发生变化") }
                } catch { note("目录身份无法核验") }
                close(child)
            } else if kind == S_IFREG {
                guard info.st_size >= 0, info.st_mode & S_IRUSR != 0 else { note("文件内容权限不足"); continue }
                let identity = DuplicateFileIdentity(info)
                if !visited.insert(identity.physicalID).inserted { note("硬链接或同一 inode（只计一份实物）", incomplete: false); continue }
                guard files.count < maximumFiles else { stop("达到文件候选预算；结果不完整"); break }
                files.append(DuplicateObservedFile(path: childPath, identity: identity,
                    protectionReason: identity.linkCount == 1 ? DuplicateFileSafety.documentProtectionReason(childPath) : "存在其他硬链接；仅可作为保留项，不计算可回收副本"))
                progress.uniqueFiles = files.count
                progress.allocatedBytes = add(progress.allocatedBytes, identity.allocatedBytes)
                progress.logicalBytes = add(progress.logicalBytes, identity.byteCount)
            } else { note(kind == S_IFLNK ? "符号链接（未跟随）" : "特殊文件（未读取）") }
        }
        if let after = try? DuplicateFileSafety.info(descriptor), !Self.directoryUnchanged(before, after) { note("目录在枚举期间发生变化") }
    }
    func reserve(_ count: UInt64) throws {
        guard count <= maximumContentBytes - min(maximumContentBytes, progress.contentBytesRead) else { stop("达到文件内容读取预算；结果不完整"); throw DuplicateFileSafety.failure("达到内容读取预算") }
    }
    func digest(_ file: DuplicateObservedFile, segmented: Bool, cancelled: @Sendable () -> Bool) throws -> String {
        let opened = try DuplicateFileSafety.openPinned(path: file.path, expected: file.identity)
        try DuplicateFileSafety.validatePinned(opened)
        var hash = SHA256(), buffer = [UInt8](repeating: 0, count: segmented ? segmentBytes : 1_048_576)
        let size = file.identity.byteCount
        let ranges: [(UInt64, UInt64)]
        if segmented {
            let segment = min(UInt64(segmentBytes), size)
            let starts = Set([UInt64(0), size > segment ? (size - segment) / 2 : 0, size > segment ? size - segment : 0]).sorted()
            ranges = starts.map { ($0, min(segment, size - $0)) }
        } else { ranges = [(0, size)] }
        for (start, length) in ranges {
            var offset = start
            while offset < start + length {
                if check(cancelled) { throw DuplicateFileSafety.failure("内容分析未完成") }
                let requested = Int(min(UInt64(buffer.count), start + length - offset))
                try reserve(UInt64(requested))
                let amount = pread(opened.descriptor, &buffer, requested, off_t(offset))
                if amount < 0 && errno == EINTR { continue }
                guard amount > 0 else { throw DuplicateFileSafety.failure("文件读取失败或提前结束") }
                progress.contentBytesRead += UInt64(amount)
                hash.update(data: Data(buffer.prefix(amount))); offset += UInt64(amount)
                emit(path: file.path)
            }
        }
        try DuplicateFileSafety.validatePinned(opened)
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    func compare(cancelled: @Sendable () -> Bool) -> [DuplicateGroup] {
        guard !check(cancelled) else { return [] }
        let sized = Dictionary(grouping: files, by: { $0.identity.byteCount }).filter { $0.value.count > 1 }
        progress.sizeCandidates = sized.values.reduce(0) { $0 + $1.count }
        var segments: [String: [DuplicateObservedFile]] = [:]
        emit(.sampling)
        for size in sized.keys.sorted() {
            for file in sized[size]!.sorted(by: { $0.path < $1.path }) {
                if check(cancelled) { break }
                do { let sum = try digest(file, segmented: true, cancelled: cancelled); segments["\(size):\(sum)", default: []].append(file); progress.sampledFiles += 1 }
                catch { if stopped == nil { note("分段读取时文件变化或不可读取") } }
            }
            if stopped != nil { break }
        }
        var hashed: [String: [DuplicateFile]] = [:]
        emit(.hashing)
        for key in segments.keys.sorted() where segments[key]!.count > 1 {
            for file in segments[key]! {
                if check(cancelled) { break }
                do {
                    let sum = try digest(file, segmented: false, cancelled: cancelled)
                    hashed["\(file.identity.byteCount):\(sum)", default: []].append(DuplicateFile(id: file.identity.physicalID,
                        path: file.path, name: (file.path as NSString).lastPathComponent, identity: file.identity,
                        sha256: sum, protectionReason: file.protectionReason))
                    progress.hashedFiles += 1
                } catch { if stopped == nil { note("完整摘要读取时文件变化或不可读取") } }
            }
            if stopped != nil { break }
        }
        emit(.verifying)
        var output: [DuplicateGroup] = []
        for key in hashed.keys.sorted() where hashed[key]!.count > 1 {
            if check(cancelled) { break }
            var verified: [DuplicateFile] = []
            for file in hashed[key]! {
                if check(cancelled) { break }
                do { let fd = try DuplicateFileSafety.openPinned(path: file.path, expected: file.identity); try DuplicateFileSafety.validatePinned(fd); verified.append(file); progress.verifiedFiles += 1 }
                catch { note("摘要完成后文件或父目录变化，已排除") }
            }
            if verified.count > 1 {
                verified.sort { $0.path < $1.path }
                let keeper = verified.first(where: { $0.protectionReason != nil }) ?? verified[0]
                output.append(DuplicateGroup(id: key, sha256: verified[0].sha256, byteCount: verified[0].identity.byteCount,
                    files: verified, suggestedKeeperID: keeper.id))
            }
        }
        return output
    }
    func finalizeGroups(_ groups: [DuplicateGroup], cancelled: @Sendable () -> Bool) -> [DuplicateGroup] {
        // Recheck even files rejected by the initial size filter: an initially
        // unique file may have changed into another size while hashing ran.
        var changed = Set<String>()
        for file in files {
            if check(cancelled) { break }
            do { let pinned = try DuplicateFileSafety.openPinned(path: file.path, expected: file.identity); try DuplicateFileSafety.validatePinned(pinned) }
            catch { changed.insert(file.identity.physicalID); note("结束复核发现文件或父目录变化，范围不完整") }
        }
        for (path, expected) in directories {
            if check(cancelled) { break }
            do {
                let descriptor = try DuplicateFileSafety.directory(path); defer { close(descriptor) }
                guard Self.directoryUnchanged(expected, try DuplicateFileSafety.info(descriptor)) else { throw DuplicateFileSafety.failure("目录发生变化") }
            } catch { note("结束复核发现子目录变化，范围不完整") }
        }
        return groups.compactMap { group in
            let retained = group.files.filter { !changed.contains($0.id) }
            guard retained.count > 1 else { return nil }
            let keeper = retained.first(where: { $0.protectionReason != nil }) ?? retained[0]
            return DuplicateGroup(id: group.id, sha256: group.sha256, byteCount: group.byteCount, files: retained, suggestedKeeperID: keeper.id)
        }
    }
    func result(groups: [DuplicateGroup]) -> DuplicateScanResult {
        emit(.finished)
        var messages = notes.keys.sorted().map { "\($0)：\(notes[$0]!) 项" }
        messages.append("仅将独立实物的完整 SHA-256 相同结果归组；操作前仍须逐字节复核。相似图片不在本引擎能力内。")
        messages.append("逻辑大小与本地分配空间不等于可释放磁盘空间；APFS 克隆、硬链接及稀疏文件会影响实际回收。")
        return DuplicateScanResult(id: UUID(), scope: scope, scopeIdentity: root, startedAt: startedAt, date: Date(),
            groups: groups, progress: progress, complete: stopped == nil && !incomplete, cancelled: cancelled,
            stopReason: stopped, notes: messages)
    }
}
