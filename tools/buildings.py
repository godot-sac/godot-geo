"""Buildings layer and bare-earth ground model for tools/build_terrain.py (`--layers buildings`).

Data: Overture Maps `buildings/building` and `buildings/building_part` (OpenStreetMap, plus Microsoft ML footprints
where OpenStreetMap has none), read like the other Overture layers (tools/layers.py). Military sites never enter a
package: features of class / subtype military and every feature inside an Overture `base/land_use` military area
are dropped, and so are underground features.

Ground model. Copernicus DEM is a surface model: roofs and tree crowns are part of its heights (smoothed at 30 m).
Buildings drawn on top of it would count their height twice, so a package with buildings gets an approximate bare
earth instead (`height.surface = "dtm-approx"`): under building footprints (dilated by one sample) the surface is
filled in from the surrounding samples (a mask-weighted pyramid fill), under tree canopy it is lowered by half the
canopy height (radar penetrates part of the crown), and it never rises above the DEM.

Heights, in order: OpenStreetMap `height`; `building:levels` x 3 m (+ roof); GHSL GHS-BUILT-H 2018 average net
building height of the 100 m cell (CC BY 4.0), varied per building by a hash; a 3-6 floor default. The
DEM-minus-ground residual is only logged against tagged heights: in Üsküdar it gave a third of the real height (the
30 m DEM spreads roofs over the streets), so it is not used. Roofs: the tagged
shape, else hipped or gabled (chosen by a hash) for near-rectangular buildings below 30 m, flat otherwise.

File `buildings.bin` (little-endian), tiles of `tile_m` metres in rows from the north-west corner:
  header   "GGBL" u16 version=1 u16 reach f32 tile_m u16 tiles_x u16 tiles_z u32 count
           (reach: how many tiles beyond its own a footprint extends into, at least 1; 0 in older files = 1)
  index    tiles_x * tiles_z x (u32 offset, u32 zlib size, u32 raw size, u32 count), offsets from file start
  tile     zlib-compressed records:
    u32 id   u8 flags (bits 0-1 height source: 0 tag, 1 floors, 2 GHSL, 3 default; bit 2 part; bit 3 ML footprint)
    u8 roof shape (0 flat, 1 gabled, 2 hipped, 3 pyramidal, 4 dome, 5 onion)   u8x3 facade rgb   u8x3 roof rgb
    f32 base (lowest ground under the footprint, package frame)   f32 min_height   f32 height   f32 roof_height
    u16 rings, per ring u16 n + n x (i16 x, i16 z) in 5 cm units from the tile centre (Godot axes: x east,
    z south); ring 0 is the outline with positive signed area in (x, z), holes negative
    u16 triangles + 3 x u16 vertex indices (into the rings' vertices in order): the flat roof / floor
"""
from __future__ import annotations

import struct
import zlib

import numpy as np
import shapely
from rasterio.features import rasterize
from rasterio.transform import Affine

import layers

FLOOR_M = 3.0
MAX_LOWERING = 8.0  # m, see ground_model
QUANT = 0.05
TILE_M = 500.0
GHSL_URL = ("/vsizip//vsicurl/https://jeodpp.jrc.ec.europa.eu/ftp/jrc-opendata/GHSL/GHS_BUILT_H_GLOBE_R2023A/"
            "GHS_BUILT_H_ANBH_E2018_GLOBE_R2023A_4326_3ss/V1-0/tiles/{name}.zip/{name}.tif")
GHSL_NAME = "GHS_BUILT_H_ANBH_E2018_GLOBE_R2023A_4326_3ss_V1_0_R{r}_C{c}"
GHSL_ATTRIBUTION = ("Building heights: Pesaresi, M., Politis, P. (2023), GHS-BUILT-H R2023A, European Commission, "
                    "Joint Research Centre, doi:10.2905/85005901-3A49-48DD-9D19-6261354F56FE (CC BY 4.0)")
