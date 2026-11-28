"""按需网络诊断。只在使用者提交后做 DNS、网关探测和指定主机的 HTTPS HEAD。"""

from __future__ import annotations

import ctypes
from ipaddress import IPv4Address
import re
import socket
import sys
import time
import urllib.error
import urllib.request

from gaojiling.errors import AppError

_HOST = re.compile(r"^(?=.{1,253}$)(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)*[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?$")
_IPV4 = re.compile(r"^(?:\d{1,3}\.){3}\d{1,3}$")
_ERROR_INSUFFICIENT_BUFFER = 122
_DIRECT_ROUTE = 3
_INDIRECT_ROUTE = 4
_UNUSED_METRIC = 0xFFFFFFFF
_MAX_ROUTE_TABLE_BYTES = 4 * 1024 * 1024


class _IPv4ForwardRow(ctypes.Structure):
    # MIB_IPFORWARDROW. Fields use fixed-width Windows DWORDs.
    _fields_ = [
        ("destination", ctypes.c_uint32),
        ("mask", ctypes.c_uint32),
        ("policy", ctypes.c_uint32),
        ("next_hop", ctypes.c_uint32),
        ("interface", ctypes.c_uint32),
        ("type", ctypes.c_uint32),
        ("protocol", ctypes.c_uint32),
        ("age", ctypes.c_uint32),
        ("next_hop_as", ctypes.c_uint32),
        ("metric", ctypes.c_uint32),
        ("other_metrics", ctypes.c_uint32 * 4),
    ]


class _IPv4ForwardTable(ctypes.Structure):
    _fields_ = [("count", ctypes.c_uint32), ("rows", _IPv4ForwardRow * 1)]


def _route_table_gateway(buffer, length: int) -> str | None:
    offset = _IPv4ForwardTable.rows.offset
    if not offset <= length <= ctypes.sizeof(buffer):
        return None
    count = ctypes.c_uint32.from_buffer(buffer).value
    row_bytes = ctypes.sizeof(_IPv4ForwardRow)
    if count > (length - offset) // row_bytes:
        return None

    # Windows includes the interface cost in dwForwardMetric1.
    best_metric = _UNUSED_METRIC
    best_hops = set()
    for row in (_IPv4ForwardRow * count).from_buffer(buffer, offset):
        if (row.destination or row.mask or not row.interface or row.type not in {_DIRECT_ROUTE, _INDIRECT_ROUTE}
                or row.metric == _UNUSED_METRIC or row.metric > best_metric):
            continue
        if row.metric < best_metric:
            best_metric = row.metric
            best_hops.clear()
        # The DWORD holds bytes in network order even on little-endian Windows.
        hop = IPv4Address(row.next_hop.to_bytes(4, sys.byteorder))
        if (row.type == _DIRECT_ROUTE or hop.is_unspecified or hop.is_loopback
                or hop.is_multicast or hop.is_reserved):
            best_hops.add(None)
        else:
            best_hops.add(hop)
    # An on-link route or distinct equal-cost gateways cannot identify one next hop.
    gateway = next(iter(best_hops)) if len(best_hops) == 1 else None
    return str(gateway) if gateway is not None else None


def _windows_default_gateway() -> str | None:
    from ctypes import wintypes

    try:
        read_table = ctypes.WinDLL("iphlpapi", use_last_error=True).GetIpForwardTable
        read_table.argtypes = [ctypes.c_void_p, ctypes.POINTER(wintypes.DWORD), wintypes.BOOL]
        read_table.restype = wintypes.DWORD
        length = wintypes.DWORD()
        buffer = None
        # The route table may grow after the initial buffer-size query.
        for _ in range(4):
            capacity = ctypes.sizeof(buffer) if buffer is not None else 0
            length.value = capacity
            status = read_table(buffer, ctypes.byref(length), False)
            if status == 0 and buffer is not None:
                return _route_table_gateway(buffer, length.value)
            if status != _ERROR_INSUFFICIENT_BUFFER or not capacity < length.value <= _MAX_ROUTE_TABLE_BYTES:
                return None
            buffer = ctypes.create_string_buffer(length.value)
    except (OSError, AttributeError):
        return None
    return None


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def validate_host(host: str) -> str:
    text = (host or "").strip()
    if text != host or not text or any(char in text for char in " /\\?#@:\n\r"):
        raise AppError("请输入主机名或 IPv4 地址，不要带协议、路径或端口。")
    if _IPV4.fullmatch(text):
        parts = [int(part) for part in text.split(".")]
        if any(part > 255 for part in parts):
            raise AppError("IPv4 地址无效。")
        return text
    if not _HOST.fullmatch(text):
        raise AppError("主机名无效。")
    return text


