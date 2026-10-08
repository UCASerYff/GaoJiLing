import Foundation
import Darwin

@main struct StorageAnalysisTests {
    private final class LookupAudit: @unchecked Sendable {
        private let lock = NSLock()
        private var identifiers: [String] = []
        func lookup(_ identifier: String) -> Bool? {
            lock.lock(); defer { lock.unlock() }
            identifiers.append(identifier)
            return identifier == "com.example.installed"
        }
        var queried: [String] { lock.lock(); defer { lock.unlock() }; return identifiers }
    }
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fputs("FAIL: \(message)\n", stderr); exit(1) }
    }
    static func allocation(_ url: URL) -> Int64 {
        var value = stat()
        require(lstat(url.path, &value) == 0, "fixture metadata available")
        return Int64(value.st_blocks) * 512
    }
    static func makeFile(_ url: URL, bytes: Int) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x5a, count: bytes).write(to: url)
    }
    static func main() throws {
        let fm = FileManager.default
        let base = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("gaojiling-storage-tests-" + UUID().uuidString)
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }
        let root = base.appendingPathComponent("root")
        let first = root.appendingPathComponent("first")
        let second = root.appendingPathComponent("second")
        let empty = root.appendingPathComponent("empty")
        let a = first.appendingPathComponent("large.bin")
        let b = second.appendingPathComponent("small.bin")
        let c = root.appendingPathComponent("direct.bin")
        try makeFile(a, bytes: 32_768)
        try makeFile(b, bytes: 8_192)
        try makeFile(c, bytes: 16_384)
        try fm.createDirectory(at: empty, withIntermediateDirectories: true)
        require(link(a.path, first.appendingPathComponent("duplicate.bin").path) == 0, "fixture hard link")
        let analyzer = StorageAnalyzer(home: base)
        let policyBefore = getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD)
        let result = try analyzer.analyze(directory: root)
        require(result.complete && result.entries.count == 3, "all direct directories included, empty directory is valid zero")
        require(result.largestFiles.count == 3, "hardlinks deduplicated")
        require(result.largestFiles[0].bytes == allocation(a), "top files sorted by allocated size")
        require(result.entries.first?.name == "first" && result.entries.first?.fileCount == 1, "directory rank and deduplicated file count")
        require(result.totalBytes == [root, first, second, empty, a, b, c].reduce(Int64(0)) { $0 + allocation($1) }, "recursive allocation total counts each inode once")
        require(result.notes.contains { $0.contains("重复 inode") }, "hardlink attribution explained")
        require(getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD) == policyBefore, "thread materialization policy restored after success")
        print("PASS: recursive totals, direct folders, empty folder and hardlink deduplication")

        let outside = base.appendingPathComponent("outside")
        try makeFile(outside.appendingPathComponent("not-scanned.bin"), bytes: 65_536)
        try fm.createSymbolicLink(at: root.appendingPathComponent("external-link"), withDestinationURL: outside)
        let placeholder = root.appendingPathComponent(".cloud-file.icloud")
        try makeFile(placeholder, bytes: 4_096)
        let pipe = root.appendingPathComponent("pipe")
        require(mkfifo(pipe.path, 0o600) == 0, "fixture FIFO")
        let skipped = try analyzer.analyze(directory: root, exclusions: [second])
        require(!skipped.complete, "skipped paths are incomplete")
        require(!skipped.entries.contains { $0.name == "second" || $0.name == "external-link" }, "excluded and symlink directories not traversed")
        require(!skipped.largestFiles.contains { $0.name == placeholder.lastPathComponent || $0.name == "not-scanned.bin" || $0.name == "small.bin" }, "placeholder and outside/excluded files omitted")
        require(skipped.notes.contains { $0.contains("占位") } && skipped.notes.contains { $0.contains("特殊文件") }, "cloud placeholders and special files reported")
        let linkRoot = base.appendingPathComponent("linked-root")
        try fm.createSymbolicLink(at: linkRoot, withDestinationURL: root)
        do { _ = try analyzer.analyze(directory: linkRoot); require(false, "symlink root must fail") } catch { }
        do { _ = try analyzer.analyze(directory: linkRoot.appendingPathComponent("first")); require(false, "intermediate symlink must fail") } catch { }
        require(getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD) == policyBefore, "thread materialization policy restored after failure")
        let forbidden = root.appendingPathComponent("restricted")
        try makeFile(forbidden.appendingPathComponent("private.bin"), bytes: 4_096)
        require(chmod(forbidden.path, 0) == 0, "fixture permission restriction")
        let denied = try analyzer.analyze(directory: root)
        require(!denied.complete && denied.notes.contains { $0.contains("权限不足") }, "permission failures reported rather than counted as empty")
        require(!denied.entries.contains { $0.name == "restricted" }, "unreadable directory is not a fake zero entry")
        require(chmod(forbidden.path, 0o700) == 0, "restore fixture permissions")
        print("PASS: nofollow roots/ancestors, exclusions, placeholders, permissions and special files")

        let many = base.appendingPathComponent("many")
        for i in 0..<25 { try makeFile(many.appendingPathComponent("dir\(i)/file.bin"), bytes: (i + 1) * 4_096) }
        let top = try analyzer.analyze(directory: many)
        require(top.entries.count == 20 && top.largestFiles.count == 20, "top lists bounded at 20")
        require(top.entries.first?.name == "dir24" && top.largestFiles.first?.bytes == allocation(many.appendingPathComponent("dir24/file.bin")), "largest allocated entries ranked first")
        let limited = try StorageAnalyzer(home: base, maximumEntries: 3).analyze(directory: many)
        require(!limited.complete && limited.notes.contains { $0.contains("条目的扫描预算") }, "entry budget yields explicit partial result")
        let expired = try StorageAnalyzer(home: base, timeBudget: 0).analyze(directory: many)
        require(!expired.complete && expired.entries.isEmpty && expired.notes.contains { $0.contains("时间预算") }, "time budget does not fabricate unvisited rows")
        let cancelled = try analyzer.analyze(directory: many, cancelled: { true })
        require(!cancelled.complete && cancelled.entries.isEmpty && cancelled.notes.contains { $0.contains("已取消") }, "cancellation yields explicit partial result")
        print("PASS: top20, entry/time limits and cancellation")

        let fakeHome = base.appendingPathComponent("home")
        try makeFile(fakeHome.appendingPathComponent(".npm/cache.bin"), bytes: 8_192)
        try makeFile(fakeHome.appendingPathComponent(".ollama/models/model.bin"), bytes: 12_288)
        try makeFile(fakeHome.appendingPathComponent(".virtualenvs/example/environment.bin"), bytes: 4_096)
        // Never inspect the host's Homebrew installation in a synthetic fixture.
        try makeFile(fakeHome.appendingPathComponent("Library/Caches/com.example.removed/cache.bin"), bytes: 4_096)
        try makeFile(fakeHome.appendingPathComponent("Library/Caches/com.example.installed/cache.bin"), bytes: 4_096)
        let managedCaches = ["com.apple.fixture", "com.gaoseries.fixture", "COM.APPLE.MixedCase"].map {
            fakeHome.appendingPathComponent("Library/Caches/\($0)")
        }
        for cache in managedCaches {
            try makeFile(cache.appendingPathComponent("never-inspect.bin"), bytes: 4_096)
            require(chmod(cache.path, 0) == 0, "managed cache fixture denies traversal")
        }
        defer { for cache in managedCaches { _ = chmod(cache.path, 0o700) } }
        let containers = fakeHome.appendingPathComponent("Library/Containers")
        try makeFile(containers.appendingPathComponent("com.docker.docker/Data/vms/never-inspect.bin"), bytes: 4_096)
        require(chmod(containers.path, 0) == 0, "sandbox container fixture denies traversal")
        defer { _ = chmod(containers.path, 0o700) }
        try makeFile(fakeHome.appendingPathComponent(".docker/buildx/cache/local.bin"), bytes: 4_096)
        let audit = LookupAudit()
        let environments = try StorageAnalyzer(home: fakeHome, ownerLookup: { audit.lookup($0) }).scanEnvironments(exclusions: [URL(fileURLWithPath: "/opt"), URL(fileURLWithPath: "/usr")])
        require(Set(environments.entries.map(\.category)) == Set(["Node.js", "Ollama", "Python", "Docker", "疑似残留缓存"]), "known locations discovered within injected home")
        require(environments.entries.contains { $0.name == "com.example.removed" && $0.risk == "归属待确认" } && !environments.entries.contains { $0.name == "com.example.installed" }, "unidentified caches remain analysis-only suspects")
        require(!audit.queried.contains { StorageAnalysisPolicy.isManagedCache($0) }, "managed cache names are rejected before owner lookup")
        require(!(environments.entries + environments.largestFiles).contains { item in
            managedCaches.contains { item.path == $0.path || item.path.hasPrefix($0.path + "/") } || item.path.hasPrefix(containers.path + "/")
        }, "system/Gao-series caches and Docker sandbox data never enter automatic results")
        require(environments.notes.contains { $0.contains("系统或搞系列管理的缓存") } && !environments.notes.contains { $0.contains("权限不足") }, "managed directories skipped by name without probing their denied permissions")
        require(environments.notes.contains { $0.contains("Docker 虚拟机数据") && $0.contains("未计入") }, "omitted sandbox data is explicitly disclosed")
        require(environments.notes.contains { $0.contains("不能立即中断") }, "soft cancellation limits disclosed without promising a hard syscall timeout")
        require(StorageAnalysisPolicy.isManagedCache("com.apple") && StorageAnalysisPolicy.isManagedCache("com.gaoseries"), "managed namespace roots excluded")
        require(!StorageAnalysisPolicy.isManagedCache("com.appleton.fixture") && !StorageAnalysisPolicy.isManagedCache("com.gaoseriesother.fixture"), "managed namespace matching respects component boundaries")
        for cache in managedCaches { require(chmod(cache.path, 0o700) == 0, "restore managed cache fixture permissions") }
        require(chmod(containers.path, 0o700) == 0, "restore sandbox container fixture permissions")
        print("PASS: managed caches rejected before owner lookup and protected sandbox roots not entered")
        require(environments.entries.contains { $0.category == "Ollama" && $0.risk == "模型数据" }, "models not represented as disposable caches")
        require(environments.entries.allSatisfy { $0.path.hasPrefix(fakeHome.path + "/") }, "fixture does not escape injected home")
        let sparse = base.appendingPathComponent("sparse")
        try fm.createDirectory(at: sparse, withIntermediateDirectories: true)
        let sparseFile = sparse.appendingPathComponent("Docker.raw")
        let descriptor = Darwin.open(sparseFile.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        require(descriptor >= 0 && ftruncate(descriptor, 1_073_741_824) == 0, "sparse fixture")
        close(descriptor)
        let sparseResult = try analyzer.analyze(directory: sparse)
        require(sparseResult.largestFiles.first?.bytes == allocation(sparseFile) && sparseResult.totalBytes < 1_073_741_824, "sparse virtual disk uses allocated rather than logical bytes")
        require(StorageAnalysisPolicy.isPlaceholder(flags: UInt32(SF_DATALESS), name: "plain"), "dataless flag policy")
        require(!StorageAnalysisPolicy.isPlaceholder(flags: 0, name: "normal"), "downloaded files eligible for metadata statistics")
        require(StorageAnalysisPolicy.product(UInt64.max, 512) == nil, "overflow cannot fabricate a size")
        require(DiskCapacity.snapshot(for: base).map { $0.totalBytes > 0 && $0.availableBytes >= 0 && $0.availableBytes <= $0.totalBytes } == true, "native disk capacity bounds")
        print("PASS: fixed environment catalog, sparse allocation, dataless/overflow policy and disk capacity")
        print("Storage analysis tests passed using synthetic files only; fixtures removed on exit.")
    }
}
