# Terrain package format (version 1)

A package is a directory written by `tools/build_terrain.py` and read by Godot with engine APIs only
(`Image.load_from_file`, `FileAccess`, `JSON`). Example: `tests/data/ankara_small/`.

| File | Content |
|---|---|
| `height.exr` | OpenEXR, one float32 channel `R` (ZIP compressed), metres. Loads as `Image.FORMAT_RF`. |
| `color.png` | RGB8, sRGB, Sentinel-2 L2A true colour. |
| `terrain.json` | Metadata, below. |
| `water.png` | Optional (`--layers water`): L8, share of each cell covered by water, 255 = all water. |
| `landcover.png` | Optional (`landcover`): L8, ESA WorldCover 2021 class value (10 tree, 20 shrub, 30 grass, 40 crop, 50 built-up, 60 bare, 70 snow, 80 water, 90 wetland, 95 mangrove, 100 moss), 0 = no data. |
| `canopy.png` | Optional (`canopy`): L8, tree canopy height in quarter metres (ETH Global Canopy Height 2020). |
| `buildings.bin` | Optional (`buildings`): building footprints, heights, roofs, colours (format in `tools/buildings.py`). |
| `footprints.png` | With `buildings`: L8 on the height grid, 255 where a footprint touches the sample's cell. |
| `roads.bin` | Optional (`roads`): road and rail polylines with class, width, bridge / tunnel flags and deck heights (format in `tools/roads.py`). |

## Grid and frame
Both rasters are square grids centred on the origin, `size_m` wide, sampled at their own `spacing_m`
(`samples = size_m / spacing_m + 1`). Row 0 is the north edge, column 0 the west edge. In Godot:

    x = -size_m/2 + col * spacing_m      (east)
    z = -size_m/2 + row * spacing_m      (south; Godot -Z is north)

The plane is the local ENU tangent plane at the origin (WGS84), identical to godot-dis `DisGeoOrigin`.

A height sample is the ENU **up** coordinate of the terrain surface point whose ENU east/north are the sample's,
relative to the origin at `origin.height` (ellipsoidal metres). The EGM2008 geoid and the Earth's curvature are
included, so `DisGeoOrigin.geodetic_to_local(lat, lon, h)` of a point on the ground gives `y` equal to the package
height at its `x, z` (when the scene origin equals the package origin). Between samples heights are bilinear.

## terrain.json
```jsonc
{
  "format": "godot-geo-terrain",
  "format_version": 1,
  "generator": "godot-geo tools/build_terrain.py 0.1.0",
  "created": "2026-10-31T15:33:41+00:00",
  "origin": {"latitude": 39.9334, "longitude": 32.8597, "height": 0.0},
  "frame": "...",
  "size_m": 3600.0,
  "height": {"file": "height.exr", "encoding": "...", "samples": 121, "spacing_m": 30.0,
             "min": 875.23, "max": 1035.25, "reference": "...", "interpolation": "bilinear between samples",
             "sha256": "..."},
  "color": {"file": "color.png", "encoding": "...", "samples": 181, "spacing_m": 20.0, "sha256": "..."},
  "corners": {"nw": {"east": -1800, "north": 1800, "latitude": ..., "longitude": ...}, "ne": ..., "sw": ..., "se": ...},
  "sources": {
    "elevation": {"product": "Copernicus DEM GLO-30 (DSM)", "vertical_datum": "EGM2008", "tiles": [{"name", "sha256"}]},
    "geoid": {"model": "EGM2008", "grid": "PROJ us_nga_egm08_25.tif ...", "n_min_m": ..., "n_max_m": ...},
    "imagery": {"product": "Sentinel-2 L2A true colour (TCI)", "scenes": [{"id", "datetime", "cloud_cover", "coverage"}]}
  },
  "attribution": ["produced using Copernicus WorldDEM-30 ...", "Contains modified Copernicus Sentinel data 2025"],
  "disclaimer": "..."
}
```
`sources` describes what went in, and its shape depends on the data:
- `elevation`: the Copernicus form above, or for your own files (`--dem`, see [own-data.md](own-data.md))
  `{"product": "user data", "files": [{"file", "format", "sha256", "crs", "vertical_datum", "vertical_datum_assumed",
  "coverage"}], "fallback": {...}}` (`fallback` only when one supplied samples; `coverage` = share of samples).
