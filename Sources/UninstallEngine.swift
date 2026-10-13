import Foundation
import AppKit
import Darwin

struct InstalledApp: Identifiable, Codable, Equatable, Sendable {
    var id: String { path }
    let path: String
    let name: String
    let bundleID: String
    let version: String
    let identity: UninstallIdentity
    let metadataHash: String
    let protectedReason: String?
    let vendorUninstallReason: String?
}

struct AppRelatedItem: Identifiable, Sendable {
    let id: String
    let category: String
    let name: String
    let path: String?
    let evidence: String
    let bytes: Int64?
    let selectable: Bool
    let reason: String
}

struct UninstallPlan: Identifiable, Sendable {
    let id: String
    let app: InstalledApp
    let items: [AppRelatedItem]
    let notes: [String]
    let complete: Bool
}

struct UninstallIssue: Sendable { let itemID: String; let message: String }
struct UninstallReport: Sendable {
    let batchID: String?
    let movedIDs: [String]
    let movedBytes: Int64
    let issues: [UninstallIssue]
    let message: String
    var cancelled: Bool = false
}
struct UninstallHistoryEntry: Identifiable, Sendable {
    let id: String
    let date: Date
    let appName: String
    let itemCount: Int
    let pendingCount: Int
    let bytes: Int64
}

/// No arbitrary-path deletion API. A plan comes only from a selected, verified
/// installed bundle; its exact cache is optional and must meet the old age rule.
/// The controller serializes every call, including history reads.
final class UninstallEngine: @unchecked Sendable {
    typealias RunningLookup = @Sendable (InstalledApp) -> Bool?
    typealias TrashAction = @Sendable (URL) throws -> URL
    typealias JournalWriter = @Sendable (Data, Int32) throws -> Void
    typealias RenameAction = @Sendable (Int32, String, Int32, String) throws -> Void
    private typealias FS = UninstallFileSafety
    private enum Kind: String, Codable { case application, cache }
    private enum State: String, Codable { case prepared, staged, trashing, trashed, restored, untouched }
    private struct Candidate {
        let item: AppRelatedItem
        let kind: Kind
        let footprint: UninstallFootprint
        let parentIdentity: UninstallIdentity
    }
    // Intentionally resembles Cleanup's receipt shape for upgrade backups.
    private struct UninstallReceipt: Codable {
        let id: String
        let itemID: String
        let original: String
        let stage: String
        var trash: String?
        let owner: String
        let category: String
        let itemKind: Kind
        let footprint: UninstallFootprint
        let parentIdentity: UninstallIdentity
        var state: State
    }
    private struct Batch: Codable {
        let id: String
        let date: Date
        let app: InstalledApp
        var receipts: [UninstallReceipt]
    }
    private struct Journal: Codable { var version = 1; var batches: [Batch] = [] }

