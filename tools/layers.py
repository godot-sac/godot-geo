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
LAYERS = ("water",)

WGS84 = pymap3d.Ellipsoid.from_name("wgs84")


@dataclass
class Layer:
    key: str
    file: str
    image: np.ndarray  # uint8, rows = north to south
    meta: dict
    attribution: list[str] = field(default_factory=list)


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
    """Lon/lat geometries -> ENU east/north on the grid's tangent plane (points at h = 0; the height of a point
    changes its east/north by millimetres only)."""
    def fn(xy: np.ndarray) -> np.ndarray:
        lon = grid.lon0 + ((xy[:, 0] - grid.lon0 + 180.0) % 360.0 - 180.0)
        e, n, _ = pymap3d.geodetic2enu(xy[:, 1], lon, np.zeros(len(xy)), grid.lat0, grid.lon0, grid.h0, WGS84)
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
    return out
