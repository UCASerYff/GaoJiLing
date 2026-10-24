import Foundation
import Darwin

private struct MovedFailure: Error, CustomStringConvertible { let description: String }
private func require(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !value() { throw MovedFailure(description: message) }
}
private func mustReject(_ action: () throws -> Void) throws {
    var rejected = false
    do { try action() } catch { rejected = true }
    try require(rejected, "Expected an operation to fail closed")
}

private struct Receipt: Decodable {
    let id: String, itemID: String, original: String, stage: String, itemKind: String, state: String
    let trash: String?
    let footprint: UninstallFootprint
    let parentIdentity: UninstallIdentity
}
private struct Batch: Decodable { let id: String; let app: InstalledApp; let receipts: [Receipt] }
private struct Journal: Decodable { let version: Int; let batches: [Batch] }
private struct Lookup: Codable {
    let phase: String, original: String, current: String
    let identity: UninstallIdentity
    let nativeResult: Int32
}
private final class Trace: @unchecked Sendable {
    var phase = "execute"
    var calls: [Lookup] = []
    func lookup(_ app: InstalledApp, current: URL) -> Bool? {
        let result = app.path.withCString { original in
            current.path.withCString { moved in
                gjl_application_running_at_locations(original, moved, app.identity.device, app.identity.inode, app.identity.uid)
            }
        }
        calls.append(Lookup(phase: phase, original: app.path, current: current.path, identity: app.identity, nativeResult: result))
        return result < 0 ? nil : result > 0
    }
}

/// Every path belongs to this executable's exclusively created .noindex root.
/// Fixture Trash uses real same-volume rename, never FileManager.trashItem.
/// Fixtures, raw journals and reports remain for the caller's exact review.
private final class Fixture: @unchecked Sendable {
    typealias FS = UninstallFileSafety
    let fm = FileManager.default
    let root: URL, home: URL, app: URL, cache: URL, trash: URL, apps: URL, ledger: URL
    let bundleID: String
    let trace = Trace()
    let appBefore: UninstallFootprint, cacheBefore: UninstallFootprint
    let binaryBefore: Data, payloadBefore: Data, externalBefore: Data

