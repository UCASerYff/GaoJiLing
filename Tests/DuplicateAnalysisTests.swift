import Foundation
import Darwin

private final class DuplicateTestAudit: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [DuplicateScanProgress] = []
    private var checks = 0
    private var changed = false
    func record(_ value: DuplicateScanProgress) { lock.lock(); values.append(value); lock.unlock() }
    func cancel(after count: Int) -> Bool { lock.lock(); defer { lock.unlock() }; checks += 1; return checks > count }
    func once(_ body: () -> Void) { lock.lock(); let first = !changed; changed = true; lock.unlock(); if first { body() } }
    var last: DuplicateScanProgress? { lock.lock(); defer { lock.unlock() }; return values.last }
}

@main struct DuplicateAnalysisTests {
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fputs("FAIL: \(message)\n", stderr); exit(1) }
    }
    static func denied(_ message: String, _ body: () throws -> Void) {
        do { try body(); require(false, message) } catch { }
    }
    static func write(_ directory: URL, _ name: String, _ data: Data) throws -> URL {
        let url = directory.appendingPathComponent(name); try data.write(to: url); return url
    }
    static func directory(_ parent: URL, _ name: String) throws -> URL {
        let url = parent.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    static func main() throws {
        let manager = FileManager.default
        let base = URL(fileURLWithPath: "/private/tmp/gaojiling-duplicates-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: base) }
        let chosen = try directory(base, "chosen")
        let data = Data(repeating: 0x62, count: 262_144)
        _ = try write(chosen, "first.bin", data); _ = try write(chosen, "second.bin", data)
        _ = try write(chosen, "unique.raw", Data(repeating: 0x63, count: 12_345))
        let audit = DuplicateTestAudit()
        let full = try DuplicateAnalyzer().scan(directory: chosen, progress: { audit.record($0) })
        require(full.complete && !full.cancelled && full.groups.count == 1, "identical independent files have one complete group")
        require(full.groups[0].files.count == 2 && full.groups[0].byteCount == UInt64(data.count), "group reports actual files and logical size")
        require(full.groups[0].files.allSatisfy({ !$0.isSelected && $0.protectionReason == nil }), "all candidates default unselected")
        require(full.groups[0].files.contains(where: { $0.id == full.groups[0].suggestedKeeperID }), "suggested keeper is a real member")
        require(full.progress.uniqueFiles == 3 && full.progress.logicalBytes == UInt64(data.count * 2 + 12_345), "whole-scope totals differ from duplicate totals")
        require(full.progress.sampledFiles == 2 && full.progress.hashedFiles == 2 && full.progress.verifiedFiles == 2, "size filter, segment filter, full digest and final checks have real counts")
        require(audit.last?.phase == .finished && audit.last?.contentBytesRead == full.progress.contentBytesRead && full.progress.contentBytesRead > UInt64(data.count * 2), "progress includes sample and full reads")
        let decoded = try JSONDecoder().decode(DuplicateScanResult.self, from: JSONEncoder().encode(full))
        require(decoded == full, "private scan state round trips without losing identity")
        print("PASS: real SHA groups, default selections, scope totals, read progress and identity persistence")

        let collision = try directory(base, "same-segments-different-content")
        let original = Data(repeating: 0x10, count: 524_288)
        var modified = original; modified[100_000] = 0x11
        _ = try write(collision, "a.bin", original); _ = try write(collision, "b.bin", modified)
        let distinct = try DuplicateAnalyzer().scan(directory: collision)
        require(distinct.complete && distinct.progress.sampledFiles == 2 && distinct.progress.hashedFiles == 2 && distinct.groups.isEmpty,
                "matching bounded segments never replace complete SHA-256")
        let empty = try directory(base, "empty")
        _ = try write(empty, "one.bin", Data()); _ = try write(empty, "two.bin", Data())
        let emptyResult = try DuplicateAnalyzer().scan(directory: empty)
        require(emptyResult.complete && emptyResult.groups.count == 1 && emptyResult.groups[0].byteCount == 0 && emptyResult.progress.contentBytesRead == 0, "empty file equality is real and reads no invented bytes")
        print("PASS: full digest rejects sample-only match and handles empty files")

        let hard = try directory(base, "hardlinks")
        let real = try write(hard, "first.bin", data)
        require(link(real.path, hard.appendingPathComponent("hard-alias.bin").path) == 0, "create isolated hardlink")
        _ = try write(hard, "independent.bin", data)
        let hardResult = try DuplicateAnalyzer().scan(directory: hard)
        require(hardResult.complete && hardResult.progress.uniqueFiles == 2 && hardResult.groups[0].files.count == 2, "same physical inode counts once without losing completeness")
        require(hardResult.progress.logicalBytes == UInt64(data.count * 2), "hardlink alias does not inflate logical total")
        let group = hardResult.groups[0]
        let keeper = group.files.first(where: { $0.identity.linkCount > 1 })!
        let candidate = group.files.first(where: { $0.identity.linkCount == 1 })!
        require(keeper.protectionReason != nil && group.suggestedKeeperID == keeper.id, "hardlinked physical object is protected keeper")
        var calls = 0
        try DuplicateFileSafety.withVerifiedPair(file: candidate, keeper: keeper, scope: hardResult.scope, scopeIdentity: hardResult.scopeIdentity) { first, second in
            try DuplicateFileSafety.validatePinned(first); try DuplicateFileSafety.validatePinned(second); calls += 1
            require(first.descriptor >= 0 && first.parentDescriptor >= 0, "transaction receives live pinned descriptors")
        }
        require(calls == 1, "verified independent duplicate reaches transaction body exactly once")
        denied("hardlinked candidate must not become a movable physical copy") {
            try DuplicateFileSafety.withVerifiedPair(file: keeper, keeper: candidate, scope: hardResult.scope, scopeIdentity: hardResult.scopeIdentity) { _, _ in calls += 1 }
        }
        require(calls == 1, "invalid pair never reaches body")
        print("PASS: hardlink physical accounting, protected keeper and final bytewise pinned verification")

        let unreadable = try directory(base, "unreadable")
        let blocked = try write(unreadable, "blocked.bin", data)
        _ = try write(unreadable, "other.bin", data)
        require(chmod(blocked.path, 0) == 0, "remove isolated content read permission")
        let deniedContents = try DuplicateAnalyzer().scan(directory: unreadable)
        require(!deniedContents.complete && deniedContents.groups.isEmpty && deniedContents.progress.contentBytesRead == 0, "unreadable contents are partial and never substituted with zeros")
        require(chmod(blocked.path, 0o600) == 0, "restore fixture permissions")
        let outside = try directory(base, "outside")
        _ = try write(outside, "private.bin", data)
        try manager.createSymbolicLink(at: unreadable.appendingPathComponent("linked-dir"), withDestinationURL: outside)
        try manager.createSymbolicLink(at: unreadable.appendingPathComponent("linked-file.bin"), withDestinationURL: outside.appendingPathComponent("private.bin"))
        require(mkfifo(unreadable.appendingPathComponent("pipe").path, 0o600) == 0, "create nonblocking-special fixture")
        let links = try DuplicateAnalyzer().scan(directory: unreadable)
        require(!links.complete && links.progress.uniqueFiles == 2 && links.progress.skippedEntries == 3 && links.groups.count == 1, "symlinks and special files not followed or opened")
        denied("symlink scope must fail") { _ = try DuplicateAnalyzer().scan(directory: unreadable.appendingPathComponent("linked-dir")) }
        denied("remote authority must fail") { _ = try DuplicateAnalyzer().scan(directory: URL(string: "file://remote.invalid" + chosen.path)!) }
        denied("oversized lexical path must fail before filesystem access") { _ = try DuplicateFileSafety.pathParts("/" + String(repeating: "a", count: 4_096)) }
        denied("multibyte lexical paths use UTF-8 byte limit") { _ = try DuplicateFileSafety.pathParts("/" + String(repeating: "文", count: 1_366)) }
        print("PASS: permission failures, nofollow scopes, symlink/special-file rejection and local authority")

        let zero = try DuplicateAnalyzer(timeBudget: 0).scan(directory: chosen)
        require(!zero.complete && zero.progress.visitedEntries == 0 && zero.groups.isEmpty && zero.stopReason != nil, "zero time budget reads nothing")
        let fileLimit = try DuplicateAnalyzer(maximumFiles: 1).scan(directory: chosen)
        require(!fileLimit.complete && fileLimit.progress.uniqueFiles == 1 && fileLimit.stopReason?.contains("文件候选") == true, "file budget is bounded and partial")
        let entryLimit = try DuplicateAnalyzer(maximumEntries: 1).scan(directory: chosen)
        require(!entryLimit.complete && entryLimit.progress.visitedEntries == 1 && entryLimit.stopReason?.contains("条目") == true, "entry budget never overflows")
        let contentLimit = try DuplicateAnalyzer(maximumContentBytes: 100).scan(directory: chosen)
        require(!contentLimit.complete && contentLimit.progress.contentBytesRead <= 100 && contentLimit.stopReason?.contains("读取预算") == true, "actual content bytes never exceed budget")
        let cancellation = DuplicateTestAudit()
        let cancelled = try DuplicateAnalyzer().scan(directory: chosen, cancelled: { cancellation.cancel(after: 2) })
        require(cancelled.cancelled && !cancelled.complete && cancelled.stopReason?.contains("取消") == true, "cooperative cancellation preserves actual status")
        let deep = try directory(base, "deep")
        let child = try directory(deep, "child")
        _ = try write(child, "hidden.bin", data)
        let depth = try DuplicateAnalyzer(maximumDepth: 0).scan(directory: deep)
        require(!depth.complete && depth.progress.uniqueFiles == 0 && depth.notes.contains(where: { $0.contains("深度") }), "directory depth bounded without entering contents")
        print("PASS: time, file, entry, content, cancellation and directory-depth limits")

        let changing = try directory(base, "changing")
        let changingA = try write(changing, "a.bin", data)
        _ = try write(changing, "b.bin", data)
        let mutation = DuplicateTestAudit()
        let changed = try DuplicateAnalyzer().scan(directory: changing, progress: { value in
            if value.phase == .hashing { mutation.once { try? Data(repeating: 0x71, count: data.count).write(to: changingA) } }
        })
        require(!changed.complete && changed.groups.isEmpty && changed.notes.contains(where: { $0.contains("摘要读取") }), "mutation after segment stage is rejected before full digest")
        try data.write(to: changingA)
        let postHashMutation = DuplicateTestAudit()
        let finalChanged = try DuplicateAnalyzer().scan(directory: changing, progress: { value in
            if value.phase == .verifying { postHashMutation.once { try? Data(repeating: 0x72, count: data.count).write(to: changingA) } }
        })
        require(!finalChanged.complete && finalChanged.groups.isEmpty && finalChanged.notes.contains(where: { $0.contains("摘要完成后") }), "post-hash final identity change is not returned as a group")
        print("PASS: mutations between stages and after full hashing retain incomplete status")

        let protected = try directory(base, "protected")
        _ = try write(protected, "paper.pdf", data); _ = try write(protected, "paper-copy.pdf", data)
        let documents = try DuplicateAnalyzer().scan(directory: protected)
        require(documents.complete && documents.groups[0].files.allSatisfy({ $0.protectionReason != nil }), "explicit document scan can report equality while retaining move protection")
        require(DuplicateFileSafety.movableReason(path: protected.appendingPathComponent("paper.pdf").path, scope: protected.path) != nil, "final path policy still protects documents")
        denied("document content equality must not bypass move protection") {
            try DuplicateFileSafety.withVerifiedPair(file: documents.groups[0].files[0], keeper: documents.groups[0].files[1], scope: documents.scope, scopeIdentity: documents.scopeIdentity) { _, _ in require(false, "protected body") }
        }
        let app = try directory(protected, "Example.app")
        _ = try write(app, "business.bin", data)
        let library = try directory(protected, "Library")
        _ = try write(library, "private.bin", data)
        _ = try write(protected, "business.sqlite", data)
        let protectedScan = try DuplicateAnalyzer().scan(directory: protected)
        require(!protectedScan.complete && protectedScan.progress.uniqueFiles == 2 && protectedScan.progress.skippedEntries == 3, "app packages, library and database content are excluded without reading")
        denied("Gao-series scope protected") { _ = try DuplicateAnalyzer().scan(directory: URL(fileURLWithPath: "/Users/example/Library/Application Support/GaoSeries/GaoJiLing")) }
        print("PASS: business/package/Gao protections and analysis-only documents")

        let safe = try directory(base, "safe")
        let safeA = try write(safe, "a.bin", data); _ = try write(safe, "b.bin", data)
        let safeResult = try DuplicateAnalyzer().scan(directory: safe)
        let first = safeResult.groups[0].files[0], second = safeResult.groups[0].files[1]
        let pinned = try DuplicateFileSafety.openPinned(path: safeA.path)
        let pinnedDigest = try DuplicateFileSafety.fullDigest(pinned)
        require(pinnedDigest == first.sha256, "public pinned digest uses real content")
        let moved = base.appendingPathComponent("moved-safe")
        try manager.moveItem(at: safe, to: moved)
        _ = try directory(base, "safe")
        _ = try write(safe, "a.bin", data); _ = try write(safe, "b.bin", data)
        denied("pinned file parent path replacement must fail final validation") { try DuplicateFileSafety.validatePinned(pinned) }
        denied("reviewed scope replacement rejected") { _ = try DuplicateAnalyzer().scan(directory: safe, expectedIdentity: safeResult.scopeIdentity) }
        denied("scope replacement stops pair before body") {
            try DuplicateFileSafety.withVerifiedPair(file: first, keeper: second, scope: safeResult.scope, scopeIdentity: safeResult.scopeIdentity) { _, _ in require(false, "replacement body") }
        }
        let afterRename = moved.appendingPathComponent("a.bin")
        let restoredPinned = try DuplicateFileSafety.openPinned(path: afterRename.path, expected: first.identity, allowRenamedTimes: true)
        let renamedDigest = try DuplicateFileSafety.fullDigest(restoredPinned)
        require(renamedDigest == first.sha256, "restore preflight can allow rename ctime while still requiring same actual contents")
        print("PASS: parent/scope replacement rejection and renamed-file restoration preflight")

        let unequal = try directory(base, "unequal")
        let u1 = try write(unequal, "a.bin", data)
        let u2 = try write(unequal, "b.bin", Data(repeating: 0x22, count: data.count))
        let p1 = try DuplicateFileSafety.openPinned(path: u1.path), p2 = try DuplicateFileSafety.openPinned(path: u2.path)
        let claimed = try DuplicateFileSafety.fullDigest(p1)
        let f1 = DuplicateFile(id: p1.identity.physicalID, path: u1.path, name: "a.bin", identity: p1.identity, sha256: claimed, protectionReason: nil)
        let f2 = DuplicateFile(id: p2.identity.physicalID, path: u2.path, name: "b.bin", identity: p2.identity, sha256: claimed, protectionReason: nil)
        let scopeFD = try DuplicateFileSafety.directory(unequal.path); defer { close(scopeFD) }
        let scopeID = DuplicateDirectoryIdentity(try DuplicateFileSafety.info(scopeFD))
        denied("forged equal SHA must still fail actual bytewise comparison") {
            try DuplicateFileSafety.withVerifiedPair(file: f1, keeper: f2, scope: unequal.path, scopeIdentity: scopeID) { _, _ in require(false, "forged body") }
        }
        denied("cancelled confirmation never reaches transaction") {
            try DuplicateFileSafety.withVerifiedPair(file: candidate, keeper: keeper, scope: hardResult.scope, scopeIdentity: hardResult.scopeIdentity, cancelled: { true }) { _, _ in require(false, "cancelled body") }
        }
        print("PASS: actual bytewise verification rejects forged summaries and honours cancellation")

        let finalScope = try directory(base, "final-size-filter")
        _ = try write(finalScope, "a.bin", data); _ = try write(finalScope, "b.bin", data)
        let uniqueFile = try write(finalScope, "initially-unique.bin", Data([0x62]))
        let initiallyEmpty = try directory(finalScope, "initially-empty")
        let lateChange = DuplicateTestAudit()
        let lateResult = try DuplicateAnalyzer().scan(directory: finalScope, progress: { value in
            if value.phase == .verifying {
                lateChange.once {
                    try? data.write(to: uniqueFile)
                    _ = try? write(initiallyEmpty, "late.bin", data)
                }
            }
        })
        require(!lateResult.complete && lateResult.notes.contains(where: { $0.contains("结束复核") }), "initial size-filter files and nested directories are rechecked before complete result")
        require(lateResult.groups.count == 1 && lateResult.groups[0].files.count == 2, "late unscanned copies never invented in an existing group")
        print("PASS: initially unique files and already-enumerated subdirectories cannot silently change a complete scope")
        print("DuplicateAnalysisTests: 10 groups passed (isolated synthetic files only; no app or GUI launched)")
    }
}