ROOF = {"flat": 0, "skillion": 0, "gabled": 1, "gambrel": 1, "saltbox": 1, "round": 1, "sawtooth": 1,
        "hipped": 2, "half_hipped": 2, "mansard": 2, "pyramidal": 3, "dome": 4, "spherical": 4, "onion": 5}
# Istanbul-like palettes (sRGB): plastered facades, terracotta tiles, grey flat roofs.
FACADES = [(232, 226, 210), (224, 214, 190), (236, 222, 196), (214, 200, 176), (226, 206, 186), (205, 205, 200),
           (238, 232, 218), (218, 190, 160), (200, 186, 170), (230, 214, 168)]
TILES = [(160, 82, 58), (150, 74, 52), (172, 96, 66), (138, 70, 54)]
FLAT_ROOFS = [(150, 148, 142), (128, 126, 122), (170, 166, 158), (110, 108, 106)]


def _hash(s: str, salt: int = 0) -> float:
    """Deterministic [0, 1) from a feature id (Python's hash() is salted per process)."""
    return (zlib.crc32(f"{salt}:{s}".encode()) & 0xFFFFFF) / 16777216.0


def _color(value, palette, u: float) -> tuple[int, int, int]:
    if isinstance(value, str) and value.startswith("#") and len(value) in (4, 7):
        v = value[1:]
        if len(v) == 3:
            v = "".join(ch * 2 for ch in v)
        try:
            return tuple(int(v[i:i + 2], 16) for i in (0, 2, 4))
        except ValueError:
            pass
    return palette[int(u * len(palette)) % len(palette)]


# --- ground model -----------------------------------------------------------------------------------------------

