import AppKit
import Combine
import UniformTypeIdentifiers

private final class DiskStorageCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    func cancel() { lock.lock(); stopped = true; lock.unlock() }
}

/// Separate from metadata-only storage scans: no image content is opened at init,
/// on appearance, by a handoff, or before the explicit content-reading agreement.
@MainActor final class DiskStorageController: ObservableObject {
    @Published private(set) var volumes: LocalVolumeMetadataSnapshot?
    @Published private(set) var image: DiskImageAnalysis?
    @Published private(set) var isBusy = false
    @Published private(set) var status: String?
    @Published private(set) var lastOutput: URL?
    @Published private(set) var preparedImage: URL?
    var actionsAllowed: () -> Bool = { true }
    private let dataDirectory: URL
    private var sourceURL: URL?
    private var cancellation: DiskStorageCancellation?
    private var operation: Task<Void, Never>?
    private var operationID: UUID?

    init(dataDirectory: URL) { self.dataDirectory = dataDirectory }

    func refreshVolumes() {
        guard canStart else { return }
        let (id, token) = begin("正在读取已挂载内置卷的元信息…")
        operation = Task { [weak self] in
            let value = await Task.detached(priority: .utility) {
                LocalVolumeMetadataCollector().snapshot(cancelled: { token.cancelled })
            }.value
            guard let self, self.operationID == id else { return }
            self.volumes = value
            self.finish(value.cancelled ? "卷查询已停止，结果仅为已读取部分。" :
                (value.complete ? "内置卷元信息已更新；未遍历目录或读取文件内容。" : "卷查询有未读取部分，请查看说明。"))
        }
    }

    func chooseImage() {
        guard canStart else { return }
        let panel = NSOpenPanel()
        panel.title = "选择普通 NTFS 卷镜像"
        panel.message = "仅选择从 NTFS 卷引导扇区开始的普通文件。不会挂载或读取原始设备，不支持压缩 DMG、整盘分区镜像或加密卷解锁。"
        panel.canChooseDirectories = false; panel.canChooseFiles = true
        panel.allowsMultipleSelection = false; panel.resolvesAliases = false
        guard panel.runModal() == .OK, let url = panel.url, canStart else { return }
        prepareImage(url)
        confirmPreparedImage()
    }

    /// Finder/LaunchServices may prefill a file, but never grant content reading.
    func prepareImage(_ url: URL) {
        guard canStart, url.isFileURL else { return }
        preparedImage = url
        status = "已预填“\(url.lastPathComponent)”，等待单独确认读取内容；尚未打开镜像。"
    }

    func confirmPreparedImage() {
        guard let url = preparedImage, canStart else { return }
        let alert = NSAlert()
        alert.messageText = "读取这个镜像的内容？"
        alert.informativeText = "将只读解析“\(url.lastPathComponent)”中的引导信息、文件记录、名称和数据属性，并可能计算小镜像的完整摘要。结果只保存在本次内存中，不上传。目录是有界 MFT 记录中已核验的路径，不是完整目录或卷健康检查。"
        alert.addButton(withTitle: "同意读取并分析"); alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { status = "已取消，未打开镜像内容。"; return }
        analyzeImage(url, contentReadConfirmed: true)
    }

    func analyzeImage(_ url: URL, contentReadConfirmed: Bool) {
        guard contentReadConfirmed else { status = "需先明确同意读取所选镜像内容，未开始分析。"; return }
        guard canStart else { return }
        let (id, token) = begin("正在只读解析所选镜像…")
        image = nil; sourceURL = nil; preparedImage = nil
        operation = Task { [weak self] in
            do {
                let value = try await Task.detached(priority: .utility) {
                    try DiskImageAnalyzer.analyze(url: url, cancelled: { token.cancelled })
                }.value
                guard let self, self.operationID == id else { return }
                guard !token.cancelled else { self.finish("分析已取消，未将迟到结果作为完成。源镜像未被写入。"); return }
                self.image = value; self.sourceURL = url
                self.finish("镜像解析已返回。仅列出预算内的已核验记录与路径；限制和未支持项见结果说明。")
            } catch {
                guard let self, self.operationID == id else { return }
                self.finish("镜像分析未完成：\(error.localizedDescription)")
            }
        }
    }

    func exportImageReport() {
        guard let report = image, canStart else { return }
        let panel = NSSavePanel(); panel.title = "导出镜像分析报告"
        panel.message = "包含镜像名称、卷信息和解析到的文件名称及路径。请选择新的报告文件名；不会覆盖已有文件。"
        panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = "搞机灵-镜像分析.json"
        guard panel.runModal() == .OK, let url = panel.url, canStart else { return }
        do {
            try validateOutput(url)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let bytes = try encoder.encode(report)
            writeReport(bytes, to: url)
        } catch { status = "未导出：\(error.localizedDescription)" }
    }

