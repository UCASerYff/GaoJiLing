import Foundation
import Darwin

// Native functions are linked by the production controllers but none belongs
// to these tests. Abort if injection ever accidentally reaches a real lookup,
// allocator operation or memory command prerequisite.
@_cdecl("gjl_application_running")
func gaBusinessForbiddenApplicationLookup(_ path: UnsafePointer<CChar>?, _ flags: Int32) -> Int32 { fatalError("Unexpected real process lookup") }
@_cdecl("gjl_development_tools_running")
func gaBusinessForbiddenDeveloperLookup() -> Int32 { fatalError("Unexpected real developer lookup") }
@_cdecl("gjl_memory_maintenance_snapshot")
func gaBusinessForbiddenMemorySnapshot(_ value: UnsafeMutablePointer<GJLMemoryMaintenance>?) -> Int32 { fatalError("Unexpected memory operation") }
@_cdecl("gjl_memory_maintenance_relief")
func gaBusinessForbiddenMemoryRelief() -> UInt64 { fatalError("Unexpected allocator operation") }

private struct BusinessFailure: Error, CustomStringConvertible { let description: String }
private func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !value() { throw BusinessFailure(description: message) }
}

private final class MoveBoundary: @unchecked Sendable {
    enum Mode { case normal, fail, pauseAfterFirst }
    private let lock = NSLock(), release = DispatchSemaphore(value: 0)
    private var calls = 0, stopped = false
    var mode = Mode.normal // Configured only while the controllers are idle.
    var callCount: Int { lock.lock(); defer { lock.unlock() }; return calls }
    var isPaused: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    func resume() { release.signal() }
    func trash(_ source: URL, home: URL) throws -> URL {
        guard source.path.hasPrefix(home.path + "/Library/Caches/.GaoJiLing-") else { throw BusinessFailure(description: "Fixture cannot move an unrelated path") }
        lock.lock(); calls += 1; let index = calls, configured = mode; lock.unlock()
        if configured == .fail { throw BusinessFailure(description: "Injected synthetic Trash failure") }
        let destination = home.appendingPathComponent(".Trash/" + source.lastPathComponent)
        try FileManager.default.moveItem(at: source, to: destination)
        if configured == .pauseAfterFirst && index == 1 {
            lock.lock(); stopped = true; lock.unlock()
            guard release.wait(timeout: .now() + 10) == .success else { throw BusinessFailure(description: "Fixture pause timed out") }
        }
        return destination
    }
}

