import Foundation
import Darwin

/// Limits apply cooperatively between syscalls; they cannot interrupt a blocked filesystem call.
struct DiskImageBudget: Sendable {
    var maximumRecords: Int = 4096
    var maximumReadBytes: UInt64 = 64 << 20
    var maximumSeconds: TimeInterval = 10
    var maximumExtractionBytes: UInt64 = 16 << 20
    func validate() throws {
        guard (1...4096).contains(maximumRecords), (512...(64 << 20)).contains(maximumReadBytes),
              maximumSeconds.isFinite, maximumSeconds > 0, maximumSeconds <= 30,
              maximumExtractionBytes <= 16 << 20 else {
            throw NTFSAnalysisError.budget("记录、读取、时间或提取预算不在允许范围")
        }
    }
}

struct DiskImageSourceIdentity: Codable, Sendable, Equatable {
    let device: Int64
    let inode: UInt64
    let owner: UInt32
    let group: UInt32
    let mode: UInt16
    let flags: UInt32
    let size: UInt64
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64
    let changedSeconds: Int64
    let changedNanoseconds: Int64
    init(_ value: stat) {
        device = Int64(value.st_dev); inode = UInt64(value.st_ino)
        owner = value.st_uid; group = value.st_gid; mode = value.st_mode; flags = value.st_flags
        size = UInt64(max(0, value.st_size))
        modifiedSeconds = Int64(value.st_mtimespec.tv_sec); modifiedNanoseconds = Int64(value.st_mtimespec.tv_nsec)
        changedSeconds = Int64(value.st_ctimespec.tv_sec); changedNanoseconds = Int64(value.st_ctimespec.tv_nsec)
    }
}

struct DiskImageEntry: Codable, Identifiable, Sendable, Equatable {
    let id: String
    let recordNumber: UInt64
    let sequence: UInt16
    let name: String
    /// Root-relative components from the observed and sequence-checked MFT name chain.
    /// Nil means unresolved; never infer an orphan's full path or manufacture a root parent.
    let pathComponents: [String]?
    let parentID: String?
    let pathState: String
    let isDirectory: Bool
    let logicalBytes: UInt64?
    let hardLinkCount: UInt16
    let observedNameCount: Int
    let streamNames: [String]
    let flags: [String]
    let canExtract: Bool
    let extractionUnavailableReason: String?
    var displayPath: String { pathComponents.map { "/" + $0.joined(separator: "/") } ?? "（父路径未解析）/\(name)" }
}

struct DiskImageAnalysis: Codable, Sendable, Identifiable {
    let schemaVersion: Int
    let id: UUID
    let analyzedAt: Date
    let imageName: String
    let sourceIdentity: DiskImageSourceIdentity
    let sourceBytes: UInt64
    let inspectedBytes: UInt64
    let sourceSHA256: String?
    let hashScope: String
    let format: String
    let status: String
    let summary: String
    let geometry: NTFSGeometry?
    let entries: [DiskImageEntry]
    let warnings: [String]
    let features: [NTFSFeatureObservation]
    let examinedRecordSlots: Int
    let recordSlotLimit: Int
    /// Always false: MFT prefix links are not a validated NTFS directory index inventory.
    let directoryInventoryComplete: Bool
    let sourceUnchanged: Bool
    let writeCapabilities: NTFSWriteCapabilities

    func search(_ query: String) -> [DiskImageEntry] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return entries }
        return entries.filter { $0.name.localizedStandardContains(term) || $0.displayPath.localizedStandardContains(term) }
    }
    func children(of parentID: String) -> [DiskImageEntry] { entries.filter { $0.parentID == parentID } }
    var unresolvedEntries: [DiskImageEntry] { entries.filter { $0.pathComponents == nil } }

    /// This bounded report contains selected file names and paths; export only at user direction.
    func jsonData() throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }
    /// Prefix every spreadsheet cell to keep untrusted image names from acting as formulas.
    func csvData() -> Data {
        func cell(_ s: String) -> String { "\"'" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        let header = ["MFT记录", "名称", "已核路径", "路径状态", "类型", "逻辑字节（未知为空）", "可提取", "限制"]
        let rows = entries.map { e in [e.id, e.name, e.pathComponents.map { "/" + $0.joined(separator: "/") } ?? "", e.pathState,
            e.isDirectory ? "目录" : "文件", e.logicalBytes.map(String.init) ?? "", e.canExtract ? "是" : "否", e.extractionUnavailableReason ?? ""] }
        return Data(([header] + rows).map { $0.map(cell).joined(separator: ",") }.joined(separator: "\r\n").appending("\r\n").utf8)
    }
}

struct DiskImageExtractionReceipt: Codable, Sendable {
    let analysisID: UUID
    let entryID: String
    let destinationName: String
    let extractedBytes: UInt64
    let extractedSHA256: String
    let sourceIdentity: DiskImageSourceIdentity
    let sourceUnchanged: Bool
    let limitations: [String]
}
