# Third-Party Notices

Entries are added when third-party code or data is copied into this repository or shipped in a terrain package.
Development-time tools (rasterio/GDAL, numpy, pyproj/PROJ, pymap3d, Pillow, OpenEXR, pytest) are listed in `tools/requirements.txt`;
their code is not included.

## Included

### GUT 9.7.1 (Godot Unit Test)
`addons/gut/` — tests only, not part of the distributed addon. MIT License, Copyright (c) 2018 Tom "Butch" Wesley.
Full text: `addons/gut/LICENSE.md`.

### geo_cases.txt
`tests/golden/geo_cases.txt` is copied from this project's sibling godot-dis (MIT, same author); generated there
with pymap3d.

## Data (attribution carried by every terrain package and by derived screenshots)
Packages are not in the repository, except the small test packages `tests/data/ankara_small/` (3.6 × 3.6 km),
`tests/data/fiji_small/` and `tests/data/norway_small/` (3 × 3 km each), which contain modified Copernicus DEM and
Sentinel-2 data under the notices below (see their `terrain.json`). Packages built from your own files
(`--dem`, `--imagery`) carry the notices you pass with `--attribution`.

### Copernicus DEM GLO-30
Free of charge, commercial use permitted (licence: Copernicus DEM licence, COPDEM-30). Required notice for modified
data:

> produced using Copernicus WorldDEM-30 © DLR e.V. 2010-2014 and © Airbus Defence and Space GmbH 2014-2018 provided
> under COPERNICUS by the European Union and ESA; all rights reserved

### Copernicus Sentinel-2
Full, free and open access (Copernicus data policy). Required notice: "Contains modified Copernicus Sentinel data
[year]". `docs/phase0/*.jpg`, `docs/phase2/*.jpg`, `docs/demo3d/*.jpg`, `docs/visibility/*.jpg`,
`docs/getting-started/*.jpg`, `docs/media/visibility.gif` and `docs/media/social-preview.jpg` contain modified
Copernicus Sentinel data 2025 and the Copernicus DEM notice above (shown in the pictures themselves, except the
older `docs/phase0` and `docs/phase2` sheets, which carry it in their documents).

The release assets `godot-geo-terrain-*.zip` contain the same data; each package has an `ATTRIBUTION.txt` with its
notices.

### EGM2008 and EGM96 geoids (NGA)
Used through the PROJ grids `us_nga_egm08_25.tif` and `us_nga_egm96_15.tif` at package build time (public domain,
U.S. National Geospatial-Intelligence Agency); `--fetch-geoid` stores them in `tools/.cache/geoid/` (not in git).
Only derived heights end up in packages.

## Specifications and algorithms (no code copied)
- `tools/dted.py` follows the public DTED specification MIL-PRF-89020B; GDAL's DTED driver is used only as a test
  oracle.
- `GeoMath` UTM follows C. F. F. Karney, *Transverse Mercator with an accuracy of a few nanometers* (2011). The golden
  file `tests/golden/utm_mgrs_cases.txt` was generated with PROJ (pyproj) and the Python `mgrs` package (MIT,
  Howard Butler); `mgrs` is not a dependency.
- `GeoVisibility.viewshed` implements the R2 sweep described by W. R. Franklin and C. Ray (1994). GRASS GIS
  `r.viewshed` (GPL) was background reading only.

## Evaluated, not included
- Terrain3D 1.1.0 (MIT, Copyright (c) 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors) — Phase 0
  renderer comparison; not committed until the renderer decision.
