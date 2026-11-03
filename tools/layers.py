"""Optional package layers for tools/build_terrain.py (`--layers`): rasters derived from open vector data, on the
package's ENU grid. Each layer returns a `Layer` (key in terrain.json, file name, uint8 image, metadata).

Vector data comes from Overture Maps GeoParquet on its public S3 bucket (anonymous, no account), read with pyarrow
with a bounding-box filter so only the row groups of the area are fetched. The rows read are cached in
tools/.cache/overture/<release>/ so a rebuild, or --offline, needs no network.

water   Overture base/water polygons (from OpenStreetMap: coastline-derived ocean, lakes, rivers, reservoirs),
        rasterised with 4x4 supersampling into a coverage mask (255 = water). Licence of the result: ODbL 1.0.
"""
from __future__ import annotations

import hashlib
from dataclasses import dataclass, field
from pathlib import Path

import numpy as np
import pymap3d
import shapely
from rasterio.features import rasterize
from rasterio.transform import Affine

OVERTURE_RELEASE = "2026-10-21.0"
OVERTURE_BUCKET = "overturemaps-us-west-2"
OVERTURE_REGION = "us-west-2"
OSM_ATTRIBUTION = ("© OpenStreetMap contributors, Overture Maps Foundation "
                   "(ODbL 1.0, https://www.openstreetmap.org/copyright)")

# Polygon subtypes of base/water drawn as water. Left out: human_made (swimming pools, fountains: they sit on roofs
# and courtyards, not on the terrain surface) and physical (named sea / strait areas, not shorelines).
WATER_SUBTYPES = ("ocean", "lake", "pond", "reservoir", "river", "water", "canal", "stream")
SUPERSAMPLE = 4
LAYERS = ("water", "landcover", "canopy", "buildings", "roads")

WGS84 = pymap3d.Ellipsoid.from_name("wgs84")

# ENU up of the terrain surface, set by build_terrain.py once the heights are solved. A package sample at (e, n)
# is the surface point (e, n, u), whose latitude / longitude differ from those of (e, n, 0) by about u * d / R
# (metres on high ground far from the origin), so rasters are sampled and vectors projected at the surface.
_surface = None  # (grid, heights) or None


def set_surface(grid, heights) -> None:
    global _surface
    _surface = (grid, heights) if heights is not None else None


def surface_up(e: np.ndarray, n: np.ndarray) -> np.ndarray:
    """ENU up of the surface at east / north (bilinear on the height grid; 0 without one or outside)."""
    if _surface is None:
        return np.zeros(np.shape(e))
    grid, h = _surface
    c = np.clip((np.asarray(e, dtype=np.float64) + grid.half) / grid.spacing, 0.0, grid.count - 1.0)
    r = np.clip((grid.half - np.asarray(n, dtype=np.float64)) / grid.spacing, 0.0, grid.count - 1.0)
    c0 = np.minimum(np.floor(c).astype(np.int64), grid.count - 2)
    r0 = np.minimum(np.floor(r).astype(np.int64), grid.count - 2)
    fc, fr = c - c0, r - r0
    a = h[r0, c0] * (1 - fc) + h[r0, c0 + 1] * fc
    b = h[r0 + 1, c0] * (1 - fc) + h[r0 + 1, c0 + 1] * fc
    return np.nan_to_num(a * (1 - fr) + b * fr)


@dataclass
class Layer:
    key: str
    file: str
    image: np.ndarray | None  # uint8, rows = north to south; None for a binary layer
    meta: dict
    attribution: list[str] = field(default_factory=list)
    data: bytes | None = None  # file content of a binary layer


# --- Overture ---------------------------------------------------------------------------------------------------

