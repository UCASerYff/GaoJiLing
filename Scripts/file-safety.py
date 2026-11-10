#!/usr/bin/env python3
"""Read-only nofollow file inspection shared by build and install tools."""
import contextlib
import ctypes
import functools
import hashlib
import json
import os
from pathlib import Path
import stat

O_SEARCH = 0x40000000 | os.O_DIRECTORY
DATALESS = getattr(stat, "SF_DATALESS", 0x40000000)


def extended_attributes(fd):
    system = ctypes.CDLL(None, use_errno=True)
    system.flistxattr.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_int]
    system.flistxattr.restype = ctypes.c_ssize_t
    system.fgetxattr.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_uint32, ctypes.c_int]
    system.fgetxattr.restype = ctypes.c_ssize_t

    def sized(call):
        length = call(None, 0)
        if length < 0:
            raise OSError(ctypes.get_errno(), "无法读取扩展属性")
        if length > 16 * 1024 * 1024:
            raise RuntimeError("扩展属性超过安全预算")
        buffer = ctypes.create_string_buffer(length or 1)
        actual = call(buffer, length)
        if actual != length:
            raise RuntimeError("扩展属性在读取时变化")
        return buffer.raw[:length]

    result = {}
    for name in sized(lambda buffer, count: system.flistxattr(fd, buffer, count, 0)).split(b"\0"):
        if not name:
            continue
        value = sized(lambda buffer, count: system.fgetxattr(fd, name, buffer, count, 0, 0))
        result[os.fsdecode(name)] = hashlib.sha256(value).hexdigest()
    return result


def no_materialization(function):
    @functools.wraps(function)
    def wrapped(*args, **kwargs):
        system = ctypes.CDLL(None, use_errno=True)
        previous = system.getiopolicy_np(3, 1)
        if previous < 0 or system.setiopolicy_np(3, 1, 1) != 0:
            raise RuntimeError("无法禁止云占位文件下载，停止读取")
        try:
            return function(*args, **kwargs)
        finally:
            if system.setiopolicy_np(3, 1, previous) != 0:
                raise RuntimeError("无法恢复文件访问策略，读取未确认")
    return wrapped


def signature(info):
    return (info.st_dev, info.st_ino, info.st_mode, info.st_uid, info.st_gid,
            info.st_nlink, info.st_size, info.st_mtime_ns, info.st_ctime_ns, info.st_flags)


def checked_stat(name, fd):
    info = os.stat(name, dir_fd=fd, follow_symlinks=False)
    if info.st_flags & DATALESS:
        raise RuntimeError("云端占位文件不可读取，未触发下载")
    return info


@contextlib.contextmanager
def directory_fd(path, read=False):
    path = Path(path)
    if not path.is_absolute() or ".." in path.parts:
        raise RuntimeError("路径不是规范绝对路径")
    fd = os.open("/", O_SEARCH | os.O_NOFOLLOW)
    try:
        for index, part in enumerate(path.parts[1:]):
            before = checked_stat(part, fd)
            if not stat.S_ISDIR(before.st_mode):
                raise RuntimeError("父路径含链接或特殊文件")
            flags = os.O_RDONLY | os.O_DIRECTORY if read and index == len(path.parts) - 2 else O_SEARCH
            child = os.open(part, flags | os.O_NOFOLLOW, dir_fd=fd)
            after = os.fstat(child)
            if (before.st_dev, before.st_ino) != (after.st_dev, after.st_ino) or after.st_flags & DATALESS:
                os.close(child)
                raise RuntimeError("父目录在打开时被替换")
            os.close(fd)
            fd = child
        yield fd
    finally:
        os.close(fd)


def safe_lstat(path):
    path = Path(path)
    with directory_fd(path.parent) as fd:
        return checked_stat(path.name, fd)


def optional_stat(path):
    try:
        return safe_lstat(path)
    except FileNotFoundError:
        return None


def read_regular(path, limit=None):
    path = Path(path)
    with directory_fd(path.parent) as parent:
        before = checked_stat(path.name, parent)
        if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1:
            raise RuntimeError("文件不是独立普通文件")
        fd = os.open(path.name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=parent)
        try:
            if signature(before) != signature(os.fstat(fd)):
                raise RuntimeError("文件在打开时改变")
            data = bytearray()
            while True:
                chunk = os.read(fd, 1024 * 1024)
                if not chunk:
                    break
                data.extend(chunk)
                if limit is not None and len(data) > limit:
                    raise RuntimeError("文件超过允许大小")
            if signature(before) != signature(os.fstat(fd)) or len(data) != before.st_size:
                raise RuntimeError("文件在读取时改变")
            return bytes(data)
        finally:
            os.close(fd)


def digest(value):
    raw = json.dumps(value, sort_keys=True, ensure_ascii=False, separators=(",", ":")).encode()
    return hashlib.sha256(raw).hexdigest()


def file_digest(path):
    return hashlib.sha256(read_regular(path)).hexdigest()


@no_materialization
def tree_manifest(path, allow_links=False, exclude=()):
    """Return a bounded content/mode/xattr manifest without copying any file."""
    path = Path(path)
    result = {}
    count = 0
    root_info = safe_lstat(path)
    if stat.S_ISLNK(root_info.st_mode):
        raise RuntimeError("根项目不能是链接")

    def walk(parent, name, relative):
        nonlocal count
        count += 1
        if count > 1_000_000 or len(Path(relative).parts) > 64:
            raise RuntimeError("文件树超过安全预算")
        before = checked_stat(name, parent)
        if before.st_dev != root_info.st_dev or before.st_uid not in (0, os.getuid()):
            raise RuntimeError("文件树跨卷或含其他用户的文件")
        mode = stat.S_IMODE(before.st_mode)
        if stat.S_ISLNK(before.st_mode):
            if not allow_links or not relative:
                raise RuntimeError("文件树含不允许的链接")
            text = os.readlink(name, dir_fd=parent)
            if signature(before) != signature(checked_stat(name, parent)):
                raise RuntimeError("链接在读取时改变")
            result[relative] = {"type": "link", "target": text}
            return
        if stat.S_ISDIR(before.st_mode):
            fd = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=parent)
            try:
                if signature(before) != signature(os.fstat(fd)):
                    raise RuntimeError("目录在打开时改变")
                result[relative] = {"type": "directory", "mode": mode, "xattrs": extended_attributes(fd)}
                for child in sorted(os.listdir(fd)):
                    if not relative and child in exclude:
                        continue
                    walk(fd, child, str(Path(relative) / child) if relative else child)
                if signature(before) != signature(os.fstat(fd)):
                    raise RuntimeError("目录在读取时改变")
            finally:
                os.close(fd)
            return
        if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1:
            raise RuntimeError("文件树含硬链接或特殊文件")
        fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=parent)
        try:
            if signature(before) != signature(os.fstat(fd)):
                raise RuntimeError("文件在打开时改变")
            checksum = hashlib.sha256()
            size = 0
            while True:
                chunk = os.read(fd, 1024 * 1024)
                if not chunk:
                    break
                checksum.update(chunk)
                size += len(chunk)
            attributes = extended_attributes(fd)
            if signature(before) != signature(os.fstat(fd)) or size != before.st_size:
                raise RuntimeError("文件在读取期间改变")
            result[relative] = {"type": "file", "mode": mode, "sha256": checksum.hexdigest(), "xattrs": attributes}
        finally:
            os.close(fd)

    with directory_fd(path.parent) as parent:
        walk(parent, path.name, "")
    return result
