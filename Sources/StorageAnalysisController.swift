import AppKit
import Combine
import Darwin

struct StorageScanSnapshot: Codable, Identifiable {
    let id: String
    let date: Date
    let totalBytes: Int64
    let scope: String
    let complete: Bool
}

private struct StorageAnalysisState: Codable {
    var version = 1
    var exclusions: [String] = []
    var history: [StorageScanSnapshot] = []
}

private final class StorageAnalysisCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    func cancel() { lock.lock(); stopped = true; lock.unlock() }
}

/// Scans only local metadata. Analysis never grants a candidate deletion rights.
@MainActor final class StorageAnalysisController: ObservableObject {
    @Published private(set) var result: StorageAnalysisResult?
    @Published private(set) var isBusy = false
    @Published private(set) var progress: ScanProgress?
    @Published private(set) var operationID: UUID?
    @Published private(set) var lastCompletedOperationID: UUID?
    @Published private(set) var completion: StorageScanCompletion?
    /// Delivers this operation's immutable result while it still owns the busy
    /// slot, so a subsequent scan cannot replace a handoff's completion state.
    var onScanCompleted: ((UUID, StorageAnalysisResult?, StorageScanCompletion) -> Void)?
    @Published private(set) var status: String?
    @Published private(set) var exclusions: [URL] = []
    @Published private(set) var capacity: DiskCapacity?
    @Published private(set) var history: [StorageScanSnapshot] = []
    var canExport: Bool { result != nil && !isBusy }
    var canSavePreferences: Bool { stateWritable }
    @Published private(set) var persistenceWarning: String?
    private let analyzer = StorageAnalyzer()
    private let dataDirectory: URL
    private let stateURL: URL
    private let stateMarkerURL: URL
    private var stateWritable = true
    private var savedState: Data?
    private var cancellation: StorageAnalysisCancellation?
    private var operation: Task<Void, Never>?
    private var scanID: UUID?

    init(dataDirectory: URL) {
        self.dataDirectory = dataDirectory
        stateURL = dataDirectory.appendingPathComponent("Storage/analysis-state.json")
        stateMarkerURL = dataDirectory.appendingPathComponent("Storage.initialized")
        do {
            try validateStatePath()
            let priorMarker = try readPrivateStateFile(stateMarkerURL, maximumBytes: 64)
            guard priorMarker == nil || priorMarker == Data("GaoJiLing.StorageAnalysis.1\n".utf8) else { throw invalid("存储分析初始化记录无效") }
            let storedBytes = try readPrivateStateFile(stateURL)
            guard priorMarker == nil || storedBytes != nil else { throw invalid("原存储分析记录缺失，不能作为首次启动覆盖") }
            if let bytes = storedBytes {
                let state = try JSONDecoder().decode(StorageAnalysisState.self, from: bytes)
                guard state.version == 1, state.exclusions.count <= 256, state.history.count <= 30,
                      state.exclusions.allSatisfy({ Self.validStoredPath($0) }),
                      Set(state.history.map(\.id)).count == state.history.count,
                      state.history.allSatisfy({ !$0.id.isEmpty && $0.id.utf8.count <= 256 && $0.totalBytes >= 0 && $0.date.timeIntervalSince1970.isFinite &&
                          ($0.scope == "开发环境" || Self.validStoredPath($0.scope)) }) else { throw invalid("存储分析记录格式无效") }
                exclusions = state.exclusions.map { URL(fileURLWithPath: $0, isDirectory: true) }
                history = Array(state.history.suffix(30))
                savedState = bytes
                if priorMarker == nil { try ensureStateMarker() }
            }
        } catch {
            stateWritable = false
            persistenceWarning = "原存储分析设置或历史缺失、不可读或格式无效，已保留原资料；新扫描仍可使用，但不会保存历史或修改排除规则。"
            status = persistenceWarning
        }
        refreshCapacity()
    }