def _boxes(bounds: tuple[float, float, float, float]) -> list[tuple[float, float, float, float]]:
    """(lon_min, lat_min, lon_max, lat_max) boxes in [-180, 180), split at the antimeridian."""
    lat_min, lat_max, lon_min, lon_max = bounds
    if lon_min < -180.0:
        return [(lon_min + 360.0, lat_min, 180.0, lat_max), (-180.0, lat_min, lon_max, lat_max)]
    if lon_max > 180.0:
        return [(lon_min, lat_min, 180.0, lat_max), (-180.0, lat_min, lon_max - 360.0, lat_max)]
    return [(lon_min, lat_min, lon_max, lat_max)]


def overture_table(theme: str, kind: str, bounds, columns: list[str], release: str, cache: Path, network, log):
    """Rows of Overture `theme/type=kind` whose bbox meets `bounds` (lat_min, lat_max, lon_min, lon_max).
    Returns (pyarrow.Table, cache file)."""
    import pyarrow as pa
    import pyarrow.parquet as pq

    key = f"{release}|{theme}|{kind}|{','.join(f'{b:.6f}' for b in bounds)}|{','.join(columns)}"
    path = cache / "overture" / release / f"{theme}-{kind}-{hashlib.sha256(key.encode()).hexdigest()[:16]}.parquet"
    if path.exists():
        return pq.read_table(path), path
    network(f"Overture {release} {theme}/{kind}")
    import pyarrow.compute as pc
    import pyarrow.dataset as ds
    import pyarrow.fs as pafs

    fs = pafs.S3FileSystem(anonymous=True, region=OVERTURE_REGION)
    data = ds.dataset(f"{OVERTURE_BUCKET}/release/{release}/theme={theme}/type={kind}/", filesystem=fs,
                      format="parquet")
    tables = []
    for x0, y0, x1, y1 in _boxes(bounds):
        log(f"  reading Overture {theme}/{kind} {x0:.3f}..{x1:.3f} E, {y0:.3f}..{y1:.3f} N")
        f = ((pc.field("bbox", "xmin") < x1) & (pc.field("bbox", "xmax") > x0)
             & (pc.field("bbox", "ymin") < y1) & (pc.field("bbox", "ymax") > y0))
        tables.append(data.to_table(columns=columns, filter=f))
    table = pa.concat_tables(tables)
    path.parent.mkdir(parents=True, exist_ok=True)
    part = path.with_suffix(".part")
    pq.write_table(table, part)
    part.replace(path)
    return table, path


# --- rasterising onto the package grid --------------------------------------------------------------------------

def to_enu(geoms: np.ndarray, grid) -> np.ndarray:
    """Lon/lat geometries -> ENU east / north of the points on the terrain surface (see set_surface): projected at
    h = 0 first, then again at the surface's ellipsoidal height there."""
    def fn(xy: np.ndarray) -> np.ndarray:
        lon = grid.lon0 + ((xy[:, 0] - grid.lon0 + 180.0) % 360.0 - 180.0)
        lat = xy[:, 1]
        e, n, _ = pymap3d.geodetic2enu(lat, lon, np.zeros(len(xy)), grid.lat0, grid.lon0, grid.h0, WGS84)
        if _surface is not None:
            _, _, h = pymap3d.enu2geodetic(e, n, surface_up(e, n), grid.lat0, grid.lon0, grid.h0, WGS84)
            e, n, _ = pymap3d.geodetic2enu(lat, lon, h, grid.lat0, grid.lon0, grid.h0, WGS84)
        return np.column_stack([e, n])
    return shapely.transform(geoms, fn)


def coverage(geoms, grid, band_rows: int = 256) -> np.ndarray:
    """Share of each grid cell (a spacing-wide square centred on the sample) covered by the ENU polygons, 0..255."""
    n = grid.count
    s = SUPERSAMPLE
    step = grid.spacing / s
    x0 = -grid.half - grid.spacing / 2
    y0 = grid.half + grid.spacing / 2
    out = np.zeros((n, n), np.uint8)
    shapes = [(g, 1) for g in geoms if not g.is_empty]
    if not shapes:
        return out
    for r0 in range(0, n, band_rows):
        r1 = min(n, r0 + band_rows)
        t = Affine(step, 0.0, x0, 0.0, -step, y0 - r0 * grid.spacing)
        sub = rasterize(shapes, out_shape=((r1 - r0) * s, n * s), transform=t, fill=0, dtype="uint8")
        out[r0:r1] = np.round(sub.reshape(r1 - r0, s, n, s).mean(axis=(1, 3)) * 255.0).astype(np.uint8)
    return out


