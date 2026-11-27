"""只监听 127.0.0.1 的本地页面。写操作必须带本次启动生成的令牌。"""

from __future__ import annotations

import json
import math
import os
import secrets
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse

from gaojiling.errors import AppError
from gaojiling.resources import asset_root, read_asset
from gaojiling.version import display


class _Quiet(ThreadingHTTPServer):
    allow_reuse_address = False

    def handle_error(self, request, client_address):
        return


def serve(service, port: int = 0, open_browser: bool = False, token: str | None = None, background: bool = False):
    session = token or secrets.token_urlsafe(24)
    holder = {"httpd": None}

    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, fmt, *args):
            return

        def _local_request(self):
            address = f"127.0.0.1:{self.server.server_address[1]}"
            if self.headers.get("Host") not in {address, f"localhost:{self.server.server_address[1]}"}:
                self._json(403, {"error": "只接受本机窗口请求。"})
                return False
            origin = self.headers.get("Origin")
            if origin and origin not in {f"http://{address}", f"http://localhost:{self.server.server_address[1]}"}:
                self._json(403, {"error": "请求来源不是本机窗口。"})
                return False
            return True

        def do_GET(self):
            if not self._local_request():
                return
            parsed = urlparse(self.path)
            if parsed.path == "/":
                page = read_asset("index.html").decode("utf-8")
                page = page.replace("__GAO_TOKEN__", session).replace("__GAO_VERSION__", display())
                self._bytes(200, page.encode("utf-8"), "text/html; charset=utf-8")
                return
            if parsed.path == "/app.css":
                self._bytes(200, read_asset("app.css"), "text/css; charset=utf-8")
                return
            if parsed.path == "/app.js":
                self._bytes(200, read_asset("app.js"), "text/javascript; charset=utf-8")
                return
            if parsed.path == "/icon.png":
                self._bytes(200, read_asset("AppIcon.png"), "image/png")
                return
            if parsed.path == "/help.txt":
                self._bytes(200, read_asset("help.txt"), "text/plain; charset=utf-8")
                return
            if parsed.path.startswith("/api/"):
                self._api("GET", parsed.path, b"")
                return
            self._bytes(404, b"not found", "text/plain")

        def do_POST(self):
            if not self._local_request():
                return
            try:
                length = int(self.headers.get("Content-Length") or 0)
                if length < 0:
                    raise ValueError
            except ValueError:
                self._json(400, {"error": "请求长度无效。"})
                return
            if length > 2 * 1024 * 1024:
                self._json(413, {"error": "请求过大。"})
                return
            body = self.rfile.read(length) if length else b""
            self._api("POST", urlparse(self.path).path, body)

        def _api(self, method, path, body):
            supplied = self.headers.get("X-Gao-Token") or ""
            if len(supplied) != len(session) or not secrets.compare_digest(supplied, session):
                self._json(401, {"error": "页面令牌无效。请刷新本机页面。"})
                return
            try:
                payload = json.loads(body.decode("utf-8")) if body else {}
                if not isinstance(payload, dict):
                    raise AppError("请求格式无效。")
                if method == "GET" and path != "/api/state":
                    self._json(405, {"error": "该接口需要 POST。"})
                    return
                if path == "/api/state":
                    if self.headers.get("X-Gao-Visible") == "1":
                        service._interactive = time.monotonic()
                    result = dispatch(service, method, path, payload)
                elif path in {"/api/cancel", "/api/history"}:
                    result = dispatch(service, method, path, payload)
                else:
                    if not service._mutation_lock.acquire(blocking=False):
                        raise AppError("另一个工作正在进行。")
                    try:
                        result = dispatch(service, method, path, payload)
                    finally:
                        service._mutation_lock.release()
            except AppError as error:
                self._json(400, {"error": error.message})
                return
            except Exception as error:
                self._json(500, {"error": str(error)})
                return
            if path == "/api/shutdown":
                self._json(200, {"ok": True})
                threading.Thread(target=holder["httpd"].shutdown, daemon=True).start()
                return
            self._json(200, result if isinstance(result, dict) else {"result": result})

        def _json(self, status, payload):
            data = json.dumps(payload, ensure_ascii=False).encode("utf-8")
            self._bytes(status, data, "application/json; charset=utf-8")

        def _bytes(self, status, data, content_type):
            self.send_response(status)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(data)))
            self.send_header("Cache-Control", "no-store")
            self.send_header("X-Content-Type-Options", "nosniff")
            self.send_header("Content-Security-Policy", "default-src 'self'; style-src 'self' 'unsafe-inline'; frame-ancestors 'none'; base-uri 'none'")
            self.end_headers()
            self.wfile.write(data)

    httpd = _Quiet(("127.0.0.1", port), Handler)
    holder["httpd"] = httpd
    if open_browser:
        import webbrowser
        webbrowser.open(f"http://127.0.0.1:{httpd.server_address[1]}/")
    if background:
        threading.Thread(target=httpd.serve_forever, daemon=True).start()
    return httpd, session


