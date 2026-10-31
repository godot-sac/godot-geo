"""Builds a godot-geo terrain package from open data: Copernicus DEM GLO-30 heights and Sentinel-2 L2A colour,
resampled onto the local ENU grid of an origin so the terrain lines up with godot-dis entities.

Usage (repo root):
  tools/.venv/Scripts/python.exe -I tools/build_terrain.py --lat 39.9334 --lon 32.8597 --size 40000 --spacing 10 \
      --out terrain/ankara

Grid: square, centred on the origin, `size` metres wide. Row 0 is the north edge, column 0 the west edge, so sample
(row, col) sits at Godot (x = -size/2 + col*spacing, z = -size/2 + row*spacing). Each height is the ENU "up"
component of the terrain surface point whose ENU east/north are those of the sample, relative to the origin at
`origin_height` (ellipsoidal). The EGM2008 geoid and Earth curvature are therefore baked in, and DIS ECEF positions
converted with the same origin land on the surface.

Package (directory): height.exr (float32, channel R), color.png (RGB8), terrain.json (see write_package).
Downloads are cached in tools/.cache/ (DEM tiles, Sentinel-2 windows); PROJ caches the geoid grid itself.
"""
from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import sys
import time
import urllib.error
import urllib.request
from dataclasses import dataclass, field
from pathlib import Path

import numpy as np
import OpenEXR
import pymap3d
import pyproj
import rasterio
from PIL import Image
from rasterio.windows import from_bounds

VERSION = "0.1.0"
PACKAGE_FORMAT = "godot-geo-terrain"
PACKAGE_FORMAT_VERSION = 1

ROOT = Path(__file__).resolve().parent
CACHE = ROOT / ".cache"
WGS84 = pymap3d.Ellipsoid.from_name("wgs84")

DEM_URL = "https://copernicus-dem-30m.s3.amazonaws.com/{t}/{t}.tif"
DEM_STEP = 1.0 / 3600.0
STAC_SEARCH = "https://earth-search.aws.element84.com/v1/search"
GEOID_GRID = "us_nga_egm08_25.tif"

DEM_ATTRIBUTION = (
    "produced using Copernicus WorldDEM-30 © DLR e.V. 2010-2014 and © Airbus Defence and Space GmbH 2014-2018 "
    "provided under COPERNICUS by the European Union and ESA; all rights reserved"
)
DEM_DISCLAIMER = (
    "The organisations in charge of the Copernicus programme by law or by delegation do not incur any liability for "
    "any use of the Copernicus WorldDEM-30."
)


def log(msg: str) -> None:
    print(msg, flush=True)


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


# --- grid and coordinates ---------------------------------------------------------------------------------------

@dataclass(frozen=True)
class Grid:
    lat0: float
    lon0: float
    h0: float
    size: float
    spacing: float

    @property
    def count(self) -> int:
        n = self.size / self.spacing
        if abs(n - round(n)) > 1e-9:
            raise ValueError(f"size {self.size} is not a multiple of spacing {self.spacing}")
        return int(round(n)) + 1

    @property
    def half(self) -> float:
        return self.size * 0.5

    def east(self) -> np.ndarray:
        return -self.half + np.arange(self.count) * self.spacing

    def north(self) -> np.ndarray:
        return self.half - np.arange(self.count) * self.spacing  # row 0 = north edge

    def rows(self, r0: int, r1: int) -> tuple[np.ndarray, np.ndarray]:
        """East/north arrays for rows [r0, r1)."""
        e = np.broadcast_to(self.east()[None, :], (r1 - r0, self.count))
        n = np.broadcast_to(self.north()[r0:r1, None], (r1 - r0, self.count))
        return np.array(e), np.array(n)


def enu_to_geodetic(e, n, u, lat0, lon0, h0):
    return pymap3d.enu2geodetic(e, n, u, lat0, lon0, h0, WGS84)


