import os
import subprocess
import sys
import textwrap

import pytest


def test_qt_void_calls_and_shutdown() -> None:
    pytest.importorskip("PySide6.QtWidgets", exc_type=ImportError)
    # PySide6 6.12's void calls lose references to None on Python 3.11.
    # Exercise the binding in a child so a native crash becomes a test failure.
    env = os.environ.copy()
    env.setdefault("QT_QPA_PLATFORM", "offscreen")
    result = subprocess.run(
        [sys.executable, "-c", textwrap.dedent("""\
            from PySide6.QtWidgets import QApplication, QLabel

            app = QApplication([])
            label = QLabel()
            for _ in range(20000):
                label.setText("runtime check")
            label.close()
            app.processEvents()
        """)],
        env=env, capture_output=True, text=True, timeout=30,
    )
    assert result.returncode == 0, result.stdout + result.stderr
