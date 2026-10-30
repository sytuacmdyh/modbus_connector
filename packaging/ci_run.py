"""Stream a CI command and expose its failure details in Actions annotations."""

from collections import deque
import os
import shutil
import subprocess
import sys


def main() -> int:
    command = sys.argv[1:]
    if not command:
        raise SystemExit("usage: ci_run.py COMMAND [ARG ...]")
    command[0] = shutil.which(command[0]) or command[0]
    tail: deque[str] = deque(maxlen=180)
    with subprocess.Popen(
        command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
        encoding="utf-8", errors="replace",
    ) as process:
        for line in process.stdout:
            print(line, end="", flush=True)
            tail.append(line)
        result = process.wait()
    if result and os.environ.get("GITHUB_ACTIONS") == "true":
        message = "".join(tail)[-24000:]
        message = message.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")
        print(f"::error title=Command failed::{message}", flush=True)
    return result


if __name__ == "__main__":
    sys.exit(main())