def geodetic_to_enu(lat, lon, h, lat0, lon0, h0):
    return pymap3d.geodetic2enu(lat, lon, h, lat0, lon0, h0, WGS84)


def bilinear(arr: np.ndarray, r: np.ndarray, c: np.ndarray) -> np.ndarray:
    """Bilinear sample of `arr` at fractional (row, col) where integer indices are sample centres."""
    r0 = np.clip(np.floor(r).astype(np.int64), 0, arr.shape[0] - 2)
    c0 = np.clip(np.floor(c).astype(np.int64), 0, arr.shape[1] - 2)
    fr = r - r0
    fc = c - c0
    a = arr[r0, c0] * (1 - fc) + arr[r0, c0 + 1] * fc
    b = arr[r0 + 1, c0] * (1 - fc) + arr[r0 + 1, c0 + 1] * fc
    return a * (1 - fr) + b * fr


def grid_bounds(grid: Grid, margin_deg: float = 0.005) -> tuple[float, float, float, float]:
    """(lat_min, lat_max, lon_min, lon_max) covering the grid edges, with a margin."""
    h = grid.half
    t = np.linspace(-h, h, 65)
    e = np.concatenate([t, t, np.full_like(t, -h), np.full_like(t, h)])
    n = np.concatenate([np.full_like(t, -h), np.full_like(t, h), t, t])
    lat, lon, _ = enu_to_geodetic(e, n, np.zeros_like(e), grid.lat0, grid.lon0, grid.h0)
    return (float(lat.min()) - margin_deg, float(lat.max()) + margin_deg,
            float(lon.min()) - margin_deg, float(lon.max()) + margin_deg)


# --- Copernicus DEM ---------------------------------------------------------------------------------------------

def dem_tile_name(lat: int, lon: int) -> str:
    ns = "N" if lat >= 0 else "S"
    ew = "E" if lon >= 0 else "W"
    return f"Copernicus_DSM_COG_10_{ns}{abs(lat):02d}_00_{ew}{abs(lon):03d}_00_DEM"


def fetch_dem_tile(name: str) -> Path | None:
    """Downloads a GLO-30 tile into the cache. None if the tile does not exist (open sea)."""
    path = CACHE / "copdem30" / f"{name}.tif"
    missing = path.with_suffix(".missing")
    if path.exists():
        return path
    if missing.exists():
        return None
    path.parent.mkdir(parents=True, exist_ok=True)
    log(f"  downloading {name}")
    try:
        urllib.request.urlretrieve(DEM_URL.format(t=name), path.with_suffix(".part"))
    except urllib.error.HTTPError as err:
        if err.code in (403, 404):
            missing.touch()
            return None
        raise
    path.with_suffix(".part").rename(path)
    return path


@dataclass
class DemMosaic:
    data: np.ndarray  # float32, rows north -> south
    lat_row0: float  # latitude of row 0 sample centres
    lon_col0: float  # longitude of column 0 sample centres
    tiles: list[dict] = field(default_factory=list)

    def sample(self, lat: np.ndarray, lon: np.ndarray) -> np.ndarray:
        return bilinear(self.data, (self.lat_row0 - lat) / DEM_STEP, (lon - self.lon_col0) / DEM_STEP)


def load_dem(lat_min: float, lat_max: float, lon_min: float, lon_max: float) -> DemMosaic:
    """Mosaic of the GLO-30 tiles covering the box. Pixel-is-point: in tile N{lat}E{lon} row 0 is latitude lat+1 and
    column 0 longitude lon, so neighbouring tiles abut without overlap. Missing tiles (sea) are filled with 0 m."""
    lats = list(range(int(np.floor(lat_min)), int(np.floor(lat_max)) + 1))
    lons = list(range(int(np.floor(lon_min)), int(np.floor(lon_max)) + 1))
    if max(abs(lats[0]), abs(lats[-1] + 1)) > 50:
        raise NotImplementedError("GLO-30 tiles above 50° latitude have fewer columns; not supported yet")
    tiles, rows = [], []
    for lat in reversed(lats):
        row = []
        for lon in lons:
            name = dem_tile_name(lat, lon)
            path = fetch_dem_tile(name)
            if path is None:
                row.append(np.zeros((3600, 3600), np.float32))
                tiles.append({"name": name, "missing": True})
                continue
            with rasterio.open(path) as ds:
                if (ds.width, ds.height) != (3600, 3600) or ds.tags().get("AREA_OR_POINT") != "Point":
                    raise ValueError(f"{name}: unexpected layout")
                row.append(ds.read(1).astype(np.float32))
            tiles.append({"name": name, "sha256": sha256_file(path)})
        rows.append(np.hstack(row))
    return DemMosaic(np.vstack(rows), float(lats[-1] + 1), float(lons[0]), tiles)


