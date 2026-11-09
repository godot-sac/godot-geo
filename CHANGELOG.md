# Changelog

All notable changes to this project are documented here. Versions follow [semver](https://semver.org/).

## [Unreleased]
### Documentation
- Exported games tested with Godot 4.7.2 release templates on Windows and Linux (docs/compatibility.md).

## [0.2.0] - 2026-11-09
### Added
- Bridges from OpenStreetMap's bridge outlines and supports (Overture `base/infrastructure`, `tools/bridges.py`): a
  deck over water at the mapped height (the Bosphorus bridges were 10–20 m low), and towers, main cables and hangers
  for suspension bridges whose towers are mapped (15 Temmuz Şehitler, Fatih Sultan Mehmet). `GeoRoadLayer` draws
  them as one mesh; `terrain.json` `roads.structures`.

## [0.1.0] - 2026-11-08
First release.

### Added
- Water layer: `build_terrain.py --layers water [--water-spacing]` rasterises Overture Maps `base/water` polygons
  (OpenStreetMap coastline, lakes, rivers; read with pyarrow from the public bucket, cached) into `water.png`, an
  anti-aliased coverage mask; `--overture-release` pins the release. `GeoTerrain.water` draws it as water (wave
  normals that fade before they alias, low roughness, shallow tint near the shore) on the terrain surface itself,
  which is at the DEM's sea level there; `GeoTerrain.water_at()`, `GeoTerrainPackage.water_at()`.
- Land cover (`--layers landcover`, ESA WorldCover) and canopy (`canopy`, ETH Global Canopy Height) layers; the
  terrain shader modulates the imagery with per-class detail textures and normals near the camera (own procedural
  textures, `tools/make_detail_textures.py`).
- Buildings (`--layers buildings`, `tools/buildings.py`): Overture / OpenStreetMap footprints and building parts,
  heights from tags, levels or GHSL GHS-BUILT-H, roof shapes, colours; military areas and underground features left
  out; an approximate bare-earth ground model replaces the DEM under them (`height.surface = "dtm-approx"`).
  `GeoBuildingLayer` draws them per 500 m tile (full detail to 4 km, tall buildings as blocks to 12 km).
- Roads (`--layers roads`, `tools/roads.py`): Overture transportation segments with bridge / tunnel flags and bridge
  deck heights; `GeoRoadLayer` paints them into ring textures around the camera and draws bridge decks.
- Trees: `GeoTreeLayer`, deterministic placement from land cover and canopy height, 3D trees near, impostors far.
- `GeoTerrainLayer` children added by `GeoTerrain.auto_layers`; layer work on `WorkerThreadPool` tasks.
- Visibility queries take a `mask` (`GeoVisibility.TERRAIN | BUILDINGS | TREES`): buildings (exact on footprints)
  and tree crowns block lines of sight, ray casts and viewsheds; results name the `obstacle` and `building_id`.
- Demo `demo/city.tscn`: camera bookmarks from `demo/places.json` (Üsküdar, Istanbul), `--place`, `--tour --out`
  (one picture per bookmark + frame times), `--check` (layers, counts, frame times, known lines of sight, exit code),
  `--bench` (fixed route at 150 m and 500 m, frame time percentiles); `demo/places_sheet.py` contact sheet. The
  visibility demo prefers `terrain/uskudar_10km`.
- `demo/dis3d.tscn` moved to Üsküdar with the godot-dis exercise (origin 41.02 N 29.05 E, 60 km package first,
  ships on the water surface, patrol boat view, new screenshots).
- Test package `tests/data/uskudar_small` (3 km, Üsküdar seafront, with all layers; ODbL for the OpenStreetMap
  derived files).
- `tools/build_terrain.py`: builds a terrain package (height EXR, Sentinel-2 colour PNG, `terrain.json`) on the local
  ENU grid at an origin, with EGM2008 geoid and Earth curvature; tests against GDAL, PROJ and godot-dis golden data.
- `GeoTerrain` node: loads a package, draws it with a CDLOD renderer (geomorphing, per-node culling), `height_at`,
  `geodetic_height`, a collision patch that follows a target, alignment with godot-dis `DisGeoOrigin`.
- `GeoMath`: WGS84 geodetic / ECEF / local frame conversions in GDScript.
- Demo `demo/terrain_view.tscn`: Ankara with sun, sky, haze and a free camera.
- 3D DIS demo `demo/dis3d.tscn`: one side of the godot-dis exercise on real terrain, remote land units clamped by
  godot-dis `DisEntityManager.ground_path`, MIL-STD-2525 symbols, minimap; `tools/link_siblings.py`.
- 3D demo testing tools: time scale and pause, move units along their routes, debug overlay, CSV log, screenshots,
  `--port`, `--check` (automatic plausibility report with frame times, exit code for scripts).
- `GeoTerrain.ground_detail`: optional procedural ground detail near the camera.
- Packages from your own data: `build_terrain.py --dem` (DTED level 0/1/2 or GeoTIFF in any CRS, files or
  directories, first file wins), `--dem-vertical` (EGM2008, EGM96, ellipsoidal; detected from DTED headers and
  compound CRSs), `--dem-fallback copernicus|zero`, `--imagery` (GeoTIFF or an offline hillshade),
  `--imagery-range`, `--attribution`, `--offline`, `--geoid-grid`, `--fetch-geoid`. `terrain.json` records files by
  name and SHA-256, their datum and coverage, and only the notices of data actually used.
- `tools/dted.py`: DTED reader in plain numpy (signed-magnitude posts, voids, checksums), tested against GDAL.
- Any latitude: Copernicus DEM tiles of every width (narrower above 50, 60, 70, 80, 85 degrees), areas across a band
  edge and across 180 degrees longitude (DEM, own files, Sentinel-2 search). Test packages for Fiji and Norway.
- Visibility queries: `GeoTerrain.line_of_sight` (exact on the drawn surface, first obstruction, clearance,
  optional refraction), `raycast`, `viewshed` (R2 ray sweep, image), `set_overlay` / `clear_overlay`;
  `GeoVisibility` for worker threads.
- Demo `demo/visibility.tscn`: line of sight under the mouse, viewshed overlay, `--check` report; positions as MGRS.
- `GeoMath`: UTM (Krüger series, Norway / Svalbard zones) and MGRS conversions, tested against PROJ and the `mgrs`
  package (golden file).
- Release assets: `tools/package_release.py` packs the addon zip (`addons/geo/` with licence files and `VERSION.txt`), prebuilt
  terrain packages (Ankara 40 km with a pinned Sentinel-2 scene; Ankara, Fiji and Norway test packages) with
  `ATTRIBUTION.txt` and `.gdignore`, and `SHA256SUMS.txt`; `tools/check_package.py` installs them into an empty
  project and runs the queries. CI runs the check and attaches the assets to a draft release on `v*` tags.
- `docs/getting-started.md`: empty project to terrain with line of sight and a viewshed, from the release zips;
  `docs/compatibility.md`: what was tested on which Godot version, platform and renderer.
- `demo/visibility_tour.tscn`: scripted run of the visibility demo for the README animation and the social preview
  (`--poster`); `tools/make_gif.py` turns Movie Maker frames into a small GIF. `docs/media/`: animation, social
  preview image (1280 × 640), icon.

- Robustness: visibility queries return at once for NaN / infinite inputs (for example `height_at` of a point outside
  the package) with an `error` entry; under the headless display server the layers keep their data and queries but
  create no render resources; Sentinel-2 scenes whose true-colour asset is not a public COG are skipped (Earth
  Search Collection 1 is searched when none is left), and areas across two Sentinel-2 tiles are filled from both.