@MainActor private final class BusinessFixture {
    let home: URL, data: URL, boundary = MoveBoundary()
    let cleanup: CleanupController, analysis: StorageAnalysisController, manager: AppManagementController
    var exchange: GAExchangeController
    var coordinator: GABusinessCoordinator!
    var externalBusy = false
    var navigations: [String] = []
    private var sequence = 100
    static let bundle = "com.example.gabusinessfixture"
    init() throws {
        home = try GAFixtures.temporaryRoot("ga-business")
        data = home.appendingPathComponent("Data")
        for relative in ["Data", "Applications", "Library/Caches", ".Trash", "Outgoing"] {
            try GAFixtures.privateDirectory(home.appendingPathComponent(relative))
        }
        let home = home, data = data, boundary = boundary, bundle = Self.bundle
        let cleanupEngine = CleanupEngine(home: home, journalDirectory: data.appendingPathComponent("Cleanup"),
            appIsRunning: { _ in false }, trash: { try boundary.trash($0, home: home) }, ownerLookup: { $0 == bundle || $0 == bundle + ".second" })
        cleanup = CleanupController(engine: cleanupEngine)
        analysis = StorageAnalysisController(dataDirectory: data)
        manager = AppManagementController(engine: UninstallEngine(home: home, journalDirectory: data.appendingPathComponent("Uninstall"),
            applicationRoots: [home.appendingPathComponent("Applications")], appIsRunning: { _ in false }, trash: { try boundary.trash($0, home: home) }))
        exchange = GAExchangeController(dataDirectory: data, clock: { GAFixtures.clock })
        bind()
        try check(exchange.writable, "Private exchange fixture must initialize")
    }
    func bind() {
        coordinator = GABusinessCoordinator(exchange: exchange, cleanup: cleanup, analysis: analysis, manager: manager,
            externallyBusy: { [weak self] in self?.externalBusy ?? true }, navigate: { [weak self] in self?.navigations.append($0) })
    }
    func restartExchange() {
        exchange.prepareForTermination()
        exchange = GAExchangeController(dataDirectory: data, clock: { GAFixtures.clock })
        bind()
    }
    func close() async {
        boundary.resume(); cleanup.cancel(); analysis.cancel(); manager.cancel(); exchange.prepareForTermination()
        try? await settle()
        try? FileManager.default.removeItem(at: home)
    }
    func settle() async throws {
        try await until("All private controllers must settle") { !self.exchange.isBusy && !self.cleanup.isBusy && !self.analysis.isBusy && !self.manager.isBusy }
    }
    func until(_ reason: String, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        try check(condition(), reason)
    }
    func scope(_ name: String, size: Int = 4096, linked: Bool = false) throws -> URL {
        let url = home.appendingPathComponent(name)
        try GAFixtures.put(Data(repeating: 7, count: size), at: url.appendingPathComponent("fixture.bin"))
        if linked { try FileManager.default.createSymbolicLink(at: url.appendingPathComponent("skipped-link"), withDestinationURL: url.appendingPathComponent("fixture.bin")) }
        return url
    }
    func cache(_ suffix: String = "") throws -> URL {
        let url = home.appendingPathComponent("Library/Caches/" + Self.bundle + suffix)
        let file = url.appendingPathComponent("cache.bin")
        try GAFixtures.put(Data(repeating: 5, count: 1024), at: file)
        let date = Date(timeIntervalSinceNow: -9 * 86400)
        for path in [file, url] { try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: path.path) }
        return url
    }
    func app() throws -> URL {
        let app = home.appendingPathComponent("Applications/Fixture.app")
        try GAFixtures.put(Data("Never execute this synthetic fixture".utf8), at: app.appendingPathComponent("Contents/MacOS/Fixture"))
        let info = ["CFBundleIdentifier": Self.bundle, "CFBundleName": "Fixture", "CFBundleShortVersionString": "1.0", "CFBundlePackageType": "APPL", "CFBundleExecutable": "Fixture"]
        try GAFixtures.put(try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0), at: app.appendingPathComponent("Contents/Info.plist"))
        return app
    }
    func request(_ action: String, reference: URL? = nil) async throws -> (String, URL) {
        sequence += 1
        var request = GAFixtures.request(sequence, action: action)
        if let reference {
            var ref = try GAFixtures.reference(reference, kind: action == "storage.inspect" ? "directory" : "application")
            ref.displayName = reference.lastPathComponent
            if ref.kind == "application" { ref.bundleID = Self.bundle }
            request.references = [ref]
        }
        let package = try GAFixtures.package(.init(name: "request-\(sequence)", manifest: request), in: home.appendingPathComponent("Outgoing"))
        exchange.receive(package); try await settle()
        try check(exchange.records.contains { $0.id == request.requestID }, "Fixture request must be received: \(exchange.status ?? "")")
        return (request.requestID, package)
    }
    func approve(_ id: String) async throws { exchange.approve(id); try await settle() }
    func record(_ id: String) throws -> GAInboxRecord {
        guard let value = exchange.records.first(where: { $0.id == id }) else { throw BusinessFailure(description: "Missing expected private inbox record") }
        return value
    }
    func breakLedger() throws { try GAFixtures.put(Data("changed by fixture".utf8), at: data.appendingPathComponent("Exchange/inbox.json")) }
    func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
    func selectedAppItems() throws -> (String, Set<String>) {
        guard let plan = manager.plan else { throw BusinessFailure(description: "No uninstall plan: \(manager.status)") }
        return (plan.id, Set(plan.items.filter(\.selectable).map(\.id)))
    }
}