- `geoid` is the first entry of `geoids`, the list of geoid models applied (`EGM2008`, `EGM96`; empty for
  ellipsoidal input, `geoid` then says so).
- `imagery`: the Sentinel-2 form above, `{"product": "user imagery", "files": [{"file", "sha256", "crs",
  "coverage"}]}`, or `{"product": "hillshade computed from the heights"}`.
- `attribution` lists only the notices of the data actually used, plus any `--attribution` text. Longitudes in
  `corners` are in [-180, 180), so across the antimeridian the west corners can have larger values than the east ones.

Optional layers have their own key, file and grid (same frame, centred on the origin, own `spacing_m`):
```jsonc
  "water": {"file": "water.png", "encoding": "PNG L8, share of the cell covered by water (255 = all water), ...",
            "samples": 4001, "spacing_m": 2.5,
            "source": {"product": "Overture Maps base/water (OpenStreetMap)", "release": "2026-10-21.0",
                       "access": "s3://overturemaps-us-west-2/...", "subtypes": {"ocean": 4, "...": 0},
                       "rows_sha256": "..."},
            "license": "ODbL-1.0 (derived from OpenStreetMap)", "water_share": 0.208, "sha256": "..."}
```
`landcover`, `canopy` and `footprints` have the same keys (file, encoding, samples, spacing_m, source, license,
sha256). `buildings` and `roads` describe their binary files: `tile_m` (500), `tiles`, `count`, sources, licence,
and for buildings `height_sources` (shares of tag / floors / GHSL / default) and `dropped` (features left out:
military areas, underground, outside). With buildings, `height.surface` is `"dtm-approx"` and `height.ground_model`
describes the bare-earth approximation; otherwise `height.surface` is `"dsm"` (older packages have no key: DSM).
Both binary files are little-endian: a header (magic `GGBL` / `GGRD`, version 1, tile size, tile counts, feature
count), an index of zlib blocks per tile, then the blocks; coordinates are 16-bit integers in 5 cm units from the
tile centre (Godot axes: x east, z south). In `buildings.bin` the second header field is `reach`: how many tiles
beyond its own (the tile of its centroid) a footprint extends into; queries search that far. The Godot readers
are `GeoBuildingData` and `GeoRoadLayer`; they check the header and index against the package and the file size
and stop at a record that does not fit, so a damaged file gives an error or fewer features, not a crash.
All rasters and vectors are placed at the terrain surface point of a sample (its ENU east / north / up), not at
the point below it on the tangent plane, so imagery and layers line up with the heights and with DIS positions.
A cell is the `spacing_m` square centred on its sample; the value is the covered share computed with 4 × 4
supersampling, so sampling it bilinearly and cutting at 0.5 gives the shoreline to a fraction of a cell. Water
polygons are Overture `base/water` subtypes ocean, lake, pond, reservoir, river, water, canal and stream (swimming
pools and named sea areas are left out). The file is derived from OpenStreetMap and licensed under ODbL 1.0; the
package's `attribution` then includes "© OpenStreetMap contributors, Overture Maps Foundation". The same holds for
`buildings.bin`, `footprints.png` and `roads.bin` (OpenStreetMap, and Microsoft ML footprints through Overture, in
one building layer). `landcover.png` and `canopy.png` are CC BY 4.0 (ESA WorldCover; ETH Global Canopy Height),
and buildings add the GHSL notice (CC BY 4.0) for their height estimates.

Readers must check `format` and `format_version`; additions within version 1 are new keys only.
Anything that shows the terrain (a game, a screenshot, a video) must show the `attribution` lines.