def _clip(geoms: np.ndarray, grid) -> np.ndarray:
    m = grid.half + grid.spacing
    return shapely.clip_by_rect(geoms, -m, -m, m, m)


# --- global rasters (3 x 3 degree COG tiles, read by window over HTTP range requests) ---------------------------

WORLDCOVER_URL = ("https://esa-worldcover.s3.eu-central-1.amazonaws.com/v200/2021/map/"
                  "ESA_WorldCover_10m_2021_v200_{tile}_Map.tif")
WORLDCOVER_ATTRIBUTION = ("© ESA WorldCover project 2021 / Contains modified Copernicus Sentinel data (2021) "
                          "processed by ESA WorldCover consortium (CC BY 4.0)")
CANOPY_URL = ("https://libdrive.ethz.ch/index.php/s/cO8or7iOe5dT2Rt/download?path=%2F3deg_cogs&files="
              "ETH_GlobalCanopyHeight_10m_2020_{tile}_Map.tif")
CANOPY_ATTRIBUTION = ("Canopy height: Lang, N., Jetz, W., Schindler, K., Wegner, J. D. (2023), A high-resolution "
                      "canopy height model of the Earth, Nature Ecology & Evolution; ETH Global Canopy Height 2020, "
                      "doi:10.3929/ethz-b-000609802 (CC BY 4.0)")
# WorldCover classes (value: name); 0 = no data.
WORLDCOVER_CLASSES = {10: "tree cover", 20: "shrubland", 30: "grassland", 40: "cropland", 50: "built-up",
                      60: "bare / sparse vegetation", 70: "snow and ice", 80: "permanent water bodies",
                      90: "herbaceous wetland", 95: "mangroves", 100: "moss and lichen"}


def tile3(lat: float, lon: float) -> str:
    """Name of the 3 x 3 degree tile (south-west corner) containing the point, e.g. N39E027."""
    la = int(np.floor(lat / 3.0)) * 3
    lo = int(np.floor(lon / 3.0)) * 3
    return f"{'N' if la >= 0 else 'S'}{abs(la):02d}{'E' if lo >= 0 else 'W'}{abs(lo):03d}"


def _grid_lat_lon(grid, r0: int, r1: int) -> tuple[np.ndarray, np.ndarray]:
    """Latitude / longitude of the surface points of grid rows [r0, r1)."""
    e = np.broadcast_to(grid.east()[None, :], (r1 - r0, grid.count))
    n = np.broadcast_to(grid.north()[r0:r1, None], (r1 - r0, grid.count))
    lat, lon, _ = pymap3d.enu2geodetic(e, n, surface_up(e, n), grid.lat0, grid.lon0, grid.h0, WGS84)
    return lat, (lon + 180.0) % 360.0 - 180.0


def _http_status(url: str) -> int:
    import urllib.error
    import urllib.request
    try:
        with urllib.request.urlopen(urllib.request.Request(url, method="HEAD"), timeout=60) as r:
            return r.status
    except urllib.error.HTTPError as err:
        return err.code