    func exportVolumeReport() {
        guard let report = volumes, canStart else { return }
        let panel = NSSavePanel(); panel.title = "导出内置卷元信息"
        panel.message = "报告包含本机卷名称、挂载路径和查询时间；未知字段保持未知，不代表可释放空间。请选择新文件。"
        panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = "搞机灵-内置卷.json"
        guard panel.runModal() == .OK, let url = panel.url, canStart else { return }
        do {
            try validateOutput(url)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            writeReport(try encoder.encode(report), to: url)
        } catch { status = "未导出：\(error.localizedDescription)" }
    }

    func extract(_ entry: DiskImageEntry) {
        guard let report = image, let source = sourceURL, entry.canExtract, canStart else { return }
        let panel = NSSavePanel(); panel.title = "提取一份普通文件副本"
        panel.message = "只提取所选默认数据流到一个新文件，不按镜像路径创建目录、不运行内容、不覆盖已有资料。不会复制权限、命名流或文件系统语义。"
        panel.nameFieldStringValue = entry.name
        guard panel.runModal() == .OK, let url = panel.url, canStart else { return }
        do { try validateOutput(url) } catch { status = error.localizedDescription; return }
        let alert = NSAlert(); alert.messageText = "提取“\(entry.name)”的文件内容？"
        alert.informativeText = "会重新核验原镜像和所选记录，只支持已确认的普通未压缩、未加密文件。目的地：\(url.path)。任何失败会明确报告，不代表卷一致或镜像安全可写。"
        alert.addButton(withTitle: "读取内容并保存新副本"); alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn, canStart else { return }
        let (id, token) = begin("正在核验镜像并提取新副本…")
        operation = Task { [weak self] in
            do {
                _ = try await Task.detached(priority: .utility) {
                    try DiskImageAnalyzer.extract(url: source, entryID: entry.id, from: report, to: url,
                        cancelled: { token.cancelled })
                }.value
                guard let self, self.operationID == id else { return }
                self.lastOutput = url
                self.finish("新副本已保存并核验：\(url.lastPathComponent)。源镜像未改写，副本不会自动打开。")
            } catch {
                guard let self, self.operationID == id else { return }
                self.finish("提取未完成：\(error.localizedDescription)")
            }
        }
    }

    func cancel() { cancellation?.cancel(); if isBusy { status = "正在请求停止；需等待当前文件系统调用返回。" } }
    func waitUntilIdle() async { await operation?.value }
    private var canStart: Bool { !isBusy && actionsAllowed() }
    private func begin(_ message: String) -> (UUID, DiskStorageCancellation) {
        let id = UUID(), token = DiskStorageCancellation()
        operationID = id; cancellation = token; isBusy = true; status = message
        return (id, token)
    }
    private func finish(_ message: String) {
        status = message; operationID = nil; cancellation = nil; operation = nil; isBusy = false
    }
    private func writeReport(_ bytes: Data, to url: URL) {
        guard canStart else { return }
        let (id, _) = begin("正在保存并核验新报告…")
        operation = Task { [weak self] in
            do {
                try await Task.detached(priority: .utility) { try DiskImageReportWriter.writeNew(data: bytes, to: url) }.value
                guard let self, self.operationID == id else { return }
                self.lastOutput = url; self.finish("报告已保存并核验：\(url.lastPathComponent)。")
            } catch {
                guard let self, self.operationID == id else { return }
                self.finish("报告未完成：\(error.localizedDescription)")
            }
        }
    }
    private func validateOutput(_ url: URL) throws {
        try DiskStorageOutputPolicy.validate(url, dataDirectory: dataDirectory, source: sourceURL)
    }
}

enum DiskStorageOutputPolicy {
    static func validate(_ url: URL, dataDirectory: URL, source: URL?) throws {
        guard url.isFileURL else { throw invalid() }
        let path = url.path
        guard path == url.standardizedFileURL.path, !path.contains("\0"), path.hasPrefix("/") else { throw invalid() }
        let prohibited = ["/dev", "/System", "/Applications", dataDirectory.path,
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/GaoSeries").path]
        // Conservatively protect aliases differing only in case/canonical Unicode
        // on the default case-insensitive APFS/HFS+ volumes as well.
        func folded(_ value: String) -> String {
            value.precomposedStringWithCanonicalMapping.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        }
        let foldedPath = folded(path)
        guard !prohibited.map(folded).contains(where: { foldedPath == $0 || foldedPath.hasPrefix($0 + "/") }),
              !url.pathComponents.contains(where: { $0.lowercased().hasSuffix(".app") }),
              source.map({ folded($0.standardizedFileURL.path) }) != foldedPath else { throw invalid() }
    }
    private static func invalid() -> NSError {
        NSError(domain: "GaoJiLing.DiskStorage", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "请选择资料目录、应用包、系统目录和源镜像之外的新普通文件；不会覆盖原件。"])
    }
}
