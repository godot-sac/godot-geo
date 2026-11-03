"""tools/build_terrain.py download(): complete files, and a stale partial file when the server ignores Range."""
import http.server
import sys
import threading
from functools import partial
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / "tools"))
import build_terrain as bt  # noqa: E402


@pytest.fixture
def server(tmp_path):
    root = tmp_path / "www"
    root.mkdir()
    (root / "tile.bin").write_bytes(bytes(range(256)) * 4000)
    handler = partial(http.server.SimpleHTTPRequestHandler, directory=str(root))  # ignores Range: always 200
    handler.log_message = lambda *a: None
    httpd = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    yield f"http://127.0.0.1:{httpd.server_address[1]}", root
    httpd.shutdown()


def test_download_complete(server, tmp_path):
    url, root = server
    dest = tmp_path / "out" / "tile.bin"
    dest.parent.mkdir()
    bt.download(f"{url}/tile.bin", dest)
    assert dest.read_bytes() == (root / "tile.bin").read_bytes()
    assert not dest.with_suffix(".bin.part").exists()


def test_download_restarts_when_range_is_ignored(server, tmp_path):
    url, root = server
    dest = tmp_path / "tile.bin"
    dest.with_suffix(".bin.part").write_bytes(b"stale bytes from an earlier attempt")
    bt.download(f"{url}/tile.bin", dest)
    assert dest.read_bytes() == (root / "tile.bin").read_bytes()


def test_download_404_raises(server, tmp_path):
    url, _ = server
    import urllib.error
    with pytest.raises(urllib.error.HTTPError):
        bt.download(f"{url}/missing.bin", tmp_path / "missing.bin")
