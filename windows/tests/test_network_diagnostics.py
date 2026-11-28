import ctypes
from email.message import Message
import io
import socket
import struct
from types import SimpleNamespace
from urllib import request, response

import pytest

from gaojiling import network


def _route(gateway, metric, *, destination="0.0.0.0", mask="0.0.0.0", route_type=4, interface=5):
    return struct.pack(
        "<4s4sI4s10I", socket.inet_aton(destination), socket.inet_aton(mask), 0,
        socket.inet_aton(gateway), interface, route_type, 3, 0, 0, metric, *([0xFFFFFFFF] * 4),
    )


def _table(*rows):
    return struct.pack("<I", len(rows)) + b"".join(rows)


def _mock_native(monkeypatch, replies):
    replies = iter(replies)
    calls = []

    def get_table(buffer, length, ordered):
        size = length._obj
        assert size.value == (0 if buffer is None else ctypes.sizeof(buffer))
        assert ordered is False
        calls.append(size.value)
        code, data = next(replies)
        if isinstance(data, bytes):
            assert buffer is not None and len(data) <= size.value
            ctypes.memmove(buffer, data, len(data))
            size.value = len(data)
        else:
            size.value = data
        return code

    def load_native(name, *, use_last_error):
        assert name == "iphlpapi" and use_last_error
        return SimpleNamespace(GetIpForwardTable=get_table)

    monkeypatch.setattr(network, "sys", SimpleNamespace(platform="win32", byteorder="little"))
    monkeypatch.setattr(ctypes, "WinDLL", load_native, raising=False)
    return calls


def test_windows_default_gateway_retries_growth_and_uses_verified_default_route(monkeypatch):
    candidates = _table(
        _route("192.0.2.5", 25),
        _route("203.0.113.25", 1, destination="203.0.113.0", mask="255.255.255.0"),
        _route("192.0.2.23", 2, route_type=2),
        _route("198.51.100.10", 7),
        _route("198.51.100.10", 7, interface=6),
        _route("192.0.2.65", 1, interface=0),
        _route("192.0.2.66", 0xFFFFFFFF),
    )
    sizes = _mock_native(monkeypatch, [(122, 60), (122, len(candidates)), (0, candidates)])
    assert network.default_gateway() == "198.51.100.10"
    assert sizes == [0, 60, len(candidates)]


@pytest.mark.parametrize("rows", [
    (),
    (_route("192.0.2.1", 10), _route("192.0.2.2", 10)),
    (_route("0.0.0.0", 5, route_type=3), _route("192.0.2.3", 10)),
    (_route("224.0.0.1", 5),),
    (_route("127.0.0.1", 5),),
    (_route("255.255.255.255", 5),),
])
def test_windows_default_gateway_does_not_guess(rows, monkeypatch):
    payload = _table(*rows)
    sizes = _mock_native(monkeypatch, [(122, len(payload)), (0, payload)])
    assert network.default_gateway() is None
    assert sizes == [0, len(payload)]


@pytest.mark.parametrize("replies", [
    [(5, 0)],                      # ERROR_ACCESS_DENIED
    [(232, 0)],                    # ERROR_NO_DATA
    [(122, 20 * 1024 * 1024)],     # Unreasonably large table
    [(122, 60), (122, 60)],        # Unchanged required size
    [(122, 60), (0, 61)],          # Length exceeds the allocation
    [(122, 60), (0, b"\0" * 3)],  # Truncated table header
    [(122, 60), (0, struct.pack("<I", 2) + _route("192.0.2.1", 1))],
])
def test_windows_incomplete_or_unavailable_route_tables_are_safe(monkeypatch, replies):
    _mock_native(monkeypatch, replies)
    assert network.default_gateway() is None


def test_windows_missing_ip_helper_leaves_gateway_unknown(monkeypatch):
    def missing(*args, **kwargs):
        raise OSError("fixture: IP Helper unavailable")

    monkeypatch.setattr(network, "sys", SimpleNamespace(platform="win32", byteorder="little"))
    monkeypatch.setattr(ctypes, "WinDLL", missing, raising=False)
    assert network.default_gateway() is None


@pytest.mark.parametrize(("code", "location"), [
    (200, None),
    (301, "https://fixture.invalid/landing"),
    (302, "http://different.invalid/"),
    (303, "https://different.invalid/"),
    (307, "https://different.invalid/"),
    (308, "https://different.invalid/"),
    (405, None),
])
def test_default_probe_attempts_only_one_https_head(monkeypatch, code, location):
    sent = []
    contents = io.BytesIO()

    class FixtureHTTPS(request.HTTPSHandler):
        def https_open(self, outgoing):
            sent.append((outgoing.get_method(), outgoing.full_url))
            # Fail immediately if a redirect attempts any additional request.
            assert sent == [("HEAD", "https://fixture.invalid/")]
            headers = Message()
            if location:
                headers["Location"] = location
            reply = response.addinfourl(contents, headers, outgoing.full_url, code)
            reply.msg = "Fixture response"
            return reply

    class RejectHTTP(request.HTTPHandler):
        def http_open(self, outgoing):
            sent.append((outgoing.get_method(), outgoing.full_url))
            pytest.fail("The probe must stay HTTPS")

    build_opener = request.build_opener
    monkeypatch.setattr(request, "build_opener", lambda *handlers: build_opener(
        request.ProxyHandler({}), FixtureHTTPS(), RejectHTTP(), *handlers,
    ))
    checks = network.diagnose("fixture.invalid", resolver=lambda _host: ["192.0.2.8"], gateway=lambda: None)
    assert sent == [("HEAD", "https://fixture.invalid/")]
    assert contents.closed
    assert checks[2]["success"] is True and f"HTTP {code}" in checks[2]["detail"]
    assert len(checks) == (4 if code >= 400 else 3)
