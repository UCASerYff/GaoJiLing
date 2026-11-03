// Migrated from GaoCiPan (MIT, Copyright (c) 2026 UCASerYff).
import Foundation
import Darwin

enum DiskImageReportWriterError: LocalizedError {
    case invalidDestination
    case overBudget
    case destinationExists
    case directoryChanged
    case temporaryChanged
    case verificationFailed
    case system(String, Int32)

    var errorDescription: String? {
        switch self {
        case .invalidDestination: return "导出目标必须是本机绝对路径下的新普通文件；路径不能包含链接、设备或特殊分量。"
        case .overBudget: return "报告超过 8 MiB 导出上限，已停止导出。"
        case .destinationExists: return "目标已经存在。为保护镜像和已有资料，请使用一个新的报告文件名；本应用不会覆盖任何已有文件。"
        case .directoryChanged: return "导出目录在操作中发生变化，无法确认目标位置。请检查目标目录后重新选择新的文件名。"
        case .temporaryChanged: return "导出临时文件身份发生变化，已停止操作。"
        case .verificationFailed: return "报告字节核验失败，已停止导出。"
        case .system(let operation, let code): return "报告导出失败（\(operation)：\(String(cString: strerror(code)))）。如目标已经创建，请保留并检查，不要重试覆盖。"
        }
    }
}

/// Creates a new report only. No existing destination is ever replaced.
/// Every directory and the output are held by file descriptors, without
/// following symlinks. This prevents path substitution from authorizing writes
/// to an existing image. It does not authenticate another process of this user.
enum DiskImageReportWriter {
    static let maximumBytes = 8 * 1024 * 1024

    static func writeNew(data: Data, to url: URL) throws {
        guard data.count <= maximumBytes else { throw DiskImageReportWriterError.overBudget }
        guard url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost" else { throw DiskImageReportWriterError.invalidDestination }
        let path = url.path
        guard path.hasPrefix("/"), !path.contains("\0"), !path.hasSuffix("/"),
              path.utf8.count < Int(PATH_MAX) else { throw DiskImageReportWriterError.invalidDestination }
        let components = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard let leaf = components.last, components.count <= 128,
              !components.contains(where: { $0 == "." || $0 == ".." || $0.utf8.count > Int(NAME_MAX) }),
              !leaf.isEmpty else { throw DiskImageReportWriterError.invalidDestination }

        let chain = try DirectoryChain(components: Array(components.dropLast()))
        defer { chain.closeAll() }
        try chain.validate()
        let directory = chain.lastFD
        var targetStat = stat()
        if fstatat(directory, leaf, &targetStat, AT_SYMLINK_NOFOLLOW) == 0 { throw DiskImageReportWriterError.destinationExists }
        guard errno == ENOENT else { throw DiskImageReportWriterError.system("检查目标", errno) }

        let temporary = ".gaojiling-image-report-\(UUID().uuidString).tmp"
        let output = openat(directory, temporary, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard output >= 0 else { throw DiskImageReportWriterError.system("创建临时报告", errno) }
        var ownStat = stat()
        var published = false
        var haveIdentity = false
        defer {
            // Only unlink our original temporary inode. Never delete a target
            // or a name replaced by another process, including after publish.
            if !published && haveIdentity {
                var current = stat()
                if fstatat(directory, temporary, &current, AT_SYMLINK_NOFOLLOW) == 0,
                   sameIdentity(current, ownStat), (current.st_mode & S_IFMT) == S_IFREG {
                    _ = unlinkat(directory, temporary, 0)
                }
            }
            _ = Darwin.close(output)
        }
        guard fstat(output, &ownStat) == 0 else { throw DiskImageReportWriterError.system("核验临时文件", errno) }
        haveIdentity = true
        guard (ownStat.st_mode & S_IFMT) == S_IFREG, ownStat.st_nlink == 1 else { throw DiskImageReportWriterError.temporaryChanged }
        guard fchmod(output, mode_t(0o600)) == 0 else { throw DiskImageReportWriterError.system("设置报告权限", errno) }

        try data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            var written = 0
            while written < buffer.count {
                let amount = Darwin.write(output, buffer.baseAddress!.advanced(by: written), min(65_536, buffer.count - written))
                if amount < 0 && errno == EINTR { continue }
                guard amount > 0 else { throw DiskImageReportWriterError.system("写入报告", amount < 0 ? errno : EIO) }
                written += amount
            }
            var verified = 0
            var scratch = [UInt8](repeating: 0, count: 65_536)
            while verified < buffer.count {
                let wanted = min(scratch.count, buffer.count - verified)
                let amount = scratch.withUnsafeMutableBytes { Darwin.pread(output, $0.baseAddress!, wanted, off_t(verified)) }
                if amount < 0 && errno == EINTR { continue }
                guard amount == wanted else { throw DiskImageReportWriterError.verificationFailed }
                let equal = scratch.withUnsafeBytes { memcmp($0.baseAddress!, buffer.baseAddress!.advanced(by: verified), wanted) == 0 }
                guard equal else { throw DiskImageReportWriterError.verificationFailed }
                verified += wanted
            }
        }
        var currentFDStat = stat()
        guard fstat(output, &currentFDStat) == 0 else { throw DiskImageReportWriterError.system("核验报告长度", errno) }
        guard sameIdentity(currentFDStat, ownStat), currentFDStat.st_size == data.count, currentFDStat.st_nlink == 1,
              (currentFDStat.st_mode & S_IFMT) == S_IFREG else { throw DiskImageReportWriterError.temporaryChanged }
        guard fsync(output) == 0 else { throw DiskImageReportWriterError.system("同步报告", errno) }
        try chain.validate()
        var temporaryStat = stat()
        guard fstatat(directory, temporary, &temporaryStat, AT_SYMLINK_NOFOLLOW) == 0,
              sameIdentity(temporaryStat, ownStat), (temporaryStat.st_mode & S_IFMT) == S_IFREG,
              temporaryStat.st_nlink == 1 else { throw DiskImageReportWriterError.temporaryChanged }

        // Darwin RENAME_EXCL is an atomic no-replace publish. A destination
        // created after the initial check is refused by the kernel too.
        if renameatx_np(directory, temporary, directory, leaf, UInt32(RENAME_EXCL)) != 0 {
            let code = errno
            if code == EEXIST || code == ENOTEMPTY { throw DiskImageReportWriterError.destinationExists }
            throw DiskImageReportWriterError.system("发布新报告", code)
        }
        published = true
        guard fsync(directory) == 0 else { throw DiskImageReportWriterError.system("同步报告目录", errno) }
        try chain.validate()
        var finalStat = stat()
        guard fstatat(directory, leaf, &finalStat, AT_SYMLINK_NOFOLLOW) == 0,
              sameIdentity(finalStat, ownStat), (finalStat.st_mode & S_IFMT) == S_IFREG,
              finalStat.st_size == data.count, finalStat.st_nlink == 1 else { throw DiskImageReportWriterError.verificationFailed }
    }

