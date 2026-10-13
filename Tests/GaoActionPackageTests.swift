import Foundation
import Darwin

@main struct GaoActionPackageTests {
    static func main() throws {
        let base = try GAFixtures.temporaryRoot("gaoaction-packages")
        defer { try? FileManager.default.removeItem(at: base) }
        let scope = base.appendingPathComponent("scope", isDirectory: true)
        try GAFixtures.privateDirectory(scope)
        try GAFixtures.put(Data("synthetic scope\n".utf8), at: scope.appendingPathComponent("sample.txt"))
        let fixtures = try GAFixtures.all(scope: scope)
        var failures: [String] = []
        func check(_ name: String, _ body: () throws -> Void) {
            do { try body(); print("PASS: " + name) }
            catch { failures.append(name + ": " + String(describing: error)); print("FAIL: " + name + ": " + String(describing: error)) }
        }
        func receive(_ package: URL, _ target: String) throws -> GAReceived {
            try GaoActionV1.receive(package, incoming: base.appendingPathComponent("Incoming"), target: target,
                                    now: GAFixtures.clock, providerOnly: false)
        }
        let validDocument = try GAFixtures.package(fixtures[0], in: base)
        for fixture in fixtures.prefix(3) {
            check("fixed fixture " + fixture.name) {
                let package = fixture.name == fixtures[0].name ? validDocument : try GAFixtures.package(fixture, in: base)
                let accepted = try receive(package, fixture.manifest.targetBundleID)
                try GAFixtures.require(accepted.manifest == fixture.manifest, "manifest meaning changed during staging")
                for (path, bytes) in fixture.files {
                    let source = try Data(contentsOf: package.appendingPathComponent(path))
                    let copy = try Data(contentsOf: accepted.stagedURL.appendingPathComponent(path))
                    try GAFixtures.require(source == bytes && copy == bytes, "source or private copy changed")
                    var info = stat()
                    try GAFixtures.require(lstat(accepted.stagedURL.appendingPathComponent(path).path, &info) == 0 && info.st_mode & 0o777 == 0o600, "copied file is not private")
                }
                var info = stat()
                try GAFixtures.require(lstat(accepted.stagedURL.path, &info) == 0 && info.st_mode & 0o777 == 0o700, "staging package is not private")
                if fixture.manifest.action == "storage.inspect" {
                    let resolved = try GaoActionV1.resolveReference(fixture.manifest.references[0])
                    try GAFixtures.require(resolved.url.path == scope.path && resolved.identity.inode == fixture.manifest.references[0].declaredIdentity?.inode, "directory reference did not retain real identity")
                }
                if fixture.manifest.kind == "result" {
                    try GAFixtures.require(accepted.manifest.status == "partial" && accepted.manifest.inReplyTo == GAFixtures.id(3), "OCR partial result lost correlation")
                }
            }
        }
        check("OCR request with two input pages matches partial result sources") {
            let partial = fixtures[2]
            let request = partial.relatedRequest!
            let package = try GAFixtures.package(.init(name: "ocr-input", manifest: request, files: partial.requestFiles), in: base)
            let accepted = try receive(package, GAFixtures.ocr)
            try GAFixtures.require(accepted.manifest.items.count == 2 && accepted.manifest.requestID == partial.manifest.inReplyTo,
                                  "OCR input/result identity mismatch")
            try GAFixtures.require(GaoActionV1.sha(GAFixtures.hello) == GAFixtures.helloSHA, "frozen hello SHA mismatch")
        }
        for fixture in fixtures.suffix(4) {
            check("reject fixed fixture " + fixture.name) {
                let package = try GAFixtures.package(fixture, in: base)
                try GAFixtures.rejects(fixture.name) { _ = try receive(package, fixture.manifest.targetBundleID) }
            }
        }
        let invalidManifests: [(String, (inout GAManifest) -> Void)] = [
            ("wrong target", { $0.targetBundleID = "com.gaoseries.WrongApp" }),
            ("invalid declared source", { $0.sourceBundleID = "not a bundle" }),
            ("invalid UUID", { $0.requestID = "not-a-uuid" }),
            ("short nonce", { $0.nonce = "AA==" }),
            ("invalid Base64 nonce", { $0.nonce = "!" }),
            ("too long TTL", { $0.expiresAt = "2026-10-12T12:02:01Z" }),
            ("future createdAt", { $0.createdAt = "2026-10-12T12:00:01Z" }),
            ("non UTC timestamp", { $0.createdAt = "2026-10-12T20:00:00+08:00" }),
            ("shell parameter", { $0.parameters["shell"] = .string("not executed") }),
            ("callback parameter", { $0.parameters["callbackURL"] = .string("https://example.invalid/") }),
            ("overlong title", { $0.parameters["suggestedTitle"] = .string(String(repeating: "a", count: 257)) }),
            ("absolute payload path", { $0.items[0].relativePath = "/private/tmp/escape" }),
            ("empty payload component", { $0.items[0].relativePath = "payload//input.txt" }),
            ("backslash payload path", { $0.items[0].relativePath = "payload/..\\input.txt" }),
            ("invalid digest", { $0.items[0].sha256 = "abc" }),
            ("payload limit", { $0.items[0].byteCount = GaoActionV1.payloadLimit + 1 }),
            ("item count limit", { $0.items = (0...256).map { GAItem(id: String($0), relativePath: "payload/\($0).txt", uti: "text/plain", byteCount: 6, sha256: GAFixtures.helloSHA) } })
        ]
        for (name, change) in invalidManifests {
            check("manifest " + name) {
                var value = fixtures[0].manifest; change(&value)
                try GAFixtures.rejects(name) { _ = try GaoActionV1.validate(GAFixtures.encode(value), target: GAFixtures.documents, now: GAFixtures.clock, providerOnly: false) }
            }
        }
        check("manifest byte limit") {
            try GAFixtures.rejects("manifest larger than 1 MiB") { _ = try GaoActionV1.validate(Data(repeating: 32, count: 1024 * 1024 + 1), now: GAFixtures.clock) }
        }
        check("unsupported duplicate-content mode and unsafe cleanup parameters") {
            var storage = fixtures[1].manifest; storage.parameters["mode"] = .string("duplicates")
            try GAFixtures.rejects("duplicates not implemented") { _ = try GaoActionV1.validate(GAFixtures.encode(storage), now: GAFixtures.clock) }
            var cleanup = GAFixtures.request(40); cleanup.parameters["path"] = .string(scope.path)
            try GAFixtures.rejects("arbitrary cleanup path") { _ = try GaoActionV1.validate(GAFixtures.encode(cleanup), now: GAFixtures.clock) }
        }
        for (name, url) in [
            ("https source URL", URL(string: "https://example.invalid" + validDocument.path)!),
            ("remote file source URL", URL(string: "file://remote.invalid" + validDocument.path)!)
        ] {
            check(name) { try GAFixtures.rejects(name) { _ = try receive(url, GAFixtures.documents) } }
        }
        for (name, alter) in [
            ("payload symlink", { (url: URL) throws in try FileManager.default.removeItem(at: url); try FileManager.default.createSymbolicLink(at: url, withDestinationURL: validDocument.appendingPathComponent("payload/input.txt")) }),
            ("payload hardlink", { (url: URL) throws in try FileManager.default.removeItem(at: url); try GAFixtures.require(link(validDocument.appendingPathComponent("payload/input.txt").path, url.path) == 0, "hardlink fixture failed") }),
            ("payload FIFO", { (url: URL) throws in try FileManager.default.removeItem(at: url); try GAFixtures.require(mkfifo(url.path, 0o600) == 0, "FIFO fixture failed") }),
            ("payload directory", { (url: URL) throws in try FileManager.default.removeItem(at: url); try GAFixtures.privateDirectory(url) }),
            ("payload changed bytes", { (url: URL) throws in try GAFixtures.put(Data("other\n".utf8), at: url) }),
            ("payload missing", { (url: URL) throws in try FileManager.default.removeItem(at: url) })
        ] {
            check(name) {
                let package = try GAFixtures.package(fixtures[0], in: base, name: name)
                try alter(package.appendingPathComponent("payload/input.txt"))
                try GAFixtures.rejects(name) { _ = try receive(package, GAFixtures.documents) }
                // Remove this controlled hardlink before subsequent valid source tests.
                try FileManager.default.removeItem(at: package)
            }
        }
        check("manifest, package and ancestor symlinks") {
            let linkedPackage = base.appendingPathComponent("linked.gaoaction")
            try FileManager.default.createSymbolicLink(at: linkedPackage, withDestinationURL: validDocument)
            try GAFixtures.rejects("package symlink") { _ = try receive(linkedPackage, GAFixtures.documents) }
            let parent = base.appendingPathComponent("linked-parent")
            try FileManager.default.createSymbolicLink(at: parent, withDestinationURL: base)
            try GAFixtures.rejects("ancestor symlink") { _ = try receive(parent.appendingPathComponent(validDocument.lastPathComponent), GAFixtures.documents) }
            let package = try GAFixtures.package(fixtures[0], in: base, name: "manifest-symlink")
            let file = package.appendingPathComponent("manifest.json")
            try FileManager.default.removeItem(at: file)
            try FileManager.default.createSymbolicLink(at: file, withDestinationURL: validDocument.appendingPathComponent("manifest.json"))
            try GAFixtures.rejects("manifest symlink") { _ = try receive(package, GAFixtures.documents) }
        }
        check("undeclared attachment and denied read permission") {
            let package = try GAFixtures.package(fixtures[0], in: base, name: "extra-file")
            try GAFixtures.put(GAFixtures.hello, at: package.appendingPathComponent("payload/extra.txt"))
            try GAFixtures.rejects("undeclared attachment") { _ = try receive(package, GAFixtures.documents) }
            try GAFixtures.require(geteuid() != 0, "permission fixture requires an ordinary user")
            let restricted = try GAFixtures.package(fixtures[0], in: base, name: "read-denied")
            let file = restricted.appendingPathComponent("payload/input.txt")
            try GAFixtures.require(chmod(file.path, 0) == 0, "restrict fixture")
            defer { _ = chmod(file.path, 0o600) }
            try GAFixtures.rejects("unreadable payload") { _ = try receive(restricted, GAFixtures.documents) }
        }
        check("oversized actual file is rejected before content read") {
            let package = try GAFixtures.package(fixtures[0], in: base, name: "oversized-sparse")
            let file = package.appendingPathComponent("payload/input.txt")
            let fd = open(file.path, O_WRONLY | O_NOFOLLOW | O_CLOEXEC)
            try GAFixtures.require(fd >= 0, "open sparse fixture")
            defer { close(fd) }
            try GAFixtures.require(ftruncate(fd, off_t(GaoActionV1.payloadLimit + 1)) == 0, "create sparse length without allocating payload contents")
            try GAFixtures.rejects("oversized regular file") { _ = try receive(package, GAFixtures.documents) }
        }
        check("reference local URL, identity and explicit selection boundaries") {
            let valid = fixtures[1].manifest.references[0]
            for text in ["https://example.invalid" + scope.path, "file://remote.invalid" + scope.path, scope.absoluteString + "?token=private", "file:///private/tmp/../outside"] {
                var ref = valid; ref.fileURL = text
                try GAFixtures.rejects("non-local or non-canonical reference") { _ = try GaoActionV1.resolveReference(ref) }
            }
            var wrong = valid; let wrongInode = (valid.declaredIdentity?.inode ?? 0) + 1; wrong.declaredIdentity?.inode = wrongInode
            try GAFixtures.rejects("wrong identity") { _ = try GaoActionV1.resolveReference(wrong) }
            var unknown = valid; unknown.declaredIdentity = GAIdentity(volumeUUID: nil, device: nil, inode: nil, byteCount: nil, modifiedAt: nil)
            try GAFixtures.rejects("identity requires local selection") { _ = try GaoActionV1.resolveReference(unknown) }
            let selected = try GaoActionV1.resolveReference(unknown, selected: scope)
            try GAFixtures.require(selected.identity.inode == valid.declaredIdentity?.inode, "selection did not derive actual identity")
            try GAFixtures.rejects("selection cannot substitute unrelated directory") { _ = try GaoActionV1.resolveReference(unknown, selected: base) }
        }
        check("reference replacement after manifest creation") {
            let directory = base.appendingPathComponent("replaced-scope")
            try GAFixtures.privateDirectory(directory)
            let ref = try GAFixtures.reference(directory)
            try FileManager.default.moveItem(at: directory, to: base.appendingPathComponent("old-scope"))
            try GAFixtures.privateDirectory(directory)
            try GAFixtures.rejects("replaced inode") { _ = try GaoActionV1.resolveReference(ref) }
        }
        check("application reference verifies real bundle and refuses linked contents") {
            let app = base.appendingPathComponent("Synthetic.app", isDirectory: true)
            let plist = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "com.example.SyntheticFixture", "CFBundleExecutable": "NoExecutable"], format: .xml, options: 0)
            try GAFixtures.put(plist, at: app.appendingPathComponent("Contents/Info.plist"))
            var ref = try GAFixtures.reference(app, kind: "application"); ref.bundleID = "com.example.SyntheticFixture"
            let accepted = try GaoActionV1.resolveReference(ref)
            try GAFixtures.require(accepted.identity.inode == ref.declaredIdentity?.inode, "application identity mismatch")
            var wrong = ref; wrong.bundleID = "com.example.DifferentApplication"
            try GAFixtures.rejects("wrong actual app bundle ID") { _ = try GaoActionV1.resolveReference(wrong) }
            let contents = app.appendingPathComponent("Contents"), moved = base.appendingPathComponent("MovedContents")
            try FileManager.default.moveItem(at: contents, to: moved)
            try FileManager.default.createSymbolicLink(at: contents, withDestinationURL: moved)
            ref.declaredIdentity = try GAFixtures.identity(app)
            try GAFixtures.rejects("application Contents symlink") { _ = try GaoActionV1.resolveReference(ref) }
        }
        check("file reference digest and hardlink boundary") {
            let file = base.appendingPathComponent("Referenced.txt")
            try GAFixtures.put(GAFixtures.hello, at: file)
            var ref = try GAFixtures.reference(file, kind: "file"); ref.sha256 = GAFixtures.helloSHA
            _ = try GaoActionV1.resolveReference(ref)
            ref.sha256 = String(repeating: "0", count: 64)
            try GAFixtures.rejects("file reference hash mismatch") { _ = try GaoActionV1.resolveReference(ref) }
            let second = base.appendingPathComponent("Referenced-hardlink.txt")
            try GAFixtures.require(link(file.path, second.path) == 0, "create reference hardlink")
            ref.declaredIdentity = try GAFixtures.identity(file); ref.sha256 = GAFixtures.helloSHA
            try GAFixtures.rejects("file reference hardlink") { _ = try GaoActionV1.resolveReference(ref) }
        }
        check("completion cannot mean merely opening maintenance UI") {
            var result = GAFixtures.request(49); result.kind = "result"; result.inReplyTo = GAFixtures.id(4); result.status = "completed"
            result.provenance = ["workflowState": .string("awaitingUser")]
            try GAFixtures.rejects("cleanup completion without receipt") { _ = try GaoActionV1.validate(GAFixtures.encode(result), now: GAFixtures.clock) }
        }
        guard failures.isEmpty else { throw GAFixtures.Failure(description: "\(failures.count) GaoAction package groups failed") }
        print("GaoAction package fixtures passed; synthetic files removed. No cross-app GUI or OCR execution was tested.")
    }
}
