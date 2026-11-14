"""Builds a godot-geo terrain package, resampled onto the local ENU grid of an origin so the terrain lines up with
godot-dis entities. Elevation: Copernicus DEM GLO-30 (downloaded) or your own DTED / GeoTIFF files. Colour:
Sentinel-2 L2A (downloaded), your own GeoTIFF imagery, or a hillshade computed from the heights.

Usage (repo root):
  tools/.venv/Scripts/python.exe -I tools/build_terrain.py --lat 39.9334 --lon 32.8597 --size 40000 --spacing 10 \
      --out terrain/ankara
  tools/.venv/Scripts/python.exe -I tools/build_terrain.py --lat 39.93 --lon 32.86 --size 20000 --spacing 30 \
      --dem data/dted --imagery data/ortho.tif --attribution "Elevation: ..." --offline --out terrain/mine

Grid: square, centred on the origin, `size` metres wide. Row 0 is the north edge, column 0 the west edge, so sample
(row, col) sits at Godot (x = -size/2 + col*spacing, z = -size/2 + row*spacing). Each height is the ENU "up"
component of the terrain surface point whose ENU east/north are those of the sample, relative to the origin at
`origin_height` (ellipsoidal). The geoid and Earth curvature are therefore baked in, and DIS ECEF positions
converted with the same origin land on the surface.

Package (directory): height.exr (float32, channel R), color.png (RGB8), terrain.json (see write_package), and
the optional layers of --layers (tools/layers.py), e.g. water.png.
Downloads are cached in tools/.cache/ (DEM tiles, Sentinel-2 windows, geoid grids from --fetch-geoid). GDAL,
rasterio and PROJ are used here only; the Godot addon reads the package with engine APIs.
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
import warnings
from dataclasses import dataclass, field
from pathlib import Path

import numpy as np
import OpenEXR
import pymap3d
import pyproj
import rasterio
from PIL import Image
from rasterio.windows import Window, from_bounds

sys.path.insert(0, str(Path(__file__).resolve().parent))  # -I leaves the script directory off sys.path
import dted  # noqa: E402
import buildings as geo_buildings  # noqa: E402
import roads as geo_roads  # noqa: E402
import layers as geo_layers  # noqa: E402

VERSION = "0.2.0"
PACKAGE_FORMAT = "godot-geo-terrain"
PACKAGE_FORMAT_VERSION = 1

ROOT = Path(__file__).resolve().parent
CACHE = ROOT / ".cache"
WGS84 = pymap3d.Ellipsoid.from_name("wgs84")
EARTH_RADIUS = 6_371_000.0

DEM_URL = "https://copernicus-dem-30m.s3.amazonaws.com/{t}/{t}.tif"
DEM_ROWS = 3600
STAC_SEARCH = "https://earth-search.aws.element84.com/v1/search"
PROJ_CDN = "https://cdn.proj.org/{f}"
# Vertical datum -> (PROJ grid, compound CRS of WGS 84 + that height). Both grids: NGA, public domain.
GEOIDS = {
    "egm2008": ("us_nga_egm08_25.tif", "EPSG:4326+3855"),
    "egm96": ("us_nga_egm96_15.tif", "EPSG:4326+5773"),
}
GEOID_GRID = GEOIDS["egm2008"][0]
VERTICAL_DATUMS = ("egm2008", "egm96", "ellipsoid")

DEM_ATTRIBUTION = (
    "produced using Copernicus WorldDEM-30 © DLR e.V. 2010-2014 and © Airbus Defence and Space GmbH 2014-2018 "
    "provided under COPERNICUS by the European Union and ESA; all rights reserved"
)
DEM_DISCLAIMER = (
    "The organisations in charge of the Copernicus programme by law or by delegation do not incur any liability for "
    "any use of the Copernicus WorldDEM-30."
)

DEM_SUFFIXES = (".dt0", ".dt1", ".dt2", ".tif", ".tiff")


def log(msg: str) -> None:
    print(msg, flush=True)


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


# --- network ----------------------------------------------------------------------------------------------------

class OfflineError(RuntimeError):
    pass


OFFLINE = False
NETWORK_USED: list[str] = []


HTTP_TIMEOUT = 60.0  # seconds without data before a download is retried
HTTP_RETRIES = 4


def download(url: str, path: Path) -> None:
    """Downloads `url` to `path` via `path`.part, with a socket timeout, retries and HTTP Range resume of the partial
    file (a stalled transfer otherwise hangs the build). HTTPError other than a server error is raised at once."""
    part = path.with_suffix(path.suffix + ".part")
    for attempt in range(HTTP_RETRIES):
        have = part.stat().st_size if part.exists() else 0
        req = urllib.request.Request(url, headers={"Range": f"bytes={have}-"} if have else {})
        try:
            with urllib.request.urlopen(req, timeout=HTTP_TIMEOUT) as r, open(part, "ab" if have else "wb") as f:
                if have and r.status != 206:  # the server ignored the range: start over
                    f.truncate(0)
                while chunk := r.read(1 << 20):
                    f.write(chunk)
            part.replace(path)
            return
        except urllib.error.HTTPError as err:
            if err.code == 416:  # nothing left to read: the partial file is complete
                part.replace(path)
                return
            if err.code < 500 or attempt == HTTP_RETRIES - 1:
                raise
        except (urllib.error.URLError, TimeoutError, ConnectionError, OSError) as err:
            if attempt == HTTP_RETRIES - 1:
                raise RuntimeError(f"download of {url} failed: {err}") from err
        log(f"  retrying {url.rsplit('/', 1)[-1]} ({attempt + 2}/{HTTP_RETRIES})")
        time.sleep(2.0 * (attempt + 1))


def network(what: str) -> None:
    """Call before any download. Raises with --offline; otherwise records what went over the network."""
    if OFFLINE:
        raise OfflineError(f"--offline: would need the network for {what}")
    NETWORK_USED.append(what)


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


def wrap_lon(lon):
    """Longitude in [-180, 180)."""
    return (np.asarray(lon, dtype=np.float64) + 180.0) % 360.0 - 180.0


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


def bilinear_inside(arr: np.ndarray, r: np.ndarray, c: np.ndarray) -> np.ndarray:
    """bilinear(), NaN outside the sample centres (no extrapolation). NaN samples propagate."""
    out = bilinear(arr, r, c).astype(np.float64)
    out[(r < 0) | (c < 0) | (r > arr.shape[0] - 1) | (c > arr.shape[1] - 1)] = np.nan
    return out


def grid_bounds(grid: Grid, margin_deg: float = 0.005) -> tuple[float, float, float, float]:
    """(lat_min, lat_max, lon_min, lon_max) covering the grid edges, with a margin. Longitudes are continuous around
    the origin, so across the antimeridian lon_max may exceed 180 (or lon_min fall below -180)."""
    h = grid.half
    t = np.linspace(-h, h, 65)
    e = np.concatenate([t, t, np.full_like(t, -h), np.full_like(t, h)])
    n = np.concatenate([np.full_like(t, -h), np.full_like(t, h), t, t])
    lat, lon, _ = enu_to_geodetic(e, n, np.zeros_like(e), grid.lat0, grid.lon0, grid.h0)
    lon = grid.lon0 + wrap_lon(lon - grid.lon0)
    return (float(lat.min()) - margin_deg, float(lat.max()) + margin_deg,
            float(lon.min()) - margin_deg, float(lon.max()) + margin_deg)


def bounds_outline(bounds: tuple[float, float, float, float], n: int = 33) -> tuple[np.ndarray, np.ndarray]:
    """Points along the edge of a bounds box (lat, lon arrays), for transforming it into another CRS."""
    lat_min, lat_max, lon_min, lon_max = bounds
    a, b = np.linspace(lat_min, lat_max, n), np.linspace(lon_min, lon_max, n)
    lat = np.concatenate([a, a, np.full(n, lat_min), np.full(n, lat_max)])
    lon = np.concatenate([np.full(n, lon_min), np.full(n, lon_max), b, b])
    return lat, lon


# --- elevation sources ------------------------------------------------------------------------------------------
# A source returns heights above its own vertical datum (`vertical`), NaN where it has no data. Sources are tried
# in order, so the first one that covers a sample supplies it.

def dem_tile_name(lat: int, lon: int) -> str:
    ns = "N" if lat >= 0 else "S"
    ew = "E" if lon >= 0 else "W"
    return f"Copernicus_DSM_COG_10_{ns}{abs(lat):02d}_00_{ew}{abs(lon):03d}_00_DEM"


def dem_tile_width(lat: int) -> int:
    """Columns of the GLO-30 tile with south edge `lat`: fewer towards the poles (Copernicus DEM product handbook)."""
    edge = min(abs(lat), abs(lat + 1))  # equatorward edge
    for limit, width in ((50, 3600), (60, 2400), (70, 1800), (80, 1200), (85, 720)):
        if edge < limit:
            return width
    return 360


def fetch_dem_tile(name: str) -> Path | None:
    """Downloads a GLO-30 tile into the cache. None if the tile does not exist (open sea)."""
    path = CACHE / "copdem30" / f"{name}.tif"
    missing = path.with_suffix(".missing")
    if path.exists():
        return path
    if missing.exists():
        return None
    network(f"Copernicus DEM tile {name}")
    path.parent.mkdir(parents=True, exist_ok=True)
    log(f"  downloading {name}")
    try:
        download(DEM_URL.format(t=name), path)
    except urllib.error.HTTPError as err:
        if err.code in (403, 404):
            missing.touch()
            return None
        raise
    return path


class CopernicusDem:
    """Copernicus DEM GLO-30 tiles covering a box, anywhere on Earth. Pixel-is-point: in tile N{lat}E{lon} row 0 is
    latitude lat+1 and column 0 longitude lon, so neighbouring tiles abut without overlap; the gap between a tile's
    last row / column and its neighbour's first is bridged by extending each tile with that neighbour row / column
    (resampled along longitude where the tile widths differ, at 50, 60, 70, 80 and 85 degrees). Missing tiles (open
    sea) are 0 m. Longitudes wrap at 180 degrees."""

    vertical = "egm2008"
    label = "Copernicus DEM GLO-30"

    def __init__(self, lat_min: float, lat_max: float, lon_min: float, lon_max: float) -> None:
        self.tiles: list[dict] = []
        self._raw: dict[tuple[int, int], np.ndarray] = {}
        self._ext: dict[tuple[int, int], np.ndarray] = {}
        for lat in range(int(np.floor(lat_max)), int(np.floor(lat_min)) - 1, -1):
            if not -90 <= lat < 90:
                continue
            for lon_c in range(int(np.floor(lon_min)), int(np.floor(lon_max)) + 1):
                lon = int(wrap_lon(lon_c))
                if (lat, lon) in self._raw:
                    continue
                name = dem_tile_name(lat, lon)
                path = fetch_dem_tile(name)
                width = dem_tile_width(lat)
                if path is None:
                    self._raw[(lat, lon)] = np.zeros((DEM_ROWS, width), np.float32)
                    self.tiles.append({"name": name, "missing": True})
                    continue
                with rasterio.open(path) as ds:
                    if (ds.width, ds.height) != (width, DEM_ROWS) or ds.tags().get("AREA_OR_POINT") != "Point":
                        raise ValueError(f"{name}: unexpected layout {ds.width}x{ds.height} (expected {width}x3600)")
                    self._raw[(lat, lon)] = ds.read(1).astype(np.float32)
                self.tiles.append({"name": name, "sha256": sha256_file(path)})

    def _extended(self, key: tuple[int, int]) -> np.ndarray:
        if key in self._ext:
            return self._ext[key]
        lat, lon = key
        east_key = (lat, int(wrap_lon(lon + 1)))
        a = self._raw[key]
        h, w = a.shape
        ext = np.empty((h + 1, w + 1), np.float32)
        ext[:h, :w] = a
        east = self._raw.get(east_key)
        ext[:h, w] = east[:, 0] if east is not None else a[:, -1]
        south = self._raw.get((lat - 1, lon))
        if south is not None:
            se = self._raw.get((lat - 1, east_key[1]))
            row = np.append(south[0], se[0, 0] if se is not None else south[0, -1])
            ws = south.shape[1]
            ext[h] = np.interp(np.arange(w + 1) / w, np.arange(ws + 1) / ws, row)
        else:  # outside the loaded box; only reached by points beyond the margin
            ext[h] = ext[h - 1]
        self._ext[key] = ext
        return ext

    def sample(self, lat: np.ndarray, lon: np.ndarray) -> np.ndarray:
        lat = np.asarray(lat, dtype=np.float64)
        lon = wrap_lon(lon)
        ti = np.floor(lat).astype(np.int64)
        tj = np.floor(lon).astype(np.int64)
        out = np.full(lat.shape, np.nan)
        keys = ti * 1000 + tj
        for k in np.unique(keys):
            m = keys == k
            key = (int(ti[m][0]), int(tj[m][0]))
            if key not in self._raw:
                continue
            ext = self._extended(key)
            w = ext.shape[1] - 1
            out[m] = bilinear(ext, (key[0] + 1 - lat[m]) * DEM_ROWS, (lon[m] - key[1]) * w)
        return out

    def describe(self) -> dict:
        return {"product": "Copernicus DEM GLO-30 (DSM)", "vertical_datum": "EGM2008",
                "access": "s3://copernicus-dem-30m", "tiles": self.tiles}


def load_dem(lat_min: float, lat_max: float, lon_min: float, lon_max: float) -> CopernicusDem:
    return CopernicusDem(lat_min, lat_max, lon_min, lon_max)


class ZeroDem:
    """Fallback: 0 m above the EGM2008 geoid (mean sea level)."""

    vertical = "egm2008"
    label = "zero (sea level)"

    def sample(self, lat, lon):
        return np.zeros(np.shape(lat))

    def describe(self) -> dict:
        return {"product": "constant 0 m above EGM2008 (fallback)"}


def _vertical_from_crs(crs: pyproj.CRS) -> str | None:
    """Vertical datum of a CRS, if it states one we can handle."""
    if crs.is_compound:
        for sub in crs.sub_crs_list:
            if sub.is_vertical:
                name = sub.name.upper().replace(" ", "")
                if "EGM2008" in name:
                    return "egm2008"
                if "EGM96" in name:
                    return "egm96"
                raise ValueError(f"vertical CRS '{sub.name}' is not supported; use --dem-vertical")
    if crs.is_geographic and len(crs.axis_info) == 3:  # e.g. EPSG:4979: heights above the ellipsoid
        return "ellipsoid"
    return None


@dataclass
class FileDem:
    """A user's elevation file (GeoTIFF or DTED), read only where it overlaps the area."""
    path: Path
    format: str
    vertical: str
    vertical_assumed: bool
    data: np.ndarray  # float32, NaN = no data
    crs: str
    note: str = ""
    _to_file: pyproj.Transformer | None = None
    _inv: object = None  # rasterio Affine (pixel corners) for GeoTIFF
    _cell: dted.DtedCell | None = None
    _lon_center: float = 0.0

    @property
    def label(self) -> str:
        return self.path.name

    def sample(self, lat: np.ndarray, lon: np.ndarray) -> np.ndarray:
        lat = np.asarray(lat, dtype=np.float64)
        lon = self._lon_center + wrap_lon(np.asarray(lon, dtype=np.float64) - self._lon_center)
        if self._cell is not None:
            return self._cell.sample(lat, lon).astype(np.float64)
        x, y = self._to_file.transform(lon, lat)
        c, r = self._inv @ (np.asarray(x), np.asarray(y))
        return bilinear_inside(self.data, np.asarray(r) - 0.5, np.asarray(c) - 0.5)  # centres at +0.5

    def describe(self) -> dict:
        return {"file": self.path.name, "format": self.format, "sha256": sha256_file(self.path), "crs": self.crs,
                "vertical_datum": self.vertical, "vertical_datum_assumed": self.vertical_assumed}


