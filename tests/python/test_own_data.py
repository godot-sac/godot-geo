"""Packages built from the user's own files (`--dem`, `--imagery`, `--offline`). The test files are made from the
cached Copernicus DEM tile with GDAL (rasterio); the oracle is GDAL's bilinear resampling of those files plus the PROJ
geoid of the stated vertical datum, at positions converted with the PROJ-based ENU oracle of test_build_terrain.py.
"""
import json
import sys
from pathlib import Path

import numpy as np
import pytest
import rasterio
import rasterio.shutil
from PIL import Image
from rasterio.crs import CRS
from rasterio.enums import Resampling
from rasterio.transform import from_origin
from rasterio.warp import reproject
from rasterio.windows import Window

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / "tools"))
import build_terrain as bt  # noqa: E402
import dted  # noqa: E402
from test_build_terrain import enu_to_geodetic_oracle, read_exr  # noqa: E402

LAT, LON, SIZE, SPACING = 39.9334, 32.8597, 1800.0, 30.0
TILE = bt.dem_tile_name(39, 32)


def build(tmp_path: Path, *extra: str, name: str = "pkg") -> tuple[Path, dict]:
    out = tmp_path / name
    args = ["--lat", str(LAT), "--lon", str(LON), "--size", str(SIZE), "--spacing", str(SPACING), "--out", str(out)]
    meta = bt.build(bt.parse_args(args + [str(x) for x in extra]))
    return out, meta


def sample_points(pkg: Path, meta: dict, count: int = 120):
    """(lat, lon, ellipsoidal height) of random package samples, by the independent ENU oracle."""
    h = read_exr(pkg / "height.exr")
    n, sp, half = meta["height"]["samples"], meta["height"]["spacing_m"], meta["size_m"] / 2
    rng = np.random.default_rng(9)
    rows, cols = rng.integers(0, n, count), rng.integers(0, n, count)
    lat, lon, h_ell = enu_to_geodetic_oracle(-half + cols * sp, half - rows * sp, h[rows, cols].astype(np.float64),
                                             LAT, LON, 0.0)
    return lat, lon, h_ell


def gdal_bilinear(path: Path, x: float, y: float) -> float:
    """GDAL bilinear value of band 1 at file CRS coordinates x, y (float copy so GDAL does not round)."""
    with rasterio.open(path) as ds:
        c, r = ~ds.transform @ (x, y)
        win = Window(int(np.floor(c - 0.5)) - 1, int(np.floor(r - 0.5)) - 1, 4, 4)
        data = ds.read(1, window=win).astype(np.float64)
        if ds.nodata is not None:
            data[data == ds.nodata] = np.nan
        fc, fr = c - 0.5 - win.col_off, r - 0.5 - win.row_off
        return float(bt.bilinear(data, np.array([fr]), np.array([fc]))[0])


@pytest.fixture(scope="module")
def tile_path() -> Path:
    path = bt.fetch_dem_tile(TILE)
    assert path is not None
    return path


@pytest.fixture(scope="module")
def reference(tmp_path_factory) -> tuple[Path, dict]:
    """The same area from Copernicus DEM tiles (the default source)."""
    return build(tmp_path_factory.mktemp("ref"), "--imagery", "hillshade")


def copy_window(tile: Path, out: Path, crs: str | None = None, transform_fn=None, cols: slice | None = None) -> Path:
    """A GeoTIFF with the tile's samples around the test area, on the tile's own grid."""
    with rasterio.open(tile) as ds:
        x, y = ~ds.transform @ (LON, LAT)
        win = Window(int(x) - 100, int(y) - 100, 200, 200)
        data = ds.read(1, window=win).astype(np.float32)
        transform = ds.window_transform(win)
    if transform_fn:
        data = transform_fn(data, transform)
    if cols is not None:
        data[:, cols] = -9999.0
    with rasterio.open(out, "w", driver="GTiff", width=data.shape[1], height=data.shape[0], count=1, dtype="float32",
                       crs=CRS.from_user_input(crs or "EPSG:4326"), transform=transform, nodata=-9999.0) as dst:
        dst.write(data, 1)
    return out