def dispatch(service, method, path, payload):
    if path == "/api/state":
        return service.state()
    if path == "/api/history":
        after, before = float(payload["after"]), float(payload["before"])
        if not math.isfinite(after) or not math.isfinite(before) or not 0 <= before - after <= 87_000:
            raise AppError("请选择有效的回看范围。")
        return {"history": service.history_range(after, before)}
    if path == "/api/sample":
        return {"sample": service.sample_once()}
    if path == "/api/pause":
        service.set_paused(bool(payload.get("paused")))
        return {"paused": service.paused}
    if path == "/api/session/start":
        return {"session": service.start_session(payload.get("name") or "")}
    if path == "/api/session/stop":
        return {"session": service.stop_session()}
    if path == "/api/settings":
        return {"settings": service.update_settings(payload)}
    if path == "/api/export":
        return service.export_csv(payload.get("kind"), payload.get("path"), payload.get("after"), payload.get("before"), payload.get("sessionId"))
    if path == "/api/backup/export":
        return service.export_backup(payload.get("path"))
    if path == "/api/backup/restore":
        return service.restore_backup(payload.get("path"), payload.get("confirmNoAutoBackup") is True)
    if path == "/api/data/clear":
        if payload.get("confirm") is not True:
            raise AppError("需要明确确认后清除所选记录。")
        return service.clear_data(payload.get("scope"), payload.get("before"))
    if path == "/api/cleanup/scan":
        return service.cleanup_scan()
    if path == "/api/cleanup/trash":
        return service.cleanup_trash(payload.get("ids") or [], payload.get("confirm") is True, payload.get("reviewId"))
    if path == "/api/cleanup/restore":
        if payload.get("confirm") is not True:
            raise AppError("请明确确认恢复所选批次。")
        return service.cleanup_restore(payload.get("batchId"))
    if path == "/api/storage/analyze":
        return service.storage_scan(payload.get("mode"), payload.get("path"), payload.get("exclusions") or [], payload.get("reviewId"))
    if path == "/api/storage/csv":
        return service.storage_csv(payload.get("path"))
    if path == "/api/duplicates/scan":
        return service.duplicate_scan(payload.get("path"), payload.get("confirmRead") is True, payload.get("reviewId"))
    if path == "/api/duplicates/move":
        return service.duplicate_move(payload.get("ids") or [], payload.get("confirm") is True)
    if path == "/api/duplicates/restore":
        if payload.get("confirm") is not True:
            raise AppError("请明确确认恢复所选批次。")
        return service.duplicates.restore(payload.get("batchId"))
    if path == "/api/volumes":
        return service.volumes()
    if path == "/api/ntfs/analyze":
        return service.ntfs(payload.get("path"), payload.get("consent") is True)
    if path == "/api/ntfs/report":
        return service.ntfs_report(payload.get("path"))
    if path == "/api/ntfs/extract":
        return service.ntfs_extract(payload.get("entryId"), payload.get("destination"), payload.get("confirm") is True)
    if path == "/api/network":
        return {"checks": service.network(payload.get("host") or "")}
    if path == "/api/memory/own":
        return service.memory_own()
    if path == "/api/memory/system":
        return service.memory_system()
    if path == "/api/apps/refresh":
        service.last_apps = service.apps.refresh()
        return service.last_apps
    if path == "/api/apps/portable":
        return service.app_add_portable(payload.get("path"), payload.get("name"))
    if path == "/api/apps/uninstall":
        return service.app_uninstall(payload.get("ids") or [], payload.get("confirm") is True, payload.get("reviewId"))
    if path == "/api/apps/restore":
        if payload.get("confirm") is not True:
            raise AppError("请明确确认恢复所选批次。")
        return service.apps.restore(payload.get("batchId"))
    if path == "/api/exchange/import":
        record = service.exchange.receive_package(payload.get("path") or "")
        return {"record": {"id": record["id"], "phase": record["phase"], "action": record["manifest"]["action"]}}
    if path == "/api/exchange/receive":
        return {"record": service.exchange.receive((payload.get("manifest") or "").encode("utf-8"))}
    if path == "/api/exchange/open":
        return service.review_open(payload.get("id") or "")
    if path == "/api/exchange/approve":
        return service.review_approve(payload.get("id") or "")
    if path == "/api/exchange/cancel":
        service.exchange.finish(payload.get("id") or "", "cancelled", {"workflowState": "cancelled"})
        return {"message": "已取消所选请求。"}
    if path == "/api/exchange/export":
        return service.exchange_export(payload.get("id") or "", payload.get("path"))
    if path == "/api/cancel":
        return service.cancel(payload.get("scope"))
    if path.startswith("/api/desktop/"):
        desktop = service.desktop
        if desktop is None:
            raise AppError("需要从 Windows 桌面程序打开此功能。")
        if path == "/api/desktop/choose":
            return {"path": desktop.choose(payload.get("kind"), payload.get("suggested"))}
        if path == "/api/desktop/settings":
            desktop.open_settings(payload.get("tab") or "module")
            return {"ok": True}
        if path == "/api/desktop/notification-settings":
            desktop.open_notification_settings()
            return {"ok": True}
        if path == "/api/desktop/reposition":
            desktop.reposition(payload.get("reset") is True)
            return {"ok": True}
    if path.startswith("/api/system/") and os.name == "nt":
        target = {
            "/api/system/data": service.data_dir,
            "/api/system/last-export": service.last_export.parent if service.last_export else None,
            "/api/system/task-manager": os.path.join(os.environ.get("SystemRoot", r"C:\Windows"), "System32", "Taskmgr.exe"),
            "/api/system/installed-apps": "ms-settings:appsfeatures",
            "/api/system/guide": asset_root() / "help.txt",
        }.get(path)
        if target:
            os.startfile(str(target))
            return {"ok": True}
    if path == "/api/shutdown":
        return {"ok": True}
    raise AppError("没有这个接口。")
