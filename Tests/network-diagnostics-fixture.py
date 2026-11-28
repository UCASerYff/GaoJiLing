"""Run the native HEAD regression with two synthetic loopback HTTP origins."""

from contextlib import contextmanager
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import subprocess
import sys
from threading import Lock, Thread


@contextmanager
def serve(name, routes, record):
    class FixtureHandler(BaseHTTPRequestHandler):
        def log_message(self, *_args):
            pass

        def respond(self):
            record(name, self.command, self.path)
            status, target = routes.get(self.path, (404, None))
            self.send_response(status)
            if target is not None:
                self.send_header("Location", target)
            self.send_header("Content-Length", "0")
            self.end_headers()

        do_HEAD = respond
        do_GET = respond

    with ThreadingHTTPServer(("127.0.0.1", 0), FixtureHandler) as server:
        thread = Thread(target=server.serve_forever, kwargs={"poll_interval": 0.05}, daemon=True)
        thread.start()
        try:
            yield f"http://127.0.0.1:{server.server_address[1]}"
        finally:
            server.shutdown()
            thread.join()


def main(command):
    requests = []
    lock = Lock()

    def record(*request):
        with lock:
            requests.append(request)

    destination_routes = {"/default-target": (204, None), "/unexpected-target": (204, None)}
    with serve("destination", destination_routes, record) as destination:
        origin_routes = {
            "/default-redirect": (307, f"{destination}/default-target"),
            "/cross-origin": (302, f"{destination}/unexpected-target"),
            "/same-origin": (307, "/unexpected-target"),
            "/unexpected-target": (204, None),
            "/server-error": (503, None),
        }
        with serve("origin", origin_routes, record) as origin:
            subprocess.run([*command, origin], check=True, timeout=30)

    expected = [
        ("origin", "HEAD", "/default-redirect"),
        ("destination", "HEAD", "/default-target"),
        ("origin", "HEAD", "/cross-origin"),
        ("origin", "HEAD", "/same-origin"),
        ("origin", "HEAD", "/server-error"),
    ]
    if requests != expected:
        raise AssertionError(f"Unexpected loopback requests: {requests}")
    print("PASS: the old client followed a redirect; the diagnostics client issued only the three requested HEADs")


if __name__ == "__main__":
    main(sys.argv[1:])
