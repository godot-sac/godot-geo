"""Phase 0 probe: find a cloud-free summer Sentinel-2 L2A scene over Ankara (Earth Search STAC) and read only the
window around the origin from its `visual` COG via HTTP range requests."""
import json
import sys
import time
import urllib.request
from pathlib import Path

import numpy as np
import rasterio
from PIL import Image
from rasterio.warp import transform_bounds
from rasterio.windows import from_bounds

STAC = "https://earth-search.aws.element84.com/v1/search"
OUT = Path(__file__).resolve().parent / ".cache" / "probe"
LAT, LON, HALF_DEG_LAT, HALF_DEG_LON = 39.9334, 32.8597, 0.09, 0.117  # ~20 x 20 km window


def search() -> list[dict]:
    body = {
        "collections": ["sentinel-2-l2a"],
        "bbox": [LON - HALF_DEG_LON, LAT - HALF_DEG_LAT, LON + HALF_DEG_LON, LAT + HALF_DEG_LAT],
        "datetime": "2025-06-01T00:00:00Z/2025-08-31T23:59:59Z",
        "query": {"eo:cloud_cover": {"lt": 2}},
        "limit": 100,
    }
    req = urllib.request.Request(STAC, data=json.dumps(body).encode(), headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req) as r:
        return json.load(r)["features"]


def main() -> int:
    items = search()
    print(f"{len(items)} scenes with cloud < 2%")
    items.sort(key=lambda f: (f["properties"]["eo:cloud_cover"], -f["properties"].get("s2:nodata_pixel_percentage", 0) * -1))
    for f in items[:5]:
        p = f["properties"]
        print(f["id"], p["datetime"], "cloud", p["eo:cloud_cover"], "nodata%", p.get("s2:nodata_pixel_percentage"))
    # Prefer a scene whose tile fully covers the window: low nodata percentage.
    best = min(items, key=lambda f: (f["properties"].get("s2:nodata_pixel_percentage", 100), f["properties"]["eo:cloud_cover"]))
    href = best["assets"]["visual"]["href"]
    print("chosen:", best["id"], href)
    t0 = time.time()
    with rasterio.Env(GDAL_DISABLE_READDIR_ON_OPEN="EMPTY_DIR", CPL_VSIL_CURL_ALLOWED_EXTENSIONS=".tif"):
        with rasterio.open(href) as ds:
            print("crs", ds.crs, "size", ds.width, ds.height, "res", ds.res, "dtype", ds.dtypes, "count", ds.count)
            b = transform_bounds("EPSG:4326", ds.crs, LON - HALF_DEG_LON, LAT - HALF_DEG_LAT,
                                 LON + HALF_DEG_LON, LAT + HALF_DEG_LAT)
            win = from_bounds(*b, transform=ds.transform).round_offsets().round_lengths()
            data = ds.read(window=win, boundless=True, fill_value=0)
    print(f"read window {win} -> {data.shape} in {time.time() - t0:.1f} s")
    OUT.mkdir(parents=True, exist_ok=True)
    img = Image.fromarray(np.moveaxis(data, 0, -1))
    img.save(OUT / "s2_ankara_window.jpg", quality=90)
    (OUT / "s2_scene.json").write_text(json.dumps({"id": best["id"], "datetime": best["properties"]["datetime"],
                                                   "href": href}, indent=2))
    print("zero pixels %:", float((data.sum(axis=0) == 0).mean() * 100))
    return 0


if __name__ == "__main__":
    sys.exit(main())
