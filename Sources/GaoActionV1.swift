import Foundation
import CryptoKit
import Darwin
import Security

// The frozen GaoAction V1 wire format. A declared sender and nonce are not authentication.
enum GAValue: Codable, Equatable, Sendable {
    case null, bool(Bool), integer(Int64), unsigned(UInt64), number(Double), string(String), array([GAValue]), object([String: GAValue])
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Int64.self) { self = .integer(v) }
        else if let v = try? c.decode(UInt64.self) { self = .unsigned(v) }
        else if let v = try? c.decode(Double.self), v.isFinite { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([GAValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String: GAValue].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .integer(let v): try c.encode(v)
        case .unsigned(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }
    var text: String? { if case .string(let v) = self { return v }; return nil }
}
struct GAIdentity: Codable, Equatable, Sendable {
    var volumeUUID: String?, device: Int32?, inode: UInt64?, byteCount: UInt64?, modifiedAt: String?
    enum CodingKeys: String, CodingKey { case volumeUUID, device, inode, byteCount, modifiedAt }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(volumeUUID, forKey: .volumeUUID); try c.encode(device, forKey: .device)
        try c.encode(inode, forKey: .inode); try c.encode(byteCount, forKey: .byteCount); try c.encode(modifiedAt, forKey: .modifiedAt)
    }
}
struct GAReference: Codable, Equatable, Sendable {
    var id: String, kind: String, fileURL: String, displayName: String
    var declaredIdentity: GAIdentity?
    var bundleID: String?
    // Accepted as an additional V1 compatibility representation; conflicting IDs are rejected.
    var application: [String: String]?
    var sha256: String?
    var applicationID: String? { bundleID ?? application?["bundleID"] }
}
struct GAItem: Codable, Equatable, Sendable {
    var id: String, relativePath: String, uti: String
    var byteCount: UInt64
    var sha256: String
}
struct GAManifest: Codable, Equatable, Sendable {
    var schemaVersion = 1
    var kind: String, requestID: String, sourceBundleID: String, targetBundleID: String, action: String
    var createdAt: String, expiresAt: String, nonce: String
    var items: [GAItem] = []
    var references: [GAReference] = []
    var parameters: [String: GAValue] = [:]
    var inReplyTo: String?, status: String?, errorCode: String?, provenance: [String: GAValue]?
}
struct GAError: LocalizedError {
    let code: String, message: String
    var errorDescription: String? { message }
    static func invalid(_ message: String, code: String = "invalidPackage") -> GAError { GAError(code: code, message: message) }
}