@main struct GaoActionBusinessTests {
    @MainActor private static func run(_ name: String, _ body: (BusinessFixture) async throws -> Void) async throws {
        let f = try BusinessFixture()
        do { try await body(f); await f.close(); print("PASS: " + name) }
        catch { await f.close(); throw BusinessFailure(description: name + ": " + String(describing: error)) }
    }
    @MainActor static func main() async {
        do {
            try await run("storage approval runs the real analyzer and maps its operation and statistics", storage)
            try await run("cleanup re-review stays pending until a real receipt-backed move", cleanup)
            try await run("uninstall re-review and completed-request relaunch never replay movement", uninstall)
            try await run("busy and failed durable records block cleanup and uninstall execution", executionGates)
            try await run("cleanup cancellation, partial work and failure never claim completed", cleanupOutcomes)
            try await run("uninstall cancellation, partial work and failure never claim completed", uninstallOutcomes)
            try await run("storage cancellation, skipped entries and scan failure retain honest outcomes", storageOutcomes)
            try await run("storage completion starting another request cannot cross-wire results", storageCorrelation)
            try await run("relaunch of an executing request never replays its engine", interruptedRestart)
            try await run("application disappearing after approval reports failed review without moving files", failedReview)
            print("PASS: 10 GaoAction business integration groups; production coordinators/controllers/engines, synthetic private fixtures only")
        } catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
    }
    @MainActor private static func storage(_ f: BusinessFixture) async throws {
        let scope = try f.scope("first-scope")
        let (id, _) = try await f.request("storage.inspect", reference: scope)
        try check(try f.record(id).outcome == "pending" && f.analysis.operationID == nil, "Receive alone must not analyze")
        let callback = f.analysis.onScanCompleted
        var observed: UUID?
        f.analysis.onScanCompleted = { operation, result, completion in observed = operation; callback?(operation, result, completion) }
        try await f.approve(id)
        let record = try f.record(id)
        try check(record.phase == "finished" && record.outcome == "completed" && record.provenance["complete"] == .bool(true), "Only real complete analysis can complete the request")
        try check(observed != nil && observed == f.analysis.lastCompletedOperationID && f.analysis.result?.root == scope.path, "Completion token and result must belong to the selected scope")
        guard case .object(let statistics) = record.provenance["statistics"] else { throw BusinessFailure(description: "Missing actual storage statistics") }
        try check(statistics["allocatedBytes"] == .integer(f.analysis.result!.totalBytes), "Provenance must use actual engine bytes")
        try check(f.boundary.callCount == 0 && f.exists(scope), "Storage must never call a movement engine")
    }
    @MainActor private static func cleanup(_ f: BusinessFixture) async throws {
        let cache = try f.cache()
        let (id, _) = try await f.request("cleanup.review")
        try await f.approve(id)
        try check(f.cleanup.items.count == 1 && f.boundary.callCount == 0 && f.exists(cache), "Approval may only discover candidates")
        try await f.approve(id)
        try check(try f.record(id).outcome == "pending", "Re-review of the same request must not cancel itself")
        f.cleanup.trash(ids: Set(f.cleanup.items.map(\.id))); try await f.settle()
        let record = try f.record(id)
        try check(record.outcome == "completed" && !f.exists(cache), "Confirmed candidate must move via production cleanup engine")
        try check(record.provenance["receiptID"]?.text == f.cleanup.report?.batchID && f.cleanup.history.contains { $0.id == f.cleanup.report?.batchID }, "Cleanup result must name the durable actual receipt")
    }
    @MainActor private static func uninstall(_ f: BusinessFixture) async throws {
        let app = try f.app(), cache = try f.cache()
        let (id, package) = try await f.request("apps.uninstall.review", reference: app)
        try await f.approve(id)
        try check(f.boundary.callCount == 0 && f.exists(app), "Opening uninstall review is not execution")
        try await f.approve(id)
        try check(try f.record(id).outcome == "pending", "Same uninstall request cannot abandon itself")
        let (plan, selected) = try f.selectedAppItems()
        f.manager.execute(planID: plan, selectedIDs: selected); try await f.settle()
        try check(try f.record(id).outcome == "completed" && !f.exists(app) && !f.exists(cache), "Confirmed app and cache must move through the real transaction")
        try check(try f.record(id).provenance["receiptID"] == .string(plan) && f.manager.report?.batchID == plan && f.manager.history.first?.id == plan, "Inbox and engine history must agree on actual batch")
        let calls = f.boundary.callCount
        f.restartExchange(); f.exchange.receive(package); try await f.settle(); try await f.approve(id)
        try check(try f.record(id).outcome == "completed" && f.boundary.callCount == calls && f.manager.plan == nil, "Duplicate completed request after relaunch must only show original outcome")
    }
    @MainActor private static func executionGates(_ f: BusinessFixture) async throws {
        _ = try f.cache()
        let (cleanupID, _) = try await f.request("cleanup.review")
        f.externalBusy = true; try await f.approve(cleanupID)
        try check(try f.record(cleanupID).phase == "received" && f.cleanup.items.isEmpty, "Busy approval cannot launch a scan")
        f.externalBusy = false; try await f.approve(cleanupID)
        f.externalBusy = true; f.cleanup.trash(ids: Set(f.cleanup.items.map(\.id))); try await f.settle()
        try check(f.boundary.callCount == 0 && !f.exists(f.data.appendingPathComponent("Cleanup/journal.json")), "Busy gate cannot create a cleanup transaction")
        f.externalBusy = false; try f.breakLedger()
        f.cleanup.trash(ids: Set(f.cleanup.items.map(\.id))); try await f.settle()
        try check(!f.exchange.writable && f.boundary.callCount == 0, "A failed executing record must block destructive cleanup")

        try await run("uninstall durable execution gate fixture") { g in
            let app = try g.app(); let (id, _) = try await g.request("apps.uninstall.review", reference: app)
            try await g.approve(id); let (plan, selected) = try g.selectedAppItems()
            g.externalBusy = true; g.manager.execute(planID: plan, selectedIDs: selected); try await g.settle()
            try check(g.exists(app) && g.boundary.callCount == 0, "Busy gate blocks uninstall")
            g.externalBusy = false; try g.breakLedger(); g.manager.execute(planID: plan, selectedIDs: selected); try await g.settle()
            try check(!g.exchange.writable && g.exists(app) && !g.exists(g.data.appendingPathComponent("Uninstall.initialized")), "Failed durable handoff state blocks every uninstall side effect")
        }
    }
    @MainActor private static func cleanupOutcomes(_ unused: BusinessFixture) async throws {
        for expected in ["cancelled", "partial", "failed"] {
            try await run("cleanup " + expected) { f in
                let first = try f.cache(), second = try f.cache(".second")
                let (id, _) = try await f.request("cleanup.review"); try await f.approve(id)
                f.boundary.mode = expected == "failed" ? .fail : (expected == "partial" ? .pauseAfterFirst : .normal)
                f.cleanup.trash(ids: Set(f.cleanup.items.map(\.id)))
                if expected == "cancelled" { f.cleanup.cancel() }
                if expected == "partial" { try await f.until("First synthetic cache must pause after move") { f.boundary.isPaused }; f.cleanup.cancel(); f.boundary.resume() }
                try await f.settle()
                try check(try f.record(id).outcome == expected, "Actual cleanup outcome must be " + expected)
                if expected != "partial" { try check(f.exists(first) && f.exists(second), "Cancelled/failed cleanup preserves original fixtures") }
                else { try check(f.cleanup.report?.removedIDs.count == 1 && f.cleanup.report?.cancelled == true, "Partial cleanup contains one actual move and explicit cancellation") }
            }
        }
    }
    @MainActor private static func uninstallOutcomes(_ unused: BusinessFixture) async throws {
        for expected in ["cancelled", "partial", "failed"] {
            try await run("uninstall " + expected) { f in
                let app = try f.app(); _ = try f.cache()
                let (id, _) = try await f.request("apps.uninstall.review", reference: app); try await f.approve(id)
                f.boundary.mode = expected == "failed" ? .fail : (expected == "partial" ? .pauseAfterFirst : .normal)
                let (plan, selected) = try f.selectedAppItems(); f.manager.execute(planID: plan, selectedIDs: selected)
                if expected == "cancelled" { f.manager.cancel() }
                if expected == "partial" { try await f.until("First synthetic uninstall item must pause after move") { f.boundary.isPaused }; f.manager.cancel(); f.boundary.resume() }
                try await f.settle()
                try check(try f.record(id).outcome == expected && f.exists(app), "Actual uninstall outcome must be honest and retain unprocessed app")
                if expected == "partial" { try check(f.manager.report?.movedIDs.count == 1 && f.manager.report?.cancelled == true, "Partial uninstall keeps actual receipt and cancellation") }
            }
        }
    }
    @MainActor private static func storageOutcomes(_ unused: BusinessFixture) async throws {
        for expected in ["cancelled", "partial", "failed"] {
            try await run("storage " + expected) { f in
                let scope = try f.scope("scope", linked: expected == "partial")
                let (id, _) = try await f.request("storage.inspect", reference: scope)
                let approved = f.exchange.onApproved
                f.exchange.onApproved = { record, reference in
                    if expected == "failed" { try! FileManager.default.removeItem(at: scope) }
                    approved?(record, reference)
                    if expected == "cancelled" { f.analysis.cancel() }
                }
                try await f.approve(id)
                try check(try f.record(id).outcome == expected && f.record(id).provenance["complete"] == .bool(false), "Incomplete or failed storage may never report completed")
                try check(f.boundary.callCount == 0, "Analysis never moves fixture files")
            }
        }
    }
    @MainActor private static func storageCorrelation(_ f: BusinessFixture) async throws {
        let first = try f.scope("scope-one", size: 4096), second = try f.scope("scope-two", size: 65536)
        let (firstID, _) = try await f.request("storage.inspect", reference: first)
        let (secondID, _) = try await f.request("storage.inspect", reference: second)
        let business = f.analysis.onScanCompleted
        var callbacks: [(UUID, String?, Int64)] = [], stale: (UUID, StorageAnalysisResult?, StorageScanCompletion)?
        var secondLaunched = false, prematureOutcome: String?
        f.analysis.onScanCompleted = { id, value, completion in
            callbacks.append((id, value?.root, value?.totalBytes ?? -1)); business?(id, value, completion)
            if value?.root == first.path {
                stale = (id, value, completion)
                Task { @MainActor in secondLaunched = true; f.exchange.approve(secondID) }
            }
        }
        let approved = f.exchange.onApproved
        f.exchange.onApproved = { record, reference in
            approved?(record, reference)
            if record.id == secondID, let old = stale {
                business?(old.0, old.1, old.2)
                prematureOutcome = try? f.record(secondID).outcome
            }
        }
        f.exchange.approve(firstID)
        try await f.until("Completion must enqueue the next approved scan") { secondLaunched }
        try await f.settle()
        try check(callbacks.count == 2 && callbacks[0].0 != callbacks[1].0 && callbacks[0].1 == first.path && callbacks[1].1 == second.path, "Back-to-back scans must keep their own IDs and immutable result snapshots")
        try check(prematureOutcome == "pending", "A late callback from the previous scan cannot complete the new request")
        for (id, index) in [(firstID, 0), (secondID, 1)] {
            let record = try f.record(id)
            guard case .object(let statistics) = record.provenance["statistics"] else { throw BusinessFailure(description: "Missing scan statistics") }
            try check(record.outcome == "completed" && statistics["allocatedBytes"] == .integer(callbacks[index].2), "Each request must keep only its own actual statistics")
        }
    }
    @MainActor private static func interruptedRestart(_ f: BusinessFixture) async throws {
        let cache = try f.cache(); let (id, package) = try await f.request("cleanup.review")
        try await f.approve(id)
        try check(f.exchange.markExecuting(id), "Persist the same transition used immediately before a side effect")
        f.restartExchange(); f.exchange.receive(package); try await f.settle(); try await f.approve(id)
        try check(try f.record(id).phase == "interrupted" && f.record(id).outcome == "failed" && f.record(id).errorCode == "interrupted" && f.boundary.callCount == 0 && f.exists(cache), "An interrupted durable execution must not replay or invent completion after restart")
    }
    @MainActor private static func failedReview(_ f: BusinessFixture) async throws {
        let app = try f.app(), (id, _) = try await f.request("apps.uninstall.review", reference: app)
        let approved = f.exchange.onApproved
        f.exchange.onApproved = { record, reference in
            try! FileManager.default.removeItem(at: app)
            approved?(record, reference)
        }
        try await f.approve(id)
        try check(try f.record(id).outcome == "failed" && f.manager.plan == nil && f.boundary.callCount == 0,
                  "A failed asynchronous review must not remain awaitingUser or claim an uninstall")
    }
}
