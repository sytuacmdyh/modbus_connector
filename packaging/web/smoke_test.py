"""Check the HTTP contract of a running static-web image (standard library only)."""

import sys
import time
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen


def main():
    base = sys.argv[1].rstrip("/") if len(sys.argv) > 1 else "http://127.0.0.1:18080"

    def fetch(path, *, encoding=None):
        headers = {"Accept-Encoding": encoding} if encoding else {}
        with urlopen(Request(base + path, headers=headers), timeout=10) as response:
            return response.headers, response.read()

    for attempt in range(30):
        try:
            _, body = fetch("/healthz")
            assert body == b"ok\n", body
            break
        except (OSError, URLError):
            if attempt == 29:
                raise
            time.sleep(1)

    headers, index = fetch("/")
    assert headers.get_content_type() == "text/html", headers
    assert b"flutter_bootstrap.js" in index
    assert headers["Cache-Control"] == "no-cache", headers
    assert fetch("/workspace/example")[1] == index, "SPA route fallback failed"
    for path, media_type in [
        ("/flutter_bootstrap.js", "application/javascript"),
        ("/main.dart.js", "application/javascript"),
        ("/canvaskit/canvaskit.wasm", "application/wasm"),
        ("/assets/AssetManifest.bin", "application/octet-stream"),
    ]:
        headers, body = fetch(path)
        assert headers.get_content_type() == media_type, (path, headers)
        assert body, path
        assert headers["Cache-Control"] == "no-cache", (path, headers)
        if path.endswith(".wasm"):
            assert body.startswith(b"\x00asm"), "Invalid WebAssembly response"
    headers, _ = fetch("/main.dart.js", encoding="gzip")
    assert headers.get("Content-Encoding") == "gzip", headers
    try:
        fetch("/assets/missing.js")
    except HTTPError as error:
        assert error.code == 404, error
    else:
        raise AssertionError("Missing assets returned the application HTML")
    print("Static-web image passed: health, SPA, JS/Wasm/assets, cache, gzip, 404")


if __name__ == "__main__":
    main()
