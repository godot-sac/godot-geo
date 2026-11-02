# Changelog

All notable changes to this project are documented here. Versions follow [semver](https://semver.org/).

## [Unreleased]
### Added
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

### Changed
- Visibility demo: the attribution wraps to the window width instead of being cut off on narrow windows.
- Sentinel-2 scenes whose true-colour asset is not a public COG (requester-pays JPEG 2000) are skipped; when none is
  left, Earth Search Collection 1 is searched.

### Fixed
- `build_terrain.py`: areas spanning two Sentinel-2 tiles stayed partly black (only the first tile's scenes were
  read); a tile is now skipped once one of its scenes adds nothing.
