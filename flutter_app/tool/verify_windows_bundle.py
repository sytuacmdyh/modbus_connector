"""Exercise the frozen Windows bridge from an unrelated working directory.

Only disposable loopback simulators and temporary Flutter data are used.
"""

from __future__ import annotations

import argparse
import json
import os
import queue
import socket
import subprocess
import tempfile
import threading
from pathlib import Path


class BridgeProcess:
    def __init__(self, executable: Path, directory: Path):
        self.process = subprocess.Popen(
            [str(executable)], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL, text=True, encoding="utf-8", cwd=directory,
            env={**os.environ, "MODBUS_FLUTTER_HOME": str(directory / "state")},
            creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
        )
        self.replies: queue.Queue[str] = queue.Queue()
        self.reader = threading.Thread(target=self._read, daemon=True)
        self.reader.start()
        self.counter = 0

    def _read(self):
        for line in self.process.stdout:
            self.replies.put(line)

    def call(self, command: str, **data):
        self.counter += 1
        message = json.dumps({"id": self.counter, "command": command, **data}, ensure_ascii=False)
        self.process.stdin.write(message + "\n")
        self.process.stdin.flush()
        reply = json.loads(self.replies.get(timeout=20))
        assert reply["id"] == self.counter and reply["ok"], reply
        return reply

    def close(self):
        self.process.stdin.close()
        self.process.wait(timeout=20)
        assert self.process.returncode == 0


def verify(bundle: Path) -> dict:
    executable = bundle.resolve() / "bridge/modbus_bridge.exe"
    assert executable.is_file() and (bundle / "modbus_desktop.exe").is_file()
    assert not any(p.name.lower() in {"pyside6", "numpy"} for p in executable.parent.rglob("*"))
    with tempfile.TemporaryDirectory(prefix="flutter-bundle-acceptance-") as temporary:
        directory = Path(temporary)
        with socket.socket() as reservation:
            reservation.bind(("127.0.0.1", 0))
            port = reservation.getsockname()[1]
        simulator = BridgeProcess(executable, directory)
        master = BridgeProcess(executable, directory)
        try:
            assert master.call("hello")["result"]["protocol"] == 1
            rows = [{"name": "温度", "kind": "holding_registers", "address": 0,
                     "count": 1, "format": "dec", "values": [123]}]
            simulator.call("sim_configure", rows=rows)
            simulator.call("device_start", mode="simulator", listen={
                "transport": "tcp", "host": "127.0.0.1", "port": port,
            })
            master.call("connect", transport="tcp", host="127.0.0.1", port=port, timeout=0.2)
            read = master.call("read_rows", rows=rows, grouped=True)
            assert read["result"]["rows"][0]["values"] == [123]
            assert {f["direction"] for f in read["traffic"]} == {"tx", "rx"}
            master.call("write", kind="holding_registers", address=0, values=[456])
            assert master.call("read", address=0, count=1)["result"]["values"] == [456]
            expression = master.call("evaluate_expressions", values={"温度": 456},
                                     expressions=[{"name": "Double", "text": "[温度]*2"}])
            assert expression["result"]["rows"][0]["numeric"] == 912
            path = directory / "samples.csv"
            master.call("logger_start", rows=rows, path=str(path), interval_ms=100)
            master.call("logger_sample", values=[[456]])
            master.call("logger_stop")
            assert "456" in path.read_text(encoding="utf-8-sig")
            catalog = master.call("template_list")["result"]["public"]
            assert catalog
            for entry in catalog:
                state = master.call("template_load", resource=entry["resource"])["result"]["state"]
                assert state["registers"]
                assert all("kind" in row and "format" in row for row in state["registers"])
                planned = master.call("plan_reads", rows=state["registers"], grouped=True)
                assert sum(map(len, planned["result"]["groups"])) == len(state["registers"])
            loaded = master.call("template_load", resource=catalog[0]["resource"])
            template = loaded["result"]["state"]
            assert template["registers"]
            saved = master.call("template_save", state=template, name="验收模板")["result"]
            master.call("template_load", template_id=saved["id"])
            master.call("disconnect")
            master.call("connect", transport="demo", timeout=0.5)
            demo_rows = [
                {"kind": "input_registers", "address": 0, "count": 1},
                {"kind": "holding_registers", "address": 0, "count": 1},
                {"kind": "coils", "address": 0, "count": 1},
                {"kind": "discrete_inputs", "address": 0, "count": 1},
            ]
            demo = master.call("read_rows", rows=demo_rows, grouped=True)["result"]["rows"]
            assert 500 <= demo[0]["values"][0] <= 1500
            assert demo[1]["values"] == [100]
            assert demo[2]["values"] == [True] and demo[3]["values"] == [True]
            master.call("write", kind="holding_registers", address=0, values=[235])
            master.call("write", kind="coils", address=0, values=[False])
            demo = master.call("read_rows", rows=demo_rows, grouped=False)["result"]["rows"]
            assert demo[1]["values"] == [235] and demo[2]["values"] == [False]
            master.call("disconnect")
            master.call("connect", transport="demo", timeout=0.5)
            demo = master.call("read_rows", rows=demo_rows, grouped=True)["result"]["rows"]
            assert demo[1]["values"] == [100] and demo[2]["values"] == [True]
        finally:
            master.close()
            simulator.close()
        # EOF must stop the listener as well as both processes.
        with socket.socket() as probe:
            assert probe.connect_ex(("127.0.0.1", port)) != 0
    return {"bundle": str(bundle.resolve()), "public_templates": len(catalog),
            "checks": ["frozen startup", "separate simulator/master", "read/write", "traffic",
                       "expressions", "CSV logger", "public/custom templates", "EOF cleanup",
                       "demo map areas/write/reconnect"]}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bundle", type=Path, required=True)
    print(json.dumps(verify(parser.parse_args().bundle), ensure_ascii=False, indent=2))