def test_geotiff_copy_of_copernicus_gives_the_same_package(tmp_path, tile_path, reference):
    tif = copy_window(tile_path, tmp_path / "dem.tif")
    pkg, meta = build(tmp_path, "--dem", tif, "--imagery", "hillshade")
    ref = read_exr(reference[0] / "height.exr")
    assert np.abs(read_exr(pkg / "height.exr") - ref).max() < 1e-3
    f = meta["sources"]["elevation"]["files"][0]
    assert f["file"] == "dem.tif" and f["vertical_datum"] == "egm2008" and f["vertical_datum_assumed"]
    assert f["coverage"] == pytest.approx(1.0)
    assert not any("Copernicus" in a for a in meta["attribution"])  # nothing of Copernicus was used
    assert str(tmp_path) not in (pkg / "terrain.json").read_text(encoding="utf-8")  # names only, no paths


def test_ellipsoidal_heights(tmp_path, tile_path, reference):
    """Heights already above the ellipsoid (DEM + N) with --dem-vertical ellipsoid: same surface, no geoid."""
    geoid = bt.Geoid()

    def add_n(data, transform):
        rows, cols = np.mgrid[0:data.shape[0], 0:data.shape[1]]
        x, y = transform @ (cols + 0.5, rows + 0.5)
        return (data + geoid.height(y, x)).astype(np.float32)

    tif = copy_window(tile_path, tmp_path / "ell.tif", transform_fn=add_n)
    pkg, meta = build(tmp_path, "--dem", tif, "--dem-vertical", "ellipsoid", "--imagery", "hillshade")
    assert np.abs(read_exr(pkg / "height.exr") - read_exr(reference[0] / "height.exr")).max() < 5e-3
    assert meta["sources"]["geoids"] == []
    assert meta["sources"]["elevation"]["files"][0]["vertical_datum"] == "ellipsoid"


def test_compound_crs_states_the_datum(tmp_path, tile_path):
    tif = copy_window(tile_path, tmp_path / "egm96.tif", crs="EPSG:4326+5773")
    _, meta = build(tmp_path, "--dem", tif, "--imagery", "hillshade")
    f = meta["sources"]["elevation"]["files"][0]
    assert f["vertical_datum"] == "egm96" and not f["vertical_datum_assumed"]
    assert [g["model"] for g in meta["sources"]["geoids"]] == ["EGM96"]


def test_projected_geotiff(tmp_path, tile_path):
    """A DEM in UTM 36N: package samples equal GDAL's bilinear value of that file + EGM2008 N."""
    with rasterio.open(tile_path) as src:
        dst_t = from_origin(488012.0 - 2500.0, 4420375.0 + 2500.0, 20.0, 20.0)  # around the origin
        dst = np.full((250, 250), np.nan, np.float32)
        reproject(rasterio.band(src, 1), dst, dst_transform=dst_t, dst_crs="EPSG:32636",
                  resampling=Resampling.bilinear, dst_nodata=np.nan)
    tif = tmp_path / "utm.tif"
    with rasterio.open(tif, "w", driver="GTiff", width=250, height=250, count=1, dtype="float32", crs="EPSG:32636",
                       transform=dst_t) as ds:
        ds.write(dst, 1)
    pkg, meta = build(tmp_path, "--dem", tif, "--imagery", "hillshade")
    assert "32636" in meta["sources"]["elevation"]["files"][0]["crs"]
    to_utm = bt.pyproj.Transformer.from_crs("EPSG:4326", "EPSG:32636", always_xy=True)
    geoid = bt.Geoid()
    lat, lon, h_ell = sample_points(pkg, meta)
    for i in range(lat.size):
        x, y = to_utm.transform(lon[i], lat[i])
        expected = gdal_bilinear(tif, x, y) + float(geoid.height(lat[i], lon[i]))
        assert abs(h_ell[i] - expected) < 0.01, (lat[i], lon[i])


