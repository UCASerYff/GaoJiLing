import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT / "src"))

from gaojiling.cli import main

if __name__ == "__main__":
    raise SystemExit(main(default_gui=False))
