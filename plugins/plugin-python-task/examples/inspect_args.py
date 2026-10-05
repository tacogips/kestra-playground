"""Compose verification fixture and a minimal worker-local batch example."""

import json
import os
import subprocess
import sys
import time
from pathlib import Path


def main() -> None:
    """Report the exact argv received, or exercise failure and timeout handling."""
    mode = sys.argv[1] if len(sys.argv) > 1 else "echo"
    if mode == "fail":
        print("intentional failure", file=sys.stderr)
        raise SystemExit(7)
    if mode == "wait":
        child = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(60)"])
        Path("/tmp/python-task-child.pid").write_text(str(child.pid))
        Path("/tmp/python-task-parent.pid").write_text(str(os.getpid()))
        time.sleep(60)
    print(json.dumps({"args": sys.argv[1:], "cwd": str(Path.cwd())}, ensure_ascii=False))


if __name__ == "__main__":
    main()