def _datum_or_default(flag: str, detected: str | None, default: str, what: str) -> tuple[str, bool]:
    if flag != "auto":
        return flag, False
    if detected:
        return detected, False
    log(f"  warning: {what} states no vertical datum; assuming {default} (set --dem-vertical if that is wrong)")
    return default, True


def open_dted(path: Path, bounds, vertical_flag: str) -> FileDem | None:
    cell = dted.read_dted(path)
    lat_min, lat_max, lon_min, lon_max = bounds
    lon_c = cell.lon0 + 0.5
    lo = float(lon_c + wrap_lon(lon_min - lon_c))
    top = cell.lat0 + (cell.nlat - 1) * cell.dlat
    right = cell.lon0 + (cell.nlon - 1) * cell.dlon
    if lat_max < cell.lat0 or lat_min > top or lo > right or lo + (lon_max - lon_min) < cell.lon0:
        return None
    # MIL-PRF-89020B: DTED heights are above mean sea level as defined by EGM96.
    detected = {"MSL": "egm96", "E96": "egm96", "E08": "egm2008", "WGE": "ellipsoid"}.get(cell.vertical_datum.upper())
    vertical, assumed = _datum_or_default(vertical_flag, detected, "egm96", path.name)
    if cell.horizontal_datum and cell.horizontal_datum.upper() not in ("WGS84", "WGS 84", "WGS-84"):
        raise ValueError(f"{path.name}: horizontal datum {cell.horizontal_datum} is not WGS84")
    return FileDem(path, cell.level or "DTED", vertical, assumed, cell.data, "WGS84 geographic (DTED)",
                   _cell=cell, _lon_center=lon_c)


