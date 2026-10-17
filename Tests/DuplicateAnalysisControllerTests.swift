import Foundation
import Darwin

private struct DuplicateControllerTestFailure: Error, CustomStringConvertible { let description: String }
@MainActor private func expect(_ value: @autoclosure () -> Bool, _ message: String) throws {
    if !value() { throw DuplicateControllerTestFailure(description: message) }
}
private final class DuplicateControllerFixture: @unchecked Sendable {
    let home = URL(fileURLWithPath: "/private/tmp/gaojiling-duplicate-controller-\(UUID().uuidString)", isDirectory: true)
    var scope: URL { home.appendingPathComponent("selected") }
    var trash: URL { home.appendingPathComponent(".Trash") }
    var data: URL { home.appendingPathComponent("Data") }
    let fm = FileManager.default
    init() throws {
        for dir in [scope, trash, home.appendingPathComponent("Library/Caches")] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        for name in ["first.bin", "second.bin", "third.bin"] { try Data(repeating: 0x61, count: 4096).write(to: scope.appendingPathComponent(name)) }
    }
    deinit { try? fm.removeItem(at: home) }
    func recovery() -> DuplicateRecovery {
        DuplicateRecovery(home: home, journalDirectory: data.appendingPathComponent("Duplicates"), trash: { [self] source in
            let destination = trash.appendingPathComponent(source.lastPathComponent)
            try fm.moveItem(at: source, to: destination); return destination
        })
    }
    @MainActor func controller(analyzer: DuplicateAnalyzer = DuplicateAnalyzer()) -> DuplicateAnalysisController {
        DuplicateAnalysisController(analyzer: analyzer, recovery: recovery())
    }
}

