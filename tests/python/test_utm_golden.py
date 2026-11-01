"""Checks tests/golden/utm_mgrs_cases.txt against pyproj (PROJ), so the golden UTM values are verified independently.

Run from the repo root:  tools/.venv/Scripts/python.exe -m pytest tests/python/test_utm_golden.py -q -p no:cacheprovider
The MGRS strings come from the `mgrs` package at generation time (tools/make_utm_golden.py) and are not needed here;
this test only re-derives the UTM numbers and checks that the MGRS lines are consistent with them.
"""
import math
from pathlib import Path

import pyproj
import pytest

GOLDEN = Path(__file__).resolve().parents[2] / "tests" / "golden" / "utm_mgrs_cases.txt"

_transformers: dict[int, pyproj.Transformer] = {}


def _lines(kind: str) -> list[list[str]]:
    out = []
    for line in GOLDEN.read_text(encoding="utf-8").splitlines():
        f = line.split()
        if f and f[0] == kind:
            out.append(f[1:])
    return out


def _utm_pyproj(lat: float, lon: float, zone: int, north: bool) -> tuple[float, float]:
    epsg = (32600 if north else 32700) + zone
    if epsg not in _transformers:
        _transformers[epsg] = pyproj.Transformer.from_crs("EPSG:4326", f"EPSG:{epsg}", always_xy=True)
    return _transformers[epsg].transform(lon, lat)


def test_golden_file_has_cases():
    assert len(_lines("utm")) >= 50
    assert len(_lines("mgrs")) == len(_lines("utm"))


@pytest.mark.parametrize("f", _lines("utm"), ids=lambda f: f"{f[0]},{f[1]}")
def test_utm_matches_pyproj(f):
    lat, lon, zone = float(f[0]), float(f[1]), int(f[2])
    north = f[3] == "N"
    e, n = _utm_pyproj(lat, lon, zone, north)
    assert abs(e - float(f[4])) < 1e-3 and abs(n - float(f[5])) < 1e-3, f
    assert north == (lat >= 0.0)
    # Every zone, exceptions included, covers at most 6 degrees either side of its central meridian.
    dlon = (lon - (zone * 6 - 183) + 180.0) % 360.0 - 180.0
    assert abs(dlon) <= 6.0 + 1e-9, f


@pytest.mark.parametrize("f", _lines("mgrs"), ids=lambda f: f"{f[0]},{f[1]}")
def test_mgrs_lines_agree_with_utm(f):
    lat, lon, digits, s = float(f[0]), float(f[1]), int(f[2]), f[3]
    assert digits == 5
    zone = int(s[:2])
    e, n = _utm_pyproj(lat, lon, zone, lat >= 0.0)
    assert int(s[-10:-5]) == math.floor(e) % 100000 and int(s[-5:]) == math.floor(n) % 100000, f
    assert s[2] in "CDEFGHJKLMNPQRSTUVWX" and (s[2] >= "N") == (lat >= 0.0), f
    col = "ABCDEFGH JKLMNPQR STUVWXYZ".split()[(zone - 1) % 3]
    assert col[math.floor(e) // 100000 - 1] == s[3], f
    row = "ABCDEFGHJKLMNPQRSTUV"[(math.floor(n) // 100000 + (5 if zone % 2 == 0 else 0)) % 20]
    assert row == s[4], f
    assert s[2] == "CDEFGHJKLMNPQRSTUVWX"[min(int(math.floor((lat + 80.0) / 8.0)), 19)], f