    func scanEnvironments() { scan(directory: nil) }
    func analyzeDirectory(_ directory: URL, expectedIdentity: StorageDirectoryIdentity? = nil) { scan(directory: directory, expectedIdentity: expectedIdentity) }
    func chooseDirectory() {
        guard !isBusy else { return }
        let panel = NSOpenPanel()
        panel.title = "选择要分析的目录"
        panel.message = "仅统计本地目录与文件的占用；不会清理此目录或读取文件内容。"
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        analyzeDirectory(directory)
    }
    private func scan(directory: URL?, expectedIdentity: StorageDirectoryIdentity? = nil) {
        guard !isBusy else { return }
        isBusy = true; result = nil; progress = nil
        let id = UUID(); scanID = id; operationID = id
        lastCompletedOperationID = nil; completion = nil
        let token = StorageAnalysisCancellation(); cancellation = token
        status = directory == nil ? "正在分析开发工具占用…" : "正在分析所选目录的本地占用…"
        let analyzer = analyzer; let exclusions = exclusions
        let update: @Sendable (ScanProgress) -> Void = { [weak self] value in
            Task { @MainActor [weak self] in
                guard let self, self.scanID == id, self.isBusy else { return }
                self.progress = value
            }
        }
        operation = Task { [weak self] in
            do {
                var value = try await Task.detached(priority: .utility) {
                    if let directory { return try analyzer.analyze(directory: directory, expectedIdentity: expectedIdentity, exclusions: exclusions, progress: update, cancelled: { token.cancelled }) }
                    return try analyzer.scanEnvironments(exclusions: exclusions, progress: update, cancelled: { token.cancelled })
                }.value
                guard let self else { return }
                if token.cancelled {
                    value.cancelled = true; value.complete = false
                    value.session?.cancelled = true; value.session?.complete = false
                }
                self.lastCompletedOperationID = id
                let outcome: StorageScanCompletion = value.cancelled ? .cancelled : (value.complete ? .completed : .partial)
                self.completion = outcome
                self.result = value
                self.progress = value.session?.progress
                self.status = value.cancelled ? "分析已取消；保留已读取部分，未读取项目不按零计算。" : (value.complete ? "分析完成，占用为本地已分配空间估算。" : "分析未完整完成；下列占用仅为已读取部分，请查看跳过说明。")
                self.history.append(StorageScanSnapshot(id: UUID().uuidString, date: value.date, totalBytes: value.totalBytes,
                                                        scope: value.root ?? "开发环境", complete: value.complete))
                self.history = Array(self.history.suffix(30))
                self.saveState()
                self.onScanCompleted?(id, value, outcome)
                self.finish()
            } catch {
                guard let self else { return }
                let outcome: StorageScanCompletion = token.cancelled ? .cancelled : .failed
                self.lastCompletedOperationID = id
                self.completion = outcome
                self.status = "分析未完成：\(error.localizedDescription)。未清理任何文件。"
                self.onScanCompleted?(id, nil, outcome)
                self.finish()
            }
        }
    }
    func cancel() { cancellation?.cancel(); if isBusy { status = "正在停止分析…" } }
    private func finish() { scanID = nil; cancellation = nil; operation = nil; refreshCapacity(); isBusy = false }
    func addExclusion() {
        guard !isBusy, stateWritable else { return }
        let panel = NSOpenPanel()
        panel.title = "添加存储分析排除目录"
        panel.message = "排除所选目录及其子目录；规则只影响存储分析。清理页面始终使用独立的保护规则。"
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        let additions = panel.urls.filter { !exclusions.contains($0) }
        guard exclusions.count + additions.count <= 256 else { status = "排除目录最多保留 256 项，请先移除不再需要的规则。"; return }
        for url in additions { exclusions.append(url) }
        saveState(); result = nil
    }
    func removeExclusion(_ url: URL) {
        guard !isBusy, stateWritable else { return }
        exclusions.removeAll { $0.path == url.path }; saveState(); result = nil
    }
    func reveal(_ entry: StorageEntry) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: entry.path)]) }
    func revealPath(_ path: String) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
    func refreshCapacity() { capacity = DiskCapacity.snapshot(for: FileManager.default.homeDirectoryForCurrentUser) }
    func exportReport() {
        guard let result, canExport else { return }
        let panel = NSSavePanel()
        panel.title = "导出本机存储分析报告"
        panel.message = "报告包含实际文件路径与名称，请按自己的分享范围保管。"
        panel.nameFieldStringValue = "搞机灵-存储分析.csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let resolved = url.resolvingSymlinksInPath().path
            let protected = dataDirectory.resolvingSymlinksInPath().path
            guard resolved != protected, !resolved.hasPrefix(protected + "/"),
                  !(result.entries + result.largestFiles).contains(where: {
                      let path = URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().path
                      return resolved == path || resolved.hasPrefix(path + "/")
                  }), result.root.map({ root in
                      let path = URL(fileURLWithPath: root).resolvingSymlinksInPath().path
                      return resolved != path && !resolved.hasPrefix(path + "/")
                  }) ?? true else {
                throw invalid("不能用分析报告覆盖资料或被分析的项目")
            }
            func csv(_ text: String) -> String {
                MonitorCSV.field(text)
            }
            var lines = ["类型,名称,分类,路径,已分配字节估算,文件数,处理建议,说明,扫描时间,是否完整,逻辑字节,设备,inode,跳过原因"]
            let date = ISO8601DateFormatter().string(from: result.date)
            for (kind, entries) in [("占用", result.entries), ("大型文件", result.largestFiles)] {
                for entry in entries {
                    lines.append([kind, entry.name, entry.category, entry.path, String(entry.bytes), String(entry.fileCount), entry.risk,
                                  entry.reason, date, result.complete ? "是" : "否", "", "", "", ""].map(csv).joined(separator: ","))
                }
            }
            if let session = result.session {
                for node in session.nodes.values.sorted(by: { $0.path < $1.path }) {
                    lines.append(["目录树", node.name, node.category, node.path,
                                  node.allocatedBytes.map(String.init) ?? "", String(node.fileCount), "仅分析", "", date,
                                  node.complete ? "是" : "否", node.logicalBytes.map(String.init) ?? "",
                                  node.device.map(String.init) ?? "", node.inode.map(String.init) ?? "",
                                  node.skipReasons.joined(separator: "；")].map(csv).joined(separator: ","))
                }
            }
            for note in result.notes { lines.append(["跳过说明", note, "", "", "", "", "", "", date, result.complete ? "是" : "否", "", "", "", ""].map(csv).joined(separator: ",")) }
            try Data(("\u{FEFF}" + lines.joined(separator: "\r\n") + "\r\n").utf8).write(to: url, options: .atomic)
            status = "存储分析报告已导出；报告只保存在所选本地位置。"
        } catch { status = "报告未导出：\(error.localizedDescription)" }
    }
    private func invalid(_ message: String) -> Error { NSError(domain: "GaoJiLing.StorageAnalysis", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    private func pathExists(_ url: URL) throws -> Bool {
        var info = stat()
        if url.path.withCString({ lstat($0, &info) }) == 0 { return true }
        let code = errno
        guard code == ENOENT else { throw invalid("存储分析资料无法读取，不能当作空资料") }
        return false
    }
    private static func validStoredPath(_ path: String) -> Bool {
        path.hasPrefix("/") && path.utf8.count <= 4096 && !path.utf8.contains(0) &&
            !path.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0 == "." || $0 == ".." })
    }
    private func readPrivateStateFile(_ url: URL, maximumBytes: Int = 2 * 1_024 * 1_024) throws -> Data? {
        guard try pathExists(url) else { return nil }
        let fd = url.path.withCString { open($0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC) }
        guard fd >= 0 else { throw invalid("存储分析记录不可读取") }
        defer { close(fd) }
        var before = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG, before.st_nlink == 1,
              before.st_uid == getuid(), before.st_size >= 0, before.st_size <= maximumBytes else {
            throw invalid("存储分析记录不是安全的有界普通文件")
        }
        var bytes = Data(), buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0, bytes.count + count <= maximumBytes else { throw invalid("存储分析记录读取失败或超过预算") }
            if count == 0 { break }
            bytes.append(contentsOf: buffer.prefix(count))
        }
        var after = stat(), named = stat()
        guard fstat(fd, &after) == 0, lstat(url.path, &named) == 0,
              StorageAnalysisPolicy.unchanged(before, after), StorageAnalysisPolicy.unchanged(after, named) else {
            throw invalid("存储分析记录读取期间被替换，已保留原资料")
        }
        return bytes
    }
    private func ensureStateMarker() throws {
        let marker = Data("GaoJiLing.StorageAnalysis.1\n".utf8)
        if let previous = try readPrivateStateFile(stateMarkerURL, maximumBytes: 64) {
            guard previous == marker else { throw invalid("存储分析初始化记录被修改") }
            return
        }
        let fd = stateMarkerURL.path.withCString { open($0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600) }
        guard fd >= 0 else { throw invalid("无法安全保存存储分析初始化记录") }
        defer { close(fd) }
        try marker.withUnsafeBytes { buffer in
            var offset = 0
            while offset < marker.count {
                let count = write(fd, buffer.baseAddress!.advanced(by: offset), marker.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw invalid("存储分析初始化记录写入失败") }
                offset += count
            }
        }
        guard fsync(fd) == 0 else { throw invalid("存储分析初始化记录无法持久保存") }
    }
    private func validateStatePath() throws {
        for url in [dataDirectory, stateURL.deletingLastPathComponent(), stateURL, stateMarkerURL] {
            guard (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) == nil else {
                throw invalid("存储分析资料路径不能使用符号链接")
            }
        }
        for url in [dataDirectory, stateURL.deletingLastPathComponent(), stateURL, stateMarkerURL] where try pathExists(url) {
            let type = try FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType
            guard type == .typeDirectory || ((url == stateURL || url == stateMarkerURL) && type == .typeRegular) else { throw invalid("存储分析资料路径不是普通文件或目录") }
        }
    }
    private func saveState() {
        guard stateWritable else { return }
        do {
            try validateStatePath()
            let current = try readPrivateStateFile(stateURL)
            guard current == savedState else { throw invalid("存储分析记录已被外部修改，保留原文件") }
            try FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try ensureStateMarker()
            let bytes = try JSONEncoder().encode(StorageAnalysisState(exclusions: exclusions.map(\.path), history: history))
            guard bytes.count <= 2 * 1_024 * 1_024 else { throw invalid("存储分析记录超过保存预算") }
            try bytes.write(to: stateURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stateURL.path)
            savedState = bytes
        } catch {
            stateWritable = false
            persistenceWarning = "存储分析设置或历史未能安全保存，原文件已保留；本次结果可查看和导出，后续扫描不会覆盖旧记录。"
            status = persistenceWarning
        }
    }
}