# --- geoid ------------------------------------------------------------------------------------------------------

class Geoid:
    """EGM2008 geoid height N (m) from the PROJ grid us_nga_egm08_25 (NGA, public domain)."""

    def __init__(self) -> None:
        pyproj.network.set_network_enabled(True)
        group = pyproj.transformer.TransformerGroup("EPSG:4979", "EPSG:4326+3855", always_xy=True)
        # Without the grid PROJ would fall back to a "ballpark" no-op; insist on the NGA grid.
        chosen = [t for t in group.transformers if GEOID_GRID in t.definition]
        if not chosen:
            raise RuntimeError(f"PROJ grid {GEOID_GRID} unavailable (network off and not cached?)")
        self._t = chosen[0]

    def height(self, lat, lon):
        lat = np.asarray(lat, dtype=np.float64)
        _, _, h_ortho = self._t.transform(np.asarray(lon, dtype=np.float64), lat, np.zeros_like(lat))
        n = -np.asarray(h_ortho)
        if not np.all(np.isfinite(n)):
            raise RuntimeError("geoid grid unavailable (no network and no cached grid?)")
        return n


# --- heights ----------------------------------------------------------------------------------------------------

def solve_heights(grid: Grid, dem: DemMosaic, geoid: Geoid, block_rows: int = 256) -> np.ndarray:
    """ENU up of the terrain surface at every grid sample. Fixed-point iteration along the local vertical:
    u <- u + (h_terrain(lat, lon) - h(e, n, u)); converges to < 1 mm in 3-4 steps (the vertical deviates from
    the geodetic normal by < 0.5° within 50 km)."""
    out = np.empty((grid.count, grid.count), np.float32)
    for r0 in range(0, grid.count, block_rows):
        r1 = min(r0 + block_rows, grid.count)
        e, n = grid.rows(r0, r1)
        u = np.zeros_like(e)
        lat, lon, _ = enu_to_geodetic(e, n, u, grid.lat0, grid.lon0, grid.h0)
        # N changes by centimetres across the area; evaluate once per block on the first guess (< 1 mm error).
        n_geoid = geoid.height(lat, lon)
        for _ in range(6):
            lat, lon, h = enu_to_geodetic(e, n, u, grid.lat0, grid.lon0, grid.h0)
            du = dem.sample(lat, lon) + n_geoid - h
            u += du
            if np.abs(du).max() < 1e-4:
                break
        else:
            raise RuntimeError("height iteration did not converge")
        out[r0:r1] = u
        log(f"  rows {r1}/{grid.count}")
    return out


# --- Sentinel-2 colour ------------------------------------------------------------------------------------------

def stac_search(bbox: list[float], year: int, max_cloud: float) -> list[dict]:
    body = {
        "collections": ["sentinel-2-l2a"],
        "bbox": bbox,
        "datetime": f"{year}-06-01T00:00:00Z/{year}-08-31T23:59:59Z",
        "query": {"eo:cloud_cover": {"lt": max_cloud}},
        "limit": 200,
    }
    req = urllib.request.Request(STAC_SEARCH, data=json.dumps(body).encode(), headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req) as r:
        return json.load(r)["features"]


