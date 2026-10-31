"""Tests for tools/build_terrain.py and the packages it writes.

Run from the repo root:  tools/.venv/Scripts/python.exe -m pytest tests/python
The oracles are independent of the code under test where it matters:
  - positions: pyproj (PROJ) ECEF conversion + an explicit ENU rotation, not pymap3d;
  - DEM heights: GDAL's own bilinear resampling (rasterio fractional-window read), not our bilinear();
  - ENU convention: godot-dis tests/golden/geo_cases.txt (shared golden cases).
The full Ankara package (terrain/ankara) is checked too when it has been built.
"""
import hashlib
import json
import math
import sys
from pathlib import Path

import numpy as np
import OpenEXR
import pyproj
import pytest
import rasterio
from PIL import Image
from rasterio.enums import Resampling
from rasterio.io import MemoryFile
from rasterio.merge import merge
from rasterio.windows import Window

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / "tools"))
import build_terrain as bt  # noqa: E402

PACKAGES = [REPO / "tests" / "data" / "ankara_small", REPO / "terrain" / "ankara"]
GEO_CASES = REPO / "tests" / "golden" / "geo_cases.txt"

_ECEF = pyproj.Transformer.from_crs("EPSG:4979", "EPSG:4978", always_xy=True)


def enu_to_geodetic_oracle(e, n, u, lat0, lon0, h0):
    """ENU -> geodetic through PROJ's ECEF conversion and an explicit rotation."""
    x0, y0, z0 = _ECEF.transform(lon0, lat0, h0)
    p, l = math.radians(lat0), math.radians(lon0)
    rot = np.array([
        [-math.sin(l), math.cos(l), 0.0],
        [-math.sin(p) * math.cos(l), -math.sin(p) * math.sin(l), math.cos(p)],
        [math.cos(p) * math.cos(l), math.cos(p) * math.sin(l), math.sin(p)],
    ])
    d = rot.T @ np.vstack([np.ravel(e), np.ravel(n), np.ravel(u)])
    lon, lat, h = _ECEF.transform(x0 + d[0], y0 + d[1], z0 + d[2], direction="INVERSE")
    return np.asarray(lat), np.asarray(lon), np.asarray(h)


_gdal_mosaics: dict = {}


def _gdal_mosaic(lat: float, lon: float):
    """GDAL mosaic (rasterio.merge) of the 2x2 tiles around the point, so points near tile seams have neighbours."""
    la, lo = round(lat), round(lon)
    if (la, lo) not in _gdal_mosaics:
        paths = [bt.fetch_dem_tile(bt.dem_tile_name(a, b)) for a in (la - 1, la) for b in (lo - 1, lo)]
        sources = [rasterio.open(p) for p in paths]
        data, transform = merge(sources)
        for s in sources:
            s.close()
        mem = MemoryFile()
        ds = mem.open(driver="GTiff", width=data.shape[2], height=data.shape[1], count=1, dtype=data.dtype,
                      crs="EPSG:4326", transform=transform)
        ds.write(data[0], 1)
        _gdal_mosaics[(la, lo)] = (mem, ds)
    return _gdal_mosaics[(la, lo)][1]


def gdal_dem_height(lat: float, lon: float) -> float:
    """Orthometric DEM height by GDAL bilinear resampling of a GDAL-built tile mosaic."""
    ds = _gdal_mosaic(lat, lon)
    x, y = ~ds.transform @ (lon, lat)
    win = Window(x - 0.5, y - 0.5, 1, 1)
    return float(ds.read(1, window=win, out_shape=(1, 1), resampling=Resampling.bilinear)[0, 0])


def read_exr(path: Path) -> np.ndarray:
    with OpenEXR.File(str(path)) as f:
        return f.channels()["R"].pixels


def existing_packages():
    return [pytest.param(p, id=p.name) for p in PACKAGES if (p / "terrain.json").exists()] or [
        pytest.param(None, marks=pytest.mark.skip("no package built"))]


