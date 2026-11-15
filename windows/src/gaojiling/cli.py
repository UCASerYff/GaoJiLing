import argparse
import os
import sys
from pathlib import Path

from gaojiling.service import Service, default_data_dir
from gaojiling.version import display
from gaojiling.web import serve


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(prog="GaoJiLing", description="搞机灵 Windows 版")
    parser.add_argument("--data-dir", default=os.environ.get("GAOJILING_DATA_DIR"))
    parser.add_argument("--serve", action="store_true")
    parser.add_argument("--no-browser", action="store_true")
    parser.add_argument("--port", type=int, default=0)
    parser.add_argument("--version", action="store_true")
    parser.add_argument("--inspect", action="store_true")
    args = parser.parse_args(argv)
    if args.version:
        print(display())
        return 0
    directory = Path(args.data_dir) if args.data_dir else default_data_dir()
    service = Service(directory, start_sampling=not args.inspect)
    try:
        if args.inspect:
            counts = service.store.counts()
            if service.store.db is None:
                print(service.store.status or "历史数据暂时无法读取")
                return 1
            print(f"samples {counts['samples']}")
            print(f"events {counts['events']}")
            print(f"sessions {counts['sessions']}")
            return 0
        if args.port < 0 or args.port > 65535:
            print("端口无效", file=sys.stderr)
            return 2
        httpd, _token = serve(service, port=args.port, open_browser=not args.no_browser)
        try:
            httpd.serve_forever()
        except KeyboardInterrupt:
            return 0
    finally:
        service.close()
    return 0
