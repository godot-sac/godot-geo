"""Whole-world support of tools/build_terrain.py: Copernicus DEM tiles of every width (narrower towards the poles)
and areas crossing the antimeridian. Oracle: GDAL bilinear resampling of the single tile holding each point, and the
PROJ-based ENU conversion of test_build_terrain.py. Needs the network or tools/.cache/ for the DEM tiles.

Places: Alta, northern Norway, across the 70 degree band edge where tiles go from 1800 to 1200 columns; Taveuni,
Fiji, across 180 degrees longitude.
"""
import json
import math
import sys
from pathlib import Path

import numpy as np
import pytest
import rasterio
from rasterio.enums import Resampling
from rasterio.windows import Window

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / "tools"))
import build_terrain as bt  # noqa: E402
from test_build_terrain import enu_to_geodetic_oracle, read_exr  # noqa: E402

NORWAY = (69.99, 23.27)
FIJI = (-16.82, 179.99)


def gdal_tile_height(lat: float, lon: float) -> float:
    """GDAL bilinear height from the one tile holding the point (the point must not be in its last row/column)."""
    lon = float(bt.wrap_lon(lon))
    path = bt.fetch_dem_tile(bt.dem_tile_name(math.floor(lat), math.floor(lon)))
    with rasterio.open(path) as ds:
        x, y = ~ds.transform @ (lon, lat)
        assert 0.5 <= x <= ds.width - 0.5 and 0.5 <= y <= ds.height - 0.5, "point in a seam gap"
        win = Window(x - 0.5, y - 0.5, 1, 1)
        return float(ds.read(1, window=win, out_shape=(1, 1), resampling=Resampling.bilinear)[0, 0])


def away_from_seams(lat, lon, w):
    """Mask of points not in the last row / column of their tile (between two tiles' samples)."""
    lon = bt.wrap_lon(lon)
    fr = (np.floor(lat) + 1 - lat) * 3600
    fc = (lon - np.floor(lon)) * w
    return (fr < 3599) & (fc < w - 1)


def test_tile_widths():
    assert [bt.dem_tile_width(x) for x in (0, 49, 50, 59, 60, 69, 70, 79, 80, 84, 85, 89)] == [
        3600, 3600, 2400, 2400, 1800, 1800, 1200, 1200, 720, 720, 360, 360]
    assert [bt.dem_tile_width(x) for x in (-1, -50, -51, -60, -61, -71, -90)] == [
        3600, 3600, 2400, 2400, 1800, 1200, 360]


def test_wrap_lon():
    np.testing.assert_allclose(bt.wrap_lon([180.0, -180.0, 179.5, 190.0, -190.0, 540.0]),
                               [-180.0, -180.0, 179.5, -170.0, 170.0, -180.0])


def test_grid_bounds_across_antimeridian():
    lat_min, lat_max, lon_min, lon_max = bt.grid_bounds(bt.Grid(*FIJI, 0.0, 6000.0, 30.0))
    assert lon_min < 180.0 < lon_max and lon_max - lon_min < 0.1
    assert lat_min < FIJI[0] < lat_max


@pytest.mark.parametrize("place,width", [(NORWAY, None), (FIJI, 3600)], ids=["norway", "fiji"])
def test_dem_matches_gdal(place, width):
    lat0, lon0 = place
    dem = bt.load_dem(lat0 - 0.04, lat0 + 0.04, lon0 - 0.04, lon0 + 0.04)
    rng = np.random.default_rng(11)
    lat = rng.uniform(lat0 - 0.03, lat0 + 0.03, 120)
    lon = rng.uniform(lon0 - 0.03, lon0 + 0.03, 120)
    w = np.array([bt.dem_tile_width(int(np.floor(a))) for a in lat])
    keep = away_from_seams(lat, lon, w)
    ours = dem.sample(lat, lon)
    assert np.isfinite(ours).all()
    for i in np.flatnonzero(keep):
        assert abs(ours[i] - gdal_tile_height(lat[i], lon[i])) < 1e-3, (lat[i], lon[i])
    # Both sides of the seam are really used.
    assert len({t["name"] for t in dem.tiles}) >= 2
    if place is FIJI:
        names = " ".join(t["name"] for t in dem.tiles)
        assert "E179" in names and "W180" in names
        # The same point given as +180.01 or -179.99 is the same height.
        np.testing.assert_allclose(dem.sample(np.array([-16.81]), np.array([180.01])),
                                   dem.sample(np.array([-16.81]), np.array([-179.99])))