def read_tile_window(url: str, name: str, bounds, cache: Path, network, log):
    """Window of a lon/lat COG covering bounds (lat_min, lat_max, lon_min, lon_max), cached as .npz.
    Returns (2-D array, rasterio Affine) or None if the tile does not exist."""
    import rasterio
    from rasterio.windows import from_bounds

    lat_min, lat_max, lon_min, lon_max = bounds
    key = hashlib.sha256(f"{url}|{lat_min:.6f},{lat_max:.6f},{lon_min:.6f},{lon_max:.6f}".encode()).hexdigest()[:16]
    path = cache / "rasters" / f"{name}-{key}.npz"
    if path.exists():
        z = np.load(path)
        return z["data"], Affine(*z["transform"])
    network(f"{name}")
    env = dict(GDAL_DISABLE_READDIR_ON_OPEN="EMPTY_DIR", GDAL_HTTP_MAX_RETRY="3", GDAL_HTTP_RETRY_DELAY="2")
    with rasterio.Env(**env):
        try:
            ds = rasterio.open(url)
        except rasterio.errors.RasterioIOError:
            if _http_status(url) in (403, 404):  # no tile there (open sea)
                return None
            raise
        with ds:
            win = from_bounds(lon_min, lat_min, lon_max, lat_max, transform=ds.transform)
            win = win.round_offsets().round_lengths()
            log(f"  reading {name} window {int(win.width)}x{int(win.height)}")
            data = ds.read(1, window=win, boundless=True, fill_value=ds.nodata or 0)
            transform = ds.window_transform(win)
    path.parent.mkdir(parents=True, exist_ok=True)
    np.savez_compressed(path, data=data, transform=np.array(transform)[:6])
    return data, transform


def sample_tiles_nearest(grid, url_fmt: str, label: str, bounds, cache: Path, network, log, fill: int = 0,
                         band_rows: int = 512) -> tuple[np.ndarray, list[str]]:
    """Nearest-neighbour sample of a 3-degree-tiled lon/lat raster at every grid point (uint8)."""
    lat_min, lat_max, lon_min, lon_max = bounds
    tiles = sorted({tile3(a, b) for a in (lat_min, lat_max) for b in (lon_min, lon_max)})
    windows = {}
    for t in tiles:
        r = read_tile_window(url_fmt.format(tile=t), f"{label}_{t}", bounds, cache, network, log)
        if r is not None:
            windows[t] = r
    out = np.full((grid.count, grid.count), fill, np.uint8)
    for r0 in range(0, grid.count, band_rows):
        r1 = min(grid.count, r0 + band_rows)
        lat, lon = _grid_lat_lon(grid, r0, r1)
        names = np.vectorize(tile3)(lat, lon) if len(windows) > 1 else np.full(lat.shape, tiles[0])
        for t, (data, tr) in windows.items():
            m = names == t
            col = np.floor((lon[m] - tr.c) / tr.a).astype(np.int64)
            row = np.floor((lat[m] - tr.f) / tr.e).astype(np.int64)
            ok = (row >= 0) & (row < data.shape[0]) & (col >= 0) & (col < data.shape[1])
            vals = np.full(m.sum(), fill, np.uint8)
            vals[ok] = data[row[ok], col[ok]]
            band = out[r0:r1]
            band[m] = vals
    return out, list(windows)


def build_landcover(grid, bounds, cache: Path, network, log, sha256_file) -> Layer:
    image, tiles = sample_tiles_nearest(grid, WORLDCOVER_URL, "worldcover", bounds, cache, network, log)
    vals, counts = np.unique(image, return_counts=True)
    shares = {WORLDCOVER_CLASSES.get(int(v), f"class {v}"): round(float(c) / image.size, 4)
              for v, c in zip(vals, counts)}
    log(f"  landcover: {shares}")
    meta = {
        "encoding": "PNG L8, ESA WorldCover 2021 class value (10 tree cover, 20 shrubland, 30 grassland, "
                    "40 cropland, 50 built-up, 60 bare, 70 snow and ice, 80 water, 90 wetland, 95 mangroves, "
                    "100 moss and lichen; 0 no data), nearest neighbour",
        "samples": grid.count, "spacing_m": grid.spacing,
        "source": {"product": "ESA WorldCover 10 m 2021 v200", "access": "s3://esa-worldcover/v200/2021/map",
                   "tiles": [f"ESA_WorldCover_10m_2021_v200_{t}_Map.tif" for t in tiles],
                   "citation": "Zanaga, D. et al. (2022) ESA WorldCover 10 m 2021 v200, doi:10.5281/zenodo.7254221"},
        "license": "CC-BY-4.0",
        "shares": shares,
    }
    return Layer("landcover", "landcover.png", image, meta, [WORLDCOVER_ATTRIBUTION])