def write_dted_from_tile(tile: Path, out: Path) -> Path:
    """DTED level 1 cell N39 E032 written by GDAL's DTED driver from every third Copernicus post."""
    with rasterio.open(tile) as ds:
        data = ds.read(1)[::3, ::3]
    data = np.vstack([data, data[-1:]])  # 1201 rows: the south edge post row (lat 39) repeats its neighbour
    data = np.hstack([data, data[:, -1:]]).astype(np.int16)
    step = 3.0 / 3600.0
    transform = from_origin(32.0 - step / 2, 40.0 + step / 2, step, step)
    mem = rasterio.MemoryFile()
    with mem.open(driver="GTiff", width=1201, height=1201, count=1, dtype="int16", crs="EPSG:4326",
                  transform=transform) as tmp:
        tmp.write(data, 1)
        rasterio.shutil.copy(tmp, out, driver="DTED")
    return out


def test_dted(tmp_path, tile_path):
    dt1 = write_dted_from_tile(tile_path, tmp_path / "n39.dt1")
    assert dted.read_dted(dt1).vertical_datum == "MSL"
    pkg, meta = build(tmp_path, "--dem", tmp_path, "--imagery", "hillshade", "--attribution", "Test DTED notice")
    f = meta["sources"]["elevation"]["files"][0]
    assert f["format"] == "DTED1" and f["vertical_datum"] == "egm96" and not f["vertical_datum_assumed"]
    assert meta["attribution"] == ["Test DTED notice"]
    geoid96 = bt.Geoid("egm96")
    lat, lon, h_ell = sample_points(pkg, meta)
    for i in range(lat.size):
        expected = gdal_bilinear(dt1, lon[i], lat[i]) + float(geoid96.height(lat[i], lon[i]))
        assert abs(h_ell[i] - expected) < 0.01, (lat[i], lon[i])


def test_dem_directory_order(tmp_path):
    for name in ("b/x.dt1", "a/y.dt2", "c.tif", "a/z.dt0", "readme.txt"):
        (tmp_path / name).parent.mkdir(parents=True, exist_ok=True)
        (tmp_path / name).write_bytes(b"")
    assert [p.name for p in bt.find_dem_files([str(tmp_path)])] == ["y.dt2", "x.dt1", "z.dt0", "c.tif"]
    with pytest.raises(FileNotFoundError):
        bt.find_dem_files([str(tmp_path / "nope")])


def test_gaps_fail_unless_a_fallback_is_given(tmp_path, tile_path, reference):
    tif = copy_window(tile_path, tmp_path / "half.tif", cols=slice(0, 100))  # west half has no data
    with pytest.raises(RuntimeError, match="dem-fallback"):
        build(tmp_path, "--dem", tif, "--imagery", "hillshade", name="fail")
    pkg, meta = build(tmp_path, "--dem", tif, "--dem-fallback", "copernicus", "--imagery", "hillshade")
    assert np.abs(read_exr(pkg / "height.exr") - read_exr(reference[0] / "height.exr")).max() < 1e-3
    el = meta["sources"]["elevation"]
    assert 0.3 < el["files"][0]["coverage"] < 0.7 and 0.3 < el["fallback"]["coverage"] < 0.7
    assert any("Copernicus WorldDEM-30" in a for a in meta["attribution"])


def test_offline(tmp_path, tile_path, monkeypatch):
    grid = bt.CACHE / "geoid" / bt.GEOID_GRID
    if not grid.exists():
        pytest.skip("run tools/build_terrain.py --fetch-geoid first")
    tif = copy_window(tile_path, tmp_path / "dem.tif")
    monkeypatch.setattr(bt, "CACHE", tmp_path / "empty_cache")  # no tiles, no grids
    with pytest.raises(bt.OfflineError):
        build(tmp_path, "--offline", "--imagery", "hillshade", name="a")  # Copernicus tile would be downloaded
    with pytest.raises(bt.OfflineError):
        build(tmp_path, "--dem", tif, "--offline", "--imagery", "hillshade", name="b")  # geoid grid from the CDN
    build(tmp_path, "--dem", tif, "--geoid-grid", grid, "--offline", "--imagery", "hillshade", name="c")
    assert bt.NETWORK_USED == []


