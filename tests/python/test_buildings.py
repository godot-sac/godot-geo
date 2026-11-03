"""Tests for tools/buildings.py: ground model, buildings.bin encoding, and the committed Üsküdar test package
(military areas, heights, footprints). The Overture rows are read from tools/.cache when present; tests that need
them are skipped otherwise (no network in tests)."""
import json
import struct
import sys
import zlib
from pathlib import Path

import numpy as np
import pytest
import shapely

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / "tools"))
import build_terrain as bt  # noqa: E402
import buildings  # noqa: E402
import layers  # noqa: E402

PACKAGE = REPO / "tests" / "data" / "uskudar_small"


def decode(data: bytes) -> list[dict]:
    """Independent reader of buildings.bin (mirrors the format in the module docstring)."""
    assert data[:4] == b"GGBL"
    version, _, tile_m, tx, tz, count = struct.unpack_from("<HHfHHI", data, 4)
    assert version == 1
    out = []
    for t in range(tx * tz):
        off, size, raw_size, n = struct.unpack_from("<IIII", data, 20 + 16 * t)
        if not n:
            continue
        raw = zlib.decompress(data[off:off + size])
        assert len(raw) == raw_size
        cx = -tx * tile_m / 2 + ((t % tx) + 0.5) * tile_m
        cz = -tz * tile_m / 2 + ((t // tx) + 0.5) * tile_m
        p = 0
        for _ in range(n):
            fid, flags, roof, *rest = struct.unpack_from("<IBB3B3B4f", raw, p)
            p += 28
            (nr,) = struct.unpack_from("<H", raw, p)
            p += 2
            rings = []
            for _ in range(nr):
                (k,) = struct.unpack_from("<H", raw, p)
                p += 2
                v = np.frombuffer(raw, "<i2", k * 2, p).reshape(k, 2) * 0.05 + (cx, cz)
                p += 4 * k
                rings.append(v)
            (nt,) = struct.unpack_from("<H", raw, p)
            p += 2 + 6 * nt
            out.append({"id": fid, "flags": flags, "roof": roof, "base": rest[6], "min_height": rest[7],
                        "height": rest[8], "roof_height": rest[9], "rings": rings, "tris": nt})
        assert p == len(raw)
    assert len(out) == count
    return out


def test_fill_holes_plane():
    yy, xx = np.mgrid[0:40, 0:50].astype(float)
    plane = 3.0 + 0.5 * xx - 0.25 * yy
    known = np.ones_like(plane, bool)
    known[10:25, 12:30] = False
    filled = buildings.fill_holes(np.where(known, plane, 999.0), known)
    assert np.abs(filled - plane)[known].max() == 0.0
    assert np.abs(filled - plane)[~known].max() < 2.0  # a plane is not exactly harmonic at the pyramid's coarse levels


def test_ground_model_removes_a_box():
    yy, xx = np.mgrid[0:60, 0:60].astype(float)
    ground = 10.0 + 0.2 * xx
    dsm = ground.copy()
    dsm[20:35, 25:40] += 6.0  # a building in the surface model (smeared to a few metres at 30 m)
    fp = np.zeros_like(dsm, bool)
    fp[21:34, 26:39] = True  # its footprint (the DEM smears a little beyond it)
    g = buildings.ground_model(dsm.astype(np.float32), fp, None)
    assert np.all(g <= dsm + 1e-4)
    assert np.abs(g - ground)[20:35, 25:40].max() < 2.0
    assert np.abs(g - ground)[:15].max() < 1e-4  # untouched away from it


def test_ground_model_keeps_water_out_of_the_fill():
    # A shore: sea (0 m) on the left, a slope rising from 20 m, fully built up near the sea.
    yy, xx = np.mgrid[0:30, 0:40].astype(float)
    dsm = np.where(xx < 10, 0.0, 20.0 + (xx - 10)).astype(np.float32)
    water = xx < 10
    fp = (xx >= 10) & (xx < 30)
    g = buildings.ground_model(dsm, fp, None, water)
    assert np.all(g[water] == 0.0)
    assert g[15, 20] > 20.0  # filled from the land beyond the buildings, not dragged to sea level
    g_bad = buildings.ground_model(dsm, fp, None, None)
    assert g_bad[15, 12] < g[15, 12]
    assert np.all(g >= dsm - buildings.MAX_LOWERING - 1e-4)


def test_ground_model_canopy():
    dsm = np.full((20, 20), 50.0, np.float32)
    canopy = np.zeros((20, 20), np.float32)
    canopy[5:15, 5:15] = 12.0
    g = buildings.ground_model(dsm, np.zeros_like(dsm, bool), canopy)
    assert g[10, 10] == pytest.approx(44.0) and g[0, 0] == pytest.approx(50.0)


def test_encode_roundtrip():
    grid = bt.Grid(41.0, 29.0, 0.0, 2000.0, 10.0)
    poly = shapely.Polygon([(100, 100), (130, 100), (130, 120), (100, 120)], [[(110, 105), (120, 105), (120, 110),
                                                                               (110, 110)]])
    l_shape = shapely.Polygon([(-300, -300), (-260, -300), (-260, -290), (-290, -290), (-290, -260), (-300, -260)])
    recs = [(0, poly, 1, 0, (1, 2, 3), (4, 5, 6), 12.5, 0.0, 18.0, 0.0),
            (1, l_shape, 4 | 2, 2, (9, 9, 9), (8, 8, 8), 7.0, 3.0, 9.0, 1.5)]
    data, tiles = buildings.encode(recs, grid)
    out = decode(data)
    assert len(out) == 2 and tiles["non_empty"] == 2
    a = next(b for b in out if b["id"] == 0)
    assert a["base"] == pytest.approx(12.5) and a["height"] == pytest.approx(18.0)
    assert len(a["rings"]) == 2
    # Godot frame: z = -north; outline positive signed area in (x, z), hole negative.
    outline = a["rings"][0]
    assert sorted(set(np.round(outline[:, 0], 2))) == [100.0, 130.0]
    assert sorted(set(np.round(outline[:, 1], 2))) == [-120.0, -100.0]
    assert buildings._area(outline) > 0 and buildings._area(a["rings"][1]) < 0
    assert a["tris"] == 8  # rectangle with a rectangular hole
    b = next(b for b in out if b["id"] == 1)
    assert b["tris"] == 4 and b["flags"] == 6 and b["roof"] == 2


def test_header_reach_covers_large_footprints():
    grid = bt.Grid(41.0, 29.0, 0.0, 4000.0, 10.0)
    big = shapely.box(-1600.0, -10.0, 100.0, 10.0)  # centroid tile centre x -750, reaches x -1600 (2 tiles west)
    small = shapely.box(10.0, 10.0, 30.0, 30.0)
    data, tiles = buildings.encode([(0, big, 0, 0, (1, 1, 1), (1, 1, 1), 0.0, 0.0, 10.0, 0.0),
                                    (1, small, 0, 0, (1, 1, 1), (1, 1, 1), 0.0, 0.0, 10.0, 0.0)], grid)
    reach = struct.unpack_from("<H", data, 6)[0]
    assert reach == tiles["reach"] == 2
    data, tiles = buildings.encode([(1, small, 0, 0, (1, 1, 1), (1, 1, 1), 0.0, 0.0, 10.0, 0.0)], grid)
    assert struct.unpack_from("<H", data, 6)[0] == 1


def test_triangles_cover_area():
    rings = [[(0, 0), (400, 0), (400, 200), (0, 200)], [(100, 50), (100, 150), (200, 150), (200, 50)]]
    tris = buildings._triangles(rings)
    verts = [v for r in rings for v in r]
    area = sum(abs(buildings._area([verts[i] for i in t])) for t in tris)
    assert area == pytest.approx(400 * 200 - 100 * 100)


@pytest.fixture(scope="module")
def package():
    meta = json.loads((PACKAGE / "terrain.json").read_text(encoding="utf-8"))
    return meta, decode((PACKAGE / "buildings.bin").read_bytes())


def test_package_buildings(package):
    meta, blds = package
    m = meta["buildings"]
    assert len(blds) == m["count"] > 3000
    assert bt.sha256_file(PACKAGE / "buildings.bin") == m["sha256"]
    assert m["license"].startswith("ODbL")
    assert meta["height"]["surface"] == "dtm-approx"
    h = np.array([b["height"] for b in blds])
    assert 6.0 < np.median(h) < 25.0  # Üsküdar: mostly 3-7 storey blocks
    assert sum(m["height_sources"].values()) == pytest.approx(1.0, abs=1e-3)
    assert m["dropped"]["military_dropped"] > 0
    assert any("Building heights" in a for a in meta["attribution"])


def test_no_building_in_military_areas(package):
    """Military land use in the area (from the Overture cache) contains no building of the package."""
    meta, blds = package
    grid = bt.Grid(meta["origin"]["latitude"], meta["origin"]["longitude"], 0.0, meta["size_m"],
                   meta["height"]["spacing_m"])
    cached = sorted((bt.CACHE / "overture" / layers.OVERTURE_RELEASE).glob("base-land_use-*.parquet"))
    if not cached:
        pytest.skip("no Overture land use in tools/.cache")
    import pyarrow.parquet as pq
    found = False
    for path in cached:
        t = pq.read_table(path)
        geoms = [g for g, s in zip(shapely.from_wkb(t.column("geometry").to_pylist()), t.column("subtype").to_pylist())
                 if s == "military"]
        if not geoms:
            continue
        found = True
        mil = shapely.union_all(shapely.make_valid(layers.to_enu(np.array(geoms, dtype=object), grid)))
        # buildings.bin is in Godot axes (z = -north)
        pts = [shapely.Point(b["rings"][0][:, 0].mean(), -b["rings"][0][:, 1].mean()) for b in blds]
        assert not any(mil.contains(p) for p in pts)
    if not found:
        pytest.skip("no military land use cached for this area")
