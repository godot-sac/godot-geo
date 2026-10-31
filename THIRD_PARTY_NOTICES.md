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
Packages are not in the repository, except the small test package `tests/data/ankara_small/` (3.6 × 3.6 km), which
contains modified Copernicus DEM and Sentinel-2 data under the notices below (see its `terrain.json`).

### Copernicus DEM GLO-30
Free of charge, commercial use permitted (licence: Copernicus DEM licence, COPDEM-30). Required notice for modified
data:

> produced using Copernicus WorldDEM-30 © DLR e.V. 2010-2014 and © Airbus Defence and Space GmbH 2014-2018 provided
> under COPERNICUS by the European Union and ESA; all rights reserved

### Copernicus Sentinel-2
Full, free and open access (Copernicus data policy). Required notice: "Contains modified Copernicus Sentinel data
[year]". `docs/phase0/*.jpg`, `docs/phase2/*.jpg` and `docs/demo3d/*.jpg` contain modified Copernicus Sentinel data 2025 and the Copernicus DEM notice above.

### EGM2008 geoid (NGA)
Used through the PROJ grid `us_nga_egm08_25.tif` at package build time (public domain, U.S. National
Geospatial-Intelligence Agency). Only derived heights end up in packages.

## Evaluated, not included
- Terrain3D 1.1.0 (MIT, Copyright (c) 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors) — Phase 0
  renderer comparison; not committed until the renderer decision.
