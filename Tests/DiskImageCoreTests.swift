import Foundation
import Darwin
import CryptoKit

// Original, deliberately minimal synthetic bytes. This is not a Windows-formatted
// filesystem and must never be mounted or described as one. No third-party image
// or Windows files are included. It exercises the parser's chosen structures only.
enum SyntheticDiskImage {
    static let sourceNote = "原创最小合成结构；不构成完整 Windows 格式化卷；禁止挂载或写入真实设备"
    static let mftOffset = 4 * 512
    static let recordBytes = 1024

    static func put<T: FixedWidthInteger>(_ value: T, at offset: Int, into bytes: inout [UInt8]) {
        for index in 0..<MemoryLayout<T>.size { bytes[offset + index] = UInt8(truncatingIfNeeded: value >> (index * 8)) }
    }
    static func text(_ value: String) -> [UInt8] {
        value.utf16.flatMap { [UInt8(truncatingIfNeeded: $0), UInt8(truncatingIfNeeded: $0 >> 8)] }
    }
    static func resident(type: UInt32, id: UInt16, value: [UInt8], name: String = "") -> [UInt8] {
        let nameBytes = text(name)
        let valueOffset = (24 + nameBytes.count + 7) & ~7
        let length = (valueOffset + value.count + 7) & ~7
        var attr = [UInt8](repeating: 0, count: length)
        put(type, at: 0, into: &attr)
        put(UInt32(length), at: 4, into: &attr)
        attr[9] = UInt8(nameBytes.count / 2)
        put(UInt16(24), at: 10, into: &attr)
        put(id, at: 14, into: &attr)
        put(UInt32(value.count), at: 16, into: &attr)
        put(UInt16(valueOffset), at: 20, into: &attr)
        attr.replaceSubrange(24..<(24 + nameBytes.count), with: nameBytes)
        attr.replaceSubrange(valueOffset..<(valueOffset + value.count), with: value)
        return attr
    }
    static func standard(id: UInt16 = 0, flags: UInt32 = 0) -> [UInt8] {
        var value = [UInt8](repeating: 0, count: 72)
        put(flags, at: 32, into: &value)
        return resident(type: 0x10, id: id, value: value)
    }
    static func filename(_ name: String, id: UInt16 = 1, parent: UInt64 = 5,
        flags: UInt32 = 0, namespace: UInt8 = 1) -> [UInt8] {
        let nameBytes = text(name)
        var value = [UInt8](repeating: 0, count: 66 + nameBytes.count)
        put(parent | (UInt64(1) << 48), at: 0, into: &value)
        put(flags, at: 56, into: &value)
        value[64] = UInt8(nameBytes.count / 2)
        value[65] = namespace
        value.replaceSubrange(66..<value.count, with: nameBytes)
        return resident(type: 0x30, id: id, value: value)
    }
    static func mftData(runlist: [UInt8] = [0x11, 16, 4, 0]) -> [UInt8] {
        var attr = [UInt8](repeating: 0, count: 88)
        put(UInt32(0x80), at: 0, into: &attr)
        put(UInt32(attr.count), at: 4, into: &attr)
        attr[8] = 1
        put(UInt16(2), at: 14, into: &attr)
        put(UInt64(15), at: 24, into: &attr)
        put(UInt16(64), at: 32, into: &attr)
        put(UInt64(8192), at: 40, into: &attr)
        put(UInt64(8192), at: 48, into: &attr)
        put(UInt64(8192), at: 56, into: &attr)
        attr.replaceSubrange(64..<(64 + runlist.count), with: runlist)
        return attr
    }
    static func record(_ id: UInt32, directory: Bool = false, links: UInt16 = 1,
        attrs: [[UInt8]], recordSize: Int = recordBytes) -> [UInt8] {
        var result = [UInt8](repeating: 0, count: recordSize)
        let usaCount = recordSize / 512 + 1
        let attrStart = (48 + usaCount * 2 + 7) & ~7
        result.replaceSubrange(0..<4, with: Array("FILE".utf8))
        put(UInt16(48), at: 4, into: &result)
        put(UInt16(usaCount), at: 6, into: &result)
        put(UInt16(1), at: 16, into: &result)
        put(links, at: 18, into: &result)
        put(UInt16(attrStart), at: 20, into: &result)
        put(UInt16(directory ? 3 : 1), at: 22, into: &result)
        put(UInt32(recordSize), at: 28, into: &result)
        put(id, at: 44, into: &result)
        var position = attrStart
        for attr in attrs {
            precondition(position + attr.count + 8 < recordSize)
            result.replaceSubrange(position..<(position + attr.count), with: attr)
            position += attr.count
        }
        put(UInt32(0xFFFFFFFF), at: position, into: &result)
        put(UInt32(position + 8), at: 24, into: &result)
        put(UInt16(0xA55A), at: 48, into: &result)
        for sector in 1..<usaCount {
            let trailer = sector * 512 - 2
            result[48 + sector * 2] = result[trailer]
            result[49 + sector * 2] = result[trailer + 1]
            put(UInt16(0xA55A), at: trailer, into: &result)
        }
        return result
    }
    static func make(mftRuns: [UInt8] = [0x11, 16, 4, 0]) -> [UInt8] {
        var result = [UInt8](repeating: 0, count: 128 * 512)
        result[0] = 0xEB; result[1] = 0x52; result[2] = 0x90
        result.replaceSubrange(3..<11, with: Array("NTFS    ".utf8))
        put(UInt16(512), at: 11, into: &result)
        result[13] = 1
        put(UInt64(128), at: 40, into: &result)
        put(UInt64(4), at: 48, into: &result)
        put(UInt64(24), at: 56, into: &result)
        result[64] = 0xF6; result[68] = 0xF4
        put(UInt16(0xAA55), at: 510, into: &result)
        func place(_ id: Int, _ record: [UInt8]) {
            let position = mftOffset + id * recordBytes
            result.replaceSubrange(position..<(position + recordBytes), with: record)
        }
        place(0, record(0, attrs: [standard(), filename("$MFT"), mftData(runlist: mftRuns)]))
        var volume = [UInt8](repeating: 0, count: 12)
        volume[8] = 3; volume[9] = 1
        place(3, record(3, attrs: [standard(), filename("$Volume"), resident(type: 0x70, id: 2, value: volume)]))
        place(5, record(5, directory: true, attrs: [standard(), filename(".")]))
        place(6, record(6, links: 2, attrs: [standard(), filename("示例.txt"),
            filename("另一个名称.txt", id: 2, parent: 7),
            resident(type: 0x80, id: 3, value: Array("example".utf8)),
            resident(type: 0x80, id: 4, value: Array("audit".utf8), name: "审计")]))
        place(7, record(7, directory: true, attrs: [standard(), filename("研究")]))
        return result
    }
    static func replaceRecord(_ id: Int, with record: [UInt8], in image: inout [UInt8]) {
        let position = mftOffset + id * recordBytes
        image.replaceSubrange(position..<(position + recordBytes), with: record)
    }
    static func larger(recordSize: Int, slots: Int, manyNames: Bool) -> [UInt8] {
        var image = [UInt8](repeating: 0, count: 2 << 20)
        image.replaceSubrange(0..<512, with: make()[0..<512])
        put(UInt64(image.count / 512), at: 40, into: &image)
        image[64] = UInt8(bitPattern: Int8(-Int(log2(Double(recordSize)))))
        let mftBytes = UInt64(recordSize * slots)
        let clusterCount = mftBytes / 512
        var data = mftData(runlist: [0x12, UInt8(truncatingIfNeeded: clusterCount),
            UInt8(truncatingIfNeeded: clusterCount >> 8), 4, 0])
        put(clusterCount - 1, at: 24, into: &data)
        put(mftBytes, at: 40, into: &data)
        put(mftBytes, at: 48, into: &data)
        put(mftBytes, at: 56, into: &data)
        func place(_ id: Int, attrs: [[UInt8]], directory: Bool = false, links: UInt16 = 1) {
            let bytes = record(UInt32(id), directory: directory, links: links, attrs: attrs, recordSize: recordSize)
            let start = mftOffset + id * recordSize
            image.replaceSubrange(start..<(start + recordSize), with: bytes)
        }
        place(0, attrs: [standard(), filename("$MFT"), data])
        place(5, attrs: [standard(), filename(".")], directory: true)
        if manyNames {
            for id in 6..<slots {
                var attrs = [standard()]
                for link in 0..<13 {
                    let name = String(repeating: "研", count: 252) + String(format: "%03d", link)
                    attrs.append(filename(name, id: UInt16(link + 1)))
                }
                place(id, attrs: attrs, links: 13)
            }
        }
        return image
    }
}


