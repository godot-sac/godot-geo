"""Bridge outlines and suspension bridge structures for the roads layer (tools/roads.py).

Data: Overture Maps `base/infrastructure`, subtype `bridge` (OpenStreetMap; ODbL):
- bridge outlines (`man_made=bridge` areas) with `bridge:structure` and, where mapped, `height` (the deck above the
  water or ground below; for the Bosphorus bridges 64-65 m). roads.py lifts the deck of a road crossing water inside
  such an outline to that height.
- bridge supports (`bridge:support`, parts of towers with `height` / `min_height` above the ground).

For a suspension bridge whose outline has a height and exactly two tower clusters of supports, towers, main cables
and hangers are generated: two legs per tower at the cable planes (90 % of the outline's half width) from the ground
to the highest part, a cross beam for every flat part (OpenStreetMap maps the beams), cables as parabolas from deck
level at the outline ends over the tower tops, 3 m above the deck at mid span, and a hanger every 18 m. Nothing is
generated where the data lacks the towers or the deck height (then the bridge is the deck only).
"""
from __future__ import annotations

import re

import numpy as np
import shapely

import layers

HANGER_STEP_M = 18.0
CABLE_RADIUS_M = 0.45
TOWER_CLUSTER_M = 60.0
_NUMBER = re.compile(r"^\s*([0-9]+(?:\.[0-9]+)?)\s*(m)?\s*$")


def metres(value) -> float | None:
    """OpenStreetMap height values: "65", "65 m", "65.5m"; None for anything else (feet, ranges, text)."""
    if value is None:
        return None
    if isinstance(value, (int, float)):
        return float(value) if np.isfinite(value) else None
    m = _NUMBER.match(str(value))
    return float(m.group(1)) if m else None


class Bridges:
    """Bridge outlines and supports of a package, in its local east / north metres."""

    def __init__(self, outlines: list[dict], supports: list[dict]):
        self.outlines = outlines  # {"poly": Polygon, "height": float | None, "structure": str}
        self.supports = supports  # {"poly": Polygon, "height": float, "min_height": float}
        self._tree = shapely.STRtree([o["poly"] for o in outlines]) if outlines else None

    def outline_at(self, point) -> dict | None:
        """The outline with a height that contains `point` (shapely Point, east / north), or None."""
        if self._tree is None:
            return None
        for i in self._tree.query(point.buffer(5.0), predicate="intersects"):
            o = self.outlines[int(i)]
            if o["height"] is not None:
                return o
        return None


def load(grid, bounds, release, cache, network, log) -> Bridges:
    cols = ["id", "subtype", "class", "height", "geometry", "source_tags"]
    t, _ = layers.overture_table("base", "infrastructure", bounds, cols, release, cache, network, log,
                                 subtype="bridge")
    rows = t.to_pylist()
    geoms = layers.to_enu(shapely.from_wkb([r["geometry"] for r in rows]), grid) if rows else []
    outlines, supports = [], []
    for r, g in zip(rows, geoms):
        if g is None or g.is_empty:
            continue
        tags = dict(r.get("source_tags") or [])
        if g.geom_type == "LineString" and g.is_closed and len(g.coords) >= 4:
            g = shapely.Polygon(g.coords)
        if g.geom_type not in ("Polygon", "MultiPolygon") or not g.is_valid:
            continue
        height = metres(r.get("height")) or metres(tags.get("height"))
        if tags.get("man_made") == "bridge":
            outlines.append({"poly": g, "height": height, "structure": tags.get("bridge:structure", "")})
        elif r.get("class") == "bridge_support" and height is not None and height >= 20.0:
            supports.append({"poly": g, "height": height, "min_height": metres(tags.get("min_height")) or 0.0})
    log(f"  bridges: {len(outlines)} outlines ({sum(1 for o in outlines if o['height'] is not None)} with a "
        f"height), {len(supports)} tower parts")
    return Bridges(outlines, supports)


def _clusters(parts: list[dict]) -> list[list[dict]]:
    out: list[list[dict]] = []
    for p in parts:
        c = p["poly"].centroid
        for group in out:
            if group[0]["poly"].centroid.distance(c) < TOWER_CLUSTER_M:
                group.append(p)
                break
        else:
            out.append([p])
    return out