@pytest.fixture(scope="module")
def geoid():
    return bt.Geoid()


# --- pure functions ---------------------------------------------------------------------------------------------

def test_bilinear_is_exact_for_planes():
    arr = np.fromfunction(lambda r, c: 3.0 * r - 2.0 * c + 7.0, (5, 6))
    r = np.array([0.0, 1.25, 3.999, 2.5])
    c = np.array([0.0, 4.75, 0.5, 5.0])
    np.testing.assert_allclose(bt.bilinear(arr, r, c), 3.0 * r - 2.0 * c + 7.0, atol=1e-12)


def test_grid_layout():
    g = bt.Grid(39.9, 32.8, 0.0, 300.0, 30.0)
    assert g.count == 11
    assert g.east()[0] == -150.0 and g.east()[-1] == 150.0
    assert g.north()[0] == 150.0 and g.north()[-1] == -150.0  # row 0 = north
    with pytest.raises(ValueError):
        _ = bt.Grid(39.9, 32.8, 0.0, 100.0, 30.0).count


def test_dem_tile_names():
    assert bt.dem_tile_name(39, 32) == "Copernicus_DSM_COG_10_N39_00_E032_00_DEM"
    assert bt.dem_tile_name(-1, -75) == "Copernicus_DSM_COG_10_S01_00_W075_00_DEM"


def test_enu_matches_godot_dis_golden_cases():
    count = 0
    for line in GEO_CASES.read_text().splitlines():
        f = line.split()
        if not f or f[0] != "enu":
            continue
        lat0, lon0, h0, lat, lon, h, e, n, u = map(float, f[1:])
        got = bt.geodetic_to_enu(lat, lon, h, lat0, lon0, h0)
        assert np.allclose(got, (e, n, u), atol=1e-3), line
        back = bt.enu_to_geodetic(e, n, u, lat0, lon0, h0)
        assert abs(back[2] - h) < 1e-3 and abs(back[0] - lat) < 1e-9 and abs((back[1] - lon + 180.0) % 360.0 - 180.0) < 1e-9, line
        count += 1
    assert count > 40


def test_golden_cases_match_sibling_repo():
    sibling = REPO.parent / "godot-dis" / "tests" / "golden" / "geo_cases.txt"
    if not sibling.exists():
        pytest.skip("godot-dis not checked out next to godot-geo")
    assert sibling.read_bytes() == GEO_CASES.read_bytes(), "re-copy geo_cases.txt from godot-dis"


def test_geoid_nga_reference_point(geoid):
    # NGA EGM2008 test value (spherical-harmonic synthesis): 38.6281550 N, 269.7791550 E -> -31.628 m.
    # The 2.5' grid interpolates it within a decimetre.
    assert abs(float(geoid.height(38.6281550, 269.7791550 - 360.0)) - (-31.628)) < 0.1


def test_dem_mosaic_matches_gdal():
    dem = bt.load_dem(39.95, 40.05, 32.95, 33.05)  # four tiles meeting at 40 N 33 E
    rng = np.random.default_rng(7)
    lat = rng.uniform(39.96, 40.04, 40)
    lon = rng.uniform(32.96, 33.04, 40)
    lat[:2], lon[:2] = 40.0 + 0.4 / 3600, 33.0 - 0.3 / 3600  # straddling the tile seams
    ours = dem.sample(lat, lon)
    for i in range(lat.size):
        assert abs(ours[i] - gdal_dem_height(lat[i], lon[i])) < 1e-3, (lat[i], lon[i])


# --- packages ---------------------------------------------------------------------------------------------------

