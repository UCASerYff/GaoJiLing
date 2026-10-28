import Foundation
import Darwin

/// No NSWorkspace enumeration, AX calls, notifications or application exits.
/// The production controller is exercised through its exact runtime boundary.
@main struct AppExitControllerTests {
    struct Failure: Error { var message: String }
    static func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw Failure(message: message) }
    }
    /// All state shared with the detached production inspections is locked.
    /// A per-call hold lets tests mutate guards during the second inspection.
    final class Inspection: @unchecked Sendable {
        private let lock = NSLock()
        private let release = DispatchSemaphore(value: 0)
        private var count = 0
        private var holdFirst = false
        private var heldCall: Int?
        private var defaultSaved: AppExitSaveState = .clean
        private var changesIdentity = false
        private var states: [AppExitSaveState] = []
        private var identityChangeCall: Int?
        var hold: Bool {
            get { lock.lock(); defer { lock.unlock() }; return holdFirst }
            set { lock.lock(); holdFirst = newValue; lock.unlock() }
        }
        var saved: AppExitSaveState {
            get { lock.lock(); defer { lock.unlock() }; return defaultSaved }
            set { lock.lock(); defaultSaved = newValue; lock.unlock() }
        }
        var changeIdentity: Bool {
            get { lock.lock(); defer { lock.unlock() }; return changesIdentity }
            set { lock.lock(); changesIdentity = newValue; lock.unlock() }
        }
        var enteredCalls: Int { lock.lock(); defer { lock.unlock() }; return count }
        var entered: Bool { enteredCalls > 0 }
        func configure(states: [AppExitSaveState], holdAtCall: Int? = nil, changeIdentityAtCall: Int? = nil) {
            lock.lock(); defer { lock.unlock() }
            precondition(count == 0, "configure before inspections begin")
            self.states = states; heldCall = holdAtCall; identityChangeCall = changeIdentityAtCall
        }
        func perform(_ observation: AppExitObservation) -> AppExitInspection {
            lock.lock(); count += 1; let call = count
            let shouldHold = (holdFirst && call == 1) || heldCall == call
            let saved = states.indices.contains(call - 1) ? states[call - 1] : defaultSaved
            let change = changesIdentity || identityChangeCall == call
            lock.unlock()
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
        var frontmost = false
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
                        isFrontmost: runtime.frontmost, memoryBytes: 2_147_483_648, windowCount: nil, saveState: .unknown, idleSeconds: 1000)
                }
            }, inspect: { inspection.perform($0) }, validate: { _ in
                runtime.validations += 1
                if runtime.validations == runtime.disallowAtValidationNumber { runtime.actionsAllowed = false }
                return !runtime.frontmost && runtime.validations != runtime.rejectValidationNumber
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
        func qualify(hold: Bool = false, heldCall: Int? = nil) async throws {
            inspection.hold = hold
            for offset in stride(from: 0.0, through: 50, by: 10) { tick(offset); try await settle() }
            tick(60)
            if hold || heldCall != nil {
                for _ in 0..<200 {
                    if inspection.enteredCalls >= (heldCall ?? 1) { return }
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
        try require(normal.inspection.enteredCalls == 2 && normal.runtime.requests == 1 && normal.runtime.durableIntentObserved, "two clean inspections and durable intent must precede the only normal-quit request")
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
        let lateIdentity = Fixture(base: base); lateIdentity.runtime.rejectValidationNumber = 3
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
        sleeping.tick(130); try await sleeping.settle()
        try require(sleeping.runtime.requests == 1, "a full new post-wake minute may qualify normally; protection must not disable rules forever")
        let suspended = Fixture(base: base)
        try await suspended.qualify(hold: true); suspended.controller.setActionsSuspended(true)
        suspended.inspection.resume(); try await suspended.settle()
        try require(suspended.runtime.requests == 0, "data restore/sampling suspension invalidates pending checks")
        let busy = Fixture(base: base)
        try await busy.qualify(hold: true); busy.runtime.actionsAllowed = false
        busy.inspection.resume(); try await busy.settle()
        try require(busy.runtime.requests == 0 && busy.controller.preferences.records.isEmpty, "actual busy state prevents quit even before the async suspension notification arrives")
        let busyLate = Fixture(base: base); busyLate.runtime.disallowAtValidationNumber = 3
        try await busyLate.qualify()
        try require(busyLate.runtime.requests == 0 && busyLate.controller.preferences.records.map(\.outcome) == ["准备请求"], "live busy guard is checked again at the final request boundary")
        let busyInitially = Fixture(base: base); busyInitially.runtime.actionsAllowed = false
        try await busyInitially.qualify()
        try require(!busyInitially.inspection.entered && busyInitially.runtime.requests == 0, "busy ingestion does not begin an AX inspection")
        print("PASS: unknown save state, both identity checks, async pause/sleep and sampling suspension")

        for state in [AppExitSaveState.edited, .unknown] {
            let changedSaved = Fixture(base: base)
            changedSaved.inspection.configure(states: [.clean, state])
            try await changedSaved.qualify()
            try require(changedSaved.inspection.enteredCalls == 2 && changedSaved.runtime.requests == 0 && changedSaved.controller.preferences.records.isEmpty, "a clean first read cannot authorize exit after a later edited/unknown read")
        }
        let secondIdentity = Fixture(base: base)
        secondIdentity.inspection.configure(states: [.clean, .clean], changeIdentityAtCall: 2)
        try await secondIdentity.qualify()
        try require(secondIdentity.runtime.requests == 0 && secondIdentity.controller.preferences.records.isEmpty, "identity change during the second inspection blocks intent and request")
        let beforeIntentIdentity = Fixture(base: base); beforeIntentIdentity.runtime.rejectValidationNumber = 2
        try await beforeIntentIdentity.qualify()
        try require(beforeIntentIdentity.runtime.requests == 0 && beforeIntentIdentity.controller.preferences.records.isEmpty, "validation after the second inspection still precedes durable intent")

        let secondPaused = Fixture(base: base)
        secondPaused.inspection.configure(states: [.clean, .clean], holdAtCall: 2)
        try await secondPaused.qualify(heldCall: 2); secondPaused.controller.update { $0.appExitPaused = true }
        secondPaused.inspection.resume(); try await secondPaused.settle()
        try require(secondPaused.runtime.requests == 0 && secondPaused.controller.preferences.records.isEmpty, "pause/generation changes during the second inspection block intent and request")
        let secondSleep = Fixture(base: base)
        secondSleep.inspection.configure(states: [.clean, .clean], holdAtCall: 2)
        try await secondSleep.qualify(heldCall: 2); secondSleep.controller.handleSleep(true)
        secondSleep.inspection.resume(); try await secondSleep.settle()
        try require(secondSleep.runtime.requests == 0 && secondSleep.controller.preferences.records.isEmpty, "sleep during the second inspection blocks intent and request")
        let secondSuspended = Fixture(base: base)
        secondSuspended.inspection.configure(states: [.clean, .clean], holdAtCall: 2)
        try await secondSuspended.qualify(heldCall: 2); secondSuspended.controller.setActionsSuspended(true)
        secondSuspended.inspection.resume(); try await secondSuspended.settle()
        try require(secondSuspended.runtime.requests == 0 && secondSuspended.controller.preferences.records.isEmpty, "suspension during the second inspection blocks intent and request")
        let secondBusy = Fixture(base: base)
        secondBusy.inspection.configure(states: [.clean, .clean], holdAtCall: 2)
        try await secondBusy.qualify(heldCall: 2); secondBusy.runtime.actionsAllowed = false
        secondBusy.inspection.resume(); try await secondBusy.settle()
        try require(secondBusy.runtime.requests == 0 && secondBusy.controller.preferences.records.isEmpty, "actual busy state blocks the second completion before async suspension")
        let secondFrontmost = Fixture(base: base)
        secondFrontmost.inspection.configure(states: [.clean, .clean], holdAtCall: 2)
        try await secondFrontmost.qualify(heldCall: 2); secondFrontmost.runtime.frontmost = true
        secondFrontmost.inspection.resume(); try await secondFrontmost.settle()
        try require(secondFrontmost.runtime.requests == 0 && secondFrontmost.controller.preferences.records.isEmpty, "frontmost revalidation after the second inspection blocks intent and request")
        let secondStale = Fixture(base: base)
        secondStale.inspection.configure(states: [.clean, .clean], holdAtCall: 2)
        try await secondStale.qualify(heldCall: 2)
        secondStale.runtime.date = secondStale.runtime.date.addingTimeInterval(13); secondStale.runtime.elapsed += 13
        secondStale.inspection.resume(); try await secondStale.settle()
        try require(secondStale.runtime.requests == 0 && secondStale.controller.preferences.records.isEmpty, "a stale original observation is not refreshed by the second AX result")
        let secondFile = Fixture(base: base)
        secondFile.inspection.configure(states: [.clean, .clean], holdAtCall: 2)
        try await secondFile.qualify(heldCall: 2)
        let secondForeign = Data("external second-inspection contents must survive".utf8)
        try secondForeign.write(to: secondFile.stateURL)
        secondFile.inspection.resume(); try await secondFile.settle()
        try require(secondFile.runtime.requests == 0 && !secondFile.controller.writable, "external state changes during the second inspection prevent quit")
        let secondBytes = try Data(contentsOf: secondFile.stateURL)
        try require(secondBytes == secondForeign, "second-inspection external bytes remain exact")
        print("PASS: second-inspection saved state, identity, generation, sleep, suspension, synchronous busy, staleness and durable intent guards")

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
