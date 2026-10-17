import Foundation
import Darwin

private struct RecoveryTestFailure: Error, CustomStringConvertible { let description: String }
private func require(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !value() { throw RecoveryTestFailure(description: message) }
}
private func rejects(_ message: String, _ body: () throws -> Void) throws {
    do { try body() } catch is RecoveryTestFailure { throw RecoveryTestFailure(description: message) } catch { return }
    throw RecoveryTestFailure(description: message)
}
private final class RecoveryState: @unchecked Sendable { var cancelled = false; var writes = 0; var substitutedURL: URL? }
private final class DuplicateFixture: @unchecked Sendable {
    let home = URL(fileURLWithPath: "/private/tmp/gaojiling-duplicate-recovery-\(UUID().uuidString)", isDirectory: true)
    let fm = FileManager.default
    let state = RecoveryState()
    var scope: URL { home.appendingPathComponent("selected") }
    var trash: URL { home.appendingPathComponent(".Trash") }
    var data: URL { home.appendingPathComponent("Data") }
    var journal: URL { data.appendingPathComponent("Duplicates") }
    var ledger: URL { journal.appendingPathComponent("journal.json") }
    init() throws { for dir in [home, scope, trash, home.appendingPathComponent("Library/Caches")] { try mkdir(dir) } }
    deinit { try? fm.removeItem(at: home) }
    func mkdir(_ url: URL) throws { try fm.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
    @discardableResult func file(_ name: String, content: Data = Data(repeating: 0x5a, count: 4096)) throws -> URL {
        let url = scope.appendingPathComponent(name); try mkdir(url.deletingLastPathComponent()); try content.write(to: url); return url
    }
    func scan(count: Int = 3) throws -> DuplicateScanResult {
        for i in 0..<count { try file("copy-\(i).bin") }
        return try DuplicateAnalyzer().scan(directory: scope)
    }
    func engine(action: DuplicateRecovery.TrashAction? = nil, writer: DuplicateRecovery.JournalWriter? = nil,
                rename: DuplicateRecovery.RenameAction? = nil) -> DuplicateRecovery {
        DuplicateRecovery(home: home, journalDirectory: journal, trash: action ?? { [self] source in
            let destination = trash.appendingPathComponent(source.lastPathComponent + "-fixture")
            try fm.moveItem(at: source, to: destination); return destination
        }, journalWriter: writer, rename: rename)
    }
    func exists(_ path: String) -> Bool { fm.fileExists(atPath: path) }
    func jsonEdit(_ body: (inout [String: Any]) -> Void) throws {
        var object = try JSONSerialization.jsonObject(with: Data(contentsOf: ledger)) as! [String: Any]
        body(&object); try JSONSerialization.data(withJSONObject: object).write(to: ledger)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: ledger.path)
    }
}