final class GAFD {
    let value: Int32
    init(_ value: Int32) throws { guard value >= 0 else { throw GAError.invalid("无法安全读取本地对象（系统错误 \(errno)）", code: "accessDenied") }; self.value = value }
    deinit { close(value) }
    func info() throws -> stat { var s = stat(); guard fstat(value, &s) == 0 else { throw GAError.invalid("无法核验对象身份") }; return s }
}
enum GAFile {
    static func parts(_ path: String) throws -> [String] {
        guard path.hasPrefix("/"), !path.contains("\0") else { throw GAError.invalid("必须使用本机绝对路径") }
        let p = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !p.contains(".."), !p.contains(".") else { throw GAError.invalid("路径不能包含相对跳转") }
        return p
    }
    static func directory(_ url: URL, createPrivate: Bool = false) throws -> GAFD {
        let pieces = try parts(url.path)
        var fd = try GAFD(open("/", O_SEARCH | O_DIRECTORY | O_CLOEXEC))
        for piece in pieces {
            if createPrivate, mkdirat(fd.value, piece, 0o700) != 0, errno != EEXIST { throw GAError.invalid("无法建立私有交接目录") }
            var before = stat()
            guard fstatat(fd.value, piece, &before, AT_SYMLINK_NOFOLLOW) == 0,
                  before.st_mode & S_IFMT == S_IFDIR, before.st_flags & UInt32(SF_DATALESS) == 0 else { throw GAError.invalid("路径含链接、云占位或不可读取祖先") }
            fd = try GAFD(openat(fd.value, piece, O_SEARCH | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC))
            let opened = try fd.info()
            guard before.st_dev == opened.st_dev, before.st_ino == opened.st_ino else { throw GAError.invalid("打开目录时身份发生变化") }
        }
        let s = try fd.info()
        guard s.st_flags & UInt32(SF_DATALESS) == 0 else { throw GAError.invalid("云端占位目录不会自动下载") }
        if createPrivate {
            guard s.st_uid == getuid(), fchmod(fd.value, 0o700) == 0 else { throw GAError.invalid("私有交接目录权限不符") }
        }
        return fd
    }
    static func regular(_ parent: GAFD, _ name: String, maximum: UInt64, allowRootOwner: Bool = false) throws -> GAFD {
        var before = stat()
        guard fstatat(parent.value, name, &before, AT_SYMLINK_NOFOLLOW) == 0,
              before.st_mode & S_IFMT == S_IFREG, (before.st_uid == getuid() || (allowRootOwner && before.st_uid == 0)), before.st_nlink == 1,
              before.st_size >= 0, UInt64(before.st_size) <= maximum,
              before.st_flags & UInt32(SF_DATALESS) == 0 else { throw GAError.invalid("附件必须是本用户可读取的普通本地文件，不能是链接、云占位或超限文件") }
        let fd = try GAFD(openat(parent.value, name, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC))
        guard same(before, try fd.info()) else { throw GAError.invalid("读取前对象已经变化") }
        return fd
    }
    static func same(_ a: stat, _ b: stat) -> Bool {
        a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_uid == b.st_uid && a.st_mode == b.st_mode &&
        a.st_nlink == b.st_nlink && a.st_size == b.st_size && a.st_flags == b.st_flags &&
        a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec &&
        a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec
    }
    static func sameIdentity(_ a: stat, _ b: stat) -> Bool {
        a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_uid == b.st_uid && a.st_mode & S_IFMT == b.st_mode & S_IFMT
    }
    static func read(_ fd: GAFD, maximum: Int, writeTo destination: GAFD? = nil, collect: Bool = true) throws -> (Data, String) {
        let before = try fd.info()
        var bytes = Data(), digest = SHA256(), offset: off_t = 0
        var buffer = [UInt8](repeating: 0, count: 1024 * 1024)
        while true {
            let n = pread(fd.value, &buffer, buffer.count, offset)
            guard n >= 0 else { if errno == EINTR { continue }; throw GAError.invalid("文件读取失败") }
            if n == 0 { break }
            guard offset <= maximum - n else { throw GAError.invalid("交接载荷超过上限") }
            let chunk = Data(buffer.prefix(n)); digest.update(data: chunk)
            if let destination {
                try chunk.withUnsafeBytes { ptr in
                    var written = 0
                    while written < n {
                        let m = Darwin.write(destination.value, ptr.baseAddress!.advanced(by: written), n - written)
                        guard m > 0 else { if errno == EINTR { continue }; throw GAError.invalid("私有暂存写入失败，原件未修改") }
                        written += m
                    }
                }
            } else if collect { bytes.append(chunk) }
            offset += off_t(n)
        }
        guard same(before, try fd.info()), offset == before.st_size else { throw GAError.invalid("读取期间文件发生变化，已停止") }
        return (bytes, digest.finalize().map { String(format: "%02x", $0) }.joined())
    }
    static func names(_ fd: GAFD) throws -> [String] {
        let readable = openat(fd.value, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard readable >= 0, let d = fdopendir(readable) else { if readable >= 0 { close(readable) }; throw GAError.invalid("无法枚举交接包") }
        defer { closedir(d) }
        var names: [String] = []; errno = 0
        while let e = readdir(d) {
            let name = withUnsafePointer(to: &e.pointee.d_name) { $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) } }
            if name == "." || name == ".." { continue }
            guard names.count < 2048 else { throw GAError.invalid("交接包目录条目超限") }
            names.append(name); errno = 0
        }
        guard errno == 0 else { throw GAError.invalid("交接包目录读取不完整") }; return names
    }
    static func atomic(_ data: Data, at url: URL, expected: Data? = nil, requireMissing: Bool = false) throws {
        let parent = try directory(url.deletingLastPathComponent(), createPrivate: true)
        let parentIdentity = try parent.info()
        var old = stat()
        let found = fstatat(parent.value, url.lastPathComponent, &old, AT_SYMLINK_NOFOLLOW) == 0
        if !found && errno != ENOENT { throw GAError.invalid("原记录不可读取，未覆盖") }
        if requireMissing && found { throw GAError.invalid("目标记录已存在，未覆盖") }
        if let expected {
            guard found else { throw GAError.invalid("原记录已经消失，未覆盖") }
            let fd = try regular(parent, url.lastPathComponent, maximum: 16 * 1024 * 1024)
            guard try read(fd, maximum: 16 * 1024 * 1024).0 == expected else { throw GAError.invalid("原记录由外部修改，未覆盖") }
        } else if found && (old.st_mode & S_IFMT != S_IFREG || old.st_uid != getuid() || old.st_nlink != 1) { throw GAError.invalid("目标记录身份异常") }
        let name = ".write-" + UUID().uuidString
        let fd = try GAFD(openat(parent.value, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600))
        defer {
            var remaining = stat()
            if fstatat(parent.value, name, &remaining, AT_SYMLINK_NOFOLLOW) == 0,
               let written = try? fd.info(), sameIdentity(remaining, written) { unlinkat(parent.value, name, 0) }
        }
        try data.withUnsafeBytes { p in
            var n = 0
            while n < data.count { let w = Darwin.write(fd.value, p.baseAddress!.advanced(by: n), data.count - n); guard w > 0 else { if errno == EINTR { continue }; throw GAError.invalid("记录写入失败") }; n += w }
        }
        guard fsync(fd.value) == 0 else { throw GAError.invalid("记录无法持久保存") }
        if let expected {
            let check = try regular(parent, url.lastPathComponent, maximum: 16 * 1024 * 1024)
            guard same(old, try check.info()), try read(check, maximum: 16 * 1024 * 1024).0 == expected else { throw GAError.invalid("原记录由外部修改，未覆盖") }
        }
        let currentParent = try directory(url.deletingLastPathComponent())
        guard sameIdentity(parentIdentity, try currentParent.info()) else { throw GAError.invalid("记录父目录在提交前变化，未覆盖") }
        if found {
            var current = stat()
            guard fstatat(parent.value, url.lastPathComponent, &current, AT_SYMLINK_NOFOLLOW) == 0, same(old, current) else { throw GAError.invalid("原记录在提交前被替换，未覆盖") }
        }
        let result = requireMissing || !found ? renameatx_np(parent.value, name, parent.value, url.lastPathComponent, UInt32(RENAME_EXCL)) : renameat(parent.value, name, parent.value, url.lastPathComponent)
        guard result == 0 else { throw GAError.invalid("记录提交失败，原记录保留") }
        guard fsync(parent.value) == 0 else { throw GAError.invalid("记录已写入但目录同步失败，停止后续操作并保留资料") }
    }

    /// Removes only a verified metadata-only package in a caller-owned private
    /// namespace. No recursive deletion and no reference path is ever followed.
    static func removeMetadataPackage(_ url: URL, verify: (Data) throws -> Void) throws {
        let parent = try directory(url.deletingLastPathComponent())
        let parentIdentity = try parent.info()
        guard parentIdentity.st_uid == getuid(), parentIdentity.st_mode & 0o077 == 0 else { throw GAError.invalid("副本父目录不是当前用户私有目录") }
        var named = stat()
        guard fstatat(parent.value, url.lastPathComponent, &named, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT { return }; throw GAError.invalid("副本状态不可读取，未清理")
        }
        guard named.st_mode & S_IFMT == S_IFDIR, named.st_uid == getuid(), named.st_mode & 0o077 == 0,
              named.st_flags & UInt32(SF_DATALESS) == 0 else { throw GAError.invalid("副本目录身份或权限异常，已保留") }
        let package = try GAFD(openat(parent.value, url.lastPathComponent, O_SEARCH | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC))
        guard same(named, try package.info()), Set(try names(package)) == ["manifest.json", "payload"] else { throw GAError.invalid("副本含非预期内容，已保留") }
        let manifest = try regular(package, "manifest.json", maximum: 1024 * 1024), manifestInfo = try manifest.info()
        let bytes = try read(manifest, maximum: 1024 * 1024).0
        try verify(bytes)
        let payload = try GAFD(openat(package.value, "payload", O_SEARCH | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC))
        let payloadInfo = try payload.info()
        guard payloadInfo.st_uid == getuid(), payloadInfo.st_mode & 0o077 == 0,
              payloadInfo.st_flags & UInt32(SF_DATALESS) == 0, try names(payload).isEmpty else { throw GAError.invalid("副本包含载荷或异常权限，未清理") }
        let currentParent = try directory(url.deletingLastPathComponent())
        var current = stat(), currentManifest = stat(), currentPayload = stat()
        guard sameIdentity(parentIdentity, try currentParent.info()),
              fstatat(parent.value, url.lastPathComponent, &current, AT_SYMLINK_NOFOLLOW) == 0, same(named, current),
              fstatat(package.value, "manifest.json", &currentManifest, AT_SYMLINK_NOFOLLOW) == 0, same(manifestInfo, currentManifest),
              fstatat(package.value, "payload", &currentPayload, AT_SYMLINK_NOFOLLOW) == 0, same(payloadInfo, currentPayload) else {
            throw GAError.invalid("副本在清理前变化，已保留")
        }
        // rmdir fails if a concurrent writer adds content. Every unlink is
        // anchored to a descriptor and addresses exactly one checked entry.
        guard unlinkat(package.value, "payload", AT_REMOVEDIR) == 0 else { throw GAError.invalid("空载荷目录在清理时变化，已停止") }
        guard fstatat(package.value, "manifest.json", &currentManifest, AT_SYMLINK_NOFOLLOW) == 0,
              same(manifestInfo, currentManifest), unlinkat(package.value, "manifest.json", 0) == 0 else { throw GAError.invalid("副本清理未完整完成，幂等记录仍保留") }
        guard fstatat(parent.value, url.lastPathComponent, &current, AT_SYMLINK_NOFOLLOW) == 0,
              sameIdentity(named, current), unlinkat(parent.value, url.lastPathComponent, AT_REMOVEDIR) == 0,
              fsync(parent.value) == 0 else { throw GAError.invalid("副本目录清理未完整完成，幂等记录仍保留") }
    }
    static func noCloud<T>(_ body: () throws -> T) throws -> T {
        let old = getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD)
        guard old >= 0 else { throw GAError.invalid("无法读取云占位保护状态，未开始读取") }
        defer { if old >= 0 { _ = setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, old) } }
        guard setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, IOPOL_MATERIALIZE_DATALESS_FILES_OFF) == 0,
              getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD) == IOPOL_MATERIALIZE_DATALESS_FILES_OFF else { throw GAError.invalid("无法启用禁止云占位下载保护，未开始读取") }
        return try body()
    }
}

