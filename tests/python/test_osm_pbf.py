"""tools/osm_pbf.py: OpenStreetMap extracts as the vector source of the layers (--osm-pbf). A small hand-made OSM
file (XML, which pyosmium reads like .osm.pbf) covers each table, the box filter and the sea from coastlines."""
from __future__ import annotations

import sys
from pathlib import Path

import pytest
import shapely

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "tools"))

osmium = pytest.importorskip("osmium")
import layers  # noqa: E402
import osm_pbf  # noqa: E402

# The box: 41.00..41.02 N, 29.00..29.02 E. The coastline runs south along 29.005 E; OpenStreetMap keeps the land on
# the left of a coastline, so the land is east of it and the sea west.
BOUNDS = (41.00, 41.02, 29.00, 29.02)

NODES = {
    # coastline from north to south at 29.005 E: land on the left = east, sea = west
    1: (41.03, 29.005), 2: (41.01, 29.005), 3: (40.99, 29.005),
    # building with a part, and its tags
    10: (41.010, 29.010), 11: (41.010, 29.011), 12: (41.011, 29.011), 13: (41.011, 29.010),
    14: (41.0102, 29.0102), 15: (41.0102, 29.0105), 16: (41.0105, 29.0105), 17: (41.0105, 29.0102),
    # military area and a building inside it
    20: (41.015, 29.012), 21: (41.015, 29.018), 22: (41.019, 29.018), 23: (41.019, 29.012),
    24: (41.016, 29.013), 25: (41.016, 29.014), 26: (41.017, 29.014), 27: (41.017, 29.013),
    # lake
    30: (41.003, 29.012), 31: (41.003, 29.014), 32: (41.005, 29.014),
    # roads: a bridge, a subway tunnel, a road under construction, a motorway link
    40: (41.008, 29.006), 41: (41.008, 29.019), 42: (41.012, 29.006), 43: (41.012, 29.019),
    44: (41.006, 29.006), 45: (41.006, 29.019), 46: (41.004, 29.006), 47: (41.004, 29.019),
    # bridge outline
    50: (41.0079, 29.010), 51: (41.0079, 29.012), 52: (41.0081, 29.012), 53: (41.0081, 29.010),
    # a building far outside the box
    60: (41.30, 29.30), 61: (41.30, 29.301), 62: (41.301, 29.301), 63: (41.301, 29.30),
}
WAYS = [
    (100, [1, 2, 3], {"natural": "coastline"}),
    (101, [10, 11, 12, 13, 10], {"building": "apartments", "building:levels": "7", "height": "24 m",
                                 "roof:shape": "flat", "building:colour": "white", "roof:colour": "#a33"}),
    (102, [14, 15, 16, 17, 14], {"building:part": "yes", "height": "40", "min_height": "24"}),
    (103, [20, 21, 22, 23, 20], {"landuse": "military"}),
    (104, [24, 25, 26, 27, 24], {"building": "yes"}),
    (105, [30, 31, 32, 30], {"natural": "water", "water": "lake"}),
    (106, [40, 41], {"highway": "primary", "bridge": "yes", "width": "14"}),
    (107, [42, 43], {"railway": "subway", "tunnel": "yes"}),
    (108, [44, 45], {"highway": "construction", "construction": "primary"}),
    (109, [46, 47], {"highway": "motorway_link"}),
    (110, [50, 51, 52, 53, 50], {"man_made": "bridge", "height": "64", "bridge:structure": "suspension"}),
    (111, [60, 61, 62, 63, 60], {"building": "house"}),
]


def _write_osm(path: Path) -> None:
    out = ['<?xml version="1.0" encoding="UTF-8"?>', '<osm version="0.6" generator="test">']
    for i, (lat, lon) in sorted(NODES.items()):
        out.append(f'<node id="{i}" version="1" lat="{lat}" lon="{lon}"/>')
    for wid, refs, tags in WAYS:
        out.append(f'<way id="{wid}" version="1">')
        out += [f'<nd ref="{r}"/>' for r in refs]
        out += [f'<tag k="{k}" v="{v}"/>' for k, v in tags.items()]
        out.append("</way>")
    out.append("</osm>")
    path.write_text("\n".join(out), encoding="utf-8")


@pytest.fixture(scope="module")
def extract(tmp_path_factory):
    d = tmp_path_factory.mktemp("osm")
    f = d / "test.osm"
    _write_osm(f)
    return osm_pbf.OsmExtract(f, d / "cache", lambda *a: None)


