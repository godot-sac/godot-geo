"""Tests for tools/layers.py (optional package layers) and the water layer of the Üsküdar test package.

No network: rasterising is checked on synthetic polygons; the package is checked against its own heights and
terrain.json (water must lie at geoid height, i.e. mean sea level).
"""
import json
import sys
from pathlib import Path

import numpy as np
import OpenEXR
import pymap3d
import pytest
import shapely
from PIL import Image

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / "tools"))
import build_terrain as bt  # noqa: E402
import layers  # noqa: E402

PACKAGE = REPO / "tests" / "data" / "uskudar_small"
WGS84 = pymap3d.Ellipsoid.from_name("wgs84")


def test_coverage_of_aligned_square_is_exact():
    grid = bt.Grid(41.0, 29.0, 0.0, 100.0, 10.0)  # 11 x 11 samples, cells centred on them
    # cells (col 2..4, row 2..4) cover east -35..-5 and north 5..35; half a cell more to the east
    square = shapely.box(-35.0, 5.0, 0.0, 35.0)
    cov = layers.coverage(np.array([square]), grid)
    assert cov[2:5, 2:5].tolist() == [[255] * 3] * 3
    assert cov[2:5, 5].tolist() == [128] * 3  # half of column 5 (east -5..5)
    assert cov.sum() == 255 * 9 + 128 * 3
    assert cov[0].sum() == 0 and cov[:, 0].sum() == 0


def test_coverage_subcell_square():
    grid = bt.Grid(41.0, 29.0, 0.0, 40.0, 10.0)
    quarter = shapely.box(-5.0, -5.0, 0.0, 0.0)  # south-west quarter of the centre cell (row 2, col 2)
    cov = layers.coverage(np.array([quarter]), grid)
    assert cov[2, 2] == 64 and cov.sum() == 64


def test_to_enu_matches_pymap3d():
    grid = bt.Grid(41.02, 29.05, 0.0, 10000.0, 5.0)
    pts = np.array([[29.0, 41.0], [29.1, 41.05], [29.05, 41.02]])
    out = shapely.get_coordinates(layers.to_enu(np.array([shapely.LineString(pts)]), grid))
    e, n, _ = pymap3d.geodetic2enu(pts[:, 1], pts[:, 0], 0.0, 41.02, 29.05, 0.0, WGS84)
    assert np.allclose(out[:, 0], e, atol=1e-6) and np.allclose(out[:, 1], n, atol=1e-6)
    assert abs(out[2]).max() < 1e-6


def test_to_enu_projects_at_the_surface():
    """With a surface set, a lon/lat point lands where the package sample (e, n, u) of that point is: on high
    ground far from the origin that is metres away from the h = 0 projection."""
    grid = bt.Grid(41.0, 29.0, 0.0, 60000.0, 100.0)
    heights = np.full((grid.count, grid.count), 900.0)
    lat, lon = 41.2, 29.25  # ~28 km from the origin
    try:
        layers.set_surface(grid, heights)
        out = shapely.get_coordinates(layers.to_enu(np.array([shapely.Point(lon, lat)]), grid))[0]
        lat_s, lon_s, _ = pymap3d.enu2geodetic(out[0], out[1], 900.0, grid.lat0, grid.lon0, grid.h0, WGS84)
        assert abs(lat_s - lat) * 111e3 < 0.05 and abs(lon_s - lon) * 84e3 < 0.05  # the surface point is the input
        e0, n0, _ = pymap3d.geodetic2enu(lat, lon, 0.0, grid.lat0, grid.lon0, grid.h0, WGS84)
        assert 2.0 < np.hypot(out[0] - e0, out[1] - n0) < 6.0  # about u * d / R
        lat_g, lon_g = bt.sample_lat_lon(bt.Grid(41.0, 29.0, 0.0, 60000.0, 30000.0))
        lat_c, lon_c, _ = pymap3d.enu2geodetic(30000.0, -30000.0, 900.0, 41.0, 29.0, 0.0, WGS84)
        assert abs(lat_g[2, 2] - lat_c) < 1e-9 and abs(lon_g[2, 2] - lon_c) < 1e-9
    finally:
        layers.set_surface(None, None)


def test_boxes_split_at_antimeridian():
    assert layers._boxes((10.0, 11.0, 179.5, 180.5)) == [(179.5, 10.0, 180.0, 11.0), (-180.0, 10.0, -179.5, 11.0)]
    assert layers._boxes((10.0, 11.0, 29.0, 29.5)) == [(29.0, 10.0, 29.5, 11.0)]


def test_unknown_layer_is_rejected():
    with pytest.raises(SystemExit):
        bt.parse_args(["--lat", "41", "--lon", "29", "--size", "100", "--out", "x", "--layers", "water,trees2"])


