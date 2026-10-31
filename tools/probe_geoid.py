"""Phase 0 probe: EGM2008 geoid height N via PROJ (NGA grid us_nga_egm08_25, public domain)."""
import sys

import pyproj
from pyproj.transformer import TransformerGroup

pyproj.network.set_network_enabled(True)

# Geographic 3D WGS84 (ellipsoidal h) -> WGS84 + EGM2008 height (orthometric H).  H = h - N.
group = TransformerGroup("EPSG:4979", "EPSG:4326+3855", always_xy=True)
for t in group.transformers:
    print("transformer:", t.description, "|", t.definition)
if not group.transformers:
    print("no transformer available; unavailable ops:", group.unavailable_operations)
    sys.exit(1)
t = group.transformers[0]


def geoid_n(lat: float, lon: float) -> float:
    _, _, h_ortho = t.transform(lon, lat, 0.0)
    return -h_ortho  # h=0 -> H = -N


# NGA's published EGM2008 test point (Hsynth_WGS84 test file): 38.6281550 N, 269.7791550 E -> -31.628 m.
print(f"NGA test point N = {geoid_n(38.6281550, 269.7791550 - 360):.3f} m (expected -31.628)")
for name, lat, lon in [("ankara_origin", 39.9334, 32.8597), ("kizilay", 39.9208, 32.8541),
                       ("sw_corner", 39.7534, 32.6250), ("ne_corner", 40.1134, 33.0944)]:
    print(f"{name:14s} N = {geoid_n(lat, lon):.3f} m")