@main struct DuplicateRecoveryTests {
    static func main() {
        let tests: [(String, () throws -> Void)] = [
            ("Explicit subset move, persistent real receipt, restart, and exact restore", roundTrip),
            ("Empty and all-group selections cannot move files", explicitSubset),
            ("A changed selected copy or keeper is rejected before moving", changedCopies),
            ("Partial and cancelled scans never grant move permission", incomplete),
            ("Document and database protection survives forged selection", protectedFiles),
            ("Hard-linked or repeated physical identities cannot be processed as separate copies", hardlinks),
            ("Trash failure returns only the unchanged exact staged object", trashFailure),
            ("Unknown Trash outcome is recovered by receipt identity without replay", unknownTrash),
            ("Partial cancellation preserves completed receipts and an unselected keeper", cancellation),
            ("Restore leaves a new original-path file intact", restoreConflict),
            ("Changed recovery content is retained instead of restored", changedRecovery),
            ("Corrupt, future, missing and externally changed journals fail closed", badJournals),
            ("A missing journal folder is detected by the independent marker", missingFolder),
            ("A linked private stage cannot redirect file movement", stageSymlink),
            ("Journal write failures before and after staging remain recoverable", writeFailures),
            ("Substituted staging objects are never rolled back", substitutedStage),
            ("Late source replacement after receipt save is caught by final FD checks", lastCheck),
            ("Forged recovery paths and marker changes cannot broaden recovery", badPaths),
            ("Stage and journal directory replacement after receipt save stops before file movement", replacedDirectories),
            ("Production journal final checkpoint preserves externally modified bytes", finalJournalCheck),
            ("A keeper changed during staging stops Trash and rolls the selected file back", lastKeeperCheck),
            ("Production journal never promotes or removes a substituted temporary file", replacedJournalTemporary),
            ("Private stage permissions are checked again at the last move checkpoint", stagePermissions)
        ]
        do {
            for (name, test) in tests {
                do { try test() } catch { throw RecoveryTestFailure(description: "\(name): \(error)") }
                print("PASS: \(name)")
            }
            print("PASS: \(tests.count) duplicate recovery groups; synthetic files and injected Trash only")
        } catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
    }
    private static func one(_ result: DuplicateScanResult) throws -> DuplicateFile {
        guard result.complete, let group = result.groups.first, group.files.count >= 2 else { throw RecoveryTestFailure(description: "Synthetic complete duplicate group expected") }
        return group.files[0]
    }
    static func roundTrip() throws {
        let f = try DuplicateFixture(), result = try f.scan(), selected = try one(result), engine = f.engine()
        try require(result.groups[0].files.allSatisfy { !$0.isSelected }, "Candidates must default to retained")
        let report = try engine.execute(result: result, selectedIDs: [selected.id])
        try require(report.batchID == result.id.uuidString && report.movedIDs == [selected.id] && report.issues.isEmpty, "Move must return the real persistent batch")
        try require(!f.exists(selected.path) && result.groups[0].files.dropFirst().allSatisfy { f.exists($0.path) }, "At least one original physical file must remain")
        try require(try Data(contentsOf: engine.initializationMarkerURL) == Data("GaoJiLing.DuplicateJournal.v1\n".utf8), "Independent marker must be durable")
        let reloaded = f.engine()
        try require(reloaded.recoveryError == nil && reloaded.history.first?.pendingCount == 1, "Restart must load the actual pending receipt")
        let repeated = try reloaded.execute(result: result, selectedIDs: [selected.id])
        try require(repeated.movedIDs.isEmpty && reloaded.history.first?.pendingCount == 1, "Receipt idempotence must prevent replay")
        let restored = reloaded.restore(batchID: result.id.uuidString)
        try require(restored.restoredIDs == [selected.id] && restored.issues.isEmpty, "Explicit restore must return the actual restored item")
        try require(try Data(contentsOf: URL(fileURLWithPath: selected.path)) == Data(repeating: 0x5a, count: 4096), "Restored bytes must match")
        try require(reloaded.history.first?.pendingCount == 0, "Restored receipt must be durable")
    }
    static func explicitSubset() throws {
        let f = try DuplicateFixture(), result = try f.scan(), engine = f.engine()
        try rejects("Empty choice must fail") { _ = try engine.execute(result: result, selectedIDs: []) }
        try rejects("Every group needs a keeper") { _ = try engine.execute(result: result, selectedIDs: Set(result.groups[0].files.map(\.id))) }
        try require(!f.exists(engine.initializationMarkerURL.path) && result.groups[0].files.allSatisfy { f.exists($0.path) }, "Invalid selection must precede journal side effects")
    }
    static func changedCopies() throws {
        for changeKeeper in [false, true] {
            let f = try DuplicateFixture(), result = try f.scan(), selected = try one(result)
            let changed = result.groups[0].files[changeKeeper ? 1 : 0]
            try Data(repeating: 0x42, count: 4096).write(to: URL(fileURLWithPath: changed.path))
            let report = try f.engine().execute(result: result, selectedIDs: [selected.id])
            try require(report.movedIDs.isEmpty && !report.issues.isEmpty && f.exists(selected.path), "Both selected and keeper changes invalidate the move")
        }
    }
    static func incomplete() throws {
        let f = try DuplicateFixture(), result = try f.scan(), selected = try one(result)
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(result)) as! [String: Any]
        for cancelled in [false, true] {
            object["complete"] = false; object["cancelled"] = cancelled
            let partial = try JSONDecoder().decode(DuplicateScanResult.self, from: JSONSerialization.data(withJSONObject: object))
            try rejects("Incomplete result must not be executable") { _ = try f.engine().execute(result: partial, selectedIDs: [selected.id]) }
        }
        try require(f.exists(selected.path), "Incomplete selection remains intact")
    }
    static func protectedFiles() throws {
        let f = try DuplicateFixture()
        try f.file("one.pdf"); try f.file("two.pdf")
        let result = try DuplicateAnalyzer().scan(directory: f.scope)
        try require(result.complete && result.groups.count == 1 && result.groups[0].files.allSatisfy { $0.protectionReason != nil }, "Documents may be compared but not selected")
        try rejects("Protected file must remain protected even if the UI forges its ID") { _ = try f.engine().execute(result: result, selectedIDs: [result.groups[0].files[0].id]) }
        try require(DuplicateFileSafety.movableReason(path: "/System/a.bin", scope: "/System") != nil &&
                    DuplicateFileSafety.movableReason(path: "/Users/fixture/Library/Group Containers/x/a", scope: "/Users/fixture") != nil &&
                    DuplicateFileSafety.movableReason(path: f.scope.appendingPathComponent("records.db").path, scope: f.scope.path) != nil, "System, shared business data, and databases remain protected")
    }
    static func hardlinks() throws {
        let f = try DuplicateFixture(), a = try f.file("a.bin"), b = try f.file("b.bin")
        let alias = f.scope.appendingPathComponent("alias.bin")
        try require(link(a.path, alias.path) == 0, "Make synthetic hard link")
        let result = try DuplicateAnalyzer().scan(directory: f.scope)
        guard let group = result.groups.first, let linked = group.files.first(where: { $0.identity.linkCount > 1 }) else { throw RecoveryTestFailure(description: "Expected hardlinked physical file") }
        try rejects("Hard link cannot be moved") { _ = try f.engine().execute(result: result, selectedIDs: [linked.id]) }
        try require(f.exists(a.path) && f.exists(b.path) && f.exists(alias.path), "Hard-linked names remain intact")
    }
    static func trashFailure() throws {
        let f = try DuplicateFixture(), result = try f.scan(), selected = try one(result)
        let report = try f.engine(action: { _ in throw UninstallFailure(message: "Synthetic Trash failure") }).execute(result: result, selectedIDs: [selected.id])
        try require(report.movedIDs.isEmpty && report.issues.count == 1 && f.exists(selected.path), "Trash failure must roll back original bytes")
        try require(f.engine().history.isEmpty, "Untouched rollback is not a pending moved item")
    }
    static func unknownTrash() throws {
        let f = try DuplicateFixture(), result = try f.scan(), selected = try one(result)
        let engine = f.engine(action: { source in
            try f.fm.moveItem(at: source, to: f.trash.appendingPathComponent(source.lastPathComponent + "-unknown"))
            throw UninstallFailure(message: "Synthetic outcome lost after the OS move")
        })
        let report = try engine.execute(result: result, selectedIDs: [selected.id])
        try require(report.movedIDs.isEmpty && !report.issues.isEmpty && !f.exists(selected.path), "Unconfirmed move must not be advertised as completed")
        let restored = f.engine().restore(batchID: result.id.uuidString)
        try require(restored.restoredIDs == [selected.id] && restored.issues.isEmpty && f.exists(selected.path), "Receipt must locate only its matching unknown-outcome physical object")
    }
    static func cancellation() throws {
        let f = try DuplicateFixture(), result = try f.scan(), files = result.groups[0].files
        let engine = f.engine(action: { source in
            let dest = f.trash.appendingPathComponent(source.lastPathComponent)
            try f.fm.moveItem(at: source, to: dest); f.state.cancelled = true; return dest
        })
        let report = try engine.execute(result: result, selectedIDs: Set(files.prefix(2).map(\.id)), cancelled: { f.state.cancelled })
        try require(report.cancelled && report.movedIDs.count == 1 && f.exists(files[2].path), "Cancellation is partial, preserving a keeper and durable completed move")
        try require(f.engine().restore(batchID: result.id.uuidString).restoredIDs.count == 1, "Partial batch remains explicitly recoverable")
    }
    static func restoreConflict() throws {
        let f = try DuplicateFixture(), result = try f.scan(), selected = try one(result), engine = f.engine()
        _ = try engine.execute(result: result, selectedIDs: [selected.id])
        let replacement = Data("New personal file, keep exact bytes".utf8)
        try replacement.write(to: URL(fileURLWithPath: selected.path))
        let report = engine.restore(batchID: result.id.uuidString)
        try require(report.restoredIDs.isEmpty && !report.issues.isEmpty, "Original path conflict must block restore")
        try require(try Data(contentsOf: URL(fileURLWithPath: selected.path)) == replacement && engine.history.first?.pendingCount == 1, "New original remains intact with old receipt pending")
    }
    static func changedRecovery() throws {
        let f = try DuplicateFixture(), result = try f.scan(), selected = try one(result), engine = f.engine()
        _ = try engine.execute(result: result, selectedIDs: [selected.id])
        let physical = try f.fm.contentsOfDirectory(at: f.trash, includingPropertiesForKeys: nil)[0]
        try Data(repeating: 0x33, count: 4096).write(to: physical)
        let report = engine.restore(batchID: result.id.uuidString)
        try require(report.restoredIDs.isEmpty && !report.issues.isEmpty && !f.exists(selected.path) && f.exists(physical.path), "Changed Trash object remains untouched")
    }
    static func badJournals() throws {
        for mode in ["corrupt", "future", "missing", "external"] {
            let f = try DuplicateFixture(), result = try f.scan(), selected = try one(result), engine = f.engine()
            _ = try engine.execute(result: result, selectedIDs: [selected.id])
            if mode == "corrupt" { try Data("not JSON".utf8).write(to: f.ledger) }
            if mode == "future" { try f.jsonEdit { $0["version"] = 900 } }
            if mode == "missing" { try f.fm.removeItem(at: f.ledger) }
            if mode == "external" { var data = try Data(contentsOf: f.ledger); data.append(0x20); try data.write(to: f.ledger) }
            let before = try? Data(contentsOf: f.ledger)
            let active = mode == "external" ? engine : f.engine()
            let report = active.restore(batchID: result.id.uuidString)
            try require(report.restoredIDs.isEmpty && !report.issues.isEmpty && active.recoveryError != nil, "Bad recovery state must fail closed")
            try require((try? Data(contentsOf: f.ledger)) == before, "Bad bytes must never be replaced by an empty journal")
        }
    }
    static func missingFolder() throws {
        let f = try DuplicateFixture(), result = try f.scan(), selected = try one(result), engine = f.engine()
        _ = try engine.execute(result: result, selectedIDs: [selected.id]); try f.fm.removeItem(at: f.journal)
        let reloaded = f.engine()
        try require(reloaded.recoveryError != nil, "Independent root marker must detect deletion of the entire journal folder")
        try require(reloaded.restore(batchID: result.id.uuidString).restoredIDs.isEmpty, "Missing state never auto-replays")
    }
    static func stageSymlink() throws {
        let f = try DuplicateFixture(), result = try f.scan(), selected = try one(result), engine = f.engine()
        try f.fm.createSymbolicLink(at: engine.stageDirectory, withDestinationURL: f.trash)
        let report = try engine.execute(result: result, selectedIDs: [selected.id])
        try require(report.movedIDs.isEmpty && !report.issues.isEmpty && f.exists(selected.path), "Linked stage must never be followed")
    }
    static func writeFailures() throws {
        for failedWrite in [1, 2, 3] {
            let f = try DuplicateFixture(), result = try f.scan(), selected = try one(result)
            let engine = f.engine(writer: { data, fd in
                f.state.writes += 1
                if f.state.writes == failedWrite { throw UninstallFailure(message: "Synthetic disk full") }
                try UninstallFileSafety.atomicData(data, directory: fd, name: "journal.json")
            })
            do { _ = try engine.execute(result: result, selectedIDs: [selected.id]) } catch { }
            try require(f.exists(selected.path), "Failure before or after stage must return exact original where possible")
            if failedWrite == 1 {
                try require(f.engine().recoveryError != nil, "Marker without first journal is evidence of failed initialization")
            } else {
                let restore = f.engine().restore(batchID: result.id.uuidString)
                try require(restore.issues.isEmpty && f.exists(selected.path), "Durable prepared receipt reconciles a successful rollback")
            }
        }
    }
    static func substitutedStage() throws {
        let f = try DuplicateFixture(), result = try f.scan(), selected = try one(result)
        let engine = f.engine(action: { source in
            try f.fm.moveItem(at: source, to: f.trash.appendingPathComponent(source.lastPathComponent))
            try Data("Replacement at stage, never move".utf8).write(to: source)
            f.state.substitutedURL = source
            throw UninstallFailure(message: "Synthetic stage substitution")
        })
        let report = try engine.execute(result: result, selectedIDs: [selected.id])
        try require(!report.issues.isEmpty && !f.exists(selected.path), "Do not roll a replacement into original")
        guard let substituted = f.state.substitutedURL else { throw RecoveryTestFailure(description: "Expected synthetic replacement") }
        try require(try Data(contentsOf: substituted) == Data("Replacement at stage, never move".utf8), "Substituted stage stays in place")
    }
    static func lastCheck() throws {
        let f = try DuplicateFixture(), result = try f.scan(), selected = try one(result)
        let replacement = Data("Late replacement, preserve".utf8)
        let engine = f.engine(writer: { data, fd in
            f.state.writes += 1
            try UninstallFileSafety.atomicData(data, directory: fd, name: "journal.json")
            if f.state.writes == 2 {
                try f.fm.moveItem(at: URL(fileURLWithPath: selected.path), to: f.home.appendingPathComponent("original-outside.bin"))
                try replacement.write(to: URL(fileURLWithPath: selected.path))
            }
        })
        let report = try engine.execute(result: result, selectedIDs: [selected.id])
        try require(report.movedIDs.isEmpty && !report.issues.isEmpty, "Final FD check must reject source replacement after durable receipt")
        try require(try Data(contentsOf: URL(fileURLWithPath: selected.path)) == replacement, "Last-moment replacement must remain intact")
    }
    static func replacedDirectories() throws {
        for replaceStage in [true, false] {
            let f = try DuplicateFixture(), result = try f.scan(), selected = try one(result)
            let oldStage = f.home.appendingPathComponent("Library/Caches/.GaoJiLing-DuplicateStage")
            let displaced = f.home.appendingPathComponent("displaced-private-directory")
            let engine = f.engine(writer: { data, fd in
                f.state.writes += 1
                try UninstallFileSafety.atomicData(data, directory: fd, name: "journal.json")
                if f.state.writes == 2 {
                    let original = replaceStage ? oldStage : f.journal
                    try f.fm.moveItem(at: original, to: displaced)
                    try f.mkdir(original)
                }
            })
            do { _ = try engine.execute(result: result, selectedIDs: [selected.id]) } catch { }
            try require(f.exists(selected.path), "Private directory replacement after receipt save cannot detach the original file from its receipt")
            try require(try f.fm.contentsOfDirectory(at: displaced, includingPropertiesForKeys: nil).allSatisfy { $0.lastPathComponent == "journal.json" }, "Displaced stage or journal must not contain a newly moved user file")
        }
    }
    static func finalJournalCheck() throws {
        let f = try DuplicateFixture(), result = try f.scan(), selected = try one(result)
        let external = Data("Externally changed recovery bytes, preserve exactly".utf8)
        let engine = DuplicateRecovery(home: f.home, journalDirectory: f.journal, trash: { source in
            let destination = f.trash.appendingPathComponent(source.lastPathComponent)
            try f.fm.moveItem(at: source, to: destination); return destination
        }, journalCheckpoint: {
            f.state.writes += 1
            if f.state.writes == 2 { try external.write(to: f.ledger) }
        })
        do { _ = try engine.execute(result: result, selectedIDs: [selected.id]) } catch { }
        try require(engine.recoveryError != nil && f.exists(selected.path), "Observed external change immediately before journal rename must stop file movement")
        try require(try Data(contentsOf: f.ledger) == external, "Production writer must not overwrite changed bytes")
    }
    static func lastKeeperCheck() throws {
        let f = try DuplicateFixture(), result = try f.scan(), selected = try one(result)
        let keeper = result.groups[0].files[1]
        let engine = f.engine(writer: { data, fd in
            f.state.writes += 1
            try UninstallFileSafety.atomicData(data, directory: fd, name: "journal.json")
            if f.state.writes == 4 { try f.fm.removeItem(at: URL(fileURLWithPath: keeper.path)) }
        })
        let report = try engine.execute(result: result, selectedIDs: [selected.id])
        try require(report.movedIDs.isEmpty && !report.issues.isEmpty && f.exists(selected.path), "Keeper must be rechecked immediately before the actual Trash call")
        try require(try f.fm.contentsOfDirectory(at: f.trash, includingPropertiesForKeys: nil).isEmpty, "A missing keeper cannot allow the selected original into Trash")
    }
    static func replacedJournalTemporary() throws {
        let f = try DuplicateFixture(), result = try f.scan(), selected = try one(result)
        let replacement = Data("Substituted temporary file, preserve exactly".utf8)
        let engine = DuplicateRecovery(home: f.home, journalDirectory: f.journal, trash: { source in
            let destination = f.trash.appendingPathComponent(source.lastPathComponent)
            try f.fm.moveItem(at: source, to: destination); return destination
        }, journalCheckpoint: {
            f.state.writes += 1
            if f.state.writes == 2 {
                let temporary = try f.fm.contentsOfDirectory(at: f.journal, includingPropertiesForKeys: nil)
                    .first { $0.lastPathComponent.hasPrefix("duplicate-journal-") && $0.pathExtension == "tmp" }!
                try f.fm.moveItem(at: temporary, to: f.home.appendingPathComponent("displaced-journal-temporary"))
                try replacement.write(to: temporary); f.state.substitutedURL = temporary
            }
        })
        do { _ = try engine.execute(result: result, selectedIDs: [selected.id]) } catch { }
        guard let substituted = f.state.substitutedURL else { throw RecoveryTestFailure(description: "Expected temporary substitution") }
        try require(engine.recoveryError != nil && f.exists(selected.path), "Replaced journal temp must stop before user-file movement")
        try require(try Data(contentsOf: substituted) == replacement, "Cleanup cannot unlink the substituted temporary path")
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: f.ledger)) as! [String: Any]
        let batches = json["batches"] as! [[String: Any]]
        try require((batches[0]["receipts"] as! [Any]).isEmpty, "Previous durable journal must remain unchanged by substituted temp")
    }
    static func stagePermissions() throws {
        let f = try DuplicateFixture(), result = try f.scan(), selected = try one(result)
        let stage = f.home.appendingPathComponent("Library/Caches/.GaoJiLing-DuplicateStage")
        let engine = f.engine(writer: { data, fd in
            f.state.writes += 1
            try UninstallFileSafety.atomicData(data, directory: fd, name: "journal.json")
            if f.state.writes == 2, chmod(stage.path, 0o755) != 0 { throw UninstallFailure(message: "Synthetic chmod failed") }
        })
        let report = try engine.execute(result: result, selectedIDs: [selected.id])
        try require(report.movedIDs.isEmpty && !report.issues.isEmpty && f.exists(selected.path), "A stage made public after receipt save cannot receive a user file")
        try require(try f.fm.contentsOfDirectory(at: stage, includingPropertiesForKeys: nil).isEmpty, "Private stage gate must precede the rename")
    }
    static func badPaths() throws {
        let f = try DuplicateFixture(), result = try f.scan(), selected = try one(result), engine = f.engine()
        _ = try engine.execute(result: result, selectedIDs: [selected.id])
        try f.jsonEdit { object in
            var batches = object["batches"] as! [[String: Any]], receipts = batches[0]["receipts"] as! [[String: Any]]
            receipts[0]["original"] = "/System/forged.bin"; batches[0]["receipts"] = receipts; object["batches"] = batches
        }
        try require(f.engine().recoveryError != nil, "Forged protected recovery destination must fail on load")
        try Data("changed marker".utf8).write(to: engine.initializationMarkerURL)
        try require(!engine.restore(batchID: result.id.uuidString).issues.isEmpty, "External marker changes stop an already loaded engine")
    }
}
