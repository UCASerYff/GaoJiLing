import Foundation
import Darwin

@main struct GaoActionExchangeTests {
    static let completedCleanup: [String: GAValue] = ["workflowState": .string("completed"),
        "receiptID": .string("33333333-3333-4333-8333-000000000001"), "itemCount": .integer(1),
        "movedBytes": .integer(16), "skippedCount": .integer(0), "failedCount": .integer(0)]
    @MainActor static func idle(_ controller: GAExchangeController) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while controller.isBusy, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try GAFixtures.require(!controller.isBusy, "synthetic receive/approval did not settle within its test deadline")
        // onApproved runs synchronously after isBusy becomes false, on the same actor.
        await Task.yield()
    }
    static func ledger(_ directory: URL) -> URL { directory.appendingPathComponent("Exchange/inbox.json") }
    static func marker(_ directory: URL) -> URL { directory.appendingPathComponent("Exchange.initialized") }
    static func mutateJSON(_ url: URL, _ action: (inout [String: Any]) throws -> Void) throws {
        var object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        try action(&object)
        try GAFixtures.put(JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), at: url)
    }
    @MainActor static func run() async throws {
        let base = try GAFixtures.temporaryRoot("gaoaction-exchange")
        defer { try? FileManager.default.removeItem(at: base) }
        let sourceRoot = base.appendingPathComponent("Source", isDirectory: true)
        let scope = base.appendingPathComponent("Scope", isDirectory: true)
        try GAFixtures.privateDirectory(scope)
        let fixtures = try GAFixtures.all(scope: scope)
        let duplicate = try GAFixtures.package(fixtures[3], in: sourceRoot)
        let originalManifest = try Data(contentsOf: duplicate.appendingPathComponent("manifest.json"))
        var failures: [String] = []
        func dataDirectory(_ name: String) throws -> URL {
            let url = base.appendingPathComponent(name, isDirectory: true)
            try GAFixtures.privateDirectory(url); return url
        }
        func check(_ name: String, _ body: () async throws -> Void) async {
            do { try await body(); print("PASS: " + name) }
            catch { failures.append(name + ": " + String(describing: error)); print("FAIL: " + name + ": " + String(describing: error)) }
        }
        await check("fixed duplicate request, durable phases and no restart replay") {
            let data = try dataDirectory("Duplicate")
            let controller = GAExchangeController(dataDirectory: data, clock: { GAFixtures.clock })
            var approvals = 0, businessRuns = 0
            controller.onApproved = { record, resolved in
                approvals += 1
                if record.manifest.action != "cleanup.review" || resolved != nil { approvals += 100 }
            }
            controller.receive(duplicate); try await idle(controller)
            try GAFixtures.require(controller.records.count == 1 && controller.records[0].phase == "received" && approvals == 0,
                                  "receiving a package must not approve or execute")
            controller.receive(duplicate); try await idle(controller)
            try GAFixtures.require(controller.records.count == 1 && approvals == 0, "duplicate receive replayed approval")
            let id = GAFixtures.id(4)
            controller.approve(id); try await idle(controller)
            try GAFixtures.require(approvals == 1 && controller.records[0].phase == "approved", "approval phase is not durable")
            if controller.markExecuting(id) { businessRuns += 1 }
            try GAFixtures.require(businessRuns == 1 && controller.records[0].phase == "executing", "engine cannot begin before executing state persists")
            try GAFixtures.require(!controller.markExecuting(id), "an executing request was started twice")
            controller.outcome(id, status: "completed", provenance: completedCleanup)
            try GAFixtures.require(controller.records[0].phase == "finished" && controller.records[0].outcome == "completed", "completion missing")
            controller.receive(duplicate); try await idle(controller)
            controller.approve(id); try await idle(controller)
            try GAFixtures.require(approvals == 1 && businessRuns == 1 && controller.records.count == 1, "finished duplicate had side effects")
            let restarted = GAExchangeController(dataDirectory: data, clock: { GAFixtures.clock })
            restarted.onApproved = { _, _ in approvals += 1 }
            try GAFixtures.require(restarted.writable && restarted.records.first?.outcome == "completed", "restart lost durable completion")
            restarted.receive(duplicate); try await idle(restarted); restarted.approve(id); try await idle(restarted)
            try GAFixtures.require(approvals == 1 && !restarted.markExecuting(id), "restart replayed completed work")
            let sourceAfter = try Data(contentsOf: duplicate.appendingPathComponent("manifest.json"))
            try GAFixtures.require(sourceAfter == originalManifest, "original sender package changed")
        }
        await check("same request ID with different contents is rejected") {
            let data = try dataDirectory("DifferentBytes")
            let controller = GAExchangeController(dataDirectory: data, clock: { GAFixtures.clock })
            controller.receive(duplicate); try await idle(controller)
            let digest = controller.records[0].digest
            var changed = fixtures[3]; changed.manifest.nonce = Data(repeating: 1, count: 32).base64EncodedString()
            let package = try GAFixtures.package(changed, in: sourceRoot, name: "same-id-different-content")
            controller.receive(package); try await idle(controller)
            try GAFixtures.require(controller.records.count == 1 && controller.records[0].digest == digest && controller.status?.contains("内容不同") == true,
                                  "same-ID changed request replaced durable record")
        }
        await check("approved long job survives original envelope expiry") {
            let data = try dataDirectory("LongJob")
            var now = GAFixtures.clock
            let controller = GAExchangeController(dataDirectory: data, clock: { now })
            var approvals = 0; controller.onApproved = { _, _ in approvals += 1 }
            controller.receive(duplicate); try await idle(controller)
            now = now.addingTimeInterval(600)
            controller.approve(GAFixtures.id(4)); try await idle(controller)
            try GAFixtures.require(approvals == 1 && controller.markExecuting(GAFixtures.id(4)), "accepted request expired during local user review")
        }
        await check("real directory identity reaches approved business callback") {
            let package = try GAFixtures.package(fixtures[1], in: sourceRoot)
            let controller = GAExchangeController(dataDirectory: try dataDirectory("StorageReference"), clock: { GAFixtures.clock })
            var resolved: GAResolvedReference?
            controller.onApproved = { _, value in resolved = value }
            controller.receive(package); try await idle(controller)
            controller.approve(GAFixtures.id(2)); try await idle(controller)
            try GAFixtures.require(resolved?.url.path == scope.path && resolved?.identity.inode == fixtures[1].manifest.references[0].declaredIdentity?.inode && resolved?.ownerUID == getuid(),
                                  "approved callback lost locally verified identity")
        }
        await check("approval rejects index and staged manifest semantic mismatch") {
            let data = try dataDirectory("IndexMismatch")
            let controller = GAExchangeController(dataDirectory: data, clock: { GAFixtures.clock })
            controller.receive(duplicate); try await idle(controller)
            try mutateJSON(ledger(data)) { object in
                var records = object["records"] as! [[String: Any]]
                var manifest = records[0]["manifest"] as! [String: Any]
                manifest["sourceBundleID"] = "com.example.DifferentSource"
                records[0]["manifest"] = manifest; object["records"] = records
            }
            let altered = try Data(contentsOf: ledger(data))
            let restarted = GAExchangeController(dataDirectory: data, clock: { GAFixtures.clock })
            var approvals = 0; restarted.onApproved = { _, _ in approvals += 1 }
            restarted.approve(GAFixtures.id(4)); try await idle(restarted)
            let after = try Data(contentsOf: ledger(data))
            try GAFixtures.require(approvals == 0 && after == altered && restarted.status?.contains("不一致") == true,
                                  "ledger semantics were trusted instead of private staged manifest")
        }
        for missing in [false, true] {
            await check(missing ? "missing private stage cannot approve" : "modified private stage cannot approve") {
                let data = try dataDirectory(missing ? "MissingStage" : "ChangedStage")
                let controller = GAExchangeController(dataDirectory: data, clock: { GAFixtures.clock })
                var approvals = 0; controller.onApproved = { _, _ in approvals += 1 }
                controller.receive(duplicate); try await idle(controller)
                let staged = data.appendingPathComponent("Exchange/Incoming/" + controller.records[0].folder + "/manifest.json")
                if missing { try FileManager.default.removeItem(at: staged) }
                else { try GAFixtures.put(Data("changed stage".utf8), at: staged) }
                controller.approve(GAFixtures.id(4)); try await idle(controller)
                try GAFixtures.require(approvals == 0 && controller.records[0].phase == "received", "damaged stage approved work")
            }
        }
        for mode in ["external-change", "marker-missing", "inbox-missing"] {
            await check("markExecuting cannot start business after " + mode) {
                let data = try dataDirectory("Execute-" + mode)
                let controller = GAExchangeController(dataDirectory: data, clock: { GAFixtures.clock })
                controller.receive(duplicate); try await idle(controller)
                controller.approve(GAFixtures.id(4)); try await idle(controller)
                var external: Data?
                if mode == "external-change" {
                    external = Data("external bytes must survive".utf8); try GAFixtures.put(external!, at: ledger(data))
                } else { try FileManager.default.removeItem(at: mode == "marker-missing" ? marker(data) : ledger(data)) }
                var runs = 0
                if controller.markExecuting(GAFixtures.id(4)) { runs += 1 }
                try GAFixtures.require(runs == 0 && !controller.writable && controller.records[0].phase == "approved", "failed executing persistence started business")
                if let external { let after = try Data(contentsOf: ledger(data)); try GAFixtures.require(after == external, "external ledger was overwritten") }
                if mode == "inbox-missing" { try GAFixtures.require(!FileManager.default.fileExists(atPath: ledger(data).path), "missing inbox replaced with empty history") }
            }
        }
        for mode in ["bad-json", "future-schema", "unknown-phase", "oversized-ledger", "marker-corrupt", "inbox-missing", "exchange-folder-missing", "read-denied"] {
            await check("restart protects " + mode) {
                let data = try dataDirectory("Protect-" + mode)
                let initial = GAExchangeController(dataDirectory: data, clock: { GAFixtures.clock })
                initial.receive(duplicate); try await idle(initial)
                var retained: Data?
                switch mode {
                case "bad-json": retained = Data("{broken journal".utf8); try GAFixtures.put(retained!, at: ledger(data))
                case "future-schema":
                    try mutateJSON(ledger(data)) { $0["version"] = 2 }; retained = try Data(contentsOf: ledger(data))
                case "unknown-phase":
                    try mutateJSON(ledger(data)) { object in
                        var records = object["records"] as! [[String: Any]]; records[0]["phase"] = "future-phase"; object["records"] = records
                    }; retained = try Data(contentsOf: ledger(data))
                case "oversized-ledger":
                    retained = Data(repeating: 32, count: 16 * 1024 * 1024 + 1); try GAFixtures.put(retained!, at: ledger(data))
                case "marker-corrupt": try GAFixtures.put(Data("future marker\n".utf8), at: marker(data)); retained = try Data(contentsOf: ledger(data))
                case "inbox-missing": try FileManager.default.removeItem(at: ledger(data))
                case "exchange-folder-missing": try FileManager.default.removeItem(at: data.appendingPathComponent("Exchange"))
                case "read-denied":
                    try GAFixtures.require(geteuid() != 0, "permission fixture requires normal user")
                    retained = try Data(contentsOf: ledger(data)); try GAFixtures.require(chmod(ledger(data).path, 0) == 0, "restrict inbox")
                default: break
                }
                let restarted = GAExchangeController(dataDirectory: data, clock: { GAFixtures.clock })
                try GAFixtures.require(!restarted.writable && restarted.status != nil, "unreadable/future/missing journal treated as empty")
                if mode == "read-denied" { _ = chmod(ledger(data).path, 0o600) }
                restarted.receive(duplicate); try await idle(restarted)
                try GAFixtures.require(restarted.records.isEmpty && !restarted.writable, "restored access silently removed protection latch")
                if let retained { let after = try Data(contentsOf: ledger(data)); try GAFixtures.require(after == retained, "protected journal changed") }
                else { try GAFixtures.require(!FileManager.default.fileExists(atPath: ledger(data).path), "missing journal was recreated") }
            }
        }
        await check("valid pre-marker ledger migrates without rewriting bytes") {
            let data = try dataDirectory("LegacyMarker")
            let original = GAExchangeController(dataDirectory: data, clock: { GAFixtures.clock })
            original.receive(duplicate); try await idle(original)
            let bytes = try Data(contentsOf: ledger(data))
            try FileManager.default.removeItem(at: marker(data))
            let restarted = GAExchangeController(dataDirectory: data, clock: { GAFixtures.clock })
            let after = try Data(contentsOf: ledger(data))
            try GAFixtures.require(restarted.writable && restarted.records.count == 1 && bytes == after && FileManager.default.fileExists(atPath: marker(data).path),
                                  "legacy marker migration rewrote original state")
        }
        await check("cancelled and interrupted requests never auto execute after restart") {
            let cancelledData = try dataDirectory("Cancelled")
            let cancelled = GAExchangeController(dataDirectory: cancelledData, clock: { GAFixtures.clock })
            cancelled.receive(duplicate); try await idle(cancelled); cancelled.cancelReview(GAFixtures.id(4))
            let restarted = GAExchangeController(dataDirectory: cancelledData, clock: { GAFixtures.clock })
            var runs = 0; restarted.onApproved = { _, _ in runs += 1 }
            restarted.approve(GAFixtures.id(4)); try await idle(restarted)
            try GAFixtures.require(runs == 0 && restarted.records.first?.outcome == "cancelled", "cancelled request replayed")
            let interruptedData = try dataDirectory("Interrupted")
            let interrupted = GAExchangeController(dataDirectory: interruptedData, clock: { GAFixtures.clock })
            interrupted.receive(duplicate); try await idle(interrupted); interrupted.approve(GAFixtures.id(4)); try await idle(interrupted)
            try GAFixtures.require(interrupted.markExecuting(GAFixtures.id(4)), "prepare interrupted execution")
            let recovered = GAExchangeController(dataDirectory: interruptedData, clock: { GAFixtures.clock })
            try GAFixtures.require(recovered.records.first?.phase == "interrupted" && recovered.records.first?.outcome == "failed" &&
                                  recovered.records.first?.errorCode == "interrupted" && recovered.records.first?.provenance["receiptID"] == nil,
                                  "restart must persist uncertainty without inventing a receipt or claiming rollback")
            recovered.onApproved = { _, _ in runs += 1 }
            recovered.receive(duplicate); try await idle(recovered); recovered.approve(GAFixtures.id(4)); try await idle(recovered)
            try GAFixtures.require(runs == 0 && !recovered.markExecuting(GAFixtures.id(4)), "interrupted execution silently replayed")
        }
        await check("completed copy cleanup preserves idempotency, originals and result regeneration") {
            let data = try dataDirectory("CompletedCopies")
            let controller = GAExchangeController(dataDirectory: data, clock: { GAFixtures.clock })
            controller.receive(duplicate); try await idle(controller); controller.approve(GAFixtures.id(4)); try await idle(controller)
            try GAFixtures.require(controller.markExecuting(GAFixtures.id(4)), "start synthetic workflow")
            controller.outcome(GAFixtures.id(4), status: "completed", provenance: completedCleanup)
            let input = data.appendingPathComponent("Exchange/Incoming/" + controller.records[0].folder)
            let result = try controller.prepareResultPackage(GAFixtures.id(4))
            controller.cleanCompletedCopies(); try await idle(controller)
            try GAFixtures.require(!FileManager.default.fileExists(atPath: input.path) && !FileManager.default.fileExists(atPath: result.path), "completed private copies were not removed")
            try GAFixtures.require(controller.records.count == 1 && controller.records[0].outcome == "completed" && controller.records[0].incomingCopyRemoved == true && controller.records[0].resultFolders.isEmpty,
                                  "copy cleanup removed the durable result or replay protection")
            let sender = try Data(contentsOf: duplicate.appendingPathComponent("manifest.json"))
            try GAFixtures.require(sender == originalManifest, "sender package was modified")
            let restarted = GAExchangeController(dataDirectory: data, clock: { GAFixtures.clock })
            var replayed = false; restarted.onApproved = { _, _ in replayed = true }
            restarted.receive(duplicate); try await idle(restarted); restarted.approve(GAFixtures.id(4)); try await idle(restarted)
            try GAFixtures.require(!replayed && restarted.records.count == 1, "cleanup allowed completed replay after restart")
            let regenerated = try restarted.prepareResultPackage(GAFixtures.id(4))
            let exported = try GaoActionV1.validate(Data(contentsOf: regenerated.appendingPathComponent("manifest.json")), target: GAFixtures.source, now: GAFixtures.clock)
            try GAFixtures.require(exported.status == "completed" && exported.provenance == completedCleanup && exported.items.isEmpty && exported.references.isEmpty,
                                  "regenerated result lost its actual receipt or leaked a reference")
        }
        for preserved in ["pending", "failed", "partial", "interrupted"] {
            await check("cleanup keeps " + preserved + " inputs and result copies") {
                let data = try dataDirectory("Keep-" + preserved)
                var controller = GAExchangeController(dataDirectory: data, clock: { GAFixtures.clock })
                controller.receive(duplicate); try await idle(controller)
                controller.approve(GAFixtures.id(4)); try await idle(controller)
                try GAFixtures.require(controller.markExecuting(GAFixtures.id(4)), "start completed fixture")
                controller.outcome(GAFixtures.id(4), status: "completed", provenance: completedCleanup)
                var other = fixtures[3]; other.manifest.requestID = GAFixtures.id(70)
                let package = try GAFixtures.package(other, in: sourceRoot, name: "preserve-" + preserved)
                controller.receive(package); try await idle(controller)
                if preserved == "failed" { controller.outcome(GAFixtures.id(70), status: "failed", provenance: ["workflowState": .string("failed"), "reason": .string("Synthetic failure")]) }
                if preserved == "partial" || preserved == "interrupted" {
                    controller.approve(GAFixtures.id(70)); try await idle(controller)
                    try GAFixtures.require(controller.markExecuting(GAFixtures.id(70)), "start retained fixture")
                    if preserved == "partial" {
                        var partial = completedCleanup; partial["workflowState"] = .string("partial"); partial["skippedCount"] = .integer(1)
                        controller.outcome(GAFixtures.id(70), status: "partial", provenance: partial)
                    } else { controller = GAExchangeController(dataDirectory: data, clock: { GAFixtures.clock }) }
                }
                let retained = controller.records.first { $0.id == GAFixtures.id(70) }!
                let input = data.appendingPathComponent("Exchange/Incoming/" + retained.folder)
                let output = try controller.prepareResultPackage(retained.id)
                controller.cleanCompletedCopies(); try await idle(controller)
                try GAFixtures.require(FileManager.default.fileExists(atPath: input.path) && FileManager.default.fileExists(atPath: output.path), "non-completed recovery copy removed")
                try GAFixtures.require(controller.records.first { $0.id == retained.id }?.resultFolders.count == 1, "retained result index changed")
            }
        }
        for tamper in ["extra-payload", "symlink", "changed-manifest", "external-ledger"] {
            await check("completed cleanup refuses " + tamper) {
                let data = try dataDirectory("CleanupTamper-" + tamper)
                let controller = GAExchangeController(dataDirectory: data, clock: { GAFixtures.clock })
                controller.receive(duplicate); try await idle(controller); controller.approve(GAFixtures.id(4)); try await idle(controller)
                try GAFixtures.require(controller.markExecuting(GAFixtures.id(4)), "start cleanup safety fixture")
                controller.outcome(GAFixtures.id(4), status: "completed", provenance: completedCleanup)
                let input = data.appendingPathComponent("Exchange/Incoming/" + controller.records[0].folder)
                let external = data.appendingPathComponent("Unrelated"); try GAFixtures.put(GAFixtures.hello, at: external.appendingPathComponent("keep.txt"))
                if tamper == "extra-payload" { try GAFixtures.put(GAFixtures.hello, at: input.appendingPathComponent("payload/keep.txt")) }
                if tamper == "symlink" { try FileManager.default.removeItem(at: input.appendingPathComponent("payload")); try FileManager.default.createSymbolicLink(at: input.appendingPathComponent("payload"), withDestinationURL: external) }
                if tamper == "changed-manifest" { try GAFixtures.put(Data("changed".utf8), at: input.appendingPathComponent("manifest.json")) }
                if tamper == "external-ledger" { try GAFixtures.put(Data("external ledger".utf8), at: ledger(data)) }
                controller.cleanCompletedCopies(); try await idle(controller)
                let sentinel = try Data(contentsOf: external.appendingPathComponent("keep.txt"))
                try GAFixtures.require(FileManager.default.fileExists(atPath: input.path) && sentinel == GAFixtures.hello && controller.records[0].incomingCopyRemoved != true,
                                      "cleanup followed a link or discarded an unverified copy")
            }
        }
        await check("per-request result capacity is explicit and completed cleanup frees copies") {
            let data = try dataDirectory("ResultCapacity")
            let controller = GAExchangeController(dataDirectory: data, clock: { GAFixtures.clock })
            controller.receive(duplicate); try await idle(controller); controller.approve(GAFixtures.id(4)); try await idle(controller)
            try GAFixtures.require(controller.markExecuting(GAFixtures.id(4)), "start capacity fixture")
            controller.outcome(GAFixtures.id(4), status: "completed", provenance: completedCleanup)
            for _ in 0..<64 { _ = try controller.prepareResultPackage(GAFixtures.id(4)) }
            try GAFixtures.rejects("65th result copy") { _ = try controller.prepareResultPackage(GAFixtures.id(4)) }
            controller.cleanCompletedCopies(); try await idle(controller)
            try GAFixtures.require(controller.records.count == 1 && controller.privateCopyCount == 0, "cleanup did not retain ID or free verified copies")
            _ = try controller.prepareResultPackage(GAFixtures.id(4))
        }
        await check("global private-copy capacity retains unknown and unfinished copies") {
            let data = try dataDirectory("GlobalCapacity")
            let controller = GAExchangeController(dataDirectory: data, clock: { GAFixtures.clock })
            for index in 0..<GAExchangeController.privateCopyLimit {
                try GAFixtures.privateDirectory(data.appendingPathComponent("Exchange/Incoming/reserved-\(index).gaoaction"))
            }
            controller.receive(duplicate); try await idle(controller)
            try GAFixtures.require(controller.records.isEmpty && controller.privateCopyCount == GAExchangeController.privateCopyLimit && controller.status?.contains("1024") == true,
                                  "copy capacity silently removed unknown copies or staged an excess request")
        }
        guard failures.isEmpty else { throw GAFixtures.Failure(description: "\(failures.count) GaoAction exchange groups failed") }
        print("GaoAction exchange tests passed; synthetic fixtures removed. No real business engine, GUI or installed app was invoked.")
    }
    @MainActor static func main() async {
        do { try await run() }
        catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
    }
}
