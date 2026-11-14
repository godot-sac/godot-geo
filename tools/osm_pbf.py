"""OpenStreetMap extracts (`.osm.pbf`) as the vector source of the package layers (`build_terrain.py --osm-pbf`),
fully offline. Reads the file with pyosmium and returns the same tables tools/layers.py `overture_table()` returns
for Overture Maps, with the columns the layers use, so water, buildings, roads and bridges are built by the same code:

base/water            natural=water (subtype from water=*), landuse=reservoir / basin, waterway=riverbank, and the
                      sea: the faces of the area box cut by natural=coastline lines that lie on the coastline's
                      right-hand side (OpenStreetMap draws coastlines with the land on the left).
base/land_use         landuse=military and military=* areas (buildings inside them never enter a package).
buildings/building    building=* areas: height, min_height, building:levels, building:min_level, roof:shape,
                      roof:height, roof:colour, building:colour, location=underground.
buildings/building_part  building:part=* areas, each linked to the building that contains it.
transportation/segment highway=* and railway=* lines: class, bridge / tunnel flags, width.
base/infrastructure   man_made=bridge areas and bridge:support=* areas (subtype bridge) with their tags.

Objects near the area box are read in one pass of the file (with a margin, so ways that start outside are seen),
then each request gets the rows whose bounding box meets the box, as Overture's filter does. Everything is
cached as Parquet in tools/.cache/osm/ (keyed by the file's size, time and the box), so the other layers and a
rebuild do not read the extract again. Licence of the result: ODbL 1.0, like the extract.
"""
from __future__ import annotations

import hashlib
import re
from pathlib import Path

import shapely
import shapely.ops

KEYS = ("building", "building:part", "highway", "railway", "natural", "water", "waterway", "landuse", "military",
        "man_made", "bridge:support")
MARGIN_DEG = 0.05  # objects with a node this close to the box are looked at in full (about 5 km)
_NUMBER = re.compile(r"^\s*(-?[0-9]+(?:\.[0-9]+)?)\s*(m)?\s*$")
WATER_SUBTYPES = {"lake": "lake", "pond": "pond", "reservoir": "reservoir", "river": "river", "oxbow": "river",
                  "canal": "canal", "stream": "stream", "basin": "reservoir", "lagoon": "lake"}
HIGHWAY_CLASSES = {"motorway", "trunk", "primary", "secondary", "tertiary", "residential", "living_street",
                   "unclassified", "service", "pedestrian", "footway", "steps", "path", "track", "cycleway",
                   "bridleway"}
HIGHWAY_ALIASES = {"sidewalk": "footway", "crossing": "footway", "road": "unknown", "busway": "unknown"}
HIGHWAY_SKIP = {"proposed", "construction", "abandoned", "disused", "platform", "corridor", "elevator", "razed",
                "bus_stop", "rest_area", "services", "via_ferrata", "raceway", "escape"}
RAILWAYS = {"rail", "light_rail", "subway", "tram", "narrow_gauge", "monorail", "funicular"}
COLOURS = {"white": "#ffffff", "black": "#000000", "grey": "#808080", "gray": "#808080", "red": "#b03a2e",
           "brown": "#8b5a3c", "beige": "#d9c8a9", "yellow": "#e6c84c", "orange": "#d98a3a", "green": "#5a8a4a",
           "blue": "#4a6a9a", "cream": "#f2e6c8", "pink": "#e0a0a8", "silver": "#c0c0c0", "maroon": "#7a2a2a",
           "tan": "#c8a878", "lightgrey": "#d0d0d0", "lightgray": "#d0d0d0", "darkgrey": "#505050",
           "darkgray": "#505050"}
THEMES = (("base", "water"), ("base", "land_use"), ("buildings", "building"), ("buildings", "building_part"),
          ("transportation", "segment"), ("base", "infrastructure"))


def metres(value) -> float | None:
    """OpenStreetMap lengths: "12", "12 m", "12.5m"; None for feet, ranges and text."""
    if value is None:
        return None
    m = _NUMBER.match(str(value))
    return float(m.group(1)) if m else None


def integer(value) -> int | None:
    v = metres(value)
    return int(round(v)) if v is not None else None


