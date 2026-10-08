import Foundation
import Darwin

private struct TestFailure: Error, CustomStringConvertible { let description: String }
private func require(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !value() { throw TestFailure(description: message) }
}
private final class State: @unchecked Sendable {
    var running: Bool? = false
    var calls = 0
    var identifiers: [String] = []
    var beforeLookup: (() -> Void)?
    func lookup(_ owner: String) -> Bool? { calls += 1; identifiers.append(owner); beforeLookup?(); return running }
}
private final class Fixture: @unchecked Sendable {
    let home: URL
    var journal: URL { home.appendingPathComponent("journal") }
    var trash: URL { home.appendingPathComponent(".Trash") }
    var journalFile: URL { journal.appendingPathComponent("journal.json") }
    let manager = FileManager.default
    init() throws {
        home = URL(fileURLWithPath: "/private/tmp/gaojiling-cleanup-fixture-\(UUID().uuidString)", isDirectory: true)
        try directory(home)
        try directory(home.appendingPathComponent("Library/Caches"))
        try directory(home.appendingPathComponent("Library/Logs"))
        try directory(journal)
        try directory(trash)
    }
    deinit { try? manager.removeItem(at: home) }
    func directory(_ url: URL) throws {
        try manager.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    @discardableResult func file(_ relative: String, content: String = "fixture payload") throws -> URL {
        let url = home.appendingPathComponent(relative)
        try directory(url.deletingLastPathComponent())
        try Data(content.utf8).write(to: url)
        return url
    }
    func age(_ url: URL, days: Double = 9) throws {
        let when = Date(timeIntervalSinceNow: -days * 86_400)
        var paths = [URL]()
        if let enumerator = manager.enumerator(at: url, includingPropertiesForKeys: [.isSymbolicLinkKey], options: []) {
            for case let child as URL in enumerator {
                if (try? child.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { enumerator.skipDescendants(); continue }
                paths.append(child)
            }
        }
        for path in paths.reversed() { try manager.setAttributes([.modificationDate: when], ofItemAtPath: path.path) }
        try manager.setAttributes([.modificationDate: when], ofItemAtPath: url.path)
    }
    @discardableResult func cache(_ owner: String = "com.example.cache") throws -> URL {
        let root = home.appendingPathComponent("Library/Caches/\(owner)")
        _ = try file("Library/Caches/\(owner)/nested/cache.bin")
        try age(root)
        return root
    }
    func engine(state: State = State(), action: CleanupEngine.TrashAction? = nil,
                owner: @escaping CleanupEngine.OwnerLookup = { $0.hasPrefix("com.example.") || $0 == "com.apple.dt.Xcode" }) -> CleanupEngine {
        CleanupEngine(home: home, journalDirectory: journal, appIsRunning: { state.lookup($0) },
            trash: action ?? { [self] url in
                let destination = trash.appendingPathComponent(url.lastPathComponent + "-moved")
                try manager.moveItem(at: url, to: destination)
                return destination
            }, ownerLookup: owner)
    }
    func exists(_ url: URL) -> Bool { manager.fileExists(atPath: url.path) }
}

@main struct CleanupEngineTests {
    static func main() {
        let cases: [(String, () throws -> Void)] = [
            ("Only old owned cache, rotated logs, and specific Xcode artifacts are proposed", boundedScan),
            ("Recent files, unknown owners, and unknown or active process state are skipped", inactiveOnly),
            ("Recent cache roots are skipped before ownership or content access", recentRootPreflight),
            ("System-managed Apple caches and logs are excluded from generic cleanup", systemCachesExcluded),
            ("Regular file metadata needs no read-open permission during scan or recovery", metadataOnlyRegularFiles),
            ("Symbolic links, hard links, and special files exclude the entire candidate", unsafeTrees),
            ("A substituted scan root is rejected", rootReplacement),
            ("Any tree change invalidates the approved snapshot", changedTree),
            ("Trash and relaunch restore preserve content and use the returned Trash URL", trashAndRestore),
            ("Known Trash items restore without parent listing; unknown outcomes report access limits", searchOnlyTrashRecovery),
            ("An application launched after scanning prevents cleanup", launchedAfterScan),
            ("A late symlink replacement is staged then rolled back without following it", lateReplacement),
            ("Trash failure rolls the original item back", trashFailure),
            ("An unknown Trash outcome is recovered by UUID and full footprint", lostTrashResult),
            ("Recovery keeps a newly recreated original and retains the staged item", recoveryConflict),
            ("A late replacement during restore is rejected and safely returned", lateRestoreReplacement),
            ("A crash after restore but before journaling is recognized on restart", restoredBeforeJournal),
            ("Corrupt or symlinked recovery records cannot be overwritten", badJournal),
            ("A recovery record changed during engine lifetime stops cleanup and restore", journalChangedWhileRunning),
            ("A symlinked staging directory cannot redirect cleanup", badStaging),
            ("Only the five exact developer cache rules bypass installed bundle lookup", developerCaches),
            ("Developer caches still require inactive tools and seven-day complete-tree age", developerCacheGuards),
            ("History supports restoring one chosen batch without affecting another", cleanupHistory),
            ("Cloud materialization stays disabled through operations and restores thread policy", materializationPolicy),
            ("Cancellation and stale IDs do not move any files", cancellation),
            ("Allocated-size estimates do not count sparse logical bytes as reclaimed", sparseAllocation)
        ]
        do {
            for (name, test) in cases {
                do { try test() } catch { throw TestFailure(description: "\(name): \(error)") }
                print("PASS: \(name)")
            }
            print("PASS: \(cases.count) cleanup engine tests (synthetic fixtures and injected Trash only)")
        } catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
    }

    static func boundedScan() throws {
        let f = try Fixture()
        let cache = try f.cache()
        let unknown = try f.cache("unidentified-folder")
        _ = try f.file("Library/Application Support/com.example.cache/business.db", content: "keep")
        _ = try f.file("Library/Keychains/keep.keychain", content: "keep")
        _ = try f.file("Library/Containers/com.example.cache/Data/keep", content: "keep")
        let oldLog = try f.file("Library/Logs/com.example.cache/output.log.1.gz")
        try f.age(oldLog, days: 40)
        let activeLog = try f.file("Library/Logs/com.example.cache/output.log")
        try f.age(activeLog, days: 40)
        let build = try f.file("Library/Developer/Xcode/DerivedData/Test-hash/Build/Intermediates.noindex/result.o").deletingLastPathComponent()
        try f.age(build)
        _ = try f.file("Library/Developer/Xcode/DerivedData/Test-hash/SourcePackages/checkouts/changes.swift", content: "must keep")
        let scan = try f.engine().scan()
        try require(Set(scan.items.map(\.displayPath)) == Set([cache.path, oldLog.path, build.path]), "Scan must contain exactly the three allowed old candidates")
        try require(scan.items.contains { $0.category == "旧轮转日志" && $0.reason?.contains("不可重新生成") == true }, "Historical logs must not be described as regeneratable")
        try require(f.exists(unknown) && f.exists(activeLog), "Scanning must not mutate ignored data")
        try require(scan.items.allSatisfy { $0.displayPath.hasPrefix("/") }, "Display paths must also support Finder reveal")
    }

    static func inactiveOnly() throws {
        let f = try Fixture()
        _ = try f.cache()
        let state = State()
        state.running = nil
        try require(try f.engine(state: state).scan().items.isEmpty, "Unknown process state must exclude cache")
        state.running = true
        try require(try f.engine(state: state).scan().items.isEmpty, "Running applications must be excluded")
        state.running = false
        try require(try f.engine(state: state, owner: { _ in nil }).scan().items.isEmpty, "Unknown installed ownership must exclude cache")
        let recent = try f.file("Library/Caches/com.example.cache/nested/new.bin")
        try require(try f.engine(state: state).scan().items.isEmpty, "One recent descendant must retain the entire cache directory")
        try require(f.exists(recent), "Recent cache must stay in place")
    }

    static func unsafeTrees() throws {
        let f = try Fixture()
        let target = try f.file("outside/sentinel", content: "untouched")
        let symlinkRoot = try f.cache("com.example.symlink")
        try f.manager.createSymbolicLink(at: symlinkRoot.appendingPathComponent("escape"), withDestinationURL: target.deletingLastPathComponent())
        try f.age(symlinkRoot)
        let hardRoot = try f.cache("com.example.hardlink")
        try f.manager.linkItem(at: target, to: hardRoot.appendingPathComponent("linked"))
        try f.age(hardRoot)
        let fifoRoot = try f.cache("com.example.fifo")
        try require(mkfifo(fifoRoot.appendingPathComponent("pipe").path, 0o600) == 0, "Fixture FIFO must be created")
        try f.age(fifoRoot)
        let topLink = f.home.appendingPathComponent("Library/Caches/com.example.toplink")
        try f.manager.createSymbolicLink(at: topLink, withDestinationURL: target.deletingLastPathComponent())
        try require(try f.engine().scan().items.isEmpty, "No unsafe candidate may be proposed")
        try require(try String(contentsOf: target, encoding: .utf8) == "untouched", "External fixture sentinel must stay unchanged")
    }

    static func recentRootPreflight() throws {
        let f = try Fixture()
        let root = try f.cache("com.example.recent")
        try f.manager.setAttributes([.modificationDate: Date()], ofItemAtPath: root.path)
        let queried = State()
        let engine = f.engine(owner: { identifier in _ = queried.lookup(identifier); return true })
        try require(try engine.scan().items.isEmpty, "A recent root must not become a candidate")
        try require(!queried.identifiers.contains("com.example.recent"), "Recent roots must be rejected before even querying their installed owner")
    }

    static func systemCachesExcluded() throws {
        let f = try Fixture()
        let safari = try f.cache("com.apple.Safari")
        let xcodeGeneric = try f.cache("com.apple.dt.Xcode")
        let log = try f.file("Library/Logs/com.apple.Safari/output.log.1")
        try f.age(log, days: 40)
        let build = try f.file("Library/Developer/Xcode/DerivedData/Test-hash/Build/Products/result.bin").deletingLastPathComponent()
        try f.age(build)
        let queried = State()
        let engine = f.engine(owner: { identifier in _ = queried.lookup(identifier); return true })
        let scan = try engine.scan()
        try require(scan.items.map(\.displayPath) == [build.path], "Only explicitly allowed Xcode output may bypass the Apple cache exclusion")
        try require(!queried.identifiers.contains("com.apple.Safari"), "System cache exclusion must run before LaunchServices ownership lookup")
        try require(scan.notes.contains { $0.contains("com.apple.*") } && f.exists(safari) && f.exists(xcodeGeneric) && f.exists(log), "Protected system scope must be stated and remain untouched")
    }

    static func metadataOnlyRegularFiles() throws {
        let f = try Fixture()
        let cache = try f.cache()
        let file = cache.appendingPathComponent("nested/cache.bin")
        try require(chmod(file.path, 0) == 0, "Fixture must deny every ordinary read-open")
        try f.age(cache)
        let engine = f.engine()
        let scan = try engine.scan()
        try require(scan.items.count == 1, "Metadata scanning must not open a regular file for reading")
        let moved = try engine.trash(ids: Set(scan.items.map(\.id)))
        try require(moved.removedIDs.count == 1 && moved.failed.isEmpty, "Metadata-only stage and Trash verification must succeed without opening regular files")
        let restored = f.engine().restoreLastCleanup()
        try require(restored.removedIDs.count == 1 && restored.failed.isEmpty, "Recovery must also avoid regular-file read opens")
        var info = stat()
        try require(lstat(file.path, &info) == 0 && info.st_mode & 0o777 == 0, "Engine must preserve file permissions rather than changing them to gain access")
    }

    static func rootReplacement() throws {
        let f = try Fixture()
        _ = try f.cache()
        let engine = f.engine()
        let ids = Set(try engine.scan().items.map(\.id))
        let caches = f.home.appendingPathComponent("Library/Caches")
        try f.manager.moveItem(at: caches, to: f.home.appendingPathComponent("old-caches"))
        let replacement = try f.cache()
        let result = try engine.trash(ids: ids)
        try require(result.removedIDs.isEmpty && result.skipped.count == 1, "Replacing an approved root must invalidate cleanup")
        try require(f.exists(replacement), "Replacement directory must not be touched")
    }

    static func changedTree() throws {
        let f = try Fixture()
        let cache = try f.cache()
        let engine = f.engine()
        let ids = Set(try engine.scan().items.map(\.id))
        _ = try f.file("Library/Caches/com.example.cache/nested/cache.bin", content: "changed payload")
        try f.age(cache)
        let result = try engine.trash(ids: ids)
        try require(result.removedIDs.isEmpty && result.skipped.count == 1, "A changed descendant must invalidate the old tree snapshot even with old mtimes")
        try require(f.exists(cache), "Changed cache must be preserved")
    }

    static func trashAndRestore() throws {
        let f = try Fixture()
        let cache = try f.cache()
        let engine = f.engine()
        let scan = try engine.scan()
        try require(scan.items.count == 1, "Fixture must have one candidate")
        let result = try engine.trash(ids: Set(scan.items.map(\.id)))
        try require(result.removedIDs.count == 1 && result.failed.isEmpty, "Selected cache must move to injected Trash")
        try require(result.movedBytes == scan.items[0].bytes && !f.exists(cache), "Reported bytes describe the moved candidate")
        try require(engine.canRestore, "Moved content must have a recovery record")
        let restarted = f.engine()
        try require(restarted.canRestore, "Recovery must survive a new engine instance")
        let restored = restarted.restoreLastCleanup()
        try require(restored.removedIDs.count == 1 && restored.failed.isEmpty, "Restoration must use actual returned Trash path")
        try require(try String(contentsOf: cache.appendingPathComponent("nested/cache.bin"), encoding: .utf8) == "fixture payload", "Recovery must preserve original content")
        try require(!restarted.canRestore, "Completed recovery must clear pending state")
    }

    static func launchedAfterScan() throws {
        let f = try Fixture()
        let cache = try f.cache()
        let state = State()
        let engine = f.engine(state: state)
        let ids = Set(try engine.scan().items.map(\.id))
        state.running = true
        let result = try engine.trash(ids: ids)
        try require(result.removedIDs.isEmpty && result.skipped.count == 1 && f.exists(cache), "App launch after scan must prevent moving its cache")
    }

    static func searchOnlyTrashRecovery() throws {
        let f = try Fixture()
        let cache = try f.cache()
        try require(chmod(f.trash.path, 0o300) == 0, "Fixture Trash must permit write/search but deny listing")
        defer { _ = chmod(f.trash.path, 0o700) }
        let engine = f.engine()
        let moved = try engine.trash(ids: Set(try engine.scan().items.map(\.id)))
        try require(moved.removedIDs.count == 1 && moved.failed.isEmpty, "Known destination validation must not require listing the Trash parent")
        let recovered = f.engine().restoreLastCleanup()
        try require(recovered.removedIDs.count == 1 && recovered.failed.isEmpty && f.exists(cache),
                    "Descriptor-relative restore must work with search-only parent access")

        let interrupted = try Fixture()
        _ = try interrupted.cache()
        try require(chmod(interrupted.trash.path, 0o300) == 0, "Interrupted fixture must deny Trash enumeration")
        defer { _ = chmod(interrupted.trash.path, 0o700) }
        let unknown = interrupted.engine(action: { url in
            try interrupted.manager.moveItem(at: url, to: interrupted.trash.appendingPathComponent(url.lastPathComponent + "-unknown"))
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EIO))
        })
        _ = try unknown.trash(ids: Set(try unknown.scan().items.map(\.id)))
        let limited = interrupted.engine().restoreLastCleanup()
        try require(limited.removedIDs.isEmpty && limited.failed.contains { $0.message.contains("Finder") },
                    "An unknown destination with denied listing must report an access limitation, not pretend the file is absent")
    }

