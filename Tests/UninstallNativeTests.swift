import Foundation
import Darwin

private struct NativeCheckFailure: Error, CustomStringConvertible {
    let description: String
}

private func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw NativeCheckFailure(description: message) }
}

/// This executable never launches an application. The opt-in creates only its
/// own UUID bundle/cache, then exercises FileManager.trashItem through the real
/// engine. There is deliberately no deinit/defer that removes a failed fixture.
private final class NativeFixture {
    typealias FS = UninstallFileSafety
    let fm = FileManager.default
    let root: URL
    let home: URL
    let bundleID: String
    let app: URL
    let cache: URL
    let nonce: String
    private var known: [String: UninstallIdentity] = [:]
    private var contents: [String: Data] = [:]
    private var links: [String: String] = [:]

    var apps: URL { home.appendingPathComponent("Applications", isDirectory: true) }
    var ledger: URL { home.appendingPathComponent("Library/Application Support/GaoSeries/GaoJiLing/Uninstall/journal.json") }

    init(root: URL, nonce: String) {
        self.root = root; self.nonce = nonce
        home = root.appendingPathComponent("home", isDirectory: true)
        bundleID = "org.example.gaojiling-native-test." + nonce.lowercased()
        app = home.appendingPathComponent("Applications/NativeFixture-\(nonce).app", isDirectory: true)
        cache = home.appendingPathComponent("Library/Caches/" + bundleID, isDirectory: true)
    }