private struct DiskImageTestFailure: Error { let description: String }
private final class DiskImageCallback: @unchecked Sendable {
    let lock = NSLock()
    var acted = false
    let body: () -> Bool
    init(_ body: @escaping () -> Bool) { self.body = body }
    func call() -> Bool { lock.lock(); defer { lock.unlock() }; return body() }
}


@main struct DiskImageCoreTests {
    static func main() throws {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: "/private/tmp/GaoJiLingDiskImageTests-\(UUID().uuidString).noindex", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: root) }
        var checks = 0
        func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
            guard try condition() else { throw DiskImageTestFailure(description: message) }; checks += 1
        }
        func write(_ data: [UInt8], _ name: String) throws -> URL {
            let u = root.appendingPathComponent(name)
            try Data(data).write(to: u, options: .withoutOverwriting); return u
        }
        func sha(_ u: URL) throws -> String {
            SHA256.hash(data: try Data(contentsOf: u)).map { String(format: "%02x", $0) }.joined()
        }
        func image(name: String = "plain.txt", contents: [UInt8] = Array("resident-data".utf8), parent: UInt64 = 7) -> [UInt8] {
            var bytes = SyntheticDiskImage.make()
            SyntheticDiskImage.replaceRecord(6, with: SyntheticDiskImage.record(6, attrs: [SyntheticDiskImage.standard(),
                SyntheticDiskImage.filename(name, parent: parent), SyntheticDiskImage.resident(type: 0x80, id: 2, value: contents)]), in: &bytes)
            return bytes
        }
        func reject(_ bytes: [UInt8], _ name: String) throws {
            let url = try write(bytes, name + ".img"), before = try sha(url)
            var caught = false
            do { _ = try DiskImageAnalyzer.analyze(url: url) } catch { caught = true }
            try expect(caught, "\(name) must reject")
            try expect(try sha(url) == before, "\(name) source mutation")
        }
        let source = try write(image(), "ordinary.img"), before = try sha(source)
        let report = try DiskImageAnalyzer.analyze(url: source)
        try expect(report.status == "partial" && !report.directoryInventoryComplete, "no invented complete inventory")
        try expect(report.entries.count == 5 && report.examinedRecordSlots == 8, "MFT real prefix rows")
        let file = try unwrap(report.entries.first { $0.recordNumber == 6 })
        try expect(file.pathComponents == ["研究", "plain.txt"] && file.parentID == "7:1", "sequence-checked directory path")
        try expect(report.children(of: "7:1").map(\.id) == ["6:1"], "real directory children")
        try expect(file.logicalBytes == 13 && file.canExtract, "resident length/support")
        try expect(report.search("研究").contains { $0.id == file.id } && report.search("PLAIN").count == 1, "search report names/path")
        try expect(report.sourceSHA256 == before && report.sourceUnchanged, "source digest")
        let json = try report.jsonData(), decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(DiskImageAnalysis.self, from: json)
        try expect(decoded.entries == report.entries && decoded.sourceIdentity == report.sourceIdentity, "Codable report roundtrip")
        let out = root.appendingPathComponent("copied.txt")
        let receipt = try DiskImageAnalyzer.extract(url: source, entryID: file.id, from: report, to: out)
        try expect(try Data(contentsOf: out) == Data("resident-data".utf8), "resident extraction bytes")
        try expect(receipt.extractedBytes == 13 && receipt.extractedSHA256 == sha(out), "extraction receipt real hash")
        try expect(try sha(source) == before, "source unchanged by extraction")
        var caught = false
        do { _ = try DiskImageAnalyzer.extract(url: source, entryID: file.id, from: report, to: out) } catch { caught = true }
        try expect(caught && (try Data(contentsOf: out)) == Data("resident-data".utf8), "existing destination never overwritten")
        let parentLink = root.appendingPathComponent("dir-link")
        try fm.createSymbolicLink(at: parentLink, withDestinationURL: root)
        caught = false
        do { _ = try DiskImageAnalyzer.extract(url: source, entryID: file.id, from: report, to: parentLink.appendingPathComponent("escape.txt")) } catch { caught = true }
        try expect(caught && !fm.fileExists(atPath: root.appendingPathComponent("escape.txt").path), "destination ancestor link refused")

        let zero = try write(image(contents: []), "zero.img"), zeroReport = try DiskImageAnalyzer.analyze(url: zero)
        let zeroEntry = try unwrap(zeroReport.entries.first { $0.recordNumber == 6 })
        let zeroOut = root.appendingPathComponent("zero.txt")
        let zeroReceipt = try DiskImageAnalyzer.extract(url: zero, entryID: zeroEntry.id, from: zeroReport, to: zeroOut)
        try expect(zeroEntry.logicalBytes == 0 && zeroReceipt.extractedBytes == 0 && (try Data(contentsOf: zeroOut)).isEmpty, "real zero resident stream supported")
        let ads = try write(SyntheticDiskImage.make(), "ads.img"), adsReport = try DiskImageAnalyzer.analyze(url: ads)
        let adsEntry = try unwrap(adsReport.entries.first { $0.recordNumber == 6 })
        try expect(!adsEntry.canExtract && adsEntry.flags.contains("ADS"), "ADS explicitly unavailable")
        let orphan = try write(image(parent: 30), "orphan.img"), orphanReport = try DiskImageAnalyzer.analyze(url: orphan)
        let orphanEntry = try unwrap(orphanReport.entries.first { $0.recordNumber == 6 })
        try expect(orphanEntry.pathComponents == nil && orphanEntry.parentID == nil && !orphanEntry.canExtract, "missing parent never attached to root")
        let formula = try write(image(name: "=SUM(1,2).txt"), "formula.img"), formulaReport = try DiskImageAnalyzer.analyze(url: formula)
        try expect(String(decoding: formulaReport.csvData(), as: UTF8.self).contains("\"'=SUM(1,2).txt\""), "CSV names cannot become spreadsheet formulas")

        var nonresident = image()
        var data = SyntheticDiskImage.mftData(runlist: [0x11, 2, 48, 0])
        SyntheticDiskImage.put(UInt64(1), at: 24, into: &data)
        SyntheticDiskImage.put(UInt64(1024), at: 40, into: &data)
        SyntheticDiskImage.put(UInt64(700), at: 48, into: &data)
        SyntheticDiskImage.put(UInt64(700), at: 56, into: &data)
        SyntheticDiskImage.replaceRecord(6, with: SyntheticDiskImage.record(6, attrs: [SyntheticDiskImage.standard(),
            SyntheticDiskImage.filename("nonresident.bin", parent: 7), data]), in: &nonresident)
        let pattern = (0..<700).map { UInt8(truncatingIfNeeded: $0) }
        nonresident.replaceSubrange((48 * 512)..<(48 * 512 + pattern.count), with: pattern)
        let nr = try write(nonresident, "nonresident.img"), nrReport = try DiskImageAnalyzer.analyze(url: nr)
        let nrEntry = try unwrap(nrReport.entries.first { $0.recordNumber == 6 })
        let nrOut = root.appendingPathComponent("nonresident.bin")
        let nrReceipt = try DiskImageAnalyzer.extract(url: nr, entryID: nrEntry.id, from: nrReport, to: nrOut)
        try expect(try Data(contentsOf: nrOut) == Data(pattern) && nrReceipt.extractedBytes == 700, "runlist extraction does not export allocation padding")
        var limited = DiskImageBudget(); limited.maximumExtractionBytes = 100
        let limitedReport = try DiskImageAnalyzer.analyze(url: nr, budget: limited)
        try expect(limitedReport.entries.first { $0.id == nrEntry.id }?.canExtract == false, "configured extraction budget")
        var uninitialized = nonresident
        SyntheticDiskImage.put(UInt64(300), at: 56, into: &data)
        SyntheticDiskImage.replaceRecord(6, with: SyntheticDiskImage.record(6, attrs: [SyntheticDiskImage.standard(),
            SyntheticDiskImage.filename("nonresident.bin", parent: 7), data]), in: &uninitialized)
        let ui = try write(uninitialized, "uninitialized.img"), uiReport = try DiskImageAnalyzer.analyze(url: ui)
        let uiEntry = try unwrap(uiReport.entries.first { $0.recordNumber == 6 }); caught = false
        let uiOut = root.appendingPathComponent("uninitialized.bin")
        do { _ = try DiskImageAnalyzer.extract(url: ui, entryID: uiEntry.id, from: uiReport, to: uiOut) } catch { caught = true }
        try expect(caught && !uiEntry.canExtract && !fm.fileExists(atPath: uiOut.path), "uninitialized data shown unavailable, not filled with fake zeros")

        var compressed = nonresident
        SyntheticDiskImage.put(UInt16(1), at: 12, into: &data)
        SyntheticDiskImage.replaceRecord(6, with: SyntheticDiskImage.record(6, attrs: [SyntheticDiskImage.standard(flags: 0x800),
            SyntheticDiskImage.filename("compressed.bin", parent: 7), data]), in: &compressed)
        let compURL = try write(compressed, "compressed.img"), compReport = try DiskImageAnalyzer.analyze(url: compURL)
        let compEntry = try unwrap(compReport.entries.first { $0.recordNumber == 6 })
        try expect(compEntry.logicalBytes == nil && !compEntry.canExtract && compEntry.flags.contains("compressed"), "compressed metadata explicit unknown and unavailable")

        var budget = DiskImageBudget(); budget.maximumRecords = 6
        let partial = try DiskImageAnalyzer.analyze(url: source, budget: budget)
        try expect(partial.examinedRecordSlots == 6 && partial.entries.count == 3 && partial.warnings.contains { $0.contains("只检查前 6") }, "record budget real bounded partial")
        budget.maximumRecords = 0; caught = false
        do { _ = try DiskImageAnalyzer.analyze(url: source, budget: budget) } catch { caught = true }
        try expect(caught, "invalid budget not silently enlarged")
        caught = false
        do { _ = try DiskImageAnalyzer.analyze(url: source, cancelled: { true }) } catch NTFSAnalysisError.cancelled { caught = true }
        try expect(caught, "cancel before reads")
        let cancelOut = root.appendingPathComponent("cancelled.bin"); caught = false
        do { _ = try DiskImageAnalyzer.extract(url: source, entryID: file.id, from: report, to: cancelOut, cancelled: { true }) } catch { caught = true }
        try expect(caught && !fm.fileExists(atPath: cancelOut.path), "cancel creates no output")
        let changed = try write(image(contents: Array("changed".utf8)), "changed.img")
        let changedReport = try DiskImageAnalyzer.analyze(url: changed)
        let handle = try FileHandle(forWritingTo: changed); try handle.seek(toOffset: 600); try handle.write(contentsOf: Data([0x7f])); try handle.close()
        caught = false
        do { _ = try DiskImageAnalyzer.extract(url: changed, entryID: "6:1", from: changedReport, to: root.appendingPathComponent("changed.bin")) } catch NTFSAnalysisError.changed { caught = true }
        try expect(caught, "report-source identity rechecked at extraction")

        // These callbacks touch only this test's disposable directory and image.
        let midwayOut = root.appendingPathComponent("midway-cancel.txt")
        let midway = DiskImageCallback { (try? fm.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".GaoJiLing-extract-") }) == true }
        caught = false
        do { _ = try DiskImageAnalyzer.extract(url: source, entryID: file.id, from: report, to: midwayOut, cancelled: { midway.call() }) } catch NTFSAnalysisError.cancelled { caught = true }
        try expect(caught && !fm.fileExists(atPath: midwayOut.path), "cancellation after temporary creation cleans only own output")
        let racedOut = root.appendingPathComponent("raced-destination.txt")
        let raced = DiskImageCallback {
            if (try? fm.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".GaoJiLing-extract-") }) == true,
               !fm.fileExists(atPath: racedOut.path) { try? Data("existing-race".utf8).write(to: racedOut, options: .withoutOverwriting) }
            return false
        }
        caught = false
        do { _ = try DiskImageAnalyzer.extract(url: source, entryID: file.id, from: report, to: racedOut, cancelled: { raced.call() }) } catch { caught = true }
        try expect(caught && (try Data(contentsOf: racedOut)) == Data("existing-race".utf8), "publish-time destination race preserved")
        let switchedOut = root.appendingPathComponent("switched-after-link.txt")
        var didSwitch = false
        let switched = DiskImageCallback {
            if !didSwitch && fm.fileExists(atPath: switchedOut.path) {
                didSwitch = true
                try? fm.removeItem(at: switchedOut)
                try? Data("external-replacement".utf8).write(to: switchedOut, options: .withoutOverwriting)
            }
            return false
        }
        caught = false
        do { _ = try DiskImageAnalyzer.extract(url: source, entryID: file.id, from: report, to: switchedOut, cancelled: { switched.call() }) } catch { caught = true }
        try expect(didSwitch && caught && (try Data(contentsOf: switchedOut)) == Data("external-replacement".utf8), "final-name swap detected; replacement kept, never false extraction receipt")
        let tamperedOut = root.appendingPathComponent("tampered-after-link.txt")
        var didTamper = false
        let tampered = DiskImageCallback {
            if !didTamper && fm.fileExists(atPath: tamperedOut.path) {
                didTamper = true
                if let h = try? FileHandle(forWritingTo: tamperedOut) { try? h.write(contentsOf: Data("tampered-data".utf8)); try? h.close() }
            }
            return false
        }
        caught = false
        do { _ = try DiskImageAnalyzer.extract(url: source, entryID: file.id, from: report, to: tamperedOut, cancelled: { tampered.call() }) } catch { caught = true }
        try expect(didTamper && caught && !fm.fileExists(atPath: tamperedOut.path), "post-publication digest verifies actual output, own tampered result removed")
        let mutationURL = try write(image(), "mutation-during-analysis.img")
        let mutator = DiskImageCallback {
            if let h = try? FileHandle(forWritingTo: mutationURL) {
                try? h.seek(toOffset: 600); try? h.write(contentsOf: Data([0x42])); try? h.close()
            }
            return false
        }
        caught = false
        do { _ = try DiskImageAnalyzer.analyze(url: mutationURL, cancelled: { mutator.call() }) } catch NTFSAnalysisError.changed { caught = true }
        try expect(caught, "source changes during analysis invalidate report")
        let budgetURL = try write(image(), "read-budget.img")
        var readBudget = DiskImageBudget(); readBudget.maximumReadBytes = 512
        caught = false
        do { _ = try DiskImageAnalyzer.analyze(url: budgetURL, budget: readBudget) } catch NTFSAnalysisError.budget { caught = true }
        try expect(caught, "bounded read failure is explicit, not a fabricated empty report")
        var malformed = image(); malformed[510] = 0; try reject(malformed, "boot-signature")
        malformed = image(); malformed[SyntheticDiskImage.mftOffset + 510] = 0; try reject(malformed, "USA-fixup")
        malformed = SyntheticDiskImage.make(mftRuns: [0x11, 8, 4, 0x11, 8, 0, 0]); try reject(malformed, "overlap-runlist")
        malformed = SyntheticDiskImage.make(mftRuns: [0x01, 16, 0]); try reject(malformed, "sparse-MFT")
        malformed = image(); SyntheticDiskImage.replaceRecord(6, with: SyntheticDiskImage.record(6, attrs: [SyntheticDiskImage.standard(), SyntheticDiskImage.filename("../bad")]), in: &malformed); try reject(malformed, "path-traversal")
        malformed = image(); var wrong = SyntheticDiskImage.filename("wrong"); SyntheticDiskImage.put(UInt64(5) | (UInt64(9) << 48), at: 24, into: &wrong); SyntheticDiskImage.replaceRecord(6, with: SyntheticDiskImage.record(6, attrs: [SyntheticDiskImage.standard(), wrong]), in: &malformed); try reject(malformed, "parent-sequence")
        malformed = image(); SyntheticDiskImage.replaceRecord(5, with: SyntheticDiskImage.record(5, directory: true, attrs: [SyntheticDiskImage.standard(), SyntheticDiskImage.filename(".", parent: 7)]), in: &malformed); try reject(malformed, "parent-cycle")
        malformed = image(); malformed.replaceSubrange(3..<11, with: Array("-FVE-FS-".utf8))
        let bit = try write(malformed, "bitlocker.img"), bitReport = try DiskImageAnalyzer.analyze(url: bit)
        try expect(bitReport.format == "BitLocker" && bitReport.status == "unsupported" && bitReport.entries.isEmpty, "BitLocker recognized then stopped")
        let link = root.appendingPathComponent("image-link.img"); try fm.createSymbolicLink(at: link, withDestinationURL: source); caught = false
        do { _ = try DiskImageAnalyzer.analyze(url: link) } catch { caught = true }; try expect(caught, "source symlink refused")
        caught = false
        do { _ = try DiskImageAnalyzer.analyze(url: parentLink.appendingPathComponent(source.lastPathComponent)) } catch { caught = true }; try expect(caught, "source ancestor link refused")
        let hard = root.appendingPathComponent("hard.img"); try fm.linkItem(at: source, to: hard); caught = false
        do { _ = try DiskImageAnalyzer.analyze(url: hard) } catch { caught = true }; try expect(caught, "hardlinks refused"); try fm.removeItem(at: hard)
        caught = false
        do { _ = try DiskImageAnalyzer.analyze(url: URL(fileURLWithPath: "/dev/null")) } catch { caught = true }; try expect(caught, "device refused before reading")
        let fifo = root.appendingPathComponent("fifo.img"); try expect(Darwin.mkfifo(fifo.path, 0o600) == 0, "create synthetic FIFO"); caught = false
        do { _ = try DiskImageAnalyzer.analyze(url: fifo) } catch { caught = true }; try expect(caught, "FIFO refused without blocking")
        try expect(!fm.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".GaoJiLing-extract-") }, "no extraction temporary residue")
        try expect(try sha(source) == before, "source hash remains unchanged at end")
        print("PASS: \(checks) assertions; bounded MFT paths/search/report/resident+runlist extraction and failures. No app, device, mount or GUI.")
    }
    static func unwrap<T>(_ x: T?) throws -> T { guard let x else { throw DiskImageTestFailure(description: "missing expected entry") }; return x }
}
