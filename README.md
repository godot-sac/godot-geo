# godot-geo

**Real-world terrain for Godot 4 from open data**: Copernicus DEM elevation and Sentinel-2 imagery, placed on the
WGS84 ellipsoid with millimetre accuracy, so simulations, DIS entities and maps agree on where the ground is.

![A DIS exercise in 3D on the real terrain of Ankara: Godot simulations and Open-DIS Python traffic](docs/demo3d/overview.jpg)

<sub>Ankara, 60 × 60 km. Three simulations on one network: blue (this demo, 3D), red (the
[godot-dis](../godot-dis) 2D demo) and civilian traffic from Open-DIS Python. Contains modified Copernicus Sentinel
data 2025. Elevation produced using Copernicus WorldDEM-30 © DLR e.V. 2010-2014 and © Airbus Defence and Space GmbH
2014-2018 provided under COPERNICUS by the European Union and ESA; all rights reserved.</sub>

> 🚧 Not released yet (v0.1 in preparation). MIT licensed, built in the open — issues and ideas welcome.

## Why
Game terrain tools are made for hand-painted worlds. Simulation needs the opposite: real ground, in a known
coordinate system, the same in every participant. godot-geo is a small, dependency-free pipeline for that:
- **Open data, commercial use allowed:** Copernicus DEM GLO-30 and Sentinel-2 L2A, fetched without an account.
- **Geodetically correct:** heights are WGS84 ellipsoidal (EGM2008 geoid applied, N = +37.2 m at Ankara), on the
  local ENU tangent plane of an origin with the Earth's curvature included (−70 m at 30 km). The frame is the one
  [godot-dis](../godot-dis) uses for DIS (IEEE 1278.1), so remote entities land exactly on the ground.
- **No GDAL or Python at run time:** an offline tool writes a small package (EXR heights, PNG colour, JSON
  metadata); the Godot addon is plain GDScript using engine APIs only.
- **One surface everywhere:** the rendered terrain, `height_at()`, geodetic queries and the collision shape are the
  same triangulated surface, tested to 1 cm.

## Features
| | |
|---|---|
| Package builder (`tools/build_terrain.py`) | any area by centre and size; DEM tiles and the clearest summer scenes chosen and cached; multi-scene mosaics; SHA-256 of every input and output; 40 × 40 km at 10 m in ~30 s |
| `GeoTerrain` node | loads a package; own CDLOD renderer (quadtree LOD with geomorphing, no cracks, per-node culling); 0.6–0.8 ms per frame for 40 × 40 km at 10 m on an RTX 4080 |
| Queries | `height_at(x, z)`, `geodetic_height(lat, lon)`, `geodetic_to_global()`, `global_to_geodetic()` |
| Collision | `HeightMapShape3D` patch that follows the camera or any node |
| godot-dis | automatic alignment with `DisGeoOrigin`; `DisEntityManager.ground_path` puts remote land units on this terrain and tilts them to the slope |
| Renderer-neutral format | [documented](docs/package-format.md); a Terrain3D backend was prototyped and is ~100 lines away |

## Accuracy, tested
- Package heights against GDAL bilinear sampling of the DEM plus the PROJ EGM2008 grid: **max 0.23 mm** over 500
  points (16 Python tests, including DEM tile seams and curvature).
- WGS84 / ENU conversions against pymap3d golden data shared with godot-dis; corners against an independent PROJ
  pipeline (< 1 cm).
- Godot side (25 GUT tests): triangle interpolation, bounds, geodetic round trips, origin alignment, ray casts against
  the drawn surface, CDLOD tiling and level steps, a remote DIS tank landing on the package within 1 cm.
- Demo self-check: `dis3d.tscn -- --check 60` runs the exercise and reports units that jump, reverse, sink, float or
  fly too low, and frame times (exit code 1 on problems).

## Quick start
```powershell
cd godot-geo
py -3.13 -m venv tools\.venv
.\tools\.venv\Scripts\python.exe -m pip install -r tools\requirements.txt
.\tools\.venv\Scripts\python.exe -I tools\build_terrain.py --lat 39.9334 --lon 32.8597 --size 40000 --spacing 10 --out terrain\ankara
godot --path . res://demo/terrain_view.tscn
```
```gdscript
$GeoTerrain.package_path = "res://terrain/ankara"
var y := $GeoTerrain.height_at(x, z)                  # surface height at a scene position
var h := $GeoTerrain.geodetic_height(39.95, 32.80)    # WGS84 ellipsoidal height of the ground
```
Any place on Earth up to 50° latitude works (`--lat`, `--lon`, `--size`); higher latitudes are on the roadmap.

## Demos
- `demo/terrain_view.tscn`: the terrain alone; free camera, six views, walk on the ground (F).
- `demo/dis3d.tscn`: the DIS exercise in 3D with godot-dis and godot-milsymbol (MIL-STD-2525 symbols): orbit
  camera on any unit, minimap, time scale, debug overlay, CSV logging, self-check. Setup: [docs/demo-3d.md](docs/demo-3d.md).

## Documentation
[GeoTerrain API and renderer](docs/geo-terrain.md) · [package format](docs/package-format.md) ·
[3D DIS demo](docs/demo-3d.md) · [phase 0 findings and renderer comparison](docs/phase0.md) · [plan](PLAN.md) ·
[changelog](CHANGELOG.md)

## Roadmap
v0.1: release with prebuilt demo packages. Next: land-cover materials from ESA WorldCover (CC BY), DTED / GeoTIFF
reading in the engine, streaming of large areas, OpenStreetMap roads, latitudes above 50°.

## Related
Part of an open-source simulation toolset for Godot: [godot-dis](../godot-dis) (DIS networking, C++ GDExtension) and
[godot-milsymbol](../godot-milsymbol) (MIL-STD-2525 / APP-6 military symbols).

## License
MIT. Terrain data is not part of this repository (except a 3.6 km test package); packages carry the attribution
required by each source (Copernicus DEM, Copernicus Sentinel data), and anything that shows the terrain must show it.
See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
