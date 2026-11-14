"""Roads and railways layer for tools/build_terrain.py (`--layers roads`).

Data: Overture Maps `transportation/segment` (OpenStreetMap; ODbL). Road and rail segments are split where their
bridge / tunnel flags change (Overture gives flags for fractions of a segment), cut into pieces of at most
`MAX_PIECE_M` and filed under the tile of their midpoint. Tunnels are kept but flagged (the renderer skips them).
Bridge pieces carry a deck height per vertex: the ground at the two ends of the whole bridge (+0.5 m), linear in
between, never less than 5 m above the ground below, and level at the higher end where the bridge crosses water.
Where the bridge's OpenStreetMap outline gives a height (tools/bridges.py), the part over water is at that height
above the water, with ramps to the ends. terrain.json's roads entry also holds the generated towers, cables and
hangers of suspension bridges ("structures", tools/bridges.py).

File `roads.bin` (little-endian), tiles like buildings.bin:
  header   "GGRD" u16 version=1 u16 reserved f32 tile_m u16 tiles_x u16 tiles_z u32 count
  index    tiles_x * tiles_z x (u32 offset, u32 zlib size, u32 raw size, u32 count)
  tile     zlib-compressed records:
    u8 class (see CLASSES)  u8 flags (1 bridge, 2 tunnel, 4 rail)  f32 width (m)  u16 n
    n x (i16 x, i16 z) in 5 cm units from the tile centre (Godot axes)
    bridges only: n x f32 deck height (package frame)
"""
from __future__ import annotations

import struct
import zlib

import numpy as np
import shapely
import shapely.ops

import bridges as geo_bridges
import layers

TILE_M = 500.0
QUANT = 0.05
MAX_PIECE_M = 400.0
CLASSES = {"motorway": 1, "trunk": 2, "primary": 3, "secondary": 4, "tertiary": 5, "residential": 6,
           "living_street": 7, "unclassified": 8, "service": 9, "pedestrian": 10, "footway": 11, "steps": 12,
           "path": 13, "track": 14, "cycleway": 15, "bridleway": 16, "unknown": 17, "rail": 20}
# Typical full width in metres (carriageway plus shoulders) when the data gives none.
WIDTH = {1: 22.0, 2: 16.0, 3: 12.0, 4: 10.0, 5: 8.0, 6: 6.0, 7: 5.0, 8: 5.0, 9: 4.0, 10: 6.0, 11: 2.0, 12: 2.0,
         13: 1.5, 14: 3.0, 15: 2.0, 16: 1.5, 17: 5.0, 20: 3.5}
BRIDGE, TUNNEL, RAIL = 1, 2, 4


def _flags_at(rules, key: str) -> list[tuple[float, float]]:
    """Fractions of the segment where flag `key` holds."""
    out = []
    for r in rules or []:
        if key in (r.get("values") or []):
            b = r.get("between")
            out.append((float(b[0]), float(b[1])) if b else (0.0, 1.0))
    return out


def _pieces(line, bridge: list, tunnel: list) -> list[tuple[object, int]]:
    cuts = sorted({0.0, 1.0} | {x for a, b in bridge + tunnel for x in (a, b)})
    out = []
    for a, b in zip(cuts[:-1], cuts[1:]):
        if b - a < 1e-6:
            continue
        mid = (a + b) / 2
        f = (BRIDGE if any(x <= mid <= y for x, y in bridge) else 0) | \
            (TUNNEL if any(x <= mid <= y for x, y in tunnel) else 0)
        part = shapely.ops.substring(line, a, b, normalized=True)
        if part.geom_type == "LineString" and part.length > 0.5:
            out.append((part, f))
    return out


