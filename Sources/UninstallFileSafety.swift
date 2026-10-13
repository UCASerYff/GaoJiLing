import Foundation
import CryptoKit
import Darwin

struct UninstallFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct UninstallIdentity: Codable, Equatable, Sendable {
    let device: UInt64
    let inode: UInt64
    let kind: UInt32
    let uid: UInt32
    init(device: UInt64, inode: UInt64, kind: UInt32 = UInt32(S_IFDIR), uid: UInt32) {
        self.device = device; self.inode = inode; self.kind = kind; self.uid = uid
    }
    init(_ info: stat) {
        device = UInt64(bitPattern: Int64(info.st_dev)); inode = UInt64(info.st_ino)
        kind = UInt32(info.st_mode & S_IFMT); uid = info.st_uid
    }
}

struct UninstallFootprint: Codable, Equatable, Sendable {
    let identity: UninstallIdentity
    let digest: String
    let bytes: Int64
    let newest: TimeInterval
    let entries: Int
}

/// Separate from cache cleanup: app bundles may contain framework symlinks.
/// Those links are recorded as links, never traversed. Cache links are rejected.
/// Pinned descriptors reduce path races; this is not race freedom against a
/// malicious process with the same user's privileges.
enum UninstallFileSafety {
    static let uid = getuid()
    static func validURL(_ url: URL) -> Bool {
        url.isFileURL && url.host.map({ $0.isEmpty || $0 == "localhost" }) != false &&
            url.path.hasPrefix("/") && !url.path.contains("\0") &&
            !url.pathComponents.contains(where: { $0 == "." || $0 == ".." })
    }
    static func failure(_ text: String) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSLocalizedDescriptionKey: text])
    }
    static func missing(_ error: Error) -> Bool {
        let e = error as NSError
        return e.domain == NSPOSIXErrorDomain && e.code == Int(ENOENT)
    }
    static func materializationDisabled<T>(_ body: () throws -> T) throws -> T {
        let previous = getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD)
        guard previous >= 0, setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, IOPOL_MATERIALIZE_DATALESS_FILES_OFF) == 0 else {
            throw UninstallFailure(message: "无法禁止云端占位文件下载，已停止操作。")
        }
        let result = Result { try body() }
        guard setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, previous) == 0 else {
            throw UninstallFailure(message: "无法恢复文件访问策略；已有恢复记录和文件会保留。")
        }
        return try result.get()
    }
    static func directory(_ url: URL, create: Bool = false, read: Bool = false, privateOnly: Bool = false) throws -> Int32 {
        // Foundation standardization can rewrite /private/tmp to the /tmp
        // symlink after a path exists. Keep the supplied physical components.
        guard validURL(url) else {
            throw UninstallFailure(message: "目录路径无效。")
        }
        var fd = Darwin.open("/", O_SEARCH | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw failure("无法固定目录") }
        do {
            let components = url.pathComponents.dropFirst()
            for (index, name) in components.enumerated() {
                var before = stat()
                if fstatat(fd, name, &before, AT_SYMLINK_NOFOLLOW) != 0 {
                    if errno == ENOENT && create {
                        guard mkdirat(fd, name, 0o700) == 0 || errno == EEXIST else { throw failure("无法创建私有恢复目录") }
                        guard fstatat(fd, name, &before, AT_SYMLINK_NOFOLLOW) == 0 else { throw failure("无法核验新目录") }
                    } else { throw failure("无法访问目录") }
                }
                guard before.st_mode & S_IFMT == S_IFDIR, before.st_flags & UInt32(SF_DATALESS) == 0 else {
                    throw UninstallFailure(message: "目录含链接或云端占位内容，已停止。")
                }
                let last = index == components.count - 1
                let flags = last && read ? O_RDONLY | O_DIRECTORY : O_SEARCH
                let next = openat(fd, name, flags | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw failure("目录无法安全打开") }
                var after = stat()
                guard fstat(next, &after) == 0, UninstallIdentity(before) == UninstallIdentity(after),
                      after.st_flags & UInt32(SF_DATALESS) == 0 else {
                    close(next); throw UninstallFailure(message: "目录在核验时发生变化。")
                }
                close(fd); fd = next
            }
            if privateOnly {
                var info = stat()
                guard fstat(fd, &info) == 0, info.st_uid == uid, info.st_mode & 0o077 == 0 else {
                    throw UninstallFailure(message: "恢复目录不是当前用户的私有目录。")
                }
            }
            return fd
        } catch { close(fd); throw error }
    }
    static func info(_ url: URL) throws -> stat {
        let fd = try directory(url.deletingLastPathComponent())
        defer { close(fd) }
        return try info(parent: fd, name: url.lastPathComponent)
    }
    static func info(parent: Int32, name: String) throws -> stat {
        var value = stat()
        guard fstatat(parent, name, &value, AT_SYMLINK_NOFOLLOW) == 0 else { throw failure("无法读取文件属性") }
        guard value.st_flags & UInt32(SF_DATALESS) == 0 else { throw UninstallFailure(message: "云端占位项目不作处理。") }
        return value
    }
    static func optionalInfo(_ url: URL) throws -> stat? {
        do { return try info(url) } catch { if missing(error) { return nil }; throw error }
    }
    static func identity(_ fd: Int32) throws -> UninstallIdentity {
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw failure("无法核验目录身份") }
        return UninstallIdentity(info)
    }
    static func names(_ fd: Int32, cancelled: () -> Bool) throws -> [String] {
        if cancelled() { throw CancellationError() }
        let copy = dup(fd)
        guard copy >= 0 else { throw failure("无法复制目录描述符") }
        guard let stream = fdopendir(copy) else { close(copy); throw failure("无法枚举目录") }
        defer { closedir(stream) }
        rewinddir(stream)
        var names: [String] = []
        while true {
            if cancelled() { throw CancellationError() }
            errno = 0
            guard let entry = readdir(stream) else {
                if errno != 0 { throw failure("目录未完整读取") }; break
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(validatingUTF8: $0) }
            }
            guard let name else { throw UninstallFailure(message: "目录含无法识别的文件名。") }
            if name == "." || name == ".." { continue }
            names.append(name)
            guard names.count <= 100_000 else { throw UninstallFailure(message: "目录条目超过安全上限，已停止。") }
        }
        return names.sorted()
    }
    static func stamp(_ info: stat, movedRoot: Bool = false) -> String {
        let id = UninstallIdentity(info)
        // rename changes the moved root's ctime; descendants must stay identical.
        return "\(id.device)|\(id.inode)|\(info.st_mode)|\(info.st_uid)|\(info.st_gid)|\(info.st_nlink)|\(info.st_size)|\(info.st_blocks)|\(info.st_flags)|\(info.st_mtimespec.tv_sec)|\(info.st_mtimespec.tv_nsec)|" +
            (movedRoot ? "root" : "\(info.st_ctimespec.tv_sec)|\(info.st_ctimespec.tv_nsec)")
    }
    static func snapshot(_ url: URL, appBundle: Bool, cancelled: () -> Bool = { false }) throws -> UninstallFootprint {
        let parent = try directory(url.deletingLastPathComponent())
        defer { close(parent) }
        let root = try info(parent: parent, name: url.lastPathComponent)
        let rootID = UninstallIdentity(root)
        guard rootID.kind == UInt32(S_IFDIR), rootID.uid == uid || (appBundle && rootID.uid == 0) else {
            throw UninstallFailure(message: "项目类型或所有者不受支持。")
        }
        var digest = SHA256(), bytes: Int64 = 0, newest: TimeInterval = 0, entries = 0
        let started = ProcessInfo.processInfo.systemUptime
        func record(_ value: stat, relative: String, link: String = "") {
            let line = "\(relative.utf8.count):\(relative)|\(stamp(value, movedRoot: relative.isEmpty))|\(link.utf8.count):\(link)\n"
            digest.update(data: Data(line.utf8))
            let amount = Int64(value.st_blocks).multipliedReportingOverflow(by: 512)
            bytes = add(bytes, amount.overflow ? Int64.max : max(0, amount.partialValue))
            newest = max(newest, Double(value.st_mtimespec.tv_sec) + Double(value.st_mtimespec.tv_nsec) / 1e9)
        }
        func walk(parent: Int32, name: String, relative: String, depth: Int) throws {
            if cancelled() { throw CancellationError() }
            guard ProcessInfo.processInfo.systemUptime - started <= 20, depth < 64, entries < 100_000 else {
                throw UninstallFailure(message: "项目扫描超过时间、条目或深度预算；未完成的项目不可卸载。")
            }
            entries += 1
            let before = try info(parent: parent, name: name)
            let id = UninstallIdentity(before)
            guard id.device == rootID.device, id.uid == uid || (appBundle && id.uid == 0) else {
                throw UninstallFailure(message: "项目跨卷或含其他用户的文件。")
            }
            let kind = before.st_mode & S_IFMT
            guard kind == S_IFDIR || kind == S_IFREG || (appBundle && kind == S_IFLNK && !relative.isEmpty) else {
                throw UninstallFailure(message: "项目含不受支持的链接或特殊文件。")
            }
            guard kind != S_IFREG || before.st_nlink == 1 else { throw UninstallFailure(message: "项目含硬链接，已保留。") }
            if kind != S_IFDIR {
                var link = ""
                if kind == S_IFLNK {
                    var buffer = [CChar](repeating: 0, count: 16_385)
                    let count = readlinkat(parent, name, &buffer, buffer.count - 1)
                    guard count >= 0, count < buffer.count - 1 else { throw failure("无法读取框架链接自身") }
                    let data = Data(buffer.prefix(count).map { UInt8(bitPattern: $0) })
                    guard let text = String(data: data, encoding: .utf8) else { throw UninstallFailure(message: "无法安全记录框架链接。") }
                    link = text
                }
                let after = try info(parent: parent, name: name)
                guard stamp(before, movedRoot: relative.isEmpty) == stamp(after, movedRoot: relative.isEmpty) else {
                    throw UninstallFailure(message: "文件在核验时改变。")
                }
                record(before, relative: relative, link: link)
                return
            }
            let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
            guard fd >= 0 else { throw failure("目录无法安全枚举") }
            defer { close(fd) }
            var opened = stat()
            guard fstat(fd, &opened) == 0, stamp(before, movedRoot: relative.isEmpty) == stamp(opened, movedRoot: relative.isEmpty) else {
                throw UninstallFailure(message: "目录在打开时改变。")
            }
            record(opened, relative: relative)
            for child in try names(fd, cancelled: cancelled) {
                try walk(parent: fd, name: child, relative: relative.isEmpty ? child : relative + "/" + child, depth: depth + 1)
            }
            var after = stat()
            guard fstat(fd, &after) == 0, stamp(opened, movedRoot: relative.isEmpty) == stamp(after, movedRoot: relative.isEmpty) else {
                throw UninstallFailure(message: "目录在扫描时改变。")
            }
        }
        try walk(parent: parent, name: url.lastPathComponent, relative: "", depth: 0)
        return UninstallFootprint(identity: rootID, digest: digest.finalize().map { String(format: "%02x", $0) }.joined(), bytes: bytes, newest: newest, entries: entries)
    }
    static func data(parent: Int32, name: String, limit: Int) throws -> Data {
        let before = try info(parent: parent, name: name)
        guard before.st_mode & S_IFMT == S_IFREG, before.st_nlink == 1, before.st_size >= 0, before.st_size <= limit else {
            throw UninstallFailure(message: "元数据文件类型或大小无效。")
        }
        let fd = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw failure("无法读取元数据") }
        defer { close(fd) }
        var opened = stat()
        guard fstat(fd, &opened) == 0, stamp(before) == stamp(opened) else { throw UninstallFailure(message: "元数据在打开时改变。") }
        var result = Data(), buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0 { if errno == EINTR { continue }; throw failure("元数据读取失败") }
            if count == 0 { break }
            result.append(contentsOf: buffer.prefix(count))
            guard result.count <= limit else { throw UninstallFailure(message: "元数据超过大小限制。") }
        }
        var after = stat()
        guard fstat(fd, &after) == 0, stamp(before) == stamp(after), result.count == before.st_size else {
            throw UninstallFailure(message: "元数据未完整读取或在读取时改变。")
        }
        return result
    }
    static func rename(from: Int32, name: String, to: Int32, destination: String) throws {
        guard renameatx_np(from, name, to, destination, UInt32(RENAME_EXCL)) == 0 else { throw failure("无法移动，目标可能已有新文件或权限不足") }
        guard fsync(from) == 0, fsync(to) == 0 else { throw failure("移动后目录同步失败，恢复记录已保留") }
    }
    static func atomicData(_ data: Data, directory fd: Int32, name: String) throws {
        let temporary = "uninstall-\(UUID().uuidString).tmp"
        let file = openat(fd, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard file >= 0 else { throw failure("无法创建恢复记录") }
        defer { close(file); unlinkat(fd, temporary, 0) }
        try data.withUnsafeBytes { raw in
            var done = 0
            while done < raw.count {
                let count = Darwin.write(file, raw.baseAddress!.advanced(by: done), raw.count - done)
                if count < 0 { if errno == EINTR { continue }; throw failure("恢复记录写入失败") }
                guard count > 0 else { throw UninstallFailure(message: "恢复记录未完整写入。") }; done += count
            }
        }
        guard fsync(file) == 0, renameat(fd, temporary, fd, name) == 0, fsync(fd) == 0 else { throw failure("无法持久保存恢复记录") }
    }
    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func add(_ left: Int64, _ right: Int64) -> Int64 {
        let sum = left.addingReportingOverflow(right); return sum.overflow ? Int64.max : sum.partialValue
    }
}
