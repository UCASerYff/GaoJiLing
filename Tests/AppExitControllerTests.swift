import Foundation
import Darwin

/// No NSWorkspace enumeration, AX calls, notifications or application exits.
/// The production controller is exercised through its exact runtime boundary.
@main struct AppExitControllerTests {
    struct Failure: Error { var message: String }
    static func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw Failure(message: message) }
    }
    final class Inspection: @unchecked Sendable {
        private let lock = NSLock()
        private let release = DispatchSemaphore(value: 0)
        private var started = false
        var hold = false
        var saved: AppExitSaveState = .clean
        var changeIdentity = false
        var entered: Bool { lock.lock(); defer { lock.unlock() }; return started }
        func perform(_ observation: AppExitObservation) -> AppExitInspection {
            lock.lock(); started = true; let shouldHold = hold, saved = self.saved, change = changeIdentity; lock.unlock()
            if shouldHold { _ = release.wait(timeout: .now() + 3) }
            var identity = observation.identity
            if change { identity.startTime += 1 }
            return AppExitInspection(identity: identity, windows: 0, saved: saved)
        }
        func resume() { release.signal() }
    }
    @MainActor final class Runtime {
        var date = Date(timeIntervalSince1970: 1_000_000)
        var elapsed: TimeInterval = 1000
        var requests = 0
        var validations = 0
        var rejectValidationNumber: Int?
        var disallowAtValidationNumber: Int?
        var actionsAllowed = true
        var accepted = true
        var exited = false
        var durableIntentObserved = false
    }
    @MainActor final class Fixture {
        let root: URL
        let runtime = Runtime()
        let inspection = Inspection()
        let controller: MaintenanceController
        let rule: AppExitRule
        var stateURL: URL { root.appendingPathComponent("Maintenance/state.json") }
        init(base: URL, enabled: Bool = true) {
            root = base.appendingPathComponent(UUID().uuidString)
            var rule = AppExitRule(bundleID: "org.example.utility", path: "/fixture/Utility.app", name: "Utility")
            rule.enabled = true; rule.minutes = 1; rule.cooldownSeconds = 600; self.rule = rule
            let stateURL = root.appendingPathComponent("Maintenance/state.json")
            let runtime = runtime, inspection = inspection
            let driver = AppExitDriver(observations: { rules, _, now in
                rules.filter(\.enabled).map { rule in
                    AppExitObservation(identity: ProcessIdentity(pid: 120, startTime: 400, uid: geteuid()),
                        bundleID: rule.bundleID, path: rule.path, name: rule.name, observedAt: now,
                        isFrontmost: false, memoryBytes: 2_147_483_648, windowCount: nil, saveState: .unknown, idleSeconds: 1000)
                }
            }, inspect: { inspection.perform($0) }, validate: { _ in
                runtime.validations += 1
                if runtime.validations == runtime.disallowAtValidationNumber { runtime.actionsAllowed = false }
                return runtime.validations != runtime.rejectValidationNumber
            }, request: { _ in
                runtime.requests += 1
                if let bytes = try? Data(contentsOf: stateURL), let state = try? JSONDecoder().decode(MaintenancePreferences.self, from: bytes) {
                    runtime.durableIntentObserved = state.records.last?.outcome == "准备请求"
                }
                return AppExitAttempt(accepted: runtime.accepted, hasExited: { runtime.exited })
            })
            controller = MaintenanceController(dataDirectory: root, driver: driver, clock: { runtime.date },
                uptime: { runtime.elapsed }, observeWorkspace: false, deliverNotice: { _ in }, actionsAllowed: { runtime.actionsAllowed })
            controller.update { $0.rules = [rule]; $0.appExitEnabled = enabled }
        }
        func tick(_ offset: TimeInterval) {
            runtime.date = Date(timeIntervalSince1970: 1_000_000 + offset); runtime.elapsed = 1000 + offset
            controller.ingest(sample: MetricsSample())
        }
        func qualify(hold: Bool = false) async throws {
            inspection.hold = hold
            for offset in stride(from: 0.0, through: 50, by: 10) { tick(offset); try await settle() }
            tick(60)
            if hold {
                for _ in 0..<200 {
                    if inspection.entered { return }
                    try await Task.sleep(nanoseconds: 5_000_000)
                }
                throw Failure(message: "inspection did not start")
            }
            try await settle()
        }
        func settle() async throws {
            for _ in 0..<400 {
                if !controller.isChecking { return }
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            throw Failure(message: "asynchronous inspection did not finish")
        }
    }
    @MainActor static func main() async throws {
        let base = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("gaojiling-app-exit-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let disabled = Fixture(base: base, enabled: false)
        try await disabled.qualify()
        try require(!disabled.inspection.entered && disabled.runtime.requests == 0, "global default-off suppresses all inspections and requests")

        let normal = Fixture(base: base)
        try await normal.qualify()
        try require(normal.runtime.requests == 1 && normal.runtime.durableIntentObserved, "durable intent must exist before the normal-quit request")
        try require(normal.controller.preferences.records.map(\.outcome) == ["准备请求"], "accepted request is not reported as an actual exit")
        normal.runtime.exited = true; normal.tick(70)
        try require(normal.controller.preferences.records.last?.outcome == "已退出", "actual exit is recorded only after runtime observation")
        normal.tick(80); try await normal.settle()
        try require(normal.runtime.requests == 1, "successful exit is not retried within cooldown")

        let refused = Fixture(base: base); refused.runtime.accepted = false
        try await refused.qualify(); refused.tick(70); try await refused.settle()
        try require(refused.runtime.requests == 1 && refused.controller.preferences.records.last?.outcome == "未发送", "refused requests are logged and not retried")
        let waiting = Fixture(base: base)
        try await waiting.qualify(); waiting.tick(91)
        try require(waiting.runtime.requests == 1 && waiting.controller.preferences.records.last?.outcome == "未退出", "accepted but still-running app times out without force or repeat")
        print("PASS: durable intent, observed completion, refusal/cooldown and pending timeout")

        let unknown = Fixture(base: base); unknown.inspection.saved = .unknown
        try await unknown.qualify()
        try require(unknown.runtime.requests == 0 && unknown.controller.preferences.records.isEmpty, "unknown save state never requests exit")
        let reused = Fixture(base: base); reused.inspection.changeIdentity = true
        try await reused.qualify()
        try require(reused.runtime.requests == 0 && reused.controller.preferences.records.isEmpty, "process identity change during AX inspection prevents request")
        let lateIdentity = Fixture(base: base); lateIdentity.runtime.rejectValidationNumber = 2
        try await lateIdentity.qualify(); lateIdentity.tick(70); try await lateIdentity.settle()
        try require(lateIdentity.runtime.requests == 0 && lateIdentity.controller.preferences.records.map(\.outcome) == ["准备请求"], "identity change after durable intent cannot cause a request or replay")

        let paused = Fixture(base: base)
        try await paused.qualify(hold: true); paused.controller.update { $0.appExitPaused = true }
        paused.inspection.resume(); try await paused.settle()
        try require(paused.runtime.requests == 0, "pausing while inspecting blocks the eventual request")
        let sleeping = Fixture(base: base)
        try await sleeping.qualify(hold: true); sleeping.controller.handleSleep(true)
        sleeping.inspection.resume(); try await sleeping.settle(); sleeping.controller.handleSleep(false)
        for offset in stride(from: 70.0, through: 120, by: 10) { sleeping.tick(offset); try await sleeping.settle() }
        try require(sleeping.runtime.requests == 0, "sleep aborts in-flight checks and wake starts a full new observation interval")
        let suspended = Fixture(base: base)
        try await suspended.qualify(hold: true); suspended.controller.setActionsSuspended(true)
        suspended.inspection.resume(); try await suspended.settle()
        try require(suspended.runtime.requests == 0, "data restore/sampling suspension invalidates pending checks")
        let busy = Fixture(base: base)
        try await busy.qualify(hold: true); busy.runtime.actionsAllowed = false
        busy.inspection.resume(); try await busy.settle()
        try require(busy.runtime.requests == 0 && busy.controller.preferences.records.isEmpty, "actual busy state prevents quit even before the async suspension notification arrives")
        let busyLate = Fixture(base: base); busyLate.runtime.disallowAtValidationNumber = 2
        try await busyLate.qualify()
        try require(busyLate.runtime.requests == 0 && busyLate.controller.preferences.records.map(\.outcome) == ["准备请求"], "live busy guard is checked again at the final request boundary")
        let busyInitially = Fixture(base: base); busyInitially.runtime.actionsAllowed = false
        try await busyInitially.qualify()
        try require(!busyInitially.inspection.entered && busyInitially.runtime.requests == 0, "busy ingestion does not begin an AX inspection")
        print("PASS: unknown save state, both identity checks, async pause/sleep and sampling suspension")

        let changed = Fixture(base: base)
        try await changed.qualify(hold: true)
        let foreign = Data("external fixture contents must survive".utf8)
        try foreign.write(to: changed.stateURL)
        changed.inspection.resume(); try await changed.settle()
        try require(changed.runtime.requests == 0 && !changed.controller.writable, "external state change blocks audit and the following quit request")
        let bytes = try Data(contentsOf: changed.stateURL)
        try require(bytes == foreign, "external file bytes are preserved exactly")
        let reopened = MaintenanceController(dataDirectory: changed.root, observeWorkspace: false, deliverNotice: { _ in })
        try require(!reopened.writable && !reopened.preferences.appExitEnabled, "unreadable/corrupt state cannot implicitly enable actions")
        print("PASS: external-state mutation prevents side effects and preserves bytes")
        print("AppExit controller tests passed; all application observations and quit requests were injected.")
    }
}