def build_roads(grid, ground: np.ndarray, water_layer, bounds, release, cache, network, log, sha256_file):
    cols = ["id", "subtype", "class", "road_flags", "width_rules", "geometry"]
    t, _ = layers.overture_table("transportation", "segment", bounds, cols, release, cache, network, log)
    rows = t.to_pylist()
    geoms = layers.to_enu(shapely.from_wkb([r["geometry"] for r in rows]), grid)
    n = grid.count
    water = water_layer
    sp = grid.spacing

    def ground_at(e, nn):
        c = np.clip((np.asarray(e) + grid.half) / sp, 0, n - 1.001)
        r = np.clip((grid.half - np.asarray(nn)) / sp, 0, n - 1.001)
        c0, r0 = np.floor(c).astype(int), np.floor(r).astype(int)
        fc, fr = c - c0, r - r0
        a = ground[r0, c0] * (1 - fc) + ground[r0, c0 + 1] * fc
        b = ground[r0 + 1, c0] * (1 - fc) + ground[r0 + 1, c0 + 1] * fc
        return a * (1 - fr) + b * fr

    def water_at(e, nn):
        if water is None:
            return np.zeros(np.shape(e), bool)
        wn = water.image.shape[0]
        ws = water.meta["spacing_m"]
        c = np.clip(np.round((np.asarray(e) + grid.half) / ws).astype(int), 0, wn - 1)
        r = np.clip(np.round((grid.half - np.asarray(nn)) / ws).astype(int), 0, wn - 1)
        return water.image[r, c] >= 128

    outlines = geo_bridges.load(grid, bounds, release, cache, network, log)

    half = grid.half - 1.0
    clip = shapely.box(-half, -half, half, half)
    records = []
    counts: dict[str, int] = {}
    for r, g in zip(rows, geoms):
        if g is None or g.is_empty or r.get("subtype") not in ("road", "rail"):
            continue
        cls = CLASSES["rail"] if r["subtype"] == "rail" else CLASSES.get(r.get("class") or "unknown", 17)
        width = WIDTH[cls]
        for w in r.get("width_rules") or []:
            if w.get("between") is None and w.get("value") and 1.5 <= w["value"] <= 60.0:
                width = float(w["value"])
        bridge = _flags_at(r.get("road_flags"), "is_bridge")
        tunnel = _flags_at(r.get("road_flags"), "is_tunnel")
        for piece, flags in _pieces(g, bridge, tunnel):
            flags |= RAIL if cls == 20 else 0
            c = np.asarray(piece.coords)
            deck = None
            if flags & BRIDGE:
                gr = ground_at(c[:, 0], c[:, 1])
                d = np.concatenate([[0.0], np.cumsum(np.linalg.norm(np.diff(c, axis=0), axis=1))])
                h0, h1 = gr[0] + 0.5, gr[-1] + 0.5
                deck = h0 + (h1 - h0) * d / max(d[-1], 1e-6)
                steps = np.arange(0.0, piece.length, 20.0)
                dense = np.asarray([piece.interpolate(s).coords[0] for s in steps])
                wet = water_at(dense[:, 0], dense[:, 1])
                if wet.any():
                    deck = np.full_like(deck, max(h0, h1))
                    outline = outlines.outline_at(piece.interpolate(0.5, normalized=True))
                    if outline is not None:
                        # Mapped deck height above the water, with ramps to the bridge ends on land.
                        top = float(np.median(ground_at(dense[wet, 0], dense[wet, 1]))) + outline["height"]
                        w0, w1 = float(steps[wet][0]), float(steps[wet][-1])
                        if top > max(h0, h1) and w1 > w0:
                            deck = np.interp(d, [0.0, w0, w1, d[-1]], [h0, top, top, h1])
                deck = np.maximum(deck, gr + 5.0 * (d > 0) * (d < d[-1]))
            clipped = piece.intersection(clip)
            if clipped.is_empty:
                continue
            if clipped.geom_type != "LineString" or len(clipped.coords) != len(c):
                if deck is not None:
                    continue  # bridges crossing the package edge: skip rather than guess their deck
                parts = [x for x in getattr(clipped, "geoms", [clipped]) if x.geom_type == "LineString"]
            else:
                parts = [clipped]
            for part in parts:
                pc = np.asarray(part.coords)
                pd = deck
                # Cut long pieces so their coordinates fit the tile encoding.
                step = max(2, int(np.ceil(part.length / MAX_PIECE_M)) + 1)
                if len(pc) >= 2 and part.length > MAX_PIECE_M:
                    cuts = np.linspace(0.0, 1.0, step)
                    for a, b in zip(cuts[:-1], cuts[1:]):
                        sub = shapely.ops.substring(part, a, b, normalized=True)
                        sc = np.asarray(sub.coords)
                        sd = None if pd is None else np.interp(
                            [part.project(shapely.Point(p)) for p in sc],
                            [part.project(shapely.Point(p)) for p in pc], pd)
                        records.append((cls, flags, width, sc, sd))
                else:
                    records.append((cls, flags, width, pc, pd))
            name = "rail" if cls == 20 else (r.get("class") or "unknown")
            counts[name] = counts.get(name, 0) + 1
    bridges = sum(1 for x in records if x[1] & BRIDGE)
    log(f"  roads: {len(records)} pieces ({bridges} bridge), classes {dict(sorted(counts.items()))}")
    data, tiles = encode(records, grid)
    structures = geo_bridges.structures(outlines, ground_at)
    log(f"  bridge structures: {len(structures['towers'])} towers, {len(structures['cables'])} cables, "
        f"{len(structures['hangers'])} hangers")
    meta = {
        "encoding": "godot-geo roads v1 (see tools/roads.py): zlib tiles of polylines with class, flags, width "
                    "and bridge deck heights; package frame",
        "structures": structures,
        "tile_m": TILE_M, "tiles": tiles, "count": len(records), "bridges": bridges,
        "source": layers.vector_source("transportation", "Overture Maps transportation segments (OpenStreetMap)",
                                       release),
        "license": layers.license_text(),
    }
    return layers.Layer("roads", "roads.bin", None, meta, [layers.attribution()], data=data)


def encode(records, grid) -> tuple[bytes, dict]:
    tx = int(np.ceil(grid.size / TILE_M))
    tiles: list[list[bytes]] = [[] for _ in range(tx * tx)]
    for cls, flags, width, c, deck in records:
        m = c[len(c) // 2] if len(c) > 2 else c.mean(axis=0)
        i = min(max(int((m[0] + grid.half) // TILE_M), 0), tx - 1)
        j = min(max(int((grid.half - m[1]) // TILE_M), 0), tx - 1)
        cx = -grid.half + (i + 0.5) * TILE_M
        cz = -grid.half + (j + 0.5) * TILE_M
        q = np.stack([np.round((c[:, 0] - cx) / QUANT), np.round((-c[:, 1] - cz) / QUANT)], axis=1)
        if np.abs(q).max() > 32000 or len(q) < 2:
            continue
        buf = struct.pack("<BBfH", cls, flags, width, len(q)) + q.astype("<i2").tobytes()
        if flags & BRIDGE:
            buf += np.asarray(deck, dtype="<f4").tobytes()
        tiles[j * tx + i].append(buf)
    header = b"GGRD" + struct.pack("<HHfHHI", 1, 0, TILE_M, tx, tx, sum(len(t) for t in tiles))
    offset = len(header) + 16 * len(tiles)
    index, blobs = [], []
    for t in tiles:
        raw = b"".join(t)
        comp = zlib.compress(raw, 6) if raw else b""
        index.append(struct.pack("<IIII", offset, len(comp), len(raw), len(t)))
        blobs.append(comp)
        offset += len(comp)
    return header + b"".join(index) + b"".join(blobs), {"x": tx, "z": tx,
                                                         "non_empty": sum(1 for t in tiles if t)}
