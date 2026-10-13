import Foundation
import Darwin

// This executable injects its engine and never enumerates real processes. The
// controller's unused default lookup still requires the native link symbol.
@_cdecl("gjl_application_running")
func uninstallFixtureRunning(_ path: UnsafePointer<CChar>?, _ flag: Int32) -> Int32 { 0 }

private struct ControllerFailure: Error { let description: String }
@MainActor private func expect(_ value: @autoclosure () -> Bool, _ message: String) throws {
    if !value() { throw ControllerFailure(description: message) }
}

@main struct UninstallControllerTests {
    @MainActor static func main() async {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: "/private/tmp/gaojiling-uninstall-controller-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        do {
            let apps = root.appendingPathComponent("Applications"), app = apps.appendingPathComponent("Fixture.app")
            let contents = app.appendingPathComponent("Contents"), trash = root.appendingPathComponent(".Trash")
            for url in [contents.appendingPathComponent("MacOS"), trash, root.appendingPathComponent("Library/Caches")] {
                try fm.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            }
            try Data("Synthetic, never executable.".utf8).write(to: contents.appendingPathComponent("MacOS/Fixture"))
            let info = ["CFBundleIdentifier": "com.example.controllerfixture", "CFBundleName": "Fixture", "CFBundlePackageType": "APPL", "CFBundleExecutable": "Fixture"]
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
            let engine = UninstallEngine(home: root, journalDirectory: root.appendingPathComponent("Data/Uninstall"), applicationRoots: [apps], appIsRunning: { _ in false }, trash: { source in
                let destination = trash.appendingPathComponent(source.lastPathComponent)
                try FileManager.default.moveItem(at: source, to: destination)
                return destination
            })
            let manager = AppManagementController(engine: engine)
            try expect(manager.review(appURL: app), "Review must be accepted")
            await manager.waitUntilIdle()
            guard let plan = manager.plan else { throw ControllerFailure(description: manager.status) }
            let selected = Set(plan.items.filter(\.selectable).map(\.id))
            try expect(selected.count == 1 && fm.fileExists(atPath: app.path), "Review must never move or select by itself")
            try expect(manager.report == nil && manager.history.isEmpty, "Opening review cannot claim completion")
            var gateCalls = 0, callbacks = 0
            manager.beforeExecution = { _ in gateCalls += 1; return false }
            manager.onExecutionFinished = { _ in callbacks += 1 }
            manager.execute(planID: plan.id, selectedIDs: selected)
            await manager.waitUntilIdle()
            try expect(gateCalls == 1 && callbacks == 0 && !manager.isBusy, "A refused durable-record gate must stop before execution")
            try expect(fm.fileExists(atPath: app.path) && !fm.fileExists(atPath: engine.initializationMarkerURL.path), "The gate must precede every engine side effect")
            print("PASS: rejected execution gate leaves app and journal untouched")

            var callbackWasConsistent = false
            manager.beforeExecution = { approved in gateCalls += 1; return approved.id == plan.id }
            manager.onExecutionFinished = { report in
                callbacks += 1
                callbackWasConsistent = report.batchID == plan.id && report.movedIDs == Array(selected) &&
                    manager.report?.batchID == plan.id && manager.history.contains(where: { $0.id == plan.id && $0.pendingCount == 1 }) &&
                    !manager.isBusy && !report.cancelled && !fm.fileExists(atPath: app.path)
            }
            manager.execute(planID: plan.id, selectedIDs: selected)
            await manager.waitUntilIdle()
            try expect(gateCalls == 2 && callbacks == 1 && callbackWasConsistent, "Completion must expose the real durable batch after history refresh")
            print("PASS: completion callback follows real receipt and history update")

            manager.execute(planID: plan.id, selectedIDs: selected)
            await manager.waitUntilIdle()
            try expect(callbacks == 1 && gateCalls == 2, "A stale repeated UI action must not re-execute")
            manager.restore(batchID: plan.id)
            await manager.waitUntilIdle()
            try expect(fm.fileExists(atPath: app.path) && manager.history.first?.pendingCount == 0, "Batch restore must complete through the controller")
            try expect(callbacks == 1, "Restore must not be emitted as a second uninstall result")
            print("PASS: stale execution is ignored and restore is not a duplicate uninstall result")
            print("PASS: 3 uninstall controller tests; injected engine and synthetic app only")
        } catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
    }
}