def build_canopy(grid, bounds, cache: Path, network, log, sha256_file) -> Layer:
    raw, tiles = sample_tiles_nearest(grid, CANOPY_URL, "eth_canopy", bounds, cache, network, log, fill=255)
    metres = np.where(raw == 255, 0, raw).astype(np.float32)  # 255 = no data
    image = np.clip(np.round(metres * 4.0), 0, 255).astype(np.uint8)
    log(f"  canopy: {float((metres >= 3).mean()) * 100:.1f} % of the area >= 3 m, max {metres.max():.0f} m")
    meta = {
        "encoding": "PNG L8, canopy top height above ground in quarter metres (value / 4 = metres, 0..63.75), "
                    "nearest neighbour; no data = 0",
        "samples": grid.count, "spacing_m": grid.spacing,
        "source": {"product": "ETH Global Canopy Height 10 m 2020 (Lang et al. 2023)",
                   "access": "libdrive.ethz.ch 3deg_cogs",
                   "tiles": [f"ETH_GlobalCanopyHeight_10m_2020_{t}_Map.tif" for t in tiles]},
        "license": "CC-BY-4.0",
    }
    return Layer("canopy", "canopy.png", image, meta, [CANOPY_ATTRIBUTION])


# --- layers -----------------------------------------------------------------------------------------------------

def build_water(grid, bounds, release: str, cache: Path, network, log, sha256_file) -> Layer:
    table, path = overture_table("base", "water", bounds, ["id", "subtype", "class", "geometry"], release, cache,
                                 network, log)
    subtype = np.array(table.column("subtype").to_pylist(), dtype=object)
    geoms = shapely.from_wkb(table.column("geometry").to_pylist())
    keep = np.isin(subtype, WATER_SUBTYPES) & np.isin(shapely.get_type_id(geoms), (3, 6))  # Polygon, MultiPolygon
    geoms = shapely.make_valid(_clip(to_enu(geoms[keep], grid), grid))
    image = coverage(geoms, grid)
    counts = {str(k): int(v) for k, v in zip(*np.unique(subtype[keep], return_counts=True))}
    share = float((image >= 128).mean())
    log(f"  water: {int(keep.sum())} polygons {counts}, {share * 100:.1f} % of the area")
    meta = {
        "encoding": "PNG L8, share of the cell covered by water (255 = all water), rows north to south",
        "samples": grid.count, "spacing_m": grid.spacing,
        "source": {"product": "Overture Maps base/water (OpenStreetMap)", "release": release,
                   "access": f"s3://{OVERTURE_BUCKET}/release/{release}/theme=base/type=water",
                   "subtypes": counts, "rows_sha256": sha256_file(path)},
        "license": "ODbL-1.0 (derived from OpenStreetMap)",
        "water_share": share,
    }
    return Layer("water", "water.png", image, meta, [OSM_ATTRIBUTION])


def build_layers(names: list[str], grid_for, bounds, release: str, cache: Path, network, log, sha256_file
                 ) -> list[Layer]:
    """`grid_for(name)` returns the grid a layer is sampled on."""
    out = []
    for name in names:
        log(f"{name}:")
        if name == "water":
            out.append(build_water(grid_for(name), bounds, release, cache, network, log, sha256_file))
        elif name == "landcover":
            out.append(build_landcover(grid_for(name), bounds, cache, network, log, sha256_file))
        elif name == "canopy":
            out.append(build_canopy(grid_for(name), bounds, cache, network, log, sha256_file))
    return out
