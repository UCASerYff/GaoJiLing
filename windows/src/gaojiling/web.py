"""只监听 127.0.0.1 的本地页面。写操作必须带本次启动生成的令牌。"""

from __future__ import annotations

import json
import secrets
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse

from gaojiling.errors import AppError
from gaojiling.resources import read_asset
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

        def do_GET(self):
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
            if parsed.path.startswith("/api/"):
                self._api("GET", parsed.path, b"")
                return
            self._bytes(404, b"not found", "text/plain")

        def do_POST(self):
            length = int(self.headers.get("Content-Length") or 0)
            if length > 256 * 1024 * 1024:
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
                result = dispatch(service, method, path, payload)
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
    if path == "/api/sample":
        return {"sample": service.sample_once(payload.get("sample"))}
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
        return service.export_csv(payload.get("kind"), payload.get("path"))
    if path == "/api/backup/export":
        return service.export_backup(payload.get("path"))
    if path == "/api/backup/restore":
        return service.restore_backup(payload.get("path"), bool(payload.get("confirmNoAutoBackup")))
    if path == "/api/data/clear":
        return service.clear_data(payload.get("scope"), payload.get("before"))
    if path == "/api/cleanup/scan":
        return service.cleanup_scan()
    if path == "/api/cleanup/trash":
        return service.cleanup_trash(payload.get("ids") or [], bool(payload.get("confirm")))
    if path == "/api/cleanup/restore":
        return service.cleanup_restore(payload.get("batchId"))
    if path == "/api/storage/analyze":
        return service.storage_scan(payload.get("mode"), payload.get("path"), payload.get("exclusions") or [])
    if path == "/api/storage/csv":
        return service.storage_csv(payload.get("path"))
    if path == "/api/duplicates/scan":
        return service.duplicate_scan(payload.get("path"), bool(payload.get("confirmRead")))
    if path == "/api/duplicates/move":
        return service.duplicate_move(payload.get("ids") or [], bool(payload.get("confirm")))
    if path == "/api/volumes":
        return service.volumes()
    if path == "/api/ntfs/analyze":
        return service.ntfs(payload.get("path"), bool(payload.get("consent")))
    if path == "/api/ntfs/extract":
        return service.ntfs_extract(payload.get("entryId"), payload.get("destination"), bool(payload.get("confirm")))
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
        app = service.apps.add_portable(payload.get("path"), payload.get("name"))
        service.last_apps = {"apps": list(service.apps.plan.values()), "notes": []}
        return {"app": app}
    if path == "/api/apps/uninstall":
        confirmed = bool(payload.get("notRunning"))
        lookup = (lambda _path: False) if confirmed else (lambda _path: None)
        return service.apps.uninstall(payload.get("ids") or [], lookup)
    if path == "/api/exchange/import":
        record = service.exchange.receive_package(payload.get("path") or "")
        return {"record": {"id": record["id"], "phase": record["phase"], "action": record["manifest"]["action"]}}
    if path == "/api/exchange/receive":
        return {"record": service.exchange.receive((payload.get("manifest") or "").encode("utf-8"))}
    if path == "/api/exchange/open":
        return service.exchange.open_request(payload.get("id") or "")
    if path == "/api/exchange/approve":
        return {"record": service.exchange.approve(payload.get("id") or "")}
    if path == "/api/exchange/finish":
        return {"record": service.exchange.finish(payload.get("id") or "", payload.get("status") or "", payload.get("provenance") or {}, payload.get("errorCode"))}
    if path == "/api/shutdown":
        service.close()
        return {"ok": True}
    raise AppError("没有这个接口。")
