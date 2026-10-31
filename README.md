# godot-geo

Real-world terrain for Godot 4 from open data: Copernicus DEM elevation and Sentinel-2 imagery, in a WGS84-based
local frame shared with godot-dis (DIS, IEEE 1278.1).

> **Status:** in development, not released yet. APIs may change before v0.1.0.

![3D DIS demo on the terrain of Ankara](docs/demo3d/overview.jpg)

<sub>Contains modified Copernicus Sentinel data 2025. Elevation produced using Copernicus WorldDEM-30 © DLR e.V.
2010-2014 and © Airbus Defence and Space GmbH 2014-2018 provided under COPERNICUS by the European Union and ESA; all
rights reserved.</sub>

## Features
- **Package builder** (`tools/build_terrain.py`, Python): downloads Copernicus DEM GLO-30 tiles and cloud-free
  Sentinel-2 L2A scenes for an area, resamples them onto the local ENU grid of an origin (EGM2008 geoid and Earth
  curvature applied) and writes a package: `height.exr`, `color.png`, `terrain.json`
  ([format](docs/package-format.md)).
- **`GeoTerrain` node** (GDScript, engine APIs only): loads a package and draws it with a CDLOD renderer
  (quadtree level of detail with geomorphing).
- **Queries:** `height_at(x, z)`, `geodetic_height(lat, lon)`, conversions between geodetic and scene positions.
  The rendered surface, the queries and the collision shape use the same triangulation.
- **Collision:** a `HeightMapShape3D` patch that follows the camera or a given node.
- **godot-dis integration:** alignment with `DisGeoOrigin`; `DisEntityManager.ground_path` places remote land
  entities on the terrain.

## Requirements
- Godot 4.7 (the addon uses engine APIs available since 4.3, untested there).
- For building packages: Python 3.12+ and the packages in `tools/requirements.txt` (rasterio, pyproj, pymap3d,
  numpy, OpenEXR, Pillow). Internet access to the public AWS buckets of Copernicus DEM and Earth Search (no
  account needed).

## Installation
Copy `addons/geo/` into your project. No plugin needs to be enabled; the classes are global.

## Usage
Build a package (40 × 40 km around Ankara at 10 m; about 30 s once the downloads are cached):
```sh
python -m venv tools/.venv
tools/.venv/Scripts/python -m pip install -r tools/requirements.txt     # bin/python on Linux and macOS
tools/.venv/Scripts/python -I tools/build_terrain.py --lat 39.9334 --lon 32.8597 --size 40000 --spacing 10 --out terrain/ankara
```
Load it:
```gdscript
var terrain := GeoTerrain.new()
terrain.package_path = "res://terrain/ankara"
add_child(terrain)

var y := terrain.height_at(x, z)                   # surface height at a scene position
var h := terrain.geodetic_height(39.95, 32.80)     # WGS84 ellipsoidal height of the ground
```
Anything that shows the terrain must show the data attribution: `terrain.attribution()`.

Limits: one package at a time, no streaming; latitudes up to 50°; packages are read from the file system.

## Demos
- `demo/terrain_view.tscn`: terrain with sun, sky and haze; free camera.
- `demo/dis3d.tscn`: a DIS exercise in 3D with godot-dis and godot-milsymbol, with debug and test tools. Setup:
  [docs/demo-3d.md](docs/demo-3d.md).

## Documentation
- [GeoTerrain API and renderer](docs/geo-terrain.md)
- [Terrain package format](docs/package-format.md)
- [3D DIS demo](docs/demo-3d.md)
- [Phase 0 findings](docs/phase0.md) (data sources, vertical datum, renderer comparison)
- [Plan](PLAN.md) (in Turkish) and [changelog](CHANGELOG.md)

## Development
```sh
godot --headless --path . --import
godot --headless --path . -s addons/gut/gut_cmdln.gd                        # Godot tests (GUT)
tools/.venv/Scripts/python -m pytest tests/python -q -p no:cacheprovider     # package builder tests
```
The Python tests compare packages with independent references (GDAL sampling, PROJ geoid grid, pymap3d golden
data). See [CONTRIBUTING.md](CONTRIBUTING.md).

## Contributing
Bug reports, questions and pull requests are welcome. Please read [CONTRIBUTING.md](CONTRIBUTING.md) and the
[code of conduct](CODE_OF_CONDUCT.md).

## License
MIT, see [LICENSE](LICENSE). Terrain data is not part of this repository (except a 3.6 km test package) and is
subject to its own terms (Copernicus DEM licence, Copernicus Sentinel data policy); packages carry the required
attribution. See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
