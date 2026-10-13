import Foundation
import Darwin

private struct CheckFailure: Error, CustomStringConvertible { let description: String }
private func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !value() { throw CheckFailure(description: message) }
}
private func rejects(_ body: () throws -> Void, _ message: String) throws {
    do { try body() } catch is CheckFailure { throw CheckFailure(description: message) } catch { return }
    throw CheckFailure(description: message)
}
private final class State: @unchecked Sendable {
    var running: Bool? = false
    var cancelled = false
    var hook: (() -> Void)?
    var writes = 0
    func lookup(_ app: InstalledApp) -> Bool? { hook?(); return running }
}
private final class Fixture: @unchecked Sendable {
    let home: URL
    let fm = FileManager.default
    let state = State()
    var apps: URL { home.appendingPathComponent("Applications", isDirectory: true) }
    var journal: URL { home.appendingPathComponent("journal", isDirectory: true) }
    var ledger: URL { journal.appendingPathComponent("journal.json") }
    var trash: URL { home.appendingPathComponent(".Trash", isDirectory: true) }
    init() throws {
        home = URL(fileURLWithPath: "/private/tmp/gaojiling-uninstall-fixture-\(UUID().uuidString)", isDirectory: true)
        try dir(home); try dir(apps); try dir(trash)
        try dir(home.appendingPathComponent("Library/Caches", isDirectory: true))
    }
    deinit { try? fm.removeItem(at: home) }
    func dir(_ url: URL) throws { try fm.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
    @discardableResult func file(_ url: URL, text: String = "synthetic fixture") throws -> URL {
        try dir(url.deletingLastPathComponent()); try Data(text.utf8).write(to: url); return url
    }
    func app(_ name: String = "Fixture", identifier: String = "com.example.uninstallfixture") throws -> URL {
        let url = apps.appendingPathComponent(name + ".app", isDirectory: true)
        try file(url.appendingPathComponent("Contents/MacOS/Fixture"), text: "This is a test, never execute.")
        let info: [String: Any] = ["CFBundleIdentifier": identifier, "CFBundleName": name,
            "CFBundleShortVersionString": "1.0", "CFBundlePackageType": "APPL", "CFBundleExecutable": "Fixture"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: url.appendingPathComponent("Contents/Info.plist"))
        return url
    }
    func cache(identifier: String = "com.example.uninstallfixture", old: Bool = true) throws -> URL {
        let url = home.appendingPathComponent("Library/Caches/" + identifier, isDirectory: true)
        try file(url.appendingPathComponent("cache.bin"))
        if old { try age(url) }
        return url
    }
    func age(_ url: URL) throws {
        let date = Date(timeIntervalSinceNow: -9 * 86_400)
        let iterator = fm.enumerator(at: url, includingPropertiesForKeys: [.isSymbolicLinkKey])
        var paths = [URL]()
        while let child = iterator?.nextObject() as? URL {
            if (try? child.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { iterator?.skipDescendants(); continue }
            paths.append(child)
        }
        for child in paths.reversed() { try fm.setAttributes([.modificationDate: date], ofItemAtPath: child.path) }
        try fm.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }
    func engine(action: UninstallEngine.TrashAction? = nil, writer: UninstallEngine.JournalWriter? = nil, rename: UninstallEngine.RenameAction? = nil) -> UninstallEngine {
        UninstallEngine(home: home, journalDirectory: journal, applicationRoots: [apps],
            appIsRunning: { [state] in state.lookup($0) }, trash: action ?? { [self] source in
                let destination = trash.appendingPathComponent(source.lastPathComponent + "-moved")
                try fm.moveItem(at: source, to: destination); return destination
            }, journalWriter: writer, rename: rename)
    }
    func exists(_ url: URL) -> Bool { fm.fileExists(atPath: url.path) }
    func selectable(_ plan: UninstallPlan) -> Set<String> { Set(plan.items.filter(\.selectable).map(\.id)) }
    func editLedger(_ body: (inout [String: Any]) -> Void) throws {
        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: ledger)) as! [String: Any]
        body(&json)
        try JSONSerialization.data(withJSONObject: json).write(to: ledger)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: ledger.path)
    }
}

