"""Phase 0 prototype: build a terrain package for Ankara on the local ENU grid so the two renderers (Terrain3D and our
own mesh) can be compared on real data. Phase 1 turns this into tools/build_terrain.py with caching, hashes, tests.

Grid: square, centred on the origin, `size` metres wide, `spacing` metres between samples. Row 0 is the north edge,
column 0 the west edge, so (row, col) maps to Godot (x = -size/2 + col*spacing, z = -size/2 + row*spacing).
Each height is the ENU "up" component of the terrain point straight above/below the grid point, relative to the
origin at ellipsoidal height 0: geoid height and Earth curvature are baked in, so DIS ECEF positions line up.

Output (terrain/<name>/): height.r32 (float32 little-endian, rows north->south), color.png, terrain.json.
"""
import argparse
import json
import time
import urllib.request
from pathlib import Path

import numpy as np
import pymap3d
import pyproj
import rasterio
from PIL import Image
from rasterio.warp import transform_bounds
from rasterio.windows import from_bounds

ROOT = Path(__file__).resolve().parent
CACHE = ROOT / ".cache" / "copdem30"
DEM_URL = "https://copernicus-dem-30m.s3.amazonaws.com/{t}/{t}.tif"
WGS84 = pymap3d.Ellipsoid.from_name("wgs84")

DEM_ATTRIBUTION = (
    "produced using Copernicus WorldDEM-30 (c) DLR e.V. 2010-2014 and (c) Airbus Defence and Space GmbH 2014-2018 "
    "provided under COPERNICUS by the European Union and ESA; all rights reserved"
)


def dem_tile_name(lat: int, lon: int) -> str:
    ns = "N" if lat >= 0 else "S"
    ew = "E" if lon >= 0 else "W"
    return f"Copernicus_DSM_COG_10_{ns}{abs(lat):02d}_00_{ew}{abs(lon):03d}_00_DEM"


def load_dem_mosaic(lat_min: float, lat_max: float, lon_min: float, lon_max: float):
    """Mosaic of 1x1 degree GLO-30 tiles (pixel-is-point, 1 arcsec). Returns (array, lat_of_row0, lon_of_col0, step).
    Only valid below 50 degrees latitude, where every tile is 3600x3600."""
    lats = range(int(np.floor(lat_min)), int(np.floor(lat_max)) + 1)
    lons = range(int(np.floor(lon_min)), int(np.floor(lon_max)) + 1)
    rows = []
    for lat in reversed(lats):  # north first
        row = []
        for lon in lons:
            name = dem_tile_name(lat, lon)
            path = CACHE / f"{name}.tif"
            if not path.exists():
                CACHE.mkdir(parents=True, exist_ok=True)
                print("downloading", name)
                urllib.request.urlretrieve(DEM_URL.format(t=name), path.with_suffix(".part"))
                path.with_suffix(".part").rename(path)
            with rasterio.open(path) as ds:
                assert ds.width == 3600 and ds.height == 3600, f"{name}: unexpected size"
                row.append(ds.read(1))
        rows.append(np.hstack(row))
    step = 1.0 / 3600.0
    return np.vstack(rows), float(lats[-1] + 1), float(lons[0]), step


def bilinear(arr: np.ndarray, r: np.ndarray, c: np.ndarray) -> np.ndarray:
    r0 = np.clip(np.floor(r).astype(np.int64), 0, arr.shape[0] - 2)
    c0 = np.clip(np.floor(c).astype(np.int64), 0, arr.shape[1] - 2)
    fr = (r - r0).astype(np.float32)
    fc = (c - c0).astype(np.float32)
    a = arr[r0, c0] * (1 - fc) + arr[r0, c0 + 1] * fc
    b = arr[r0 + 1, c0] * (1 - fc) + arr[r0 + 1, c0 + 1] * fc
    return a * (1 - fr) + b * fr


def geoid_grid(lat: np.ndarray, lon: np.ndarray) -> np.ndarray:
    """EGM2008 geoid height N (m) via PROJ grid us_nga_egm08_25, computed on a coarse grid and upsampled
    (N varies by centimetres over hundreds of metres)."""
    pyproj.network.set_network_enabled(True)
    t = pyproj.Transformer.from_crs("EPSG:4979", "EPSG:4326+3855", always_xy=True)
    stride = 50
    lat_c, lon_c = lat[::stride, ::stride], lon[::stride, ::stride]
    _, _, h_ortho = t.transform(lon_c, lat_c, np.zeros_like(lat_c))
    n_c = -np.asarray(h_ortho)
    assert np.all(np.isfinite(n_c)), "geoid grid unavailable"
    rr = np.arange(lat.shape[0]) / stride
    cc = np.arange(lat.shape[1]) / stride
    pad = np.pad(n_c, ((0, 1), (0, 1)), mode="edge")
    return bilinear(pad, rr[:, None] + 0 * cc[None, :], cc[None, :] + 0 * rr[:, None])