def stac_item(scene_id: str) -> dict:
    url = f"https://earth-search.aws.element84.com/v1/collections/sentinel-2-l2a/items/{scene_id}"
    with urllib.request.urlopen(url) as r:
        return json.load(r)


def read_scene_window(href: str, scene_id: str, lat: np.ndarray, lon: np.ndarray):
    """Reads (and caches) the part of the TCI COG covering the given points.
    Returns (uint8 array [3, h, w], window transform, x, y) with x/y the points in the scene CRS."""
    with rasterio.Env(GDAL_DISABLE_READDIR_ON_OPEN="EMPTY_DIR", CPL_VSIL_CURL_ALLOWED_EXTENSIONS=".tif"):
        with rasterio.open(href) as ds:
            x, y = pyproj.Transformer.from_crs("EPSG:4326", ds.crs.to_wkt(), always_xy=True).transform(lon, lat)
            bounds = (float(x.min()) - 30, float(y.min()) - 30, float(x.max()) + 30, float(y.max()) + 30)
            win = from_bounds(*bounds, transform=ds.transform).round_offsets().round_lengths()
            key = f"{scene_id}_{int(win.col_off)}_{int(win.row_off)}_{int(win.width)}_{int(win.height)}.npy"
            path = CACHE / "s2" / key
            if path.exists():
                data = np.load(path)
            else:
                t0 = time.time()
                data = ds.read(window=win, boundless=True, fill_value=0)
                log(f"  read {scene_id} window {data.shape[1]}x{data.shape[2]} in {time.time() - t0:.1f} s")
                if data.any():  # an all-empty window (outside the scene) is not worth caching
                    path.parent.mkdir(parents=True, exist_ok=True)
                    np.save(path, data)
            return data, ds.window_transform(win), x, y


def bbox_overlap(scene: list[float], area: tuple[float, float, float, float]) -> float:
    """Fraction of `area` (lon_min, lat_min, lon_max, lat_max) inside the scene's footprint box."""
    w = min(scene[2], area[2]) - max(scene[0], area[0])
    h = min(scene[3], area[3]) - max(scene[1], area[1])
    if w <= 0 or h <= 0:
        return 0.0
    return (w * h) / ((area[2] - area[0]) * (area[3] - area[1]))


MAX_SCENE_READS = 12


