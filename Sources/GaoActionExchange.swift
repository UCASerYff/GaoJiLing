import AppKit
import UniformTypeIdentifiers
import Combine

struct GAInboxRecord: Codable, Identifiable, Sendable {
    var id: String { manifest.requestID }
    var manifest: GAManifest
    var digest: String
    var folder: String
    var acceptedAt: Date
    var phase = "received"
    var outcome = "pending"
    var provenance: [String: GAValue] = ["workflowState": .string("awaitingUser")]
    var resultFolders: [String] = []
    var errorCode: String? = nil
    var incomingCopyRemoved: Bool? = nil
}
private struct GAInboxLedger: Codable { var version = 1; var records: [GAInboxRecord] = [] }

/// An exchange opens a local review. Only existing business engines can perform maintenance.
@MainActor final class GAExchangeController: ObservableObject {
    @Published private(set) var records: [GAInboxRecord] = []
    @Published private(set) var isBusy = false
    @Published private(set) var status: String?
    @Published var selectedID: String?
    @Published private(set) var writable = true
    @Published private(set) var privateCopyCount = 0
    static let recordLimit = 256
    static let privateCopyLimit = 1024
    var canCleanCompletedCopies: Bool { records.contains { $0.phase == "finished" && $0.outcome == "completed" && ($0.incomingCopyRemoved != true || !$0.resultFolders.isEmpty) } }
    var onApproved: ((GAInboxRecord, GAResolvedReference?) -> Void)?
    var onShowBusiness: ((GAInboxRecord) -> Void)?
    var businessIsBusy: (() -> Bool)?
    private let root: URL, stateURL: URL, markerURL: URL
    private let clock: () -> Date
    private let marker = Data("GaoActionInboxV1\n".utf8)
    private var savedState: Data?
    private var queue: [URL] = []
    private var selectedReferences: [String: GAReference] = [:]
    private var terminating = false

