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
  godot-dis `DisEntityManager.ground_path`, MIL-STD-2525 symbols, minimap; `tools/link_siblings.ps1`.