def build_color(grid: Grid, year: int, max_cloud: float, scene_ids: list[str] | None) -> tuple[np.ndarray, list[dict]]:
    """Colour of every grid sample from Sentinel-2 L2A true-colour (TCI) images. Scenes are taken clearest first
    until every sample is covered (TCI value 0 = no data)."""
    e, n = grid.rows(0, grid.count)
    lat, lon, _ = enu_to_geodetic(e, n, np.zeros_like(e), grid.lat0, grid.lon0, grid.h0)
    del e, n
    if scene_ids:
        items = [stac_item(s) for s in scene_ids]
    else:
        lat_min, lat_max, lon_min, lon_max = grid_bounds(grid)
        items = stac_search([lon_min, lat_min, lon_max, lat_max], year, max_cloud)
        if not items:
            raise RuntimeError(f"no Sentinel-2 scene with cloud < {max_cloud}% in summer {year}")
        # Scenes whose footprint box covers the whole area first (MGRS tiles overlap, so the box of a
        # neighbouring tile may only clip an edge), then the clearest.
        area = (lon_min, lat_min, lon_max, lat_max)
        items = [f for f in items if bbox_overlap(f["bbox"], area) > 0.0]
        items.sort(key=lambda f: (-round(bbox_overlap(f["bbox"], area), 2), f["properties"]["eo:cloud_cover"]))
    color = np.zeros((grid.count, grid.count, 3), np.uint8)
    filled = np.zeros((grid.count, grid.count), bool)
    used = []
    exhausted = set()  # MGRS tiles whose footprint adds nothing more (scenes of one tile cover the same ground)
    reads = 0
    for item in items:
        tile = item["id"].split("_")[1]
        if tile in exhausted:
            continue
        if reads >= MAX_SCENE_READS:
            break
        reads += 1
        data, transform, x, y = read_scene_window(item["assets"]["visual"]["href"], item["id"], lat, lon)
        c, r = ~transform @ (x, y)
        r -= 0.5  # raster coordinates address pixel corners; centres sit at +0.5
        c -= 0.5
        # A sample is valid when its four neighbours all hold data.
        r0 = np.clip(np.floor(r).astype(np.int64), 0, data.shape[1] - 2)
        c0 = np.clip(np.floor(c).astype(np.int64), 0, data.shape[2] - 2)
        nodata = data.sum(axis=0) == 0
        valid = ~(nodata[r0, c0] | nodata[r0 + 1, c0] | nodata[r0, c0 + 1] | nodata[r0 + 1, c0 + 1])
        take = valid & ~filled
        if take.any():
            for k in range(3):
                band = bilinear(data[k].astype(np.float32), r[take], c[take])
                color[..., k][take] = np.clip(band + 0.5, 0, 255).astype(np.uint8)
            filled |= take
            p = item["properties"]
            used.append({"id": item["id"], "datetime": p["datetime"], "cloud_cover": p["eo:cloud_cover"],
                         "coverage": float(take.mean())})
            log(f"  {item['id']}: {take.mean() * 100:.1f} % of samples (cloud {p['eo:cloud_cover']:.3f} %)")
        if take.mean() < 1e-4:
            exhausted.add(tile)
            log(f"  {item['id']}: nothing new, skipping other scenes of tile {tile}")
        if filled.all() or len(used) >= 8:
            break
    if not filled.all():
        log(f"  warning: {(~filled).mean() * 100:.2f} % of samples without colour (left black)")
    return color, used


# --- package ----------------------------------------------------------------------------------------------------

def write_exr(path: Path, data: np.ndarray) -> None:
    header = {"compression": OpenEXR.ZIP_COMPRESSION, "type": OpenEXR.scanlineimage}
    with OpenEXR.File(header, {"R": np.ascontiguousarray(data, dtype=np.float32)}) as f:
        f.write(str(path))


def corner_coordinates(grid: Grid) -> dict:
    h = grid.half
    out = {}
    for name, e, n in [("nw", -h, h), ("ne", h, h), ("sw", -h, -h), ("se", h, -h)]:
        lat, lon, _ = enu_to_geodetic(e, n, 0.0, grid.lat0, grid.lon0, grid.h0)
        out[name] = {"east": e, "north": n, "latitude": float(lat), "longitude": float(lon)}
    return out