def test_norway_band_edge_is_continuous():
    """At 70 N the tile above has 1200 columns, the one below 1800; heights must not jump across the seam."""
    dem = bt.load_dem(69.95, 70.05, 23.2, 23.35)
    lon = np.linspace(23.22, 23.32, 50)
    eps = 1e-7
    above = dem.sample(np.full(lon.size, 70.0 + eps), lon)
    below = dem.sample(np.full(lon.size, 70.0 - eps), lon)
    # The seam row is resampled along longitude from 1800 to 1200 columns: differences stay well below the height
    # change between neighbouring posts.
    step = np.abs(np.diff(dem.sample(np.full(400, 70.0 - eps), np.linspace(23.22, 23.32, 400)))).max()
    assert np.abs(above - below).max() <= max(step, 0.5)


@pytest.fixture(scope="module")
def geoid():
    return bt.Geoid()


def check_package_heights(pkg: Path, meta: dict, geoid) -> None:
    """Samples converted back to geodetic lie on the DEM surface + geoid (single-tile GDAL oracle)."""
    o = meta["origin"]
    h = read_exr(pkg / "height.exr")
    n, sp, half = meta["height"]["samples"], meta["height"]["spacing_m"], meta["size_m"] / 2
    rng = np.random.default_rng(5)
    rows, cols = rng.integers(0, n, 150), rng.integers(0, n, 150)
    e, nn, u = -half + cols * sp, half - rows * sp, h[rows, cols].astype(np.float64)
    lat, lon, h_ell = enu_to_geodetic_oracle(e, nn, u, o["latitude"], o["longitude"], o["height"])
    w = np.array([bt.dem_tile_width(int(np.floor(a))) for a in lat])
    checked = 0
    for i in np.flatnonzero(away_from_seams(lat, lon, w)):
        expected = gdal_tile_height(lat[i], lon[i]) + float(geoid.height(lat[i], bt.wrap_lon(lon[i])))
        assert abs(h_ell[i] - expected) < 0.5, (lat[i], lon[i], h_ell[i], expected)
        checked += 1
    assert checked > 100


@pytest.mark.parametrize("place", [NORWAY, FIJI], ids=["norway", "fiji"])
def test_package_on_either_side_of_a_seam(tmp_path, place, geoid):
    """A 6 km package across the band edge / the antimeridian."""
    lat0, lon0 = place
    out = tmp_path / "pkg"
    meta = bt.build(bt.parse_args(["--lat", str(lat0), "--lon", str(lon0), "--size", "6000", "--spacing", "30",
                                   "--imagery", "hillshade", "--out", str(out)]))
    assert any("Copernicus WorldDEM-30" in a for a in meta["attribution"])
    assert not any("Sentinel" in a for a in meta["attribution"])
    corners = meta["corners"]
    if place is FIJI:
        assert corners["nw"]["longitude"] > 179.9 and corners["ne"]["longitude"] < -179.9
    else:
        assert corners["sw"]["latitude"] < 70.0 < corners["nw"]["latitude"]
    check_package_heights(out, meta, geoid)


@pytest.mark.parametrize("name", ["fiji_small", "norway_small"])
def test_committed_world_packages(name, geoid):
    pkg = REPO / "tests" / "data" / name
    meta = json.loads((pkg / "terrain.json").read_text(encoding="utf-8"))
    check_package_heights(pkg, meta, geoid)
