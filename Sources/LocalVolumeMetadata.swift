import Foundation

/// A mounted-volume metadata snapshot, not a device scan or filesystem check.
/// No directory children, device nodes or file contents are opened by this code.
struct LocalVolumeClassification: Equatable, Sendable {
    var isLocal: Bool?
    var isInternal: Bool?
    var isRemovable: Bool?
    var isEjectable: Bool?

    var isIncluded: Bool {
        isLocal == true && isInternal == true && isRemovable == false && isEjectable == false
    }
}

struct LocalVolumeCapability: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    /// nil means the resource value was not supplied, never false or zero.
    let supported: Bool?
}

struct LocalVolumeDetails: Sendable {
    var name: String?
    var uuid: String?
    var formatDescription: String?
    var isReadOnly: Bool?
    var totalBytes: Int64?
    var availableBytes: Int64?
    var capabilities: [LocalVolumeCapability]
}

/// Split classification from details so excluded hardware/network mounts never
/// have their capacity or feature values requested by the collector.
protocol LocalVolumeMetadataProviding: Sendable {
    func mountedVolumeURLs() throws -> [URL]
    func classification(for url: URL) throws -> LocalVolumeClassification
    func details(for url: URL) throws -> LocalVolumeDetails
}

enum LocalVolumeMetadataError: LocalizedError {
    case enumerationUnavailable
    case classificationChanged

    var errorDescription: String? {
        switch self {
        case .enumerationUnavailable: return "系统未返回已挂载卷列表，不能作为没有本机卷处理。"
        case .classificationChanged: return "卷的本机内置属性发生变化或不可确认，已停止读取该卷详情。"
        }
    }
}

struct FoundationLocalVolumeMetadataProvider: LocalVolumeMetadataProviding {
    private static let classificationKeys: Set<URLResourceKey> = [
        .volumeIsLocalKey, .volumeIsInternalKey, .volumeIsRemovableKey, .volumeIsEjectableKey
    ]
    private static let detailKeys: Set<URLResourceKey> = [
        .volumeNameKey, .volumeUUIDStringKey, .volumeLocalizedFormatDescriptionKey,
        .volumeIsReadOnlyKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
        .volumeSupportsCaseSensitiveNamesKey, .volumeSupportsCasePreservedNamesKey,
        .volumeSupportsSymbolicLinksKey, .volumeSupportsHardLinksKey,
        .volumeSupportsSparseFilesKey, .volumeSupportsFileCloningKey
    ]

    func mountedVolumeURLs() throws -> [URL] {
        // No capacity prefetch, directory walk, hidden-volume guess or mount.
        guard let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: []) else {
            throw LocalVolumeMetadataError.enumerationUnavailable
        }
        return urls
    }

    func classification(for url: URL) throws -> LocalVolumeClassification {
        let values = try url.resourceValues(forKeys: Self.classificationKeys)
        return LocalVolumeClassification(isLocal: values.volumeIsLocal, isInternal: values.volumeIsInternal,
                                         isRemovable: values.volumeIsRemovable, isEjectable: values.volumeIsEjectable)
    }

    func details(for url: URL) throws -> LocalVolumeDetails {
        // Recheck immediately before reading detail resource values. This is a
        // read-only best-effort snapshot; it does not freeze mount topology.
        guard try classification(for: url).isIncluded else { throw LocalVolumeMetadataError.classificationChanged }
        let values = try url.resourceValues(forKeys: Self.detailKeys)
        let result = LocalVolumeDetails(
            name: values.volumeName,
            uuid: values.volumeUUIDString,
            formatDescription: values.volumeLocalizedFormatDescription,
            isReadOnly: values.volumeIsReadOnly,
            totalBytes: values.volumeTotalCapacity.map { Int64($0) },
            availableBytes: values.volumeAvailableCapacity.map { Int64($0) },
            capabilities: [
                LocalVolumeCapability(id: "caseSensitiveNames", name: "区分名称大小写", supported: values.volumeSupportsCaseSensitiveNames),
                LocalVolumeCapability(id: "casePreservedNames", name: "保留名称大小写", supported: values.volumeSupportsCasePreservedNames),
                LocalVolumeCapability(id: "symbolicLinks", name: "符号链接", supported: values.volumeSupportsSymbolicLinks),
                LocalVolumeCapability(id: "hardLinks", name: "硬链接", supported: values.volumeSupportsHardLinks),
                LocalVolumeCapability(id: "sparseFiles", name: "稀疏文件", supported: values.volumeSupportsSparseFiles),
                LocalVolumeCapability(id: "fileCloning", name: "文件克隆", supported: values.volumeSupportsFileCloning)
            ])
        guard try classification(for: url).isIncluded else { throw LocalVolumeMetadataError.classificationChanged }
        return result
    }
}

