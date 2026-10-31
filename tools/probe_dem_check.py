"""Phase 0 probe: sanity-check DEM heights against a published elevation (Esenboga airport, 953 m AMSL)."""
import urllib.request
from pathlib import Path

import rasterio

CACHE = Path(__file__).resolve().parent / ".cache" / "copdem30"
TILE = "Copernicus_DSM_COG_10_N40_00_E032_00_DEM"
p = CACHE / f"{TILE}.tif"
if not p.exists():
    urllib.request.urlretrieve(f"https://copernicus-dem-30m.s3.amazonaws.com/{TILE}/{TILE}.tif", p)
with rasterio.open(p) as ds:
    # Runway 03R/21L midpoint area and ARP (AIP LTAC: ARP 40 07 41N 032 59 42E, elevation 3125 ft = 952.5 m).
    for name, lat, lon in [("arp", 40 + 7 / 60 + 41 / 3600, 32 + 59 / 60 + 42 / 3600)]:
        print(name, float(next(ds.sample([(lon, lat)]))[0]))