    init(root: URL, child: URL) throws {
        self.root = root
        try require(mkdir(root.path, 0o700) == 0, "Fixture root must be newly and exclusively created")
        home = root.appendingPathComponent("home", isDirectory: true)
        apps = home.appendingPathComponent("Applications", isDirectory: true)
        app = apps.appendingPathComponent("MovedFixture.app", isDirectory: true)
        bundleID = "org.example.gaojiling-moved." + UUID().uuidString.lowercased()
        cache = home.appendingPathComponent("Library/Caches/" + bundleID, isDirectory: true)
        trash = home.appendingPathComponent(".Trash", isDirectory: true)
        ledger = home.appendingPathComponent("Library/Application Support/GaoSeries/GaoJiLing/Uninstall/journal.json")
        binaryBefore = try Data(contentsOf: child)
        payloadBefore = Data("Synthetic complete bundle payload\n".utf8)
        externalBefore = Data("Synthetic external symlink target must remain unchanged\n".utf8)
        for directory in [app.appendingPathComponent("Contents/MacOS"), app.appendingPathComponent("Contents/Resources"), cache, trash, home.appendingPathComponent("Documents")] {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        try binaryBefore.write(to: app.appendingPathComponent("Contents/MacOS/FixtureChild"), options: .withoutOverwriting)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: app.appendingPathComponent("Contents/MacOS/FixtureChild").path)
        let info: [String: Any] = ["CFBundleIdentifier": bundleID, "CFBundleName": "MovedFixture", "CFBundlePackageType": "APPL",
            "CFBundleExecutable": "FixtureChild", "CFBundleShortVersionString": "1.0"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"), options: .withoutOverwriting)
        try payloadBefore.write(to: app.appendingPathComponent("Contents/Resources/payload.bin"), options: .withoutOverwriting)
        let external = home.appendingPathComponent("Documents/external-sentinel.bin")
        try externalBefore.write(to: external, options: .withoutOverwriting)
        try fm.createSymbolicLink(atPath: app.appendingPathComponent("Contents/Resources/ExternalLink").path, withDestinationPath: external.path)
        try fm.createSymbolicLink(atPath: app.appendingPathComponent("Contents/Resources/RelativeLink").path, withDestinationPath: "payload.bin")
        let cacheFile = cache.appendingPathComponent("cache.bin")
        try Data("Synthetic old cache\n".utf8).write(to: cacheFile, options: .withoutOverwriting)
        let old = Date(timeIntervalSinceNow: -9 * 86_400)
        for url in [cacheFile, cache] { try fm.setAttributes([.modificationDate: old], ofItemAtPath: url.path) }
        appBefore = try FS.snapshot(app, appBundle: true)
        cacheBefore = try FS.snapshot(cache, appBundle: false)
    }

    func engine(phase: String) -> UninstallEngine {
        trace.phase = phase
        return UninstallEngine(home: home, applicationRoots: [apps], appIsRunning: { app in
            let result = app.path.withCString { gjl_application_running($0, 0) }
            return result < 0 ? nil : result > 0
        }, appIsRunningAtLocation: { [trace] app, current in trace.lookup(app, current: current) }, trash: { [self] source in
            let destination = trash.appendingPathComponent(source.lastPathComponent + "-fixture")
            try rename(source, destination)
            return destination
        })
    }

    func rename(_ source: URL, _ destination: URL) throws {
        try require(source.path.hasPrefix(root.path + "/") && destination.path.hasPrefix(root.path + "/"), "Rename escaped fixture")
        let from = try FS.directory(source.deletingLastPathComponent()); defer { close(from) }
        let to = try FS.directory(destination.deletingLastPathComponent()); defer { close(to) }
        try FS.rename(from: from, name: source.lastPathComponent, to: to, destination: destination.lastPathComponent)
    }
    func batch() throws -> Batch {
        let decoded = try JSONDecoder().decode(Journal.self, from: Data(contentsOf: ledger))
        try require(decoded.version == 1 && decoded.batches.count == 1, "Fixture must have exactly its own batch")
        return decoded.batches[0]
    }
    func receipt(_ kind: String) throws -> Receipt {
        let matches = try batch().receipts.filter { $0.itemKind == kind }
        try require(matches.count == 1, "Expected exactly one receipt of each selected kind")
        return matches[0]
    }
    func current(_ receipt: Receipt) throws -> URL {
        guard let path = receipt.trash else { throw MovedFailure(description: "Expected fixture Trash receipt") }
        let result = URL(fileURLWithPath: path)
        try require(result.deletingLastPathComponent() == trash, "Receipt must use only private fixture Trash")
        return result
    }
    func execute() throws -> Batch {
        let engine = engine(phase: "execute")
        try require(engine.recoveryError == nil, "Fresh engine journal must load")
        let plan = try engine.review(appURL: app, expectedBundleID: bundleID, expectedIdentity: appBefore.identity)
        let selected = plan.items.filter(\.selectable)
        try require(plan.complete && Set(selected.compactMap(\.path)) == Set([app.path, cache.path]), "Only app and precise aged cache may be selected")
        let ids = Set(selected.map(\.id))
        let report = try engine.execute(planID: plan.id, selectedIDs: ids)
        try require(!report.cancelled && report.issues.isEmpty && Set(report.movedIDs) == ids, "Real native inactive lookup must allow both moves")
        let batch = try self.batch()
        try require(batch.id == report.batchID && batch.receipts.count == 2, "Durable batch must contain both selected objects")
        for receipt in batch.receipts {
            try require(receipt.state == "trashed", "Completed fixture move must be durably trashed")
            try require(try FS.snapshot(current(receipt), appBundle: receipt.itemKind == "application") == receipt.footprint,
                        "Real rename must preserve complete receipt footprint and device/inode/UID")
            try require(try FS.optionalInfo(URL(fileURLWithPath: receipt.original)) == nil, "Moved source must be absent")
            try require(try FS.optionalInfo(URL(fileURLWithPath: receipt.stage)) == nil, "Completed move must leave no stage")
        }
        return batch
    }
    func restoreSuccess(_ batch: Batch, phase: String = "fresh-restore") throws {
        let fresh = engine(phase: phase)
        try require(fresh.recoveryError == nil && fresh.history.first?.pendingCount == 2, "Fresh engine must reconstruct both pending receipts")
        let report = fresh.restore(batchID: batch.id)
        try require(report.issues.isEmpty && Set(report.movedIDs) == Set(batch.receipts.map(\.itemID)), "Fresh engine must restore app and cache")
        try verifyOriginals()
        try require(try self.batch().receipts.allSatisfy { $0.state == "restored" }, "Both restore states must be durable")
        let completed = engine(phase: "idempotent")
        try require(completed.history.first?.pendingCount == 0, "Restored history must have no pending receipts")
        let repeated = completed.restore(batchID: batch.id)
        try require(repeated.issues.isEmpty && repeated.movedIDs.isEmpty, "Completed restoration must be idempotent")
    }
    func verifyOriginals() throws {
        try require(try FS.snapshot(app, appBundle: true) == appBefore, "App footprint must survive round trip")
        try require(try FS.snapshot(cache, appBundle: false) == cacheBefore, "Cache footprint must survive round trip")
        try require(try Data(contentsOf: app.appendingPathComponent("Contents/MacOS/FixtureChild")) == binaryBefore, "Executable bytes changed")
        try require(try Data(contentsOf: app.appendingPathComponent("Contents/Resources/payload.bin")) == payloadBefore, "Bundle payload bytes changed")
        try require(try Data(contentsOf: home.appendingPathComponent("Documents/external-sentinel.bin")) == externalBefore, "External link target changed")
        try require(try fm.destinationOfSymbolicLink(atPath: app.appendingPathComponent("Contents/Resources/RelativeLink").path) == "payload.bin", "Relative bundle link changed")
    }
    func rejectRestore(_ batch: Batch, phase: String) throws {
        let before = try Data(contentsOf: ledger)
        let fresh = engine(phase: phase)
        try require(fresh.recoveryError == nil, "Failure case must load a genuine, valid journal")
        let report = fresh.restore(batchID: batch.id)
        try require(!report.issues.isEmpty && report.movedIDs.isEmpty, "Unsafe restore must move zero objects")
        try require(try Data(contentsOf: ledger) == before, "Rejected restore must leave durable journal unchanged")
        try require(try FS.optionalInfo(cache) == nil, "Rejected app status must also preserve moved cache")
        let receipt = try self.receipt("cache")
        try require(try FS.snapshot(current(receipt), appBundle: false) == cacheBefore, "Rejected restore changed fixture cache")
    }
    func native(_ original: URL, _ current: URL, _ identity: UninstallIdentity) -> Int32 {
        original.path.withCString { source in current.path.withCString { moved in
            gjl_application_running_at_locations(source, moved, identity.device, identity.inode, identity.uid)
        } }
    }
    func saveTrace() throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(trace.calls).write(to: root.appendingPathComponent("native-lookups.json"))
    }
}