def open_geotiff_dem(path: Path, bounds, vertical_flag: str) -> FileDem | None:
    with rasterio.open(path) as ds:
        crs = pyproj.CRS.from_wkt(ds.crs.to_wkt())
        horizontal = crs.sub_crs_list[0] if crs.is_compound else crs
        to_file = pyproj.Transformer.from_crs("EPSG:4326", horizontal, always_xy=True)
        lon_c = 0.0
        if horizontal.is_geographic:
            lon_c = (ds.bounds.left + ds.bounds.right) * 0.5
        lat, lon = bounds_outline(bounds)
        lon = lon_c + wrap_lon(lon - lon_c)
        x, y = to_file.transform(lon, lat)
        win = from_bounds(float(np.min(x)), float(np.min(y)), float(np.max(x)), float(np.max(y)), ds.transform)
        win = Window(int(np.floor(win.col_off)) - 2, int(np.floor(win.row_off)) - 2,
                     int(np.ceil(win.width)) + 5, int(np.ceil(win.height)) + 5)
        try:
            win = win.intersection(Window(0, 0, ds.width, ds.height))
        except rasterio.errors.WindowError:
            return None
        if win.width < 2 or win.height < 2:
            return None
        band = ds.read(1, window=win, masked=True)
        data = band.astype(np.float32).filled(np.nan)
        vertical, assumed = _datum_or_default(vertical_flag, _vertical_from_crs(crs), "egm2008", path.name)
        return FileDem(path, "GeoTIFF", vertical, assumed, data, horizontal.to_string(),
                       _to_file=to_file, _inv=~ds.window_transform(win), _lon_center=lon_c)