def default_gateway() -> str | None:
    if sys.platform.startswith("linux"):
        try:
            for line in open("/proc/net/route", encoding="utf-8"):
                parts = line.split()
                if len(parts) >= 3 and parts[1] == "00000000":
                    raw = parts[2]
                    octets = [str(int(raw[index:index + 2], 16)) for index in (6, 4, 2, 0)]
                    return ".".join(octets)
        except OSError:
            return None
    if sys.platform == "win32":
        return _windows_default_gateway()
    return None


def diagnose(host: str, resolver=None, gateway=None, probe=None, https=None) -> list[dict]:
    host = validate_host(host)
    checks = []
    gate = default_gateway if gateway is None else gateway
    try:
        address = gate()
    except Exception as error:
        address = None
        checks.append({"title": "默认网关", "detail": f"读取网关失败：{error}", "success": None})
    if address:
        def tcp_probe(ip):
            started = time.monotonic()
            try:
                with socket.create_connection((ip, 80), timeout=2):
                    return True, f"{ip} · TCP 80 连通 · {int((time.monotonic() - started) * 1000)} ms"
            except OSError:
                return None, f"{ip} · 未收到可确认响应；路由器可能不接受探测。"
        success, detail = (probe or tcp_probe)(address)
        checks.append({"title": "默认网关", "detail": detail, "success": success})
    elif not checks:
        checks.append({"title": "默认网关", "detail": "未找到 IPv4 默认网关。", "success": None})

    def resolve(name):
        found = []
        for item in socket.getaddrinfo(name, 443, type=socket.SOCK_STREAM):
            found.append(item[4][0])
        return list(dict.fromkeys(found))[:4]

    try:
        addresses = (resolver or resolve)(host)
    except Exception as error:
        addresses = []
        checks.append({"title": "DNS 解析", "detail": f"系统解析未返回地址：{error}。仍将尝试 HTTPS 连接。", "success": None})
    else:
        checks.append({"title": "DNS 解析", "detail": " · ".join(addresses) if addresses else "系统解析未返回地址；仍将尝试 HTTPS 连接。", "success": True if addresses else None})

    def head(name):
        request = urllib.request.Request(f"https://{name}/", method="HEAD")
        request.add_header("User-Agent", "GaoJiLing")
        started = time.monotonic()
        try:
            opener = urllib.request.build_opener(_NoRedirect())
            with opener.open(request, timeout=8) as response:
                code = getattr(response, "status", 0)
                return True, code, int((time.monotonic() - started) * 1000), None
        except urllib.error.HTTPError as error:
            with error:
                return True, error.code, int((time.monotonic() - started) * 1000), None
        except Exception as error:
            return False, 0, int((time.monotonic() - started) * 1000), str(error)

    ok, code, elapsed, error = (https or head)(host)
    if ok:
        checks.append({"title": "HTTPS 连接", "detail": f"{host} · {elapsed} ms · HTTP {code}。耗时包含解析、TLS 和服务器响应。", "success": True})
        if code >= 400:
            checks.append({"title": "服务状态", "detail": f"服务器已响应，但返回 HTTP {code}；可能限制 HEAD 请求或需要登录。", "success": None})
    else:
        checks.append({"title": "HTTPS 连接", "detail": error or "连接失败", "success": False})
    return checks