    private static func sameIdentity(_ a: stat, _ b: stat) -> Bool { a.st_dev == b.st_dev && a.st_ino == b.st_ino }

    private final class DirectoryChain {
        private var descriptors: [Int32] = []
        private var names: [String] = []
        private var identities: [stat] = []
        var lastFD: Int32 { descriptors.last! }

        init(components: [String]) throws {
            do {
                let root = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard root >= 0 else { throw DiskImageReportWriterError.system("打开根目录", errno) }
                descriptors.append(root)
                var identity = stat()
                guard fstat(root, &identity) == 0 else { throw DiskImageReportWriterError.system("核验根目录", errno) }
                identities.append(identity)
                for name in components {
                    let next = openat(lastFD, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    guard next >= 0 else { throw DiskImageReportWriterError.invalidDestination }
                    descriptors.append(next)
                    names.append(name)
                    var value = stat()
                    guard fstat(next, &value) == 0, (value.st_mode & S_IFMT) == S_IFDIR else { throw DiskImageReportWriterError.invalidDestination }
                    identities.append(value)
                }
            } catch { closeAll(); throw error }
        }
        func validate() throws {
            for index in descriptors.indices {
                var current = stat()
                guard fstat(descriptors[index], &current) == 0, (current.st_mode & S_IFMT) == S_IFDIR,
                      DiskImageReportWriter.sameIdentity(current, identities[index]) else { throw DiskImageReportWriterError.directoryChanged }
                if index > 0 {
                    var named = stat()
                    guard fstatat(descriptors[index - 1], names[index - 1], &named, AT_SYMLINK_NOFOLLOW) == 0,
                          (named.st_mode & S_IFMT) == S_IFDIR,
                          DiskImageReportWriter.sameIdentity(named, identities[index]) else { throw DiskImageReportWriterError.directoryChanged }
                }
            }
        }
        func closeAll() { for descriptor in descriptors.reversed() { _ = Darwin.close(descriptor) }; descriptors.removeAll() }
    }
}
