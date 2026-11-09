"""Tests for tools/bridges.py: OpenStreetMap height values, deck outlines, suspension bridge structures."""
import sys
from pathlib import Path

import numpy as np
import shapely

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / "tools"))
import bridges  # noqa: E402


def test_metres():
    assert bridges.metres("65 m") == 65.0
    assert bridges.metres("65") == 65.0
    assert bridges.metres("64.5m") == 64.5
    assert bridges.metres(155.0) == 155.0
    for bad in (None, "", "60 ft", "50-60", "tall", float("nan")):
        assert bridges.metres(bad) is None


def _support(x: float, height: float, min_height: float = 0.0) -> dict:
    return {"poly": shapely.box(x - 4, -15, x + 4, 15), "height": height, "min_height": min_height}


def _suspension(supports: list[dict], height=65.0, structure="suspension") -> bridges.Bridges:
    # A 1500 m long, 30 m wide bridge along east-west, towers 540 m either side of the middle.
    outline = {"poly": shapely.box(-750, -15, 750, 15), "height": height, "structure": structure}
    return bridges.Bridges([outline], supports)


def flat(e, n):
    return np.zeros(np.shape(e))


TOWERS = [_support(-540, 155, 50), _support(-540, 125, 120), _support(540, 155, 152), _support(540, 125, 120)]


def test_outline_at():
    b = _suspension(TOWERS)
    assert b.outline_at(shapely.Point(0, 0))["height"] == 65.0
    assert b.outline_at(shapely.Point(0, 500)) is None
    assert bridges.Bridges([], []).outline_at(shapely.Point(0, 0)) is None


def test_suspension_structures():
    s = bridges.structures(_suspension(TOWERS), flat)
    assert len(s["towers"]) == 2
    west, east = sorted(s["towers"], key=lambda t: t["x"])
    assert abs(west["x"] + 540) < 1 and abs(east["x"] - 540) < 1
    assert west["top"] == 155.0 and west["base"] == -5.0
    assert [120.0, 125.0] in west["beams"] and [152.0, 155.0] in east["beams"]
    assert abs(abs(west["ux"]) - 1.0) < 1e-6 and abs(west["half_width"] - 13.5) < 0.01
    assert len(s["cables"]) == 2
    for cable in s["cables"]:
        pts = np.asarray(cable["points"])
        assert abs(pts[:, 0].min() + 750) < 1 and abs(pts[:, 0].max() - 750) < 1, "anchor to anchor"
        mid = pts[np.argmin(np.abs(pts[:, 0]))]
        assert abs(mid[1] - 68.0) < 0.5, "3 m above the 65 m deck at mid span"
        assert pts[:, 1].max() <= 153.0 + 0.01, "below the tower tops"
        assert abs(abs(pts[0, 2]) - 13.5) < 0.01, "in the cable plane"
    assert len(s["hangers"]) > 100
    for x, z, y0, y1 in s["hangers"]:
        assert y0 == 65.0 and y1 - y0 >= 2.0


def test_nothing_without_data():
    assert bridges.structures(_suspension(TOWERS, height=None), flat)["towers"] == []
    assert bridges.structures(_suspension(TOWERS, structure="beam"), flat)["towers"] == []
    assert bridges.structures(_suspension(TOWERS[:2]), flat)["cables"] == [], "one tower: not a suspension span"
    assert bridges.structures(_suspension([]), flat)["hangers"] == []
