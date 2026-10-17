import AppKit
import Combine

/// Terminal status refers to this operation's observed work, never a guarantee
/// that the complete selected directory was readable or that space was freed.
enum DuplicateScanCompletion: String, Sendable { case completed, partial, cancelled, failed }

private final class DuplicateCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    func cancel() { lock.lock(); stopped = true; lock.unlock() }
}

@MainActor final class DuplicateAnalysisController: ObservableObject {
    @Published private(set) var preparedDirectory: URL?
    @Published private(set) var preparedExpectedIdentity: DuplicateDirectoryIdentity?
    @Published private(set) var result: DuplicateScanResult?
    @Published private(set) var progress: DuplicateScanProgress?
    @Published private(set) var isBusy = false
    @Published private(set) var operationID: UUID?
    @Published private(set) var completion: DuplicateScanCompletion?
    @Published private(set) var report: DuplicateRecoveryReport?
    @Published private(set) var history: [DuplicateRecoveryHistory] = []
    @Published private(set) var recoveryError: String?
    @Published private(set) var status = "选择目录后单独确认读取文件内容。默认不选择任何重复副本。"
    /// Root host supplies the same synchronous gate used by other maintenance
    /// operations; view-level disabling is not the execution boundary.
    var actionsAllowed: (() -> Bool)?
    /// GaoAction saves its executing state only after the local content consent.
    var onBeforeScan: ((UUID, URL) -> Bool)?
    /// Immutable completion is delivered before releasing this operation's slot.
    var onScanCompleted: ((UUID, DuplicateScanResult?, DuplicateScanCompletion) -> Void)?
    var onRecoveryCompleted: ((DuplicateRecoveryReport) -> Void)?
    private let analyzer: DuplicateAnalyzer
    private let recovery: DuplicateRecovery
    private var cancellation: DuplicateCancellation?
    private var operation: Task<Void, Never>?
    private var activeScanID: UUID?