def _erode(mask: np.ndarray, r: int) -> np.ndarray:
    """Binary erosion with a (2r+1)^2 square; cells outside the array count as false."""
    out = mask.copy()
    for dr in range(-r, r + 1):
        for dc in range(-r, r + 1):
            shifted = np.zeros_like(mask)
            src = mask[max(dr, 0):mask.shape[0] + min(dr, 0), max(dc, 0):mask.shape[1] + min(dc, 0)]
            shifted[max(-dr, 0):mask.shape[0] + min(-dr, 0), max(-dc, 0):mask.shape[1] + min(-dc, 0)] = src
            out &= shifted
    return out


@pytest.fixture(scope="module")
def package():
    meta = json.loads((PACKAGE / "terrain.json").read_text(encoding="utf-8"))
    with OpenEXR.File(str(PACKAGE / "height.exr")) as f:
        height = np.asarray(f.channels()["R"].pixels, dtype=np.float64)
    water = np.asarray(Image.open(PACKAGE / meta["water"]["file"]))
    return meta, height, water


def test_water_metadata(package):
    meta, _, water = package
    w = meta["water"]
    assert water.dtype == np.uint8 and water.shape == (w["samples"], w["samples"])
    assert w["samples"] == round(meta["size_m"] / w["spacing_m"]) + 1
    assert bt.sha256_file(PACKAGE / w["file"]) == w["sha256"]
    assert w["license"].startswith("ODbL")
    assert any("OpenStreetMap contributors" in a for a in meta["attribution"])
    assert abs(float((water >= 128).mean()) - w["water_share"]) < 1e-9
    assert 0.4 < w["water_share"] < 0.7  # Bosphorus off Üsküdar: about half sea


def test_open_water_is_at_mean_sea_level(package):
    """Away from the shore, the surface under the water layer is the DEM's 0 m (EGM2008), i.e. the geoid."""
    meta, height, water = package
    ws = meta["water"]["spacing_m"]
    hs = meta["height"]["spacing_m"]
    k = int(round(hs / ws))
    deep = _erode(water[::k, ::k] == 255, int(60 / hs))  # water samples at least 60 m from any land
    assert deep.sum() > 1000
    rows, cols = np.nonzero(deep)
    half = meta["size_m"] / 2
    e = -half + cols * hs
    n = half - rows * hs
    o = meta["origin"]
    _, _, h = pymap3d.enu2geodetic(e, n, height[rows, cols], o["latitude"], o["longitude"], o["height"], WGS84)
    g = meta["sources"]["geoid"]
    assert g["n_min_m"] - 0.05 < h.min() and h.max() < g["n_max_m"] + 0.05


def test_landcover_matches_worldcover_cache(package):
    """landcover.png equals ESA WorldCover at the sample positions (positions through PROJ, not pymap3d)."""
    meta = package[0]
    if "landcover" not in meta:
        pytest.skip("no land cover layer")
    cached = sorted((bt.CACHE / "rasters").glob("worldcover_N39E027-*.npz"))
    if not cached:
        pytest.skip("no WorldCover window in tools/.cache")
    import pyproj
    lc = np.asarray(Image.open(PACKAGE / meta["landcover"]["file"]))
    n, sp = lc.shape[0], meta["landcover"]["spacing_m"]
    o = meta["origin"]
    enu = pyproj.Transformer.from_pipeline(
        f"+proj=pipeline +step +inv +proj=topocentric +ellps=WGS84 +lon_0={o['longitude']} +lat_0={o['latitude']} "
        f"+h_0={o['height']} +step +inv +proj=cart +ellps=WGS84 +step +proj=unitconvert +xy_in=rad +xy_out=deg")
    rng = np.random.default_rng(5)
    rows, cols = rng.integers(0, n, 300), rng.integers(0, n, 300)
    lon, lat, _ = enu.transform(-meta["size_m"] / 2 + cols * sp, meta["size_m"] / 2 - rows * sp, np.zeros(300))
    for path in cached:
        z = np.load(path)
        a, _, c, _, e, f = z["transform"]
        r = np.floor((lat - f) / e).astype(int)
        q = np.floor((lon - c) / a).astype(int)
        ok = (r >= 0) & (r < z["data"].shape[0]) & (q >= 0) & (q < z["data"].shape[1])
        if ok.all():
            same = z["data"][r, q] == lc[rows, cols]
            # Points within millimetres of a WorldCover pixel edge may round the other way.
            assert same.mean() > 0.99
            return
    pytest.skip("cached window does not cover the package")


def test_land_is_not_water(package):
    meta, height, water = package
    k = int(round(meta["height"]["spacing_m"] / meta["water"]["spacing_m"]))
    land = water[::k, ::k] == 0
    o = meta["origin"]
    hs = meta["height"]["spacing_m"]
    rows, cols = np.nonzero(land)
    half = meta["size_m"] / 2
    _, _, h = pymap3d.enu2geodetic(-half + cols * hs, half - rows * hs, height[rows, cols], o["latitude"],
                                   o["longitude"], o["height"], WGS84)
    # most land is above the sea; Üsküdar rises to ~130 m within the package
    assert np.median(h - meta["sources"]["geoid"]["n_min_m"]) > 10.0
