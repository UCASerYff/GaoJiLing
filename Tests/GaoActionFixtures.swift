import Foundation
import Darwin

/// Frozen Task 03 compatibility inputs. These are synthetic protocol fixtures,
/// never production requests or evidence that an OCR/maintenance task ran.
enum GAFixtures {
    static let clock = ISO8601DateFormatter().date(from: "2026-10-12T12:00:00Z")!
    static let created = "2026-10-12T12:00:00Z"
    static let expires = "2026-10-12T12:02:00Z"
    static let nonce = Data(repeating: 0, count: 32).base64EncodedString()
    static let hello = Data("hello\n".utf8)
    static let helloSHA = "5891b5b522d5df086d0ff0b110fbd9d21bb4fc7163af34d08286a2e846f6be03"
    static let source = "com.gaoseries.GaoCaoZuo"
    static let documents = "com.gaoseries.GaoWenJian"
    static let ocr = "com.gaoseries.GaoJieTu"
    static let names = ["v1-documents-newText", "v1-storage-directory", "v1-ocr-partial", "v1-duplicate-request",
                        "v1-expired", "v1-path-traversal", "v1-unknown-action", "v2-unsupported"]
    struct Fixture {
        let name: String
        var manifest: GAManifest
        var files: [String: Data] = [:]
        // A result uses its own UUID and refers to this request, rather than itself.
        var relatedRequest: GAManifest?
        var requestFiles: [String: Data] = [:]
    }
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
        guard value() else { throw Failure(description: message) }
    }
    static func rejects(_ message: String, _ action: () throws -> Void) throws {
        do { try action() } catch { return }
        throw Failure(description: "accepted invalid input: " + message)
    }
    static func id(_ index: Int) -> String { String(format: "11111111-1111-4111-8111-%012d", index) }
    static func request(_ index: Int, action: String = "cleanup.review", target: String = GaoActionV1.bundleID) -> GAManifest {
        GAManifest(kind: "request", requestID: id(index), sourceBundleID: source, targetBundleID: target,
                   action: action, createdAt: created, expiresAt: expires, nonce: nonce)
    }
    static func encode(_ value: GAManifest) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
    static func privateDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard chmod(url.path, 0o700) == 0 else { throw Failure(description: "cannot protect synthetic directory") }
    }
    static func put(_ bytes: Data, at url: URL) throws {
        try privateDirectory(url.deletingLastPathComponent())
        try bytes.write(to: url)
        guard chmod(url.path, 0o600) == 0 else { throw Failure(description: "cannot protect synthetic file") }
    }
    static func temporaryRoot(_ name: String) throws -> URL {
        let url = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("gaojiling-" + name + "-" + UUID().uuidString, isDirectory: true)
        try privateDirectory(url); return url
    }
    static func identity(_ url: URL) throws -> GAIdentity {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_size >= 0 else { throw Failure(description: "synthetic reference stat failed") }
        let modified = Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1e9)
        return GAIdentity(volumeUUID: try url.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString,
                          device: info.st_dev, inode: info.st_ino, byteCount: UInt64(info.st_size),
                          modifiedAt: GaoActionV1.timestamp(modified))
    }
    static func reference(_ url: URL, kind: String = "directory") throws -> GAReference {
        GAReference(id: "scope", kind: kind, fileURL: url.absoluteString, displayName: "合成测试目录",
                    declaredIdentity: try identity(url))
    }
    static func all(scope: URL) throws -> [Fixture] {
        var document = request(1, action: "documents.newText", target: documents)
        document.items = [GAItem(id: "input", relativePath: "payload/input.txt", uti: "text/plain", byteCount: 6, sha256: helloSHA)]
        document.parameters = ["suggestedTitle": .string("交接测试")]
        var storage = request(2, action: "storage.inspect")
        storage.references = [try reference(scope)]; storage.parameters = ["mode": .string("metadata")]
        // Two one-pixel PNG copies represent two input pages. No real OCR is run.
        let pixel = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Wl6WAAAAABJRU5ErkJggg==")!
        let pixelSHA = GaoActionV1.sha(pixel)
        var ocrRequest = request(3, action: "ocr.files", target: ocr)
        ocrRequest.items = (1...2).map { GAItem(id: "page\($0)", relativePath: "payload/page\($0).png", uti: "public.png", byteCount: UInt64(pixel.count), sha256: pixelSHA) }
        ocrRequest.parameters = ["outputs": .array([.string("text")])]
        var partial = GAManifest(kind: "result", requestID: "22222222-2222-4222-8222-000000000003",
            sourceBundleID: ocr, targetBundleID: source, action: "ocr.files", createdAt: created, expiresAt: expires, nonce: nonce,
            inReplyTo: id(3), status: "partial", provenance: ["pages": .array([
                .object(["sourceItemID": .string("page1"), "sourceSHA256": .string(pixelSHA), "status": .string("completed"), "outputItemID": .string("page1-text")]),
                .object(["sourceItemID": .string("page2"), "sourceSHA256": .string(pixelSHA), "status": .string("failed"), "errorCode": .string("fixturePageFailure")])])])
        partial.items = [GAItem(id: "page1-text", relativePath: "payload/page1.txt", uti: "text/plain", byteCount: 6, sha256: helloSHA)]
        var expired = request(5); expired.createdAt = "2026-10-12T11:57:59Z"; expired.expiresAt = "2026-10-12T11:59:59Z"
        var traversal = document; traversal.requestID = id(6); traversal.items[0].relativePath = "payload/../input.txt"
        var unknown = request(7); unknown.action = "shell.run"
        var future = request(8); future.schemaVersion = 2
        return [Fixture(name: names[0], manifest: document, files: ["payload/input.txt": hello]),
                Fixture(name: names[1], manifest: storage),
                Fixture(name: names[2], manifest: partial, files: ["payload/page1.txt": hello], relatedRequest: ocrRequest,
                        requestFiles: ["payload/page1.png": pixel, "payload/page2.png": pixel]),
                Fixture(name: names[3], manifest: request(4)), Fixture(name: names[4], manifest: expired),
                Fixture(name: names[5], manifest: traversal, files: ["payload/input.txt": hello]),
                Fixture(name: names[6], manifest: unknown), Fixture(name: names[7], manifest: future)]
    }
    /// Writes only explicit fixture files; a malicious manifest path is never used as a destination.
    static func package(_ fixture: Fixture, in directory: URL, name: String? = nil) throws -> URL {
        let url = directory.appendingPathComponent((name ?? fixture.name) + ".gaoaction", isDirectory: true)
        try privateDirectory(url.appendingPathComponent("payload", isDirectory: true))
        for (path, bytes) in fixture.files {
            guard path.hasPrefix("payload/"), !path.split(separator: "/").contains("..") else { throw Failure(description: "unsafe fixture destination") }
            try put(bytes, at: url.appendingPathComponent(path))
        }
        try put(try encode(fixture.manifest), at: url.appendingPathComponent("manifest.json"))
        return url
    }
}