struct GAResolvedReference: Sendable {
    let url: URL, identity: GAIdentity
    let ownerUID: UInt32
}

struct GAReceived: Sendable {
    let manifest: GAManifest, manifestSHA256: String, stagedURL: URL
}
enum GaoActionV1 {
    static let bundleID = "com.gaoseries.GaoJiLing"
    static let actions: Set<String> = ["storage.inspect", "cleanup.review", "apps.uninstall.review"]
    static let payloadLimit: UInt64 = 2 * 1024 * 1024 * 1024
    static func date(_ value: String) -> Date? {
        guard value.hasSuffix("Z") else { return nil }
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = formatter.date(from: value) { return d }
        formatter.formatOptions = [.withInternetDateTime]; return formatter.date(from: value)
    }
    static func timestamp(_ value: Date) -> String { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f.string(from: value) }
    static func nonce() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw GAError.invalid("无法生成随机交接标识") }
        return Data(bytes).base64EncodedString()
    }
    static func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func validate(_ data: Data, target: String = bundleID, now: Date = Date(), providerOnly: Bool = true) throws -> GAManifest {
        guard data.count <= 1024 * 1024,
              let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw GAError.invalid("manifest 超限或无效") }
        let allowed: Set<String> = ["schemaVersion","kind","requestID","sourceBundleID","targetBundleID","action","createdAt","expiresAt","nonce","items","references","parameters","inReplyTo","status","errorCode","provenance"]
        guard Set(raw.keys).isSubset(of: allowed) else { throw GAError.invalid("manifest 包含未声明字段") }
        var m = try JSONDecoder().decode(GAManifest.self, from: data)
        guard m.schemaVersion == 1 else { throw GAError.invalid("不支持此交接版本", code: "unsupportedSchema") }
        guard UUID(uuidString: m.requestID) != nil, m.targetBundleID == target,
              validBundle(m.sourceBundleID), validBundle(m.targetBundleID),
              let n = Data(base64Encoded: m.nonce), n.count == 32,
              let created = date(m.createdAt), let expires = date(m.expiresAt),
              created <= now, now < expires, expires > created, expires.timeIntervalSince(created) <= 120.001 else { throw GAError.invalid("交接目标、标识或有效期无效", code: "expiredOrInvalidEnvelope") }
        m.requestID = UUID(uuidString: m.requestID)!.uuidString
        if let reply = m.inReplyTo, let id = UUID(uuidString: reply) { m.inReplyTo = id.uuidString }
        let known = actions.union(["documents.newText", "ocr.files"])
        guard (providerOnly ? actions : known).contains(m.action) else { throw GAError.invalid("本版不支持该动作", code: "unsupportedAction") }
        guard m.items.count + m.references.count <= 256,
              Set(m.items.map(\.id)).count == m.items.count, Set(m.references.map(\.id)).count == m.references.count,
              Set(m.items.map(\.relativePath)).count == m.items.count else { throw GAError.invalid("交接项目超限或重复") }
        var size: UInt64 = 0
        for item in m.items {
            _ = try payloadParts(item.relativePath)
            guard !item.id.isEmpty, !item.uti.isEmpty, isSHA(item.sha256), item.byteCount <= payloadLimit - size else { throw GAError.invalid("附件声明无效或载荷超限") }
            size += item.byteCount
        }
        for ref in m.references {
            guard !ref.id.isEmpty, ["file", "directory", "application"].contains(ref.kind), ref.displayName.count <= 4096 else { throw GAError.invalid("引用格式无效") }
            _ = try localURL(ref.fileURL)
            if let v = ref.sha256, !isSHA(v) { throw GAError.invalid("引用摘要无效") }
            if ref.kind == "application" { guard let b = ref.applicationID, validBundle(b), ref.bundleID == nil || ref.application?["bundleID"] == nil || ref.bundleID == ref.application?["bundleID"] else { throw GAError.invalid("应用引用标识缺失或冲突") } }
            if let d = ref.declaredIdentity {
                if let t = d.modifiedAt, date(t) == nil { throw GAError.invalid("引用修改时间无效") }
                if let v = d.volumeUUID, UUID(uuidString: v) == nil { throw GAError.invalid("卷标识无效") }
            }
        }
        if m.kind == "result" {
            guard let reply = m.inReplyTo, UUID(uuidString: reply) != nil,
                  let status = m.status, ["pending","completed","partial","cancelled","failed","unsupported"].contains(status),
                  m.parameters.isEmpty, let provenance = m.provenance else { throw GAError.invalid("结果缺少关联、状态或来源说明") }
            if actions.contains(m.action) {
                guard m.items.isEmpty, m.references.isEmpty else { throw GAError.invalid("本 App 的维护与元数据分析结果不携带文件或原件引用") }
                try validateOutcome(action: m.action, status: status, provenance: provenance, errorCode: m.errorCode)
            }
            return m
        }
        guard m.kind == "request", m.inReplyTo == nil, m.status == nil, m.errorCode == nil, m.provenance == nil else { throw GAError.invalid("请求包含结果专用字段") }
        switch m.action {
        case "storage.inspect":
            guard m.items.isEmpty, m.references.count == 1, m.references[0].kind == "directory", Set(m.parameters.keys).isSubset(of: ["mode"]) else { throw GAError.invalid("存储分析只接受一个目录引用") }
            if let mode = m.parameters["mode"] { guard mode.text == "metadata" else { throw GAError.invalid("本版未提供内容重复扫描", code: "unsupportedMode") } }
        case "cleanup.review":
            guard m.items.isEmpty, m.references.isEmpty, m.parameters.isEmpty else { throw GAError.invalid("缓存复核不能接受任意路径或参数") }
        case "apps.uninstall.review":
            guard m.items.isEmpty, m.references.count == 1, m.references[0].kind == "application", m.parameters.isEmpty else { throw GAError.invalid("卸载复核只接受一个应用引用") }
        case "documents.newText":
            guard m.items.count == 1, m.references.isEmpty, ["text/plain","text/markdown","public.plain-text","net.daringfireball.markdown"].contains(m.items[0].uti), Set(m.parameters.keys).isSubset(of: ["suggestedTitle"]) else { throw GAError.invalid("新文本文档输入无效") }
            if let title = m.parameters["suggestedTitle"] { guard let t = title.text, t.count <= 256 else { throw GAError.invalid("标题无效") } }
        case "ocr.files":
            guard !m.items.isEmpty, m.references.isEmpty, Set(m.parameters.keys).isSubset(of: ["languages","outputs"]) else { throw GAError.invalid("OCR 输入无效") }
        default: throw GAError.invalid("不支持该动作")
        }
        return m
    }
    /// The three provider-owned result schemas. Generic compatibility fixtures
    /// for other providers retain their own result provenance.
    static func validateOutcome(action: String, status: String, provenance p: [String: GAValue], errorCode: String? = nil) throws {
        guard actions.contains(action), let state = p["workflowState"]?.text else { throw GAError.invalid("结果缺少实际流程状态") }
        let states: [String: Set<String>] = ["pending": ["awaitingUser", "executing"], "completed": ["completed"],
            "partial": ["partial", "reviewedNoChanges"], "cancelled": ["cancelled"], "failed": ["failed", "interrupted"], "unsupported": ["unsupported", "failed"]]
        guard states[status]?.contains(state) == true else { throw GAError.invalid("结果状态与流程状态不一致") }
        if let errorCode {
            guard !errorCode.isEmpty, errorCode.utf8.count <= 128,
                  errorCode.range(of: "^[A-Za-z0-9_.-]+$", options: .regularExpression) != nil,
                  ["failed", "unsupported", "partial", "cancelled"].contains(status) else { throw GAError.invalid("结果错误代码无效") }
        }
        if state == "interrupted" { guard errorCode == "interrupted" else { throw GAError.invalid("中断结果缺少明确错误代码") } }
        if let reason = p["reason"] { guard let text = reason.text, !text.isEmpty, text.utf8.count <= 4096 else { throw GAError.invalid("结果说明无效") } }
        if let flag = p["originalsModifiedByHandoff"] {
            guard flag == .bool(false), ["pending", "cancelled", "failed", "unsupported"].contains(status) else { throw GAError.invalid("原件修改说明与结果不一致") }
        }
        let common: Set<String> = ["workflowState", "reason", "originalsModifiedByHandoff"]
        func number(_ key: String, in values: [String: GAValue]) -> Int64? {
            switch values[key] {
            case .integer(let value): return value >= 0 ? value : nil
            case .unsigned(let value): return value <= UInt64(Int64.max) ? Int64(value) : nil
            default: return nil
            }
        }
        if action == "storage.inspect" {
            guard Set(p.keys).isSubset(of: common.union(["scope", "complete", "statistics"])) else { throw GAError.invalid("存储结果含未定义字段") }
            if let scope = p["scope"] {
                guard case .object(let value) = scope, Set(value.keys) == ["referenceID", "displayName", "kind"],
                      let id = value["referenceID"]?.text, !id.isEmpty, id.utf8.count <= 4096,
                      let name = value["displayName"]?.text, name.count <= 4096,
                      value["kind"] == .string("directory") else { throw GAError.invalid("存储结果范围不是受限目录说明") }
            }
            if let complete = p["complete"] {
                guard case .bool(let value) = complete, value == (status == "completed") else { throw GAError.invalid("存储完整性与结果状态不一致") }
            }
            if let statistics = p["statistics"] {
                guard case .object(let values) = statistics,
                      Set(values.keys).isSubset(of: ["allocatedBytes", "logicalBytes", "files", "directories", "entries", "skippedCount"]),
                      number("allocatedBytes", in: values) != nil,
                      values.keys.allSatisfy({ number($0, in: values) != nil }), p["scope"] != nil, p["complete"] != nil else {
                    throw GAError.invalid("存储统计必须是实际非负整数，不能携带路径或指令")
                }
            }
            if ["completed", "partial"].contains(status) {
                guard p["scope"] != nil, p["complete"] != nil, p["statistics"] != nil, state != "reviewedNoChanges" else { throw GAError.invalid("已完成或部分分析缺少范围与实际统计") }
            }
            if status == "pending" || status == "unsupported" || state == "interrupted" {
                guard p["statistics"] == nil else { throw GAError.invalid("尚未确认的分析不能附完成统计") }
            }
        } else {
            let counts: Set<String> = action == "cleanup.review" ? ["itemCount", "movedBytes", "skippedCount", "failedCount"] : ["itemCount", "movedBytes", "issueCount"]
            guard Set(p.keys).isSubset(of: common.union(counts).union(["receiptID"])) else { throw GAError.invalid("维护结果含未定义字段") }
            let hasCounts = !Set(p.keys).isDisjoint(with: counts)
            if hasCounts { guard counts.allSatisfy({ number($0, in: p) != nil }) else { throw GAError.invalid("维护统计不完整或不是非负整数") } }
            if let receipt = p["receiptID"] {
                guard let text = receipt.text, UUID(uuidString: text) != nil, hasCounts else { throw GAError.invalid("回执必须是实际批次 UUID，并附实际处理统计") }
            }
            let moved = number("itemCount", in: p) ?? 0
            if moved == 0 && hasCounts { guard number("movedBytes", in: p) == 0 else { throw GAError.invalid("未移动项目不能报告已处理占用") } }
            if moved > 0 { guard p["receiptID"] != nil, ["completed", "partial"].contains(status), p["originalsModifiedByHandoff"] == nil else { throw GAError.invalid("实际移动必须关联回执及正确结果状态") } }
            switch status {
            case "completed":
                guard hasCounts, moved > 0, p["receiptID"] != nil,
                      counts.subtracting(["itemCount", "movedBytes"]).allSatisfy({ number($0, in: p) == 0 }) else { throw GAError.invalid("打开复核页或空结果不能冒充维护完成") }
            case "partial":
                guard hasCounts, state == (moved == 0 ? "reviewedNoChanges" : "partial") else { throw GAError.invalid("部分维护结果缺少实际统计") }
            case "pending", "unsupported":
                guard !hasCounts, p["receiptID"] == nil else { throw GAError.invalid("等待复核不能附加执行回执") }
            default: break
            }
            if state == "interrupted" { guard !hasCounts, p["receiptID"] == nil else { throw GAError.invalid("中断不能猜测已执行数量或伪造回执") } }
        }
    }
    static func validBundle(_ value: String) -> Bool { value.count <= 255 && value.range(of: "^[A-Za-z0-9-]+(\\.[A-Za-z0-9-]+)+$", options: .regularExpression) != nil }
    static func isSHA(_ value: String) -> Bool { value.count == 64 && value.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil }
    static func payloadParts(_ path: String) throws -> [String] {
        let p = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard p.count >= 2, p[0] == "payload", p.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\0") && !$0.contains("\\") }) else { throw GAError.invalid("附件路径越界") }; return p
    }
    static func localURL(_ text: String) throws -> URL {
        guard let u = URL(string: text), u.isFileURL, u.host == nil || u.host == "" || u.host == "localhost", u.query == nil, u.fragment == nil, u.user == nil, u.password == nil, u.port == nil else { throw GAError.invalid("引用必须为规范化本机 file URL") }
        let p = try GAFile.parts(u.path)
        guard u.path == "/" + p.joined(separator: "/") || u.path == "/" + p.joined(separator: "/") + "/" else { throw GAError.invalid("引用路径未规范化") }; return u
    }
    static func receive(_ url: URL, incoming: URL, target: String = bundleID, now: Date = Date(), providerOnly: Bool = true) throws -> GAReceived {
        try GAFile.noCloud {
            _ = try localURL(url.absoluteString)
            guard url.pathExtension.lowercased() == "gaoaction" else { throw GAError.invalid("请选择 .gaoaction 目录包") }
            let root = try GAFile.directory(url), original = try root.info()
            guard original.st_uid == getuid(), Set(try GAFile.names(root)) == ["manifest.json", "payload"] else { throw GAError.invalid("交接包必须由本用户持有且仅含 manifest.json 与 payload") }
            let manifestFD = try GAFile.regular(root, "manifest.json", maximum: 1024 * 1024)
            let (bytes, checksum) = try GAFile.read(manifestFD, maximum: 1024 * 1024)
            let m = try validate(bytes, target: target, now: now, providerOnly: providerOnly)
            if providerOnly && m.kind != "request" { throw GAError.invalid("本提供方仅接收动作请求") }
            let sourcePayload = try GAFD(openat(root.value, "payload", O_SEARCH | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC))
            let payloadBefore = try sourcePayload.info()
            guard try sourcePayload.info().st_uid == getuid() else { throw GAError.invalid("载荷目录归属无效") }
            let allowed = Set(m.items.map(\.relativePath)); var listed = Set<String>(); var entryCount = 0
            func inspect(_ fd: GAFD, _ prefix: String, _ depth: Int) throws {
                guard depth <= 32 else { throw GAError.invalid("载荷目录深度超限") }
                let before = try fd.info()
                for name in try GAFile.names(fd) {
                    entryCount += 1; guard entryCount <= 2048 else { throw GAError.invalid("载荷目录条目超限") }
                    var s = stat(); guard fstatat(fd.value, name, &s, AT_SYMLINK_NOFOLLOW) == 0, s.st_uid == getuid(), s.st_flags & UInt32(SF_DATALESS) == 0 else { throw GAError.invalid("载荷含不可核验条目") }
                    let path = prefix + "/" + name
                    if s.st_mode & S_IFMT == S_IFDIR {
                        guard allowed.contains(where: { $0.hasPrefix(path + "/") }) else { throw GAError.invalid("载荷含未声明目录") }
                        let child = try GAFD(openat(fd.value, name, O_SEARCH | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)); try inspect(child, path, depth + 1)
                    } else {
                        guard s.st_mode & S_IFMT == S_IFREG, s.st_nlink == 1, allowed.contains(path) else { throw GAError.invalid("载荷含链接、特殊或未声明文件") }; listed.insert(path)
                    }
                }
                guard GAFile.same(before, try fd.info()) else { throw GAError.invalid("枚举期间载荷发生变化") }
            }
            try inspect(sourcePayload, "payload", 0)
            guard listed == allowed else { throw GAError.invalid("载荷文件不完整") }
            _ = try GAFile.directory(incoming, createPrivate: true)
            let staged = incoming.appendingPathComponent(UUID().uuidString + ".gaoaction", isDirectory: true)
            let destination = try GAFile.directory(staged, createPrivate: true)
            guard mkdirat(destination.value, "payload", 0o700) == 0 else { throw GAError.invalid("无法建立载荷暂存") }
            var committed = false
            defer { if !committed { try? FileManager.default.removeItem(at: staged) } }
            for item in m.items {
                let p = try payloadParts(item.relativePath)
                var source = sourcePayload
                var output = try GAFD(openat(destination.value, "payload", O_SEARCH | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC))
                for piece in p.dropFirst().dropLast() {
                    source = try GAFD(openat(source.value, piece, O_SEARCH | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC))
                    if mkdirat(output.value, piece, 0o700) != 0 && errno != EEXIST { throw GAError.invalid("无法建立载荷子目录") }
                    output = try GAFD(openat(output.value, piece, O_SEARCH | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC))
                }
                let input = try GAFile.regular(source, p.last!, maximum: payloadLimit)
                guard UInt64(try input.info().st_size) == item.byteCount else { throw GAError.invalid("附件大小不一致") }
                let file = try GAFD(openat(output.value, p.last!, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600))
                let digest = try GAFile.read(input, maximum: Int(payloadLimit), writeTo: file).1
                guard digest == item.sha256, fsync(file.value) == 0 else { throw GAError.invalid("附件摘要或暂存持久化失败") }
                var currentSource = try GAFD(openat(root.value, "payload", O_SEARCH | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC))
                for component in p.dropFirst().dropLast() { currentSource = try GAFD(openat(currentSource.value, component, O_SEARCH | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)) }
                let sourceCheck = try GAFile.regular(currentSource, p.last!, maximum: payloadLimit)
                guard GAFile.same(try input.info(), try sourceCheck.info()) else { throw GAError.invalid("附件路径在复制期间被替换") }
                let copied = try GAFile.regular(output, p.last!, maximum: payloadLimit)
                guard try GAFile.read(copied, maximum: Int(payloadLimit), collect: false).1 == digest else { throw GAError.invalid("暂存副本摘要不符") }
            }
            guard GAFile.same(original, try root.info()), GAFile.same(payloadBefore, try sourcePayload.info()), try GAFile.read(manifestFD, maximum: 1024 * 1024).0 == bytes else { throw GAError.invalid("接收期间交接包发生变化") }
            try GAFile.atomic(bytes, at: staged.appendingPathComponent("manifest.json"), requireMissing: true)
            committed = true; return GAReceived(manifest: m, manifestSHA256: checksum, stagedURL: staged)
        }
    }
    static func verifyReference(_ ref: GAReference, selected: URL? = nil) throws -> URL {
        try resolveReference(ref, selected: selected).url
    }
    static func resolveReference(_ ref: GAReference, selected: URL? = nil) throws -> GAResolvedReference {
        try GAFile.noCloud {
            let declared = try localURL(ref.fileURL), url = selected ?? declared
            guard try localURL(url.absoluteString).path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == declared.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) else { throw GAError.invalid("所选对象与请求引用不同，请重新发起请求") }
            let parent = try GAFile.directory(url.deletingLastPathComponent())
            var s = stat(); guard fstatat(parent.value, url.lastPathComponent, &s, AT_SYMLINK_NOFOLLOW) == 0,
                                  s.st_flags & UInt32(SF_DATALESS) == 0 else { throw GAError.invalid("原对象不可读取，请在本 App 选择并复核", code: "selectionRequired") }
            let isDirectory = s.st_mode & S_IFMT == S_IFDIR
            guard ref.kind == "file" ? s.st_mode & S_IFMT == S_IFREG : isDirectory else { throw GAError.invalid("引用对象类型发生变化") }
            if ref.kind == "file" { guard s.st_nlink == 1 else { throw GAError.invalid("文件引用不接受硬链接") } }
            guard let identity = ref.declaredIdentity else { throw GAError.invalid("引用没有可核验身份，请重新选择后发送", code: "identityMissing") }
            if selected == nil && (identity.device == nil || identity.inode == nil) { throw GAError.invalid("引用身份不完整，需要本 App 明确选择", code: "selectionRequired") }
            if let v = identity.device, v != s.st_dev { throw GAError.invalid("引用设备已变化", code: "identityChanged") }
            if let v = identity.inode, v != s.st_ino { throw GAError.invalid("引用对象已被替换", code: "identityChanged") }
            if let v = identity.byteCount, v != UInt64(s.st_size) { throw GAError.invalid("引用大小已变化", code: "identityChanged") }
            if let v = identity.modifiedAt, let date = date(v) {
                let actual = Double(s.st_mtimespec.tv_sec) + Double(s.st_mtimespec.tv_nsec) / 1_000_000_000
                // V1 allows ISO-8601 timestamps without fractions; compare at that precision.
                let tolerance = v.contains(".") ? 0.0011 : 1.0
                guard abs(actual - date.timeIntervalSince1970) < tolerance else { throw GAError.invalid("引用内容时间已变化", code: "identityChanged") }
            }
            if let expected = identity.volumeUUID {
                let actual = try url.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString
                guard actual?.caseInsensitiveCompare(expected) == .orderedSame else { throw GAError.invalid("引用所在卷已变化") }
            }
            if ref.kind == "application" {
                let app = try GAFD(openat(parent.value, url.lastPathComponent, O_SEARCH | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC))
                let contents = try GAFD(openat(app.value, "Contents", O_SEARCH | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC))
                let info = try GAFile.regular(contents, "Info.plist", maximum: 1024 * 1024, allowRootOwner: true)
                let data = try GAFile.read(info, maximum: 1024 * 1024).0
                let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
                guard url.pathExtension.lowercased() == "app", plist?["CFBundleIdentifier"] as? String == ref.applicationID else { throw GAError.invalid("真实应用标识与引用不符") }
            } else if let expected = ref.sha256 {
                let file = try GAFile.regular(parent, url.lastPathComponent, maximum: payloadLimit)
                guard try GAFile.read(file, maximum: Int(payloadLimit), collect: false).1 == expected else { throw GAError.invalid("原文件摘要已变化") }
            }
            var after = stat(); guard fstatat(parent.value, url.lastPathComponent, &after, AT_SYMLINK_NOFOLLOW) == 0, GAFile.same(s, after) else { throw GAError.invalid("复核期间原件发生变化") }
            let currentParent = try GAFile.directory(url.deletingLastPathComponent())
            var current = stat()
            guard fstatat(currentParent.value, url.lastPathComponent, &current, AT_SYMLINK_NOFOLLOW) == 0, GAFile.same(s, current) else { throw GAError.invalid("原件祖先或路径在复核期间发生变化") }
            let actualDate = Date(timeIntervalSince1970: Double(s.st_mtimespec.tv_sec) + Double(s.st_mtimespec.tv_nsec) / 1e9)
            let actual = GAIdentity(volumeUUID: try? url.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString,
                                    device: s.st_dev, inode: s.st_ino, byteCount: UInt64(s.st_size), modifiedAt: timestamp(actualDate))
            return GAResolvedReference(url: url, identity: actual, ownerUID: UInt32(s.st_uid))
        }
    }
}