def build_height(lat0, lon0, e, n, dem, dem_lat0, dem_lon0, step):
    """Find, for every (e, n), the ENU up value u of the terrain surface point with those E/N coordinates."""
    u = np.zeros_like(e)
    geoid = None
    for it in range(4):
        lat, lon, h_pt = pymap3d.enu2geodetic(e, n, u, lat0, lon0, 0.0, WGS84)
        if geoid is None:
            geoid = geoid_grid(lat, lon)
        h_terrain = bilinear(dem, (dem_lat0 - lat) / step, (lon - dem_lon0) / step) + geoid
        du = h_terrain - h_pt  # along the local normal; the normal is within 0.2 deg of "up" here
        u = u + du
        print(f"  iteration {it}: max |du| = {np.abs(du).max():.4f} m")
    return u.astype(np.float32), geoid


def build_color(lat0, lon0, e, n, scene_href: str) -> np.ndarray:
    lat, lon, _ = pymap3d.enu2geodetic(e, n, np.zeros_like(e), lat0, lon0, 0.0, WGS84)
    with rasterio.Env(GDAL_DISABLE_READDIR_ON_OPEN="EMPTY_DIR", CPL_VSIL_CURL_ALLOWED_EXTENSIONS=".tif"):
        with rasterio.open(scene_href) as ds:
            to_utm = pyproj.Transformer.from_crs("EPSG:4326", ds.crs, always_xy=True)
            x, y = to_utm.transform(lon, lat)
            b = (x.min() - 50, y.min() - 50, x.max() + 50, y.max() + 50)
            win = from_bounds(*b, transform=ds.transform).round_offsets().round_lengths()
            t0 = time.time()
            data = ds.read(window=win, boundless=True, fill_value=0).astype(np.float32)
            print(f"  read S2 window {data.shape} in {time.time() - t0:.1f} s")
            wt = ds.window_transform(win)
    inv = ~wt
    c, r = inv * (x, y)
    # Raster coordinates address pixel corners; centres are at +0.5.
    out = np.stack([bilinear(data[k], r - 0.5, c - 0.5) for k in range(3)], axis=-1)
    return np.clip(out + 0.5, 0, 255).astype(np.uint8)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--lat", type=float, default=39.9334)
    ap.add_argument("--lon", type=float, default=32.8597)
    ap.add_argument("--size", type=float, default=40000.0)
    ap.add_argument("--spacing", type=float, default=10.0)
    ap.add_argument("--scene", default=str(ROOT / ".cache" / "probe" / "s2_scene.json"))
    ap.add_argument("--out", default=str(ROOT.parent / "terrain" / "ankara_proto"))
    a = ap.parse_args()

    count = int(round(a.size / a.spacing)) + 1
    half = (count - 1) / 2 * a.spacing
    axis = -half + np.arange(count) * a.spacing
    e = np.broadcast_to(axis[None, :], (count, count)).copy()
    n = np.broadcast_to(-axis[:, None], (count, count)).copy()  # row 0 = north
    print(f"grid {count}x{count} @ {a.spacing} m")

    lat_c, lon_c, _ = pymap3d.enu2geodetic(np.array([-half, half]), np.array([-half, half]), 0, a.lat, a.lon, 0, WGS84)
    dem, dem_lat0, dem_lon0, step = load_dem_mosaic(lat_c.min() - 0.01, lat_c.max() + 0.01,
                                                    lon_c.min() - 0.01, lon_c.max() + 0.01)
    print("height:")
    height, geoid = build_height(a.lat, a.lon, e, n, dem, dem_lat0, dem_lon0, step)
    scene = json.loads(Path(a.scene).read_text())
    print("color:", scene["id"])
    color = build_color(a.lat, a.lon, e, n, scene["href"])

    out = Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    (out.parent / ".gdignore").touch()  # keep the Godot editor from importing package files
    height.astype("<f4").tofile(out / "height.r32")
    Image.fromarray(color).save(out / "color.png", optimize=False)
    meta = {
        "format": "godot-geo-prototype",
        "origin": {"latitude": a.lat, "longitude": a.lon, "height": 0.0},
        "size_m": 2 * half, "spacing_m": a.spacing, "samples": count,
        "height": {"file": "height.r32", "dtype": "float32-le", "min": float(height.min()), "max": float(height.max()),
                   "reference": "ENU up relative to origin at ellipsoidal height 0 (geoid EGM2008 + curvature)"},
        "color": {"file": "color.png", "scene": scene["id"], "datetime": scene["datetime"]},
        "geoid_n_m": {"min": float(geoid.min()), "max": float(geoid.max())},
        "attribution": [DEM_ATTRIBUTION, f"Contains modified Copernicus Sentinel data {scene['datetime'][:4]}"],
    }
    (out / "terrain.json").write_text(json.dumps(meta, indent=2))
    print(json.dumps(meta, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
