"""Phase 0 probe: download the Copernicus DEM GLO-30 tile covering Ankara and print its metadata."""
import hashlib
import json
import sys
import urllib.request
from pathlib import Path

import rasterio

CACHE = Path(__file__).resolve().parent / ".cache" / "copdem30"
TILE = "Copernicus_DSM_COG_10_N39_00_E032_00_DEM"
URL = f"https://copernicus-dem-30m.s3.amazonaws.com/{TILE}/{TILE}.tif"


def fetch(url: str, dest: Path) -> Path:
    if not dest.exists():
        dest.parent.mkdir(parents=True, exist_ok=True)
        print(f"downloading {url}")
        tmp = dest.with_suffix(".part")
        urllib.request.urlretrieve(url, tmp)
        tmp.rename(dest)
    return dest


def main() -> int:
    path = fetch(URL, CACHE / f"{TILE}.tif")
    sha = hashlib.sha256(path.read_bytes()).hexdigest()
    with rasterio.open(path) as ds:
        info = {
            "file": path.name,
            "sha256": sha,
            "size_bytes": path.stat().st_size,
            "crs": ds.crs.to_string(),
            "crs_wkt": ds.crs.to_wkt(),
            "width": ds.width,
            "height": ds.height,
            "dtype": ds.dtypes[0],
            "nodata": ds.nodata,
            "transform": list(ds.transform)[:6],
            "bounds": list(ds.bounds),
            "area_or_point": ds.tags().get("AREA_OR_POINT"),
            "tags": ds.tags(),
            "band_tags": ds.tags(1),
            "overviews": ds.overviews(1),
        }
        # Elevation at Kizilay square (39.9208 N, 32.8541 E) and at Ankara Esenboga airport ARP.
        for name, lat, lon in [("kizilay", 39.9208, 32.8541), ("esenboga_arp", 40.1281, 32.9951)]:
            v = next(ds.sample([(lon, lat)]))[0]
            info[f"h_{name}"] = float(v)
    print(json.dumps(info, indent=2, default=str))
    return 0


if __name__ == "__main__":
    sys.exit(main())