    init(dataDirectory: URL) {
        analyzer = DuplicateAnalyzer()
        recovery = DuplicateRecovery(journalDirectory: dataDirectory.appendingPathComponent("Duplicates", isDirectory: true))
        refreshHistory()
    }
    init(analyzer: DuplicateAnalyzer, recovery: DuplicateRecovery) {
        self.analyzer = analyzer; self.recovery = recovery; refreshHistory()
    }
    @discardableResult func prepareDirectory(_ directory: URL, expectedIdentity: DuplicateDirectoryIdentity? = nil) -> Bool {
        guard !isBusy, actionsAllowed?() != false else { return false }
        guard DuplicateFileSafety.validDirectoryURL(directory), (try? DuplicateFileSafety.pathParts(directory.path)) != nil else {
            status = "请选择规范的本机目录路径。"; return false
        }
        // Preparing a handoff does not open a directory or file and does not
        // count as user consent to content access.
        preparedDirectory = directory; preparedExpectedIdentity = expectedIdentity
        result = nil; progress = nil; completion = nil; report = nil
        status = "目录已预填，尚未读取内容。请查看范围，再明确确认内容分析。"
        return true
    }
    func chooseDirectory() {
        guard !isBusy, actionsAllowed?() != false else { return }
        let panel = NSOpenPanel()
        panel.title = "选择重复文件内容分析范围"
        panel.message = "选择只会预填范围；随后仍须单独确认读取本地文件内容。不会下载云占位文件。"
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        _ = prepareDirectory(url)
    }
    @discardableResult func scanPreparedDirectory(contentReadConfirmed: Bool) -> Bool {
        guard contentReadConfirmed, !isBusy, actionsAllowed?() != false, let directory = preparedDirectory else { return false }
        let id = UUID()
        guard onBeforeScan?(id, directory) != false else {
            status = "扫描前的安全记录或业务前置检查未完成，未开始读取内容。"; return false
        }
        let expected = preparedExpectedIdentity
        let token = DuplicateCancellation(); cancellation = token
        operationID = id; activeScanID = id; isBusy = true; result = nil; progress = nil; completion = nil; report = nil
        status = "正在分析已确认目录中的本地文件内容…"
        let analyzer = analyzer
        let update: @Sendable (DuplicateScanProgress) -> Void = { [weak self] value in
            Task { @MainActor [weak self] in
                guard let self, self.activeScanID == id, self.isBusy else { return }; self.progress = value
            }
        }
        operation = Task { [weak self] in
            do {
                let value = try await Task.detached(priority: .utility) {
                    try analyzer.scan(directory: directory, expectedIdentity: expected, progress: update, cancelled: { token.cancelled })
                }.value
                guard let self, self.activeScanID == id else { return }
                let outcome: DuplicateScanCompletion = token.cancelled || value.cancelled ? .cancelled : (value.complete ? .completed : .partial)
                self.result = value; self.progress = value.progress; self.completion = outcome
                switch outcome {
                case .completed: self.status = "内容分析完成，找到 \(value.groups.count) 组完全相同文件。所有副本默认不选，每组必须保留一个实物。"
                case .partial: self.status = "仅完成部分内容分析；已保留读取结果与原因，本轮不允许移动副本。"
                case .cancelled: self.status = "内容分析已取消；已读取部分保留，未扫描区域不按没有重复计算，本轮不允许移动。"
                case .failed: break
                }
                self.onScanCompleted?(id, value, outcome)
                self.finish()
            } catch {
                guard let self, self.activeScanID == id else { return }
                let outcome: DuplicateScanCompletion = token.cancelled || error is CancellationError ? .cancelled : .failed
                self.completion = outcome
                self.status = "内容分析未完成：\(error.localizedDescription)。未移动任何文件。"
                self.onScanCompleted?(id, nil, outcome)
                self.finish()
            }
        }
        return true
    }
    func selectionBlockReason(_ file: DuplicateFile) -> String? {
        guard let result, result.complete, !result.cancelled, completion == .completed else { return "本轮分析不完整，不能移动副本。" }
        if let reason = file.protectionReason { return reason }
        if file.identity.linkCount != 1 { return "硬链接实物保留，不按可处理重复副本计算。" }
        if file.identity.uid != getuid() { return "其他所有者的文件保留。" }
        return DuplicateFileSafety.movableReason(path: file.path, scope: result.scope)
    }
    func execute(resultID: UUID, selectedIDs: Set<String>) {
        guard !isBusy, actionsAllowed?() != false, let result, result.id == resultID,
              completion == .completed, result.complete, !result.cancelled, !selectedIDs.isEmpty, recoveryError == nil else { return }
        begin("正在逐字节复核所选副本和保留文件，并保存恢复回执…")
        let recovery = recovery, token = cancellation!
        operation = Task { [weak self] in
            let value: DuplicateRecoveryReport
            do {
                value = try await Task.detached(priority: .utility) {
                    try recovery.execute(result: result, selectedIDs: selectedIDs, cancelled: { token.cancelled })
                }.value
            } catch {
                value = DuplicateRecoveryReport(batchID: recovery.hasRecordedBatch(result.id.uuidString) ? result.id.uuidString : nil,
                    movedIDs: [], restoredIDs: [], processedBytes: 0,
                    issues: [DuplicateRecoveryIssue(itemID: result.id.uuidString, message: error.localizedDescription)],
                    cancelled: token.cancelled, message: "处理未完成：\(error.localizedDescription)。已有恢复记录与实物保留。")
            }
            guard let self else { return }
            self.report = value; self.status = value.message; self.result = nil
            self.refreshHistory(); self.onRecoveryCompleted?(value); self.finish()
        }
    }
    func restore(batchID: String) {
        guard !isBusy, actionsAllowed?() != false, recoveryError == nil else { return }
        begin("正在核验恢复实物；原位置已有文件时保留并跳过…")
        let recovery = recovery, token = cancellation!
        operation = Task { [weak self] in
            let value = await Task.detached(priority: .utility) { recovery.restore(batchID: batchID, cancelled: { token.cancelled }) }.value
            guard let self else { return }
            self.report = value; self.status = value.message; self.result = nil
            self.refreshHistory(); self.onRecoveryCompleted?(value); self.finish()
        }
    }
    func cancel() {
        guard isBusy else { return }; cancellation?.cancel()
        status = "正在等待当前文件操作返回后停止；已读部分和任何恢复记录保留。"
    }
    func waitUntilIdle() async { await operation?.value }
    func reveal(_ path: String) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
    private func begin(_ text: String) { cancellation = DuplicateCancellation(); isBusy = true; status = text; report = nil; activeScanID = nil }
    private func finish() { refreshHistory(); activeScanID = nil; cancellation = nil; isBusy = false; operation = nil }
    private func refreshHistory() { history = recovery.history; recoveryError = recovery.recoveryError }
}
