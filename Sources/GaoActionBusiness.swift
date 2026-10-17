import Foundation
import Darwin

/// Binds accepted requests to actual operations. No manifest can call a delete API.
@MainActor final class GABusinessCoordinator {
    private let exchange: GAExchangeController
    private let cleanup: CleanupController
    private let analysis: StorageAnalysisController
    private let manager: AppManagementController
    private let duplicates: DuplicateAnalysisController?
    private let navigate: (GAInboxRecord) -> Void
    private let externallyBusy: () -> Bool
    private var cleanupReview: String?
    private var cleanupOperations: [UUID: String] = [:]
    private var uninstallReview: (id: String, reference: GAResolvedReference)?
    private var uninstallOperations: [String: String] = [:]
    private var storageOperation: (id: String, operationID: UUID, referenceID: String, displayName: String)?
    private var duplicateReview: (id: String, referenceID: String, displayName: String, url: URL, identity: DuplicateDirectoryIdentity)?
    private var duplicateOperation: (id: String, operationID: UUID, referenceID: String, displayName: String)?

    init(exchange: GAExchangeController, cleanup: CleanupController, analysis: StorageAnalysisController,
         manager: AppManagementController, duplicates: DuplicateAnalysisController? = nil,
         externallyBusy: @escaping () -> Bool, navigate: @escaping (GAInboxRecord) -> Void) {
        self.exchange = exchange; self.cleanup = cleanup; self.analysis = analysis; self.manager = manager
        self.duplicates = duplicates
        self.externallyBusy = externallyBusy; self.navigate = navigate
        exchange.businessIsBusy = { [weak self] in self?.busy ?? true }
        exchange.onApproved = { [weak self] record, resolved in self?.approved(record, resolved) }
        exchange.onShowBusiness = navigate
        cleanup.beforeTrash = { [weak self] operationID in self?.beforeCleanup(operationID) ?? false }
        cleanup.onTrashCompleted = { [weak self] operationID, report in self?.finishedCleanup(operationID, report) }
        manager.beforeExecution = { [weak self] plan in self?.beforeUninstall(plan) ?? false }
        manager.onExecutionFinished = { [weak self] report in self?.finishedUninstall(report) }
        manager.onReviewFailed = { [weak self] url, cancelled in
            guard let self, let context = self.uninstallReview, context.reference.url.path == url.path,
                  self.current(context.id)?.phase == "approved" else { return }
            self.uninstallReview = nil
            self.finish(context.id, cancelled ? "cancelled" : "failed", cancelled ? "cancelled" : "failed",
                        ["reason": .string("应用复核未完成，未通过此请求移动文件；详情见应用管理页")])
        }
        analysis.onScanCompleted = { [weak self] id, result, completion in
            self?.finishedStorage(operationID: id, result: result, completion: completion)
        }
        duplicates?.onBeforeScan = { [weak self] operationID, scope in
            guard let self, !self.externallyBusy(), !self.cleanup.isBusy, !self.analysis.isBusy, !self.manager.isBusy else { return false }
            guard let context = self.duplicateReview else { return true }
            guard self.current(context.id)?.phase == "approved" else { self.duplicateReview = nil; return true }
            guard scope.path == context.url.path, self.duplicates?.preparedExpectedIdentity == context.identity else {
                self.abandon(context.id); self.duplicateReview = nil; return true
            }
            guard self.exchange.markExecuting(context.id) else { return false }
            self.duplicateOperation = (context.id, operationID, context.referenceID, context.displayName)
            return true
        }
        duplicates?.onScanCompleted = { [weak self] id, result, completion in
            self?.finishedDuplicates(operationID: id, result: result, completion: completion)
        }
    }
    private var busy: Bool { externallyBusy() || cleanup.isBusy || analysis.isBusy || manager.isBusy || duplicates?.isBusy == true }
    private func current(_ id: String) -> GAInboxRecord? { exchange.records.first { $0.id == id } }
    private func finish(_ id: String, _ status: String, _ state: String, _ extra: [String: GAValue] = [:]) {
        var provenance = extra; provenance["workflowState"] = .string(state)
        exchange.outcome(id, status: status, provenance: provenance)
    }
    private func abandon(_ id: String?) {
        guard let id, let record = current(id), ["received", "approved", "reviewing"].contains(record.phase) else { return }
        finish(id, "cancelled", "cancelled", ["reason": .string("用户选择了另一项复核；未通过此请求移动文件")])
    }
    private func approved(_ record: GAInboxRecord, _ reference: GAResolvedReference?) {
        guard !busy else { finish(record.id, "failed", "failed", ["reason": .string("其他本机业务正在执行，未开始本请求")]); return }
        switch record.manifest.action {
        case "storage.inspect":
            guard let reference, let device = reference.identity.device, let inode = reference.identity.inode else { finish(record.id, "failed", "failed", ["reason": .string("目录身份未核验")]); return }
            if record.manifest.parameters["mode"] == .string("duplicates") {
                guard let duplicates else { finish(record.id, "unsupported", "failed", ["reason": .string("内容分析控制器未接入")]); return }
                if duplicateReview?.id != record.id { abandon(duplicateReview?.id) }
                let identity = DuplicateDirectoryIdentity(device: device, inode: inode, uid: reference.ownerUID)
                guard duplicates.prepareDirectory(reference.url, expectedIdentity: identity) else {
                    finish(record.id, "failed", "failed", ["reason": .string("所选范围无法进入内容扫描确认")]); return
                }
                duplicateReview = (record.id, record.manifest.references[0].id, record.manifest.references[0].displayName, reference.url, identity)
                navigate(record); return
            }
            abandon(duplicateReview?.id); duplicateReview = nil
            guard exchange.markExecuting(record.id) else { return }
            analysis.analyzeDirectory(reference.url, expectedIdentity: StorageDirectoryIdentity(device: device, inode: inode, ownerUID: reference.ownerUID))
            guard let operationID = analysis.operationID else { finish(record.id, "failed", "failed"); return }
            storageOperation = (record.id, operationID, record.manifest.references[0].id, record.manifest.references[0].displayName)
        case "cleanup.review":
            if cleanupReview != record.id { abandon(cleanupReview) }; cleanupReview = record.id
            // This is read-only scanning. Moving items still requires the original selection and confirmation UI.
            cleanup.scan()
        case "apps.uninstall.review":
            guard let reference, let device = reference.identity.device, let inode = reference.identity.inode else { finish(record.id, "failed", "failed", ["reason": .string("应用身份未核验")]); return }
            if uninstallReview?.id != record.id { abandon(uninstallReview?.id) }; uninstallReview = (record.id, reference)
            let expected = UninstallIdentity(device: UInt64(bitPattern: Int64(device)), inode: inode, uid: reference.ownerUID)
            guard manager.review(appURL: reference.url, expectedBundleID: record.manifest.references.first?.applicationID, expectedIdentity: expected) else { finish(record.id, "failed", "failed"); uninstallReview = nil; return }
        default: finish(record.id, "unsupported", "failed"); return
        }
        navigate(record)
    }
    private func beforeCleanup(_ operationID: UUID) -> Bool {
        guard !externallyBusy(), !analysis.isBusy, !manager.isBusy, duplicates?.isBusy != true else { return false }
        guard let id = cleanupReview else { return true }
        guard let record = current(id), record.phase != "finished" else { cleanupReview = nil; return true }
        guard exchange.markExecuting(id) else { return false }
        cleanupOperations[operationID] = id; return true
    }
    private func finishedCleanup(_ operationID: UUID, _ report: CleanupReport) {
        guard let id = cleanupOperations.removeValue(forKey: operationID) else { return }
        cleanupReview = nil
        var provenance: [String: GAValue] = ["itemCount": .integer(Int64(report.removedIDs.count)), "movedBytes": .integer(report.movedBytes),
                                           "skippedCount": .integer(Int64(report.skipped.count)), "failedCount": .integer(Int64(report.failed.count))]
        if let batchID = report.batchID { provenance["receiptID"] = .string(batchID) }
        if report.cancelled && report.removedIDs.isEmpty { finish(id, "cancelled", "cancelled", provenance) }
        else if !report.removedIDs.isEmpty && report.skipped.isEmpty && report.failed.isEmpty && !report.cancelled { finish(id, "completed", "completed", provenance) }
        else if !report.failed.isEmpty && report.removedIDs.isEmpty { finish(id, "failed", "failed", provenance) }
        else { finish(id, "partial", report.removedIDs.isEmpty ? "reviewedNoChanges" : "partial", provenance) }
    }
    private func beforeUninstall(_ plan: UninstallPlan) -> Bool {
        guard !externallyBusy(), !cleanup.isBusy, !analysis.isBusy, duplicates?.isBusy != true else { return false }
        guard let context = uninstallReview else { return true }
        guard current(context.id)?.phase != "finished" else { uninstallReview = nil; return true }
        guard plan.app.path == context.reference.url.path,
              plan.app.identity.device == UInt64(bitPattern: Int64(context.reference.identity.device ?? 0)),
              plan.app.identity.inode == context.reference.identity.inode else {
            // A new local selection is a different workflow, never a result for the old external request.
            abandon(context.id); uninstallReview = nil; return true
        }
        guard exchange.markExecuting(context.id) else { return false }
        uninstallOperations[plan.id] = context.id; return true
    }
    private func finishedUninstall(_ report: UninstallReport) {
        let planID = report.batchID
        let id = planID.flatMap { uninstallOperations.removeValue(forKey: $0) } ?? uninstallReview?.id
        guard let id, current(id)?.phase == "executing" else { return }
        uninstallReview = nil
        var provenance: [String: GAValue] = ["itemCount": .integer(Int64(report.movedIDs.count)), "movedBytes": .integer(report.movedBytes), "issueCount": .integer(Int64(report.issues.count))]
        if let planID { provenance["receiptID"] = .string(planID) }
        if report.cancelled && report.movedIDs.isEmpty { finish(id, "cancelled", "cancelled", provenance) }
        else if !report.movedIDs.isEmpty && report.issues.isEmpty && !report.cancelled { finish(id, "completed", "completed", provenance) }
        else if report.movedIDs.isEmpty && !report.issues.isEmpty { finish(id, "failed", "failed", provenance) }
        else { finish(id, "partial", report.movedIDs.isEmpty ? "reviewedNoChanges" : "partial", provenance) }
    }
    private func finishedStorage(operationID: UUID, result: StorageAnalysisResult?, completion: StorageScanCompletion) {
        guard let context = storageOperation, context.operationID == operationID else { return }
        storageOperation = nil
        var provenance: [String: GAValue] = ["scope": .object(["referenceID": .string(context.referenceID), "displayName": .string(context.displayName), "kind": .string("directory")])]
        if let result {
            let progress = result.session?.progress
            provenance["complete"] = .bool(result.complete)
            var statistics: [String: GAValue] = ["allocatedBytes": .integer(result.totalBytes)]
            if let progress {
                statistics.merge(["logicalBytes": .integer(progress.logicalBytes), "files": .integer(Int64(progress.fileCount)),
                                  "directories": .integer(Int64(progress.directoryCount)), "entries": .integer(Int64(progress.visitedEntries)),
                                  "skippedCount": .integer(Int64(progress.skippedCount))]) { _, new in new }
            }
            provenance["statistics"] = .object(statistics)
        } else { provenance["complete"] = .bool(false) }
        finish(context.id, completion.rawValue, completion.rawValue, provenance)
    }
    private func finishedDuplicates(operationID: UUID, result: DuplicateScanResult?, completion: DuplicateScanCompletion) {
        guard let context = duplicateOperation, context.operationID == operationID else { return }
        duplicateOperation = nil; duplicateReview = nil
        var provenance: [String: GAValue] = ["mode": .string("duplicates"), "scope": .object([
            "referenceID": .string(context.referenceID), "displayName": .string(context.displayName), "kind": .string("directory")])]
        provenance["complete"] = .bool(result?.complete == true && completion == .completed)
        if let result {
            let candidates = result.groups.flatMap { group in group.files.filter { $0.id != group.suggestedKeeperID } }
            func sum(_ values: [UInt64]) -> Int64 { values.reduce(0) { sum, value in let n = sum.addingReportingOverflow(Int64(clamping: value)); return n.overflow ? Int64.max : n.partialValue } }
            provenance["statistics"] = .object([
                "allocatedBytes": .integer(Int64(clamping: result.progress.allocatedBytes)),
                "logicalBytes": .integer(Int64(clamping: result.progress.logicalBytes)),
                "files": .integer(Int64(result.progress.uniqueFiles)), "entries": .integer(Int64(result.progress.visitedEntries)),
                "skippedCount": .integer(Int64(result.progress.skippedEntries)),
                "duplicateGroups": .integer(Int64(result.groups.count)), "duplicateFiles": .integer(Int64(candidates.count)),
                "duplicateLogicalBytes": .integer(sum(candidates.map { $0.identity.byteCount })),
                "duplicateAllocatedBytes": .integer(sum(candidates.map { $0.identity.allocatedBytes })),
                "contentBytesRead": .integer(Int64(clamping: result.progress.contentBytesRead))])
        }
        finish(context.id, completion.rawValue, completion.rawValue, provenance)
    }
}
