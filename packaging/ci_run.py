"""Stream a CI command and expose its failure details in Actions annotations."""

from collections import deque
import os
import shutil
import subprocess
import sys
import traceback


def main() -> int:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    command = sys.argv[1:]
    if not command:
        raise SystemExit("usage: ci_run.py COMMAND [ARG ...]")
    command[0] = shutil.which(command[0]) or command[0]
    tail: deque[str] = deque(maxlen=500)
    try:
        with subprocess.Popen(
            command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            encoding="utf-8", errors="replace",
        ) as process:
            for line in process.stdout:
                print(line, end="", flush=True)
                tail.append(line)
            result = process.wait()
    except Exception:
        detail = traceback.format_exc()
        print(detail, flush=True)
        tail.append(detail)
        result = 1
    if result and os.environ.get("GITHUB_ACTIONS") == "true":
        message = "".join(line for line in tail if not line.startswith("✅"))[-24000:]
        # Actions truncates long annotations. Keep each diagnostic chunk readable.
        for offset in range(0, len(message), 2500):
            chunk = message[offset:offset + 2500]
            chunk = chunk.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")
            print(f"::error title=Command failed ({offset // 2500 + 1})::{chunk}", flush=True)
    return result


if __name__ == "__main__":
    sys.exit(main())