    static func lateReplacement() throws {
        let f = try Fixture()
        let cache = try f.cache()
        let sentinel = try f.file("outside/sentinel", content: "do not follow")
        let state = State()
        let engine = f.engine(state: state)
        let ids = Set(try engine.scan().items.map(\.id))
        var replaced = false
        state.calls = 0
        defer { state.beforeLookup = nil }
        state.beforeLookup = {
            if state.calls == 2 {
                do {
                    try f.manager.moveItem(at: cache, to: f.home.appendingPathComponent("saved-original"))
                    try f.manager.createSymbolicLink(at: cache, withDestinationURL: sentinel.deletingLastPathComponent())
                    replaced = true
                } catch { }
            }
        }
        let result = try engine.trash(ids: ids)
        try require(replaced && result.removedIDs.isEmpty && !result.failed.isEmpty, "Late replacement must fail post-stage validation")
        try require(try String(contentsOf: sentinel, encoding: .utf8) == "do not follow", "Outside data must not be traversed or moved")
        try require(f.exists(f.home.appendingPathComponent("saved-original")), "Original candidate must remain recoverable")
        try require((try cache.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink == true, "Rejected replacement must be returned without following it")
    }

    static func trashFailure() throws {
        let f = try Fixture()
        let cache = try f.cache()
        let engine = f.engine(action: { _ in throw NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES)) })
        let result = try engine.trash(ids: Set(try engine.scan().items.map(\.id)))
        try require(result.removedIDs.isEmpty && !result.failed.isEmpty && f.exists(cache), "Trash failure must restore the staged item")
        try require(!engine.canRestore, "Successful automatic rollback must not leave stale pending state")
    }

    static func lostTrashResult() throws {
        let f = try Fixture()
        let cache = try f.cache()
        let engine = f.engine(action: { url in
            try f.manager.moveItem(at: url, to: f.trash.appendingPathComponent(url.lastPathComponent + " 2"))
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EIO))
        })
        let result = try engine.trash(ids: Set(try engine.scan().items.map(\.id)))
        try require(result.removedIDs.isEmpty && !result.failed.isEmpty && !f.exists(cache), "Fixture must model an unknown outcome after Trash moved the file")
        let restarted = f.engine()
        let restored = restarted.restoreLastCleanup()
        try require(restored.removedIDs.count == 1 && restored.failed.isEmpty && f.exists(cache), "Crash recovery must find the UUID-named moved object without a returned URL")
    }

    static func recoveryConflict() throws {
        let f = try Fixture()
        let cache = try f.cache()
        let engine = f.engine(action: { _ in
            _ = try f.file("Library/Caches/com.example.cache/new-data", content: "new app state")
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))
        })
        _ = try engine.trash(ids: Set(try engine.scan().items.map(\.id)))
        let restarted = f.engine()
        try require(restarted.canRestore, "A blocked rollback must retain its staged receipt across restart")
        let conflict = restarted.restoreLastCleanup()
        try require(conflict.removedIDs.isEmpty && conflict.skipped.count == 1, "Restoration must not replace a recreated cache")
        try require(try String(contentsOf: cache.appendingPathComponent("new-data"), encoding: .utf8) == "new app state", "New app data must remain unchanged")
        try f.manager.removeItem(at: cache) // Only remove our known fixture to resolve the simulated conflict.
        let restored = restarted.restoreLastCleanup()
        try require(restored.removedIDs.count == 1 && f.exists(cache.appendingPathComponent("nested/cache.bin")), "Resolving a conflict must allow staged recovery")
    }

    static func restoredBeforeJournal() throws {
        let f = try Fixture()
        let cache = try f.cache()
        let engine = f.engine()
        _ = try engine.trash(ids: Set(try engine.scan().items.map(\.id)))
        let oldJournal = try Data(contentsOf: f.journalFile)
        try require(engine.restoreLastCleanup().removedIDs.count == 1, "Fixture restore must succeed")
        try oldJournal.write(to: f.journalFile) // Simulate crash before the post-rename journal was persisted.
        let restarted = f.engine()
        let result = restarted.restoreLastCleanup()
        try require(result.failed.isEmpty && !restarted.canRestore && f.exists(cache), "Restart must recognize the original inode is already safely restored")
    }

    static func lateRestoreReplacement() throws {
        let f = try Fixture()
        let cache = try f.cache()
        let state = State()
        let engine = f.engine(state: state)
        _ = try engine.trash(ids: Set(try engine.scan().items.map(\.id)))
        let trashName = try f.manager.contentsOfDirectory(atPath: f.trash.path).first!
        let trashItem = f.trash.appendingPathComponent(trashName)
        let sentinel = try f.file("outside/sentinel", content: "untouched")
        state.calls = 0
        var replaced = false
        defer { state.beforeLookup = nil }
        state.beforeLookup = {
            if state.calls == 2 {
                do {
                    try f.manager.moveItem(at: trashItem, to: f.home.appendingPathComponent("saved-trash-original"))
                    try f.manager.createSymbolicLink(at: trashItem, withDestinationURL: sentinel.deletingLastPathComponent())
                    replaced = true
                } catch { }
            }
        }
        let result = engine.restoreLastCleanup()
        try require(replaced && result.removedIDs.isEmpty && !result.failed.isEmpty && !f.exists(cache),
                    "A swapped restore source must fail post-rename verification and return to Trash")
        try require((try trashItem.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink == true,
                    "Rollback must move the replacement link itself, never its target")
        try require(try String(contentsOf: sentinel, encoding: .utf8) == "untouched", "Restore must not touch an external sentinel")
    }

    static func badJournal() throws {
        let f = try Fixture()
        _ = try f.cache()
        let corrupt = Data("not json".utf8)
        try corrupt.write(to: f.journalFile)
        let engine = f.engine()
        var scanFailed = false
        do { _ = try engine.scan() } catch { scanFailed = true }
        var trashFailed = false
        do { _ = try engine.trash(ids: ["old"]) } catch { trashFailed = true }
        try require(scanFailed && trashFailed && !engine.restoreLastCleanup().failed.isEmpty, "Unreadable journal must block all mutations")
        try require(try Data(contentsOf: f.journalFile) == corrupt, "Corrupt recovery state must not become an empty replacement journal")
        try f.manager.removeItem(at: f.journalFile)
        let sentinel = try f.file("outside/journal", content: "keep")
        try f.manager.createSymbolicLink(at: f.journalFile, withDestinationURL: sentinel)
        let linked = f.engine()
        do { _ = try linked.scan(); throw TestFailure(description: "Symlinked journal was accepted") }
        catch is TestFailure { throw TestFailure(description: "Symlinked journal was accepted") }
        catch { }
        try require(try String(contentsOf: sentinel, encoding: .utf8) == "keep", "Symlinked journal target must remain untouched")
    }

    static func badStaging() throws {
        let f = try Fixture()
        let cache = try f.cache()
        let outside = f.home.appendingPathComponent("outside")
        try f.directory(outside)
        try f.manager.createSymbolicLink(at: f.home.appendingPathComponent("Library/Caches/.GaoJiLing-CleanupStage"), withDestinationURL: outside)
        let engine = f.engine()
        let result = try engine.trash(ids: Set(try engine.scan().items.map(\.id)))
        try require(result.removedIDs.isEmpty && f.exists(cache), "A substituted staging directory must stop mutation")
        try require(try f.manager.contentsOfDirectory(atPath: outside.path).isEmpty, "Cleanup must not populate a symlinked staging target")
    }

    static func journalChangedWhileRunning() throws {
        let f = try Fixture()
        let cache = try f.cache()
        let engine = f.engine()
        let ids = Set(try engine.scan().items.map(\.id))
        let changed = Data("external change".utf8)
        try changed.write(to: f.journalFile)
        var blocked = false
        do { _ = try engine.trash(ids: ids) } catch { blocked = true }
        try require(blocked && f.exists(cache) && (try Data(contentsOf: f.journalFile)) == changed,
                    "A journal created after initialization must not be overwritten or allow a move")

        let other = try Fixture()
        let otherCache = try other.cache()
        let restoreEngine = other.engine()
        _ = try restoreEngine.trash(ids: Set(try restoreEngine.scan().items.map(\.id)))
        try changed.write(to: other.journalFile)
        let report = restoreEngine.restoreLastCleanup()
        try require(!report.failed.isEmpty && !other.exists(otherCache) && (try Data(contentsOf: other.journalFile)) == changed,
                    "Restore must detect a modified journal before it moves any file")
    }

    static func cancellation() throws {
        let f = try Fixture()
        let cache = try f.cache()
        let engine = f.engine()
        try require(try engine.scan(cancelled: { true }).items.isEmpty, "Pre-cancelled scan must produce no candidates")
        let ids = Set(try engine.scan().items.map(\.id))
        let cancelled = try engine.trash(ids: ids, cancelled: { true })
        try require(cancelled.removedIDs.isEmpty && cancelled.skipped.count == 1 && f.exists(cache), "Cancelled cleanup must preserve selected files")
        _ = try engine.scan()
        let stale = try engine.trash(ids: ids)
        try require(stale.removedIDs.isEmpty && stale.skipped.count == 1 && f.exists(cache), "A new scan must invalidate old candidate IDs")
    }

    static func developerCaches() throws {
        let f = try Fixture()
        let paths = [".npm/_cacache", "Library/Caches/pip", "Library/Caches/pypoetry", "Library/Caches/Homebrew", ".gradle/caches"]
        for path in paths {
            _ = try f.file(path + "/nested/cache.bin")
            try f.age(f.home.appendingPathComponent(path))
        }
        for path in [".npmrc", ".gradle/gradle.properties", ".m2/repository/keep", "project/node_modules/keep", "project/venv/keep", "Models/keep", "Library/Containers/com.docker.docker/keep"] {
            _ = try f.file(path, content: "keep source or configuration")
        }
        let engine = f.engine(owner: { _ in false })
        let scan = try engine.scan()
        try require(Set(scan.items.map(\.displayPath)) == Set(paths.map { f.home.appendingPathComponent($0).path }),
                    "Developer candidates must be the exact known cache paths even without installed app bundles")
        try require(scan.items.allSatisfy { $0.category == "开发工具缓存" }, "Developer rules must be visibly categorized")
        let moved = try engine.trash(ids: Set(scan.items.map(\.id)))
        try require(moved.removedIDs.count == 5 && moved.failed.isEmpty, "All five known inactive caches must support reversible cleanup")
        let restarted = f.engine(owner: { _ in false })
        let restored = restarted.restoreLastCleanup()
        try require(restored.removedIDs.count == 5 && restored.failed.isEmpty, "Recovery whitelist must accept all five exact owner/path pairs")
        try require(paths.allSatisfy { f.exists(f.home.appendingPathComponent($0 + "/nested/cache.bin")) }, "Developer cache restoration must preserve content")
        try require(try String(contentsOf: f.home.appendingPathComponent(".npmrc"), encoding: .utf8) == "keep source or configuration", "Tool credentials/configuration must remain untouched")
    }

    static func developerCacheGuards() throws {
        let f = try Fixture()
        let root = try f.file(".npm/_cacache/old.bin").deletingLastPathComponent()
        try f.age(root)
        let state = State()
        state.running = nil
        try require(try f.engine(state: state, owner: { _ in false }).scan().items.isEmpty, "Unknown npm process state must exclude its cache")
        state.running = true
        try require(try f.engine(state: state, owner: { _ in false }).scan().items.isEmpty, "Running npm must exclude its cache")
        state.running = false
        let recent = try f.file(".npm/_cacache/new.bin")
        try require(try f.engine(state: state, owner: { _ in false }).scan().items.isEmpty, "A recent child must exclude the developer cache")
        try f.age(root)
        let sentinel = try f.file("outside/keep")
        try f.manager.createSymbolicLink(at: root.appendingPathComponent("escape"), withDestinationURL: sentinel)
        try f.age(root)
        try require(try f.engine(state: state, owner: { _ in false }).scan().items.isEmpty && f.exists(recent), "Known developer rules must retain all ordinary symlink and age protections")
    }

    static func cleanupHistory() throws {
        let f = try Fixture()
        let first = try f.cache()
        let engine = f.engine()
        _ = try engine.trash(ids: Set(try engine.scan().items.map(\.id)))
        let firstID = try { () throws -> String in
            guard let entry = engine.history.first else { throw TestFailure(description: "First batch needs history") }
            try require(entry.itemCount == 1 && entry.restorableCount == 1 && abs(entry.date.timeIntervalSinceNow) < 120, "History must report actual batch time and restorable count")
            return entry.id
        }()
        let second = try f.cache("com.example.other")
        _ = try engine.trash(ids: Set(try engine.scan().items.map(\.id)))
        try require(engine.history.count == 2 && engine.history[0].id != firstID, "History must retain both batches newest first")
        let restarted = f.engine()
        let firstRestore = restarted.restore(batchID: firstID)
        try require(firstRestore.removedIDs.count == 1 && f.exists(first) && !f.exists(second), "Restoring a chosen old batch must leave the newer batch in Trash")
        try require(restarted.history.first(where: { $0.id == firstID })?.restorableCount == 0 && restarted.canRestore, "Only the restored batch should lose its pending count")
        let invalid = restarted.restore(batchID: "missing-batch")
        try require(invalid.removedIDs.isEmpty && !invalid.skipped.isEmpty, "Unknown batch IDs must never restore another batch")
        try require(restarted.restoreLastCleanup().removedIDs.count == 1 && f.exists(second), "Restore latest must reuse per-batch restore behavior")
        try require(!restarted.canRestore && restarted.history.allSatisfy { $0.restorableCount == 0 }, "Recovered history must persist without stale pending items")
    }

    static func sparseAllocation() throws {
        let f = try Fixture()
        let cache = try f.cache()
        let url = cache.appendingPathComponent("sparse.bin")
        try Data().write(to: url)
        let handle = try FileHandle(forWritingTo: url)
        try handle.seek(toOffset: 128 * 1024 * 1024)
        try handle.write(contentsOf: Data([1]))
        try handle.close()
        try f.age(cache)
        let items = try f.engine().scan().items
        try require(items.count == 1 && items[0].bytes < 128 * 1024 * 1024, "Allocated estimate must account for sparse storage, not its logical length")
    }

    static func materializationPolicy() throws {
        let type = Int32(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES)
        let scope = Int32(IOPOL_SCOPE_THREAD)
        let previous = getiopolicy_np(type, scope)
        let f = try Fixture()
        _ = try f.cache()
        let engine = CleanupEngine(home: f.home, journalDirectory: f.journal, appIsRunning: { _ in
            getiopolicy_np(type, scope) == Int32(IOPOL_MATERIALIZE_DATALESS_FILES_OFF) ? false : nil
        }, trash: { url in
            try require(getiopolicy_np(type, scope) == Int32(IOPOL_MATERIALIZE_DATALESS_FILES_OFF), "Trash callback must retain non-materializing policy")
            let destination = f.trash.appendingPathComponent(url.lastPathComponent)
            try f.manager.moveItem(at: url, to: destination)
            return destination
        }, ownerLookup: { $0 == "com.example.cache" })
        try require(getiopolicy_np(type, scope) == previous, "Initialization must restore thread policy")
        let scan = try engine.scan()
        try require(scan.items.count == 1 && getiopolicy_np(type, scope) == previous, "Scan must be non-materializing and restore thread policy")
        let moved = try engine.trash(ids: Set(scan.items.map(\.id)))
        try require(moved.removedIDs.count == 1 && getiopolicy_np(type, scope) == previous, "Cleanup must restore thread policy")
        try require(engine.restoreLastCleanup().removedIDs.count == 1 && getiopolicy_np(type, scope) == previous, "Recovery must restore thread policy")
        try Data("corrupt".utf8).write(to: f.journalFile)
        do { _ = try engine.trash(ids: ["stale"]); throw TestFailure(description: "Expected journal failure") }
        catch is TestFailure { throw TestFailure(description: "Expected journal failure") }
        catch { }
        try require(getiopolicy_np(type, scope) == previous, "Thrown errors must also restore the prior thread policy")
    }
}