def test_imagery_geotiff(tmp_path):
    """RGB GeoTIFF in UTM whose colour is linear in x / y, with an alpha hole: bilinear sampling is exact there."""
    px, n = 5.0, 600
    x0, y0 = 488012.0 - 1500.0, 4420375.0 - 1500.0  # 3 km square around the origin, UTM 36N
    t = from_origin(x0, y0 + n * px, px, px)
    cols, rows = np.meshgrid(np.arange(n), np.arange(n))
    x, y = t @ (cols + 0.5, rows + 0.5)
    hole = (cols >= 300) & (cols < 340)
    data = np.stack([np.round((x - x0) / 3000.0 * 250.0), np.round((y - y0) / 3000.0 * 250.0),
                     np.full(x.shape, 128.0), np.where(hole, 0, 255)]).astype(np.uint8)
    tif = tmp_path / "ortho.tif"
    with rasterio.open(tif, "w", driver="GTiff", width=n, height=n, count=4, dtype="uint8", crs="EPSG:32636",
                       transform=t, photometric="RGB", alpha="YES") as ds:
        ds.write(data)
    pkg, meta = build(tmp_path, "--dem", copy_window(bt.fetch_dem_tile(TILE), tmp_path / "d.tif"), "--imagery", tif,
                      "--attribution", "Test imagery notice")
    assert meta["sources"]["imagery"]["files"][0]["file"] == "ortho.tif"
    assert meta["attribution"] == ["Test imagery notice"]
    color = np.asarray(Image.open(pkg / "color.png"), dtype=np.float64)
    nn = meta["color"]["samples"]
    half = SIZE / 2
    e, nth = np.meshgrid(-half + np.arange(nn) * SPACING, half - np.arange(nn) * SPACING)
    lat, lon, _ = enu_to_geodetic_oracle(e, nth, np.zeros_like(e), LAT, LON, 0.0)
    to_utm = bt.pyproj.Transformer.from_crs("EPSG:4326", "EPSG:32636", always_xy=True)
    ux, uy = (np.asarray(v).reshape(e.shape) for v in to_utm.transform(lon, lat))
    col = (ux - x0) / px - 0.5
    near_hole = (col > 298) & (col < 341)
    in_hole = (col > 300.5) & (col < 338.5)
    assert np.abs(color[..., 0][~near_hole] - (ux[~near_hole] - x0) / 3000.0 * 250.0).max() <= 1.0
    assert np.abs(color[..., 1][~near_hole] - (uy[~near_hole] - y0) / 3000.0 * 250.0).max() <= 1.0
    assert np.all(color[..., 2][~near_hole] == 128)
    assert in_hole.any() and np.all(color[in_hole] == 0)  # transparent: left black


def test_imagery_stretch(tmp_path):
    """A single-band uint16 image is stretched to 0..255 with --imagery-range."""
    tif = tmp_path / "grey.tif"
    t = from_origin(32.84, 39.95, 0.0002, 0.0002)
    with rasterio.open(tif, "w", driver="GTiff", width=200, height=200, count=1, dtype="uint16", crs="EPSG:4326",
                       transform=t) as ds:
        ds.write(np.full((200, 200), 3000, np.uint16), 1)
    pkg, _ = build(tmp_path, "--dem", copy_window(bt.fetch_dem_tile(TILE), tmp_path / "d.tif"), "--imagery", tif,
                   "--imagery-range", "1000", "5000")
    color = np.asarray(Image.open(pkg / "color.png"))
    assert np.all(np.abs(color.astype(int) - 128) <= 1)


def test_hillshade_package(reference):
    pkg, meta = reference
    color = np.asarray(Image.open(pkg / "color.png"))
    assert color.shape == (meta["color"]["samples"],) * 2 + (3,)
    assert color.std() > 5.0  # relief is visible
    assert meta["sources"]["imagery"]["product"].startswith("hillshade")
    assert json.loads((pkg / "terrain.json").read_text(encoding="utf-8"))["attribution"] == meta["attribution"]
