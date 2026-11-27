import argparse
import os
import sys
import threading
from pathlib import Path

from gaojiling.autostart import Startup
from gaojiling.service import Service, default_data_dir
from gaojiling.version import display
from gaojiling.web import serve


def main(argv=None, default_gui=True) -> int:
    parser = argparse.ArgumentParser(prog="GaoJiLing", description="搞机灵 Windows 版")
    parser.add_argument("--data-dir", default=os.environ.get("GAOJILING_DATA_DIR"))
    parser.add_argument("--serve", action="store_true")
    parser.add_argument("--no-browser", action="store_true")
    parser.add_argument("--port", type=int, default=0)
    parser.add_argument("--startup", action="store_true", help="从登录启动进入托盘")
    parser.add_argument("--app-window", nargs=3, metavar=("URL", "SIGNALS", "THEME"), help=argparse.SUPPRESS)
    parser.add_argument("--version", action="store_true")
    parser.add_argument("--inspect", action="store_true")
    args = parser.parse_args(argv)
    if args.app_window:
        from gaojiling.appwindow import run

        url, signals, appearance = args.app_window
        return run(url, Path(signals), appearance == "dark")
    if args.version:
        print(display())
        return 0
    directory = Path(args.data_dir) if args.data_dir else default_data_dir()
    if args.port < 0 or args.port > 65535:
        print("端口无效", file=sys.stderr)
        return 2
    native = default_gui and os.name == "nt" and not (args.inspect or args.serve or args.no_browser)
    instance = None
    if native:
        from gaojiling.desktop import DesktopInstance

        instance = DesktopInstance(directory)
        if instance.existing:
            try:
                return 0 if args.startup or instance.activate() else 1
            finally:
                instance.close()
    service = None
    try:
        service = Service(directory, start_sampling=not args.inspect)
        service.startup = Startup.for_launch(default_data=native and not args.data_dir)
        if args.inspect:
            counts = service.store.counts()
            if service.store.db is None:
                print(service.store.status or "历史数据暂时无法读取")
                return 1
            print(f"samples {counts['samples']}")
            print(f"events {counts['events']}")
            print(f"sessions {counts['sessions']}")
            return 0
        if native:
            return run_desktop(service, args, instance)
        httpd, _token = serve(service, port=args.port, open_browser=not args.no_browser)
        try:
            with httpd:
                httpd.serve_forever()
        except KeyboardInterrupt:
            pass
    finally:
        if service:
            service.close()
        if instance:
            instance.close()
    return 0


def run_desktop(service, args, instance):
    import tkinter

    from gaojiling.desktop import Desktop, report_error

    httpd, _token = serve(service, port=args.port)
    with httpd:
        url = f"http://127.0.0.1:{httpd.server_address[1]}/"
        try:
            desktop = Desktop(service, url, instance.name, isolated=bool(args.data_dir))
        except (OSError, tkinter.TclError) as error:
            report_error(f"桌面监控未能启动：{error}")
            return 1
        service.desktop = desktop

        def run_server():
            try:
                httpd.serve_forever()
            finally:
                desktop.server_stopped()

        server = threading.Thread(target=run_server, name="gaojiling-local-web", daemon=True)
        server.start()
        try:
            desktop.run(startup=args.startup)
        finally:
            httpd.shutdown()
            server.join()
    return 0
