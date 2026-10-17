import Foundation
import AppKit
import Darwin

struct DuplicateRecoveryIssue: Sendable { let itemID: String; let message: String }
struct DuplicateRecoveryReport: Sendable {
    let batchID: String?
    let movedIDs: [String]
    let restoredIDs: [String]
    let processedBytes: UInt64
    let issues: [DuplicateRecoveryIssue]
    let cancelled: Bool
    let message: String
}
struct DuplicateRecoveryHistory: Identifiable, Sendable {
    let id: String
    let date: Date
    let scope: String
    let itemCount: Int
    let pendingCount: Int
    let logicalBytes: UInt64
}

/// Content duplicate recovery is deliberately independent of cache cleanup and
/// app uninstall. Only a complete scan and explicit selection grant a temporary
/// right to move an ordinary file; no arbitrary-path deletion API is exposed.
final class DuplicateRecovery: @unchecked Sendable {
    typealias TrashAction = @Sendable (URL) throws -> URL
    typealias JournalWriter = @Sendable (Data, Int32) throws -> Void
    typealias RenameAction = @Sendable (Int32, String, Int32, String) throws -> Void
    private typealias FS = UninstallFileSafety
    private enum State: String, Codable { case prepared, staged, trashing, trashed, restored, untouched }
    private struct Receipt: Codable {
        let id: String
        let itemID: String
        let original: String
        let keeper: String
        let stage: String
        var trash: String?
        let identity: DuplicateFileIdentity
        let sha256: String
        let parentIdentity: DuplicateDirectoryIdentity
        var state: State
    }
    private struct Batch: Codable {
        let id: String
        let date: Date
        let scope: String
        let scopeIdentity: DuplicateDirectoryIdentity
        var receipts: [Receipt]
    }
    private struct Journal: Codable { var version = 1; var batches: [Batch] = [] }
    let home: URL
    let journalDirectory: URL
    let initializationMarkerURL: URL
    let stageDirectory: URL
    private let trashAction: TrashAction
    private let journalWriter: JournalWriter?
    private let journalCheckpoint: (@Sendable () throws -> Void)?
    private let renameAction: RenameAction
    private let injectedTrash: Bool
    private var journal = Journal()
    private var savedJournalHash: String?
    private var markerPresent = false
    private var journalFailure: Error?
    private static let marker = Data("GaoJiLing.DuplicateJournal.v1\n".utf8)

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser, journalDirectory: URL? = nil,
         trash: TrashAction? = nil, journalWriter: JournalWriter? = nil, rename: RenameAction? = nil,
         journalCheckpoint: (@Sendable () throws -> Void)? = nil) {
        self.home = home
        self.journalDirectory = journalDirectory ?? home.appendingPathComponent("Library/Application Support/GaoSeries/GaoJiLing/Duplicates", isDirectory: true)
        initializationMarkerURL = self.journalDirectory.deletingLastPathComponent().appendingPathComponent("Duplicates.initialized")
        stageDirectory = home.appendingPathComponent("Library/Caches/.GaoJiLing-DuplicateStage", isDirectory: true)
        injectedTrash = trash != nil
        self.journalWriter = journalWriter
        self.journalCheckpoint = journalCheckpoint
        renameAction = rename ?? { try FS.rename(from: $0, name: $1, to: $2, destination: $3) }
        trashAction = trash ?? { url in
            var result: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &result)
            guard let result else { throw UninstallFailure(message: "系统未返回废纸篓位置；请保留恢复记录和文件。") }
            return result as URL
        }
        do { try DuplicateFileSafety.withMaterializationDisabled { try loadJournal() } }
        catch { journalFailure = error }
    }
    var recoveryError: String? { journalFailure?.localizedDescription }
    var history: [DuplicateRecoveryHistory] {
        journal.batches.reversed().compactMap { batch in
            let receipts = batch.receipts.filter { $0.state != .untouched }
            guard !receipts.isEmpty else { return nil }
            return DuplicateRecoveryHistory(id: batch.id, date: batch.date, scope: batch.scope,
                itemCount: receipts.count, pendingCount: receipts.filter { $0.state != .restored }.count,
                logicalBytes: receipts.reduce(0) { add($0, $1.identity.byteCount) })
        }
    }
    func hasRecordedBatch(_ id: String) -> Bool { journal.batches.contains { $0.id == id } }

    func execute(result: DuplicateScanResult, selectedIDs: Set<String>, cancelled: @Sendable () -> Bool = { false }) throws -> DuplicateRecoveryReport {
        try DuplicateFileSafety.withMaterializationDisabled {
            if let journalFailure { throw journalFailure }
            try verifyJournal()
            let batchID = result.id.uuidString
            if hasRecordedBatch(batchID) {
                return report(batchID, message: "此扫描批次已经处理，未重复移动；需要继续处理时请重新扫描。")
            }
            guard result.complete, !result.cancelled, !selectedIDs.isEmpty else {
                throw UninstallFailure(message: "只有完整内容扫描的明确选择可以移入废纸篓。")
            }
            let all = result.groups.flatMap(\.files)
            guard Set(all.map(\.id)).count == all.count,
                  selectedIDs.allSatisfy({ id in all.contains { $0.id == id } }) else {
                throw UninstallFailure(message: "选择与当前内容扫描不符，请重新扫描。")
            }
            var pairs: [(DuplicateFile, DuplicateFile)] = []
            for group in result.groups {
                let selected = group.files.filter { selectedIDs.contains($0.id) }
                guard !selected.isEmpty else { continue }
                guard let keeper = group.files.first(where: { !selectedIDs.contains($0.id) }) else {
                    throw UninstallFailure(message: "每组必须至少保留一个未选择的实物。")
                }
                let physical = Set(group.files.map { "\($0.identity.device):\($0.identity.inode)" })
                guard physical.count == group.files.count, physical.count >= 2 else {
                    throw UninstallFailure(message: "硬链接或同一实物不能当作可处理的重复副本。")
                }
                for file in selected {
                    guard file.identity.uid == getuid(), file.identity.linkCount == 1,
                          file.protectionReason == nil,
                          DuplicateFileSafety.movableReason(path: file.path, scope: result.scope) == nil else {
                        throw UninstallFailure(message: "选择包含硬链接、其他所有者或受保护项目，已停止。")
                    }
                    pairs.append((file, keeper))
                }
            }
            guard pairs.count == selectedIDs.count, journal.batches.count < 1_024,
                  journal.batches.reduce(0, { $0 + $1.receipts.count }) + pairs.count <= 10_000 else {
                throw UninstallFailure(message: "选择或恢复记录超出安全上限，未移动任何项目。")
            }
            if cancelled() { return report(nil, cancelled: true, message: "已取消，未移动任何文件。") }
            let index = journal.batches.count
            journal.batches.append(Batch(id: batchID, date: Date(), scope: result.scope,
                                         scopeIdentity: result.scopeIdentity, receipts: []))
            try saveJournal()
            var moved: [String] = [], issues: [DuplicateRecoveryIssue] = [], bytes: UInt64 = 0
            for (file, keeper) in pairs {
                if cancelled() { issues.append(DuplicateRecoveryIssue(itemID: file.id, message: "已取消，未开始此项目。")); break }
                do {
                    try move(file, keeper: keeper, result: result, batch: index, cancelled: cancelled)
                    moved.append(file.id); bytes = add(bytes, file.identity.byteCount)
                } catch {
                    issues.append(DuplicateRecoveryIssue(itemID: file.id,
                        message: error is CancellationError ? "已取消；已开始项目的恢复记录保留。" : error.localizedDescription))
                    if journalFailure != nil { break }
                }
            }
            return report(batchID, moved: moved, bytes: bytes, issues: issues, cancelled: cancelled(),
                message: "已确认完成 \(moved.count) 个副本；\(issues.count) 项未完成或位置待核实，请保留恢复记录。移入废纸篓仍占空间，不等于已释放磁盘容量。")
        }
    }

    func restore(batchID: String, cancelled: @Sendable () -> Bool = { false }) -> DuplicateRecoveryReport {
        do {
            return try DuplicateFileSafety.withMaterializationDisabled {
                if let journalFailure { throw journalFailure }; try verifyJournal()
                guard let index = journal.batches.firstIndex(where: { $0.id == batchID }) else {
                    throw UninstallFailure(message: "未找到此重复文件恢复批次。")
                }
                var restored: [String] = [], issues: [DuplicateRecoveryIssue] = [], bytes: UInt64 = 0
                for r in journal.batches[index].receipts.indices {
                    let receipt = journal.batches[index].receipts[r]
                    guard receipt.state != .restored && receipt.state != .untouched else { continue }
                    if cancelled() { break }
                    do {
                        let original = URL(fileURLWithPath: receipt.original)
                        guard let source = try recoverySource(receipt) else {
                            if let original = try? verifiedMovedFile(path: receipt.original, receipt: receipt, cancelled: cancelled) {
                                try DuplicateFileSafety.validatePinned(original)
                                journal.batches[index].receipts[r].state = receipt.state == .prepared ? .untouched : .restored
                                try saveJournal(); continue
                            }
                            throw UninstallFailure(message: "未找到原恢复实物；可能已被移动或废纸篓被清空，记录保留。")
                        }
                        let pinned = try verifiedMovedFile(path: source.path, receipt: receipt, cancelled: cancelled)
                        let target = try FS.directory(original.deletingLastPathComponent()); defer { close(target) }
                        guard try directoryIdentity(target) == receipt.parentIdentity else {
                            throw UninstallFailure(message: "原父目录身份已变化，停止恢复。")
                        }
                        if cancelled() { throw CancellationError() }
                        try verifyJournal(); try DuplicateFileSafety.validatePinned(pinned)
                        try validateDirectoryPath(original.deletingLastPathComponent(), expected: receipt.parentIdentity)
                        try renameAction(pinned.parentDescriptor, pinned.name, target, original.lastPathComponent)
                        // Only the receipt's exact inode can ever be rolled back.
                        // A concurrently created replacement is left untouched.
                        do {
                            let restoredFile = try verifiedMovedFile(path: receipt.original, receipt: receipt, cancelled: { false })
                            try DuplicateFileSafety.validatePinned(restoredFile)
                        } catch {
                            if let exact = try? verifiedMovedFile(path: receipt.original, receipt: receipt, cancelled: { false }) {
                                do {
                                    try DuplicateFileSafety.validatePinned(exact)
                                    try validateDirectoryPath(source.deletingLastPathComponent(), expected: directoryIdentity(pinned.parentDescriptor))
                                    try renameAction(exact.parentDescriptor, exact.name, pinned.parentDescriptor, pinned.name)
                                } catch { /* Preserve the receipt; never move an unverified replacement. */ }
                            }
                            throw error
                        }
                        journal.batches[index].receipts[r].state = .restored
                        try saveJournal()
                        restored.append(receipt.itemID); bytes = add(bytes, receipt.identity.byteCount)
                    } catch {
                        issues.append(DuplicateRecoveryIssue(itemID: receipt.itemID, message: error.localizedDescription))
                        if journalFailure != nil { break }
                    }
                }
                return report(batchID, restored: restored, bytes: bytes, issues: issues, cancelled: cancelled(),
                    message: "已恢复 \(restored.count) 项；\(issues.count) 项待处理。已有新文件的位置不会覆盖。")
            }
        } catch { return report(batchID, issues: [DuplicateRecoveryIssue(itemID: batchID, message: error.localizedDescription)], message: "恢复未完成：\(error.localizedDescription)") }
    }

    private func move(_ file: DuplicateFile, keeper: DuplicateFile, result: DuplicateScanResult, batch: Int,
                      cancelled: @Sendable () -> Bool) throws {
        try DuplicateFileSafety.withVerifiedPair(file: file, keeper: keeper, scope: result.scope,
                                               scopeIdentity: result.scopeIdentity, cancelled: cancelled) { source, retained in
            let stageFD = try FS.directory(stageDirectory, create: true, privateOnly: true); defer { close(stageFD) }
            guard try directoryIdentity(stageFD).device == file.identity.device else {
                throw UninstallFailure(message: "文件与私有恢复区不在同一卷；此版本不跨卷移动。")
            }
            let id = UUID().uuidString
            let stage = stageDirectory.appendingPathComponent("GaoJiLing-Duplicate-" + id)
            var receipt = Receipt(id: id, itemID: file.id, original: file.path, keeper: keeper.path,
                stage: stage.path, trash: nil, identity: file.identity, sha256: file.sha256,
                parentIdentity: try directoryIdentity(source.parentDescriptor), state: .prepared)
            let r = journal.batches[batch].receipts.count
            journal.batches[batch].receipts.append(receipt); try saveJournal()
            do {
                if cancelled() { throw CancellationError() }
                guard DuplicateFileSafety.movableReason(path: file.path, scope: result.scope) == nil else {
                    throw UninstallFailure(message: "最终保护规则不允许处理此文件。")
                }
                try DuplicateFileSafety.validatePinned(retained)
                try DuplicateFileSafety.validatePinned(source)
                try validateDirectoryPath(stageDirectory, expected: directoryIdentity(stageFD), privateOnly: true)
                try renameAction(source.parentDescriptor, source.name, stageFD, stage.lastPathComponent)
                receipt.state = .staged; journal.batches[batch].receipts[r] = receipt; try saveJournal()
                _ = try verifiedMovedFile(path: stage.path, receipt: receipt, cancelled: cancelled)
                if cancelled() { throw CancellationError() }
                // Persist the deterministic recovery name before calling the OS.
                // A crash during Trash is recovered explicitly, never replayed.
                if !injectedTrash {
                    let root = try FileManager.default.url(for: .trashDirectory, in: .userDomainMask, appropriateFor: stage, create: true)
                    guard allowedTrash(root.appendingPathComponent(stage.lastPathComponent)) else {
                        throw UninstallFailure(message: "系统废纸篓不在支持的本机位置，已停止。")
                    }
                    receipt.trash = root.appendingPathComponent(stage.lastPathComponent).path
                }
                receipt.state = .trashing; journal.batches[batch].receipts[r] = receipt; try saveJournal()
                let staged = try verifiedMovedFile(path: stage.path, receipt: receipt, cancelled: cancelled)
                try DuplicateFileSafety.validatePinned(staged)
                try DuplicateFileSafety.validatePinned(retained)
                if cancelled() { throw CancellationError() }
                let destination = try trashAction(stage)
                guard allowedTrash(destination), destination.lastPathComponent.hasPrefix(stage.lastPathComponent) else {
                    throw UninstallFailure(message: "系统返回非预期废纸篓位置；恢复记录保留。")
                }
                receipt.trash = destination.path; journal.batches[batch].receipts[r] = receipt; try saveJournal()
                _ = try verifiedMovedFile(path: destination.path, receipt: receipt, cancelled: { false })
                receipt.state = .trashed; journal.batches[batch].receipts[r] = receipt; try saveJournal()
            } catch {
                let failure = error
                // Roll back only the exact, unchanged staged inode, using the
                // original pinned parent and exclusive rename. Never overwrite.
                if let staged = try? verifiedMovedFile(path: stage.path, receipt: receipt, cancelled: { false }) {
                    do {
                        try DuplicateFileSafety.validatePinned(staged)
                        try validateDirectoryPath(URL(fileURLWithPath: receipt.original).deletingLastPathComponent(), expected: receipt.parentIdentity)
                        try renameAction(staged.parentDescriptor, staged.name, source.parentDescriptor, source.name)
                        _ = try verifiedMovedFile(path: receipt.original, receipt: receipt, cancelled: { false })
                        journal.batches[batch].receipts[r].state = .untouched; try saveJournal()
                    } catch { /* The durable receipt remains for explicit recovery. */ }
                } else if receipt.state == .prepared,
                          (try? verifiedMovedFile(path: receipt.original, receipt: receipt, cancelled: { false })) != nil {
                    journal.batches[batch].receipts[r].state = .untouched; try? saveJournal()
                }
                throw failure
            }
        }
    }

    private func verifiedMovedFile(path: String, receipt: Receipt, cancelled: @Sendable () -> Bool) throws -> DuplicatePinnedFile {
        let pinned = try DuplicateFileSafety.openPinned(path: path, expected: receipt.identity, allowRenamedTimes: true)
        guard try DuplicateFileSafety.fullDigest(pinned, cancelled: cancelled) == receipt.sha256 else {
            throw UninstallFailure(message: "恢复实物内容已变化，未移动文件。")
        }
        try DuplicateFileSafety.validatePinned(pinned)
        return pinned
    }
    private func directoryIdentity(_ fd: Int32) throws -> DuplicateDirectoryIdentity {
        var value = stat()
        guard fstat(fd, &value) == 0, value.st_mode & S_IFMT == S_IFDIR else { throw FS.failure("无法核验恢复父目录") }
        return DuplicateDirectoryIdentity(device: value.st_dev, inode: UInt64(value.st_ino), uid: value.st_uid)
    }
    private func validateDirectoryPath(_ path: URL, expected: DuplicateDirectoryIdentity, privateOnly: Bool = false) throws {
        let fd = try FS.directory(path, privateOnly: privateOnly); defer { close(fd) }
        guard try directoryIdentity(fd) == expected else { throw UninstallFailure(message: "父目录路径被替换，停止移动。") }
    }
    private func trashDirectories() -> [URL] {
        var result = [home.appendingPathComponent(".Trash", isDirectory: true)]
        if !injectedTrash, let system = try? FileManager.default.url(for: .trashDirectory, in: .userDomainMask, appropriateFor: home, create: false),
           !result.contains(system) { result.append(system) }
        return result
    }
    private func allowedTrash(_ url: URL) -> Bool {
        FS.validURL(url) && trashDirectories().contains { url.deletingLastPathComponent().path == $0.path }
    }
    private func recoverySource(_ receipt: Receipt) throws -> URL? {
        let stage = URL(fileURLWithPath: receipt.stage)
        if try FS.optionalInfo(stage) != nil { return stage }
        if let trash = receipt.trash, try FS.optionalInfo(URL(fileURLWithPath: trash)) != nil { return URL(fileURLWithPath: trash) }
        guard receipt.state == .trashing else { return nil }
        for root in trashDirectories() {
            let fd: Int32
            do { fd = try FS.directory(root, read: true) }
            catch { if FS.missing(error) { continue }; throw error }
            defer { close(fd) }
            for name in try FS.names(fd, cancelled: { false }) where name.hasPrefix("GaoJiLing-Duplicate-" + receipt.id) {
                let path = root.appendingPathComponent(name)
                if (try? verifiedMovedFile(path: path.path, receipt: receipt, cancelled: { false })) != nil { return path }
            }
        }
        return nil
    }
    private func valid(_ receipt: Receipt, batch: Batch) -> Bool {
        let identity = receipt.identity
        guard UUID(uuidString: receipt.id) != nil, !receipt.itemID.isEmpty, receipt.itemID.utf8.count <= 256,
              validPath(receipt.original), validPath(receipt.keeper), receipt.original != receipt.keeper,
              DuplicateFileSafety.within(receipt.keeper, scope: batch.scope),
              DuplicateFileSafety.movableReason(path: receipt.original, scope: batch.scope) == nil,
              identity.uid == getuid(), identity.mode & UInt32(S_IFMT) == UInt32(S_IFREG), identity.linkCount == 1,
              identity.device == batch.scopeIdentity.device,
              receipt.parentIdentity.device == identity.device, receipt.parentIdentity.uid == getuid(),
              receipt.sha256.utf8.count == 64, receipt.sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              receipt.stage == stageDirectory.appendingPathComponent("GaoJiLing-Duplicate-" + receipt.id).path else { return false }
        if let trash = receipt.trash, !allowedTrash(URL(fileURLWithPath: trash)) || !URL(fileURLWithPath: trash).lastPathComponent.hasPrefix("GaoJiLing-Duplicate-" + receipt.id) { return false }
        return true
    }
    private func validPath(_ path: String) -> Bool { path.utf8.count <= 4096 && (try? DuplicateFileSafety.pathParts(path)) != nil }
    private func journalData() throws -> Data? {
        do {
            let fd = try FS.directory(journalDirectory, privateOnly: true); defer { close(fd) }
            let info: stat
            do { info = try FS.info(parent: fd, name: "journal.json") } catch { if FS.missing(error) { return nil }; throw error }
            guard info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { throw UninstallFailure(message: "重复文件恢复记录权限无效。") }
            return try FS.data(parent: fd, name: "journal.json", limit: 32 * 1_024 * 1_024)
        } catch { if FS.missing(error) { return nil }; throw error }
    }
    private func loadJournal() throws {
        markerPresent = try readMarker()
        guard let data = try journalData() else {
            guard !markerPresent else { throw UninstallFailure(message: "重复文件恢复记录缺失；不能当首次使用覆盖，请保留实物与备份。") }
            for directory in [journalDirectory, stageDirectory] {
                do {
                    let fd = try FS.directory(directory, read: true, privateOnly: true); defer { close(fd) }
                    guard try FS.names(fd, cancelled: { false }).isEmpty else { throw UninstallFailure(message: "存在未归档重复文件恢复资料，已停止移动。") }
                } catch { if !FS.missing(error) { throw error } }
            }
            return
        }
        let loaded = try JSONDecoder().decode(Journal.self, from: data)
        let receipts = loaded.batches.flatMap(\.receipts)
        guard loaded.version == 1, loaded.batches.count <= 1_024, receipts.count <= 10_000,
              Set(loaded.batches.map(\.id)).count == loaded.batches.count,
              Set(receipts.map(\.id)).count == receipts.count,
              loaded.batches.allSatisfy({ batch in UUID(uuidString: batch.id) != nil && validPath(batch.scope) &&
                  batch.scopeIdentity.uid == getuid() && batch.date.timeIntervalSince1970.isFinite &&
                  Set(batch.receipts.map(\.itemID)).count == batch.receipts.count && batch.receipts.allSatisfy { valid($0, batch: batch) } }) else {
            throw UninstallFailure(message: "重复文件恢复记录格式或路径无效，已停止；不会覆盖为空记录。")
        }
        journal = loaded; savedJournalHash = FS.hash(data); try ensureMarker()
    }
    private func verifyJournal() throws {
        do {
            guard try readMarker() == markerPresent, try journalData().map(FS.hash) == savedJournalHash else {
                throw UninstallFailure(message: "重复文件恢复记录或初始化标记被外部改变，已停止移动。")
            }
        } catch { journalFailure = error; throw error }
    }
    private func saveJournal() throws {
        if let journalFailure { throw journalFailure }
        do {
            try verifyJournal(); try ensureMarker()
            let data = try JSONEncoder().encode(journal)
            guard data.count <= 32 * 1_024 * 1_024 else { throw UninstallFailure(message: "重复文件恢复记录超过安全上限。") }
            let fd = try FS.directory(journalDirectory, create: true, privateOnly: true); defer { close(fd) }
            let identity = try directoryIdentity(fd)
            try validateDirectoryPath(journalDirectory, expected: identity, privateOnly: true)
            if let journalWriter { try journalWriter(data, fd) }
            else { try writeJournalAtomically(data, directory: fd, identity: identity) }
            try validateDirectoryPath(journalDirectory, expected: identity, privateOnly: true)
            guard try readMarker(), try journalData().map(FS.hash) == FS.hash(data) else {
                throw UninstallFailure(message: "恢复记录保存后的路径或内容复核失败，未继续移动。")
            }
            savedJournalHash = FS.hash(data)
        } catch { journalFailure = error; throw error }
    }
    /// Same-user malicious races cannot be eliminated by path APIs. The
    /// production writer nevertheless verifies old bytes and the pinned parent
    /// again at the final rename checkpoint, rather than overwriting an external
    /// change observed after the initial preflight. Injected writers are trusted
    /// test fault boundaries and are never selected by the application.
    private func writeJournalAtomically(_ data: Data, directory fd: Int32, identity: DuplicateDirectoryIdentity) throws {
        let temporary = "duplicate-journal-\(UUID().uuidString).tmp"
        let file = openat(fd, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard file >= 0 else { throw FS.failure("无法创建重复文件恢复记录") }
        defer {
            var opened = stat(), named = stat()
            if fstat(file, &opened) == 0, fstatat(fd, temporary, &named, AT_SYMLINK_NOFOLLOW) == 0,
               UninstallIdentity(opened) == UninstallIdentity(named) { unlinkat(fd, temporary, 0) }
            close(file)
        }
        try data.withUnsafeBytes { raw in
            var done = 0
            while done < raw.count {
                let count = Darwin.write(file, raw.baseAddress!.advanced(by: done), raw.count - done)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw FS.failure("恢复记录未完整写入") }; done += count
            }
        }
        guard fsync(file) == 0 else { throw FS.failure("恢复记录未同步") }
        var written = stat()
        guard fstat(file, &written) == 0, written.st_mode & S_IFMT == S_IFREG,
              written.st_uid == getuid(), written.st_nlink == 1, written.st_size == data.count else {
            throw UninstallFailure(message: "新恢复记录的临时实物无效。")
        }
        try journalCheckpoint?()
        try validateDirectoryPath(journalDirectory, expected: identity, privateOnly: true)
        guard try journalData().map(FS.hash) == savedJournalHash, try readMarker() else {
            throw UninstallFailure(message: "恢复记录在最终保存前被外部改变，已停止；不会覆盖外部内容。")
        }
        try validateDirectoryPath(journalDirectory, expected: identity, privateOnly: true)
        var stillOpened = stat(), stillNamed = stat()
        guard fstat(file, &stillOpened) == 0, fstatat(fd, temporary, &stillNamed, AT_SYMLINK_NOFOLLOW) == 0,
              FS.stamp(written) == FS.stamp(stillOpened), FS.stamp(written) == FS.stamp(stillNamed) else {
            throw UninstallFailure(message: "新恢复记录的临时文件被替换，已停止保存。")
        }
        guard renameat(fd, temporary, fd, "journal.json") == 0, fsync(fd) == 0 else { throw FS.failure("恢复记录未持久保存") }
    }
    private func readMarker() throws -> Bool {
        do {
            let fd = try FS.directory(initializationMarkerURL.deletingLastPathComponent()); defer { close(fd) }
            let info = try FS.info(parent: fd, name: initializationMarkerURL.lastPathComponent)
            guard info.st_uid == getuid(), info.st_mode & 0o077 == 0,
                  try FS.data(parent: fd, name: initializationMarkerURL.lastPathComponent, limit: 128) == Self.marker else {
                throw UninstallFailure(message: "重复文件初始化标记无效。")
            }
            return true
        } catch { if FS.missing(error) { return false }; throw error }
    }
    private func ensureMarker() throws {
        guard !markerPresent else { return }
        let parent = try FS.directory(initializationMarkerURL.deletingLastPathComponent(), create: true); defer { close(parent) }
        guard try FS.identity(parent).uid == getuid() else { throw UninstallFailure(message: "恢复资料目录不属于当前用户。") }
        let fd = openat(parent, initializationMarkerURL.lastPathComponent, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw FS.failure("无法创建重复文件初始化标记") }
        defer { close(fd) }
        try Self.marker.withUnsafeBytes { raw in
            var done = 0
            while done < raw.count {
                let count = Darwin.write(fd, raw.baseAddress!.advanced(by: done), raw.count - done)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw FS.failure("无法完整保存初始化标记") }; done += count
            }
        }
        guard fsync(fd) == 0, fsync(parent) == 0 else { throw FS.failure("初始化标记未持久保存") }
        markerPresent = true
    }
    private func add(_ a: UInt64, _ b: UInt64) -> UInt64 { let sum = a.addingReportingOverflow(b); return sum.overflow ? UInt64.max : sum.partialValue }
    private func report(_ batchID: String?, moved: [String] = [], restored: [String] = [], bytes: UInt64 = 0,
                        issues: [DuplicateRecoveryIssue] = [], cancelled: Bool = false, message: String) -> DuplicateRecoveryReport {
        DuplicateRecoveryReport(batchID: batchID, movedIDs: moved, restoredIDs: restored, processedBytes: bytes,
                                issues: issues, cancelled: cancelled, message: message)
    }
}