def colour(value) -> str | None:
    if not value:
        return None
    v = str(value).strip().lower()
    if v.startswith("#"):
        return v
    return COLOURS.get(v.replace(" ", "").replace("_", ""))


def _true(value) -> bool:
    return value is not None and value not in ("no", "false", "0")


class OsmExtract:
    """The rows of one extract for one area box, by (theme, kind)."""

    def __init__(self, pbf: Path, cache: Path, log):
        self.pbf = Path(pbf)
        if not self.pbf.is_file():
            raise FileNotFoundError(f"--osm-pbf: no such file {self.pbf}")
        self.cache = cache
        self.log = log
        self._loaded: dict[str, dict] = {}  # box key -> {(theme, kind): pyarrow.Table}
        self._sha256: str | None = None

    def describe(self) -> dict:
        return {"product": "OpenStreetMap extract (.osm.pbf)", "file": self.pbf.name,
                "size": self.pbf.stat().st_size, "sha256": self.sha256()}

    def sha256(self) -> str:
        if self._sha256 is None:
            h = hashlib.sha256()
            with open(self.pbf, "rb") as f:
                for block in iter(lambda: f.read(1 << 22), b""):
                    h.update(block)
            self._sha256 = h.hexdigest()
        return self._sha256

    def table(self, theme: str, kind: str, bounds, columns: list[str], subtype: str | None = None):
        """(pyarrow.Table with `columns`, Parquet cache file) like layers.overture_table()."""
        import pyarrow as pa
        import pyarrow.compute as pc
        import pyarrow.parquet as pq

        st = self.pbf.stat()
        key = f"{self.pbf.name}|{st.st_size}|{int(st.st_mtime)}|{','.join(f'{b:.6f}' for b in bounds)}"
        folder = self.cache / "osm" / (self.pbf.name.split(".")[0] + "-" + hashlib.sha256(key.encode()).hexdigest()[:16])
        files = {tk: folder / f"{tk[0]}-{tk[1]}.parquet" for tk in THEMES}
        if key not in self._loaded:
            if all(f.exists() for f in files.values()):
                self._loaded[key] = {tk: pq.read_table(f) for tk, f in files.items()}
            else:
                tables = read(self.pbf, bounds, self.log)
                folder.mkdir(parents=True, exist_ok=True)
                for tk, t in tables.items():
                    part = files[tk].with_suffix(".part")
                    pq.write_table(t, part)
                    part.replace(files[tk])
                self._loaded[key] = tables
        t = self._loaded[key][(theme, kind)]
        if t.num_rows and "geometry" in t.column_names:
            # Like Overture's bbox filter: rows whose bounding box meets the box (the read kept a margin around it).
            lat0, lat1, lon0, lon1 = bounds
            b = shapely.bounds(shapely.from_wkb(t.column("geometry").to_pylist()))
            keep = (b[:, 0] < lon1) & (b[:, 2] > lon0) & (b[:, 1] < lat1) & (b[:, 3] > lat0)
            t = t.filter(pa.array(keep))
        if subtype:
            t = t.filter(pc.equal(t.column("subtype"), subtype))
        out = {c: (t.column(c) if c in t.column_names else pa.nulls(t.num_rows)) for c in columns}
        return pa.table(out), files[(theme, kind)]


# --- reading ------------------------------------------------------------------------------------------------------

class _Box:
    def __init__(self, bounds, margin: float):
        lat0, lat1, lon0, lon1 = bounds
        self.lat0, self.lat1, self.lon0, self.lon1 = lat0 - margin, lat1 + margin, lon0 - margin, lon1 + margin
        self.exact = shapely.box(lon0, lat0, lon1, lat1)

    def near(self, loc) -> bool:
        return loc.valid() and self.lat0 <= loc.lat <= self.lat1 and self.lon0 <= loc.lon <= self.lon1


def _way_near(way, box: _Box, full: bool = False) -> bool:
    nodes = way.nodes
    if len(nodes) == 0:
        return False
    if box.near(nodes[0].location):
        return True
    if not full:
        return box.near(nodes[len(nodes) - 1].location)
    return any(box.near(n.location) for n in nodes)


