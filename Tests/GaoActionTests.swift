import Foundation
import Darwin

@main struct GaoActionStepTests {
    static func main() throws {
        let base = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let package = base.appendingPathComponent("request.gaoaction", isDirectory: true)
        let payload = package.appendingPathComponent("payload", isDirectory: true)
        _ = try GAFile.directory(payload, createPrivate: true)
        let hello = Data("hello\n".utf8)
        try GAFile.atomic(hello, at: payload.appendingPathComponent("input.txt"), requireMissing: true)
        let now = GaoActionV1.date("2026-10-12T12:00:00Z")!
        let manifest = GAManifest(kind: "request", requestID: "11111111-1111-4111-8111-000000000001",
            sourceBundleID: "com.gaoseries.GaoCaoZuo", targetBundleID: "com.gaoseries.GaoWenJian", action: "documents.newText",
            createdAt: "2026-10-12T12:00:00Z", expiresAt: "2026-10-12T12:02:00Z", nonce: Data(repeating: 0, count: 32).base64EncodedString(),
            items: [GAItem(id: "input", relativePath: "payload/input.txt", uti: "text/plain", byteCount: 6,
                           sha256: "5891b5b522d5df086d0ff0b110fbd9d21bb4fc7163af34d08286a2e846f6be03")],
            parameters: ["suggestedTitle": .string("交接测试")])
        let encoder = JSONEncoder(), valid = try encoder.encode(manifest)
        try GAFile.atomic(valid, at: package.appendingPathComponent("manifest.json"), requireMissing: true)
        let received = try GaoActionV1.receive(package, incoming: base.appendingPathComponent("Incoming"),
            target: manifest.targetBundleID, now: now, providerOnly: false)
        assert(received.manifest.requestID == manifest.requestID)
        let copied = try Data(contentsOf: received.stagedURL.appendingPathComponent("payload/input.txt"))
        let original = try Data(contentsOf: payload.appendingPathComponent("input.txt"))
        assert(copied == hello && original == hello)
        print("PASS: frozen hello fixture, fixed-FD private staging and source preservation")
        func rejected(_ data: Data, _ label: String) {
            do { _ = try GaoActionV1.validate(data, target: manifest.targetBundleID, now: now, providerOnly: false); fatalError(label) }
            catch { print("PASS: rejected " + label) }
        }
        var bad = manifest; bad.schemaVersion = 2; rejected(try encoder.encode(bad), "future schema")
        bad = manifest; bad.expiresAt = "2026-10-12T12:00:00Z"; rejected(try encoder.encode(bad), "expired request")
        bad = manifest; bad.items[0].relativePath = "payload/../escape"; rejected(try encoder.encode(bad), "path traversal")
        bad = manifest; bad.action = "shell.run"; rejected(try encoder.encode(bad), "unknown action")
        bad = manifest; bad.parameters["shell"] = .string("ignored"); rejected(try encoder.encode(bad), "unexpected parameter")
        bad = manifest; bad.nonce = "AA=="; rejected(try encoder.encode(bad), "invalid nonce")
        let record = base.appendingPathComponent("record.json")
        try GAFile.atomic(Data("first".utf8), at: record, requireMissing: true)
        try GAFile.atomic(Data("external".utf8), at: record, expected: Data("first".utf8))
        do { try GAFile.atomic(Data("wrong".utf8), at: record, expected: Data("first".utf8)); fatalError("external change") }
        catch { let current = try Data(contentsOf: record); assert(current == Data("external".utf8)); print("PASS: externally modified state preserved") }
        print("GaoAction checkpoint tests passed; full fixture matrix and provider integration remain pending.")
    }
}