private final class Child {
    let process = Process()
    let input = Pipe(), output = Pipe()
    private var closed = false
    init(executable: URL) throws {
        process.executableURL = executable
        process.standardInput = input; process.standardOutput = output; process.standardError = output
        try process.run()
        let ready = output.fileHandleForReading.readData(ofLength: 6)
        guard ready == Data("READY\n".utf8), process.isRunning else {
            try? input.fileHandleForWriting.close(); process.waitUntilExit()
            throw MovedFailure(description: "Purpose-built CLI child failed readiness")
        }
    }
    func path() throws -> String {
        var values: UnsafeMutablePointer<GJLProcess>?
        var total: Int32 = 0
        let count = gjl_process_snapshot(&values, &total)
        guard let values else { throw MovedFailure(description: "Native process snapshot unavailable for own child") }
        defer { gjl_free_processes(values) }
        for index in 0..<Int(count) where values[index].pid == process.processIdentifier {
            return withUnsafePointer(to: &values[index].path) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: 4096) { String(cString: $0) }
            }
        }
        throw MovedFailure(description: "Own child PID missing from native process snapshot")
    }
    func finish() throws {
        if !closed { try input.fileHandleForWriting.close(); closed = true }
        process.waitUntilExit()
        try require(process.terminationReason == .exit && process.terminationStatus == 0, "CLI child must exit normally on EOF")
    }
    deinit { if !closed { try? input.fileHandleForWriting.close(); process.waitUntilExit() } }
}