def _area_near(area, box: _Box) -> bool:
    for ring in area.outer_rings():
        if box.near(ring[0].location):
            return True
        if not area.from_way():  # relations: large lakes or military areas may start far away
            return any(box.near(n.location) for n in ring)
    return False


def _tags(obj) -> dict:
    return {t.k: t.v for t in obj.tags}


def _source_tags(tags: dict) -> list:
    return [[k, v] for k, v in sorted(tags.items())]


def read(pbf: Path, bounds, log) -> dict:
    """One pass over the extract; {(theme, kind): pyarrow.Table} of the objects reaching into `bounds`."""
    import osmium
    import osmium.filter
    import pyarrow as pa

    box = _Box(bounds, MARGIN_DEG)
    wkb = osmium.geom.WKBFactory()
    rows: dict[tuple, list] = {tk: [] for tk in THEMES}
    coast = []
    log(f"  reading {Path(pbf).name} (OpenStreetMap extract)")
    fp = (osmium.FileProcessor(str(pbf)).with_locations("sparse_mem_array")
          .with_areas().with_filter(osmium.filter.KeyFilter(*KEYS)))
    n_seen = 0
    for obj in fp:
        n_seen += 1
        if obj.is_area():
            if not _area_near(obj, box):
                continue
            tags = _tags(obj)
            oid = ("w" if obj.from_way() else "r") + str(obj.orig_id())
            try:
                geom = bytes.fromhex(wkb.create_multipolygon(obj))
            except Exception:  # noqa: BLE001 - broken multipolygons are skipped, as osmium does for areas
                continue
            _area_rows(rows, oid, tags, geom)
        elif obj.is_way():
            tags = _tags(obj)
            is_coast = tags.get("natural") == "coastline"
            if not ("highway" in tags or "railway" in tags or is_coast):
                continue
            if not _way_near(obj, box, full=is_coast):
                continue
            try:
                geom = bytes.fromhex(wkb.create_linestring(obj))
            except Exception:  # noqa: BLE001 - ways with missing nodes
                continue
            if is_coast:
                coast.append(shapely.from_wkb(geom))
            else:
                _segment_row(rows, "w" + str(obj.id), tags, geom)
    _link_parts(rows)
    for g in _sea(coast, box):
        rows[("base", "water")].append({"id": "coastline", "subtype": "ocean", "class": "ocean",
                                        "geometry": shapely.to_wkb(g)})
    counts = {f"{t}/{k}": len(v) for (t, k), v in rows.items()}
    log(f"  OpenStreetMap: {n_seen} tagged objects read, kept {counts}, {len(coast)} coastline ways")
    return {tk: (pa.Table.from_pylist(v) if v else pa.table({"id": pa.array([], pa.string())}))
            for tk, v in rows.items()}


def _area_rows(rows, oid: str, tags: dict, geom: bytes) -> None:
    natural, landuse, water = tags.get("natural"), tags.get("landuse"), tags.get("water")
    if natural == "water" or landuse in ("reservoir", "basin") or tags.get("waterway") == "riverbank":
        sub = WATER_SUBTYPES.get(water or landuse or "", "river" if tags.get("waterway") else "water")
        if water in ("pool", "wastewater", "fountain") or tags.get("leisure") == "swimming_pool":
            sub = "human_made"
        rows[("base", "water")].append({"id": oid, "subtype": sub, "class": water or natural or landuse,
                                        "geometry": geom})
    if landuse == "military" or _true(tags.get("military")):
        rows[("base", "land_use")].append({"id": oid, "subtype": "military",
                                           "class": tags.get("military") or "military", "geometry": geom})
    if _true(tags.get("building")) and not _true(tags.get("building:part")):
        rows[("buildings", "building")].append(_building_row(oid, tags, geom) | {"has_parts": False})
    if _true(tags.get("building:part")):
        rows[("buildings", "building_part")].append(_building_row(oid, tags, geom) | {"building_id": None})
    if tags.get("man_made") == "bridge" or _true(tags.get("bridge:support")):
        rows[("base", "infrastructure")].append({
            "id": oid, "subtype": "bridge",
            "class": "bridge" if tags.get("man_made") == "bridge" else "bridge_support",
            "height": metres(tags.get("height")), "source_tags": _source_tags(tags), "geometry": geom})


