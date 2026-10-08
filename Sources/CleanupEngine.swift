import Foundation
import AppKit
import CryptoKit
import Darwin

struct CleanupItem: Identifiable {
    let id: String
    let category: String
    let name: String
    let displayPath: String
    let bytes: Int64
    let reason: String?
}

struct CleanupIssue {
    let itemID: String
    let message: String
}

struct CleanupReport {
    let removedIDs: [String]
    let movedBytes: Int64
    let skipped: [CleanupIssue]
    let failed: [CleanupIssue]
    let message: String
}

struct CleanupScanResult {
    let items: [CleanupItem]
    let notes: [String]
    let skippedCount: Int
}

struct CleanupHistoryEntry: Identifiable {
    let id: String
    let date: Date
    let itemCount: Int
    let bytes: Int64
    let restorableCount: Int
    let summary: String
}

/// The caller serializes operations. Candidates are metadata-only snapshots;
/// this engine never permanently deletes candidate data or empties the Trash.
/// Descriptor-relative staging reduces pathname races, but is not a claim of
/// race freedom against another process with the same user's privileges.
final class CleanupEngine: @unchecked Sendable {
    typealias RunningLookup = @Sendable (String) -> Bool?
    typealias OwnerLookup = @Sendable (String) -> Bool?
    typealias TrashAction = @Sendable (URL) throws -> URL

    private struct Failure: LocalizedError {
        let text: String
        var errorDescription: String? { text }
    }
    private struct Identity: Codable, Equatable {
        let device: UInt64
        let inode: UInt64
        let kind: UInt32
        init(_ value: stat) {
            device = UInt64(bitPattern: Int64(value.st_dev))
            inode = UInt64(value.st_ino)
            kind = UInt32(value.st_mode & S_IFMT)
        }
    }
    private struct Footprint: Codable, Equatable {
        let identity: Identity
        let digest: String
        let bytes: Int64
        let newest: TimeInterval
        let entries: Int
    }
    private struct Candidate {
        let item: CleanupItem
        let url: URL
        let root: URL
        let rootIdentity: Identity
        let owner: String
        let footprint: Footprint
        let age: TimeInterval
    }
    private enum ReceiptState: String, Codable { case prepared, staged, trashing, trashed, restored, untouched }
    private struct Receipt: Codable {
        let id: String
        let itemID: String
        let original: String
        let stage: String
        var trash: String?
        let owner: String
        let category: String
        let footprint: Footprint
        var state: ReceiptState
    }
    private struct Batch: Codable {
        let id: String
        let date: Date?
        var receipts: [Receipt]
    }
    private struct Journal: Codable {
        var version = 1
        var batches: [Batch] = []
    }