    let home: URL
    let journalDirectory: URL
    let stageDirectory: URL
    let initializationMarkerURL: URL
    private let applicationRoots: [URL]
    private let running: RunningLookup
    private let trashAction: TrashAction
    private let injectedTrash: Bool
    private let journalWriter: JournalWriter
    private let renameAction: RenameAction
    private var plan: UninstallPlan?
    private var candidates: [String: Candidate] = [:]
    private var journal = Journal()
    private var savedJournalHash: String?
    private var journalFailure: Error?
    private var markerPresent = false
    private static let marker = Data("GaoJiLing.UninstallJournal.v1\n".utf8)

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser, journalDirectory: URL? = nil,
         applicationRoots: [URL]? = nil, appIsRunning: @escaping RunningLookup, trash: TrashAction? = nil,
         journalWriter: JournalWriter? = nil, rename: RenameAction? = nil) {
        self.home = home
        self.journalDirectory = journalDirectory ?? home.appendingPathComponent("Library/Application Support/GaoSeries/GaoJiLing/Uninstall", isDirectory: true)
        initializationMarkerURL = self.journalDirectory.deletingLastPathComponent().appendingPathComponent("Uninstall.initialized")
        stageDirectory = home.appendingPathComponent("Library/Caches/.GaoJiLing-UninstallStage", isDirectory: true)
        self.applicationRoots = applicationRoots ?? [URL(fileURLWithPath: "/Applications", isDirectory: true), home.appendingPathComponent("Applications", isDirectory: true)]
        running = appIsRunning
        injectedTrash = trash != nil
        self.journalWriter = journalWriter ?? { data, fd in try FS.atomicData(data, directory: fd, name: "journal.json") }
        renameAction = rename ?? { from, name, to, destination in try FS.rename(from: from, name: name, to: to, destination: destination) }
        trashAction = trash ?? { url in
            var result: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &result)
            guard let result else { throw UninstallFailure(message: "系统未返回废纸篓位置，恢复记录已保留。") }
            return result as URL
        }
        do { try FS.materializationDisabled { try loadJournal() } }
        catch { journalFailure = error }
    }

    var recoveryError: String? { journalFailure?.localizedDescription }
    func hasRecordedBatch(_ id: String) -> Bool { journal.batches.contains { $0.id == id } }
    var history: [UninstallHistoryEntry] {
        journal.batches.reversed().compactMap { batch in
            let receipts = batch.receipts.filter { $0.state != .untouched }
            guard !receipts.isEmpty else { return nil }
            return UninstallHistoryEntry(id: batch.id, date: batch.date, appName: batch.app.name,
                itemCount: receipts.count, pendingCount: receipts.filter { $0.state != .restored }.count,
                bytes: receipts.reduce(0) { FS.add($0, $1.footprint.bytes) })
        }
    }

    /// Only application directories are enumerated, never the whole home folder.
    func installedApps(cancelled: () -> Bool = { false }) throws -> [InstalledApp] {
        try FS.materializationDisabled {
            var apps: [InstalledApp] = []
            for root in applicationRoots {
                if cancelled() { break }
                let fd: Int32
                do { fd = try FS.directory(root, read: true) }
                catch { if FS.missing(error) { continue }; throw error }
                defer { close(fd) }
                for name in try FS.names(fd, cancelled: cancelled) where name.hasSuffix(".app") {
                    if cancelled() { break }
                    if let app = try? inspectApp(root.appendingPathComponent(name)) { apps.append(app) }
                }
            }
            return apps.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
    }

    func review(appURL: URL, expectedBundleID: String? = nil, expectedIdentity: UninstallIdentity? = nil,
                cancelled: () -> Bool = { false }) throws -> UninstallPlan {
        try FS.materializationDisabled {
            if let journalFailure { throw journalFailure }
            try verifyJournal()
            plan = nil; candidates.removeAll()
            if cancelled() { throw CancellationError() }
            let app = try inspectApp(appURL)
            if let expectedIdentity, expectedIdentity != app.identity {
                throw UninstallFailure(message: "所选应用已被替换，与批准的设备、inode 或所有者不符。")
            }
            if let expectedBundleID, expectedBundleID != app.bundleID {
                throw UninstallFailure(message: "应用标识与请求不符，请重新选择真实应用。")
            }
            var items: [AppRelatedItem] = [], notes: [String] = [], complete = true
            let state = running(app)
            let block = app.protectedReason ?? app.vendorUninstallReason ?? (state == false ? nil : "应用仍在运行或无法确认全部相关进程已退出；请先正常退出。")
            func addCandidate(_ url: URL, kind: Kind, category: String, evidence: String, blocked: String?) {
                let id = UUID().uuidString
                do {
                    if cancelled() { throw CancellationError() }
                    let root = try FS.info(url)
                    let identity = UninstallIdentity(root)
                    guard identity.kind == UInt32(S_IFDIR) else { throw UninstallFailure(message: "该位置不是可独立处理的普通目录。") }
                    if let blocked {
                        items.append(AppRelatedItem(id: id, category: category, name: url.lastPathComponent, path: url.path,
                            evidence: evidence, bytes: nil, selectable: false, reason: blocked)); return
                    }
                    if kind == .cache {
                        guard identity.uid == getuid(), Date().timeIntervalSince1970 - Double(root.st_mtimespec.tv_sec) >= 7 * 86_400 else {
                            throw UninstallFailure(message: "缓存不足 7 天或不属于当前用户，保留。")
                        }
                    }
                    let footprint = try FS.snapshot(url, appBundle: kind == .application, cancelled: cancelled)
                    guard kind != .application || footprint.identity == app.identity else {
                        throw UninstallFailure(message: "应用在读取元数据后被替换，已保留。")
                    }
                    if kind == .cache && Date().timeIntervalSince1970 - footprint.newest < 7 * 86_400 {
                        throw UninstallFailure(message: "缓存内仍有最近 7 天修改的项目，保留整个目录。")
                    }
                    let parent = try FS.directory(url.deletingLastPathComponent()); defer { close(parent) }
                    let item = AppRelatedItem(id: id, category: category, name: url.lastPathComponent, path: url.path,
                        evidence: evidence, bytes: footprint.bytes, selectable: true,
                        reason: kind == .application ? "仅应用包；不会删除由此应用创建的文档。" : "精确标识、当前用户、完整目录至少 7 天未修改。")
                    items.append(item)
                    candidates[id] = Candidate(item: item, kind: kind, footprint: footprint, parentIdentity: try FS.identity(parent))
                } catch is CancellationError { complete = false }
                catch {
                    items.append(AppRelatedItem(id: id, category: category, name: url.lastPathComponent, path: url.path,
                        evidence: evidence, bytes: nil, selectable: false, reason: "保留：\(error.localizedDescription)"))
                }
            }
            addCandidate(URL(fileURLWithPath: app.path), kind: .application, category: "应用程序", evidence: "用户选定的应用包；Info.plist 的 CFBundleIdentifier 为 \(app.bundleID)。", blocked: block)
            let cache = home.appendingPathComponent("Library/Caches").appendingPathComponent(app.bundleID)
            if !cancelled() {
                do {
                    if try FS.optionalInfo(cache) != nil {
                        addCandidate(cache, kind: .cache, category: "应用缓存", evidence: "仅精确路径 Library/Caches/\(app.bundleID)，不匹配相似名称。", blocked: block)
                    }
                } catch { notes.append("缓存位置无法安全读取，未处理：\(error.localizedDescription)") }
            }
            let retained: [(String, String?, String)] = [
                ("偏好设置", "Library/Preferences/\(app.bundleID).plist", "可能被系统偏好服务缓存并重新写入；此版本保留设置文件。"),
                ("业务资料库", "Library/Application Support/\(app.bundleID)", "可能包含数据库、附件和授权资料，保留；不按应用名称搜索其他资料库。"),
                ("应用沙盒", "Library/Containers/\(app.bundleID)", "沙盒可能包含用户创建的数据，保留整个容器。"),
                ("窗口恢复状态", "Library/Saved Application State/\(app.bundleID).savedState", "可能包含未保存内容，保留。"),
                ("共享组与钥匙串", nil, "共享容器、App Group、钥匙串与跨应用资源不扫描、不处理。"),
                ("文稿与下载", nil, "不扫描或删除由应用创建的文件；卸载不会取消订阅。"),
                ("登录项与驱动", nil, "不猜测删除 launchd、驱动或系统扩展；存在这些组件时使用厂商卸载流程。")
            ]
            for (category, relative, reason) in retained {
                items.append(AppRelatedItem(id: UUID().uuidString, category: category, name: category,
                    path: relative.map { home.appendingPathComponent($0).path },
                    evidence: relative == nil ? "不建立自动删除归属。" : "仅展示标准精确位置，未扫描内容，也不表示一定存在。",
                    bytes: nil, selectable: false, reason: reason))
            }
            if cancelled() { complete = false; candidates.removeAll(); notes.append("复核已取消，所有候选失效；重新扫描后才可执行。") }
            notes.append("默认不勾选任何项目。移入废纸篓仍占空间；不自动清空，也不承诺零残留。")
            notes.append("扫描与取消在检查点生效，不能中断尚未返回的系统文件调用。仅支持当前磁盘可访问的普通应用包；权限不足不提权处理。")
            let result = UninstallPlan(id: UUID().uuidString, app: app, items: items, notes: notes, complete: complete)
            plan = result; return result
        }
    }

    func execute(planID: String, selectedIDs: Set<String>, cancelled: () -> Bool = { false }) throws -> UninstallReport {
        try FS.materializationDisabled {
            if let journalFailure { throw journalFailure }
            try verifyJournal()
            if let existing = journal.batches.first(where: { $0.id == planID }) {
                return UninstallReport(batchID: existing.id, movedIDs: [], movedBytes: 0, issues: [],
                    message: "此复核批次已执行过，未重复移动；剩余项目请重新扫描。")
            }
            guard let plan, plan.id == planID, plan.complete, !selectedIDs.isEmpty,
                  selectedIDs.allSatisfy({ candidates[$0] != nil }) else {
                throw UninstallFailure(message: "选择包含受保护项目或复核已失效，请重新扫描。")
            }
            try validateApp(plan.app)
            if cancelled() { return report(nil, [], 0, [], "已取消，未移动文件。", cancelled: true) }
            let index = journal.batches.count
            journal.batches.append(Batch(id: plan.id, date: Date(), app: plan.app, receipts: []))
            try saveJournal()
            var moved: [String] = [], issues: [UninstallIssue] = [], bytes: Int64 = 0
            // Caches first, app last: process/app metadata can still be verified
            // against the selected installed app until its final move.
            let selected = selectedIDs.compactMap { candidates[$0] }.sorted { $0.kind.rawValue > $1.kind.rawValue }
            for candidate in selected {
                let id = candidate.item.id
                if cancelled() { issues.append(UninstallIssue(itemID: id, message: "已取消，未开始此项目。")); continue }
                do {
                    try validateApp(plan.app)
                    try move(candidate, batch: index, cancelled: cancelled)
                    moved.append(id); bytes = FS.add(bytes, candidate.footprint.bytes)
                } catch {
                    issues.append(UninstallIssue(itemID: id, message: error is CancellationError ? "已取消；任何已开始移动的项目仍保留恢复记录。" : error.localizedDescription))
                    if journalFailure != nil { break }
                }
            }
            self.plan = nil; candidates.removeAll()
            return report(plan.id, moved, bytes, issues, "已移入废纸篓 \(moved.count) 项；\(issues.count) 项未完成。占用不会立即释放，可按此批次尝试恢复。", cancelled: cancelled())
        }
    }

    func restore(batchID: String, cancelled: () -> Bool = { false }) -> UninstallReport {
        do {
            return try FS.materializationDisabled {
                if let journalFailure { throw journalFailure }
                try verifyJournal()
                guard let index = journal.batches.firstIndex(where: { $0.id == batchID }) else { throw UninstallFailure(message: "未找到卸载批次。") }
                try requireInactive(journal.batches[index].app)
                var restored: [String] = [], issues: [UninstallIssue] = [], bytes: Int64 = 0
                for r in journal.batches[index].receipts.indices {
                    let receipt = journal.batches[index].receipts[r]
                    if receipt.state == .restored || receipt.state == .untouched { continue }
                    if cancelled() { issues.append(UninstallIssue(itemID: receipt.itemID, message: "恢复已取消，未覆盖任何文件。")); break }
                    do {
                        try requireInactive(journal.batches[index].app)
                        let original = URL(fileURLWithPath: receipt.original)
                        guard let source = try recoverySource(receipt) else {
                            if let footprint = try? FS.snapshot(original, appBundle: receipt.itemKind == .application), footprint == receipt.footprint {
                                journal.batches[index].receipts[r].state = receipt.state == .prepared ? .untouched : .restored
                                try saveJournal(); continue
                            }
                            throw UninstallFailure(message: "未找到原恢复实物；可能已被移动或清空，请检查 Finder 废纸篓。")
                        }
                        guard try FS.snapshot(source, appBundle: receipt.itemKind == .application, cancelled: cancelled) == receipt.footprint else {
                            throw UninstallFailure(message: "恢复实物已变化，未移动或覆盖任何文件。")
                        }
                        let sourceFD = try FS.directory(source.deletingLastPathComponent()); defer { close(sourceFD) }
                        let destinationFD = try FS.directory(original.deletingLastPathComponent()); defer { close(destinationFD) }
                        guard try FS.identity(destinationFD) == receipt.parentIdentity else { throw UninstallFailure(message: "原父目录身份已变化，停止恢复。") }
                        try requireInactive(journal.batches[index].app)
                        guard UninstallIdentity(try FS.info(parent: sourceFD, name: source.lastPathComponent)) == receipt.footprint.identity else {
                            throw UninstallFailure(message: "恢复实物被替换。")
                        }
                        try renameAction(sourceFD, source.lastPathComponent, destinationFD, original.lastPathComponent)
                        do {
                            guard try FS.snapshot(original, appBundle: receipt.itemKind == .application) == receipt.footprint else {
                                throw UninstallFailure(message: "恢复后身份复核未通过。")
                            }
                        } catch {
                            // A pathname may now refer to a newly created object.
                            // Only the exact receipt object may be moved back.
                            if (try? FS.info(parent: destinationFD, name: original.lastPathComponent)).map(UninstallIdentity.init) == receipt.footprint.identity {
                                try? renameAction(destinationFD, original.lastPathComponent, sourceFD, source.lastPathComponent)
                            }
                            throw error
                        }
                        journal.batches[index].receipts[r].state = .restored
                        try saveJournal()
                        restored.append(receipt.itemID); bytes = FS.add(bytes, receipt.footprint.bytes)
                    } catch {
                        issues.append(UninstallIssue(itemID: receipt.itemID, message: error.localizedDescription))
                        if journalFailure != nil { break }
                    }
                }
                plan = nil; candidates.removeAll()
                return report(batchID, restored, bytes, issues, "已恢复 \(restored.count) 项；\(issues.count) 项保留待处理。原位置已有新文件时绝不覆盖。", cancelled: cancelled())
            }
        } catch { return report(batchID, [], 0, [UninstallIssue(itemID: batchID, message: error.localizedDescription)], "恢复未完成：\(error.localizedDescription)") }
    }

    private func move(_ candidate: Candidate, batch: Int, cancelled: () -> Bool) throws {
        guard let path = candidate.item.path else { throw UninstallFailure(message: "无效项目。") }
        let source = URL(fileURLWithPath: path)
        let sourceFD = try FS.directory(source.deletingLastPathComponent()); defer { close(sourceFD) }
        guard try FS.identity(sourceFD) == candidate.parentIdentity,
              try FS.snapshot(source, appBundle: candidate.kind == .application, cancelled: cancelled) == candidate.footprint else {
            throw UninstallFailure(message: "项目或父目录在复核后改变，请重新扫描。")
        }
        let stageFD = try FS.directory(stageDirectory, create: true, privateOnly: true); defer { close(stageFD) }
        guard try FS.identity(stageFD).device == candidate.footprint.identity.device else {
            throw UninstallFailure(message: "应用与私有恢复区不在同一磁盘；此版本不跨卷卸载。")
        }
        let receiptID = UUID().uuidString
        let stage = stageDirectory.appendingPathComponent("GaoJiLing-Uninstall-" + receiptID)
        let app = journal.batches[batch].app
        var receipt = UninstallReceipt(id: receiptID, itemID: candidate.item.id, original: path, stage: stage.path,
            trash: nil, owner: app.bundleID, category: candidate.item.category, itemKind: candidate.kind,
            footprint: candidate.footprint, parentIdentity: candidate.parentIdentity, state: .prepared)
        let r = journal.batches[batch].receipts.count
        journal.batches[batch].receipts.append(receipt)
        try saveJournal()
        do {
            if cancelled() { throw CancellationError() }
            try requireInactive(app)
            guard UninstallIdentity(try FS.info(parent: sourceFD, name: source.lastPathComponent)) == candidate.footprint.identity else {
                throw UninstallFailure(message: "最后身份复核未通过。")
            }
            try renameAction(sourceFD, source.lastPathComponent, stageFD, stage.lastPathComponent)
            receipt.state = .staged; journal.batches[batch].receipts[r] = receipt; try saveJournal()
            guard try FS.snapshot(stage, appBundle: candidate.kind == .application) == candidate.footprint else {
                throw UninstallFailure(message: "暂存后完整复核未通过，尝试原样回退。")
            }
            if cancelled() { throw CancellationError() }
            try requireInactive(app)
            if !injectedTrash {
                let destination = try FileManager.default.url(for: .trashDirectory, in: .userDomainMask, appropriateFor: stage, create: true)
                receipt.trash = destination.appendingPathComponent(stage.lastPathComponent).path
            }
            receipt.state = .trashing; journal.batches[batch].receipts[r] = receipt; try saveJournal()
            let destination = try trashAction(stage)
            guard allowedTrash(destination), destination.lastPathComponent.hasPrefix(stage.lastPathComponent) else {
                throw UninstallFailure(message: "系统返回了非预期的废纸篓位置，恢复记录已保留。")
            }
            receipt.trash = destination.path; journal.batches[batch].receipts[r] = receipt; try saveJournal()
            guard try FS.snapshot(destination, appBundle: candidate.kind == .application) == candidate.footprint else {
                throw UninstallFailure(message: "移入废纸篓后复核未通过，请保留恢复记录和文件。")
            }
            receipt.state = .trashed; journal.batches[batch].receipts[r] = receipt; try saveJournal()
        } catch {
            let failure = error
            // If the system already moved it, keep the pending receipt; if our
            // stage still exists, return that exact object without overwriting.
            if (try? FS.info(parent: stageFD, name: stage.lastPathComponent)).map(UninstallIdentity.init) == receipt.footprint.identity {
                do {
                    try renameAction(stageFD, stage.lastPathComponent, sourceFD, source.lastPathComponent)
                    guard try FS.snapshot(source, appBundle: candidate.kind == .application) == candidate.footprint else { throw failure }
                    journal.batches[batch].receipts[r].state = .untouched
                    try saveJournal()
                } catch { /* Durable receipt remains for explicit recovery. */ }
            } else if receipt.state == .prepared,
                      (try? FS.snapshot(source, appBundle: candidate.kind == .application)) == candidate.footprint {
                journal.batches[batch].receipts[r].state = .untouched; try? saveJournal()
            }
            throw failure
        }
    }

    private func inspectApp(_ url: URL) throws -> InstalledApp {
        guard validAppPath(url) else { throw UninstallFailure(message: "请选择 /Applications 或个人 Applications 内的真实 .app；其他位置本版不处理。") }
        let root = try FS.info(url)
        let identity = UninstallIdentity(root)
        guard identity.kind == UInt32(S_IFDIR), identity.uid == getuid() || identity.uid == 0 else {
            throw UninstallFailure(message: "应用不是普通目录或属于其他用户。")
        }
        let appFD = try FS.directory(url); defer { close(appFD) }
        guard try FS.identity(appFD) == identity else { throw UninstallFailure(message: "应用在固定描述符时被替换。") }
        let contents = try FS.directory(url.appendingPathComponent("Contents")); defer { close(contents) }
        let data = try FS.data(parent: contents, name: "Info.plist", limit: 1_048_576)
        guard let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let bundleID = info["CFBundleIdentifier"] as? String, validBundleID(bundleID),
              info["CFBundlePackageType"] as? String == "APPL",
              let executable = info["CFBundleExecutable"] as? String,
              !executable.isEmpty, executable != ".", executable != "..", !executable.contains("/") else {
            throw UninstallFailure(message: "应用元数据不完整，无法确认归属。")
        }
        let binary = try FS.info(url.appendingPathComponent("Contents/MacOS").appendingPathComponent(executable))
        guard binary.st_mode & S_IFMT == S_IFREG, binary.st_nlink == 1 else { throw UninstallFailure(message: "应用执行文件不是独立普通文件。") }
        let protected = protection(bundleID: bundleID, path: url.path)
        var vendor: String?
        if let privileged = info["SMPrivilegedExecutables"] as? [String: Any], !privileged.isEmpty {
            vendor = "此应用声明特权 helper；请使用厂商支持的卸载方法。"
        }
        for component in ["Contents/Library/LoginItems", "Contents/Library/LaunchServices", "Contents/Library/SystemExtensions", "Contents/Library/Extensions"] {
            if try FS.optionalInfo(url.appendingPathComponent(component)) != nil {
                vendor = "此应用包含登录项、helper 或扩展组件；请按厂商说明卸载，不能只删应用包。"
            }
        }
        for directory in [home.appendingPathComponent("Library/LaunchAgents"), URL(fileURLWithPath: "/Library/LaunchAgents"), URL(fileURLWithPath: "/Library/LaunchDaemons")] {
            if try FS.optionalInfo(directory.appendingPathComponent(bundleID + ".plist")) != nil {
                vendor = "发现同标识的启动配置；不会删除 launchd 文件，请使用厂商卸载流程。"
            }
        }
        guard try FS.identity(appFD) == identity, UninstallIdentity(try FS.info(url)) == identity else { throw UninstallFailure(message: "应用在读取时被替换。") }
        return InstalledApp(path: url.path, name: (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String) ?? url.deletingPathExtension().lastPathComponent,
            bundleID: bundleID, version: (info["CFBundleShortVersionString"] as? String) ?? "未知",
            identity: identity, metadataHash: FS.hash(data), protectedReason: protected, vendorUninstallReason: vendor)
    }
    private func validateApp(_ expected: InstalledApp) throws {
        let fresh = try inspectApp(URL(fileURLWithPath: expected.path))
        guard fresh == expected else { throw UninstallFailure(message: "应用身份或配置已改变，原复核不再有效。") }
        if let reason = fresh.protectedReason ?? fresh.vendorUninstallReason { throw UninstallFailure(message: reason) }
        try requireInactive(fresh)
    }
    private func requireInactive(_ app: InstalledApp) throws {
        guard running(app) == false else { throw UninstallFailure(message: "应用或相关进程仍在运行，或状态未知，已保留文件。") }
    }
    private func protection(bundleID: String, path: String) -> String? {
        if bundleID.hasPrefix("com.apple.") || path == "/System" || path.hasPrefix("/System/") {
            return "Apple 系统管理应用受保护，本应用不卸载。"
        }
        if bundleID.hasPrefix("com.gaoseries.") || bundleID == "cn.mendao.launcher" || URL(fileURLWithPath: path).lastPathComponent.hasPrefix("搞") {
            return "所有搞系列应用及其资料受保护，请通过各应用的升级或专用卸载流程处理。"
        }
        return nil
    }
    private func validBundleID(_ id: String) -> Bool {
        id.count <= 255 && id.range(of: #"^[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+$"#, options: .regularExpression) != nil
    }
    private func descendant(_ url: URL, of root: URL) -> Bool {
        let parts = url.pathComponents, prefix = root.pathComponents
        return parts.count > prefix.count && Array(parts.prefix(prefix.count)) == prefix
    }
    private func validAppPath(_ url: URL) -> Bool {
        guard FS.validURL(url), url.pathExtension == "app",
              !url.path.hasPrefix("/System/"), !url.pathComponents.dropLast().contains(where: { $0.hasSuffix(".app") }) else { return false }
        return applicationRoots.contains { descendant(url, of: $0) }
    }
    private func trashDirectories() -> [URL] {
        var roots = [home.appendingPathComponent(".Trash", isDirectory: true)]
        if !injectedTrash, let system = try? FileManager.default.url(for: .trashDirectory, in: .userDomainMask, appropriateFor: home, create: false),
           !roots.contains(system) { roots.append(system) }
        return roots
    }
    private func allowedTrash(_ url: URL) -> Bool {
        FS.validURL(url) && trashDirectories().contains { url.deletingLastPathComponent() == $0 }
    }
    private func recoverySource(_ receipt: UninstallReceipt) throws -> URL? {
        let stage = URL(fileURLWithPath: receipt.stage)
        if try FS.optionalInfo(stage) != nil { return stage }
        if let path = receipt.trash {
            let known = URL(fileURLWithPath: path)
            if try FS.optionalInfo(known) != nil { return known }
        }
        guard receipt.state == .trashing else { return nil }
        // Only an interrupted native Trash call without its returned URL needs
        // name lookup; normal restore never enumerates the user's Trash.
        for root in trashDirectories() {
            let fd: Int32
            do { fd = try FS.directory(root, read: true) }
            catch {
                if FS.missing(error) { continue }
                throw UninstallFailure(message: "无法定位中断的移动。请在 Finder 废纸篓查找 GaoJiLing-Uninstall-\(receipt.id)；文件未删除。")
            }
            defer { close(fd) }
            for name in try FS.names(fd, cancelled: { false }) where name.hasPrefix(stage.lastPathComponent) {
                let url = root.appendingPathComponent(name)
                if (try? FS.snapshot(url, appBundle: receipt.itemKind == .application)) == receipt.footprint { return url }
            }
        }
        return nil
    }
    private func valid(_ receipt: UninstallReceipt, app: InstalledApp) -> Bool {
        guard UUID(uuidString: receipt.id) != nil, UUID(uuidString: receipt.itemID) != nil,
              validStoredApp(app), receipt.owner == app.bundleID,
              protection(bundleID: app.bundleID, path: app.path) == nil, validAppPath(URL(fileURLWithPath: app.path)),
              receipt.footprint.bytes >= 0, receipt.footprint.newest.isFinite, receipt.footprint.entries > 0,
              validDigest(receipt.footprint.digest), receipt.footprint.identity.kind == UInt32(S_IFDIR),
              receipt.parentIdentity.kind == UInt32(S_IFDIR), receipt.parentIdentity.device == receipt.footprint.identity.device,
              receipt.footprint.identity.uid == getuid() || (receipt.itemKind == .application && receipt.footprint.identity.uid == 0),
              receipt.stage == stageDirectory.appendingPathComponent("GaoJiLing-Uninstall-" + receipt.id).path else { return false }
        if let trash = receipt.trash, !allowedTrash(URL(fileURLWithPath: trash)) || !URL(fileURLWithPath: trash).lastPathComponent.hasPrefix("GaoJiLing-Uninstall-" + receipt.id) { return false }
        switch receipt.itemKind {
        case .application: return receipt.original == app.path && receipt.footprint.identity == app.identity
        case .cache: return receipt.original == home.appendingPathComponent("Library/Caches").appendingPathComponent(app.bundleID).path
        }
    }
    private func validDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    private func validStoredApp(_ app: InstalledApp) -> Bool {
        validBundleID(app.bundleID) && validAppPath(URL(fileURLWithPath: app.path)) &&
            app.identity.kind == UInt32(S_IFDIR) && (app.identity.uid == getuid() || app.identity.uid == 0) &&
            validDigest(app.metadataHash) && protection(bundleID: app.bundleID, path: app.path) == nil &&
            app.protectedReason == nil && app.vendorUninstallReason == nil
    }
    private func journalData() throws -> Data? {
        do {
            let fd = try FS.directory(journalDirectory, privateOnly: true); defer { close(fd) }
            let info: stat
            do { info = try FS.info(parent: fd, name: "journal.json") } catch { if FS.missing(error) { return nil }; throw error }
            guard info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { throw UninstallFailure(message: "恢复记录权限无效。") }
            return try FS.data(parent: fd, name: "journal.json", limit: 16 * 1024 * 1024)
        } catch { if FS.missing(error) { return nil }; throw error }
    }
    private func loadJournal() throws {
        markerPresent = try readMarker()
        guard let data = try journalData() else {
            guard !markerPresent else { throw UninstallFailure(message: "卸载恢复记录已丢失，不能作为首次使用覆盖。请保留废纸篓与暂存文件，从安全备份恢复记录。") }
            // Orphaned private staging is also evidence of an earlier operation.
            do {
                let fd = try FS.directory(stageDirectory, read: true, privateOnly: true); defer { close(fd) }
                guard try FS.names(fd, cancelled: { false }).isEmpty else { throw UninstallFailure(message: "存在未归档卸载暂存文件但缺少记录，已停止操作。") }
            } catch { if !FS.missing(error) { throw error } }
            return
        }
        let loaded = try JSONDecoder().decode(Journal.self, from: data)
        let receiptIDs = loaded.batches.flatMap { $0.receipts.map(\.id) }
        guard loaded.version == 1, Set(loaded.batches.map(\.id)).count == loaded.batches.count,
              receiptIDs.count <= 10_000, Set(receiptIDs).count == receiptIDs.count,
              loaded.batches.allSatisfy({ batch in UUID(uuidString: batch.id) != nil && batch.date.timeIntervalSince1970.isFinite &&
                  validStoredApp(batch.app) && batch.receipts.allSatisfy { valid($0, app: batch.app) } }) else {
            throw UninstallFailure(message: "卸载恢复记录格式或路径无法识别，已停止操作；不会覆盖为空记录。")
        }
        journal = loaded; savedJournalHash = FS.hash(data)
        // A validated pre-marker journal is evidence of prior use. Migrate the
        // separate marker now, without changing any existing journal bytes.
        try ensureMarker()
    }
    private func verifyJournal() throws {
        do {
            guard try readMarker() == markerPresent else { throw UninstallFailure(message: "卸载初始化标记被外部改变，已停止操作。") }
            guard try journalData().map(FS.hash) == savedJournalHash else { throw UninstallFailure(message: "卸载恢复记录被外部改变，已停止所有移动。") }
        } catch { journalFailure = error; throw error }
    }
    private func saveJournal() throws {
        if let journalFailure { throw journalFailure }
        do {
            try verifyJournal()
            try ensureMarker()
            let fd = try FS.directory(journalDirectory, create: true, privateOnly: true); defer { close(fd) }
            let data = try JSONEncoder().encode(journal)
            guard data.count <= 16 * 1024 * 1024 else { throw UninstallFailure(message: "卸载恢复记录超过安全上限，未继续移动。") }
            try journalWriter(data, fd)
            savedJournalHash = FS.hash(data)
        } catch { journalFailure = error; throw error }
    }
    private func readMarker() throws -> Bool {
        do {
            let parent = try FS.directory(initializationMarkerURL.deletingLastPathComponent()); defer { close(parent) }
            let info = try FS.info(parent: parent, name: initializationMarkerURL.lastPathComponent)
            guard info.st_uid == getuid(), info.st_mode & 0o077 == 0,
                  try FS.data(parent: parent, name: initializationMarkerURL.lastPathComponent, limit: 128) == Self.marker else {
                throw UninstallFailure(message: "卸载初始化标记无效，已停止操作。")
            }
            return true
        } catch { if FS.missing(error) { return false }; throw error }
    }
    private func ensureMarker() throws {
        if markerPresent { return }
        let parent = try FS.directory(initializationMarkerURL.deletingLastPathComponent(), create: true); defer { close(parent) }
        guard try FS.identity(parent).uid == getuid() else { throw UninstallFailure(message: "初始化标记目录不属于当前用户。") }
        // Exclusive creation, rather than overwriting, makes a raced marker a
        // conflict. Its durability precedes the first journal and every move.
        let fd = openat(parent, initializationMarkerURL.lastPathComponent, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw FS.failure("无法创建卸载初始化标记") }
        defer { close(fd) }
        try Self.marker.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if written < 0 { if errno == EINTR { continue }; throw FS.failure("初始化标记写入失败") }
                guard written > 0 else { throw UninstallFailure(message: "初始化标记未完整保存。") }
                offset += written
            }
        }
        guard fsync(fd) == 0, fsync(parent) == 0 else { throw FS.failure("初始化标记未持久保存") }
        markerPresent = true
    }
    private func report(_ id: String?, _ moved: [String], _ bytes: Int64, _ issues: [UninstallIssue], _ message: String, cancelled: Bool = false) -> UninstallReport {
        UninstallReport(batchID: id, movedIDs: moved, movedBytes: bytes, issues: issues, message: message, cancelled: cancelled)
    }
}
