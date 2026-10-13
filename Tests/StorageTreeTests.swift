import Foundation
import Darwin

private final class TreeAudit: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [ScanProgress] = []
    private var checks = 0
    func record(_ value: ScanProgress) { lock.lock(); samples.append(value); lock.unlock() }
    func cancelAfterChecks(_ limit: Int) -> Bool { lock.lock(); defer { lock.unlock() }; checks += 1; return checks > limit }
    var progress: [ScanProgress] { lock.lock(); defer { lock.unlock() }; return samples }
}

@main struct StorageTreeTests {
    private static func require(_ value: @autoclosure () -> Bool, _ message: String) {
        if !value() { fputs("FAIL: \(message)\n", stderr); exit(1) }
    }
    static func main() throws {
        let manager = FileManager.default
        let base = URL(fileURLWithPath: "/private/tmp/gaojiling-tree-fixture-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: base) }
        let root = base.appendingPathComponent("chosen")
        let nested = root.appendingPathComponent("nested/deeper")
        try manager.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data(repeating: 0x35, count: 8_192).write(to: root.appendingPathComponent("primary.bin"))
        require(link(root.appendingPathComponent("primary.bin").path, root.appendingPathComponent("alias.bin").path) == 0, "create isolated hardlink")
        let sparse = nested.appendingPathComponent("sparse.raw")
        let fd = open(sparse.path, O_CREAT | O_WRONLY | O_CLOEXEC, 0o600)
        require(fd >= 0 && ftruncate(fd, 1_048_576) == 0, "create isolated sparse file")
        close(fd)
        let audit = TreeAudit()
        let result = try StorageAnalyzer(home: base).analyze(directory: root, progress: { audit.record($0) })
        let session = result.session!
        let rootNode = session.nodes[root.path]!
        require(result.complete && session.complete, "complete traversal and session agree")
        require(rootNode.logicalBytes == 1_048_576 + 8_192, "logical total includes sparse length and counts hardlink once")
        require(rootNode.allocatedBytes == result.totalBytes && result.totalBytes < rootNode.logicalBytes!, "allocated and logical totals remain separate")
        require(rootNode.device != nil && rootNode.inode != nil && rootNode.ownerUID == getuid(), "real identity retained")
        require(rootNode.fileCount == 2 && session.progress.fileCount == 2, "file progress counts unique observed files")
        require(session.breadcrumbs(to: sparse.path).map(\.name) == ["chosen", "nested", "deeper", "sparse.raw"], "breadcrumb parent chain")
        require(session.children(of: nested.path).count == 1, "directory drill-in returns direct children only")
        require(audit.progress.last?.allocatedBytes == result.totalBytes && audit.progress.last?.logicalBytes == rootNode.logicalBytes, "final actual progress totals match result")
        require(audit.progress.first?.visitedEntries == 1, "first progress emitted before completion")
        require(session.nodes.values.filter { $0.skipReasons.contains(where: { $0.contains("inode 相同") }) }.count == 1, "hardlink duplicate explicitly explained")
        print("PASS: identity, logical/allocated totals, sparse files, hardlinks, breadcrumbs and actual progress")

        let skipped = root.appendingPathComponent("skipped")
        try manager.createDirectory(at: skipped, withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: skipped.appendingPathComponent("private.bin"))
        try manager.createSymbolicLink(at: root.appendingPathComponent("linked"), withDestinationURL: base)
        let partial = try StorageAnalyzer(home: base).analyze(directory: root, exclusions: [skipped])
        require(!partial.complete && partial.session?.nodes[root.path]?.complete == false, "partial status propagates to ancestor")
        let unknown = partial.session!.nodes[skipped.path]!
        require(unknown.allocatedBytes == nil && unknown.logicalBytes == nil && unknown.device == nil, "excluded metadata is not fabricated or accessed")
        require(!unknown.skipReasons.isEmpty && unknown.childIDs.isEmpty, "excluded tree node has explanation and no descendants")
        require(partial.session!.nodes[root.appendingPathComponent("linked").path]?.kind == .symbolicLink, "symlink represented but never followed")
        print("PASS: skipped node reasons, unread values and ancestor completeness")
        require(session.children(of: "missing-node").isEmpty, "missing node must not navigate back to root silently")
        let review = base.appendingPathComponent("review")
        try manager.createDirectory(at: review, withIntermediateDirectories: true)
        try Data([1]).write(to: review.appendingPathComponent("original.bin"))
        let reviewed = try StorageAnalyzer(home: base).analyze(directory: review).session!.nodes[review.path]!.directoryIdentity!
        try manager.moveItem(at: review, to: base.appendingPathComponent("original-review"))
        try manager.createDirectory(at: review, withIntermediateDirectories: true)
        try Data([9]).write(to: review.appendingPathComponent("replacement.bin"))
        do {
            _ = try StorageAnalyzer(home: base).analyze(directory: review, expectedIdentity: reviewed)
            require(false, "replacement directory must not pass reviewed identity")
        } catch { require(error.localizedDescription.contains("身份"), "identity rejection explains replacement") }
        let ordinary = try StorageAnalyzer(home: base).analyze(directory: review)
        require(ordinary.complete, "new explicit choice can inspect replacement independently")
        do {
            _ = try StorageAnalyzer(home: base).analyze(directory: URL(string: "file://remote.invalid" + review.path)!)
            require(false, "remote file authority must not silently become local scope")
        } catch { }
        let metadataOnly = base.appendingPathComponent("metadata-only")
        try manager.createDirectory(at: metadataOnly, withIntermediateDirectories: true)
        let unreadableFile = metadataOnly.appendingPathComponent("unreadable.bin")
        try Data(repeating: 7, count: 4096).write(to: unreadableFile)
        require(chmod(unreadableFile.path, 0) == 0, "deny file contents in isolated fixture")
        defer { _ = chmod(unreadableFile.path, 0o600) }
        let metadataResult = try StorageAnalyzer(home: base).analyze(directory: metadataOnly)
        require(metadataResult.complete && metadataResult.session?.nodes[unreadableFile.path]?.logicalBytes == 4096,
                "metadata scan must not need permission to open regular contents")
        print("PASS: reviewed root identity, replacement refusal, local-only URLs and metadata-only files")

        let many = base.appendingPathComponent("many")
        try manager.createDirectory(at: many, withIntermediateDirectories: true)
        for i in 0..<160 { try Data([UInt8(i)]).write(to: many.appendingPathComponent("file-\(i).bin")) }
        let bounded = try StorageAnalyzer(home: base, maximumNodes: 12).analyze(directory: many)
        require(bounded.session!.nodes.count == 12 && !bounded.complete, "node budget bounds entire tree")
        require(bounded.session!.stopReason?.contains("节点") == true, "node limit explained")
        require(bounded.session!.nodes[many.path]?.complete == false, "budget makes root partial")
        let cancellation = TreeAudit()
        let cancelled = try StorageAnalyzer(home: base).analyze(directory: many, cancelled: { cancellation.cancelAfterChecks(30) })
        require(cancelled.cancelled && cancelled.session!.cancelled && !cancelled.complete && cancelled.session!.progress.fileCount < 160, "cooperative cancellation returns partial results")
        require(cancelled.session!.stopReason?.contains("取消") == true, "cancellation has a real reason")
        let zeroTime = try StorageAnalyzer(home: base, timeBudget: 0).analyze(directory: many)
        require(!zeroTime.complete && zeroTime.session!.nodes.isEmpty, "no invented nodes before traversal")
        let full = try StorageAnalyzer(home: base).analyze(directory: many)
        require(full.session!.children(of: many.path).count == 160, "tree keeps nodes beyond old top20 ranking for pagination")
        print("PASS: bounded memory, cancellation, time budget and wide directory pagination input")

        let values: [(id: String, bytes: Int64)] = [("a", 8), ("b", 4), ("c", 2), ("d", 1), ("zero", 0)]
        let rect = CGRect(x: 0, y: 0, width: 640, height: 220)
        let tiles = DiskMapLayout.rectangles(values, in: rect)
        require(tiles.count == 4, "treemap omits zero weights without fake area")
        for tile in tiles {
            let fraction = Double(values.first { $0.id == tile.id }!.bytes) / 15
            require(abs(tile.rect.width * tile.rect.height / (640 * 220) - fraction) < 0.000001, "treemap area proportional to actual bytes")
            require(rect.contains(tile.rect), "tile stays in bounds")
            for other in tiles where other.id != tile.id {
                let intersection = tile.rect.intersection(other.rect)
                require(intersection.isNull || intersection.width * intersection.height < 0.000001, "tiles do not overlap")
            }
        }
        require(DiskMapLayout.rectangles(values, in: CGRect(x: 0, y: 0, width: Double.nan, height: 10)).isEmpty, "nonfinite geometry rejected")
        require(DiskMapLayout.rectangles([], in: rect).isEmpty, "empty geometry safe")
        print("PASS: proportional bounded treemap, no overlap, zero and invalid geometry")
        print("Storage tree tests passed with synthetic metadata fixtures only.")
    }
}
