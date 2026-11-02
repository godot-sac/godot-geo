"""Tests for tools/roads.py: splitting at bridge / tunnel flags, roads.bin encoding, the committed test package."""
import json
import struct
import sys
import zlib
from pathlib import Path

import numpy as np
import pytest
import shapely

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / "tools"))
import build_terrain as bt  # noqa: E402
import roads  # noqa: E402

PACKAGE = REPO / "tests" / "data" / "uskudar_small"


def decode(data: bytes) -> list[dict]:
    assert data[:4] == b"GGRD"
    version, _, tile_m, tx, tz, count = struct.unpack_from("<HHfHHI", data, 4)
    assert version == 1
    out = []
    for t in range(tx * tz):
        off, size, raw_size, n = struct.unpack_from("<IIII", data, 20 + 16 * t)
        if not n:
            continue
        raw = zlib.decompress(data[off:off + size])
        assert len(raw) == raw_size
        cx = -tx * tile_m / 2 + ((t % tx) + 0.5) * tile_m
        cz = -tz * tile_m / 2 + ((t // tx) + 0.5) * tile_m
        p = 0
        for _ in range(n):
            cls, flags, width, k = struct.unpack_from("<BBfH", raw, p)
            p += 8
            pts = np.frombuffer(raw, "<i2", 2 * k, p).reshape(k, 2) * 0.05 + (cx, cz)
            p += 4 * k
            deck = None
            if flags & roads.BRIDGE:
                deck = np.frombuffer(raw, "<f4", k, p)
                p += 4 * k
            out.append({"class": cls, "flags": flags, "width": width, "points": pts, "deck": deck})
        assert p == len(raw)
    assert len(out) == count
    return out


def test_flags_and_pieces():
    rules = [{"values": ["is_bridge", "is_link"], "between": [0.25, 0.5]}, {"values": ["is_tunnel"], "between": None}]
    assert roads._flags_at(rules, "is_bridge") == [(0.25, 0.5)]
    assert roads._flags_at(rules, "is_tunnel") == [(0.0, 1.0)]
    line = shapely.LineString([(0, 0), (100, 0)])
    pieces = roads._pieces(line, [(0.25, 0.5)], [])
    assert [round(p.length) for p, _ in pieces] == [25, 25, 50]
    assert [f for _, f in pieces] == [0, roads.BRIDGE, 0]


def test_encode_roundtrip():
    grid = bt.Grid(41.0, 29.0, 0.0, 2000.0, 10.0)
    recs = [(6, 0, 6.0, np.array([[0.0, 0.0], [50.0, 10.0], [90.0, 0.0]]), None),
            (1, roads.BRIDGE, 20.0, np.array([[-300.0, 200.0], [-100.0, 200.0]]), np.array([40.0, 45.0]))]
    data, tiles = roads.encode(recs, grid)
    out = decode(data)
    assert len(out) == 2 and tiles["non_empty"] == 2
    street = next(r for r in out if r["class"] == 6)
    assert np.allclose(street["points"], [[0, 0], [50, -10], [90, 0]], atol=0.03)  # z = -north
    bridge = next(r for r in out if r["class"] == 1)
    assert bridge["flags"] == roads.BRIDGE and np.allclose(bridge["deck"], [40.0, 45.0])


def test_package_roads():
    meta = json.loads((PACKAGE / "terrain.json").read_text(encoding="utf-8"))
    if "roads" not in meta:
        pytest.skip("test package built without roads")
    out = decode((PACKAGE / "roads.bin").read_bytes())
    assert len(out) == meta["roads"]["count"] > 500
    assert bt.sha256_file(PACKAGE / "roads.bin") == meta["roads"]["sha256"]
    assert meta["roads"]["license"].startswith("ODbL")
    half = meta["size_m"] / 2
    for r in out:
        assert np.abs(r["points"]).max() <= half + 1.0
        if r["deck"] is not None:
            assert np.all(np.isfinite(r["deck"]))
