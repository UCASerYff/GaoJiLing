import Foundation
import Darwin

@main struct StorageAnalysisControllerTests {
    private struct TestFailure: Error, CustomStringConvertible {
        let description: String
    }
    private struct StateFixture: Codable {
        var version = 1
        var exclusions: [String] = []
        var history: [StorageScanSnapshot] = []
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw TestFailure(description: message) }
    }

    private static func stateURL(_ directory: URL) -> URL {
        directory.appendingPathComponent("Storage/analysis-state.json")
    }

    private static func put(_ data: Data, at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    @MainActor private static func scan(_ controller: StorageAnalysisController, directory: URL) async throws {
        controller.analyzeDirectory(directory)
        try require(controller.isBusy, "analysis enters busy state synchronously")
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while controller.isBusy, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        if controller.isBusy {
            controller.cancel()
            throw TestFailure(description: "synthetic analysis did not finish within 10 seconds")
        }
        try require(controller.result?.complete == true, "synthetic analysis returns a complete result")
        try require(controller.result?.root == directory.path, "analysis stays within the selected synthetic directory")
        try require(controller.result?.largestFiles.count == 1, "synthetic file appears in the result")
        try require(controller.canExport, "completed result remains available when persistence is protected")
    }

    @MainActor private static func run() async throws {
        let fm = FileManager.default
        let base = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("gaojiling-storage-controller-tests-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }
        let scannedDirectory = base.appendingPathComponent("scanned", isDirectory: true)
        try put(Data(repeating: 0x5a, count: 8192), at: scannedDirectory.appendingPathComponent("fixture.bin"))

        let corruptDirectory = base.appendingPathComponent("corrupt", isDirectory: true)
        let corruptURL = stateURL(corruptDirectory)
        let corruptBytes = Data("{ invalid JSON; preserve these exact bytes".utf8)
        try put(corruptBytes, at: corruptURL)
        let corruptController = StorageAnalysisController(dataDirectory: corruptDirectory)
        try require(corruptController.status != nil, "bad JSON is reported on load")
        try await scan(corruptController, directory: scannedDirectory)
        let corruptAfter = try Data(contentsOf: corruptURL)
        try require(corruptAfter == corruptBytes, "bad JSON is never replaced by a new scan")
        print("PASS: malformed state remains byte-for-byte intact while analysis stays usable")

        let restrictedDirectory = base.appendingPathComponent("restricted", isDirectory: true)
        let restrictedURL = stateURL(restrictedDirectory)
        let restrictedParent = restrictedURL.deletingLastPathComponent()
        let oldSnapshot = StorageScanSnapshot(id: "synthetic-original", date: Date(timeIntervalSinceReferenceDate: 1000),
                                              totalBytes: 8192, scope: scannedDirectory.path, complete: true)
        let original = StateFixture(exclusions: [base.appendingPathComponent("excluded").path], history: [oldSnapshot])
        let originalBytes = try JSONEncoder().encode(original)
        try put(originalBytes, at: restrictedURL)
        try require(chmod(restrictedParent.path, 0) == 0, "restrict synthetic state directory")
        defer { _ = chmod(restrictedParent.path, 0o700) }
        var info = stat()
        let denied = lstat(restrictedURL.path, &info)
        let denialCode = errno
        try require(denied == -1 && denialCode == EACCES,
                    "permission fixture must deny access (run this test as a normal, non-root user)")
        let restrictedController = StorageAnalysisController(dataDirectory: restrictedDirectory)
        try require(restrictedController.status != nil, "permission denial is reported rather than treated as missing state")
        try require(chmod(restrictedParent.path, 0o700) == 0, "restore synthetic state directory permissions")
        try await scan(restrictedController, directory: scannedDirectory)
        let restrictedAfter = try Data(contentsOf: restrictedURL)
        try require(restrictedAfter == originalBytes, "restored access must not permit replacing unread old records")
        print("PASS: permission denial remains protected after access is restored")

        let changedDirectory = base.appendingPathComponent("external-change", isDirectory: true)
        let changedURL = stateURL(changedDirectory)
        try put(originalBytes, at: changedURL)
        let changedController = StorageAnalysisController(dataDirectory: changedDirectory)
        try require(changedController.history.count == 1 && changedController.exclusions.count == 1,
                    "valid original state loaded before external modification")
        let externalBytes = Data("external modification after controller initialization".utf8)
        try externalBytes.write(to: changedURL, options: .atomic)
        try await scan(changedController, directory: scannedDirectory)
        let externalAfter = try Data(contentsOf: changedURL)
        try require(externalAfter == externalBytes, "a live controller refuses to overwrite an external modification")
        try require(changedController.status?.contains("未能安全保存") == true, "external modification produces a persistence warning")
        try await scan(changedController, directory: scannedDirectory)
        let externalAfterSecondScan = try Data(contentsOf: changedURL)
        try require(externalAfterSecondScan == externalBytes, "subsequent scans retain the protection latch")
        print("PASS: external state changes survive repeated scans")

        let newDirectory = base.appendingPathComponent("new-state", isDirectory: true)
        let newURL = stateURL(newDirectory)
        let newController = StorageAnalysisController(dataDirectory: newDirectory)
        try require(newController.history.isEmpty && newController.status == nil, "genuinely missing state starts empty")
        try await scan(newController, directory: scannedDirectory)
        let firstSaved = try JSONDecoder().decode(StateFixture.self, from: Data(contentsOf: newURL))
        try require(firstSaved.version == 1 && firstSaved.history.count == 1 && firstSaved.exclusions.isEmpty,
                    "first successful scan persists a valid initial state")
        try require(firstSaved.history[0].scope == scannedDirectory.path && firstSaved.history[0].complete,
                    "persisted scope and completeness reflect the actual scan")
        try require(firstSaved.history[0].totalBytes == newController.result?.totalBytes,
                    "persisted byte total comes from the actual result")
        try await scan(newController, directory: scannedDirectory)
        let secondSaved = try JSONDecoder().decode(StateFixture.self, from: Data(contentsOf: newURL))
        try require(secondSaved.history.count == 2, "normal subsequent writes preserve earlier history")
        let reloaded = StorageAnalysisController(dataDirectory: newDirectory)
        try require(reloaded.history.map(\.id) == secondSaved.history.map(\.id), "saved records survive controller recreation")
        try require(reloaded.status == nil, "normal persisted state reloads without a warning")
        var savedInfo = stat()
        try require(lstat(newURL.path, &savedInfo) == 0 && savedInfo.st_mode & 0o777 == 0o600,
                    "new state has private file permissions")
        print("PASS: new state persists, updates and reloads with private permissions")
    }

    @MainActor static func main() async {
        do {
            try await run()
            print("Storage analysis controller tests passed; synthetic fixtures removed.")
        } catch {
            fputs("FAIL: \(error)\n", stderr)
            exit(1)
        }
    }
}
