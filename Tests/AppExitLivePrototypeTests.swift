import AppKit
import ApplicationServices

/// Explicit opt-in, coordinated GUI test of the real normal-quit primitive.
/// Builds/launches only a self-created temporary app with no user documents.
/// It does not claim that an AX-denied/unknown app is eligible for AppOFF.
@main struct AppExitLivePrototypeTests {
    private static let identifier = "org.example.GaoJiLingExitFixture"
    private static func canonicalPath(_ url: URL) -> String { url.resolvingSymlinksInPath().path }
    struct Failure: Error { var message: String }
    @MainActor final class Delegate: NSObject, NSApplicationDelegate {
        func applicationDidFinishLaunching(_ notification: Notification) {
            NSApplication.shared.setAccessibilityEdited(false)
            // A failed harness can never leave an indefinite fixture process.
            DispatchQueue.main.asyncAfter(deadline: .now() + 20) { NSApplication.shared.terminate(nil) }
        }
        func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply { .terminateNow }
    }
    @MainActor static func main() async throws {
        if CommandLine.arguments.contains("--fixture-mode") {
            guard Bundle.main.bundleIdentifier == identifier,
                  canonicalPath(Bundle.main.bundleURL).hasPrefix(canonicalPath(URL(fileURLWithPath: "/private/tmp")) + "/gaojiling-app-exit-live-") else {
                throw Failure(message: "fixture role is limited to its self-created temporary app bundle")
            }
            let app = NSApplication.shared; let delegate = Delegate()
            app.delegate = delegate; app.setActivationPolicy(.accessory)
            withExtendedLifetime(delegate) { app.run() }
            return
        }
        guard ProcessInfo.processInfo.environment["GJL_RUN_APP_EXIT_PROTOTYPE"] == "1" else {
            print("SKIP: self-created app prototype requires an explicitly coordinated GUI window and GJL_RUN_APP_EXIT_PROTOTYPE=1")
            return
        }
        let fm = FileManager.default
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("gaojiling-app-exit-live-" + UUID().uuidString)
        let bundle = root.appendingPathComponent("ExitFixture.app")
        let contents = bundle.appendingPathComponent("Contents")
        let bin = contents.appendingPathComponent("MacOS")
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        var target: NSRunningApplication?
        defer { if target?.isTerminated != false { try? fm.removeItem(at: root) } }
        let executable = bin.appendingPathComponent("ExitFixture")
        try fm.copyItem(at: URL(fileURLWithPath: CommandLine.arguments[0]), to: executable)
        let plist: [String: Any] = ["CFBundleIdentifier": identifier, "CFBundleName": "ExitFixture",
            "CFBundleExecutable": "ExitFixture", "CFBundlePackageType": "APPL", "CFBundleVersion": "1",
            "LSUIElement": true, "NSPrincipalClass": "NSApplication"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
        let configuration = NSWorkspace.OpenConfiguration(); configuration.activates = false
        configuration.arguments = ["--fixture-mode"]
        let app = try await NSWorkspace.shared.openApplication(at: bundle, configuration: configuration)
        target = app
        try await Task.sleep(nanoseconds: 400_000_000)
        guard app.bundleIdentifier == identifier, app.bundleURL.map(canonicalPath) == canonicalPath(bundle),
              let identity = AppExitRuntime.identity(pid: app.processIdentifier), !app.isActive else {
            throw Failure(message: "self-created background application identity could not be confirmed; fixture expires itself")
        }
        let observation = AppExitObservation(identity: identity, bundleID: identifier, path: canonicalPath(bundle),
            name: "ExitFixture", observedAt: Date(), isFrontmost: false, memoryBytes: nil, windowCount: nil, saveState: .unknown, idleSeconds: nil)
        let driver = AppExitDriver.live, inspect = driver.inspect
        let inspection = await Task.detached { inspect(observation) }.value
        guard inspection.identity == identity, driver.validate(observation) else { throw Failure(message: "live process identity validation failed") }
        print("Live AX saved-state availability: \(inspection.saved.rawValue); unknown remains ineligible under the production rules.")
        // The fixture is our own stateless program. This checks only the live
        // termination boundary; injected controller tests separately require
        // a confirmed clean save state before invoking this boundary.
        let attempt = driver.request(observation)
        guard attempt.accepted else { throw Failure(message: "normal-quit request was not accepted; fixture expires itself") }
        for _ in 0..<100 {
            if attempt.hasExited() {
                print("PASS: verified self-created PID/start/UID received only a normal quit and was observed terminated.")
                print("No real user application was selected or closed.")
                return
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw Failure(message: "fixture did not exit within observation budget; no force signal issued; fixture self-expires")
    }
}