def find_dem_files(paths: list[str]) -> list[Path]:
    """Files in the given order; a directory adds its elevation files, best DTED level first."""
    level = {".dt2": 0, ".dt1": 1, ".dt0": 2}
    out: list[Path] = []
    for p in map(Path, paths):
        if p.is_dir():
            found = [f for f in p.rglob("*") if f.suffix.lower() in DEM_SUFFIXES and f.is_file()]
            out += sorted(found, key=lambda f: (level.get(f.suffix.lower(), 3), str(f).lower()))
        elif p.is_file():
            out.append(p)
        else:
            raise FileNotFoundError(f"--dem {p}: no such file or directory")
    if not out:
        raise FileNotFoundError(f"--dem {' '.join(paths)}: no {'/'.join(DEM_SUFFIXES)} files found")
    return out


def open_dem_sources(args: argparse.Namespace, bounds) -> list:
    if not args.dem:
        return [CopernicusDem(*bounds)]
    sources: list = []
    for path in find_dem_files(args.dem):
        is_dted = path.suffix.lower() in (".dt0", ".dt1", ".dt2")
        src = (open_dted if is_dted else open_geotiff_dem)(path, bounds, args.dem_vertical)
        if src is None:
            continue
        log(f"  {path.name}: {src.format}, {src.data.shape[1]}x{src.data.shape[0]} posts read, "
            f"vertical {src.vertical}{' (assumed)' if src.vertical_assumed else ''}")
        sources.append(src)
    if args.dem_fallback == "copernicus":
        sources.append(CopernicusDem(*bounds))
    elif args.dem_fallback == "zero":
        sources.append(ZeroDem())
    if not sources:
        raise RuntimeError("none of the --dem files overlaps the area")
    return sources


# --- geoid ------------------------------------------------------------------------------------------------------

def _grid_pipeline(path: Path) -> pyproj.Transformer:
    # Forward vgridshift with multiplier 1 adds the grid value: z = 0 -> N.
    return pyproj.Transformer.from_pipeline(
        "+proj=pipeline +step +proj=unitconvert +xy_in=deg +xy_out=rad "
        f"+step +proj=vgridshift +grids={path.resolve().as_posix()} +multiplier=1 "
        "+step +proj=unitconvert +xy_in=rad +xy_out=deg")


class Geoid:
    """Geoid height N (m) of EGM2008 (PROJ grid us_nga_egm08_25) or EGM96 (us_nga_egm96_15), both NGA, public domain.
    Looked up in this order: `grid_path`, tools/.cache/geoid/ (see --fetch-geoid), PROJ's data directories, and
    only then the PROJ CDN (not with --offline)."""

    def __init__(self, model: str = "egm2008", grid_path: str | Path | None = None) -> None:
        if model not in GEOIDS:
            raise ValueError(f"unknown geoid model {model}")
        self.model = model
        grid, target = GEOIDS[model]
        self.grid = grid
        self._sign = 1.0
        for p in ([Path(grid_path)] if grid_path else []) + [CACHE / "geoid" / grid]:
            if p.is_file():
                if p.name != grid:
                    raise ValueError(f"geoid grid for {model} must be {grid}, got {p.name}")
                self._t = _grid_pipeline(p)
                self.source = f"{grid} (local file)"
                return
            if grid_path and p == Path(grid_path):
                raise FileNotFoundError(f"--geoid-grid {p} does not exist")
        for net in (False, True):
            if net:
                network(f"PROJ CDN geoid grid {grid}")
            pyproj.network.set_network_enabled(net)
            with warnings.catch_warnings():  # "best transformation is not available" while trying without network
                warnings.simplefilter("ignore", UserWarning)
                group = pyproj.transformer.TransformerGroup("EPSG:4979", target, always_xy=True)
            # Without the grid PROJ would fall back to a "ballpark" no-op; insist on the NGA grid.
            chosen = [t for t in group.transformers if grid in t.definition]
            if chosen:
                self._t = chosen[0]
                self._sign = -1.0  # ellipsoidal 0 m -> orthometric -N
                self.source = f"{grid} (PROJ{' CDN' if net else ''})"
                return
        raise RuntimeError(f"PROJ grid {grid} unavailable")

    def height(self, lat, lon):
        lat = np.asarray(lat, dtype=np.float64)
        _, _, z = self._t.transform(np.asarray(lon, dtype=np.float64), lat, np.zeros_like(lat))
        n = self._sign * np.asarray(z)
        if not np.all(np.isfinite(n)):
            raise RuntimeError(f"geoid grid {self.grid} gave no value (no network and no cached grid?)")
        return n


def fetch_geoids() -> None:
    """Downloads both geoid grids into tools/.cache/geoid/ (copy that folder to an offline machine)."""
    for grid, _ in GEOIDS.values():
        path = CACHE / "geoid" / grid
        if path.exists():
            log(f"{path} exists")
            continue
        network(f"PROJ CDN geoid grid {grid}")
        path.parent.mkdir(parents=True, exist_ok=True)
        log(f"downloading {grid}")
        download(PROJ_CDN.format(f=grid), path)
        log(f"  {path} ({path.stat().st_size / 1e6:.1f} MB)")


# --- heights ----------------------------------------------------------------------------------------------------

class DemStack:
    """Elevation sources in priority order, giving ellipsoidal heights."""

    def __init__(self, sources: list, geoid_grid: str | None = None) -> None:
        self.sources = sources
        self.geoids: dict[str, Geoid] = {}
        for s in sources:
            if s.vertical != "ellipsoid" and s.vertical not in self.geoids:
                grid = geoid_grid if geoid_grid and Path(geoid_grid).name == GEOIDS[s.vertical][0] else None
                self.geoids[s.vertical] = Geoid(s.vertical, grid)
        self.used = np.zeros(len(sources), np.int64)

    def geoid_offsets(self, lat, lon) -> dict[str, np.ndarray]:
        out = {m: g.height(lat, lon) for m, g in self.geoids.items()}
        out["ellipsoid"] = np.zeros(np.shape(lat))
        return out

    def ellipsoidal(self, lat: np.ndarray, lon: np.ndarray, offsets: dict[str, np.ndarray],
                    count: bool = False) -> np.ndarray:
        out = np.full(np.shape(lat), np.nan)
        for i, s in enumerate(self.sources):
            need = np.isnan(out)
            if not need.any():
                break
            v = s.sample(lat[need], lon[need]) + offsets[s.vertical][need]
            out[need] = v
            if count:
                self.used[i] += int(np.isfinite(v).sum())
        return out