@main struct UninstallEngineTests {
    static func main() {
        let tests: [(String, () throws -> Void)] = [
            ("Exact ownership separates caches from settings, business data, shared resources and documents", exactScope),
            ("Protected Apple and every Gao-series application cannot be selected", protectedApps),
            ("Bundled login items and helpers require a vendor uninstall route", vendorRoute),
            ("Running or unknown processes, recent cache and changed metadata prevent execution", activityAndAge),
            ("Move, native-style returned Trash URL, relaunch and batch restore preserve the full app", roundTrip),
            ("Framework symlinks are preserved without touching their target; cache symlinks are refused", links),
            ("Hard links and special files invalidate candidates", specialFiles),
            ("Stale and forged selections cannot broaden a plan", staleAndForged),
            ("Root or descendant replacement after review cannot be moved", changedAfterReview),
            ("Late replacement is caught and original paths are not followed", lateReplacement),
            ("Trash failure rolls back and preserves the approved object", trashFailure),
            ("Unknown Trash outcome survives relaunch and is recovered by receipt identity", unknownTrashOutcome),
            ("Partial cancellation keeps a durable batch and duplicate execution has no side effects", partialAndIdempotent),
            ("Recovery never overwrites recreated original files", recoveryConflict),
            ("Crash after successful restore is recognized from original identity", restoredBeforeJournal),
            ("Corrupt, future and externally changed journals block writes", badJournals),
            ("A symlinked private stage cannot redirect an uninstall", badStage),
            ("Thread materialization policy is restored on success and failure", cloudPolicy),
            ("Cancelled review and wrong external bundle identity have no executable plan", cancelledReview),
            ("Independent initialization marker detects journal loss across restarts", missingJournal),
            ("Valid legacy journal gains a marker without changing receipts", legacyMarker),
            ("Journal disk-full failures before and after staging preserve recoverability", diskFull),
            ("External approval identity rejects an application replaced at the same path", approvalIdentity),
            ("Last-moment source replacement while restoring is never moved", lateRestore),
            ("Failure rollback leaves a substituted staging object in place", replacedStageRollback),
            ("Restore validation failure never rolls back a newly created original-path object", replacedRestoreRollback)
        ]
        do {
            for (name, test) in tests {
                do { try test() } catch { throw CheckFailure(description: "\(name): \(error)") }
                print("PASS: \(name)")
            }
            print("PASS: \(tests.count) uninstall tests; synthetic apps and injected Trash only")
        } catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
    }
    static func exactScope() throws {
        let f = try Fixture(), app = try f.app(), cache = try f.cache()
        let unrelated = try f.cache(identifier: "com.example.uninstallfixture.other")
        let protected = ["Library/Preferences/com.example.uninstallfixture.plist", "Library/Application Support/com.example.uninstallfixture/records.db", "Library/Containers/com.example.uninstallfixture/Data/document", "Library/Group Containers/shared/keep", "Library/Keychains/keep", "Documents/Fixture/keep"]
        for path in protected { try f.file(f.home.appendingPathComponent(path)) }
        let engine = f.engine(), plan = try engine.review(appURL: app)
        try check(Set(plan.items.filter(\.selectable).compactMap(\.path)) == Set([app.path, cache.path]), "Only explicit app and exact old cache may be selectable")
        try check(plan.items.contains { $0.category == "偏好设置" && !$0.selectable }, "Preferences must be visibly classified as retained")
        let report = try engine.execute(planID: plan.id, selectedIDs: f.selectable(plan))
        try check(report.movedIDs.count == 2 && report.issues.isEmpty, "Both approved independent candidates must move")
        try check(f.exists(unrelated), "Prefix-similar cache must remain")
        for path in protected { try check(f.exists(f.home.appendingPathComponent(path)), "Protected data must stay") }
    }
    static func protectedApps() throws {
        for (name, id) in [("Apple", "com.apple.testfixture"), ("OtherGao", "com.gaoseries.Other"), ("Portal", "cn.mendao.launcher"), ("搞旧版", "net.legacy.fixture")] {
            let f = try Fixture(), app = try f.app(name, identifier: id)
            _ = try f.cache(identifier: id)
            let engine = f.engine(), plan = try engine.review(appURL: app)
            try check(f.selectable(plan).isEmpty && plan.app.protectedReason != nil, "Protected bundle and cache must not be selectable")
            try rejects({ _ = try engine.execute(planID: plan.id, selectedIDs: [plan.items[0].id]) }, "Forged protected selection must fail")
            try check(f.exists(app), "Protected app must remain")
        }
    }
    static func vendorRoute() throws {
        let f = try Fixture(), app = try f.app()
        try f.dir(app.appendingPathComponent("Contents/Library/LoginItems/Helper.app"))
        let plan = try f.engine().review(appURL: app)
        try check(plan.app.vendorUninstallReason != nil && f.selectable(plan).isEmpty, "Embedded external lifecycle components require the vendor route")
    }
    static func activityAndAge() throws {
        let f = try Fixture(), app = try f.app(), cache = try f.cache(old: false)
        let engine = f.engine()
        f.state.running = nil
        try check(f.selectable(try engine.review(appURL: app)).isEmpty, "Unknown process state is not inactive")
        f.state.running = true
        try check(f.selectable(try engine.review(appURL: app)).isEmpty, "Running app must stay")
        f.state.running = false
        let plan = try engine.review(appURL: app)
        try check(plan.items.filter(\.selectable).compactMap(\.path) == [app.path], "Recent cache is retained even during uninstall")
        f.state.running = true
        try rejects({ _ = try engine.execute(planID: plan.id, selectedIDs: f.selectable(plan)) }, "Launch after review must prevent movement")
        try check(f.exists(app) && f.exists(cache), "Rejected execution must preserve both")
    }
    static func roundTrip() throws {
        let f = try Fixture(), app = try f.app()
        let engine = f.engine(), plan = try engine.review(appURL: app)
        let identity = try UninstallFileSafety.info(app)
        let report = try engine.execute(planID: plan.id, selectedIDs: f.selectable(plan))
        try check(report.movedIDs.count == 1 && report.issues.isEmpty && !f.exists(app), "App must move to injected native-style Trash")
        let relaunched = f.engine()
        try check(relaunched.history.first?.pendingCount == 1, "Pending history must load from durable journal")
        let restore = relaunched.restore(batchID: report.batchID!)
        try check(restore.movedIDs.count == 1 && restore.issues.isEmpty, "Restore must use the returned, renamed Trash URL")
        try check(UninstallIdentity(try UninstallFileSafety.info(app)) == UninstallIdentity(identity), "Restored app keeps exact original inode and owner")
        try check(try String(contentsOf: app.appendingPathComponent("Contents/MacOS/Fixture"), encoding: .utf8) == "This is a test, never execute.", "Fixture bytes must be intact")
        try check(f.engine().history.first?.pendingCount == 0, "Restored history persists")
    }
    static func links() throws {
        let f = try Fixture(), app = try f.app(), cache = try f.cache()
        let outside = try f.file(f.home.appendingPathComponent("Documents/sentinel"), text: "do not touch")
        try f.fm.createSymbolicLink(at: app.appendingPathComponent("Contents/external-link"), withDestinationURL: outside)
        try f.fm.createSymbolicLink(at: cache.appendingPathComponent("link"), withDestinationURL: outside)
        try f.age(cache)
        let engine = f.engine(), plan = try engine.review(appURL: app)
        try check(plan.items.filter(\.selectable).compactMap(\.path) == [app.path], "App links are leaf metadata, cache links exclude cache")
        let report = try engine.execute(planID: plan.id, selectedIDs: f.selectable(plan))
        try check(report.movedIDs.count == 1, "Common framework-like app links must not make app uninstall unusable")
        try check(f.engine().restore(batchID: report.batchID!).issues.isEmpty, "Linked bundle can be restored")
        try check(try f.fm.destinationOfSymbolicLink(atPath: app.appendingPathComponent("Contents/external-link").path) == outside.path, "The link text must be preserved")
        try check(try String(contentsOf: outside, encoding: .utf8) == "do not touch" && f.exists(cache), "Links must never move their targets")
    }
    static func specialFiles() throws {
        for useFIFO in [false, true] {
            let f = try Fixture(), app = try f.app()
            let target = app.appendingPathComponent("Contents/unsafe")
            if useFIFO { try check(mkfifo(target.path, 0o600) == 0, "Create own FIFO") }
            else {
                let resource = try f.file(app.appendingPathComponent("Contents/Resources/fixture"))
                try f.fm.linkItem(at: resource, to: target)
            }
            try check(f.selectable(try f.engine().review(appURL: app)).isEmpty, "Unsupported app content must be retained")
        }
    }
    static func staleAndForged() throws {
        let f = try Fixture(), app = try f.app(), other = try f.app("Other", identifier: "com.example.other")
        let engine = f.engine(), first = try engine.review(appURL: app), second = try engine.review(appURL: other)
        try rejects({ _ = try engine.execute(planID: first.id, selectedIDs: f.selectable(first)) }, "Stale plan cannot execute")
        let protected = second.items.first { !$0.selectable }!
        try rejects({ _ = try engine.execute(planID: second.id, selectedIDs: [protected.id]) }, "Protected virtual row cannot be converted to a deletion path")
        try check(f.exists(app) && f.exists(other), "Invalid selections change nothing")
    }
    static func changedAfterReview() throws {
        let f = try Fixture(), app = try f.app(), engine = f.engine()
        let plan = try engine.review(appURL: app)
        try f.file(app.appendingPathComponent("Contents/MacOS/Fixture"), text: "updated version")
        let report = try engine.execute(planID: plan.id, selectedIDs: f.selectable(plan))
        try check(report.movedIDs.isEmpty && !report.issues.isEmpty && f.exists(app), "A changed descendant must invalidate old approval")
        let fresh = try engine.review(appURL: app)
        try f.fm.moveItem(at: app, to: f.apps.appendingPathComponent("Original.app"))
        _ = try f.app()
        try rejects({ _ = try engine.execute(planID: fresh.id, selectedIDs: f.selectable(fresh)) }, "Replacing app root must fail final identity validation")
    }
    static func lateReplacement() throws {
        let f = try Fixture(), app = try f.app(), engine = f.engine()
        let plan = try engine.review(appURL: app)
        let saved = f.apps.appendingPathComponent("Saved.app")
        f.state.hook = {
            f.state.hook = nil
            try! f.fm.moveItem(at: app, to: saved)
            try! f.fm.createSymbolicLink(at: app, withDestinationURL: saved)
        }
        let report = try engine.execute(planID: plan.id, selectedIDs: f.selectable(plan))
        try check(report.movedIDs.isEmpty && !report.issues.isEmpty, "Late replacement cannot pass the pinned-parent checks")
        try check(f.exists(saved) && (try? f.fm.destinationOfSymbolicLink(atPath: app.path)) != nil, "The target of a raced symlink must remain")
    }
    static func trashFailure() throws {
        let f = try Fixture(), app = try f.app()
        let engine = f.engine(action: { _ in throw UninstallFailure(message: "simulated Trash failure") })
        let plan = try engine.review(appURL: app), footprint = try UninstallFileSafety.snapshot(app, appBundle: true)
        let report = try engine.execute(planID: plan.id, selectedIDs: f.selectable(plan))
        try check(report.movedIDs.isEmpty && !report.issues.isEmpty, "System failure is not reported as success")
        try check(try UninstallFileSafety.snapshot(app, appBundle: true) == footprint, "Stage rollback restores exact original")
        try check(f.engine().history.isEmpty, "A completely rolled-back attempt is not a pending recovery")
    }
    static func unknownTrashOutcome() throws {
        let f = try Fixture(), app = try f.app()
        let engine = f.engine(action: { source in
            try f.fm.moveItem(at: source, to: f.trash.appendingPathComponent(source.lastPathComponent + "-unknown"))
            throw UninstallFailure(message: "result lost after move")
        })
        let plan = try engine.review(appURL: app)
        let report = try engine.execute(planID: plan.id, selectedIDs: f.selectable(plan))
        try check(!f.exists(app) && !report.issues.isEmpty, "Uncertain native move must retain a pending receipt")
        let restored = f.engine().restore(batchID: plan.id)
        try check(restored.issues.isEmpty && restored.movedIDs.count == 1 && f.exists(app), "Interrupted Trash result can recover by unique receipt and complete footprint")
    }
    static func partialAndIdempotent() throws {
        let f = try Fixture(), app = try f.app(), cache = try f.cache()
        let engine = f.engine(action: { source in
            let target = f.trash.appendingPathComponent(source.lastPathComponent)
            try f.fm.moveItem(at: source, to: target); f.state.cancelled = true; return target
        })
        let plan = try engine.review(appURL: app)
        let report = try engine.execute(planID: plan.id, selectedIDs: f.selectable(plan), cancelled: { f.state.cancelled })
        try check(report.cancelled && report.movedIDs.count == 1 && !f.exists(cache) && f.exists(app), "Cancellation between items preserves app and logs the one moved cache with explicit cancelled state")
        let duplicate = try engine.execute(planID: plan.id, selectedIDs: f.selectable(plan))
        try check(duplicate.movedIDs.isEmpty && f.exists(app) && engine.history.count == 1, "Repeating an executed plan cannot repeat or expand side effects")
        f.state.cancelled = false
        try check(f.engine().restore(batchID: plan.id).issues.isEmpty && f.exists(cache), "A partial batch remains independently recoverable")
    }
    static func recoveryConflict() throws {
        let f = try Fixture(), app = try f.app(), engine = f.engine()
        let plan = try engine.review(appURL: app)
        _ = try engine.execute(planID: plan.id, selectedIDs: f.selectable(plan))
        _ = try f.app()
        try f.file(app.appendingPathComponent("new-user-data"), text: "keep new app")
        let failed = f.engine().restore(batchID: plan.id)
        try check(failed.movedIDs.isEmpty && !failed.issues.isEmpty && f.exists(app.appendingPathComponent("new-user-data")), "Restore must never overwrite a recreated app")
        try f.fm.removeItem(at: app) // This fixture owns both versions.
        try check(f.engine().restore(batchID: plan.id).movedIDs.count == 1, "Conflict resolution permits a later restore from retained receipt")
    }
    static func restoredBeforeJournal() throws {
        let f = try Fixture(), app = try f.app(), engine = f.engine()
        let plan = try engine.review(appURL: app)
        _ = try engine.execute(planID: plan.id, selectedIDs: f.selectable(plan))
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: f.ledger)) as! [String: Any]
        let batches = json["batches"] as! [[String: Any]], receipts = batches[0]["receipts"] as! [[String: Any]]
        try f.fm.moveItem(at: URL(fileURLWithPath: receipts[0]["trash"] as! String), to: app)
        let restarted = f.engine(), result = restarted.restore(batchID: plan.id)
        try check(result.issues.isEmpty && restarted.history[0].pendingCount == 0, "A crash after rename but before state save must not leave permanent false pending recovery")
    }
    static func badJournals() throws {
        for future in [false, true] {
            let f = try Fixture(), app = try f.app(), engine = f.engine()
            let plan = try engine.review(appURL: app)
            _ = try engine.execute(planID: plan.id, selectedIDs: f.selectable(plan))
            if future { try f.editLedger { $0["version"] = 999 } }
            else { try Data("broken".utf8).write(to: f.ledger); try f.fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: f.ledger.path) }
            let before = try Data(contentsOf: f.ledger), restarted = f.engine()
            try check(restarted.recoveryError != nil && !restarted.restore(batchID: plan.id).issues.isEmpty, "Unreadable/future recovery schema must fail closed")
            try check(try Data(contentsOf: f.ledger) == before, "An invalid journal must never be overwritten empty")
        }
        let f = try Fixture(), app = try f.app(), engine = f.engine()
        let plan = try engine.review(appURL: app)
        try f.dir(f.journal)
        try f.file(f.ledger, text: "external replacement")
        try f.fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: f.ledger.path)
        try rejects({ _ = try engine.execute(planID: plan.id, selectedIDs: f.selectable(plan)) }, "Journal changed after scan must stop movement")
        try check(f.exists(app), "Journal conflict cannot remove original app")
    }
    static func badStage() throws {
        let f = try Fixture(), app = try f.app(), engine = f.engine()
        let outside = f.home.appendingPathComponent("other"); try f.dir(outside)
        try f.fm.createSymbolicLink(at: engine.stageDirectory, withDestinationURL: outside)
        let plan = try engine.review(appURL: app), result = try engine.execute(planID: plan.id, selectedIDs: f.selectable(plan))
        try check(result.movedIDs.isEmpty && f.exists(app), "Symlinked staging must fail before any rename")
        try check(try f.fm.contentsOfDirectory(atPath: outside.path).isEmpty, "Uninstall cannot write through a stage symlink")
    }
    static func cloudPolicy() throws {
        let f = try Fixture(), app = try f.app()
        let before = getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD)
        f.state.hook = { precondition(getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD) == IOPOL_MATERIALIZE_DATALESS_FILES_OFF) }
        _ = try f.engine().review(appURL: app)
        try check(getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD) == before, "Successful review restores previous thread policy")
        try rejects({ _ = try f.engine().review(appURL: app, expectedBundleID: "com.example.wrong") }, "Expected mismatch failure")
        try check(getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD) == before, "Failure also restores thread policy")
    }
    static func cancelledReview() throws {
        let f = try Fixture(), app = try f.app(), engine = f.engine()
        try rejects({ _ = try engine.review(appURL: app, cancelled: { true }) }, "Pre-cancelled review must not produce a plan")
        try rejects({ _ = try engine.review(appURL: app, expectedBundleID: "com.example.unrelated") }, "External bundle claims must be independently checked")
        try check(f.exists(app) && !f.exists(f.ledger), "Rejected review never mutates app or creates an execution receipt")
    }
    static func missingJournal() throws {
        let f = try Fixture(), app = try f.app(), engine = f.engine()
        let plan = try engine.review(appURL: app)
        _ = try engine.execute(planID: plan.id, selectedIDs: f.selectable(plan))
        try check(f.exists(engine.initializationMarkerURL), "Every durable transaction has a separate initialized marker")
        try f.fm.removeItem(at: f.journal)
        let restarted = f.engine()
        try check(restarted.recoveryError != nil && !restarted.restore(batchID: plan.id).issues.isEmpty, "Missing journal after initialization is never treated as an empty first run")
        try check(!f.exists(f.ledger) && (try f.fm.contentsOfDirectory(atPath: f.trash.path).count) == 1, "Fail-closed keeps all recovery bytes and does not recreate the journal")
    }
    static func diskFull() throws {
        for failAt in [1, 3] {
            let f = try Fixture(), app = try f.app()
            let before = try UninstallFileSafety.snapshot(app, appBundle: true)
            let engine = f.engine(writer: { data, fd in
                f.state.writes += 1
                if f.state.writes == failAt { throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC)) }
                try UninstallFileSafety.atomicData(data, directory: fd, name: "journal.json")
            })
            let plan = try engine.review(appURL: app)
            if failAt == 1 {
                try rejects({ _ = try engine.execute(planID: plan.id, selectedIDs: f.selectable(plan)) }, "Initial journal ENOSPC must prevent movement")
                try check(f.engine().recoveryError != nil, "Incomplete initialization remains visibly blocked on relaunch")
            } else {
                let result = try engine.execute(planID: plan.id, selectedIDs: f.selectable(plan))
                try check(result.movedIDs.isEmpty && !result.issues.isEmpty, "Post-stage ENOSPC cannot claim success")
                try check(f.engine().restore(batchID: plan.id).issues.isEmpty, "Persisted prepared receipt recognizes exact rollback after restart")
            }
            try check(try UninstallFileSafety.snapshot(app, appBundle: true) == before, "Disk-full rollback must keep the full approved app")
        }
    }
    static func legacyMarker() throws {
        let f = try Fixture(), app = try f.app(), engine = f.engine()
        let plan = try engine.review(appURL: app)
        _ = try engine.execute(planID: plan.id, selectedIDs: f.selectable(plan))
        let before = try Data(contentsOf: f.ledger)
        try f.fm.removeItem(at: engine.initializationMarkerURL)
        let migrated = f.engine()
        try check(migrated.recoveryError == nil && f.exists(engine.initializationMarkerURL), "Existing verified journal must create its independent marker")
        try check(try Data(contentsOf: f.ledger) == before, "Marker migration cannot rewrite legacy receipt bytes")
        try check(migrated.restore(batchID: plan.id).movedIDs.count == 1 && f.exists(app), "Legacy receipts remain restorable after migration")
    }
    static func approvalIdentity() throws {
        let f = try Fixture(), app = try f.app()
        let identity = UninstallIdentity(try UninstallFileSafety.info(app))
        try f.fm.moveItem(at: app, to: f.apps.appendingPathComponent("Old.app"))
        _ = try f.app()
        try rejects({ _ = try f.engine().review(appURL: app, expectedIdentity: identity) }, "A same-bundle replacement cannot inherit an external approval")
        try check(f.exists(app) && !f.exists(f.ledger), "External identity rejection must not begin a transaction")
    }
    static func lateRestore() throws {
        let f = try Fixture(), app = try f.app(), engine = f.engine()
        let plan = try engine.review(appURL: app)
        _ = try engine.execute(planID: plan.id, selectedIDs: f.selectable(plan))
        let trash = try f.fm.contentsOfDirectory(at: f.trash, includingPropertiesForKeys: nil)[0]
        let saved = f.home.appendingPathComponent("saved-original")
        let sentinel = try f.file(f.home.appendingPathComponent("sentinel"), text: "keep")
        var calls = 0
        f.state.hook = {
            calls += 1
            if calls == 3 {
                try! f.fm.moveItem(at: trash, to: saved)
                try! f.fm.createSymbolicLink(at: trash, withDestinationURL: sentinel)
            }
        }
        let result = f.engine().restore(batchID: plan.id)
        try check(result.movedIDs.isEmpty && !result.issues.isEmpty && !f.exists(app), "Final identity check must reject a late substituted link before rename")
        try check(f.exists(saved) && (try String(contentsOf: sentinel, encoding: .utf8)) == "keep", "Restore must not follow or overwrite the replacement target")
    }
    static func replacedStageRollback() throws {
        let f = try Fixture(), app = try f.app()
        let saved = f.home.appendingPathComponent("saved-approved-app")
        let engine = f.engine(action: { stage in
            try f.fm.moveItem(at: stage, to: saved)
            try f.file(stage.appendingPathComponent("new-object"), text: "new data must stay")
            throw UninstallFailure(message: "Injected replacement followed by Trash failure")
        })
        let plan = try engine.review(appURL: app)
        let result = try engine.execute(planID: plan.id, selectedIDs: f.selectable(plan))
        let stage = try f.fm.contentsOfDirectory(at: engine.stageDirectory, includingPropertiesForKeys: nil).first
        try check(result.movedIDs.isEmpty && !result.issues.isEmpty && !f.exists(app), "A replacement staging object must not be rolled into the original app path")
        try check(stage != nil && f.exists(stage!.appendingPathComponent("new-object")) && f.exists(saved), "Both the substituted stage and displaced approved app must stay untouched")
        try check(f.engine().history.first?.pendingCount == 1, "Failed identity must retain a pending receipt across relaunch")
    }
    static func replacedRestoreRollback() throws {
        let f = try Fixture(), app = try f.app(), engine = f.engine()
        let plan = try engine.review(appURL: app)
        _ = try engine.execute(planID: plan.id, selectedIDs: f.selectable(plan))
        let saved = f.home.appendingPathComponent("saved-restored-app")
        let restorer = f.engine(rename: { from, name, to, destination in
            try UninstallFileSafety.rename(from: from, name: name, to: to, destination: destination)
            // Simulate another writer after the atomic rename and before its
            // post-validation, without racing a test scheduler or real files.
            if destination == app.lastPathComponent {
                try f.fm.moveItem(at: app, to: saved)
                try f.file(app.appendingPathComponent("new-object"), text: "new data must stay")
            }
        })
        let result = restorer.restore(batchID: plan.id)
        try check(result.movedIDs.isEmpty && !result.issues.isEmpty, "Replaced post-restore object cannot be reported as restored")
        try check(f.exists(app.appendingPathComponent("new-object")) && f.exists(saved), "Rollback must not move the new object at the original path")
        try check(try f.fm.contentsOfDirectory(atPath: f.trash.path).isEmpty, "Rollback must not send the new object to the former Trash path")
        let restarted = f.engine()
        try check(restarted.history.first?.pendingCount == 1 && !restarted.restore(batchID: plan.id).issues.isEmpty, "Receipt persists and another restore never overwrites the replacement")
    }
}