struct LocalVolumeMetadataEntry: Codable, Identifiable, Equatable, Sendable {
    var id: String { mountPath }
    let mountPath: String
    let name: String?
    let uuid: String?
    /// Localized system description, not an independently verified filesystem signature.
    let formatDescription: String?
    let isReadOnly: Bool?
    let totalBytes: Int64?
    let availableBytes: Int64?
    let capabilities: [LocalVolumeCapability]
    let unavailableFields: [String]
}

struct LocalVolumeMetadataSnapshot: Codable, Sendable {
    let capturedAt: Date
    let source: String
    let volumes: [LocalVolumeMetadataEntry]
    /// Completeness covers this bounded metadata query only, not filesystem health.
    let complete: Bool
    let cancelled: Bool
    let skippedExternalOrRemovableCount: Int
    let skippedNetworkCount: Int
    let skippedUnknownCount: Int
    let notes: [String]
}

struct LocalVolumeMetadataCollector: Sendable {
    private let provider: any LocalVolumeMetadataProviding
    let maximumVolumes: Int
    let timeBudget: TimeInterval
    private let clock: @Sendable () -> TimeInterval
    private let now: @Sendable () -> Date

    init(provider: any LocalVolumeMetadataProviding = FoundationLocalVolumeMetadataProvider(),
         maximumVolumes: Int = 128, timeBudget: TimeInterval = 3,
         clock: @escaping @Sendable () -> TimeInterval = { Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000 },
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.provider = provider
        self.maximumVolumes = max(0, min(maximumVolumes, 1024))
        self.timeBudget = timeBudget.isFinite ? max(0, min(timeBudget, 60)) : 0
        self.clock = clock
        self.now = now
    }

    func snapshot(cancelled: @escaping @Sendable () -> Bool = { false }) -> LocalVolumeMetadataSnapshot {
        let capturedAt = now()
        let start = clock()
        var volumes: [LocalVolumeMetadataEntry] = []
        var complete = true
        var wasCancelled = false
        var skippedExternal = 0
        var skippedNetwork = 0
        var skippedUnknown = 0
        var notes = [
            "来源为 Foundation 已挂载卷资源值；只列能确认属于本机内置、非可移除且非可弹出的本地卷。",
            "各卷容量不可直接相加；APFS 容器共享空间、快照与可清除空间会影响口径，不代表可释放空间或卷健康。",
            "不读取卷内容、原始设备、目录子项或外接盘容量；外接硬件范围不做（用户取消）。",
            "时间与取消预算在检查点生效；系统资源值调用未返回时不能强制中断。"
        ]
        func shouldStop() -> Bool {
            if cancelled() {
                complete = false
                wasCancelled = true
                if !notes.contains("已取消；仅保留检查点之前的已读取卷元信息。") {
                    notes.append("已取消；仅保留检查点之前的已读取卷元信息。")
                }
                return true
            }
            let current = clock()
            if !start.isFinite || !current.isFinite || current < start || current - start >= timeBudget {
                complete = false
                if !notes.contains("达到时间预算；未读取的卷或字段不能当作零值。") {
                    notes.append("达到时间预算；未读取的卷或字段不能当作零值。")
                }
                return true
            }
            return false
        }
        if !shouldStop() {
            do {
                let urls = try provider.mountedVolumeURLs()
                if urls.isEmpty {
                    complete = false
                    notes.append("系统返回空卷列表，未取得可用的本机卷观察，不能据此宣称设备没有卷。")
                }
                var seen = Set<String>()
                if urls.count > maximumVolumes {
                    complete = false
                    notes.append("达到卷条目预算（\(maximumVolumes)）；列表未完整检查。")
                }
                for url in urls.prefix(maximumVolumes) {
                    if shouldStop() { break }
                    guard Self.validLocalURL(url) else {
                        complete = false
                        skippedUnknown += 1
                        continue
                    }
                    let path = url.path
                    guard seen.insert(path).inserted else { continue }
                    let classification: LocalVolumeClassification
                    do { classification = try provider.classification(for: url) }
                    catch {
                        complete = false
                        skippedUnknown += 1
                        notes.append("一个挂载项的归属属性不可读，已跳过，未请求容量或功能详情。")
                        continue
                    }
                    // Definite exclusions require no further metadata access.
                    if classification.isLocal == false { skippedNetwork += 1; continue }
                    if classification.isInternal == false || classification.isRemovable == true || classification.isEjectable == true {
                        skippedExternal += 1
                        continue
                    }
                    guard classification.isIncluded else {
                        complete = false
                        skippedUnknown += 1
                        continue
                    }
                    if shouldStop() { break }
                    do {
                        let details = try provider.details(for: url)
                        let row = Self.entry(path: path, details: details)
                        // Mount changes invalidate this row; they never authorize
                        // rereading an excluded device or synthesizing capacities.
                        guard try provider.classification(for: url) == classification else {
                            complete = false
                            skippedUnknown += 1
                            notes.append("一个卷在读取期间归属属性改变，已作废该卷结果。")
                            continue
                        }
                        volumes.append(row)
                        if !row.unavailableFields.isEmpty { complete = false }
                    } catch {
                        complete = false
                        skippedUnknown += 1
                        notes.append("一个已确认本机卷的详情读取失败或卷属性改变；未读取项没有填入零值。")
                    }
                    if shouldStop() { break }
                }
                // Also cover the final excluded mount: its system attribute
                // lookup may have returned after the cooperative deadline.
                _ = shouldStop()
            } catch {
                complete = false
                notes.append("未取得有效的已挂载卷列表：\(error.localizedDescription)")
            }
        }
        if skippedUnknown > 0 { notes.append("\(skippedUnknown) 个挂载项的归属、路径或元信息不可确认，已跳过。") }
        return LocalVolumeMetadataSnapshot(capturedAt: capturedAt,
            source: "Foundation FileManager.mountedVolumeURLs / URL.resourceValues（公开只读接口）",
            volumes: volumes.sorted { $0.mountPath.localizedStandardCompare($1.mountPath) == .orderedAscending },
            complete: complete, cancelled: wasCancelled,
            skippedExternalOrRemovableCount: skippedExternal, skippedNetworkCount: skippedNetwork,
            skippedUnknownCount: skippedUnknown, notes: notes)
    }