def solve_heights(grid: Grid, dem: DemStack, block_rows: int = 256) -> np.ndarray:
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
        offsets = dem.geoid_offsets(lat, lon)
        for i in range(8):
            lat, lon, h = enu_to_geodetic(e, n, u, grid.lat0, grid.lon0, grid.h0)
            du = dem.ellipsoidal(lat, lon, offsets, count=i == 0) - h
            if i == 0 and np.isnan(du).any():
                bad = np.argwhere(np.isnan(du))[0]
                frac = np.isnan(du).mean() * 100
                raise RuntimeError(
                    f"no elevation data for {frac:.2f} % of rows {r0}-{r1} (first at {float(lat[tuple(bad)]):.6f}, "
                    f"{float(lon[tuple(bad)]):.6f}); add files to --dem or use --dem-fallback copernicus|zero")
            du = np.nan_to_num(du)  # a sample nudged off the data edge by the iteration keeps its height
            u += du
            if np.abs(du).max() < 1e-4:
                break
        else:
            raise RuntimeError("height iteration did not converge")
        out[r0:r1] = u
        log(f"  rows {r1}/{grid.count}")
    return out


# --- colour -----------------------------------------------------------------------------------------------------

S2_COLLECTIONS = ("sentinel-2-l2a", "sentinel-2-c1-l2a")


def stac_search(bbox: list[float], year: int, max_cloud: float) -> list[dict]:
    """Scenes with a public COG true-colour asset intersecting `bbox`, from the first collection that has any: the
    original L2A collection (some of its items only point to requester-pays JPEG 2000 files), then Collection 1.
    A box crossing the antimeridian (lon beyond +-180) is searched as two boxes."""
    for collection in S2_COLLECTIONS:
        items = _stac_search(collection, bbox, year, max_cloud)
        public = [f for f in items if f["assets"].get("visual", {}).get("href", "").startswith("https://")]
        if len(public) < len(items):
            log(f"  {collection}: {len(items) - len(public)} scenes without a public COG skipped")
        if public:
            return public
    return []


def scene_tile(item: dict) -> str:
    """MGRS tile of a scene, e.g. 36TVK (ids differ between collections)."""
    p = item["properties"]
    if "mgrs:grid_square" in p:
        return f"{p['mgrs:utm_zone']}{p['mgrs:latitude_band']}{p['mgrs:grid_square']}"
    return item["id"].split("_")[1].lstrip("T0")


