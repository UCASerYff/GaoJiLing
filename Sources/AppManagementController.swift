import AppKit
import Combine
import UniformTypeIdentifiers

private final class UninstallCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func cancel() { lock.lock(); value = true; lock.unlock() }
}

@MainActor final class AppManagementController: ObservableObject {
    @Published private(set) var apps: [InstalledApp] = []
    @Published private(set) var plan: UninstallPlan?
    @Published private(set) var report: UninstallReport?
    @Published private(set) var history: [UninstallHistoryEntry] = []
    @Published private(set) var isBusy = false
    @Published private(set) var isLoadingApps = false
    @Published private(set) var status = "选择应用后查看明确关联；所有项目默认不勾选。"
    @Published private(set) var recoveryError: String?
    private let engine: UninstallEngine
    private var cancellation: UninstallCancellation?
    private var operation: Task<Void, Never>?
    var beforeExecution: ((UninstallPlan) -> Bool)?
    var onExecutionFinished: ((UninstallReport) -> Void)?
    var onReviewFailed: ((URL, Bool) -> Void)?

    init(dataDirectory: URL) {
        engine = UninstallEngine(journalDirectory: dataDirectory.appendingPathComponent("Uninstall", isDirectory: true),
            appIsRunning: { Self.runningState($0) },
            appIsRunningAtLocation: { Self.runningState($0, current: $1) })
        refreshHistory()
    }
    /// Tests or another native host can inject its own serialized engine.
    init(engine: UninstallEngine) { self.engine = engine; refreshHistory() }

    nonisolated private static func runningState(_ app: InstalledApp, current: URL? = nil) -> Bool? {
        if NSWorkspace.shared.runningApplications.contains(where: {
            $0.bundleIdentifier == app.bundleID || $0.bundleIdentifier?.hasPrefix(app.bundleID + ".") == true ||
                $0.bundleURL?.path == app.path || (current != nil && $0.bundleURL?.path == current?.path)
        }) { return true }
        // Native enumeration includes background executables under the bundle;
        // an unreadable process list is unknown, never a claim of inactivity.
        let state = app.path.withCString { original in
            if let current {
                return current.path.withCString { gjl_application_running_at_locations(original, $0,
                    app.identity.device, app.identity.inode, app.identity.uid) }
            }
            return gjl_application_running(original, 0)
        }
        return state < 0 ? nil : state != 0
    }

    func loadApps() {
        guard !isBusy else { return }
        begin("正在读取应用目录…"); isLoadingApps = true
        let engine = engine, token = cancellation!
        operation = Task { [weak self] in
            do {
                let apps = try await Task.detached(priority: .utility) { try engine.installedApps(cancelled: { token.isCancelled }) }.value
                guard let self else { return }
                self.apps = apps
                self.status = token.isCancelled ? "应用列表已停止；可以单独选择应用。" : "列出 \(apps.count) 个可识别应用；子目录中的应用可通过“选择应用”打开。"
            } catch { self?.status = "应用列表未完整读取：\(error.localizedDescription)。可以单独选择应用。" }
            self?.finish()
        }
    }

    func chooseApplication() {
        guard !isBusy else { return }
        let panel = NSOpenPanel()
        panel.title = "选择要复核卸载的应用"
        panel.prompt = "查看关联项目"
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        review(appURL: url)
    }

    /// GaoAction apps.uninstall.review may call this with a verified reference;
    /// it only opens the review state and never selects or executes an item.
    @discardableResult func review(appURL: URL, expectedBundleID: String? = nil, expectedIdentity: UninstallIdentity? = nil) -> Bool {
        guard !isBusy else { return false }
        begin("正在读取所选应用的明确关联…"); plan = nil; report = nil
        let engine = engine, token = cancellation!
        operation = Task { [weak self] in
            do {
                let result = try await Task.detached(priority: .utility) {
                    try engine.review(appURL: appURL, expectedBundleID: expectedBundleID, expectedIdentity: expectedIdentity, cancelled: { token.isCancelled })
                }.value
                guard let self else { return }
                self.plan = result
                self.status = result.complete ? "复核完成，默认保留所有项目；请逐项确认后再选择。" : "复核未完成，不能执行卸载，请重新复核。"
            } catch {
                self?.status = error is CancellationError ? "已取消复核，未移动文件。" : "无法复核：\(error.localizedDescription)"
                self?.onReviewFailed?(appURL, token.isCancelled || error is CancellationError)
            }
            self?.finish()
        }
        return true
    }

    func execute(planID: String, selectedIDs: Set<String>) {
        guard !isBusy, let plan, plan.id == planID, !selectedIDs.isEmpty else { return }
        guard beforeExecution?(plan) != false else {
            status = "前置安全记录未能完成，已停止卸载；未开始任何文件移动。"
            return
        }
        begin("正在复核身份并移入废纸篓…"); report = nil
        let engine = engine, token = cancellation!
        operation = Task { [weak self] in
            do {
                let result = try await Task.detached(priority: .utility) {
                    try engine.execute(planID: planID, selectedIDs: selectedIDs, cancelled: { token.isCancelled })
                }.value
                self?.report = result; self?.status = result.message
            } catch {
                let message = "卸载未完成：\(error.localizedDescription)。已有恢复记录会保留。"
                self?.status = message
                self?.report = UninstallReport(batchID: engine.hasRecordedBatch(planID) ? planID : nil,
                    movedIDs: [], movedBytes: 0, issues: [UninstallIssue(itemID: planID, message: error.localizedDescription)], message: message, cancelled: token.isCancelled)
            }
            self?.plan = nil
            self?.finish()
            if let report = self?.report { self?.onExecutionFinished?(report) }
        }
    }

    func restore(batchID: String) {
        guard !isBusy else { return }
        begin("正在按批次恢复；已有新文件的位置会保留并跳过…"); report = nil
        let engine = engine, token = cancellation!
        operation = Task { [weak self] in
            let result = await Task.detached(priority: .utility) {
                engine.restore(batchID: batchID, cancelled: { token.isCancelled })
            }.value
            self?.report = result; self?.status = result.message; self?.plan = nil
            self?.finish()
        }
    }
    func cancel() {
        guard isBusy else { return }
        cancellation?.cancel()
        status = "正在等待当前文件操作返回后停止；已移动的项目仍保留恢复记录。"
    }
    func waitUntilIdle() async { await operation?.value }
    func reveal(_ path: String) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
    private func begin(_ text: String) { cancellation = UninstallCancellation(); isBusy = true; status = text }
    private func finish() { refreshHistory(); isBusy = false; isLoadingApps = false; cancellation = nil; operation = nil }
    private func refreshHistory() { history = engine.history; recoveryError = engine.recoveryError }
}
