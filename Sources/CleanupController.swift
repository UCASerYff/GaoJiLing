import AppKit
import Combine

private final class CleanupCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    func cancel() { lock.lock(); stopped = true; lock.unlock() }
}

/// Owns one maintenance operation at a time. File work stays off the main
/// thread; cancellation stops between items and never discards recovery data.
@MainActor final class CleanupController: ObservableObject {
    @Published private(set) var items: [CleanupItem] = []
    @Published private(set) var isScanning = false
    @Published private(set) var isCleaning = false
    @Published private(set) var isReleasingMemory = false
    @Published private(set) var isBusy = false
    @Published private(set) var status: String?
    @Published private(set) var scanNotes: [String] = []
    @Published private(set) var report: CleanupReport?
    @Published private(set) var memorySnapshot: MemorySnapshot?
    @Published private(set) var memoryReport: MemoryReleaseReport?
    @Published private(set) var canRestore = false
    @Published private(set) var history: [CleanupHistoryEntry] = []
    private let engine: CleanupEngine
    private var cancellation: CleanupCancellation?
    private var operation: Task<Void, Never>?
    private var isRestoring = false

    init(dataDirectory: URL) {
        engine = CleanupEngine(journalDirectory: dataDirectory.appendingPathComponent("Cleanup", isDirectory: true),
                               appIsRunning: { Self.runningState(for: $0) })
        canRestore = engine.canRestore
        history = engine.history
    }

    nonisolated private static func runningState(for identifier: String) -> Bool? {
        // Monitoring data and other Gao-series apps are always outside cleanup.
        if identifier.hasPrefix("com.gaoseries.") { return true }
        if identifier.hasPrefix("developer.") {
            let state = gjl_development_tools_running()
            return state < 0 ? nil : state != 0
        }
        if NSWorkspace.shared.runningApplications.contains(where: {
            $0.bundleIdentifier == identifier || $0.bundleIdentifier?.hasPrefix(identifier + ".") == true
        }) { return true }
        guard let bundle = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) else { return nil }
        let state = bundle.path.withCString { gjl_application_running($0, identifier == "com.apple.dt.Xcode" ? 1 : 0) }
        return state < 0 ? nil : state != 0
    }

    func scan() {
        guard !isBusy else { return }
        begin(); isScanning = true
        items = []; report = nil; scanNotes = []
        status = "正在扫描过期缓存与编译产物…"
        let token = cancellation!; let engine = engine
        operation = Task { [weak self] in
            do {
                let result = try await Task.detached(priority: .utility) {
                    try engine.scan(cancelled: { token.isCancelled })
                }.value
                guard let self else { return }
                self.items = result.items
                self.scanNotes = result.notes
                self.status = token.isCancelled ? "扫描已停止，尚未完成的范围不作清理。" :
                    "扫描完成：\(result.items.count) 项候选；\(result.skippedCount) 项因状态、保留期限或权限跳过。"
                self.finish()
            } catch {
                self?.status = "扫描未完成：\(error.localizedDescription)。未清理任何文件。"
                self?.finish()
            }
        }
    }

    func trash(ids: Set<String>) {
        guard !isBusy, !ids.isEmpty else { return }
        begin(); isCleaning = true; report = nil
        status = "正在复查并移入废纸篓…"
        let token = cancellation!; let engine = engine
        operation = Task { [weak self] in
            do {
                let result = try await Task.detached(priority: .utility) {
                    try engine.trash(ids: ids, cancelled: { token.isCancelled })
                }.value
                guard let self else { return }
                self.report = result
                self.status = result.message
                let removed = Set(result.removedIDs)
                self.items.removeAll { removed.contains($0.id) }
                self.finish()
            } catch {
                self?.status = "清理未完成：\(error.localizedDescription)。已有恢复记录会保留。"
                self?.finish()
            }
        }
    }

    func restore(batchID: String? = nil) {
        guard !isBusy, canRestore else { return }
        begin(); isCleaning = true; isRestoring = true; status = "正在恢复，遇到已有文件会保留并跳过…"
        let engine = engine
        operation = Task { [weak self] in
            let result = await Task.detached(priority: .utility) {
                if let batchID { return engine.restore(batchID: batchID) }
                return engine.restoreLastCleanup()
            }.value
            guard let self else { return }
            self.status = result.message
            self.scanNotes = (result.skipped + result.failed).map(\.message)
            self.items = []; self.report = nil
            self.finish()
        }
    }

    func cancel() {
        guard isBusy, !isReleasingMemory else { return }
        if isRestoring { status = "正在等待恢复完成；完成后退出，已有文件不会被覆盖。"; return }
        cancellation?.cancel()
        status = "正在停止；已完成的项目和恢复记录会保留…"
    }

    func reveal(id: String) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.displayPath)])
    }
    func openTrash() { NSWorkspace.shared.open(URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".Trash", isDirectory: true)) }

    func refreshMemory() { memorySnapshot = MemoryMaintenance.snapshot() }
    func releaseOwnMemory() { releaseMemory(system: false) }
    func reclaimSystemFileCache() { releaseMemory(system: true) }
    private func releaseMemory(system: Bool) {
        guard !isBusy else { return }
        begin(); isReleasingMemory = true; memoryReport = nil
        status = system ? "等待系统管理员授权并回收文件缓存；可在授权框中取消。" : "正在回收本应用可归还的内存…"
        operation = Task { [weak self] in
            let result = system ? await MemoryMaintenance.reclaimSystemFileCache() : await MemoryMaintenance.releaseOwnMemory()
            guard let self else { return }
            self.memoryReport = result
            self.memorySnapshot = result.after ?? MemoryMaintenance.snapshot()
            self.status = result.message
            self.finish()
        }
    }

    private func begin() { cancellation = CleanupCancellation(); isBusy = true }
    private func finish() {
        canRestore = engine.canRestore
        history = engine.history
        isScanning = false; isCleaning = false; isReleasingMemory = false; isRestoring = false
        cancellation = nil; operation = nil; isBusy = false
    }
}