def _stac_search(collection: str, bbox: list[float], year: int, max_cloud: float) -> list[dict]:
    lon_min, lat_min, lon_max, lat_max = bbox
    if lon_max - lon_min >= 360.0:
        boxes = [[-180.0, lat_min, 180.0, lat_max]]
    elif lon_min < -180.0 or lon_max > 180.0:
        a, b = float(wrap_lon(lon_min)), float(wrap_lon(lon_max))
        boxes = [[a, lat_min, 180.0, lat_max], [-180.0, lat_min, b, lat_max]]
    else:
        boxes = [bbox]
    found: dict[str, dict] = {}
    for box in boxes:
        network("Earth Search STAC (Sentinel-2)")
        body = {
            "collections": [collection],
            "bbox": box,
            "datetime": f"{year}-06-01T00:00:00Z/{year}-08-31T23:59:59Z",
            "query": {"eo:cloud_cover": {"lt": max_cloud}},
            "limit": 200,
        }
        req = urllib.request.Request(STAC_SEARCH, data=json.dumps(body).encode(),
                                     headers={"Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=HTTP_TIMEOUT) as r:
            for f in json.load(r)["features"]:
                found.setdefault(f["id"], f)
    return list(found.values())


def stac_item(scene_id: str) -> dict:
    network("Earth Search STAC (Sentinel-2)")
    collection = S2_COLLECTIONS[1] if scene_id.split("_")[1].startswith("T") else S2_COLLECTIONS[0]
    url = f"https://earth-search.aws.element84.com/v1/collections/{collection}/items/{scene_id}"
    with urllib.request.urlopen(url, timeout=HTTP_TIMEOUT) as r:
        return json.load(r)


def read_scene_window(href: str, scene_id: str, lat: np.ndarray, lon: np.ndarray):
    """Reads (and caches) the part of the TCI COG covering the given points.
    Returns (uint8 array [3, h, w], window transform, x, y) with x/y the points in the scene CRS."""
    with rasterio.Env(GDAL_DISABLE_READDIR_ON_OPEN="EMPTY_DIR", CPL_VSIL_CURL_ALLOWED_EXTENSIONS=".tif"):
        cached = sorted((CACHE / "s2").glob(f"{scene_id}_*.npy"))
        if OFFLINE and not cached:
            network(f"Sentinel-2 scene {scene_id}")
        if not OFFLINE:
            network(f"Sentinel-2 scene {scene_id} (header)")
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
    """Fraction of `area` (lon_min, lat_min, lon_max, lat_max) inside the scene's footprint box. Longitudes of the
    scene are moved by 360 degrees to lie next to the area's (antimeridian)."""
    width = (scene[2] - scene[0]) % 360.0 or 360.0
    centre = (area[0] + area[2]) * 0.5
    s0 = float(centre + wrap_lon(scene[0] - centre))
    if s0 > area[0] and s0 - 360.0 + width > area[0]:  # box starting west of the area across the seam
        s0 -= 360.0
    w = min(s0 + width, area[2]) - max(s0, area[0])
    h = min(scene[3], area[3]) - max(scene[1], area[1])
    if w <= 0 or h <= 0:
        return 0.0
    return (w * h) / ((area[2] - area[0]) * (area[3] - area[1]))


def sample_rgb(data: np.ndarray, transform, x: np.ndarray, y: np.ndarray, nodata: np.ndarray, take: np.ndarray,
               color: np.ndarray) -> np.ndarray:
    """Bilinear colour of `data` ([3, h, w] floats 0-255) at points x/y (in the raster CRS) into color[take & valid].
    A point is valid when it lies inside and its four neighbours hold data. Returns the mask of points written."""
    c, r = ~transform @ (x, y)
    r = np.asarray(r) - 0.5  # raster coordinates address pixel corners; centres sit at +0.5
    c = np.asarray(c) - 0.5
    inside = (r >= 0) & (c >= 0) & (r <= data.shape[1] - 1) & (c <= data.shape[2] - 1)
    r0 = np.clip(np.floor(r).astype(np.int64), 0, data.shape[1] - 2)
    c0 = np.clip(np.floor(c).astype(np.int64), 0, data.shape[2] - 2)
    valid = inside & ~(nodata[r0, c0] | nodata[r0 + 1, c0] | nodata[r0, c0 + 1] | nodata[r0 + 1, c0 + 1])
    put = valid & take
    if put.any():
        for k in range(3):
            band = bilinear(data[k], r[put], c[put])
            color[..., k][put] = np.clip(band + 0.5, 0, 255).astype(np.uint8)
    return put


MAX_SCENE_READS = 12


def sample_lat_lon(grid: Grid) -> tuple[np.ndarray, np.ndarray]:
    """Latitude / longitude of the terrain surface point of every grid sample (geo_layers.set_surface)."""
    e, n = grid.rows(0, grid.count)
    lat, lon, _ = enu_to_geodetic(e, n, geo_layers.surface_up(e, n), grid.lat0, grid.lon0, grid.h0)
    return lat, grid.lon0 + wrap_lon(lon - grid.lon0)


def build_color(grid: Grid, year: int, max_cloud: float, scene_ids: list[str] | None) -> tuple[np.ndarray, list[dict]]:
    """Colour of every grid sample from Sentinel-2 L2A true-colour (TCI) images. Scenes are taken clearest first
    until every sample is covered (TCI value 0 = no data)."""
    lat, lon = sample_lat_lon(grid)
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
        tile = scene_tile(item)
        if tile in exhausted:
            continue
        if reads >= MAX_SCENE_READS:
            break
        reads += 1
        data, transform, x, y = read_scene_window(item["assets"]["visual"]["href"], item["id"], lat, wrap_lon(lon))
        take = sample_rgb(data.astype(np.float32), transform, x, y, data.sum(axis=0) == 0, ~filled, color)
        if take.any():
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


def build_color_files(grid: Grid, paths: list[str], value_range: tuple[float, float] | None
                      ) -> tuple[np.ndarray, list[dict]]:
    """Colour from the user's GeoTIFFs (RGB or RGBA, or one grey band), first file first. uint8 is taken as is;
    other types are stretched linearly from `value_range` or from the 2nd-98th percentile of the area."""
    lat, lon = sample_lat_lon(grid)
    bounds = grid_bounds(grid)
    color = np.zeros((grid.count, grid.count, 3), np.uint8)
    filled = np.zeros((grid.count, grid.count), bool)
    used = []
    for path in map(Path, paths):
        if not path.is_file():
            raise FileNotFoundError(f"--imagery {path}: no such file")
        with rasterio.open(path) as ds:
            crs = pyproj.CRS.from_wkt(ds.crs.to_wkt())
            to_file = pyproj.Transformer.from_crs("EPSG:4326", crs, always_xy=True)
            lon_c = (ds.bounds.left + ds.bounds.right) * 0.5 if crs.is_geographic else 0.0
            blat, blon = bounds_outline(bounds)
            bx, by = to_file.transform(lon_c + wrap_lon(blon - lon_c), blat)
            win = from_bounds(float(np.min(bx)), float(np.min(by)), float(np.max(bx)), float(np.max(by)),
                              ds.transform)
            win = Window(int(np.floor(win.col_off)) - 2, int(np.floor(win.row_off)) - 2,
                         int(np.ceil(win.width)) + 5, int(np.ceil(win.height)) + 5)
            try:
                win = win.intersection(Window(0, 0, ds.width, ds.height))
            except rasterio.errors.WindowError:
                log(f"  {path.name}: outside the area, skipped")
                continue
            bands = [1, 2, 3] if ds.count >= 3 else [1, 1, 1]
            data = ds.read(bands, window=win).astype(np.float32)
            mask = ds.read_masks(1, window=win) == 0  # GDAL mask: nodata, alpha band or internal mask
            if ds.dtypes[0] != "uint8":
                lo, hi = value_range or tuple(np.percentile(data[:, ~mask], [2, 98])) if (~mask).any() else (0, 1)
                log(f"  {path.name}: {ds.dtypes[0]} stretched from {lo:g} .. {hi:g} to 0 .. 255")
                data = (data - lo) * (255.0 / max(hi - lo, 1e-9))
            x, y = to_file.transform(lon_c + wrap_lon(lon - lon_c), lat)
            take = sample_rgb(data, ds.window_transform(win), np.asarray(x), np.asarray(y), mask, ~filled, color)
        filled |= take
        used.append({"file": path.name, "sha256": sha256_file(path), "crs": crs.to_string(),
                     "coverage": float(take.mean())})
        log(f"  {path.name}: {take.mean() * 100:.1f} % of samples")
        if filled.all():
            break
    if not filled.all():
        log(f"  warning: {(~filled).mean() * 100:.2f} % of samples without colour (left black)")
    return color, used


HYPSOMETRIC = np.array([  # (fraction of the height range, RGB)
    (0.00, 70, 110, 60), (0.25, 120, 150, 80), (0.50, 185, 170, 110), (0.75, 160, 120, 85), (1.00, 235, 230, 225),
], np.float64)


def hillshade_color(grid: Grid, height: np.ndarray, color_grid: Grid) -> np.ndarray:
    """Offline colour: hypsometric tint (2nd-98th percentile of the area) times a hillshade lit from the north-west,
    computed from the height grid. Earth curvature is removed first so the tint follows elevation."""
    if color_grid.count != grid.count:
        t = (color_grid.east() + grid.half) / grid.spacing
        cc, rr = np.meshgrid(t, t)
        height = bilinear(height.astype(np.float64), rr, cc)
    sp = color_grid.spacing
    e, n = color_grid.rows(0, color_grid.count)
    elev = height + (e * e + n * n) / (2 * EARTH_RADIUS)
    dz_dsouth, dz_deast = np.gradient(elev, sp)
    normal = np.stack([-dz_deast, dz_dsouth, np.ones_like(elev)])  # east, north, up
    normal /= np.linalg.norm(normal, axis=0)
    az, alt = np.radians(315.0), np.radians(45.0)
    light = np.array([np.sin(az) * np.cos(alt), np.cos(az) * np.cos(alt), np.sin(alt)])
    shade = np.clip(np.tensordot(light, normal, axes=1), 0.0, 1.0)
    lo, hi = np.percentile(elev, [2, 98])
    f = np.clip((elev - lo) / max(hi - lo, 1.0), 0.0, 1.0)
    rgb = np.stack([np.interp(f, HYPSOMETRIC[:, 0], HYPSOMETRIC[:, k]) for k in (1, 2, 3)], axis=-1)
    rgb *= (0.35 + 0.65 * shade)[..., None] / (0.35 + 0.65 * np.sin(alt))
    return np.clip(rgb + 0.5, 0, 255).astype(np.uint8)


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
        out[name] = {"east": e, "north": n, "latitude": float(lat), "longitude": float(wrap_lon(lon))}
    return out


@dataclass
class Sources:
    """What went into a package, for terrain.json."""
    elevation: dict
    geoids: list[dict]
    imagery: dict
    attribution: list[str] = field(default_factory=list)
    disclaimer: str = ""
    # "dsm": the DEM as it is (roofs and crowns included); "dtm-approx": buildings and part of the canopy removed
    surface: str = "dsm"
    ground_model: dict | None = None


def write_package(out: Path, grid: Grid, color_grid: Grid, height: np.ndarray, color: np.ndarray,
                  sources: Sources, extra: list | None = None) -> dict:
    """`extra`: optional layers (layers.Layer), written as 8-bit PNGs and listed under their own keys."""
    out.mkdir(parents=True, exist_ok=True)
    write_exr(out / "height.exr", height)
    Image.fromarray(color).save(out / "color.png")
    for layer in extra or []:
        if layer.data is not None:
            (out / layer.file).write_bytes(layer.data)
        else:
            Image.fromarray(layer.image, mode="L").save(out / layer.file)
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
            "reference": "ENU up relative to the origin; geoid and Earth curvature included",
            "interpolation": "bilinear between samples",
            "surface": sources.surface,
            "sha256": sha256_file(out / "height.exr"),
        } | ({"ground_model": sources.ground_model} if sources.ground_model else {}),
        "color": {
            "file": "color.png", "encoding": f"PNG RGB8, sRGB ({sources.imagery['product']})",
            "samples": color_grid.count, "spacing_m": color_grid.spacing,
            "sha256": sha256_file(out / "color.png"),
        },
        "corners": corner_coordinates(grid),
        "sources": {
            "elevation": sources.elevation,
            "geoid": sources.geoids[0] if sources.geoids else {"model": "none (ellipsoidal heights)"},
            "geoids": sources.geoids,
            "imagery": sources.imagery,
        },
        "attribution": sources.attribution,
        "disclaimer": sources.disclaimer,
    }
    for layer in extra or []:
        meta[layer.key] = {"file": layer.file} | layer.meta | {"sha256": sha256_file(out / layer.file)}
    (out / "terrain.json").write_text(json.dumps(meta, indent=2, ensure_ascii=False) + "\n", encoding="utf-8",
                                      newline="\n")
    gdignore = out.parent / ".gdignore"  # keep the Godot editor from importing big package files under res://
    if out.parent.name == "terrain" and not gdignore.exists():
        gdignore.touch()
    return meta