def _r(v: float) -> float:
    return round(float(v), 2)


def structures(bridges: Bridges, ground_at) -> dict:
    """Towers, cables and hangers of the suspension bridges, package frame (x east, y up, z = -north)."""
    towers, cables, hangers = [], [], []
    for o in bridges.outlines:
        if o["height"] is None or "suspension" not in o["structure"]:
            continue
        area = o["poly"].buffer(40.0)
        parts = [s for s in bridges.supports if area.contains(s["poly"].centroid)]
        groups = _clusters(parts)
        if len(groups) != 2:
            continue
        rect = o["poly"].minimum_rotated_rectangle
        xy = np.asarray(rect.exterior.coords)[:4]
        sides = [np.linalg.norm(xy[(k + 1) % 4] - xy[k]) for k in range(4)]
        k = int(np.argmax(sides[:2]))
        u = (xy[k + 1] - xy[k]) / sides[k]
        half_width = max(min(sides[:2]) * 0.5 * 0.9, 8.0)
        a = (xy[(k + 3) % 4] + xy[k]) * 0.5  # middle of one short side
        length = sides[k]
        lateral = np.array([-u[1], u[0]])
        stations = sorted(float(np.dot(np.asarray(g[0]["poly"].centroid.coords[0]) - a, u)) for g in groups)
        mid = a + u * (stations[0] + stations[1]) * 0.5
        deck = float(ground_at([mid[0]], [mid[1]])[0]) + o["height"]
        tops = []
        for g, s in zip(sorted(groups, key=lambda g: float(np.dot(np.asarray(g[0]["poly"].centroid.coords[0]) - a, u))),
                        stations):
            c = a + u * s
            base = float(ground_at([c[0]], [c[1]])[0])
            top = base + max(p["height"] for p in g)
            tops.append(top)
            beams = sorted({(_r(base + p["min_height"]), _r(base + p["height"])) for p in g
                            if 0.0 < p["height"] - p["min_height"] <= 15.0})
            towers.append({"x": _r(c[0]), "z": _r(-c[1]), "ux": round(float(u[0]), 5), "uz": round(float(-u[1]), 5),
                           "half_width": _r(half_width), "base": _r(base - 5.0), "top": _r(top),
                           "beams": [list(b) for b in beams]})
        top_y = min(tops) - 2.0
        s0, s1 = stations
        spans = [(0.0, s0, deck + 1.0, "up"), (s0, s1, deck + 3.0, "sag"), (s1, length, deck + 1.0, "down")]
        for side in (-1.0, 1.0):
            off = lateral * half_width * side
            points = []
            for lo, hi, low, kind in spans:
                n = max(int((hi - lo) / 15.0), 4)
                for s in np.linspace(lo, hi, n + 1)[:-1] if kind != "down" else np.linspace(lo, hi, n + 1):
                    if kind == "sag":
                        f = ((s - (lo + hi) * 0.5) / ((hi - lo) * 0.5)) ** 2
                    elif kind == "up":
                        f = ((s - lo) / (hi - lo)) ** 2
                    else:
                        f = ((hi - s) / (hi - lo)) ** 2
                    y = low + (top_y - low) * f
                    p = a + u * s + off
                    points.append([_r(p[0]), _r(y), _r(-p[1])])
            cables.append({"points": points, "radius": CABLE_RADIUS_M})
            for s in np.arange(HANGER_STEP_M, length, HANGER_STEP_M):
                if abs(s - s0) < 8.0 or abs(s - s1) < 8.0:
                    continue
                if s < s0:
                    y = deck + 1.0 + (top_y - deck - 1.0) * (s / s0) ** 2
                elif s > s1:
                    y = deck + 1.0 + (top_y - deck - 1.0) * ((length - s) / (length - s1)) ** 2
                else:
                    y = deck + 3.0 + (top_y - deck - 3.0) * ((s - (s0 + s1) * 0.5) / ((s1 - s0) * 0.5)) ** 2
                if y - deck < 2.0:
                    continue
                p = a + u * s + off
                hangers.append([_r(p[0]), _r(-p[1]), _r(deck), _r(y)])
    return {"towers": towers, "cables": cables, "hangers": hangers}