@pytest.mark.parametrize("pkg", existing_packages())
def test_package_files(pkg):
    meta = json.loads((pkg / "terrain.json").read_text(encoding="utf-8"))
    assert meta["format"] == bt.PACKAGE_FORMAT and meta["format_version"] == bt.PACKAGE_FORMAT_VERSION
    for key in ("height", "color"):
        path = pkg / meta[key]["file"]
        assert hashlib.sha256(path.read_bytes()).hexdigest() == meta[key]["sha256"]
    h = read_exr(pkg / "height.exr")
    assert h.dtype == np.float32 and h.shape == (meta["height"]["samples"],) * 2
    assert math.isclose(float(h.min()), meta["height"]["min"]) and math.isclose(float(h.max()), meta["height"]["max"])
    n = meta["height"]["samples"]
    assert math.isclose((n - 1) * meta["height"]["spacing_m"], meta["size_m"])
    with Image.open(pkg / "color.png") as img:
        assert img.mode == "RGB" and img.size == (meta["color"]["samples"],) * 2
    assert any("Copernicus WorldDEM-30" in a for a in meta["attribution"])
    assert any("Copernicus Sentinel data" in a for a in meta["attribution"])


@pytest.mark.parametrize("pkg", existing_packages())
def test_package_corners_geodetic(pkg):
    meta = json.loads((pkg / "terrain.json").read_text(encoding="utf-8"))
    o = meta["origin"]
    for name, c in meta["corners"].items():
        lat, lon, _ = enu_to_geodetic_oracle(c["east"], c["north"], 0.0, o["latitude"], o["longitude"], o["height"])
        d_north = (float(lat[0]) - c["latitude"]) * 111_000
        d_east = (float(lon[0]) - c["longitude"]) * 111_000 * math.cos(math.radians(c["latitude"]))
        assert math.hypot(d_north, d_east) < 0.01, name


@pytest.mark.parametrize("pkg", existing_packages())
def test_package_heights_against_dem_and_geoid(pkg, geoid):
    """Every checked sample, converted back to geodetic, lies on the DEM surface + geoid (within 0.5 m)."""
    meta = json.loads((pkg / "terrain.json").read_text(encoding="utf-8"))
    o, hm = meta["origin"], meta["height"]
    h = read_exr(pkg / "height.exr")
    n, sp, half = hm["samples"], hm["spacing_m"], meta["size_m"] / 2
    rng = np.random.default_rng(3)
    rows = np.concatenate([[0, 0, n - 1, n - 1, n // 2], rng.integers(0, n, 60)])
    cols = np.concatenate([[0, n - 1, 0, n - 1, n // 2], rng.integers(0, n, 60)])
    e, nn, u = -half + cols * sp, half - rows * sp, h[rows, cols].astype(np.float64)
    lat, lon, h_ell = enu_to_geodetic_oracle(e, nn, u, o["latitude"], o["longitude"], o["height"])
    for i in range(rows.size):
        expected = gdal_dem_height(lat[i], lon[i]) + float(geoid.height(lat[i], lon[i]))
        assert abs(h_ell[i] - expected) < 0.5, (rows[i], cols[i], h_ell[i], expected)


@pytest.mark.parametrize("pkg", existing_packages())
def test_package_curvature_is_baked_in(pkg):
    """Far from the origin, a sample's u is lower than its ellipsoidal height by about d^2 / 2R."""
    meta = json.loads((pkg / "terrain.json").read_text(encoding="utf-8"))
    o, hm = meta["origin"], meta["height"]
    h = read_exr(pkg / "height.exr")
    half = meta["size_m"] / 2
    u = float(h[0, 0])
    _, _, h_ell = enu_to_geodetic_oracle(-half, half, u, o["latitude"], o["longitude"], o["height"])
    drop = float(h_ell[0]) - o["height"] - u
    d = math.hypot(half, half)
    assert drop == pytest.approx(d * d / (2 * 6_371_000), rel=0.02)


def test_bbox_overlap():
    area = (32.0, 39.0, 33.0, 40.0)
    assert bt.bbox_overlap([31.0, 38.0, 34.0, 41.0], area) == 1.0
    assert bt.bbox_overlap([32.5, 39.0, 34.0, 40.0], area) == pytest.approx(0.5)
    assert bt.bbox_overlap([33.5, 39.0, 34.0, 40.0], area) == 0.0