def build(args: argparse.Namespace) -> dict:
    global OFFLINE
    OFFLINE = args.offline
    geo_layers.set_surface(None, None)
    NETWORK_USED.clear()
    grid = Grid(args.lat, args.lon, args.origin_height, args.size, args.spacing)
    color_grid = Grid(args.lat, args.lon, args.origin_height, args.size, args.color_spacing or args.spacing)
    log(f"height grid {grid.count}x{grid.count} @ {grid.spacing} m, colour {color_grid.count}x{color_grid.count} "
        f"@ {color_grid.spacing} m")
    t0 = time.time()
    log("elevation:")
    dem = DemStack(open_dem_sources(args, grid_bounds(grid, margin_deg=0.01)), args.geoid_grid)
    height = solve_heights(grid, dem)
    geo_layers.set_surface(grid, height)  # imagery and layers are sampled at the surface points
    corners = corner_coordinates(grid)
    clat = np.array([c["latitude"] for c in corners.values()] + [grid.lat0])
    clon = np.array([c["longitude"] for c in corners.values()] + [grid.lon0])
    geoids = []
    for model, g in dem.geoids.items():
        n_vals = g.height(clat, clon)
        geoids.append({"model": model.upper(), "grid": f"PROJ {g.grid} (NGA, public domain)",
                       "n_min_m": float(n_vals.min()), "n_max_m": float(n_vals.max())})
    total = grid.count * grid.count
    used = [s for s, k in zip(dem.sources, dem.used) if k > 0]
    for s, k in zip(dem.sources, dem.used):
        log(f"  {s.label}: {k / total * 100:.1f} % of samples")
    attribution: list[str] = []
    disclaimer = ""
    if args.dem:
        elevation = {"product": "user data", "files": [s.describe() | {"coverage": k / total}
                                                         for s, k in zip(dem.sources, dem.used)
                                                         if isinstance(s, FileDem)]}
        fallback = [s for s in used if not isinstance(s, FileDem)]
        if fallback:
            elevation["fallback"] = fallback[0].describe() | {"coverage": float(dem.used[-1]) / total}
    else:
        elevation = dem.sources[0].describe()
    if any(isinstance(s, CopernicusDem) for s in used):
        attribution.append(DEM_ATTRIBUTION)
        disclaimer = DEM_DISCLAIMER
    log("colour:")
    if args.imagery == ["hillshade"]:
        color = hillshade_color(grid, height, color_grid)
        imagery = {"product": "hillshade computed from the heights"}
    elif args.imagery:
        color, files = build_color_files(color_grid, args.imagery, tuple(args.imagery_range) if args.imagery_range
                                         else None)
        imagery = {"product": "user imagery", "files": files}
    else:
        color, scenes = build_color(color_grid, args.year, args.max_cloud, args.scene)
        imagery = {"product": "Sentinel-2 L2A true colour (TCI)",
                   "access": "Earth Search STAC (earth-search.aws.element84.com/v1)", "scenes": scenes}
        years = sorted({s["datetime"][:4] for s in scenes})
        attribution.append(f"Contains modified Copernicus Sentinel data {', '.join(years)}")
    extra = []
    surface, ground_model = "dsm", None
    if args.layers:
        geo_layers.use_osm_pbf(args.osm_pbf, CACHE, log)
        layer_grids = {"water": Grid(args.lat, args.lon, args.origin_height, args.size,
                                     args.water_spacing or color_grid.spacing),
                       "landcover": color_grid, "canopy": color_grid}
        raster = [x for x in args.layers if x not in ("buildings", "roads")]
        extra = geo_layers.build_layers(raster, layer_grids.__getitem__, grid_bounds(grid),
                                        args.overture_release, CACHE, network, log, sha256_file)
        if "buildings" in args.layers:
            log("buildings:")
            canopy = next((x for x in extra if x.key == "canopy"), None)
            water = next((x for x in extra if x.key == "water"), None)
            height, blayer, ground_stats = geo_buildings.build_buildings(
                grid, height, canopy, grid_bounds(grid), args.overture_release, CACHE, network, log, sha256_file,
                water)
            extra += blayer
            surface, ground_model = "dtm-approx", {
                "method": "DEM filled in under building footprints from the surrounding samples, lowered by half "
                          "the canopy height under trees, never above the DEM (tools/buildings.py)"} | ground_stats
        if "roads" in args.layers:
            log("roads:")
            water = next((x for x in extra if x.key == "water"), None)
            extra.append(geo_roads.build_roads(grid, height, water, grid_bounds(grid), args.overture_release, CACHE,
                                               network, log, sha256_file))
        for layer in extra:
            attribution += [a for a in layer.attribution if a not in attribution]
    attribution += args.attribution or []
    if (args.dem or args.imagery not in (None, ["hillshade"])) and not args.attribution:
        log("  note: no --attribution given; add the notice your data's licence requires")
    meta = write_package(Path(args.out), grid, color_grid, height, color,
                         Sources(elevation, geoids, imagery, attribution, disclaimer, surface, ground_model), extra)
    log(f"done in {time.time() - t0:.0f} s: {args.out} (heights {meta['height']['min']:.1f} .. "
        f"{meta['height']['max']:.1f} m)")
    if NETWORK_USED:
        log(f"network used for: {', '.join(sorted(set(NETWORK_USED)))}")
    else:
        log("no network access")
    return meta


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--fetch-geoid", action="store_true",
                    help="download the EGM2008 and EGM96 geoid grids into tools/.cache/geoid/ and exit")
    ap.add_argument("--lat", type=float, help="origin latitude (deg)")
    ap.add_argument("--lon", type=float, help="origin longitude (deg)")
    ap.add_argument("--origin-height", type=float, default=0.0,
                    help="origin ellipsoidal height (m); heights are relative to it (default 0)")
    ap.add_argument("--size", type=float, help="edge length of the square area (m)")
    ap.add_argument("--spacing", type=float, default=10.0, help="height sample spacing (m)")
    ap.add_argument("--color-spacing", type=float, default=None, help="colour sample spacing (m, default = spacing)")
    ap.add_argument("--out", help="output package directory")
    g = ap.add_argument_group("elevation (default: Copernicus DEM GLO-30, downloaded)")
    g.add_argument("--dem", action="append", metavar="PATH",
                   help="DTED (.dt0/.dt1/.dt2) or GeoTIFF file, or a directory of them; repeatable, first wins")
    g.add_argument("--dem-vertical", choices=("auto",) + VERTICAL_DATUMS, default="auto",
                   help="vertical datum of the --dem files (auto: DTED = EGM96, GeoTIFF = from its CRS, else EGM2008)")
    g.add_argument("--dem-fallback", choices=("none", "copernicus", "zero"), default="none",
                   help="where --dem files leave gaps: fail (default), Copernicus DEM, or 0 m")
    g.add_argument("--geoid-grid", metavar="FILE", help="local us_nga_egm08_25.tif or us_nga_egm96_15.tif")
    g = ap.add_argument_group("colour (default: Sentinel-2 L2A, downloaded)")
    g.add_argument("--imagery", action="append", metavar="PATH",
                   help="GeoTIFF (RGB/RGBA/grey, any CRS; repeatable, first wins), or 'hillshade'")
    g.add_argument("--imagery-range", type=float, nargs=2, metavar=("LO", "HI"),
                   help="value range mapped to 0..255 for non-uint8 imagery (default: 2nd-98th percentile)")
    g.add_argument("--year", type=int, default=2025, help="summer (Jun-Aug) to take Sentinel-2 scenes from")
    g.add_argument("--max-cloud", type=float, default=5.0, help="maximum scene cloud cover (%%)")
    g.add_argument("--scene", action="append", help="use this Sentinel-2 scene id (repeatable) instead of searching")
    g = ap.add_argument_group("layers (optional; vector data from Overture Maps, downloaded once and cached)")
    g.add_argument("--layers", type=lambda v: [x for x in v.split(",") if x], default=[],
                   help=f"comma-separated: {', '.join(geo_layers.LAYERS)}")
    g.add_argument("--water-spacing", type=float, default=None,
                   help="spacing of the water mask (m, default = colour spacing); finer gives a sharper shoreline")
    g.add_argument("--overture-release", default=geo_layers.OVERTURE_RELEASE,
                   help=f"Overture Maps release to read (default {geo_layers.OVERTURE_RELEASE})")
    g.add_argument("--osm-pbf", metavar="FILE",
                   help="take water, buildings, roads and bridges from this OpenStreetMap extract (.osm.pbf, e.g. "
                        "from Geofabrik) instead of Overture Maps; read offline with pyosmium, cached")
    ap.add_argument("--attribution", action="append", metavar="TEXT",
                    help="notice required by your data's licence (repeatable); stored in terrain.json")
    ap.add_argument("--offline", action="store_true", help="fail instead of using the network (cached data is fine)")
    args = ap.parse_args(argv)
    if args.fetch_geoid:
        return args
    missing = [f"--{k}" for k in ("lat", "lon", "size", "out") if getattr(args, k) is None]
    if missing:
        ap.error(f"the following arguments are required: {', '.join(missing)}")
    unknown = [x for x in args.layers if x not in geo_layers.LAYERS]
    if unknown:
        ap.error(f"unknown layer(s) {', '.join(unknown)}; choose from {', '.join(geo_layers.LAYERS)}")
    if args.imagery and "hillshade" in args.imagery and len(args.imagery) > 1:
        ap.error("--imagery hillshade cannot be combined with files")
    return args


if __name__ == "__main__":
    a = parse_args()
    try:
        if a.fetch_geoid:
            fetch_geoids()
        else:
            build(a)
    except (OfflineError, RuntimeError, FileNotFoundError, ValueError) as err:
        print(f"error: {err}", file=sys.stderr)
        sys.exit(1)
    sys.exit(0)