def write_package(out: Path, grid: Grid, color_grid: Grid, height: np.ndarray, color: np.ndarray,
                  dem: DemMosaic, scenes: list[dict], geoid_range: tuple[float, float]) -> dict:
    out.mkdir(parents=True, exist_ok=True)
    write_exr(out / "height.exr", height)
    Image.fromarray(color).save(out / "color.png")
    years = sorted({s["datetime"][:4] for s in scenes})
    meta = {
        "format": PACKAGE_FORMAT,
        "format_version": PACKAGE_FORMAT_VERSION,
        "generator": f"godot-geo tools/build_terrain.py {VERSION}",
        "created": dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds"),
        "origin": {"latitude": grid.lat0, "longitude": grid.lon0, "height": grid.h0},
        "frame": "local ENU tangent plane at the origin (WGS84); Godot +X east, +Y up, -Z north; "
                 "row 0 = north edge, column 0 = west edge",
        "size_m": grid.size,
        "height": {
            "file": "height.exr", "encoding": "OpenEXR float32, channel R, metres",
            "samples": grid.count, "spacing_m": grid.spacing,
            "min": float(height.min()), "max": float(height.max()),
            "reference": "ENU up relative to the origin; EGM2008 geoid and Earth curvature included",
            "interpolation": "bilinear between samples",
            "sha256": sha256_file(out / "height.exr"),
        },
        "color": {
            "file": "color.png", "encoding": "PNG RGB8, sRGB (Sentinel-2 L2A TCI)",
            "samples": color_grid.count, "spacing_m": color_grid.spacing,
            "sha256": sha256_file(out / "color.png"),
        },
        "corners": corner_coordinates(grid),
        "sources": {
            "elevation": {"product": "Copernicus DEM GLO-30 (DSM)", "vertical_datum": "EGM2008",
                          "access": "s3://copernicus-dem-30m", "tiles": dem.tiles},
            "geoid": {"model": "EGM2008", "grid": f"PROJ {GEOID_GRID} (NGA, public domain)",
                      "n_min_m": geoid_range[0], "n_max_m": geoid_range[1]},
            "imagery": {"product": "Sentinel-2 L2A true colour (TCI)",
                        "access": "Earth Search STAC (earth-search.aws.element84.com/v1)", "scenes": scenes},
        },
        "attribution": [DEM_ATTRIBUTION, f"Contains modified Copernicus Sentinel data {', '.join(years)}"],
        "disclaimer": DEM_DISCLAIMER,
    }
    (out / "terrain.json").write_text(json.dumps(meta, indent=2, ensure_ascii=False) + "\n", encoding="utf-8",
                                      newline="\n")
    gdignore = out.parent / ".gdignore"  # keep the Godot editor from importing big package files under res://
    if out.parent.name == "terrain" and not gdignore.exists():
        gdignore.touch()
    return meta


def build(args: argparse.Namespace) -> dict:
    grid = Grid(args.lat, args.lon, args.origin_height, args.size, args.spacing)
    color_grid = Grid(args.lat, args.lon, args.origin_height, args.size, args.color_spacing or args.spacing)
    log(f"height grid {grid.count}x{grid.count} @ {grid.spacing} m, colour {color_grid.count}x{color_grid.count} "
        f"@ {color_grid.spacing} m")
    t0 = time.time()
    log("elevation:")
    dem = load_dem(*grid_bounds(grid, margin_deg=0.01))
    geoid = Geoid()
    height = solve_heights(grid, dem, geoid)
    corners = corner_coordinates(grid)
    clat = [c["latitude"] for c in corners.values()] + [grid.lat0]
    clon = [c["longitude"] for c in corners.values()] + [grid.lon0]
    n_vals = geoid.height(clat, clon)
    log("colour:")
    color, scenes = build_color(color_grid, args.year, args.max_cloud, args.scene)
    meta = write_package(Path(args.out), grid, color_grid, height, color, dem, scenes,
                         (float(n_vals.min()), float(n_vals.max())))
    log(f"done in {time.time() - t0:.0f} s: {args.out} (heights {meta['height']['min']:.1f} .. "
        f"{meta['height']['max']:.1f} m)")
    return meta


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--lat", type=float, required=True, help="origin latitude (deg)")
    ap.add_argument("--lon", type=float, required=True, help="origin longitude (deg)")
    ap.add_argument("--origin-height", type=float, default=0.0,
                    help="origin ellipsoidal height (m); heights are relative to it (default 0)")
    ap.add_argument("--size", type=float, required=True, help="edge length of the square area (m)")
    ap.add_argument("--spacing", type=float, default=10.0, help="height sample spacing (m)")
    ap.add_argument("--color-spacing", type=float, default=None, help="colour sample spacing (m, default = spacing)")
    ap.add_argument("--year", type=int, default=2025, help="summer (Jun-Aug) to take Sentinel-2 scenes from")
    ap.add_argument("--max-cloud", type=float, default=5.0, help="maximum scene cloud cover (%%)")
    ap.add_argument("--scene", action="append", help="use this Sentinel-2 scene id (repeatable) instead of searching")
    ap.add_argument("--out", required=True, help="output package directory")
    return ap.parse_args(argv)


if __name__ == "__main__":
    build(parse_args())
    sys.exit(0)
