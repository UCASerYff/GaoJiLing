import Foundation

private enum SyntheticVolumeError: Error { case unavailable }

/// Every input is in-memory. These tests never enumerate actual mounted volumes.
private final class SyntheticVolumeProvider: LocalVolumeMetadataProviding, @unchecked Sendable {
    var urls: [URL] = []
    var flags: [String: LocalVolumeClassification] = [:]
    var values: [String: LocalVolumeDetails] = [:]
    var enumerationFails = false
    var classificationFailures = Set<String>()
    var detailFailures = Set<String>()
    var classificationAfterDetails: [String: LocalVolumeClassification] = [:]
    private(set) var enumerationCalls = 0
    private(set) var classificationCalls: [String] = []
    private(set) var detailCalls: [String] = []

    func mountedVolumeURLs() throws -> [URL] {
        enumerationCalls += 1
        if enumerationFails { throw SyntheticVolumeError.unavailable }
        return urls
    }
    func classification(for url: URL) throws -> LocalVolumeClassification {
        classificationCalls.append(url.path)
        if classificationFailures.contains(url.path) { throw SyntheticVolumeError.unavailable }
        if detailCalls.contains(url.path), let replacement = classificationAfterDetails[url.path] { return replacement }
        guard let result = flags[url.path] else { throw SyntheticVolumeError.unavailable }
        return result
    }
    func details(for url: URL) throws -> LocalVolumeDetails {
        detailCalls.append(url.path)
        if detailFailures.contains(url.path) { throw SyntheticVolumeError.unavailable }
        guard let result = values[url.path] else { throw SyntheticVolumeError.unavailable }
        return result
    }
}

private final class SyntheticVolumeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [TimeInterval]
    private var index = 0
    init(_ values: [TimeInterval]) { self.values = values }
    func next() -> TimeInterval {
        lock.lock(); defer { lock.unlock() }
        defer { index += 1 }
        return values[min(index, values.count - 1)]
    }
}

@main struct LocalVolumeMetadataTests {
    static func require(_ value: @autoclosure () -> Bool, _ detail: String) {
        if !value() { fputs("FAIL: \(detail)\n", stderr); exit(1) }
    }
    static let included = LocalVolumeClassification(isLocal: true, isInternal: true, isRemovable: false, isEjectable: false)
    static let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
    static func details(total: Int64? = 1000, available: Int64? = 400) -> LocalVolumeDetails {
        LocalVolumeDetails(name: "Synthetic internal volume", uuid: "synthetic-uuid",
            formatDescription: "Synthetic APFS description", isReadOnly: true,
            totalBytes: total, availableBytes: available,
            capabilities: [LocalVolumeCapability(id: "hardLinks", name: "硬链接", supported: true)])
    }
    private static func collector(_ provider: SyntheticVolumeProvider, maximumVolumes: Int = 128,
                          timeBudget: TimeInterval = 3,
                          clock: @escaping @Sendable () -> TimeInterval = { 0 }) -> LocalVolumeMetadataCollector {
        LocalVolumeMetadataCollector(provider: provider, maximumVolumes: maximumVolumes,
                                     timeBudget: timeBudget, clock: clock, now: { fixedDate })
    }