@main struct UninstallMovedProcessTests {
    typealias FS = UninstallFileSafety
    static func main() {
        guard CommandLine.arguments.count == 3 else { fputs("Usage: UninstallMovedProcessTests NEW_RUN.noindex CHILD_BINARY\n", stderr); exit(2) }
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let childBinary = URL(fileURLWithPath: CommandLine.arguments[2])
        var fixtures: [Fixture] = []
        var passed: [String] = []
        do {
            try require(root.pathExtension == "noindex" && FS.validURL(root), "Output must be a canonical .noindex run root")
            try require(mkdir(root.path, 0o700) == 0, "Run root must be newly and exclusively created")
            func run(_ name: String, _ action: (Fixture) throws -> Void) throws {
                let fixture = try Fixture(root: root.appendingPathComponent(name, isDirectory: true), child: childBinary)
                fixtures.append(fixture)
                try action(fixture)
                try fixture.saveTrace()
                passed.append(name)
                print("PASS: " + name)
            }

            try run("round-trip-real-native") { fixture in
                let batch = try fixture.execute()
                let appReceipt = try fixture.receipt("application")
                let actualApp = try fixture.current(appReceipt)
                try require(fixture.native(fixture.app, actualApp, fixture.appBefore.identity) == 0, "Absent original plus verified current may be inactive")
                try fixture.restoreSuccess(batch)
                let moved = fixture.trace.calls.filter { $0.phase == "fresh-restore" }
                try require(moved.count >= 4 && moved.allSatisfy { $0.current == actualApp.path && $0.identity == fixture.appBefore.identity && $0.nativeResult == 0 },
                            "Cache and app restore must use same-batch actual app, never cache or absent original")
            }
            try run("original-replacement-zero-overwrite") { fixture in
                let batch = try fixture.execute()
                let appReceipt = try fixture.receipt("application"), actualApp = try fixture.current(appReceipt)
                try fixture.fm.createDirectory(at: fixture.app, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                let sentinel = fixture.app.appendingPathComponent("new-object.bin"), data = Data("Preserve new original-path object".utf8)
                try data.write(to: sentinel, options: .withoutOverwriting)
                let conflict = try FS.snapshot(fixture.app, appBundle: true)
                try require(fixture.native(fixture.app, actualApp, fixture.appBefore.identity) == -1, "Native must reject conflicting original identity")
                try fixture.rejectRestore(batch, phase: "conflict")
                try require(try FS.snapshot(fixture.app, appBundle: true) == conflict && Data(contentsOf: sentinel) == data, "Original conflict must never be overwritten")
                try require(try FS.snapshot(actualApp, appBundle: true) == fixture.appBefore, "Original conflict changed moved application")
            }
            try run("current-root-replacement-fail-closed") { fixture in
                let batch = try fixture.execute()
                let actualApp = try fixture.current(fixture.receipt("application"))
                let displaced = actualApp.appendingPathExtension("displaced")
                try fixture.rename(actualApp, displaced)
                try fixture.fm.createDirectory(at: actualApp, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                let replacement = try FS.snapshot(actualApp, appBundle: true)
                try require(fixture.native(fixture.app, actualApp, fixture.appBefore.identity) == -1, "Native must reject replaced current device/inode/UID")
                try fixture.rejectRestore(batch, phase: "current-replaced")
                try require(try FS.snapshot(actualApp, appBundle: true) == replacement, "Current replacement was modified")
                try require(try FS.snapshot(displaced, appBundle: true) == fixture.appBefore, "Displaced original app was modified")
            }
            try run("current-root-missing-fail-closed") { fixture in
                let batch = try fixture.execute()
                let actualApp = try fixture.current(fixture.receipt("application"))
                let displaced = actualApp.appendingPathExtension("displaced")
                try fixture.rename(actualApp, displaced)
                try require(fixture.native(fixture.app, actualApp, fixture.appBefore.identity) == -1, "Native must reject absent current app")
                try fixture.rejectRestore(batch, phase: "current-missing")
                try require(try FS.optionalInfo(actualApp) == nil && FS.snapshot(displaced, appBundle: true) == fixture.appBefore, "Missing-current failure changed fixture")
            }
            try run("original-parent-replacement-fail-closed") { fixture in
                let batch = try fixture.execute()
                let displaced = fixture.apps.appendingPathExtension("displaced")
                try fixture.rename(fixture.apps, displaced)
                try fixture.fm.createDirectory(at: fixture.apps, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                let beforeCalls = fixture.trace.calls.count
                try fixture.rejectRestore(batch, phase: "parent-replaced")
                try require(fixture.trace.calls.count == beforeCalls, "Changed original parent must fail before moved process lookup")
                try require(try FS.snapshot(fixture.current(fixture.receipt("application")), appBundle: true) == fixture.appBefore, "Changed-parent failure modified app")
            }
            try run("descendant-footprint-change-fail-closed") { fixture in
                let batch = try fixture.execute()
                let actualApp = try fixture.current(fixture.receipt("application"))
                let payload = actualApp.appendingPathComponent("Contents/Resources/payload.bin")
                try Data("Changed synthetic payload\n".utf8).write(to: payload)
                let changed = try FS.snapshot(actualApp, appBundle: true)
                try require(changed != fixture.appBefore, "Fixture mutation must alter full footprint")
                try fixture.rejectRestore(batch, phase: "footprint-changed")
                try require(try FS.snapshot(actualApp, appBundle: true) == changed, "Rejected footprint was modified")
            }
            try run("original-active-cli-denies-execute") { fixture in
                let engine = fixture.engine(phase: "review-before-child")
                let plan = try engine.review(appURL: fixture.app)
                let selected = Set(plan.items.filter(\.selectable).map(\.id))
                try require(selected.count == 2, "Inactive app and cache must be reviewable before child launch")
                let child = try Child(executable: fixture.app.appendingPathComponent("Contents/MacOS/FixtureChild"))
                defer { try? child.finish() }
                let observed = try child.path()
                try require(observed.hasPrefix(fixture.app.path + "/"), "Own live child must have original app prefix")
                try require(fixture.native(fixture.app, fixture.app, fixture.appBefore.identity) == 1, "Real native dual lookup must detect original-prefix process")
                try mustReject { _ = try engine.execute(planID: plan.id, selectedIDs: selected) }
                try fixture.verifyOriginals()
                try Data((observed + "\n").utf8).write(to: fixture.root.appendingPathComponent("own-child-path.txt"))
                try child.finish()
            }
            try run("moved-active-cli-denies-restore-until-eof") { fixture in
                let batch = try fixture.execute()
                let actualApp = try fixture.current(fixture.receipt("application"))
                let child = try Child(executable: actualApp.appendingPathComponent("Contents/MacOS/FixtureChild"))
                defer { try? child.finish() }
                let observed = try child.path()
                try require(observed.hasPrefix(actualApp.path + "/"), "Own live child must have moved app prefix")
                try require(fixture.native(fixture.app, actualApp, fixture.appBefore.identity) == 1, "Real native dual lookup must detect moved-prefix process")
                try fixture.rejectRestore(batch, phase: "moved-child-running")
                try require(fixture.trace.calls.last?.current == actualApp.path && fixture.trace.calls.last?.nativeResult == 1,
                            "Fresh engine must deny through genuine moved native lookup")
                try Data((observed + "\n").utf8).write(to: fixture.root.appendingPathComponent("own-child-path.txt"))
                try child.finish()
                try fixture.restoreSuccess(batch, phase: "child-eof-restore")
            }
            try run("rename-live-cli-observes-real-prefix") { fixture in
                let child = try Child(executable: fixture.app.appendingPathComponent("Contents/MacOS/FixtureChild"))
                defer { try? child.finish() }
                let oldPath = try child.path()
                let current = fixture.trash.appendingPathComponent("ManuallyRenamedFixture.app")
                try fixture.rename(fixture.app, current)
                let movedPath = try child.path()
                let prefix = movedPath.hasPrefix(fixture.app.path + "/") ? "original" : movedPath.hasPrefix(current.path + "/") ? "current" : "unexpected"
                try require(prefix != "unexpected", "Own child must retain one of the two real observed prefixes")
                try require(fixture.native(fixture.app, current, fixture.appBefore.identity) == 1, "Live child spanning real rename must prevent inactivity")
                try Data(("before=" + oldPath + "\nafter=" + movedPath + "\nobserved-prefix=" + prefix + "\n").utf8)
                    .write(to: fixture.root.appendingPathComponent("own-child-rename-path.txt"))
                try child.finish()
                try fixture.rename(current, fixture.app)
                try fixture.verifyOriginals()
            }
            try Data((passed.joined(separator: "\n") + "\n").utf8).write(to: root.appendingPathComponent("passed-cases.txt"))
            print("PASS: \(passed.count) focused real-native integration cases; no GUI, system Trash or personal data")
        } catch {
            for fixture in fixtures { try? fixture.saveTrace() }
            try? Data(("\(error)\npassed=" + passed.joined(separator: ",") + "\n").utf8).write(to: root.appendingPathComponent("failure.txt"))
            fputs("FAIL: moved process integration: \(error)\n", stderr)
            exit(1)
        }
    }
}