    private static func validLocalURL(_ url: URL) -> Bool {
        guard url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost",
              url.baseURL == nil, url.query == nil, url.fragment == nil else { return false }
        let path = url.path
        guard path.hasPrefix("/"), path.utf8.count < 4096, !path.contains("\0") else { return false }
        return !path.split(separator: "/").contains { $0 == "." || $0 == ".." || $0.utf8.count > 255 }
    }

    private static func entry(path: String, details: LocalVolumeDetails) -> LocalVolumeMetadataEntry {
        var unavailable: [String] = []
        func text(_ value: String?, field: String) -> String? {
            guard let value, !value.isEmpty, value.utf8.count <= 4096, !value.contains("\0") else {
                unavailable.append(field)
                return nil
            }
            return value
        }
        let name = text(details.name, field: "卷名称")
        let uuid = text(details.uuid, field: "卷 UUID")
        let format = text(details.formatDescription, field: "系统格式描述")
        if details.isReadOnly == nil { unavailable.append("只读状态") }
        let total = details.totalBytes.flatMap { $0 > 0 ? $0 : nil }
        var available = details.availableBytes.flatMap { $0 >= 0 ? $0 : nil }
        if total == nil { unavailable.append("总容量") }
        if let total, let amount = available, amount > total { available = nil }
        if available == nil { unavailable.append("可用容量") }
        var seen = Set<String>()
        let capabilities = details.capabilities.prefix(32).filter { capability in
            !capability.id.isEmpty && capability.id.utf8.count <= 128 &&
            !capability.name.isEmpty && capability.name.utf8.count <= 256 && seen.insert(capability.id).inserted
        }
        if capabilities.count != details.capabilities.count { unavailable.append("部分功能标记") }
        for capability in capabilities where capability.supported == nil { unavailable.append(capability.name) }
        return LocalVolumeMetadataEntry(mountPath: path, name: name, uuid: uuid,
            formatDescription: format, isReadOnly: details.isReadOnly, totalBytes: total,
            availableBytes: available, capabilities: Array(capabilities), unavailableFields: unavailable)
    }
}