def _down(a: np.ndarray, w: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    h, wd = a.shape
    h2, w2 = (h + 1) // 2, (wd + 1) // 2
    pa = np.zeros((h2 * 2, w2 * 2))
    pw = np.zeros((h2 * 2, w2 * 2))
    pa[:h, :wd] = a * w
    pw[:h, :wd] = w
    s = pa.reshape(h2, 2, w2, 2).sum(axis=(1, 3))
    n = pw.reshape(h2, 2, w2, 2).sum(axis=(1, 3))
    return np.where(n > 0, s / np.maximum(n, 1e-12), 0.0), n


def fill_holes(values: np.ndarray, known: np.ndarray) -> np.ndarray:
    """Fills the unknown samples from the known ones: a mask-weighted image pyramid, coarse values pushed down into
    the holes, then a few smoothing passes inside the holes only."""
    levels = [(values.astype(np.float64), known.astype(np.float64))]
    while min(levels[-1][0].shape) > 2 and levels[-1][1].min() == 0:
        levels.append(_down(*levels[-1]))
    top, w_top = levels[-1]
    mean = float((values[known]).mean()) if known.any() else 0.0
    filled = np.where(w_top > 0, top, mean)  # cells still empty at the coarsest level take the overall mean
    for a, w in reversed(levels[:-1]):
        up = np.repeat(np.repeat(filled, 2, axis=0), 2, axis=1)[:a.shape[0], :a.shape[1]]
        filled = np.where(w > 0, a, up)
    holes = ~known
    for _ in range(8):
        p = np.pad(filled, 1, mode="edge")
        smooth = (p[:-2, 1:-1] + p[2:, 1:-1] + p[1:-1, :-2] + p[1:-1, 2:]) * 0.25
        filled = np.where(holes, smooth, filled)
    return filled


def _dilate(mask: np.ndarray) -> np.ndarray:
    p = np.pad(mask, 1)
    rows = p[:-2] | p[1:-1] | p[2:]
    return rows[:, :-2] | rows[:, 1:-1] | rows[:, 2:]  # 3 x 3 square


def ground_model(dsm: np.ndarray, footprints: np.ndarray, canopy_m: np.ndarray | None,
                 water: np.ndarray | None = None) -> np.ndarray:
    """Approximate bare earth. Water samples neither feed the fill (on a built-up shore they would drag the land
    down to sea level) nor change."""
    crowns = 0.5 * np.where(canopy_m >= 3.0, canopy_m, 0.0) if canopy_m is not None else np.zeros_like(dsm)
    lowered = dsm.astype(np.float64) - crowns
    mask = _dilate(footprints)
    if water is not None:
        mask = mask & ~water
        ground = fill_holes(lowered, ~mask & ~water)
        ground = np.where(water, dsm, ground)
    else:
        ground = fill_holes(lowered, ~mask)
    # The 30 m DEM smears a roof over its surroundings, so the building signal in it is a few metres; capping the
    # lowering keeps hills that are entirely built over (the fill would otherwise flatten them towards their foot).
    ground = np.maximum(ground, dsm - np.maximum(MAX_LOWERING, crowns))
    return np.minimum(ground, dsm).astype(np.float32)


def _resample_nearest(img: np.ndarray, n: int) -> np.ndarray:
    idx = np.clip(np.round(np.arange(n) * (img.shape[0] - 1) / (n - 1)).astype(np.int64), 0, img.shape[0] - 1)
    return img[np.ix_(idx, idx)]


# --- GHSL average building height ---------------------------------------------------------------------------------

def ghsl_heights(points_lat: np.ndarray, points_lon: np.ndarray, bounds, cache, network, log) -> np.ndarray | None:
    """GHS-BUILT-H average net building height (m) at the points; NaN where 0 / outside; None if unavailable."""
    lat_min, lat_max, lon_min, lon_max = bounds
    out = np.full(points_lat.shape, np.nan)
    names = set()
    for la in (lat_min, lat_max):
        for lo in (lon_min, lon_max):
            names.add((int((89.0996 - la) // 10) + 1, int((lo + 180.0079) // 10) + 1))
    found = False
    for r, c in sorted(names):
        name = GHSL_NAME.format(r=r, c=c)
        try:
            res = layers.read_tile_window(GHSL_URL.format(name=name), f"ghsl_{r}_{c}", bounds, cache, network, log)
        except Exception as err:  # noqa: BLE001 - the estimate falls back to defaults
            log(f"  GHSL {name}: {err}")
            continue
        if res is None:
            continue
        found = True
        data, tr = res
        col = np.floor((points_lon - tr.c) / tr.a).astype(np.int64)
        row = np.floor((points_lat - tr.f) / tr.e).astype(np.int64)
        ok = (row >= 0) & (row < data.shape[0]) & (col >= 0) & (col < data.shape[1])
        vals = np.full(points_lat.shape, np.nan)
        vals[ok] = data[row[ok], col[ok]]
        out = np.where(np.isnan(out) & (vals > 0), vals, out)
    return out if found else None


# --- features -----------------------------------------------------------------------------------------------------

def _num(v):
    return None if v is None or (isinstance(v, float) and np.isnan(v)) else v


def _is_ml(sources) -> bool:
    return bool(sources) and all("OpenStreetMap" not in (s.get("dataset") or "") for s in sources)


def load_features(grid, bounds, release, cache, network, log):
    cols = ["id", "class", "subtype", "height", "min_height", "num_floors", "min_floor", "roof_shape", "roof_height",
            "roof_color", "facade_color", "is_underground", "has_parts", "sources", "geometry"]
    b, _ = layers.overture_table("buildings", "building", bounds, cols, release, cache, network, log)
    pcols = [c for c in cols if c not in ("class", "subtype", "has_parts")] + ["building_id"]
    p, _ = layers.overture_table("buildings", "building_part", bounds, pcols, release, cache, network, log)
    lu, _ = layers.overture_table("base", "land_use", bounds, ["id", "subtype", "class", "geometry"], release, cache,
                                  network, log)
    military = [g for g, s, c in zip(shapely.from_wkb(lu.column("geometry").to_pylist()),
                                     lu.column("subtype").to_pylist(), lu.column("class").to_pylist())
                if s == "military" or c in ("military", "barracks", "bunker", "naval_base", "airfield_military")]
    military = layers.to_enu(np.array(military, dtype=object), grid) if military else np.array([], dtype=object)
    mil_union = shapely.union_all(shapely.make_valid(military)) if len(military) else None
    if mil_union is not None:
        shapely.prepare(mil_union)

    brows = b.to_pylist()
    prows = p.to_pylist()
    bgeo = layers.to_enu(shapely.from_wkb([r["geometry"] for r in brows]), grid)
    pgeo = layers.to_enu(shapely.from_wkb([r["geometry"] for r in prows]), grid) if prows else np.array([])
    parts_of: dict[str, list[int]] = {}
    for i, r in enumerate(prows):
        parts_of.setdefault(r["building_id"], []).append(i)

    half = grid.half - grid.spacing
    stats = {"military_dropped": 0, "underground_dropped": 0, "outside": 0}
    feats = []
    for i, r in enumerate(brows):
        g = bgeo[i]
        if g is None or g.is_empty:
            continue
        if r.get("is_underground"):
            stats["underground_dropped"] += 1
            continue
        pt = g.representative_point()
        if abs(pt.x) > half or abs(pt.y) > half:
            stats["outside"] += 1
            continue
        if r.get("class") == "military" or r.get("subtype") == "military" or \
                (mil_union is not None and mil_union.contains(pt)):
            stats["military_dropped"] += 1
            continue
        ml = _is_ml(r.get("sources"))
        parts = parts_of.get(r["id"], [])
        if parts:
            for j in parts:
                pr = prows[j]
                if pr.get("is_underground") or pgeo[j] is None or pgeo[j].is_empty:
                    continue
                pr = dict(pr)
                for k in ("facade_color", "roof_color"):
                    pr[k] = pr.get(k) or r.get(k)
                pr["class"] = r.get("class")
                feats.append((pr, pgeo[j], True, ml))
        else:
            feats.append((r, g, False, ml))
    return feats, stats


def _polygons(g):
    g = shapely.make_valid(g)
    if g.geom_type == "Polygon":
        return [g]
    return [x for x in getattr(g, "geoms", []) if x.geom_type == "Polygon"]


def _rect_like(poly) -> tuple[bool, float, float]:
    """(near-rectangular, short side, long side) from the minimum rotated rectangle."""
    mrr = shapely.minimum_rotated_rectangle(poly)
    c = np.asarray(mrr.exterior.coords)[:4]
    a = np.linalg.norm(c[1] - c[0])
    b = np.linalg.norm(c[2] - c[1])
    fill = poly.area / max(mrr.area, 1e-9)
    # Exactly four corners: the renderer builds hipped / gabled / pyramidal roofs on four-corner outlines only.
    return fill > 0.85 and len(poly.exterior.coords) == 5, min(a, b), max(a, b)


def build_buildings(grid, dsm: np.ndarray, canopy_layer, bounds, release, cache, network, log, sha256_file,
                    water_layer=None):
    """Returns (ground heights for height.exr, [Layer buildings.bin, Layer footprints.png], stats)."""
    feats, stats = load_features(grid, bounds, release, cache, network, log)
    log(f"  {len(feats)} buildings / parts in the area; dropped: {stats}")

    # Split multipolygons, simplify, drop slivers. Coordinates: ENU east / north here.
    polys = []
    for r, g, part, ml in feats:
        for poly in _polygons(g):
            poly = shapely.simplify(poly, 0.25)
            if poly.is_empty or poly.area < 6.0 or poly.geom_type != "Polygon":
                continue
            polys.append((r, poly, part, ml))

    # Footprint mask on the height grid and the ground model.
    n = grid.count
    t = Affine(grid.spacing, 0.0, -grid.half - grid.spacing / 2, 0.0, -grid.spacing, grid.half + grid.spacing / 2)
    labels = rasterize([(poly, k + 1) for k, (_, poly, _, _) in enumerate(polys)], out_shape=(n, n), transform=t,
                       fill=0, dtype="int32", all_touched=True)
    canopy_m = None
    if canopy_layer is not None:
        canopy_m = _resample_nearest(canopy_layer.image, n).astype(np.float32) / 4.0
    water = _resample_nearest(water_layer.image, n) >= 128 if water_layer is not None else None
    ground = ground_model(dsm, labels > 0, canopy_m, water)
    residual = np.clip(dsm - ground, 0.0, None)
    removed = residual[labels > 0]
    log(f"  ground model: DEM lowered under footprints by {np.median(removed):.1f} m median, "
        f"{np.percentile(removed, 90):.1f} m p90")

    # Residual mean per footprint (bincount over the label raster).
    cnt = np.bincount(labels.ravel(), minlength=len(polys) + 1)
    rsum = np.bincount(labels.ravel(), weights=residual.ravel(), minlength=len(polys) + 1)
    rmean = rsum / np.maximum(cnt, 1)

    cent = np.array([[p.centroid.x, p.centroid.y] for _, p, _, _ in polys]) if polys else np.zeros((0, 2))
    lat, lon, _ = layers.pymap3d.enu2geodetic(cent[:, 0], cent[:, 1], 0.0, grid.lat0, grid.lon0, grid.h0,
                                              layers.WGS84)
    ghsl = ghsl_heights(lat, (lon + 180.0) % 360.0 - 180.0, bounds, cache, network, log)

    def ground_at(e, nn):
        c = (e + grid.half) / grid.spacing
        r = (grid.half - nn) / grid.spacing
        c0 = np.clip(np.floor(c).astype(int), 0, n - 2)
        r0 = np.clip(np.floor(r).astype(int), 0, n - 2)
        fc, fr = np.clip(c - c0, 0, 1), np.clip(r - r0, 0, 1)
        a = ground[r0, c0] * (1 - fc) + ground[r0, c0 + 1] * fc
        b = ground[r0 + 1, c0] * (1 - fc) + ground[r0 + 1, c0 + 1] * fc
        return a * (1 - fr) + b * fr

    # Resolve heights, roofs and colours.
    records = []
    src_count = [0, 0, 0, 0]
    tagged_pairs = []
    for k, (r, poly, part, ml) in enumerate(polys):
        fid = r["id"]
        area = poly.area
        roof_h = _num(r.get("roof_height")) or 0.0
        min_h = _num(r.get("min_height"))
        if min_h is None and _num(r.get("min_floor")):
            min_h = r["min_floor"] * FLOOR_M
        min_h = min_h or 0.0
        h = _num(r.get("height"))
        floors = _num(r.get("num_floors"))
        est = None
        if rmean[k + 1] > 3.0 and area >= 400.0:
            est = float(rmean[k + 1]) * 1.4  # the 30 m DEM spreads a roof over its surroundings
        if h is not None and h > min_h:
            src = 0
            if est is not None:
                tagged_pairs.append((h, est, ghsl[k] if ghsl is not None else np.nan))
        elif floors:
            h = floors * FLOOR_M + roof_h
            src = 1
        elif ghsl is not None and not np.isnan(ghsl[k]):
            h = float(ghsl[k]) * (0.75 + 0.5 * _hash(fid, 1))
            if area < 60.0:
                h = min(h, 6.0)
            src = 2
        else:
            h = (FLOOR_M * (2 if area < 60.0 else 3 + int(_hash(fid, 1) * 4)))
            src = 3
        h = float(np.clip(h, min_h + 2.5, 600.0))
        src_count[src] += 1
        shape_tag = r.get("roof_shape")
        rect, short, long_ = _rect_like(poly)
        if shape_tag in ROOF:
            shape = ROOF[shape_tag]
        elif part or src == 0 and h > 30.0:
            shape = 0
        elif rect and h < 30.0 and area < 1500.0:
            u = _hash(fid, 2)
            shape = 2 if u < 0.65 else (1 if u < 0.75 else 0)
        else:
            shape = 0
        if shape in (1, 2, 3) and not roof_h:
            roof_h = min(0.3 * short, 3.5) if short > 0 else 2.0
        if shape in (4, 5) and not roof_h:
            roof_h = np.sqrt(area / np.pi)
        roof_h = float(min(roof_h, max(h - min_h - 1.0, 0.5)))
        facade = _color(r.get("facade_color"), FACADES, _hash(fid, 3))
        roof_pal = TILES if shape in (1, 2, 3) else FLAT_ROOFS
        roof_c = _color(r.get("roof_color"), roof_pal, _hash(fid, 4))
        ext = np.asarray(poly.exterior.coords)[:-1]
        base = float(min(ground_at(ext[:, 0], ext[:, 1]).min(), ground_at(np.array([poly.centroid.x]),
                                                                         np.array([poly.centroid.y]))[0]))
        flags = src | (4 if part else 0) | (8 if ml else 0)
        records.append((k, poly, flags, shape, facade, roof_c, base, min_h, h, roof_h))
    if tagged_pairs:
        tp = np.array(tagged_pairs)
        log(f"  height check on {len(tp)} tagged buildings with a DEM estimate: median tag {np.median(tp[:, 0]):.1f} m,"
            f" estimate {np.median(tp[:, 1]):.1f} m, GHSL {np.nanmedian(tp[:, 2]):.1f} m")
    names = ["tag", "floors", "ghsl", "default"]
    shares = {names[i]: round(c / max(len(records), 1), 4) for i, c in enumerate(src_count)}
    log(f"  height sources: {shares}")

    data, tiles = encode(records, grid)
    meta = {
        "encoding": "godot-geo buildings v1 (see tools/buildings.py): zlib tiles of footprints with base, heights, "
                    "roof shape, colours and roof triangles; positions in the package frame",
        "tile_m": TILE_M, "tiles": tiles, "count": len(records), "height_sources": shares,
        "dropped": stats,
        "source": {"product": "Overture Maps buildings (OpenStreetMap; Microsoft ML footprints where OSM has none)",
                   "release": release, "access": f"s3://{layers.OVERTURE_BUCKET}/release/{release}/theme=buildings",
                   "height_hint": "GHS-BUILT-H R2023A ANBH 2018 (100 m)" if ghsl is not None else None},
        "license": "ODbL-1.0 (derived from OpenStreetMap via Overture Maps)",
    }
    attribution = [layers.OSM_ATTRIBUTION] + ([GHSL_ATTRIBUTION] if ghsl is not None else [])
    layer = layers.Layer("buildings", "buildings.bin", None, meta, attribution, data=data)
    fp = layers.Layer("footprints", "footprints.png", np.where(labels > 0, 255, 0).astype(np.uint8), {
        "encoding": "PNG L8, 255 where a building footprint touches the height sample's cell, else 0",
        "samples": n, "spacing_m": grid.spacing, "license": "ODbL-1.0 (derived from OpenStreetMap via Overture Maps)"})
    ground_stats = {"removed_median_m": float(np.median(removed)) if removed.size else 0.0,
                    "removed_p90_m": float(np.percentile(removed, 90)) if removed.size else 0.0}
    return ground, [layer, fp], ground_stats


def _quant_ring(coords: np.ndarray, cx: float, cz: float) -> list[tuple[int, int]]:
    """ENU east / north -> Godot x, z relative to the tile centre, 5 cm integers, duplicates removed."""
    out = []
    for e, nn in coords:
        q = (int(round((e - cx) / QUANT)), int(round((-nn - cz) / QUANT)))
        if not out or q != out[-1]:
            out.append(q)
    if len(out) > 1 and out[0] == out[-1]:
        out.pop()
    return out


def _area(ring) -> float:
    a = np.asarray(ring, dtype=np.float64)
    return 0.5 * float(np.sum(a[:, 0] * np.roll(a[:, 1], -1) - np.roll(a[:, 0], -1) * a[:, 1]))


def _triangles(rings) -> list[tuple[int, int, int]]:
    index = {}
    k = 0
    for ring in rings:
        for v in ring:
            index.setdefault(v, k)
            k += 1
    poly = shapely.Polygon(rings[0], rings[1:])
    if not poly.is_valid:
        poly = shapely.Polygon(rings[0])
    try:
        tris = shapely.constrained_delaunay_triangles(poly)
    except Exception:  # noqa: BLE001
        return []
    out = []
    for tri in getattr(tris, "geoms", []):
        c = [tuple(int(round(x)) for x in p) for p in np.asarray(tri.exterior.coords)[:3]]
        if all(v in index for v in c):
            out.append(tuple(index[v] for v in c))
    return out


def encode(records, grid) -> tuple[bytes, dict]:
    tx = int(np.ceil(grid.size / TILE_M))
    tiles: list[list[bytes]] = [[] for _ in range(tx * tx)]
    reach = 1  # tiles beyond its own that a footprint reaches into (readers search that far)
    for k, poly, flags, shape, facade, roof_c, base, min_h, h, roof_h in records:
        c = poly.centroid
        i = min(max(int((c.x + grid.half) // TILE_M), 0), tx - 1)
        j = min(max(int((grid.half - c.y) // TILE_M), 0), tx - 1)
        cx = -grid.half + (i + 0.5) * TILE_M
        cz = -grid.half + (j + 0.5) * TILE_M
        rings = [_quant_ring(np.asarray(poly.exterior.coords), cx, cz)]
        rings += [_quant_ring(np.asarray(r.coords), cx, cz) for r in poly.interiors]
        rings = [r for r in rings if len(r) >= 3]
        if not rings or len(rings[0]) < 3 or abs(_area(rings[0])) * QUANT * QUANT < 4.0:
            continue
        if _area(rings[0]) < 0:
            rings[0].reverse()
        for r in rings[1:]:
            if _area(r) > 0:
                r.reverse()
        extent = max(max(abs(x), abs(z)) for r in rings for x, z in r)
        if extent > 32000:
            continue  # cannot happen for footprints below ~1.1 km
        reach = max(reach, int(np.ceil((extent * QUANT - TILE_M / 2) / TILE_M)))
        tris = _triangles(rings)
        buf = [struct.pack("<IBB3B3B4f", k, flags, shape, *facade, *roof_c, base, min_h, h, roof_h),
               struct.pack("<H", len(rings))]
        for r in rings:
            buf.append(struct.pack("<H", len(r)))
            buf.append(np.asarray(r, dtype="<i2").tobytes())
        buf.append(struct.pack("<H", len(tris)))
        buf.append(np.asarray(tris, dtype="<u2").tobytes() if tris else b"")
        tiles[j * tx + i].append(b"".join(buf))
    header = b"GGBL" + struct.pack("<HHfHHI", 1, reach, TILE_M, tx, tx, sum(len(t) for t in tiles))
    offset = len(header) + 16 * len(tiles)
    index = []
    blobs = []
    for t in tiles:
        raw = b"".join(t)
        comp = zlib.compress(raw, 6) if raw else b""
        index.append(struct.pack("<IIII", offset, len(comp), len(raw), len(t)))
        blobs.append(comp)
        offset += len(comp)
    nonempty = sum(1 for t in tiles if t)
    return header + b"".join(index) + b"".join(blobs), {"x": tx, "z": tx, "non_empty": nonempty, "reach": reach}
