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
    @Published private(set) var status: String?
    @Published private(set) var exclusions: [URL] = []
    @Published private(set) var capacity: DiskCapacity?
    @Published private(set) var history: [StorageScanSnapshot] = []
    var canExport: Bool { result != nil && !isBusy }
    private let analyzer = StorageAnalyzer()
    private let dataDirectory: URL
    private let stateURL: URL
    private var stateWritable = true
    private var savedState: Data?
    private var cancellation: StorageAnalysisCancellation?
    private var operation: Task<Void, Never>?

    init(dataDirectory: URL) {
        self.dataDirectory = dataDirectory
        stateURL = dataDirectory.appendingPathComponent("Storage/analysis-state.json")
        do {
            try validateStatePath()
            if try pathExists(stateURL) {
                let bytes = try Data(contentsOf: stateURL)
                let state = try JSONDecoder().decode(StorageAnalysisState.self, from: bytes)
                guard state.version == 1, state.exclusions.allSatisfy({ $0.hasPrefix("/") }),
                      state.history.allSatisfy({ $0.totalBytes >= 0 }) else { throw invalid("存储分析记录格式无效") }
                exclusions = state.exclusions.map { URL(fileURLWithPath: $0, isDirectory: true) }
                history = Array(state.history.suffix(30))
                savedState = bytes
            }
        } catch {
            stateWritable = false
            status = "原存储分析设置或历史无法读取，已保留文件；新扫描仍可使用，但不会覆盖旧记录。"
        }
        refreshCapacity()
    }

    func scanEnvironments() { scan(directory: nil) }
    func analyzeDirectory(_ directory: URL) { scan(directory: directory) }
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
    private func scan(directory: URL?) {
        guard !isBusy else { return }
        isBusy = true; result = nil
        let token = StorageAnalysisCancellation(); cancellation = token
        status = directory == nil ? "正在分析开发工具占用…" : "正在分析所选目录的本地占用…"
        let analyzer = analyzer; let exclusions = exclusions
        operation = Task { [weak self] in
            do {
                let value = try await Task.detached(priority: .utility) {
                    if let directory { return try analyzer.analyze(directory: directory, exclusions: exclusions, cancelled: { token.cancelled }) }
                    return try analyzer.scanEnvironments(exclusions: exclusions, cancelled: { token.cancelled })
                }.value
                guard let self else { return }
                self.result = value
                self.status = value.complete ? "分析完成，占用为本地已分配空间估算。" : "分析未完整完成；下列占用仅为已读取部分，请查看跳过说明。"
                self.history.append(StorageScanSnapshot(id: UUID().uuidString, date: value.date, totalBytes: value.totalBytes,
                                                        scope: value.root ?? "开发环境", complete: value.complete))
                self.history = Array(self.history.suffix(30))
                self.saveState()
                self.finish()
            } catch {
                self?.status = "分析未完成：\(error.localizedDescription)。未清理任何文件。"
                self?.finish()
            }
        }
    }
    func cancel() { cancellation?.cancel(); if isBusy { status = "正在停止分析…" } }
    private func finish() { cancellation = nil; operation = nil; refreshCapacity(); isBusy = false }
    func addExclusion() {
        guard !isBusy else { return }
        let panel = NSOpenPanel()
        panel.title = "添加存储分析排除目录"
        panel.message = "排除所选目录及其子目录；规则只影响存储分析。清理页面始终使用独立的保护规则。"
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls where !exclusions.contains(where: { $0.path == url.path }) { exclusions.append(url) }
        saveState(); result = nil
    }
    func removeExclusion(_ url: URL) {
        guard !isBusy else { return }
        exclusions.removeAll { $0.path == url.path }; saveState(); result = nil
    }
    func reveal(_ entry: StorageEntry) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: entry.path)]) }
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
            var lines = ["类型,名称,分类,路径,已分配字节估算,文件数,处理建议,说明,扫描时间,是否完整"]
            let date = ISO8601DateFormatter().string(from: result.date)
            for (kind, entries) in [("占用", result.entries), ("大型文件", result.largestFiles)] {
                for entry in entries {
                    lines.append([kind, entry.name, entry.category, entry.path, String(entry.bytes), String(entry.fileCount), entry.risk,
                                  entry.reason, date, result.complete ? "是" : "否"].map(csv).joined(separator: ","))
                }
            }
            for note in result.notes { lines.append(["跳过说明", note, "", "", "", "", "", "", date, result.complete ? "是" : "否"].map(csv).joined(separator: ",")) }
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
    private func validateStatePath() throws {
        for url in [dataDirectory, stateURL.deletingLastPathComponent(), stateURL] {
            guard (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) == nil else {
                throw invalid("存储分析资料路径不能使用符号链接")
            }
        }
        for url in [dataDirectory, stateURL.deletingLastPathComponent(), stateURL] where try pathExists(url) {
            let type = try FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType
            guard type == .typeDirectory || (url == stateURL && type == .typeRegular) else { throw invalid("存储分析资料路径不是普通文件或目录") }
        }
    }
    private func saveState() {
        guard stateWritable else { return }
        do {
            try validateStatePath()
            let current = try pathExists(stateURL) ? Data(contentsOf: stateURL) : nil
            guard current == savedState else { throw invalid("存储分析记录已被外部修改，保留原文件") }
            try FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let bytes = try JSONEncoder().encode(StorageAnalysisState(exclusions: exclusions.map(\.path), history: history))
            try bytes.write(to: stateURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stateURL.path)
            savedState = bytes
        } catch {
            stateWritable = false
            status = "存储分析设置或历史未能安全保存，原文件已保留；本次分析结果仍可查看和导出。"
        }
    }
}
