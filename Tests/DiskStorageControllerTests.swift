import Foundation

@main struct DiskStorageControllerTests {
    struct Failure: Error { let message: String }
    @MainActor static func main() async throws {
        func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
            if try !value() { throw Failure(message: message) }
        }
        let root = URL(fileURLWithPath: "/private/tmp/gaojiling-controller-\(UUID().uuidString).noindex", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let data = root.appendingPathComponent("existing-data", isDirectory: true)
        let controller = DiskStorageController(dataDirectory: data)
        let source = root.appendingPathComponent("not-created.img")
        controller.prepareImage(source)
        try check(controller.preparedImage == source && controller.image == nil && !controller.isBusy,
                  "Finder prefill must not open an image, even when the path does not exist")
        controller.analyzeImage(source, contentReadConfirmed: false)
        try check(!controller.isBusy && controller.image == nil && controller.volumes == nil, "consent required before any work")
        try check(!FileManager.default.fileExists(atPath: data.path), "controller must not create/initialize a business directory")
        controller.actionsAllowed = { false }
        controller.analyzeImage(source, contentReadConfirmed: true)
        controller.refreshVolumes()
        try check(!controller.isBusy && controller.image == nil && controller.volumes == nil, "external business gate must protect both operations")
        controller.actionsAllowed = { true }
        let malformed = root.appendingPathComponent("malformed.img")
        let original = Data(repeating: 0xCC, count: 512)
        try original.write(to: malformed)
        controller.analyzeImage(malformed, contentReadConfirmed: true)
        try check(controller.isBusy, "accepted operation owns busy synchronously")
        await controller.waitUntilIdle()
        try check(!controller.isBusy && controller.image == nil, "failed image must release busy without manufacturing a report")
        try check(try Data(contentsOf: malformed) == original, "failure must not alter source")
        controller.analyzeImage(malformed, contentReadConfirmed: true)
        controller.cancel()
        await controller.waitUntilIdle()
        try check(!controller.isBusy && controller.image == nil, "cancelled/failed repeated operation must not replay a stale result")
        try check(!FileManager.default.fileExists(atPath: data.path), "retries must not create migration records or reset original data")

        for destination in [data.appendingPathComponent("new.json"), URL(fileURLWithPath: "/dev/new.img"),
                            URL(fileURLWithPath: data.path.uppercased() + "/new.json"),
                            URL(fileURLWithPath: "/Applications/Other.app/new.json"), malformed,
                            root.appendingPathComponent("Other.app/new.json")] {
            var rejected = false
            do { try DiskStorageOutputPolicy.validate(destination, dataDirectory: data, source: malformed) }
            catch { rejected = true }
            try check(rejected, "protected destination was accepted")
        }
        try DiskStorageOutputPolicy.validate(root.appendingPathComponent("new-file.json"), dataDirectory: data, source: malformed)
        print("PASS: DiskStorageController consent, busy gate, failure/cancel retry and protected new output checks; no app/volumes/real data opened")
    }
}