    static func main() throws {
        let provider = SyntheticVolumeProvider()
        provider.urls = [URL(fileURLWithPath: "/Synthetic/Internal"),
                         URL(fileURLWithPath: "/Synthetic/External"),
                         URL(fileURLWithPath: "/Synthetic/Network"),
                         URL(fileURLWithPath: "/Synthetic/Unknown"),
                         URL(fileURLWithPath: "/Synthetic/Removable"),
                         URL(fileURLWithPath: "/Synthetic/Ejectable")]
        provider.flags = [
            "/Synthetic/Internal": included,
            "/Synthetic/External": .init(isLocal: true, isInternal: false, isRemovable: false, isEjectable: false),
            "/Synthetic/Network": .init(isLocal: false, isInternal: nil, isRemovable: nil, isEjectable: nil),
            "/Synthetic/Unknown": .init(isLocal: true, isInternal: true, isRemovable: nil, isEjectable: false),
            "/Synthetic/Removable": .init(isLocal: true, isInternal: true, isRemovable: true, isEjectable: false),
            "/Synthetic/Ejectable": .init(isLocal: true, isInternal: true, isRemovable: false, isEjectable: true)
        ]
        provider.values["/Synthetic/Internal"] = details()
        let result = collector(provider).snapshot()
        require(provider.detailCalls == ["/Synthetic/Internal"], "excluded/unknown/network mounts never request capacity or capabilities")
        require(result.volumes.count == 1 && result.volumes[0].totalBytes == 1000 && result.volumes[0].availableBytes == 400,
                "confirmed real provider values are retained, not demonstration values")
        require(result.skippedExternalOrRemovableCount == 3 && result.skippedNetworkCount == 1 && result.skippedUnknownCount == 1,
                "exclusions have distinct truthful reason counts")
        require(!result.complete && !result.cancelled && result.capturedAt == fixedDate, "unknown classification gives partial bounded metadata")
        require(!result.notes.joined().contains("/Synthetic/External") && !result.notes.joined().contains("/Synthetic/Network"),
                "excluded hardware/network paths are not included in report notes")
        print("PASS: internal-only two-stage query, no excluded capacity access, unknown classifications and sources")

        let optional = SyntheticVolumeProvider()
        optional.urls = [URL(fileURLWithPath: "/Synthetic/UnknownValues")]
        optional.flags["/Synthetic/UnknownValues"] = included
        optional.values["/Synthetic/UnknownValues"] = .init(name: nil, uuid: nil, formatDescription: nil,
            isReadOnly: nil, totalBytes: nil, availableBytes: nil,
            capabilities: [.init(id: "cloning", name: "克隆", supported: nil)])
        let unknown = collector(optional).snapshot()
        require(unknown.volumes.count == 1, "known internal volume with unavailable fields is represented")
        let row = unknown.volumes[0]
        require(row.totalBytes == nil && row.availableBytes == nil && row.isReadOnly == nil && row.capabilities[0].supported == nil,
                "unprovided values remain nil rather than zero or false")
        require(row.unavailableFields.count == 7 && !unknown.complete, "each unknown field carries explicit unavailable label")
        let data = try JSONEncoder().encode(unknown)
        let decoded = try JSONDecoder().decode(LocalVolumeMetadataSnapshot.self, from: data)
        require(decoded.volumes == unknown.volumes && decoded.capturedAt == fixedDate, "actual metadata report roundtrips optional values")
        print("PASS: nil semantics, unavailable labels and Codable report")

        for (total, available, validTotal, validAvailable) in [
            (Int64(1000), Int64(0), true, true),
            (Int64(0), Int64(400), false, true),
            (Int64(-1), Int64(-2), false, false),
            (Int64(1000), Int64(1001), true, false)
        ] {
            let p = SyntheticVolumeProvider();p.urls = [URL(fileURLWithPath: "/Synthetic/Capacity")]
            p.flags["/Synthetic/Capacity"] = included;p.values["/Synthetic/Capacity"] = details(total: total, available: available)
            let current = collector(p).snapshot().volumes[0]
            require((current.totalBytes != nil) == validTotal && (current.availableBytes != nil) == validAvailable,
                    "reject invalid capacity combinations without fabricating zero")
            if available == 0 { require(current.availableBytes == 0, "real zero available is valid and distinct from unavailable") }
        }
        print("PASS: capacity invariants, valid real zero and invalid-value refusal")

        let missing = SyntheticVolumeProvider();missing.enumerationFails = true
        let missingResult = collector(missing).snapshot()
        require(!missingResult.complete && missingResult.volumes.isEmpty && !missingResult.notes.isEmpty,
                "enumeration failure is partial, not empty success")
        let empty = SyntheticVolumeProvider()
        require(!collector(empty).snapshot().complete, "empty system response is not positive proof of no volumes")
        let unreadable = SyntheticVolumeProvider();unreadable.urls = [URL(fileURLWithPath: "/Synthetic/Permission")]
        unreadable.flags["/Synthetic/Permission"] = included;unreadable.detailFailures.insert("/Synthetic/Permission")
        let denied = collector(unreadable).snapshot()
        require(!denied.complete && denied.volumes.isEmpty && denied.skippedUnknownCount == 1,
                "permission/read error is partial and does not create a zero-capacity volume")
        let unclassified = SyntheticVolumeProvider();unclassified.urls = unreadable.urls
        unclassified.classificationFailures.insert("/Synthetic/Permission")
        let flagDenied = collector(unclassified).snapshot()
        require(unclassified.detailCalls.isEmpty && flagDenied.skippedUnknownCount == 1 && !flagDenied.complete,
                "classification error stops before capacity query")
        print("PASS: missing list, empty list, classification and detail failures")

        let changed = SyntheticVolumeProvider();changed.urls = [URL(fileURLWithPath: "/Synthetic/Changed")]
        changed.flags["/Synthetic/Changed"] = included;changed.values["/Synthetic/Changed"] = details()
        changed.classificationAfterDetails["/Synthetic/Changed"] = .init(isLocal: true, isInternal: false, isRemovable: false, isEjectable: true)
        let invalidated = collector(changed).snapshot()
        require(invalidated.volumes.isEmpty && !invalidated.complete && invalidated.skippedUnknownCount == 1,
                "mount classification change invalidates already-read row instead of reporting stale result")

        let bounded = SyntheticVolumeProvider()
        bounded.urls = (0..<4).map { URL(fileURLWithPath: "/Synthetic/Volume\($0)") }
        for url in bounded.urls { bounded.flags[url.path] = included;bounded.values[url.path] = details() }
        let limited = collector(bounded, maximumVolumes: 2).snapshot()
        require(limited.volumes.count == 2 && bounded.detailCalls.count == 2 && !limited.complete,
                "volume budget bounds classification and detail work")
        let noWork = SyntheticVolumeProvider()
        let cancelled = collector(noWork).snapshot(cancelled: { true })
        require(cancelled.cancelled && !cancelled.complete && noWork.enumerationCalls == 0,
                "already cancelled request does not enumerate mounts")
        let timed = SyntheticVolumeProvider()
        let noTime = collector(timed, timeBudget: 0).snapshot()
        require(!noTime.complete && !noTime.cancelled && timed.enumerationCalls == 0,
                "zero soft time budget does not start system lookup")
        let backwards = SyntheticVolumeClock([10, 9])
        let invalidClock = collector(SyntheticVolumeProvider(), clock: { backwards.next() }).snapshot()
        require(!invalidClock.complete, "invalid/nonmonotonic test clock fails bounded observation")
        print("PASS: mount-change invalidation, count/time/cancel budgets")

        let finalExternal = SyntheticVolumeProvider();finalExternal.urls = [URL(fileURLWithPath: "/Synthetic/External")]
        finalExternal.flags["/Synthetic/External"] = .init(isLocal: true, isInternal: false, isRemovable: true, isEjectable: true)
        let slowFinal = SyntheticVolumeClock([0, 0, 0, 4])
        let overTime = collector(finalExternal, clock: { slowFinal.next() }).snapshot()
        require(!overTime.complete && finalExternal.detailCalls.isEmpty,
                "late final excluded classification still triggers soft deadline")
        let duplicates = SyntheticVolumeProvider();duplicates.urls = [URL(fileURLWithPath: "/Synthetic/A"), URL(fileURLWithPath: "/Synthetic/A")]
        duplicates.flags["/Synthetic/A"] = included;duplicates.values["/Synthetic/A"] = details()
        let deduped = collector(duplicates).snapshot()
        require(deduped.complete && deduped.volumes.count == 1 && duplicates.detailCalls.count == 1,
                "same mount path returned twice queried once, not duplicate capacity")
        let remote = SyntheticVolumeProvider();remote.urls = [URL(string: "file://remote.invalid/Synthetic/Remote")!]
        let remoteResult = collector(remote).snapshot()
        require(remote.classificationCalls.isEmpty && remote.detailCalls.isEmpty && !remoteResult.complete,
                "nonlocal file URL refused before provider query")
        print("PASS: late deadline, duplicate paths and nonlocal URL refusal")
        print("Local volume metadata tests use synthetic providers only; no actual mounted-volume or hardware queries.")
    }
}