    func prepare() throws {
        // Exclusive creation prevents a colliding existing object becoming a fixture.
        guard mkdir(root.path, 0o700) == 0 else { throw NativeCheckFailure(description: "Cannot create exclusive fixture root") }
        known[root.path] = try identity(root)
        try directory(home)
        try file(root.appendingPathComponent("fixture-id"), Data(nonce.utf8))
        try file(app.appendingPathComponent("Contents/MacOS/Fixture"), Data("Synthetic test only; never execute.\n".utf8))
        let info: [String: Any] = ["CFBundleIdentifier": bundleID, "CFBundleName": "NativeFixture-" + nonce,
            "CFBundleShortVersionString": "1.0", "CFBundlePackageType": "APPL", "CFBundleExecutable": "Fixture"]
        try file(app.appendingPathComponent("Contents/Info.plist"),
                 PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0))
        try file(app.appendingPathComponent("Contents/Resources/payload.bin"), Data([0, 1, 2, 127, 128, 255]))
        let outside = home.appendingPathComponent("Documents/sentinel.txt")
        try file(outside, Data(("Keep external target " + nonce).utf8))
        try link(app.appendingPathComponent("Contents/Resources/ExternalLink"), target: outside.path)
        try link(app.appendingPathComponent("Contents/Resources/RelativeLink"), target: "payload.bin")
        try file(cache.appendingPathComponent("nested/cache.bin"), Data(("Old cache " + nonce).utf8))
        try file(home.appendingPathComponent("Library/Caches/" + bundleID + ".unrelated/keep.bin"), Data(nonce.utf8))
        // Known exact paths only: no recursive traversal of anyone's cache.
        let old = Date(timeIntervalSinceNow: -8 * 86_400)
        for path in [cache.appendingPathComponent("nested/cache.bin"), cache.appendingPathComponent("nested"), cache] {
            try fm.setAttributes([.modificationDate: old], ofItemAtPath: path.path)
            let metadata = try FS.info(path)
            try require(Date().timeIntervalSince1970 - Double(metadata.st_mtimespec.tv_sec) >= 7 * 86_400,
                        "The exact cache and descendants must pass the seven-day policy")
        }
    }

    func makeEngine() -> UninstallEngine {
        let path = app.path, identifier = bundleID, appIdentity = known[app.path]
        return UninstallEngine(home: home, applicationRoots: [apps], appIsRunning: { candidate in
            // This never-executed bundle is the only identity allowed as inactive.
            candidate.path == path && candidate.bundleID == identifier && candidate.identity == appIdentity ? false : nil
        }) // No injected trash, rename, journal writer or fake recovery path.
    }

    func run() throws {
        let engine = makeEngine()
        try require(engine.recoveryError == nil, "Fresh production engine must load")
        let plan = try engine.review(appURL: app, expectedBundleID: bundleID, expectedIdentity: known[app.path])
        let selected = plan.items.filter(\.selectable)
        try require(plan.complete && Set(selected.compactMap(\.path)) == Set([app.path, cache.path]),
                    "Only the UUID app and its exact old cache may be selectable")
        let selectedIDs = Set(selected.map(\.id))
        let moved = try engine.execute(planID: plan.id, selectedIDs: selectedIDs)
        try require(!moved.cancelled && moved.issues.isEmpty && Set(moved.movedIDs) == selectedIDs,
                    "Native Trash must move both selected objects without issues")
        guard let batchID = moved.batchID else { throw NativeCheckFailure(description: "Native move did not record a batch") }
        let receipts = try readReceipts(batchID: batchID)
        try require(receipts.count == 2 && Set(receipts.map(\.original)) == Set([app.path, cache.path]),
                    "Journal must contain exactly the approved app and cache")
        let trashRoot = try fm.url(for: .trashDirectory, in: .userDomainMask, appropriateFor: home, create: false)
        for receipt in receipts {
            guard let path = receipt.trash else { throw NativeCheckFailure(description: "Native Trash URL missing from receipt") }
            let destination = URL(fileURLWithPath: path)
            try require(UUID(uuidString: receipt.id) != nil && receipt.state == "trashed" &&
                        destination.deletingLastPathComponent() == trashRoot &&
                        destination.lastPathComponent.hasPrefix("GaoJiLing-Uninstall-" + receipt.id),
                        "Receipt must point to its own UUID object in the real system Trash")
            try require(try identity(destination) == known[receipt.original], "Trash must preserve device, inode, type and UID")
            try require(try FS.optionalInfo(URL(fileURLWithPath: receipt.original)) == nil, "Moved original path must be absent")
            try require(try FS.optionalInfo(URL(fileURLWithPath: receipt.stage)) == nil, "Completed move must leave no staged object")
        }

        // A fresh instance must reconstruct the actual native recovery locations.
        let restarted = makeEngine()
        try require(restarted.recoveryError == nil && restarted.history.count == 1 &&
                    restarted.history.first?.id == batchID && restarted.history.first?.pendingCount == 2,
                    "Restart must retain both pending native Trash receipts")
        let restored = restarted.restore(batchID: batchID)
        try require(!restored.cancelled && restored.issues.isEmpty && Set(restored.movedIDs) == selectedIDs,
                    "Fresh engine must restore both objects through production restore")
        try verifyOriginals()
        for receipt in receipts {
            // Check these exact receipt paths only; never enumerate or empty Trash.
            try require(try FS.optionalInfo(URL(fileURLWithPath: receipt.trash!)) == nil,
                        "Restored receipt must no longer have a Trash object")
            try require(try FS.optionalInfo(URL(fileURLWithPath: receipt.stage)) == nil,
                        "Restored receipt must no longer have a staged object")
        }
        let completed = makeEngine()
        try require(completed.recoveryError == nil && completed.history.count == 1 &&
                    completed.history.first?.pendingCount == 0 && completed.history.first?.itemCount == 2,
                    "Restart after restoration must report no pending work")
        try require(try readReceipts(batchID: batchID).allSatisfy { $0.state == "restored" },
                    "Both durable receipts must be marked restored")
        let repeated = completed.restore(batchID: batchID)
        try require(repeated.issues.isEmpty && repeated.movedIDs.isEmpty, "Restoration must be idempotent")
        try verifyOriginals()
    }

    private struct Receipt: Decodable {
        let id: String, original: String, stage: String, state: String
        let trash: String?
    }
    private struct Batch: Decodable { let id: String; let receipts: [Receipt] }
    private struct Journal: Decodable { let version: Int; let batches: [Batch] }
    private func readReceipts(batchID: String) throws -> [Receipt] {
        let journal = try JSONDecoder().decode(Journal.self, from: Data(contentsOf: ledger))
        try require(journal.version == 1 && journal.batches.count == 1 && journal.batches[0].id == batchID,
                    "Only the fixture's own batch may be present")
        return journal.batches[0].receipts
    }

    private func identity(_ url: URL) throws -> UninstallIdentity { UninstallIdentity(try FS.info(url)) }
    private func directory(_ url: URL) throws {
        if known[url.path] != nil { return }
        try require(url.path.hasPrefix(root.path + "/"), "Fixture directory escaped UUID root")
        try directory(url.deletingLastPathComponent())
        guard mkdir(url.path, 0o700) == 0 else { throw NativeCheckFailure(description: "Cannot create exclusive fixture directory") }
        known[url.path] = try identity(url)
    }
    private func file(_ url: URL, _ data: Data) throws {
        try directory(url.deletingLastPathComponent())
        try data.write(to: url, options: .withoutOverwriting)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        known[url.path] = try identity(url); contents[url.path] = data
    }
    private func link(_ url: URL, target: String) throws {
        try fm.createSymbolicLink(atPath: url.path, withDestinationPath: target)
        known[url.path] = try identity(url); links[url.path] = target
    }
    private func verifyOriginals() throws {
        for (path, original) in known {
            try require(try identity(URL(fileURLWithPath: path)) == original,
                        "Fixture object device/inode/type/UID must survive the round trip")
        }
        for (path, data) in contents {
            try require(try Data(contentsOf: URL(fileURLWithPath: path)) == data, "Fixture content or external target changed")
        }
        for (path, target) in links {
            try require(try fm.destinationOfSymbolicLink(atPath: path) == target, "App bundle link target changed")
        }
    }

    /// Only after all restoration assertions pass. unlink/rmdir act on exact
    /// known objects and cannot recursively delete an unexpected child.
    func cleanSuccessfulFixture() throws {
        try verifyOriginals()
        let generated = ["Library/Application Support", "Library/Application Support/GaoSeries",
            "Library/Application Support/GaoSeries/GaoJiLing", "Library/Application Support/GaoSeries/GaoJiLing/Uninstall",
            "Library/Application Support/GaoSeries/GaoJiLing/Uninstall/journal.json",
            "Library/Application Support/GaoSeries/GaoJiLing/Uninstall.initialized",
            "Library/Caches/.GaoJiLing-UninstallStage"]
        for relative in generated {
            let url = home.appendingPathComponent(relative)
            known[url.path] = try identity(url)
        }
        // All identity checks happen before deleting anything; unknown children
        // still make rmdir fail safely, never trigger recursive cleanup.
        for (path, expected) in known { try require(try identity(URL(fileURLWithPath: path)) == expected, "Cleanup identity changed") }
        for (path, expected) in known.sorted(by: { $0.key.count > $1.key.count }) {
            try require(try identity(URL(fileURLWithPath: path)) == expected, "Cleanup object was replaced")
            let result = expected.kind == UInt32(S_IFDIR) ? rmdir(path) : unlink(path)
            guard result == 0 else { throw NativeCheckFailure(description: "Cleanup left a fixture object in place") }
        }
    }
}

@main struct UninstallNativeTests {
    static func main() {
        guard ProcessInfo.processInfo.environment["GJL_RUN_UNINSTALL_NATIVE"] == "1" else {
            print("SKIP: native uninstall Trash/restore test (requires separately coordinated GJL_RUN_UNINSTALL_NATIVE=1)")
            return
        }
        let nonce = UUID().uuidString
        let root = URL(fileURLWithPath: "/private/tmp/gaojiling-uninstall-native-" + nonce, isDirectory: true)
        let fixture = NativeFixture(root: root, nonce: nonce)
        do {
            try fixture.prepare()
            try fixture.run()
        } catch {
            fputs("FAIL: native uninstall fixture: \(error)\nPreserved fixture and recovery records: \(root.path)\n", stderr)
            exit(1)
        }
        do { try fixture.cleanSuccessfulFixture() }
        catch {
            fputs("WARN: round trip passed; exact fixture cleanup stopped safely at \(root.path)\n", stderr)
        }
        print("PASS: production native Trash → engine restart → restore; device/inode/content/links preserved, no pending receipts")
    }
}
