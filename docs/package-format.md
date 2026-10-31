# Terrain package format (version 1)

A package is a directory written by `tools/build_terrain.py` and read by Godot with engine APIs only
(`Image.load_from_file`, `FileAccess`, `JSON`). Example: `tests/data/ankara_small/`.

| File | Content |
|---|---|
| `height.exr` | OpenEXR, one float32 channel `R` (ZIP compressed), metres. Loads as `Image.FORMAT_RF`. |
| `color.png` | RGB8, sRGB, Sentinel-2 L2A true colour. |
| `terrain.json` | Metadata, below. |

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
Readers must check `format` and `format_version`; additions within version 1 are new keys only.
Anything that shows the terrain (a game, a screenshot, a video) must show the `attribution` lines.
