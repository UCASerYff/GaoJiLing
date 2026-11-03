import Foundation
import Darwin

@main
struct DiskImageReportWriterTests {
    static func main() throws {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: "/private/tmp/gaojiling-export-tests-\(UUID().uuidString).noindex", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: root) }
        let report = Data("{\"schemaVersion\":1,\"text\":\"只读报告\"}".utf8)
        let sourceBytes = Data("original disposable image contents".utf8)
        var passed = 0
        func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
            if try !value() { throw Failure(message) }
        }
        func rejected(_ name: String, _ destination: URL, data: Data? = nil) throws {
            do { try DiskImageReportWriter.writeNew(data: data ?? report, to: destination); throw Failure("\(name): unexpectedly succeeded") }
            catch is DiskImageReportWriterError { passed += 1 }
        }

        let success = root.appendingPathComponent("report.json")
        try DiskImageReportWriter.writeNew(data: report, to: success)
        try check(try Data(contentsOf: success) == report, "successful report contents")
        var permissions = stat()
        try check(lstat(success.path, &permissions) == 0 && (permissions.st_mode & 0o777) == 0o600 && permissions.st_nlink == 1, "report mode/link count")
        passed += 1
        try rejected("existing report", success)
        try check(try Data(contentsOf: success) == report, "existing report changed")

        let source = root.appendingPathComponent("source.img")
        try sourceBytes.write(to: source)
        try rejected("source image", source)
        let moved = root.appendingPathComponent("renamed-source.img")
        try fm.moveItem(at: source, to: moved)
        try rejected("moved source image", moved)
        try check(try Data(contentsOf: moved) == sourceBytes, "source image changed")
        let hardlink = root.appendingPathComponent("source-hardlink.json")
        try check(link(moved.path, hardlink.path) == 0, "create hardlink")
        try rejected("hardlink to source", hardlink)
        try check(try Data(contentsOf: moved) == sourceBytes, "hardlinked source changed")
        let symlink = root.appendingPathComponent("source-symlink.json")
        try check(Darwin.symlink(moved.path, symlink.path) == 0, "create symlink")
        try rejected("symlink to source", symlink)
        try check(try Data(contentsOf: moved) == sourceBytes, "symlink target changed")

        let actual = root.appendingPathComponent("actual", isDirectory: true)
        try fm.createDirectory(at: actual, withIntermediateDirectories: false)
        let parentLink = root.appendingPathComponent("parent-link", isDirectory: true)
        try check(Darwin.symlink(actual.path, parentLink.path) == 0, "create parent symlink")
        try rejected("symlink parent", parentLink.appendingPathComponent("new.json"))
        try check(!fm.fileExists(atPath: actual.appendingPathComponent("new.json").path), "followed parent symlink")
        let tooBig = root.appendingPathComponent("too-big.json")
        try rejected("over budget", tooBig, data: Data(repeating: 0, count: DiskImageReportWriter.maximumBytes + 1))
        try check(!fm.fileExists(atPath: tooBig.path), "over-budget output exists")
        let package = root.appendingPathComponent("sample.app", isDirectory: true)
        try fm.createDirectory(at: package, withIntermediateDirectories: false)
        try rejected("existing package directory", package)
        try rejected("device destination", URL(fileURLWithPath: "/dev/null"))
        try rejected("non-file URL", URL(string: "https://example.invalid/report.json")!)
        try rejected("oversized path", root.appendingPathComponent(String(repeating: "x", count: 2_048)))
        let deepPath = "/" + Array(repeating: "x", count: 129).joined(separator: "/")
        try rejected("excessive path depth", URL(fileURLWithPath: deepPath))
        let maximum = Data(repeating: 0x5A, count: DiskImageReportWriter.maximumBytes)
        let maximumURL = root.appendingPathComponent("maximum.json")
        try DiskImageReportWriter.writeNew(data: maximum, to: maximumURL)
        try check(try Data(contentsOf: maximumURL) == maximum, "exact byte budget failed")
        passed += 1
        let emptyURL = root.appendingPathComponent("empty.json")
        try DiskImageReportWriter.writeNew(data: Data(), to: emptyURL)
        try check(try Data(contentsOf: emptyURL).isEmpty, "empty export failed")
        passed += 1
        let raceURL = root.appendingPathComponent("concurrent.json")
        let outcomes = Outcomes()
        DispatchQueue.concurrentPerform(iterations: 2) { index in
            do {
                try DiskImageReportWriter.writeNew(data: Data("winner-\(index)".utf8), to: raceURL)
                outcomes.add(success: true)
            } catch DiskImageReportWriterError.destinationExists { outcomes.add(success: false) }
            catch { outcomes.addUnexpected() }
        }
        try check(outcomes.successes == 1 && outcomes.refusals == 1 && outcomes.unexpected == 0, "concurrent publish replaced or lost an output")
        let winner = try Data(contentsOf: raceURL)
        try check(winner == Data("winner-0".utf8) || winner == Data("winner-1".utf8), "concurrent output incomplete")
        passed += 1
        let leftovers = try fm.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix(".gaojiling-image-report-") }
        try check(leftovers.isEmpty, "temporary files leaked")
        print("DiskImageReportWriterTests: \(passed) checks passed; disposable ordinary files only; no GUI or mounts.")
    }
    struct Failure: Error, CustomStringConvertible { let description: String; init(_ value: String) { description = value } }
    final class Outcomes: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var successes = 0
        private(set) var refusals = 0
        private(set) var unexpected = 0
        func add(success: Bool) { lock.lock(); defer { lock.unlock() }; if success { successes += 1 } else { refusals += 1 } }
        func addUnexpected() { lock.lock(); unexpected += 1; lock.unlock() }
    }
}