    init(dataDirectory: URL, clock: @escaping () -> Date = Date.init) {
        root = dataDirectory.appendingPathComponent("Exchange", isDirectory: true)
        stateURL = root.appendingPathComponent("inbox.json")
        markerURL = dataDirectory.appendingPathComponent("Exchange.initialized")
        self.clock = clock
        do {
            let dataFD = try GAFile.directory(dataDirectory)
            var markerInfo = stat()
            let initialized = fstatat(dataFD.value, markerURL.lastPathComponent, &markerInfo, AT_SYMLINK_NOFOLLOW) == 0
            if !initialized && errno != ENOENT { throw GAError.invalid("交接初始化记录不可读取") }
            if initialized {
                guard try GAFile.read(GAFile.regular(dataFD, markerURL.lastPathComponent, maximum: 128), maximum: 128).0 == marker else { throw GAError.invalid("交接初始化记录损坏或版本过新") }
            }
            let fd = try GAFile.directory(root, createPrivate: true)
            var s = stat()
            if fstatat(fd.value, "inbox.json", &s, AT_SYMLINK_NOFOLLOW) == 0 {
                let bytes = try GAFile.read(GAFile.regular(fd, "inbox.json", maximum: 16 * 1024 * 1024), maximum: 16 * 1024 * 1024).0
                let ledger = try JSONDecoder().decode(GAInboxLedger.self, from: bytes)
                guard ledger.version == 1, ledger.records.count <= Self.recordLimit,
                      Set(ledger.records.map(\.id)).count == ledger.records.count,
                      Set(ledger.records.map(\.folder)).count == ledger.records.count,
                      ledger.records.allSatisfy({ validRecord($0) }) else { throw GAError.invalid("交接记录格式无效或版本过新") }
                savedState = bytes; records = ledger.records
                if !initialized { try GAFile.atomic(marker, at: markerURL, requireMissing: true) }
            } else {
                guard errno == ENOENT, !initialized, try GAFile.names(fd).isEmpty else { throw GAError.invalid("原交接记录缺失或不可读取，未当作首次空白状态") }
                try GAFile.atomic(marker, at: markerURL, requireMissing: true)
                let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
                let empty = try encoder.encode(GAInboxLedger())
                try GAFile.atomic(empty, at: stateURL, requireMissing: true)
                savedState = empty
            }
            if records.contains(where: { $0.phase == "executing" }) {
                var interrupted = records
                for index in interrupted.indices where interrupted[index].phase == "executing" {
                    interrupted[index].phase = "interrupted"; interrupted[index].outcome = "failed"
                    interrupted[index].errorCode = "interrupted"
                    interrupted[index].provenance = ["workflowState": .string("interrupted"),
                        "reason": .string("上次运行中断，无法确认是否已有副作用；请核对对应业务历史。未自动重放，也未认定已回滚。")]
                }
                // Publish the transition only after the old journal and marker
                // have been rechecked and the replacement has been persisted.
                try persist(interrupted)
                status = "发现上次中断的流程，已保留请求和副本；请核对业务历史，不会自动重放。"
            }
            privateCopyCount = try countPrivateCopies()
            selectedID = records.last?.id
        } catch { writable = false; status = "原交接记录无法核验，已保留文件并暂停接收：\(error.localizedDescription)" }
    }
    private func validRecord(_ record: GAInboxRecord) -> Bool {
        guard let encoded = try? JSONEncoder().encode(record.manifest),
              let validated = try? GaoActionV1.validate(encoded, now: record.acceptedAt),
              validated == record.manifest, validated.kind == "request" else { return false }
        guard (try? GaoActionV1.validateOutcome(action: record.manifest.action, status: record.outcome,
                                               provenance: record.provenance, errorCode: record.errorCode)) != nil else { return false }
        let state = record.provenance["workflowState"]?.text
        let consistent: Bool
        switch record.phase {
        case "received", "approved", "reviewing": consistent = record.outcome == "pending" && state == "awaitingUser"
        case "executing": consistent = record.outcome == "pending" && state == "executing"
        case "finished": consistent = record.outcome != "pending" && state != "interrupted"
        case "interrupted": consistent = record.outcome == "failed" && state == "interrupted" && record.errorCode == "interrupted"
        default: consistent = false
        }
        return consistent && UUID(uuidString: record.id) != nil && GaoActionV1.actions.contains(record.manifest.action) &&
        record.manifest.targetBundleID == GaoActionV1.bundleID && GaoActionV1.isSHA(record.digest) && validFolder(record.folder) &&
        record.resultFolders.count <= 64 && Set(record.resultFolders).count == record.resultFolders.count && record.resultFolders.allSatisfy(validFolder) &&
        (record.incomingCopyRemoved != true || (record.phase == "finished" && record.outcome == "completed")) &&
        ["pending", "completed", "partial", "cancelled", "failed", "unsupported"].contains(record.outcome)
    }
    private func validFolder(_ name: String) -> Bool { name.hasSuffix(".gaoaction") && UUID(uuidString: String(name.dropLast(10))) != nil && !name.contains("/") }
    var selected: GAInboxRecord? { records.first { $0.id == selectedID } }
    func importPackage() {
        let panel = NSOpenPanel(); panel.title = "导入动作交接包"; panel.message = "只接收固定 GaoAction V1；接收不授予清理或卸载权限。"
        panel.canChooseFiles = true; panel.canChooseDirectories = true; panel.treatsFilePackagesAsDirectories = false; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }; receive(url)
    }
    func receive(_ url: URL) {
        guard writable, !terminating else { return }
        guard queue.count < 16 else { status = "待接收请求过多，请稍后逐个导入。"; return }
        queue.append(url); processNext()
    }
    private func processNext() {
        guard !isBusy, !queue.isEmpty, writable, !terminating else { return }
        isBusy = true; let url = queue.removeFirst(), incoming = root.appendingPathComponent("Incoming", isDirectory: true), now = clock()
        Task {
            do {
                try requireCopyCapacity()
                let received = try await Task.detached(priority: .utility) { try GaoActionV1.receive(url, incoming: incoming, now: now) }.value
                guard received.manifest.kind == "request" else { throw GAError.invalid("本提供方仅接收动作请求，结果请交给原发送方") }
                if let old = records.first(where: { $0.id == received.manifest.requestID }) {
                    // The new folder was made by this process. Never remove the sender's package.
                    try GAFile.noCloud { try GAFile.removeMetadataPackage(received.stagedURL) { bytes in
                        guard GaoActionV1.sha(bytes) == received.manifestSHA256 else { throw GAError.invalid("重复请求副本已变化，保留待复核") }
                    } }
                    guard old.digest == received.manifestSHA256 else { throw GAError.invalid("相同请求 ID 的内容不同，已拒绝") }
                    selectedID = old.id; status = "重复请求：显示原状态，不重复执行。"
                } else {
                    guard records.count < Self.recordLimit else {
                        try GAFile.noCloud { try GAFile.removeMetadataPackage(received.stagedURL) { bytes in
                            guard GaoActionV1.sha(bytes) == received.manifestSHA256 else { throw GAError.invalid("未接收副本已变化，保留待复核") }
                        } }
                        throw GAError.invalid("幂等记录已达 256 项，暂停接收新请求；旧记录不会自动删除，清理副本也不会重置请求额度")
                    }
                    let record = GAInboxRecord(manifest: received.manifest, digest: received.manifestSHA256,
                                               folder: received.stagedURL.lastPathComponent, acceptedAt: now)
                    try persist(records + [record]); selectedID = record.id
                    status = "请求已接收；来源只是声明，请核对输入后再进入本 App 业务。"
                }
            } catch { status = "未接收请求：\(error.localizedDescription)" }
            privateCopyCount = (try? countPrivateCopies()) ?? privateCopyCount
            isBusy = false; processNext()
        }
    }
    private func persist(_ newRecords: [GAInboxRecord]) throws {
        guard writable else { throw GAError.invalid("原记录不可写，未继续") }
        do {
            guard newRecords.count <= Self.recordLimit, newRecords.allSatisfy({ validRecord($0) }) else { throw GAError.invalid("交接记录状态不完整，未覆盖原记录") }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let bytes = try encoder.encode(GAInboxLedger(records: newRecords))
            guard bytes.count <= 16 * 1024 * 1024 else { throw GAError.invalid("交接记录大小超限，未覆盖原记录") }
            let markerParent = try GAFile.directory(markerURL.deletingLastPathComponent())
            guard try GAFile.read(GAFile.regular(markerParent, markerURL.lastPathComponent, maximum: 128), maximum: 128).0 == marker else { throw GAError.invalid("交接初始化记录丢失或变化，未继续") }
            try GAFile.atomic(bytes, at: stateURL, expected: savedState, requireMissing: savedState == nil)
            records = newRecords; savedState = bytes
        } catch { writable = false; throw error }
    }
    func chooseReference(_ id: String) {
        guard !isBusy, businessIsBusy?() != true, let record = records.first(where: { $0.id == id }), ["received", "approved", "reviewing"].contains(record.phase), let ref = record.manifest.references.first else { return }
        let panel = NSOpenPanel(); panel.title = ref.kind == "application" ? "核对原应用" : "核对原目录"
        panel.message = "请选择请求中同一个原对象；不能用不同路径或被替换的对象代替。"
        panel.canChooseFiles = ref.kind == "application"; panel.canChooseDirectories = ref.kind == "directory"; panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let resolved = try GaoActionV1.resolveReference(ref, selected: url)
            var selected = ref
            selected.declaredIdentity = resolved.identity
            selectedReferences[id] = selected; status = "已选择并核验原对象；进入业务前还会再次核对。"
        } catch { status = error.localizedDescription }
    }
    func approve(_ id: String) {
        guard writable, !isBusy, businessIsBusy?() != true, let record = records.first(where: { $0.id == id }), ["received", "approved", "reviewing"].contains(record.phase) else { return }
        isBusy = true
        Task {
            defer { processNext() }
            do {
                let package = root.appendingPathComponent("Incoming/" + record.folder)
                let fd = try GAFile.directory(package)
                let bytes = try GAFile.read(GAFile.regular(fd, "manifest.json", maximum: 1024 * 1024), maximum: 1024 * 1024).0
                guard GaoActionV1.sha(bytes) == record.digest else { throw GAError.invalid("私有暂存中的请求发生变化，未继续") }
                let stagedManifest = try GaoActionV1.validate(bytes, now: record.acceptedAt)
                guard stagedManifest == record.manifest else { throw GAError.invalid("交接索引与私有请求副本内容不一致，未继续") }
                let reference = selectedReferences[id] ?? record.manifest.references.first
                let selected = selectedReferences[id] == nil ? nil : reference.flatMap { URL(string: $0.fileURL) }
                let resolved = try await Task.detached(priority: .utility) {
                    try reference.map { try GaoActionV1.resolveReference($0, selected: selected) }
                }.value
                guard !terminating else { throw GAError.invalid("正在退出，本请求保留待下次复核") }
                var updated = record; updated.phase = "approved"
                var all = records; all[all.firstIndex(where: { $0.id == id })!] = updated
                try persist(all)
                status = "已进入本 App 复核；清理和卸载仍须在对应页面另行选择并确认。"
                isBusy = false; onApproved?(updated, resolved)
            } catch { isBusy = false; status = "复核未通过：\(error.localizedDescription)" }
        }
    }
    @discardableResult func markExecuting(_ id: String) -> Bool {
        guard writable, !terminating, let index = records.firstIndex(where: { $0.id == id }), ["approved", "reviewing"].contains(records[index].phase) else { return false }
        var all = records; all[index].phase = "executing"; all[index].provenance["workflowState"] = .string("executing")
        do { try persist(all); return true }
        catch { status = "无法保存执行状态，业务未开始：\(error.localizedDescription)"; return false }
    }
    func outcome(_ id: String, status resultStatus: String, provenance: [String: GAValue]) {
        guard let index = records.firstIndex(where: { $0.id == id }), !["finished", "interrupted"].contains(records[index].phase) else { return }
        guard !["completed", "partial"].contains(resultStatus) || records[index].phase == "executing" else {
            status = "业务尚未进入执行，不能写入已完成或部分执行结果。"; return
        }
        var all = records; all[index].outcome = resultStatus; all[index].provenance = provenance
        all[index].errorCode = resultStatus == "failed" ? "operationFailed" : (resultStatus == "unsupported" ? "unsupportedAction" : nil)
        all[index].phase = resultStatus == "pending" ? "approved" : "finished"
        do {
            try GaoActionV1.validateOutcome(action: all[index].manifest.action, status: resultStatus, provenance: provenance, errorCode: all[index].errorCode)
            try persist(all); status = "流程结果已保存；仅在点击发送结果后交给原应用。"
        }
        catch { status = "流程结果无法写入交接记录；请在本 App 业务历史中核对，未自动重试：\(error.localizedDescription)" }
    }
    func cancelReview(_ id: String) {
        guard businessIsBusy?() != true, let record = records.first(where: { $0.id == id }), ["received", "approved", "reviewing"].contains(record.phase) else { return }
        outcome(id, status: "cancelled", provenance: ["workflowState": .string("cancelled"), "originalsModifiedByHandoff": .bool(false)])
    }
    func showBusiness(_ id: String) { if let record = records.first(where: { $0.id == id }) { onShowBusiness?(record) } }
    func prepareForTermination() { terminating = true; queue.removeAll() }
    /// Creates a local package only. Transport remains an explicit UI action.
    func prepareResultPackage(_ id: String) throws -> URL {
        guard !isBusy, writable, !terminating, let record = records.first(where: { $0.id == id }) else { throw GAError.invalid("当前请求不可生成结果副本") }
        return try resultPackage(record)
    }
    private func resultPackage(_ record: GAInboxRecord) throws -> URL {
        guard record.resultFolders.count < 64 else { throw GAError.invalid("本请求已有 64 份结果副本；已完成请求可清理副本后再生成，未完成或失败副本继续保留") }
        try requireCopyCapacity()
        let now = clock(), id = UUID().uuidString
        let manifest = GAManifest(kind: "result", requestID: id, sourceBundleID: GaoActionV1.bundleID,
                                  targetBundleID: record.manifest.sourceBundleID, action: record.manifest.action,
                                  createdAt: GaoActionV1.timestamp(now), expiresAt: GaoActionV1.timestamp(now.addingTimeInterval(120)),
                                  nonce: try GaoActionV1.nonce(), inReplyTo: record.id, status: record.outcome, errorCode: record.errorCode, provenance: record.provenance)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(manifest)
        _ = try GaoActionV1.validate(data, target: manifest.targetBundleID, now: now)
        let url = root.appendingPathComponent("Outgoing/" + id + ".gaoaction", isDirectory: true)
        _ = try GAFile.directory(url.appendingPathComponent("payload"), createPrivate: true)
        try GAFile.atomic(data, at: url.appendingPathComponent("manifest.json"), requireMissing: true)
        if let index = records.firstIndex(where: { $0.id == record.id }) {
            var all = records; all[index].resultFolders.append(url.lastPathComponent); try persist(all)
        }
        privateCopyCount = try countPrivateCopies()
        return url
    }
    func sendResult(_ id: String) {
        guard !isBusy, writable, let record = records.first(where: { $0.id == id }) else { return }
        do {
            guard let application = NSWorkspace.shared.urlForApplication(withBundleIdentifier: record.manifest.sourceBundleID),
                  Bundle(url: application)?.bundleIdentifier == record.manifest.sourceBundleID else { throw GAError.invalid("未找到声明的接收应用；可导出结果包后手动导入") }
            let package = try prepareResultPackage(record.id)
            let configuration = NSWorkspace.OpenConfiguration(); configuration.activates = true
            NSWorkspace.shared.open([package], withApplicationAt: application, configuration: configuration) { [weak self] _, error in
                Task { @MainActor in self?.status = error == nil ? "已请求原应用打开结果包；不代表对方业务已经接收或完成。" : "结果打开失败，可导出或在 Finder 中显示；原记录保留。" }
            }
        } catch { status = error.localizedDescription }
    }
    func exportResult(_ id: String) {
        guard !isBusy, writable, let record = records.first(where: { $0.id == id }) else { return }
        let panel = NSSavePanel(); panel.title = "导出 GaoAction 结果包"; panel.nameFieldStringValue = "搞机灵-结果.gaoaction"
        panel.message = "结果可能包含所选对象名称和本机维护状态；仅保存在你选择的位置，包的接收有效期为 120 秒。"
        panel.allowedContentTypes = [UTType(importedAs: "com.gaoseries.action-package")]; panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            guard !FileManager.default.fileExists(atPath: url.path), !url.path.hasPrefix(root.path + "/") else { throw GAError.invalid("目标已存在或位于内部交接目录，未覆盖") }
            let source = try prepareResultPackage(record.id)
            let fd = try GAFile.directory(source)
            let bytes = try GAFile.read(GAFile.regular(fd, "manifest.json", maximum: 1024 * 1024), maximum: 1024 * 1024).0
            _ = try GAFile.directory(url.appendingPathComponent("payload"), createPrivate: true)
            try GAFile.atomic(bytes, at: url.appendingPathComponent("manifest.json"), requireMissing: true)
            status = "已导出私有结果包；未自动启动或发送到其他应用。"
        } catch { status = "导出未完成：\(error.localizedDescription)" }
    }
    func revealResult(_ id: String) {
        do { NSWorkspace.shared.activateFileViewerSelecting([try prepareResultPackage(id)]) } catch { status = error.localizedDescription }
    }

    private func countPrivateCopies() throws -> Int {
        try GAFile.noCloud {
            let rootFD = try GAFile.directory(root)
            var count = 0
            for name in ["Incoming", "Outgoing"] {
                var info = stat()
                if fstatat(rootFD.value, name, &info, AT_SYMLINK_NOFOLLOW) != 0 {
                    if errno == ENOENT { continue }; throw GAError.invalid("副本目录无法核验")
                }
                guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid(), info.st_mode & 0o077 == 0,
                      info.st_flags & UInt32(SF_DATALESS) == 0 else { throw GAError.invalid("副本目录身份或权限异常，未继续") }
                let fd = try GAFD(openat(rootFD.value, name, O_SEARCH | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC))
                guard GAFile.sameIdentity(info, try fd.info()) else { throw GAError.invalid("副本目录在核验时变化") }
                count += try GAFile.names(fd).count
            }
            return count
        }
    }
    private func requireCopyCapacity() throws {
        privateCopyCount = try countPrivateCopies()
        guard privateCopyCount < Self.privateCopyLimit else { throw GAError.invalid("私有副本已达 1024 份上限，请先清理已完成副本；未完成、失败和中断资料不会自动删除") }
    }

    func cleanCompletedCopies() {
        guard writable, !isBusy, !terminating, businessIsBusy?() != true, canCleanCompletedCopies else { return }
        isBusy = true; status = "正在核验并清理已完成请求的私有副本…"
        let candidates = records.filter { $0.phase == "finished" && $0.outcome == "completed" }
        let root = root
        Task {
            do {
                // A write of the same state verifies the marker and expected
                // bytes before any copy is removed; IDs and outcomes remain.
                try persist(records)
                let result = await Task.detached(priority: .utility) {
                    var cleaned: [String: [String]] = [:], incomingRemoved = Set<String>(), failures = 0
                    for record in candidates {
                        if record.incomingCopyRemoved != true {
                            do {
                                try GAFile.noCloud { try GAFile.removeMetadataPackage(root.appendingPathComponent("Incoming/" + record.folder)) { bytes in
                                    guard GaoActionV1.sha(bytes) == record.digest,
                                          try GaoActionV1.validate(bytes, now: record.acceptedAt) == record.manifest else { throw GAError.invalid("已完成请求副本与记录不一致") }
                                } }
                                incomingRemoved.insert(record.id)
                            } catch { failures += 1 }
                        }
                        for folder in record.resultFolders {
                            do {
                                try GAFile.noCloud { try GAFile.removeMetadataPackage(root.appendingPathComponent("Outgoing/" + folder)) { bytes in
                                    let preliminary = try JSONDecoder().decode(GAManifest.self, from: bytes)
                                    guard let created = GaoActionV1.date(preliminary.createdAt) else { throw GAError.invalid("结果副本日期无效") }
                                    let result = try GaoActionV1.validate(bytes, target: record.manifest.sourceBundleID, now: created)
                                    guard result.kind == "result", result.sourceBundleID == GaoActionV1.bundleID,
                                          result.inReplyTo == record.id, result.action == record.manifest.action,
                                          result.requestID + ".gaoaction" == folder else { throw GAError.invalid("结果副本不属于此请求") }
                                } }
                                cleaned[record.id, default: []].append(folder)
                            } catch { failures += 1 }
                        }
                    }
                    return (cleaned, incomingRemoved, failures)
                }.value
                var updated = records
                for index in updated.indices {
                    if result.1.contains(updated[index].id) { updated[index].incomingCopyRemoved = true }
                    let removed = Set(result.0[updated[index].id] ?? [])
                    updated[index].resultFolders.removeAll { removed.contains($0) }
                }
                try persist(updated)
                let removed = result.1.count + result.0.values.reduce(0) { $0 + $1.count }
                status = "已清理 \(removed) 份已完成副本，保留请求标识和结果，重复请求不会重放。" + (result.2 == 0 ? "" : " \(result.2) 份副本无法完整核验或清理，已保留待复核。")
            } catch { status = "副本清理未完成：\(error.localizedDescription)。幂等记录与原件保留；不会删除未完成或失败资料。" }
            privateCopyCount = (try? countPrivateCopies()) ?? privateCopyCount
            isBusy = false; processNext()
        }
    }
}