@main struct DuplicateAnalysisControllerTests {
    @MainActor static func main() async {
        do {
            try await consentAndGates()
            try await consistentCallback()
            try await statuses()
            try await identityAndFailure()
            try await realReceiptAndRestore()
            try await recoveryFailureDoesNotBlockReadOnlyScan()
            print("PASS: 6 duplicate controller groups; isolated files and injected Trash, no GUI")
        } catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
    }
    @MainActor static func consentAndGates() async throws {
        let f = try DuplicateControllerFixture(), controller = f.controller()
        var starts = 0, completions = 0
        controller.onBeforeScan = { _, _ in starts += 1; return true }
        controller.onScanCompleted = { _, _, _ in completions += 1 }
        try expect(controller.prepareDirectory(f.scope), "A local reference can only prefill scope")
        try expect(controller.result == nil && !controller.isBusy && controller.progress == nil && controller.operationID == nil, "Preparation cannot read content or claim an operation")
        try expect(!controller.scanPreparedDirectory(contentReadConfirmed: false), "Explicit content consent is required")
        try expect(starts == 0 && completions == 0, "No consent means no provider start/completion")
        controller.actionsAllowed = { false }
        try expect(!controller.scanPreparedDirectory(contentReadConfirmed: true) && !controller.prepareDirectory(f.home), "External busy gate applies synchronously")
        controller.actionsAllowed = { true }; controller.onBeforeScan = { _, _ in starts += 1; return false }
        try expect(!controller.scanPreparedDirectory(contentReadConfirmed: true), "Durable preflight must approve before any content read")
        try expect(starts == 1 && completions == 0 && !controller.isBusy && controller.operationID == nil, "Rejected preflight cannot invent a scan token")
        try expect(!f.fm.fileExists(atPath: f.data.appendingPathComponent("Duplicates.initialized").path), "Read-only preparation/gates must not create a recovery journal")
        print("PASS: directory prefill, separate content consent and synchronous durable/external gates")
    }
    @MainActor static func consistentCallback() async throws {
        let f = try DuplicateControllerFixture(), controller = f.controller()
        try expect(controller.prepareDirectory(f.scope), "Prepare synthetic scope")
        var beforeID: UUID?, completedID: UUID?, calls = 0, callbackConsistent = false, nestedStart = true
        controller.onBeforeScan = { id, url in beforeID = id; return url.path == f.scope.path }
        controller.onScanCompleted = { id, result, status in
            calls += 1; completedID = id
            callbackConsistent = controller.isBusy && controller.operationID == id && result == controller.result &&
                result?.complete == true && result?.groups.count == 1 && status == .completed && controller.completion == .completed
            nestedStart = controller.scanPreparedDirectory(contentReadConfirmed: true)
        }
        try expect(controller.scanPreparedDirectory(contentReadConfirmed: true) && controller.isBusy, "Scan synchronously owns a busy operation slot")
        let originalID = controller.operationID
        try expect(!controller.scanPreparedDirectory(contentReadConfirmed: true) && controller.operationID == originalID, "A busy scan cannot be replaced")
        await controller.waitUntilIdle()
        try expect(calls == 1 && callbackConsistent && !nestedStart && !controller.isBusy && beforeID == originalID && completedID == originalID, "Immutable real result callback must run exactly once before busy slot release")
        try expect(controller.result?.groups[0].files.allSatisfy { !$0.isSelected } == true, "All candidates default unselected")
        print("PASS: production asynchronous scan correlation, immutable completion and busy-slot ordering")
    }
    @MainActor static func statuses() async throws {
        let f = try DuplicateControllerFixture(), partial = f.controller(analyzer: DuplicateAnalyzer(maximumFiles: 1))
        _ = partial.prepareDirectory(f.scope)
        var calls = 0
        partial.onScanCompleted = { _, result, status in calls += 1; if result?.complete != false || status != .partial { calls += 100 } }
        _ = partial.scanPreparedDirectory(contentReadConfirmed: true); await partial.waitUntilIdle()
        try expect(calls == 1 && partial.completion == .partial && partial.result?.complete == false, "Budget-limited scan is partial, not empty completed")
        let cancelled = f.controller(); _ = cancelled.prepareDirectory(f.scope)
        var cancelledCalls = 0
        cancelled.onScanCompleted = { _, _, status in if status == .cancelled { cancelledCalls += 1 } }
        _ = cancelled.scanPreparedDirectory(contentReadConfirmed: true); cancelled.cancel(); await cancelled.waitUntilIdle()
        try expect(cancelledCalls == 1 && cancelled.completion == .cancelled && !cancelled.isBusy, "Cancellation has its own truthful terminal state")
        print("PASS: partial budgets and cooperative cancellation remain distinct from completed scans")
    }
    @MainActor static func identityAndFailure() async throws {
        let f = try DuplicateControllerFixture(), controller = f.controller()
        var info = stat(); try expect(lstat(f.scope.path, &info) == 0, "Read selected directory identity")
        let wrong = DuplicateDirectoryIdentity(device: info.st_dev, inode: UInt64(info.st_ino) + 1, uid: info.st_uid)
        _ = controller.prepareDirectory(f.scope, expectedIdentity: wrong)
        var calls = 0
        controller.onScanCompleted = { _, result, status in if result == nil && status == .failed && controller.isBusy { calls += 1 } }
        _ = controller.scanPreparedDirectory(contentReadConfirmed: true); await controller.waitUntilIdle()
        try expect(calls == 1 && controller.completion == .failed && controller.result == nil, "External identity mismatch produces failed, never zero-result complete")
        try expect(f.fm.fileExists(atPath: f.scope.appendingPathComponent("first.bin").path), "Failed scan cannot move any file")
        print("PASS: external scope identity mismatch fails without reading another directory or moving files")
    }
    @MainActor static func realReceiptAndRestore() async throws {
        let f = try DuplicateControllerFixture(), controller = f.controller()
        _ = controller.prepareDirectory(f.scope); _ = controller.scanPreparedDirectory(contentReadConfirmed: true); await controller.waitUntilIdle()
        guard let result = controller.result, let first = result.groups.first?.files.first else { throw DuplicateControllerTestFailure(description: "Complete group expected") }
        var callbacks = 0, consistent = false
        controller.onRecoveryCompleted = { report in
            callbacks += 1
            if callbacks == 1 {
                consistent = report.batchID == result.id.uuidString && report.movedIDs == [first.id] &&
                    controller.report?.batchID == report.batchID && controller.history.first?.pendingCount == 1 && controller.isBusy
            }
        }
        controller.actionsAllowed = { false }; controller.execute(resultID: result.id, selectedIDs: [first.id])
        try expect(!controller.isBusy && callbacks == 0 && f.fm.fileExists(atPath: first.path), "Data busy must gate actual moves")
        controller.actionsAllowed = { true }; controller.execute(resultID: result.id, selectedIDs: [first.id]); await controller.waitUntilIdle()
        try expect(consistent && callbacks == 1 && controller.result == nil && !f.fm.fileExists(atPath: first.path), "Actual move yields receipt/history and invalidates stale scan")
        controller.execute(resultID: result.id, selectedIDs: [first.id]); await controller.waitUntilIdle()
        try expect(callbacks == 1, "A stale UI execution must not repeat")
        controller.restore(batchID: result.id.uuidString); await controller.waitUntilIdle()
        try expect(callbacks == 2 && controller.report?.restoredIDs == [first.id] && controller.history.first?.pendingCount == 0 && f.fm.fileExists(atPath: first.path), "Explicit restoration uses actual durable recovery receipt")
        print("PASS: actual synthetic move/receipt, stale execution prevention and non-overwriting restore")
    }
    @MainActor static func recoveryFailureDoesNotBlockReadOnlyScan() async throws {
        let f = try DuplicateControllerFixture()
        let journal = f.data.appendingPathComponent("Duplicates")
        try f.fm.createDirectory(at: journal, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let corrupt = Data("Malformed journal, preserve exactly".utf8), url = journal.appendingPathComponent("journal.json")
        try corrupt.write(to: url); try f.fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let controller = f.controller(); try expect(controller.recoveryError != nil, "Bad recovery state is visible")
        _ = controller.prepareDirectory(f.scope); _ = controller.scanPreparedDirectory(contentReadConfirmed: true); await controller.waitUntilIdle()
        guard let result = controller.result, let file = result.groups.first?.files.first else { throw DuplicateControllerTestFailure(description: "Read-only scan remains usable") }
        controller.execute(resultID: result.id, selectedIDs: [file.id]); await controller.waitUntilIdle()
        try expect(controller.completion == .completed && controller.report == nil && f.fm.fileExists(atPath: file.path), "Read-only analysis grants no move when recovery state is bad")
        let after = try Data(contentsOf: url); try expect(after == corrupt, "Malformed recovery bytes are never replaced")
        print("PASS: malformed recovery state is preserved, read-only scans work, moves stay blocked")
    }
}