def _rows(extract, theme, kind, cols, subtype=None):
    t, _ = extract.table(theme, kind, BOUNDS, cols, subtype)
    return t.to_pylist()


def test_buildings_and_parts(extract):
    rows = {r["id"]: r for r in _rows(extract, "buildings", "building", [
        "id", "class", "height", "num_floors", "roof_shape", "roof_color", "facade_color", "has_parts", "sources",
        "is_underground", "geometry"])}
    assert set(rows) == {"w101", "w104"}, "the far building is outside the box"
    b = rows["w101"]
    assert (b["class"], b["height"], b["num_floors"], b["roof_shape"]) == ("apartments", 24.0, 7, "flat")
    assert b["facade_color"] == "#ffffff" and b["roof_color"] == "#a33"
    assert b["has_parts"] is True and rows["w104"]["has_parts"] is False
    assert b["sources"][0]["dataset"] == "OpenStreetMap"
    parts = _rows(extract, "buildings", "building_part", ["id", "building_id", "height", "min_height"])
    assert parts == [{"id": "w102", "building_id": "w101", "height": 40.0, "min_height": 24.0}]


def test_military_land_use(extract):
    rows = _rows(extract, "base", "land_use", ["id", "subtype", "class"])
    assert rows == [{"id": "w103", "subtype": "military", "class": "military"}]


def test_segments(extract):
    rows = {r["id"]: r for r in _rows(extract, "transportation", "segment",
                                      ["id", "subtype", "class", "road_flags", "width_rules"])}
    assert set(rows) == {"w106", "w107", "w109"}, "highway=construction is left out"
    assert rows["w106"]["class"] == "primary"
    assert rows["w106"]["road_flags"][0]["values"] == ["is_bridge"]
    assert rows["w106"]["width_rules"][0]["value"] == 14.0
    assert (rows["w107"]["subtype"], rows["w107"]["road_flags"][0]["values"]) == ("rail", ["is_tunnel"])
    assert rows["w109"]["class"] == "motorway"


def test_bridges(extract):
    rows = _rows(extract, "base", "infrastructure", ["id", "class", "height", "source_tags"], subtype="bridge")
    assert len(rows) == 1 and rows[0]["class"] == "bridge" and rows[0]["height"] == 64.0
    assert dict(rows[0]["source_tags"])["bridge:structure"] == "suspension"


def test_water_and_sea(extract):
    rows = _rows(extract, "base", "water", ["id", "subtype", "geometry"])
    by = {r["subtype"]: shapely.from_wkb(r["geometry"]) for r in rows}
    assert set(by) == {"lake", "ocean"}
    sea = by["ocean"]
    # The coastline runs south along 29.005 E, so the sea is the strip west of it, inside the box.
    assert sea.contains(shapely.Point(29.002, 41.01))
    assert not sea.contains(shapely.Point(29.010, 41.01))
    assert sea.area == pytest.approx(0.005 * 0.02, rel=1e-6)


def test_layers_switch_source(extract, tmp_path):
    f = tmp_path / "x.osm"
    _write_osm(f)
    layers.use_osm_pbf(f, tmp_path / "cache", lambda *a: None)
    try:
        t, _ = layers.overture_table("buildings", "building", BOUNDS, ["id"], layers.OVERTURE_RELEASE, tmp_path,
                                     lambda w: pytest.fail(f"network used for {w}"), lambda *a: None)
        assert sorted(t.column("id").to_pylist()) == ["w101", "w104"]
        assert layers.attribution() == layers.OSM_ONLY_ATTRIBUTION
        assert layers.vector_source("buildings", "x", "r")["file"] == "x.osm"
    finally:
        layers.use_osm_pbf(None, tmp_path, lambda *a: None)
    assert layers.attribution() == layers.OSM_ATTRIBUTION


def test_lengths_and_colours():
    assert osm_pbf.metres("12.5 m") == 12.5 and osm_pbf.metres("40'") is None and osm_pbf.metres(None) is None
    assert osm_pbf.integer("3") == 3 and osm_pbf.integer("3;4") is None
    assert osm_pbf.colour("Light Grey") == "#d0d0d0" and osm_pbf.colour("#ABC") == "#abc"
    assert osm_pbf.colour("mauve") is None