def _building_row(oid: str, tags: dict, geom: bytes) -> dict:
    kind = tags.get("building") if _true(tags.get("building")) else tags.get("building:part")
    return {
        "id": oid, "class": kind, "subtype": "military" if kind == "military" else None,
        "height": metres(tags.get("height")), "min_height": metres(tags.get("min_height")),
        "num_floors": integer(tags.get("building:levels")), "min_floor": integer(tags.get("building:min_level")),
        "roof_shape": tags.get("roof:shape"), "roof_height": metres(tags.get("roof:height")),
        "roof_color": colour(tags.get("roof:colour")), "facade_color": colour(tags.get("building:colour")),
        "is_underground": tags.get("location") == "underground" or kind == "underground",
        "sources": [{"dataset": "OpenStreetMap", "record_id": oid}], "geometry": geom,
    }


def _segment_row(rows, oid: str, tags: dict, geom: bytes) -> None:
    hw, rw = tags.get("highway"), tags.get("railway")
    if rw in RAILWAYS:
        subtype, cls = "rail", rw
    elif hw and hw not in HIGHWAY_SKIP and tags.get("area") != "yes":
        base = hw[:-5] if hw.endswith("_link") else hw
        subtype, cls = "road", base if base in HIGHWAY_CLASSES else HIGHWAY_ALIASES.get(base, "unknown")
    else:
        return
    flags = []
    if _true(tags.get("bridge")):
        flags.append({"values": ["is_bridge"], "between": None})
    if _true(tags.get("tunnel")):
        flags.append({"values": ["is_tunnel"], "between": None})
    width = metres(tags.get("width"))
    rows[("transportation", "segment")].append({
        "id": oid, "subtype": subtype, "class": cls, "road_flags": flags or None,
        "width_rules": [{"value": width, "between": None}] if width else None, "geometry": geom})


def _link_parts(rows) -> None:
    """building_id of each part: the building that contains it (OpenStreetMap does not link them)."""
    blds = rows[("buildings", "building")]
    parts = rows[("buildings", "building_part")]
    if not blds or not parts:
        return
    polys = shapely.from_wkb([b["geometry"] for b in blds])
    tree = shapely.STRtree(polys)
    for p in parts:
        pt = shapely.from_wkb(p["geometry"]).representative_point()
        hits = [int(i) for i in tree.query(pt, predicate="within")]
        if hits:
            best = min(hits, key=lambda i: polys[i].area)  # the innermost building
            p["building_id"] = blds[best]["id"]
            blds[best]["has_parts"] = True


def _sea(lines: list, box: _Box) -> list:
    """Sea polygons inside the exact box from coastline lines: the box is cut along the coastlines and every face on
    the right-hand side of a coastline (seen along its direction) is sea. No coastline: no sea."""
    if not lines:
        return []
    merged = shapely.ops.linemerge(shapely.MultiLineString([g for g in lines if g.geom_type == "LineString"]))
    clipped = shapely.intersection(merged, box.exact)
    if clipped.is_empty:
        return []
    parts = [g for g in getattr(clipped, "geoms", [clipped]) if g.geom_type == "LineString"]
    faces = list(shapely.ops.polygonize(shapely.unary_union([box.exact.boundary] + parts)))
    sea = []
    for face in faces:
        verdict = None
        for line in parts:
            c = list(line.coords)
            for (x0, y0), (x1, y1) in zip(c[:-1], c[1:]):
                mx, my = (x0 + x1) / 2, (y0 + y1) / 2
                if face.boundary.distance(shapely.Point(mx, my)) > 1e-9:
                    continue
                d = ((x1 - x0) ** 2 + (y1 - y0) ** 2) ** 0.5
                if d < 1e-12:
                    continue
                eps = 1e-7
                right = shapely.Point(mx + (y1 - y0) / d * eps, my - (x1 - x0) / d * eps)
                left = shapely.Point(mx - (y1 - y0) / d * eps, my + (x1 - x0) / d * eps)
                if face.contains(right):
                    verdict = True
                elif face.contains(left):
                    verdict = False
                if verdict is not None:
                    break
            if verdict is not None:
                break
        if verdict:
            sea.append(face)
    return sea