    private let home: URL
    private let journalDirectory: URL
    private let stageDirectory: URL
    private let running: RunningLookup
    private let ownerLookup: OwnerLookup
    private let trashAction: TrashAction
    private let injectedTrash: Bool
    private var plan: [String: Candidate] = [:]
    private var journal = Journal()
    private var journalFailure: Error?
    private var savedJournalHash: String?
    private let uid = getuid()
    private let maxEntries = 100_000
    private let cacheAge: TimeInterval = 7 * 24 * 60 * 60
    private let logAge: TimeInterval = 30 * 24 * 60 * 60
    private static let developmentRules: [(owner: String, path: String)] = [
        ("developer.npm", ".npm/_cacache"),
        ("developer.pip", "Library/Caches/pip"),
        ("developer.pypoetry", "Library/Caches/pypoetry"),
        ("developer.homebrew", "Library/Caches/Homebrew"),
        ("developer.gradle", ".gradle/caches")
    ]

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser, journalDirectory: URL? = nil,
         appIsRunning: @escaping RunningLookup,
         trash: TrashAction? = nil,
         ownerLookup: @escaping OwnerLookup = { identifier in
             NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) != nil
         }) {
        self.home = home
        self.journalDirectory = (journalDirectory ?? home.appendingPathComponent("Library/Application Support/GaoSeries/GaoJiLing/Cleanup", isDirectory: true))
        stageDirectory = home.appendingPathComponent("Library/Caches/.GaoJiLing-CleanupStage", isDirectory: true)
        running = appIsRunning
        self.ownerLookup = ownerLookup
        injectedTrash = trash != nil
        trashAction = trash ?? { url in
            var result: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &result)
            guard let result else { throw Failure(text: "系统未返回废纸篓位置，文件未确认。") }
            return result as URL
        }
        do { try withoutMaterializing { try loadJournal() } }
        catch { journalFailure = error }
    }

    var canRestore: Bool {
        journalFailure == nil && journal.batches.contains { batch in
            batch.receipts.contains { $0.state != .restored && $0.state != .untouched }
        }
    }

    var history: [CleanupHistoryEntry] {
        guard journalFailure == nil else { return [] }
        return journal.batches.reversed().compactMap { batch in
            let receipts = batch.receipts.filter { $0.state != .untouched }
            guard !receipts.isEmpty else { return nil }
            let pending = receipts.filter { $0.state != .restored }.count
            let bytes = receipts.reduce(Int64(0)) { adding($0, $1.footprint.bytes) }
            let summary = pending > 0 ? "\(pending) 项待尝试恢复，恢复时不会覆盖原位置的新文件。" : "此批次已恢复。"
            return CleanupHistoryEntry(id: batch.id, date: batch.date ?? Date(timeIntervalSince1970: 0),
                itemCount: receipts.count, bytes: bytes, restorableCount: pending,
                summary: batch.date == nil ? "早期记录，未记录时间。" + summary : summary)
        }
    }

    func scan(cancelled: @Sendable () -> Bool = { false }) throws -> CleanupScanResult {
        try withoutMaterializing { try scanImpl(cancelled: cancelled) }
    }

    private func scanImpl(cancelled: @Sendable () -> Bool) throws -> CleanupScanResult {
        plan.removeAll()
        if let journalFailure { throw Failure(text: "清理恢复记录无法读取，已停止操作：\(journalFailure.localizedDescription)") }
        var items: [CleanupItem] = []
        var skipped = 0
        var notes = ["仅检查明确归属的应用缓存及已知开发工具缓存，要求相关进程已退出且至少 7 天未修改；未知归属及运行状态不明的项目跳过。",
                     "系统管理的 com.apple.* 缓存与日志不作清理；Xcode 仅检查单独列出的可重建构建目录。",
                     "旧轮转日志保留至少 30 天；日志属于历史记录，移走后不能重新生成。",
                     "占用为磁盘分配大小估算；移入废纸篓仍占空间，可随后恢复。"]
        let now = Date().timeIntervalSince1970
        let caches = home.appendingPathComponent("Library/Caches", isDirectory: true)
        let logs = home.appendingPathComponent("Library/Logs", isDirectory: true)
        let derived = home.appendingPathComponent("Library/Developer/Xcode/DerivedData", isDirectory: true)

        func add(_ url: URL, root: URL, owner: String, category: String, age: TimeInterval) {
            guard !cancelled() else { return }
            do {
                // Reject recently modified roots using only parent-relative
                // metadata. Do not request directory read access just to learn
                // that a cache is too recent to clean (notably protected caches).
                let parentFD = try openDirectory(url.deletingLastPathComponent(), searchOnly: true)
                defer { close(parentFD) }
                var top = stat()
                guard fstatat(parentFD, url.lastPathComponent, &top, AT_SYMLINK_NOFOLLOW) == 0 else { throw posix("无法读取项目根属性") }
                let expectedKind = category == "旧轮转日志" ? S_IFREG : S_IFDIR
                guard top.st_mode & S_IFMT == expectedKind, top.st_flags & UInt32(SF_DATALESS) == 0,
                      top.st_uid == uid, expectedKind != S_IFREG || top.st_nlink == 1,
                      now - (Double(top.st_mtimespec.tv_sec) + Double(top.st_mtimespec.tv_nsec) / 1_000_000_000) >= age else {
                    skipped += 1; return
                }
                if cancelled() { return }
                try requireInactive(owner, checkInstalled: category != "开发工具缓存")
                let rootFD = try openDirectory(root)
                defer { close(rootFD) }
                let rootID = try identity(of: rootFD)
                let footprint = try snapshot(url, on: rootID.device, cancelled: cancelled)
                guard footprint.identity.kind == UInt32(category == "旧轮转日志" ? S_IFREG : S_IFDIR) else { skipped += 1; return }
                guard now - footprint.newest >= age else { skipped += 1; return }
                let item = CleanupItem(id: UUID().uuidString, category: category, name: url.lastPathComponent,
                    displayPath: displayPath(url), bytes: footprint.bytes,
                    reason: category == "旧轮转日志" ? "超过 30 天的历史日志，不可重新生成" : "至少 7 天未修改；所属应用已退出")
                plan[item.id] = Candidate(item: item, url: url, root: root, rootIdentity: rootID,
                                          owner: owner, footprint: footprint, age: age)
                items.append(item)
            } catch is CancellationError { return }
            catch { skipped += 1 }
        }
        func children(_ root: URL) -> [String] {
            do { return try directoryNames(root, cancelled: cancelled) }
            catch is CancellationError { return [] }
            catch {
                if !isMissing(error) { notes.append("\(displayPath(root)) 无法安全读取，已跳过。") }
                return []
            }
        }
        for name in children(caches) {
            if cancelled() { break }
            guard !name.hasPrefix("com.gaoseries."), !name.hasPrefix("com.apple."), validBundleID(name) else { skipped += 1; continue }
            add(caches.appendingPathComponent(name), root: caches, owner: name, category: "应用缓存", age: cacheAge)
        }
        for rule in Self.developmentRules {
            if cancelled() { break }
            let url = home.appendingPathComponent(rule.path, isDirectory: true)
            add(url, root: url.deletingLastPathComponent(), owner: rule.owner, category: "开发工具缓存", age: cacheAge)
        }
        if !cancelled() {
            for owner in children(logs) {
                if cancelled() { break }
                guard !owner.hasPrefix("com.gaoseries."), !owner.hasPrefix("com.apple."), validBundleID(owner), ownerLookup(owner) == true, running(owner) == false else { skipped += 1; continue }
                let directory = logs.appendingPathComponent(owner, isDirectory: true)
                for name in children(directory) {
                    if cancelled() { break }
                    guard isRotatedLog(name) else { skipped += 1; continue }
                    add(directory.appendingPathComponent(name), root: logs, owner: owner, category: "旧轮转日志", age: logAge)
                }
            }
        }
        if !cancelled(), ownerLookup("com.apple.dt.Xcode") == true, running("com.apple.dt.Xcode") == false {
            for name in children(derived) {
                if cancelled() { break }
                if ["ModuleCache.noindex", "SDKStatCaches.noindex", "CompilationCache.noindex"].contains(name) {
                    add(derived.appendingPathComponent(name), root: derived, owner: "com.apple.dt.Xcode", category: "Xcode 构建", age: cacheAge)
                } else if !name.hasPrefix(".") {
                    // Never remove the complete project directory or SourcePackages.
                    for leaf in ["Intermediates.noindex", "Products"] {
                        let url = derived.appendingPathComponent(name).appendingPathComponent("Build").appendingPathComponent(leaf)
                        add(url, root: derived, owner: "com.apple.dt.Xcode", category: "Xcode 构建", age: cacheAge)
                    }
                }
            }
        }
        if cancelled() { notes.append("扫描已取消，仅保留已完成检查的项目。") }
        return CleanupScanResult(items: items.sorted { $0.bytes > $1.bytes }, notes: notes, skippedCount: skipped)
    }

    func trash(ids: Set<String>, cancelled: () -> Bool = { false }) throws -> CleanupReport {
        try withoutMaterializing { try trashImpl(ids: ids, cancelled: cancelled) }
    }

    private func trashImpl(ids: Set<String>, cancelled: () -> Bool) throws -> CleanupReport {
        if let journalFailure { throw journalFailure }
        var removed: [String] = [], skipped: [CleanupIssue] = [], failed: [CleanupIssue] = []
        var bytes: Int64 = 0
        guard !ids.isEmpty else { return report(removed, bytes, skipped, failed, "未选择项目。") }
        let batchIndex = journal.batches.count
        journal.batches.append(Batch(id: UUID().uuidString, date: Date(), receipts: []))
        try saveJournal()
        for id in ids.sorted() {
            if cancelled() { skipped.append(CleanupIssue(itemID: id, message: "操作已取消。")); continue }
            guard let candidate = plan[id] else { skipped.append(CleanupIssue(itemID: id, message: "扫描结果已失效，请重新扫描。")); continue }
            var prepared = false
            do {
                try requireInactive(candidate.owner, checkInstalled: candidate.item.category != "开发工具缓存")
                let rootFD = try openDirectory(candidate.root)
                defer { close(rootFD) }
                guard try identity(of: rootFD) == candidate.rootIdentity else { throw Failure(text: "扫描目录已改变，请重新扫描。") }
                guard try snapshot(candidate.url, on: candidate.rootIdentity.device, cancelled: cancelled) == candidate.footprint else {
                    throw Failure(text: "文件在扫描后发生变化，已跳过。")
                }
                guard Date().timeIntervalSince1970 - candidate.footprint.newest >= candidate.age else { throw Failure(text: "项目未达到保留期限。") }
                let stageFD = try openPrivateDirectory(stageDirectory, create: true)
                defer { close(stageFD) }
                guard try identity(of: stageFD).device == candidate.rootIdentity.device else { throw Failure(text: "暂存目录不在同一磁盘，已跳过。") }
                let receiptID = UUID().uuidString
                let stage = stageDirectory.appendingPathComponent("GaoJiLing-\(receiptID)")
                let receiptIndex = journal.batches[batchIndex].receipts.count
                journal.batches[batchIndex].receipts.append(Receipt(id: receiptID, itemID: id, original: candidate.url.path,
                    stage: stage.path, trash: nil, owner: candidate.owner, category: candidate.item.category,
                    footprint: candidate.footprint, state: .prepared))
                prepared = true
                try saveJournal() // Intent is durable before touching the source.
                let sourceFD = try openDirectory(candidate.url.deletingLastPathComponent(), searchOnly: true)
                defer { close(sourceFD) }
                try requireInactive(candidate.owner, checkInstalled: candidate.item.category != "开发工具缓存")
                if cancelled() { throw CancellationError() }
                try renameExclusive(from: sourceFD, name: candidate.url.lastPathComponent, to: stageFD, name: stage.lastPathComponent)
                journal.batches[batchIndex].receipts[receiptIndex].state = .staged
                try saveJournal()
                do {
                    guard try snapshot(stage, on: candidate.rootIdentity.device, cancelled: cancelled) == candidate.footprint else {
                        throw Failure(text: "移动期间文件发生变化，已停止并尝试放回。")
                    }
                    try requireInactive(candidate.owner, checkInstalled: candidate.item.category != "开发工具缓存")
                    if cancelled() { throw CancellationError() }
                    journal.batches[batchIndex].receipts[receiptIndex].state = .trashing
                    if !injectedTrash {
                        // A unique staged basename normally survives the system
                        // move. Persist this exact recovery path before invoking
                        // Trash, so a crash need not enumerate private Trash data.
                        let directory = try FileManager.default.url(for: .trashDirectory, in: .userDomainMask,
                                                                    appropriateFor: stage, create: false)
                        journal.batches[batchIndex].receipts[receiptIndex].trash = directory.appendingPathComponent(stage.lastPathComponent).path
                    }
                    try saveJournal()
                    let destination = try trashAction(stage)
                    // Record the system's actual destination before further verification.
                    journal.batches[batchIndex].receipts[receiptIndex].trash = destination.path
                    journal.batches[batchIndex].receipts[receiptIndex].state = .trashed
                    try saveJournal()
                    guard allowedTrashURL(destination),
                          try snapshot(destination, on: candidate.rootIdentity.device) == candidate.footprint else {
                        throw Failure(text: "废纸篓项目未通过核验，已保留恢复记录，请使用恢复。")
                    }
                    removed.append(id)
                    bytes = adding(bytes, candidate.footprint.bytes)
                    plan.removeValue(forKey: id)
                } catch {
                    if safelyExists(stage) {
                        do {
                            // Never overwrite a cache recreated by the owning app.
                            try renameExclusive(from: stageFD, name: stage.lastPathComponent, to: sourceFD, name: candidate.url.lastPathComponent)
                            journal.batches[batchIndex].receipts[receiptIndex].state = .restored
                            try saveJournal()
                        } catch {
                            failed.append(CleanupIssue(itemID: id, message: "项目保留在安全暂存区；原位置已占用或无法放回，请使用恢复。"))
                        }
                    }
                    throw error
                }
            } catch {
                let issue = CleanupIssue(itemID: id, message: error.localizedDescription)
                if prepared { failed.append(issue) } else { skipped.append(issue) }
            }
        }
        return report(removed, bytes, skipped, failed,
                      "已将 \(removed.count) 项移入废纸篓；这些文件仍占磁盘空间，可使用恢复。")
    }

    func restoreLastCleanup() -> CleanupReport {
        if let journalFailure { return report([], 0, [], [CleanupIssue(itemID: "journal", message: journalFailure.localizedDescription)], "恢复记录无法读取，未改动文件。") }
        guard let batch = journal.batches.last(where: { $0.receipts.contains { $0.state != .restored && $0.state != .untouched } }) else {
            return report([], 0, [], [], "没有可恢复的清理记录。")
        }
        return restore(batchID: batch.id)
    }

    func restore(batchID: String) -> CleanupReport {
        do { return try withoutMaterializing { restoreImpl(batchID: batchID) } }
        catch { return report([], 0, [], [CleanupIssue(itemID: batchID, message: error.localizedDescription)], "无法安全访问文件，未继续恢复。") }
    }

    private func restoreImpl(batchID: String) -> CleanupReport {
        var restored: [String] = [], skipped: [CleanupIssue] = [], failed: [CleanupIssue] = []
        var bytes: Int64 = 0
        if let journalFailure { return report([], 0, [], [CleanupIssue(itemID: "journal", message: journalFailure.localizedDescription)], "恢复记录无法读取，未改动文件。") }
        do { try verifyJournal() }
        catch { return report([], 0, [], [CleanupIssue(itemID: "journal", message: error.localizedDescription)], "恢复记录发生变化，未改动文件。") }
        guard let batchIndex = journal.batches.firstIndex(where: { $0.id == batchID }) else {
            return report([], 0, [CleanupIssue(itemID: batchID, message: "找不到这条清理记录。")], [], "未改动文件。")
        }
        for index in journal.batches[batchIndex].receipts.indices.reversed() {
            let receipt = journal.batches[batchIndex].receipts[index]
            if receipt.state == .restored || receipt.state == .untouched { continue }
            do {
                guard validReceipt(receipt) else { throw Failure(text: "恢复路径无效，未改动文件。") }
                try requireInactive(receipt.owner, checkInstalled: false)
                let original = URL(fileURLWithPath: receipt.original)
                let source = try recoverySource(receipt)
                guard let source else {
                    if safelyExists(original),
                       try snapshot(original, on: receipt.footprint.identity.device) == receipt.footprint {
                        journal.batches[batchIndex].receipts[index].state = receipt.state == .prepared ? .untouched : .restored
                        try saveJournal()
                        continue
                    }
                    throw Failure(text: "未找到可核验的原项目；可能已在废纸篓中手动处理。")
                }
                guard try snapshot(source, on: receipt.footprint.identity.device) == receipt.footprint else {
                    throw Failure(text: "待恢复内容发生变化，已保留文件，未覆盖原位置。")
                }
                let parentFD = try openDirectory(original.deletingLastPathComponent(), searchOnly: true)
                defer { close(parentFD) }
                let sourceFD = try openDirectory(source.deletingLastPathComponent(), searchOnly: true)
                defer { close(sourceFD) }
                try requireInactive(receipt.owner, checkInstalled: false)
                try renameExclusive(from: sourceFD, name: source.lastPathComponent, to: parentFD, name: original.lastPathComponent)
                do {
                    guard try snapshot(original, on: receipt.footprint.identity.device) == receipt.footprint else {
                        throw Failure(text: "恢复移动期间内容发生变化，未确认恢复成功。")
                    }
                } catch {
                    // Return an unexpected moved object without following it or
                    // overwriting a Trash entry created during this interval.
                    do { try renameExclusive(from: parentFD, name: original.lastPathComponent, to: sourceFD, name: source.lastPathComponent) }
                    catch { throw Failure(text: "恢复内容发生变化且无法安全放回；文件已保留，请检查原位置和废纸篓。") }
                    throw error
                }
                journal.batches[batchIndex].receipts[index].state = .restored
                try saveJournal()
                restored.append(receipt.itemID)
                bytes = adding(bytes, receipt.footprint.bytes)
            } catch {
                let message = error.localizedDescription
                if (error as NSError).code == Int(EEXIST) {
                    skipped.append(CleanupIssue(itemID: receipt.itemID, message: "原位置已有新文件，未覆盖；清理项目仍可在废纸篓或暂存区找回。"))
                } else { failed.append(CleanupIssue(itemID: receipt.itemID, message: message)) }
            }
        }
        return report(restored, bytes, skipped, failed, "已恢复 \(restored.count) 项；冲突项目不会覆盖原位置。")
    }

    private func requireInactive(_ owner: String, checkInstalled: Bool = true) throws {
        if checkInstalled && ownerLookup(owner) != true { throw Failure(text: "无法确认所属应用，已跳过。") }
        guard let active = running(owner) else { throw Failure(text: "无法确认应用及后台进程状态，已跳过。") }
        guard !active else { throw Failure(text: "所属应用或后台进程正在运行，已跳过。") }
    }
    private func report(_ ids: [String], _ bytes: Int64, _ skipped: [CleanupIssue], _ failed: [CleanupIssue], _ message: String) -> CleanupReport {
        CleanupReport(removedIDs: ids, movedBytes: bytes, skipped: skipped, failed: failed, message: message)
    }
    private func displayPath(_ url: URL) -> String {
        url.path
    }
    private func validBundleID(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count >= 2 && parts.allSatisfy { !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 } }
    }
    private func isRotatedLog(_ name: String) -> Bool {
        name.range(of: "\\.log\\.(?:[0-9][0-9._-]*(?:\\.(?:gz|bz2|xz))?|gz|bz2|xz|old)$", options: [.regularExpression, .caseInsensitive]) != nil
    }
    private func adding(_ a: Int64, _ b: Int64) -> Int64 {
        let result = a.addingReportingOverflow(b)
        return result.overflow ? Int64.max : result.partialValue
    }

    /// TN3150: even metadata queries of an intermediate dataless directory can
    /// materialize cloud data. Keep this synchronous scope on its calling thread.
    private func withoutMaterializing<T>(_ operation: () throws -> T) throws -> T {
        let type = Int32(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES)
        let scope = Int32(IOPOL_SCOPE_THREAD)
        let previous = getiopolicy_np(type, scope)
        guard previous >= 0 else { throw posix("无法读取云端占位文件保护状态") }
        guard setiopolicy_np(type, scope, Int32(IOPOL_MATERIALIZE_DATALESS_FILES_OFF)) == 0 else {
            throw posix("无法启用云端占位文件保护，已停止操作")
        }
        let result = Result { try operation() }
        guard setiopolicy_np(type, scope, previous) == 0 else { throw posix("无法恢复文件访问策略，已停止后续操作") }
        return try result.get()
    }

    // All paths are opened component by component. O_NOFOLLOW on only the final
    // pathname would still follow a substituted ancestor directory.
    private func openDirectory(_ url: URL, create: Bool = false, searchOnly: Bool = false) throws -> Int32 {
        guard url.isFileURL, url.path.hasPrefix("/"), !url.pathComponents.contains("..") else { throw Failure(text: "目录路径无效。") }
        var descriptor = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { throw posix("无法打开文件系统根目录") }
        do {
            let components = Array(url.pathComponents.dropFirst())
            for (index, component) in components.enumerated() {
                var before = stat()
                if fstatat(descriptor, component, &before, AT_SYMLINK_NOFOLLOW) == 0 {
                    guard before.st_flags & UInt32(SF_DATALESS) == 0 else { throw Failure(text: "路径包含云端占位目录，已跳过。") }
                } else if errno != ENOENT { throw posix("无法核验目录属性") }
                // Searching a known child does not require directory listing.
                // This is essential for macOS Trash, whose known items can be
                // accessible even when enumerating the Trash is privacy-limited.
                let access = searchOnly || index < components.count - 1 ? O_SEARCH : (O_RDONLY | O_DIRECTORY)
                var next = openat(descriptor, component, access | O_NOFOLLOW | O_CLOEXEC)
                if next < 0 && errno == ENOENT && create {
                    guard mkdirat(descriptor, component, 0o700) == 0 || errno == EEXIST else { throw posix("无法建立恢复目录") }
                    next = openat(descriptor, component, access | O_NOFOLLOW | O_CLOEXEC)
                }
                guard next >= 0 else { throw posix("目录无法安全访问（\(component)）") }
                var opened = stat()
                guard fstat(next, &opened) == 0, opened.st_flags & UInt32(SF_DATALESS) == 0 else {
                    close(next)
                    throw Failure(text: "目录不可安全读取或包含云端占位内容。")
                }
                close(descriptor)
                descriptor = next
            }
            return descriptor
        } catch { close(descriptor); throw error }
    }

    private func openPrivateDirectory(_ url: URL, create: Bool) throws -> Int32 {
        let descriptor = try openDirectory(url, create: create)
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_uid == uid, info.st_mode & 0o077 == 0 else {
            close(descriptor)
            throw Failure(text: "恢复目录不是当前用户的私有目录，已停止操作。")
        }
        return descriptor
    }

    private func identity(of descriptor: Int32) throws -> Identity {
        var value = stat()
        guard fstat(descriptor, &value) == 0 else { throw posix("无法核验目录身份") }
        return Identity(value)
    }

    private func names(in descriptor: Int32, cancelled: () -> Bool = { false }) throws -> [String] {
        let copy = dup(descriptor)
        guard copy >= 0 else { throw posix("无法读取目录") }
        guard let stream = fdopendir(copy) else { close(copy); throw posix("无法读取目录") }
        defer { closedir(stream) }
        rewinddir(stream)
        var result: [String] = []
        while true {
            if cancelled() { throw CancellationError() }
            errno = 0
            guard let entry = readdir(stream) else {
                if errno != 0 { throw posix("目录读取未完成") }
                break
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(validatingUTF8: $0) }
            }
            guard let name else { throw Failure(text: "目录包含无法安全识别的文件名。") }
            if name == "." || name == ".." { continue }
            result.append(name)
            guard result.count <= maxEntries else { throw Failure(text: "目录条目过多，已跳过。") }
        }
        if cancelled() { throw CancellationError() }
        return result.sorted()
    }

    private func directoryNames(_ url: URL, cancelled: () -> Bool = { false }) throws -> [String] {
        if cancelled() { throw CancellationError() }
        let descriptor = try openDirectory(url)
        defer { close(descriptor) }
        return try names(in: descriptor, cancelled: cancelled)
    }

    private func snapshot(_ url: URL, on device: UInt64, cancelled: () -> Bool = { false }) throws -> Footprint {
        let parent = try openDirectory(url.deletingLastPathComponent(), searchOnly: true)
        defer { close(parent) }
        var digest = SHA256()
        var bytes: Int64 = 0
        var newest: TimeInterval = 0
        var count = 0
        var rootIdentity: Identity?
        func signature(_ info: stat, root: Bool) -> String {
            let identity = Identity(info)
            return "\(identity.device)|\(identity.inode)|\(info.st_mode)|\(info.st_uid)|\(info.st_gid)|\(info.st_nlink)|\(info.st_size)|\(info.st_blocks)|\(info.st_mtimespec.tv_sec)|\(info.st_mtimespec.tv_nsec)|" +
                (root ? "root" : "\(info.st_ctimespec.tv_sec)|\(info.st_ctimespec.tv_nsec)")
        }
        func record(_ info: stat, relative: String) {
            if relative.isEmpty { rootIdentity = Identity(info) }
            let record = "\(relative.utf8.count):\(relative)|\(signature(info, root: relative.isEmpty))\n"
            digest.update(data: Data(record.utf8))
            let allocation = Int64(info.st_blocks).multipliedReportingOverflow(by: 512)
            bytes = adding(bytes, allocation.overflow ? Int64.max : max(0, allocation.partialValue))
            newest = max(newest, Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1_000_000_000)
        }
        func walk(parent: Int32, name: String, relative: String, depth: Int) throws {
            if cancelled() { throw CancellationError() }
            count += 1
            guard count <= maxEntries, depth < 64 else { throw Failure(text: "项目目录过大或过深，已跳过。") }
            var before = stat()
            guard fstatat(parent, name, &before, AT_SYMLINK_NOFOLLOW) == 0 else { throw posix("无法读取项目属性") }
            guard before.st_flags & UInt32(SF_DATALESS) == 0 else { throw Failure(text: "项目含云端占位内容，已跳过。") }
            let kind = before.st_mode & S_IFMT
            guard kind == S_IFDIR || kind == S_IFREG else { throw Failure(text: "项目含符号链接或特殊文件，已跳过。") }
            guard before.st_uid == uid, Identity(before).device == device else { throw Failure(text: "项目跨磁盘或归属其他用户，已跳过。") }
            guard kind != S_IFREG || before.st_nlink == 1 else { throw Failure(text: "项目含硬链接，已跳过。") }
            if kind == S_IFREG {
                // Opening a regular cache file can request App Data Protection
                // access even without read(). Metadata is sufficient: keep the
                // parent descriptor pinned and recheck the named entry instead.
                if cancelled() { throw CancellationError() }
                var after = stat()
                guard fstatat(parent, name, &after, AT_SYMLINK_NOFOLLOW) == 0,
                      before.st_flags == after.st_flags,
                      signature(before, root: relative.isEmpty) == signature(after, root: relative.isEmpty) else {
                    throw Failure(text: "项目在读取期间发生变化，已跳过。")
                }
                record(before, relative: relative)
                return
            }
            let descriptor = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC | O_DIRECTORY)
            guard descriptor >= 0 else { throw posix("项目无法安全打开") }
            defer { close(descriptor) }
            var opened = stat()
            guard fstat(descriptor, &opened) == 0, opened.st_flags & UInt32(SF_DATALESS) == 0,
                  signature(opened, root: relative.isEmpty) == signature(before, root: relative.isEmpty) else {
                throw Failure(text: "项目在读取期间发生变化，已跳过。")
            }
            record(opened, relative: relative)
            if kind == S_IFDIR {
                for child in try names(in: descriptor, cancelled: cancelled) {
                    try walk(parent: descriptor, name: child, relative: relative.isEmpty ? child : relative + "/" + child, depth: depth + 1)
                }
            }
            var after = stat()
            guard fstat(descriptor, &after) == 0, signature(opened, root: relative.isEmpty) == signature(after, root: relative.isEmpty) else {
                throw Failure(text: "项目在读取期间发生变化，已跳过。")
            }
        }
        try walk(parent: parent, name: url.lastPathComponent, relative: "", depth: 0)
        guard let rootIdentity else { throw Failure(text: "项目读取不完整。") }
        return Footprint(identity: rootIdentity, digest: digest.finalize().map { String(format: "%02x", $0) }.joined(), bytes: bytes, newest: newest, entries: count)
    }

    private func renameExclusive(from source: Int32, name sourceName: String, to destination: Int32, name destinationName: String) throws {
        guard renameatx_np(source, sourceName, destination, destinationName, UInt32(RENAME_EXCL)) == 0 else {
            throw posix("无法安全移动项目（原位置可能已被占用）")
        }
        // Persist both directory entries before advancing the durable journal.
        guard fsync(source) == 0, fsync(destination) == 0 else { throw posix("项目已移动，但目录同步失败；恢复记录已保留") }
    }

    private func safelyExists(_ url: URL) -> Bool {
        guard let parent = try? openDirectory(url.deletingLastPathComponent(), searchOnly: true) else { return false }
        defer { close(parent) }
        var value = stat()
        return fstatat(parent, url.lastPathComponent, &value, AT_SYMLINK_NOFOLLOW) == 0
    }

    private func loadJournal() throws {
        let descriptor: Int32
        do { descriptor = try openPrivateDirectory(journalDirectory, create: false) }
        catch { if isMissing(error) { return }; throw error }
        defer { close(descriptor) }
        guard let data = try journalBytes(in: descriptor) else { return }
        let loaded = try JSONDecoder().decode(Journal.self, from: data)
        guard loaded.version == 1, loaded.batches.flatMap(\.receipts).allSatisfy(validReceipt) else { throw Failure(text: "恢复记录格式或路径无效。") }
        journal = loaded
        savedJournalHash = hash(data)
    }

    private func journalBytes(in descriptor: Int32) throws -> Data? {
        let file = openat(descriptor, "journal.json", O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if file < 0 { if errno == ENOENT { return nil }; throw posix("恢复记录无法安全读取") }
        defer { close(file) }
        var info = stat()
        guard fstat(file, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
              info.st_uid == uid, info.st_flags & UInt32(SF_DATALESS) == 0,
              info.st_size >= 0, info.st_size <= 16 * 1024 * 1024 else { throw Failure(text: "恢复记录的属性无效。") }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = Darwin.read(file, &buffer, buffer.count)
            if count < 0 { if errno == EINTR { continue }; throw posix("恢复记录读取失败") }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
            guard data.count <= 16 * 1024 * 1024 else { throw Failure(text: "恢复记录过大。") }
        }
        return data
    }

    private func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func verifyJournal(in descriptor: Int32? = nil) throws {
        do {
            var current: Data?
            if let descriptor { current = try journalBytes(in: descriptor) }
            else {
                do {
                    let opened = try openPrivateDirectory(journalDirectory, create: false)
                    defer { close(opened) }
                    current = try journalBytes(in: opened)
                } catch { if !isMissing(error) { throw error } }
            }
            guard current.map(hash) == savedJournalHash else { throw Failure(text: "恢复记录已被外部修改或移除，已停止操作并保留现有文件。") }
        } catch {
            journalFailure = error
            throw error
        }
    }

    private func saveJournal() throws {
        if let journalFailure { throw journalFailure }
        let descriptor = try openPrivateDirectory(journalDirectory, create: true)
        defer { close(descriptor) }
        try verifyJournal(in: descriptor)
        let name = "journal-\(UUID().uuidString).tmp"
        let file = openat(descriptor, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard file >= 0 else { throw posix("无法创建恢复记录") }
        defer { close(file); unlinkat(descriptor, name, 0) }
        let data = try JSONEncoder().encode(journal)
        try data.withUnsafeBytes { raw in
            var written = 0
            while written < raw.count {
                let count = Darwin.write(file, raw.baseAddress!.advanced(by: written), raw.count - written)
                if count < 0 { if errno == EINTR { continue }; throw posix("恢复记录写入失败") }
                guard count > 0 else { throw Failure(text: "恢复记录未完整写入。") }
                written += count
            }
        }
        guard fsync(file) == 0, renameat(descriptor, name, descriptor, "journal.json") == 0 else {
            throw posix("恢复记录无法安全保存")
        }
        savedJournalHash = hash(data)
        guard fsync(descriptor) == 0 else { throw posix("恢复记录目录同步失败") }
    }

    private func descendant(_ url: URL, of root: URL) -> Bool {
        let path = url.pathComponents
        let prefix = root.pathComponents
        return path.count > prefix.count && Array(path.prefix(prefix.count)) == prefix
    }
    private func allowedTrashURL(_ url: URL) -> Bool {
        if injectedTrash { return descendant(url, of: home) }
        return trashDirectories().contains { descendant(url, of: $0) }
    }
    private func trashDirectories() -> [URL] {
        var directories = [home.appendingPathComponent(".Trash", isDirectory: true)]
        // A home directory may reside on a separate volume with a per-volume
        // Trash. Ask the system without creating it or assuming another user's path.
        if !injectedTrash,
           let system = try? FileManager.default.url(for: .trashDirectory, in: .userDomainMask, appropriateFor: home, create: false),
           !directories.contains(where: { $0.path == system.path }) {
            directories.append(system)
        }
        return directories
    }
    private func validReceipt(_ receipt: Receipt) -> Bool {
        guard UUID(uuidString: receipt.id) != nil, validBundleID(receipt.owner) else { return false }
        let original = URL(fileURLWithPath: receipt.original)
        let stage = URL(fileURLWithPath: receipt.stage)
        guard stage.deletingLastPathComponent() == stageDirectory,
              stage.lastPathComponent == "GaoJiLing-\(receipt.id)", receipt.footprint.bytes >= 0 else { return false }
        if let trash = receipt.trash, !allowedTrashURL(URL(fileURLWithPath: trash)) { return false }
        let cache = home.appendingPathComponent("Library/Caches", isDirectory: true)
        let logs = home.appendingPathComponent("Library/Logs", isDirectory: true).appendingPathComponent(receipt.owner, isDirectory: true)
        let derived = home.appendingPathComponent("Library/Developer/Xcode/DerivedData", isDirectory: true)
        switch receipt.category {
        case "应用缓存": return original.deletingLastPathComponent() == cache && original.lastPathComponent == receipt.owner && !receipt.owner.hasPrefix("com.gaoseries.")
        case "旧轮转日志": return original.deletingLastPathComponent() == logs && !receipt.owner.hasPrefix("com.gaoseries.") && isRotatedLog(original.lastPathComponent)
        case "开发工具缓存": return Self.developmentRules.contains { $0.owner == receipt.owner && original.path == home.appendingPathComponent($0.path, isDirectory: true).path }
        case "Xcode 构建":
            guard receipt.owner == "com.apple.dt.Xcode", descendant(original, of: derived) else { return false }
            let components = Array(original.pathComponents.dropFirst(derived.pathComponents.count))
            return (components.count == 1 && ["ModuleCache.noindex", "SDKStatCaches.noindex", "CompilationCache.noindex"].contains(components[0])) ||
                (components.count == 3 && components[1] == "Build" && ["Intermediates.noindex", "Products"].contains(components[2]))
        default: return false
        }
    }

    private func recoverySource(_ receipt: Receipt) throws -> URL? {
        let stage = URL(fileURLWithPath: receipt.stage)
        if safelyExists(stage) { return stage }
        if let path = receipt.trash {
            let trash = URL(fileURLWithPath: path)
            if safelyExists(trash) { return trash }
        }
        // A crash can happen after the OS moved the item but before it returned
        // the resulting URL. The staged UUID survives Trash name collisions.
        for trashDirectory in trashDirectories() {
            let names: [String]
            do { names = try directoryNames(trashDirectory) }
            catch {
                if isMissing(error) { continue }
                throw Failure(text: "无法列出废纸篓以定位中断的移动。请在 Finder 废纸篓查找 GaoJiLing-\(receipt.id)，或允许本应用访问后重试；文件未删除。")
            }
            let matches = names.filter { $0.hasPrefix("GaoJiLing-\(receipt.id)") }
            for name in matches {
                let url = trashDirectory.appendingPathComponent(name)
                if let footprint = try? snapshot(url, on: receipt.footprint.identity.device), footprint == receipt.footprint { return url }
            }
        }
        return nil
    }

    private func posix(_ text: String) -> NSError {
        let code = errno
        return NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSLocalizedDescriptionKey: "\(text)：\(String(cString: strerror(code)))"])
    }
    private func isMissing(_ error: Error) -> Bool {
        let ns = error as NSError
        return ns.domain == NSPOSIXErrorDomain && ns.code == Int(ENOENT)
    }
}
